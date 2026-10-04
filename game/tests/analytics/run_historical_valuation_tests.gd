extends SceneTree

const History = preload("res://scripts/analytics/historical_valuation_service.gd")

var failures: Array[String] = []
var checks := 0


func _initialize() -> void:
	_test_t09_and_recorded_points()
	_test_span_and_flow_coverage()
	_test_snapshot_and_fx_integrity()
	_test_same_time_boundary()
	if failures.is_empty():
		print("HISTORICAL VALUATION TESTS PASS: %d checks" % checks)
		quit(0)
	else:
		for failure in failures:
			printerr("FAIL: " + failure)
		printerr("HISTORICAL VALUATION TESTS FAIL: %d failures in %d checks" % [failures.size(), checks])
		quit(1)


func _check(condition: bool, label: String) -> void:
	checks += 1
	if not condition:
		failures.append(label)


func _snapshot(id: String, at: String, sequence: int, ledger_hash: String,
		value: String, currency: String = "CNY", native: String = "") -> Dictionary:
	var component := {"id": "cash:a", "currency": currency,
		"native_value": value if native.is_empty() else native,
		"base_value": value, "fx_lock_id": "",
		"source_at": at, "source": "LEDGER", "source_status": "CURRENT"}
	var locks := []
	if currency != "CNY":
		component.fx_lock_id = "fx:" + currency
		locks.append({"id": component.fx_lock_id, "currency": currency,
			"base_currency": "CNY", "rate": "10", "quoted_at": at,
			"source": "manual-test", "status": "CURRENT"})
	return {"schema_version": 1, "id": id, "at": at,
		"ledger_event_sequence": sequence, "ledger_hash": ledger_hash,
		"base_currency": "CNY", "asset_total": value,
		"valuation_quality": "CURRENT",
		"coverage": {"status": "COMPLETE", "ledger_event_sequence": sequence,
			"expected_component_ids": ["cash:a"]},
		"components": [component], "fx_locks": locks}


func _request() -> Dictionary:
	var a := "a".repeat(64)
	var b := "b".repeat(64)
	var c := "c".repeat(64)
	var jan := "2026-01-01T00:00:00Z"
	var feb := "2026-02-01T00:00:00Z"
	var mar := "2026-03-01T00:00:00Z"
	return {"schema_version": 1, "start_snapshot_id": "start",
		"end_snapshot_id": "end",
		"snapshots": [_snapshot("start", jan, 1, a, "100", "USD", "10"),
			_snapshot("preflow", feb, 2, b, "110"),
			_snapshot("end", mar, 3, c, "231")],
		"ledger_events": [
			{"id": "interest", "sequence": 2, "effective_at": feb,
				"type": "interest", "external": false,
				"ledger_hash_before": a, "ledger_hash_after": b},
			{"id": "deposit", "sequence": 3, "effective_at": feb,
				"type": "cash_delta", "external": true, "delta": "10",
				"currency": "USD", "ledger_hash_before": b,
				"ledger_hash_after": c}],
		"external_flows": [
			{"event_id": "deposit", "sequence": 3, "effective_at": feb,
				"currency": "USD", "amount_native": "10", "amount_base": "100",
				"fx_lock": {"id": "fx:deposit", "currency": "USD",
					"base_currency": "CNY", "rate": "10", "quoted_at": feb,
					"source": "manual-test", "status": "CURRENT"}}]}


func _test_t09_and_recorded_points() -> void:
	var request := _request()
	var before := JSON.stringify(request)
	var result := History.analyze(request)
	_check(result.ok and result.status == "COMPLETE", "aligned history yields complete interval")
	_check(result.interval.net_external_flow == "100" and \
		result.interval.asset_change == "131" and \
		result.interval.flow_adjusted_change == "31",
		"T09 flow-adjusted change uses locked flow-time FX")
	_check(result.twr.ok and result.twr.rate == "0.21" and \
		result.twr.percent == "21", "complete pre-flow mark yields exact TWR")
	_check(result.recorded_points.size() == 3 and \
		result.recorded_points[0].id == "start" and \
		result.recorded_points[1].id == "preflow" and \
		result.recorded_points[2].id == "end",
		"series contains only three actually recorded points")
	_check(JSON.stringify(request) == before, "read-only analysis leaves source unchanged")
	var duplicate_mark := request.duplicate(true)
	var extra: Dictionary = duplicate_mark.snapshots[1].duplicate(true)
	extra.id = "preflow-again"
	duplicate_mark.snapshots.append(extra)
	_check(History.analyze(duplicate_mark).error == "DUPLICATE_VALUATION_BOUNDARY",
		"same timestamp and ledger sequence cannot select arbitrary valuation")
	var absent_boundary := request.duplicate(true)
	absent_boundary.snapshots.remove_at(1)
	var no_twr := History.analyze(absent_boundary)
	_check(no_twr.ok and no_twr.interval.flow_adjusted_change == "31" and \
		not no_twr.twr.ok and no_twr.twr.error == "MISSING_FLOW_BOUNDARY" and \
		no_twr.recorded_points.size() == 2,
		"missing pre-flow mark leaves interval but withholds exact TWR")
	_check(result.xirr.ok and result.xirr.day_basis == 365,
		"complete history passes dated flows to fixed-365 XIRR solver")


func _test_span_and_flow_coverage() -> void:
	var missing_event := _request()
	missing_event.ledger_events.remove_at(0)
	var gap := History.analyze(missing_event)
	_check(not gap.ok and gap.status == "UNAVAILABLE" and \
		gap.error == "INCOMPLETE_LEDGER_EVENT_COVERAGE" and \
		not gap.has("interval"), "ledger sequence gap withholds exact interval")
	var missing_flow := _request()
	missing_flow.external_flows.clear()
	var no_flow := History.analyze(missing_flow)
	_check(not no_flow.ok and no_flow.error == "INCOMPLETE_EXTERNAL_FLOW_COVERAGE",
		"omitted external event cannot be called complete coverage")
	var invented_flow := _request()
	invented_flow.external_flows[0].event_id = "interest"
	_check(History.analyze(invented_flow).error == "EXTERNAL_FLOW_EVENT_MISMATCH",
		"internal event cannot be passed as external flow")
	var conflicting_event := _request()
	conflicting_event.ledger_events[1].delta = "11"
	_check(History.analyze(conflicting_event).error == "EXTERNAL_FLOW_EVENT_MISMATCH",
		"flow amount must equal authoritative event amount")
	var broken_hash := _request()
	broken_hash.ledger_events[1].ledger_hash_before = "d".repeat(64)
	_check(History.analyze(broken_hash).error == "LEDGER_HASH_CHAIN_MISMATCH",
		"ledger prefix hashes must chain across interval")
	var older_time := _request()
	older_time.ledger_events[1].effective_at = "2026-01-15T00:00:00Z"
	older_time.external_flows[0].effective_at = older_time.ledger_events[1].effective_at
	_check(History.analyze(older_time).error == "BACKDATED_LEDGER_EVENT",
		"backdated event invalidates earlier pre-flow boundary")


func _test_snapshot_and_fx_integrity() -> void:
	var bad_snapshot_rate := _request()
	bad_snapshot_rate.snapshots[0].fx_locks[0].rate = "9"
	_check(History.analyze(bad_snapshot_rate).error == "SNAPSHOT_FX_AMOUNT_MISMATCH",
		"snapshot total cannot ignore locked FX arithmetic")
	var missing_component := _request()
	missing_component.snapshots[0].components.clear()
	_check(History.analyze(missing_component).error == "SNAPSHOT_COMPONENT_COVERAGE_MISMATCH",
		"declared ledger component coverage must be present")
	var false_total := _request()
	false_total.snapshots[2].asset_total = "230"
	_check(History.analyze(false_total).error == "SNAPSHOT_TOTAL_MISMATCH",
		"asset total must equal the locked component sum")
	var future_quote := _request()
	future_quote.snapshots[0].components[0].source_at = "2026-01-02T00:00:00Z"
	_check(History.analyze(future_quote).error == "INVALID_SNAPSHOT_COMPONENT",
		"future quote cannot value an earlier snapshot")
	var future_fx := _request()
	future_fx.external_flows[0].fx_lock.quoted_at = "2026-02-02T00:00:00Z"
	_check(History.analyze(future_fx).error == "MISSING_OR_INVALID_FLOW_FX",
		"external flow requires available FX at its own time")
	var wrong_fx := _request()
	wrong_fx.external_flows[0].fx_lock.rate = "11"
	_check(History.analyze(wrong_fx).error == "FLOW_FX_AMOUNT_MISMATCH",
		"flow base amount must recompute exactly from the locked rate")
	var stale_prefix_mark := _request()
	stale_prefix_mark.snapshots[1].ledger_hash = "d".repeat(64)
	var measured := History.analyze(stale_prefix_mark)
	_check(measured.ok and not measured.twr.ok and \
		measured.twr.error == "MISSING_FLOW_BOUNDARY",
		"TWR ignores pre-flow valuation from a different ledger prefix")
	var stale_boundary := _request()
	stale_boundary.snapshots[1].components[0].source_status = "STALE_CONFIRMED"
	stale_boundary.snapshots[1].valuation_quality = "STALE_CONFIRMED"
	var stale_result := History.analyze(stale_boundary)
	_check(stale_result.ok and stale_result.interval.flow_adjusted_change == "31" and \
		not stale_result.twr.ok and stale_result.twr.error == "STALE_VALUATION_OR_FX" and \
		not stale_result.xirr.ok,
		"stale confirmed boundary retains recorded change but withholds exact returns")
	var stale_flow_fx := _request()
	stale_flow_fx.external_flows[0].fx_lock.status = "STALE_CONFIRMED"
	var stale_fx_result := History.analyze(stale_flow_fx)
	_check(stale_fx_result.ok and not stale_fx_result.twr.ok and \
		stale_fx_result.twr.error == "STALE_VALUATION_OR_FX",
		"stale flow-time FX cannot publish exact TWR")
	var false_quality := _request()
	false_quality.snapshots[0].fx_locks[0].status = "STALE_CONFIRMED"
	_check(History.analyze(false_quality).error == "SNAPSHOT_QUALITY_MISMATCH",
		"snapshot quality must reflect all locked input statuses")
	var incomplete := _request()
	incomplete.snapshots[0].coverage.status = "INCOMPLETE"
	_check(History.analyze(incomplete).error == "INCOMPLETE_SNAPSHOT_COVERAGE",
		"incomplete boundary cannot publish exact change")


func _test_same_time_boundary() -> void:
	var request := _request()
	request.start_snapshot_id = "preflow"
	request.end_snapshot_id = "end"
	request.ledger_events.remove_at(0)
	var result := History.analyze(request)
	_check(result.ok and result.interval.net_external_flow == "100" and \
		result.interval.flow_count == 1,
		"start sequence excludes old event and includes same-time later deposit")
	var at_flow := request.duplicate(true)
	at_flow.snapshots[2].at = "2026-02-01T00:00:00Z"
	at_flow.snapshots[2].components[0].source_at = at_flow.snapshots[2].at
	var same_time := History.analyze(at_flow)
	_check(same_time.ok and same_time.interval.flow_count == 1,
		"(t0,t1] uses event sequence when timestamps are equal")
	_check(not same_time.xirr.ok,
		"same-date endpoints do not invent an annual XIRR")
