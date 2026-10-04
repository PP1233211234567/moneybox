extends SceneTree

const Store = preload("res://scripts/data/project_store.gd")
const Ledger = preload("res://scripts/data/ledger_core.gd")


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var directory := ProjectSettings.globalize_path("res://").path_join("tests/tmp")
	DirAccess.make_dir_recursive_absolute(directory)
	var base := directory.path_join("personal-scene-" + str(Time.get_ticks_usec()))
	OS.set_environment("MONEYBOX_PERSONAL_STATE_PATH", base)
	var packed: PackedScene = load("res://scenes/personal_main.tscn")
	var first := packed.instantiate()
	root.add_child(first)
	await process_frame
	if not _check(first.get_node("JarView").get_visual_metrics().bean_count == 0
			and first.get_node("JarView").get_visual_metrics().inventory_revision_id.is_empty()
			and first.get("_onboarding").visible,
			"EMPTY display snapshot produces an unversioned empty personal jar"):
		return
	first.get("_name_input").text = "现金"
	first.get("_amount_input").text = "50000"
	first.get("_gold_input").text = "1000"
	first.call("_create_opening")
	await process_frame
	if not _check(first.get_node("JarView").get_visual_metrics().bean_count == 50 and not first.get("_onboarding").visible, "confirmed personal opening shows 50 real bodies"):
		return
	first.get("_delta_input").text = "1000"
	first.call("_record_change")
	await process_frame
	if not _check(first.get_node("JarView").get_visual_metrics().bean_count == 51, "confirmed personal deposit shows one new body"):
		return
	if not _check(first.get("_source_label").text.find("手工参考金价 ¥1000/g") >= 0,
			"current mapping reference price appears with its confirmed manual source"):
		return
	var store := Store.new(base)
	var finance_before := _finance_fingerprint(store.load_project().state)
	first.call("_toggle_skin")
	first.call("_toggle_privacy")
	await process_frame
	var first_jar: JarView = first.get_node("JarView")
	if not _check(first.get("_ecology_panel").visible and first_jar.get_ecology_metrics().organism_count == 0,
			"ecology skin opens with no invented saved organisms"):
		return
	first.call("_add_fish")
	first.call("_add_shrimp")
	first.call("_add_or_move_plant")
	await process_frame
	var ecology_before_move := first_jar.get_ecology_metrics()
	if not _check(ecology_before_move.organism_count == 2 and ecology_before_move.plant_count == 1
			and ecology_before_move.kinds.has("fish") and ecology_before_move.kinds.has("shrimp")
			and first_jar.get_node("EcologyVisualOnly/SavedEcologyVisuals").get_child_count() == 3,
			"saved fish, shrimp and seaweed render as separate outer visuals"):
		return
	for organism_node in first_jar.get("_organism_nodes").values():
		var base_position: Vector3 = organism_node.get_meta("base_position")
		if not _check(Vector2(base_position.x, base_position.z).length() > 1.0
				and (organism_node.find_child("EcoFishBody", true, false) is MeshInstance3D
				or organism_node.find_child("EcoShrimpSegment00", true, false) is MeshInstance3D),
				"saved organism uses formal GLB mesh in outer annulus"):
			return
	first.call("_feed_first_organism")
	first.call("_add_or_move_plant")
	await process_frame
	var ecology_after_move := first_jar.get_ecology_metrics()
	var plant_id: String = ecology_before_move.plant_ids[0]
	if not _check(ecology_after_move.feeding_count == 1
			and ecology_after_move.plant_positions[plant_id] != ecology_before_move.plant_positions[plant_id],
			"feeding and moving seaweed visibly update saved ecology"):
		return
	first.call("_toggle_skin")
	await process_frame
	if not _check(first_jar.get_visual_metrics().skin_id == "basic"
			and not first_jar.get_node("GoldJarModel").find_child("EcologyOuter", true, false).visible
			and first_jar.get_ecology_metrics().organism_count == 2,
			"basic skin hides outer shell without deleting ecology state"):
		return
	first.call("_toggle_skin")
	await process_frame
	if not _check(first_jar.get_visual_metrics().skin_id == "ecology"
			and first_jar.get_ecology_metrics().organism_count == 2
			and _finance_fingerprint(store.load_project().state) == finance_before,
			"ecology operations and skin switches preserve ledger, mapping, inventory, quotes and valuation"):
		return
	if not _check(first.get("_amount_label").text.find("¥51000") < 0 and first.get("_source_label").text.find("¥1000") < 0, "personal privacy hides amount and manual price"):
		return
	first.queue_free()
	await process_frame
	var second := packed.instantiate()
	root.add_child(second)
	await process_frame
	if not _check(second.get_node("JarView").get_visual_metrics().bean_count == 51 and second.get_node("JarView").get_visual_metrics().skin_id == "ecology", "personal scene restart restores beans and skin"):
		return
	var saved: Dictionary = store.load_project().state
	var expected_revision: String = str(saved.mappings.back().id) + ":" + str(int(saved.inventory.revision))
	if not _check(second.get_node("JarView").get_visual_metrics().inventory_revision_id == expected_revision
			and second.get_node("JarView").get_ecology_metrics().organism_count == 2
			and second.get_node("JarView").get_ecology_metrics().plant_count == 1
			and second.get_node("JarView").get_ecology_metrics().feeding_count == 1
			and second.get_node("JarView").get_ecology_metrics().plant_ids.has(plant_id),
			"display snapshot version and persisted ecology restore together"):
		return
	if not _check(second.get("_amount_label").text.find("¥51000") < 0 and second.get("_privacy_mode") == "hide_total", "personal scene restart restores privacy"):
		return
	var loaded := store.load_project()
	var added := Ledger.apply(loaded.state.ledger, {"command_id": "imported-after-scene", "type": "cash_delta", "account_id": "cash-1", "delta": "100", "external": true, "effective_at": "2026-09-27T03:00:00Z"})
	if not _check(added.ok, "pending fixture ledger event accepted"):
		return
	loaded.state.ledger = added.state
	loaded.state.valuation_pending = {"reason": "CSV_IMPORT", "ledger_hash": Store.canonical_ledger_hash(added.state)}
	if not _check(store.save_project(loaded.state, loaded.generation).ok, "pending fixture saved"):
		return
	second.queue_free()
	await process_frame
	var third := packed.instantiate()
	root.add_child(third)
	await process_frame
	if not _check(third.get("_amount_label").text.find("上次完整快照") >= 0 and third.get("_source_label").text.find("上次完整快照") >= 0, "pending page labels old beans as previous snapshot"):
		return
	if not _check(third.get("_update_button").disabled
			and third.get("_revaluation_button").text == "去重估"
			and third.get_node("JarView").get_visual_metrics().bean_count == 51,
			"pending page blocks stale cash remapping and shows revaluation entry"):
		return
	var legacy := store.load_project()
	legacy.state.ledger = saved.ledger.duplicate(true)
	legacy.state.valuation_pending = {}
	legacy.state.mappings.back().erase("ledger_hash")
	if not _check(store.save_project(legacy.state, legacy.generation).ok,
			"legacy mapping fixture without ledger hash saved"):
		return
	third.queue_free()
	await process_frame
	var fourth := packed.instantiate()
	root.add_child(fourth)
	await process_frame
	if not _check(fourth.get("_amount_label").text.find("上次完整快照") >= 0
			and fourth.get("_source_label").text.find("上次完整快照") >= 0
			and fourth.get("_update_button").disabled
			and fourth.get_node("JarView").get_visual_metrics().bean_count == 51,
			"legacy unverified mapping stays previous even with no valuation_pending"):
		return
	print("personal scene integration: passed")
	quit(0)


func _check(condition: bool, message: String) -> bool:
	if not condition:
		printerr("personal scene integration failed: ", message)
		quit(1)
		return false
	return true


func _finance_fingerprint(project: Dictionary) -> String:
	return JSON.stringify([project.ledger, project.mappings, project.inventory,
		project.quote_gateway, project.valuation]).sha256_text()
