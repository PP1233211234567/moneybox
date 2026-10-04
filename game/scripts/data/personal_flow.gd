extends RefCounted
## First real local cash account path. Manual gold input is explicitly user supplied.
## Account, opening event, mapping and inventory commit in one ProjectStore generation.

const Decimal = preload("res://scripts/data/decimal_text.gd")
const Ledger = preload("res://scripts/data/ledger_core.gd")
const Mapping = preload("res://scripts/domain/gold_mapping_service.gd")
const Inventory = preload("res://scripts/domain/jar_inventory.gd")
const Store = preload("res://scripts/data/project_store.gd")
const Display = preload("res://scripts/data/display_snapshot_service.gd")
const QuoteContract = preload("res://scripts/quotes/quote_contract.gd")

var _store: RefCounted


func _init(base_path: String = "user://personal/moneybox") -> void:
	_store = Store.new(base_path)


func load() -> Dictionary:
	var loaded: Dictionary = _store.load_project()
	if not loaded.ok:
		return loaded
	if loaded.state.get("data_kind", "personal") != "personal":
		return _error("NOT_PERSONAL_DATA")
	if loaded.generation == 0 or loaded.state.mappings.is_empty():
		var empty_display := Display.build(loaded.state, loaded.generation)
		if not empty_display.ok:
			return empty_display
		return {"ok": true, "initialized": false, "generation": loaded.generation,
			"display_snapshot": empty_display.snapshot}
	return _visible_result(loaded.state, loaded.generation, false)


func create_opening_cash(operation_id: String, account_id: String, account_name: String,
		amount: Variant, manual_gold_price_per_gram: Variant, at_utc: String) -> Dictionary:
	if not _valid_id(operation_id) or not _valid_id(account_id) or account_name.strip_edges().is_empty() \
		or typeof(amount) != TYPE_STRING or not _nonnegative(amount) \
		or typeof(manual_gold_price_per_gram) != TYPE_STRING \
		or not _positive(manual_gold_price_per_gram) or QuoteContract.utc_unix(at_utc) < 0:
		return _error("INVALID_OPENING_INPUT")
	var loaded: Dictionary = _store.load_project()
	if not loaded.ok:
		return loaded
	if loaded.state.get("data_kind", "personal") != "personal":
		return _error("NOT_PERSONAL_DATA")
	var request_fingerprint := JSON.stringify([operation_id, account_id,
		account_name.strip_edges(), Decimal.canonical(amount),
		Decimal.canonical(manual_gold_price_per_gram), at_utc]).sha256_text()
	if loaded.generation != 0:
		if loaded.state.get("opening_operation_id", "") == operation_id:
			if loaded.state.get("opening_request_fingerprint", "") != request_fingerprint:
				return _error("IDEMPOTENCY_KEY_CONFLICT")
			return _visible_result(loaded.state, loaded.generation, true)
		return _error("ALREADY_INITIALIZED")
	var project: Dictionary = _store.new_project()
	project["opening_operation_id"] = operation_id
	project["opening_request_fingerprint"] = request_fingerprint
	project["manual_gold_quote"] = _manual_quote(operation_id, manual_gold_price_per_gram, at_utc)
	project.presentation.selected_jar = "jar-000001"
	var account := {"command_id": operation_id + ":account", "type": "account_create", "account": {
		"id": account_id, "name": account_name.strip_edges(), "currency": "CNY",
		"mode": "detail", "cost_method": "FIFO"}}
	var applied := Ledger.apply(project.ledger, account)
	if not applied.ok:
		return applied
	project.ledger = applied.state
	applied = Ledger.apply(project.ledger, {"command_id": operation_id + ":opening",
		"type": "opening_cash", "account_id": account_id, "amount": amount,
		"effective_at": at_utc})
	if not applied.ok:
		return applied
	project.ledger = applied.state
	var mapped := _map_latest(project, operation_id + ":snapshot", "INITIAL_MANUAL_MAPPING")
	if not mapped.ok:
		return mapped
	var saved: Dictionary = _store.save_project(project, 0)
	if not saved.ok:
		return saved
	return _visible_result(project, saved.generation, false)


func record_cash_change(operation_id: String, account_id: String, delta: Variant,
		at_utc: String, expected_generation: int) -> Dictionary:
	if not _valid_id(operation_id) or not _valid_id(account_id) or typeof(delta) != TYPE_STRING \
		or not Decimal.is_valid(delta) or Decimal.compare(delta, "0") == 0 \
		or QuoteContract.utc_unix(at_utc) < 0 or expected_generation < 1:
		return _error("INVALID_CHANGE_INPUT")
	var loaded: Dictionary = _store.load_project()
	if not loaded.ok:
		return loaded
	var project: Dictionary = loaded.state
	if project.get("data_kind", "personal") != "personal":
		return _error("NOT_PERSONAL_DATA")
	if loaded.generation == 0 or project.mappings.is_empty():
		return _error("NOT_INITIALIZED")
	if typeof(project.get("valuation_pending", {})) != TYPE_DICTIONARY:
		return _error("INVALID_VALUATION_PENDING")
	if not project.get("valuation_pending", {}).is_empty():
		return _error("VALUATION_PENDING")
	if not _cash_only(project.ledger):
		return _error("CASH_ONLY_FLOW")
	var command := {"command_id": operation_id, "type": "cash_delta",
		"account_id": account_id, "delta": delta, "external": true, "effective_at": at_utc}
	var applied := Ledger.apply(project.ledger, command)
	if not applied.ok:
		return applied
	if applied.duplicate:
		return _visible_result(project, loaded.generation, true)
	if int(loaded.generation) != expected_generation:
		return _error("GENERATION_CONFLICT")
	project.ledger = applied.state
	var mapped := _map_latest(project, operation_id + ":snapshot", "USER_ASSET_UPDATE")
	if not mapped.ok:
		return mapped
	var saved: Dictionary = _store.save_project(project, expected_generation)
	if not saved.ok:
		return saved
	return _visible_result(project, saved.generation, false)


func set_presentation(setting: String, value: String, expected_generation: int) -> Dictionary:
	if (setting == "skin_id" and not ["basic", "ecology"].has(value)) \
		or (setting == "privacy_mode" and not ["show_total", "hide_total"].has(value)) \
		or not ["skin_id", "privacy_mode"].has(setting):
		return _error("INVALID_PRESENTATION_SETTING")
	var loaded: Dictionary = _store.load_project()
	if not loaded.ok:
		return loaded
	var project: Dictionary = loaded.state
	if project.get("data_kind", "personal") != "personal":
		return _error("NOT_PERSONAL_DATA")
	if loaded.generation == 0 or project.mappings.is_empty():
		return _error("NOT_INITIALIZED")
	if int(loaded.generation) != expected_generation:
		return _error("GENERATION_CONFLICT")
	if project.presentation.get(setting, "") == value:
		return _visible_result(project, loaded.generation, true)
	project.presentation[setting] = value
	var saved: Dictionary = _store.save_project(project, expected_generation)
	if not saved.ok:
		return saved
	return _visible_result(project, saved.generation, false)


func select_jar(jar_id: String, expected_generation: int) -> Dictionary:
	var loaded: Dictionary = _store.load_project()
	if not loaded.ok:
		return loaded
	var project: Dictionary = loaded.state
	if project.get("data_kind", "personal") != "personal":
		return _error("NOT_PERSONAL_DATA")
	if loaded.generation == 0 or project.mappings.is_empty():
		return _error("NOT_INITIALIZED")
	if int(loaded.generation) != expected_generation:
		return _error("GENERATION_CONFLICT")
	var found := false
	for jar in project.inventory.jars:
		if str(jar.get("id", "")) == jar_id:
			found = true
	if not found:
		return _error("UNKNOWN_JAR")
	if project.presentation.get("selected_jar", "") == jar_id:
		return _visible_result(project, loaded.generation, true)
	project.presentation.selected_jar = jar_id
	var saved: Dictionary = _store.save_project(project, expected_generation)
	if not saved.ok:
		return saved
	return _visible_result(project, saved.generation, false)


func _map_latest(project: Dictionary, snapshot_id: String, reason: String) -> Dictionary:
	if not _cash_only(project.ledger):
		return _error("CASH_ONLY_FLOW")
	var projection := Ledger.project(project.ledger)
	if not projection.ok or not projection.incomplete.is_empty():
		return _error("VALUATION_INCOMPLETE")
	var previous: Dictionary = project.mappings.back() if not project.mappings.is_empty() else {}
	var mapped := Mapping.create_revision(snapshot_id, projection.asset_total,
		"CNY", project.manual_gold_quote, {}, "total_assets", previous, reason)
	if not mapped.ok:
		return mapped
	if not mapped.changed:
		return {"ok": true, "changed": false}
	mapped.revision["ledger_hash"] = Store.canonical_ledger_hash(project.ledger)
	var inventory: Dictionary = project.inventory if not project.inventory.is_empty() else Inventory.new_state()
	var revised := Inventory.apply_mapping(inventory, mapped.revision, "apply-" + mapped.revision.id)
	if not revised.ok:
		return revised
	project.mappings.append(mapped.revision)
	project.inventory = revised.state
	return {"ok": true, "changed": true}


func _visible_result(project: Dictionary, generation: int, duplicate: bool) -> Dictionary:
	if project.mappings.is_empty() or not Inventory.validate(project.inventory):
		return _error("DISPLAY_STATE_INVALID")
	var pending: Variant = project.get("valuation_pending", {})
	if typeof(pending) != TYPE_DICTIONARY:
		return _error("INVALID_VALUATION_PENDING")
	var revision: Dictionary = project.mappings.back()
	if str(project.inventory.mapping_id) != str(revision.id):
		return _error("DISPLAY_VERSION_MISMATCH")
	var selected_jar: String = str(project.presentation.get("selected_jar", "jar-000001"))
	var display := Display.build(project, generation, selected_jar)
	if not display.ok:
		return display
	var jar_ids: Array[String] = []
	for jar in project.inventory.jars:
		jar_ids.append(str(jar.get("id", "")))
	var account_ids: Array = project.ledger.accounts.keys()
	account_ids.sort()
	var account_id: String = str(account_ids[0]) if not account_ids.is_empty() else ""
	return {"ok": true, "initialized": true, "duplicate": duplicate,
		"generation": generation, "amount": revision.amount,
		"base_currency": revision.base_currency,
		"equivalent_grams": revision.equivalent_grams,
		"valuation_pending": pending.duplicate(true),
		"cash_only": _cash_only(project.ledger),
		"privacy_mode": str(project.presentation.get("privacy_mode", "show_total")),
		"account_id": account_id,
		"account_name": str(project.ledger.accounts[account_id].get("name", "")) if not account_id.is_empty() else "",
		"jar_ids": jar_ids, "selected_jar": selected_jar,
		"manual_gold_quote": project.manual_gold_quote.duplicate(true),
		"gold_reference": {"price_per_gram": str(revision.get("price_per_gram", "")),
			"source": str(revision.get("gold_quote_source", "")),
			"quoted_at": str(revision.get("gold_quote_quoted_at", ""))},
		"display_snapshot": display.snapshot,
		"view": {"inventory_revision_id": revision.id + ":" + str(int(project.inventory.revision)),
			"skin_id": str(project.presentation.get("skin_id", "basic")), "demo": false,
			"beans": Inventory.active_beans(project.inventory, selected_jar)}}


func _manual_quote(operation_id: String, price: String, at_utc: String) -> Dictionary:
	return {"id": "user-manual-gold:" + operation_id, "source": "USER_MANUAL",
		"quoted_at": at_utc, "fetched_at": at_utc, "currency": "CNY",
		"unit": "CURRENCY_PER_GRAM", "price": Decimal.canonical(price)}


func _cash_only(ledger: Dictionary) -> bool:
	if typeof(ledger.get("accounts", null)) != TYPE_DICTIONARY \
		or typeof(ledger.get("instruments", null)) != TYPE_DICTIONARY \
		or typeof(ledger.get("other_assets", {})) != TYPE_DICTIONARY \
		or ledger.accounts.size() != 1 or not ledger.instruments.is_empty() \
		or not ledger.get("other_assets", {}).is_empty():
		return false
	for account in ledger.accounts.values():
		if str(account.get("currency", "")) != "CNY" or \
				str(account.get("asset_kind", "CASH")) != "CASH":
			return false
	return true


func _positive(value: String) -> bool:
	return Decimal.is_valid(value) and Decimal.compare(value, "0") > 0


func _nonnegative(value: String) -> bool:
	return Decimal.is_valid(value) and Decimal.compare(value, "0") >= 0


func _valid_id(value: String) -> bool:
	return not value.is_empty() and not value.contains("|") and value.length() <= 128


func _error(code: String) -> Dictionary:
	return {"ok": false, "error": code}
