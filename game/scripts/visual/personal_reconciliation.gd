extends Control
## Read-only statement comparison. Nothing entered here is posted to the ledger.

const Store = preload("res://scripts/data/project_store.gd")
const Ledger = preload("res://scripts/data/ledger_core.gd")
const Reconcile = preload("res://scripts/reconciliation/reconciliation_service.gd")
const DEFAULT_PATH := "user://personal/moneybox"
const RETURN_SCENE := "res://scenes/personal_main.tscn"
const CODE_LABELS := {
	"SETTLEMENT_STATUS_MISSING": "尚未声明待交收状态",
	"PENDING_SETTLEMENT_NOT_RECONCILABLE": "存在或不确定待交收项目，当前服务无法核对",
	"STATEMENT_ROWS_MISSING": "账单项目未填齐",
	"STATEMENT_BEFORE_LEDGER_EVENT": "账单截至时间早于账本中的流水",
	"LEDGER_VERSION_MISMATCH": "账单与当前账本版本不符",
	"AGGREGATE_BALANCE_NOT_CASH": "汇总余额不能当作明细现金",
	"RESTRICTED_BALANCE_RECONCILIATION_UNSUPPORTED": "公积金或养老金余额尚无独立账单对账路径；本次不声明全额匹配",
	"INVALID_STATEMENT": "账单时间或必填结构无效",
	"INVALID_CASH_ROW": "现金金额须为非负十进制数",
	"INVALID_POSITION_ROW": "持仓数量须为非负十进制数",
	"INVALID_FEE_ROW": "手续费须为非负十进制数",
	"INVALID_ACCOUNT_TOTAL_CHECKPOINT": "账户总额须为非负十进制数",
}

@export var base_path := DEFAULT_PATH

var _store: RefCounted
var _ledger: Dictionary = {}
var _generation := -1
var _ledger_hash := ""
var _forms: Dictionary = {}
var _account_ids: Array[String] = []
var _account_picker: OptionButton
var _as_of_input: LineEdit
var _settlement_picker: OptionButton
var _scroll: ScrollContainer
var _form_host: VBoxContainer
var _status_label: Label
var _result_label: Label
var _detail_label: Label
var _preview_button: Button
var _back_button: Button


func _ready() -> void:
	if base_path == DEFAULT_PATH:
		var test_path := OS.get_environment("MONEYBOX_PERSONAL_STATE_PATH")
		if not test_path.is_empty():
			base_path = test_path
	_store = Store.new(base_path)
	_build_ui()
	refresh()


func refresh() -> void:
	_clear_forms()
	_preview_button.disabled = true
	_result_label.text = "尚未对账。输入账单值后预览差异；不会修改账本。"
	_detail_label.text = ""
	_account_picker.clear()
	_account_picker.disabled = true
	_generation = -1
	_ledger_hash = ""
	_ledger = {}
	var loaded: Dictionary = _store.load_project()
	if not loaded.ok:
		_status_label.text = "个人账本读取失败：%s" % str(loaded.get("error", "UNKNOWN"))
		return
	if loaded.state.get("data_kind", "") != "personal":
		_status_label.text = "仅能对个人账本检查；演示项目不可用于对账。"
		return
	if int(loaded.generation) < 1 or loaded.state.ledger.accounts.is_empty():
		_status_label.text = "请先建立并保存个人账户。"
		return
	if str(loaded.state.get("presentation", {}).get("privacy_mode", "hide_total")) != "show_total":
		_status_label.text = "隐私模式已开启。请先在金豆罐显示金额，再进入对账页。"
		return
	var projection: Dictionary = Ledger.project(loaded.state.ledger)
	if not projection.ok:
		_status_label.text = "账本投影失败：%s" % str(projection.get("error", "UNKNOWN"))
		return
	if not projection.restricted_balances.is_empty():
		_status_label.text = "含公积金或养老金受限余额；此页尚不能对其对账，未声明全额匹配。"
		return
	_generation = int(loaded.generation)
	_ledger = loaded.state.ledger
	_ledger_hash = Store.canonical_ledger_hash(_ledger)
	_account_ids.assign(_ledger.accounts.keys())
	_account_ids.sort()
	var fee_events := _active_trade_fees(_ledger)
	for account_id in _account_ids:
		var account: Dictionary = _ledger.accounts[account_id]
		_account_picker.add_item("%s · %s · %s" % [
			str(account.get("name", account_id)), str(account.currency), account_id])
		_build_account_form(account_id, account, projection, fee_events)
	_account_picker.disabled = false
	_select_account(0)
	_preview_button.disabled = false
	_status_label.text = "当前个人账本第 %d 版。逐个账户录入同一时间的账单；仅做只读比较。" % _generation


func get_account_picker() -> OptionButton:
	return _account_picker


func get_as_of_input() -> LineEdit:
	return _as_of_input


func get_settlement_picker() -> OptionButton:
	return _settlement_picker


func get_preview_button() -> Button:
	return _preview_button


func get_back_button() -> Button:
	return _back_button


func get_status_text() -> String:
	return _status_label.text


func get_result_text() -> String:
	return _result_label.text + "\n" + _detail_label.text


func get_input(account_id: String, kind: String, key: String = "") -> LineEdit:
	var form: Dictionary = _forms.get(account_id, {})
	if form.is_empty():
		return null
	if kind == "cash" or kind == "total":
		return form.get(kind, null)
	return form.get(kind, {}).get(key, null)


func _build_ui() -> void:
	var background := ColorRect.new()
	background.color = Color("faf7f0")
	background.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(background)
	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	margin.add_theme_constant_override("margin_left", 20)
	margin.add_theme_constant_override("margin_right", 20)
	margin.add_theme_constant_override("margin_top", 24)
	margin.add_theme_constant_override("margin_bottom", 20)
	add_child(margin)
	var layout := VBoxContainer.new()
	layout.add_theme_constant_override("separation", 10)
	margin.add_child(layout)
	layout.add_child(_label("账户对账检查", 27, Color("34312c")))
	_status_label = _label("正在读取个人账本…", 14, Color("665d50"))
	layout.add_child(_status_label)
	_result_label = _label("尚未对账。", 17, Color("594a38"))
	layout.add_child(_result_label)
	_scroll = ScrollContainer.new()
	_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	layout.add_child(_scroll)
	var content := VBoxContainer.new()
	content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content.add_theme_constant_override("separation", 12)
	_scroll.add_child(content)
	content.add_child(_label("对账只比较账单与当前账本，不是余额更正；差额不会记作收入或收益。", 15,
		Color("8a4e37")))
	content.add_child(_label("账单截至时间（UTC，例如 2026-09-27T12:00:00Z）", 15, Color("594a38")))
	_as_of_input = _line_input("账单截至时间 UTC")
	_as_of_input.text = Time.get_datetime_string_from_system(true, false) + "Z"
	content.add_child(_as_of_input)
	content.add_child(_label("待交收项目声明", 15, Color("594a38")))
	_settlement_picker = OptionButton.new()
	_settlement_picker.add_item("尚未声明", 0)
	_settlement_picker.add_item("我确认本账单无待交收项目", 1)
	_settlement_picker.add_item("存在或不确定是否有待交收项目", 2)
	_settlement_picker.custom_minimum_size.y = 43
	_style_picker(_settlement_picker)
	content.add_child(_settlement_picker)
	content.add_child(_label("服务尚无交收模型；只有明确声明无待交收项目，才能完成目前支持范围的比较。", 13,
		Color("776c5c")))
	content.add_child(_label("选择账户并填写账单值", 19, Color("594a38")))
	_account_picker = OptionButton.new()
	_account_picker.custom_minimum_size.y = 43
	_style_picker(_account_picker)
	_account_picker.item_selected.connect(_select_account)
	content.add_child(_account_picker)
	_form_host = VBoxContainer.new()
	_form_host.add_theme_constant_override("separation", 8)
	content.add_child(_form_host)
	content.add_child(_label("空白现金、持仓或手续费表示账单资料缺失，结果会标为“资料不足”。账户总额只作未验证检查点。", 13,
		Color("776c5c")))
	_detail_label = _label("", 14, Color("665d50"))
	content.add_child(_detail_label)
	_preview_button = _button("预览对账差异", layout)
	_preview_button.disabled = true
	_preview_button.pressed.connect(_preview)
	_back_button = _button("返回个人金豆罐", layout)
	_back_button.pressed.connect(func() -> void: get_tree().change_scene_to_file(RETURN_SCENE))


func _build_account_form(account_id: String, account: Dictionary, projection: Dictionary,
		fee_events: Dictionary) -> void:
	var panel := PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.bg_color = Color("fffdf9")
	style.border_color = Color("dfd1bc")
	style.set_border_width_all(1)
	style.set_corner_radius_all(12)
	style.set_content_margin_all(13)
	panel.add_theme_stylebox_override("panel", style)
	_form_host.add_child(panel)
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 8)
	panel.add_child(column)
	column.add_child(_label("%s · %s" % [str(account.get("name", account_id)), str(account.currency)],
		18, Color("594a38")))
	var form := {"panel": panel, "cash": null, "total": null, "position": {}, "fee": {}}
	if str(account.get("mode", "")) != "detail" or projection.replaced_accounts.has(account_id):
		column.add_child(_label("此账户不是有效明细账户；当前服务不能将其余额当作现金对账。", 14,
			Color("8a4e37")))
	else:
		column.add_child(_label("账单现金余额 · %s" % str(account.currency), 14, Color("665d50")))
		form.cash = _line_input("按账单输入现金余额，十进制")
		column.add_child(form.cash)
		var position_keys: Array = projection.positions.keys()
		position_keys.sort()
		for key in position_keys:
			var position: Dictionary = projection.positions[key]
			if str(position.account_id) != account_id or str(position.quantity) == "0":
				continue
			var identity: Dictionary = _ledger.instruments.get(str(position.instrument_id), {})
			column.add_child(_label("账单持仓数量 · %s:%s · ID %s" % [
				str(identity.get("market", "")), str(identity.get("symbol", "")), str(position.instrument_id)],
				14, Color("665d50")))
			var field := _line_input("按账单输入持仓数量")
			column.add_child(field)
			form.position[str(position.instrument_id)] = field
		var fee_ids: Array = fee_events.keys()
		fee_ids.sort()
		for event_id in fee_ids:
			var event: Dictionary = fee_events[event_id]
			if str(event.account_id) != account_id:
				continue
			column.add_child(_label("账单买卖手续费 · %s · %s" % [
				str(event_id), str(event.effective_at)], 14, Color("665d50")))
			var field := _line_input("按账单输入该笔手续费")
			column.add_child(field)
			form.fee[str(event_id)] = field
	column.add_child(_label("券商账户总额（可选，仅作未验证检查点）", 14, Color("665d50")))
	form.total = _line_input("可留空；不会覆盖现金或持仓")
	column.add_child(form.total)
	_forms[account_id] = form


func _active_trade_fees(ledger: Dictionary) -> Dictionary:
	var voided := {}
	for event in ledger.events:
		if event.type == "void":
			voided[str(event.target_event_id)] = true
	var fees := {}
	for event in ledger.events:
		if ["buy", "sell"].has(str(event.type)) and not voided.has(str(event.id)):
			fees[str(event.id)] = event
	return fees


func _select_account(index: int) -> void:
	for i in _account_ids.size():
		var account_id: String = _account_ids[i]
		if _forms.has(account_id):
			_forms[account_id].panel.visible = i == index


func _preview() -> void:
	if _ledger.is_empty():
		return
	var current: Dictionary = _store.load_project()
	if not current.ok or int(current.generation) != _generation or \
			Store.canonical_ledger_hash(current.state.ledger) != _ledger_hash:
		_result_label.text = "账本版本已变化，请重新进入或刷新本页后录入新账单。"
		_detail_label.text = "未执行对账；没有写入账本。"
		_preview_button.disabled = true
		return
	var statement := {"schema_version": 1, "ledger_hash": _ledger_hash,
		"as_of": _as_of_input.text.strip_edges(), "cash_balances": [], "positions": [],
		"fees": [], "account_total_checkpoints": []}
	match _settlement_picker.selected:
		1:
			statement.pending_settlements = {"status": "NONE"}
		2:
			statement.pending_settlements = {"status": "UNKNOWN"}
	for account_id in _account_ids:
		var form: Dictionary = _forms[account_id]
		var currency: String = str(_ledger.accounts[account_id].currency)
		if form.cash != null and not form.cash.text.strip_edges().is_empty():
			statement.cash_balances.append({"account_id": account_id, "currency": currency,
				"amount": form.cash.text.strip_edges()})
		for instrument_id in form.position:
			var field: LineEdit = form.position[instrument_id]
			if not field.text.strip_edges().is_empty():
				statement.positions.append({"account_id": account_id,
					"instrument_id": instrument_id, "quantity": field.text.strip_edges()})
		for event_id in form.fee:
			var field: LineEdit = form.fee[event_id]
			if not field.text.strip_edges().is_empty():
				statement.fees.append({"event_id": event_id, "currency": currency,
					"amount": field.text.strip_edges()})
		if not form.total.text.strip_edges().is_empty():
			statement.account_total_checkpoints.append({"account_id": account_id,
				"currency": currency, "amount": form.total.text.strip_edges()})
	_show_result(Reconcile.compare(_ledger, statement))
	call_deferred("_scroll_to_result")


func _show_result(result: Dictionary) -> void:
	if not result.ok:
		_result_label.text = "输入有误：%s" % _describe_code(str(result.get("error", "UNKNOWN")))
		_detail_label.text = "未执行账本更正；请检查十进制数值、币种和时间格式。"
		return
	var checkpoints: Array = result.get("unverified_account_totals", [])
	var checkpoint_note := "\n账户总额检查点 %d 项：未验证，需锁定完整估值。" % checkpoints.size() \
		if not checkpoints.is_empty() else ""
	match str(result.status):
		"MATCHED":
			_result_label.text = "当前支持范围内一致；这不是完整账户对账。"
			_detail_label.text = "仅比较各币种现金、有效持仓数量和已记录买卖手续费；无交收模型。差额不会入账。" + checkpoint_note
		"DIFFERENCE":
			_result_label.text = "发现 %d 处账单与账本差异；没有修改账本。" % result.differences.size()
			var lines: Array[String] = []
			for row in result.differences:
				match str(row.kind):
					"CASH":
						lines.append("现金 %s %s：账本 %s，账单 %s，差额 %s" % [
							str(row.account_id), str(row.currency), str(row.ledger_amount),
							str(row.statement_amount), str(row.difference)])
					"POSITION":
						lines.append("持仓 %s/%s：账本 %s，账单 %s，差额 %s" % [
							str(row.account_id), str(row.instrument_id), str(row.ledger_quantity),
							str(row.statement_quantity), str(row.difference)])
					"RECORDED_TRADE_FEE":
						lines.append("手续费 %s %s：账本 %s，账单 %s，差额 %s" % [
							str(row.event_id), str(row.currency), str(row.ledger_amount),
							str(row.statement_amount), str(row.difference)])
			_detail_label.text = "\n".join(lines) + checkpoint_note + "\n差额仅供检查，不会自动更正或计入收益。"
		"INSUFFICIENT_DATA":
			_result_label.text = "资料不足，无法判断是否一致。"
			var missing: Array = result.get("missing", [])
			var reasons: Array[String] = []
			for reason in result.get("reasons", []):
				reasons.append(_describe_code(str(reason)))
			_detail_label.text = "原因：%s%s%s" % [
				"，".join(reasons),
				"\n待补账单项目：" + ", ".join(missing) if not missing.is_empty() else "",
				checkpoint_note]


func _describe_code(code: String) -> String:
	return "%s（%s）" % [str(CODE_LABELS[code]), code] if CODE_LABELS.has(code) else code


func _clear_forms() -> void:
	_forms.clear()
	_account_ids.clear()
	if _form_host == null:
		return
	for child in _form_host.get_children():
		child.queue_free()


func _scroll_to_result() -> void:
	if _scroll != null:
		_scroll.scroll_vertical = int(_scroll.get_v_scroll_bar().max_value)


func _label(value: String, font_size: int, color: Color) -> Label:
	var label := Label.new()
	label.text = value
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", color)
	return label


func _line_input(placeholder: String) -> LineEdit:
	var field := LineEdit.new()
	field.placeholder_text = placeholder
	field.custom_minimum_size.y = 42
	field.add_theme_font_size_override("font_size", 15)
	field.add_theme_color_override("font_color", Color("34312c"))
	field.add_theme_color_override("font_placeholder_color", Color("8d806d"))
	var style := StyleBoxFlat.new()
	style.bg_color = Color("fffcf6")
	style.border_color = Color("d7c9b4")
	style.set_border_width_all(1)
	style.set_corner_radius_all(10)
	style.content_margin_left = 10
	style.content_margin_right = 10
	field.add_theme_stylebox_override("normal", style)
	var focus := style.duplicate()
	focus.border_color = Color("b99559")
	focus.set_border_width_all(2)
	field.add_theme_stylebox_override("focus", focus)
	return field


func _style_picker(picker: OptionButton) -> void:
	picker.add_theme_font_size_override("font_size", 15)
	picker.add_theme_color_override("font_color", Color("34312c"))
	picker.add_theme_color_override("font_hover_color", Color("34312c"))
	picker.add_theme_color_override("font_pressed_color", Color("34312c"))
	picker.add_theme_color_override("font_disabled_color", Color("8d806d"))
	var style := StyleBoxFlat.new()
	style.bg_color = Color("fffcf6")
	style.border_color = Color("d7c9b4")
	style.set_border_width_all(1)
	style.set_corner_radius_all(10)
	style.content_margin_left = 10
	style.content_margin_right = 10
	picker.add_theme_stylebox_override("normal", style)
	var hover := style.duplicate()
	hover.bg_color = Color("f1e7d5")
	picker.add_theme_stylebox_override("hover", hover)
	picker.add_theme_stylebox_override("pressed", hover)
	var disabled := style.duplicate()
	disabled.bg_color = Color("f1eee8")
	picker.add_theme_stylebox_override("disabled", disabled)
	var focus := style.duplicate()
	focus.border_color = Color("b99559")
	focus.set_border_width_all(2)
	picker.add_theme_stylebox_override("focus", focus)


func _button(value: String, parent: Node) -> Button:
	var button := Button.new()
	button.text = value
	button.custom_minimum_size.y = 44
	button.add_theme_font_size_override("font_size", 15)
	button.add_theme_color_override("font_color", Color("34312c"))
	var style := StyleBoxFlat.new()
	style.bg_color = Color("f1e7d5")
	style.set_corner_radius_all(12)
	button.add_theme_stylebox_override("normal", style)
	parent.add_child(button)
	return button
