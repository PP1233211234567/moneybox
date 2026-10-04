extends SceneTree

const PERSONAL_SCENE := preload("res://scenes/personal_main.tscn")


func _initialize() -> void:
	call_deferred("_capture")


func _capture() -> void:
	var scene := PERSONAL_SCENE.instantiate()
	root.add_child(scene)
	for frame in 90:
		await process_frame
	var texture := root.get_texture()
	if texture == null:
		push_error("Personal preview needs a graphical renderer")
		quit(1)
		return
	var output_dir := ProjectSettings.globalize_path("res://tmp")
	DirAccess.make_dir_recursive_absolute(output_dir)
	var output_file := output_dir.path_join("personal_empty_preview.png")
	var result := texture.get_image().save_png(output_file)
	if result != OK:
		push_error("Personal preview save failed: " + str(result))
		quit(1)
		return
	print("PERSONAL_PREVIEW: " + output_file)
	quit(0)
