extends SceneTree

const Store = preload("res://scripts/data/project_store.gd")
const Ledger = preload("res://scripts/data/ledger_core.gd")
const Contract = preload("res://scripts/quotes/quote_contract.gd")
const Gateway = preload("res://scripts/quotes/quote_gateway.gd")
const ManualProvider = preload("res://scripts/quotes/manual_quote_provider.gd")
const Flow = preload("res://scripts/quotes/personal_gold_flow.gd")
const Inventory = preload("res://scripts/domain/jar_inventory.gd")
const Display = preload("res://scripts/data/display_snapshot_service.gd")

const T0 := "2026-09-27T02:00:00Z"
const T1 := "2026-09-27T02:06:00Z"
const T2 := "2026-09-27T02:12:00Z"
const T3 := "2026-09-27T02:18:00Z"
const T4 := "2026-09-27T02:24:00Z"
const T5 := "2026-09-27T02:30:00Z"
const T_DAY := "2026-09-28T02:30:00Z"

var checks := 0
var failures: Array[String] = []
var directory := ""


func _initialize() -> void:
	directory = ProjectSettings.globalize_path("res://").get_base_dir().path_join("tests").path_join("data").path_join("tmp")
	DirAccess.make_dir_recursive_absolute(directory)
	var suffix := str(Time.get_ticks_usec())
	_test_mapping_restart_reprice_failure(directory.path_join("personal-gold-" + suffix))
	_test_cross_currency_troy(directory.path_join("personal-gold-fx-" + suffix))
	_test_asset_quote_expiry(directory.path_join("personal-gold-asset-expiry-" + suffix))
	_test_unverified_and_demo(directory.path_join("personal-gold-unverified-" + suffix))
	if failures.is_empty():
		print("PERSONAL GOLD TESTS PASS: %d checks" % checks)
		quit(0)
	else:
		for failure in failures:
			printerr(failure)
		printerr("PERSONAL GOLD TESTS FAIL: %d failures in %d checks" % [failures.size(), checks])
		quit(1)


func _test_mapping_restart_reprice_failure(path: String) -> void:
	var store := Store.new(path)
	var project := _cash_project(store, "100000")
	if project.is_empty():
		return
	project.valuation_pending = {"reason": "TRADE_CONFIRMED",
		"ledger_hash": Store.canonical_ledger_hash(project.ledger)}
	var seeded := store.save_project(project, 0)
	_check(seeded.ok, "personal cash ledger and pending marker saved")
	if not seeded.ok:
		return
	var gold_identity := _identity("GOLD", "SPOT", "XAU", "CNY")
	var gold_key := Contract.identity_key(gold_identity)
	var quote1 := _quote(gold_identity, "1000", "gold-1000", T0, T0)
	var first := _refresh(project.quote_gateway, [gold_identity], {gold_key: quote1}, T0,
		"asset-gold-1")
	var valued := store.commit_quote_valuation(first, [], [_cash("100000")], false,
		seeded.generation)
	_check(valued.ok and valued.snapshot.asset_total == "100000"
		and not store.load_project().state.valuation_pending.is_empty(),
		"saved full valuation keeps pending until mapping/inventory persist")
	if not valued.ok:
		return
	var flow := Flow.new(path)
	var selection := _selection(str(valued.snapshot.id), "asset-gold-1", gold_key,
		"", false, "USER_ASSET_UPDATE")
	var first_mapping := flow.apply(selection, valued.generation, T0)
	_check(first_mapping.ok and first_mapping.changed
		and first_mapping.mapping.equivalent_grams == "100"
		and first_mapping.mapping.amount == "100000"
		and first_mapping.mapping.ledger_hash == Store.canonical_ledger_hash(project.ledger),
		"personal valuation maps to 100 grams")
	if not first_mapping.ok:
		return
	var restarted := Store.new(path)
	var restored := restarted.load_project()
	_check(restored.ok and not restored.state.has("valuation_pending")
		and restored.state.mappings.size() == 1
		and Inventory.active_beans(restored.state.inventory).size() == 100
		and restored.state.inventory.mapping_id == first_mapping.mapping.id,
		"restart restores one committed mapping/inventory generation and clears pending")
	var displayed := Display.build(restored.state, restored.generation)
	_check(displayed.ok and displayed.snapshot.snapshot_status == "CURRENT"
		and displayed.snapshot.display_amount == "100000"
		and displayed.snapshot.selected_jar_id == "jar-000001",
		"atomic personal gold save produces current minimal display snapshot")
	var replay := Flow.new(path).apply(selection, restored.generation, T0)
	_check(replay.ok and replay.duplicate and replay.generation == restored.generation
		and Store.new(path).load_project().state.mappings.size() == 1,
		"same asset version and gold quote replay is idempotent")
	var late_replay := Flow.new(path).apply(selection, restored.generation,
		"2026-09-28T02:00:00Z")
	_check(not late_replay.ok and late_replay.error == "STALE_QUOTE_CONFIRMATION_REQUIRED"
		and Store.new(path).load_project().generation == restored.generation,
		"old saved gold quote requires fresh explicit stale confirmation at apply time")
	var legacy_mapping_state: Dictionary = restored.state.duplicate(true)
	legacy_mapping_state.mappings[0].erase("ledger_hash")
	legacy_mapping_state.mappings[0].erase("asset_ledger_hash")
	var legacy_mapping_store := Store.new(path + "-legacy-mapping")
	var legacy_mapping_saved := legacy_mapping_store.save_project(legacy_mapping_state, 0)
	_check(legacy_mapping_saved.ok and legacy_mapping_store.load_project().ok,
		"historical mapping without ledger hash remains readable")
	var wrong_generation := Flow.new(path).apply(selection, seeded.generation, T0)
	_check(not wrong_generation.ok and wrong_generation.error == "GENERATION_CONFLICT",
		"stale project generation cannot replace displayed jar")
	var quote2 := _quote(gold_identity, "1250", "gold-1250", T1, T1)
	var refresh2 := _refresh(restored.state.quote_gateway, [gold_identity],
		{gold_key: quote2}, T1, "gold-reprice-2")
	var with_second_batch: Dictionary = restored.state.duplicate(true)
	with_second_batch.quote_gateway = refresh2.state
	var saved_quote2 := restarted.save_project(with_second_batch, restored.generation)
	_check(saved_quote2.ok, "new gold batch saved before repricing")
	var repriced_selection := _selection(str(valued.snapshot.id), "gold-reprice-2",
		gold_key, "", false, "USER_REPRICE")
	var repriced := Flow.new(path).apply(repriced_selection, saved_quote2.generation, T1)
	_check(repriced.ok and repriced.mapping.amount == "100000"
		and repriced.mapping.equivalent_grams == "80"
		and repriced.mapping.gold_price_change_grams == "-20"
		and Store.new(path).load_project().state.inventory.whole_grams == 80,
		"gold price increase reduces beans without changing ledger assets")
	if not repriced.ok:
		return
	var after_reprice := Store.new(path).load_project()
	var prior_replay := Flow.new(path).apply(selection, after_reprice.generation, T1)
	var after_prior_replay := Store.new(path).load_project()
	_check(not prior_replay.ok and prior_replay.error == "MAPPING_KEY_ALREADY_APPLIED"
		and after_prior_replay.generation == after_reprice.generation
		and after_prior_replay.state.mappings.size() == 2
		and after_prior_replay.state.inventory.whole_grams == 80,
		"A-B-A quote replay cannot append duplicate mapping key or restore old beans")
	var zero_quote := _quote(gold_identity, "0", "bad-zero", T2, T2)
	var fallback := _refresh(after_reprice.state.quote_gateway, [gold_identity],
		{gold_key: zero_quote}, T2, "bad-gold-batch")
	_check(fallback.ok and fallback.batch.status == "COMPLETE_WITH_STALE"
		and fallback.batch.entries[gold_key].status == "STALE_FALLBACK",
		"zero new gold price preserves the old quote as stale fallback")
	var with_failed_batch: Dictionary = after_reprice.state.duplicate(true)
	with_failed_batch.quote_gateway = fallback.state
	var saved_failed := Store.new(path).save_project(with_failed_batch, after_reprice.generation)
	var refused := Flow.new(path).apply(_selection(str(valued.snapshot.id),
		"bad-gold-batch", gold_key, "", false, "USER_REPRICE"), saved_failed.generation, T2)
	var unchanged := Store.new(path).load_project()
	_check(not refused.ok and refused.error == "STALE_QUOTE_CONFIRMATION_REQUIRED"
		and unchanged.generation == saved_failed.generation
		and unchanged.state.inventory.whole_grams == 80
		and unchanged.state.mappings.size() == 2,
		"unconfirmed old price leaves the saved jar unchanged")
	var stock := _identity("STOCK", "NASDAQ", "UNAVAILABLE", "USD")
	var incomplete := _refresh(unchanged.state.quote_gateway, [gold_identity, stock],
		{gold_key: _quote(gold_identity, "1250", "gold-1250-new", T3, T3)},
		T3, "incomplete-gold-batch")
	_check(incomplete.ok and incomplete.batch.status == "INCOMPLETE",
		"missing second requested quote makes batch incomplete")
	var with_incomplete: Dictionary = unchanged.state.duplicate(true)
	with_incomplete.quote_gateway = incomplete.state
	var saved_incomplete := Store.new(path).save_project(with_incomplete, unchanged.generation)
	var refused_incomplete := Flow.new(path).apply(_selection(str(valued.snapshot.id),
		"incomplete-gold-batch", gold_key, "", false, "USER_REPRICE"),
		saved_incomplete.generation, T3)
	_check(not refused_incomplete.ok and refused_incomplete.error == "GOLD_BATCH_INCOMPLETE"
		and Store.new(path).load_project().state.inventory.whole_grams == 80,
		"cross-batch missing item cannot silently update jar")
	var changed: Dictionary = Store.new(path).load_project().state
	var new_cash := Ledger.apply(changed.ledger, {"command_id": "cash-plus-1000",
		"type": "cash_delta", "account_id": "cash", "delta": "1000",
		"external": true, "effective_at": T4})
	changed.ledger = new_cash.state
	changed.valuation_pending = {"reason": "TRADE_CONFIRMED",
		"ledger_hash": Store.canonical_ledger_hash(changed.ledger)}
	var before_change := Store.new(path).load_project()
	var unsafe_change: Dictionary = changed.duplicate(true)
	unsafe_change.erase("valuation_pending")
	var rejected_without_pending := Store.new(path).save_project(unsafe_change,
		before_change.generation)
	_check(not rejected_without_pending.ok and rejected_without_pending.error == "INVALID_PROJECT_SCHEMA"
		and Store.new(path).load_project().generation == before_change.generation,
		"new ledger cannot retain versioned old mapping without pending marker")
	var saved_changed := Store.new(path).save_project(changed, before_change.generation)
	var old_snapshot_attempt := Flow.new(path).apply(repriced_selection,
		saved_changed.generation, T4)
	var after_old_attempt := Store.new(path).load_project()
	_check(not old_snapshot_attempt.ok and old_snapshot_attempt.error == "NEEDS_VALUATION"
		and not after_old_attempt.state.valuation_pending.is_empty()
		and after_old_attempt.state.inventory.whole_grams == 80,
		"ledger change invalidates saved snapshot and preserves pending/old jar")
	var pending_display := Display.build(after_old_attempt.state, after_old_attempt.generation)
	_check(pending_display.ok and pending_display.snapshot.snapshot_status == "PREVIOUS_COMPLETE"
		and not pending_display.snapshot.has("display_amount"),
		"pending ledger shows previous jar without publishing an old asset amount")
	var refresh_new_asset := _refresh(after_old_attempt.state.quote_gateway,
		[gold_identity], {gold_key: _quote(gold_identity, "1250", "gold-1250-asset", T4, T4)},
		T4, "asset-gold-2")
	var newly_valued := Store.new(path).commit_quote_valuation(refresh_new_asset,
		[], [_cash("101000")], false, after_old_attempt.generation)
	_check(newly_valued.ok and newly_valued.snapshot.ledger_hash == \
		Store.canonical_ledger_hash(after_old_attempt.state.ledger),
		"new ledger version receives a newly bound full valuation")
	if not newly_valued.ok:
		return
	var applied_new := Flow.new(path).apply(_selection(str(newly_valued.snapshot.id),
		"asset-gold-2", gold_key, "", false, "USER_ASSET_UPDATE"),
		newly_valued.generation, T4)
	_check(applied_new.ok and applied_new.mapping.amount == "101000"
		and applied_new.mapping.equivalent_grams == "80.8"
		and not Store.new(path).load_project().state.has("valuation_pending"),
		"matching new snapshot maps and clears pending after atomic save")
	if not applied_new.ok:
		return
	var same_total: Dictionary = Store.new(path).load_project().state
	var plus_one := Ledger.apply(same_total.ledger, {"command_id": "same-total-plus",
		"type": "cash_delta", "account_id": "cash", "delta": "1",
		"external": true, "effective_at": T5})
	var minus_one := Ledger.apply(plus_one.state, {"command_id": "same-total-minus",
		"type": "cash_delta", "account_id": "cash", "delta": "-1",
		"external": true, "effective_at": T5})
	same_total.ledger = minus_one.state
	same_total.valuation_pending = {"reason": "TRADE_CONFIRMED",
		"ledger_hash": Store.canonical_ledger_hash(same_total.ledger)}
	var saved_same_total := Store.new(path).save_project(same_total, applied_new.generation)
	var rejected_old := Flow.new(path).apply(_selection(str(newly_valued.snapshot.id),
		"asset-gold-2", gold_key, "", false, "USER_ASSET_UPDATE"),
		saved_same_total.generation, T5)
	_check(not rejected_old.ok and rejected_old.error == "NEEDS_VALUATION"
		and Store.new(path).load_project().state.mappings.back().id == applied_new.mapping.id,
		"same amount with two new ledger events still invalidates old asset snapshot")
	var refreshed_same := _refresh(same_total.quote_gateway, [gold_identity],
		{gold_key: _quote(gold_identity, "1250", "gold-1250-same", T5, T5)},
		T5, "asset-gold-same-total")
	var same_valued := Store.new(path).commit_quote_valuation(refreshed_same,
		[], [_cash("101000")], false, saved_same_total.generation)
	var same_mapped := Flow.new(path).apply(_selection(str(same_valued.snapshot.id),
		"asset-gold-same-total", gold_key, "", false, "USER_ASSET_UPDATE"),
		same_valued.generation, T5)
	var same_restored := Store.new(path).load_project()
	_check(same_mapped.ok and same_mapped.changed
		and same_mapped.mapping.id != applied_new.mapping.id
		and same_mapped.mapping.amount == applied_new.mapping.amount
		and same_mapped.mapping.equivalent_grams == applied_new.mapping.equivalent_grams
		and same_mapped.mapping.ledger_hash == Store.canonical_ledger_hash(same_restored.state.ledger)
		and not same_restored.state.has("valuation_pending"),
		"same numeric assets and gold price still create new bound mapping for new ledger version")
	var current_display := Display.build(same_restored.state, same_restored.generation)
	_check(current_display.ok and current_display.snapshot.snapshot_status == "CURRENT"
		and current_display.snapshot.display_amount == "101000",
		"new same-total mapping restores current display status")


func _test_cross_currency_troy(path: String) -> void:
	var store := Store.new(path)
	var project := _cash_project(store, "7000")
	var seeded := store.save_project(project, 0)
	if not seeded.ok:
		_check(false, "FX test setup")
		return
	var gold := _identity("GOLD", "SPOT", "XAU", "USD")
	var fx := _identity("FX", "FX", "USD/CNY", "CNY")
	var gold_key := Contract.identity_key(gold)
	var fx_key := Contract.identity_key(fx)
	var gold_quote := _quote(gold, "3110.34768", "gold-troy", T0, T0)
	gold_quote.unit = "CURRENCY_PER_TROY_OUNCE"
	var refresh := _refresh(project.quote_gateway, [gold, fx],
		{gold_key: gold_quote, fx_key: _quote(fx, "7", "fx-seven", T0, T0)},
		T0, "troy-batch")
	var valued := store.commit_quote_valuation(refresh, [], [_cash("7000")],
		false, seeded.generation)
	if not valued.ok:
		_check(false, "FX valuation setup")
		return
	var missing_fx := Flow.new(path).apply(_selection(str(valued.snapshot.id),
		"troy-batch", gold_key, "", false, "USER_ASSET_UPDATE"), valued.generation, T0)
	_check(not missing_fx.ok and missing_fx.error == "GOLD_FX_SELECTION_REQUIRED",
		"foreign gold quote requires explicitly selected matching FX")
	var accepted := Flow.new(path).apply(_selection(str(valued.snapshot.id),
		"troy-batch", gold_key, fx_key, false, "USER_ASSET_UPDATE"), valued.generation, T0)
	_check(accepted.ok and accepted.mapping.price_per_gram == "700"
		and accepted.mapping.equivalent_grams == "10"
		and accepted.mapping.fx_rate_id == "fx-seven",
		"USD per troy ounce uses selected USD/CNY once to make 10 grams")


func _test_asset_quote_expiry(path: String) -> void:
	var store := Store.new(path)
	var project := store.new_project()
	var account := Ledger.apply(project.ledger, {"command_id": "usd-account",
		"type": "account_create", "account": {"id": "usd", "currency": "USD",
		"mode": "detail", "cost_method": "FIFO"}})
	var opening := Ledger.apply(account.state, {"command_id": "usd-opening",
		"type": "opening_cash", "account_id": "usd", "amount": "100",
		"effective_at": T0})
	project.ledger = opening.state
	var seeded := store.save_project(project, 0)
	if not seeded.ok:
		_check(false, "asset quote expiry setup")
		return
	var fx := _identity("FX", "FX", "USD/CNY", "CNY")
	var gold := _identity("GOLD", "SPOT", "XAU", "CNY")
	var asset_refresh := _refresh(project.quote_gateway, [fx, gold],
		{Contract.identity_key(fx): _quote(fx, "7", "fx-old", T0, T0),
		 Contract.identity_key(gold): _quote(gold, "1000", "gold-old", T0, T0)},
		T0, "usd-asset-batch")
	var valued := store.commit_quote_valuation(asset_refresh, [],
		[{"balance_id": "usd", "amount": "100", "currency": "USD"}],
		false, seeded.generation)
	if not valued.ok:
		_check(false, "USD cash valuation setup")
		return
	var updated := Store.new(path).load_project()
	var gold_refresh := _refresh(updated.state.quote_gateway, [gold],
		{Contract.identity_key(gold): _quote(gold, "1000", "gold-next-day", T_DAY, T_DAY)},
		T_DAY, "gold-next-day-batch")
	var with_new_gold: Dictionary = updated.state.duplicate(true)
	with_new_gold.quote_gateway = gold_refresh.state
	var saved_gold := Store.new(path).save_project(with_new_gold, updated.generation)
	var unconfirmed := Flow.new(path).apply(_selection(str(valued.snapshot.id),
		"gold-next-day-batch", Contract.identity_key(gold), "", false,
		"USER_ASSET_UPDATE"), saved_gold.generation, T_DAY)
	_check(not unconfirmed.ok and unconfirmed.error == \
		"STALE_ASSET_QUOTE_CONFIRMATION_REQUIRED"
		and Store.new(path).load_project().state.mappings.is_empty(),
		"fresh gold cannot silently reuse yesterday's asset FX quote")
	var confirmed := Flow.new(path).apply(_selection(str(valued.snapshot.id),
		"gold-next-day-batch", Contract.identity_key(gold), "", true,
		"USER_ASSET_UPDATE"), saved_gold.generation, T_DAY)
	_check(confirmed.ok and confirmed.mapping.amount == "700"
		and confirmed.mapping.equivalent_grams == "0.7"
		and confirmed.mapping.stale_confirmed
		and Store.new(path).load_project().state.mappings.size() == 1,
		"explicit stale consent allows saved complete USD cash valuation")


func _test_unverified_and_demo(path: String) -> void:
	var store := Store.new(path)
	var project := _cash_project(store, "1000")
	var seeded := store.save_project(project, 0)
	if not seeded.ok:
		_check(false, "unverified test setup")
		return
	var gold := _identity("GOLD", "SPOT", "XAU", "CNY")
	var key := Contract.identity_key(gold)
	var refresh := _refresh(project.quote_gateway, [gold],
		{key: _quote(gold, "1000", "gold-legacy", T0, T0)}, T0, "legacy-batch")
	var valued := store.commit_quote_valuation(refresh, [], [_cash("1000")], false,
		seeded.generation)
	var old_snapshot: Dictionary = Store.new(path).load_project().state
	old_snapshot.valuation.snapshots[valued.snapshot.id].erase("ledger_hash")
	var erased := Store.new(path).save_project(old_snapshot, valued.generation)
	var refused := Flow.new(path).apply(_selection(str(valued.snapshot.id),
		"legacy-batch", key, "", false, "USER_ASSET_UPDATE"), erased.generation, T0)
	_check(not refused.ok and refused.error == "UNVERIFIED_ASSET_VERSION"
		and Store.new(path).load_project().state.mappings.is_empty(),
		"old snapshot without ledger hash remains readable but cannot create beans")
	var demo_store := Store.new(path + "-demo")
	var demo := demo_store.new_project()
	demo.data_kind = "demo"
	var demo_saved := demo_store.save_project(demo, 0)
	var denied := Flow.new(path + "-demo").apply(_selection("none", "none", key,
		"", false, "USER_ASSET_UPDATE"), demo_saved.generation, T0)
	_check(not denied.ok and denied.error == "PERSONAL_PROJECT_REQUIRED",
		"demo state cannot enter personal gold flow")


func _cash_project(store: RefCounted, amount: String) -> Dictionary:
	var project: Dictionary = store.new_project()
	var account := Ledger.apply(project.ledger, {"command_id": "cash-account", "type": "account_create",
		"account": {"id": "cash", "currency": "CNY", "mode": "detail", "cost_method": "FIFO"}})
	if not account.ok:
		_check(false, "cash account setup")
		return {}
	var opening := Ledger.apply(account.state, {"command_id": "cash-opening",
		"type": "opening_cash", "account_id": "cash", "amount": amount,
		"effective_at": T0})
	if not opening.ok:
		_check(false, "cash opening setup")
		return {}
	project.ledger = opening.state
	return project


func _cash(amount: String) -> Dictionary:
	return {"balance_id": "cash", "amount": amount, "currency": "CNY"}


func _identity(kind: String, market: String, symbol: String, currency: String) -> Dictionary:
	return {"kind": kind, "market": market, "symbol": symbol,
		"currency": currency, "share_class": ""}


func _quote(identity: Dictionary, price: String, id: String,
		quoted_at: String, fetched_at: String) -> Dictionary:
	var unit := "CURRENCY_PER_GRAM" if identity.kind == "GOLD" else "CURRENCY_PER_FOREIGN_UNIT"
	return {"id": id, "identity": identity.duplicate(true), "price": price,
		"currency": identity.currency, "unit": unit, "source": "USER_MANUAL",
		"provider_symbol": identity.symbol, "quoted_at": quoted_at,
		"fetched_at": fetched_at, "delay": "MANUAL", "session": "MANUAL_INPUT"}


func _refresh(state: Dictionary, identities: Array, quotes: Dictionary,
		now_at: String, id: String) -> Dictionary:
	return Gateway.refresh(state, identities, ManualProvider.new(quotes), now_at, id)


func _selection(snapshot_id: String, batch_id: String, gold_key: String,
		gold_fx_key: String, allow_stale: bool, reason: String) -> Dictionary:
	return {"valuation_snapshot_id": snapshot_id, "gold_batch_id": batch_id,
		"gold_quote_key": gold_key, "gold_fx_key": gold_fx_key,
		"allow_stale": allow_stale, "reason": reason}


func _check(condition: bool, label: String) -> void:
	checks += 1
	if not condition:
		failures.append("FAIL: " + label)
