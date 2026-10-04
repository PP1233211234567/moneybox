extends SceneTree

const Scene = preload("res://scenes/personal_csv_export.tscn")
const Store = preload("res://scripts/data/project_store.gd")
const PersonalFlow = preload("res://scripts/data/personal_flow.gd")

var checks := 0
var failures: Array[String] = []
var _directory := ""


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	_directory = ProjectSettings.globalize_path("res://").get_base_dir().path_join("tests").path_join(
		".csv-export-scene-test-" + Crypto.new().generate_random_bytes(8).hex_encode())
	if DirAccess.make_dir_recursive_absolute(_directory) != OK:
		printerr("PERSONAL CSV EXPORT SCENE FAIL: sandbox directory unavailable")
		quit(1)
		return
	await _test_guards()
	await _test_export_and_privacy()
	await _test_return_path()
	if failures.is_empty():
		print("PERSONAL CSV EXPORT SCENE PASS: %d checks" % checks)
		quit(0)
	else:
		for failure in failures:
			printerr("FAIL: " + failure)
		printerr("PERSONAL CSV EXPORT SCENE FAIL: %d failures in %d checks" % [failures.size(), checks])
		quit(1)


func _test_guards() -> void:
	var demo_path := _directory.path_join("demo")
	var demo_store := Store.new(demo_path)
	var demo: Dictionary = demo_store.new_project()
	demo.data_kind = "demo"
	_check(demo_store.save_project(demo, 0).ok, "synthetic demo project saved")
	var demo_panel := await _mount(demo_path)
	_check(demo_panel.get_choose_button().disabled and demo_panel.get_export_button().disabled and \
		demo_panel.get_status_text().contains("演示项目"), "demo export controls stay disabled")
	demo_panel.queue_free()
	await process_frame
	var empty_panel := await _mount(_directory.path_join("empty"))
	_check(empty_panel.get_choose_button().disabled and \
		empty_panel.get_status_text().contains("尚未保存"), "unsaved personal project cannot export")
	empty_panel.queue_free()
	await process_frame


func _test_export_and_privacy() -> void:
	var personal_path := _directory.path_join("personal")
	_check(PersonalFlow.new(personal_path).create_opening_cash("opening", "cash-1", "Synthetic Cash",
		"5000", "1000", "2026-09-27T00:00:00Z").ok, "personal fixture saved")
	var store := Store.new(personal_path)
	var current: Dictionary = store.load_project()
	current.state.presentation.privacy_mode = "hide_total"
	_check(store.save_project(current.state, int(current.generation)).ok,
		"privacy-mode fixture saved")
	var before := store.load_project()
	var before_sha := JSON.stringify(before.state).sha256_text()
	var panel := await _mount(personal_path)
	_check(panel.get_status_text().contains("第 2 版") and \
		panel.get_status_text().contains("1 条流水") and panel.get_export_button().disabled,
		"page lists saved generation/count without automatic export")
	_check(panel.get_file_dialog().access == FileDialog.ACCESS_FILESYSTEM and \
		panel.get_file_dialog().file_mode == FileDialog.FILE_MODE_SAVE_FILE,
		"page uses explicit filesystem save dialog")
	var has_warning := false
	var has_limit := false
	var has_android_caveat := false
	for label in panel.find_children("*", "Label", true, false):
		has_warning = has_warning or label.text.contains("明文") and label.text.contains("泄露")
		has_limit = has_limit or label.text.contains("不会截断")
		has_android_caveat = has_android_caveat or label.text.contains("Android 系统文件选择器")
	_check(has_warning and has_limit and has_android_caveat,
		"page discloses privacy, bounded export and Android picker limitation")
	var output := _directory.path_join("private-events.csv")
	panel.select_export_path(output)
	_check(not panel.get_export_button().disabled and panel.get_path_text().contains("private-events.csv"),
		"file selection arms one explicit export")
	panel.get_export_button().pressed.emit()
	_check(FileAccess.file_exists(output) and panel.get_export_button().disabled and \
		panel.get_status_text().contains("已导出第 2 版") and \
		panel.get_status_text().contains("个人账本未改变"),
		"explicit export succeeds even in privacy mode and disarms action")
	var existing_bytes := FileAccess.get_file_as_bytes(output)
	panel.select_export_path(output)
	panel.get_export_button().pressed.emit()
	_check(panel.get_export_button().disabled and panel.get_path_text().contains("不会覆盖") and \
		FileAccess.get_file_as_bytes(output) == existing_bytes,
		"page refuses existing file and preserves its bytes")
	var after := store.load_project()
	_check(after.generation == before.generation and \
		JSON.stringify(after.state).sha256_text() == before_sha,
		"CSV page leaves private saved project unchanged")
	panel.queue_free()
	await process_frame


func _test_return_path() -> void:
	var path := _directory.path_join("return-personal")
	_check(PersonalFlow.new(path).create_opening_cash("return-opening", "cash-1", "Synthetic Cash",
		"5000", "1000", "2026-09-27T00:00:00Z").ok, "return fixture saved")
	OS.set_environment("MONEYBOX_PERSONAL_STATE_PATH", path)
	var panel := await _mount(path)
	panel.get_back_button().pressed.emit()
	await process_frame
	await process_frame
	_check(current_scene != null and current_scene.scene_file_path == "res://scenes/personal_main.tscn",
		"back button returns to personal main scene")
	OS.set_environment("MONEYBOX_PERSONAL_STATE_PATH", "")


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
