extends SceneTree

const MAIN_SCENE := preload("res://scenes/main.tscn")


func _initialize() -> void:
	call_deferred("_capture")


func _capture() -> void:
	var scene := MAIN_SCENE.instantiate()
	root.add_child(scene)
	var ecology := OS.get_environment("MONEYBOX_CAPTURE_SKIN") == "ecology"
	var hidden := OS.get_environment("MONEYBOX_CAPTURE_PRIVACY") == "hidden"
	if ecology:
		scene.call("_toggle_skin")
	if hidden:
		scene.call("_toggle_privacy")
	for frame in 90:
		await process_frame
	var texture := root.get_texture()
	if texture == null:
		push_error("Preview capture needs a graphical renderer")
		quit(1)
		return
	var shot := texture.get_image()
	if shot.is_empty():
		push_error("Preview capture returned an empty image")
		quit(1)
		return
	var output_dir := ProjectSettings.globalize_path("res://tmp")
	DirAccess.make_dir_recursive_absolute(output_dir)
	var filename := "jar_hidden_preview.png" if hidden else ("jar_ecology_preview.png" if ecology else "jar_preview.png")
	var output_file := output_dir.path_join(filename)
	var result := shot.save_png(output_file)
	if result != OK:
		push_error("Preview capture could not save image: " + str(result))
		quit(1)
		return
	print("JAR_PREVIEW: " + output_file)
	quit(0)
