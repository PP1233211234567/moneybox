extends SceneTree

const Store = preload("res://scripts/data/project_store.gd")
const Ledger = preload("res://scripts/data/ledger_core.gd")
const Personal = preload("res://scripts/data/personal_flow.gd")
const Asset = preload("res://scripts/data/personal_asset_flow.gd")
const Revalue = preload("res://scripts/quotes/personal_manual_revaluation_flow.gd")
const Contract = preload("res://scripts/quotes/quote_contract.gd")
const Display = preload("res://scripts/data/display_snapshot_service.gd")

const OPENED_AT := "2026-09-27T02:00:00Z"
const UPDATED_AT := "2026-09-27T03:00:00Z"
const VALUED_AT := "2026-09-27T04:00:00Z"
const ASSET_ID := "synthetic-other-asset"

var checks := 0
var failures: Array[String] = []


func _initialize() -> void:
	var directory := ProjectSettings.globalize_path("res://").get_base_dir().path_join(
		"tests").path_join("data").path_join("tmp")
	DirAccess.make_dir_recursive_absolute(directory)
	_run(directory.path_join("other-asset-" + str(Time.get_ticks_usec())))
	if failures.is_empty():
		print("OTHER ASSET TESTS PASS: %d checks" % checks)
		quit(0)
	else:
		for failure in failures:
			printerr("FAIL: " + failure)
		printerr("OTHER ASSET TESTS FAIL: %d failures in %d checks" % [
			failures.size(), checks])
		quit(1)


func _run(path: String) -> void:
	var opened := Personal.new(path).create_opening_cash("synthetic-opening",
		"cash", "Synthetic cash", "10000", "1000", OPENED_AT)
	_check(opened.ok and opened.equivalent_grams == "10", "synthetic personal opening")
	if not opened.ok:
		return
	var store := Store.new(path)
	var initial := store.load_project()
	var previous_mapping: Dictionary = initial.state.mappings.back().duplicate(true)
	var initial_net := str(Ledger.project(initial.state.ledger).external_net_invested)
	var create := _create_command()
	var create_preview := Asset.new(path).preview([create], initial.generation)
	_check(create_preview.ok and not create_preview.duplicate and
		create_preview.other_asset_values.get(ASSET_ID, "") == "2500" and
		create_preview.missing_valuation_inputs.has("FX:USD") and
		create_preview.valuation_status == "NEEDS_VALUATION" and
		not create_preview.has("asset_total") and
		store.load_project().generation == initial.generation,
		"creation preview shows owned USD value without writing or inventing FX")
	if not create_preview.ok:
		return
	var declined := Asset.new(path).confirm([create], create_preview,
		{"confirmed": false, "preview_id": create_preview.preview_id})
	var changed_create := create.duplicate(true)
	changed_create.opening_value.amount = "2501"
	var stale_confirm := Asset.new(path).confirm([changed_create], create_preview,
		_confirmation(create_preview))
	_check(not declined.ok and declined.error == "EXPLICIT_CONFIRMATION_REQUIRED" and
		not stale_confirm.ok and stale_confirm.error == "PREVIEW_INPUT_CHANGED" and
		store.load_project().generation == initial.generation,
		"creation requires explicit confirmation of unchanged preview")
	var created := Asset.new(path).confirm([create], create_preview,
		_confirmation(create_preview))
	_check(created.ok and created.generation == initial.generation + 1 and
		created.valuation_pending.reason == "ASSET_STRUCTURE_CHANGE",
		"creation and pending marker save in one generation")
	if not created.ok:
		return
	var restarted := Store.new(path).load_project()
	var projection := Ledger.project(restarted.state.ledger)
	var asset: Dictionary = restarted.state.ledger.other_assets.get(ASSET_ID, {})
	var checkpoint: Dictionary = projection.other_asset_checkpoints.get(ASSET_ID, {})
	var display := Display.build(restarted.state, restarted.generation)
	_check(restarted.ok and asset.get("name", "") == "Synthetic collectible" and
		asset.get("currency", "") == "USD" and
		asset.get("ownership_scope", "") == "OWNED_SHARE" and
		asset.get("ownership_note", "") == "Synthetic half ownership" and
		asset.get("dedup_key", "") == "SYNTHETIC-COLLECTIBLE" and
		projection.other_asset_values.get(ASSET_ID, "") == "2500" and
		checkpoint.get("event_id", "") == "synthetic-other-create" and
		checkpoint.get("valuation_basis", "") == "Synthetic reference A" and
		checkpoint.get("effective_at", "") == OPENED_AT and
		projection.external_net_invested == initial_net and
		restarted.state.valuation_pending.ledger_hash ==
		Store.canonical_ledger_hash(restarted.state.ledger) and
		restarted.state.mappings.back() == previous_mapping and
		display.ok and display.snapshot.snapshot_status == "PREVIOUS_COMPLETE" and
		not display.snapshot.has("display_amount"),
		"restart preserves ownership and value provenance while old beans stay pending")
	var duplicate_asset := _create_command()
	duplicate_asset.command_id = "synthetic-duplicate-create"
	duplicate_asset.asset.id = "synthetic-duplicate-id"
	duplicate_asset.asset.dedup_key = " synthetic-collectible "
	var duplicate_preview := Asset.new(path).preview([duplicate_asset], restarted.generation)
	var invalid_asset := _create_command()
	invalid_asset.command_id = "synthetic-invalid-create"
	invalid_asset.asset.id = "synthetic-invalid-id"
	invalid_asset.asset.ownership_scope = "UNKNOWN"
	var invalid_preview := Asset.new(path).preview([invalid_asset], restarted.generation)
	_check(not duplicate_preview.ok and duplicate_preview.error == "DUPLICATE_OTHER_ASSET" and
		not invalid_preview.ok and invalid_preview.error == "INVALID_OTHER_ASSET_INPUT" and
		store.load_project().generation == restarted.generation and
		store.load_project().state.ledger.other_assets.size() == 1,
		"ownership scope and normalized dedup key reject invalid assets without writes")
	var update := {"command_id": "synthetic-other-update",
		"type": "other_asset_value_set", "asset_id": ASSET_ID,
		"amount": "2600.00", "valuation_basis": "Synthetic reference B",
		"effective_at": UPDATED_AT}
	var update_preview := Asset.new(path).preview([update], restarted.generation)
	_check(update_preview.ok and update_preview.other_asset_values.get(ASSET_ID, "") == "2600" and
		store.load_project().generation == restarted.generation,
		"later checkpoint previews replacement value without writing")
	if not update_preview.ok:
		return
	var updated := Asset.new(path).confirm([update], update_preview,
		_confirmation(update_preview))
	_check(updated.ok and updated.generation == restarted.generation + 1,
		"later checkpoint confirms once")
	if not updated.ok:
		return
	var after_update := Store.new(path).load_project()
	var current := Ledger.project(after_update.state.ledger)
	var current_checkpoint: Dictionary = current.other_asset_checkpoints.get(ASSET_ID, {})
	_check(current.other_asset_values.get(ASSET_ID, "") == "2600" and
		current_checkpoint.get("event_id", "") == "synthetic-other-update" and
		current_checkpoint.get("valuation_basis", "") == "Synthetic reference B" and
		current_checkpoint.get("effective_at", "") == UPDATED_AT and
		after_update.state.ledger.events.size() == restarted.state.ledger.events.size() + 1 and
		current.external_net_invested == initial_net and current.asset_total == "" and
		after_update.state.valuation_pending.reason == "ASSET_STRUCTURE_CHANGE",
		"restart uses latest event as value checkpoint without double count or invented return")
	var cash_rows := [{"balance_id": "cash", "amount": "10000", "currency": "CNY"}]
	var other_rows := [{"asset_id": ASSET_ID, "amount": "2600", "currency": "USD",
		"valuation_basis": "Synthetic reference B", "effective_at": UPDATED_AT,
		"event_id": "synthetic-other-update"}]
	var wrong_rows := other_rows.duplicate(true)
	wrong_rows[0].valuation_basis = "Synthetic reference A"
	_check(store.validate_valuation_coverage(after_update.state.ledger, [], cash_rows).error ==
		"VALUATION_COVERAGE_MISMATCH" and
		store.validate_valuation_coverage(after_update.state.ledger, [], cash_rows,
			[], wrong_rows).error == "VALUATION_COVERAGE_MISMATCH" and
		store.validate_valuation_coverage(after_update.state.ledger, [], cash_rows,
			[], other_rows).ok,
		"complete valuation requires exact current other-asset amount and event provenance")
	var needed := Revalue.new(path).requirements(after_update.generation)
	var fx_key := Contract.identity_key(_identity("FX", "FX", "USD/CNY", "CNY"))
	var gold_key := Contract.identity_key(_identity("GOLD", "SPOT", "XAU", "CNY"))
	var keys: Array[String] = []
	if needed.ok:
		for identity in needed.identities:
			keys.append(Contract.identity_key(identity))
	_check(needed.ok and needed.other_asset_count == 1 and
		needed.cash_account_count == 1 and needed.position_count == 0 and
		keys.size() == 2 and keys.has(fx_key) and keys.has(gold_key),
		"manual revaluation derives only USD/CNY FX and gold for the synthetic asset")
	if not needed.ok:
		return
	var entries := {}
	entries[fx_key] = _entry("7", "CURRENCY_PER_FOREIGN_UNIT")
	entries[gold_key] = _entry("1000", "CURRENCY_PER_GRAM")
	var missing := entries.duplicate(true)
	missing.erase(fx_key)
	var missing_preview := Revalue.new(path).preview(missing,
		after_update.generation, VALUED_AT)
	_check(not missing_preview.ok and missing_preview.error ==
		"MANUAL_QUOTE_COVERAGE_MISMATCH" and
		store.load_project().generation == after_update.generation,
		"foreign asset cannot be valued without current FX")
	var valued_preview := Revalue.new(path).preview(entries,
		after_update.generation, VALUED_AT)
	var preview_rows: Array = valued_preview.get("other_asset_values", [])
	var preview_row: Dictionary = preview_rows[0] if preview_rows.size() == 1 else {}
	_check(valued_preview.ok and valued_preview.asset_total == "28200" and
		valued_preview.equivalent_grams == "28.2" and
		preview_row.get("asset_id", "") == ASSET_ID and
		preview_row.get("amount", "") == "2600" and
		preview_row.get("event_id", "") == "synthetic-other-update" and
		store.load_project().generation == after_update.generation and
		store.load_project().state.valuation.snapshots.is_empty(),
		"cash plus one owned USD value previews 28200 CNY and 28.2 grams without writing")
	if not valued_preview.ok:
		return
	var confirmed := Revalue.new(path).confirm(entries, valued_preview,
		_confirmation(valued_preview), VALUED_AT)
	_check(confirmed.ok and confirmed.generation == after_update.generation + 2 and
		confirmed.asset_total == "28200" and confirmed.equivalent_grams == "28.2",
		"confirmed full valuation saves valuation and gold mapping")
	if not confirmed.ok:
		return
	var restored := Store.new(path).load_project()
	var snapshot_id := "valuation:" + str(valued_preview.batch_id)
	var snapshot: Dictionary = restored.state.valuation.snapshots.get(snapshot_id, {})
	var rows: Array = snapshot.get("other_asset_values", [])
	var row: Dictionary = rows[0] if rows.size() == 1 else {}
	var visible := Display.build(restored.state, restored.generation)
	_check(restored.ok and rows.size() == 1 and
		row.get("asset_id", "") == ASSET_ID and row.get("amount", "") == "2600" and
		row.get("currency", "") == "USD" and
		row.get("valuation_basis", "") == "Synthetic reference B" and
		row.get("effective_at", "") == UPDATED_AT and
		row.get("event_id", "") == "synthetic-other-update" and
		row.get("base_value", "") == "18200" and
		row.get("fx_quote", {}).get("price", "") == "7" and
		store.current_valuation_snapshot(restored.state, snapshot_id).ok and
		not restored.state.has("valuation_pending") and
		restored.state.mappings.back().ledger_hash ==
		Store.canonical_ledger_hash(restored.state.ledger) and
		restored.state.mappings.back().amount == "28200" and
		restored.state.mappings.back().equivalent_grams == "28.2" and
		visible.ok and visible.snapshot.snapshot_status == "CURRENT" and
		visible.snapshot.display_amount == "28200" and
		visible.snapshot.equivalent_grams == "28.2",
		"restart preserves exact other-asset FX evidence and current visible gold mapping")
	var missing_row: Dictionary = restored.state.duplicate(true)
	missing_row.valuation.snapshots[snapshot_id].other_asset_values.clear()
	var changed_row: Dictionary = restored.state.duplicate(true)
	changed_row.valuation.snapshots[snapshot_id].other_asset_values[0].valuation_basis = "Synthetic stale reference"
	_check(not store.current_valuation_snapshot(missing_row, snapshot_id).ok and
		not store.current_valuation_snapshot(changed_row, snapshot_id).ok,
		"missing or stale other-asset snapshot row cannot certify current total")
	var replay_preview := Revalue.new(path).preview(entries, restored.generation, VALUED_AT)
	_check(replay_preview.ok and replay_preview.duplicate and
		store.load_project().generation == restored.generation,
		"same quote batch and current ledger replay without another generation")


func _create_command() -> Dictionary:
	return {"command_id": "synthetic-other-create", "type": "other_asset_create",
		"asset": {"id": ASSET_ID, "name": "Synthetic collectible", "currency": "USD",
			"ownership_scope": "OWNED_SHARE",
			"ownership_note": "Synthetic half ownership",
			"dedup_key": " synthetic-collectible "},
		"opening_value": {"amount": "2500.00", "valuation_basis": "Synthetic reference A",
			"effective_at": OPENED_AT}}


func _identity(kind: String, market: String, symbol: String, currency: String) -> Dictionary:
	return {"kind": kind, "market": market, "symbol": symbol,
		"currency": currency, "share_class": ""}


func _entry(price: String, unit: String) -> Dictionary:
	return {"price": price, "unit": unit, "quoted_at": VALUED_AT,
		"source_note": "Synthetic manually checked reference"}


func _confirmation(preview: Dictionary) -> Dictionary:
	return {"confirmed": true, "preview_id": str(preview.get("preview_id", ""))}


func _check(condition: bool, label: String) -> void:
	checks += 1
	if not condition:
		failures.append(label)
