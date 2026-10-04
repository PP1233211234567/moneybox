extends SceneTree

const SCENE = preload("res://scenes/personal_overview.tscn")
const Store = preload("res://scripts/data/project_store.gd")
const Ledger = preload("res://scripts/data/ledger_core.gd")
const Contract = preload("res://scripts/quotes/quote_contract.gd")
const Gateway = preload("res://scripts/quotes/quote_gateway.gd")
const ManualProvider = preload("res://scripts/quotes/manual_quote_provider.gd")
const Personal = preload("res://scripts/data/personal_flow.gd")
const Asset = preload("res://scripts/data/personal_asset_flow.gd")
const Revalue = preload("res://scripts/quotes/personal_manual_revaluation_flow.gd")

const NOW := "2026-09-27T02:00:00Z"

var checks := 0
var failures: Array[String] = []
var directory := ""


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	directory = ProjectSettings.globalize_path("res://").get_base_dir().path_join("tests") \
		.path_join("data").path_join("tmp")
	DirAccess.make_dir_recursive_absolute(directory)
	var suffix := str(Time.get_ticks_usec())
	await _test_empty(directory.path_join("overview-empty-" + suffix))
	await _test_cash(directory.path_join("overview-cash-" + suffix))
	await _test_mapped_cash(directory.path_join("overview-mapped-cash-" + suffix))
	await _test_restricted_balance(directory.path_join("overview-restricted-" + suffix))
	await _test_holding_valuation_privacy_restart(directory.path_join("overview-holding-" + suffix))
	await _test_demo_rejected(directory.path_join("overview-demo-" + suffix))
	if failures.is_empty():
		print("PERSONAL OVERVIEW TESTS PASS: %d checks" % checks)
		quit(0)
	else:
		for failure in failures:
			printerr(failure)
		printerr("PERSONAL OVERVIEW TESTS FAIL: %d failures in %d checks" % [failures.size(), checks])
		quit(1)


func _check(condition: bool, label: String) -> void:
	checks += 1
	if not condition:
		failures.append(label)


func _open(path: String) -> Control:
	var scene: Control = SCENE.instantiate()
	scene.base_path = path
	root.add_child(scene)
	await process_frame
	return scene


func _close(scene: Control) -> void:
	root.remove_child(scene)
	scene.free()


func _visible_text(scene: Control) -> String:
	var lines: Array[String] = []
	_collect_text(scene, lines)
	return "\n".join(lines)


func _collect_text(node: Node, lines: Array[String]) -> void:
	if node is Label:
		lines.append(node.text)
	elif node is Button:
		lines.append(node.text)
	for child in node.get_children():
		_collect_text(child, lines)


func _test_empty(path: String) -> void:
	var scene: Control = await _open(path)
	_check(scene.get_generation() == 0 and scene.get_status_text().contains("尚未保存") \
		and scene.get_account_texts().is_empty() and scene.get_holding_texts().is_empty(),
		"unsaved empty project shows onboarding state without numbers")
	_check(scene.get_return_button() != null and scene.get_return_button().text == "返回金豆罐",
		"overview has return button")
	_close(scene)
	var store := Store.new(path)
	var saved := store.save_project(store.new_project(), 0)
	_check(saved.ok, "saved empty project fixture")
	scene = await _open(path)
	_check(scene.get_status_text().contains("待重估") \
		and scene.get_account_texts().is_empty() \
		and not scene.get_summary_text().contains("CNY 0"),
		"saved empty ledger cannot imply complete zero valuation")
	_close(scene)


func _test_cash(path: String) -> void:
	var store := Store.new(path)
	var project := store.new_project()
	var commands := [
		{"command_id": "cash-account", "type": "account_create", "account": {
			"id": "cash", "name": "现金账户", "currency": "CNY", "mode": "detail",
			"cost_method": "FIFO", "source": "手工", "custodian": "自持"}},
		{"command_id": "cash-opening", "type": "opening_cash", "account_id": "cash",
			"amount": "5000", "effective_at": NOW},
	]
	for command in commands:
		var applied := Ledger.apply(project.ledger, command)
		if not applied.ok:
			_check(false, "cash fixture command")
			return
		project.ledger = applied.state
	var saved := store.save_project(project, 0)
	_check(saved.ok, "cash account project saved")
	if not saved.ok:
		return
	var original := JSON.stringify(store.load_project().state)
	var scene: Control = await _open(path)
	_check(scene.get_account_texts().size() == 1 \
		and scene.get_account_texts()[0].contains("现金  CNY 5000") \
		and scene.get_account_texts()[0].contains("来源  手工") \
		and scene.get_holding_texts().is_empty(),
		"current ledger cash and account identity visible")
	_check(scene.get_summary_text().contains("待完整估值") and not _visible_text(scene).contains("总资产  CNY 5000"),
		"cash-only ledger total still requires complete valuation")
	_check(JSON.stringify(store.load_project().state) == original \
		and store.load_project().generation == saved.generation,
		"overview reads without writing ledger or generation")
	_close(scene)


func _test_mapped_cash(path: String) -> void:
	var opened := Personal.new(path).create_opening_cash("mapped-open", "cash", "现金账户",
		"50000", "1000", NOW)
	_check(opened.ok, "create personal cash mapping fixture")
	if not opened.ok:
		return
	var scene: Control = await _open(path)
	_check(scene.get_summary_text().contains("总资产  CNY 50000")
		and scene.get_status_text().contains("当前金豆映射"),
		"cash-only current mapping and ledger agree in overview")
	_close(scene)
	var store := Store.new(path)
	var before: Dictionary = store.load_project()
	var changed: Dictionary = before.state.duplicate(true)
	changed.valuation_pending = {"reason": "TEST_PENDING",
		"ledger_hash": Store.canonical_ledger_hash(changed.ledger)}
	var saved := store.save_project(changed, before.generation)
	scene = await _open(path)
	_check(saved.ok and scene.get_summary_text().contains("待完整估值")
		and not scene.get_summary_text().contains("50000"),
		"pending status cannot reuse cash mapping as current total")
	_close(scene)


func _test_restricted_balance(path: String) -> void:
	var opened := Personal.new(path).create_opening_cash("overview-restricted-start",
		"cash", "现金", "10000", "1000", NOW)
	_check(opened.ok, "restricted overview opening")
	if not opened.ok:
		return
	var commands := [
		{"command_id": "overview-restricted-account", "type": "account_create",
			"account": {"id": "provident", "name": "住房公积金", "currency": "CNY",
				"mode": "detail", "cost_method": "FIFO", "asset_kind": "PROVIDENT_FUND"}},
		{"command_id": "overview-restricted-balance", "type": "restricted_balance_set",
			"account_id": "provident", "amount": "2300.5",
			"source_note": "个人账户对账单", "effective_at": NOW},
	]
	var preview := Asset.new(path).preview(commands, opened.generation)
	var committed := Asset.new(path).confirm(commands, preview,
		{"confirmed": true, "preview_id": str(preview.get("preview_id", ""))})
	_check(preview.ok and committed.ok, "restricted overview account and balance saved")
	if not committed.ok:
		return
	var scene: Control = await _open(path)
	_check(scene.get_summary_text().contains("待完整估值") \
		and scene.get_account_texts().size() == 2 \
		and scene.get_account_texts()[1].contains("受限余额  CNY 2300.5") \
		and not scene.get_account_texts()[1].contains("现金  CNY 2300.5"),
		"overview shows restricted balance separately and withholds stale total")
	_close(scene)
	var flow := Revalue.new(path)
	var gold := {"kind": "GOLD", "market": "SPOT", "symbol": "XAU",
		"currency": "CNY", "share_class": ""}
	var entries := {}
	entries[Contract.identity_key(gold)] = {"price": "1000", "unit": "CURRENCY_PER_GRAM",
		"quoted_at": NOW, "source_note": "人工核对的测试数据"}
	var valuation_preview := flow.preview(entries, committed.generation, NOW)
	var valued := flow.confirm(entries, valuation_preview,
		{"confirmed": true, "preview_id": str(valuation_preview.get("preview_id", ""))}, NOW)
	_check(valuation_preview.ok and valued.ok and valued.asset_total == "12300.5",
		"full manual valuation includes restricted balance once")
	if not valued.ok:
		return
	scene = await _open(path)
	_check(scene.get_summary_text().contains("总资产  CNY 12300.5") \
		and scene.get_account_texts()[1].contains("住房公积金") \
		and scene.get_account_texts()[1].contains("受限余额  CNY 2300.5"),
		"overview displays current total only after complete restricted coverage")
	_close(scene)


func _test_holding_valuation_privacy_restart(path: String) -> void:
	var store := Store.new(path)
	var project := store.new_project()
	var commands := [
		{"command_id": "broker-account", "type": "account_create", "account": {
			"id": "broker", "name": "测试券商", "currency": "CNY", "mode": "detail", "cost_method": "FIFO"}},
		{"command_id": "opening-cash", "type": "opening_cash", "account_id": "broker",
			"amount": "5000", "effective_at": NOW},
		{"command_id": "stock", "type": "instrument_create", "instrument": {
			"id": "stock", "kind": "STOCK", "market": "TEST", "symbol": "ZZZ",
			"currency": "CNY", "share_class": ""}},
		{"command_id": "opening-position", "type": "opening_position", "account_id": "broker",
			"instrument_id": "stock", "quantity": "2", "reference_price": "100",
			"cost_basis": "200", "effective_at": NOW},
		{"command_id": "old-quote", "type": "quote_update", "quote": {
			"instrument_id": "stock", "price": "999", "quoted_at": NOW, "source": "old-test"}},
	]
	for command in commands:
		var applied := Ledger.apply(project.ledger, command)
		if not applied.ok:
			_check(false, "holding fixture command: " + str(applied.get("error", "")))
			return
		project.ledger = applied.state
	var seeded := store.save_project(project, 0)
	_check(seeded.ok, "security ledger saved before valuation")
	if not seeded.ok:
		return
	var scene: Control = await _open(path)
	_check(scene.get_holding_texts().size() == 1 \
		and scene.get_holding_texts()[0].contains("TEST:ZZZ") \
		and scene.get_holding_texts()[0].contains("数量  2") \
		and scene.get_account_texts()[0].contains("现金  CNY 5000"),
		"security identity, quantity and current cash come from ledger projection")
	_check(scene.get_summary_text().contains("待完整估值") \
		and not _visible_text(scene).contains("999") \
		and not _visible_text(scene).contains("估值  CNY"),
		"old ledger quote is not presented as current valuation")
	_close(scene)
	var identity := {"kind": "STOCK", "market": "TEST", "symbol": "ZZZ",
		"currency": "CNY", "share_class": ""}
	var key := Contract.identity_key(identity)
	var quote := {"id": "manual-stock", "identity": identity, "price": "200",
		"currency": "CNY", "unit": "CURRENCY_PER_SHARE", "source": "USER_MANUAL",
		"provider_symbol": "ZZZ", "quoted_at": NOW, "fetched_at": NOW,
		"delay": "MANUAL", "session": "MANUAL_INPUT"}
	var refresh := Gateway.refresh(project.quote_gateway, [identity],
		ManualProvider.new({key: quote}), NOW, "overview-batch")
	_check(refresh.ok and refresh.batch.status == "COMPLETE", "complete quote batch fixture")
	if not refresh.ok:
		return
	var valued := store.commit_quote_valuation(refresh,
		[{"position_id": "broker|stock", "identity": identity, "quantity": "2"}],
		[{"balance_id": "broker", "amount": "5000", "currency": "CNY"}],
		false, seeded.generation)
	_check(valued.ok and valued.snapshot.asset_total == "5400", "complete ledger-bound valuation saved")
	if not valued.ok:
		return
	scene = await _open(path)
	_check(scene.get_summary_text().contains("总资产  CNY 5400") \
		and scene.get_holding_texts()[0].contains("估值  CNY 400"),
		"exact current ledger match displays total and holding value")
	_close(scene)
	var incomplete_state: Dictionary = store.load_project().state
	incomplete_state.valuation.snapshots[valued.snapshot.id].position_values.clear()
	var incomplete_path := path + "-incomplete-snapshot"
	var incomplete_store := Store.new(incomplete_path)
	var incomplete_saved := incomplete_store.save_project(incomplete_state, 0)
	_check(incomplete_saved.ok, "isolated incomplete snapshot fixture saved")
	if incomplete_saved.ok:
		scene = await _open(incomplete_path)
		_check(scene.get_summary_text().contains("待完整估值") \
			and not _visible_text(scene).contains("5400") \
			and not _visible_text(scene).contains("估值  CNY 400"),
			"matching hash alone cannot certify incomplete holding coverage")
		_close(scene)
	var private_current: Dictionary = store.load_project().state
	private_current.presentation.privacy_mode = "hide_total"
	var private_current_path := path + "-private-current"
	var private_current_saved := Store.new(private_current_path).save_project(private_current, 0)
	_check(private_current_saved.ok, "isolated current-valuation privacy fixture saved")
	if private_current_saved.ok:
		scene = await _open(private_current_path)
		var current_private_text := _visible_text(scene)
		_check(current_private_text.contains("隐私模式") and not current_private_text.contains("5400") \
			and not current_private_text.contains("5000") and not current_private_text.contains("400") \
			and not current_private_text.contains("ZZZ") \
			and scene.get_holding_texts().is_empty(),
			"privacy hides current confirmed valuation and exact holding details")
		_close(scene)
	var changed: Dictionary = store.load_project().state
	var change := Ledger.apply(changed.ledger, {"command_id": "new-cash",
		"type": "cash_delta", "account_id": "broker", "delta": "100",
		"external": true, "effective_at": NOW})
	_check(change.ok, "ledger change fixture")
	if not change.ok:
		return
	changed.ledger = change.state
	changed.valuation_pending = {"reason": "LEDGER_CHANGED",
		"ledger_hash": Store.canonical_ledger_hash(changed.ledger)}
	var changed_save := store.save_project(changed, valued.generation)
	_check(changed_save.ok, "changed ledger saved with pending valuation marker")
	if not changed_save.ok:
		return
	scene = await _open(path)
	_check(scene.get_summary_text().contains("待完整估值") \
		and scene.get_account_texts()[0].contains("现金  CNY 5100") \
		and not _visible_text(scene).contains("5400") \
		and not _visible_text(scene).contains("估值  CNY 400"),
		"old complete snapshot becomes pending after ledger hash changes")
	_close(scene)
	changed = store.load_project().state
	changed.presentation.privacy_mode = "hide_total"
	var private_save := store.save_project(changed, changed_save.generation)
	_check(private_save.ok, "privacy preference saved")
	if not private_save.ok:
		return
	var private_before := JSON.stringify(store.load_project().state)
	scene = await _open(path)
	var private_text := _visible_text(scene)
	_check(scene.get_account_texts().is_empty() and scene.get_holding_texts().is_empty() \
		and private_text.contains("隐私模式") and not private_text.contains("5000") \
		and not private_text.contains("5100") and not private_text.contains("5400") \
		and not private_text.contains("ZZZ"),
		"privacy mode hides amounts, precise quantities and user-entered identities")
	_close(scene)
	scene = await _open(path)
	_check(_visible_text(scene) == private_text and scene.get_generation() == private_save.generation \
		and JSON.stringify(store.load_project().state) == private_before,
		"privacy survives scene restart without a project write")
	_close(scene)


func _test_demo_rejected(path: String) -> void:
	var store := Store.new(path)
	var state := store.new_project()
	state.data_kind = "demo"
	var saved := store.save_project(state, 0)
	_check(saved.ok, "demo state test fixture saved")
	var scene: Control = await _open(path)
	_check(scene.get_status_text().contains("不是个人账本") \
		and scene.get_account_texts().is_empty() and scene.get_holding_texts().is_empty(),
		"overview refuses isolated demo state")
	_close(scene)
