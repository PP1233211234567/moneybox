extends Control
## P06 read-only ledger history. Events are shown by booking sequence, with effective date explicit.

const Store = preload("res://scripts/data/project_store.gd")
const Ledger = preload("res://scripts/data/ledger_core.gd")
const DEFAULT_PATH := "user://personal/moneybox"
const RETURN_SCENE := "res://scenes/personal_main.tscn"
const MAX_ROWS := 100
const TYPE_NAMES := {
	"opening_cash": "期初现金", "cash_delta": "现金变动", "transfer": "内部转账",
	"restricted_balance_set": "公积金 / 养老金余额检查点",
	"opening_position": "期初持仓", "buy": "买入", "sell": "卖出",
	"dividend_suggest": "派息建议", "dividend_confirm": "派息确认",
	"void": "冲销", "aggregate_replaced": "汇总余额替代",
}

@export var base_path := DEFAULT_PATH

var _store: RefCounted
var _status_label: Label
var _detail_label: Label
var _rows_box: VBoxContainer
var _search_input: LineEdit
var _account_picker: OptionButton
var _back_button: Button
var _row_buttons: Array[Button] = []
var _row_texts: Array[String] = []
var _generation := 0


func _ready() -> void:
	if base_path == DEFAULT_PATH:
		var test_path := OS.get_environment("MONEYBOX_PERSONAL_STATE_PATH")
		if not test_path.is_empty():
			base_path = test_path
	_store = Store.new(base_path)
	_build_ui()
	refresh()


func get_status_text() -> String:
	return _status_label.text


func get_detail_text() -> String:
	return _detail_label.text


func get_row_texts() -> Array[String]:
	return _row_texts.duplicate()


func get_row_buttons() -> Array[Button]:
	return _row_buttons.duplicate()


func get_search_input() -> LineEdit:
	return _search_input


func get_account_picker() -> OptionButton:
	return _account_picker


func get_back_button() -> Button:
	return _back_button


func get_generation() -> int:
	return _generation


func refresh() -> void:
	_clear_rows()
	_detail_label.text = "选择流水查看已保存的字段。这里不修改账本；更正需另走确认流程。"
	_status_label.text = "正在读取已保存的个人账本…"
	var loaded: Dictionary = _store.load_project()
	if not loaded.ok:
		_status_label.text = "个人账本读取失败；未显示流水。"
		return
	_generation = int(loaded.generation)
	if loaded.state.get("data_kind", "") != "personal":
		_status_label.text = "当前不是个人项目；未显示流水。"
		return
	if _generation == 0:
		_status_label.text = "尚未保存个人账本。"
		return
	var project: Dictionary = loaded.state
	var ledger: Dictionary = project.get("ledger", {})
	var projected: Dictionary = Ledger.project(ledger)
	if not projected.ok:
		_status_label.text = "账本投影失败；未显示流水。"
		return
	var private_mode := str(project.get("presentation", {}).get("privacy_mode", "hide_total")) != "show_total"
	if private_mode:
		_status_label.text = "隐私模式已启用；流水内容和搜索已隐藏。"
		_search_input.editable = false
		_account_picker.disabled = true
		return
	_search_input.editable = true
	_account_picker.disabled = false
	_update_accounts(ledger)
	var selected_account := str(_account_picker.get_item_metadata(_account_picker.selected))
	var query := _search_input.text.strip_edges().to_lower()
	var events: Array = ledger.get("events", [])
	var voided := {}
	for raw in events:
		if typeof(raw) == TYPE_DICTIONARY and raw.get("type", "") == "void":
			voided[str(raw.get("target_event_id", ""))] = true
	var matched := 0
	for index in range(events.size() - 1, -1, -1):
		var raw: Variant = events[index]
		if typeof(raw) != TYPE_DICTIONARY:
			continue
		var event: Dictionary = raw
		var account_id := str(event.get("account_id", ""))
		var destination_id := str(event.get("to_account_id", ""))
		if not selected_account.is_empty() and selected_account != account_id \
				and selected_account != destination_id:
			continue
		var account_name := _account_name(ledger, account_id)
		var instrument_name := _instrument_name(ledger, str(event.get("instrument_id", "")))
		var type_name := str(TYPE_NAMES.get(str(event.get("type", "")), "其他记录"))
		var searchable := "%s %s %s %s %s %s" % [account_name, instrument_name, type_name,
			str(event.get("id", "")), account_id, str(event.get("effective_at", ""))]
		if not query.is_empty() and not searchable.to_lower().contains(query):
			continue
		matched += 1
		if _row_buttons.size() >= MAX_ROWS:
			continue
		var summary := "#%s · %s%s\n生效 %s · %s" % [str(event.get("sequence", "?")),
			type_name, " · 已冲销" if voided.has(str(event.get("id", ""))) else "",
			str(event.get("effective_at", "")), account_name]
		if not instrument_name.is_empty():
			summary += " · " + instrument_name
		var detail := _detail(ledger, event, voided.has(str(event.get("id", ""))))
		var button := _button(summary)
		_rows_box.add_child(button)
		button.pressed.connect(func() -> void: _detail_label.text = detail)
		_row_buttons.append(button)
		_row_texts.append(summary)
	if matched == 0:
		_status_label.text = "当前条件下没有流水。"
	else:
		_status_label.text = "个人项目第 %d 版 · 共 %d 条匹配流水，按入账序号倒序%s。" % [
			_generation, matched, "，仅显示最近 100 条" if matched > MAX_ROWS else ""]


func _update_accounts(ledger: Dictionary) -> void:
	var selected_id := ""
	if _account_picker.item_count > 0 and _account_picker.selected >= 0:
		selected_id = str(_account_picker.get_item_metadata(_account_picker.selected))
	_account_picker.clear()
	_account_picker.add_item("全部账户")
	_account_picker.set_item_metadata(0, "")
	var account_ids: Array = ledger.get("accounts", {}).keys()
	account_ids.sort()
	for account_id in account_ids:
		var index := _account_picker.item_count
		_account_picker.add_item(_account_name(ledger, str(account_id)))
		_account_picker.set_item_metadata(index, str(account_id))
		if selected_id == str(account_id):
			_account_picker.select(index)
	if _account_picker.selected < 0:
		_account_picker.select(0)


func _detail(ledger: Dictionary, event: Dictionary, was_voided: bool) -> String:
	var lines: Array[String] = []
	lines.append("%s · 第 %s 条%s" % [str(TYPE_NAMES.get(str(event.get("type", "")), "其他记录")),
		str(event.get("sequence", "?")), " · 已冲销，不计入当前投影" if was_voided else ""])
	lines.append("事件 ID：" + str(event.get("id", "")))
	lines.append("生效时间：" + str(event.get("effective_at", "")))
	var account_id := str(event.get("account_id", ""))
	if not account_id.is_empty():
		lines.append("账户：" + _account_name(ledger, account_id))
	var destination_id := str(event.get("to_account_id", ""))
	if not destination_id.is_empty():
		lines.append("转入：" + _account_name(ledger, destination_id))
	var instrument_id := str(event.get("instrument_id", ""))
	if not instrument_id.is_empty():
		lines.append("资产：" + _instrument_name(ledger, instrument_id))
	var currency := ""
	if ledger.get("accounts", {}).has(account_id):
		currency = str(ledger.accounts[account_id].get("currency", ""))
	for field in ["amount", "delta", "quantity", "unit_price", "fee", "cost_basis",
			"reference_price", "gross_amount", "withholding_tax", "net_cash"]:
		if event.has(field) and not str(event[field]).is_empty():
			var suffix := " " + currency if field != "quantity" and not currency.is_empty() else ""
			lines.append("%s：%s%s" % [_field_name(field), str(event[field]), suffix])
	if event.get("external", false):
		lines.append("分类：外部资金流")
	if event.has("target_event_id"):
		lines.append("冲销目标：" + str(event.target_event_id))
	if event.has("replaces_event_id"):
		lines.append("替代原事件：" + str(event.replaces_event_id))
	if event.has("suggestion_event_id"):
		lines.append("派息建议来源：" + str(event.suggestion_event_id))
	if event.has("source_note"):
		lines.append("余额依据：" + str(event.source_note))
	if event.get("type", "") == "restricted_balance_set":
		lines.append("此余额替代该账户此前检查点；不推算缴存、利息或收益。")
	lines.append("这是已保存流水字段；行情与当前市值不从成交价推断。")
	return "\n".join(lines)


func _field_name(field: String) -> String:
	return str({"amount": "金额", "delta": "现金增减", "quantity": "数量", "unit_price": "成交单价",
		"fee": "费用", "cost_basis": "期初成本", "reference_price": "期初参考价",
		"gross_amount": "税前金额", "withholding_tax": "预扣税", "net_cash": "净到账"}.get(field, field))


func _account_name(ledger: Dictionary, account_id: String) -> String:
	if ledger.get("accounts", {}).has(account_id):
		var name := str(ledger.accounts[account_id].get("name", ""))
		return name if not name.is_empty() else account_id
	return account_id


func _instrument_name(ledger: Dictionary, instrument_id: String) -> String:
	if instrument_id.is_empty():
		return ""
	if ledger.get("instruments", {}).has(instrument_id):
		var instrument: Dictionary = ledger.instruments[instrument_id]
		return "%s:%s" % [str(instrument.get("market", "")), str(instrument.get("symbol", ""))]
	return instrument_id


func _clear_rows() -> void:
	_row_buttons.clear()
	_row_texts.clear()
	for child in _rows_box.get_children():
		_rows_box.remove_child(child)
		child.free()


func _build_ui() -> void:
	var background := ColorRect.new()
	background.color = Color("faf7f0")
	background.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(background)
	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	margin.add_theme_constant_override("margin_left", 22)
	margin.add_theme_constant_override("margin_right", 22)
	margin.add_theme_constant_override("margin_top", 24)
	margin.add_theme_constant_override("margin_bottom", 24)
	add_child(margin)
	var column := VBoxContainer.new()
	column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	column.size_flags_vertical = Control.SIZE_EXPAND_FILL
	column.add_theme_constant_override("separation", 10)
	margin.add_child(column)
	column.add_child(_label("流水记录", 27, Color("34312c")))
	_back_button = _button("返回个人金豆罐")
	_back_button.pressed.connect(func() -> void: get_tree().change_scene_to_file(RETURN_SCENE))
	column.add_child(_back_button)
	_status_label = _label("", 14, Color("665d50"))
	column.add_child(_status_label)
	_search_input = LineEdit.new()
	_search_input.placeholder_text = "搜索账户、资产、类型、日期或事件 ID"
	_search_input.add_theme_color_override("font_color", Color("34312c"))
	_search_input.add_theme_color_override("font_placeholder_color", Color("776c5c"))
	_search_input.add_theme_color_override("font_uneditable_color", Color("776c5c"))
	var input_style := StyleBoxFlat.new()
	input_style.bg_color = Color("fffdfa")
	input_style.border_color = Color("d7c6a9")
	input_style.set_border_width_all(1)
	input_style.set_corner_radius_all(9)
	input_style.set_content_margin_all(10)
	_search_input.add_theme_stylebox_override("normal", input_style)
	_search_input.add_theme_stylebox_override("focus", input_style)
	var disabled_input := input_style.duplicate()
	disabled_input.bg_color = Color("eee9e0")
	_search_input.add_theme_stylebox_override("read_only", disabled_input)
	_search_input.text_changed.connect(func(_value: String) -> void: refresh())
	column.add_child(_search_input)
	_account_picker = OptionButton.new()
	_account_picker.add_theme_color_override("font_color", Color("34312c"))
	_account_picker.add_theme_color_override("font_hover_color", Color("332b23"))
	_account_picker.add_theme_color_override("font_pressed_color", Color("332b23"))
	_account_picker.add_theme_color_override("font_disabled_color", Color("6d6459"))
	var picker_style := input_style.duplicate()
	picker_style.bg_color = Color("f1e7d5")
	_account_picker.add_theme_stylebox_override("normal", picker_style)
	var picker_hover := picker_style.duplicate()
	picker_hover.bg_color = Color("e9d8bc")
	_account_picker.add_theme_stylebox_override("hover", picker_hover)
	_account_picker.add_theme_stylebox_override("pressed", picker_hover)
	_account_picker.add_theme_stylebox_override("disabled", disabled_input)
	_account_picker.item_selected.connect(func(_index: int) -> void: refresh())
	column.add_child(_account_picker)
	var scroll := ScrollContainer.new()
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	column.add_child(scroll)
	_rows_box = VBoxContainer.new()
	_rows_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_rows_box.add_theme_constant_override("separation", 8)
	scroll.add_child(_rows_box)
	var detail_panel := PanelContainer.new()
	var panel_style := StyleBoxFlat.new()
	panel_style.bg_color = Color("fffdfa")
	panel_style.border_color = Color("e8decc")
	panel_style.set_border_width_all(1)
	panel_style.set_corner_radius_all(10)
	panel_style.set_content_margin_all(12)
	detail_panel.add_theme_stylebox_override("panel", panel_style)
	detail_panel.custom_minimum_size.y = 170
	column.add_child(detail_panel)
	_detail_label = _label("", 14, Color("4b4237"))
	detail_panel.add_child(_detail_label)


func _button(value: String) -> Button:
	var button := Button.new()
	button.text = value
	button.alignment = HORIZONTAL_ALIGNMENT_LEFT
	button.custom_minimum_size.y = 48
	button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	button.add_theme_font_size_override("font_size", 15)
	button.add_theme_color_override("font_color", Color("40372d"))
	button.add_theme_color_override("font_hover_color", Color("332b23"))
	button.add_theme_color_override("font_pressed_color", Color("332b23"))
	var style := StyleBoxFlat.new()
	style.bg_color = Color("f1e7d5")
	style.set_corner_radius_all(9)
	style.set_content_margin_all(9)
	button.add_theme_stylebox_override("normal", style)
	var hover := style.duplicate()
	hover.bg_color = Color("e9d8bc")
	button.add_theme_stylebox_override("hover", hover)
	return button


func _label(value: String, size: int, color: Color) -> Label:
	var label := Label.new()
	label.text = value
	label.add_theme_font_size_override("font_size", size)
	label.add_theme_color_override("font_color", color)
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return label
