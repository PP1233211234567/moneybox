extends RefCounted
## Local user-entered valuation preview and confirmation for an initialized
## personal ledger. Market requirements come from every active account/holding.

const Store = preload("res://scripts/data/project_store.gd")
const Ledger = preload("res://scripts/data/ledger_core.gd")
const Decimal = preload("res://scripts/data/decimal_text.gd")
const Contract = preload("res://scripts/quotes/quote_contract.gd")
const Gateway = preload("res://scripts/quotes/quote_gateway.gd")
const Provider = preload("res://scripts/quotes/user_manual_quote_provider.gd")
const Valuation = preload("res://scripts/quotes/valuation_batch_service.gd")
const Mapping = preload("res://scripts/domain/gold_mapping_service.gd")
const GoldFlow = preload("res://scripts/quotes/personal_gold_flow.gd")

const MAX_QUOTE_AGE_SECONDS := 86400
const MAX_PREVIEW_AGE_SECONDS := 600

var _store: RefCounted
var _base_path: String


func _init(base_path: String = "user://personal/moneybox") -> void:
	_base_path = base_path
	_store = Store.new(base_path)


func requirements(expected_generation: int, gold_currency: String = "") -> Dictionary:
	var loaded := _load_personal(expected_generation)
	if not loaded.ok:
		return loaded
	var derived := _derive(loaded.state.ledger, gold_currency)
	if not derived.ok:
		return derived
	var coverage: Dictionary = _store.validate_valuation_coverage(loaded.state.ledger,
		derived.positions, derived.cash_balances, derived.restricted_balances,
		derived.other_asset_values)
	if not coverage.ok:
		return coverage
	return {"ok": true, "generation": expected_generation,
		"ledger_hash": Store.canonical_ledger_hash(loaded.state.ledger),
		"base_currency": derived.base_currency,
		"gold_currency": derived.gold_currency,
		"identities": derived.identities.duplicate(true),
		"position_count": derived.positions.size(),
		"cash_account_count": derived.cash_balances.size(),
		"restricted_account_count": derived.restricted_balances.size(),
		"other_asset_count": derived.other_asset_values.size(),
		"quote_source": "USER_MANUAL"}


func preview(manual_entries: Dictionary, expected_generation: int,
		at_utc: String = "", gold_currency: String = "") -> Dictionary:
	if at_utc.is_empty():
		at_utc = Time.get_datetime_string_from_system(true, false) + "Z"
	var ready := _prepare(manual_entries, expected_generation, at_utc, gold_currency)
	if not ready.ok:
		return ready
	var id := _preview_id(expected_generation, ready.source_project_sha256,
		ready.batch_id, at_utc, str(ready.valued.snapshot.asset_total),
		str(ready.mapping.revision.mapping_key))
	return {"ok": true, "generation": expected_generation,
		"source_project_sha256": ready.source_project_sha256,
		"ledger_hash": ready.ledger_hash, "batch_id": ready.batch_id,
		"at_utc": at_utc, "gold_currency": ready.gold_currency,
		"preview_id": id, "quote_source": "USER_MANUAL",
		"quote_count": ready.identities.size(),
		"restricted_balances": ready.restricted_balances.duplicate(true),
		"other_asset_values": ready.other_asset_values.duplicate(true),
		"asset_total": str(ready.valued.snapshot.asset_total),
		"base_currency": ready.base_currency,
		"equivalent_grams": str(ready.mapping.revision.equivalent_grams),
		"whole_grams": str(ready.mapping.revision.whole_grams),
		"price_per_gram": str(ready.mapping.revision.price_per_gram),
		"duplicate": ready.duplicate}


func confirm(manual_entries: Dictionary, shown_preview: Dictionary,
		confirmation: Dictionary, now_at: String = "") -> Dictionary:
	if confirmation.get("confirmed", null) != true or \
			str(confirmation.get("preview_id", "")) != str(shown_preview.get("preview_id", "")) or \
			str(confirmation.get("preview_id", "")).is_empty():
		return _error("EXPLICIT_CONFIRMATION_REQUIRED")
	if shown_preview.get("ok", false) != true or \
			typeof(shown_preview.get("generation", null)) != TYPE_INT or \
			typeof(shown_preview.get("at_utc", null)) != TYPE_STRING:
		return _error("VALID_PREVIEW_REQUIRED")
	if now_at.is_empty():
		now_at = Time.get_datetime_string_from_system(true, false) + "Z"
	var now_unix := Contract.utc_unix(now_at)
	var preview_unix := Contract.utc_unix(str(shown_preview.at_utc))
	if now_unix < 0 or preview_unix < 0 or now_unix < preview_unix or \
			now_unix - preview_unix > MAX_PREVIEW_AGE_SECONDS:
		return _error("PREVIEW_EXPIRED")
	var ready := _prepare(manual_entries, int(shown_preview.generation),
		str(shown_preview.at_utc), str(shown_preview.get("gold_currency", "")))
	if not ready.ok:
		return ready
	var expected_id := _preview_id(int(shown_preview.generation),
		ready.source_project_sha256, ready.batch_id,
		str(shown_preview.at_utc), str(ready.valued.snapshot.asset_total),
		str(ready.mapping.revision.mapping_key))
	if expected_id != str(shown_preview.preview_id) or \
			ready.source_project_sha256 != str(shown_preview.get("source_project_sha256", "")) or \
			ready.ledger_hash != str(shown_preview.get("ledger_hash", "")) or \
			ready.batch_id != str(shown_preview.get("batch_id", "")):
		return _error("PREVIEW_INPUT_CHANGED")
	for key in ready.quotes:
		var quoted_unix := Contract.utc_unix(str(ready.quotes[key].quoted_at))
		if quoted_unix > now_unix or now_unix - quoted_unix >= MAX_QUOTE_AGE_SECONDS:
			return _error("MANUAL_QUOTE_STALE")
	if ready.duplicate:
		return {"ok": true, "duplicate": true,
			"generation": int(shown_preview.generation),
			"valuation_status": "CURRENT",
			"asset_total": str(ready.valued.snapshot.asset_total),
			"equivalent_grams": str(ready.mapping.revision.equivalent_grams)}
	var committed: Dictionary = _store.commit_quote_valuation(ready.refresh,
		ready.positions, ready.cash_balances, false, int(shown_preview.generation),
		ready.restricted_balances, ready.other_asset_values)
	if not committed.ok:
		return committed
	var selection := {"valuation_snapshot_id": str(committed.snapshot.id),
		"gold_batch_id": ready.batch_id, "gold_quote_key": ready.gold_key,
		"gold_fx_key": ready.gold_fx_key, "allow_stale": false,
		"reason": "USER_ASSET_UPDATE"}
	var mapped := GoldFlow.new(_base_path).apply(selection,
		int(committed.generation), now_at)
	if not mapped.ok:
		return {"ok": false, "error": "VALUATION_SAVED_MAPPING_PENDING",
			"mapping_error": str(mapped.get("error", "UNKNOWN")),
			"valuation_saved": not committed.duplicate,
			"generation": int(committed.generation),
			"snapshot_id": str(committed.snapshot.id)}
	return {"ok": true, "duplicate": committed.duplicate and mapped.duplicate,
		"generation": int(mapped.generation),
		"valuation_generation": int(committed.generation),
		"valuation_status": "CURRENT",
		"asset_total": str(committed.snapshot.asset_total),
		"equivalent_grams": str(mapped.mapping.equivalent_grams),
		"mapping_id": str(mapped.mapping.id)}


func _prepare(manual_entries: Dictionary, expected_generation: int,
		at_utc: String, gold_currency: String) -> Dictionary:
	if Contract.utc_unix(at_utc) < 0:
		return _error("INVALID_TIME")
	var loaded := _load_personal(expected_generation)
	if not loaded.ok:
		return loaded
	var project: Dictionary = loaded.state
	var derived := _derive(project.ledger, gold_currency)
	if not derived.ok:
		return derived
	var coverage: Dictionary = _store.validate_valuation_coverage(project.ledger,
		derived.positions, derived.cash_balances, derived.restricted_balances,
		derived.other_asset_values)
	if not coverage.ok:
		return coverage
	var supplied := _manual_quotes(manual_entries, derived.identities, at_utc)
	if not supplied.ok:
		return supplied
	var ledger_hash := Store.canonical_ledger_hash(project.ledger)
	var batch_id := "manual-" + JSON.stringify([ledger_hash, supplied.fingerprint]).sha256_text().substr(0, 32)
	var refresh := Gateway.refresh(project.quote_gateway, derived.identities,
		Provider.new(supplied.quotes), at_utc, batch_id, 0, MAX_QUOTE_AGE_SECONDS)
	if not refresh.ok:
		return refresh
	if str(refresh.batch.status) != "COMPLETE" or \
			not refresh.batch.failed_symbols.is_empty() or \
			not refresh.batch.stale_symbols.is_empty():
		return _error("MANUAL_BATCH_INCOMPLETE")
	if str(refresh.batch.provider_versions.get("selected", "")) != \
			"user-manual-entry-v1":
		return _error("MANUAL_BATCH_CONTENT_CONFLICT")
	for key in supplied.quotes:
		var actual: Dictionary = refresh.batch.entries.get(key, {}).get("quote", {})
		if not _same_manual_quote(actual, supplied.quotes[key]):
			return _error("MANUAL_BATCH_CONTENT_CONFLICT")
	var valued := Valuation.create_snapshot(project.valuation, refresh.batch,
		derived.positions, derived.cash_balances, derived.base_currency, false,
		int(project.valuation.revision), derived.restricted_balances,
		derived.other_asset_values)
	if not valued.ok:
		return valued
	if valued.duplicate:
		var bound: Dictionary = _store.current_valuation_snapshot(project,
			str(valued.snapshot.id))
		if not bound.ok:
			return bound
	var gold_key := Contract.identity_key({"kind": "GOLD", "market": "SPOT",
		"symbol": "XAU", "currency": derived.gold_currency, "share_class": ""})
	var gold_quote: Dictionary = refresh.batch.entries[gold_key].quote
	var gold_fx_key := ""
	var gold_fx := {}
	if derived.gold_currency != derived.base_currency:
		gold_fx_key = Contract.identity_key({"kind": "FX", "market": "FX",
			"symbol": derived.gold_currency + "/" + derived.base_currency,
			"currency": derived.base_currency, "share_class": ""})
		var fx_quote: Dictionary = refresh.batch.entries[gold_fx_key].quote
		gold_fx = {"id": fx_quote.id, "rate": fx_quote.price,
			"from_currency": derived.gold_currency,
			"to_currency": derived.base_currency,
			"source": fx_quote.source, "quoted_at": fx_quote.quoted_at,
			"fetched_at": fx_quote.fetched_at}
	var previous: Dictionary = project.mappings.back()
	var mapped := Mapping.create_revision(str(valued.snapshot.id),
		str(valued.snapshot.asset_total), derived.base_currency,
		gold_quote, gold_fx, "total_assets", previous, "USER_ASSET_UPDATE")
	if not mapped.ok:
		return mapped
	var duplicate: bool = valued.duplicate and not mapped.changed and \
		project.get("valuation_pending", {}).is_empty() and \
		str(previous.get("ledger_hash", "")) == ledger_hash
	return {"ok": true, "positions": derived.positions,
		"cash_balances": derived.cash_balances,
		"restricted_balances": derived.restricted_balances,
		"other_asset_values": derived.other_asset_values,
		"identities": derived.identities,
		"base_currency": derived.base_currency,
		"gold_currency": derived.gold_currency,
		"ledger_hash": ledger_hash,
		"source_project_sha256": JSON.stringify(project).sha256_text(),
		"batch_id": batch_id, "refresh": refresh, "valued": valued,
		"mapping": mapped, "gold_key": gold_key, "gold_fx_key": gold_fx_key,
		"quotes": supplied.quotes, "duplicate": duplicate}


func _load_personal(expected_generation: int) -> Dictionary:
	if expected_generation < 0:
		return _error("GENERATION_REQUIRED")
	var loaded: Dictionary = _store.load_project()
	if not loaded.ok:
		return loaded
	if int(loaded.generation) != expected_generation:
		return _error("GENERATION_CONFLICT")
	var project: Dictionary = loaded.state
	if project.get("data_kind", "") != "personal":
		return _error("PERSONAL_PROJECT_REQUIRED")
	if expected_generation == 0 or project.get("mappings", []).is_empty():
		return _error("PERSONAL_PROJECT_NOT_INITIALIZED")
	return loaded


func _derive(ledger: Dictionary, gold_currency: String) -> Dictionary:
	var projection := Ledger.project(ledger)
	if not projection.ok:
		return projection
	var base := str(ledger.get("base_currency", ""))
	if base.length() != 3 or base != base.to_upper():
		return _error("INVALID_BASE_CURRENCY")
	if gold_currency.is_empty():
		gold_currency = base
	var gold := Contract.normalize_identity({"kind": "GOLD", "market": "SPOT",
		"symbol": "XAU", "currency": gold_currency, "share_class": ""})
	if gold.is_empty():
		return _error("INVALID_GOLD_CURRENCY")
	gold_currency = str(gold.currency)
	var by_key := {}
	by_key[Contract.identity_key(gold)] = gold
	var positions: Array = []
	var position_keys: Array = projection.positions.keys()
	position_keys.sort()
	for position_key in position_keys:
		var position: Dictionary = projection.positions[position_key]
		if position.quantity == "0" or projection.replaced_accounts.has(position.account_id):
			continue
		var instrument: Dictionary = ledger.instruments.get(position.instrument_id, {})
		var kind := str(instrument.get("kind", ""))
		if not ["STOCK", "ETF", "FUND"].has(kind):
			return _error("INSTRUMENT_CLASSIFICATION_REQUIRED")
		var identity := Contract.normalize_identity({"kind": kind,
			"market": instrument.get("market", ""),
			"symbol": instrument.get("symbol", ""),
			"currency": instrument.get("currency", ""),
			"share_class": instrument.get("share_class", "")})
		if identity.is_empty():
			return _error("INVALID_INSTRUMENT_IDENTITY")
		by_key[Contract.identity_key(identity)] = identity
		positions.append({"position_id": str(position_key),
			"identity": identity, "quantity": str(position.quantity)})
	var cash_balances: Array = []
	var restricted_balances: Array = []
	var other_asset_values: Array = []
	var currencies := {}
	var account_ids: Array = ledger.accounts.keys()
	account_ids.sort()
	for account_id in account_ids:
		if projection.replaced_accounts.has(account_id):
			continue
		var currency := str(ledger.accounts[account_id].currency)
		if projection.restricted_balances.has(account_id):
			restricted_balances.append({"balance_id": str(account_id),
				"amount": str(projection.restricted_balances[account_id]),
				"currency": currency,
				"account_name": str(ledger.accounts[account_id].get("name", account_id))})
		else:
			cash_balances.append({"balance_id": str(account_id),
				"amount": str(projection.cash[account_id]), "currency": currency})
		if currency != base:
			currencies[currency] = true
	for position in positions:
		if str(position.identity.currency) != base:
			currencies[str(position.identity.currency)] = true
	var other_ids: Array = ledger.get("other_assets", {}).keys()
	other_ids.sort()
	for asset_id in other_ids:
		if not projection.other_asset_values.has(asset_id) or \
				not projection.other_asset_checkpoints.has(asset_id):
			return _error("OTHER_ASSET_VALUE_MISSING")
		var asset: Dictionary = ledger.other_assets[asset_id]
		var checkpoint: Dictionary = projection.other_asset_checkpoints[asset_id]
		var currency := str(asset.currency)
		other_asset_values.append({"asset_id": str(asset_id),
			"amount": str(projection.other_asset_values[asset_id]),
			"currency": currency, "asset_name": str(asset.name),
			"ownership_scope": str(asset.ownership_scope),
			"ownership_note": str(asset.ownership_note),
			"dedup_key": str(asset.dedup_key),
			"valuation_basis": str(checkpoint.valuation_basis),
			"effective_at": str(checkpoint.effective_at),
			"event_id": str(checkpoint.event_id)})
		if currency != base:
			currencies[currency] = true
	if gold_currency != base:
		currencies[gold_currency] = true
	for currency in currencies:
		var fx := Contract.normalize_identity({"kind": "FX", "market": "FX",
			"symbol": str(currency) + "/" + base,
			"currency": base, "share_class": ""})
		if fx.is_empty():
			return _error("INVALID_FX_REQUIREMENT")
		by_key[Contract.identity_key(fx)] = fx
	var keys: Array = by_key.keys()
	keys.sort()
	var identities: Array = []
	for key in keys:
		identities.append(by_key[key])
	return {"ok": true, "base_currency": base, "gold_currency": gold_currency,
		"identities": identities, "positions": positions,
		"cash_balances": cash_balances,
		"restricted_balances": restricted_balances,
		"other_asset_values": other_asset_values}


func _manual_quotes(entries: Dictionary, identities: Array, at_utc: String) -> Dictionary:
	if entries.size() != identities.size():
		return _error("MANUAL_QUOTE_COVERAGE_MISMATCH")
	var now_unix := Contract.utc_unix(at_utc)
	var quotes := {}
	var parts: Array = []
	for identity in identities:
		var key := Contract.identity_key(identity)
		if not entries.has(key) or typeof(entries[key]) != TYPE_DICTIONARY:
			return _error("MANUAL_QUOTE_COVERAGE_MISMATCH")
		var entry: Dictionary = entries[key]
		for field in entry:
			if not ["price", "unit", "quoted_at", "source_note"].has(field):
				return _error("INVALID_MANUAL_QUOTE")
		if typeof(entry.get("price", null)) != TYPE_STRING or \
				not Decimal.is_valid(entry.price) or \
				Decimal.compare(entry.price, "0") <= 0 or \
				typeof(entry.get("unit", null)) != TYPE_STRING or \
				typeof(entry.get("quoted_at", null)) != TYPE_STRING or \
				typeof(entry.get("source_note", null)) != TYPE_STRING or \
				str(entry.source_note).strip_edges().is_empty() or \
				str(entry.source_note).length() > 256:
			return _error("INVALID_MANUAL_QUOTE")
		var quoted_unix := Contract.utc_unix(str(entry.quoted_at))
		if quoted_unix < 0 or quoted_unix > now_unix or \
				now_unix - quoted_unix >= MAX_QUOTE_AGE_SECONDS:
			return _error("MANUAL_QUOTE_STALE")
		var price := Decimal.canonical(str(entry.price))
		var source_note := str(entry.source_note).strip_edges()
		var quote_id := "user-manual-" + JSON.stringify([key, price,
			str(entry.unit), str(entry.quoted_at), source_note]).sha256_text().substr(0, 24)
		var quote := {"id": quote_id, "identity": identity.duplicate(true),
			"price": price, "currency": str(identity.currency),
			"unit": str(entry.unit), "source": "USER_MANUAL",
			"source_note": source_note, "provider_symbol": str(identity.symbol),
			"quoted_at": str(entry.quoted_at), "fetched_at": at_utc,
			"delay": "MANUAL", "session": "MANUAL_INPUT"}
		if not Contract.validate_quote(quote, identity, at_utc).ok:
			return _error("INVALID_MANUAL_QUOTE")
		quotes[key] = quote
		parts.append([key, quote_id])
	return {"ok": true, "quotes": quotes,
		"fingerprint": JSON.stringify(parts).sha256_text()}


func _preview_id(generation: int, project_hash: String, batch_id: String,
		at_utc: String, asset_total: String, mapping_key: String) -> String:
	return JSON.stringify([generation, project_hash, batch_id, at_utc,
		asset_total, mapping_key]).sha256_text()


func _same_manual_quote(actual: Dictionary, expected: Dictionary) -> bool:
	for field in ["id", "price", "currency", "unit", "source", "source_note",
			"provider_symbol", "quoted_at", "delay", "session"]:
		if str(actual.get(field, "")) != str(expected.get(field, "")):
			return false
	return typeof(actual.get("identity", null)) == TYPE_DICTIONARY and \
		Contract.identity_key(actual.identity) == Contract.identity_key(expected.identity)


func _error(code: String) -> Dictionary:
	return {"ok": false, "error": code}
