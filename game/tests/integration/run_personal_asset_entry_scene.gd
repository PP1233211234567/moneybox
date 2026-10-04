extends SceneTree

const Scene = preload("res://scenes/personal_asset_entry.tscn")
const Store = preload("res://scripts/data/project_store.gd")
const PersonalFlow = preload("res://scripts/data/personal_flow.gd")
const Ledger = preload("res://scripts/data/ledger_core.gd")

const NOW := "2026-09-27T02:00:00Z"

var checks := 0
var failures: Array[String] = []


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var directory := ProjectSettings.globalize_path("res://").path_join("tests/tmp")
	DirAccess.make_dir_recursive_absolute(directory)
	var prefix := directory.path_join("personal-asset-entry-" + str(Time.get_ticks_usec()))
	await _test_guard(prefix + "-empty", prefix + "-demo")
	await _test_forms(prefix + "-personal")
	await _test_restricted_form(prefix + "-restricted")
	await _test_other_asset_forms(prefix + "-other-asset")
	if failures.is_empty():
		print("PERSONAL ASSET ENTRY SCENE PASS: %d checks" % checks)
		quit(0)
	else:
		for failure in failures:
			printerr("FAIL: " + failure)
		printerr("PERSONAL ASSET ENTRY SCENE FAIL: %d failures in %d checks" % [
			failures.size(), checks])
		quit(1)


func _test_guard(empty_path: String, demo_path: String) -> void:
	var empty := await _mount(empty_path)
	_check(empty.get_preview_button().disabled and empty.get_confirm_button().disabled
		and empty.get_status_text().contains("现金开户"),
		"unopened personal project cannot enter assets")
	empty.queue_free()
	await process_frame
	var store := Store.new(demo_path)
	var demo := store.new_project()
	demo.data_kind = "demo"
	_check(store.save_project(demo, 0).ok, "demo fixture saved")
	var panel := await _mount(demo_path)
	_check(panel.get_preview_button().disabled and panel.get_status_text().contains("演示账本"),
		"demo project cannot use personal asset entry")
	panel.queue_free()
	await process_frame


func _test_forms(path: String) -> void:
	var opened: Dictionary = PersonalFlow.new(path).create_opening_cash(
		"asset-entry-opening", "cash-primary", "主现金账户", "10000", "1000", NOW)
	_check(opened.ok, "mapped personal opening fixture")
	if not opened.ok:
		return
	var store := Store.new(path)
	var original: Dictionary = store.load_project()
	var original_mapping: Dictionary = original.state.mappings.back().duplicate(true)
	var panel := await _mount(path)
	_check(not panel.get_preview_button().disabled and panel.get_confirm_button().disabled,
		"opened personal project displays separate preview and disabled confirm")
	_select(panel.get_picker("mode"), "account_create")
	panel.get_input("account_name").text = "第二现金账户"
	panel.get_input("account_currency").text = "CNY"
	var before := store.load_project()
	_preview(panel)
	_check(not panel.get_confirm_button().disabled and panel.get_preview_text().contains("待确认")
		and panel.get_preview_text().contains("第二现金账户")
		and store.load_project().generation == before.generation,
		"account form preview is readable and does not write")
	_confirm(panel)
	var saved := store.load_project()
	_check(saved.generation == before.generation + 1 and saved.state.ledger.accounts.size() == 2
		and not saved.state.valuation_pending.is_empty() and panel.get_confirm_button().disabled,
		"account confirmation writes exactly one pending generation")
	_confirm(panel)
	_check(store.load_project().generation == saved.generation,
		"second confirm click cannot save again")
	var second_cny := _account_id(saved.state.ledger, "第二现金账户")
	_check(not second_cny.is_empty(), "account ID generated and saved")

	panel.get_input("account_name").text = "美元券商"
	panel.get_input("account_currency").text = "USD"
	_preview(panel)
	_confirm(panel)
	saved = store.load_project()
	var usd_account := _account_id(saved.state.ledger, "美元券商")
	_check(saved.generation == before.generation + 2 and not usd_account.is_empty(),
		"second account has its own generated ID")

	_select(panel.get_picker("mode"), "instrument_create")
	_select(panel.get_picker("instrument_kind"), "ETF")
	panel.get_input("instrument_name").text = "示例 ETF"
	panel.get_input("instrument_market").text = "NASDAQ"
	panel.get_input("instrument_symbol").text = "VOO"
	panel.get_input("instrument_currency").text = "USD"
	before = store.load_project()
	_preview(panel)
	_check(panel.get_preview_text().contains("ETF · NASDAQ:VOO")
		and before.generation == store.load_project().generation,
		"instrument form previews market and symbol without a quote")
	_confirm(panel)
	saved = store.load_project()
	var instrument_id := _instrument_id(saved.state.ledger, "VOO")
	_check(saved.generation == before.generation + 1 and not instrument_id.is_empty(),
		"ETF identity confirmed with generated ID")

	_select(panel.get_picker("mode"), "opening_cash")
	_select(panel.get_picker("cash_account"), usd_account)
	panel.get_input("cash_amount").text = "1000.25"
	panel.get_input("cash_at").text = NOW
	before = store.load_project()
	_preview(panel)
	_check(panel.get_preview_text().contains("1000.25 USD")
		and before.generation == store.load_project().generation,
		"opening cash string decimal preview makes no write")
	_confirm(panel)
	saved = store.load_project()
	_check(saved.generation == before.generation + 1
		and Ledger.project(saved.state.ledger).cash[usd_account] == "1000.25",
		"opening cash confirmation stores exact decimal amount")

	_select(panel.get_picker("mode"), "opening_position")
	_select(panel.get_picker("position_account"), usd_account)
	_select(panel.get_picker("position_instrument"), instrument_id)
	panel.get_input("position_quantity").text = "2.5"
	panel.get_input("position_price").text = "100"
	panel.get_input("position_cost").text = ""
	panel.get_input("position_at").text = NOW
	before = store.load_project()
	_preview(panel)
	_check(panel.get_preview_text().contains("手工参考价 100 USD")
		and panel.get_preview_text().contains("已知总成本：未知")
		and before.generation == store.load_project().generation,
		"opening holding requires explicit manual price and permits unknown cost")
	_confirm(panel)
	saved = store.load_project()
	var position_key := usd_account + "|" + instrument_id
	var projection: Dictionary = Ledger.project(saved.state.ledger)
	_check(saved.generation == before.generation + 1 and projection.positions.has(position_key)
		and projection.positions[position_key].quantity == "2.5"
		and not projection.positions[position_key].cost_known,
		"opening holding confirms quantity without inventing cost")

	_select(panel.get_picker("mode"), "transfer")
	_select(panel.get_picker("transfer_from"), "cash-primary")
	_select(panel.get_picker("transfer_to"), second_cny)
	panel.get_input("transfer_amount").text = "125.5"
	panel.get_input("transfer_at").text = NOW
	before = store.load_project()
	_preview(panel)
	_check(not panel.get_confirm_button().disabled and
		store.load_project().generation == before.generation,
		"same-currency transfer previews before write")
	_confirm(panel)
	saved = store.load_project()
	projection = Ledger.project(saved.state.ledger)
	_check(saved.generation == before.generation + 1
		and projection.cash["cash-primary"] == "9874.5"
		and projection.cash[second_cny] == "125.5",
		"transfer preserves cash across both accounts")

	_select(panel.get_picker("mode"), "opening_cash")
	_select(panel.get_picker("cash_account"), usd_account)
	panel.get_input("cash_amount").text = "12.5x"
	panel.get_input("cash_at").text = NOW
	before = store.load_project()
	_preview(panel)
	_check(panel.get_confirm_button().disabled and panel.get_preview_text().contains("预览失败")
		and store.load_project().generation == before.generation,
		"invalid decimal fails preview with no write")
	panel.get_input("cash_amount").text = "2"
	_preview(panel)
	panel.get_input("cash_amount").text = "3" # Programmatic edit bypasses UI signal.
	_confirm(panel)
	_check(store.load_project().generation == before.generation
		and panel.get_preview_text().contains("重新预览"),
		"changed input cannot reuse a shown preview")
	panel.get_input("cash_amount").text = "4"
	_preview(panel)
	panel.get_input("cash_amount").text = "5"
	panel.get_input("cash_amount").text_changed.emit("5")
	_check(panel.get_confirm_button().disabled and store.load_project().generation == before.generation,
		"real text edit immediately invalidates confirm without a write")

	_select(panel.get_picker("mode"), "transfer")
	_select(panel.get_picker("transfer_from"), "cash-primary")
	_select(panel.get_picker("transfer_to"), usd_account)
	panel.get_input("transfer_amount").text = "10"
	_preview(panel)
	_check(panel.get_confirm_button().disabled and panel.get_preview_text().contains("同币种")
		and store.load_project().generation == before.generation,
		"cross-currency transfer is rejected without FX guessing")

	_check(saved.state.mappings.back() == original_mapping
		and saved.state.valuation_pending.ledger_hash ==
		Store.canonical_ledger_hash(saved.state.ledger)
		and panel.get_status_text().contains("等待重估"),
		"old mapped beans remain explicitly previous snapshot after asset changes")
	panel.queue_free()
	await process_frame
	var restarted := await _mount(path)
	_check(restarted.get_status_text().contains("等待重估")
		and restarted.get_confirm_button().disabled
		and Store.new(path).load_project().state.ledger.events.size() == 4,
		"restart shows pending status and restores exactly four events")
	restarted.queue_free()
	await process_frame
	var privacy := store.load_project()
	privacy.state.presentation.privacy_mode = "hide_total"
	_check(store.save_project(privacy.state, privacy.generation).ok,
		"privacy fixture saved without touching ledger")
	var private_panel := await _mount(path)
	_select(private_panel.get_picker("mode"), "opening_cash")
	_select(private_panel.get_picker("cash_account"), "cash-primary")
	private_panel.get_input("cash_amount").text = "1"
	private_panel.get_input("cash_at").text = NOW
	_preview(private_panel)
	_check(private_panel.get_preview_text().contains("隐私模式")
		and not private_panel.get_preview_text().contains("现金 ·")
		and store.load_project().state.ledger.events.size() == 4,
		"privacy mode masks projected balances without committing preview")
	private_panel.queue_free()
	await process_frame


func _test_restricted_form(path: String) -> void:
	var opened := PersonalFlow.new(path).create_opening_cash(
		"restricted-scene-start", "cash", "现金", "10000", "1000", NOW)
	_check(opened.ok, "restricted scene personal opening")
	if not opened.ok:
		return
	var store := Store.new(path)
	var panel := await _mount(path)
	_select(panel.get_picker("mode"), "account_create")
	_select(panel.get_picker("account_asset_kind"), "PROVIDENT_FUND")
	panel.get_input("account_name").text = "住房公积金"
	panel.get_input("account_currency").text = "CNY"
	var before := store.load_project()
	_preview(panel)
	_check(panel.get_preview_text().contains("新增账户") \
		and panel.get_preview_text().contains("住房公积金") \
		and store.load_project().generation == before.generation,
		"provident account category previews with no write")
	_confirm(panel)
	var created := store.load_project()
	var restricted_id := _account_id(created.state.ledger, "住房公积金")
	_check(created.generation == before.generation + 1 and not restricted_id.is_empty() \
		and created.state.ledger.accounts[restricted_id].asset_kind == "PROVIDENT_FUND",
		"provident account confirmed with explicit kind")
	if restricted_id.is_empty():
		panel.queue_free()
		await process_frame
		return
	_select(panel.get_picker("mode"), "restricted_balance_set")
	_select(panel.get_picker("restricted_account"), restricted_id)
	panel.get_input("restricted_amount").text = "2300.50"
	panel.get_input("restricted_source").text = "个人账户对账单"
	panel.get_input("restricted_at").text = NOW
	before = store.load_project()
	_preview(panel)
	_check(panel.get_preview_text().contains("受限余额检查点") \
		and panel.get_preview_text().contains("2300.5 CNY") \
		and panel.get_preview_text().contains("不推算缴存、利息或收益") \
		and store.load_project().generation == before.generation,
		"restricted balance preview shows amount, source and non-inference rule")
	_confirm(panel)
	var saved := store.load_project()
	var projection := Ledger.project(saved.state.ledger)
	_check(saved.generation == before.generation + 1 \
		and projection.restricted_balances[restricted_id] == "2300.5" \
		and not projection.cash.has(restricted_id) \
		and projection.cash.cash == "10000" \
		and saved.state.valuation_pending.ledger_hash == \
		Store.canonical_ledger_hash(saved.state.ledger),
		"restricted balance saves separately from cash with pending valuation")
	_select(panel.get_picker("mode"), "opening_cash")
	var has_restricted_cash := false
	for index in panel.get_picker("cash_account").item_count:
		if str(panel.get_picker("cash_account").get_item_metadata(index)) == restricted_id:
			has_restricted_cash = true
	_check(not has_restricted_cash, "restricted account is absent from cash entry picker")
	panel.queue_free()
	await process_frame
	var restarted := await _mount(path)
	_check(restarted.get_status_text().contains("等待重估") \
		and Ledger.project(store.load_project().state.ledger).restricted_balances[restricted_id] == "2300.5",
		"scene restart restores confirmed restricted checkpoint")
	restarted.queue_free()
	await process_frame


func _test_other_asset_forms(path: String) -> void:
	var opened := PersonalFlow.new(path).create_opening_cash(
		"other-scene-start", "cash", "现金", "10000", "1000", NOW)
	_check(opened.ok, "other asset scene personal opening")
	if not opened.ok:
		return
	var store := Store.new(path)
	var before: Dictionary = store.load_project()
	var original_mapping: Dictionary = before.state.mappings.back().duplicate(true)
	var panel := await _mount(path)
	_select(panel.get_picker("mode"), "other_asset_create")
	_select(panel.get_picker("other_ownership_scope"), "OWNED_SHARE")
	panel.get_input("other_name").text = "共同持有画作"
	panel.get_input("other_currency").text = "CNY"
	panel.get_input("other_dedup_key").text = "art-001"
	panel.get_input("other_opening_amount").text = "2500.00"
	panel.get_input("other_opening_basis").text = "已核对评估记录"
	panel.get_input("other_opening_at").text = NOW
	_preview(panel)
	_check(panel.get_confirm_button().disabled and
		store.load_project().generation == before.generation,
		"other asset requires an ownership basis before confirmation")
	panel.get_input("other_ownership_note").text = "共同购买协议"
	panel.get_input("other_opening_basis").text = ""
	_preview(panel)
	_check(panel.get_confirm_button().disabled and
		store.load_project().generation == before.generation,
		"other asset requires a valuation basis before confirmation")
	panel.get_input("other_opening_basis").text = "已核对评估记录"
	_preview(panel)
	_check(not panel.get_confirm_button().disabled and
		panel.get_preview_text().contains("待确认") and
		panel.get_preview_text().contains("共同持有画作") and
		panel.get_preview_text().contains("2500") and
		panel.get_preview_text().contains("共同购买协议") and
		panel.get_preview_text().contains("已核对评估记录") and
		store.load_project().generation == before.generation and
		store.load_project().state.ledger.other_assets.is_empty(),
		"other asset preview shows ownership and value without writing")
	_confirm(panel)
	var created: Dictionary = store.load_project()
	var asset_id := _other_asset_id(created.state.ledger, "共同持有画作")
	var projection: Dictionary = Ledger.project(created.state.ledger)
	_check(created.generation == before.generation + 1 and not asset_id.is_empty() and
		created.state.ledger.other_assets[asset_id].ownership_scope == "OWNED_SHARE" and
		created.state.ledger.other_assets[asset_id].ownership_note == "共同购买协议" and
		created.state.ledger.other_assets[asset_id].dedup_key == "ART-001" and
		projection.other_asset_values[asset_id] == "2500" and
		projection.other_asset_checkpoints[asset_id].valuation_basis == "已核对评估记录" and
		created.state.valuation_pending.ledger_hash ==
		Store.canonical_ledger_hash(created.state.ledger) and
		created.state.mappings.back() == original_mapping and
		panel.get_confirm_button().disabled,
		"other asset confirmation saves one pending version and keeps old mapping")
	_confirm(panel)
	_check(store.load_project().generation == created.generation,
		"other asset second confirm cannot append another event")
	if asset_id.is_empty():
		panel.queue_free()
		await process_frame
		return
	_check(_picker_has(panel.get_picker("other_existing_asset"), asset_id),
		"confirmed other asset appears in the update selector")
	_select(panel.get_picker("mode"), "other_asset_value_set")
	_select(panel.get_picker("other_existing_asset"), asset_id)
	panel.get_input("other_value_amount").text = "2600.00"
	panel.get_input("other_value_at").text = NOW
	_preview(panel)
	_check(panel.get_confirm_button().disabled and
		store.load_project().generation == created.generation,
		"other asset update requires a new valuation basis")
	panel.get_input("other_value_basis").text = "本次市场参考资料"
	_preview(panel)
	_check(not panel.get_confirm_button().disabled and
		panel.get_preview_text().contains("待确认") and
		panel.get_preview_text().contains("共同持有画作") and
		panel.get_preview_text().contains("2600") and
		panel.get_preview_text().contains("本次市场参考资料") and
		store.load_project().generation == created.generation,
		"other asset replacement value previews without writing")
	_confirm(panel)
	var updated: Dictionary = store.load_project()
	projection = Ledger.project(updated.state.ledger)
	_check(updated.generation == created.generation + 1 and
		updated.state.ledger.events.size() == created.state.ledger.events.size() + 1 and
		projection.other_asset_values[asset_id] == "2600" and
		projection.other_asset_checkpoints[asset_id].valuation_basis == "本次市场参考资料" and
		updated.state.ledger.events[-2].amount == "2500" and
		updated.state.mappings.back() == original_mapping and
		updated.state.valuation_pending.ledger_hash ==
		Store.canonical_ledger_hash(updated.state.ledger),
		"other asset update preserves history and replaces current checkpoint")
	panel.queue_free()
	await process_frame
	var restarted := await _mount(path)
	_check(restarted.get_status_text().contains("等待重估") and
		_picker_has(restarted.get_picker("other_existing_asset"), asset_id) and
		Ledger.project(store.load_project().state.ledger).other_asset_values[asset_id] == "2600",
		"scene restart restores pending other asset and update selector")
	restarted.queue_free()
	await process_frame


func _mount(path: String) -> Control:
	var panel := Scene.instantiate()
	panel.base_path = path
	root.add_child(panel)
	await process_frame
	return panel


func _select(picker: OptionButton, value: String) -> void:
	for index in picker.item_count:
		if str(picker.get_item_metadata(index)) == value:
			picker.select(index)
			picker.item_selected.emit(index)
			return
	_check(false, "option missing: " + value)


func _preview(panel: Control) -> void:
	panel.get_preview_button().pressed.emit()


func _confirm(panel: Control) -> void:
	panel.get_confirm_button().pressed.emit()


func _account_id(ledger: Dictionary, name: String) -> String:
	for id in ledger.accounts:
		if str(ledger.accounts[id].get("name", "")) == name:
			return str(id)
	return ""


func _instrument_id(ledger: Dictionary, symbol: String) -> String:
	for id in ledger.instruments:
		if str(ledger.instruments[id].get("symbol", "")) == symbol:
			return str(id)
	return ""


func _other_asset_id(ledger: Dictionary, name: String) -> String:
	for id in ledger.other_assets:
		if str(ledger.other_assets[id].get("name", "")) == name:
			return str(id)
	return ""


func _picker_has(picker: OptionButton, value: String) -> bool:
	for index in picker.item_count:
		if str(picker.get_item_metadata(index)) == value:
			return true
	return false


func _check(condition: bool, label: String) -> void:
	checks += 1
	if not condition:
		failures.append(label)
