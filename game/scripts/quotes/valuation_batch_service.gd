extends RefCounted
## Local, deterministic valuation input from one completed quote batch.
## This module does not write LedgerCore, mappings, or storage. Persist returned state atomically.

const Contract = preload("res://scripts/quotes/quote_contract.gd")
const Decimal = preload("res://scripts/data/decimal_text.gd")


static func new_state() -> Dictionary:
	return {"schema_version": 1, "revision": 0, "processed_batches": {}, "snapshots": {}}


static func create_snapshot(state: Dictionary, batch: Dictionary, positions: Array,
		cash_balances: Array, base_currency: String, allow_stale: bool = false,
		expected_revision: int = -1, restricted_balances: Array = [],
		other_asset_values: Array = []) -> Dictionary:
	if not _currency(base_currency) or int(state.get("schema_version", -1)) != 1 \
		or typeof(state.get("processed_batches", null)) != TYPE_DICTIONARY \
		or typeof(state.get("snapshots", null)) != TYPE_DICTIONARY \
		or not state.has("revision"):
		return _error("INVALID_STATE_OR_CURRENCY")
	if int(batch.get("schema_version", -1)) != 1 or str(batch.get("id", "")).is_empty() \
		or Contract.utc_unix(str(batch.get("completed_at", ""))) < 0:
		return _error("INVALID_BATCH")
	if not _valid_batch(batch):
		return _error("INVALID_BATCH")
	var batch_id := str(batch.id)
	var input := _normalize_input(positions, cash_balances, restricted_balances,
		other_asset_values)
	if not input.ok:
		return input
	var fingerprint := _fingerprint(batch, input.positions, input.cash_balances,
		base_currency, input.restricted_balances, input.other_asset_values)
	var processed_raw = state.processed_batches.get(batch_id, {})
	if typeof(processed_raw) != TYPE_DICTIONARY:
		return _error("INVALID_STATE_OR_CURRENCY")
	var processed: Dictionary = processed_raw
	if not processed.is_empty():
		if str(processed.get("fingerprint", "")) != fingerprint:
			return _error("BATCH_INPUT_CONFLICT")
		if not state.snapshots.has(str(processed.get("snapshot_id", ""))):
			return _error("INVALID_STATE_OR_CURRENCY")
		return {"ok": true, "duplicate": true, "state": state,
			"snapshot": state.snapshots[processed.snapshot_id].duplicate(true)}
	if expected_revision >= 0 and int(state.revision) != expected_revision:
		return _error("REVISION_CONFLICT")
	if not ["COMPLETE", "COMPLETE_WITH_STALE"].has(str(batch.get("status", ""))):
		return _error("BATCH_INCOMPLETE")
	if not batch.get("failed_symbols", []).is_empty():
		return _error("BATCH_INCOMPLETE")
	if not batch.get("stale_symbols", []).is_empty() and not allow_stale:
		return _error("STALE_CONFIRMATION_REQUIRED")
	var entries: Dictionary = batch.get("entries", {})
	var total := "0"
	var position_values: Array = []
	var cash_values: Array = []
	var restricted_values: Array = []
	var other_values: Array = []
	for position in input.positions:
		var key := Contract.identity_key(position.identity)
		var quote_result := _quote_for(entries, key, position.identity,
			str(batch.completed_at), allow_stale)
		if not quote_result.ok:
			return quote_result
		var quote: Dictionary = quote_result.quote
		var original := Decimal.multiply(str(position.quantity), str(quote.price))
		var converted := _convert(entries, original, str(quote.currency), base_currency,
			str(batch.completed_at), allow_stale)
		if not converted.ok:
			return converted
		total = Decimal.add(total, str(converted.amount))
		position_values.append({"position_id": position.position_id,
			"instrument_identity": position.identity, "quantity": position.quantity,
			"market_value": original, "currency": quote.currency,
			"base_value": converted.amount, "quote": quote,
			"quote_status": quote_result.status, "fx_quote": converted.fx_quote})
	for balance in input.cash_balances:
		var converted := _convert(entries, str(balance.amount), str(balance.currency),
			base_currency, str(batch.completed_at), allow_stale)
		if not converted.ok:
			return converted
		total = Decimal.add(total, str(converted.amount))
		cash_values.append({"balance_id": balance.balance_id, "amount": balance.amount,
			"currency": balance.currency, "base_value": converted.amount,
			"fx_quote": converted.fx_quote})
	for balance in input.restricted_balances:
		var converted := _convert(entries, str(balance.amount), str(balance.currency),
			base_currency, str(batch.completed_at), allow_stale)
		if not converted.ok:
			return converted
		total = Decimal.add(total, str(converted.amount))
		restricted_values.append({"balance_id": balance.balance_id,
			"amount": balance.amount, "currency": balance.currency,
			"base_value": converted.amount, "fx_quote": converted.fx_quote})
	for asset in input.other_asset_values:
		var converted := _convert(entries, str(asset.amount), str(asset.currency),
			base_currency, str(batch.completed_at), allow_stale)
		if not converted.ok:
			return converted
		total = Decimal.add(total, str(converted.amount))
		other_values.append({"asset_id": asset.asset_id,
			"amount": asset.amount, "currency": asset.currency,
			"valuation_basis": asset.valuation_basis,
			"effective_at": asset.effective_at,
			"event_id": asset.event_id,
			"base_value": converted.amount, "fx_quote": converted.fx_quote})
	var gold_quotes: Array = []
	for key in entries.keys():
		var entry: Dictionary = entries[key]
		if str(entry.get("identity", {}).get("kind", "")) == "GOLD" \
			and entry.has("quote"):
			gold_quotes.append(entry.quote.duplicate(true))
	var snapshot_id := "valuation:" + batch_id
	var snapshot := {"schema_version": 1, "id": snapshot_id, "quote_batch_id": batch_id,
		"asset_total": total, "base_currency": base_currency,
		"position_values": position_values, "cash_values": cash_values,
		"restricted_values": restricted_values,
		"other_asset_values": other_values,
		"gold_quotes": gold_quotes, "stale_symbols": batch.get("stale_symbols", []).duplicate(),
		"stale_confirmed": allow_stale and not batch.get("stale_symbols", []).is_empty(),
		"created_at": batch.completed_at, "revision": int(state.revision) + 1}
	var next := state.duplicate(true)
	next.revision = snapshot.revision
	next.snapshots[snapshot_id] = snapshot.duplicate(true)
	next.processed_batches[batch_id] = {"fingerprint": fingerprint, "snapshot_id": snapshot_id}
	return {"ok": true, "duplicate": false, "state": next, "snapshot": snapshot}


static func _normalize_input(positions: Array, cash_balances: Array,
		restricted_balances: Array = [], other_asset_values: Array = []) -> Dictionary:
	var normalized_positions: Array = []
	var normalized_cash: Array = []
	var normalized_restricted: Array = []
	var normalized_other: Array = []
	var used_ids := {}
	for raw in positions:
		if typeof(raw) != TYPE_DICTIONARY:
			return _error("INVALID_POSITION")
		var id := str(raw.get("position_id", ""))
		var raw_identity = raw.get("identity", {})
		if typeof(raw_identity) != TYPE_DICTIONARY:
			return _error("INVALID_POSITION")
		var identity := Contract.normalize_identity(raw_identity)
		var quantity = raw.get("quantity", null)
		if id.is_empty() or used_ids.has("P:" + id) or identity.is_empty() \
			or not ["STOCK", "ETF", "FUND"].has(identity.kind) \
			or typeof(quantity) != TYPE_STRING or not _nonnegative(quantity):
			return _error("INVALID_POSITION")
		used_ids["P:" + id] = true
		normalized_positions.append({"position_id": id, "identity": identity,
			"quantity": Decimal.canonical(quantity)})
	for raw in cash_balances:
		if typeof(raw) != TYPE_DICTIONARY:
			return _error("INVALID_CASH_BALANCE")
		var id := str(raw.get("balance_id", ""))
		var amount = raw.get("amount", null)
		var currency := str(raw.get("currency", ""))
		if id.is_empty() or used_ids.has("C:" + id) or not _currency(currency) \
			or typeof(amount) != TYPE_STRING or not _nonnegative(amount):
			return _error("INVALID_CASH_BALANCE")
		used_ids["C:" + id] = true
		normalized_cash.append({"balance_id": id, "amount": Decimal.canonical(amount),
			"currency": currency})
	for raw in restricted_balances:
		if typeof(raw) != TYPE_DICTIONARY:
			return _error("INVALID_RESTRICTED_BALANCE")
		var id := str(raw.get("balance_id", ""))
		var amount = raw.get("amount", null)
		var currency := str(raw.get("currency", ""))
		if id.is_empty() or used_ids.has("C:" + id) or \
				used_ids.has("R:" + id) or not _currency(currency) or \
				typeof(amount) != TYPE_STRING or not _nonnegative(amount):
			return _error("INVALID_RESTRICTED_BALANCE")
		used_ids["R:" + id] = true
		normalized_restricted.append({"balance_id": id,
			"amount": Decimal.canonical(amount), "currency": currency})
	for raw in other_asset_values:
		if typeof(raw) != TYPE_DICTIONARY:
			return _error("INVALID_OTHER_ASSET_VALUE")
		var id := str(raw.get("asset_id", ""))
		var amount = raw.get("amount", null)
		var currency := str(raw.get("currency", ""))
		if id.is_empty() or used_ids.has("O:" + id) or \
				not _currency(currency) or typeof(amount) != TYPE_STRING or \
				not _nonnegative(amount) or \
				str(raw.get("valuation_basis", "")).strip_edges().is_empty() or \
				Contract.utc_unix(str(raw.get("effective_at", ""))) < 0 or \
				str(raw.get("event_id", "")).is_empty():
			return _error("INVALID_OTHER_ASSET_VALUE")
		used_ids["O:" + id] = true
		normalized_other.append({"asset_id": id,
			"amount": Decimal.canonical(amount), "currency": currency,
			"valuation_basis": str(raw.valuation_basis).strip_edges(),
			"effective_at": str(raw.effective_at),
			"event_id": str(raw.event_id)})
	normalized_positions.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return str(a.position_id) < str(b.position_id))
	normalized_cash.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return str(a.balance_id) < str(b.balance_id))
	normalized_restricted.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return str(a.balance_id) < str(b.balance_id))
	normalized_other.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return str(a.asset_id) < str(b.asset_id))
	return {"ok": true, "positions": normalized_positions,
		"cash_balances": normalized_cash,
		"restricted_balances": normalized_restricted,
		"other_asset_values": normalized_other}


static func _quote_for(entries: Dictionary, key: String, identity: Dictionary,
		now_at: String, allow_stale: bool) -> Dictionary:
	var entry: Dictionary = entries.get(key, {})
	if entry.is_empty() or not entry.has("quote"):
		return _error("MISSING_QUOTE")
	var status := str(entry.get("status", ""))
	if not ["SUCCESS", "STALE", "STALE_FALLBACK"].has(status):
		return _error("INVALID_QUOTE_STATUS")
	if status != "SUCCESS" and not allow_stale:
		return _error("STALE_CONFIRMATION_REQUIRED")
	var validated := Contract.validate_quote(entry.quote, identity, now_at)
	if not validated.ok:
		return _error("INVALID_QUOTE_INPUT")
	return {"ok": true, "quote": validated.quote, "status": status}


static func _convert(entries: Dictionary, amount: String, currency: String,
		base_currency: String, now_at: String, allow_stale: bool) -> Dictionary:
	if currency == base_currency:
		return {"ok": true, "amount": amount, "fx_quote": {}}
	var identity := {"kind": "FX", "market": "FX", "symbol": currency + "/" + base_currency,
		"currency": base_currency, "share_class": ""}
	var quote_result := _quote_for(entries, Contract.identity_key(identity), identity,
		now_at, allow_stale)
	if not quote_result.ok:
		return _error("MISSING_OR_INVALID_FX")
	return {"ok": true, "amount": Decimal.multiply(amount, str(quote_result.quote.price)),
		"fx_quote": quote_result.quote}


static func _fingerprint(batch: Dictionary, positions: Array, cash_balances: Array,
		base_currency: String, restricted_balances: Array = [],
		other_asset_values: Array = []) -> String:
	var quote_parts: Array[String] = []
	var entries: Dictionary = batch.get("entries", {})
	var keys: Array = entries.keys()
	keys.sort()
	for key in keys:
		var entry: Dictionary = entries[key]
		var quote: Dictionary = entry.get("quote", {})
		quote_parts.append("|".join([str(key), str(entry.get("status", "")),
			str(quote.get("id", "")), str(quote.get("price", "")),
			str(quote.get("quoted_at", "")), str(quote.get("fetched_at", "")),
			str(quote.get("source", "")), str(quote.get("provider_symbol", "")),
			str(quote.get("currency", "")), str(quote.get("unit", "")),
			str(quote.get("delay", "")), str(quote.get("session", ""))]))
	var parts := [str(batch.id), str(batch.get("status", "")),
		str(batch.get("request_fingerprint", "")), quote_parts,
		positions, cash_balances, base_currency]
	# Keep old batch identities stable for projects without restricted accounts.
	if not restricted_balances.is_empty():
		parts.append(restricted_balances)
	if not other_asset_values.is_empty():
		parts.append({"other_asset_values": other_asset_values})
	return JSON.stringify(parts).sha256_text()


static func _valid_batch(batch: Dictionary) -> bool:
	if typeof(batch.get("requested_symbols", null)) != TYPE_ARRAY \
		or typeof(batch.get("entries", null)) != TYPE_DICTIONARY \
		or typeof(batch.get("success_symbols", null)) != TYPE_ARRAY \
		or typeof(batch.get("stale_symbols", null)) != TYPE_ARRAY \
		or typeof(batch.get("failed_symbols", null)) != TYPE_ARRAY \
		or typeof(batch.get("provider_versions", null)) != TYPE_DICTIONARY:
		return false
	if str(batch.provider_versions.get("selected", "")).is_empty():
		return false
	var requested: Array = batch.requested_symbols
	var entries: Dictionary = batch.entries
	var keys: Array[String] = []
	for identity in requested:
		if typeof(identity) != TYPE_DICTIONARY:
			return false
		var key := Contract.identity_key(identity)
		if key.is_empty() or keys.has(key) or not entries.has(key):
			return false
		keys.append(key)
	if keys.is_empty() or entries.size() != keys.size():
		return false
	keys.sort()
	if "\n".join(keys).sha256_text() != str(batch.get("request_fingerprint", "")):
		return false
	var expected_success: Array[String] = []
	var expected_stale: Array[String] = []
	var expected_failed: Array[String] = []
	for key in keys:
		var entry_raw = entries[key]
		if typeof(entry_raw) != TYPE_DICTIONARY:
			return false
		var entry: Dictionary = entry_raw
		if typeof(entry.get("identity", null)) != TYPE_DICTIONARY \
			or Contract.identity_key(entry.identity) != key:
			return false
		match str(entry.get("status", "")):
			"SUCCESS":
				expected_success.append(key)
			"STALE", "STALE_FALLBACK":
				expected_stale.append(key)
			"FAILED":
				expected_failed.append(key)
			_:
				return false
		if str(entry.status) != "FAILED":
			if typeof(entry.get("quote", null)) != TYPE_DICTIONARY \
				or not Contract.validate_quote(entry.quote, entry.identity,
					str(batch.completed_at)).ok:
				return false
		elif entry.has("quote"):
			return false
	if not _same_key_set(batch.success_symbols, expected_success) \
		or not _same_key_set(batch.stale_symbols, expected_stale) \
		or not _same_key_set(batch.failed_symbols, expected_failed):
		return false
	if not expected_failed.is_empty():
		return str(batch.get("status", "")) == "INCOMPLETE"
	if not expected_stale.is_empty():
		return str(batch.get("status", "")) == "COMPLETE_WITH_STALE"
	return str(batch.get("status", "")) == "COMPLETE"


static func _same_key_set(actual: Array, expected: Array[String]) -> bool:
	if actual.size() != expected.size():
		return false
	for key in actual:
		if typeof(key) != TYPE_STRING:
			return false
	var copy := actual.duplicate()
	copy.sort()
	return copy == expected


static func _nonnegative(value: String) -> bool:
	return Decimal.is_valid(value) and Decimal.compare(value, "0") >= 0


static func _currency(value: String) -> bool:
	if value.length() != 3:
		return false
	for index in value.length():
		var character := value.substr(index, 1)
		if character < "A" or character > "Z":
			return false
	return true


static func _error(code: String) -> Dictionary:
	return {"ok": false, "error": code}
