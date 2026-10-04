extends RefCounted
## Explicitly isolated demonstration ledger. Never opened as the personal finance store.

const Ledger = preload("res://scripts/data/ledger_core.gd")
const Mapping = preload("res://scripts/domain/gold_mapping_service.gd")
const Inventory = preload("res://scripts/domain/jar_inventory.gd")
const Store = preload("res://scripts/data/project_store.gd")
const Display = preload("res://scripts/data/display_snapshot_service.gd")

const DEMO_ACCOUNT := "demo-cash"
const DEMO_INITIAL_CNY := "50000"
const DEMO_MANUAL_GOLD_CNY_PER_GRAM := "1000"

var _store: RefCounted


func _init(base_path: String = "user://demo/moneybox") -> void:
	_store = Store.new(base_path)


func load_or_create() -> Dictionary:
	var loaded: Dictionary = _store.load_project()
	if not loaded.ok:
		return loaded
	if loaded.generation > 0:
		if loaded.state.get("data_kind", "") != "demo":
			return {"ok": false, "error": "NOT_DEMO_DATA"}
		return _visible_result(loaded.state, loaded.generation, false)
	var project: Dictionary = _store.new_project()
	project.data_kind = "demo"
	project.presentation["selected_jar"] = "jar-000001"
	project["demo_gold_quote"] = _manual_quote()
	var account := {"command_id": "demo-account-v1", "type": "account_create", "account": {"id": DEMO_ACCOUNT, "name": "演示现金", "currency": "CNY", "mode": "detail", "cost_method": "FIFO"}}
	var result := Ledger.apply(project.ledger, account)
	if not result.ok:
		return result
	project.ledger = result.state
	result = Ledger.apply(project.ledger, {"command_id": "demo-opening-v1", "type": "opening_cash", "account_id": DEMO_ACCOUNT, "amount": DEMO_INITIAL_CNY, "effective_at": _now_utc()})
	if not result.ok:
		return result
	project.ledger = result.state
	var mapped := _apply_latest_mapping(project, "demo-opening-v1")
	if not mapped.ok:
		return mapped
	var saved: Dictionary = _store.save_project(project, 0)
	if not saved.ok:
		return saved
	return _visible_result(project, saved.generation, true)


func record_cash_change(delta: String) -> Dictionary:
	if delta != "1000" and delta != "-1000":
		return {"ok": false, "error": "DEMO_DELTA_NOT_ALLOWED"}
	var loaded: Dictionary = _store.load_project()
	if not loaded.ok or loaded.generation == 0:
		return {"ok": false, "error": "DEMO_NOT_INITIALIZED"}
	var project: Dictionary = loaded.state
	if project.get("data_kind", "") != "demo":
		return {"ok": false, "error": "NOT_DEMO_DATA"}
	var command_id := "demo-change-" + Crypto.new().generate_random_bytes(16).hex_encode()
	var result := Ledger.apply(project.ledger, {"command_id": command_id, "type": "cash_delta", "account_id": DEMO_ACCOUNT, "delta": delta, "external": true, "effective_at": _now_utc()})
	if not result.ok:
		return result
	project.ledger = result.state
	var mapped := _apply_latest_mapping(project, command_id)
	if not mapped.ok:
		return mapped
	var saved: Dictionary = _store.save_project(project, int(loaded.generation))
	if not saved.ok:
		return saved
	return _visible_result(project, saved.generation, false)


func set_skin(skin_id: String) -> Dictionary:
	if skin_id != "basic" and skin_id != "ecology":
		return {"ok": false, "error": "INVALID_SKIN"}
	var loaded: Dictionary = _store.load_project()
	if not loaded.ok or loaded.generation == 0:
		return {"ok": false, "error": "DEMO_NOT_INITIALIZED"}
	var project: Dictionary = loaded.state
	if project.get("data_kind", "") != "demo":
		return {"ok": false, "error": "NOT_DEMO_DATA"}
	if project.presentation.get("skin_id", "basic") == skin_id:
		return _visible_result(project, int(loaded.generation), false)
	project.presentation["skin_id"] = skin_id
	var saved: Dictionary = _store.save_project(project, int(loaded.generation))
	if not saved.ok:
		return saved
	return _visible_result(project, saved.generation, false)


func set_privacy_mode(mode: String) -> Dictionary:
	if mode != "show_total" and mode != "hide_total":
		return {"ok": false, "error": "INVALID_PRIVACY_MODE"}
	var loaded: Dictionary = _store.load_project()
	if not loaded.ok or loaded.generation == 0:
		return {"ok": false, "error": "DEMO_NOT_INITIALIZED"}
	var project: Dictionary = loaded.state
	if project.get("data_kind", "") != "demo":
		return {"ok": false, "error": "NOT_DEMO_DATA"}
	if project.presentation.get("privacy_mode", "show_total") == mode:
		return _visible_result(project, int(loaded.generation), false)
	project.presentation["privacy_mode"] = mode
	var saved: Dictionary = _store.save_project(project, int(loaded.generation))
	if not saved.ok:
		return saved
	return _visible_result(project, saved.generation, false)


func _apply_latest_mapping(project: Dictionary, snapshot_id: String) -> Dictionary:
	var projection := Ledger.project(project.ledger)
	if not projection.ok or not projection.incomplete.is_empty():
		return {"ok": false, "error": "DEMO_VALUATION_INCOMPLETE"}
	var previous: Dictionary = project.mappings.back() if not project.mappings.is_empty() else {}
	var mapping := Mapping.create_revision(snapshot_id, projection.asset_total, "CNY", project.demo_gold_quote, {}, "total_assets", previous, "USER_ASSET_UPDATE")
	if not mapping.ok:
		return mapping
	if not mapping.changed:
		return {"ok": true, "changed": false}
	mapping.revision["ledger_hash"] = Store.canonical_ledger_hash(project.ledger)
	var inventory: Dictionary = project.inventory if not project.inventory.is_empty() else Inventory.new_state()
	var revised := Inventory.apply_mapping(inventory, mapping.revision, "apply-" + mapping.revision.id)
	if not revised.ok:
		return revised
	project.mappings.append(mapping.revision)
	project.inventory = revised.state
	return {"ok": true, "changed": true}


func _visible_result(project: Dictionary, generation: int, created: bool) -> Dictionary:
	if project.mappings.is_empty() or not Inventory.validate(project.inventory):
		return {"ok": false, "error": "DEMO_DISPLAY_STATE_INVALID"}
	var revision: Dictionary = project.mappings.back()
	if project.inventory.mapping_id != revision.id:
		return {"ok": false, "error": "DEMO_VERSION_MISMATCH"}
	var selected_jar: String = str(project.presentation.get("selected_jar", "jar-000001"))
	var display := Display.build(project, generation, selected_jar)
	if not display.ok:
		return display
	return {
		"ok": true,
		"created": created,
		"generation": generation,
		"amount": revision.amount,
		"base_currency": revision.base_currency,
		"equivalent_grams": revision.equivalent_grams,
		"fractional_grams": revision.fractional_grams,
		"jar_count": project.inventory.jars.size(),
		"bean_count": Inventory.active_beans(project.inventory).size(),
		"manual_price": DEMO_MANUAL_GOLD_CNY_PER_GRAM,
		"privacy_mode": str(project.presentation.get("privacy_mode", "show_total")),
		"display_snapshot": display.snapshot,
		"view": {"inventory_revision_id": revision.id + ":" + str(int(project.inventory.revision)), "skin_id": str(project.presentation.get("skin_id", "basic")), "demo": true, "beans": Inventory.active_beans(project.inventory, selected_jar)},
	}


func _manual_quote() -> Dictionary:
	return {"id": "demo-manual-gold-1", "source": "manual-demo-only", "quoted_at": _now_utc(), "fetched_at": _now_utc(), "currency": "CNY", "unit": "CURRENCY_PER_GRAM", "price": DEMO_MANUAL_GOLD_CNY_PER_GRAM}


func _now_utc() -> String:
	return Time.get_datetime_string_from_system(true, false) + "Z"
