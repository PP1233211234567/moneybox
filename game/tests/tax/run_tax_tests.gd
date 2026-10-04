extends SceneTree

const Tax = preload("res://scripts/tax/tax_workpaper_service.gd")

var failures: Array[String] = []
var checks := 0


func _initialize() -> void:
	_test_workpaper_without_rules()
	_test_commands_and_history()
	_test_invalid_inputs_and_json_roundtrip()
	if failures.is_empty():
		print("TAX TESTS PASS: %d checks" % checks)
		quit(0)
	else:
		for failure in failures:
			printerr("FAIL: " + failure)
		printerr("TAX TESTS FAIL: %d failures in %d checks" % [failures.size(), checks])
		quit(1)


func _check(condition: bool, label: String) -> void:
	checks += 1
	if not condition:
		failures.append(label)


func _gap_for(gaps: Array, id: String) -> Dictionary:
	for gap in gaps:
		if gap.entry_id == id:
			return gap
	return {}


func _entry(id: String = "synthetic-income-1") -> Dictionary:
	return {"id": id, "tax_year": 2026, "source_region": "US",
		"income_category": "DIVIDEND", "currency": "USD", "gross_income": "100.25",
		"acquisition_cost": "", "requires_acquisition_cost": false,
		"foreign_tax_paid": "10.02",
		"locked_fx": {"base_currency": "CNY", "rate_to_base": "7.1234",
			"quoted_at": "2026-02-01T00:00:00Z", "source": "synthetic-test"},
		"evidence_refs": ["receipt-1"], "rule_version": "", "source_ref": "ledger-event-1"}


func _apply(state: Dictionary, id: String, type: String, payload: Dictionary) -> Dictionary:
	var command := {"command_id": id, "expected_revision": state.revision, "type": type}
	command.merge(payload)
	var result := Tax.apply(state, command)
	if not result.ok:
		failures.append("fixture " + id + ": " + str(result.error))
		return state
	return result.state


func _test_workpaper_without_rules() -> void:
	var state := Tax.new_state()
	state = _apply(state, "residency-2026", "SET_RESIDENCY", {"tax_year": 2026,
		"residency": {"jurisdiction": "CN", "status": "resident", "rule_version": ""}})
	state = _apply(state, "add-income-1", "ADD_ENTRY", {"entry": _entry()})
	var second := _entry("synthetic-income-2")
	second.gross_income = "0.75"
	second.foreign_tax_paid = ""
	second.locked_fx = {}
	second.evidence_refs = []
	second.source_ref = ""
	state = _apply(state, "add-income-2", "ADD_ENTRY", {"entry": second})
	var gain := _entry("synthetic-gain-1")
	gain.source_region = "HK"
	gain.income_category = "CAPITAL_GAIN"
	gain.currency = "HKD"
	gain.gross_income = "20"
	gain.acquisition_cost = ""
	gain.requires_acquisition_cost = true
	gain.foreign_tax_paid = "0"
	gain.locked_fx.rate_to_base = "0.9"
	gain.evidence_refs = []
	state = _apply(state, "add-gain", "ADD_ENTRY", {"entry": gain})
	var before := JSON.stringify(state)
	var paper := Tax.build_workpaper(state, 2026)
	_check(paper.ok and paper.calculation_status == "NO_VALID_RULES" and
		paper.calculation == {"status": "NO_VALID_RULES"},
		"L10 no verified rules yields only NO_VALID_RULES")
	_check(not paper.has("tax_due") and not paper.has("credit") and
		not paper.calculation.has("tax_due") and not paper.calculation.has("credit"),
		"L10 never fabricates tax liability or foreign tax credit")
	_check(paper.record_count == 3 and paper.group_count == 2 and
		paper.residency.jurisdiction == "CN", "L10 annual residency and grouped source records")
	_check(paper.annual_gaps.has("RESIDENCY_RULE_VERSION_MISSING"),
		"L10 missing residency rule version remains visible")
	var usd_group: Dictionary = paper.groups[1]
	_check(usd_group.source_region == "US" and usd_group.income_category == "DIVIDEND"
		and usd_group.currency == "USD" and usd_group.entry_ids.size() == 2,
		"L10 US dividend USD group traces both source records")
	_check(usd_group.gross_income == "101" and usd_group.foreign_tax_paid_known == "10.02"
		and not usd_group.foreign_tax_paid_complete,
		"L10 decimal group totals keep unknown foreign tax separate from known amount")
	_check(usd_group.gross_base_known == "714.12085" and not usd_group.gross_base_complete,
		"L10 locked FX conversion is exact and missing FX blocks complete base total")
	var income_gap := _gap_for(paper.evidence_gaps, "synthetic-income-2")
	var gain_gap := _gap_for(paper.evidence_gaps, "synthetic-gain-1")
	_check(paper.evidence_gaps.size() == 3 and not income_gap.is_empty() and
		income_gap.missing.has("FOREIGN_TAX_UNCONFIRMED") and
		income_gap.missing.has("LOCKED_FX_MISSING") and not gain_gap.is_empty() and
		gain_gap.missing.has("ACQUISITION_COST_UNKNOWN"),
		"L10 evidence, tax-paid, FX and acquisition cost gaps stay explicit")
	_check(JSON.stringify(state) == before, "L10 report does not mutate stored evidence")
	var empty_year := Tax.build_workpaper(state, 2025)
	_check(empty_year.ok and empty_year.record_count == 0 and
		empty_year.annual_gaps.has("TAX_RESIDENCY_MISSING") and
		empty_year.calculation_status == "NO_VALID_RULES",
		"L10 missing year configuration still produces an empty workpaper")


func _test_commands_and_history() -> void:
	var state := Tax.new_state()
	var residency_command := {"command_id": "resident", "expected_revision": 0,
		"type": "SET_RESIDENCY", "tax_year": 2026,
		"residency": {"jurisdiction": "CN", "status": "resident", "rule_version": ""}}
	var first := Tax.apply(state, residency_command)
	_check(first.ok and not first.duplicate and state.revision == 0 and first.state.revision == 1,
		"L10 command applies to copy and increments revision")
	if not first.ok:
		return
	var replay := Tax.apply(first.state, residency_command)
	_check(replay.ok and replay.duplicate and replay.state.revision == 1,
		"L10 identical command ID replays once")
	var conflict := residency_command.duplicate(true)
	conflict.residency.status = "nonresident"
	_check(Tax.apply(first.state, conflict).error == "COMMAND_ID_CONFLICT",
		"L10 changed command under same ID conflicts")
	var stale := {"command_id": "other", "expected_revision": 0,
		"type": "SET_RESIDENCY", "tax_year": 2025,
		"residency": {"jurisdiction": "CN", "status": "resident", "rule_version": ""}}
	_check(Tax.apply(first.state, stale).error == "VERSION_CONFLICT",
		"L10 stale revision cannot overwrite another update")
	state = _apply(first.state, "add-entry", "ADD_ENTRY", {"entry": _entry()})
	var revised := _entry()
	revised.evidence_refs = ["receipt-1", "receipt-2"]
	revised.foreign_tax_paid = "0"
	var revise := Tax.apply(state, {"command_id": "revise-entry", "expected_revision": state.revision,
		"type": "REVISE_ENTRY", "expected_entry_revision": 1, "entry": revised})
	_check(revise.ok and revise.state.entries[revised.id].entry_revision == 2 and
		revise.state.entry_versions[revised.id].size() == 1 and
		revise.state.entry_versions[revised.id][0].foreign_tax_paid == "10.02",
		"L10 revision keeps prior evidence and financial values")
	if not revise.ok:
		return
	var damaged: Dictionary = revise.state.duplicate(true)
	damaged.entry_versions[revised.id] = []
	_check(Tax.build_workpaper(damaged, 2026).error == "INVALID_TAX_STATE",
		"L10 missing revision history is rejected")
	var stale_entry := Tax.apply(revise.state, {"command_id": "stale-entry",
		"expected_revision": revise.state.revision, "type": "REVISE_ENTRY",
		"expected_entry_revision": 1, "entry": revised})
	_check(not stale_entry.ok and stale_entry.error == "ENTRY_VERSION_CONFLICT",
		"L10 entry revision conflict stays explicit")
	var voided := Tax.apply(revise.state, {"command_id": "void-entry",
		"expected_revision": revise.state.revision, "type": "VOID_ENTRY",
		"entry_id": revised.id, "expected_entry_revision": 2})
	_check(voided.ok and voided.state.entries[revised.id].status == "voided" and
		voided.state.entry_versions[revised.id].size() == 2,
		"L10 void keeps immutable prior entry versions")
	if voided.ok:
		var paper := Tax.build_workpaper(voided.state, 2026)
		_check(paper.ok and paper.record_count == 0 and
			paper.voided_entry_ids.has(revised.id),
			"voided entry stays auditable but leaves current tax workpaper")


func _test_invalid_inputs_and_json_roundtrip() -> void:
	var state := Tax.new_state()
	var bad_tax := _entry()
	bad_tax.foreign_tax_paid = "-1"
	var bad_tax_result := Tax.apply(state, {"command_id": "negative-tax", "expected_revision": 0,
		"type": "ADD_ENTRY", "entry": bad_tax})
	_check(not bad_tax_result.ok and bad_tax_result.error == "INVALID_TAX_ENTRY"
		and state.entries.is_empty(), "negative foreign tax is rejected without mutation")
	var bad_fx := _entry()
	bad_fx.currency = "CNY"
	bad_fx.locked_fx.rate_to_base = "2"
	var bad_fx_result := Tax.apply(state, {"command_id": "bad-fx", "expected_revision": 0,
		"type": "ADD_ENTRY", "entry": bad_fx})
	_check(not bad_fx_result.ok and bad_fx_result.error == "INVALID_LOCKED_FX",
		"same-currency locked FX must equal one")
	var bad_ref := _entry()
	bad_ref.evidence_refs = ["C:/private/receipt.pdf"]
	var bad_ref_result := Tax.apply(state, {"command_id": "bad-evidence", "expected_revision": 0,
		"type": "ADD_ENTRY", "entry": bad_ref})
	_check(not bad_ref_result.ok and bad_ref_result.error == "INVALID_EVIDENCE_REFS",
		"evidence index cannot embed a filesystem path")
	var unverified := _entry()
	unverified.rule_version = "unverified-test-v1"
	state = _apply(state, "add-valid", "ADD_ENTRY", {"entry": unverified})
	var roundtrip: Variant = JSON.parse_string(JSON.stringify(state))
	var paper := Tax.build_workpaper(roundtrip, 2026)
	_check(paper.ok and paper.record_count == 1 and paper.groups[0].gross_income == "100.25",
		"L10 persisted JSON numeric metadata rehydrates without losing decimal strings")
	_check(paper.calculation_status == "NO_VALID_RULES" and
		not paper.calculation.has("tax_due"),
		"L10 a typed rule-version label is not proof of a verified rule package")
	var next := Tax.apply(roundtrip, {"command_id": "after-json", "expected_revision": 1,
		"type": "SET_RESIDENCY", "tax_year": 2026,
		"residency": {"jurisdiction": "CN", "status": "resident", "rule_version": ""}})
	_check(next.ok and next.state.revision == 2,
		"L10 commands continue after JSON roundtrip")
