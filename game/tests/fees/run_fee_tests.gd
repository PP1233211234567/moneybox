extends SceneTree

const Fees = preload("res://scripts/fees/fee_rule_service.gd")

var checks := 0
var failures: Array[String] = []


func _initialize() -> void:
	_test_date_selection_and_amounts()
	_test_actual_bill_and_idempotency()
	_test_ambiguity_and_invalid_inputs()
	if failures.is_empty():
		print("FEE TESTS PASS: %d checks" % checks)
		quit(0)
	else:
		for failure in failures:
			printerr(failure)
		printerr("FEE TESTS FAIL: %d failures in %d checks" % [failures.size(), checks])
		quit(1)


func _test_date_selection_and_amounts() -> void:
	var empty := Fees.new_state()
	var before := Fees.evaluate(empty, _context("before", "2025-12-31", "3001"))
	_check(before.ok and before.status == "MANUAL_REQUIRED"
		and not before.has("estimated_fee"),
		"missing rule is manual-required, not zero fee")
	var registered := Fees.register_rule_set(empty, _rule_set(), "register-fixture", 0)
	_check(registered.ok and registered.state.revision == 1,
		"only explicit versioned rules enter state")
	if not registered.ok:
		return
	var jan := Fees.evaluate(registered.state, _context("jan", "2026-01-01", "3001"))
	var june := Fees.evaluate(registered.state, _context("june", "2026-06-30", "3001"))
	var july := Fees.evaluate(registered.state, _context("july", "2026-07-01", "3001"))
	_check(jan.ok and jan.estimated_fee == "3" and jan.rule_id == "first-half",
		"effective_from day is inclusive")
	_check(june.ok and june.estimated_fee == "3" and june.rule_id == "first-half",
		"effective_to day is inclusive")
	_check(july.ok and july.estimated_fee == "6" and july.rule_id == "second-half-app",
		"next versioned rule starts on following day; specificity wins tie")
	var old := Fees.evaluate(registered.state, _context("old", "2025-12-31", "3001"))
	_check(old.ok and old.status == "MANUAL_REQUIRED" and not old.has("estimated_fee"),
		"date outside supplied rule window remains unknown")
	var min_result := Fees.evaluate(registered.state, _context("min", "2026-01-02", "100"))
	_check(min_result.ok and min_result.estimated_fee == "1",
		"explicit rule minimum applied with decimal text")
	var max_result := Fees.evaluate(registered.state, _context("max", "2026-01-02", "10000"))
	_check(max_result.ok and max_result.estimated_fee == "5",
		"explicit rule maximum applied with decimal text")
	var sell_context := _context("sell", "2026-07-01", "3001")
	sell_context.direction = "SELL"
	var sell := Fees.evaluate(registered.state, sell_context)
	_check(sell.ok and sell.rule_id == "second-half-general"
		and sell.estimated_fee == "3", "channel/direction specificity does not leak to sell")
	var mismatch := _context("other-market", "2026-07-01", "3001")
	mismatch.market = "NYSE"
	var unknown := Fees.evaluate(registered.state, mismatch)
	_check(unknown.ok and unknown.status == "MANUAL_REQUIRED"
		and not unknown.has("estimated_fee"), "market mismatch never invents rate")
	var replay := Fees.register_rule_set(registered.state, _rule_set(),
		"register-fixture", 0)
	_check(replay.ok and replay.duplicate and replay.state.revision == 1,
		"rule-set command replay returns same revision")
	var stale := Fees.register_rule_set(registered.state, _another_rule_set(),
		"stale-register", 0)
	_check(not stale.ok and stale.error == "REVISION_CONFLICT",
		"stale expected state revision cannot register rules")


func _test_actual_bill_and_idempotency() -> void:
	var registered := Fees.register_rule_set(Fees.new_state(), _rule_set(), "reg", 0)
	if not registered.ok:
		_check(false, "actual test setup")
		return
	var context := _context("trade-1", "2026-07-01", "3001")
	var created := Fees.create_estimate(registered.state, context, "estimate-1", 1)
	_check(created.ok and created.record.status == "ESTIMATED"
		and created.record.estimated_fee == "6"
		and created.record.rule_set_version == "2026-example-v1"
		and created.record.source_kind == "TEST_ONLY",
		"estimate retains exact fixture rule version and source")
	if not created.ok:
		return
	var actual := Fees.record_actual_bill(created.state, "trade-1", "7.25",
		"bill-001", "actual-1", 2, 1)
	_check(actual.ok and actual.record.status == "ACTUAL"
		and actual.record.actual_fee == "7.25"
		and actual.record.estimated_fee == "6"
		and actual.record.fee_difference == "1.25"
		and actual.record.rule_id == "second-half-app"
		and actual.record.actual_source == "USER_CONFIRMED_BILL",
		"actual bill overrides preview while preserving estimate and difference")
	if not actual.ok:
		return
	var original_estimate_replay := Fees.create_estimate(actual.state, context,
		"estimate-1", 1)
	_check(original_estimate_replay.ok and original_estimate_replay.duplicate
		and original_estimate_replay.record.status == "ESTIMATED"
		and original_estimate_replay.state.revision == 3,
		"replayed estimate returns original command result after actual bill")
	var actual_replay := Fees.record_actual_bill(actual.state, "trade-1", "7.25",
		"bill-001", "actual-1", 2, 1)
	_check(actual_replay.ok and actual_replay.duplicate and actual_replay.state.revision == 3,
		"duplicate actual command does not apply again")
	var changed_payload := Fees.record_actual_bill(actual.state, "trade-1", "7.26",
		"bill-001", "actual-1", 3, 2)
	_check(not changed_payload.ok and changed_payload.error == "IDEMPOTENCY_KEY_CONFLICT",
		"same command ID with changed bill amount rejected")
	var stale_record := Fees.record_actual_bill(actual.state, "trade-1", "8",
		"bill-002", "actual-2", 3, 1)
	_check(not stale_record.ok and stale_record.error == "RECORD_VERSION_CONFLICT",
		"stale fee-record version cannot overwrite actual bill")
	var unmatched := _context("trade-no-rule", "2025-01-01", "3001")
	var pending := Fees.create_estimate(actual.state, unmatched, "estimate-missing", 3)
	_check(pending.ok and pending.record.status == "MANUAL_REQUIRED"
		and not pending.record.has("estimated_fee"),
		"unmatched trade record retains missing status without zero estimate")
	var explicit_zero := Fees.record_actual_bill(pending.state, "trade-no-rule", "0",
		"bill-zero", "actual-zero", 4, 1)
	_check(explicit_zero.ok and explicit_zero.record.actual_fee == "0"
		and not explicit_zero.record.difference_known
		and not explicit_zero.record.has("fee_difference"),
		"explicit zero on actual bill is distinct from unknown estimate")
	var roundtrip: Dictionary = JSON.parse_string(JSON.stringify(explicit_zero.state))
	var persisted_replay := Fees.record_actual_bill(roundtrip, "trade-no-rule", "0",
		"bill-zero", "actual-zero", 4, 1)
	_check(persisted_replay.ok and persisted_replay.duplicate
		and persisted_replay.state.revision == 5,
		"idempotency survives JSON serialization")


func _test_ambiguity_and_invalid_inputs() -> void:
	var state: Dictionary = Fees.register_rule_set(Fees.new_state(), _rule_set(), "reg", 0).state
	var duplicate_rule := _another_rule_set()
	var second := Fees.register_rule_set(state, duplicate_rule, "reg-2", 1)
	_check(second.ok, "independent versioned rule set registered")
	var ambiguous := Fees.evaluate(second.state, _context("ambiguous", "2026-07-01", "3001"))
	_check(not ambiguous.ok and ambiguous.error == "AMBIGUOUS_FEE_RULES",
		"equal priority and specificity overlap is rejected")
	var ambiguity_write := Fees.create_estimate(second.state,
		_context("ambiguous", "2026-07-01", "3001"), "estimate-ambiguous", 2)
	_check(not ambiguity_write.ok and ambiguity_write.error == "AMBIGUOUS_FEE_RULES"
		and second.state.records.is_empty(),
		"ambiguity cannot create a fee record")
	var bad_rule_set := _rule_set()
	bad_rule_set.rules[0].formula.rate = 0.001
	var rejected_rule := Fees.register_rule_set(Fees.new_state(), bad_rule_set, "bad-float", 0)
	_check(not rejected_rule.ok and rejected_rule.error == "INVALID_RULE_SET",
		"float fee rate cannot enter authoritative rule state")
	var bad_context := _context("float-gross", "2026-07-01", "3001")
	bad_context.gross_amount = 3001.0
	var rejected_gross := Fees.evaluate(state, bad_context)
	_check(not rejected_gross.ok and rejected_gross.error == "INVALID_FEE_CONTEXT",
		"float trade gross rejected before estimate")
	var estimate := Fees.create_estimate(state, _context("trade-bad-bill", "2026-07-01", "3001"),
		"est", 1)
	var rejected_bill := Fees.record_actual_bill(estimate.state, "trade-bad-bill",
		7.25, "bill", "float-bill", 2, 1)
	_check(not rejected_bill.ok and rejected_bill.error == "INVALID_ACTUAL_BILL",
		"float actual bill rejected")
	var bad_date := _context("invalid-date", "2026-02-30", "3001")
	_check(not Fees.evaluate(state, bad_date).ok,
		"invalid calendar date cannot match a rule")
	var zero_gross := _context("zero-gross", "2026-07-01", "0")
	_check(Fees.evaluate(state, zero_gross).error == "INVALID_FEE_CONTEXT",
		"zero gross trade cannot trigger a minimum fee")
	var damaged: Dictionary = state.duplicate(true)
	damaged.rule_sets["fixture-rules-v1"].rules[0].formula.rate = 0.001
	_check(Fees.evaluate(damaged, _context("damaged", "2026-07-01", "3001")).error \
		== "INVALID_FEE_CONTEXT", "damaged persisted rule pack cannot calculate")
	var round_set := _another_rule_set()
	round_set.id = "rounding-fixture"
	round_set.rules[0].formula.rate = "0.005"
	round_set.rules[0].formula.minimum = "0"
	var round_state := Fees.register_rule_set(Fees.new_state(), round_set, "round-reg", 0)
	var round_result := Fees.evaluate(round_state.state,
		_context("round", "2026-07-01", "1"))
	_check(round_result.ok and round_result.status == "ESTIMATED"
		and round_result.estimated_fee == "0" and round_result.source_kind == "TEST_ONLY",
		"an explicit rule can calculate zero using decimal half-even rounding")


func _rule_set() -> Dictionary:
	return {"id": "fixture-rules-v1", "version": "2026-example-v1",
		"source_kind": "TEST_ONLY", "source_ref": "local-test-fixture",
		"verified_at": "2026-09-27", "rules": [
			_rule("first-half", "*", "*", "2026-01-01", "2026-06-30", "5", "0.001"),
			_rule("second-half-general", "*", "*", "2026-07-01", "", "5", "0.001"),
			_rule("second-half-app", "APP", "BUY", "2026-07-01", "", "5", "0.002"),
		]}


func _another_rule_set() -> Dictionary:
	return {"id": "fixture-rules-v2", "version": "2026-example-v2",
		"source_kind": "TEST_ONLY", "source_ref": "local-overlap-fixture",
		"verified_at": "2026-09-27", "rules": [
			_rule("same-specificity", "APP", "BUY", "2026-07-01", "", "5", "0.003")
		]}


func _rule(id: String, channel: String, direction: String, start: String,
		end: String, priority: String, rate: String) -> Dictionary:
	return {"id": id, "plan_id": "TEST_PLAN", "channel": channel,
		"market": "HKEX", "product": "STOCK", "direction": direction,
		"effective_from": start, "effective_to": end,
		"priority": priority, "currency": "HKD",
		"formula": {"rate": rate, "fixed": "0", "minimum": "1",
			"maximum": "5" if id == "first-half" else "",
			"rounding_scale": "2", "rounding_mode": "HALF_EVEN"}}


func _context(trade_id: String, date: String, gross: String) -> Dictionary:
	return {"trade_id": trade_id, "plan_id": "TEST_PLAN", "channel": "APP",
		"market": "HKEX", "product": "STOCK", "direction": "BUY",
		"trade_date": date, "gross_amount": gross, "currency": "HKD"}


func _check(condition: bool, label: String) -> void:
	checks += 1
	if not condition:
		failures.append("FAIL: " + label)
