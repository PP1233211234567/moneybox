extends Control
## A local, structured review surface. Only explicit confirmation changes the ledger.

signal trade_confirmed(result: Dictionary)
signal return_to_jar_requested

const Flow = preload("res://scripts/trade/personal_trade_flow.gd")
const Store = preload("res://scripts/data/project_store.gd")
const DEFAULT_PATH := "user://personal/moneybox"
const TEXT_FIELDS := ["quantity", "currency", "trade_date", "settlement_date",
	"total_amount", "unit_price", "fee", "tax_amount"]
const MONEY_FIELDS := ["total_amount", "unit_price", "fee", "tax_amount"]
const FIELD_LABELS := {
	"direction": "方向", "account_id": "账户", "instrument_id": "标的",
	"quantity": "数量", "currency": "币种", "trade_date": "交易日",
	"settlement_date": "结算日", "total_amount": "现金总额",
	"amount_basis": "金额口径", "unit_price": "成交单价", "fee": "手续费",
	"tax_amount": "税款（请明确填 0；非零税暂不支持）",
}

@export var base_path := DEFAULT_PATH

var _flow: RefCounted
var _store: RefCounted
var _generation := 0
var _draft: Dictionary = {}
var _candidates: Dictionary = {}
var _privacy_mode := "show_total"
var _shown_preview: Dictionary = {}
var _shown_generation := -1
var _shown_revision := -1
var _shown_signature := ""
var _confirm_key := ""
var _completed := false
var _fields: Dictionary = {}
var _pickers: Dictionary = {}
var _source_input: LineEdit
var _reference_date_input: LineEdit
var _resume_picker: OptionButton
var _create_button: Button
var _resume_button: Button
var _preview_button: Button
var _confirm_button: Button
var _return_button: Button
var _status_label: Label
var _preview_label: Label


func _ready() -> void:
	if base_path == DEFAULT_PATH:
		var test_path := OS.get_environment("MONEYBOX_PERSONAL_STATE_PATH")
		if not test_path.is_empty():
			base_path = test_path
	_store = Store.new(base_path)
	_flow = Flow.new(base_path)
	_build_ui()
	_refresh_project()


func get_source_input() -> LineEdit:
	return _source_input


func get_reference_date_input() -> LineEdit:
	return _reference_date_input


func get_field(name: String) -> LineEdit:
	return _fields.get(name)


func get_picker(name: String) -> OptionButton:
	return _pickers.get(name)


func get_create_button() -> Button:
	return _create_button


func get_preview_button() -> Button:
	return _preview_button


func get_confirm_button() -> Button:
	return _confirm_button


func get_return_button() -> Button:
	return _return_button


func get_resume_button() -> Button:
	return _resume_button


func get_resume_picker() -> OptionButton:
	return _resume_picker


func get_status_text() -> String:
	return _status_label.text


func get_preview_text() -> String:
	return _preview_label.text


func get_active_draft_id() -> String:
	return str(_draft.get("id", ""))


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
	content.add_child(_label("本地交易草稿", 27))
	content.add_child(_label("输入一句交易记录，核对账户、标的与每个金额，再预览和确认。草稿仅存本地；不会联网获取报价。", 15))
	_status_label = _label("正在读取个人项目…", 14)
	content.add_child(_status_label)
	_add_caption(content, "交易原文（最多 500 字，本地解析后清空输入框）")
	_source_input = _line(content, "例：今天在汇丰香港用3001美元买了5股VOO，其中手续费1美元")
	_source_input.max_length = 500
	_add_caption(content, "“今天／昨天”的参照日期（北京时间）")
	_reference_date_input = _line(content, "YYYY-MM-DD")
	_reference_date_input.text = _beijing_date()
	_create_button = Button.new()
	_create_button.text = "生成本地草稿"
	_style_button(_create_button, true)
	_create_button.pressed.connect(_on_create_pressed)
	content.add_child(_create_button)
	_add_caption(content, "继续未确认草稿")
	_resume_picker = OptionButton.new()
	_style_picker(_resume_picker)
	content.add_child(_resume_picker)
	_resume_button = Button.new()
	_resume_button.text = "载入草稿"
	_style_button(_resume_button, false)
	_resume_button.pressed.connect(_on_resume_pressed)
	content.add_child(_resume_button)
	var review := PanelContainer.new()
	review.add_theme_stylebox_override("panel", _box(Color("fffdfa"), Color("d5e2dc"), 16))
	content.add_child(review)
	var review_margin := MarginContainer.new()
	review_margin.add_theme_constant_override("margin_left", 14)
	review_margin.add_theme_constant_override("margin_right", 14)
	review_margin.add_theme_constant_override("margin_top", 14)
	review_margin.add_theme_constant_override("margin_bottom", 14)
	review.add_child(review_margin)
	var review_column := VBoxContainer.new()
	review_column.add_theme_constant_override("separation", 9)
	review_margin.add_child(review_column)
	review_column.add_child(_label("逐项核对 · 账户和标的只能选账本已有候选项", 17))
	_add_picker(review_column, "direction", [
		{"label": "请选择方向", "value": ""}, {"label": "买入", "value": "buy"},
		{"label": "卖出", "value": "sell"}])
	_add_picker(review_column, "account_id", [{"label": "请选择已有账户", "value": ""}])
	_add_picker(review_column, "instrument_id", [{"label": "请选择已有标的", "value": ""}])
	for name in ["quantity", "currency", "trade_date", "settlement_date",
			"total_amount"]:
		_add_field(review_column, name)
	_add_picker(review_column, "amount_basis", [
		{"label": "请选择金额口径", "value": ""},
		{"label": "含费用现金总额", "value": "cash_flow"},
		{"label": "不含费用成交额", "value": "gross_trade"}])
	for name in ["unit_price", "fee", "tax_amount"]:
		_add_field(review_column, name)
	content.add_child(_label("修订草稿会本地保存结构化字段；预览不会写账本。税款必须明确确认，非零税暂不能入账。", 14))
	var actions := HBoxContainer.new()
	actions.add_theme_constant_override("separation", 12)
	content.add_child(actions)
	_preview_button = Button.new()
	_preview_button.text = "预览交易"
	_style_button(_preview_button, false)
	_preview_button.disabled = true
	_preview_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_preview_button.pressed.connect(_on_preview_pressed)
	actions.add_child(_preview_button)
	_confirm_button = Button.new()
	_confirm_button.text = "确认并写入账本"
	_style_button(_confirm_button, true)
	_confirm_button.disabled = true
	_confirm_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_confirm_button.pressed.connect(_on_confirm_pressed)
	actions.add_child(_confirm_button)
	var preview_panel := PanelContainer.new()
	preview_panel.add_theme_stylebox_override("panel", _box(Color("eaf4ef"), Color("c8ded2"), 14))
	content.add_child(preview_panel)
	_preview_label = _label("先生成草稿，核对后点击预览。", 15)
	_preview_label.custom_minimum_size.y = 150
	preview_panel.add_child(_preview_label)
	_return_button = Button.new()
	_return_button.text = "返回个人金豆罐"
	_style_button(_return_button, false)
	_return_button.pressed.connect(func() -> void:
		return_to_jar_requested.emit()
		if get_tree().current_scene == self:
			get_tree().change_scene_to_file("res://scenes/personal_main.tscn"))
	content.add_child(_return_button)


func _label(value: String, size: int) -> Label:
	var label := Label.new()
	label.text = value
	label.add_theme_font_size_override("font_size", size)
	label.add_theme_color_override("font_color", Color("173f3b") if size >= 24 else Color("263d3c"))
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return label


func _add_caption(parent: VBoxContainer, value: String) -> void:
	parent.add_child(_label(value, 14))


func _line(parent: VBoxContainer, hint: String) -> LineEdit:
	var input := LineEdit.new()
	input.placeholder_text = hint
	input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	input.custom_minimum_size.y = 46
	input.add_theme_stylebox_override("normal", _box(Color("ffffff"), Color("b7cbc3"), 9))
	input.add_theme_stylebox_override("focus", _box(Color("ffffff"), Color("278675"), 9))
	input.add_theme_color_override("font_color", Color("213735"))
	input.add_theme_color_override("font_placeholder_color", Color("637873"))
	input.add_theme_color_override("caret_color", Color("17695d"))
	input.add_theme_color_override("selection_color", Color("a9d4c8"))
	parent.add_child(input)
	return input


func _add_field(parent: VBoxContainer, name: String) -> void:
	_add_caption(parent, str(FIELD_LABELS[name]))
	var input := _line(parent, "留空表示尚未填写")
	input.text_changed.connect(_invalidate_preview)
	_fields[name] = input


func _add_picker(parent: VBoxContainer, name: String, options: Array) -> void:
	_add_caption(parent, str(FIELD_LABELS[name]))
	var picker := OptionButton.new()
	_style_picker(picker)
	_set_options(picker, options)
	picker.item_selected.connect(_invalidate_preview)
	parent.add_child(picker)
	_pickers[name] = picker


func _box(fill: Color, border: Color, radius: int) -> StyleBoxFlat:
	var box := StyleBoxFlat.new()
	box.bg_color = fill
	box.border_color = border
	box.set_border_width_all(1)
	box.set_corner_radius_all(radius)
	box.content_margin_left = 12
	box.content_margin_right = 12
	box.content_margin_top = 9
	box.content_margin_bottom = 9
	return box


func _style_picker(picker: OptionButton) -> void:
	picker.custom_minimum_size.y = 46
	picker.add_theme_stylebox_override("normal", _box(Color("ffffff"), Color("b7cbc3"), 9))
	picker.add_theme_stylebox_override("hover", _box(Color("f1faf5"), Color("7fb4a3"), 9))
	picker.add_theme_stylebox_override("pressed", _box(Color("e6f4ec"), Color("278675"), 9))
	picker.add_theme_stylebox_override("focus", _box(Color("ffffff"), Color("278675"), 9))
	picker.add_theme_stylebox_override("disabled", _box(Color("e9ede9"), Color("ced8d1"), 9))
	for color_name in ["font_color", "font_hover_color", "font_pressed_color", "font_focus_color"]:
		picker.add_theme_color_override(color_name, Color("213735"))
	picker.add_theme_color_override("font_disabled_color", Color("526a63"))


func _style_button(button: Button, primary: bool) -> void:
	button.custom_minimum_size.y = 48
	var fill := Color("176c5d") if primary else Color("eef6f0")
	var hover := Color("125f52") if primary else Color("e1f0e7")
	var pressed := Color("0e5148") if primary else Color("d4e8db")
	var border := Color("176c5d") if primary else Color("b8d4c5")
	button.add_theme_stylebox_override("normal", _box(fill, border, 10))
	button.add_theme_stylebox_override("hover", _box(hover, border, 10))
	button.add_theme_stylebox_override("pressed", _box(pressed, border, 10))
	button.add_theme_stylebox_override("focus", _box(fill, Color("278675"), 10))
	button.add_theme_stylebox_override("disabled", _box(Color("e5ebe6"), Color("cad8cd"), 10))
	var font_color := Color("ffffff") if primary else Color("174c43")
	for color_name in ["font_color", "font_hover_color", "font_pressed_color", "font_focus_color"]:
		button.add_theme_color_override(color_name, font_color)
	button.add_theme_color_override("font_disabled_color", Color("62796f"))


func _set_options(picker: OptionButton, options: Array) -> void:
	picker.clear()
	for option in options:
		picker.add_item(str(option.label))
		picker.set_item_metadata(picker.item_count - 1, str(option.value))
	picker.select(0)


func _selected(name: String) -> String:
	var picker: OptionButton = _pickers[name]
	if picker.selected < 0:
		return ""
	return str(picker.get_item_metadata(picker.selected))


func _select_value(name: String, value: String) -> void:
	var picker: OptionButton = _pickers[name]
	for index in picker.item_count:
		if str(picker.get_item_metadata(index)) == value:
			picker.select(index)
			return
	picker.select(0)


func _refresh_project() -> void:
	_invalidate_preview()
	var loaded: Dictionary = _store.load_project()
	_create_button.disabled = true
	_resume_button.disabled = true
	_preview_button.disabled = true
	if not loaded.ok:
		_status_label.text = "个人项目读取失败：" + str(loaded.get("error", "UNKNOWN"))
		return
	if loaded.state.get("data_kind", "") != "personal":
		_status_label.text = "仅支持个人项目；演示项目不能录入交易。"
		return
	if int(loaded.generation) == 0 or loaded.state.get("mappings", []).is_empty():
		_status_label.text = "请先完成个人现金开户，再录入交易。"
		return
	var offered: Dictionary = _flow.list_candidates()
	if not offered.ok:
		_status_label.text = "账本候选项读取失败：" + str(offered.get("error", "UNKNOWN"))
		return
	_generation = int(offered.generation)
	_candidates = offered.candidates
	_privacy_mode = str(loaded.state.get("presentation", {}).get("privacy_mode", "show_total"))
	_apply_privacy()
	var account_options := [{"label": "请选择已有账户", "value": ""}]
	for account in _candidates.accounts:
		var aliases: Array = account.get("aliases", [])
		var label := str(aliases[0]) if not aliases.is_empty() else str(account.id)
		account_options.append({"label": "%s · %s · ID %s" % [label, account.currency, account.id],
			"value": str(account.id)})
	_set_options(_pickers.account_id, account_options)
	var instrument_options := [{"label": "请选择已有标的", "value": ""}]
	for instrument in _candidates.instruments:
		instrument_options.append({"label": "%s:%s · %s · ID %s" % [instrument.market,
			instrument.symbol, instrument.currency, instrument.id], "value": str(instrument.id)})
	_set_options(_pickers.instrument_id, instrument_options)
	var pending_ids: Array = []
	for draft_id in loaded.state.get("trade_drafts", {}):
		var raw: Variant = loaded.state.trade_drafts[draft_id]
		if typeof(raw) == TYPE_DICTIONARY and raw.get("status", "") == "pending":
			pending_ids.append(str(draft_id))
	pending_ids.sort()
	_resume_picker.clear()
	for draft_id in pending_ids:
		_resume_picker.add_item(draft_id)
		_resume_picker.set_item_metadata(_resume_picker.item_count - 1, draft_id)
	_resume_button.disabled = pending_ids.is_empty()
	_create_button.disabled = false
	_status_label.text = "第 %d 版个人项目 · %d 个已有账户 · %d 个已有标的" % [
		_generation, _candidates.accounts.size(), _candidates.instruments.size()]
	if _privacy_mode == "hide_total":
		_status_label.text += " · 隐私模式隐藏金额"
	if not loaded.state.get("valuation_pending", {}).is_empty():
		_status_label.text += " · 旧金额和金豆仅为上次完整快照，等待重估"


func _apply_privacy() -> void:
	var private := _privacy_mode == "hide_total"
	_source_input.secret = private
	for name in MONEY_FIELDS:
		_fields[name].secret = private


func _on_create_pressed() -> void:
	_invalidate_preview()
	if _create_button.disabled:
		return
	var source := _source_input.text.strip_edges()
	if source.is_empty():
		_preview_label.text = "请先输入交易原文。"
		return
	var token := Crypto.new().generate_random_bytes(16).hex_encode()
	var created: Dictionary = _flow.create_draft(source, "local-" + token,
		"draft-" + token, _now_utc(), _reference_date_input.text.strip_edges(), _generation)
	if not created.ok:
		_preview_label.text = "生成草稿失败：" + str(created.get("error", "UNKNOWN"))
		return
	_source_input.text = ""
	_activate_draft(created)
	_status_label.text = "结构化草稿已本地保存；账本和金豆未改变。请核对每一项。"


func _on_resume_pressed() -> void:
	if _resume_button.disabled or _resume_picker.selected < 0:
		return
	_sync_privacy()
	var draft_id := str(_resume_picker.get_item_metadata(_resume_picker.selected))
	var loaded: Dictionary = _flow.load_draft(draft_id)
	if not loaded.ok:
		_preview_label.text = "载入草稿失败：" + str(loaded.get("error", "UNKNOWN"))
		return
	_activate_draft(loaded)
	_status_label.text = "已载入本地结构化草稿；请重新核对并预览。"


func _activate_draft(loaded: Dictionary) -> void:
	_draft = loaded.draft
	_generation = int(loaded.generation)
	_candidates = loaded.candidates
	_completed = false
	_confirm_key = "trade-" + Crypto.new().generate_random_bytes(16).hex_encode()
	for name in TEXT_FIELDS:
		_fields[name].text = _draft_value(name)
	for name in ["direction", "account_id", "instrument_id", "amount_basis"]:
		_select_value(name, _draft_value(name))
	_preview_button.disabled = false
	_invalidate_preview()
	_preview_label.text = "草稿 %s · 第 %d 次修订。确认前请预览并检查缺失与冲突。" % [
		str(_draft.id), int(_draft.revision)]


func _draft_value(name: String) -> String:
	var entry: Variant = _draft.get("fields", {}).get(name, {})
	return str(entry.get("value", "")) if typeof(entry) == TYPE_DICTIONARY else ""


func _form_values() -> Dictionary:
	var values := {}
	for name in TEXT_FIELDS:
		values[name] = _fields[name].text.strip_edges()
	for name in ["direction", "account_id", "instrument_id", "amount_basis"]:
		values[name] = _selected(name)
	return values


func _on_preview_pressed() -> void:
	_sync_privacy()
	_invalidate_preview()
	if _draft.is_empty() or _completed:
		return
	var values := _form_values()
	var changes := {}
	for name in values:
		if str(values[name]) != _draft_value(name):
			changes[name] = str(values[name])
	if not changes.is_empty():
		var revised: Dictionary = _flow.revise_draft(str(_draft.id), changes, _generation)
		if not revised.ok:
			_preview_label.text = "草稿修订失败：" + str(revised.get("error", "UNKNOWN"))
			return
		_draft = revised.draft
		_generation = int(revised.generation)
	var loaded: Dictionary = _flow.load_draft(str(_draft.id), str(values.tax_amount))
	if not loaded.ok:
		_preview_label.text = "预览失败：" + str(loaded.get("error", "UNKNOWN"))
		return
	_draft = loaded.draft
	_generation = int(loaded.generation)
	var validation: Dictionary = loaded.validation
	if not validation.ok:
		var missing: Array = validation.get("missing_fields", [])
		var conflicts: Array = validation.get("conflicts", [])
		_preview_label.text = "预览未通过。\n缺失：%s\n冲突：%s\n请修订后再次预览。" % [
			", ".join(missing), ", ".join(conflicts)]
		return
	_shown_preview = validation.preview.duplicate(true)
	_shown_generation = _generation
	_shown_revision = int(_draft.revision)
	_shown_signature = JSON.stringify(values)
	_confirm_button.disabled = false
	_preview_label.text = _render_preview(validation.preview)
	_status_label.text = "交易预览已通过；账本未改变。请单独点击确认。"


func _render_preview(preview: Dictionary) -> String:
	var identity := "%s · 账户 ID %s · 标的 ID %s" % [
		"买入" if preview.direction == "buy" else "卖出", preview.account_id, preview.instrument_id]
	var lines := ["交易草稿预览（尚未入账）", identity,
		"数量 %s · 交易日 %s · 结算日 %s" % [preview.quantity,
			preview.trade_date, preview.settlement_date if not str(preview.settlement_date).is_empty() else "未指定"],
		"候选身份与现金／持仓已核对；税款已明确确认。"]
	if _privacy_mode == "hide_total":
		lines.append("隐私模式：单价、总额、费用、税款和现金变化已隐藏；金额等式已校验。")
	else:
		lines.append("单价 %s %s · 成交额 %s %s" % [preview.unit_price, preview.currency,
			preview.gross_amount, preview.currency])
		lines.append("现金总额 %s %s · 手续费 %s · 税款 %s" % [preview.cash_total,
			preview.currency, preview.fee, preview.tax_amount])
		lines.append("现金变化 %s %s · 持仓变化 %s" % [preview.cash_delta,
			preview.currency, preview.quantity_delta])
	lines.append("确认后将写入账本一次，并标记等待重估；旧金豆不会作为当前资产展示。")
	return "\n".join(lines)


func _on_confirm_pressed() -> void:
	if _confirm_button.disabled or _draft.is_empty() or _completed:
		return
	if _sync_privacy():
		_invalidate_preview()
		_preview_label.text = "隐私设置已变化，请重新预览。"
		return
	var values := _form_values()
	if JSON.stringify(values) != _shown_signature:
		_invalidate_preview()
		_preview_label.text = "输入已变化，请重新预览。"
		return
	var loaded: Dictionary = _flow.load_draft(str(_draft.id), str(values.tax_amount))
	if not loaded.ok or int(loaded.get("generation", -1)) != _shown_generation \
			or int(loaded.get("draft", {}).get("revision", -1)) != _shown_revision \
			or not loaded.get("validation", {}).get("ok", false) \
			or JSON.stringify(loaded.validation.preview) != JSON.stringify(_shown_preview):
		_invalidate_preview()
		_preview_label.text = "项目或预览已变化，请重新预览。"
		return
	var result: Dictionary = _flow.confirm_trade({"confirmed": true,
		"draft_id": str(_draft.id), "draft_revision": _shown_revision,
		"idempotency_key": _confirm_key, "tax_amount": str(values.tax_amount)},
		_shown_generation)
	if not result.ok:
		_invalidate_preview()
		_preview_label.text = "确认失败：" + str(result.get("error", "UNKNOWN"))
		return
	_completed = true
	_confirm_button.disabled = true
	_preview_button.disabled = true
	_generation = int(result.generation)
	_preview_label.text = "交易账本已保存一次，等待重估。旧金额和金豆仅为上次完整快照；请返回金豆罐发起重估。"
	_status_label.text = "第 %d 版 · 交易已确认 · 等待重估" % _generation
	trade_confirmed.emit(result)


func _invalidate_preview(_value: Variant = null) -> void:
	_shown_preview = {}
	_shown_generation = -1
	_shown_revision = -1
	_shown_signature = ""
	if _confirm_button != null:
		_confirm_button.disabled = true


func _sync_privacy() -> bool:
	var loaded: Dictionary = _store.load_project()
	if not loaded.ok:
		return false
	var next_mode := str(loaded.state.get("presentation", {}).get("privacy_mode", "show_total"))
	if next_mode == _privacy_mode:
		return false
	_privacy_mode = next_mode
	_apply_privacy()
	# A previous normal preview may contain money. Scrub it as soon as privacy changes.
	_preview_label.text = "隐私设置已变化，请重新预览。"
	return true


func _now_utc() -> String:
	return Time.get_datetime_string_from_unix_time(int(Time.get_unix_time_from_system())) + "Z"


func _beijing_date() -> String:
	return Time.get_date_string_from_unix_time(int(Time.get_unix_time_from_system()) + 8 * 3600)
