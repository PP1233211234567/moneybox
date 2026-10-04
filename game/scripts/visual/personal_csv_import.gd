extends Control
## Pasted CSV only. This scene never opens user files or calls a file chooser.
## The import service is the authority for parsing, row validation and persistence.

signal import_confirmed(result: Dictionary)

const Flow = preload("res://scripts/import/personal_import_flow.gd")
const CsvImport = preload("res://scripts/import/csv_import_service.gd")
const Store = preload("res://scripts/data/project_store.gd")
const DEFAULT_PATH := "user://personal/moneybox"
const FIELD_LABELS := {
	"type": "流水类型 *", "account": "账户来源值 *", "to_account": "转入账户来源值",
	"instrument": "证券来源值", "effective_at": "生效时间 UTC *", "amount": "金额",
	"delta": "现金变动", "quantity": "数量", "unit_price": "成交单价", "fee": "手续费",
	"reference_price": "期初参考价", "cost_basis": "期初成本", "external": "外部资金标记",
	"currency": "币种", "tax_amount": "税款", "total_amount": "交易总额",
	"amount_basis": "总额口径"
}

@export var base_path := DEFAULT_PATH

var _flow: RefCounted
var _store: RefCounted
var _csv_input: TextEdit
var _column_button: Button
var _identity_button: Button
var _preview_button: Button
var _confirm_button: Button
var _status_label: Label
var _summary_label: Label
var _file_notice_label: Label
var _row_list: ItemList
var _column_container: VBoxContainer
var _account_container: VBoxContainer
var _instrument_container: VBoxContainer
var _field_pickers: Dictionary = {}
var _account_pickers: Dictionary = {}
var _instrument_pickers: Dictionary = {}
var _account_options: Array = []
var _instrument_options: Array = []
var _header: Array = []
var _parsed_rows: Array = []
var _scanned_hash := ""
var _identities_scanned := false
var _shown_preview: Dictionary = {}
var _opened := false


func _ready() -> void:
	if base_path == DEFAULT_PATH:
		var test_path := OS.get_environment("MONEYBOX_PERSONAL_STATE_PATH")
		if not test_path.is_empty():
			base_path = test_path
	_flow = Flow.new(base_path)
	_store = Store.new(base_path)
	_build_ui()
	_refresh_project()


func get_csv_input() -> TextEdit:
	return _csv_input


func get_column_button() -> Button:
	return _column_button


func get_identity_button() -> Button:
	return _identity_button


func get_preview_button() -> Button:
	return _preview_button


func get_confirm_button() -> Button:
	return _confirm_button


func get_field_picker(field: String) -> OptionButton:
	return _field_pickers.get(field, null)


func get_account_picker(alias: String) -> OptionButton:
	return _account_pickers.get(alias, null)


func get_instrument_picker(alias: String) -> OptionButton:
	return _instrument_pickers.get(alias, null)


func get_status_text() -> String:
	return _status_label.text


func get_summary_text() -> String:
	return _summary_label.text


func get_file_notice_text() -> String:
	return _file_notice_label.text


func get_row_list() -> ItemList:
	return _row_list


func _build_ui() -> void:
	var background := ColorRect.new()
	background.color = Color("faf7f0")
	background.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(background)
	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	margin.add_theme_constant_override("margin_left", 20)
	margin.add_theme_constant_override("margin_right", 20)
	margin.add_theme_constant_override("margin_top", 26)
	margin.add_theme_constant_override("margin_bottom", 24)
	add_child(margin)
	var layout := VBoxContainer.new()
	layout.add_theme_constant_override("separation", 12)
	margin.add_child(layout)
	var title := _label("导入 CSV 到个人账本", 26, Color("34312c"))
	layout.add_child(title)
	_status_label = _label("正在读取个人账本…", 14, Color("665d50"))
	layout.add_child(_status_label)
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	layout.add_child(scroll)
	var content := VBoxContainer.new()
	content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content.add_theme_constant_override("separation", 12)
	scroll.add_child(content)
	content.add_child(_label("1. 粘贴 CSV 文本", 20, Color("594a38")))
	_file_notice_label = _label("仅处理这里粘贴的文本；尚未接入系统文件选择器，也不会读取设备文件。", 14,
		Color("776c5c"))
	content.add_child(_file_notice_label)
	_csv_input = TextEdit.new()
	_csv_input.custom_minimum_size.y = 160
	_csv_input.placeholder_text = "粘贴含表头的 CSV；原始文本只在此页用于预览和确认"
	_style_csv_input(_csv_input)
	_csv_input.text_changed.connect(_on_csv_changed)
	content.add_child(_csv_input)
	_column_button = _button("读取列名", content)
	_column_button.pressed.connect(_scan_columns)
	content.add_child(_label("2. 将 CSV 列映射为账本字段", 20, Color("594a38")))
	content.add_child(_label("星号为所有行必需；具体流水还需要对应金额、数量、费用和税款字段。", 14,
		Color("776c5c")))
	_column_container = VBoxContainer.new()
	_column_container.add_theme_constant_override("separation", 8)
	content.add_child(_column_container)
	for field in CsvImport.FIELDS:
		var picker := _picker(_column_container, str(FIELD_LABELS[field]))
		picker.name = "map_" + str(field)
		picker.item_selected.connect(_on_field_changed)
		_field_pickers[field] = picker
	content.add_child(_label("3. 显式匹配账户与证券 ID", 20, Color("594a38")))
	content.add_child(_label("不会按名称或代码自动入账；每个来源值需选择本地已有 ID。", 14,
		Color("776c5c")))
	_identity_button = _button("识别来源值", content)
	_identity_button.pressed.connect(_scan_identities)
	_account_container = VBoxContainer.new()
	_account_container.add_theme_constant_override("separation", 8)
	content.add_child(_account_container)
	_instrument_container = VBoxContainer.new()
	_instrument_container.add_theme_constant_override("separation", 8)
	content.add_child(_instrument_container)
	content.add_child(_label("4. 检查整批预览", 20, Color("594a38")))
	_summary_label = _label("预览不会写入账本。错误行会显示行号；任一错误都会阻止整批确认。", 15,
		Color("665d50"))
	content.add_child(_summary_label)
	_row_list = ItemList.new()
	_row_list.custom_minimum_size.y = 230
	_row_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content.add_child(_row_list)
	content.add_child(_label("确认后一次保存账本与待重估标记；金额和金豆保留上次完整快照。", 14,
		Color("8b6545")))
	var actions := HBoxContainer.new()
	actions.add_theme_constant_override("separation", 8)
	layout.add_child(actions)
	_preview_button = _button("预览整批", actions)
	_preview_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_preview_button.pressed.connect(_on_preview_pressed)
	_confirm_button = _button("确认写入", actions)
	_confirm_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_confirm_button.disabled = true
	_confirm_button.pressed.connect(_on_confirm_pressed)
	var back := _button("返回金豆罐", layout)
	back.pressed.connect(func() -> void:
		get_tree().change_scene_to_file("res://scenes/personal_main.tscn"))


func _refresh_project() -> void:
	var loaded: Dictionary = _store.load_project()
	_opened = loaded.ok and loaded.state.get("data_kind", "") == "personal" and \
		int(loaded.generation) >= 1 and not loaded.state.get("mappings", []).is_empty()
	_column_button.disabled = not _opened
	_identity_button.disabled = not _opened
	_preview_button.disabled = not _opened
	if not loaded.ok:
		_status_label.text = "读取个人账本失败：" + str(loaded.get("error", "UNKNOWN"))
		return
	if loaded.state.get("data_kind", "") != "personal":
		_status_label.text = "仅能导入个人账本；演示项目不会写入。"
		return
	if not _opened:
		_status_label.text = "请先在个人页建立现金账户。"
		return
	var project: Dictionary = loaded.state
	_account_options = []
	var account_ids: Array = project.ledger.accounts.keys()
	account_ids.sort()
	for id in account_ids:
		var account: Dictionary = project.ledger.accounts[id]
		_account_options.append(["%s · %s · ID %s" % [
			str(account.get("name", id)), str(account.get("currency", "")), str(id)], str(id)])
	_instrument_options = []
	var instrument_ids: Array = project.ledger.instruments.keys()
	instrument_ids.sort()
	for id in instrument_ids:
		var instrument: Dictionary = project.ledger.instruments[id]
		_instrument_options.append(["%s:%s · %s · ID %s" % [
			str(instrument.get("market", "")), str(instrument.get("symbol", "")),
			str(instrument.get("currency", "")), str(id)], str(id)])
	var pending: Dictionary = project.get("valuation_pending", {})
	_status_label.text = "个人账本第 %d 版 · %s" % [int(loaded.generation),
		"金豆等待重估" if not pending.is_empty() else "可粘贴 CSV"]


func _scan_columns() -> void:
	_invalidate_preview()
	_clear_identities()
	if not _opened:
		return
	var raw := _csv_input.text
	if raw.is_empty() or raw.to_utf8_buffer().size() > CsvImport.MAX_BYTES:
		_summary_label.text = "CSV 文本为空或超过本地 8 MB 上限。"
		return
	var parsed := CsvImport._parse_csv(raw)
	if not parsed.ok or parsed.rows.is_empty():
		_summary_label.text = "CSV 语法错误：%s · 物理行 %d" % [
			str(parsed.get("error", "CSV_DATA_ROWS_REQUIRED")), int(parsed.get("line", 0))]
		return
	var header: Array = parsed.rows[0].fields.duplicate()
	header[0] = str(header[0]).trim_prefix("\uFEFF")
	var seen := {}
	for name in header:
		if str(name).is_empty() or seen.has(name):
			_summary_label.text = "CSV 表头包含空列名或重复列名。"
			return
		seen[name] = true
	_header = header
	_parsed_rows = parsed.rows
	_scanned_hash = raw.sha256_text()
	for field in CsvImport.FIELDS:
		var picker: OptionButton = _field_pickers[field]
		var previous := _selected(picker)
		picker.clear()
		picker.add_item("不映射")
		picker.set_item_metadata(0, "")
		var selected := 0
		for name in header:
			var index := picker.item_count
			picker.add_item(str(name))
			picker.set_item_metadata(index, str(name))
			if str(name) == previous:
				selected = index
		picker.select(selected)
	_summary_label.text = "已读取 %d 列、%d 个数据行。请逐项选择列，再识别账户与证券值。" % [
		header.size(), maxi(0, parsed.rows.size() - 1)]


func _scan_identities() -> void:
	_invalidate_preview()
	_clear_identities()
	if _scanned_hash.is_empty() or _scanned_hash != _csv_input.text.sha256_text():
		_summary_label.text = "CSV 已变化，请重新读取列名。"
		return
	var columns := _column_map()
	if not columns.has("account") or not columns.has("type") or not columns.has("effective_at"):
		_summary_label.text = "先选择流水类型、账户来源值和生效时间三列。"
		return
	_refresh_project()
	var account_aliases := {}
	var instrument_aliases := {}
	for record_index in range(1, _parsed_rows.size()):
		var cells: Array = _parsed_rows[record_index].fields
		if cells.size() != _header.size():
			continue
		for field in ["account", "to_account"]:
			if columns.has(field):
				var alias := str(cells[_header.find(columns[field])])
				if not alias.is_empty():
					account_aliases[alias] = true
		if columns.has("instrument"):
			var alias := str(cells[_header.find(columns.instrument)])
			if not alias.is_empty():
				instrument_aliases[alias] = true
	var accounts: Array = account_aliases.keys()
	accounts.sort()
	for alias in accounts:
		_account_pickers[alias] = _identity_picker(_account_container,
			"账户来源值：" + str(alias), _account_options)
	var instruments: Array = instrument_aliases.keys()
	instruments.sort()
	for alias in instruments:
		_instrument_pickers[alias] = _identity_picker(_instrument_container,
			"证券来源值：" + str(alias), _instrument_options)
	_identities_scanned = true
	_summary_label.text = "识别到 %d 个账户值、%d 个证券值；请显式选择已有 ID。" % [
		accounts.size(), instruments.size()]


func _on_preview_pressed() -> void:
	_invalidate_preview()
	_row_list.clear()
	if not _opened or not _identities_scanned or \
			_scanned_hash != _csv_input.text.sha256_text():
		_summary_label.text = "先读取列名、选择字段，并重新识别来源值。"
		return
	var mapping := _mapping()
	var preview: Dictionary = _flow.preview_csv(_csv_input.text, mapping)
	if not preview.ok:
		_render_errors(preview)
		return
	if preview.duplicate:
		_summary_label.text = "该 CSV 已导入：%d 行。重复批次不会再次入账。" % preview.row_count
		_status_label.text = "重复批次 · 无需再次确认"
		return
	_shown_preview = preview
	_summary_label.text = "待确认：%d 行全部通过预检。预览未保存，确认后金豆等待重估。" % [
		int(preview.row_count)]
	for row in preview.rows:
		_row_list.add_item(_row_text(row))
	_confirm_button.disabled = false


func _on_confirm_pressed() -> void:
	if _shown_preview.is_empty() or _confirm_button.disabled:
		return
	var mapping := _mapping()
	var result: Dictionary = _flow.confirm_csv(_csv_input.text, mapping,
		_shown_preview, {"confirmed": true,
			"content_sha256": str(_shown_preview.content_sha256)})
	if not result.ok:
		_invalidate_preview()
		_summary_label.text = "确认失败：%s。账本未通过本次确认写入，请重新预览。" % [
			str(result.get("error", "UNKNOWN"))]
		_refresh_project()
		return
	_invalidate_preview()
	_confirm_button.disabled = true
	_csv_input.clear()
	_clear_identities()
	_header = []
	_parsed_rows = []
	_scanned_hash = ""
	_row_list.clear()
	_refresh_project()
	_summary_label.text = "已保存到个人账本第 %d 版。金豆仍是上次完整快照，等待重新估值。" % [
		int(result.generation)]
	import_confirmed.emit(result)


func _render_errors(preview: Dictionary) -> void:
	var errors: Array = preview.get("row_errors", [])
	_summary_label.text = "%d 行中有 %d 项错误；整批未保存。" % [
		int(preview.get("row_count", 0)), errors.size()]
	if errors.is_empty():
		_row_list.add_item("错误：" + str(preview.get("error", "UNKNOWN")))
	for item in errors:
		_row_list.add_item("第 %d 行（数据第 %d 行）：%s" % [
			int(item.get("line", 0)), int(item.get("row", 0)),
			_error_label(str(item.get("code", "UNKNOWN")))])


func _row_text(row: Dictionary) -> String:
	var command: Dictionary = row.command
	var kind := str(command.type)
	var description := "%s · 账户 ID %s" % [_kind_label(kind), str(command.account_id)]
	if command.has("instrument_id"):
		description += " · 证券 ID " + str(command.instrument_id)
	if command.has("delta"):
		description += " · 现金变动 " + str(command.delta)
	if command.has("amount"):
		description += " · 金额 " + str(command.amount)
	if command.has("quantity"):
		description += " · 数量 " + str(command.quantity)
	if command.has("unit_price"):
		description += " · 单价 " + str(command.unit_price)
	if command.has("fee"):
		description += " · 费用 " + str(command.fee)
	return "第 %d 行 · %s · %s" % [int(row.line), description, str(command.effective_at)]


func _kind_label(kind: String) -> String:
	match kind:
		"opening_cash": return "期初现金"
		"cash_delta": return "现金变动"
		"transfer": return "内部转账"
		"buy": return "买入"
		"sell": return "卖出"
		"opening_position": return "期初持仓"
	return kind


func _error_label(code: String) -> String:
	match code:
		"ACCOUNT_MAPPING_REQUIRED": return "账户值没有匹配已有 ID（%s）" % code
		"INSTRUMENT_MAPPING_REQUIRED": return "证券值没有匹配已有 ID（%s）" % code
		"CSV_COLUMN_COUNT_MISMATCH": return "列数与表头不一致（%s）" % code
		"REQUIRED_FIELD_MISSING": return "必需字段缺失（%s）" % code
		"INSUFFICIENT_CASH": return "账户现金不足（%s）" % code
		"INSUFFICIENT_HOLDING": return "持仓数量不足（%s）" % code
	return code


func _on_csv_changed() -> void:
	_invalidate_preview()
	_clear_identities()
	_header = []
	_parsed_rows = []
	_scanned_hash = ""
	_row_list.clear()
	_summary_label.text = "CSV 已变化。请重新读取列名并核对映射。"


func _on_field_changed(_index: int) -> void:
	_invalidate_preview()
	_clear_identities()
	_summary_label.text = "字段映射已变化，请重新识别账户与证券值。"


func _invalidate_preview(_value: Variant = null) -> void:
	_shown_preview = {}
	if _confirm_button != null:
		_confirm_button.disabled = true


func _clear_identities() -> void:
	_account_pickers.clear()
	_instrument_pickers.clear()
	_identities_scanned = false
	for container in [_account_container, _instrument_container]:
		if container == null:
			continue
		for child in container.get_children():
			container.remove_child(child)
			child.queue_free()


func _column_map() -> Dictionary:
	var result := {}
	for field in CsvImport.FIELDS:
		var selected := _selected(_field_pickers[field])
		if not selected.is_empty():
			result[field] = selected
	return result


func _mapping() -> Dictionary:
	var accounts := {}
	for alias in _account_pickers:
		var selected := _selected(_account_pickers[alias])
		if not selected.is_empty():
			accounts[alias] = selected
	var instruments := {}
	for alias in _instrument_pickers:
		var selected := _selected(_instrument_pickers[alias])
		if not selected.is_empty():
			instruments[alias] = selected
	return {"column_map": _column_map(), "account_ids": accounts,
		"instrument_ids": instruments}


func _selected(picker: OptionButton) -> String:
	if picker == null or picker.selected < 0:
		return ""
	return str(picker.get_item_metadata(picker.selected))


func _identity_picker(parent: VBoxContainer, caption: String, options: Array) -> OptionButton:
	parent.add_child(_label(caption, 14, Color("665d50")))
	var picker := OptionButton.new()
	picker.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_style_picker(picker)
	picker.add_item("请选择已有 ID")
	picker.set_item_metadata(0, "")
	for option in options:
		var index := picker.item_count
		picker.add_item(str(option[0]))
		picker.set_item_metadata(index, str(option[1]))
	picker.item_selected.connect(_invalidate_preview)
	parent.add_child(picker)
	return picker


func _picker(parent: VBoxContainer, caption: String) -> OptionButton:
	parent.add_child(_label(caption, 14, Color("665d50")))
	var picker := OptionButton.new()
	picker.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_style_picker(picker)
	picker.add_item("先读取列名")
	picker.set_item_metadata(0, "")
	parent.add_child(picker)
	return picker


func _style_csv_input(input: TextEdit) -> void:
	var normal := _input_box(Color("fffcf6"), Color("cbbda7"))
	input.add_theme_stylebox_override("normal", normal)
	input.add_theme_stylebox_override("focus", _input_box(Color("fffcf6"), Color("9b7750")))
	input.add_theme_stylebox_override("read_only", _input_box(Color("f1e9dc"), Color("cbbda7")))
	input.add_theme_color_override("font_color", Color("34312c"))
	input.add_theme_color_override("font_placeholder_color", Color("756b5d"))
	input.add_theme_color_override("font_readonly_color", Color("665d50"))
	input.add_theme_color_override("caret_color", Color("5c4630"))
	input.add_theme_color_override("selection_color", Color("dbc59f"))
	input.add_theme_color_override("font_selected_color", Color("28231d"))
	input.add_theme_font_size_override("font_size", 15)


func _style_picker(picker: OptionButton) -> void:
	picker.custom_minimum_size.y = 42
	picker.clip_text = true
	picker.add_theme_stylebox_override("normal", _input_box(Color("fffcf6"), Color("cbbda7")))
	picker.add_theme_stylebox_override("hover", _input_box(Color("f9f1e2"), Color("bca98b")))
	picker.add_theme_stylebox_override("pressed", _input_box(Color("f0e2ca"), Color("a98d67")))
	picker.add_theme_stylebox_override("disabled", _input_box(Color("f3ebdf"), Color("d6c9b6")))
	picker.add_theme_stylebox_override("focus", _input_box(Color("fffcf6"), Color("9b7750")))
	for color_name in ["font_color", "font_hover_color", "font_pressed_color", "font_focus_color"]:
		picker.add_theme_color_override(color_name, Color("34312c"))
	picker.add_theme_color_override("font_disabled_color", Color("675f53"))
	picker.add_theme_font_size_override("font_size", 15)
	var popup := picker.get_popup()
	popup.add_theme_stylebox_override("panel", _input_box(Color("fffcf6"), Color("cbbda7")))
	var hover := StyleBoxFlat.new()
	hover.bg_color = Color("f0e2ca")
	hover.set_corner_radius_all(6)
	popup.add_theme_stylebox_override("hover", hover)
	popup.add_theme_color_override("font_color", Color("34312c"))
	popup.add_theme_color_override("font_hover_color", Color("34312c"))
	popup.add_theme_color_override("font_disabled_color", Color("675f53"))
	popup.add_theme_font_size_override("font_size", 15)


func _input_box(fill: Color, border: Color) -> StyleBoxFlat:
	var box := StyleBoxFlat.new()
	box.bg_color = fill
	box.border_color = border
	box.set_border_width_all(1)
	box.set_corner_radius_all(8)
	box.content_margin_left = 10
	box.content_margin_right = 10
	box.content_margin_top = 7
	box.content_margin_bottom = 7
	return box


func _label(value: String, size: int, color: Color) -> Label:
	var label := Label.new()
	label.text = value
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.add_theme_font_size_override("font_size", size)
	label.add_theme_color_override("font_color", color)
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return label


func _button(value: String, parent: Node) -> Button:
	var button := Button.new()
	button.text = value
	button.custom_minimum_size.y = 43
	button.add_theme_font_size_override("font_size", 15)
	button.add_theme_color_override("font_color", Color("34312c"))
	var style := StyleBoxFlat.new()
	style.bg_color = Color("f1e7d5")
	style.set_corner_radius_all(10)
	button.add_theme_stylebox_override("normal", style)
	var hover := style.duplicate()
	hover.bg_color = Color("ead6b0")
	button.add_theme_stylebox_override("hover", hover)
	parent.add_child(button)
	return button
