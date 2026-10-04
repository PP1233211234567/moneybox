extends RefCounted
## Minimal, versioned read-only payload for App/wallpaper renderers.
## No account, holding, price, source text or tax data is published here.

const Decimal = preload("res://scripts/data/decimal_text.gd")
const Inventory = preload("res://scripts/domain/jar_inventory.gd")
const Store = preload("res://scripts/data/project_store.gd")


static func build(project: Dictionary, generation: int, requested_jar_id: String = "") -> Dictionary:
	var kind := str(project.get("data_kind", ""))
	var presentation_raw: Variant = project.get("presentation", null)
	if not ["personal", "demo"].has(kind) or generation < 0 or \
			typeof(presentation_raw) != TYPE_DICTIONARY:
		return _error("INVALID_PROJECT")
	var presentation: Dictionary = presentation_raw
	var privacy_mode := str(presentation.get("privacy_mode", "show_total"))
	var skin_id := str(presentation.get("skin_id", "basic"))
	if not ["show_total", "hide_total"].has(privacy_mode) or \
			not ["basic", "ecology"].has(skin_id):
		return _error("INVALID_PRESENTATION")
	var mappings_raw: Variant = project.get("mappings", null)
	var inventory_raw: Variant = project.get("inventory", null)
	var ledger_raw: Variant = project.get("ledger", null)
	if typeof(mappings_raw) != TYPE_ARRAY or typeof(inventory_raw) != TYPE_DICTIONARY \
		or typeof(ledger_raw) != TYPE_DICTIONARY:
		return _error("INVALID_PROJECT")
	var mappings: Array = mappings_raw
	var inventory: Dictionary = inventory_raw
	if mappings.is_empty():
		if not inventory.is_empty() or generation != 0:
			return _error("NO_COMPLETE_DISPLAY_REVISION")
		return {"ok": true, "snapshot": {"schema_version": 1,
			"data_kind": kind, "demo_badge": kind == "demo",
			"project_generation": "0", "snapshot_status": "EMPTY",
			"privacy_mode": privacy_mode, "skin_id": skin_id,
			"mapping_revision_id": "", "inventory_revision": "",
			"selected_jar_id": "", "jar_count": 0,
			"equivalent_grams": "0", "beans": []}}
	if not Inventory.validate(inventory):
		return _error("INVALID_INVENTORY")
	var latest_raw: Variant = mappings.back()
	if typeof(latest_raw) != TYPE_DICTIONARY:
		return _error("INVALID_MAPPING")
	var latest: Dictionary = latest_raw
	if str(inventory.get("mapping_id", "")) != str(latest.get("id", "")) or \
			not Decimal.is_valid(str(latest.get("amount", ""))) or \
			not Decimal.is_valid(str(latest.get("equivalent_grams", ""))):
		return _error("DISPLAY_VERSION_MISMATCH")
	var pending_raw: Variant = project.get("valuation_pending", {})
	if typeof(pending_raw) != TYPE_DICTIONARY:
		return _error("INVALID_VALUATION_PENDING")
	var selected_jar := requested_jar_id if not requested_jar_id.is_empty() else \
		str(presentation.get("selected_jar", ""))
	var exists := false
	for jar in inventory.jars:
		if str(jar.get("id", "")) == selected_jar:
			exists = true
	if not exists:
		return _error("UNKNOWN_JAR")
	var beans: Array = []
	for bean in Inventory.active_beans(inventory, selected_jar):
		beans.append({"id": str(bean.get("id", "")),
			"denomination_grams": int(bean.get("denomination_grams", 0))})
	var current_hash := Store.canonical_ledger_hash(ledger_raw)
	var verified_current: bool = pending_raw.is_empty() and \
		str(latest.get("ledger_hash", "")) == current_hash and not current_hash.is_empty()
	var status := "CURRENT" if verified_current else "PREVIOUS_COMPLETE"
	var snapshot := {"schema_version": 1,
		"data_kind": kind, "demo_badge": kind == "demo",
		"project_generation": str(generation), "snapshot_status": status,
		"privacy_mode": privacy_mode, "skin_id": skin_id,
		"mapping_revision_id": str(latest.id),
		"inventory_revision": str(int(inventory.revision)),
		"selected_jar_id": selected_jar,
		"jar_count": inventory.jars.size(),
		"equivalent_grams": str(latest.equivalent_grams),
		"beans": beans}
	if status == "CURRENT" and privacy_mode == "show_total":
		snapshot["display_amount"] = str(latest.amount)
		snapshot["display_currency"] = str(latest.base_currency)
	return {"ok": true, "snapshot": snapshot}


static func _error(code: String) -> Dictionary:
	return {"ok": false, "error": code}
