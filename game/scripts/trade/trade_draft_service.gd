extends RefCounted
## Local, deliberately narrow trade parsing. A draft never writes LedgerCore state.

const Decimal = preload("res://scripts/data/decimal_text.gd")
const Ledger = preload("res://scripts/data/ledger_core.gd")

const MONEY_UNIT := "(美元|USD|人民币|元|港币|HKD|欧元|EUR|英镑|GBP|新币|SGD)"
const NUMBER := "([0-9]+(?:\\.[0-9]+)?)"
const REQUIRED_FIELDS := ["direction", "account_id", "instrument_id", "quantity", "currency", "trade_date", "fee"]
const FIELD_NAMES := ["direction", "account_id", "instrument_id", "quantity", "currency", "trade_date",
	"settlement_date", "total_amount", "amount_basis", "unit_price", "fee", "tax_amount"]
const DRAFT_KEYS := ["schema_version", "id", "revision", "source_text_local_ref", "fields",
	"confidence", "missing_fields", "conflicts", "assumptions", "status", "created_at",
	"confirmed_command_id", "confirmed_tax_amount"]


static func parse_local(source_text: String, source_text_local_ref: String, draft_id: String,
		created_at: String, reference_date: String, candidates: Dictionary) -> Dictionary:
	var draft := {
		"schema_version": 1,
		"id": draft_id,
		"revision": 1,
		"source_text_local_ref": source_text_local_ref,
		"fields": {},
		"confidence": 1.0,
		"missing_fields": [],
		"conflicts": [],
		"assumptions": [],
		"status": "pending",
		"created_at": created_at,
	}
	var fields: Dictionary = draft.fields
	var conflicts: Array = draft.conflicts
	if source_text.length() > 500:
		_add_unique(conflicts, "INPUT_TOO_LONG")
		return draft
	var buys := _matches("买入|买了|买", source_text)
	var sells := _matches("卖出|卖了|卖", source_text)
	if not buys.is_empty() and not sells.is_empty():
		_add_unique(conflicts, "CONFLICTING_DIRECTION")
	elif not buys.is_empty():
		_put(fields, "direction", "buy", buys[0].get_string())
	elif not sells.is_empty():
		_put(fields, "direction", "sell", sells[0].get_string())

	_parse_identity(fields, conflicts, "account_id", source_text, candidates.get("accounts", []), false)
	_parse_identity(fields, conflicts, "instrument_id", source_text, candidates.get("instruments", []), true)

	var quantities := _matches(NUMBER + "\\s*(?:股|份|克)", source_text)
	var quantity_values := {}
	for found in quantities:
		var value := Decimal.canonical(found.get_string(1))
		if not value.is_empty():
			quantity_values[value] = found.get_string()
	if quantity_values.size() > 1:
		_add_unique(conflicts, "CONFLICTING_QUANTITY")
	elif quantity_values.size() == 1:
		var quantity: String = quantity_values.keys()[0]
		_put(fields, "quantity", quantity, quantity_values[quantity])

	var amount_matches := []
	for item in [
		{"pattern": "用\\s*" + NUMBER + "\\s*" + MONEY_UNIT, "basis": "cash_flow", "flow_direction": "buy"},
		{"pattern": "收到\\s*" + NUMBER + "\\s*" + MONEY_UNIT, "basis": "cash_flow", "flow_direction": "sell"},
		{"pattern": "成交金额\\s*" + NUMBER + "\\s*" + MONEY_UNIT, "basis": "gross_trade", "flow_direction": ""},
	]:
		for found in _matches(item.pattern, source_text):
			amount_matches.append({"amount": Decimal.canonical(found.get_string(1)),
				"unit": found.get_string(2), "span": found.get_string(), "basis": item.basis,
				"flow_direction": item.flow_direction})
	if amount_matches.size() > 1:
		_add_unique(conflicts, "CONFLICTING_TOTAL_AMOUNT")
	elif amount_matches.size() == 1:
		var amount: Dictionary = amount_matches[0]
		_put(fields, "total_amount", amount.amount, amount.span)
		_put(fields, "amount_basis", amount.basis, amount.span)
		if not str(amount.flow_direction).is_empty() and fields.has("direction") \
				and str(amount.flow_direction) != str(fields.direction.value):
			_add_unique(conflicts, "AMOUNT_DIRECTION_MISMATCH")

	var unit_prices := _matches("(?:每股|单价)\\s*" + NUMBER + "\\s*" + MONEY_UNIT, source_text)
	if unit_prices.size() > 1:
		_add_unique(conflicts, "CONFLICTING_UNIT_PRICE")
	elif unit_prices.size() == 1:
		_put(fields, "unit_price", Decimal.canonical(unit_prices[0].get_string(1)), unit_prices[0].get_string())

	var fees := _matches("手续费\\s*" + NUMBER + "\\s*" + MONEY_UNIT, source_text)
	if fees.size() > 1:
		_add_unique(conflicts, "CONFLICTING_FEE")
	elif fees.size() == 1:
		_put(fields, "fee", Decimal.canonical(fees[0].get_string(1)), fees[0].get_string())
	var taxes := _matches("(?:税款|税费)\\s*" + NUMBER + "\\s*" + MONEY_UNIT, source_text)
	if taxes.size() > 1:
		_add_unique(conflicts, "CONFLICTING_TAX")
	elif taxes.size() == 1:
		_put(fields, "tax_amount", Decimal.canonical(taxes[0].get_string(1)), taxes[0].get_string())

	var currencies := {}
	for found in _matches(NUMBER + "\\s*" + MONEY_UNIT, source_text):
		var currency := _currency_for(found.get_string(2))
		currencies[currency] = found.get_string()
	if currencies.size() > 1:
		_add_unique(conflicts, "CONFLICTING_CURRENCY")
	elif currencies.size() == 1:
		var currency: String = currencies.keys()[0]
		_put(fields, "currency", currency, currencies[currency])

	var settlement_matches := _matches("结算日(?:期)?[：:\\s]*([0-9]{4}-[0-9]{2}-[0-9]{2})", source_text)
	if settlement_matches.size() > 1:
		_add_unique(conflicts, "CONFLICTING_SETTLEMENT_DATE")
	elif settlement_matches.size() == 1:
		_put(fields, "settlement_date", settlement_matches[0].get_string(1), settlement_matches[0].get_string())
	var explicit_dates := _matches("[0-9]{4}-[0-9]{2}-[0-9]{2}", source_text)
	var date_values := {}
	for found in explicit_dates:
		var is_settlement := false
		for settlement in settlement_matches:
			if found.get_start() >= settlement.get_start() and found.get_end() <= settlement.get_end():
				is_settlement = true
		if is_settlement:
			continue
		date_values[found.get_string()] = found.get_string()
	if not _matches("今天", source_text).is_empty():
		if _valid_date(reference_date):
			date_values[reference_date] = "今天"
			draft.assumptions.append("TODAY_RESOLVED_FROM_REFERENCE_DATE")
	if not _matches("昨天", source_text).is_empty():
		if _valid_date(reference_date):
			var yesterday := Time.get_date_string_from_unix_time(
					Time.get_unix_time_from_datetime_string(reference_date + "T00:00:00") - 86400)
			date_values[yesterday] = "昨天"
			draft.assumptions.append("YESTERDAY_RESOLVED_FROM_REFERENCE_DATE")
	if date_values.size() > 1:
		_add_unique(conflicts, "CONFLICTING_TRADE_DATE")
	elif date_values.size() == 1:
		var date: String = date_values.keys()[0]
		_put(fields, "trade_date", date, date_values[date])

	for field in REQUIRED_FIELDS:
		if not fields.has(field):
			_add_unique(draft.missing_fields, field)
	if not fields.has("total_amount") and not fields.has("unit_price"):
		_add_unique(draft.missing_fields, "unit_price_or_total_amount")
	if not fields.has("tax_amount"):
		_add_unique(draft.missing_fields, "tax_amount")
	return draft


static func revise(draft: Dictionary, changed_values: Dictionary) -> Dictionary:
	if not _shape_valid(draft) or draft.status != "pending" or changed_values.is_empty():
		return {"ok": false, "error": "INVALID_DRAFT_REVISION"}
	var next: Dictionary = draft.duplicate(true)
	var fields: Dictionary = next.fields
	for name in changed_values:
		if not FIELD_NAMES.has(name):
			return {"ok": false, "error": "UNKNOWN_DRAFT_FIELD"}
		if typeof(changed_values[name]) != TYPE_STRING:
			return {"ok": false, "error": "INVALID_DRAFT_FIELD"}
		var value: String = changed_values[name]
		if value.is_empty():
			fields.erase(name)
		else:
			fields[name] = {"value": value, "source_span": "", "confidence": 1.0, "origin": "user"}
	next.revision = int(next.revision) + 1
	next.missing_fields = []
	var retained_conflicts := []
	for conflict in next.conflicts:
		var resolved: bool = (conflict == "CONFLICTING_DIRECTION" and changed_values.has("direction")) \
			or (conflict == "AMBIGUOUS_ACCOUNT" and changed_values.has("account_id")) \
			or (conflict == "AMBIGUOUS_INSTRUMENT" and changed_values.has("instrument_id")) \
			or (conflict == "CONFLICTING_QUANTITY" and changed_values.has("quantity")) \
			or (conflict == "CONFLICTING_CURRENCY" and changed_values.has("currency")) \
			or (conflict == "CONFLICTING_TOTAL_AMOUNT" and changed_values.has("total_amount")) \
			or (conflict == "CONFLICTING_UNIT_PRICE" and changed_values.has("unit_price")) \
			or (conflict == "CONFLICTING_FEE" and changed_values.has("fee")) \
			or (conflict == "CONFLICTING_TAX" and changed_values.has("tax_amount")) \
			or (conflict == "CONFLICTING_TRADE_DATE" and changed_values.has("trade_date")) \
			or (conflict == "CONFLICTING_SETTLEMENT_DATE" and changed_values.has("settlement_date")) \
			or (conflict == "AMOUNT_DIRECTION_MISMATCH" and (changed_values.has("direction") or changed_values.has("total_amount")))
		if not resolved:
			retained_conflicts.append(conflict)
	next.conflicts = retained_conflicts
	return {"ok": true, "draft": next}


static func validate(draft: Dictionary, state: Dictionary, candidates: Dictionary,
		confirmed_tax: String = "", replay_command_id: String = "") -> Dictionary:
	if not _shape_valid(draft):
		return {"ok": false, "error": "INVALID_DRAFT_SCHEMA", "missing_fields": [],
			"conflicts": ["INVALID_DRAFT_SCHEMA"], "preview": {}}
	var fields: Dictionary = draft.fields
	var missing := []
	var conflicts: Array = draft.conflicts.duplicate()
	for name in fields:
		if not _field_valid(fields[name]):
			_add_unique(conflicts, "INVALID_FIELD:" + str(name))
	for name in REQUIRED_FIELDS:
		if _value(fields, name).is_empty():
			_add_unique(missing, name)
	if _value(fields, "unit_price").is_empty() and _value(fields, "total_amount").is_empty():
		_add_unique(missing, "unit_price_or_total_amount")
	var tax := _value(fields, "tax_amount")
	if confirmed_tax.is_empty() and tax.is_empty():
		_add_unique(missing, "tax_amount")
	elif not confirmed_tax.is_empty():
		if not tax.is_empty() and Decimal.canonical(tax) != Decimal.canonical(confirmed_tax):
			_add_unique(conflicts, "TAX_CONFIRMATION_MISMATCH")
		tax = confirmed_tax

	var direction := _value(fields, "direction")
	if not direction.is_empty() and not ["buy", "sell"].has(direction):
		_add_unique(conflicts, "INVALID_DIRECTION")
	var account_id := _value(fields, "account_id")
	var instrument_id := _value(fields, "instrument_id")
	var accounts: Dictionary = state.get("accounts", {})
	var instruments: Dictionary = state.get("instruments", {})
	if not account_id.is_empty():
		if not _candidate_has(candidates.get("accounts", []), account_id) or not accounts.has(account_id):
			_add_unique(conflicts, "UNKNOWN_OR_UNMATCHED_ACCOUNT")
		elif not _identity_source_valid(fields.get("account_id", {}), candidates.get("accounts", []), account_id, false):
			_add_unique(conflicts, "UNVERIFIED_ACCOUNT_IDENTITY")
	if not instrument_id.is_empty():
		if not _candidate_has(candidates.get("instruments", []), instrument_id) or not instruments.has(instrument_id):
			_add_unique(conflicts, "UNKNOWN_OR_UNMATCHED_INSTRUMENT")
		elif not _identity_source_valid(fields.get("instrument_id", {}), candidates.get("instruments", []), instrument_id, true):
			_add_unique(conflicts, "UNVERIFIED_INSTRUMENT_IDENTITY")
	if accounts.has(account_id):
		var offered_account := _candidate_by_id(candidates.get("accounts", []), account_id)
		if offered_account.has("currency") and str(offered_account.currency) != str(accounts[account_id].get("currency", "")):
			_add_unique(conflicts, "ACCOUNT_CANDIDATE_MISMATCH")
	if instruments.has(instrument_id):
		var offered_instrument := _candidate_by_id(candidates.get("instruments", []), instrument_id)
		for name in ["market", "symbol", "currency"]:
			if offered_instrument.has(name) and str(offered_instrument[name]) != str(instruments[instrument_id].get(name, "")):
				_add_unique(conflicts, "INSTRUMENT_CANDIDATE_MISMATCH")
	var currency := _value(fields, "currency")
	if not currency.is_empty() and (currency.length() != 3 or currency != currency.to_upper()):
		_add_unique(conflicts, "INVALID_CURRENCY")
	if accounts.has(account_id) and instruments.has(instrument_id):
		if str(accounts[account_id].get("currency", "")) != currency or str(instruments[instrument_id].get("currency", "")) != currency:
			_add_unique(conflicts, "CURRENCY_IDENTITY_MISMATCH")
	var trade_date := _value(fields, "trade_date")
	if not trade_date.is_empty() and not _valid_date(trade_date):
		_add_unique(conflicts, "INVALID_TRADE_DATE")
	var settlement_date := _value(fields, "settlement_date")
	if not settlement_date.is_empty():
		if not _valid_date(settlement_date) or (_valid_date(trade_date) and settlement_date < trade_date):
			_add_unique(conflicts, "INVALID_SETTLEMENT_DATE")
	for name in ["quantity", "total_amount", "unit_price"]:
		var value := _value(fields, name)
		if not value.is_empty() and (not Decimal.is_valid(value) or Decimal.compare(value, "0") <= 0):
			_add_unique(conflicts, "INVALID_" + name.to_upper())
	for name in ["fee", "tax_amount"]:
		var value := tax if name == "tax_amount" else _value(fields, name)
		if not value.is_empty() and (not Decimal.is_valid(value) or Decimal.compare(value, "0") < 0):
			_add_unique(conflicts, "INVALID_" + name.to_upper())
	if Decimal.is_valid(tax) and Decimal.compare(tax, "0") != 0:
		_add_unique(conflicts, "UNSUPPORTED_TAX_LEDGER")
	var basis := _value(fields, "amount_basis")
	if not _value(fields, "total_amount").is_empty() and not ["cash_flow", "gross_trade"].has(basis):
		_add_unique(conflicts, "AMOUNT_BASIS_REQUIRED")
	if not conflicts.is_empty() or not missing.is_empty():
		return {"ok": false, "missing_fields": missing, "conflicts": conflicts, "preview": {}}

	var quantity := Decimal.canonical(_value(fields, "quantity"))
	var fee := Decimal.canonical(_value(fields, "fee"))
	var total := Decimal.canonical(_value(fields, "total_amount"))
	var price := Decimal.canonical(_value(fields, "unit_price"))
	var gross := ""
	if not price.is_empty():
		gross = Decimal.multiply(quantity, price)
	elif basis == "gross_trade":
		gross = total
	elif direction == "buy":
		gross = Decimal.subtract(Decimal.subtract(total, fee), tax)
	else:
		gross = Decimal.add(Decimal.add(total, fee), tax)
	if not Decimal.is_valid(gross) or Decimal.compare(gross, "0") <= 0:
		_add_unique(conflicts, "INVALID_GROSS_AMOUNT")
	else:
		if price.is_empty():
			price = Decimal.divide(gross, quantity, 30)
			if Decimal.multiply(price, quantity) != gross:
				_add_unique(conflicts, "NON_EXACT_UNIT_PRICE")
		var expected_total := gross
		if basis == "cash_flow":
			expected_total = Decimal.add(Decimal.add(gross, fee), tax) if direction == "buy" else Decimal.subtract(Decimal.subtract(gross, fee), tax)
		if not total.is_empty() and Decimal.compare(expected_total, total) != 0:
			_add_unique(conflicts, "AMOUNT_EQUATION_MISMATCH")
		if total.is_empty():
			total = expected_total
		if basis == "gross_trade":
			total = Decimal.add(Decimal.add(gross, fee), tax) if direction == "buy" else Decimal.subtract(Decimal.subtract(gross, fee), tax)
	if Decimal.is_valid(total) and Decimal.compare(total, "0") <= 0:
		_add_unique(conflicts, "INVALID_CASH_FLOW")
	if not conflicts.is_empty():
		return {"ok": false, "missing_fields": missing, "conflicts": conflicts, "preview": {}}

	var effective_at := _local_date_to_utc(trade_date)
	var cash_delta := "-" + total if direction == "buy" else total
	var quantity_delta := quantity if direction == "buy" else "-" + quantity
	var current := Ledger.project(state)
	if not current.ok:
		_add_unique(conflicts, str(current.error))
	elif direction == "buy" and Decimal.compare(str(current.cash.get(account_id, "0")), total) < 0:
		_add_unique(conflicts, "INSUFFICIENT_CASH")
	elif direction == "sell":
		var held := str(current.positions.get(account_id + "|" + instrument_id, {}).get("quantity", "0"))
		if Decimal.compare(held, quantity) < 0:
			_add_unique(conflicts, "INSUFFICIENT_HOLDING")
	if _same_trade_exists(state, direction, account_id, instrument_id, quantity, price, fee, effective_at, replay_command_id):
		_add_unique(conflicts, "POSSIBLE_DUPLICATE_TRADE")
	var preview := {"direction": direction, "account_id": account_id, "instrument_id": instrument_id,
		"currency": currency, "quantity": quantity, "unit_price": price, "gross_amount": gross,
		"cash_total": total, "fee": fee, "tax_amount": tax, "cash_delta": cash_delta,
		"quantity_delta": quantity_delta, "trade_date": trade_date, "settlement_date": settlement_date,
		"effective_at": effective_at}
	if conflicts.is_empty():
		# LedgerCore checks cash and holdings at the trade's effective date. Its
		# returned state is discarded here; only confirm may persist the command.
		var dry_run_key := replay_command_id
		if dry_run_key.is_empty():
			dry_run_key = "draft-preview-" + str(draft.id).sha256_text()
			while state.get("command_fingerprints", {}).has(dry_run_key):
				dry_run_key += "-preview"
		var dry_run_command := {"command_id": dry_run_key, "type": direction,
			"account_id": account_id, "instrument_id": instrument_id,
			"quantity": quantity, "unit_price": price, "fee": fee,
			"effective_at": effective_at}
		if not settlement_date.is_empty():
			dry_run_command["settlement_date"] = settlement_date
		var dry_run: Dictionary = Ledger.apply(state, dry_run_command)
		if not dry_run.ok:
			_add_unique(conflicts, str(dry_run.error))
	return {"ok": conflicts.is_empty(), "missing_fields": missing, "conflicts": conflicts, "preview": preview}


static func confirm(state: Dictionary, draft: Dictionary, candidates: Dictionary,
		confirmation: Dictionary) -> Dictionary:
	if confirmation.get("confirmed", false) != true:
		return {"ok": false, "error": "EXPLICIT_CONFIRMATION_REQUIRED"}
	if not _shape_valid(draft) or confirmation.get("draft_id", "") != draft.id or int(confirmation.get("draft_revision", -1)) != int(draft.revision):
		return {"ok": false, "error": "STALE_OR_INVALID_DRAFT"}
	var key := str(confirmation.get("idempotency_key", ""))
	if key.is_empty() or key.contains("|"):
		return {"ok": false, "error": "IDEMPOTENCY_KEY_REQUIRED"}
	if draft.status == "confirmed" and draft.get("confirmed_command_id", "") != key:
		return {"ok": false, "error": "ALREADY_CONFIRMED"}
	if not confirmation.has("tax_amount") or typeof(confirmation.tax_amount) != TYPE_STRING:
		return {"ok": false, "error": "EXPLICIT_TAX_REVIEW_REQUIRED"}
	if draft.status == "confirmed" and draft.get("confirmed_tax_amount", "") != Decimal.canonical(str(confirmation.tax_amount)):
		return {"ok": false, "error": "ALREADY_CONFIRMED"}
	var checked := validate(draft, state, candidates, str(confirmation.tax_amount), key)
	if not checked.ok:
		return {"ok": false, "error": "DRAFT_VALIDATION_FAILED", "validation": checked}
	var preview: Dictionary = checked.preview
	var command := {"command_id": key, "type": preview.direction, "account_id": preview.account_id,
		"instrument_id": preview.instrument_id, "quantity": preview.quantity,
		"unit_price": preview.unit_price, "fee": preview.fee, "effective_at": preview.effective_at}
	if not str(preview.settlement_date).is_empty():
		command["settlement_date"] = preview.settlement_date
	var result := Ledger.apply(state, command)
	if not result.ok:
		return result
	var confirmed_draft: Dictionary = draft.duplicate(true)
	confirmed_draft.status = "confirmed"
	confirmed_draft.confirmed_command_id = key
	confirmed_draft.confirmed_tax_amount = Decimal.canonical(str(confirmation.tax_amount))
	confirmed_draft.fields.tax_amount = {"value": confirmed_draft.confirmed_tax_amount,
		"source_span": "", "confidence": 1.0, "origin": "user"}
	confirmed_draft.missing_fields.erase("tax_amount")
	return {"ok": true, "duplicate": result.duplicate, "state": result.state,
		"projection": result.projection, "preview": preview, "draft": confirmed_draft}


static func _parse_identity(fields: Dictionary, conflicts: Array, field: String,
		source_text: String, candidates: Variant, instrument: bool) -> void:
	if typeof(candidates) != TYPE_ARRAY:
		return
	var matched := {}
	for candidate in candidates:
		if typeof(candidate) != TYPE_DICTIONARY:
			continue
		var candidate_id := str(candidate.get("id", ""))
		if candidate_id.is_empty():
			continue
		var aliases: Array = candidate.get("aliases", []).duplicate() if typeof(candidate.get("aliases", [])) == TYPE_ARRAY else []
		if instrument and not str(candidate.get("symbol", "")).is_empty():
			aliases.append(str(candidate.symbol))
		for alias in aliases:
			if typeof(alias) != TYPE_STRING or alias.is_empty():
				continue
			if _contains_token(source_text, alias):
				matched[candidate_id] = alias
	if matched.size() > 1:
		_add_unique(conflicts, "AMBIGUOUS_INSTRUMENT" if instrument else "AMBIGUOUS_ACCOUNT")
	elif matched.size() == 1:
		var candidate_id: String = matched.keys()[0]
		_put(fields, field, candidate_id, matched[candidate_id])


static func _contains_token(source_text: String, alias: String) -> bool:
	var upper_text := source_text.to_upper()
	var upper_alias := alias.to_upper()
	var from := 0
	while true:
		var at := upper_text.find(upper_alias, from)
		if at < 0:
			return false
		var before_ok := at == 0 or not _ascii_identifier(upper_text.substr(at - 1, 1))
		var after_at := at + upper_alias.length()
		var after_ok := after_at == upper_text.length() or not _ascii_identifier(upper_text.substr(after_at, 1))
		if before_ok and after_ok:
			return true
		from = at + 1
	return false


static func _ascii_identifier(character: String) -> bool:
	return (character >= "A" and character <= "Z") or (character >= "0" and character <= "9") or character == "_"


static func _matches(pattern: String, source_text: String) -> Array:
	var regex := RegEx.new()
	if regex.compile(pattern) != OK:
		return []
	return regex.search_all(source_text)


static func _put(fields: Dictionary, name: String, value: String, source_span: String) -> void:
	fields[name] = {"value": value, "source_span": source_span, "confidence": 1.0, "origin": "local_rule"}


static func _value(fields: Dictionary, name: String) -> String:
	var entry: Variant = fields.get(name, {})
	return str(entry.get("value", "")) if typeof(entry) == TYPE_DICTIONARY else ""


static func _field_valid(entry: Variant) -> bool:
	if typeof(entry) != TYPE_DICTIONARY:
		return false
	if typeof(entry.get("value")) != TYPE_STRING or typeof(entry.get("source_span")) != TYPE_STRING:
		return false
	if typeof(entry.get("confidence")) not in [TYPE_FLOAT, TYPE_INT] or float(entry.confidence) < 0.0 or float(entry.confidence) > 1.0:
		return false
	return entry.get("origin", "") in ["local_rule", "user", "remote_ai"]


static func _shape_valid(draft: Dictionary) -> bool:
	for key in draft:
		if not DRAFT_KEYS.has(key):
			return false
	if typeof(draft.get("schema_version")) != TYPE_INT or draft.schema_version != 1 \
			or typeof(draft.get("revision")) != TYPE_INT or int(draft.revision) < 1:
		return false
	for name in ["id", "source_text_local_ref", "created_at"]:
		if typeof(draft.get(name)) != TYPE_STRING or str(draft[name]).is_empty():
			return false
	if typeof(draft.get("confidence")) not in [TYPE_FLOAT, TYPE_INT] \
			or float(draft.confidence) < 0.0 or float(draft.confidence) > 1.0:
		return false
	if typeof(draft.get("fields")) != TYPE_DICTIONARY:
		return false
	for name in draft.fields:
		if not FIELD_NAMES.has(name):
			return false
	for name in ["missing_fields", "conflicts", "assumptions"]:
		if typeof(draft.get(name)) != TYPE_ARRAY:
			return false
		for item in draft[name]:
			if typeof(item) != TYPE_STRING:
				return false
	if draft.get("status", "") not in ["pending", "confirmed"]:
		return false
	if draft.status == "confirmed" and (typeof(draft.get("confirmed_command_id")) != TYPE_STRING \
			or typeof(draft.get("confirmed_tax_amount")) != TYPE_STRING):
		return false
	return true


static func _candidate_has(candidates: Variant, candidate_id: String) -> bool:
	if typeof(candidates) != TYPE_ARRAY:
		return false
	for candidate in candidates:
		if typeof(candidate) == TYPE_DICTIONARY and str(candidate.get("id", "")) == candidate_id:
			return true
	return false


static func _candidate_by_id(candidates: Variant, candidate_id: String) -> Dictionary:
	if typeof(candidates) != TYPE_ARRAY:
		return {}
	for candidate in candidates:
		if typeof(candidate) == TYPE_DICTIONARY and str(candidate.get("id", "")) == candidate_id:
			return candidate
	return {}


static func _identity_source_valid(entry: Variant, candidates: Variant, candidate_id: String,
		instrument: bool) -> bool:
	if typeof(entry) != TYPE_DICTIONARY:
		return false
	if entry.get("origin", "") == "user":
		return true
	var span := str(entry.get("source_span", ""))
	if span.is_empty():
		return false
	var matched_ids := {}
	if typeof(candidates) != TYPE_ARRAY:
		return false
	for candidate in candidates:
		if typeof(candidate) != TYPE_DICTIONARY:
			continue
		var aliases: Array = candidate.get("aliases", []).duplicate() if typeof(candidate.get("aliases", [])) == TYPE_ARRAY else []
		if instrument and not str(candidate.get("symbol", "")).is_empty():
			aliases.append(str(candidate.symbol))
		for alias in aliases:
			if typeof(alias) == TYPE_STRING and alias.to_upper() == span.to_upper():
				matched_ids[str(candidate.get("id", ""))] = true
	return matched_ids.size() == 1 and matched_ids.has(candidate_id)


static func _currency_for(label: String) -> String:
	match label.to_upper():
		"美元", "USD": return "USD"
		"人民币", "元", "CNY": return "CNY"
		"港币", "HKD": return "HKD"
		"欧元", "EUR": return "EUR"
		"英镑", "GBP": return "GBP"
		"新币", "SGD": return "SGD"
	return ""


static func _valid_date(value: String) -> bool:
	if _matches("^[0-9]{4}-[0-9]{2}-[0-9]{2}$", value).is_empty():
		return false
	var parts := value.split("-")
	var year := int(parts[0])
	var month := int(parts[1])
	var day := int(parts[2])
	if year < 1 or month < 1 or month > 12:
		return false
	var days := [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
	if month == 2 and year % 4 == 0 and (year % 100 != 0 or year % 400 == 0):
		return day >= 1 and day <= 29
	return day >= 1 and day <= days[month - 1]


static func _local_date_to_utc(local_date: String) -> String:
	# Current local rule is explicitly scoped to the product default Asia/Shanghai timezone.
	var unix := Time.get_unix_time_from_datetime_string(local_date + "T00:00:00") - 8 * 3600
	return Time.get_datetime_string_from_unix_time(unix) + "Z"


static func _same_trade_exists(state: Dictionary, direction: String, account_id: String,
		instrument_id: String, quantity: String, price: String, fee: String,
		effective_at: String, replay_command_id: String) -> bool:
	for event in state.get("events", []):
		if event.get("type", "") == direction and event.get("id", "") != replay_command_id \
				and event.get("account_id", "") == account_id and event.get("instrument_id", "") == instrument_id \
				and event.get("quantity", "") == quantity and event.get("unit_price", "") == price \
				and event.get("fee", "") == fee and event.get("effective_at", "") == effective_at:
			return true
	return false


static func _add_unique(values: Array, value: String) -> void:
	if not values.has(value):
		values.append(value)
