extends Control
## Local-only structured asset entry. The user sees a preview before an explicit ledger commit.

signal asset_confirmed(result: Dictionary)

const AssetFlow = preload("res://scripts/data/personal_asset_flow.gd")
const Store = preload("res://scripts/data/project_store.gd")
const QuoteContract = preload("res://scripts/quotes/quote_contract.gd")
const DEFAULT_PATH := "user://personal/moneybox"

@export var base_path := DEFAULT_PATH

var _flow: RefCounted
var _store: RefCounted
var _forms: Dictionary = {}
var _inputs: Dictionary = {}
var _pickers: Dictionary = {}
var _mode_picker: OptionButton
var _preview_button: Button
var _confirm_button: Button
var _preview_label: Label
var _status_label: Label
var _mode := "account_create"
var _command_id := ""
var _entity_id := ""
var _shown_preview: Dictionary = {}
var _opened := false


func _ready() -> void:
	if base_path == DEFAULT_PATH:
		var test_path := OS.get_environment("MONEYBOX_PERSONAL_STATE_PATH")
		if not test_path.is_empty():
			base_path = test_path
	_flow = AssetFlow.new(base_path)
	_store = Store.new(base_path)
	_new_command_ids()
	_build_ui()
	_refresh_project()


func get_input(key: String) -> LineEdit:
	return _inputs.get(key, null)


func get_picker(key: String) -> OptionButton:
	return _pickers.get(key, null)


func get_preview_button() -> Button:
	return _preview_button


func get_confirm_button() -> Button:
	return _confirm_button


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
	content.add_child(_label("个人资产录入", 27))
	var back_button := Button.new()
	back_button.text = "返回个人金豆罐"
	_style_button(back_button)
	back_button.pressed.connect(func() -> void: get_tree().change_scene_to_file("res://scenes/personal_main.tscn"))
	content.add_child(back_button)
	content.add_child(_label("先预览，再单独确认。金额与数量均按十进制文本录入。", 15))
	_status_label = _label("正在读取个人账本…", 14)
	content.add_child(_status_label)
	_mode_picker = _picker(content, "mode", "录入类型", [
		["新增账户", "account_create"], ["新增股票 / ETF / 基金", "instrument_create"],
		["期初现金", "opening_cash"], ["公积金 / 养老金余额", "restricted_balance_set"],
		["新增其他估值资产", "other_asset_create"],
		["更新其他资产估值", "other_asset_value_set"],
		["期初持仓", "opening_position"],
		["同币种账户转账", "transfer"]])
	_mode_picker.item_selected.connect(_on_mode_selected)
	var forms := VBoxContainer.new()
	forms.add_theme_constant_override("separation", 10)
	content.add_child(forms)
	_build_account_form(forms)
	_build_instrument_form(forms)
	_build_cash_form(forms)
	_build_restricted_form(forms)
	_build_other_asset_create_form(forms)
	_build_other_asset_value_form(forms)
	_build_position_form(forms)
	_build_transfer_form(forms)
	_show_form()
	var actions := HBoxContainer.new()
	actions.add_theme_constant_override("separation", 12)
	content.add_child(actions)
	_preview_button = Button.new()
	_preview_button.text = "预览变化"
	_style_button(_preview_button)
	_preview_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_preview_button.pressed.connect(_on_preview_pressed)
	actions.add_child(_preview_button)
	_confirm_button = Button.new()
	_confirm_button.text = "确认写入账本"
	_style_button(_confirm_button)
	_confirm_button.disabled = true
	_confirm_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_confirm_button.pressed.connect(_on_confirm_pressed)
	actions.add_child(_confirm_button)
	var panel := PanelContainer.new()
	_style_panel(panel)
	content.add_child(panel)
	_preview_label = _label("输入后点击“预览变化”。预览不会保存账本。", 15)
	_preview_label.custom_minimum_size.y = 160
	panel.add_child(_preview_label)
	content.add_child(_label("写入后需要重新估值；旧金豆只代表上次完整快照。", 14))


func _build_account_form(parent: VBoxContainer) -> void:
	var form := _form(parent, "account_create")
	_add_input(form, "account_name", "账户名称", "例如：现金账户")
	_add_input(form, "account_currency", "账户币种（三位代码）", "CNY", "CNY")
	_picker(form, "account_mode", "账户范围", [
		["明细账户", "detail"], ["仅汇总余额", "aggregate"]])
	_picker(form, "account_asset_kind", "账户资产类别", [
		["可用现金", "CASH"], ["住房公积金", "PROVIDENT_FUND"],
		["养老金", "PENSION"]])
	form.add_child(_label("公积金、养老金是受限余额，只能选明细账户；不能直接用于证券买入或现金转账。", 14))
	_picker(form, "account_cost_method", "持仓成本法", [
		["先进先出 FIFO", "FIFO"], ["移动平均", "MOVING_AVERAGE"]])
	_add_input(form, "account_source", "来源标记（可留空）", "自定义来源，不填账号")
	_add_input(form, "account_custodian", "实际托管机构标记（可留空）", "与展示来源分开")


func _build_instrument_form(parent: VBoxContainer) -> void:
	var form := _form(parent, "instrument_create")
	_picker(form, "instrument_kind", "资产类别", [
		["股票", "STOCK"], ["ETF", "ETF"], ["公募基金", "FUND"]])
	_add_input(form, "instrument_name", "显示名称（可留空）", "自行核对证券身份")
	_add_input(form, "instrument_market", "市场代码", "例如：NASDAQ")
	_add_input(form, "instrument_symbol", "证券 / 基金代码", "例如：VOO")
	_add_input(form, "instrument_currency", "报价币种（三位代码）", "例如：USD")
	_add_input(form, "instrument_share_class", "份额类别（可留空）", "例如：A")


func _build_cash_form(parent: VBoxContainer) -> void:
	var form := _form(parent, "opening_cash")
	_picker(form, "cash_account", "现金所属账户", [["请选择账户", ""]])
	_add_input(form, "cash_amount", "期初现金（账户币种）", "例如：1000.00")
	_add_input(form, "cash_at", "生效时间（UTC）", "YYYY-MM-DDTHH:MM:SSZ", _now_utc())


func _build_restricted_form(parent: VBoxContainer) -> void:
	var form := _form(parent, "restricted_balance_set")
	_picker(form, "restricted_account", "公积金 / 养老金账户", [["请选择账户", ""]])
	_add_input(form, "restricted_amount", "核对后的当前余额（账户币种）", "例如：12000.50")
	_add_input(form, "restricted_source", "余额依据（必填）", "例如：个人账户对账单；不填账号")
	_add_input(form, "restricted_at", "余额生效时间（UTC）", "YYYY-MM-DDTHH:MM:SSZ", _now_utc())
	form.add_child(_label("这是余额检查点：新余额替代该账户此前余额，不推算缴存、利息、成本或收益。", 14))


func _build_other_asset_create_form(parent: VBoxContainer) -> void:
	var form := _form(parent, "other_asset_create")
	_add_input(form, "other_name", "资产名称", "例如：自有收藏品")
	_add_input(form, "other_currency", "估值币种（三位代码）", "CNY", "CNY")
	_picker(form, "other_ownership_scope", "计入的所有权范围", [
		["本人独有，计入全额", "SOLE"], ["仅计入本人拥有的份额", "OWNED_SHARE"]])
	_add_input(form, "other_ownership_note", "所有权依据（必填）", "例如：本人购买凭证；不要填证件号码")
	_add_input(form, "other_dedup_key", "资产去重归属键（必填）", "同一资产在各来源使用同一键")
	_add_input(form, "other_opening_amount", "本人拥有部分的当前估值", "例如：2500.00")
	_add_input(form, "other_opening_basis", "估值依据（必填）", "例如：已核对的近期交易记录")
	_add_input(form, "other_opening_at", "估值生效时间（UTC）", "YYYY-MM-DDTHH:MM:SSZ", _now_utc())
	form.add_child(_label("同一资产只登记一次。金额须是本人拥有部分的估值；不推算购买成本或投资收益。", 14))


func _build_other_asset_value_form(parent: VBoxContainer) -> void:
	var form := _form(parent, "other_asset_value_set")
	_picker(form, "other_existing_asset", "已有其他估值资产", [["请选择资产", ""]])
	_add_input(form, "other_value_amount", "新的当前估值（本人拥有部分）", "例如：2600.00")
	_add_input(form, "other_value_basis", "本次估值依据（必填）", "例如：已核对的市场参考资料")
	_add_input(form, "other_value_at", "估值生效时间（UTC）", "YYYY-MM-DDTHH:MM:SSZ", _now_utc())
	form.add_child(_label("新估值替代此前检查点，不将差额认作收益或资金流。", 14))


func _build_position_form(parent: VBoxContainer) -> void:
	var form := _form(parent, "opening_position")
	_picker(form, "position_account", "持仓所属明细账户", [["请选择账户", ""]])
	_picker(form, "position_instrument", "证券身份", [["请选择证券", ""]])
	_add_input(form, "position_quantity", "期初数量 / 份额", "例如：5")
	_add_input(form, "position_price", "手工参考价（每份，证券币种）", "例如：100.00")
	_add_input(form, "position_cost", "已知总成本（可留空）", "不清楚时留空，不推测")
	_add_input(form, "position_at", "生效时间（UTC）", "YYYY-MM-DDTHH:MM:SSZ", _now_utc())


func _build_transfer_form(parent: VBoxContainer) -> void:
	var form := _form(parent, "transfer")
	_picker(form, "transfer_from", "转出账户", [["请选择账户", ""]])
	_picker(form, "transfer_to", "转入账户", [["请选择账户", ""]])
	_add_input(form, "transfer_amount", "转账金额（同币种）", "例如：500.00")
	_add_input(form, "transfer_at", "生效时间（UTC）", "YYYY-MM-DDTHH:MM:SSZ", _now_utc())


func _form(parent: VBoxContainer, key: String) -> VBoxContainer:
	var form := VBoxContainer.new()
	form.name = key
	form.add_theme_constant_override("separation", 8)
	_forms[key] = form
	parent.add_child(form)
	return form


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


func _style_panel(panel: PanelContainer) -> void:
	var style := StyleBoxFlat.new()
	style.bg_color = Color("fffcf6")
	style.border_color = Color("e0d3be")
	style.set_border_width_all(1)
	style.set_corner_radius_all(9)
	style.content_margin_left = 12.0
	style.content_margin_right = 12.0
	style.content_margin_top = 10.0
	style.content_margin_bottom = 10.0
	panel.add_theme_stylebox_override("panel", style)


func _add_input(parent: VBoxContainer, key: String, caption: String,
		placeholder: String, default_value: String = "") -> LineEdit:
	parent.add_child(_label(caption, 14))
	var line := LineEdit.new()
	line.name = key
	line.placeholder_text = placeholder
	line.text = default_value
	line.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_style_input(line)
	line.text_changed.connect(_invalidate_preview)
	parent.add_child(line)
	_inputs[key] = line
	return line


func _picker(parent: VBoxContainer, key: String, caption: String,
		options: Array) -> OptionButton:
	parent.add_child(_label(caption, 14))
	var picker := OptionButton.new()
	picker.name = key
	picker.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_style_picker(picker)
	for option in options:
		var index := picker.item_count
		picker.add_item(str(option[0]))
		picker.set_item_metadata(index, str(option[1]))
	picker.item_selected.connect(_invalidate_preview)
	parent.add_child(picker)
	_pickers[key] = picker
	return picker


func _on_mode_selected(index: int) -> void:
	_mode = str(_mode_picker.get_item_metadata(index))
	_show_form()
	_invalidate_preview()


func _show_form() -> void:
	for key in _forms:
		_forms[key].visible = key == _mode


func _refresh_project() -> void:
	var loaded: Dictionary = _store.load_project()
	_opened = loaded.ok and loaded.state.get("data_kind", "") == "personal" and \
			not loaded.state.get("mappings", []).is_empty()
	_preview_button.disabled = not _opened
	if not loaded.ok:
		_status_label.text = "读取个人账本失败：" + str(loaded.get("error", "UNKNOWN"))
		return
	if loaded.state.get("data_kind", "") != "personal":
		_status_label.text = "这里只能录入个人账本，演示账本不可写入。"
		return
	if not _opened:
		_status_label.text = "请先在个人页完成现金开户，再录入其他资产。"
		return
	var ledger: Dictionary = loaded.state.ledger
	var account_options: Array = [["请选择账户", ""]]
	var restricted_options: Array = [["请选择账户", ""]]
	var account_ids: Array = ledger.accounts.keys()
	account_ids.sort()
	for id in account_ids:
		var account: Dictionary = ledger.accounts[id]
		var option := [str(account.get("name", id)) + " · " +
			str(account.get("currency", "")), str(id)]
		if str(account.get("asset_kind", "CASH")) == "CASH":
			account_options.append(option)
		else:
			restricted_options.append(option)
	for key in ["cash_account", "position_account", "transfer_from", "transfer_to"]:
		_set_options(_pickers[key], account_options)
	_set_options(_pickers.restricted_account, restricted_options)
	var other_options: Array = [["请选择资产", ""]]
	var other_assets: Dictionary = ledger.get("other_assets", {})
	var other_ids: Array = other_assets.keys()
	other_ids.sort()
	for id in other_ids:
		var other: Dictionary = other_assets[id]
		other_options.append([str(other.get("name", id)) + " · " +
			str(other.get("currency", "")), str(id)])
	_set_options(_pickers.other_existing_asset, other_options)
	var instrument_options: Array = [["请选择证券", ""]]
	var instrument_ids: Array = ledger.instruments.keys()
	instrument_ids.sort()
	for id in instrument_ids:
		var instrument: Dictionary = ledger.instruments[id]
		instrument_options.append(["%s · %s:%s · %s" % [
			str(instrument.get("kind", "")), str(instrument.get("market", "")),
			str(instrument.get("symbol", "")), str(instrument.get("currency", ""))], str(id)])
	_set_options(_pickers.position_instrument, instrument_options)
	var pending: Dictionary = loaded.state.get("valuation_pending", {})
	_status_label.text = "个人账本第 %d 版 · %s" % [int(loaded.generation),
		"等待重估；金豆为上次完整快照" if not pending.is_empty() else "可以预览新记录"]


func _set_options(picker: OptionButton, options: Array) -> void:
	var selected := _selected(picker)
	picker.clear()
	var selected_index := 0
	for option in options:
		var index := picker.item_count
		picker.add_item(str(option[0]))
		picker.set_item_metadata(index, str(option[1]))
		if not selected.is_empty() and selected == str(option[1]):
			selected_index = index
	picker.select(selected_index)


func _selected(picker: OptionButton) -> String:
	if picker.selected < 0:
		return ""
	return str(picker.get_item_metadata(picker.selected))


func _text(key: String) -> String:
	return str(_inputs[key].text).strip_edges()


func _on_preview_pressed() -> void:
	_invalidate_preview()
	if not _opened:
		_preview_label.text = "请先完成个人现金开户。"
		return
	var loaded: Dictionary = _store.load_project()
	if not loaded.ok or loaded.state.get("data_kind", "") != "personal" or \
			loaded.state.get("mappings", []).is_empty():
		_preview_label.text = "无法读取已开户的个人项目。"
		return
	var built := _build_command(loaded.state)
	if not built.ok:
		_preview_label.text = "请检查输入：" + str(built.error)
		return
	var preview: Dictionary = _flow.preview([built.command], int(loaded.generation))
	if not preview.ok:
		_preview_label.text = "预览失败：" + str(preview.error)
		return
	_shown_preview = preview
	_preview_label.text = _render_preview(built.command, preview, loaded.state)
	_confirm_button.disabled = preview.duplicate


func _on_confirm_pressed() -> void:
	if _shown_preview.is_empty() or not _opened:
		return
	var loaded: Dictionary = _store.load_project()
	if not loaded.ok or loaded.state.get("data_kind", "") != "personal" or \
			loaded.state.get("mappings", []).is_empty():
		_invalidate_preview()
		_preview_label.text = "个人项目已变化，请重新预览。"
		return
	var built := _build_command(loaded.state)
	if not built.ok:
		_invalidate_preview()
		_preview_label.text = "输入已变化，请重新预览：" + str(built.error)
		return
	var result: Dictionary = _flow.confirm([built.command], _shown_preview,
		{"confirmed": true, "preview_id": str(_shown_preview.preview_id)})
	if not result.ok:
		_invalidate_preview()
		_preview_label.text = "确认失败：" + str(result.error) + "。请重新预览。"
		_refresh_project()
		return
	_invalidate_preview()
	_new_command_ids()
	_clear_current_value()
	_refresh_project()
	_preview_label.text = "已保存到个人账本第 %d 版。等待重估；当前总资产与金豆尚未更新。" % [
		int(result.generation)]
	asset_confirmed.emit(result)


func _build_command(project: Dictionary) -> Dictionary:
	var ledger: Dictionary = project.ledger
	match _mode:
		"account_create":
			if _text("account_name").is_empty():
				return _error("请输入账户名称")
			var account := {"id": _entity_id, "name": _text("account_name"),
				"currency": _text("account_currency").to_upper(),
				"mode": _selected(_pickers.account_mode),
				"cost_method": _selected(_pickers.account_cost_method),
				"asset_kind": _selected(_pickers.account_asset_kind)}
			if account.asset_kind != "CASH" and account.mode != "detail":
				return _error("公积金和养老金须使用明细账户")
			if not _text("account_source").is_empty():
				account.source_id = _text("account_source")
			if not _text("account_custodian").is_empty():
				account.custodian_id = _text("account_custodian")
			return {"ok": true, "command": {"command_id": _command_id,
				"type": _mode, "account": account}}
		"instrument_create":
			var identity := QuoteContract.normalize_identity({
				"kind": _selected(_pickers.instrument_kind),
				"market": _text("instrument_market"),
				"symbol": _text("instrument_symbol"),
				"currency": _text("instrument_currency"),
				"share_class": _text("instrument_share_class")})
			if identity.is_empty():
				return _error("证券类别、市场、代码、币种或份额类别无效")
			var identity_key: String = QuoteContract.identity_key(identity)
			for instrument_id in ledger.instruments:
				if QuoteContract.identity_key(ledger.instruments[instrument_id]) == identity_key:
					return _error("证券身份已存在，请选现有证券")
			var instrument: Dictionary = identity.duplicate(true)
			instrument.id = _entity_id
			if not _text("instrument_name").is_empty():
				instrument.name = _text("instrument_name")
			return {"ok": true, "command": {"command_id": _command_id,
				"type": _mode, "instrument": instrument}}
		"opening_cash":
			var account_id := _selected(_pickers.cash_account)
			if account_id.is_empty():
				return _error("请选择现金账户")
			return {"ok": true, "command": {"command_id": _command_id,
				"type": _mode, "account_id": account_id, "amount": _text("cash_amount"),
				"effective_at": _text("cash_at")}}
		"restricted_balance_set":
			var account_id := _selected(_pickers.restricted_account)
			if account_id.is_empty():
				return _error("请选择公积金或养老金账户")
			return {"ok": true, "command": {"command_id": _command_id,
				"type": _mode, "account_id": account_id,
				"amount": _text("restricted_amount"),
				"source_note": _text("restricted_source"),
				"effective_at": _text("restricted_at")}}
		"other_asset_create":
			if _text("other_name").is_empty() or _text("other_ownership_note").is_empty() or \
					_text("other_dedup_key").is_empty() or _text("other_opening_basis").is_empty():
				return _error("请填写资产名称、所有权依据、去重归属键和估值依据")
			return {"ok": true, "command": {"command_id": _command_id,
				"type": _mode,
				"asset": {"id": _entity_id, "name": _text("other_name"),
					"currency": _text("other_currency").to_upper(),
					"ownership_scope": _selected(_pickers.other_ownership_scope),
					"ownership_note": _text("other_ownership_note"),
					"dedup_key": _text("other_dedup_key")},
				"opening_value": {"amount": _text("other_opening_amount"),
					"valuation_basis": _text("other_opening_basis"),
					"effective_at": _text("other_opening_at")}}}
		"other_asset_value_set":
			var asset_id := _selected(_pickers.other_existing_asset)
			if asset_id.is_empty() or not ledger.get("other_assets", {}).has(asset_id):
				return _error("请选择已有的其他估值资产")
			if _text("other_value_basis").is_empty():
				return _error("请填写本次估值依据")
			return {"ok": true, "command": {"command_id": _command_id,
				"type": _mode, "asset_id": asset_id,
				"amount": _text("other_value_amount"),
				"valuation_basis": _text("other_value_basis"),
				"effective_at": _text("other_value_at")}}
		"opening_position":
			var account_id := _selected(_pickers.position_account)
			var instrument_id := _selected(_pickers.position_instrument)
			if account_id.is_empty() or instrument_id.is_empty():
				return _error("请选择明细账户与证券身份")
			if not ledger.accounts.has(account_id) or not ledger.instruments.has(instrument_id) or \
					str(ledger.accounts[account_id].get("mode", "")) != "detail" or \
					str(ledger.accounts[account_id].get("currency", "")) != \
					str(ledger.instruments[instrument_id].get("currency", "")):
				return _error("持仓须属于同币种明细账户")
			return {"ok": true, "command": {"command_id": _command_id,
				"type": _mode, "account_id": account_id, "instrument_id": instrument_id,
				"quantity": _text("position_quantity"),
				"reference_price": _text("position_price"),
				"cost_basis": _text("position_cost"), "effective_at": _text("position_at")}}
		"transfer":
			var from_id := _selected(_pickers.transfer_from)
			var to_id := _selected(_pickers.transfer_to)
			if from_id.is_empty() or to_id.is_empty() or from_id == to_id:
				return _error("请选择两个不同账户")
			if not ledger.accounts.has(from_id) or not ledger.accounts.has(to_id) or \
					str(ledger.accounts[from_id].currency) != str(ledger.accounts[to_id].currency):
				return _error("转账两端必须是同币种账户")
			return {"ok": true, "command": {"command_id": _command_id,
				"type": _mode, "account_id": from_id, "to_account_id": to_id,
				"amount": _text("transfer_amount"), "effective_at": _text("transfer_at")}}
	return _error("不支持此录入类型")


func _render_preview(command: Dictionary, preview: Dictionary, project: Dictionary) -> String:
	var lines: Array[String] = ["待确认 · 预览未写入账本"]
	match _mode:
		"account_create":
			lines.append("新增账户：%s · %s · %s · %s" % [command.account.name,
				command.account.currency, command.account.mode,
				_asset_kind_label(str(command.account.asset_kind))])
		"instrument_create":
			lines.append("新增证券：%s · %s:%s · %s · 份额类别 %s" % [
				command.instrument.kind, command.instrument.market, command.instrument.symbol,
				command.instrument.currency,
				str(command.instrument.share_class) if not str(command.instrument.share_class).is_empty() else "无"])
		"opening_cash":
			lines.append("期初现金：%s · %s %s · %s" % [
				_account_name(project, command.account_id, command), command.amount,
				_account_currency(project, command.account_id), command.effective_at])
		"restricted_balance_set":
			lines.append("受限余额检查点：%s · %s %s · %s" % [
				_account_name(project, command.account_id, command), command.amount,
				_account_currency(project, command.account_id), command.effective_at])
			lines.append("余额依据：%s；不推算缴存、利息或收益。" % command.source_note)
		"other_asset_create":
			lines.append("新增其他估值资产：%s · %s %s · %s" % [
				command.asset.name, command.opening_value.amount,
				command.asset.currency, command.opening_value.effective_at])
			lines.append("所有权：%s · %s；去重键：%s" % [
				"本人独有" if command.asset.ownership_scope == "SOLE" else "本人持有份额",
				command.asset.ownership_note, command.asset.dedup_key])
			lines.append("估值依据：%s；金额仅计入本人拥有部分，不推算成本或收益。" % [
				command.opening_value.valuation_basis])
		"other_asset_value_set":
			var other: Dictionary = project.ledger.get("other_assets", {}).get(command.asset_id, {})
			lines.append("更新其他资产估值：%s · %s %s · %s" % [
				str(other.get("name", command.asset_id)), command.amount,
				str(other.get("currency", "")), command.effective_at])
			lines.append("估值依据：%s；新估值替代旧检查点，不将差额认作收益。" % [
				command.valuation_basis])
		"opening_position":
			lines.append("期初持仓：%s · %s · %s 份 · 手工参考价 %s %s / 份" % [
				_account_name(project, command.account_id, command),
				_instrument_name(project, command.instrument_id), command.quantity, command.reference_price,
				_account_currency(project, command.account_id)])
			lines.append("已知总成本：%s · %s" % [
				command.cost_basis if not command.cost_basis.is_empty() else "未知",
				command.effective_at])
		"transfer":
			lines.append("账户间转账：%s → %s · %s %s · %s" % [
				_account_name(project, command.account_id, command),
				_account_name(project, command.to_account_id, command), command.amount,
				_account_currency(project, command.account_id), command.effective_at])
	if str(project.get("presentation", {}).get("privacy_mode", "")) == "hide_total":
		lines.append("隐私模式：其他账户余额和持仓投影已隐藏。")
	else:
		var balances: Dictionary = preview.cash_balances
		var ids: Array = balances.keys()
		ids.sort()
		for id in ids:
			lines.append("现金 · %s：%s %s" % [_account_name(project, str(id), command),
				str(balances[id]), _account_currency(project, str(id), command)])
		var restricted: Dictionary = preview.restricted_balances
		ids = restricted.keys()
		ids.sort()
		for id in ids:
			lines.append("受限余额 · %s：%s %s" % [
				_account_name(project, str(id), command), str(restricted[id]),
				_account_currency(project, str(id), command)])
		var other_values: Dictionary = preview.other_asset_values
		ids = other_values.keys()
		ids.sort()
		for id in ids:
			var other: Dictionary = project.ledger.get("other_assets", {}).get(id, {})
			if command.type == "other_asset_create" and str(command.asset.id) == str(id):
				other = command.asset
			lines.append("其他估值资产 · %s：%s %s" % [
				str(other.get("name", id)), str(other_values[id]),
				str(other.get("currency", ""))])
		var positions: Dictionary = preview.position_quantities
		var keys: Array = positions.keys()
		keys.sort()
		for key in keys:
			var parts := str(key).split("|")
			var title := str(key)
			if parts.size() == 2:
				title = _account_name(project, parts[0], command) + " · " + \
					_instrument_name(project, parts[1])
			lines.append("持仓 · %s：%s 份" % [title, str(positions[key])])
	if not preview.missing_valuation_inputs.is_empty():
		lines.append("估值所需行情 / 汇率仍缺：" + ", ".join(preview.missing_valuation_inputs))
	lines.append("确认后等待重估；当前总资产与金豆不在此预览计算。")
	return "\n".join(lines)


func _account_name(project: Dictionary, account_id: String, command: Dictionary) -> String:
	if project.ledger.accounts.has(account_id):
		return str(project.ledger.accounts[account_id].get("name", account_id))
	if command.type == "account_create" and command.account.id == account_id:
		return str(command.account.name)
	return account_id


func _instrument_name(project: Dictionary, instrument_id: String) -> String:
	if not project.ledger.instruments.has(instrument_id):
		return instrument_id
	var instrument: Dictionary = project.ledger.instruments[instrument_id]
	var identity := "%s %s:%s" % [str(instrument.get("kind", "")),
		str(instrument.get("market", "")), str(instrument.get("symbol", ""))]
	var label := str(instrument.get("name", "")).strip_edges()
	return identity if label.is_empty() else label + "（" + identity + "）"


func _account_currency(project: Dictionary, account_id: String,
		command: Dictionary = {}) -> String:
	if project.ledger.accounts.has(account_id):
		return str(project.ledger.accounts[account_id].currency)
	if command.get("type", "") == "account_create" and command.account.id == account_id:
		return str(command.account.currency)
	return ""


func _asset_kind_label(kind: String) -> String:
	match kind:
		"PROVIDENT_FUND": return "住房公积金"
		"PENSION": return "养老金"
	return "可用现金"


func _clear_current_value() -> void:
	match _mode:
		"account_create":
			_inputs.account_name.clear()
			_inputs.account_source.clear()
			_inputs.account_custodian.clear()
		"instrument_create":
			for key in ["instrument_name", "instrument_market", "instrument_symbol",
					"instrument_currency", "instrument_share_class"]:
				_inputs[key].clear()
		"opening_cash":
			_inputs.cash_amount.clear()
		"restricted_balance_set":
			_inputs.restricted_amount.clear()
			_inputs.restricted_source.clear()
		"other_asset_create":
			for key in ["other_name", "other_ownership_note", "other_dedup_key",
					"other_opening_amount", "other_opening_basis"]:
				_inputs[key].clear()
		"other_asset_value_set":
			_inputs.other_value_amount.clear()
			_inputs.other_value_basis.clear()
		"opening_position":
			for key in ["position_quantity", "position_price", "position_cost"]:
				_inputs[key].clear()
		"transfer":
			_inputs.transfer_amount.clear()


func _new_command_ids() -> void:
	_command_id = "asset-" + Crypto.new().generate_random_bytes(16).hex_encode()
	_entity_id = "item-" + Crypto.new().generate_random_bytes(16).hex_encode()


func _now_utc() -> String:
	return Time.get_datetime_string_from_unix_time(int(Time.get_unix_time_from_system())) + "Z"


func _invalidate_preview(_value: Variant = null) -> void:
	_shown_preview = {}
	if _confirm_button != null:
		_confirm_button.disabled = true
	if _preview_label != null:
		_preview_label.text = "输入已变化。请重新预览，预览不会保存账本。"


func _error(message: String) -> Dictionary:
	return {"ok": false, "error": message}
