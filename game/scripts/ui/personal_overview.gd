extends Control
## Read-only account and holding overview from one saved personal ProjectStore generation.
## Current totals and holding values require a complete, ledger-bound valuation snapshot.

const Store = preload("res://scripts/data/project_store.gd")
const Ledger = preload("res://scripts/data/ledger_core.gd")
const Decimal = preload("res://scripts/data/decimal_text.gd")
const Display = preload("res://scripts/data/display_snapshot_service.gd")
const DEFAULT_PATH := "user://personal/moneybox"

@export var base_path := DEFAULT_PATH

var _summary_label: Label
var _status_label: Label
var _detail_box: VBoxContainer
var _return_button: Button
var _account_texts: Array[String] = []
var _holding_texts: Array[String] = []
var _generation := 0


func _ready() -> void:
	if base_path == DEFAULT_PATH:
		var test_path := OS.get_environment("MONEYBOX_PERSONAL_STATE_PATH")
		if not test_path.is_empty():
			base_path = test_path
	_build_ui()
	refresh()


func refresh() -> void:
	_clear_details()
	_summary_label.text = "总资产：待完整估值"
	_status_label.text = "正在读取已保存的个人账本…"
	var store := Store.new(base_path)
	var loaded := store.load_project()
	if not loaded.ok:
		_status_label.text = "个人账本读取失败；未显示任何金额。"
		return
	_generation = int(loaded.generation)
	if loaded.state.get("data_kind", "") != "personal":
		_status_label.text = "当前状态不是个人账本；未显示任何金额。"
		return
	if _generation == 0:
		_status_label.text = "尚未保存个人账本；请先记录第一笔资产。"
		return
	var project: Dictionary = loaded.state
	var ledger: Dictionary = project.ledger
	var projected := Ledger.project(ledger)
	if not projected.ok:
		_status_label.text = "账本投影失败；未显示任何金额。"
		return
	var private_mode := str(project.get("presentation", {}).get("privacy_mode", "hide_total")) != "show_total"
	var valuation := _current_complete_valuation(store, project)
	var mapped_cash := _current_cash_mapping(project, projected, _generation)
	if private_mode:
		_summary_label.text = "隐私模式已启用"
		_status_label.text = "金额、证券身份和精确持仓数量已隐藏。"
		_add_detail(_label("账户与持仓明细已隐藏。", 16, Color("665d50")))
		return
	if valuation.ok:
		var snapshot: Dictionary = valuation.snapshot
		_summary_label.text = "总资产  %s %s" % [snapshot.base_currency, snapshot.asset_total]
		_status_label.text = "最近完整估值 · 已匹配当前账本版本"
	elif mapped_cash.ok:
		_summary_label.text = "总资产  %s %s" % [mapped_cash.currency, mapped_cash.amount]
		_status_label.text = "纯现金账本 · 已匹配当前金豆映射"
	else:
		_summary_label.text = "总资产：待完整估值"
		_status_label.text = "现金与持仓来自当前账本；证券市值和总资产待重估。"
	_render_accounts(ledger, projected, valuation)


func get_summary_text() -> String:
	return _summary_label.text


func get_status_text() -> String:
	return _status_label.text


func get_account_texts() -> Array[String]:
	return _account_texts.duplicate()


func get_holding_texts() -> Array[String]:
	return _holding_texts.duplicate()


func get_return_button() -> Button:
	return _return_button


func get_generation() -> int:
	return _generation


func _current_complete_valuation(store: RefCounted, project: Dictionary) -> Dictionary:
	var valuation: Dictionary = project.get("valuation", {})
	var snapshots: Dictionary = valuation.get("snapshots", {})
	var best: Dictionary = {}
	var best_revision := -1
	for snapshot_id in snapshots:
		var checked: Dictionary = store.current_valuation_snapshot(project, str(snapshot_id))
		if not checked.ok or not _complete_snapshot_rows(store, project, checked.snapshot):
			continue
		var revision := int(checked.snapshot.get("revision", -1))
		if revision > best_revision:
			best = checked.snapshot
			best_revision = revision
	if best.is_empty():
		return {"ok": false}
	return {"ok": true, "snapshot": best}


func _current_cash_mapping(project: Dictionary, projected: Dictionary,
		generation: int) -> Dictionary:
	var ledger: Dictionary = project.ledger
	if not ledger.instruments.is_empty() or not projected.positions.is_empty() or \
			not projected.restricted_balances.is_empty() \
			or not projected.incomplete.is_empty() or project.mappings.is_empty():
		return {"ok": false}
	var currency := str(ledger.base_currency)
	for account in ledger.accounts.values():
		if str(account.get("currency", "")) != currency:
			return {"ok": false}
	var display := Display.build(project, generation)
	if not display.ok or display.snapshot.snapshot_status != "CURRENT" \
			or not display.snapshot.has("display_amount") \
			or str(display.snapshot.get("display_currency", "")) != currency \
			or Decimal.compare(str(display.snapshot.display_amount),
				str(projected.asset_total)) != 0:
		return {"ok": false}
	return {"ok": true, "amount": str(display.snapshot.display_amount),
		"currency": currency}


func _complete_snapshot_rows(store: RefCounted, project: Dictionary, snapshot: Dictionary) -> bool:
	var position_rows: Variant = snapshot.get("position_values", null)
	var cash_rows: Variant = snapshot.get("cash_values", null)
	var restricted_rows: Variant = snapshot.get("restricted_values", [])
	if typeof(position_rows) != TYPE_ARRAY or typeof(cash_rows) != TYPE_ARRAY or \
			typeof(restricted_rows) != TYPE_ARRAY:
		return false
	var positions := []
	var cash := []
	var restricted := []
	var sum := "0"
	for raw in position_rows:
		if typeof(raw) != TYPE_DICTIONARY or \
				typeof(raw.get("instrument_identity")) != TYPE_DICTIONARY or \
				typeof(raw.get("quantity")) != TYPE_STRING or \
				typeof(raw.get("base_value")) != TYPE_STRING or \
				not Decimal.is_valid(raw.base_value):
			return false
		positions.append({"position_id": raw.get("position_id", ""),
			"identity": raw.instrument_identity, "quantity": raw.quantity})
		sum = Decimal.add(sum, raw.base_value)
	for raw in cash_rows:
		if typeof(raw) != TYPE_DICTIONARY or typeof(raw.get("amount")) != TYPE_STRING \
				or typeof(raw.get("base_value")) != TYPE_STRING or \
				not Decimal.is_valid(raw.base_value):
			return false
		cash.append({"balance_id": raw.get("balance_id", ""),
			"amount": raw.amount, "currency": raw.get("currency", "")})
		sum = Decimal.add(sum, raw.base_value)
	for raw in restricted_rows:
		if typeof(raw) != TYPE_DICTIONARY or typeof(raw.get("amount")) != TYPE_STRING \
				or typeof(raw.get("base_value")) != TYPE_STRING or \
				not Decimal.is_valid(raw.base_value):
			return false
		restricted.append({"balance_id": raw.get("balance_id", ""),
			"amount": raw.amount, "currency": raw.get("currency", "")})
		sum = Decimal.add(sum, raw.base_value)
	return store.validate_valuation_coverage(project.ledger, positions, cash,
		restricted).ok \
		and Decimal.compare(sum, str(snapshot.asset_total)) == 0


func _render_accounts(ledger: Dictionary, projected: Dictionary, valuation: Dictionary) -> void:
	var account_ids: Array = ledger.accounts.keys()
	account_ids.sort()
	if account_ids.is_empty():
		_add_detail(_label("还没有账户。", 16, Color("665d50")))
		return
	var position_values := {}
	if valuation.ok:
		for row in valuation.snapshot.position_values:
			position_values[str(row.position_id)] = row
	for account_id in account_ids:
		var account: Dictionary = ledger.accounts[account_id]
		var account_name := str(account.get("name", ""))
		if account_name.is_empty():
			account_name = str(account_id)
		var currency := str(account.get("currency", ""))
		var asset_kind := str(account.get("asset_kind", "CASH"))
		var category := "住房公积金" if asset_kind == "PROVIDENT_FUND" else \
			"养老金" if asset_kind == "PENSION" else "现金账户"
		var row_text := "%s · %s · %s" % [account_name, currency, category]
		if projected.replaced_accounts.has(account_id):
			row_text += "\n已由明细账户替代"
		else:
			if projected.restricted_balances.has(account_id):
				row_text += "\n受限余额  %s %s" % [currency,
					str(projected.restricted_balances[account_id])]
			else:
				row_text += "\n现金  %s %s" % [currency,
					str(projected.cash.get(account_id, "0"))]
		var source := str(account.get("source", ""))
		var custodian := str(account.get("custodian", ""))
		if not source.is_empty():
			row_text += "\n来源  " + source
		if not custodian.is_empty():
			row_text += "\n托管  " + custodian
		_account_texts.append(row_text)
		_add_detail(_card(row_text))
		var position_keys: Array = projected.positions.keys()
		position_keys.sort()
		for key in position_keys:
			var position: Dictionary = projected.positions[key]
			if position.account_id != account_id or position.quantity == "0" \
				or projected.replaced_accounts.has(account_id):
				continue
			var instrument: Dictionary = ledger.instruments[position.instrument_id]
			var kind := str(instrument.get("kind", "证券"))
			var market := str(instrument.get("market", ""))
			var symbol := str(instrument.get("symbol", ""))
			var share_class := str(instrument.get("share_class", ""))
			var title := "%s  %s:%s" % [kind, market, symbol]
			if not share_class.is_empty():
				title += " / " + share_class
			var text_value := "%s\n数量  %s · %s" % [title, position.quantity,
				str(instrument.get("currency", ""))]
			if valuation.ok and position_values.has(key):
				text_value += "\n估值  %s %s" % [valuation.snapshot.base_currency,
					str(position_values[key].base_value)]
			_holding_texts.append(text_value)
			_add_detail(_card(text_value))


func _clear_details() -> void:
	_account_texts.clear()
	_holding_texts.clear()
	for child in _detail_box.get_children():
		_detail_box.remove_child(child)
		child.free()


func _add_detail(node: Control) -> void:
	_detail_box.add_child(node)


func _build_ui() -> void:
	var background := ColorRect.new()
	background.color = Color("faf7f0")
	background.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(background)
	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	for side in ["left", "right"]:
		margin.add_theme_constant_override("margin_" + side, 24)
	margin.add_theme_constant_override("margin_top", 24)
	margin.add_theme_constant_override("margin_bottom", 24)
	add_child(margin)
	var column := VBoxContainer.new()
	column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	column.size_flags_vertical = Control.SIZE_EXPAND_FILL
	column.add_theme_constant_override("separation", 12)
	margin.add_child(column)
	var heading := HBoxContainer.new()
	column.add_child(heading)
	_return_button = Button.new()
	_return_button.text = "返回金豆罐"
	_return_button.custom_minimum_size.y = 42.0
	_return_button.add_theme_font_size_override("font_size", 15)
	_return_button.add_theme_color_override("font_color", Color("34312c"))
	var back_style := StyleBoxFlat.new()
	back_style.bg_color = Color("f1e5cf")
	back_style.set_corner_radius_all(10)
	_return_button.add_theme_stylebox_override("normal", back_style)
	_return_button.pressed.connect(func() -> void:
		get_tree().change_scene_to_file("res://scenes/personal_main.tscn"))
	heading.add_child(_return_button)
	var title := _label("总览与账户", 27, Color("34312c"))
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	heading.add_child(title)
	_summary_label = _label("", 20, Color("493d2b"))
	column.add_child(_summary_label)
	_status_label = _label("", 14, Color("665d50"))
	column.add_child(_status_label)
	var scroll := ScrollContainer.new()
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	column.add_child(scroll)
	_detail_box = VBoxContainer.new()
	_detail_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_detail_box.add_theme_constant_override("separation", 10)
	scroll.add_child(_detail_box)


func _card(value: String) -> PanelContainer:
	var panel := PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.bg_color = Color("fffdfa")
	style.border_color = Color("e8decc")
	style.set_border_width_all(1)
	style.set_corner_radius_all(12)
	style.set_content_margin_all(12)
	panel.add_theme_stylebox_override("panel", style)
	panel.add_child(_label(value, 16, Color("403c36")))
	return panel


func _label(value: String, size: int, color: Color) -> Label:
	var label := Label.new()
	label.text = value
	label.add_theme_font_size_override("font_size", size)
	label.add_theme_color_override("font_color", color)
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	return label
