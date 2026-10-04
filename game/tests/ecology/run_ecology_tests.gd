extends SceneTree

const Ecology = preload("res://scripts/ecology/ecology_service.gd")

var failures: Array[String] = []
var checks := 0


func _initialize() -> void:
	_test_t45_offline_restore()
	_test_t46_isolation_and_commands()
	if failures.is_empty():
		print("ECOLOGY TESTS PASS: %d checks" % checks)
		quit(0)
	else:
		for failure in failures:
			printerr(failure)
		printerr("ECOLOGY TESTS FAIL: %d failures in %d checks" % [failures.size(), checks])
		quit(1)


func _check(condition: bool, label: String) -> void:
	checks += 1
	if not condition:
		failures.append(label)


func _apply(state: Dictionary, command: Dictionary) -> Dictionary:
	var result := Ecology.apply(state, command)
	_check(result.ok, "command %s: %s" % [command.command_id, result.get("error", "")])
	return result.state if result.ok else state


func _command(command_id: String, kind: String, version: int, at_utc: String) -> Dictionary:
	return {"command_id": command_id, "type": kind, "expected_version": version,
		"effective_at": at_utc}


func _test_t45_offline_restore() -> void:
	var start := "2026-09-24T02:00:00Z"
	var state := Ecology.new_state("scene-1", "ecology-sea", start, 42)
	_check(Ecology.validate(state), "T45 initial ecology state valid")
	_check(state.scene.day_night_phase == "day", "T45 Asia/Shanghai daytime phase")
	var add_fish := _command("fish-1", "ADD_ORGANISM", 0, start)
	add_fish.merge({"species_id": "small-fish", "kind": "fish",
		"x_per_mille": 250, "y_per_mille": 400})
	state = _apply(state, add_fish)
	var add_shrimp := _command("shrimp-1", "ADD_ORGANISM", 1, start)
	add_shrimp.merge({"species_id": "ornamental-shrimp", "kind": "shrimp",
		"x_per_mille": 700, "y_per_mille": 800})
	state = _apply(state, add_shrimp)
	var add_plant := _command("plant-1", "ADD_PLANT", 2, start)
	add_plant.merge({"species_id": "seagrass-a", "x_per_mille": 550,
		"depth_per_mille": 900})
	state = _apply(state, add_plant)
	var feed := _command("feed-1", "FEED", 3, start)
	feed["organism_id"] = state.organisms[0].id
	state = _apply(state, feed)
	_check(state.organisms[0].behavior_state == "foraging", "T45 feed changes current behavior hint")
	var basic := _command("basic-1", "SET_SKIN", 4, start)
	basic["skin_id"] = "basic"
	state = _apply(state, basic)
	var fish_id: String = state.organisms[0].id
	var shrimp_id: String = state.organisms[1].id
	var plant_id: String = state.plants[0].id
	var restored: Dictionary = JSON.parse_string(JSON.stringify(state))
	_check(Ecology.validate(restored), "T45 state survives JSON restart roundtrip")
	var restored_replay := Ecology.apply(restored, basic)
	_check(restored_replay.ok and restored_replay.duplicate \
		and JSON.stringify(restored_replay.state) == JSON.stringify(restored),
		"T45 command idempotency survives restart")
	_check(restored.scene.settings.active_skin_id == "basic" and restored.organisms.size() == 2 \
		and restored.plants.size() == 1, "T45 ordinary skin preserves ecology records")
	var after_three_days := "2026-09-27T13:00:00Z"
	var advance := _command("resume-3-days", "ADVANCE_TIME", 5, after_three_days)
	var resumed := Ecology.apply(restored, advance)
	_check(resumed.ok and not resumed.has("animation_events"), "T45 offline resume does not backfill animations")
	if not resumed.ok:
		return
	state = resumed.state
	_check(state.scene.last_simulated_at == after_three_days and state.scene.day_night_phase == "night",
		"T45 deterministic last time and night phase")
	_check(state.organisms[0].id == fish_id and state.organisms[1].id == shrimp_id \
		and state.plants[0].id == plant_id, "T45 identities survive restart and offline time")
	_check(state.organisms[0].growth_stage == "adult" and state.organisms[1].growth_stage == "adult" \
		and state.plants[0].growth_stage == "mature", "T45 three day growth reaches bounded stage")
	_check(state.organisms[0].behavior_state == "cruising" \
		and state.organisms[1].behavior_state == "grazing", "T45 old feeding hint expires without replay")
	_check(state.organisms.size() == 2 and state.plants.size() == 1,
		"T45 no offline death or automatic reproduction")
	_check(state.scene.settings.active_skin_id == "basic", "T45 ordinary skin remains selected")
	var back := _command("back-to-ecology", "SET_SKIN", 6, after_three_days)
	back["skin_id"] = "ecology-sea"
	state = _apply(state, back)
	_check(state.scene.settings.active_skin_id == "ecology-sea" and state.organisms.size() == 2 \
		and state.plants.size() == 1 and Ecology.validate(state),
		"T45 switching back restores scene state")
	var far_future := _command("far-future", "ADVANCE_TIME", 7, "2026-10-27T13:00:00Z")
	state = _apply(state, far_future)
	_check(state.organisms[0].growth_stage == "adult" and state.plants[0].growth_stage == "mature",
		"T45 growth stays capped after a long absence")


func _test_t46_isolation_and_commands() -> void:
	var finance := {"ledger": {"asset_total": "100000", "events": [{"id": "opening", "amount": "100000"}]},
		"gold_mapping": {"equivalent_grams": "100", "price_per_gram": "1000"},
		"jar_inventory": {"whole_grams": 100, "beans": [{"id": "bean-1", "denomination_grams": 1}]}}
	var finance_fingerprint := JSON.stringify(finance).sha256_text()
	var start := "2026-09-27T02:00:00Z"
	var state := Ecology.new_state("scene-2", "ecology-sea", start)
	var add_fish := _command("fish-a", "ADD_ORGANISM", 0, start)
	add_fish.merge({"species_id": "small-fish", "kind": "fish",
		"x_per_mille": 200, "y_per_mille": 500})
	var before := JSON.stringify(state)
	var added := Ecology.apply(state, add_fish)
	_check(added.ok and JSON.stringify(state) == before, "T46 add returns new state without mutating input")
	if not added.ok:
		return
	state = added.state
	_check(state.organisms.size() == 1 and state.organisms[0].position_hint.zone == "outer_water",
		"T46 user adds one outer-water fish")
	var replay := Ecology.apply(state, add_fish)
	_check(replay.ok and replay.duplicate and JSON.stringify(replay.state) == JSON.stringify(state),
		"T46 repeated add command is idempotent")
	var conflict := add_fish.duplicate(true)
	conflict.x_per_mille = 300
	_check(Ecology.apply(state, conflict).error == "COMMAND_ID_CONFLICT",
		"T46 reused command id with different payload rejected")
	var stale := _command("stale-shrimp", "ADD_ORGANISM", 0, start)
	stale.merge({"species_id": "ornamental-shrimp", "kind": "shrimp",
		"x_per_mille": 400, "y_per_mille": 800})
	_check(Ecology.apply(state, stale).error == "VERSION_CONFLICT",
		"T46 stale version rejected")
	stale.expected_version = 1
	state = _apply(state, stale)
	var plant := _command("plant-a", "ADD_PLANT", 2, start)
	plant.merge({"species_id": "seagrass-a", "x_per_mille": 300,
		"depth_per_mille": 850})
	state = _apply(state, plant)
	var move := _command("move-plant", "MOVE_PLANT", 3, start)
	move.merge({"plant_id": state.plants[0].id, "x_per_mille": 650,
		"depth_per_mille": 900})
	var old_state := JSON.stringify(state)
	state = _apply(state, move)
	_check(state.plants[0].anchor.x_per_mille == 650 and state.plants[0].anchor.zone == "outer_water" \
		and old_state != JSON.stringify(state), "T46 plant moved only in outer layout")
	var feed := _command("feed-fish", "FEED", 4, start)
	feed["organism_id"] = state.organisms[0].id
	state = _apply(state, feed)
	_check(state.organisms[0].behavior_state == "foraging" and state.organisms.size() == 2,
		"T46 feeding changes hint without changing population")
	var injected := _command("bad-finance", "ADVANCE_TIME", 5, start)
	injected["financial_state"] = finance
	_check(Ecology.apply(state, injected).error == "INVALID_ECOLOGY_COMMAND",
		"T46 ecology command refuses financial state")
	var mixed_state := state.duplicate(true)
	mixed_state["ledger"] = finance.ledger
	_check(Ecology.apply(mixed_state, _command("bad-mixed", "ADVANCE_TIME", 5, start)).error \
		== "INVALID_ECOLOGY_STATE", "T46 ecology service refuses mixed financial state")
	_check(JSON.stringify(finance).sha256_text() == finance_fingerprint,
		"T46 ledger, mapping and bean inventory fingerprint unchanged")
	_check(not state.has("ledger") and not state.has("gold_mapping") and not state.has("jar_inventory") \
		and Ecology.validate(state), "T46 ecology output contains no financial state")
	var long_scene := Ecology.new_state("s".repeat(128), "ecology-sea", start)
	var long_add := _command("c".repeat(128), "ADD_ORGANISM", 0, start)
	long_add.merge({"species_id": "small-fish", "kind": "fish",
		"x_per_mille": 100, "y_per_mille": 100})
	var long_result := Ecology.apply(long_scene, long_add)
	_check(long_result.ok and Ecology.validate(long_result.state) \
		and long_result.state.organisms[0].id.length() <= 128,
		"T46 deterministic individual ID remains valid for long command IDs")
