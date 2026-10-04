extends SceneTree

const Reconcile = preload("res://scripts/reconciliation/reconciliation_service.gd")
const Ledger = preload("res://scripts/data/ledger_core.gd")
const Store = preload("res://scripts/data/project_store.gd")
const CsvImport = preload("res://scripts/import/csv_import_service.gd")

const T0 := "2026-01-01T00:00:00Z"
const T1 := "2026-02-01T00:00:00Z"
const T2 := "2026-03-01T00:00:00Z"

var checks := 0
var failures: Array[String] = []


func _initialize() -> void:
	_test_match_differences_and_missing()
	_test_duplicates_and_input_types()
	_test_csv_imported_cash()
	_test_aggregate_requires_detail()
	if failures.is_empty():
		print("RECONCILIATION TESTS PASS: %d checks" % checks)
		quit(0)
	else:
		for failure in failures:
			printerr(failure)
		printerr("RECONCILIATION TESTS FAIL: %d failures in %d checks" % [failures.size(), checks])
		quit(1)


func _check(condition: bool, label: String) -> void:
	checks += 1
	if not condition:
		failures.append(label)


func _step(state: Dictionary, command: Dictionary) -> Dictionary:
	var applied := Ledger.apply(state, command)
	if not applied.ok:
		failures.append("fixture command failed: " + str(applied.get("error", "")))
		return state
	return applied.state


func _ledger() -> Dictionary:
	var state := Ledger.new_state()
	state = _step(state, {"command_id": "account-cny", "type": "account_create",
		"account": {"id": "broker", "currency": "CNY", "mode": "detail", "cost_method": "FIFO"}})
	state = _step(state, {"command_id": "account-usd", "type": "account_create",
		"account": {"id": "usd", "currency": "USD", "mode": "detail", "cost_method": "FIFO"}})
	state = _step(state, {"command_id": "instrument", "type": "instrument_create",
		"instrument": {"id": "stock", "kind": "STOCK", "market": "TEST",
			"symbol": "ZZZ", "currency": "CNY"}})
	state = _step(state, {"command_id": "open-cny", "type": "opening_cash",
		"account_id": "broker", "amount": "1000", "effective_at": T0})
	state = _step(state, {"command_id": "open-usd", "type": "opening_cash",
		"account_id": "usd", "amount": "100", "effective_at": T0})
	state = _step(state, {"command_id": "buy-stock", "type": "buy",
		"account_id": "broker", "instrument_id": "stock", "quantity": "2",
		"unit_price": "100", "fee": "5", "effective_at": T1})
	return state


func _statement(ledger: Dictionary) -> Dictionary:
	return {"schema_version": 1, "ledger_hash": Store.canonical_ledger_hash(ledger),
		"as_of": T2, "pending_settlements": {"status": "NONE"},
		"cash_balances": [
			{"account_id": "broker", "currency": "CNY", "amount": "795"},
			{"account_id": "usd", "currency": "USD", "amount": "100"}],
		"positions": [{"account_id": "broker", "instrument_id": "stock", "quantity": "2"}],
		"fees": [{"event_id": "buy-stock", "currency": "CNY", "amount": "5"}],
		"account_total_checkpoints": [{"account_id": "broker", "currency": "CNY",
			"amount": "995"}]}


func _test_match_differences_and_missing() -> void:
	var ledger := _ledger()
	var before := JSON.stringify(ledger)
	var statement := _statement(ledger)
	var matched := Reconcile.compare(ledger, statement)
	_check(matched.ok and matched.status == "MATCHED" and not matched.full_reconciliation \
		and matched.differences.is_empty() and matched.scope == "CASH_ACTIVE_POSITIONS_RECORDED_TRADE_FEES",
		"supported cash, holdings and recorded fees match without claiming full reconciliation")
	_check(matched.cash_by_currency.CNY.ledger_amount == "795" \
		and matched.cash_by_currency.USD.statement_amount == "100" \
		and matched.unverified_account_totals[0].status == "UNVERIFIED",
		"per-currency cash and broker total checkpoint remain separate")
	_check(JSON.stringify(ledger) == before and Ledger.project(ledger).cash.broker == "795",
		"matching is read-only")
	var changed := statement.duplicate(true)
	changed.cash_balances[0].amount = "794.90"
	changed.positions[0].quantity = "1.5"
	changed.fees[0].amount = "6"
	var differences := Reconcile.compare(ledger, changed)
	_check(differences.ok and differences.status == "DIFFERENCE" \
		and differences.differences.size() == 3,
		"cash, holding and fee differences all reported")
	_check(differences.differences[0].kind == "CASH" \
		and differences.differences[0].difference == "-0.1" \
		and differences.differences[1].kind == "POSITION" \
		and differences.differences[1].difference == "-0.5" \
		and differences.differences[2].kind == "RECORDED_TRADE_FEE" \
		and differences.differences[2].difference == "1" \
		and not differences.has("realized_gain"),
		"differences are exact decimal strings and never booked as income")
	_check(JSON.stringify(ledger) == before and Ledger.project(ledger).cash.broker == "795",
		"difference report does not adjust ledger cash or holdings")
	var missing_cash := statement.duplicate(true)
	missing_cash.cash_balances.pop_back()
	var incomplete := Reconcile.compare(ledger, missing_cash)
	_check(incomplete.ok and incomplete.status == "INSUFFICIENT_DATA" \
		and incomplete.missing.has("CASH:usd") and incomplete.differences.is_empty(),
		"missing account cash yields insufficient data rather than a false match")
	var missing_holding := statement.duplicate(true)
	missing_holding.positions.clear()
	_check(Reconcile.compare(ledger, missing_holding).missing.has("POSITION:broker|stock"),
		"missing active holding yields insufficient data")
	var missing_fee := statement.duplicate(true)
	missing_fee.fees.clear()
	_check(Reconcile.compare(ledger, missing_fee).missing.has("FEE:buy-stock"),
		"missing recorded fee yields insufficient data")
	var unknown_settlement := statement.duplicate(true)
	unknown_settlement.pending_settlements = {"status": "UNKNOWN"}
	_check(Reconcile.compare(ledger, unknown_settlement).reasons.has("PENDING_SETTLEMENT_NOT_RECONCILABLE"),
		"unknown settlement is explicitly insufficient")
	var missing_settlement := statement.duplicate(true)
	missing_settlement.erase("pending_settlements")
	_check(Reconcile.compare(ledger, missing_settlement).reasons.has("SETTLEMENT_STATUS_MISSING"),
		"missing settlement status is explicitly insufficient")
	var early := statement.duplicate(true)
	early.as_of = T0
	_check(Reconcile.compare(ledger, early).reasons.has("STATEMENT_BEFORE_LEDGER_EVENT"),
		"statement before trade cannot reconcile current ledger")
	var stale := statement.duplicate(true)
	stale.ledger_hash = "0".repeat(64)
	_check(Reconcile.compare(ledger, stale).reasons.has("LEDGER_VERSION_MISMATCH"),
		"statement mapping for another ledger revision rejected")
	_check(JSON.stringify(ledger) == before, "all incomplete cases leave ledger unchanged")


func _test_duplicates_and_input_types() -> void:
	var ledger := _ledger()
	var original := JSON.stringify(ledger)
	var statement := _statement(ledger)
	var duplicated := statement.duplicate(true)
	duplicated.cash_balances.append(duplicated.cash_balances[0].duplicate(true))
	_check(Reconcile.compare(ledger, duplicated).error == "DUPLICATE_CASH_ACCOUNT",
		"duplicate account cash row rejected")
	duplicated = statement.duplicate(true)
	duplicated.positions.append(duplicated.positions[0].duplicate(true))
	_check(Reconcile.compare(ledger, duplicated).error == "DUPLICATE_POSITION",
		"duplicate holding row rejected")
	duplicated = statement.duplicate(true)
	duplicated.fees.append(duplicated.fees[0].duplicate(true))
	_check(Reconcile.compare(ledger, duplicated).error == "DUPLICATE_FEE_EVENT",
		"duplicate fee event row rejected")
	var float_amount := statement.duplicate(true)
	float_amount.cash_balances[0].amount = 795.0
	_check(Reconcile.compare(ledger, float_amount).error == "INVALID_CASH_ROW",
		"financial float in statement rejected")
	var unknown_position := statement.duplicate(true)
	unknown_position.positions[0].instrument_id = "unmapped"
	_check(Reconcile.compare(ledger, unknown_position).reasons.has("UNMAPPED_OR_INACTIVE_POSITION"),
		"unmapped security is insufficient, not inferred as profit")
	_check(JSON.stringify(ledger) == original, "invalid rows never mutate ledger")


func _test_csv_imported_cash() -> void:
	var ledger := Ledger.new_state()
	ledger = _step(ledger, {"command_id": "csv-account", "type": "account_create",
		"account": {"id": "cash", "currency": "CNY", "mode": "detail", "cost_method": "FIFO"}})
	ledger = _step(ledger, {"command_id": "csv-opening", "type": "opening_cash",
		"account_id": "cash", "amount": "100", "effective_at": T0})
	var csv := "event,account,date,change,external\n" + \
		"cash_delta,Wallet,2026-02-01T00:00:00Z,5,false\n"
	var mapping := {"column_map": {"type": "event", "account": "account",
		"effective_at": "date", "delta": "change", "external": "external"},
		"account_ids": {"Wallet": "cash"}, "instrument_ids": {}}
	var preview := CsvImport.preview_csv(ledger, csv, mapping)
	_check(preview.ok, "CSV import preview fixture")
	if not preview.ok:
		return
	var imported := CsvImport.confirm(ledger, csv, mapping, preview,
		{"confirmed": true, "content_sha256": preview.content_sha256})
	_check(imported.ok and imported.projection.cash.cash == "105", "CSV cash delta committed")
	if not imported.ok:
		return
	var imported_before := JSON.stringify(imported.state)
	var statement := {"schema_version": 1, "ledger_hash": Store.canonical_ledger_hash(imported.state),
		"as_of": T2, "pending_settlements": {"status": "NONE"},
		"cash_balances": [{"account_id": "cash", "currency": "CNY", "amount": "105"}],
		"positions": [], "fees": []}
	var result := Reconcile.compare(imported.state, statement)
	_check(result.ok and result.status == "MATCHED" and result.cash_by_currency.CNY.ledger_amount == "105",
		"confirmed CSV event participates in read-only cash reconciliation")
	_check(JSON.stringify(imported.state) == imported_before and JSON.stringify(ledger) != imported_before,
		"reconciliation leaves imported ledger and prior source untouched")


func _test_aggregate_requires_detail() -> void:
	var ledger := Ledger.new_state()
	ledger = _step(ledger, {"command_id": "aggregate", "type": "account_create",
		"account": {"id": "summary", "currency": "CNY", "mode": "aggregate", "cost_method": "FIFO"}})
	ledger = _step(ledger, {"command_id": "aggregate-opening", "type": "opening_cash",
		"account_id": "summary", "amount": "1000", "effective_at": T0})
	var statement := {"schema_version": 1, "ledger_hash": Store.canonical_ledger_hash(ledger),
		"as_of": T2, "pending_settlements": {"status": "NONE"},
		"cash_balances": [{"account_id": "summary", "currency": "CNY", "amount": "1000"}],
		"positions": [], "fees": []}
	_check(Reconcile.compare(ledger, statement).reasons.has("AGGREGATE_BALANCE_NOT_CASH"),
		"aggregate balance cannot be silently treated as detail cash")
