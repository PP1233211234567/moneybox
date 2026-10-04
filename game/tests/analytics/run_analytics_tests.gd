extends SceneTree

const Analytics = preload("res://scripts/analytics/portfolio_analytics.gd")

var failures: Array[String] = []
var checks := 0


func _initialize() -> void:
	_test_t09_complete_twr()
	_test_interval_boundaries_and_incomplete_coverage()
	_test_twr_missing_boundary()
	_test_t10_xirr()
	_test_xirr_rejections_and_day_basis()
	if failures.is_empty():
		print("ANALYTICS TESTS PASS: %d checks" % checks)
		quit(0)
	else:
		for failure in failures:
			printerr("FAIL: " + failure)
		printerr("ANALYTICS TESTS FAIL: %d failures in %d checks" % [failures.size(), checks])
		quit(1)


func _check(condition: bool, label: String) -> void:
	checks += 1
	if not condition:
		failures.append(label)


func _snapshot(at: String, sequence: int, value: String, complete: bool = true) -> Dictionary:
	return {"at": at, "sequence": sequence, "asset_total": value,
		"base_currency": "CNY", "complete": complete}


func _flow(id: String, at: String, sequence: int, amount: String) -> Dictionary:
	return {"id": id, "effective_at": at, "sequence": sequence,
		"amount_base": amount, "base_currency": "CNY", "external": true}


func _test_t09_complete_twr() -> void:
	var start := _snapshot("2026-01-01T00:00:00Z", 1, "100")
	var end := _snapshot("2026-03-01T00:00:00Z", 4, "231")
	var flow := _flow("deposit-100", "2026-02-01T00:00:00Z", 3, "100")
	var original := JSON.stringify([start, end, flow])
	var interval := Analytics.measure_interval(start, end, [flow], true)
	_check(interval.ok and interval.net_external_flow == "100" and interval.flow_count == 1,
		"T09 (t0,t1] net external investment is 100")
	_check(interval.asset_change == "131" and interval.flow_adjusted_change == "31",
		"T09 absolute and flow-adjusted changes are 131 and 31")
	_check(interval.flow_adjusted_change_ratio == "0.31",
		"T09 simple difference ratio remains distinct from TWR")
	var before_flow := _snapshot(flow.effective_at, flow.sequence - 1, "110")
	var twr := Analytics.time_weighted_return(start, end, [flow],
		{"deposit-100": before_flow}, true)
	_check(twr.ok and twr.status == "COMPLETE" and twr.rate == "0.21"
		and twr.percent == "21", "T09 complete boundary valuations yield 21 percent TWR")
	_check(twr.period_count == 2 and twr.method == "CHAINED_SUBPERIOD_TWR",
		"T09 two subperiods are compounded")
	_check(JSON.stringify([start, end, flow]) == original,
		"analytics never changes authoritative inputs")


func _test_interval_boundaries_and_incomplete_coverage() -> void:
	var at_start := "2026-01-01T00:00:00Z"
	var at_end := "2026-02-01T00:00:00Z"
	var start := _snapshot(at_start, 5, "100")
	var end := _snapshot(at_end, 10, "130")
	var flows := [
		_flow("at-start-included-before-snapshot", at_start, 5, "100"),
		_flow("at-start-after-snapshot", at_start, 6, "10"),
		_flow("at-end-in-snapshot", at_end, 10, "20"),
		_flow("at-end-after-snapshot", at_end, 11, "300"),
	]
	var interval := Analytics.measure_interval(start, end, flows, true)
	_check(interval.ok and interval.flow_count == 2 and interval.net_external_flow == "30",
		"same-time sequence implements exclusive start and inclusive end")
	_check(interval.asset_change == "30" and interval.flow_adjusted_change == "0",
		"same-time boundary flow is not double deducted")
	var incomplete := Analytics.measure_interval(start, end, flows, false)
	_check(incomplete.ok and incomplete.status == "INCOMPLETE_FLOW_COVERAGE"
		and not incomplete.has("net_external_flow") and not incomplete.has("flow_adjusted_change"),
		"incomplete flow coverage exposes observed values without complete-flow claim")
	var zero_start := Analytics.measure_interval(_snapshot(at_start, 5, "0"), end, [], true)
	_check(zero_start.ok and zero_start.asset_change_ratio == ""
		and zero_start.flow_adjusted_change_ratio == "",
		"zero starting asset value has no misleading percentage")
	var negative_start := Analytics.measure_interval(_snapshot(at_start, 5, "-1"), end, [], true)
	_check(negative_start.ok and negative_start.asset_change_ratio == ""
		and negative_start.flow_adjusted_change_ratio == "",
		"negative starting asset value has no misleading percentage")


func _test_twr_missing_boundary() -> void:
	var start := _snapshot("2026-01-01T00:00:00Z", 1, "100")
	var end := _snapshot("2026-03-01T00:00:00Z", 4, "231")
	var flow := _flow("deposit-100", "2026-02-01T00:00:00Z", 3, "100")
	var missing := Analytics.time_weighted_return(start, end, [flow], {}, true)
	_check(not missing.ok and missing.status == "UNAVAILABLE"
		and missing.error == "MISSING_FLOW_BOUNDARY" and not missing.has("rate"),
		"TWR with missing pre-flow valuation is unavailable")
	var stale := Analytics.time_weighted_return(start, end, [flow],
		{flow.id: _snapshot(flow.effective_at, 2, "110", false)}, true)
	_check(not stale.ok and stale.error == "INVALID_FLOW_BOUNDARY" and not stale.has("rate"),
		"incomplete boundary valuation is not accepted as exact TWR")
	var wrong_sequence := Analytics.time_weighted_return(start, end, [flow],
		{flow.id: _snapshot(flow.effective_at, 3, "210")}, true)
	_check(not wrong_sequence.ok and wrong_sequence.error == "INVALID_FLOW_BOUNDARY",
		"post-flow snapshot cannot masquerade as pre-flow valuation")
	var incomplete_flows := Analytics.time_weighted_return(start, end, [flow], {}, false)
	_check(not incomplete_flows.ok and incomplete_flows.error == "INCOMPLETE_FLOW_COVERAGE"
		and not incomplete_flows.has("rate"), "TWR requires complete external cash-flow coverage")


func _test_t10_xirr() -> void:
	var flows := [{"date": "2025-01-01", "amount": "-10000"},
		{"date": "2026-01-01", "amount": "11000"}]
	var original := JSON.stringify(flows)
	var result := Analytics.xirr(flows)
	_check(result.ok and result.annual_rate == "0.1" and result.percent == "10",
		"T10 365-day XIRR is 10 percent")
	_check(result.day_basis == 365 and result.status == "APPROXIMATE_NUMERIC_ROOT"
		and result.method == "LOG_RATE_BISECTION_FLOAT", "T10 numeric method and day rule explicit")
	_check(JSON.stringify(flows) == original, "XIRR does not rewrite cash-flow strings")


func _test_xirr_rejections_and_day_basis() -> void:
	var same_sign := Analytics.xirr([{"date": "2025-01-01", "amount": "100"},
		{"date": "2026-01-01", "amount": "200"}])
	_check(not same_sign.ok and same_sign.error == "SAME_SIGN_CASH_FLOWS"
		and not same_sign.has("annual_rate"), "same-sign cash flows give no fake XIRR")
	var multi := Analytics.xirr([{"date": "2025-01-01", "amount": "-100"},
		{"date": "2026-01-01", "amount": "230"},
		{"date": "2027-01-01", "amount": "-132"}])
	_check(not multi.ok and multi.error == "MULTIPLE_ROOTS"
		and not multi.has("annual_rate"), "two real XIRR roots are rejected")
	var invalid := Analytics.xirr([{"date": "2025-02-29", "amount": "-100"},
		{"date": "2026-01-01", "amount": "110"}])
	_check(not invalid.ok and invalid.error == "INVALID_CASH_FLOW",
		"invalid Gregorian date rejected")
	var leap := Analytics.xirr([{"date": "2024-01-01", "amount": "-100"},
		{"date": "2025-01-01", "amount": "110"}])
	_check(leap.ok and float(leap.annual_rate) < 0.1 and float(leap.annual_rate) > 0.099,
		"366 actual days retain fixed 365-day annualization")
	var same_day := Analytics.xirr([{"date": "2025-01-01", "amount": "-100"},
		{"date": "2025-01-01", "amount": "50"},
		{"date": "2026-01-01", "amount": "55"}])
	_check(same_day.ok and same_day.annual_rate == "0.1"
		and same_day.distinct_dates == 2, "same-day cash flows net before solving")
