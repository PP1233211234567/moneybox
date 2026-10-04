extends RefCounted
## Financial display calculations over complete, base-currency valuation boundaries.
## Inputs remain decimal strings. Only XIRR's root solver uses local floating point.
## Callers must lock each external flow into the snapshot base currency using the
## flow-time FX rate, and attach the last included ledger event sequence to every
## valuation. A quote snapshot without that sequence is not a valid TWR boundary.

const Decimal = preload("res://scripts/data/decimal_text.gd")
const XIRR_LOG_MIN := -24.0
const XIRR_LOG_MAX := 24.0


static func measure_interval(start_snapshot: Dictionary, end_snapshot: Dictionary,
		external_flows: Array, flow_coverage_complete: bool) -> Dictionary:
	var boundaries := _boundaries(start_snapshot, end_snapshot)
	if not boundaries.ok:
		return boundaries
	var normalized := _normalize_flows(external_flows, str(start_snapshot.base_currency))
	if not normalized.ok:
		return normalized
	var included := _within(normalized.flows, start_snapshot, end_snapshot)
	var net := "0"
	for flow in included:
		net = Decimal.add(net, str(flow.amount_base))
	var change := Decimal.subtract(str(end_snapshot.asset_total), str(start_snapshot.asset_total))
	var adjusted := Decimal.subtract(change, net)
	var result := {"ok": true, "status": "COMPLETE" if flow_coverage_complete else "INCOMPLETE_FLOW_COVERAGE",
		"asset_change": change, "flow_count": included.size(),
		"flow_coverage_complete": flow_coverage_complete,
		"net_external_flow_observed": net, "adjusted_change_observed": adjusted,
		"asset_change_ratio": "", "flow_adjusted_change_ratio": ""}
	if Decimal.compare(str(start_snapshot.asset_total), "0") > 0:
		result.asset_change_ratio = Decimal.divide(change, str(start_snapshot.asset_total), 18)
	if flow_coverage_complete:
		result.net_external_flow = net
		result.flow_adjusted_change = adjusted
		if Decimal.compare(str(start_snapshot.asset_total), "0") > 0:
			# A simple difference ratio, never labelled as a time-weighted return.
			result.flow_adjusted_change_ratio = Decimal.divide(adjusted,
				str(start_snapshot.asset_total), 18)
	return result


static func time_weighted_return(start_snapshot: Dictionary, end_snapshot: Dictionary,
		external_flows: Array, pre_flow_snapshots: Dictionary,
		flow_coverage_complete: bool) -> Dictionary:
	var measured := measure_interval(start_snapshot, end_snapshot, external_flows,
		flow_coverage_complete)
	if not measured.ok:
		return measured
	if not flow_coverage_complete:
		return _unavailable("INCOMPLETE_FLOW_COVERAGE")
	if Decimal.compare(str(start_snapshot.asset_total), "0") <= 0:
		return _unavailable("NONPOSITIVE_START_VALUE")
	var normalized := _normalize_flows(external_flows, str(start_snapshot.base_currency))
	var included := _within(normalized.flows, start_snapshot, end_snapshot)
	var previous_post: String = start_snapshot.asset_total
	var compounded := "1"
	for flow in included:
		if not pre_flow_snapshots.has(flow.id):
			return _unavailable("MISSING_FLOW_BOUNDARY", str(flow.id))
		var boundary_raw: Variant = pre_flow_snapshots[flow.id]
		if typeof(boundary_raw) != TYPE_DICTIONARY:
			return _unavailable("INVALID_FLOW_BOUNDARY", str(flow.id))
		var boundary: Dictionary = boundary_raw
		if not _valid_snapshot(boundary) or str(boundary.base_currency) != str(start_snapshot.base_currency) \
				or str(boundary.at) != str(flow.effective_at) or \
				int(boundary.sequence) != int(flow.sequence) - 1:
			return _unavailable("INVALID_FLOW_BOUNDARY", str(flow.id))
		if Decimal.compare(previous_post, "0") <= 0:
			return _unavailable("NONPOSITIVE_PERIOD_BASE", str(flow.id))
		var multiplier := Decimal.divide(str(boundary.asset_total), previous_post, 30)
		compounded = Decimal.multiply(compounded, multiplier)
		previous_post = Decimal.add(str(boundary.asset_total), str(flow.amount_base))
		if Decimal.compare(previous_post, "0") <= 0:
			return _unavailable("NONPOSITIVE_POST_FLOW_VALUE", str(flow.id))
	var final_multiplier := Decimal.divide(str(end_snapshot.asset_total), previous_post, 30)
	compounded = Decimal.multiply(compounded, final_multiplier)
	var rate := Decimal.subtract(compounded, "1")
	return {"ok": true, "status": "COMPLETE", "method": "CHAINED_SUBPERIOD_TWR",
		"rate": rate, "percent": Decimal.multiply(rate, "100"),
		"period_count": included.size() + 1, "flow_count": included.size(),
		"net_external_flow": measured.net_external_flow,
		"flow_adjusted_change": measured.flow_adjusted_change}


static func xirr(cashflows: Array) -> Dictionary:
	if cashflows.size() < 2:
		return _error("INSUFFICIENT_CASH_FLOWS")
	var grouped := {}
	for raw in cashflows:
		if typeof(raw) != TYPE_DICTIONARY or typeof(raw.get("date", null)) != TYPE_STRING or \
				typeof(raw.get("amount", null)) != TYPE_STRING:
			return _error("INVALID_CASH_FLOW")
		var date: String = raw.date
		var amount: String = raw.amount
		if _date_ordinal(date) < 0 or not Decimal.is_valid(amount):
			return _error("INVALID_CASH_FLOW")
		grouped[date] = Decimal.add(str(grouped.get(date, "0")), amount)
	var dates: Array = grouped.keys()
	dates.sort()
	var nonzero := []
	var positive := false
	var negative := false
	var sign_changes := 0
	var previous_sign := 0
	for date in dates:
		var amount: String = grouped[date]
		var sign := Decimal.compare(amount, "0")
		if sign == 0:
			continue
		if previous_sign != 0 and sign != previous_sign:
			sign_changes += 1
		previous_sign = sign
		positive = positive or sign > 0
		negative = negative or sign < 0
		nonzero.append({"date": date, "amount": amount, "ordinal": _date_ordinal(date)})
	if not positive or not negative:
		return _error("SAME_SIGN_CASH_FLOWS")
	if nonzero.size() < 2 or nonzero[0].ordinal == nonzero.back().ordinal:
		return _error("INSUFFICIENT_DATES")
	var origin: int = nonzero[0].ordinal
	var numeric := []
	for flow in nonzero:
		var amount_float := float(flow.amount)
		if amount_float == 0.0 or absf(amount_float) > 1e300 or is_nan(amount_float):
			return _error("NUMERIC_RANGE_UNSUPPORTED")
		numeric.append({"years": float(int(flow.ordinal) - origin) / 365.0,
			"amount": amount_float})
	if sign_changes > 1:
		# Multiple sign changes can hide even-multiplicity or very narrow roots.
		# Never publish a single guessed XIRR for such a series.
		return _error("MULTIPLE_ROOTS" if _sample_root_crossings(numeric) >= 2 else "AMBIGUOUS_ROOTS")
	var lower := XIRR_LOG_MIN
	var upper := XIRR_LOG_MAX
	var lower_sign := _sign(_scaled_npv(numeric, lower))
	var upper_sign := _sign(_scaled_npv(numeric, upper))
	if lower_sign == 0 or upper_sign == 0 or lower_sign == upper_sign:
		return _error("ROOT_OUT_OF_RANGE")
	for iteration in 120:
		var middle := (lower + upper) / 2.0
		var middle_sign := _sign(_scaled_npv(numeric, middle))
		if middle_sign == 0:
			lower = middle
			upper = middle
			break
		if middle_sign == lower_sign:
			lower = middle
			lower_sign = middle_sign
		else:
			upper = middle
	var log_rate := (lower + upper) / 2.0
	var annual_rate := exp(log_rate) - 1.0
	if is_nan(annual_rate) or absf(annual_rate) > 1e300:
		return _error("NUMERIC_RANGE_UNSUPPORTED")
	return {"ok": true, "status": "APPROXIMATE_NUMERIC_ROOT",
		"annual_rate": Decimal.canonical("%.12f" % annual_rate),
		"percent": Decimal.canonical("%.10f" % (annual_rate * 100.0)),
		"day_basis": 365, "cash_flow_count": cashflows.size(),
		"distinct_dates": nonzero.size(), "method": "LOG_RATE_BISECTION_FLOAT"}


static func _boundaries(start_snapshot: Dictionary, end_snapshot: Dictionary) -> Dictionary:
	if not _valid_snapshot(start_snapshot) or not _valid_snapshot(end_snapshot):
		return _error("INVALID_OR_INCOMPLETE_SNAPSHOT")
	if start_snapshot.base_currency != end_snapshot.base_currency:
		return _error("CURRENCY_MISMATCH")
	if _compare_point(start_snapshot.at, int(start_snapshot.sequence),
			end_snapshot.at, int(end_snapshot.sequence)) >= 0:
		return _error("INVALID_INTERVAL")
	return {"ok": true}


static func _valid_snapshot(value: Dictionary) -> bool:
	return typeof(value.get("at", null)) == TYPE_STRING and _valid_utc(value.at) and \
		typeof(value.get("sequence", null)) == TYPE_INT and int(value.sequence) >= 0 and \
		typeof(value.get("asset_total", null)) == TYPE_STRING and Decimal.is_valid(value.asset_total) and \
		typeof(value.get("base_currency", null)) == TYPE_STRING and \
		_valid_currency(value.base_currency) and value.get("complete", false) == true


static func _normalize_flows(flows: Array, currency: String) -> Dictionary:
	var normalized := []
	var seen := {}
	for raw in flows:
		if typeof(raw) != TYPE_DICTIONARY or typeof(raw.get("id", null)) != TYPE_STRING or \
				str(raw.id).is_empty() or seen.has(raw.id) or \
				typeof(raw.get("effective_at", null)) != TYPE_STRING or \
				not _valid_utc(str(raw.effective_at)) or \
				typeof(raw.get("sequence", null)) != TYPE_INT or int(raw.sequence) < 1 or \
				typeof(raw.get("amount_base", null)) != TYPE_STRING or \
				not Decimal.is_valid(str(raw.amount_base)) or \
				raw.get("base_currency", "") != currency or raw.get("external", false) != true:
			return _error("INVALID_EXTERNAL_FLOW")
		seen[raw.id] = true
		normalized.append(raw.duplicate(true))
	normalized.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return _compare_point(a.effective_at, int(a.sequence), b.effective_at, int(b.sequence)) < 0)
	return {"ok": true, "flows": normalized}


static func _within(flows: Array, start_snapshot: Dictionary, end_snapshot: Dictionary) -> Array:
	var selected := []
	for flow in flows:
		if _compare_point(flow.effective_at, int(flow.sequence),
				start_snapshot.at, int(start_snapshot.sequence)) > 0 and \
				_compare_point(flow.effective_at, int(flow.sequence),
				end_snapshot.at, int(end_snapshot.sequence)) <= 0:
			selected.append(flow)
	return selected


static func _compare_point(at_a: String, sequence_a: int, at_b: String, sequence_b: int) -> int:
	if at_a < at_b:
		return -1
	if at_a > at_b:
		return 1
	if sequence_a < sequence_b:
		return -1
	if sequence_a > sequence_b:
		return 1
	return 0


static func _valid_utc(value: String) -> bool:
	if value.length() != 20 or value.substr(4, 1) != "-" or value.substr(7, 1) != "-" or \
			value.substr(10, 1) != "T" or value.substr(13, 1) != ":" or \
			value.substr(16, 1) != ":" or value.substr(19, 1) != "Z":
		return false
	for index in [0, 1, 2, 3, 5, 6, 8, 9, 11, 12, 14, 15, 17, 18]:
		var digit := value.substr(index, 1)
		if digit < "0" or digit > "9":
			return false
	if _date_ordinal(value.substr(0, 10)) < 0:
		return false
	return int(value.substr(11, 2)) <= 23 and int(value.substr(14, 2)) <= 59 and \
		int(value.substr(17, 2)) <= 59


static func _valid_currency(value: String) -> bool:
	if value.length() != 3:
		return false
	for index in 3:
		var letter := value.substr(index, 1)
		if letter < "A" or letter > "Z":
			return false
	return true


static func _date_ordinal(value: String) -> int:
	if value.length() != 10 or value.substr(4, 1) != "-" or value.substr(7, 1) != "-":
		return -1
	for index in [0, 1, 2, 3, 5, 6, 8, 9]:
		var digit := value.substr(index, 1)
		if digit < "0" or digit > "9":
			return -1
	var year := int(value.substr(0, 4))
	var month := int(value.substr(5, 2))
	var day := int(value.substr(8, 2))
	if year < 1 or month < 1 or month > 12:
		return -1
	var leap := year % 400 == 0 or (year % 4 == 0 and year % 100 != 0)
	var month_days := [31, 29 if leap else 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
	if day < 1 or day > month_days[month - 1]:
		return -1
	var prior_year := year - 1
	var ordinal := prior_year * 365 + int(prior_year / 4) - int(prior_year / 100) + \
		int(prior_year / 400) + day
	for index in range(month - 1):
		ordinal += month_days[index]
	return ordinal


static func _scaled_npv(flows: Array, log_rate: float) -> float:
	var largest_exponent := -INF
	for flow in flows:
		largest_exponent = maxf(largest_exponent, -float(flow.years) * log_rate)
	var sum := 0.0
	for flow in flows:
		sum += float(flow.amount) * exp(-float(flow.years) * log_rate - largest_exponent)
	return sum


static func _sample_root_crossings(flows: Array) -> int:
	var crossings := 0
	var previous := 0
	for index in 4097:
		var y := XIRR_LOG_MIN + (XIRR_LOG_MAX - XIRR_LOG_MIN) * float(index) / 4096.0
		var sign := _sign(_scaled_npv(flows, y))
		if sign == 0:
			continue
		if previous != 0 and sign != previous:
			crossings += 1
		previous = sign
	return crossings


static func _sign(value: float) -> int:
	if value > 0.0:
		return 1
	if value < 0.0:
		return -1
	return 0


static func _unavailable(code: String, flow_id: String = "") -> Dictionary:
	return {"ok": false, "status": "UNAVAILABLE", "error": code, "flow_id": flow_id}


static func _error(code: String) -> Dictionary:
	return {"ok": false, "error": code}
