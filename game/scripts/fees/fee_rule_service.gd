extends RefCounted
## Versioned, local fee-rule inputs. No broker rates are bundled or fetched here.
## A computed estimate is a preview; an actual bill remains distinct and authoritative.

const Decimal = preload("res://scripts/data/decimal_text.gd")
const SOURCE_KINDS := ["OFFICIAL_DOCUMENT", "USER_SUPPLIED", "TEST_ONLY"]
const DIRECTIONS := ["BUY", "SELL", "SUBSCRIBE", "REDEEM"]


static func new_state() -> Dictionary:
	return {"schema_version": 1, "revision": 0, "rule_sets": {}, "records": {},
		"command_fingerprints": {}, "command_results": {}}


static func register_rule_set(state: Dictionary, rule_set: Dictionary,
		command_id: String, expected_revision: int) -> Dictionary:
	var fingerprint := JSON.stringify(["REGISTER_RULE_SET", rule_set]).sha256_text()
	var replay := _replay(state, command_id, fingerprint)
	if replay.has("ok"):
		return replay
	if not _valid_state(state) or not _valid_id(command_id) or not _valid_rule_set(rule_set):
		return _error("INVALID_RULE_SET")
	if int(state.revision) != expected_revision:
		return _error("REVISION_CONFLICT")
	var id := str(rule_set.id)
	if state.rule_sets.has(id):
		return _error("RULE_SET_ID_CONFLICT")
	var next := state.duplicate(true)
	next.revision = int(state.revision) + 1
	next.rule_sets[id] = rule_set.duplicate(true)
	var result := {"ok": true, "duplicate": false, "state": next,
		"rule_set": rule_set.duplicate(true)}
	_record_command(next, command_id, fingerprint, {"rule_set": result.rule_set})
	return result


static func evaluate(state: Dictionary, context: Dictionary) -> Dictionary:
	if not _valid_state(state) or not _valid_context(context):
		return _error("INVALID_FEE_CONTEXT")
	var candidates: Array = []
	for rule_set in state.rule_sets.values():
		for rule in rule_set.rules:
			if _matches(rule, context):
				candidates.append({"rule_set": rule_set, "rule": rule,
					"priority": int(rule.priority), "specificity": _specificity(rule)})
	if candidates.is_empty():
		# Missing fee information is unknown, never a fabricated zero.
		return {"ok": true, "status": "MANUAL_REQUIRED",
			"reason": "NO_MATCHING_RULE"}
	var highest_priority := -1
	var highest_specificity := -1
	var selected := {}
	var tied := false
	for candidate in candidates:
		if candidate.priority > highest_priority or \
				(candidate.priority == highest_priority and candidate.specificity > highest_specificity):
			highest_priority = candidate.priority
			highest_specificity = candidate.specificity
			selected = candidate
			tied = false
		elif candidate.priority == highest_priority and candidate.specificity == highest_specificity:
			tied = true
	if tied:
		return _error("AMBIGUOUS_FEE_RULES")
	var rule: Dictionary = selected.rule
	var formula: Dictionary = rule.formula
	var raw := Decimal.add(Decimal.multiply(str(context.gross_amount), str(formula.rate)),
		str(formula.fixed))
	if Decimal.compare(raw, str(formula.minimum)) < 0:
		raw = str(formula.minimum)
	if not str(formula.maximum).is_empty() and Decimal.compare(raw, str(formula.maximum)) > 0:
		raw = str(formula.maximum)
	var fee := Decimal.canonical(Decimal.fixed(raw, int(formula.rounding_scale)))
	var rule_set: Dictionary = selected.rule_set
	return {"ok": true, "status": "ESTIMATED", "estimated_fee": fee,
		"currency": str(context.currency), "rule_id": str(rule.id),
		"rule_set_id": str(rule_set.id), "rule_set_version": str(rule_set.version),
		"source_kind": str(rule_set.source_kind), "source_ref": str(rule_set.source_ref),
		"verified_at": str(rule_set.verified_at), "rounding_mode": "HALF_EVEN"}


static func create_estimate(state: Dictionary, context: Dictionary,
		command_id: String, expected_revision: int) -> Dictionary:
	var fingerprint := JSON.stringify(["CREATE_ESTIMATE", context]).sha256_text()
	var replay := _replay(state, command_id, fingerprint)
	if replay.has("ok"):
		return replay
	if not _valid_state(state) or not _valid_id(command_id) or not _valid_context(context):
		return _error("INVALID_FEE_CONTEXT")
	if int(state.revision) != expected_revision:
		return _error("REVISION_CONFLICT")
	var trade_id := str(context.trade_id)
	if state.records.has(trade_id):
		return _error("TRADE_FEE_RECORD_EXISTS")
	var estimate := evaluate(state, context)
	if not estimate.ok:
		return estimate
	var record := {"trade_id": trade_id, "record_version": 1,
		"status": estimate.status, "context": context.duplicate(true),
		"currency": str(context.currency)}
	if estimate.status == "ESTIMATED":
		for key in ["estimated_fee", "rule_id", "rule_set_id", "rule_set_version",
				"source_kind", "source_ref", "verified_at", "rounding_mode"]:
			record[key] = estimate[key]
	else:
		record.reason = estimate.reason
	var next := state.duplicate(true)
	next.revision = int(state.revision) + 1
	next.records[trade_id] = record.duplicate(true)
	_record_command(next, command_id, fingerprint, {"record": record})
	return {"ok": true, "duplicate": false, "state": next, "record": record}


static func record_actual_bill(state: Dictionary, trade_id: String, actual_fee: Variant,
		bill_ref: String, command_id: String, expected_revision: int,
		expected_record_version: int) -> Dictionary:
	# actual_fee is in the trade context currency. Cross-currency bills need a separate
	# evidenced FX conversion before this command; this service never assumes a rate.
	var fingerprint := JSON.stringify(["RECORD_ACTUAL_BILL", trade_id, actual_fee,
		bill_ref, expected_record_version]).sha256_text()
	var replay := _replay(state, command_id, fingerprint)
	if replay.has("ok"):
		return replay
	if not _valid_state(state) or not _valid_id(command_id) or \
			not _valid_id(trade_id) or bill_ref.strip_edges().is_empty() or \
			typeof(actual_fee) != TYPE_STRING or not _nonnegative(actual_fee):
		return _error("INVALID_ACTUAL_BILL")
	if int(state.revision) != expected_revision:
		return _error("REVISION_CONFLICT")
	var old_raw = state.records.get(trade_id, null)
	if typeof(old_raw) != TYPE_DICTIONARY:
		return _error("FEE_RECORD_NOT_FOUND")
	var old: Dictionary = old_raw
	if int(old.record_version) != expected_record_version:
		return _error("RECORD_VERSION_CONFLICT")
	if old.status == "ACTUAL":
		return _error("ACTUAL_BILL_ALREADY_RECORDED")
	var revised := old.duplicate(true)
	revised.record_version = int(old.record_version) + 1
	revised.status = "ACTUAL"
	revised.actual_fee = Decimal.canonical(actual_fee)
	revised.bill_ref = bill_ref.strip_edges()
	revised.actual_source = "USER_CONFIRMED_BILL"
	if revised.has("estimated_fee"):
		revised.fee_difference = Decimal.subtract(revised.actual_fee,
			str(revised.estimated_fee))
		revised.difference_known = true
	else:
		revised.difference_known = false
	var next := state.duplicate(true)
	next.revision = int(state.revision) + 1
	next.records[trade_id] = revised.duplicate(true)
	_record_command(next, command_id, fingerprint, {"record": revised})
	return {"ok": true, "duplicate": false, "state": next, "record": revised}


static func _matches(rule: Dictionary, context: Dictionary) -> bool:
	if rule.plan_id != context.plan_id or rule.currency != context.currency \
			or str(context.trade_date) < str(rule.effective_from):
		return false
	if not str(rule.effective_to).is_empty() and str(context.trade_date) > str(rule.effective_to):
		return false
	for key in ["channel", "market", "product", "direction"]:
		if rule[key] != "*" and rule[key] != context[key]:
			return false
	return true


static func _specificity(rule: Dictionary) -> int:
	var count := 0
	for key in ["channel", "market", "product", "direction"]:
		if rule[key] != "*":
			count += 1
	return count


static func _valid_state(state: Dictionary) -> bool:
	if not (int(state.get("schema_version", -1)) == 1 \
		and typeof(state.get("rule_sets", null)) == TYPE_DICTIONARY \
		and typeof(state.get("records", null)) == TYPE_DICTIONARY \
		and typeof(state.get("command_fingerprints", null)) == TYPE_DICTIONARY \
		and typeof(state.get("command_results", null)) == TYPE_DICTIONARY \
		and int(state.get("revision", -1)) >= 0):
		return false
	for key in state.rule_sets:
		var value = state.rule_sets[key]
		if typeof(value) != TYPE_DICTIONARY or str(value.get("id", "")) != str(key) \
				or not _valid_rule_set(value):
			return false
	return true


static func _valid_rule_set(rule_set: Dictionary) -> bool:
	if not _valid_id(str(rule_set.get("id", ""))) or \
			str(rule_set.get("version", "")).is_empty() or \
			not SOURCE_KINDS.has(str(rule_set.get("source_kind", ""))) or \
			str(rule_set.get("source_ref", "")).strip_edges().is_empty() or \
			not _valid_date(str(rule_set.get("verified_at", ""))) or \
			typeof(rule_set.get("rules", null)) != TYPE_ARRAY or rule_set.rules.is_empty():
		return false
	var ids := {}
	for raw in rule_set.rules:
		if typeof(raw) != TYPE_DICTIONARY or not _valid_rule(raw):
			return false
		var id := str(raw.id)
		if ids.has(id):
			return false
		ids[id] = true
	return true


static func _valid_rule(rule: Dictionary) -> bool:
	if not _valid_id(str(rule.get("id", ""))) or \
			not _valid_id(str(rule.get("plan_id", ""))) or \
			not _match_token(str(rule.get("channel", ""))) or \
			not _match_token(str(rule.get("market", ""))) or \
			not _match_token(str(rule.get("product", ""))) or \
			not (str(rule.get("direction", "")) == "*" or \
				DIRECTIONS.has(str(rule.get("direction", "")))) or \
			not _currency(str(rule.get("currency", ""))) or \
			not _valid_date(str(rule.get("effective_from", ""))):
		return false
	var effective_to := str(rule.get("effective_to", ""))
	if not effective_to.is_empty() and (not _valid_date(effective_to) or \
			effective_to < str(rule.effective_from)):
		return false
	if not _small_integer_text(rule.get("priority", null), 0, 1000):
		return false
	var formula_raw = rule.get("formula", null)
	if typeof(formula_raw) != TYPE_DICTIONARY:
		return false
	var formula: Dictionary = formula_raw
	if str(formula.get("rounding_mode", "")) != "HALF_EVEN" or \
			not _small_integer_text(formula.get("rounding_scale", null), 0, 8):
		return false
	for key in ["rate", "fixed", "minimum"]:
		var value = formula.get(key, null)
		if typeof(value) != TYPE_STRING or not _nonnegative(value):
			return false
	var maximum = formula.get("maximum", null)
	if typeof(maximum) != TYPE_STRING or \
			(not maximum.is_empty() and (not _nonnegative(maximum) or \
			Decimal.compare(maximum, str(formula.minimum)) < 0)):
		return false
	var scale := int(formula.rounding_scale)
	if Decimal.canonical(Decimal.fixed(str(formula.minimum), scale)) != \
			Decimal.canonical(str(formula.minimum)):
		return false
	if not maximum.is_empty() and \
			Decimal.canonical(Decimal.fixed(maximum, scale)) != Decimal.canonical(maximum):
		return false
	return true


static func _valid_context(context: Dictionary) -> bool:
	if not _valid_id(str(context.get("trade_id", ""))) or \
			not _valid_id(str(context.get("plan_id", ""))) or \
			not _match_token(str(context.get("channel", "")), false) or \
			not _match_token(str(context.get("market", "")), false) or \
			not _match_token(str(context.get("product", "")), false) or \
			not DIRECTIONS.has(str(context.get("direction", ""))) or \
			not _valid_date(str(context.get("trade_date", ""))) or \
			not _currency(str(context.get("currency", ""))):
		return false
	var amount = context.get("gross_amount", null)
	return typeof(amount) == TYPE_STRING and _positive(amount)


static func _valid_date(value: String) -> bool:
	if value.length() != 10 or value.substr(4, 1) != "-" or value.substr(7, 1) != "-":
		return false
	for index in [0, 1, 2, 3, 5, 6, 8, 9]:
		var character := value.substr(index, 1)
		if character < "0" or character > "9":
			return false
	var year := value.substr(0, 4).to_int()
	var month := value.substr(5, 2).to_int()
	var day := value.substr(8, 2).to_int()
	if year < 1970 or month < 1 or month > 12:
		return false
	var days := [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
	if month == 2 and (year % 400 == 0 or (year % 4 == 0 and year % 100 != 0)):
		days[1] = 29
	return day >= 1 and day <= days[month - 1]


static func _small_integer_text(value: Variant, minimum: int, maximum: int) -> bool:
	if typeof(value) != TYPE_STRING:
		return false
	var value_text: String = value
	if value_text.is_empty() or value_text.length() > 4:
		return false
	for index in value_text.length():
		var character := value_text.substr(index, 1)
		if character < "0" or character > "9":
			return false
	if value_text.length() > 1 and value_text.begins_with("0"):
		return false
	return value_text.to_int() >= minimum and value_text.to_int() <= maximum


static func _match_token(value: String, allow_wildcard: bool = true) -> bool:
	if value == "*":
		return allow_wildcard
	return _valid_id(value) and value == value.to_upper()


static func _valid_id(value: String) -> bool:
	if value.is_empty() or value.length() > 128:
		return false
	for index in value.length():
		var character := value.substr(index, 1)
		if (character >= "A" and character <= "Z") or \
				(character >= "a" and character <= "z") or \
				(character >= "0" and character <= "9") or \
				"._:/-".contains(character):
			continue
		return false
	return true


static func _currency(value: String) -> bool:
	if value.length() != 3:
		return false
	for index in value.length():
		var character := value.substr(index, 1)
		if character < "A" or character > "Z":
			return false
	return true


static func _nonnegative(value: String) -> bool:
	return Decimal.is_valid(value) and Decimal.compare(value, "0") >= 0


static func _positive(value: String) -> bool:
	return Decimal.is_valid(value) and Decimal.compare(value, "0") > 0


static func _replay(state: Dictionary, command_id: String, fingerprint: String) -> Dictionary:
	if not _valid_state(state) or not _valid_id(command_id):
		return _error("INVALID_FEE_STATE_OR_COMMAND")
	if not state.command_fingerprints.has(command_id):
		return {}
	if state.command_fingerprints[command_id] != fingerprint:
		return _error("IDEMPOTENCY_KEY_CONFLICT")
	var saved_raw = state.command_results.get(command_id, null)
	if typeof(saved_raw) != TYPE_DICTIONARY:
		return _error("INVALID_FEE_STATE_OR_COMMAND")
	var saved: Dictionary = saved_raw
	var result := {"ok": true, "duplicate": true, "state": state}
	for key in saved:
		if typeof(saved[key]) != TYPE_DICTIONARY:
			return _error("INVALID_FEE_STATE_OR_COMMAND")
		result[key] = saved[key].duplicate(true)
	return result


static func _record_command(state: Dictionary, command_id: String, fingerprint: String,
		result: Dictionary) -> void:
	state.command_fingerprints[command_id] = fingerprint
	state.command_results[command_id] = result.duplicate(true)


static func _error(code: String) -> Dictionary:
	return {"ok": false, "error": code}
