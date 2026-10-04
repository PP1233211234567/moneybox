extends SceneTree

const SCENE = preload("res://scenes/personal_ledger_history.tscn")
const Store = preload("res://scripts/data/project_store.gd")
const Ledger = preload("res://scripts/data/ledger_core.gd")
const NOW := "2026-09-27T02:00:00Z"

var checks := 0
var failures: Array[String] = []
var base_path := ""


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var directory := ProjectSettings.globalize_path("res://").get_base_dir().path_join("tests") \
		.path_join("data").path_join("tmp")
	DirAccess.make_dir_recursive_absolute(directory)
	base_path = directory.path_join("history-" + str(Time.get_ticks_usec()))
	await _test_empty()
	await _test_events_filters_privacy()
	if failures.is_empty():
		print("PERSONAL LEDGER HISTORY SCENE TESTS PASS: %d checks" % checks)
		quit(0)
	else:
		for failure in failures:
			printerr(failure)
		printerr("PERSONAL LEDGER HISTORY SCENE TESTS FAIL: %d failures in %d checks" % [
			failures.size(), checks])
		quit(1)


func _check(condition: bool, label: String) -> void:
	checks += 1
	if not condition:
		failures.append(label)


func _open() -> Control:
	var scene: Control = SCENE.instantiate()
	scene.base_path = base_path
	root.add_child(scene)
	await process_frame
	return scene


func _close(scene: Control) -> void:
	root.remove_child(scene)
	scene.free()


func _test_empty() -> void:
	var scene := await _open()
	_check(scene.get_status_text().contains("尚未保存") and scene.get_row_texts().is_empty(),
		"unsaved project has no history")
	_check(scene.get_back_button() != null, "history page has return path")
	_close(scene)


func _test_events_filters_privacy() -> void:
	var store := Store.new(base_path)
	var project: Dictionary = store.new_project()
	project.presentation.privacy_mode = "show_total"
	var commands := [
		{"command_id": "h-account-a", "type": "account_create", "account": {
			"id": "a", "name": "主现金", "currency": "CNY", "mode": "detail", "cost_method": "FIFO"}},
		{"command_id": "h-account-b", "type": "account_create", "account": {
			"id": "b", "name": "备用现金", "currency": "CNY", "mode": "detail", "cost_method": "FIFO"}},
		{"command_id": "h-open", "type": "opening_cash", "account_id": "a",
			"amount": "5000", "effective_at": NOW},
		{"command_id": "h-correct", "type": "void_replace", "target_event_id": "h-open",
			"effective_at": "2026-09-27T03:00:00Z", "replacement": {
				"type": "opening_cash", "account_id": "a", "amount": "4800",
				"effective_at": NOW}},
		{"command_id": "h-cash", "type": "cash_delta", "account_id": "a", "delta": "200",
			"external": true, "effective_at": "2026-09-27T04:00:00Z"},
		{"command_id": "h-transfer", "type": "transfer", "account_id": "a",
			"to_account_id": "b", "amount": "100", "effective_at": "2026-09-27T05:00:00Z"},
	]
	for command in commands:
		var applied: Dictionary = Ledger.apply(project.ledger, command)
		_check(applied.ok, "ledger fixture command " + str(command.command_id))
		if not applied.ok:
			return
		project.ledger = applied.state
	var saved: Dictionary = store.save_project(project, 0)
	_check(saved.ok, "fixture project saved")
	if not saved.ok:
		return
	var before: Dictionary = store.load_project()
	var before_json := JSON.stringify(before.state)
	var scene := await _open()
	_check(scene.get_generation() == saved.generation and scene.get_row_texts().size() == 5,
		"history shows all five actual events")
	_check(scene.get_row_texts()[0].contains("内部转账") and
		scene.get_status_text().contains("入账序号倒序"),
		"latest booking appears first with ordering label")
	var voided_found := false
	for row in scene.get_row_texts():
		if row.contains("期初现金") and row.contains("已冲销"):
			voided_found = true
	_check(voided_found, "voided original remains visible and marked")
	scene.get_row_buttons()[0].pressed.emit()
	_check(scene.get_detail_text().contains("转入：备用现金") and
		scene.get_detail_text().contains("金额：100 CNY"),
		"transfer detail shows destination and amount")
	scene.get_search_input().text = "现金变动"
	scene.refresh()
	_check(scene.get_row_texts().size() == 1 and scene.get_row_texts()[0].contains("现金变动"),
		"local search filters event type")
	scene.get_search_input().text = ""
	scene.get_account_picker().select(2)
	scene.refresh()
	_check(scene.get_row_texts().size() == 1 and scene.get_row_texts()[0].contains("内部转账"),
		"destination account filter includes incoming transfer")
	_close(scene)
	var after_read: Dictionary = store.load_project()
	_check(after_read.generation == before.generation and JSON.stringify(after_read.state) == before_json,
		"opening, search and detail never write project")
	var private_project: Dictionary = after_read.state.duplicate(true)
	private_project.presentation.privacy_mode = "hide_total"
	var private_saved: Dictionary = store.save_project(private_project, after_read.generation)
	_check(private_saved.ok, "privacy setting saved")
	scene = await _open()
	_check(scene.get_row_texts().is_empty() and scene.get_status_text().contains("隐私模式")
		and not scene.get_search_input().editable and scene.get_account_picker().disabled,
		"privacy hides event content and disables search")
	_check(not scene.get_detail_text().contains("5000") and not scene.get_detail_text().contains("主现金"),
		"privacy detail leaks no fixture values")
	_close(scene)
