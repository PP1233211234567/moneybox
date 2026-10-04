extends RefCounted
## Local tax evidence workpaper. No rates, credits, due dates or tax liabilities are
## inferred. A verified jurisdiction rule package and calculation engine are absent.

const Decimal = preload("res://scripts/data/decimal_text.gd")
const SCHEMA_VERSION := 1
const MAX_SAFE_REVISION := 9007199254740991
const ENTRY_FIELDS := ["id", "tax_year", "source_region", "income_category", "currency",
	"gross_income", "acquisition_cost", "requires_acquisition_cost",
	"foreign_tax_paid", "locked_fx", "evidence_refs", "rule_version", "source_ref"]


static func new_state(base_currency: String = "CNY") -> Dictionary:
	if not _currency(base_currency):
		return {}
	return {"schema_version": SCHEMA_VERSION, "revision": 0,
		"base_currency": base_currency, "residency_by_year": {}, "entries": {},
		"entry_versions": {}, "residency_versions": {}, "command_fingerprints": {},
		"audit": []}


static func apply(state: Dictionary, command: Dictionary) -> Dictionary:
	if not _valid_state(state):
		return _error("INVALID_TAX_STATE")
	var command_id: Variant = command.get("command_id", null)
	var expected: Variant = command.get("expected_revision", null)
	if typeof(command_id) != TYPE_STRING or not _opaque_id(command_id) or \
			not _safe_int(expected, 0, MAX_SAFE_REVISION):
		return _error("INVALID_COMMAND")
	var fingerprint := JSON.stringify(command)
	var existing: Dictionary = state.command_fingerprints
	if existing.has(command_id):
		if existing[command_id] != fingerprint:
			return _error("COMMAND_ID_CONFLICT")
		return {"ok": true, "duplicate": true, "state": state.duplicate(true),
			"revision": int(state.revision)}
	if int(expected) != int(state.revision):
		return _error("VERSION_CONFLICT")
	if int(state.revision) >= MAX_SAFE_REVISION:
		return _error("REVISION_LIMIT")
	var next := state.duplicate(true)
	var kind := str(command.get("type", ""))
	var target := ""
	match kind:
		"SET_RESIDENCY":
			var year_value: Variant = command.get("tax_year", null)
			var config_value: Variant = command.get("residency", null)
			if not _year(year_value) or typeof(config_value) != TYPE_DICTIONARY or \
					not _valid_residency(config_value):
				return _error("INVALID_RESIDENCY")
			target = str(year_value)
			if next.residency_by_year.has(target):
				var prior: Array = next.residency_versions.get(target, [])
				prior.append(next.residency_by_year[target].duplicate(true))
				next.residency_versions[target] = prior
			next.residency_by_year[target] = config_value.duplicate(true)
		"ADD_ENTRY":
			var normalized := _normalize_entry(command.get("entry", null),
				str(state.base_currency))
			if not normalized.ok:
				return normalized
			target = str(normalized.entry.id)
			if next.entries.has(target):
				return _error("ENTRY_ID_EXISTS")
			var entry: Dictionary = normalized.entry
			entry.entry_revision = 1
			entry.status = "active"
			next.entries[target] = entry
		"REVISE_ENTRY":
			var normalized := _normalize_entry(command.get("entry", null),
				str(state.base_currency))
			if not normalized.ok:
				return normalized
			target = str(normalized.entry.id)
			if not next.entries.has(target) or next.entries[target].status != "active":
				return _error("ACTIVE_ENTRY_NOT_FOUND")
			var old: Dictionary = next.entries[target]
			if not _safe_int(command.get("expected_entry_revision", null), 1, MAX_SAFE_REVISION) or \
					int(command.expected_entry_revision) != int(old.entry_revision):
				return _error("ENTRY_VERSION_CONFLICT")
			if int(old.entry_revision) >= MAX_SAFE_REVISION:
				return _error("ENTRY_REVISION_LIMIT")
			if int(normalized.entry.tax_year) != int(old.tax_year):
				return _error("ENTRY_YEAR_IMMUTABLE")
			var versions: Array = next.entry_versions.get(target, [])
			versions.append(old.duplicate(true))
			next.entry_versions[target] = versions
			var replacement: Dictionary = normalized.entry
			replacement.entry_revision = int(old.entry_revision) + 1
			replacement.status = "active"
			next.entries[target] = replacement
		"VOID_ENTRY":
			target = str(command.get("entry_id", ""))
			if not next.entries.has(target) or next.entries[target].status != "active":
				return _error("ACTIVE_ENTRY_NOT_FOUND")
			var old: Dictionary = next.entries[target]
			if not _safe_int(command.get("expected_entry_revision", null), 1, MAX_SAFE_REVISION) or \
					int(command.expected_entry_revision) != int(old.entry_revision):
				return _error("ENTRY_VERSION_CONFLICT")
			if int(old.entry_revision) >= MAX_SAFE_REVISION:
				return _error("ENTRY_REVISION_LIMIT")
			var versions: Array = next.entry_versions.get(target, [])
			versions.append(old.duplicate(true))
			next.entry_versions[target] = versions
			next.entries[target].entry_revision = int(old.entry_revision) + 1
			next.entries[target].status = "voided"
		_:
			return _error("UNKNOWN_TAX_COMMAND")
	next.revision = int(state.revision) + 1
	next.command_fingerprints[command_id] = fingerprint
	next.audit.append({"revision": next.revision, "command_id": command_id,
		"type": kind, "target_id": target})
	return {"ok": true, "duplicate": false, "state": next,
		"revision": next.revision}


static func build_workpaper(state: Dictionary, tax_year: int) -> Dictionary:
	if not _valid_state(state):
		return _error("INVALID_TAX_STATE")
	if not _year(tax_year):
		return _error("INVALID_TAX_YEAR")
	var year_key := str(tax_year)
	var annual_gaps: Array[String] = []
	var residency: Dictionary = state.residency_by_year.get(year_key, {}).duplicate(true)
	if residency.is_empty():
		annual_gaps.append("TAX_RESIDENCY_MISSING")
	elif str(residency.rule_version).is_empty():
		annual_gaps.append("RESIDENCY_RULE_VERSION_MISSING")
	var groups := {}
	var records: Array = []
	var evidence_gaps: Array = []
	var voided_ids: Array[String] = []
	var ids: Array = state.entries.keys()
	ids.sort()
	for id in ids:
		var entry: Dictionary = state.entries[id]
		if int(entry.tax_year) != tax_year:
			continue
		if entry.status == "voided":
			voided_ids.append(id)
			continue
		var entry_copy := entry.duplicate(true)
		var gaps: Array[String] = []
		if entry_copy.evidence_refs.is_empty():
			gaps.append("EVIDENCE_MISSING")
		if str(entry_copy.foreign_tax_paid).is_empty():
			gaps.append("FOREIGN_TAX_UNCONFIRMED")
		if entry_copy.requires_acquisition_cost and str(entry_copy.acquisition_cost).is_empty():
			gaps.append("ACQUISITION_COST_UNKNOWN")
		if entry_copy.locked_fx.is_empty():
			gaps.append("LOCKED_FX_MISSING")
		if str(entry_copy.rule_version).is_empty():
			gaps.append("RULE_VERSION_MISSING")
		if str(entry_copy.source_ref).is_empty():
			gaps.append("SOURCE_REF_MISSING")
		if not gaps.is_empty():
			evidence_gaps.append({"entry_id": id, "missing": gaps})
		entry_copy.evidence_gaps = gaps.duplicate()
		records.append(entry_copy)
		var key := str(entry.source_region) + "|" + str(entry.income_category) + "|" + \
			str(entry.currency)
		if not groups.has(key):
			groups[key] = {"source_region": entry.source_region,
				"income_category": entry.income_category, "currency": entry.currency,
				"base_currency": state.base_currency, "entry_ids": [], "rule_versions": [],
				"gross_income": "0", "foreign_tax_paid_known": "0",
				"foreign_tax_paid_complete": true, "acquisition_cost_known": "0",
				"acquisition_cost_complete": true, "gross_base_known": "0",
				"gross_base_complete": true, "evidence_gap_count": 0}
		var group: Dictionary = groups[key]
		group.entry_ids.append(id)
		if not str(entry.rule_version).is_empty() and not group.rule_versions.has(entry.rule_version):
			group.rule_versions.append(entry.rule_version)
		group.gross_income = Decimal.add(str(group.gross_income), str(entry.gross_income))
		if str(entry.foreign_tax_paid).is_empty():
			group.foreign_tax_paid_complete = false
		else:
			group.foreign_tax_paid_known = Decimal.add(str(group.foreign_tax_paid_known),
				str(entry.foreign_tax_paid))
		if str(entry.acquisition_cost).is_empty():
			if entry.requires_acquisition_cost:
				group.acquisition_cost_complete = false
		else:
			group.acquisition_cost_known = Decimal.add(str(group.acquisition_cost_known),
				str(entry.acquisition_cost))
		if entry.locked_fx.is_empty():
			group.gross_base_complete = false
		else:
			group.gross_base_known = Decimal.add(str(group.gross_base_known),
				Decimal.multiply(str(entry.gross_income), str(entry.locked_fx.rate_to_base)))
		if not gaps.is_empty():
			group.evidence_gap_count = int(group.evidence_gap_count) + 1
		groups[key] = group
	var ordered_groups: Array = []
	var keys: Array = groups.keys()
	keys.sort()
	for key in keys:
		var group: Dictionary = groups[key]
		group.rule_versions.sort()
		ordered_groups.append(group)
	return {"ok": true, "schema_version": SCHEMA_VERSION, "tax_year": tax_year,
		"base_currency": state.base_currency, "residency": residency,
		"revision": state.revision, "records": records, "record_count": records.size(),
		"voided_entry_ids": voided_ids, "groups": ordered_groups,
		"group_count": ordered_groups.size(), "annual_gaps": annual_gaps,
		"evidence_gaps": evidence_gaps, "calculation_status": "NO_VALID_RULES",
		"calculation": {"status": "NO_VALID_RULES"}}


static func _normalize_entry(raw: Variant, base_currency: String) -> Dictionary:
	if typeof(raw) != TYPE_DICTIONARY:
		return _error("INVALID_TAX_ENTRY")
	for field in ENTRY_FIELDS:
		if not raw.has(field):
			return _error("TAX_ENTRY_FIELD_MISSING")
	for field in raw:
		if not ENTRY_FIELDS.has(field):
			return _error("INVALID_TAX_ENTRY")
	if typeof(raw.id) != TYPE_STRING or not _opaque_id(raw.id) or not _year(raw.tax_year) or \
			typeof(raw.source_region) != TYPE_STRING or not _label(raw.source_region) or \
			typeof(raw.income_category) != TYPE_STRING or not _label(raw.income_category) or \
			typeof(raw.currency) != TYPE_STRING or not _currency(raw.currency) or \
			typeof(raw.gross_income) != TYPE_STRING or not Decimal.is_valid(raw.gross_income) or \
			typeof(raw.acquisition_cost) != TYPE_STRING or \
			(not raw.acquisition_cost.is_empty() and not _nonnegative(raw.acquisition_cost)) or \
			typeof(raw.requires_acquisition_cost) != TYPE_BOOL or \
			typeof(raw.foreign_tax_paid) != TYPE_STRING or \
			(not raw.foreign_tax_paid.is_empty() and not _nonnegative(raw.foreign_tax_paid)) or \
			typeof(raw.locked_fx) != TYPE_DICTIONARY or \
			typeof(raw.evidence_refs) != TYPE_ARRAY or \
			typeof(raw.rule_version) != TYPE_STRING or raw.rule_version.length() > 128 or \
			typeof(raw.source_ref) != TYPE_STRING or \
			(not raw.source_ref.is_empty() and not _opaque_id(raw.source_ref)):
		return _error("INVALID_TAX_ENTRY")
	var refs := {}
	for reference in raw.evidence_refs:
		if typeof(reference) != TYPE_STRING or not _opaque_id(reference) or refs.has(reference):
			return _error("INVALID_EVIDENCE_REFS")
		refs[reference] = true
	if not raw.locked_fx.is_empty() and not _valid_fx(raw.locked_fx, raw.currency, base_currency):
		return _error("INVALID_LOCKED_FX")
	var entry: Dictionary = raw.duplicate(true)
	for field in ["gross_income", "acquisition_cost", "foreign_tax_paid"]:
		if not str(entry[field]).is_empty():
			entry[field] = Decimal.canonical(str(entry[field]))
	if not entry.locked_fx.is_empty():
		entry.locked_fx.rate_to_base = Decimal.canonical(str(entry.locked_fx.rate_to_base))
	return {"ok": true, "entry": entry}


static func _valid_fx(fx: Dictionary, source_currency: String, base_currency: String) -> bool:
	for field in ["rate_to_base", "base_currency", "quoted_at", "source"]:
		if typeof(fx.get(field, null)) != TYPE_STRING:
			return false
	for field in fx:
		if field not in ["rate_to_base", "base_currency", "quoted_at", "source"]:
			return false
	if fx.base_currency != base_currency or not _positive(fx.rate_to_base) or \
			not _valid_utc(fx.quoted_at) or fx.source.is_empty() or fx.source.length() > 128:
		return false
	return source_currency != base_currency or Decimal.compare(fx.rate_to_base, "1") == 0


static func _valid_state(state: Dictionary) -> bool:
	if not _safe_int(state.get("schema_version", null), SCHEMA_VERSION, SCHEMA_VERSION) or \
			int(state.schema_version) != SCHEMA_VERSION or \
			not _safe_int(state.get("revision", null), 0, MAX_SAFE_REVISION) or \
			typeof(state.get("base_currency", null)) != TYPE_STRING or \
			not _currency(state.base_currency):
		return false
	for field in ["residency_by_year", "entries", "entry_versions", "residency_versions",
			"command_fingerprints"]:
		if typeof(state.get(field, null)) != TYPE_DICTIONARY:
			return false
	if typeof(state.get("audit", null)) != TYPE_ARRAY or \
			state.audit.size() != int(state.revision) or \
			state.command_fingerprints.size() != int(state.revision):
		return false
	for year_key in state.residency_by_year:
		if not _year_string(str(year_key)) or \
				typeof(state.residency_by_year[year_key]) != TYPE_DICTIONARY or \
				not _valid_residency(state.residency_by_year[year_key]):
			return false
	for id in state.entries:
		var entry_value: Variant = state.entries[id]
		if not _valid_stored_entry(entry_value, str(id), str(state.base_currency)) or \
				int(entry_value.entry_revision) > int(state.revision):
			return false
		var versions_value: Variant = state.entry_versions.get(id, [])
		if typeof(versions_value) != TYPE_ARRAY or \
				versions_value.size() + 1 != int(entry_value.entry_revision):
			return false
		for index in versions_value.size():
			var prior: Variant = versions_value[index]
			if not _valid_stored_entry(prior, str(id), str(state.base_currency)) or \
					int(prior.entry_revision) != index + 1 or prior.status != "active" or \
					int(prior.tax_year) != int(entry_value.tax_year):
				return false
	for id in state.entry_versions:
		if not state.entries.has(id):
			return false
	for year_key in state.residency_versions:
		if not state.residency_by_year.has(year_key) or \
				typeof(state.residency_versions[year_key]) != TYPE_ARRAY:
			return false
		for prior in state.residency_versions[year_key]:
			if typeof(prior) != TYPE_DICTIONARY or not _valid_residency(prior):
				return false
	for id in state.command_fingerprints:
		if typeof(id) != TYPE_STRING or not _opaque_id(str(id)) or \
				typeof(state.command_fingerprints[id]) != TYPE_STRING:
			return false
	for index in state.audit.size():
		var audit_row: Variant = state.audit[index]
		if typeof(audit_row) != TYPE_DICTIONARY or \
				not _safe_int(audit_row.get("revision", null), index + 1, index + 1) or \
				str(audit_row.get("type", "")) not in ["SET_RESIDENCY", "ADD_ENTRY", "REVISE_ENTRY", "VOID_ENTRY"] or \
				not state.command_fingerprints.has(audit_row.get("command_id", null)) or \
				not _opaque_id(str(audit_row.get("target_id", ""))):
			return false
	return true


static func _valid_stored_entry(value: Variant, id: String, base_currency: String) -> bool:
	if typeof(value) != TYPE_DICTIONARY or str(value.get("id", "")) != id or \
			value.get("status", "") not in ["active", "voided"] or \
			not _safe_int(value.get("entry_revision", null), 1, MAX_SAFE_REVISION):
		return false
	var input: Dictionary = value.duplicate(true)
	input.erase("status")
	input.erase("entry_revision")
	return _normalize_entry(input, base_currency).ok


static func _valid_residency(value: Dictionary) -> bool:
	if typeof(value.get("jurisdiction", null)) != TYPE_STRING or \
			not _label(value.jurisdiction) or \
			typeof(value.get("status", null)) != TYPE_STRING or \
			value.status not in ["resident", "nonresident", "dual", "undetermined"] or \
			typeof(value.get("rule_version", null)) != TYPE_STRING or \
			str(value.rule_version).length() > 128:
		return false
	for key in value:
		if key not in ["jurisdiction", "status", "rule_version"]:
			return false
	return true


static func _year(value: Variant) -> bool:
	return _safe_int(value, 1, 9999)


static func _safe_int(value: Variant, minimum: int, maximum: int) -> bool:
	if typeof(value) not in [TYPE_INT, TYPE_FLOAT]:
		return false
	var numeric := float(value)
	return not is_nan(numeric) and numeric >= float(minimum) and \
		numeric <= float(maximum) and numeric == floor(numeric)


static func _year_string(value: String) -> bool:
	if value.is_empty() or str(int(value)) != value:
		return false
	return _year(int(value))


static func _label(value: String) -> bool:
	return not value.is_empty() and value.length() <= 64 and not value.contains("|")


static func _opaque_id(value: String) -> bool:
	if value.is_empty() or value.length() > 128:
		return false
	for index in value.length():
		var character := value.substr(index, 1)
		if not ((character >= "A" and character <= "Z") or \
				(character >= "a" and character <= "z") or \
				(character >= "0" and character <= "9") or \
				character in ["_", "-", ".", ":"]):
			return false
	return true


static func _currency(value: String) -> bool:
	if value.length() != 3:
		return false
	for index in 3:
		var character := value.substr(index, 1)
		if character < "A" or character > "Z":
			return false
	return true


static func _positive(value: String) -> bool:
	return Decimal.is_valid(value) and Decimal.compare(value, "0") > 0


static func _nonnegative(value: String) -> bool:
	return Decimal.is_valid(value) and Decimal.compare(value, "0") >= 0


static func _valid_utc(value: String) -> bool:
	if value.length() != 20 or value.substr(4, 1) != "-" or value.substr(7, 1) != "-" or \
			value.substr(10, 1) != "T" or value.substr(13, 1) != ":" or \
			value.substr(16, 1) != ":" or value.substr(19, 1) != "Z":
		return false
	for index in [0, 1, 2, 3, 5, 6, 8, 9, 11, 12, 14, 15, 17, 18]:
		var digit := value.substr(index, 1)
		if digit < "0" or digit > "9":
			return false
	var year := int(value.substr(0, 4))
	var month := int(value.substr(5, 2))
	var day := int(value.substr(8, 2))
	if year < 1 or month < 1 or month > 12 or int(value.substr(11, 2)) > 23 or \
			int(value.substr(14, 2)) > 59 or int(value.substr(17, 2)) > 59:
		return false
	var days := [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
	if month == 2 and (year % 400 == 0 or (year % 4 == 0 and year % 100 != 0)):
		days[1] = 29
	return day >= 1 and day <= days[month - 1]


static func _error(code: String) -> Dictionary:
	return {"ok": false, "error": code}
