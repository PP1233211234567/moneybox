extends SceneTree

const Store = preload("res://scripts/data/project_store.gd")
const Ledger = preload("res://scripts/data/ledger_core.gd")
const Mapping = preload("res://scripts/domain/gold_mapping_service.gd")
const Inventory = preload("res://scripts/domain/jar_inventory.gd")
const Ecology = preload("res://scripts/ecology/ecology_service.gd")

const START := "2026-09-24T02:00:00Z"
const RESUME := "2026-09-27T13:00:00Z"

var checks := 0
var failures: Array[String] = []


func _initialize() -> void:
	var directory := ProjectSettings.globalize_path("res://").get_base_dir().path_join("tests") \
		.path_join("data").path_join("tmp")
	DirAccess.make_dir_recursive_absolute(directory)
	var suffix := str(Time.get_ticks_usec())
	_test_save_restore_and_isolation(directory.path_join("ecology-store-" + suffix))
	_test_old_v2_empty_ecology(directory.path_join("ecology-old-v2-" + suffix))
	_test_demo_rejected(directory.path_join("ecology-demo-" + suffix))
	if failures.is_empty():
		print("ECOLOGY STORE TESTS PASS: %d checks" % checks)
		quit(0)
	else:
		for failure in failures:
			printerr(failure)
		printerr("ECOLOGY STORE TESTS FAIL: %d failures in %d checks" % [failures.size(), checks])
		quit(1)


func _check(condition: bool, label: String) -> void:
	checks += 1
	if not condition:
		failures.append(label)


func _command(command_id: String, kind: String, version: int, at_utc: String) -> Dictionary:
	return {"command_id": command_id, "type": kind, "expected_version": version,
		"effective_at": at_utc}


func _financial_fingerprint(project: Dictionary) -> String:
	return JSON.stringify([project.ledger, project.mappings, project.inventory,
		project.quote_gateway, project.valuation]).sha256_text()


func _fixture(store: RefCounted) -> Dictionary:
	var project: Dictionary = store.new_project()
	var account := Ledger.apply(project.ledger, {"command_id": "account", "type": "account_create",
		"account": {"id": "cash", "currency": "CNY", "mode": "detail", "cost_method": "FIFO"}})
	if not account.ok:
		return {}
	var opening := Ledger.apply(account.state, {"command_id": "opening", "type": "opening_cash",
		"account_id": "cash", "amount": "5000", "effective_at": START})
	if not opening.ok:
		return {}
	project.ledger = opening.state
	var quote := {"id": "gold-manual", "price": "1000", "currency": "CNY",
		"unit": "CURRENCY_PER_GRAM", "source": "TEST_MANUAL", "quoted_at": START}
	var mapping := Mapping.create_revision("assets-1", "5000", "CNY", quote)
	if not mapping.ok:
		return {}
	var inventory := Inventory.apply_mapping(Inventory.new_state(), mapping.revision, "inventory-1")
	if not inventory.ok:
		return {}
	project.mappings.append(mapping.revision)
	project.inventory = inventory.state
	return project


func _commit(store: RefCounted, command: Dictionary) -> Dictionary:
	var loaded: Dictionary = store.load_project()
	if not loaded.ok:
		_check(false, "load before ecology command " + str(command.command_id))
		return {}
	var original := JSON.stringify(loaded.state)
	var result: Dictionary = store.commit_ecology_command(command, int(loaded.generation))
	_check(result.ok, "commit %s: %s" % [command.command_id, result.get("error", "")])
	_check(JSON.stringify(loaded.state) == original, "commit keeps caller's project state immutable")
	return result


func _test_save_restore_and_isolation(path: String) -> void:
	var store := Store.new(path)
	var project := _fixture(store)
	_check(not project.is_empty() and Ecology.validate(project.ecology), "seeded project has valid ecology")
	if project.is_empty():
		return
	var seeded := store.save_project(project, 0)
	_check(seeded.ok and seeded.generation == 1, "personal project persisted")
	if not seeded.ok:
		return
	var finance_before := _financial_fingerprint(store.load_project().state)
	var fish := _command("fish-1", "ADD_ORGANISM", 0, START)
	fish.merge({"species_id": "small-fish", "kind": "fish", "x_per_mille": 200,
		"y_per_mille": 450})
	var added_fish := _commit(store, fish)
	if not added_fish.get("ok", false):
		return
	var shrimp := _command("shrimp-1", "ADD_ORGANISM", 1, START)
	shrimp.merge({"species_id": "ornamental-shrimp", "kind": "shrimp", "x_per_mille": 700,
		"y_per_mille": 800})
	_commit(store, shrimp)
	var plant := _command("plant-1", "ADD_PLANT", 2, START)
	plant.merge({"species_id": "seagrass-a", "x_per_mille": 400, "depth_per_mille": 900})
	_commit(store, plant)
	var after_add := store.load_project()
	_check(after_add.state.ecology.organisms.size() == 2 and after_add.state.ecology.plants.size() == 1,
		"fish, shrimp and plant persisted independently")
	var fish_id: String = after_add.state.ecology.organisms[0].id
	var plant_id: String = after_add.state.ecology.plants[0].id
	var feed := _command("feed-1", "FEED", 3, START)
	feed["organism_id"] = fish_id
	_commit(store, feed)
	var move := _command("move-1", "MOVE_PLANT", 4, START)
	move.merge({"plant_id": plant_id, "x_per_mille": 650, "depth_per_mille": 850})
	_commit(store, move)
	var ecology_skin := _command("skin-ecology", "SET_SKIN", 5, START)
	ecology_skin["skin_id"] = "ecology"
	_commit(store, ecology_skin)
	var basic_skin := _command("skin-basic", "SET_SKIN", 6, START)
	basic_skin["skin_id"] = "basic"
	_commit(store, basic_skin)
	var switched := Store.new(path).load_project()
	_check(switched.ok and switched.state.presentation.skin_id == "basic" \
		and switched.state.ecology.scene.settings.active_skin_id == "basic" \
		and switched.state.ecology.organisms.size() == 2 and switched.state.ecology.plants.size() == 1,
		"ordinary skin and restart retain ecology records")
	var advance := _command("resume-3-days", "ADVANCE_TIME", 7, RESUME)
	_commit(Store.new(path), advance)
	var resumed := Store.new(path).load_project()
	_check(resumed.ok and resumed.state.ecology.scene.day_night_phase == "night" \
		and resumed.state.ecology.scene.last_simulated_at == RESUME \
		and resumed.state.ecology.organisms[0].growth_stage == "adult" \
		and resumed.state.ecology.plants[0].growth_stage == "mature",
		"three-day offline growth and night phase survive project restart")
	_check(resumed.state.ecology.organisms[0].id == fish_id \
		and resumed.state.ecology.plants[0].id == plant_id \
		and resumed.state.ecology.plants[0].anchor.x_per_mille == 650 \
		and resumed.state.ecology.organisms[0].behavior_state == "cruising",
		"identity, moved layout and expired feeding hint restored")
	var return_skin := _command("skin-return", "SET_SKIN", 8, RESUME)
	return_skin["skin_id"] = "ecology"
	var returned := _commit(Store.new(path), return_skin)
	_check(returned.ok and Store.new(path).load_project().state.presentation.skin_id == "ecology",
		"ecology skin selection published with saved project")
	var restarted := Store.new(path)
	var before_replay := restarted.load_project()
	var replay := restarted.commit_ecology_command(return_skin, before_replay.generation)
	_check(replay.ok and replay.duplicate and replay.generation == before_replay.generation \
		and restarted.load_project().generation == before_replay.generation,
		"same command after restart does not write a generation")
	var fingerprint_before_errors := JSON.stringify(restarted.load_project().state)
	var bad_command := _command("finance-injection", "ADVANCE_TIME", 9, RESUME)
	bad_command["asset_total"] = "999999"
	var bad := restarted.commit_ecology_command(bad_command, before_replay.generation)
	_check(not bad.ok and bad.error == "INVALID_ECOLOGY_COMMAND",
		"financial field in ecology command rejected")
	var stale_version := _command("stale-version", "ADVANCE_TIME", 1, RESUME)
	_check(restarted.commit_ecology_command(stale_version, before_replay.generation).error \
		== "VERSION_CONFLICT", "stale ecology version rejected")
	var stale_generation := _command("stale-generation", "ADVANCE_TIME", 9, RESUME)
	_check(restarted.commit_ecology_command(stale_generation, before_replay.generation - 1).error \
		== "GENERATION_CONFLICT", "stale project generation rejected")
	_check(JSON.stringify(restarted.load_project().state) == fingerprint_before_errors \
		and restarted.load_project().generation == before_replay.generation,
		"failed ecology commands preserve full project and generation")
	_check(_financial_fingerprint(restarted.load_project().state) == finance_before,
		"ledger, mapping, beans, quotes and valuation fingerprint unchanged")
	var invalid_project: Dictionary = restarted.load_project().state
	invalid_project.ecology.scene.settings.active_skin_id = "unknown"
	_check(restarted.save_project(invalid_project, before_replay.generation).error == "INVALID_PROJECT_SCHEMA" \
		and restarted.load_project().generation == before_replay.generation,
		"malformed canonical ecology cannot be saved")


func _test_old_v2_empty_ecology(path: String) -> void:
	var store := Store.new(path)
	var old := store.new_project()
	old.ecology = {}
	old["custom_marker"] = {"preserve": "yes"}
	var payload := JSON.stringify(old)
	var envelope := {"format": "moneybox-state", "schema_version": 2, "generation": 1,
		"payload": payload, "sha256": payload.sha256_text()}
	var file := FileAccess.open(path + ".1.json", FileAccess.WRITE)
	file.store_string(JSON.stringify(envelope))
	file.close()
	var loaded := store.load_project()
	_check(loaded.ok and loaded.migrated and loaded.generation == 1 \
		and Ecology.validate(loaded.state.ecology) and loaded.state.ecology.scene.version == 0 \
		and loaded.state.custom_marker.preserve == "yes",
		"old v2 empty ecology hydrates in memory without losing other state")
	_check(old.ecology.is_empty() and FileAccess.get_file_as_string(path + ".1.json") \
		== JSON.stringify(envelope), "old slot and input stay unchanged during hydration")
	var add := _command("legacy-plant", "ADD_PLANT", 0, START)
	add.merge({"species_id": "seagrass-a", "x_per_mille": 400, "depth_per_mille": 900})
	var committed := store.commit_ecology_command(add, 1)
	_check(committed.ok and committed.generation == 2 \
		and Store.new(path).load_project().state.ecology.plants.size() == 1,
		"first ecological command writes hydrated v2 to next generation")


func _test_demo_rejected(path: String) -> void:
	var store := Store.new(path)
	var demo := store.new_project()
	demo.data_kind = "demo"
	var saved := store.save_project(demo, 0)
	_check(saved.ok, "demo fixture saved for access check")
	var add := _command("demo-fish", "ADD_ORGANISM", 0, START)
	add.merge({"species_id": "small-fish", "kind": "fish",
		"x_per_mille": 100, "y_per_mille": 200})
	var result := store.commit_ecology_command(add, saved.generation)
	_check(not result.ok and result.error == "PERSONAL_PROJECT_REQUIRED" \
		and store.load_project().generation == saved.generation \
		and store.load_project().state.ecology.organisms.is_empty(),
		"ecology command cannot alter a demo project")
