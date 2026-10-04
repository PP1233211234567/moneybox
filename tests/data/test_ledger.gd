extends SceneTree

const Ledger = preload("res://scripts/data/ledger_core.gd")
var failures := 0

func _initialize() -> void:
	_test_t01()
	_test_t02()
	_test_t03("FIFO", "2000", "2000")
	_test_t03("MOVING_AVERAGE", "1500", "1500")
	_test_t04()
	_test_t05()
	_test_t06()
	_test_t08()
	_test_financial_input_types()
	print("ledger: %s" % ("passed" if failures == 0 else "%d failures" % failures))
	quit(0 if failures == 0 else 1)


func _step(state: Dictionary, command: Dictionary) -> Dictionary:
	var result: Dictionary = Ledger.apply(state, command)
	if not result.ok:
		printerr("command failed: ", command.get("command_id"), " ", result.error)
		failures += 1
		return state
	return result.state


func _equal(actual: Variant, expected: Variant, label: String) -> void:
	if actual != expected:
		printerr(label, ": got ", actual, " expected ", expected)
		failures += 1


func _account(state: Dictionary, account_id: String, method: String = "FIFO", mode: String = "detail") -> Dictionary:
	return _step(state, {"command_id": "account-" + account_id, "type": "account_create", "account": {"id": account_id, "currency": "CNY", "mode": mode, "cost_method": method}})


func _instrument(state: Dictionary) -> Dictionary:
	return _step(state, {"command_id": "instrument-stock", "type": "instrument_create", "instrument": {"id": "stock", "symbol": "TEST", "market": "TEST", "currency": "CNY"}})


func _opening(state: Dictionary, account_id: String, amount: String) -> Dictionary:
	return _step(state, {"command_id": "opening-" + account_id, "type": "opening_cash", "account_id": account_id, "amount": amount, "effective_at": "2026-01-01T00:00:00Z"})


func _test_t01() -> void:
	var state := Ledger.new_state()
	state = _account(state, "cash")
	state = _instrument(state)
	state = _opening(state, "cash", "10000")
	state = _step(state, {"command_id": "buy-t01", "type": "buy", "account_id": "cash", "instrument_id": "stock", "quantity": "10", "unit_price": "800", "fee": "10", "effective_at": "2026-02-01T00:00:00Z"})
	state = _step(state, {"command_id": "quote-t01", "type": "quote_update", "quote": {"instrument_id": "stock", "price": "800", "quoted_at": "2026-02-01T12:00:00Z", "source": "manual-test"}})
	var view := Ledger.project(state)
	_equal(view.cash.cash, "1990", "T01 cash")
	_equal(view.positions["cash|stock"].cost, "8010", "T01 cost")
	_equal(view.asset_total, "9990", "T01 assets")
	var replay := Ledger.apply(state, {"command_id": "quote-t01", "type": "quote_update", "quote": {"instrument_id": "stock", "price": "800", "quoted_at": "2026-02-01T12:00:00Z", "source": "manual-test"}})
	_equal(replay.duplicate, true, "quote idempotency")
	_equal(replay.state.quote_history.size(), 1, "quote replay history")


func _test_t02() -> void:
	var state := Ledger.new_state()
	state = _account(state, "a")
	state = _account(state, "b")
	state = _opening(state, "a", "10000")
	state = _step(state, {"command_id": "transfer-t02", "type": "transfer", "account_id": "a", "to_account_id": "b", "amount": "1000", "effective_at": "2026-02-01T00:00:00Z"})
	var view := Ledger.project(state)
	_equal(view.cash.a, "9000", "T02 source")
	_equal(view.cash.b, "1000", "T02 destination")
	_equal(view.asset_total, "10000", "T02 assets")
	_equal(view.external_net_invested, "0", "T02 external flow")


func _test_t03(method: String, realized: String, remaining: String) -> void:
	var state := Ledger.new_state()
	state = _account(state, "trade", method)
	state = _instrument(state)
	state = _opening(state, "trade", "10000")
	state = _step(state, {"command_id": "buy-1", "type": "buy", "account_id": "trade", "instrument_id": "stock", "quantity": "10", "unit_price": "100", "fee": "0", "effective_at": "2026-02-01T00:00:00Z"})
	state = _step(state, {"command_id": "buy-2", "type": "buy", "account_id": "trade", "instrument_id": "stock", "quantity": "10", "unit_price": "200", "fee": "0", "effective_at": "2026-02-02T00:00:00Z"})
	state = _step(state, {"command_id": "sell-1", "type": "sell", "account_id": "trade", "instrument_id": "stock", "quantity": "10", "unit_price": "300", "fee": "0", "effective_at": "2026-02-03T00:00:00Z"})
	var position: Dictionary = Ledger.project(state).positions["trade|stock"]
	_equal(position.realized_gain, realized, "T03 " + method + " realized")
	_equal(position.cost, remaining, "T03 " + method + " remaining")


func _test_t04() -> void:
	var state := Ledger.new_state()
	state = _account(state, "a")
	state = _instrument(state)
	state = _opening(state, "a", "10000")
	state = _step(state, {"command_id": "recent-quote", "type": "quote_update", "quote": {"instrument_id": "stock", "price": "200", "quoted_at": "2026-09-26T12:00:00Z", "source": "manual-test"}})
	state = _step(state, {"command_id": "old-buy", "type": "buy", "account_id": "a", "instrument_id": "stock", "quantity": "10", "unit_price": "100", "fee": "0", "effective_at": "2026-02-01T00:00:00Z"})
	_equal(state.quotes.stock.price, "200", "T04 quote retained")
	_equal(Ledger.project(state).asset_total, "11000", "T04 current valuation")


func _test_t05() -> void:
	var state := Ledger.new_state()
	state = _account(state, "summary", "FIFO", "aggregate")
	state = _instrument(state)
	state = _opening(state, "summary", "100000")
	state = _step(state, {"command_id": "replace-summary", "type": "aggregate_replace", "account_id": "summary", "effective_at": "2026-02-01T00:00:00Z", "detail_accounts": [
		{"account": {"id": "detail-cash", "currency": "CNY", "mode": "detail", "cost_method": "FIFO"}, "opening_amount": "40000"},
		{"account": {"id": "detail-investment", "currency": "CNY", "mode": "detail", "cost_method": "FIFO"}, "opening_amount": "0", "opening_positions": [{"instrument_id": "stock", "quantity": "100", "reference_price": "600"}]},
	]})
	var view := Ledger.project(state)
	_equal(view.asset_total, "100000", "T05 no double count")
	_equal(view.cash["detail-cash"], "40000", "T05 detail cash")
	_equal(view.positions["detail-investment|stock"].quantity, "100", "T05 holdings")
	_equal(view.positions["detail-investment|stock"].cost_known, false, "T05 unknown cost not fabricated")


func _test_t06() -> void:
	var state := Ledger.new_state()
	state = _account(state, "a")
	state = _opening(state, "a", "100")
	state = _step(state, {"command_id": "fix-opening", "type": "void_replace", "target_event_id": "opening-a", "effective_at": "2026-02-01T00:00:00Z", "replacement": {"type": "opening_cash", "account_id": "a", "amount": "80", "effective_at": "2026-01-01T00:00:00Z"}})
	_equal(Ledger.project(state).cash.a, "80", "T06 cash")
	_equal(state.events.size(), 3, "T06 audit events")


func _test_t08() -> void:
	var state := Ledger.new_state()
	state = _account(state, "dividend")
	state = _instrument(state)
	state = _opening(state, "dividend", "1000")
	var suggestion := {"command_id": "dividend-suggestion", "type": "dividend_suggest", "account_id": "dividend", "instrument_id": "stock", "gross_amount": "0100.00", "source": "manual-test", "effective_at": "2026-02-01T00:00:00Z"}
	state = _step(state, suggestion)
	var suggested := Ledger.project(state)
	_equal(suggested.cash.dividend, "1000", "T08 suggestion has no cash effect")
	_equal(suggested.asset_total, "1000", "T08 suggestion has no asset effect")
	_equal(suggested.dividends["dividend-suggestion"].status, "suggested", "T08 suggestion status")
	_equal(suggested.dividends["dividend-suggestion"].suggested_gross, "100", "T08 suggested gross canonical")
	_equal(suggested.dividend_totals_by_currency.is_empty(), true, "T08 suggestion has no income or tax")
	var float_suggestion := suggestion.duplicate(true)
	float_suggestion.command_id = "float-suggestion"
	float_suggestion.gross_amount = 100.0
	_equal(Ledger.apply(state, float_suggestion).error, "INVALID_DIVIDEND_SUGGESTION", "T08 financial float rejected")
	var invalid_confirmation := {"command_id": "invalid-dividend-confirmation", "type": "dividend_confirm", "suggestion_event_id": "dividend-suggestion", "gross_amount": "100", "withholding_tax": "101", "effective_at": "2026-02-02T00:00:00Z"}
	_equal(Ledger.apply(state, invalid_confirmation).error, "INVALID_DIVIDEND_AMOUNT", "T08 tax cannot exceed gross")
	var confirmation := {"command_id": "dividend-confirmation", "type": "dividend_confirm", "suggestion_event_id": "dividend-suggestion", "gross_amount": "100", "withholding_tax": "10", "effective_at": "2026-02-02T00:00:00Z"}
	state = _step(state, confirmation)
	var confirmed := Ledger.project(state)
	_equal(confirmed.cash.dividend, "1090", "T08 confirmed net cash")
	_equal(confirmed.asset_total, "1090", "T08 confirmed assets")
	_equal(confirmed.external_net_invested, "0", "T08 dividend is not external savings")
	_equal(confirmed.dividends["dividend-suggestion"].status, "confirmed", "T08 confirmed status")
	_equal(confirmed.dividends["dividend-suggestion"].source, "manual-test", "T08 source audit")
	_equal(confirmed.dividends["dividend-suggestion"].confirmation_event_id, "dividend-confirmation", "T08 confirmation link")
	_equal(confirmed.dividend_totals_by_currency.CNY.gross_income, "100", "T08 gross income")
	_equal(confirmed.dividend_totals_by_currency.CNY.withholding_tax, "10", "T08 withholding tax")
	_equal(confirmed.dividend_totals_by_currency.CNY.net_cash, "90", "T08 net cash projection")
	_equal(state.events[-1].net_cash, "90", "T08 auditable net cash event")
	var replay := Ledger.apply(state, confirmation)
	_equal(replay.duplicate, true, "T08 command replay is idempotent")
	_equal(replay.state.events.size(), 3, "T08 command replay has no event")
	var second_confirmation := confirmation.duplicate(true)
	second_confirmation.command_id = "second-dividend-confirmation"
	_equal(Ledger.apply(state, second_confirmation).error, "DIVIDEND_ALREADY_CONFIRMED", "T08 second confirmation blocked")
	var unsupported_void := {"command_id": "void-dividend", "type": "void_replace", "target_event_id": "dividend-confirmation", "effective_at": "2026-02-03T00:00:00Z", "replacement": {"type": "opening_cash", "account_id": "dividend", "amount": "1000", "effective_at": "2026-01-01T00:00:00Z"}}
	_equal(Ledger.apply(state, unsupported_void).error, "UNSUPPORTED_REPLACEMENT", "T08 dividend cannot be rewritten as opening cash")
	_equal(Ledger.project(state).cash.dividend, "1090", "T08 rejected second confirmation has no cash effect")


func _test_financial_input_types() -> void:
	var state := Ledger.new_state()
	state = _account(state, "typed")
	state = _account(state, "other")
	state = _instrument(state)
	state = _opening(state, "typed", "1000")
	var invalid_commands := [
		{"command_id": "float-opening", "type": "opening_cash", "account_id": "typed", "amount": 1.25, "effective_at": "2026-02-01T00:00:00Z"},
		{"command_id": "float-delta", "type": "cash_delta", "account_id": "typed", "delta": 1.25, "effective_at": "2026-02-01T00:00:00Z"},
		{"command_id": "float-transfer", "type": "transfer", "account_id": "typed", "to_account_id": "other", "amount": 1.25, "effective_at": "2026-02-01T00:00:00Z"},
		{"command_id": "float-buy", "type": "buy", "account_id": "typed", "instrument_id": "stock", "quantity": 1.25, "unit_price": "10", "fee": "0", "effective_at": "2026-02-01T00:00:00Z"},
		{"command_id": "float-price", "type": "quote_update", "quote": {"instrument_id": "stock", "price": 1.25, "quoted_at": "2026-02-01T00:00:00Z", "source": "manual-test"}},
		{"command_id": "float-fx", "type": "fx_update", "fx": {"currency": "USD", "rate_to_base": 7.25, "quoted_at": "2026-02-01T00:00:00Z", "source": "manual-test"}},
		{"command_id": "float-position", "type": "opening_position", "account_id": "typed", "instrument_id": "stock", "quantity": "2", "reference_price": "10", "cost_basis": 20.0, "effective_at": "2026-02-01T00:00:00Z"},
	]
	var expected_errors := ["INVALID_AMOUNT", "INVALID_AMOUNT", "INVALID_TRANSFER", "INVALID_TRADE", "INVALID_QUOTE", "INVALID_FX", "INVALID_OPENING_POSITION"]
	for index in invalid_commands.size():
		var rejected := Ledger.apply(state, invalid_commands[index])
		_equal(rejected.ok, false, "financial float rejected " + str(index))
		_equal(rejected.get("error", ""), expected_errors[index], "financial float error " + str(index))
	_equal(Ledger.project(state).cash.typed, "1000", "financial float rejection leaves original state")
