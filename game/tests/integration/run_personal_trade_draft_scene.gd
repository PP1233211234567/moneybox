extends SceneTree

const Scene = preload("res://scenes/personal_trade_draft.tscn")
const Store = preload("res://scripts/data/project_store.gd")
const PersonalFlow = preload("res://scripts/data/personal_flow.gd")
const Ledger = preload("res://scripts/data/ledger_core.gd")

const SAMPLE := "今天在汇丰香港用3001美元买了5股VOO，其中手续费1美元"
const MISSING_ACCOUNT := "今天用3001美元买了5股VOO，其中手续费1美元"
const OPENED_AT := "2020-01-01T00:00:00Z"

var checks := 0
var failures: Array[String] = []
var now_at := ""


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	now_at = Time.get_datetime_string_from_unix_time(int(Time.get_unix_time_from_system())) + "Z"
	var directory := ProjectSettings.globalize_path("res://tests/tmp")
	DirAccess.make_dir_recursive_absolute(directory)
	var prefix := directory.path_join("personal-trade-scene-" + str(Time.get_ticks_usec()))
	await _test_guards(prefix + "-empty", prefix + "-demo")
	await _test_trade_path(prefix + "-normal", false)
	await _test_trade_path(prefix + "-private", true)
	_check(checks >= 23, "all scene interaction checks reached")
	if failures.is_empty():
		print("PERSONAL TRADE DRAFT SCENE PASS: %d checks" % checks)
		quit(0)
	else:
		for failure in failures:
			printerr("FAIL: " + failure)
		printerr("PERSONAL TRADE DRAFT SCENE FAIL: %d failures in %d checks" % [
			failures.size(), checks])
		quit(1)


func _test_guards(empty_path: String, demo_path: String) -> void:
	var empty := await _mount(empty_path)
	_check(empty.get_create_button().disabled and empty.get_preview_button().disabled
		and empty.get_confirm_button().disabled and empty.get_status_text().contains("现金开户"),
		"uninitialized personal project cannot save trade draft")
	empty.queue_free()
	await process_frame
	var store := Store.new(demo_path)
	var demo := store.new_project()
	demo.data_kind = "demo"
	_check(store.save_project(demo, 0).ok, "demo fixture saved")
	var panel := await _mount(demo_path)
	_check(panel.get_create_button().disabled and panel.get_status_text().contains("演示项目")
		and panel.get_return_button().visible,
		"demo project cannot use personal trade entry")
	panel.queue_free()
	await process_frame


func _test_trade_path(path: String, private: bool) -> void:
	var label := "private" if private else "normal"
	var seeded := _create_fixture(path)
	_check(seeded.ok, label + " personal account and instrument fixture saved")
	if not seeded.ok:
		return
	var store := Store.new(path)
	if private:
		var privacy: Dictionary = store.load_project()
		privacy.state.presentation.privacy_mode = "hide_total"
		_check(store.save_project(privacy.state, int(privacy.generation)).ok,
			"privacy setting saved")
	var before: Dictionary = store.load_project()
	var original_events: int = before.state.ledger.events.size()
	var panel := await _mount(path)
	_check(panel.get_return_button().visible and not panel.get_create_button().disabled,
		label + " trade page opens and return route is visible")
	_check(panel.get_picker("account_id").item_count == 3
		and panel.get_picker("instrument_id").item_count == 2,
		label + " only ledger account and instrument candidates are offered")
	panel.get_source_input().text = MISSING_ACCOUNT
	panel.get_create_button().pressed.emit()
	var missing_draft_id: String = panel.get_active_draft_id()
	var drafted: Dictionary = store.load_project()
	_check(not missing_draft_id.is_empty() and drafted.state.ledger.events.size() == original_events
		and drafted.generation == before.generation + 1
		and not JSON.stringify(drafted.state).contains(MISSING_ACCOUNT),
		label + " source text is not stored and creating structured draft leaves ledger unchanged")
	_check(panel.get_source_input().text.is_empty() and panel.get_confirm_button().disabled,
		label + " raw input cleared and no automatic confirmation")
	panel.queue_free()
	await process_frame
	panel = await _mount(path)
	_check(panel.get_resume_picker().item_count == 1 and panel.get_resume_button().disabled == false
		and panel.get_source_input().text.is_empty(),
		label + " restart offers only the pending structured draft and no raw text")
	panel.get_resume_button().pressed.emit()
	_check(panel.get_active_draft_id() == missing_draft_id
		and panel.get_field("total_amount").text == "3001"
		and panel.get_confirm_button().disabled
		and store.load_project().state.ledger.events.size() == original_events,
		label + " resumed fields require a fresh preview and do not write ledger")
	panel.get_field("tax_amount").text = "0"
	panel.get_preview_button().pressed.emit()
	_check(panel.get_confirm_button().disabled and panel.get_preview_text().contains("account_id")
		and store.load_project().state.ledger.events.size() == original_events,
		label + " missing account blocks preview without ledger write")
	_select_id(panel.get_picker("account_id"), "hsbc-usd")
	panel.get_field("tax_amount").text = "1"
	panel.get_preview_button().pressed.emit()
	_check(panel.get_confirm_button().disabled and panel.get_preview_text().contains("UNSUPPORTED_TAX_LEDGER")
		and store.load_project().state.ledger.events.size() == original_events,
		label + " nonzero tax blocks confirmation without ledger write")
	panel.get_field("tax_amount").text = "0"
	var actual_date: String = panel.get_field("trade_date").text
	panel.get_field("trade_date").text = "2019-01-01"
	panel.get_preview_button().pressed.emit()
	_check(panel.get_confirm_button().disabled and panel.get_preview_text().contains("INSUFFICIENT_CASH")
		and store.load_project().state.ledger.events.size() == original_events,
		label + " historical cash dry-run blocks an unfunded earlier trade without a write")
	panel.get_field("trade_date").text = actual_date
	panel.get_preview_button().pressed.emit()
	var preview_text: String = panel.get_preview_text()
	var after_preview: Dictionary = store.load_project()
	_check(not panel.get_confirm_button().disabled and after_preview.state.ledger.events.size() == original_events
		and after_preview.state.trade_drafts[missing_draft_id].status == "pending",
		label + " verified preview saves only draft revisions, never ledger")
	_check(preview_text.contains("hsbc-usd") and preview_text.contains("voo-arca")
		and preview_text.contains("数量 5") and preview_text.contains("等待重估"),
		label + " preview shows explicit candidate identities, quantity and pending outcome")
	if private:
		_check(panel.get_source_input().secret and panel.get_field("total_amount").secret
			and panel.get_field("unit_price").secret and panel.get_field("fee").secret
			and panel.get_field("tax_amount").secret
			and preview_text.contains("隐私模式") and not preview_text.contains("3001")
			and not preview_text.contains("600") and not preview_text.contains("现金总额"),
			"private form masks money and preview exposes no monetary values")
	else:
		_check(preview_text.contains("现金总额 3001 USD")
			and preview_text.contains("单价 600 USD") and preview_text.contains("手续费 1"),
			"normal preview explains exact price derived from entered total and fee")
	var navigation := {"requested": false}
	panel.return_to_jar_requested.connect(func() -> void: navigation.requested = true)
	panel.get_confirm_button().pressed.emit()
	var saved: Dictionary = store.load_project()
	var projection: Dictionary = Ledger.project(saved.state.ledger)
	_check(saved.generation == after_preview.generation + 1
		and saved.state.ledger.events.size() == original_events + 1
		and saved.state.trade_drafts[missing_draft_id].status == "confirmed",
		label + " explicit confirm atomically saves one ledger event in one generation")
	_check(projection.ok and projection.cash["hsbc-usd"] == "6999"
		and projection.positions["hsbc-usd|voo-arca"].quantity == "5"
		and projection.positions["hsbc-usd|voo-arca"].cost == "3001",
		label + " exact cash, quantity and cost reconcile after trade")
	_check(saved.state.valuation_pending.reason == "TRADE_CONFIRM"
		and saved.state.valuation_pending.ledger_hash == Store.canonical_ledger_hash(saved.state.ledger)
		and panel.get_preview_text().contains("上次完整快照"),
		label + " new ledger and pending hash share one save; old beans labelled prior snapshot")
	if private:
		_check(not panel.get_preview_text().contains("3001") and not panel.get_status_text().contains("3001"),
			"private success never renders monetary value")
	panel.get_confirm_button().pressed.emit()
	_check(store.load_project().generation == saved.generation and
		store.load_project().state.ledger.events.size() == original_events + 1,
		label + " double confirmation cannot write again")
	panel.get_return_button().pressed.emit()
	_check(navigation.requested, label + " return to personal jar signal works")
	panel.queue_free()
	await process_frame
	var restarted := await _mount(path)
	_check(restarted.get_resume_picker().item_count == 0
		and restarted.get_confirm_button().disabled
		and restarted.get_status_text().contains("等待重估")
		and Store.new(path).load_project().generation == saved.generation,
		label + " restart preserves confirmed draft and pending valuation")
	restarted.queue_free()
	await process_frame


func _create_fixture(path: String) -> Dictionary:
	var created: Dictionary = PersonalFlow.new(path).create_opening_cash(
		"seed-open", "cash-cny", "人民币现金", "50000", "1000", OPENED_AT)
	if not created.ok:
		return created
	var store := Store.new(path)
	var loaded: Dictionary = store.load_project()
	var project: Dictionary = loaded.state
	for command in [
		{"command_id": "seed-hsbc-account", "type": "account_create", "account": {
			"id": "hsbc-usd", "name": "汇丰香港", "currency": "USD", "mode": "detail",
			"cost_method": "FIFO"}},
		{"command_id": "seed-usd-opening", "type": "opening_cash", "account_id": "hsbc-usd",
			"amount": "10000", "effective_at": OPENED_AT},
		{"command_id": "seed-voo-instrument", "type": "instrument_create",
			"instrument": {"id": "voo-arca", "kind": "ETF", "symbol": "VOO",
				"market": "ARCA", "currency": "USD", "share_class": ""}},
	]:
		var applied: Dictionary = Ledger.apply(project.ledger, command)
		if not applied.ok:
			return applied
		project.ledger = applied.state
	# No quote is invented. The existing complete mapping is explicitly prior-only.
	project.valuation_pending = {"reason": "ASSET_ENTRY",
		"ledger_hash": Store.canonical_ledger_hash(project.ledger)}
	return store.save_project(project, int(loaded.generation))


func _mount(path: String) -> Control:
	var panel := Scene.instantiate()
	panel.base_path = path
	root.add_child(panel)
	await process_frame
	return panel


func _select_id(picker: OptionButton, id: String) -> void:
	for index in picker.item_count:
		if str(picker.get_item_metadata(index)) == id:
			picker.select(index)
			return
	failures.append("candidate missing: " + id)


func _check(condition: bool, label: String) -> void:
	checks += 1
	if not condition:
		failures.append(label)
