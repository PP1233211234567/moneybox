extends RefCounted
## Read-only analysis of recorded valuation points and an authoritative ledger span.
## The caller must supply the complete event slice from its ledger. This service
## checks that the slice is contiguous and that every external event has one
## flow with a time-locked conversion. It does not create missing price marks.

const Decimal = preload("res://scripts/data/decimal_text.gd")
const Analytics = preload("res://scripts/analytics/portfolio_analytics.gd")
const QuoteContract = preload("res://scripts/quotes/quote_contract.gd")


static func analyze(request: Dictionary) -> Dictionary:
	if typeof(request.get("schema_version", null)) != TYPE_INT or \
			request.schema_version != 1 or \
			typeof(request.get("snapshots", null)) != TYPE_ARRAY or \
			typeof(request.get("ledger_events", null)) != TYPE_ARRAY or \
			typeof(request.get("external_flows", null)) != TYPE_ARRAY:
		return _error("INVALID_HISTORY_REQUEST")
	var snapshots: Array = request.snapshots
	var indexed := {}
	var point_keys := {}
	var points := []
	for raw in snapshots:
		if typeof(raw) != TYPE_DICTIONARY:
			return _error("INVALID_SNAPSHOT")
		var checked := _snapshot(raw)
		if not checked.ok:
			return checked
		var snapshot: Dictionary = checked.snapshot
		if indexed.has(snapshot.id):
			return _error("DUPLICATE_SNAPSHOT_ID")
		var point_key := str(snapshot.at) + "|" + str(snapshot.ledger_event_sequence)
		if point_keys.has(point_key):
			return _error("DUPLICATE_VALUATION_BOUNDARY")
		point_keys[point_key] = true
		indexed[snapshot.id] = snapshot
		points.append({"id": snapshot.id, "at": snapshot.at,
			"ledger_event_sequence": snapshot.ledger_event_sequence,
			"asset_total": snapshot.asset_total,
			"base_currency": snapshot.base_currency,
			"complete": checked.complete,
			"ledger_hash": snapshot.ledger_hash})
	points.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return _compare_point(a.at, int(a.ledger_event_sequence),
			b.at, int(b.ledger_event_sequence)) < 0)
	var start_id := str(request.get("start_snapshot_id", ""))
	var end_id := str(request.get("end_snapshot_id", ""))
	if not indexed.has(start_id) or not indexed.has(end_id):
		return _error("SNAPSHOT_NOT_FOUND")
	var start: Dictionary = indexed[start_id]
	var finish: Dictionary = indexed[end_id]
	if start.base_currency != finish.base_currency:
		return _error("CURRENCY_MISMATCH")
	if _compare_point(start.at, int(start.ledger_event_sequence),
			finish.at, int(finish.ledger_event_sequence)) >= 0 or \
			int(start.ledger_event_sequence) > int(finish.ledger_event_sequence):
		return _error("INVALID_INTERVAL")
	if not _is_complete(start) or not _is_complete(finish):
		return _unavailable("INCOMPLETE_BOUNDARY_VALUATION", points)
	var span := _ledger_span(request.ledger_events, start, finish)
	if not span.ok:
		return _unavailable(str(span.error), points)
	var converted := _flows(request.external_flows, span.events, str(start.base_currency))
	if not converted.ok:
		return _unavailable(str(converted.error), points)
	var start_point := _analytic_point(start)
	var end_point := _analytic_point(finish)
	var interval := Analytics.measure_interval(start_point, end_point,
		converted.flows, true)
	if not interval.ok:
		return _unavailable(str(interval.error), points)
	var pre_flow := {}
	var stale_boundary := false
	for flow in converted.flows:
		for snapshot in indexed.values():
			if _is_complete(snapshot) and snapshot.base_currency == start.base_currency \
					and snapshot.at == flow.effective_at and \
					int(snapshot.ledger_event_sequence) == int(flow.sequence) - 1 and \
					snapshot.ledger_hash == span.hash_by_sequence[int(snapshot.ledger_event_sequence)]:
				if snapshot.valuation_quality == "CURRENT":
					pre_flow[flow.id] = _analytic_point(snapshot)
				else:
					stale_boundary = true
				break
	var returns_eligible: bool = start.valuation_quality == "CURRENT" and \
		finish.valuation_quality == "CURRENT" and not stale_boundary and \
		not converted.stale_fx
	var twr := {"ok": false, "status": "UNAVAILABLE",
		"error": "STALE_VALUATION_OR_FX"}
	if returns_eligible:
		twr = Analytics.time_weighted_return(start_point, end_point,
			converted.flows, pre_flow, true)
	var xirr_flows := [{"date": str(start.at).substr(0, 10),
		"amount": Decimal.subtract("0", str(start.asset_total))}]
	for flow in converted.flows:
		xirr_flows.append({"date": str(flow.effective_at).substr(0, 10),
			"amount": Decimal.subtract("0", str(flow.amount_base))})
	xirr_flows.append({"date": str(finish.at).substr(0, 10),
		"amount": str(finish.asset_total)})
	var xirr := {"ok": false, "status": "UNAVAILABLE",
		"error": "STALE_VALUATION_OR_FX"}
	if returns_eligible:
		xirr = Analytics.xirr(xirr_flows)
	return {"ok": true, "status": "COMPLETE", "recorded_points": points,
		"interval": interval, "twr": twr, "xirr": xirr,
		"ledger_event_count": span.events.size(), "external_flow_count": converted.flows.size()}


static func _snapshot(value: Dictionary) -> Dictionary:
	var at := str(value.get("at", ""))
	var sequence = value.get("ledger_event_sequence", null)
	var asset_total = value.get("asset_total", null)
	var coverage = value.get("coverage", null)
	var components = value.get("components", null)
	var fx_locks = value.get("fx_locks", null)
	var base_currency := str(value.get("base_currency", ""))
	if typeof(value.get("schema_version", null)) != TYPE_INT or \
			value.schema_version != 1 or str(value.get("id", "")).is_empty() \
			or QuoteContract.utc_unix(at) < 0 or typeof(sequence) != TYPE_INT \
			or sequence < 0 or not _hash(str(value.get("ledger_hash", ""))) \
			or not _currency(base_currency) or typeof(asset_total) != TYPE_STRING \
			or not Decimal.is_valid(asset_total) or typeof(coverage) != TYPE_DICTIONARY \
			or typeof(components) != TYPE_ARRAY or typeof(fx_locks) != TYPE_ARRAY or \
			not ["CURRENT", "STALE_CONFIRMED"].has(value.get("valuation_quality", "")):
		return _error("INVALID_SNAPSHOT")
	if coverage.get("status", "") != "COMPLETE" or \
			typeof(coverage.get("expected_component_ids", null)) != TYPE_ARRAY or \
			typeof(coverage.get("ledger_event_sequence", null)) != TYPE_INT or \
			coverage.ledger_event_sequence != sequence:
		return _error("INCOMPLETE_SNAPSHOT_COVERAGE")
	var expected: Array = coverage.expected_component_ids
	var expected_set := {}
	for id in expected:
		if typeof(id) != TYPE_STRING or id.is_empty() or expected_set.has(id):
			return _error("INVALID_SNAPSHOT_COVERAGE")
		expected_set[id] = true
	var fx_by_id := {}
	for raw_lock in fx_locks:
		if typeof(raw_lock) != TYPE_DICTIONARY or not _valid_fx(raw_lock,
				base_currency, at):
			return _error("INVALID_SNAPSHOT_FX")
		if fx_by_id.has(raw_lock.id):
			return _error("DUPLICATE_SNAPSHOT_FX")
		fx_by_id[raw_lock.id] = raw_lock
	var actual := {}
	var used_fx := {}
	var total := "0"
	var stale_input := false
	for raw_component in components:
		if typeof(raw_component) != TYPE_DICTIONARY:
			return _error("INVALID_SNAPSHOT_COMPONENT")
		var component: Dictionary = raw_component
		var id := str(component.get("id", ""))
		var native = component.get("native_value", null)
		var base = component.get("base_value", null)
		var currency := str(component.get("currency", ""))
		var source_at := str(component.get("source_at", ""))
		if id.is_empty() or actual.has(id) or not expected_set.has(id) or \
				not _currency(currency) or typeof(native) != TYPE_STRING or \
				not Decimal.is_valid(native) or typeof(base) != TYPE_STRING or \
				not Decimal.is_valid(base) or str(component.get("source", "")).is_empty() or \
				not ["CURRENT", "STALE_CONFIRMED"].has(component.get("source_status", "")) or \
				QuoteContract.utc_unix(source_at) < 0 or source_at > at:
			return _error("INVALID_SNAPSHOT_COMPONENT")
		actual[id] = true
		stale_input = stale_input or component.source_status == "STALE_CONFIRMED"
		var lock_id := str(component.get("fx_lock_id", ""))
		var expected_base := str(native)
		if currency == base_currency:
			if not lock_id.is_empty():
				return _error("UNEXPECTED_SNAPSHOT_FX")
		else:
			if not fx_by_id.has(lock_id) or fx_by_id[lock_id].currency != currency:
				return _error("MISSING_SNAPSHOT_FX")
			used_fx[lock_id] = true
			stale_input = stale_input or fx_by_id[lock_id].status == "STALE_CONFIRMED"
			expected_base = Decimal.multiply(str(native), str(fx_by_id[lock_id].rate))
		if Decimal.compare(expected_base, str(base)) != 0:
			return _error("SNAPSHOT_FX_AMOUNT_MISMATCH")
		total = Decimal.add(total, str(base))
	if actual.size() != expected_set.size() or used_fx.size() != fx_by_id.size():
		return _error("SNAPSHOT_COMPONENT_COVERAGE_MISMATCH")
	if Decimal.compare(total, str(asset_total)) != 0:
		return _error("SNAPSHOT_TOTAL_MISMATCH")
	if value.valuation_quality != ("STALE_CONFIRMED" if stale_input else "CURRENT"):
		return _error("SNAPSHOT_QUALITY_MISMATCH")
	return {"ok": true, "complete": true, "snapshot": value.duplicate(true)}


static func _ledger_span(raw_events: Array, start: Dictionary, finish: Dictionary) -> Dictionary:
	var events := {}
	var event_ids := {}
	var first := int(start.ledger_event_sequence) + 1
	var last := int(finish.ledger_event_sequence)
	for raw in raw_events:
		if typeof(raw) != TYPE_DICTIONARY:
			return _error("INVALID_LEDGER_EVENT")
		var event: Dictionary = raw
		var sequence = event.get("sequence", null)
		var at := str(event.get("effective_at", ""))
		if typeof(sequence) != TYPE_INT or sequence < first or sequence > last or \
				str(event.get("id", "")).is_empty() or \
				str(event.get("type", "")).is_empty() or \
				not _hash(str(event.get("ledger_hash_before", ""))) or \
				not _hash(str(event.get("ledger_hash_after", ""))) or \
				QuoteContract.utc_unix(at) < 0 or \
				typeof(event.get("external", null)) != TYPE_BOOL or \
				_compare_point(at, sequence, start.at,
					int(start.ledger_event_sequence)) <= 0 or \
				_compare_point(at, sequence, finish.at,
					int(finish.ledger_event_sequence)) > 0:
			return _error("INVALID_LEDGER_EVENT")
		if events.has(sequence) or event_ids.has(event.id):
			return _error("DUPLICATE_LEDGER_SEQUENCE")
		event_ids[event.id] = true
		if event.external and (event.get("type", "") != "cash_delta" or \
				typeof(event.get("delta", null)) != TYPE_STRING or \
				not Decimal.is_valid(event.delta) or \
				not _currency(str(event.get("currency", "")))):
			return _error("INVALID_EXTERNAL_EVENT")
		events[sequence] = event
	if events.size() != last - first + 1:
		return _error("INCOMPLETE_LEDGER_EVENT_COVERAGE")
	var ordered := []
	var hashes := {int(start.ledger_event_sequence): str(start.ledger_hash)}
	var previous_hash := str(start.ledger_hash)
	var previous_at := str(start.at)
	for sequence in range(first, last + 1):
		if not events.has(sequence):
			return _error("INCOMPLETE_LEDGER_EVENT_COVERAGE")
		var event: Dictionary = events[sequence]
		if event.ledger_hash_before != previous_hash:
			return _error("LEDGER_HASH_CHAIN_MISMATCH")
		if str(event.effective_at) < previous_at:
			return _error("BACKDATED_LEDGER_EVENT")
		ordered.append(event)
		previous_hash = str(event.ledger_hash_after)
		previous_at = str(event.effective_at)
		hashes[sequence] = previous_hash
	if previous_hash != str(finish.ledger_hash):
		return _error("LEDGER_HASH_CHAIN_MISMATCH")
	return {"ok": true, "events": ordered, "hash_by_sequence": hashes}


static func _flows(raw_flows: Array, events: Array, base_currency: String) -> Dictionary:
	var events_by_id := {}
	for event in events:
		if event.external:
			if events_by_id.has(event.id):
				return _error("DUPLICATE_EXTERNAL_EVENT")
			events_by_id[event.id] = event
	var used := {}
	var converted := []
	var stale_fx := false
	for raw in raw_flows:
		if typeof(raw) != TYPE_DICTIONARY:
			return _error("INVALID_EXTERNAL_FLOW")
		var flow: Dictionary = raw
		var event_id := str(flow.get("event_id", ""))
		if not events_by_id.has(event_id) or used.has(event_id):
			return _error("EXTERNAL_FLOW_EVENT_MISMATCH")
		var event: Dictionary = events_by_id[event_id]
		var currency := str(flow.get("currency", ""))
		var native = flow.get("amount_native", null)
		var base = flow.get("amount_base", null)
		if currency != str(event.currency) or \
				str(flow.get("effective_at", "")) != str(event.effective_at) or \
				flow.get("sequence", null) != event.sequence or \
				typeof(native) != TYPE_STRING or not Decimal.is_valid(native) or \
				typeof(base) != TYPE_STRING or not Decimal.is_valid(base) or \
				Decimal.compare(native, str(event.delta)) != 0:
			return _error("EXTERNAL_FLOW_EVENT_MISMATCH")
		var lock = flow.get("fx_lock", null)
		var expected_base := str(native)
		if currency == base_currency:
			if typeof(lock) != TYPE_DICTIONARY or not lock.is_empty():
				return _error("UNEXPECTED_FLOW_FX")
		else:
			if typeof(lock) != TYPE_DICTIONARY or not _valid_fx(lock,
					base_currency, str(flow.effective_at)) or str(lock.currency) != currency:
				return _error("MISSING_OR_INVALID_FLOW_FX")
			stale_fx = stale_fx or lock.status == "STALE_CONFIRMED"
			expected_base = Decimal.multiply(str(native), str(lock.rate))
		if Decimal.compare(expected_base, str(base)) != 0:
			return _error("FLOW_FX_AMOUNT_MISMATCH")
		used[event_id] = true
		converted.append({"id": event_id, "effective_at": event.effective_at,
			"sequence": event.sequence, "amount_base": Decimal.canonical(str(base)),
			"base_currency": base_currency, "external": true})
	if used.size() != events_by_id.size():
		return _error("INCOMPLETE_EXTERNAL_FLOW_COVERAGE")
	converted.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return _compare_point(a.effective_at, int(a.sequence),
			b.effective_at, int(b.sequence)) < 0)
	return {"ok": true, "flows": converted, "stale_fx": stale_fx}


static func _valid_fx(value: Dictionary, base_currency: String, as_of: String) -> bool:
	return not str(value.get("id", "")).is_empty() and \
		_currency(str(value.get("currency", ""))) and \
		str(value.get("currency", "")) != base_currency and \
		str(value.get("base_currency", "")) == base_currency and \
		typeof(value.get("rate", null)) == TYPE_STRING and \
		Decimal.is_valid(value.rate) and Decimal.compare(value.rate, "0") > 0 and \
		QuoteContract.utc_unix(str(value.get("quoted_at", ""))) >= 0 and \
		str(value.quoted_at) <= as_of and not str(value.get("source", "")).is_empty() and \
		["CURRENT", "STALE_CONFIRMED"].has(value.get("status", ""))


static func _is_complete(snapshot: Dictionary) -> bool:
	return snapshot.get("coverage", {}).get("status", "") == "COMPLETE"


static func _analytic_point(snapshot: Dictionary) -> Dictionary:
	return {"at": snapshot.at, "sequence": snapshot.ledger_event_sequence,
		"asset_total": Decimal.canonical(str(snapshot.asset_total)),
		"base_currency": snapshot.base_currency, "complete": true}


static func _compare_point(at_a: String, sequence_a: int,
		at_b: String, sequence_b: int) -> int:
	if at_a != at_b:
		return -1 if at_a < at_b else 1
	if sequence_a == sequence_b:
		return 0
	return -1 if sequence_a < sequence_b else 1


static func _hash(value: String) -> bool:
	if value.length() != 64:
		return false
	for index in value.length():
		var digit := value.substr(index, 1)
		if not ((digit >= "0" and digit <= "9") or (digit >= "a" and digit <= "f")):
			return false
	return true


static func _currency(value: String) -> bool:
	if value.length() != 3:
		return false
	for index in 3:
		var letter := value.substr(index, 1)
		if letter < "A" or letter > "Z":
			return false
	return true


static func _unavailable(code: String, points: Array) -> Dictionary:
	return {"ok": false, "status": "UNAVAILABLE", "error": code,
		"recorded_points": points}


static func _error(code: String) -> Dictionary:
	return {"ok": false, "error": code}
