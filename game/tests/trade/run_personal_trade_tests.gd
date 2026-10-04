extends SceneTree

const PersonalFlow = preload("res://scripts/data/personal_flow.gd")
const TradeFlow = preload("res://scripts/trade/personal_trade_flow.gd")
const DemoFlow = preload("res://scripts/data/demo_flow.gd")
const Store = preload("res://scripts/data/project_store.gd")
const Ledger = preload("res://scripts/data/ledger_core.gd")
const Mapping = preload("res://scripts/domain/gold_mapping_service.gd")
const Inventory = preload("res://scripts/domain/jar_inventory.gd")

const SAMPLE := "今天在汇丰香港用3001美元买了5股VOO，其中手续费1美元"
const NOW := "2026-09-27T09:00:00Z"
const TODAY := "2026-09-27"

var failures: Array[String] = []
var checks := 0


func _initialize() -> void:
	var directory := ProjectSettings.globalize_path("res://tests/trade/tmp")
	DirAccess.make_dir_recursive_absolute(directory)
	var base := directory.path_join("personal-trade-" + str(Time.get_ticks_usec()))
	var seed := _seed_personal(base)
	if seed.ok:
		_test_persistence_and_confirmation(base, seed.generation)
	_test_demo_rejection(directory.path_join("demo-trade-" + str(Time.get_ticks_usec())))
	if checks < 15:
		failures.append("test runner stopped before expected checks")
	if failures.is_empty():
		print("PERSONAL TRADE TESTS PASS: %d checks" % checks)
		quit(0)
	else:
		for failure in failures:
			printerr("FAIL: " + failure)
		printerr("PERSONAL TRADE TESTS FAIL: %d failures in %d checks" % [failures.size(), checks])
		quit(1)


func _seed_personal(base: String) -> Dictionary:
	var created: Dictionary = PersonalFlow.new(base).create_opening_cash(
		"seed-open", "cash-cny", "中国现金", "50000", "1000", "2026-09-01T00:00:00Z")
	_check(created.ok and created.amount == "50000", "seed personal cash and mapping")
	if not created.ok:
		return {"ok": false}
	var store := Store.new(base)
	var loaded: Dictionary = store.load_project()
	if not loaded.ok:
		failures.append("seed project load failed")
		return {"ok": false}
	var project: Dictionary = loaded.state
	for command in [
		{"command_id": "seed-hsbc-account", "type": "account_create",
			"account": {"id": "hsbc-usd", "name": "汇丰香港", "currency": "USD", "mode": "detail", "cost_method": "FIFO"}},
		{"command_id": "seed-usd-opening", "type": "opening_cash", "account_id": "hsbc-usd",
			"amount": "10000", "effective_at": "2026-09-01T00:00:00Z"},
		{"command_id": "seed-voo-instrument", "type": "instrument_create",
			"instrument": {"id": "voo-arca", "symbol": "VOO", "market": "ARCA", "currency": "USD"}},
		{"command_id": "seed-usd-fx", "type": "fx_update",
			"fx": {"currency": "USD", "rate_to_base": "7", "quoted_at": NOW, "source": "TEST_MANUAL"}},
		{"command_id": "seed-voo-quote", "type": "quote_update",
			"quote": {"instrument_id": "voo-arca", "price": "600", "quoted_at": NOW, "source": "TEST_MANUAL"}},
	]:
		var applied: Dictionary = Ledger.apply(project.ledger, command)
		if not applied.ok:
			failures.append("seed ledger command failed: " + str(applied.error))
			return {"ok": false}
		project.ledger = applied.state
	var projection: Dictionary = Ledger.project(project.ledger)
	_check(projection.ok and projection.asset_total == "120000", "seed ledger projection 50000 CNY plus 10000 USD x 7")
	var previous: Dictionary = project.mappings.back()
	var mapped: Dictionary = Mapping.create_revision("seed-complete-assets", projection.asset_total,
		"CNY", project.manual_gold_quote, {}, "total_assets", previous, "USER_ASSET_UPDATE")
	if not mapped.ok:
		failures.append("seed mapping failed: " + str(mapped.error))
		return {"ok": false}
	var inventoried: Dictionary = Inventory.apply_mapping(project.inventory, mapped.revision,
		"seed-complete-inventory")
	if not inventoried.ok:
		failures.append("seed inventory failed: " + str(inventoried.error))
		return {"ok": false}
	project.mappings.append(mapped.revision)
	project.inventory = inventoried.state
	var saved: Dictionary = store.save_project(project, int(loaded.generation))
	_check(saved.ok, "seed full personal state saved")
	return {"ok": saved.ok, "generation": saved.get("generation", 0)}


func _test_persistence_and_confirmation(base: String, generation: int) -> void:
	var flow := TradeFlow.new(base)
	var candidates: Dictionary = flow.list_candidates()
	_check(candidates.ok and candidates.candidates.accounts.size() == 2
		and candidates.candidates.instruments[0].id == "voo-arca", "candidate IDs derive from local ledger")
	var original: Dictionary = Store.new(base).load_project()
	var original_events: int = original.state.ledger.events.size()
	var drafted: Dictionary = flow.create_draft(SAMPLE, "local-input-1", "draft-1", NOW, TODAY, generation)
	_check(drafted.ok and drafted.draft.status == "pending"
		and drafted.validation.missing_fields.has("tax_amount"), "draft persisted as pending with missing tax review")
	if not drafted.ok:
		return
	_check(Store.new(base).load_project().state.ledger.events.size() == original_events,
		"draft save does not write ledger")
	var reopened: Dictionary = TradeFlow.new(base).load_draft("draft-1", "0")
	_check(reopened.ok and reopened.draft.fields.account_id.value == "hsbc-usd"
		and reopened.draft.fields.instrument_id.value == "voo-arca"
		and reopened.validation.ok and reopened.validation.preview.unit_price == "600",
		"restart restores structured draft and deterministic preview")
	var same_draft: Dictionary = TradeFlow.new(base).create_draft(SAMPLE, "local-input-1", "draft-1", NOW,
		TODAY, drafted.generation)
	_check(same_draft.ok and same_draft.duplicate and same_draft.generation == drafted.generation,
		"same draft request is idempotent without saving again")
	var reused_id: Dictionary = flow.create_draft(SAMPLE + "。", "local-input-1", "draft-1", NOW,
		TODAY, drafted.generation)
	_check(not reused_id.ok and reused_id.error == "DRAFT_ID_CONFLICT", "draft ID cannot hide changed source")
	var confirmation := {"confirmed": true, "draft_id": "draft-1", "draft_revision": 1,
		"idempotency_key": "confirmed-trade-1", "tax_amount": "0"}
	var taxed: Dictionary = TradeFlow.new(base).confirm_trade({"confirmed": true, "draft_id": "draft-1",
		"draft_revision": 1, "idempotency_key": "taxed-trade-1", "tax_amount": "1"}, drafted.generation)
	_check(not taxed.ok and taxed.get("validation", {}).get("conflicts", []).has("UNSUPPORTED_TAX_LEDGER"),
		"nonzero tax cannot reach LedgerCore")
	var no_consent: Dictionary = flow.confirm_trade({"confirmed": false, "draft_id": "draft-1",
		"draft_revision": 1, "idempotency_key": "confirmed-trade-1", "tax_amount": "0"}, drafted.generation)
	_check(not no_consent.ok and Store.new(base).load_project().state.ledger.events.size() == original_events,
		"explicit user confirmation is required")
	var committed: Dictionary = flow.confirm_trade(confirmation, drafted.generation)
	_check(committed.ok and not committed.duplicate and not committed.display_ready
		and not committed.has("amount") and not committed.has("view"),
		"confirmation returns no stale amount or bean view")
	if not committed.ok:
		return
	var stored: Dictionary = Store.new(base).load_project()
	var ledger: Dictionary = stored.state.ledger
	var projection: Dictionary = Ledger.project(ledger)
	_check(stored.generation == committed.generation and ledger.events.size() == original_events + 1,
		"one ProjectStore generation contains one new ledger event")
	_check(projection.cash["hsbc-usd"] == "6999"
		and projection.positions["hsbc-usd|voo-arca"].quantity == "5"
		and projection.positions["hsbc-usd|voo-arca"].cost == "3001"
		and projection.asset_total == "119993", "confirmed cash, holding, cost and total reconcile")
	_check(stored.state.mappings.back().amount == "120000"
		and stored.state.inventory.mapping_id == stored.state.mappings.back().id
		and stored.state.valuation_pending.reason == "TRADE_CONFIRM"
		and stored.state.valuation_pending.ledger_hash == Store.canonical_ledger_hash(ledger),
		"old mapping remains a prior snapshot and pending marker binds the new ledger")
	_check(stored.state.trade_drafts["draft-1"].status == "confirmed"
		and stored.state.trade_confirmations["confirmed-trade-1"].committed_generation == committed.generation,
		"confirmed draft and idempotency record survive restart")
	var replay_generation: int = int(stored.generation)
	for index in 100:
		var retry: Dictionary = TradeFlow.new(base).confirm_trade(confirmation, drafted.generation)
		if not retry.ok or not retry.duplicate or retry.committed_generation != committed.generation:
			failures.append("double-click retry failed at " + str(index))
			break
	_check(Store.new(base).load_project().generation == replay_generation
		and Store.new(base).load_project().state.ledger.events.size() == original_events + 1,
		"100 retries after restart write no new generation or event")
	var second_key: Dictionary = flow.confirm_trade({"confirmed": true, "draft_id": "draft-1",
		"draft_revision": 1, "idempotency_key": "another-key", "tax_amount": "0"}, replay_generation)
	_check(not second_key.ok and second_key.error == "ALREADY_CONFIRMED", "confirmed draft cannot use a new key")
	var stale_draft: Dictionary = flow.create_draft("今天在汇丰香港用601美元买了1股VOO，其中手续费1美元",
		"local-input-2", "draft-2", NOW, TODAY, drafted.generation)
	_check(not stale_draft.ok and stale_draft.error == "GENERATION_CONFLICT", "new draft rejects stale generation")
	var missing_account: Dictionary = flow.create_draft("今天用601美元买了1股VOO，其中手续费1美元",
		"local-input-3", "draft-missing", NOW, TODAY, replay_generation)
	_check(missing_account.ok and missing_account.validation.missing_fields.has("account_id"),
		"missing account persists as a request for user choice")
	var missing_confirm: Dictionary = TradeFlow.new(base).confirm_trade({"confirmed": true,
		"draft_id": "draft-missing", "draft_revision": 1,
		"idempotency_key": "missing-account-key", "tax_amount": "0"}, missing_account.generation)
	_check(not missing_confirm.ok and missing_confirm.validation.missing_fields.has("account_id")
		and Store.new(base).load_project().state.ledger.events.size() == original_events + 1,
		"missing account cannot enter ledger")
	var edited: Dictionary = flow.revise_draft("draft-missing", {"fee": "1"},
		int(missing_account.generation))
	_check(edited.ok and edited.draft.revision == 2
		and TradeFlow.new(base).load_draft("draft-missing").draft.revision == 2,
		"draft edit revision survives restart")
	var stale_confirmation: Dictionary = flow.confirm_trade({"confirmed": true,
		"draft_id": "draft-missing", "draft_revision": 2,
		"idempotency_key": "stale-confirm-key", "tax_amount": "0"},
		int(missing_account.generation))
	_check(not stale_confirmation.ok and stale_confirmation.error == "GENERATION_CONFLICT",
		"new confirmation rejects stale project generation")


func _test_demo_rejection(base: String) -> void:
	var demo: Dictionary = DemoFlow.new(base).load_or_create()
	_check(demo.ok, "demo fixture saved")
	var personal := TradeFlow.new(base)
	var candidates: Dictionary = personal.list_candidates()
	_check(not candidates.ok and candidates.error == "NOT_PERSONAL_DATA", "demo candidates rejected")
	var draft: Dictionary = personal.create_draft(SAMPLE, "local-demo", "demo-draft", NOW, TODAY,
		int(demo.generation))
	_check(not draft.ok and draft.error == "NOT_PERSONAL_DATA", "demo draft save rejected")
	var confirmed: Dictionary = personal.confirm_trade({"confirmed": true,
		"draft_id": "demo-draft", "draft_revision": 1,
		"idempotency_key": "demo-confirm", "tax_amount": "0"}, int(demo.generation))
	_check(not confirmed.ok and confirmed.error == "NOT_PERSONAL_DATA", "demo confirmation rejected")


func _check(condition: bool, label: String) -> void:
	checks += 1
	if not condition:
		failures.append(label)
