extends SceneTree

const Scene = preload("res://scenes/personal_reconciliation.tscn")
const Store = preload("res://scripts/data/project_store.gd")
const Ledger = preload("res://scripts/data/ledger_core.gd")

const T0 := "2026-01-01T00:00:00Z"
const T1 := "2026-02-01T00:00:00Z"
const T2 := "2026-03-01T00:00:00Z"

var checks := 0
var failures: Array[String] = []
var _path := ""


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	_path = ProjectSettings.globalize_path("res://tests/tmp").path_join(
		"reconciliation-scene-" + Crypto.new().generate_random_bytes(8).hex_encode())
	var state := Store.new(_path).new_project()
	var commands := [
		{"command_id": "broker", "type": "account_create", "account": {
			"id": "broker", "name": "测试券商", "currency": "CNY", "mode": "detail", "cost_method": "FIFO"}},
		{"command_id": "usd", "type": "account_create", "account": {
			"id": "usd", "name": "美元现金", "currency": "USD", "mode": "detail", "cost_method": "FIFO"}},
		{"command_id": "stock", "type": "instrument_create", "instrument": {
			"id": "stock", "kind": "STOCK", "market": "TEST", "symbol": "ZZZ", "currency": "CNY"}},
		{"command_id": "open-cny", "type": "opening_cash", "account_id": "broker",
			"amount": "1000", "effective_at": T0},
		{"command_id": "open-usd", "type": "opening_cash", "account_id": "usd",
			"amount": "100", "effective_at": T0},
		{"command_id": "buy-stock", "type": "buy", "account_id": "broker",
			"instrument_id": "stock", "quantity": "2", "unit_price": "100",
			"fee": "5", "effective_at": T1},
	]
	for command in commands:
		var applied := Ledger.apply(state.ledger, command)
		if not applied.ok:
			_check(false, "fixture command " + str(applied.get("error", "UNKNOWN")))
			_finish()
			return
		state.ledger = applied.state
	var store := Store.new(_path)
	_check(store.save_project(state, 0).ok, "synthetic personal project saved")
	var before: Dictionary = store.load_project()
	var state_text := JSON.stringify(before.state)
	var panel := await _mount(_path)
	_check(panel.get_account_picker().item_count == 2 and not panel.get_preview_button().disabled,
		"both accounts offered for read-only statement input")
	_check(panel.get_input("broker", "cash").text.is_empty() and
		panel.get_input("broker", "position", "stock").text.is_empty() and
		panel.get_input("broker", "fee", "buy-stock").text.is_empty(),
		"statement amounts are not filled from ledger values")
	panel.get_as_of_input().text = T2
	panel.get_preview_button().pressed.emit()
	_check(panel.get_result_text().contains("资料不足") and
		panel.get_result_text().contains("SETTLEMENT_STATUS_MISSING"),
		"missing settlement declaration cannot produce a false match")
	panel.get_settlement_picker().select(1)
	panel.get_input("broker", "cash").text = "795"
	panel.get_input("broker", "position", "stock").text = "2"
	panel.get_input("broker", "fee", "buy-stock").text = "5"
	panel.get_input("broker", "total").text = "995"
	panel.get_account_picker().select(1)
	panel.call("_select_account", 1)
	_check(panel.get_input("usd", "cash") != null and
		panel.get_input("usd", "cash").is_visible_in_tree() and
		not panel.get_input("broker", "cash").is_visible_in_tree(),
		"account selector switches the visible statement form")
	panel.get_input("usd", "cash").text = "100"
	panel.get_preview_button().pressed.emit()
	_check(panel.get_result_text().contains("支持范围内一致") and
		panel.get_result_text().contains("未验证") and
		panel.get_result_text().contains("不是完整账户对账"),
		"matched scope and unverified broker total are explicit")
	_check(JSON.stringify(store.load_project().state) == state_text and
		store.load_project().generation == before.generation,
		"matched preview leaves saved project unchanged")
	panel.get_input("broker", "cash").text = "794.90"
	panel.get_input("broker", "position", "stock").text = "1.5"
	panel.get_input("broker", "fee", "buy-stock").text = "6"
	panel.get_preview_button().pressed.emit()
	_check(panel.get_result_text().contains("3 处") and
		panel.get_result_text().contains("现金 broker CNY") and
		panel.get_result_text().contains("持仓 broker/stock") and
		panel.get_result_text().contains("手续费 buy-stock CNY") and
		panel.get_result_text().contains("不会自动更正"),
		"cash, holding and fee differences displayed without correction action")
	panel.get_input("usd", "cash").clear()
	panel.get_preview_button().pressed.emit()
	_check(panel.get_result_text().contains("资料不足") and
		panel.get_result_text().contains("CASH:usd") and
		not panel.get_result_text().contains("发现 3 处"),
		"missing second-account cash is not reported as a complete comparison")
	panel.get_input("usd", "cash").text = "100"
	panel.get_settlement_picker().select(2)
	panel.get_preview_button().pressed.emit()
	_check(panel.get_result_text().contains("资料不足") and
		panel.get_result_text().contains("PENDING_SETTLEMENT_NOT_RECONCILABLE"),
		"pending settlement uncertainty remains insufficient")
	panel.get_settlement_picker().select(1)
	panel.get_input("broker", "cash").text = "1e2"
	panel.get_preview_button().pressed.emit()
	_check(panel.get_result_text().contains("输入有误") and
		panel.get_result_text().contains("INVALID_CASH_ROW"),
		"non-decimal financial input rejected")
	_check(JSON.stringify(store.load_project().state) == state_text and
		store.load_project().generation == before.generation,
		"all preview paths remain read-only")
	var changed: Dictionary = store.load_project().state
	changed.presentation.skin_id = "ecology"
	_check(store.save_project(changed, before.generation).ok, "external generation change fixture saved")
	panel.get_input("broker", "cash").text = "795"
	panel.get_preview_button().pressed.emit()
	_check(panel.get_result_text().contains("账本版本已变化") and panel.get_preview_button().disabled,
		"stale form cannot compare a changed saved project")
	panel.queue_free()
	await process_frame
	var private_state: Dictionary = store.load_project().state
	private_state.presentation.privacy_mode = "hide_total"
	_check(store.save_project(private_state, 2).ok, "privacy fixture saved")
	panel = await _mount(_path)
	_check(panel.get_preview_button().disabled and panel.get_account_picker().item_count == 0 and
		panel.get_status_text().contains("隐私模式") and not panel.get_status_text().contains("795"),
		"privacy mode does not expose balances or identities in reconciliation")
	panel.queue_free()
	await process_frame
	var demo_path := _path + "-demo"
	var demo_store := Store.new(demo_path)
	var demo_state: Dictionary = demo_store.new_project()
	demo_state.data_kind = "demo"
	_check(demo_store.save_project(demo_state, 0).ok, "isolated demo fixture saved")
	panel = await _mount(demo_path)
	_check(panel.get_preview_button().disabled and panel.get_status_text().contains("演示项目"),
		"demo project cannot be reconciled as personal assets")
	panel.queue_free()
	await process_frame
	_finish()


func _mount(path: String) -> Control:
	var panel := Scene.instantiate()
	panel.base_path = path
	root.add_child(panel)
	await process_frame
	return panel


func _check(condition: bool, label: String) -> void:
	checks += 1
	if not condition:
		failures.append(label)


func _finish() -> void:
	if failures.is_empty():
		print("PERSONAL RECONCILIATION SCENE PASS: %d checks" % checks)
		quit(0)
	else:
		for failure in failures:
			printerr("FAIL: " + failure)
		printerr("PERSONAL RECONCILIATION SCENE FAIL: %d failures in %d checks" % [failures.size(), checks])
		quit(1)
