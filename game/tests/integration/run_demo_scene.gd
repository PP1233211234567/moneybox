extends SceneTree

const Store = preload("res://scripts/data/project_store.gd")


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var directory := ProjectSettings.globalize_path("res://").path_join("tests").path_join("tmp")
	DirAccess.make_dir_recursive_absolute(directory)
	OS.set_environment("MONEYBOX_DEMO_STATE_PATH", directory.path_join("scene-" + str(Time.get_ticks_usec())))
	var packed: PackedScene = load("res://scenes/main.tscn")
	var first := packed.instantiate()
	root.add_child(first)
	await process_frame
	var jar: JarView = first.get_node("JarView")
	if not _assert(jar.get_visual_metrics().bean_count == 50, "initial persisted 50 beans"):
		return
	first.call("_record_change", "1000")
	await process_frame
	if not _assert(jar.get_visual_metrics().bean_count == 51, "confirmed demo change reaches rigid bodies"):
		return
	var revision_id: String = jar.get_visual_metrics().inventory_revision_id
	first.queue_free()
	await process_frame
	var second := packed.instantiate()
	root.add_child(second)
	await process_frame
	var restored_jar: JarView = second.get_node("JarView")
	if not _assert(restored_jar.get_visual_metrics().bean_count == 51, "scene restart restores bean count"):
		return
	if not _assert(restored_jar.get_visual_metrics().inventory_revision_id == revision_id, "scene restart does not remap"):
		return
	second.call("_toggle_skin")
	await process_frame
	if not _assert(restored_jar.get_visual_metrics().skin_id == "ecology" and restored_jar.get_visual_metrics().bean_count == 51, "skin switch keeps beans"):
		return
	second.queue_free()
	await process_frame
	var third := packed.instantiate()
	root.add_child(third)
	await process_frame
	if not _assert(third.get_node("JarView").get_visual_metrics().skin_id == "ecology", "skin restart restores selection"):
		return
	third.call("_toggle_privacy")
	await process_frame
	if not _assert(third.get("_amount_label").text.find("¥51000") < 0 and third.get("_source_label").text.find("¥1000") < 0, "privacy hides amount and reference price"):
		return
	third.queue_free()
	await process_frame
	var fourth := packed.instantiate()
	root.add_child(fourth)
	await process_frame
	if not _assert(fourth.get("_amount_label").text.find("¥51000") < 0 and fourth.get_node("JarView").get_visual_metrics().bean_count == 51, "privacy persists while beans restore"):
		return
	var store := Store.new(OS.get_environment("MONEYBOX_DEMO_STATE_PATH"))
	var legacy := store.load_project()
	legacy.state.mappings.back().erase("ledger_hash")
	if not _assert(store.save_project(legacy.state, legacy.generation).ok,
			"legacy mapping fixture saves without current ledger proof"):
		return
	fourth.queue_free()
	await process_frame
	var fifth := packed.instantiate()
	root.add_child(fifth)
	await process_frame
	if not _assert(fifth.get("_amount_label").text.find("待核验") >= 0 and
			fifth.get_node("JarView").get_visual_metrics().bean_count == 51,
			"unverified old mapping keeps beans but never publishes a current amount"):
		return
	print("demo scene integration: passed")
	quit(0)


func _assert(condition: bool, message: String) -> bool:
	if not condition:
		printerr("demo scene integration failed: ", message)
		quit(1)
		return false
	return true
