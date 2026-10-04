extends SceneTree


func _initialize() -> void:
	call_deferred("_inspect")


func _inspect() -> void:
	var test_dir := ProjectSettings.globalize_path("res://tests/tmp")
	DirAccess.make_dir_recursive_absolute(test_dir)
	var run_id := str(Time.get_ticks_usec())
	OS.set_environment("MONEYBOX_DEMO_STATE_PATH", test_dir.path_join("layout-demo-" + run_id))
	var demo: Node3D = load("res://scenes/main.tscn").instantiate()
	root.add_child(demo)
	await process_frame
	demo.queue_free()
	await process_frame
	OS.set_environment("MONEYBOX_PERSONAL_STATE_PATH", test_dir.path_join("layout-" + run_id))
	var scene: Node3D = load("res://scenes/personal_main.tscn").instantiate()
	root.add_child(scene)
	current_scene = scene
	await process_frame
	if not _check(scene.get("_asset_button").disabled
			and scene.get("_revaluation_button").disabled
			and not scene.get("_actions").visible,
			"finance navigation is unavailable before opening a personal account"):
		return
	scene.get("_name_input").text = "布局测试现金"
	scene.get("_amount_input").text = "50000"
	scene.get("_gold_input").text = "1000"
	scene.call("_create_opening")
	await process_frame
	if not _check(not scene.get("_asset_button").disabled
			and not scene.get("_revaluation_button").disabled
			and not scene.get("_more_button").disabled
			and scene.get("_more_button").get_popup().item_count == 8
			and scene.get("_actions").visible,
			"asset and revaluation navigation appear after opening a personal account"):
		return
	if not _check(_geometry_clear(scene, "basic"), "basic jar fits between header and footer"):
		return
	scene.call("_toggle_skin")
	await process_frame
	if not _check(_geometry_clear(scene, "ecology"), "ecology jar fits between header and footer"):
		return
	scene.call("_add_fish")
	scene.call("_add_shrimp")
	scene.call("_add_or_move_plant")
	await create_timer(2.0).timeout
	if not _check(_geometry_clear(scene, "ecology-populated"),
			"saved fish, shrimp and plant leave all finance labels unobscured"):
		return
	scene.get("_asset_button").pressed.emit()
	await process_frame
	await process_frame
	if not _check(current_scene != null and current_scene.scene_file_path == "res://scenes/personal_asset_entry.tscn",
			"record assets button opens the dedicated personal asset entry scene"):
		return
	var return_button: Button = null
	for button in current_scene.find_children("*", "Button", true, false):
		if button.text == "返回个人金豆罐":
			return_button = button
	if not _check(return_button != null, "asset entry has a return button"):
		return
	return_button.pressed.emit()
	await process_frame
	await process_frame
	if not _check(current_scene != null and current_scene.scene_file_path == "res://scenes/personal_main.tscn",
			"asset entry returns to the personal jar"):
		return
	var more_pages := [
		{"id": 1, "path": "res://scenes/personal_overview.tscn"},
		{"id": 2, "path": "res://scenes/personal_bean_organizer.tscn"},
		{"id": 3, "path": "res://scenes/personal_trade_draft.tscn"},
		{"id": 4, "path": "res://scenes/personal_csv_import.tscn"},
		{"id": 5, "path": "res://scenes/personal_backup_restore.tscn"},
		{"id": 6, "path": "res://scenes/personal_reconciliation.tscn"},
		{"id": 7, "path": "res://scenes/personal_ledger_history.tscn"},
		{"id": 8, "path": "res://scenes/personal_csv_export.tscn"},
	]
	for entry in more_pages:
		current_scene.call("_open_more", int(entry.id))
		await process_frame
		await process_frame
		if not _check(current_scene != null and current_scene.scene_file_path == str(entry.path),
				"more menu opens " + str(entry.path)):
			return
		var back_button: Button = null
		for candidate in current_scene.find_children("*", "Button", true, false):
			if candidate.text.begins_with("返回"):
				back_button = candidate
		if not _check(back_button != null, "more page has return action"):
			return
		back_button.pressed.emit()
		await process_frame
		await process_frame
		if not _check(current_scene != null and current_scene.scene_file_path == "res://scenes/personal_main.tscn",
				"more page returns to the personal jar"):
			return
	current_scene.get("_revaluation_button").pressed.emit()
	await process_frame
	await process_frame
	if not _check(current_scene != null and current_scene.scene_file_path == "res://scenes/personal_manual_revaluation.tscn",
			"manual revaluation button opens its dedicated scene"):
		return
	print("PERSONAL_LAYOUT_PASS: empty finance gating, basic/ecology clearance, ten finance navigation paths")
	quit(0)


func _geometry_clear(scene: Node3D, phase: String) -> bool:
	var ui: Control = scene.get_node("PersonalOverlay").get_child(0)
	var header: Control = ui.get_child(0)
	var footer: Control = scene.get("_footer")
	var camera: Camera3D = scene.get_node("Camera3D")
	var base_screen := camera.unproject_position(Vector3(0.0, -0.08, 0.0))
	var top_screen := camera.unproject_position(Vector3(0.0, 2.6, 0.0))
	var header_bottom: float = (header.get_child(header.get_child_count() - 1) as Control).get_global_rect().end.y
	var footer_top: float = footer.get_global_rect().position.y
	print("LAYOUT ", phase, " header_bottom=", header_bottom,
		" jar_top=", top_screen.y, " jar_base=", base_screen.y,
		" footer_top=", footer_top)
	return is_equal_approx(header.get_global_rect().position.y, 36.0) \
		and header.offset_bottom > header.offset_top \
		and top_screen.y - header_bottom >= 3.0 \
		and footer_top - base_screen.y >= 16.0


func _check(condition: bool, message: String) -> bool:
	if not condition:
		printerr("personal layout failed: ", message)
		quit(1)
		return false
	return true
