extends SceneTree

const Store = preload("res://scripts/data/project_store.gd")
const Ledger = preload("res://scripts/data/ledger_core.gd")
const Personal = preload("res://scripts/data/personal_flow.gd")
const Asset = preload("res://scripts/data/personal_asset_flow.gd")
const Revalue = preload("res://scripts/quotes/personal_manual_revaluation_flow.gd")
const Contract = preload("res://scripts/quotes/quote_contract.gd")
const Display = preload("res://scripts/data/display_snapshot_service.gd")
const Reconcile = preload("res://scripts/reconciliation/reconciliation_service.gd")

const NOW := "2026-09-27T02:00:00Z"

var checks := 0
var failures: Array[String] = []


func _initialize() -> void:
	var directory := ProjectSettings.globalize_path("res://").get_base_dir().path_join(
		"tests").path_join("data").path_join("tmp")
	DirAccess.make_dir_recursive_absolute(directory)
	_run(directory.path_join("restricted-asset-" + str(Time.get_ticks_usec())))
	if failures.is_empty():
		print("RESTRICTED ASSET TESTS PASS: %d checks" % checks)
		quit(0)
	else:
		for failure in failures:
			printerr("FAIL: " + failure)
		printerr("RESTRICTED ASSET TESTS FAIL: %d failures in %d checks" % [
			failures.size(), checks])
		quit(1)


func _run(path: String) -> void:
	var opening := Personal.new(path).create_opening_cash("restricted-start",
		"cash", "现金", "10000", "1000", NOW)
	_check(opening.ok and opening.equivalent_grams == "10", "starting personal jar")
	if not opening.ok:
		return
	var store := Store.new(path)
	var commands := [
		{"command_id": "provident-account", "type": "account_create",
			"account": _account("provident", "住房公积金", "CNY", "PROVIDENT_FUND")},
		{"command_id": "pension-account", "type": "account_create",
			"account": _account("pension", "养老金", "USD", "PENSION")},
		{"command_id": "provident-balance-1", "type": "restricted_balance_set",
			"account_id": "provident", "amount": "1200.50",
			"source_note": "个人账户对账单", "effective_at": NOW},
		{"command_id": "pension-balance-1", "type": "restricted_balance_set",
			"account_id": "pension", "amount": "100",
			"source_note": "养老金账户对账单", "effective_at": NOW},
	]
	var before := store.load_project()
	var preview := Asset.new(path).preview(commands, before.generation)
	_check(preview.ok and preview.restricted_balances.provident == "1200.5" \
		and preview.restricted_balances.pension == "100" \
		and preview.cash_balances.size() == 1 and preview.cash_balances.cash == "10000" \
		and preview.missing_valuation_inputs.has("FX:USD") \
		and not preview.has("asset_total") and store.load_project().generation == before.generation,
		"two restricted account balances preview separately from spendable cash")
	if not preview.ok:
		return
	var saved := Asset.new(path).confirm(commands, preview,
		{"confirmed": true, "preview_id": preview.preview_id})
	var restarted := store.load_project()
	var projected := Ledger.project(restarted.state.ledger)
	_check(saved.ok and restarted.generation == before.generation + 1 \
		and restarted.state.valuation_pending.reason == "ASSET_STRUCTURE_CHANGE" \
		and projected.restricted_balances.provident == "1200.5" \
		and projected.restricted_balances.pension == "100" \
		and not projected.cash.has("provident") and not projected.cash.has("pension") \
		and projected.cash.cash == "10000" and projected.asset_total == "" \
		and projected.external_net_invested == "0",
		"confirmation and restart preserve exact balances without inventing flows or FX")
	if not saved.ok:
		return
	var ledger: Dictionary = restarted.state.ledger
	var statement := {"schema_version": 1,
		"ledger_hash": Store.canonical_ledger_hash(ledger), "as_of": NOW,
		"cash_balances": [], "positions": [], "fees": [],
		"pending_settlements": {"status": "NONE"}}
	var reconciliation := Reconcile.compare(ledger, statement)
	_check(reconciliation.ok and reconciliation.status == "INSUFFICIENT_DATA" \
		and reconciliation.reasons.has("RESTRICTED_BALANCE_RECONCILIATION_UNSUPPORTED"),
		"cash-only reconciliation cannot claim restricted accounts matched")
	_check(Ledger.apply(ledger, {"command_id": "spend-pension", "type": "buy",
		"account_id": "pension", "instrument_id": "anything", "quantity": "1",
		"unit_price": "1", "fee": "0", "effective_at": NOW}).error == \
		"INVALID_ACCOUNT_ASSET_KIND" \
		and Ledger.apply(ledger, {"command_id": "transfer-provident", "type": "transfer",
			"account_id": "provident", "to_account_id": "cash", "amount": "1",
			"effective_at": NOW}).error == "INVALID_ACCOUNT_ASSET_KIND" \
		and Ledger.apply(ledger, {"command_id": "cash-on-provident", "type": "opening_cash",
			"account_id": "provident", "amount": "1", "effective_at": NOW}).error == \
			"INVALID_ACCOUNT_ASSET_KIND" \
		and Ledger.apply(ledger, {"command_id": "cash-into-provident", "type": "transfer",
			"account_id": "cash", "to_account_id": "provident", "amount": "1",
			"effective_at": NOW}).error == "INVALID_TRANSFER",
		"restricted balance cannot buy, transfer or masquerade as available cash")
	var bad_float := [{"command_id": "bad-float", "type": "restricted_balance_set",
		"account_id": "provident", "amount": 123.5,
		"source_note": "statement", "effective_at": NOW}]
	var no_source := [{"command_id": "bad-source", "type": "restricted_balance_set",
		"account_id": "provident", "amount": "123.5",
		"source_note": "", "effective_at": NOW}]
	_check(Asset.new(path).preview(bad_float, restarted.generation).error == \
		"INVALID_RESTRICTED_BALANCE_INPUT" \
		and Asset.new(path).preview(no_source, restarted.generation).error == \
		"INVALID_RESTRICTED_BALANCE_INPUT" \
		and store.load_project().generation == restarted.generation,
		"float and missing provenance fail without a write")
	var cash_rows := [{"balance_id": "cash", "amount": "10000", "currency": "CNY"}]
	var restricted_rows := [{"balance_id": "provident", "amount": "1200.5", "currency": "CNY"},
		{"balance_id": "pension", "amount": "100", "currency": "USD"}]
	var incomplete := store.validate_valuation_coverage(ledger, [], cash_rows)
	var wrong := restricted_rows.duplicate(true)
	wrong[0].amount = "1200.51"
	_check(not incomplete.ok and incomplete.error == "VALUATION_COVERAGE_MISMATCH" \
		and store.validate_valuation_coverage(ledger, [], cash_rows, wrong).error == \
		"VALUATION_COVERAGE_MISMATCH" \
		and store.validate_valuation_coverage(ledger, [], cash_rows, restricted_rows).ok,
		"full valuation requires exact cash and every restricted balance")
	var change := [{"command_id": "provident-balance-2", "type": "restricted_balance_set",
		"account_id": "provident", "amount": "1300.50",
		"source_note": "更新的个人账户对账单", "effective_at": NOW}]
	var change_preview := Asset.new(path).preview(change, restarted.generation)
	var changed := Asset.new(path).confirm(change, change_preview,
		{"confirmed": true, "preview_id": change_preview.preview_id})
	var after_change := store.load_project()
	var new_projection := Ledger.project(after_change.state.ledger)
	_check(change_preview.ok and changed.ok and \
		new_projection.restricted_balances.provident == "1300.5" \
		and after_change.state.ledger.events.size() == ledger.events.size() + 1 \
		and new_projection.external_net_invested == "0",
		"later balance checkpoint replaces previous amount without double count or invented return")
	if not changed.ok:
		return
	var needed := Revalue.new(path).requirements(after_change.generation)
	var fx_key := Contract.identity_key(_identity("FX", "FX", "USD/CNY", "CNY"))
	var gold_key := Contract.identity_key(_identity("GOLD", "SPOT", "XAU", "CNY"))
	_check(needed.ok and needed.cash_account_count == 1 \
		and needed.restricted_account_count == 2 and needed.position_count == 0 \
		and needed.identities.size() == 2,
		"manual revaluation derives FX and gold without treating restricted balance as cash")
	if not needed.ok:
		return
	var entries := {}
	entries[fx_key] = _entry("7", "CURRENCY_PER_FOREIGN_UNIT")
	entries[gold_key] = _entry("1000", "CURRENCY_PER_GRAM")
	var manual_preview := Revalue.new(path).preview(entries, after_change.generation, NOW)
	_check(manual_preview.ok and manual_preview.asset_total == "12000.5" \
		and manual_preview.equivalent_grams == "12.0005" \
		and store.load_project().generation == after_change.generation,
		"one complete valuation previews cash plus two separate restricted balances")
	if not manual_preview.ok:
		return
	var confirmed := Revalue.new(path).confirm(entries, manual_preview,
		{"confirmed": true, "preview_id": manual_preview.preview_id}, NOW)
	var restored := Store.new(path).load_project()
	var snapshot: Dictionary = restored.state.valuation.snapshots["valuation:" + manual_preview.batch_id]
	var display := Display.build(restored.state, restored.generation)
	_check(confirmed.ok and confirmed.asset_total == "12000.5" \
		and restored.generation == after_change.generation + 2 \
		and snapshot.cash_values.size() == 1 and snapshot.restricted_values.size() == 2 \
		and snapshot.restricted_values[0].amount == "100" \
		and snapshot.restricted_values[1].amount == "1300.5" \
		and not restored.state.has("valuation_pending") \
		and display.ok and display.snapshot.snapshot_status == "CURRENT" \
		and restored.state.mappings.back().amount == "12000.5",
		"confirmed full valuation and gold mapping survive restart with restricted evidence")
	var corrupted: Dictionary = restored.state.duplicate(true)
	corrupted.valuation.snapshots["valuation:" + manual_preview.batch_id].restricted_values.pop_back()
	var corrupt_path := path + "-missing-restricted-row"
	var corrupt_store := Store.new(corrupt_path)
	var corrupt_saved := corrupt_store.save_project(corrupted, 0)
	_check(corrupt_saved.ok and not corrupt_store.current_valuation_snapshot(
		corrupted, "valuation:" + manual_preview.batch_id).ok,
		"saved snapshot with missing restricted row cannot certify a current total")
	var repeated := Revalue.new(path).preview(entries, restored.generation, NOW)
	_check(repeated.ok and repeated.duplicate and store.load_project().generation == \
		restored.generation, "same quotes and ledger replay without another valuation generation")


func _account(id: String, name: String, currency: String, kind: String) -> Dictionary:
	return {"id": id, "name": name, "currency": currency, "mode": "detail",
		"cost_method": "FIFO", "asset_kind": kind}


func _identity(kind: String, market: String, symbol: String, currency: String) -> Dictionary:
	return {"kind": kind, "market": market, "symbol": symbol,
		"currency": currency, "share_class": ""}


func _entry(price: String, unit: String) -> Dictionary:
	return {"price": price, "unit": unit, "quoted_at": NOW,
		"source_note": "人工核对的测试数据"}


func _check(condition: bool, label: String) -> void:
	checks += 1
	if not condition:
		failures.append(label)
