extends SceneTree
## Desktop visual evidence from synthetic local-only data; no Android claim.

const Personal = preload("res://scripts/data/personal_flow.gd")
const Asset = preload("res://scripts/data/personal_asset_flow.gd")
const Revalue = preload("res://scripts/quotes/personal_manual_revaluation_flow.gd")
const Contract = preload("res://scripts/quotes/quote_contract.gd")

const AT := "2026-09-27T02:00:00Z"


func _initialize() -> void:
	call_deferred("_capture")


func _capture() -> void:
	var project_dir := ProjectSettings.globalize_path("res://project.godot").get_base_dir().get_base_dir()
	var test_dir := project_dir.path_join("tests/tmp")
	var evidence_dir := project_dir.path_join("docs/evidence")
	DirAccess.make_dir_recursive_absolute(test_dir)
	DirAccess.make_dir_recursive_absolute(evidence_dir)
	var path := test_dir.path_join("restricted-pages-" + str(Time.get_ticks_usec()))
	var opening := Personal.new(path).create_opening_cash("visual-start", "cash",
		"现金", "10000", "1000", AT)
	if not opening.ok:
		printerr("RESTRICTED_CAPTURE_SETUP_FAILED: ", opening)
		quit(1)
		return
	var commands := [
		{"command_id": "visual-account", "type": "account_create",
			"account": {"id": "provident", "name": "住房公积金", "currency": "CNY",
				"mode": "detail", "cost_method": "FIFO", "asset_kind": "PROVIDENT_FUND"}},
		{"command_id": "visual-balance", "type": "restricted_balance_set",
			"account_id": "provident", "amount": "2300.5",
			"source_note": "个人账户对账单", "effective_at": AT},
	]
	var preview := Asset.new(path).preview(commands, opening.generation)
	var saved := Asset.new(path).confirm(commands, preview,
		{"confirmed": true, "preview_id": str(preview.get("preview_id", ""))})
	if not saved.ok:
		printerr("RESTRICTED_CAPTURE_ASSET_FAILED: ", saved)
		quit(1)
		return
	OS.set_environment("MONEYBOX_PERSONAL_STATE_PATH", path)
	var asset_page: Control = load("res://scenes/personal_asset_entry.tscn").instantiate()
	root.add_child(asset_page)
	await process_frame
	var mode: OptionButton = asset_page.get_picker("mode")
	for index in mode.item_count:
		if str(mode.get_item_metadata(index)) == "restricted_balance_set":
			mode.select(index)
			mode.item_selected.emit(index)
			break
	var account: OptionButton = asset_page.get_picker("restricted_account")
	for index in account.item_count:
		if str(account.get_item_metadata(index)) == "provident":
			account.select(index)
			account.item_selected.emit(index)
			break
	asset_page.get_input("restricted_amount").text = "2500.5"
	asset_page.get_input("restricted_source").text = "更新的个人账户对账单"
	asset_page.get_input("restricted_at").text = AT
	asset_page.get_preview_button().pressed.emit()
	await create_timer(0.5).timeout
	if not _save(evidence_dir.path_join("finance_desktop_restricted_entry.png")):
		return
	asset_page.queue_free()
	await process_frame
	var revalue: Control = load("res://scenes/personal_manual_revaluation.tscn").instantiate()
	root.add_child(revalue)
	await process_frame
	var gold := {"kind": "GOLD", "market": "SPOT", "symbol": "XAU",
		"currency": "CNY", "share_class": ""}
	var key := Contract.identity_key(gold)
	var fields: Dictionary = revalue.get_quote_fields(key)
	fields.price.text = "1000"
	fields.quoted_at.text = AT
	fields.source_note.text = "人工核对的测试数据"
	fields.unit.select(1)
	revalue.get_at_input().text = AT
	revalue.get_preview_button().pressed.emit()
	await create_timer(0.5).timeout
	if not _save(evidence_dir.path_join("finance_desktop_restricted_revaluation.png")):
		return
	var scrolls := revalue.find_children("*", "ScrollContainer", true, false)
	if not scrolls.is_empty():
		var scroll: ScrollContainer = scrolls[0]
		scroll.scroll_vertical = int(scroll.get_v_scroll_bar().max_value)
		await create_timer(0.3).timeout
		if not _save(evidence_dir.path_join("finance_desktop_restricted_revaluation_bottom.png")):
			return
	revalue.queue_free()
	await process_frame
	var entries := {}
	entries[key] = {"price": "1000", "unit": "CURRENCY_PER_GRAM",
		"quoted_at": AT, "source_note": "人工核对的测试数据"}
	var value_preview := Revalue.new(path).preview(entries, saved.generation, AT)
	var valued := Revalue.new(path).confirm(entries, value_preview,
		{"confirmed": true, "preview_id": str(value_preview.get("preview_id", ""))}, AT)
	if not valued.ok:
		printerr("RESTRICTED_CAPTURE_VALUATION_FAILED: ", valued)
		quit(1)
		return
	var overview: Control = load("res://scenes/personal_overview.tscn").instantiate()
	root.add_child(overview)
	await create_timer(0.5).timeout
	if not _save(evidence_dir.path_join("finance_desktop_restricted_overview.png")):
		return
	overview.queue_free()
	print("RESTRICTED_DESKTOP_CAPTURE_PASS: 3 pages, 4 images")
	quit(0)


func _save(path: String) -> bool:
	var error := root.get_texture().get_image().save_png(path)
	if error != OK:
		printerr("RESTRICTED_CAPTURE_FAILED: ", path, " error=", error)
		quit(1)
		return false
	print("CAPTURED ", path)
	return true
