extends SceneTree

const Scene = preload("res://scenes/personal_manual_revaluation.tscn")
const Store = preload("res://scripts/data/project_store.gd")
const PersonalFlow = preload("res://scripts/data/personal_flow.gd")
const AssetFlow = preload("res://scripts/data/personal_asset_flow.gd")
const Contract = preload("res://scripts/quotes/quote_contract.gd")
const Display = preload("res://scripts/data/display_snapshot_service.gd")

var checks := 0
var failures: Array[String] = []
var now_at := ""


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	now_at = Time.get_datetime_string_from_unix_time(int(Time.get_unix_time_from_system())) + "Z"
	var directory := ProjectSettings.globalize_path("res://").path_join("tests/tmp")
	DirAccess.make_dir_recursive_absolute(directory)
	var prefix := directory.path_join("personal-manual-scene-" + str(Time.get_ticks_usec()))
	await _test_guards(prefix + "-empty", prefix + "-demo")
	await _test_complete_path(prefix + "-normal", false)
	await _test_complete_path(prefix + "-private", true)
	await _test_restricted_page(prefix + "-restricted")
	await _test_other_asset_page(prefix + "-other")
	_check(checks >= 25, "all scene interaction checks reached")
	if failures.is_empty():
		print("PERSONAL MANUAL REVALUATION SCENE PASS: %d checks" % checks)
		quit(0)
	else:
		for failure in failures:
			printerr("FAIL: " + failure)
		printerr("PERSONAL MANUAL REVALUATION SCENE FAIL: %d failures in %d checks" % [
			failures.size(), checks])
		quit(1)


func _test_guards(empty_path: String, demo_path: String) -> void:
	var empty := await _mount(empty_path)
	_check(empty.get_preview_button().disabled and empty.get_confirm_button().disabled
		and empty.get_status_text().contains("现金开户")
		and empty.get_return_button().visible,
		"uninitialized personal project cannot use manual valuation")
	empty.queue_free()
	await process_frame
	var store := Store.new(demo_path)
	var demo := store.new_project()
	demo.data_kind = "demo"
	_check(store.save_project(demo, 0).ok, "demo fixture saved")
	var panel := await _mount(demo_path)
	_check(panel.get_preview_button().disabled and panel.get_status_text().contains("演示项目")
		and panel.get_required_keys().is_empty() and panel.get_return_button().visible,
		"demo project has no manual valuation controls")
	panel.queue_free()
	await process_frame


func _test_complete_path(path: String, private: bool) -> void:
	var label := "private" if private else "normal"
	var initialized := _create_fixture(path)
	_check(initialized.ok, label + " initialized personal fixture")
	if not initialized.ok:
		return
	var store := Store.new(path)
	if private:
		var privacy := store.load_project()
		privacy.state.presentation.privacy_mode = "hide_total"
		_check(store.save_project(privacy.state, privacy.generation).ok,
			"privacy mode saved before valuation")
	var before: Dictionary = store.load_project()
	var panel := await _mount(path)
	_check(panel.get_return_button().visible,
		label + " can return to personal jar before entering quotes")
	var keys: Array[String] = panel.get_required_keys()
	var stock := _key("STOCK", "NYSE", "EXMPL", "USD")
	var etf := _key("ETF", "NASDAQ", "SAMPLE", "USD")
	var fund := _key("FUND", "CN", "FUND1", "CNY", "A")
	var fx := _key("FX", "FX", "USD/CNY", "CNY")
	var gold := _key("GOLD", "SPOT", "XAU", "CNY")
	_check(keys.size() == 5 and keys.has(stock) and keys.has(etf) and keys.has(fund)
		and keys.has(fx) and keys.has(gold),
		label + " exact stock, ETF, fund, FX and gold identities derived")
	var blank := true
	for key in keys:
		var fields: Dictionary = panel.get_quote_fields(key)
		blank = blank and fields.price.text.is_empty() and fields.quoted_at.text.is_empty()
		blank = blank and fields.source_note.text.is_empty()
		blank = blank and str(fields.unit.get_item_metadata(fields.unit.selected)).is_empty()
	_check(blank and not panel.get_at_input().text.is_empty(),
		label + " no quote price, unit, time or source is invented")
	panel.get_at_input().text = now_at
	_fill(panel, stock, "50", "CURRENCY_PER_SHARE", "user stock statement")
	_fill(panel, etf, "100", "CURRENCY_PER_SHARE", "user ETF statement")
	_fill(panel, fund, "10", "CURRENCY_PER_SHARE", "user fund NAV")
	_fill(panel, fx, "7", "CURRENCY_PER_FOREIGN_UNIT", "user FX statement")
	_fill(panel, gold, "0", "CURRENCY_PER_GRAM", "user gold statement")
	_preview(panel)
	_check(panel.get_confirm_button().disabled and panel.get_preview_text().contains("预览失败")
		and store.load_project().generation == before.generation,
		label + " invalid zero gold price makes no write")
	panel.get_quote_fields(gold).price.text = "1000"
	_preview(panel)
	var preview_text: String = panel.get_preview_text()
	_check(not panel.get_confirm_button().disabled and preview_text.contains("12.13 克")
		and preview_text.contains("EXMPL") and preview_text.contains("FUND1")
		and preview_text.contains("USD/CNY") and preview_text.contains("来源 user ETF statement")
		and store.load_project().generation == before.generation
		and store.load_project().state.valuation.snapshots.is_empty(),
		label + " readable complete preview computes grams without saving")
	if private:
		_check(preview_text.contains("隐私模式") and not preview_text.contains("12130")
			and not preview_text.contains("预计总资产："),
			"privacy preview masks monetary total while retaining reviewable identities and grams")
	else:
		_check(preview_text.contains("预计总资产：12130 CNY"),
			"normal preview shows derived amount and currency")
	var navigation := {"requested": false}
	panel.return_to_jar_requested.connect(func() -> void: navigation.requested = true)
	_confirm(panel)
	var saved: Dictionary = store.load_project()
	var display: Dictionary = Display.build(saved.state, saved.generation)
	_check(saved.generation == before.generation + 2
		and saved.state.valuation.snapshots.size() == 1
		and not saved.state.has("valuation_pending")
		and display.ok and display.snapshot.snapshot_status == "CURRENT"
		and panel.get_return_button().visible,
		label + " confirm saves valuation then current gold mapping")
	if private:
		_check(panel.get_preview_text().contains("隐私模式")
			and not panel.get_preview_text().contains("12130")
			and not display.snapshot.has("display_amount"),
			"private success stays reviewable without monetary total")
	else:
		_check(panel.get_preview_text().contains("12130")
			and display.snapshot.display_amount == "12130",
			"normal success matches versioned current display")
	var batch: Dictionary = saved.state.quote_gateway.batches.values()[0]
	_check(batch.entries[stock].quote.source == "USER_MANUAL"
		and batch.entries[fund].quote.source_note == "user fund NAV"
		and batch.entries[gold].quote.price == "1000",
		label + " source notes and exact prices persisted")
	panel.get_return_button().pressed.emit()
	_check(navigation.requested, label + " return-to-jar signal offered after success")
	_confirm(panel)
	_check(store.load_project().generation == saved.generation,
		label + " second confirmation cannot add generations")
	panel.queue_free()
	await process_frame
	var restarted := await _mount(path)
	_check(restarted.get_status_text().contains("当前完整快照")
		and restarted.get_confirm_button().disabled
		and Store.new(path).load_project().generation == saved.generation,
		label + " restart reads CURRENT mapping and requires fresh user quote review")
	restarted.queue_free()
	await process_frame


func _test_restricted_page(path: String) -> void:
	var opened := PersonalFlow.new(path).create_opening_cash(
		"restricted-revalue-start", "cash", "现金", "10000", "1000", now_at)
	_check(opened.ok, "restricted revaluation scene opening")
	if not opened.ok:
		return
	var commands := [
		{"command_id": "restricted-account", "type": "account_create",
			"account": {"id": "provident", "name": "住房公积金", "currency": "CNY",
				"mode": "detail", "cost_method": "FIFO", "asset_kind": "PROVIDENT_FUND"}},
		{"command_id": "restricted-checkpoint", "type": "restricted_balance_set",
			"account_id": "provident", "amount": "2300.5",
			"source_note": "个人账户对账单", "effective_at": now_at},
	]
	var preview := AssetFlow.new(path).preview(commands, opened.generation)
	var committed := AssetFlow.new(path).confirm(commands, preview,
		{"confirmed": true, "preview_id": str(preview.get("preview_id", ""))})
	_check(preview.ok and committed.ok, "restricted revaluation fixture saved")
	if not committed.ok:
		return
	var panel := await _mount(path)
	var gold := _key("GOLD", "SPOT", "XAU", "CNY")
	_check(panel.get_status_text().contains("1 现金账户 / 1 受限账户") \
		and panel.get_required_keys() == [gold],
		"page includes restricted account without inventing a separate market quote")
	panel.get_at_input().text = now_at
	_fill(panel, gold, "1000", "CURRENCY_PER_GRAM", "user gold statement")
	var before := Store.new(path).load_project()
	_preview(panel)
	_check(panel.get_preview_text().contains("受限余额 · 住房公积金：2300.5 CNY") \
		and panel.get_preview_text().contains("预计总资产：12300.5 CNY") \
		and before.generation == Store.new(path).load_project().generation,
		"manual valuation preview explicitly shows restricted checkpoint and total")
	_confirm(panel)
	var saved := Store.new(path).load_project()
	_check(saved.generation == before.generation + 2 \
		and saved.state.valuation.snapshots.values()[0].restricted_values.size() == 1 \
		and Display.build(saved.state, saved.generation).snapshot.snapshot_status == "CURRENT",
		"manual valuation UI confirms restricted balance and current gold mapping")
	panel.queue_free()
	await process_frame


func _test_other_asset_page(path: String) -> void:
	var opened := PersonalFlow.new(path).create_opening_cash(
		"other-revalue-start", "cash", "现金", "10000", "1000", now_at)
	_check(opened.ok, "other asset revaluation scene opening")
	if not opened.ok:
		return
	var commands := [{"command_id": "other-create", "type": "other_asset_create",
		"asset": {"id": "collection", "name": "测试收藏品", "currency": "USD",
			"ownership_scope": "OWNED_SHARE", "ownership_note": "本人持有份额",
			"dedup_key": "COLLECTION-1"},
		"opening_value": {"amount": "2500", "valuation_basis": "测试成交参考",
			"effective_at": now_at}}]
	var preview := AssetFlow.new(path).preview(commands, opened.generation)
	if not preview.ok:
		_check(false, "other asset revaluation fixture preview")
		return
	var committed := AssetFlow.new(path).confirm(commands, preview,
		{"confirmed": true, "preview_id": str(preview.preview_id)})
	_check(committed.ok, "other asset revaluation fixture saved")
	if not committed.ok:
		return
	var panel := await _mount(path)
	var fx := _key("FX", "FX", "USD/CNY", "CNY")
	var gold := _key("GOLD", "SPOT", "XAU", "CNY")
	var keys: Array[String] = panel.get_required_keys()
	_check(keys.size() == 2 and keys.has(fx) and keys.has(gold),
		"other asset currency requires FX and gold without an invented asset quote")
	panel.get_at_input().text = now_at
	_fill(panel, fx, "7", "CURRENCY_PER_FOREIGN_UNIT", "test FX reference")
	_fill(panel, gold, "1000", "CURRENCY_PER_GRAM", "test gold reference")
	var before := Store.new(path).load_project()
	_preview(panel)
	_check(panel.get_preview_text().contains("其他估值资产 · 测试收藏品：2500 USD") \
		and panel.get_preview_text().contains("依据 测试成交参考") \
		and panel.get_preview_text().contains("预计总资产：27500 CNY") \
		and before.generation == Store.new(path).load_project().generation,
		"manual preview shows other asset checkpoint, basis and converted total")
	_confirm(panel)
	var saved := Store.new(path).load_project()
	_check(saved.generation == before.generation + 2 \
		and saved.state.valuation.snapshots.values()[0].other_asset_values.size() == 1 \
		and Display.build(saved.state, saved.generation).snapshot.snapshot_status == "CURRENT",
		"manual UI confirmation includes other asset in current gold mapping")
	panel.queue_free()
	await process_frame


func _create_fixture(path: String) -> Dictionary:
	var opening: Dictionary = PersonalFlow.new(path).create_opening_cash(
		"manual-scene-opening", "cash-cny", "CNY Cash", "10000", "1000", now_at)
	if not opening.ok:
		return opening
	var commands := [
		{"command_id": "usd-account", "type": "account_create", "account": {
			"id": "usd-account", "name": "USD Brokerage", "currency": "USD",
			"mode": "detail", "cost_method": "FIFO"}},
		{"command_id": "stock", "type": "instrument_create", "instrument": {
			"id": "stock", "kind": "STOCK", "market": "NYSE", "symbol": "EXMPL",
			"currency": "USD", "share_class": ""}},
		{"command_id": "etf", "type": "instrument_create", "instrument": {
			"id": "etf", "kind": "ETF", "market": "NASDAQ", "symbol": "SAMPLE",
			"currency": "USD", "share_class": ""}},
		{"command_id": "fund", "type": "instrument_create", "instrument": {
			"id": "fund", "kind": "FUND", "market": "CN", "symbol": "FUND1",
			"currency": "CNY", "share_class": "A"}},
		{"command_id": "usd-cash", "type": "opening_cash", "account_id": "usd-account",
			"amount": "100", "effective_at": now_at},
		{"command_id": "stock-position", "type": "opening_position",
			"account_id": "usd-account", "instrument_id": "stock", "quantity": "2",
			"reference_price": "45", "cost_basis": "", "effective_at": now_at},
		{"command_id": "etf-position", "type": "opening_position",
			"account_id": "usd-account", "instrument_id": "etf", "quantity": "1",
			"reference_price": "90", "cost_basis": "", "effective_at": now_at},
		{"command_id": "fund-position", "type": "opening_position",
			"account_id": "cash-cny", "instrument_id": "fund", "quantity": "3",
			"reference_price": "9", "cost_basis": "", "effective_at": now_at},
	]
	var flow := AssetFlow.new(path)
	var preview: Dictionary = flow.preview(commands, int(opening.generation))
	if not preview.ok:
		return preview
	return flow.confirm(commands, preview, {"confirmed": true, "preview_id": preview.preview_id})


func _mount(path: String) -> Control:
	var panel := Scene.instantiate()
	panel.base_path = path
	root.add_child(panel)
	await process_frame
	return panel


func _fill(panel: Control, key: String, price: String, unit: String, source: String) -> void:
	var fields: Dictionary = panel.get_quote_fields(key)
	fields.price.text = price
	fields.quoted_at.text = now_at
	fields.source_note.text = source
	var picker: OptionButton = fields.unit
	for index in picker.item_count:
		if str(picker.get_item_metadata(index)) == unit:
			picker.select(index)
			picker.item_selected.emit(index)
			return
	_check(false, "unit option missing: " + unit)


func _key(kind: String, market: String, symbol: String,
		currency: String, share_class: String = "") -> String:
	return Contract.identity_key({"kind": kind, "market": market, "symbol": symbol,
		"currency": currency, "share_class": share_class})


func _preview(panel: Control) -> void:
	panel.get_preview_button().pressed.emit()


func _confirm(panel: Control) -> void:
	panel.get_confirm_button().pressed.emit()


func _check(condition: bool, label: String) -> void:
	checks += 1
	if not condition:
		failures.append(label)
