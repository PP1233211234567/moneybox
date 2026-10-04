extends RefCounted
## Read-only reconciliation of facts the current LedgerCore can actually prove.
## Broker totals are checkpoints. Differences never become cash, cost, or income events.

const Ledger = preload("res://scripts/data/ledger_core.gd")
const Decimal = preload("res://scripts/data/decimal_text.gd")
const Store = preload("res://scripts/data/project_store.gd")
const TimeContract = preload("res://scripts/quotes/quote_contract.gd")

const FORMAT_VERSION := 1
const SCOPE := "CASH_ACTIVE_POSITIONS_RECORDED_TRADE_FEES"


static func compare(ledger: Dictionary, statement: Dictionary) -> Dictionary:
	if int(statement.get("schema_version", -1)) != FORMAT_VERSION or \
			typeof(statement.get("cash_balances")) != TYPE_ARRAY or \
			typeof(statement.get("positions")) != TYPE_ARRAY or \
			typeof(statement.get("fees")) != TYPE_ARRAY or \
			typeof(statement.get("as_of")) != TYPE_STRING or \
			TimeContract.utc_unix(statement.as_of) < 0:
		return _error("INVALID_STATEMENT")
	var projection := Ledger.project(ledger)
	if not projection.ok:
		return _error("INVALID_LEDGER_PROJECTION")
	if not projection.restricted_balances.is_empty():
		return _insufficient(["RESTRICTED_BALANCE_RECONCILIATION_UNSUPPORTED"])
	var ledger_hash := Store.canonical_ledger_hash(ledger)
	if typeof(statement.get("ledger_hash")) != TYPE_STRING or \
			str(statement.ledger_hash) != ledger_hash:
		return _insufficient(["LEDGER_VERSION_MISMATCH"])
	var statement_unix := TimeContract.utc_unix(statement.as_of)
	for event in ledger.get("events", []):
		var event_unix := TimeContract.utc_unix(str(event.get("effective_at", "")))
		if event_unix < 0:
			return _insufficient(["LEDGER_EVENT_DATE_UNKNOWN"])
		if event_unix > statement_unix:
			return _insufficient(["STATEMENT_BEFORE_LEDGER_EVENT"])
	var settlements_raw: Variant = statement.get("pending_settlements", null)
	if typeof(settlements_raw) != TYPE_DICTIONARY:
		return _insufficient(["SETTLEMENT_STATUS_MISSING"])
	var settlements: Dictionary = settlements_raw
	if settlements.get("status", "") != "NONE":
		return _insufficient(["PENDING_SETTLEMENT_NOT_RECONCILABLE"])
	var expected_cash := {}
	for account_id in ledger.get("accounts", {}):
		if projection.replaced_accounts.has(account_id):
			continue
		var account: Dictionary = ledger.accounts[account_id]
		if account.get("mode", "") != "detail":
			return _insufficient(["AGGREGATE_BALANCE_NOT_CASH"])
		expected_cash[account_id] = {"currency": str(account.currency),
			"amount": str(projection.cash[account_id])}
	var expected_positions := {}
	for key in projection.positions:
		var position: Dictionary = projection.positions[key]
		if position.quantity == "0" or projection.replaced_accounts.has(position.account_id):
			continue
		expected_positions[key] = {"account_id": position.account_id,
			"instrument_id": position.instrument_id, "quantity": position.quantity}
	var expected_fees := _recorded_fees(ledger)
	if not expected_fees.ok:
		return expected_fees
	var cash := _index_cash(statement.cash_balances, expected_cash)
	if not cash.has("rows"):
		return cash
	var positions := _index_positions(statement.positions, expected_positions)
	if not positions.has("rows"):
		return positions
	var fees := _index_fees(statement.fees, expected_fees.rows)
	if not fees.has("rows"):
		return fees
	var checkpoints := _checkpoints(statement.get("account_total_checkpoints", []), ledger.accounts)
	if not checkpoints.has("rows"):
		return checkpoints
	var missing: Array[String] = []
	for account_id in expected_cash:
		if not cash.rows.has(account_id):
			missing.append("CASH:" + str(account_id))
	for key in expected_positions:
		if not positions.rows.has(key):
			missing.append("POSITION:" + str(key))
	for event_id in expected_fees.rows:
		if not fees.rows.has(event_id):
			missing.append("FEE:" + str(event_id))
	if not missing.is_empty():
		missing.sort()
		return _insufficient(["STATEMENT_ROWS_MISSING"], missing, checkpoints.rows)
	var differences := []
	var cash_by_currency := {}
	var account_ids: Array = expected_cash.keys()
	account_ids.sort()
	for account_id in account_ids:
		var expected: Dictionary = expected_cash[account_id]
		var reported: Dictionary = cash.rows[account_id]
		var currency: String = expected.currency
		if not cash_by_currency.has(currency):
			cash_by_currency[currency] = {"ledger_amount": "0", "statement_amount": "0"}
		var totals: Dictionary = cash_by_currency[currency]
		totals.ledger_amount = Decimal.add(totals.ledger_amount, expected.amount)
		totals.statement_amount = Decimal.add(totals.statement_amount, reported.amount)
		cash_by_currency[currency] = totals
		if Decimal.compare(reported.amount, expected.amount) != 0:
			differences.append({"kind": "CASH", "account_id": account_id,
				"currency": currency, "ledger_amount": expected.amount,
				"statement_amount": reported.amount,
				"difference": Decimal.subtract(reported.amount, expected.amount)})
	var position_keys: Array = expected_positions.keys()
	position_keys.sort()
	for key in position_keys:
		var expected: Dictionary = expected_positions[key]
		var reported: Dictionary = positions.rows[key]
		if Decimal.compare(reported.quantity, expected.quantity) != 0:
			differences.append({"kind": "POSITION", "account_id": expected.account_id,
				"instrument_id": expected.instrument_id, "ledger_quantity": expected.quantity,
				"statement_quantity": reported.quantity,
				"difference": Decimal.subtract(reported.quantity, expected.quantity)})
	var fee_ids: Array = expected_fees.rows.keys()
	fee_ids.sort()
	for event_id in fee_ids:
		var expected: Dictionary = expected_fees.rows[event_id]
		var reported: Dictionary = fees.rows[event_id]
		if Decimal.compare(reported.amount, expected.amount) != 0:
			differences.append({"kind": "RECORDED_TRADE_FEE", "event_id": event_id,
				"account_id": expected.account_id, "currency": expected.currency,
				"ledger_amount": expected.amount, "statement_amount": reported.amount,
				"difference": Decimal.subtract(reported.amount, expected.amount)})
	return {"ok": true, "status": "MATCHED" if differences.is_empty() else "DIFFERENCE",
		"scope": SCOPE, "full_reconciliation": false,
		"settlement_basis": "USER_DECLARED_NONE", "ledger_hash": ledger_hash,
		"cash_by_currency": cash_by_currency, "differences": differences,
		"unverified_account_totals": checkpoints.rows,
		"limitations": ["ACCOUNT_TOTAL_REQUIRES_LOCKED_VALUATION",
			"LEDGER_HAS_NO_SETTLEMENT_MODEL"]}


static func _recorded_fees(ledger: Dictionary) -> Dictionary:
	var voided := {}
	for event in ledger.events:
		if event.type == "void":
			voided[str(event.target_event_id)] = true
	var rows := {}
	for event in ledger.events:
		if not ["buy", "sell"].has(event.type) or voided.has(str(event.id)):
			continue
		var amount: Variant = event.get("fee", null)
		if typeof(amount) != TYPE_STRING or not _nonnegative(amount):
			return _error("LEDGER_FEE_INVALID")
		var account: Dictionary = ledger.accounts.get(str(event.account_id), {})
		if account.is_empty():
			return _error("LEDGER_FEE_ACCOUNT_UNKNOWN")
		rows[str(event.id)] = {"account_id": str(event.account_id),
			"currency": str(account.currency), "amount": Decimal.canonical(amount)}
	return {"ok": true, "rows": rows}


static func _index_cash(raw_rows: Array, expected: Dictionary) -> Dictionary:
	var rows := {}
	for raw in raw_rows:
		if typeof(raw) != TYPE_DICTIONARY or typeof(raw.get("account_id")) != TYPE_STRING \
				or typeof(raw.get("currency")) != TYPE_STRING \
				or typeof(raw.get("amount")) != TYPE_STRING or not _nonnegative(raw.amount):
			return _error("INVALID_CASH_ROW")
		var account_id: String = raw.account_id
		if rows.has(account_id):
			return _error("DUPLICATE_CASH_ACCOUNT")
		if not expected.has(account_id) or expected[account_id].currency != raw.currency:
			return _insufficient(["UNMAPPED_CASH_ACCOUNT"])
		rows[account_id] = {"amount": Decimal.canonical(raw.amount)}
	return {"ok": true, "rows": rows}


static func _index_positions(raw_rows: Array, expected: Dictionary) -> Dictionary:
	var rows := {}
	for raw in raw_rows:
		if typeof(raw) != TYPE_DICTIONARY or typeof(raw.get("account_id")) != TYPE_STRING \
				or typeof(raw.get("instrument_id")) != TYPE_STRING \
				or typeof(raw.get("quantity")) != TYPE_STRING or not _nonnegative(raw.quantity):
			return _error("INVALID_POSITION_ROW")
		var key := str(raw.account_id) + "|" + str(raw.instrument_id)
		if rows.has(key):
			return _error("DUPLICATE_POSITION")
		if not expected.has(key):
			return _insufficient(["UNMAPPED_OR_INACTIVE_POSITION"])
		rows[key] = {"quantity": Decimal.canonical(raw.quantity)}
	return {"ok": true, "rows": rows}


static func _index_fees(raw_rows: Array, expected: Dictionary) -> Dictionary:
	var rows := {}
	for raw in raw_rows:
		if typeof(raw) != TYPE_DICTIONARY or typeof(raw.get("event_id")) != TYPE_STRING \
				or typeof(raw.get("currency")) != TYPE_STRING \
				or typeof(raw.get("amount")) != TYPE_STRING or not _nonnegative(raw.amount):
			return _error("INVALID_FEE_ROW")
		var event_id: String = raw.event_id
		if rows.has(event_id):
			return _error("DUPLICATE_FEE_EVENT")
		if not expected.has(event_id) or expected[event_id].currency != raw.currency:
			return _insufficient(["UNMAPPED_FEE_EVENT"])
		rows[event_id] = {"amount": Decimal.canonical(raw.amount)}
	return {"ok": true, "rows": rows}


static func _checkpoints(raw_rows: Variant, accounts: Dictionary) -> Dictionary:
	if typeof(raw_rows) != TYPE_ARRAY:
		return _error("INVALID_ACCOUNT_TOTAL_CHECKPOINTS")
	var rows := []
	var seen := {}
	for raw in raw_rows:
		if typeof(raw) != TYPE_DICTIONARY or typeof(raw.get("account_id")) != TYPE_STRING \
				or typeof(raw.get("currency")) != TYPE_STRING \
				or typeof(raw.get("amount")) != TYPE_STRING or not _nonnegative(raw.amount):
			return _error("INVALID_ACCOUNT_TOTAL_CHECKPOINT")
		var key := str(raw.account_id) + "|" + str(raw.currency)
		if seen.has(key):
			return _error("DUPLICATE_ACCOUNT_TOTAL_CHECKPOINT")
		if not accounts.has(raw.account_id):
			return _insufficient(["UNMAPPED_ACCOUNT_TOTAL_CHECKPOINT"])
		seen[key] = true
		rows.append({"account_id": raw.account_id, "currency": raw.currency,
			"amount": Decimal.canonical(raw.amount), "status": "UNVERIFIED",
			"reason": "ACCOUNT_TOTAL_REQUIRES_LOCKED_VALUATION"})
	return {"ok": true, "rows": rows}


static func _nonnegative(value: String) -> bool:
	return Decimal.is_valid(value) and Decimal.compare(value, "0") >= 0


static func _insufficient(reasons: Array[String], missing: Array[String] = [],
		checkpoints: Array = []) -> Dictionary:
	return {"ok": true, "status": "INSUFFICIENT_DATA", "scope": SCOPE,
		"full_reconciliation": false, "reasons": reasons,
		"missing": missing, "differences": [],
		"unverified_account_totals": checkpoints}


static func _error(code: String) -> Dictionary:
	return {"ok": false, "error": code}
