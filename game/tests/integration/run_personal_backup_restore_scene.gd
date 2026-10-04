extends SceneTree

const Scene = preload("res://scenes/personal_backup_restore.tscn")
const Store = preload("res://scripts/data/project_store.gd")
const PersonalFlow = preload("res://scripts/data/personal_flow.gd")
const Backup = preload("res://scripts/backup/backup_service.gd")

var checks := 0
var failures: Array[String] = []
var _directory := ""


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	_directory = ProjectSettings.globalize_path("res://").get_base_dir().path_join("tests").path_join(
		".backup-scene-test-" + Crypto.new().generate_random_bytes(8).hex_encode())
	if DirAccess.make_dir_recursive_absolute(_directory) != OK:
		printerr("PERSONAL BACKUP SCENE FAIL: sandbox directory unavailable")
		quit(1)
		return
	await _test_guards()
	await _test_export_preview_restore()
	await _test_stale_preview()
	await _test_return_path()
	if failures.is_empty():
		print("PERSONAL BACKUP SCENE PASS: %d checks" % checks)
		quit(0)
	else:
		for failure in failures:
			printerr("FAIL: " + failure)
		printerr("PERSONAL BACKUP SCENE FAIL: %d failures in %d checks" % [failures.size(), checks])
		quit(1)


func _test_guards() -> void:
	var demo_path := _directory.path_join("demo")
	var demo_store := Store.new(demo_path)
	var demo_state: Dictionary = demo_store.new_project()
	demo_state.data_kind = "demo"
	_check(demo_store.save_project(demo_state, 0).ok, "synthetic demo project saved")
	var demo := await _mount(demo_path, _directory.path_join("demo-safety"))
	_check(demo.get_export_choose_button().disabled and demo.get_restore_choose_button().disabled and \
		demo.get_status_text().contains("演示项目"), "demo data cannot use personal backup page")
	_check(demo.get_preview_text().contains("预览") and demo.get_confirm_button().disabled,
		"restore starts without a pending confirmation")
	demo.queue_free()
	await process_frame


func _test_export_preview_restore() -> void:
	var path := _directory.path_join("personal")
	var safety_dir := _directory.path_join("personal-safety")
	_check(_fixture(path).ok, "synthetic personal fixture saved")
	var store := Store.new(path)
	var first: Dictionary = store.load_project()
	var original_hash := JSON.stringify(first.state).sha256_text()
	var panel := await _mount(path, safety_dir)
	_check(panel.get_status_text().contains("第 1 版") and \
		panel.get_export_path_text().contains("尚未选择") and \
		panel.get_confirm_button().disabled, "personal page shows initial generation and no pending action")
	_check(panel.get_status_text().contains("第 1 版") and \
		panel.get_preview_text().contains("预览") and \
		panel.get_export_choose_button() != null,
		"backup page exposes export and restore sections")
	var has_plaintext_warning := false
	var has_picker_caveat := false
	for label in panel.find_children("*", "Label", true, false):
		has_plaintext_warning = has_plaintext_warning or label.text.contains("不适合上传")
		has_picker_caveat = has_picker_caveat or label.text.contains("Android 系统文件选择器尚未验证")
	_check(has_plaintext_warning and has_picker_caveat,
		"page discloses plaintext export and unverified Android picker")
	var backup_path := _directory.path_join("personal-full.json")
	panel.select_export_path(backup_path)
	_check(not panel.get_export_button().disabled and \
		panel.get_export_path_text().contains("personal-full.json"),
		"new output path selected before export")
	panel.get_export_button().pressed.emit()
	_check(FileAccess.file_exists(backup_path) and panel.get_export_button().disabled and \
		store.load_project().generation == first.generation and \
		panel.get_export_path_text().contains("明文"), "export writes chosen new file without changing project")
	var existing_bytes := FileAccess.get_file_as_string(backup_path)
	panel.select_export_path(backup_path)
	panel.get_export_button().pressed.emit()
	_check(panel.get_export_button().disabled and \
		panel.get_export_path_text().contains("不会覆盖") and \
		FileAccess.get_file_as_string(backup_path) == existing_bytes,
		"existing export file cannot be overwritten")
	var changed: Dictionary = PersonalFlow.new(path).record_cash_change("scene-change", "cash-1", "1000",
		"2026-09-27T01:00:00Z", int(first.generation))
	_check(changed.ok and store.load_project().generation == 2,
		"personal ledger advanced after backup")
	var current_hash := JSON.stringify(store.load_project().state).sha256_text()
	panel.select_restore_path(backup_path)
	_check(panel.get_confirm_button().disabled and not panel.get_preview_button().disabled,
		"file selection alone cannot restore")
	panel.get_preview_button().pressed.emit()
	var preview_text: String = panel.get_preview_text()
	_check(preview_text.contains("备份文件声明的来源第 1 版") and \
		preview_text.contains("当前第 2 版") and preview_text.contains("流水：1 → 2") and \
		preview_text.contains("金豆：5 → 6"),
		"preview shows declared backup generation and count differences")
	_check(store.load_project().generation == 2 and \
		JSON.stringify(store.load_project().state).sha256_text() == current_hash and \
		not DirAccess.dir_exists_absolute(safety_dir),
		"preview reads only and creates no safety copy")
	var legacy_path := _directory.path_join("legacy-without-source-generation.json")
	var legacy_document: Dictionary = JSON.parse_string(existing_bytes)
	legacy_document.manifest.erase("source_generation")
	var legacy_file := FileAccess.open(legacy_path, FileAccess.WRITE)
	legacy_file.store_string(JSON.stringify(legacy_document))
	legacy_file.close()
	panel.select_restore_path(legacy_path)
	_check(panel.get_confirm_button().disabled, "choosing another backup invalidates shown preview")
	panel.get_preview_button().pressed.emit()
	_check(panel.get_preview_text().contains("备份来源版本未知") and \
		store.load_project().generation == 2, "older backup without source generation remains previewable")
	panel.select_restore_path(backup_path)
	panel.get_preview_button().pressed.emit()
	panel.get_confirm_button().pressed.emit()
	_check(store.load_project().generation == 2 and panel.get_confirmation_dialog().visible,
		"first restore action opens a second explicit confirmation without writing")
	panel.get_confirmation_dialog().canceled.emit()
	panel.get_confirmation_dialog().hide()
	panel.get_confirmation_dialog().confirmed.emit()
	_check(store.load_project().generation == 2, "canceled confirmation cannot restore")
	panel.get_confirm_button().pressed.emit()
	panel.get_confirmation_dialog().confirmed.emit()
	panel.get_confirmation_dialog().hide()
	var restored: Dictionary = store.load_project()
	_check(restored.generation == 3 and JSON.stringify(restored.state).sha256_text() == original_hash and \
		panel.get_confirm_button().disabled and panel.get_preview_button().disabled,
		"second explicit confirmation restores exactly the selected snapshot")
	var safety_files := DirAccess.get_files_at(safety_dir)
	_check(safety_files.size() == 1 and \
		Backup.new(safety_dir).preview_backup(safety_dir.path_join(safety_files[0]), store).backup_counts.events == 2,
		"restore leaves private safety backup of newer project")
	_check(panel.get_status_text().contains("第 3 版") and \
		panel.get_preview_text().contains("应用私有备份目录"),
		"page reports new generation and safety copy")
	panel.queue_free()
	await process_frame


func _test_stale_preview() -> void:
	var path := _directory.path_join("stale-personal")
	var safety_dir := _directory.path_join("stale-safety")
	_check(_fixture(path).ok, "stale preview fixture saved")
	var store := Store.new(path)
	var backup_path := _directory.path_join("stale-full.json")
	_check(Backup.new(safety_dir).export_project(store, backup_path).ok, "stale test backup exported")
	var panel := await _mount(path, safety_dir)
	panel.select_restore_path(backup_path)
	panel.get_preview_button().pressed.emit()
	_check(not panel.get_confirm_button().disabled, "valid preview can enter confirmation")
	var newer: Dictionary = store.load_project().state
	newer.presentation.privacy_mode = "hide_total"
	_check(store.save_project(newer, 1).ok, "project changed after preview")
	panel.get_confirm_button().pressed.emit()
	panel.get_confirmation_dialog().confirmed.emit()
	panel.get_confirmation_dialog().hide()
	_check(store.load_project().generation == 2 and \
		store.load_project().state.presentation.privacy_mode == "hide_total" and \
		panel.get_confirm_button().disabled and panel.get_preview_text().contains("CURRENT_STATE_CHANGED") and \
		not DirAccess.dir_exists_absolute(safety_dir),
		"stale preview is rejected before safety copy or replacement")
	panel.queue_free()
	await process_frame


func _test_return_path() -> void:
	var path := _directory.path_join("return-personal")
	_check(_fixture(path).ok, "return path personal fixture saved")
	OS.set_environment("MONEYBOX_PERSONAL_STATE_PATH", path)
	var panel := await _mount(path, _directory.path_join("return-safety"))
	panel.get_back_button().pressed.emit()
	await process_frame
	await process_frame
	_check(current_scene != null and current_scene.scene_file_path == "res://scenes/personal_main.tscn",
		"back button returns to personal main scene")
	OS.set_environment("MONEYBOX_PERSONAL_STATE_PATH", "")


func _fixture(path: String) -> Dictionary:
	return PersonalFlow.new(path).create_opening_cash("fixture-opening", "cash-1", "Synthetic Cash",
		"5000", "1000", "2026-09-27T00:00:00Z")


func _mount(path: String, safety_dir: String) -> Control:
	var panel := Scene.instantiate()
	panel.base_path = path
	panel.safety_directory = safety_dir
	root.add_child(panel)
	await process_frame
	return panel


func _check(condition: bool, label: String) -> void:
	checks += 1
	if not condition:
		failures.append(label)
