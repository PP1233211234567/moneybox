extends SceneTree

const Drafts = preload("res://scripts/trade/trade_draft_service.gd")
const Ledger = preload("res://scripts/data/ledger_core.gd")

const SAMPLE := "今天在汇丰香港用3001美元买了5股VOO，其中手续费1美元"
const NOW := "2026-09-27T09:00:00Z"
const DATE := "2026-09-27"

var failures: Array[String] = []
var checks := 0


func _initialize() -> void:
	_test_t39()
	_test_t40()
	_test_sell_and_review()
	if checks < 25:
		failures.append("test runner stopped before expected checks")
	if failures.is_empty():
		print("TRADE TESTS PASS: %d checks" % checks)
		quit(0)
	else:
		for failure in failures:
			printerr("FAIL: " + failure)
		printerr("TRADE TESTS FAIL: %d failures in %d checks" % [failures.size(), checks])
		quit(1)


func _state() -> Dictionary:
	var state := Ledger.new_state("USD")
	for command in [
		{"command_id": "account-hsbc", "type": "account_create",
			"account": {"id": "hsbc-hk-usd", "currency": "USD", "mode": "detail", "cost_method": "FIFO"}},
		{"command_id": "instrument-voo", "type": "instrument_create",
			"instrument": {"id": "voo-arca-usd", "symbol": "VOO", "market": "ARCA", "currency": "USD"}},
		{"command_id": "opening-hsbc", "type": "opening_cash", "account_id": "hsbc-hk-usd",
			"amount": "10000", "effective_at": "2026-09-01T00:00:00Z"},
	]:
		var result := Ledger.apply(state, command)
		if not result.ok:
			failures.append("test setup: " + str(result.error))
			return state
		state = result.state
	return state


func _candidates() -> Dictionary:
	return {"accounts": [{"id": "hsbc-hk-usd", "aliases": ["汇丰香港"]}],
		"instruments": [{"id": "voo-arca-usd", "symbol": "VOO", "market": "ARCA",
			"currency": "USD", "aliases": ["VOO"]}]}


func _draft(text: String, draft_id: String = "draft-1", candidates: Dictionary = {}) -> Dictionary:
	return Drafts.parse_local(text, "local-text-1", draft_id, NOW, DATE,
		_candidates_or_default(candidates))


func _candidates_or_default(candidates: Dictionary) -> Dictionary:
	return _candidates() if candidates.is_empty() else candidates


func _confirmation(draft: Dictionary, key: String = "trade-1") -> Dictionary:
	return {"confirmed": true, "draft_id": draft.id, "draft_revision": draft.revision,
		"idempotency_key": key, "tax_amount": "0"}


func _test_t39() -> void:
	var state := _state()
	var original_events: int = state.events.size()
	var draft := _draft(SAMPLE)
	_check(draft.status == "pending" and draft.schema_version == 1, "T39 versioned pending draft")
	_check(draft.fields.account_id.value == "hsbc-hk-usd" and draft.fields.instrument_id.value == "voo-arca-usd",
		"T39 identity uses supplied candidate IDs")
	_check(draft.fields.trade_date.value == DATE and draft.fields.trade_date.source_span == "今天",
		"T39 today resolved against supplied local date")
	_check(draft.fields.quantity.value == "5" and draft.fields.total_amount.value == "3001"
		and draft.fields.fee.value == "1" and not draft.fields.has("unit_price"),
		"T39 source values retained; no price fabricated in draft")
	_check(state.events.size() == original_events, "T39 parsing does not mutate ledger")
	var preview_without_tax := Drafts.validate(draft, state, _candidates())
	_check(not preview_without_tax.ok and preview_without_tax.missing_fields.has("tax_amount"),
		"T39 missing tax status is explicit")
	var missing_review := Drafts.confirm(state, draft, _candidates(),
		{"confirmed": true, "draft_id": draft.id, "draft_revision": draft.revision,
			"idempotency_key": "trade-1"})
	_check(not missing_review.ok and missing_review.error == "EXPLICIT_TAX_REVIEW_REQUIRED"
		and state.events.size() == original_events, "T39 no implicit zero tax or ledger mutation")
	var rejected := Drafts.confirm(state, draft, _candidates(),
		{"confirmed": false, "draft_id": draft.id, "draft_revision": draft.revision,
			"idempotency_key": "trade-1", "tax_amount": "0"})
	_check(not rejected.ok and rejected.error == "EXPLICIT_CONFIRMATION_REQUIRED",
		"T39 explicit confirmation gate")
	var checked := Drafts.validate(draft, state, _candidates(), "0")
	_check(checked.ok and checked.preview.unit_price == "600" and checked.preview.cash_delta == "-3001"
		and checked.preview.quantity_delta == "5", "T39 deterministic 3001 = 5 x 600 + 1 preview")
	var confirmed := Drafts.confirm(state, draft, _candidates(), _confirmation(draft))
	_check(confirmed.ok and not confirmed.duplicate, "T39 one confirmed LedgerCore command")
	if not confirmed.ok:
		return
	_check(confirmed.draft.fields.tax_amount.value == "0"
		and not confirmed.draft.missing_fields.has("tax_amount"),
		"T39 confirmed draft records explicit zero tax review")
	_check(state.events.size() == original_events and confirmed.state.events.size() == original_events + 1,
		"T39 input state unchanged; returned state has one trade")
	_check(confirmed.state.events.back().id == "trade-1" and confirmed.state.events.back().effective_at == "2026-09-26T16:00:00Z",
		"T39 stable command ID and UTC date")
	_check(confirmed.projection.cash["hsbc-hk-usd"] == "6999"
		and confirmed.projection.positions["hsbc-hk-usd|voo-arca-usd"].quantity == "5"
		and confirmed.projection.positions["hsbc-hk-usd|voo-arca-usd"].cost == "3001",
		"T39 cash, position and cost follow ledger math")
	var replay_state: Dictionary = confirmed.state
	for index in 100:
		var replay := Drafts.confirm(replay_state, confirmed.draft, _candidates(), _confirmation(confirmed.draft))
		if not replay.ok or not replay.duplicate:
			failures.append("T41 confirmed trade replay failed at " + str(index))
			break
		replay_state = replay.state
	_check(replay_state.events.size() == original_events + 1, "T41 100 retries leave one trade event")
	var altered := _draft(SAMPLE, "draft-2")
	var different_key := Drafts.confirm(replay_state, altered, _candidates(), _confirmation(altered, "trade-2"))
	_check(not different_key.ok and different_key.validation.conflicts.has("POSSIBLE_DUPLICATE_TRADE"),
		"T39 same trade with a new key needs duplicate review")


func _test_t40() -> void:
	var state := _state()
	var future_state := Ledger.new_state("USD")
	for command in [
		{"command_id": "future-account", "type": "account_create",
			"account": {"id": "hsbc-hk-usd", "currency": "USD", "mode": "detail",
				"cost_method": "FIFO"}},
		{"command_id": "future-instrument", "type": "instrument_create",
			"instrument": {"id": "voo-arca-usd", "symbol": "VOO", "market": "ARCA",
				"currency": "USD"}},
		{"command_id": "future-cash", "type": "opening_cash", "account_id": "hsbc-hk-usd",
			"amount": "10000", "effective_at": "2026-10-01T00:00:00Z"},
	]:
		var built: Dictionary = Ledger.apply(future_state, command)
		if not built.ok:
			failures.append("future cash setup: " + str(built.error))
			break
		future_state = built.state
	var future_event_count: int = future_state.events.size()
	var historical: Dictionary = Drafts.validate(_draft(SAMPLE), future_state, _candidates(), "0")
	_check(not historical.ok and historical.conflicts.has("INSUFFICIENT_CASH")
		and future_state.events.size() == future_event_count,
		"T40 future cash cannot fund an earlier trade; dry-run never mutates ledger")
	var no_account := _draft("今天用3001美元买了5股VOO，其中手续费1美元")
	var account_result := Drafts.validate(no_account, state, _candidates(), "0")
	_check(not account_result.ok and account_result.missing_fields.has("account_id"),
		"T40 missing account is requested")
	var no_date := _draft("在汇丰香港用3001美元买了5股VOO，其中手续费1美元")
	var date_result := Drafts.validate(no_date, state, _candidates(), "0")
	_check(not date_result.ok and date_result.missing_fields.has("trade_date"),
		"T40 missing date is requested")
	var conflicting_quantity := _draft("今天在汇丰香港用3001美元买了5股VOO，又买了6股VOO，其中手续费1美元")
	var quantity_result := Drafts.validate(conflicting_quantity, state, _candidates(), "0")
	_check(not quantity_result.ok and quantity_result.conflicts.has("CONFLICTING_QUANTITY"),
		"T40 conflicting quantity is not guessed")
	var conflicting_currency := _draft("今天在汇丰香港用3001美元买了5股VOO，其中手续费1元")
	var currency_result := Drafts.validate(conflicting_currency, state, _candidates(), "0")
	_check(not currency_result.ok and currency_result.conflicts.has("CONFLICTING_CURRENCY"),
		"T40 conflicting currencies are surfaced")
	var candidate_set := _candidates()
	candidate_set.instruments.append({"id": "voo-other-market", "symbol": "VOO", "aliases": ["VOO"]})
	var ambiguous := _draft(SAMPLE, "draft-ambiguous", candidate_set)
	var ambiguous_result := Drafts.validate(ambiguous, state, candidate_set, "0")
	_check(not ambiguous_result.ok and ambiguous_result.conflicts.has("AMBIGUOUS_INSTRUMENT"),
		"T40 ticker alone cannot choose among instrument identities")
	var chosen := Drafts.revise(ambiguous, {"instrument_id": "voo-arca-usd"})
	_check(chosen.ok and Drafts.validate(chosen.draft, state, candidate_set, "0").ok,
		"T40 user may explicitly choose a candidate instrument ID")
	var tampered := _draft(SAMPLE, "draft-tampered")
	tampered.fields.account_id.value = "unoffered-account"
	var tampered_result := Drafts.validate(tampered, state, _candidates(), "0")
	_check(not tampered_result.ok and tampered_result.conflicts.has("UNKNOWN_OR_UNMATCHED_ACCOUNT"),
		"T40 validator rejects unoffered account ID")
	var unverified := _draft(SAMPLE, "draft-unverified")
	unverified.fields.instrument_id.source_span = "OTHER"
	_check(Drafts.validate(unverified, state, _candidates(), "0").conflicts.has("UNVERIFIED_INSTRUMENT_IDENTITY"),
		"T40 parsed candidate identity must match its source span")
	var mismatched_candidate := _candidates()
	mismatched_candidate.instruments[0].currency = "HKD"
	_check(Drafts.validate(_draft(SAMPLE), state, mismatched_candidate, "0").conflicts.has("INSTRUMENT_CANDIDATE_MISMATCH"),
		"T40 candidate metadata must match ledger instrument")
	var no_fee := _draft("今天在汇丰香港用3001美元买了5股VOO")
	_check(Drafts.validate(no_fee, state, _candidates(), "0").missing_fields.has("fee"),
		"T40 fee is not fabricated")
	var only_quantity_fix := Drafts.revise(conflicting_quantity, {"fee": "1"})
	_check(Drafts.validate(only_quantity_fix.draft, state, _candidates(), "0").conflicts.has("CONFLICTING_QUANTITY"),
		"T40 unrelated edit cannot dismiss quantity conflict")
	var quantity_fix := Drafts.revise(conflicting_quantity, {"quantity": "5"})
	_check(Drafts.validate(quantity_fix.draft, state, _candidates(), "0").ok,
		"T40 explicit quantity edit resolves its conflict")
	var settlement := _draft(SAMPLE + "，结算日期2026-09-29", "draft-settlement")
	_check(settlement.fields.trade_date.value == DATE and settlement.fields.settlement_date.value == "2026-09-29"
		and Drafts.validate(settlement, state, _candidates(), "0").ok,
		"T40 settlement date is distinct from trade date")
	var impossible := Drafts.revise(_draft(SAMPLE), {"trade_date": "2026-02-30"})
	_check(Drafts.validate(impossible.draft, state, _candidates(), "0").conflicts.has("INVALID_TRADE_DATE"),
		"T40 impossible calendar date rejected")
	var non_exact := _draft("今天在汇丰香港用1美元买了3股VOO，其中手续费0美元", "draft-repeating")
	_check(Drafts.validate(non_exact, state, _candidates(), "0").conflicts.has("NON_EXACT_UNIT_PRICE"),
		"T40 unit price is never silently rounded to balance trade")
	var wrong_flow := _draft("今天在汇丰香港收到3001美元买了5股VOO，其中手续费1美元", "draft-flow")
	_check(Drafts.validate(wrong_flow, state, _candidates(), "0").conflicts.has("AMOUNT_DIRECTION_MISMATCH"),
		"T40 cash direction must agree with buy or sell")
	var unexpected := _draft(SAMPLE, "draft-extra")
	unexpected.fields["secret_amount"] = {"value": "1", "source_span": "", "confidence": 1.0, "origin": "remote_ai"}
	_check(Drafts.validate(unexpected, state, _candidates(), "0").error == "INVALID_DRAFT_SCHEMA",
		"unknown remote field rejected by runtime shape check")
	var oversized := _draft("买".repeat(501), "draft-long")
	_check(Drafts.validate(oversized, state, _candidates(), "0").conflicts.has("INPUT_TOO_LONG"),
		"local parser bounds input length")
	_check(state.events.size() == 1, "T40 failed drafts do not mutate ledger")


func _test_sell_and_review() -> void:
	var state := _state()
	var draft := _draft(SAMPLE)
	var old_confirmation := _confirmation(draft)
	var revision := Drafts.revise(draft, {"trade_date": DATE})
	_check(revision.ok and revision.draft.revision == 2, "editing creates a new draft revision")
	var stale := Drafts.confirm(state, revision.draft, _candidates(), old_confirmation)
	_check(not stale.ok and stale.error == "STALE_OR_INVALID_DRAFT", "old confirmation rejected after edit")
	var mismatch_revision := Drafts.revise(draft, {"unit_price": "601"})
	var mismatch := Drafts.validate(mismatch_revision.draft, state, _candidates(), "0")
	_check(not mismatch.ok and mismatch.conflicts.has("AMOUNT_EQUATION_MISMATCH"),
		"explicit unit price must satisfy cash equation")
	var taxed := _draft(SAMPLE + "，税款1美元", "draft-taxed")
	var tax_result := Drafts.validate(taxed, state, _candidates(), "1")
	_check(not tax_result.ok and tax_result.conflicts.has("UNSUPPORTED_TAX_LEDGER"),
		"nonzero tax blocked until LedgerCore supports it")
	var bought := Drafts.confirm(state, draft, _candidates(), _confirmation(draft))
	if not bought.ok:
		failures.append("sell setup buy failed")
		return
	var sell := _draft("今天在汇丰香港卖了5股VOO，收到2999美元，其中手续费1美元", "draft-sell")
	var sell_preview := Drafts.validate(sell, bought.state, _candidates(), "0")
	_check(sell_preview.ok and sell_preview.preview.unit_price == "600"
		and sell_preview.preview.cash_delta == "2999", "sell proceeds and fee equation")
	var sold := Drafts.confirm(bought.state, sell, _candidates(), _confirmation(sell, "trade-sell"))
	_check(sold.ok and sold.projection.cash["hsbc-hk-usd"] == "9998"
		and sold.projection.positions["hsbc-hk-usd|voo-arca-usd"].quantity == "0",
		"sell confirmation changes ledger only after review")


func _check(condition: bool, label: String) -> void:
	checks += 1
	if not condition:
		failures.append(label)
