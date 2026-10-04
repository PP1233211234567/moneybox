extends SceneTree

## Local engine smoke test; timing is diagnostic and is not a phone performance result.


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var packed: PackedScene = load("res://scenes/jar_view.tscn")
	var jar: JarView = packed.instantiate()
	root.add_child(jar)
	await process_frame
	var small := _snapshot(30, "capacity-30")
	if not _check(jar.apply_inventory_snapshot(small), "30 bean snapshot accepted"):
		return
	if not _check(jar.get_visual_metrics().bean_count == 30, "30 rigid bodies created"):
		return
	var began := Time.get_ticks_msec()
	var large := _snapshot(300, "capacity-300")
	if not _check(jar.apply_inventory_snapshot(large), "300 bean snapshot accepted"):
		return
	var build_ms := Time.get_ticks_msec() - began
	if not _check(jar.get_visual_metrics().bean_count == 300, "300 rigid bodies created"):
		return
	if not _check(jar.get_scene_state().poses.size() == 300, "300 distinct bean poses"):
		return
	for frame in 15:
		await physics_frame
	var before_pause: Dictionary = jar.get_scene_state()
	jar.set_active_visible(false)
	for frame in 15:
		await physics_frame
	if not _check(jar.get_scene_state().poses == before_pause.poses, "hidden scene remains frozen"):
		return
	jar.set_active_visible(true)
	if not _check(jar.restore_scene_state(before_pause), "matching revision restores transient layout"):
		return
	if not _check(not jar.restore_scene_state({"inventory_revision_id": "older", "poses": before_pause.poses}), "old scene revision rejected"):
		return
	if not _check(jar.apply_inventory_snapshot(large) and jar.get_visual_metrics().bean_count == 300, "replay does not duplicate rigid bodies"):
		return
	print("capacity smoke: 30 and 300 bodies passed; build_ms=", build_ms, " (local headless diagnostic)")
	quit(0)


func _snapshot(count: int, revision: String) -> Dictionary:
	var beans: Array[Dictionary] = []
	for index in count:
		beans.append({"id": "bean-%04d" % index, "denomination_grams": 1})
	return {"inventory_revision_id": revision, "skin_id": "basic", "beans": beans}


func _check(condition: bool, reason: String) -> bool:
	if not condition:
		printerr("capacity smoke failed: ", reason)
		quit(1)
		return false
	return true
