extends RefCounted
## Confirmed presentation-only bean changes. Financial state and mapping are immutable here.

const Store = preload("res://scripts/data/project_store.gd")
const Inventory = preload("res://scripts/domain/jar_inventory.gd")
const Display = preload("res://scripts/data/display_snapshot_service.gd")

var _store: RefCounted


func _init(base_path: String = "user://personal/moneybox") -> void:
	_store = Store.new(base_path)


func load() -> Dictionary:
	var loaded: Dictionary = _store.load_project()
	if not loaded.ok:
		return loaded
	var project: Dictionary = loaded.state
	if project.get("data_kind", "") != "personal":
		return {"ok": false, "error": "PERSONAL_PROJECT_REQUIRED"}
	if project.mappings.is_empty() or not Inventory.validate(project.inventory):
		return {"ok": false, "error": "NOT_INITIALIZED"}
	var selected_jar := str(project.presentation.get("selected_jar", ""))
	var display := Display.build(project, int(loaded.generation), selected_jar)
	if not display.ok:
		return display
	var jars: Array = []
	for jar in project.inventory.jars:
		var jar_id := str(jar.id)
		var beans := Inventory.active_beans(project.inventory, jar_id)
		var one_count := 0
		var ten_count := 0
		for bean in beans:
			if int(bean.denomination_grams) == 1:
				one_count += 1
			else:
				ten_count += 1
		jars.append({"id": jar_id, "one_count": one_count, "ten_count": ten_count,
			"beans": beans})
	return {"ok": true, "generation": int(loaded.generation),
		"inventory_revision": int(project.inventory.revision),
		"state_hash": str(project.inventory.state_hash),
		"whole_grams": str(int(project.inventory.whole_grams)),
		"fractional_grams": str(project.inventory.fractional_grams),
		"selected_jar": selected_jar,
		"snapshot_status": str(display.snapshot.snapshot_status),
		"privacy_mode": str(project.presentation.get("privacy_mode", "show_total")),
		"jars": jars}


func preview_combine(jar_id: String, bean_ids: Array,
		expected_generation: int) -> Dictionary:
	return _preview("COMBINE", jar_id, bean_ids, expected_generation)


func preview_split(jar_id: String, bean_id: String,
		expected_generation: int) -> Dictionary:
	return _preview("SPLIT", jar_id, [bean_id], expected_generation)


func confirm(preview: Dictionary, confirmed: bool) -> Dictionary:
	if not confirmed or not ["COMBINE", "SPLIT"].has(str(preview.get("mode", ""))):
		return {"ok": false, "error": "EXPLICIT_CONFIRMATION_REQUIRED"}
	var mode := str(preview.mode)
	var jar_id := str(preview.get("jar_id", ""))
	var bean_ids: Variant = preview.get("bean_ids", null)
	var command_id := str(preview.get("preview_id", ""))
	var generation := int(preview.get("generation", -1))
	if typeof(bean_ids) != TYPE_ARRAY or command_id.is_empty() or generation < 1:
		return {"ok": false, "error": "INVALID_PREVIEW"}
	var loaded: Dictionary = _store.load_project()
	if not loaded.ok:
		return loaded
	var project: Dictionary = loaded.state
	if project.get("data_kind", "") != "personal" or project.mappings.is_empty() \
			or not Inventory.validate(project.inventory):
		return {"ok": false, "error": "NOT_INITIALIZED"}
	if int(loaded.generation) != generation:
		# A retry after a successful write may return the saved result. Other stale
		# previews never change the project.
		if project.inventory.applied_commands.has(command_id):
			var replay := _apply(project.inventory, mode, bean_ids, command_id,
				int(preview.get("inventory_revision", -1)))
			if replay.ok and replay.duplicate:
				var visible: Dictionary = self.load()
				visible["duplicate"] = true
				return visible
		return {"ok": false, "error": "GENERATION_CONFLICT"}
	var verified := _preview(mode, jar_id, bean_ids, generation)
	if not verified.ok or verified.preview_id != command_id \
			or str(preview.get("state_hash", "")) != str(verified.state_hash) \
			or int(preview.get("inventory_revision", -1)) != int(verified.inventory_revision):
		return {"ok": false, "error": "PREVIEW_CHANGED"}
	var applied := _apply(project.inventory, mode, bean_ids, command_id,
		int(project.inventory.revision))
	if not applied.ok or applied.duplicate:
		return {"ok": false, "error": str(applied.get("error", "PREVIEW_CHANGED"))}
	var next: Dictionary = project.duplicate(true)
	next.inventory = applied.state
	var saved: Dictionary = _store.save_project(next, generation)
	if not saved.ok:
		return saved
	var visible: Dictionary = self.load()
	visible["duplicate"] = false
	visible["operation_id"] = command_id
	return visible


func _preview(mode: String, jar_id: String, bean_ids: Array,
		expected_generation: int) -> Dictionary:
	var loaded: Dictionary = _store.load_project()
	if not loaded.ok:
		return loaded
	var project: Dictionary = loaded.state
	if project.get("data_kind", "") != "personal" or project.mappings.is_empty() \
			or not Inventory.validate(project.inventory):
		return {"ok": false, "error": "NOT_INITIALIZED"}
	if int(loaded.generation) != expected_generation:
		return {"ok": false, "error": "GENERATION_CONFLICT"}
	if jar_id.is_empty() or bean_ids.size() != (10 if mode == "COMBINE" else 1):
		return {"ok": false, "error": "INVALID_SELECTION"}
	var sorted_ids: Array = bean_ids.duplicate()
	sorted_ids.sort()
	for index in sorted_ids.size():
		if typeof(sorted_ids[index]) != TYPE_STRING or str(sorted_ids[index]).is_empty() \
				or (index > 0 and sorted_ids[index] == sorted_ids[index - 1]):
			return {"ok": false, "error": "INVALID_SELECTION"}
	var selected: Dictionary = {}
	for bean in Inventory.active_beans(project.inventory, jar_id):
		selected[str(bean.id)] = int(bean.denomination_grams)
	for bean_id in sorted_ids:
		if not selected.has(bean_id) or \
				int(selected[bean_id]) != (1 if mode == "COMBINE" else 10):
			return {"ok": false, "error": "SELECTION_NOT_IN_JAR"}
	var payload := JSON.stringify([mode, jar_id, sorted_ids, expected_generation,
		str(project.inventory.state_hash), int(project.inventory.revision)])
	var command_id := "organize:" + payload.sha256_text()
	var applied := _apply(project.inventory, mode, sorted_ids, command_id,
		int(project.inventory.revision))
	if not applied.ok or applied.duplicate:
		return {"ok": false, "error": str(applied.get("error", "PREVIEW_CHANGED"))}
	return {"ok": true, "preview_id": command_id, "mode": mode,
		"jar_id": jar_id, "bean_ids": sorted_ids,
		"generation": expected_generation,
		"inventory_revision": int(project.inventory.revision),
		"state_hash": str(project.inventory.state_hash),
		"whole_grams": str(int(project.inventory.whole_grams)),
		"before_objects": Inventory.active_beans(project.inventory, jar_id).size(),
		"after_objects": Inventory.active_beans(applied.state, jar_id).size(),
		"snapshot_status": _status(project, expected_generation, jar_id)}


func _apply(state: Dictionary, mode: String, bean_ids: Array,
		command_id: String, revision: int) -> Dictionary:
	if mode == "COMBINE":
		return Inventory.combine(state, bean_ids, command_id, revision)
	return Inventory.split(state, str(bean_ids[0]), command_id, revision)


func _status(project: Dictionary, generation: int, jar_id: String) -> String:
	var display := Display.build(project, generation, jar_id)
	return str(display.snapshot.snapshot_status) if display.ok else "UNKNOWN"
