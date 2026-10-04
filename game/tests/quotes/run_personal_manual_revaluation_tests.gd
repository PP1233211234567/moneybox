extends SceneTree

const Store = preload("res://scripts/data/project_store.gd")
const PersonalFlow = preload("res://scripts/data/personal_flow.gd")
const AssetFlow = preload("res://scripts/data/personal_asset_flow.gd")
const Revalue = preload("res://scripts/quotes/personal_manual_revaluation_flow.gd")
const Contract = preload("res://scripts/quotes/quote_contract.gd")
const Display = preload("res://scripts/data/display_snapshot_service.gd")

const NOW := "2026-09-27T02:00:00Z"
const OLD := "2026-09-25T02:00:00Z"

var checks := 0
var failures: Array[String] = []
var directory := ""


func _initialize() -> void:
	directory = ProjectSettings.globalize_path("res://").get_base_dir().path_join(
		"tests").path_join("data").path_join("tmp")
	DirAccess.make_dir_recursive_absolute(directory)
	var path := directory.path_join("manual-revalue-" + str(Time.get_ticks_usec()))
	_test_flow(path)
	if failures.is_empty():
		print("PERSONAL MANUAL REVALUATION TESTS PASS: %d checks" % checks)
		quit(0)
	else:
		for failure in failures:
			printerr("FAIL: " + failure)
		printerr("PERSONAL MANUAL REVALUATION TESTS FAIL: %d failures in %d checks" % [
			failures.size(), checks])
		quit(1)


func _test_flow(path: String) -> void:
	var opening := PersonalFlow.new(path).create_opening_cash("start",
		"cash-cny", "Cash", "10000", "1000", NOW)
	if not opening.ok:
		_check(false, "starting personal jar")
		return
	var asset := AssetFlow.new(path)
	var commands := _asset_commands()
	var asset_preview := asset.preview(commands, opening.generation)
	var asset_confirmed := asset.confirm(commands, asset_preview,
		{"confirmed": true, "preview_id": asset_preview.preview_id})
	_check(asset_confirmed.ok and asset_confirmed.valuation_pending.reason == \
		"ASSET_STRUCTURE_CHANGE", "saved multiaccount ETF ledger awaits valuation")
	if not asset_confirmed.ok:
		return
	var store := Store.new(path)
	var generation: int = asset_confirmed.generation
	var flow := Revalue.new(path)
	var needed := flow.requirements(generation)
	var etf_key := Contract.identity_key(_identity("ETF", "NASDAQ", "SAMPLE", "USD"))
	var fx_key := Contract.identity_key(_identity("FX", "FX", "USD/CNY", "CNY"))
	var gold_key := Contract.identity_key(_identity("GOLD", "SPOT", "XAU", "CNY"))
	var keys: Array[String] = []
	for identity in needed.identities:
		keys.append(Contract.identity_key(identity))
	_check(needed.ok and needed.quote_source == "USER_MANUAL"
		and needed.position_count == 1 and needed.cash_account_count == 3
		and keys.size() == 3 and keys.has(etf_key) and keys.has(fx_key)
		and keys.has(gold_key) and not needed.has("asset_total")
		and not needed.has("price"),
		"requirements derive ETF, shared USD/CNY FX and gold without any invented price")
	var entries := _entries(etf_key, fx_key, gold_key)
	var missing: Dictionary = entries.duplicate(true)
	missing.erase(etf_key)
	var missing_result := flow.preview(missing, generation, NOW)
	_check(not missing_result.ok and missing_result.error == \
		"MANUAL_QUOTE_COVERAGE_MISMATCH" and store.load_project().generation == generation,
		"historical opening reference price cannot fill missing ETF market quote")
	var invalid: Dictionary = entries.duplicate(true)
	invalid[etf_key].price = 0.0
	var float_result := flow.preview(invalid, generation, NOW)
	_check(not float_result.ok and float_result.error == "INVALID_MANUAL_QUOTE",
		"floating price is rejected before a batch is written")
	invalid = entries.duplicate(true)
	invalid[fx_key].price = "0"
	var zero_result := flow.preview(invalid, generation, NOW)
	_check(not zero_result.ok and zero_result.error == "INVALID_MANUAL_QUOTE",
		"zero FX cannot convert a personal asset to base currency")
	invalid = entries.duplicate(true)
	invalid[gold_key].source_note = ""
	var no_source := flow.preview(invalid, generation, NOW)
	_check(not no_source.ok and no_source.error == "INVALID_MANUAL_QUOTE",
		"manual quote must have explicit source note")
	invalid = entries.duplicate(true)
	invalid[gold_key].quoted_at = OLD
	var stale := flow.preview(invalid, generation, NOW)
	_check(not stale.ok and stale.error == "MANUAL_QUOTE_STALE",
		"stale manually entered gold time cannot be silently confirmed")
	var preview := flow.preview(entries, generation, NOW)
	_check(preview.ok and preview.asset_total == "12100"
		and preview.equivalent_grams == "12.1"
		and preview.whole_grams == "12" and preview.quote_count == 3
		and preview.quote_source == "USER_MANUAL" and not preview.duplicate,
		"complete manual entries preview CNY 12100 and 12.1 grams")
	if not preview.ok:
		return
	_check(store.load_project().generation == generation
		and store.load_project().state.valuation.snapshots.is_empty(),
		"manual valuation preview has no project write")
	var declined := flow.confirm(entries, preview,
		{"confirmed": false, "preview_id": preview.preview_id}, NOW)
	_check(not declined.ok and declined.error == "EXPLICIT_CONFIRMATION_REQUIRED"
		and store.load_project().generation == generation,
		"user must explicitly accept the shown manual valuation")
	invalid = entries.duplicate(true)
	invalid[etf_key].price = "101"
	var changed := flow.confirm(invalid, preview, _confirmation(preview), NOW)
	_check(not changed.ok and changed.error == "PREVIEW_INPUT_CHANGED"
		and store.load_project().generation == generation,
		"changed manual price cannot reuse old preview confirmation")
	var expired := flow.confirm(entries, preview, _confirmation(preview),
		"2026-09-27T02:11:00Z")
	_check(not expired.ok and expired.error == "PREVIEW_EXPIRED"
		and store.load_project().generation == generation,
		"expired preview requires a fresh user review")
	var concurrent: Dictionary = store.load_project().state
	concurrent.presentation.privacy_mode = "hide_total"
	var concurrent_saved := store.save_project(concurrent, generation)
	var conflicting := flow.confirm(entries, preview, _confirmation(preview), NOW)
	_check(concurrent_saved.ok and not conflicting.ok
		and conflicting.error == "GENERATION_CONFLICT"
		and store.load_project().state.valuation.snapshots.is_empty(),
		"generation conflict cannot commit a previously shown valuation")
	var fresh := flow.preview(entries, concurrent_saved.generation, NOW)
	var confirmed := flow.confirm(entries, fresh, _confirmation(fresh), NOW)
	_check(confirmed.ok and not confirmed.duplicate
		and confirmed.valuation_status == "CURRENT"
		and confirmed.asset_total == "12100"
		and confirmed.equivalent_grams == "12.1"
		and confirmed.generation == concurrent_saved.generation + 2,
		"confirmation saves valuation then mapping in two verified generations")
	if not confirmed.ok:
		return
	var restarted := Store.new(path).load_project()
	var saved_batch: Dictionary = restarted.state.quote_gateway.batches[fresh.batch_id]
	var display := Display.build(restarted.state, restarted.generation)
	_check(restarted.ok and not restarted.state.has("valuation_pending")
		and saved_batch.provider_versions.selected == "user-manual-entry-v1"
		and saved_batch.entries[etf_key].quote.source == "USER_MANUAL"
		and saved_batch.entries[etf_key].quote.source_note == "user statement"
		and restarted.state.mappings.back().ledger_hash == \
		Store.canonical_ledger_hash(restarted.state.ledger)
		and display.ok and display.snapshot.snapshot_status == "CURRENT"
		and not display.snapshot.has("display_amount"),
		"restart keeps manual provenance, current beans and hidden amount")
	var replay_preview := Revalue.new(path).preview(entries, restarted.generation, NOW)
	var replay := Revalue.new(path).confirm(entries, replay_preview,
		_confirmation(replay_preview), NOW)
	_check(replay_preview.ok and replay_preview.duplicate and replay.ok
		and replay.duplicate and replay.generation == restarted.generation
		and store.load_project().state.mappings.size() == 2,
		"same ledger and user quotes replay without extra snapshot or gold revision")
	var usd_gold_key := Contract.identity_key(_identity("GOLD", "SPOT", "XAU", "USD"))
	var usd_needed := Revalue.new(path).requirements(restarted.generation, "USD")
	var usd_keys: Array[String] = []
	for identity in usd_needed.identities:
		usd_keys.append(Contract.identity_key(identity))
	_check(usd_needed.ok and usd_keys.size() == 3 and usd_keys.has(usd_gold_key)
		and usd_keys.has(fx_key) and not usd_keys.has(gold_key),
		"foreign gold reuses required USD/CNY FX in one exact quote batch")
	var usd_entries := _entries(etf_key, fx_key, usd_gold_key)
	usd_entries[usd_gold_key].price = "3110.34768"
	usd_entries[usd_gold_key].unit = "CURRENCY_PER_TROY_OUNCE"
	var usd_preview := Revalue.new(path).preview(usd_entries,
		restarted.generation, NOW, "USD")
	var usd_confirm := Revalue.new(path).confirm(usd_entries, usd_preview,
		_confirmation(usd_preview), NOW)
	var usd_restored := Store.new(path).load_project()
	_check(usd_preview.ok and usd_preview.price_per_gram == "700"
		and usd_confirm.ok and not usd_confirm.duplicate
		and usd_restored.state.mappings.back().gold_quote_currency == "USD"
		and usd_restored.state.mappings.back().price_per_gram == "700"
		and not usd_restored.state.mappings.back().fx_rate_id.is_empty()
		and usd_restored.state.mappings.back().ledger_hash == \
		Store.canonical_ledger_hash(usd_restored.state.ledger),
		"USD per troy ounce gold and selected FX produce a current personal mapping")


func _asset_commands() -> Array:
	return [
		{"command_id": "usd-bank", "type": "account_create", "account":
			_account("usd-bank", "USD Bank")},
		{"command_id": "usd-broker", "type": "account_create", "account":
			_account("usd-broker", "USD Broker")},
		{"command_id": "etf-instrument", "type": "instrument_create",
			"instrument": {"id": "sample-etf", "kind": "ETF", "market": "NASDAQ",
				"symbol": "SAMPLE", "currency": "USD", "share_class": ""}},
		{"command_id": "usd-opening", "type": "opening_cash", "account_id": "usd-bank",
			"amount": "100", "effective_at": NOW},
		{"command_id": "etf-opening", "type": "opening_position",
			"account_id": "usd-broker", "instrument_id": "sample-etf",
			"quantity": "2", "reference_price": "90", "cost_basis": "",
			"effective_at": NOW},
	]


func _account(id: String, name: String) -> Dictionary:
	return {"id": id, "name": name, "currency": "USD",
		"mode": "detail", "cost_method": "FIFO"}


func _identity(kind: String, market: String, symbol: String,
		currency: String) -> Dictionary:
	return {"kind": kind, "market": market, "symbol": symbol,
		"currency": currency, "share_class": ""}


func _entries(etf_key: String, fx_key: String, gold_key: String) -> Dictionary:
	return {etf_key: {"price": "100", "unit": "CURRENCY_PER_SHARE",
			"quoted_at": NOW, "source_note": "user statement"},
		fx_key: {"price": "7", "unit": "CURRENCY_PER_FOREIGN_UNIT",
			"quoted_at": NOW, "source_note": "user FX reference"},
		gold_key: {"price": "1000", "unit": "CURRENCY_PER_GRAM",
			"quoted_at": NOW, "source_note": "user gold reference"}}


func _confirmation(preview: Dictionary) -> Dictionary:
	return {"confirmed": true, "preview_id": str(preview.get("preview_id", ""))}


func _check(condition: bool, label: String) -> void:
	checks += 1
	if not condition:
		failures.append(label)
