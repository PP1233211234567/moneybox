extends Control
## User-entered local quotes. No price or source is inferred from old trades or cache.

signal revaluation_confirmed(result: Dictionary)
signal return_to_jar_requested

const Revalue = preload("res://scripts/quotes/personal_manual_revaluation_flow.gd")
const Store = preload("res://scripts/data/project_store.gd")
const Contract = preload("res://scripts/quotes/quote_contract.gd")
const Display = preload("res://scripts/data/display_snapshot_service.gd")
const DEFAULT_PATH := "user://personal/moneybox"

@export var base_path := DEFAULT_PATH

var _flow: RefCounted
var _store: RefCounted
var _requirements: Dictionary = {}
var _quote_fields: Dictionary = {}
var _shown_preview: Dictionary = {}
var _privacy_mode := "show_total"
var _status_label: Label
var _preview_label: Label
var _quote_list: VBoxContainer
var _at_input: LineEdit
var _preview_button: Button
var _confirm_button: Button
var _refresh_button: Button
var _return_button: Button


func _ready() -> void:
	if base_path == DEFAULT_PATH:
		var test_path := OS.get_environment("MONEYBOX_PERSONAL_STATE_PATH")
		if not test_path.is_empty():
			base_path = test_path
	_store = Store.new(base_path)
	_flow = Revalue.new(base_path)
	_build_ui()
	_load_requirements()


func get_quote_fields(key: String) -> Dictionary:
	return _quote_fields.get(key, {})


func get_required_keys() -> Array[String]:
	var keys: Array[String] = []
	for key in _quote_fields:
		keys.append(str(key))
	keys.sort()
	return keys


func get_at_input() -> LineEdit:
	return _at_input


func get_preview_button() -> Button:
	return _preview_button


func get_confirm_button() -> Button:
	return _confirm_button


func get_return_button() -> Button:
	return _return_button


func get_preview_text() -> String:
	return _preview_label.text


func get_status_text() -> String:
	return _status_label.text


func _build_ui() -> void:
	var background := ColorRect.new()
	background.color = Color("faf7f0")
	background.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(background)
	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	for side in ["left", "right"]:
		margin.add_theme_constant_override("margin_" + side, 24)
	margin.add_theme_constant_override("margin_top", 30)
	margin.add_theme_constant_override("margin_bottom", 30)
	add_child(margin)
	var scroll := ScrollContainer.new()
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	margin.add_child(scroll)
	var content := VBoxContainer.new()
	content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content.add_theme_constant_override("separation", 12)
	scroll.add_child(content)
	content.add_child(_label("手工估值与金豆重算", 27))
	content.add_child(_label("逐项核对证券、汇率与黄金身份，并录入自己的报价来源。所有价格留空待填写。", 15))
	_status_label = _label("正在读取个人项目…", 14)
	content.add_child(_status_label)
	_refresh_button = Button.new()
	_refresh_button.text = "刷新所需报价"
	_style_button(_refresh_button)
	_refresh_button.pressed.connect(_load_requirements)
	content.add_child(_refresh_button)
	content.add_child(_label("预览计算时间（UTC）", 14))
	_at_input = LineEdit.new()
	_at_input.placeholder_text = "YYYY-MM-DDTHH:MM:SSZ"
	_at_input.text = _now_utc()
	_style_input(_at_input)
	_at_input.text_changed.connect(_invalidate_preview)
	content.add_child(_at_input)
	_quote_list = VBoxContainer.new()
	_quote_list.add_theme_constant_override("separation", 10)
	content.add_child(_quote_list)
	var actions := HBoxContainer.new()
	actions.add_theme_constant_override("separation", 12)
	content.add_child(actions)
	_preview_button = Button.new()
	_preview_button.text = "预览估值"
	_style_button(_preview_button)
	_preview_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_preview_button.pressed.connect(_on_preview_pressed)
	actions.add_child(_preview_button)
	_confirm_button = Button.new()
	_confirm_button.text = "确认估值并重算金豆"
	_style_button(_confirm_button)
	_confirm_button.disabled = true
	_confirm_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_confirm_button.pressed.connect(_on_confirm_pressed)
	actions.add_child(_confirm_button)
	var preview_panel := PanelContainer.new()
	_style_panel(preview_panel)
	content.add_child(preview_panel)
	_preview_label = _label("完成每项报价后点击预览；预览不会保存。", 15)
	_preview_label.custom_minimum_size.y = 180
	preview_panel.add_child(_preview_label)
	_return_button = Button.new()
	_return_button.text = "返回个人金豆罐"
	_style_button(_return_button)
	_return_button.visible = true
	_return_button.pressed.connect(func() -> void:
		return_to_jar_requested.emit()
		if get_tree().current_scene == self:
			get_tree().change_scene_to_file("res://scenes/personal_main.tscn"))
	content.add_child(_return_button)


func _label(value: String, size: int) -> Label:
	var label := Label.new()
	label.text = value
	label.add_theme_font_size_override("font_size", size)
	label.add_theme_color_override("font_color", Color("34312c") if size >= 18 else Color("665d50"))
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return label


func _style_button(button: Button) -> void:
	button.custom_minimum_size.y = 40.0
	button.add_theme_font_size_override("font_size", 15)
	for state in ["font_color", "font_hover_color", "font_pressed_color"]:
		button.add_theme_color_override(state, Color("34312c"))
	button.add_theme_color_override("font_disabled_color", Color("91877a"))
	var normal := StyleBoxFlat.new()
	normal.bg_color = Color("f1e7d5")
	normal.set_corner_radius_all(10)
	normal.content_margin_left = 10.0
	normal.content_margin_right = 10.0
	button.add_theme_stylebox_override("normal", normal)
	var hover := normal.duplicate()
	hover.bg_color = Color("e9d8bc")
	button.add_theme_stylebox_override("hover", hover)
	var pressed := normal.duplicate()
	pressed.bg_color = Color("ddc9a8")
	button.add_theme_stylebox_override("pressed", pressed)
	var disabled := normal.duplicate()
	disabled.bg_color = Color("ebe6de")
	button.add_theme_stylebox_override("disabled", disabled)


func _style_input(input: LineEdit) -> void:
	input.custom_minimum_size.y = 40.0
	input.add_theme_font_size_override("font_size", 15)
	input.add_theme_color_override("font_color", Color("34312c"))
	input.add_theme_color_override("font_placeholder_color", Color("887d6f"))
	var normal := StyleBoxFlat.new()
	normal.bg_color = Color("fffcf6")
	normal.border_color = Color("d7c9b4")
	normal.set_border_width_all(1)
	normal.set_corner_radius_all(9)
	normal.content_margin_left = 10.0
	normal.content_margin_right = 10.0
	input.add_theme_stylebox_override("normal", normal)
	var focus := normal.duplicate()
	focus.border_color = Color("b99559")
	focus.set_border_width_all(2)
	input.add_theme_stylebox_override("focus", focus)


func _style_picker(picker: OptionButton) -> void:
	_style_button(picker)
	var normal := StyleBoxFlat.new()
	normal.bg_color = Color("fffcf6")
	normal.border_color = Color("d7c9b4")
	normal.set_border_width_all(1)
	normal.set_corner_radius_all(9)
	normal.content_margin_left = 10.0
	normal.content_margin_right = 10.0
	picker.add_theme_stylebox_override("normal", normal)
	var popup := picker.get_popup()
	var panel := normal.duplicate()
	panel.bg_color = Color("fffcf6")
	popup.add_theme_stylebox_override("panel", panel)
	popup.add_theme_color_override("font_color", Color("34312c"))
	popup.add_theme_color_override("font_hover_color", Color("34312c"))


func _style_panel(panel: PanelContainer, quote_card: bool = false) -> void:
	var style := StyleBoxFlat.new()
	style.bg_color = Color("f5efe4") if quote_card else Color("fffcf6")
	style.border_color = Color("e0d3be")
	style.set_border_width_all(1)
	style.set_corner_radius_all(9)
	style.content_margin_left = 12.0
	style.content_margin_right = 12.0
	style.content_margin_top = 10.0
	style.content_margin_bottom = 10.0
	panel.add_theme_stylebox_override("panel", style)


func _load_requirements() -> void:
	_invalidate_preview()
	_return_button.visible = true
	_requirements = {}
	_quote_fields.clear()
	for child in _quote_list.get_children():
		_quote_list.remove_child(child)
		child.queue_free()
	var loaded: Dictionary = _store.load_project()
	_preview_button.disabled = true
	if not loaded.ok:
		_status_label.text = "个人项目读取失败：" + str(loaded.get("error", "UNKNOWN"))
		return
	if loaded.state.get("data_kind", "") != "personal":
		_status_label.text = "仅支持个人项目；演示项目不能手工重估。"
		return
	if int(loaded.generation) == 0 or loaded.state.get("mappings", []).is_empty():
		_status_label.text = "请先完成个人现金开户，再进行手工重估。"
		return
	_privacy_mode = str(loaded.state.get("presentation", {}).get("privacy_mode", "show_total"))
	var needed: Dictionary = _flow.requirements(int(loaded.generation))
	if not needed.ok:
		_status_label.text = "无法推导完整报价需求：" + str(needed.error)
		return
	_requirements = needed
	for identity in needed.identities:
		_add_quote_card(identity)
	_preview_button.disabled = false
	var pending: Dictionary = loaded.state.get("valuation_pending", {})
	var display: Dictionary = Display.build(loaded.state, int(loaded.generation))
	var state_label := "旧金豆为上次完整快照，等待重估" if not pending.is_empty() else \
		"当前完整快照" if display.ok and display.snapshot.snapshot_status == "CURRENT" else \
		"可生成新估值"
	_status_label.text = "第 %d 版 · %d 项手工报价 · %d 现金账户 / %d 受限账户 · %s" % [
		int(loaded.generation), int(needed.identities.size()),
		int(needed.cash_account_count), int(needed.restricted_account_count), state_label]
	if _privacy_mode == "hide_total":
		_status_label.text += " · 隐私模式隐藏总金额"


func _add_quote_card(identity: Dictionary) -> void:
	var key: String = Contract.identity_key(identity)
	var panel := PanelContainer.new()
	_style_panel(panel, true)
	_quote_list.add_child(panel)
	var card := VBoxContainer.new()
	card.add_theme_constant_override("separation", 5)
	panel.add_child(card)
	card.add_child(_label(_identity_label(identity), 18))
	card.add_child(_label("手工单价 · " + str(identity.currency), 14))
	var price := LineEdit.new()
	price.placeholder_text = "请输入十进制正数，不采用历史成交价"
	_style_input(price)
	price.text_changed.connect(_invalidate_preview)
	card.add_child(price)
	card.add_child(_label("报价单位", 14))
	var unit := OptionButton.new()
	_style_picker(unit)
	unit.add_item("请选择单位")
	unit.set_item_metadata(0, "")
	var units: Array = []
	match str(identity.kind):
		"GOLD":
			units = [["每克", "CURRENCY_PER_GRAM"],
				["每金衡盎司", "CURRENCY_PER_TROY_OUNCE"]]
		"FX":
			units = [["每 1 单位外币", "CURRENCY_PER_FOREIGN_UNIT"]]
		_:
			units = [["每股 / 每份", "CURRENCY_PER_SHARE"]]
	for option in units:
		var index := unit.item_count
		unit.add_item(str(option[0]))
		unit.set_item_metadata(index, str(option[1]))
	unit.item_selected.connect(_invalidate_preview)
	card.add_child(unit)
	card.add_child(_label("报价时间（UTC）", 14))
	var quoted_at := LineEdit.new()
	quoted_at.placeholder_text = "YYYY-MM-DDTHH:MM:SSZ"
	_style_input(quoted_at)
	quoted_at.text_changed.connect(_invalidate_preview)
	card.add_child(quoted_at)
	card.add_child(_label("报价来源说明", 14))
	var source := LineEdit.new()
	source.placeholder_text = "例如：自己核对的账单或报价页面"
	_style_input(source)
	source.text_changed.connect(_invalidate_preview)
	card.add_child(source)
	_quote_fields[key] = {"identity": identity.duplicate(true), "price": price,
		"unit": unit, "quoted_at": quoted_at, "source_note": source}


func _identity_label(identity: Dictionary) -> String:
	match str(identity.kind):
		"FX":
			return "汇率 · %s · 报价币种 %s" % [identity.symbol, identity.currency]
		"GOLD":
			return "黄金 · XAU · 报价币种 %s" % identity.currency
		_:
			var share_class := str(identity.share_class)
			return "%s · %s:%s · %s%s" % [identity.kind, identity.market,
				identity.symbol, identity.currency,
				" · 份额 " + share_class if not share_class.is_empty() else ""]


func _entries_from_form() -> Dictionary:
	var entries := {}
	for key in _quote_fields:
		var fields: Dictionary = _quote_fields[key]
		var unit: OptionButton = fields.unit
		var unit_value := ""
		if unit.selected >= 0:
			unit_value = str(unit.get_item_metadata(unit.selected))
		var entry := {"price": str(fields.price.text).strip_edges(),
			"unit": unit_value,
			"quoted_at": str(fields.quoted_at.text).strip_edges(),
			"source_note": str(fields.source_note.text).strip_edges()}
		for value in entry.values():
			if str(value).is_empty():
				return {"ok": false, "error": "请填写 " +
					_identity_label(fields.identity) + " 的价格、单位、UTC 时间和来源"}
		entries[key] = entry
	return {"ok": true, "entries": entries}


func _on_preview_pressed() -> void:
	_invalidate_preview()
	if _requirements.is_empty():
		_preview_label.text = "请先载入个人项目的完整报价需求。"
		return
	var collected := _entries_from_form()
	if not collected.ok:
		_preview_label.text = str(collected.error)
		return
	var at_utc := _at_input.text.strip_edges()
	var preview: Dictionary = _flow.preview(collected.entries,
		int(_requirements.generation), at_utc, str(_requirements.gold_currency))
	if not preview.ok:
		_preview_label.text = "估值预览失败：" + str(preview.error)
		if preview.error == "GENERATION_CONFLICT":
			_status_label.text = "项目已变化，请刷新所需报价。"
		return
	_shown_preview = preview
	_preview_label.text = _render_preview(preview, collected.entries)
	_confirm_button.disabled = preview.duplicate


func _on_confirm_pressed() -> void:
	if _shown_preview.is_empty():
		return
	if _at_input.text.strip_edges() != str(_shown_preview.at_utc):
		_invalidate_preview()
		_preview_label.text = "预览计算时间已变化，请重新预览。"
		return
	var collected := _entries_from_form()
	if not collected.ok:
		_invalidate_preview()
		_preview_label.text = str(collected.error) + "。请重新预览。"
		return
	var result: Dictionary = _flow.confirm(collected.entries, _shown_preview,
		{"confirmed": true, "preview_id": str(_shown_preview.preview_id)})
	if not result.ok:
		_invalidate_preview()
		if result.error == "VALUATION_SAVED_MAPPING_PENDING":
			var loaded: Dictionary = _store.load_project()
			var saved_snapshot: bool = loaded.ok and \
				int(loaded.generation) == int(result.generation) and \
				loaded.state.get("valuation", {}).get("snapshots", {}).has(
					str(result.get("snapshot_id", "")))
			if saved_snapshot:
				_status_label.text = "估值快照已保存为第 %d 版；金豆映射未完成。" % [
					int(result.generation)]
				_preview_label.text = "旧金豆仅代表上次完整快照，不能作为当前估值展示。" + \
					"映射失败（%s）；请刷新需求后重试。" % [str(result.mapping_error)]
			else:
				_status_label.text = "重估未完成；本地快照保存状态待核查。"
				_preview_label.text = "请检查个人项目状态，勿把旧金豆当作当前估值。"
			return
		var loaded: Dictionary = _store.load_project()
		if loaded.ok and int(loaded.generation) > int(_requirements.generation):
			_status_label.text = "项目已变化；请刷新并检查待重估状态。"
		_preview_label.text = "确认失败：" + str(result.error) + "。请重新预览。"
		return
	_invalidate_preview()
	_load_requirements()
	var success := "已完成估值和金豆映射：%s 克。" % [str(result.equivalent_grams)]
	if _privacy_mode == "hide_total":
		success += "隐私模式：总金额已隐藏。"
	else:
		success += " 总资产 %s。" % [str(result.asset_total)]
	_status_label.text = "个人项目第 %d 版 · 当前完整快照" % [int(result.generation)]
	_preview_label.text = success
	_return_button.visible = true
	revaluation_confirmed.emit(result)


func _render_preview(preview: Dictionary, entries: Dictionary) -> String:
	var lines: Array[String] = ["待确认 · 本地手工报价 · 预览没有保存项目"]
	var keys: Array = entries.keys()
	keys.sort()
	for key in keys:
		var fields: Dictionary = _quote_fields[key]
		var entry: Dictionary = entries[key]
		lines.append("%s：%s %s · %s · 来源 %s" % [
			_identity_label(fields.identity), str(entry.price),
			_unit_label(str(entry.unit)),
			str(entry.quoted_at), str(entry.source_note)])
	if _privacy_mode == "hide_total":
		lines.append("隐私模式：预计总资产金额已隐藏。")
	else:
		for balance in preview.get("restricted_balances", []):
			lines.append("受限余额 · %s：%s %s（已确认的账本检查点）" % [
				str(balance.get("account_name", balance.get("balance_id", ""))),
				str(balance.get("amount", "")), str(balance.get("currency", ""))])
		for asset in preview.get("other_asset_values", []):
			lines.append("其他估值资产 · %s：%s %s · %s · 依据 %s" % [
				str(asset.get("asset_name", asset.get("asset_id", ""))),
				str(asset.get("amount", "")), str(asset.get("currency", "")),
				str(asset.get("effective_at", "")),
				str(asset.get("valuation_basis", ""))])
		lines.append("预计总资产：%s %s" % [preview.asset_total, preview.base_currency])
	lines.append("预计金豆折合：%s 克（完整克 %s）" % [
		preview.equivalent_grams, preview.whole_grams])
	lines.append("金价折算基准：%s %s / 克" % [
		preview.price_per_gram, preview.base_currency])
	lines.append("确认后会先保存估值，再提交金豆映射；若第二步失败，旧金豆继续标为上次完整快照。")
	return "\n".join(lines)


func _unit_label(unit: String) -> String:
	match unit:
		"CURRENCY_PER_GRAM": return "每克"
		"CURRENCY_PER_TROY_OUNCE": return "每金衡盎司"
		"CURRENCY_PER_FOREIGN_UNIT": return "每单位外币"
		"CURRENCY_PER_SHARE": return "每股 / 每份"
	return unit


func _invalidate_preview(_value: Variant = null) -> void:
	_shown_preview = {}
	if _confirm_button != null:
		_confirm_button.disabled = true
	if _preview_label != null:
		_preview_label.text = "报价已变化，请重新预览；预览不会保存。"


func _now_utc() -> String:
	return Time.get_datetime_string_from_unix_time(int(Time.get_unix_time_from_system())) + "Z"
