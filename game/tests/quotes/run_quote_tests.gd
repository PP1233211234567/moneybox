extends SceneTree

const Contract = preload("res://scripts/quotes/quote_contract.gd")
const Gateway = preload("res://scripts/quotes/quote_gateway.gd")
const ManualProvider = preload("res://scripts/quotes/manual_quote_provider.gd")
const Valuation = preload("res://scripts/quotes/valuation_batch_service.gd")

const T0 := "2026-09-27T01:00:00Z"
const T1 := "2026-09-27T01:02:00Z"
const T2 := "2026-09-27T01:06:00Z"
const T3 := "2026-09-27T01:12:00Z"

var checks := 0
var failures: Array[String] = []


func _initialize() -> void:
	_test_identity_and_validation()
	_test_batch_cache_and_valuation()
	_test_failure_fallback()
	if failures.is_empty():
		print("QUOTE TESTS PASS: %d checks" % checks)
		quit(0)
	else:
		for failure in failures:
			printerr(failure)
		printerr("QUOTE TESTS FAIL: %d failures in %d checks" % [failures.size(), checks])
		quit(1)


func _test_identity_and_validation() -> void:
	var a := _identity("ETF", "NASDAQ", "VOO", "USD")
	var b := _identity("ETF", "NYSE", "VOO", "USD")
	var c := _identity("ETF", "NASDAQ", "VOO", "HKD")
	var d := _identity("FUND", "NASDAQ", "VOO", "USD", "A")
	_check(Contract.identity_key(a) != Contract.identity_key(b)
		and Contract.identity_key(a) != Contract.identity_key(c)
		and Contract.identity_key(a) != Contract.identity_key(d),
		"market, currency, asset class, share class distinguish identities")
	_check(Contract.identity_key(_identity("FX", "FX", "USD/CNY", "USD")) == "",
		"FX output currency must match pair")
	_check(Contract.utc_unix("2026-02-30T01:00:00Z") < 0,
		"invalid UTC calendar date rejected")
	var good := _quote(a, "10", T0, T0)
	_check(Contract.validate_quote(good, a, T0).ok, "manual quote has complete provenance")
	var claimed_live := good.duplicate(true)
	claimed_live.source = "CLAIMED_LIVE"
	claimed_live.delay = "REALTIME"
	var manual_response := ManualProvider.new({Contract.identity_key(a): claimed_live}).fetch_quotes([a], T0)
	_check(manual_response.quotes[Contract.identity_key(a)].source == "USER_MANUAL"
		and manual_response.quotes[Contract.identity_key(a)].delay == "MANUAL",
		"manual adapter cannot label supplied values as live market data")
	for bad_price in ["0", "-1", "NaN", "1e3", "1,000"]:
		var bad := good.duplicate(true)
		bad.price = bad_price
		_check(not Contract.validate_quote(bad, a, T0).ok,
			"invalid price rejected: " + bad_price)
	var wrong_unit := good.duplicate(true)
	wrong_unit.unit = "CURRENCY_PER_GRAM"
	_check(not Contract.validate_quote(wrong_unit, a, T0).ok,
		"security quote with gold unit rejected")
	var no_time := good.duplicate(true)
	no_time.erase("quoted_at")
	_check(not Contract.validate_quote(no_time, a, T0).ok,
		"actual quote time cannot be replaced by fetch time")
	var malformed_identity := good.duplicate(true)
	malformed_identity.identity = "VOO"
	_check(Contract.validate_quote(malformed_identity, a, T0).error == "IDENTITY_MISMATCH",
		"malformed provider identity returns a contract error")
	var malformed_state := Gateway.refresh({"schema_version": 1, "cache": [], "batches": {}},
		[a], ManualProvider.new(), T0, "bad-state")
	_check(not malformed_state.ok and malformed_state.error == "INVALID_STATE",
		"malformed persisted cache returns an error")


func _test_batch_cache_and_valuation() -> void:
	var identities := _full_request()
	var quotes := _quote_map(identities, "10", T0, T0)
	var provider := ManualProvider.new(quotes)
	var duplicate_request := identities.duplicate(true)
	duplicate_request.append(identities[0].duplicate(true))
	var first := Gateway.refresh(Gateway.new_state(), duplicate_request, provider, T0, "batch-1")
	_check(first.ok and first.batch.status == "COMPLETE"
		and first.batch.requested_symbols.size() == 24
		and first.batch.success_symbols.size() == 24, "T37 completed 20+3+gold batch")
	_check(provider.fetch_calls == 1 and provider.requested_keys.size() == 24,
		"T37 one adapter batch call and one fetch per identity")
	var replay := Gateway.refresh(first.state, identities, provider, T1, "batch-1")
	_check(replay.ok and replay.duplicate and replay.batch.completed_at == T0
		and provider.fetch_calls == 1, "same batch ID returns immutable prior result")
	var persisted_quote_state: Dictionary = JSON.parse_string(JSON.stringify(first.state))
	var replay_after_reload := Gateway.refresh(persisted_quote_state, identities,
		provider, T1, "batch-1")
	_check(replay_after_reload.ok and replay_after_reload.duplicate
		and provider.fetch_calls == 1, "quote batch ID survives state serialization")
	var conflicting_batch_id := Gateway.refresh(first.state, [identities[0]],
		provider, T1, "batch-1")
	_check(not conflicting_batch_id.ok and conflicting_batch_id.error == "BATCH_ID_CONFLICT",
		"batch ID cannot be reused for a different request set")
	var within_window := Gateway.refresh(first.state, identities, provider, T1, "batch-2")
	_check(within_window.ok and within_window.batch.status == "COMPLETE"
		and provider.fetch_calls == 1, "new batch within cache window has no provider request")
	var every_hit := true
	for entry in within_window.batch.entries.values():
		if not entry.cache_hit:
			every_hit = false
	_check(every_hit, "T37 every cached quote retains source and timestamps")
	var positions: Array = []
	for i in 5:
		positions.append({"position_id": "p-%02d" % i, "identity": identities[i],
			"quantity": "2"})
	var cash := [{"balance_id": "cash-cny", "currency": "CNY", "amount": "300"}]
	var valuation := Valuation.create_snapshot(Valuation.new_state(), first.batch,
		positions, cash, "CNY")
	_check(valuation.ok and valuation.snapshot.asset_total == "1000"
		and valuation.snapshot.quote_batch_id == "batch-1"
		and valuation.snapshot.position_values.size() == 5,
		"T37 five USD holdings and CNY cash give one locked valuation")
	var repeated := Valuation.create_snapshot(valuation.state, first.batch,
		positions, cash, "CNY", false, 0)
	_check(repeated.ok and repeated.duplicate and repeated.state.revision == 1
		and repeated.snapshot.id == valuation.snapshot.id,
		"T07/T37 batch replay makes at most one snapshot")
	var restored: Dictionary = JSON.parse_string(JSON.stringify(valuation.state))
	var repeated_after_reload := Valuation.create_snapshot(restored, first.batch,
		positions, cash, "CNY")
	_check(repeated_after_reload.ok and repeated_after_reload.duplicate
		and repeated_after_reload.state.revision == 1,
		"persisted valuation state remains idempotent after serialization")
	var edited_positions := positions.duplicate(true)
	edited_positions[0].quantity = "3"
	var conflict := Valuation.create_snapshot(valuation.state, first.batch,
		edited_positions, cash, "CNY")
	_check(not conflict.ok and conflict.error == "BATCH_INPUT_CONFLICT",
		"same batch cannot value changed holdings as second snapshot")
	var malformed_position := Valuation.create_snapshot(Valuation.new_state(), first.batch,
		[{"position_id": "bad", "identity": "TEST00", "quantity": "2"}], cash, "CNY")
	_check(not malformed_position.ok and malformed_position.error == "INVALID_POSITION",
		"malformed local holding input returns an error")
	var stock_only := Gateway.refresh(Gateway.new_state(), [identities[0]],
		ManualProvider.new({Contract.identity_key(identities[0]): quotes[Contract.identity_key(identities[0])]}),
		T0, "stock-only")
	var no_fx := Valuation.create_snapshot(Valuation.new_state(), stock_only.batch,
		[positions[0]], cash, "CNY")
	_check(not no_fx.ok and no_fx.error == "MISSING_OR_INVALID_FX",
		"missing FX never silently uses rate one or zero")
	var tampered: Dictionary = first.batch.duplicate(true)
	tampered.entries.erase(Contract.identity_key(_identity("FX", "FX", "USD/CNY", "CNY")))
	var tampered_result := Valuation.create_snapshot(Valuation.new_state(), tampered,
		positions, cash, "CNY")
	_check(not tampered_result.ok and tampered_result.error == "INVALID_BATCH",
		"complete batch label cannot hide a missing requested quote")


func _test_failure_fallback() -> void:
	var identities := _full_request()
	var initial := Gateway.refresh(Gateway.new_state(), identities,
		ManualProvider.new(_quote_map(identities, "10", T0, T0)), T0, "seed")
	var failed_key := Contract.identity_key(identities[0])
	var new_quotes := _quote_map(identities, "11", T2, T2)
	var provider := ManualProvider.new(new_quotes, {failed_key: "TIMEOUT"})
	var batch_result := Gateway.refresh(initial.state, identities, provider, T2, "with-timeout")
	_check(batch_result.ok and batch_result.batch.status == "COMPLETE_WITH_STALE"
		and batch_result.batch.stale_symbols == [failed_key]
		and batch_result.batch.entries[failed_key].quote.quoted_at == T0
		and batch_result.batch.entries[failed_key].quote.price == "10",
		"T07 failed item retains old price and actual quote time")
	var positions: Array = []
	for i in 5:
		positions.append({"position_id": "p-%02d" % i, "identity": identities[i],
			"quantity": "2"})
	var cash := [{"balance_id": "cash-cny", "currency": "CNY", "amount": "300"}]
	var blocked := Valuation.create_snapshot(Valuation.new_state(), batch_result.batch,
		positions, cash, "CNY")
	_check(not blocked.ok and blocked.error == "STALE_CONFIRMATION_REQUIRED",
		"stale fallback requires explicit confirmation before valuation")
	var accepted := Valuation.create_snapshot(Valuation.new_state(), batch_result.batch,
		positions, cash, "CNY", true)
	_check(accepted.ok and accepted.snapshot.asset_total == "1056"
		and accepted.snapshot.stale_confirmed,
		"T07 one explicitly approved mixed-time valuation records stale flag")
	var retry := Valuation.create_snapshot(accepted.state, batch_result.batch,
		positions, cash, "CNY", true)
	_check(retry.ok and retry.duplicate and retry.state.revision == 1,
		"T07 stale batch cannot create a second snapshot")
	var bad_quotes := _quote_map(identities, "12", T3, T3)
	bad_quotes[failed_key].price = "0"
	var negative_key := Contract.identity_key(identities[1])
	bad_quotes[negative_key].price = "-1"
	var zero_result := Gateway.refresh(batch_result.state, identities,
		ManualProvider.new(bad_quotes), T3, "invalid-prices")
	_check(zero_result.ok and zero_result.batch.stale_symbols.has(failed_key)
		and zero_result.batch.stale_symbols.has(negative_key)
		and zero_result.batch.entries[failed_key].quote.price == "10"
		and zero_result.batch.entries[negative_key].quote.price == "11",
		"T38 zero and negative new prices use last valid quotes")
	var disabled := ManualProvider.new()
	disabled.enabled = false
	var license_result := Gateway.refresh(zero_result.state, identities, disabled,
		"2026-09-27T01:18:00Z", "license-disabled")
	_check(license_result.ok and license_result.batch.status == "COMPLETE_WITH_STALE"
		and license_result.batch.stale_symbols.size() == 24
		and license_result.batch.entries[failed_key].reason == "LICENSE_DISABLED",
		"T38 disabled provider marks every cached value stale")
	var empty_zero := Gateway.refresh(Gateway.new_state(), [identities[0]],
		ManualProvider.new({failed_key: bad_quotes[failed_key]}), T3, "no-valid-cache")
	_check(empty_zero.ok and empty_zero.batch.status == "INCOMPLETE"
		and empty_zero.batch.failed_symbols == [failed_key],
		"T38 invalid price without cache is incomplete, never zero")
	var refused := Valuation.create_snapshot(Valuation.new_state(), empty_zero.batch,
		[{"position_id": "p", "identity": identities[0], "quantity": "1"}], [], "USD")
	_check(not refused.ok and refused.error == "BATCH_INCOMPLETE",
		"T38 incomplete batch cannot create a valuation snapshot")
	var aged_quote := _quote(identities[0], "10", "2026-09-26T01:00:00Z", T0)
	var aged := Gateway.refresh(Gateway.new_state(), [identities[0]],
		ManualProvider.new({failed_key: aged_quote}), T0, "aged-quote")
	_check(aged.ok and aged.batch.status == "COMPLETE_WITH_STALE"
		and aged.batch.entries[failed_key].status == "STALE"
		and aged.batch.entries[failed_key].quote.fetched_at == T0
		and aged.batch.entries[failed_key].quote.quoted_at != T0,
		"24-hour age threshold uses quoted_at, not fetched_at")


func _full_request() -> Array:
	var requested: Array = []
	for i in 20:
		requested.append(_identity("STOCK", "NASDAQ", "TEST%02d" % i, "USD"))
	for currency in ["USD", "HKD", "EUR"]:
		requested.append(_identity("FX", "FX", currency + "/CNY", "CNY"))
	requested.append(_identity("GOLD", "SPOT", "XAU", "CNY"))
	return requested


func _quote_map(identities: Array, security_price: String,
		quoted_at: String, fetched_at: String) -> Dictionary:
	var result := {}
	for identity in identities:
		var price := security_price
		if identity.kind == "FX":
			price = "7"
		elif identity.kind == "GOLD":
			price = "1000"
		var key := Contract.identity_key(identity)
		result[key] = _quote(identity, price, quoted_at, fetched_at)
	return result


func _identity(kind: String, market: String, symbol: String,
		currency: String, share_class: String = "") -> Dictionary:
	return {"kind": kind, "market": market, "symbol": symbol,
		"currency": currency, "share_class": share_class}


func _quote(identity: Dictionary, price: String, quoted_at: String,
		fetched_at: String) -> Dictionary:
	var unit := "CURRENCY_PER_SHARE"
	if identity.kind == "FX":
		unit = "CURRENCY_PER_FOREIGN_UNIT"
	elif identity.kind == "GOLD":
		unit = "CURRENCY_PER_GRAM"
	return {"id": "manual-" + Contract.identity_key(identity).sha256_text().substr(0, 16)
		+ "-" + quoted_at, "identity": identity.duplicate(true), "price": price,
		"currency": identity.currency, "unit": unit, "source": "USER_MANUAL",
		"provider_symbol": identity.symbol, "quoted_at": quoted_at,
		"fetched_at": fetched_at, "delay": "MANUAL", "session": "MANUAL_INPUT"}


func _check(condition: bool, label: String) -> void:
	checks += 1
	if not condition:
		failures.append("FAIL: " + label)
