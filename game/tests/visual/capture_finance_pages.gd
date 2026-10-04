extends SceneTree
## Graphical desktop evidence only. All pages read one isolated synthetic personal project.

const Personal = preload("res://scripts/data/personal_flow.gd")


func _initialize() -> void:
	call_deferred("_capture")


func _capture() -> void:
	var project_dir := ProjectSettings.globalize_path("res://project.godot").get_base_dir().get_base_dir()
	var test_dir := project_dir.path_join("tests/tmp")
	var evidence_dir := project_dir.path_join("docs/evidence")
	DirAccess.make_dir_recursive_absolute(test_dir)
	DirAccess.make_dir_recursive_absolute(evidence_dir)
	var path := test_dir.path_join("finance-pages-" + str(Time.get_ticks_usec()))
	var opened := Personal.new(path).create_opening_cash("screen-open", "cash", "截图测试现金",
		"50000", "1000", "2026-09-27T02:00:00Z")
	if not opened.ok:
		printerr("FINANCE_CAPTURE_SETUP_FAILED: ", opened)
		quit(1)
		return
	OS.set_environment("MONEYBOX_PERSONAL_STATE_PATH", path)
	var pages := [
		{"name": "overview", "scene": "res://scenes/personal_overview.tscn"},
		{"name": "asset_entry", "scene": "res://scenes/personal_asset_entry.tscn"},
		{"name": "manual_revaluation", "scene": "res://scenes/personal_manual_revaluation.tscn"},
		{"name": "trade_draft", "scene": "res://scenes/personal_trade_draft.tscn"},
		{"name": "csv_import", "scene": "res://scenes/personal_csv_import.tscn"},
		{"name": "bean_organizer", "scene": "res://scenes/personal_bean_organizer.tscn"},
		{"name": "backup_restore", "scene": "res://scenes/personal_backup_restore.tscn"},
		{"name": "ledger_history", "scene": "res://scenes/personal_ledger_history.tscn"},
		{"name": "reconciliation", "scene": "res://scenes/personal_reconciliation.tscn"},
		{"name": "csv_export", "scene": "res://scenes/personal_csv_export.tscn"},
	]
	for entry in pages:
		var page: Control = load(str(entry.scene)).instantiate()
		root.add_child(page)
		await create_timer(0.5).timeout
		var file_path := evidence_dir.path_join("finance_desktop_" + str(entry.name) + ".png")
		var error := root.get_texture().get_image().save_png(file_path)
		if error != OK:
			printerr("FINANCE_CAPTURE_FAILED: ", file_path, " error=", error)
			quit(1)
			return
		print("CAPTURED ", file_path)
		page.queue_free()
		await process_frame
	print("FINANCE_PAGES_CAPTURED: ", pages.size())
	quit(0)
