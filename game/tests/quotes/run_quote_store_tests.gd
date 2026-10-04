extends SceneTree

const Store = preload("res://scripts/data/project_store.gd")
const Ledger = preload("res://scripts/data/ledger_core.gd")
const Contract = preload("res://scripts/quotes/quote_contract.gd")
const Gateway = preload("res://scripts/quotes/quote_gateway.gd")
const ManualProvider = preload("res://scripts/quotes/manual_quote_provider.gd")
const Valuation = preload("res://scripts/quotes/valuation_batch_service.gd")

const NOW := "2026-09-27T02:00:00Z"
const LATER := "2026-09-27T02:02:00Z"

var checks := 0
var failures: Array[String] = []
var directory := ""


func _initialize() -> void:
	directory = ProjectSettings.globalize_path("res://").get_base_dir().path_join("tests").path_join("data").path_join("tmp")
	DirAccess.make_dir_recursive_absolute(directory)
	var suffix := str(Time.get_ticks_usec())
	_test_old_v2_optional_fields(directory.path_join("quote-old-v2-" + suffix))
	_test_pending_validation(directory.path_join("quote-pending-" + suffix))
	_test_complete_holdings_and_restart(directory.path_join("quote-personal-" + suffix))
	_test_zero_holdings_multi_account(directory.path_join("quote-cash-only-" + suffix))
	if failures.is_empty():
		print("QUOTE STORE TESTS PASS: %d checks" % checks)
		quit(0)
	else:
		for failure in failures:
			printerr(failure)
		printerr("QUOTE STORE TESTS FAIL: %d failures in %d checks" % [failures.size(), checks])
		quit(1)


func _test_old_v2_optional_fields(path: String) -> void:
	var store := Store.new(path)
	var old_v2 := store.new_project()
	old_v2.erase("quote_gateway")
	old_v2.erase("valuation")
	old_v2.custom_marker = {"preserve": "yes"}
	var saved := store.save_project(old_v2, 0)
	_check(saved.ok, "legacy v2 state without new fields still saves")
	var restored := Store.new(path).load_project()
	_check(restored.ok and restored.migrated and restored.state.schema_version == 2
		and restored.state.custom_marker.preserve == "yes"
		and restored.state.quote_gateway.batches.is_empty()
		and restored.state.valuation.snapshots.is_empty(),
		"existing v2 empty fields hydrate without data loss or version bump")
	var saved_hydrated := Store.new(path).save_project(restored.state, restored.generation)
	_check(saved_hydrated.ok and Store.new(path).load_project().state.custom_marker.preserve == "yes",
		"hydrated v2 state persists in next generation")


func _test_pending_validation(path: String) -> void:
	var store := Store.new(path)
	var state := store.new_project()
	state.valuation_pending = {"reason": "TRADE_CONFIRMED",
		"ledger_hash": Store.canonical_ledger_hash(state.ledger)}
	var saved := store.save_project(state, 0)
	_check(saved.ok, "matching pending ledger hash saves: " + str(saved.get("error", "OK")))
	var invalid: Dictionary = state.duplicate(true)
	invalid.valuation_pending.ledger_hash = "0".repeat(64)
	_check(store.save_project(invalid, 1).error == "INVALID_PROJECT_SCHEMA",
		"pending hash for another ledger is rejected")
	invalid = state.duplicate(true)
	invalid.valuation_pending.extra = "unversioned"
	_check(store.save_project(invalid, 1).error == "INVALID_PROJECT_SCHEMA",
		"pending marker rejects unknown fields")
	invalid = state.duplicate(true)
	var changed := Ledger.apply(invalid.ledger, {"command_id": "pending-account", "type": "account_create",
		"account": {"id": "cash", "currency": "CNY", "mode": "detail", "cost_method": "FIFO"}})
	invalid.ledger = changed.state
	_check(store.save_project(invalid, 1).error == "INVALID_PROJECT_SCHEMA",
		"ledger mutation without refreshed pending hash cannot save")


func _test_complete_holdings_and_restart(path: String) -> void:
	var store := Store.new(path)
	var project := store.new_project()
	var commands := [
		{"command_id": "account-usd", "type": "account_create", "account": {"id": "broker-usd", "currency": "USD", "mode": "detail", "cost_method": "FIFO"}},
		{"command_id": "account-cny", "type": "account_create", "account": {"id": "cash-cny", "currency": "CNY", "mode": "detail", "cost_method": "FIFO"}},
		{"command_id": "opening-usd", "type": "opening_cash", "account_id": "broker-usd", "amount": "100", "effective_at": NOW},
		{"command_id": "opening-cny", "type": "opening_cash", "account_id": "cash-cny", "amount": "300", "effective_at": NOW},
		{"command_id": "instrument-a", "type": "instrument_create", "instrument": {"id": "s-a", "kind": "STOCK", "market": "NASDAQ", "symbol": "TESTA", "currency": "USD"}},
		{"command_id": "instrument-b", "type": "instrument_create", "instrument": {"id": "s-b", "kind": "STOCK", "market": "NASDAQ", "symbol": "TESTB", "currency": "USD"}},
		{"command_id": "holding-a", "type": "opening_position", "account_id": "broker-usd", "instrument_id": "s-a", "quantity": "2", "reference_price": "10", "cost_basis": "20", "effective_at": NOW},
		{"command_id": "holding-b", "type": "opening_position", "account_id": "broker-usd", "instrument_id": "s-b", "quantity": "2", "reference_price": "10", "cost_basis": "20", "effective_at": NOW},
	]
	for command in commands:
		var result := Ledger.apply(project.ledger, command)
		if not result.ok:
			_check(false, "ledger setup: " + str(result.get("error", "")))
			return
		project.ledger = result.state
	var seeded := store.save_project(project, 0)
	_check(seeded.ok, "personal ledger with two holdings and two cash accounts saved")
	if not seeded.ok:
		return
	var identities := [
		_identity("STOCK", "NASDAQ", "TESTA", "USD"),
		_identity("STOCK", "NASDAQ", "TESTB", "USD"),
		_identity("FX", "FX", "USD/CNY", "CNY"),
		_identity("GOLD", "SPOT", "XAU", "CNY"),
	]
	var quotes := _quotes(identities)
	var provider := ManualProvider.new(quotes)
	var refresh := Gateway.refresh(project.quote_gateway, identities, provider, NOW, "personal-batch-1")
	_check(refresh.ok and refresh.batch.status == "COMPLETE",
		"manual batch completed with securities, FX and gold")
	if not refresh.ok:
		return
	var positions := [
		{"position_id": "broker-usd|s-a", "identity": identities[0], "quantity": "2"},
		{"position_id": "broker-usd|s-b", "identity": identities[1], "quantity": "2"},
	]
	var cash := [
		{"balance_id": "broker-usd", "amount": "100", "currency": "USD"},
		{"balance_id": "cash-cny", "amount": "300", "currency": "CNY"},
	]
	var missing_position := store.commit_quote_valuation(refresh, [positions[0]], cash,
		false, seeded.generation)
	_check(not missing_position.ok and missing_position.error == "VALUATION_COVERAGE_MISMATCH"
		and store.load_project().generation == seeded.generation,
		"partial holdings rejected before an asset-total snapshot or write")
	var missing_cash := store.commit_quote_valuation(refresh, positions, [cash[0]],
		false, seeded.generation)
	_check(not missing_cash.ok and missing_cash.error == "VALUATION_COVERAGE_MISMATCH",
		"partial multi-account cash rejected")
	var wrong_identity := positions.duplicate(true)
	wrong_identity[0].identity.market = "NYSE"
	var mismatch := store.commit_quote_valuation(refresh, wrong_identity, cash,
		false, seeded.generation)
	_check(not mismatch.ok and mismatch.error == "VALUATION_COVERAGE_MISMATCH",
		"market identity must match the ledger instrument")
	var committed := store.commit_quote_valuation(refresh, positions, cash,
		false, seeded.generation)
	_check(committed.ok and not committed.duplicate and committed.snapshot.asset_total == "1280"
		and committed.snapshot.position_values.size() == 2
		and committed.snapshot.cash_values.size() == 2,
		"complete projection produces CNY 1280 snapshot through save_project")
	if not committed.ok:
		return
	var expected_pending := {"reason": "QUOTE_VALUATION_PENDING_MAPPING",
		"ledger_hash": Store.canonical_ledger_hash(project.ledger)}
	_check(store.load_project().state.valuation_pending == expected_pending,
		"quote valuation keeps the saved jar pending until gold mapping")
	var restarted := Store.new(path)
	var loaded := restarted.load_project()
	_check(loaded.ok and loaded.generation == committed.generation
		and loaded.state.valuation.snapshots[committed.snapshot.id].asset_total == "1280"
		and loaded.state.quote_gateway.batches.has("personal-batch-1")
		and loaded.state.ledger.events.size() == project.ledger.events.size()
		and loaded.state.valuation_pending == expected_pending,
		"new Store restores quote batch, valuation, ledger and pending marker together")
	_check(loaded.state.valuation.snapshots[committed.snapshot.id].ledger_hash == \
		Store.canonical_ledger_hash(loaded.state.ledger) and \
		restarted.current_valuation_snapshot(loaded.state, committed.snapshot.id).ok,
		"saved complete valuation is bound to exact current ledger version")
	var legacy_snapshot_state: Dictionary = loaded.state.duplicate(true)
	legacy_snapshot_state.valuation.snapshots[committed.snapshot.id].erase("ledger_hash")
	var legacy_store := Store.new(path + "-legacy-snapshot")
	var legacy_saved := legacy_store.save_project(legacy_snapshot_state, 0)
	_check(legacy_saved.ok and legacy_store.load_project().ok and \
		legacy_store.current_valuation_snapshot(
			legacy_store.load_project().state, committed.snapshot.id).error == "UNVERIFIED_ASSET_VERSION",
		"historical snapshot without ledger hash stays readable but is not current proof")
	var replay_refresh := Gateway.refresh(loaded.state.quote_gateway, identities,
		provider, LATER, "personal-batch-1")
	var replay := restarted.commit_quote_valuation(replay_refresh, positions, cash,
		false, loaded.generation)
	_check(replay.ok and replay.duplicate and replay.generation == loaded.generation
		and restarted.load_project().state.valuation.snapshots.size() == 1
		and restarted.load_project().state.valuation_pending == expected_pending,
		"same batch after restart is idempotent without clearing pending marker")
	var reused_id := Gateway.refresh(loaded.state.quote_gateway, [identities[0]],
		provider, LATER, "personal-batch-1")
	_check(not reused_id.ok and reused_id.error == "BATCH_ID_CONFLICT",
		"batch ID with changed request is rejected after restart")
	var changed: Dictionary = loaded.state.duplicate(true)
	var added := Ledger.apply(changed.ledger, {"command_id": "new-cash", "type": "cash_delta",
		"account_id": "cash-cny", "delta": "1", "external": true, "effective_at": LATER})
	_check(added.ok, "new ledger event after valuation is accepted")
	if not added.ok:
		return
	changed.ledger = added.state
	changed.valuation_pending = {"reason": "TEST_LEDGER_CHANGE",
		"ledger_hash": Store.canonical_ledger_hash(added.state)}
	var changed_saved := restarted.save_project(changed, loaded.generation)
	_check(changed_saved.ok, "ledger can advance while historical valuation is preserved")
	_check(changed_saved.ok and restarted.load_project().state.valuation_pending ==
		changed.valuation_pending and changed.valuation_pending.ledger_hash !=
		expected_pending.ledger_hash,
		"ledger change persists a refreshed pending hash rather than the old one")
	_check(restarted.current_valuation_snapshot(restarted.load_project().state,
		committed.snapshot.id).error == "NEEDS_VALUATION",
		"ledger change makes formerly valid saved snapshot stale")
	var updated_cash := cash.duplicate(true)
	updated_cash[1].amount = "301"
	var same_batch_new_assets := restarted.commit_quote_valuation(replay_refresh,
		positions, updated_cash, false, changed_saved.generation)
	_check(not same_batch_new_assets.ok and same_batch_new_assets.error == "BATCH_INPUT_CONFLICT"
		and restarted.load_project().generation == changed_saved.generation,
		"same batch cannot value changed ledger as another snapshot")
	var unclassified_ledger: Dictionary = changed.ledger.duplicate(true)
	unclassified_ledger.instruments["s-a"].erase("kind")
	var unclassified := restarted.validate_valuation_coverage(unclassified_ledger,
		positions, updated_cash)
	_check(not unclassified.ok and unclassified.error == "INSTRUMENT_KIND_UNKNOWN",
		"legacy holding without asset class requires explicit classification")


func _test_zero_holdings_multi_account(path: String) -> void:
	var store := Store.new(path)
	var project := store.new_project()
	var commands := [
		{"command_id": "cash-account", "type": "account_create", "account": {"id": "cash-cny", "currency": "CNY", "mode": "detail", "cost_method": "FIFO"}},
		{"command_id": "foreign-account", "type": "account_create", "account": {"id": "cash-usd", "currency": "USD", "mode": "detail", "cost_method": "FIFO"}},
		{"command_id": "cash-opening", "type": "opening_cash", "account_id": "cash-cny", "amount": "300", "effective_at": NOW},
		{"command_id": "foreign-opening", "type": "opening_cash", "account_id": "cash-usd", "amount": "100", "effective_at": NOW},
	]
	for command in commands:
		var result := Ledger.apply(project.ledger, command)
		if not result.ok:
			_check(false, "cash-only ledger setup")
			return
		project.ledger = result.state
	var seeded := store.save_project(project, 0)
	_check(seeded.ok, "zero-holding two-account project saved")
	if not seeded.ok:
		return
	var identities := [_identity("FX", "FX", "USD/CNY", "CNY"),
		_identity("GOLD", "SPOT", "XAU", "CNY")]
	var refresh := Gateway.refresh(project.quote_gateway, identities,
		ManualProvider.new(_quotes(identities)), NOW, "cash-only-batch")
	var cash := [{"balance_id": "cash-cny", "amount": "300", "currency": "CNY"},
		{"balance_id": "cash-usd", "amount": "100", "currency": "USD"}]
	var committed := store.commit_quote_valuation(refresh, [], cash, false, seeded.generation)
	_check(committed.ok and committed.snapshot.asset_total == "1000"
		and committed.snapshot.position_values.is_empty()
		and Store.new(path).load_project().state.valuation.snapshots.size() == 1
		and Store.new(path).load_project().state.valuation_pending ==
		{"reason": "QUOTE_VALUATION_PENDING_MAPPING",
		"ledger_hash": Store.canonical_ledger_hash(project.ledger)},
		"zero holdings and two cash accounts produce a complete pending valuation")


func _identity(kind: String, market: String, symbol: String, currency: String) -> Dictionary:
	return {"kind": kind, "market": market, "symbol": symbol,
		"currency": currency, "share_class": ""}


func _quotes(identities: Array) -> Dictionary:
	var result := {}
	for identity in identities:
		var key := Contract.identity_key(identity)
		var unit := "CURRENCY_PER_SHARE"
		var price := "10"
		if identity.kind == "FX":
			unit = "CURRENCY_PER_FOREIGN_UNIT"
			price = "7"
		elif identity.kind == "GOLD":
			unit = "CURRENCY_PER_GRAM"
			price = "1000"
		result[key] = {"id": "manual-" + key.sha256_text().substr(0, 12),
			"identity": identity, "price": price, "currency": identity.currency,
			"unit": unit, "source": "USER_MANUAL", "provider_symbol": identity.symbol,
			"quoted_at": NOW, "fetched_at": NOW, "delay": "MANUAL", "session": "MANUAL_INPUT"}
	return result


func _check(condition: bool, label: String) -> void:
	checks += 1
	if not condition:
		failures.append("FAIL: " + label)
