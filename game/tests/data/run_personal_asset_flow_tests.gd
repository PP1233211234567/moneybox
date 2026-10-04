extends SceneTree

const Flow = preload("res://scripts/data/personal_asset_flow.gd")
const PersonalFlow = preload("res://scripts/data/personal_flow.gd")
const Store = preload("res://scripts/data/project_store.gd")
const Ledger = preload("res://scripts/data/ledger_core.gd")
const Display = preload("res://scripts/data/display_snapshot_service.gd")
const QuoteContract = preload("res://scripts/quotes/quote_contract.gd")
const QuoteGateway = preload("res://scripts/quotes/quote_gateway.gd")
const ManualProvider = preload("res://scripts/quotes/manual_quote_provider.gd")
const GoldFlow = preload("res://scripts/quotes/personal_gold_flow.gd")

const NOW := "2026-09-27T02:00:00Z"

var checks := 0
var failures: Array[String] = []
var directory := ""


func _initialize() -> void:
	directory = ProjectSettings.globalize_path("res://").get_base_dir().path_join(
		"tests").path_join("data").path_join("tmp")
	DirAccess.make_dir_recursive_absolute(directory)
	var suffix := str(Time.get_ticks_usec())
	_test_multicurrency_pending(directory.path_join("personal-asset-" + suffix))
	_test_initial_structure(directory.path_join("personal-asset-empty-" + suffix))
	_test_demo_rejection(directory.path_join("personal-asset-demo-" + suffix))
	if failures.is_empty():
		print("PERSONAL ASSET FLOW TESTS PASS: %d checks" % checks)
		quit(0)
	else:
		for failure in failures:
			printerr("FAIL: " + failure)
		printerr("PERSONAL ASSET FLOW TESTS FAIL: %d failures in %d checks" % [
			failures.size(), checks])
		quit(1)


func _test_multicurrency_pending(path: String) -> void:
	var opening := PersonalFlow.new(path).create_opening_cash("personal-start",
		"cash-cny", "CNY Cash", "10000", "1000", NOW)
	_check(opening.ok and opening.amount == "10000", "personal starting jar setup")
	if not opening.ok:
		return
	var store := Store.new(path)
	var before: Dictionary = store.load_project()
	var previous_mapping: Dictionary = before.state.mappings.back().duplicate(true)
	var commands := _multicurrency_commands()
	var flow := Flow.new(path)
	var preview := flow.preview(commands, before.generation)
	_check(preview.ok and preview.command_count == 6 and not preview.duplicate
		and preview.cash_balances["usd-bank"] == "400"
		and preview.cash_balances["usd-broker"] == "100"
		and preview.position_quantities["usd-broker|sample-etf"] == "2"
		and preview.missing_valuation_inputs.has("FX:USD")
		and not preview.has("asset_total") and preview.valuation_status == "NEEDS_VALUATION",
		"preview exposes structure and balances without claiming stale total assets")
	if not preview.ok:
		return
	_check(store.load_project().generation == before.generation
		and store.load_project().state.ledger.accounts.size() == 1,
		"preview makes no ledger or generation write")
	var declined := flow.confirm(commands, preview,
		{"confirmed": false, "preview_id": preview.preview_id})
	_check(not declined.ok and declined.error == "EXPLICIT_CONFIRMATION_REQUIRED"
		and store.load_project().generation == before.generation,
		"explicit confirmation is required")
	var altered := commands.duplicate(true)
	altered[3].amount = "600"
	var changed_input := flow.confirm(altered, preview, _confirmation(preview))
	_check(not changed_input.ok and changed_input.error == "PREVIEW_INPUT_CHANGED"
		and store.load_project().generation == before.generation,
		"changed amount cannot reuse previously shown preview")
	var committed := flow.confirm(commands, preview, _confirmation(preview))
	_check(committed.ok and not committed.duplicate
		and committed.generation == before.generation + 1
		and committed.valuation_pending.reason == "ASSET_STRUCTURE_CHANGE",
		"six structure and opening commands save in one generation with pending")
	if not committed.ok:
		return
	var restarted := Store.new(path).load_project()
	var projected := Ledger.project(restarted.state.ledger)
	_check(restarted.ok and restarted.state.ledger.accounts.size() == 3
		and restarted.state.ledger.instruments.size() == 1
		and projected.cash["usd-bank"] == "400"
		and projected.cash["usd-broker"] == "100"
		and projected.positions["usd-broker|sample-etf"].quantity == "2"
		and not projected.positions["usd-broker|sample-etf"].cost_known
		and restarted.state.valuation_pending.ledger_hash == \
		Store.canonical_ledger_hash(restarted.state.ledger),
		"restart restores multiaccount balances, unknown cost and canonical pending hash")
	_check(restarted.state.mappings.back() == previous_mapping
		and restarted.state.inventory.mapping_id == previous_mapping.id,
		"new ledger structure preserves previous complete gold jar")
	var display := Display.build(restarted.state, restarted.generation)
	_check(display.ok and display.snapshot.snapshot_status == "PREVIOUS_COMPLETE"
		and not display.snapshot.has("display_amount"),
		"previous jar is marked pending without exposing old asset amount")
	var replay_preview := Flow.new(path).preview(commands, restarted.generation)
	var replay := Flow.new(path).confirm(commands, replay_preview,
		_confirmation(replay_preview))
	_check(replay_preview.ok and replay_preview.duplicate and replay.ok
		and replay.duplicate and replay.generation == restarted.generation
		and store.load_project().state.ledger.events.size() == 4,
		"same commands replay without another event or generation")
	_test_invalid_atomicity(path, commands)
	_test_complete_valuation_and_gold(path, commands)


func _test_invalid_atomicity(path: String, original_commands: Array) -> void:
	var store := Store.new(path)
	var before: Dictionary = store.load_project()
	var float_batch := [{"command_id": "new-account", "type": "account_create",
		"account": _account("new-account", "New Account", "CNY")},
		{"command_id": "bad-opening", "type": "opening_cash",
		"account_id": "new-account", "amount": 12.5, "effective_at": NOW}]
	var float_preview := Flow.new(path).preview(float_batch, before.generation)
	_check(not float_preview.ok and float_preview.error == "INVALID_OPENING_CASH_INPUT"
		and store.load_project().generation == before.generation
		and not store.load_project().state.ledger.accounts.has("new-account"),
		"float in second command rolls back whole in-memory preview")
	var wrong_currency := [{"command_id": "cross-currency-transfer", "type": "transfer",
		"account_id": "cash-cny", "to_account_id": "usd-bank", "amount": "1",
		"effective_at": NOW}]
	var transfer_preview := Flow.new(path).preview(wrong_currency, before.generation)
	_check(not transfer_preview.ok and transfer_preview.error == "INVALID_TRANSFER"
		and store.load_project().generation == before.generation,
		"cross-currency transfer needs a separate explicit FX business path")
	var conflicting := [original_commands[0].duplicate(true)]
	conflicting[0].account.name = "Different Custodian"
	var conflict_preview := Flow.new(path).preview(conflicting, before.generation)
	_check(not conflict_preview.ok and conflict_preview.error == "IDEMPOTENCY_KEY_CONFLICT",
		"same command ID cannot acquire different account details")
	var mixed := [original_commands[0].duplicate(true),
		{"command_id": "mixed-new", "type": "account_create",
		 "account": _account("mixed-new", "Mixed", "CNY")}]
	var mixed_preview := Flow.new(path).preview(mixed, before.generation)
	_check(not mixed_preview.ok and mixed_preview.error == "MIXED_DUPLICATE_COMMANDS"
		and not store.load_project().state.ledger.accounts.has("mixed-new"),
		"mixed old and new command IDs do not create a partial batch")
	var stale_commands := [{"command_id": "late-account", "type": "account_create",
		"account": _account("late-account", "Late", "CNY")}]
	var stale_preview := Flow.new(path).preview(stale_commands, before.generation)
	var concurrent: Dictionary = before.state.duplicate(true)
	concurrent.presentation.privacy_mode = "hide_total"
	var concurrent_saved := store.save_project(concurrent, before.generation)
	var stale_confirm := Flow.new(path).confirm(stale_commands, stale_preview,
		_confirmation(stale_preview))
	_check(concurrent_saved.ok and not stale_confirm.ok
		and stale_confirm.error == "GENERATION_CONFLICT"
		and not store.load_project().state.ledger.accounts.has("late-account"),
		"generation conflict leaves concurrent project and ledger untouched")
	_check(not Flow.new(path).preview([], concurrent_saved.generation).ok,
		"empty command batch is rejected")


func _test_initial_structure(path: String) -> void:
	var flow := Flow.new(path)
	var commands := [{"command_id": "initial-account", "type": "account_create",
		"account": _account("initial-account", "Initial", "CNY")},
		{"command_id": "initial-cash", "type": "opening_cash",
		"account_id": "initial-account", "amount": "2500", "effective_at": NOW}]
	var preview := flow.preview(commands, 0)
	var restored := Store.new(path).load_project()
	_check(not preview.ok and preview.error == "PERSONAL_PROJECT_NOT_INITIALIZED"
		and restored.ok and restored.generation == 0
		and restored.state.mappings.is_empty() and restored.state.inventory.is_empty()
		and not restored.state.has("valuation_pending"),
		"empty project cannot enter an onboarding dead end before first mapping exists")


func _test_complete_valuation_and_gold(path: String, original_commands: Array) -> void:
	var store := Store.new(path)
	var loaded: Dictionary = store.load_project()
	var etf := _identity("ETF", "NASDAQ", "SAMPLE", "USD")
	var fx := _identity("FX", "FX", "USD/CNY", "CNY")
	var gold := _identity("GOLD", "SPOT", "XAU", "CNY")
	var identities := [etf, fx, gold]
	var prices := {QuoteContract.identity_key(etf): _quote(etf, "100", "etf-100"),
		QuoteContract.identity_key(fx): _quote(fx, "7", "usd-cny-7"),
		QuoteContract.identity_key(gold): _quote(gold, "1000", "gold-1000")}
	var batch := QuoteGateway.refresh(loaded.state.quote_gateway, identities,
		ManualProvider.new(prices), NOW, "asset-flow-valuation-1")
	var incomplete := store.commit_quote_valuation(batch,
		[{"position_id": "usd-broker|sample-etf", "identity": etf, "quantity": "2"}],
		[{"balance_id": "cash-cny", "amount": "10000", "currency": "CNY"},
		 {"balance_id": "usd-bank", "amount": "400", "currency": "USD"}],
		false, loaded.generation)
	_check(not incomplete.ok and incomplete.error == "VALUATION_COVERAGE_MISMATCH"
		and store.load_project().generation == loaded.generation,
		"partial multiaccount cash cannot be mistaken for total assets")
	var valued := store.commit_quote_valuation(batch,
		[{"position_id": "usd-broker|sample-etf", "identity": etf, "quantity": "2"}],
		[{"balance_id": "cash-cny", "amount": "10000", "currency": "CNY"},
		 {"balance_id": "usd-bank", "amount": "400", "currency": "USD"},
		 {"balance_id": "usd-broker", "amount": "100", "currency": "USD"}],
		false, loaded.generation)
	_check(valued.ok and valued.snapshot.asset_total == "14900"
		and not store.load_project().state.valuation_pending.is_empty(),
		"complete market identity and FX batch values all accounts plus ETF")
	if not valued.ok:
		return
	var selection := {"valuation_snapshot_id": str(valued.snapshot.id),
		"gold_batch_id": "asset-flow-valuation-1",
		"gold_quote_key": QuoteContract.identity_key(gold), "gold_fx_key": "",
		"allow_stale": false, "reason": "USER_ASSET_UPDATE"}
	var mapped := GoldFlow.new(path).apply(selection, valued.generation, NOW)
	var restored := Store.new(path).load_project()
	var display := Display.build(restored.state, restored.generation)
	_check(mapped.ok and mapped.mapping.equivalent_grams == "14.9"
		and not restored.state.has("valuation_pending")
		and restored.state.mappings.size() == 2
		and display.ok and display.snapshot.snapshot_status == "CURRENT"
		and not display.snapshot.has("display_amount"),
		"full quote valuation and gold mapping clear pending while privacy stays hidden")
	var replay_preview := Flow.new(path).preview(original_commands, restored.generation)
	var replay := Flow.new(path).confirm(original_commands, replay_preview,
		_confirmation(replay_preview))
	_check(replay_preview.ok and replay_preview.valuation_status == "CURRENT"
		and replay.ok and replay.duplicate and replay.valuation_status == "CURRENT"
		and store.load_project().generation == restored.generation,
		"replaying an old structure command after valuation keeps current status")


func _test_demo_rejection(path: String) -> void:
	var store := Store.new(path)
	var demo := store.new_project()
	demo.data_kind = "demo"
	var saved := store.save_project(demo, 0)
	var denied := Flow.new(path).preview([{"command_id": "demo-account",
		"type": "account_create", "account": _account("demo-account", "Demo", "CNY")}],
		saved.generation)
	_check(saved.ok and not denied.ok and denied.error == "PERSONAL_PROJECT_REQUIRED"
		and store.load_project().state.ledger.accounts.is_empty(),
		"demo data cannot enter the personal asset ledger")


func _multicurrency_commands() -> Array:
	return [
		{"command_id": "reg-usd-bank", "type": "account_create",
			"account": _account("usd-bank", "USD Bank", "USD")},
		{"command_id": "reg-usd-broker", "type": "account_create",
			"account": _account("usd-broker", "USD Broker", "USD")},
		{"command_id": "reg-etf", "type": "instrument_create", "instrument": {
			"id": "sample-etf", "kind": "ETF", "market": "NASDAQ",
			"symbol": "SAMPLE", "currency": "USD", "share_class": ""}},
		{"command_id": "open-usd", "type": "opening_cash", "account_id": "usd-bank",
			"amount": "500", "effective_at": NOW},
		{"command_id": "transfer-usd", "type": "transfer", "account_id": "usd-bank",
			"to_account_id": "usd-broker", "amount": "100", "effective_at": NOW},
		{"command_id": "open-etf", "type": "opening_position",
			"account_id": "usd-broker", "instrument_id": "sample-etf", "quantity": "2",
			"reference_price": "100", "cost_basis": "", "effective_at": NOW},
	]


func _account(id: String, name: String, currency: String) -> Dictionary:
	return {"id": id, "name": name, "currency": currency, "mode": "detail",
		"cost_method": "FIFO", "source_id": "user-source",
		"custodian_id": "local-custodian", "channel_id": "manual"}


func _identity(kind: String, market: String, symbol: String,
		currency: String) -> Dictionary:
	return {"kind": kind, "market": market, "symbol": symbol,
		"currency": currency, "share_class": ""}


func _quote(identity: Dictionary, price: String, id: String) -> Dictionary:
	var unit := "CURRENCY_PER_SHARE"
	if identity.kind == "FX":
		unit = "CURRENCY_PER_FOREIGN_UNIT"
	elif identity.kind == "GOLD":
		unit = "CURRENCY_PER_GRAM"
	return {"id": id, "identity": identity.duplicate(true), "price": price,
		"currency": identity.currency, "unit": unit, "source": "USER_MANUAL",
		"provider_symbol": identity.symbol, "quoted_at": NOW,
		"fetched_at": NOW, "delay": "MANUAL", "session": "MANUAL_INPUT"}


func _confirmation(preview: Dictionary) -> Dictionary:
	return {"confirmed": true, "preview_id": str(preview.get("preview_id", ""))}


func _check(condition: bool, label: String) -> void:
	checks += 1
	if not condition:
		failures.append(label)
