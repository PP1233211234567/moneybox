extends SceneTree
## Run with the graphical Godot executable (not --headless). Uses isolated test stores.


func _initialize() -> void:
	call_deferred("_capture")


func _capture() -> void:
	var project_dir := ProjectSettings.globalize_path("res://project.godot").get_base_dir().get_base_dir()
	var work_dir := project_dir.path_join("tests/tmp")
	var evidence_dir := project_dir.path_join("docs/evidence")
	DirAccess.make_dir_recursive_absolute(work_dir)
	DirAccess.make_dir_recursive_absolute(evidence_dir)
	var run_id := str(Time.get_ticks_usec())
	OS.set_environment("MONEYBOX_DEMO_STATE_PATH", work_dir.path_join("formal-demo-" + run_id))
	var demo: Node3D = load("res://scenes/main.tscn").instantiate()
	root.add_child(demo)
	await create_timer(2.0).timeout
	if not _save(evidence_dir.path_join("formal_jar_desktop_basic.png")):
		quit(1)
		return
	demo.queue_free()
	await process_frame
	OS.set_environment("MONEYBOX_PERSONAL_STATE_PATH", work_dir.path_join("formal-personal-" + run_id))
	var personal: Node3D = load("res://scenes/personal_main.tscn").instantiate()
	root.add_child(personal)
	await create_timer(0.5).timeout
	if not _save(evidence_dir.path_join("formal_jar_desktop_empty.png")):
		quit(1)
		return
	personal.get("_name_input").text = "截图测试现金"
	personal.get("_amount_input").text = "50000"
	personal.get("_gold_input").text = "1000"
	personal.call("_create_opening")
	personal.call("_toggle_skin")
	personal.call("_add_fish")
	personal.call("_add_shrimp")
	personal.call("_add_or_move_plant")
	await create_timer(2.0).timeout
	if not _save(evidence_dir.path_join("formal_jar_desktop_ecology.png")):
		quit(1)
		return
	print("FORMAL_PREVIEW_CAPTURED: basic, empty, ecology")
	quit(0)


func _save(path: String) -> bool:
	var image: Image = root.get_texture().get_image()
	var error := image.save_png(path)
	if error != OK:
		printerr("Formal preview capture failed: ", path, " code=", error)
		return false
	print("CAPTURED ", path, " ", image.get_width(), "x", image.get_height())
	return true
