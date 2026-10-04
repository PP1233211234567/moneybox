extends SceneTree

const Display = preload("res://scripts/data/display_snapshot_service.gd")
const PersonalFlow = preload("res://scripts/data/personal_flow.gd")
const DemoFlow = preload("res://scripts/data/demo_flow.gd")
const Store = preload("res://scripts/data/project_store.gd")
const Ledger = preload("res://scripts/data/ledger_core.gd")
const Contract = preload("res://scripts/quotes/quote_contract.gd")
const Gateway = preload("res://scripts/quotes/quote_gateway.gd")
const ManualProvider = preload("res://scripts/quotes/manual_quote_provider.gd")
const GoldFlow = preload("res://scripts/quotes/personal_gold_flow.gd")
var failures := 0


func _initialize() -> void:
	var directory := ProjectSettings.globalize_path("res://").get_base_dir().path_join("tests/data/tmp")
	DirAccess.make_dir_recursive_absolute(directory)
	var empty := Display.build(Store.new(directory.path_join("display-empty")).new_project(), 0)
	_check(empty.ok and empty.snapshot.snapshot_status == "EMPTY" and empty.snapshot.beans.is_empty() and not empty.snapshot.has("display_amount"), "new personal project publishes empty jar without amount")
	var base := directory.path_join("display-personal-" + str(Time.get_ticks_usec()))
	var flow := PersonalFlow.new(base)
	var created := flow.create_opening_cash("open-display", "cash-1", "私密现金账户", "50000", "1000", "2026-09-27T00:00:00Z")
	_check(created.ok, "personal fixture saved")
	var loaded := Store.new(base).load_project()
	var current := Display.build(loaded.state, loaded.generation)
	_check(current.ok and current.snapshot.snapshot_status == "CURRENT" and current.snapshot.display_amount == "50000" and current.snapshot.beans.size() == 50, "current snapshot uses one committed amount and inventory")
	var mismatched: Dictionary = loaded.state.duplicate(true)
	mismatched.ledger.events.append({"not": "a committed event"})
	var mismatched_view := Display.build(mismatched, loaded.generation)
	_check(mismatched_view.ok and mismatched_view.snapshot.snapshot_status == "PREVIOUS_COMPLETE" and not mismatched_view.snapshot.has("display_amount"), "unmatched ledger cannot be published as a current amount")
	var wrong_inventory: Dictionary = loaded.state.duplicate(true)
	wrong_inventory.inventory.mapping_id = "unrelated-mapping"
	var wrong_view := Display.build(wrong_inventory, loaded.generation)
	_check(not wrong_view.ok, "mapping and bean inventory must be one version")
	var serialized := JSON.stringify(current.snapshot)
	_check(serialized.find("私密现金账户") < 0 and serialized.find("USER_MANUAL") < 0 and serialized.find("1000") < 0, "display payload omits account identity and quote price")
	var hidden := flow.set_presentation("privacy_mode", "hide_total", created.generation)
	_check(hidden.ok, "privacy saved")
	loaded = Store.new(base).load_project()
	var private_view := Display.build(loaded.state, loaded.generation)
	_check(private_view.ok and private_view.snapshot.privacy_mode == "hide_total" and not private_view.snapshot.has("display_amount") and not private_view.snapshot.has("display_currency"), "privacy payload contains no amount or currency")
	var added := Ledger.apply(loaded.state.ledger, {"command_id": "import-for-display", "type": "cash_delta", "account_id": "cash-1", "delta": "1000", "external": true, "effective_at": "2026-09-27T01:00:00Z"})
	_check(added.ok, "new ledger event accepted")
	if added.ok:
		loaded.state.ledger = added.state
		loaded.state.valuation_pending = {"reason": "CSV_IMPORT", "ledger_hash": Store.canonical_ledger_hash(added.state)}
		var saved := Store.new(base).save_project(loaded.state, loaded.generation)
		_check(saved.ok, "pending ledger generation saved")
		if saved.ok:
			var pending := Display.build(Store.new(base).load_project().state, saved.generation)
			_check(pending.ok and pending.snapshot.snapshot_status == "PREVIOUS_COMPLETE" and pending.snapshot.beans.size() == 50 and not pending.snapshot.has("display_amount"), "pending snapshot is explicitly previous and does not publish old amount")
	var demo_base := directory.path_join("display-demo-" + str(Time.get_ticks_usec()))
	_check(DemoFlow.new(demo_base).load_or_create().ok, "demo fixture saved")
	var demo_loaded := Store.new(demo_base).load_project()
	var demo := Display.build(demo_loaded.state, demo_loaded.generation)
	_check(demo.ok and demo.snapshot.data_kind == "demo" and demo.snapshot.demo_badge, "demo badge is mandatory")
	var invalid_jar := Display.build(demo_loaded.state, demo_loaded.generation, "not-a-jar")
	_check(not invalid_jar.ok and invalid_jar.error == "UNKNOWN_JAR", "unknown jar cannot masquerade as empty")
	var reprice_base := directory.path_join("display-reprice-" + str(Time.get_ticks_usec()))
	var opened := PersonalFlow.new(reprice_base).create_opening_cash("open-reprice", "cash-1",
		"Synthetic", "50000", "1000", "2026-09-27T00:00:00Z")
	_check(opened.ok and opened.display_snapshot.snapshot_status == "CURRENT", "reprice fixture starts current")
	if opened.ok:
		var reprice_store := Store.new(reprice_base)
		var before_quote := reprice_store.load_project()
		var identity := {"kind": "GOLD", "market": "SPOT", "symbol": "XAU",
			"currency": "CNY", "share_class": ""}
		var key := Contract.identity_key(identity)
		var quote := {"id": "user-reprice-1250", "identity": identity, "price": "1250",
			"currency": "CNY", "unit": "CURRENCY_PER_GRAM", "source": "USER_MANUAL",
			"provider_symbol": "XAU", "quoted_at": "2026-09-27T02:00:00Z",
			"fetched_at": "2026-09-27T02:00:00Z", "delay": "MANUAL",
			"session": "MANUAL_INPUT"}
		var refresh := Gateway.refresh(before_quote.state.quote_gateway, [identity],
			ManualProvider.new({key: quote}), "2026-09-27T02:00:00Z", "display-reprice-batch")
		var valued := reprice_store.commit_quote_valuation(refresh, [],
			[{"balance_id": "cash-1", "amount": "50000", "currency": "CNY"}],
			false, before_quote.generation)
		_check(valued.ok, "new valuation saves before gold mapping")
		if valued.ok:
			var intermediate := reprice_store.load_project()
			var intermediate_display := Display.build(intermediate.state, intermediate.generation)
			_check(intermediate_display.ok and intermediate_display.snapshot.snapshot_status == "PREVIOUS_COMPLETE"
				and intermediate_display.snapshot.beans.size() == 50
				and not intermediate_display.snapshot.has("display_amount")
				and not intermediate.state.valuation_pending.is_empty(),
				"valuation-only generation never publishes old beans as current")
			var mapped := GoldFlow.new(reprice_base).apply({"valuation_snapshot_id": str(valued.snapshot.id),
				"gold_batch_id": "display-reprice-batch", "gold_quote_key": key,
				"gold_fx_key": "", "allow_stale": false, "reason": "USER_REPRICE"},
				valued.generation, "2026-09-27T02:00:00Z")
			_check(mapped.ok, "gold mapping applies after valuation")
			if mapped.ok:
				var completed := reprice_store.load_project()
				var completed_display := Display.build(completed.state, completed.generation)
				_check(completed_display.ok and completed_display.snapshot.snapshot_status == "CURRENT"
					and completed_display.snapshot.beans.size() == 40
					and completed_display.snapshot.display_amount == "50000",
					"only completed valuation and gold mapping publish current amount and 40 beans")
	print("display snapshot: %s" % ("passed" if failures == 0 else "%d failures" % failures))
	quit(0 if failures == 0 else 1)


func _check(condition: bool, label: String) -> void:
	if not condition:
		printerr("display snapshot failure: ", label)
		failures += 1
