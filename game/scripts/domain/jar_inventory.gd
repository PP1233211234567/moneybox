extends RefCounted
## Persisted logical beans. Renderer positions are deliberately absent from this state.

const Decimal = preload("res://scripts/data/decimal_text.gd")
const DEFAULT_JAR_LIMIT := 300


static func new_state(max_objects_per_jar: int = DEFAULT_JAR_LIMIT,
		max_volume_units_per_jar: int = DEFAULT_JAR_LIMIT) -> Dictionary:
	if max_objects_per_jar < 1 or max_volume_units_per_jar < 10:
		return {}
	var state := {
		"revision": 0,
		"mapping_id": "",
		"whole_grams": 0,
		"fractional_grams": "0",
		"beans": [],
		"jars": [{"id": "jar-000001", "active_objects": 0, "active_volume_units": 0}],
		"next_bean_seq": 1,
		"next_jar_seq": 2,
		"max_objects_per_jar": max_objects_per_jar,
		"max_volume_units_per_jar": max_volume_units_per_jar,
		"applied_commands": {},
		"mapping_history": {},
		"operations": [],
	}
	state["state_hash"] = _state_hash(state)
	return state


static func apply_mapping(state: Dictionary, mapping: Dictionary, command_id: String,
		expected_revision: int = -1) -> Dictionary:
	if not mapping.get("ok", true):
		return _error("INVALID_MAPPING", state)
	var whole_text: String = str(mapping.get("whole_grams", ""))
	if not whole_text.is_valid_int() or whole_text.begins_with("-"):
		return _error("INVALID_WHOLE_GRAMS", state)
	var whole: int = whole_text.to_int()
	if str(whole) != whole_text:
		return _error("WHOLE_GRAMS_OVERFLOW", state)
	return reconcile(state, whole, str(mapping.get("fractional_grams", "")),
		str(mapping.get("id", "")), command_id, expected_revision)


static func reconcile(state: Dictionary, target_whole: int, fractional: String,
		mapping_id: String, command_id: String, expected_revision: int = -1) -> Dictionary:
	if state.is_empty() or not validate(state):
		return _error("INVALID_STATE", state)
	if target_whole < 0 or not _valid_fraction(fractional):
		return _error("INVALID_TARGET", state)
	if mapping_id.is_empty() or command_id.is_empty():
		return _error("MISSING_ID", state)
	var fraction: String = Decimal.canonical(fractional)
	var fingerprint: String = JSON.stringify(["RECONCILE", mapping_id, target_whole, fraction])
	var command_result := _check_command(state, command_id, fingerprint)
	if not command_result.is_empty():
		return command_result
	var mapping_history: Dictionary = state.get("mapping_history", {})
	if mapping_history.has(mapping_id):
		if mapping_history[mapping_id] == fingerprint:
			return {"ok": true, "duplicate": true, "state": state.duplicate(true)}
		return _error("MAPPING_ID_REUSED", state)
	if expected_revision >= 0 and int(state.revision) != expected_revision:
		return _error("REVISION_CONFLICT", state)
	var next: Dictionary = state.duplicate(true)
	var previous_whole: int = int(next.whole_grams)
	var added: Array = []
	var retired: Array = []
	var automatic_splits: Array = []
	if target_whole > previous_whole:
		for _i in range(target_whole - previous_whole):
			added.append(_add_bean(next, 1, command_id))
	elif target_whole < previous_whole:
		var remove_count: int = previous_whole - target_whole
		remove_count = _retire_recent_ones(next, remove_count, command_id, retired)
		while remove_count > 0:
			var ten_index: int = _last_active_ten_index(next.beans)
			if ten_index < 0:
				return _error("INSUFFICIENT_BEANS", state)
			var old_id: String = str(next.beans[ten_index].id)
			_retire_bean(next, ten_index, command_id, retired)
			var child_ids: Array = []
			for _i in 10:
				child_ids.append(_add_bean(next, 1, command_id, old_id))
			automatic_splits.append({"source_id": old_id, "child_ids": child_ids,
				"reason": "REVALUATION_SPLIT"})
			remove_count = _retire_recent_ones(next, remove_count, command_id, retired)
	next.whole_grams = target_whole
	next.fractional_grams = fraction
	next.mapping_id = mapping_id
	next.revision = int(next.revision) + 1
	next.applied_commands[command_id] = fingerprint
	next.mapping_history[mapping_id] = fingerprint
	next.operations.append({"command_id": command_id, "type": "RECONCILE",
		"mapping_id": mapping_id, "added_ids": added, "retired_ids": retired,
		"automatic_splits": automatic_splits, "revision": next.revision})
	if not validate(next):
		return _error("INVARIANT_FAILED", state)
	next.state_hash = _state_hash(next)
	return {"ok": true, "duplicate": false, "state": next,
		"added_ids": added, "retired_ids": retired,
		"automatic_splits": automatic_splits,
		"delta_whole_grams": target_whole - previous_whole}


static func combine(state: Dictionary, bean_ids: Array, command_id: String,
		expected_revision: int = -1) -> Dictionary:
	if state.is_empty() or not validate(state):
		return _error("INVALID_STATE", state)
	if bean_ids.size() != 10 or command_id.is_empty():
		return _error("INVALID_SELECTION", state)
	var sorted_ids: Array = bean_ids.duplicate()
	sorted_ids.sort()
	for index in range(1, sorted_ids.size()):
		if sorted_ids[index] == sorted_ids[index - 1]:
			return _error("DUPLICATE_BEAN_ID", state)
	var fingerprint: String = JSON.stringify(["COMBINE", sorted_ids])
	var command_result := _check_command(state, command_id, fingerprint)
	if not command_result.is_empty():
		return command_result
	if expected_revision >= 0 and int(state.revision) != expected_revision:
		return _error("REVISION_CONFLICT", state)
	var next: Dictionary = state.duplicate(true)
	var indexes: Array[int] = []
	var preferred_jar := ""
	for bean_id in sorted_ids:
		var index: int = _active_index(next.beans, str(bean_id))
		if index < 0 or int(next.beans[index].denomination_grams) != 1:
			return _error("SELECTION_NOT_TEN_ACTIVE_ONES", state)
		var bean_jar := str(next.beans[index].jar_id)
		if preferred_jar.is_empty():
			preferred_jar = bean_jar
		elif preferred_jar != bean_jar:
			preferred_jar = "*"
		indexes.append(index)
	var retired: Array = []
	for index in indexes:
		_retire_bean(next, index, command_id, retired)
	var result_id: String = _add_bean(next, 10, command_id, "",
		"" if preferred_jar == "*" else preferred_jar)
	next.revision = int(next.revision) + 1
	next.applied_commands[command_id] = fingerprint
	next.operations.append({"command_id": command_id, "type": "COMBINE",
		"input_ids": sorted_ids, "output_ids": [result_id], "revision": next.revision})
	if not validate(next):
		return _error("INVARIANT_FAILED", state)
	next.state_hash = _state_hash(next)
	return {"ok": true, "duplicate": false, "state": next,
		"input_ids": retired, "output_id": result_id}


static func split(state: Dictionary, bean_id: String, command_id: String,
		expected_revision: int = -1) -> Dictionary:
	if state.is_empty() or not validate(state):
		return _error("INVALID_STATE", state)
	if bean_id.is_empty() or command_id.is_empty():
		return _error("MISSING_ID", state)
	var fingerprint: String = JSON.stringify(["SPLIT", bean_id])
	var command_result := _check_command(state, command_id, fingerprint)
	if not command_result.is_empty():
		return command_result
	if expected_revision >= 0 and int(state.revision) != expected_revision:
		return _error("REVISION_CONFLICT", state)
	var next: Dictionary = state.duplicate(true)
	var index: int = _active_index(next.beans, bean_id)
	if index < 0 or int(next.beans[index].denomination_grams) != 10:
		return _error("SELECTION_NOT_ACTIVE_TEN", state)
	var source_jar: String = str(next.beans[index].jar_id)
	var retired: Array = []
	_retire_bean(next, index, command_id, retired)
	var children: Array = []
	for _i in 10:
		children.append(_add_bean(next, 1, command_id, bean_id, source_jar))
	next.revision = int(next.revision) + 1
	next.applied_commands[command_id] = fingerprint
	next.operations.append({"command_id": command_id, "type": "SPLIT",
		"input_ids": [bean_id], "output_ids": children, "revision": next.revision})
	if not validate(next):
		return _error("INVARIANT_FAILED", state)
	next.state_hash = _state_hash(next)
	return {"ok": true, "duplicate": false, "state": next,
		"input_id": bean_id, "output_ids": children}


static func active_beans(state: Dictionary, jar_id: String = "") -> Array:
	var result: Array = []
	for bean in state.get("beans", []):
		if bean.get("status", "") == "active" and (jar_id.is_empty() or bean.get("jar_id", "") == jar_id):
			result.append(bean.duplicate(true))
	return result


static func validate(state: Dictionary) -> bool:
	for required in ["whole_grams", "fractional_grams", "beans", "jars", "revision",
			"next_bean_seq", "next_jar_seq", "applied_commands", "mapping_history", "operations"]:
		if not state.has(required):
			return false
	if typeof(state.beans) != TYPE_ARRAY or typeof(state.jars) != TYPE_ARRAY or \
			typeof(state.applied_commands) != TYPE_DICTIONARY or \
			typeof(state.mapping_history) != TYPE_DICTIONARY:
		return false
	if int(state.get("whole_grams", -1)) < 0 or not _valid_fraction(str(state.get("fractional_grams", ""))):
		return false
	var max_objects: int = int(state.get("max_objects_per_jar", 0))
	var max_volume: int = int(state.get("max_volume_units_per_jar", 0))
	if max_objects < 1 or max_volume < 10:
		return false
	var jars: Dictionary = {}
	for jar in state.get("jars", []):
		var jar_id: String = str(jar.get("id", ""))
		if jar_id.is_empty() or jars.has(jar_id):
			return false
		jars[jar_id] = {"objects": 0, "volume": 0}
	var ids: Dictionary = {}
	var total := 0
	for bean in state.get("beans", []):
		var bean_id: String = str(bean.get("id", ""))
		if bean_id.is_empty() or ids.has(bean_id):
			return false
		ids[bean_id] = true
		var denomination: int = int(bean.get("denomination_grams", 0))
		if denomination != 1 and denomination != 10:
			return false
		if bean.get("status", "") == "active":
			var jar_id: String = str(bean.get("jar_id", ""))
			if not jars.has(jar_id):
				return false
			jars[jar_id].objects += 1
			jars[jar_id].volume += denomination
			total += denomination
		elif bean.get("status", "") != "retired":
			return false
	if total != int(state.whole_grams):
		return false
	for occupancy in jars.values():
		if int(occupancy.objects) > max_objects or int(occupancy.volume) > max_volume:
			return false
	for jar in state.jars:
		var occupancy: Dictionary = jars[str(jar.id)]
		if int(jar.get("active_objects", -1)) != int(occupancy.objects) or \
				int(jar.get("active_volume_units", -1)) != int(occupancy.volume):
			return false
	return true


static func _add_bean(state: Dictionary, denomination: int, operation_id: String,
		source_id: String = "", preferred_jar_id: String = "") -> String:
	var jar_id: String = _jar_with_space(state, denomination, preferred_jar_id)
	var seq: int = int(state.next_bean_seq)
	state.next_bean_seq = seq + 1
	var bean_id := "bean-%09d" % seq
	state.beans.append({"id": bean_id, "jar_id": jar_id,
		"denomination_grams": denomination, "status": "active",
		"created_seq": seq, "created_revision": int(state.revision) + 1,
		"operation_id": operation_id, "source_id": source_id})
	for jar in state.jars:
		if jar.id == jar_id:
			jar.active_objects = int(jar.active_objects) + 1
			jar.active_volume_units = int(jar.active_volume_units) + denomination
			break
	return bean_id


static func _jar_with_space(state: Dictionary, denomination: int,
		preferred_jar_id: String = "") -> String:
	if not preferred_jar_id.is_empty():
		for jar in state.jars:
			if str(jar.id) == preferred_jar_id and \
					int(jar.active_objects) + 1 <= int(state.max_objects_per_jar) and \
					int(jar.active_volume_units) + denomination <= int(state.max_volume_units_per_jar):
				return preferred_jar_id
	for jar in state.jars:
		if int(jar.active_objects) + 1 <= int(state.max_objects_per_jar) and \
				int(jar.active_volume_units) + denomination <= int(state.max_volume_units_per_jar):
			return str(jar.id)
	var seq: int = int(state.next_jar_seq)
	state.next_jar_seq = seq + 1
	var jar_id := "jar-%06d" % seq
	state.jars.append({"id": jar_id, "active_objects": 0, "active_volume_units": 0})
	return jar_id


static func _retire_recent_ones(state: Dictionary, remove_count: int, operation_id: String,
		retired: Array) -> int:
	for index in range(state.beans.size() - 1, -1, -1):
		if remove_count == 0:
			break
		if state.beans[index].status == "active" and int(state.beans[index].denomination_grams) == 1:
			_retire_bean(state, index, operation_id, retired)
			remove_count -= 1
	return remove_count


static func _retire_bean(state: Dictionary, index: int, operation_id: String,
		retired: Array) -> void:
	var jar_id: String = str(state.beans[index].jar_id)
	var denomination: int = int(state.beans[index].denomination_grams)
	for jar in state.jars:
		if jar.id == jar_id:
			jar.active_objects = int(jar.active_objects) - 1
			jar.active_volume_units = int(jar.active_volume_units) - denomination
			break
	state.beans[index].status = "retired"
	state.beans[index].retired_by = operation_id
	retired.append(str(state.beans[index].id))


static func _last_active_ten_index(beans: Array) -> int:
	for index in range(beans.size() - 1, -1, -1):
		if beans[index].status == "active" and int(beans[index].denomination_grams) == 10:
			return index
	return -1


static func _active_index(beans: Array, bean_id: String) -> int:
	for index in beans.size():
		if beans[index].id == bean_id and beans[index].status == "active":
			return index
	return -1


static func _valid_fraction(value: String) -> bool:
	if not Decimal.is_valid(value):
		return false
	return Decimal.compare(value, "0") >= 0 and Decimal.compare(value, "1") < 0


static func _check_command(state: Dictionary, command_id: String, fingerprint: String) -> Dictionary:
	var previous: Dictionary = state.get("applied_commands", {})
	if not previous.has(command_id):
		return {}
	if previous[command_id] == fingerprint:
		return {"ok": true, "duplicate": true, "state": state.duplicate(true)}
	return _error("COMMAND_ID_REUSED", state)


static func _state_hash(state: Dictionary) -> String:
	var active: Array[String] = []
	for bean in state.beans:
		if bean.status == "active":
			active.append("%s:%s:%d" % [bean.id, bean.jar_id, int(bean.denomination_grams)])
	active.sort()
	return JSON.stringify([state.mapping_id, state.whole_grams,
		state.fractional_grams, active]).sha256_text()


static func _error(code: String, state: Dictionary) -> Dictionary:
	return {"ok": false, "error": code, "state": state.duplicate(true)}
