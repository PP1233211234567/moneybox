extends RefCounted
## Pure, local ecology state. This service has no ledger, mapping, or inventory input.
## Renderer positions and offline animation frames are deliberately not persisted.

const SECONDS_PER_DAY := 86400
const MAX_SAFE_VERSION := 9007199254740991


static func new_state(scene_id: String, skin_id: String, at_utc: String,
		layout_seed: int = 1, utc_offset_minutes: int = 480) -> Dictionary:
	var now := _utc_unix(at_utc)
	if not _valid_id(scene_id) or not _valid_id(skin_id) or skin_id == "basic" \
		or now < 0 or layout_seed < 0 or layout_seed > MAX_SAFE_VERSION \
		or utc_offset_minutes < -720 or utc_offset_minutes > 840:
		return {}
	var scene := {"id": scene_id, "skin_id": skin_id, "version": 0,
		"last_simulated_at": at_utc, "layout_seed": layout_seed,
		"settings": {"utc_offset_minutes": utc_offset_minutes, "active_skin_id": skin_id},
		"day_night_phase": "", "phase_minute": 0}
	_set_phase(scene, now)
	return {"schema_version": 1, "scene": scene, "organisms": [], "plants": [],
		"applied_commands": {}}


static func apply(state: Dictionary, command: Dictionary) -> Dictionary:
	if not validate(state):
		return _error("INVALID_ECOLOGY_STATE")
	var kind := str(command.get("type", ""))
	if not _valid_command(command, kind):
		return _error("INVALID_ECOLOGY_COMMAND")
	var command_id: String = command.command_id
	var fingerprint := _fingerprint(command)
	var previous: Dictionary = state.applied_commands
	if previous.has(command_id):
		if previous[command_id] != fingerprint:
			return _error("COMMAND_ID_CONFLICT")
		return {"ok": true, "duplicate": true, "state": state.duplicate(true)}
	if int(command.expected_version) != int(state.scene.version):
		return _error("VERSION_CONFLICT")
	if int(state.scene.version) >= MAX_SAFE_VERSION:
		return _error("VERSION_LIMIT")
	var now := _utc_unix(command.effective_at)
	if now < _utc_unix(state.scene.last_simulated_at):
		return _error("TIME_REGRESSION")
	var next := state.duplicate(true)
	_advance_to(next, now, command.effective_at)
	match kind:
		"ADD_ORGANISM":
			if typeof(command.get("species_id")) != TYPE_STRING \
				or not _valid_id(str(command.get("species_id", ""))) \
				or not ["fish", "shrimp"].has(command.get("kind", "")) \
				or not _per_mille(command.get("x_per_mille")) \
				or not _per_mille(command.get("y_per_mille")):
				return _error("INVALID_ORGANISM")
			var organism_id := _entity_id(str(next.scene.id), "organism", command_id)
			next.organisms.append({"id": organism_id, "scene_id": next.scene.id,
				"species_id": command.species_id, "kind": command.kind,
				"growth_stage": "juvenile", "behavior_state": _default_behavior(command.kind),
				"position_hint": {"zone": "outer_water", "x_per_mille": int(command.x_per_mille),
					"y_per_mille": int(command.y_per_mille)},
				"created_at": command.effective_at, "last_fed_at": ""})
		"ADD_PLANT":
			if typeof(command.get("species_id")) != TYPE_STRING \
				or not _valid_id(str(command.get("species_id", ""))) \
				or not _per_mille(command.get("x_per_mille")) \
				or not _per_mille(command.get("depth_per_mille")):
				return _error("INVALID_PLANT")
			var plant_id := _entity_id(str(next.scene.id), "plant", command_id)
			next.plants.append({"id": plant_id, "scene_id": next.scene.id,
				"species_id": command.species_id, "growth_stage": "sprout",
				"anchor": {"zone": "outer_water", "x_per_mille": int(command.x_per_mille),
					"depth_per_mille": int(command.depth_per_mille)},
				"created_at": command.effective_at})
		"MOVE_PLANT":
			if not _per_mille(command.get("x_per_mille")) \
				or not _per_mille(command.get("depth_per_mille")):
				return _error("INVALID_PLANT_ANCHOR")
			var index := _entity_index(next.plants, str(command.get("plant_id", "")))
			if index < 0:
				return _error("PLANT_NOT_FOUND")
			next.plants[index].anchor.x_per_mille = int(command.x_per_mille)
			next.plants[index].anchor.depth_per_mille = int(command.depth_per_mille)
		"FEED":
			var index := _entity_index(next.organisms, str(command.get("organism_id", "")))
			if index < 0:
				return _error("ORGANISM_NOT_FOUND")
			next.organisms[index].last_fed_at = command.effective_at
			next.organisms[index].behavior_state = "foraging" if next.organisms[index].kind == "fish" else "feeding"
		"SET_SKIN":
			var selected := str(command.get("skin_id", ""))
			if selected != "basic" and selected != str(next.scene.skin_id):
				return _error("UNKNOWN_SKIN")
			next.scene.settings.active_skin_id = selected
		"ADVANCE_TIME":
			pass
		_:
			return _error("UNKNOWN_ECOLOGY_COMMAND")
	next.scene.version = int(next.scene.version) + 1
	next.applied_commands[command_id] = fingerprint
	if not validate(next):
		return _error("ECOLOGY_INVARIANT_FAILED")
	return {"ok": true, "duplicate": false, "state": next}


static func validate(state: Dictionary) -> bool:
	if not _only_keys(state, ["schema_version", "scene", "organisms", "plants", "applied_commands"]) \
		or not _whole(state.get("schema_version"), 1, 1) \
		or typeof(state.get("scene")) != TYPE_DICTIONARY \
		or typeof(state.get("organisms")) != TYPE_ARRAY \
		or typeof(state.get("plants")) != TYPE_ARRAY \
		or typeof(state.get("applied_commands")) != TYPE_DICTIONARY:
		return false
	var scene: Dictionary = state.scene
	if not _only_keys(scene, ["id", "skin_id", "version", "last_simulated_at", "layout_seed",
		"settings", "day_night_phase", "phase_minute"]) \
		or not _valid_id(str(scene.get("id", ""))) \
		or not _valid_id(str(scene.get("skin_id", ""))) or scene.skin_id == "basic" \
		or not _whole(scene.get("version"), 0, MAX_SAFE_VERSION) \
		or not _whole(scene.get("layout_seed"), 0, MAX_SAFE_VERSION) \
		or _utc_unix(str(scene.get("last_simulated_at", ""))) < 0 \
		or typeof(scene.get("settings")) != TYPE_DICTIONARY:
		return false
	var settings: Dictionary = scene.settings
	if not _only_keys(settings, ["utc_offset_minutes", "active_skin_id"]) \
		or not _whole(settings.get("utc_offset_minutes"), -720, 840) \
		or not ["basic", scene.skin_id].has(settings.get("active_skin_id", "")):
		return false
	var expected_scene := scene.duplicate(true)
	_set_phase(expected_scene, _utc_unix(scene.last_simulated_at))
	if scene.get("day_night_phase") != expected_scene.day_night_phase \
		or not _whole(scene.get("phase_minute"), 0, 1439) \
		or int(scene.phase_minute) != int(expected_scene.phase_minute):
		return false
	var ids := {}
	for organism_value in state.organisms:
		if typeof(organism_value) != TYPE_DICTIONARY:
			return false
		var organism: Dictionary = organism_value
		if not _only_keys(organism, ["id", "scene_id", "species_id", "kind", "growth_stage",
			"behavior_state", "position_hint", "created_at", "last_fed_at"]) \
			or typeof(organism.get("id")) != TYPE_STRING \
			or not _valid_id(str(organism.get("id", ""))) or ids.has(organism.id) \
			or organism.get("scene_id") != scene.id \
			or typeof(organism.get("species_id")) != TYPE_STRING \
			or not _valid_id(str(organism.get("species_id", ""))) \
			or not ["fish", "shrimp"].has(organism.get("kind", "")) \
			or typeof(organism.get("position_hint")) != TYPE_DICTIONARY:
			return false
		var hint: Dictionary = organism.position_hint
		if not _only_keys(hint, ["zone", "x_per_mille", "y_per_mille"]) \
			or hint.get("zone") != "outer_water" or not _per_mille(hint.get("x_per_mille")) \
			or not _per_mille(hint.get("y_per_mille")):
			return false
		var created := _utc_unix(str(organism.get("created_at", "")))
		var fed_text := str(organism.get("last_fed_at", ""))
		if created < 0 or created > _utc_unix(scene.last_simulated_at) \
			or (not fed_text.is_empty() and (_utc_unix(fed_text) < created \
				or _utc_unix(fed_text) > _utc_unix(scene.last_simulated_at))) \
			or organism.get("growth_stage") != _organism_stage(_utc_unix(scene.last_simulated_at) - created) \
			or not [_default_behavior(organism.kind), "foraging" if organism.kind == "fish" else "feeding"].has(organism.get("behavior_state")):
			return false
		ids[organism.id] = true
	for plant_value in state.plants:
		if typeof(plant_value) != TYPE_DICTIONARY:
			return false
		var plant: Dictionary = plant_value
		if not _only_keys(plant, ["id", "scene_id", "species_id", "growth_stage", "anchor", "created_at"]) \
			or typeof(plant.get("id")) != TYPE_STRING \
			or not _valid_id(str(plant.get("id", ""))) or ids.has(plant.id) \
			or plant.get("scene_id") != scene.id \
			or typeof(plant.get("species_id")) != TYPE_STRING \
			or not _valid_id(str(plant.get("species_id", ""))) \
			or typeof(plant.get("anchor")) != TYPE_DICTIONARY:
			return false
		var anchor: Dictionary = plant.anchor
		if not _only_keys(anchor, ["zone", "x_per_mille", "depth_per_mille"]) \
			or anchor.get("zone") != "outer_water" or not _per_mille(anchor.get("x_per_mille")) \
			or not _per_mille(anchor.get("depth_per_mille")):
			return false
		var created := _utc_unix(str(plant.get("created_at", "")))
		if created < 0 or created > _utc_unix(scene.last_simulated_at) \
			or plant.get("growth_stage") != _plant_stage(_utc_unix(scene.last_simulated_at) - created):
			return false
		ids[plant.id] = true
	for command_id in state.applied_commands:
		if not _valid_id(str(command_id)) or typeof(state.applied_commands[command_id]) != TYPE_STRING:
			return false
	return true


static func _advance_to(state: Dictionary, now: int, at_utc: String) -> void:
	for organism in state.organisms:
		organism.growth_stage = _organism_stage(now - _utc_unix(organism.created_at))
		if not str(organism.last_fed_at).is_empty() \
			and now - _utc_unix(organism.last_fed_at) >= 3600:
			organism.behavior_state = _default_behavior(organism.kind)
	for plant in state.plants:
		plant.growth_stage = _plant_stage(now - _utc_unix(plant.created_at))
	state.scene.last_simulated_at = at_utc
	_set_phase(state.scene, now)


static func _set_phase(scene: Dictionary, now: int) -> void:
	var local_seconds := (now + int(scene.settings.utc_offset_minutes) * 60) % SECONDS_PER_DAY
	if local_seconds < 0:
		local_seconds += SECONDS_PER_DAY
	var minute := int(local_seconds / 60)
	scene.phase_minute = minute
	scene.day_night_phase = "day" if minute >= 360 and minute < 1080 else "night"


static func _organism_stage(age_seconds: int) -> String:
	if age_seconds >= 3 * SECONDS_PER_DAY:
		return "adult"
	if age_seconds >= SECONDS_PER_DAY:
		return "growing"
	return "juvenile"


static func _plant_stage(age_seconds: int) -> String:
	if age_seconds >= 3 * SECONDS_PER_DAY:
		return "mature"
	if age_seconds >= SECONDS_PER_DAY:
		return "young"
	return "sprout"


static func _default_behavior(kind: String) -> String:
	return "cruising" if kind == "fish" else "grazing"


static func _valid_command(command: Dictionary, kind: String) -> bool:
	var allowed := ["command_id", "type", "expected_version", "effective_at"]
	match kind:
		"ADD_ORGANISM":
			allowed.append_array(["species_id", "kind", "x_per_mille", "y_per_mille"])
		"ADD_PLANT":
			allowed.append_array(["species_id", "x_per_mille", "depth_per_mille"])
		"MOVE_PLANT":
			allowed.append_array(["plant_id", "x_per_mille", "depth_per_mille"])
		"FEED":
			allowed.append("organism_id")
		"SET_SKIN":
			allowed.append("skin_id")
		"ADVANCE_TIME":
			pass
		_:
			return false
	return _only_keys(command, allowed) \
		and typeof(command.get("command_id")) == TYPE_STRING \
		and _valid_id(str(command.get("command_id", ""))) \
		and typeof(command.get("expected_version")) in [TYPE_INT, TYPE_FLOAT] \
		and _whole(command.get("expected_version"), 0, MAX_SAFE_VERSION) \
		and typeof(command.get("effective_at")) == TYPE_STRING \
		and _utc_unix(command.effective_at) >= 0


static func _fingerprint(command: Dictionary) -> String:
	var keys := command.keys()
	keys.sort()
	var entries := []
	for key in keys:
		entries.append([key, command[key]])
	return JSON.stringify(entries).sha256_text()


static func _entity_index(entities: Array, entity_id: String) -> int:
	for index in entities.size():
		if entities[index].id == entity_id:
			return index
	return -1


static func _entity_id(scene_id: String, entity_kind: String, command_id: String) -> String:
	return entity_kind + "-" + JSON.stringify([scene_id, entity_kind, command_id]).sha256_text()


static func _only_keys(value: Dictionary, allowed: Array) -> bool:
	for key in value:
		if typeof(key) != TYPE_STRING or not allowed.has(key):
			return false
	return true


static func _whole(value: Variant, minimum: int, maximum: int) -> bool:
	if typeof(value) == TYPE_INT:
		return value >= minimum and value <= maximum
	if typeof(value) == TYPE_FLOAT:
		return value >= minimum and value <= maximum and floor(value) == value
	return false


static func _per_mille(value: Variant) -> bool:
	return _whole(value, 0, 1000)


static func _valid_id(value: String) -> bool:
	return not value.is_empty() and not value.contains("|") and value.length() <= 128


static func _utc_unix(value: String) -> int:
	if value.length() != 20 or value.substr(4, 1) != "-" or value.substr(7, 1) != "-" \
		or value.substr(10, 1) != "T" or value.substr(13, 1) != ":" \
		or value.substr(16, 1) != ":" or not value.ends_with("Z"):
		return -1
	for index in [0, 1, 2, 3, 5, 6, 8, 9, 11, 12, 14, 15, 17, 18]:
		var character := value.substr(index, 1)
		if character < "0" or character > "9":
			return -1
	var raw := value.substr(0, 19)
	var unix := int(Time.get_unix_time_from_datetime_string(raw))
	if unix < 0 or Time.get_datetime_string_from_unix_time(unix) != raw:
		return -1
	return unix


static func _error(code: String) -> Dictionary:
	return {"ok": false, "error": code}
