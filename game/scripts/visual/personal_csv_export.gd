extends Control
## P06/P15: explicit, read-only export of saved personal ledger events.

const Store = preload("res://scripts/data/project_store.gd")
const Exporter = preload("res://scripts/export/ledger_csv_export_service.gd")
const DEFAULT_PATH := "user://personal/moneybox"
const RETURN_SCENE := "res://scenes/personal_main.tscn"

@export var base_path := DEFAULT_PATH

var _store: RefCounted
var _exporter: RefCounted
var _allowed := false
var _selected_path := ""
var _status_label: Label
var _path_label: Label
var _choose_button: Button
var _export_button: Button
var _back_button: Button
var _dialog: FileDialog


func _ready() -> void:
	if base_path == DEFAULT_PATH:
		var test_path := OS.get_environment("MONEYBOX_PERSONAL_STATE_PATH")
		if not test_path.is_empty():
			base_path = test_path
	_store = Store.new(base_path)
	_exporter = Exporter.new()
	_build_ui()
	_refresh()


func get_status_text() -> String:
	return _status_label.text


func get_path_text() -> String:
	return _path_label.text


func get_choose_button() -> Button:
	return _choose_button


func get_export_button() -> Button:
	return _export_button


func get_back_button() -> Button:
	return _back_button


func get_file_dialog() -> FileDialog:
	return _dialog


func select_export_path(path: String) -> void:
	_selected_path = ""
	_export_button.disabled = true
	if not _allowed or path.is_empty():
		return
	if FileAccess.file_exists(path):
		_path_label.text = "目标文件已存在；请选择新文件，不会覆盖。"
		return
	_selected_path = path
	_path_label.text = "已选择新文件：" + path.get_file()
	_export_button.disabled = false


func _refresh() -> void:
	var loaded: Dictionary = _store.load_project()
	_allowed = loaded.ok and loaded.state.get("data_kind", "") == "personal" and \
		int(loaded.generation) >= 1
	_choose_button.disabled = not _allowed
	_export_button.disabled = not _allowed or _selected_path.is_empty()
	if not loaded.ok:
		_status_label.text = "个人账本读取失败：" + str(loaded.get("error", "UNKNOWN"))
	elif loaded.state.get("data_kind", "") != "personal":
		_status_label.text = "演示项目不能从此页导出个人流水。"
	elif int(loaded.generation) < 1:
		_status_label.text = "尚未保存个人账本；暂无可导出流水。"
	else:
		_status_label.text = "个人项目第 %d 版，已保存 %d 条流水。" % [
			int(loaded.generation), loaded.state.ledger.events.size()]


func _on_export_pressed() -> void:
	if not _allowed or _selected_path.is_empty():
		return
	var result: Dictionary = _exporter.export_events(_store, _selected_path)
	_selected_path = ""
	_export_button.disabled = true
	if not result.ok:
		_status_label.text = "CSV 导出失败：" + str(result.error) + "。当前项目未改变。"
		_path_label.text = "请重新选择一个新文件。"
		return
	_path_label.text = "已写入所选新文件；请妥善保管明文 CSV。"
	_status_label.text = "已导出第 %d 版的 %d 条流水（%d 字节）。个人账本未改变。" % [
		int(result.generation), int(result.event_count), int(result.byte_count)]


func _build_ui() -> void:
	var background := ColorRect.new()
	background.color = Color("faf7f0")
	background.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(background)
	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	margin.add_theme_constant_override("margin_left", 22)
	margin.add_theme_constant_override("margin_right", 22)
	margin.add_theme_constant_override("margin_top", 26)
	margin.add_theme_constant_override("margin_bottom", 24)
	add_child(margin)
	var scroll := ScrollContainer.new()
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	margin.add_child(scroll)
	var content := VBoxContainer.new()
	content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content.add_theme_constant_override("separation", 14)
	scroll.add_child(content)
	content.add_child(_label("导出流水 CSV", 27, Color("34312c")))
	_back_button = _button("返回个人金豆罐", content)
	_back_button.pressed.connect(func() -> void: get_tree().change_scene_to_file(RETURN_SCENE))
	_status_label = _label("正在读取个人账本…", 15, Color("665d50"))
	content.add_child(_status_label)
	var warning := _panel(content)
	warning.add_child(_label("导出的 CSV 是明文，包含完整流水和事件原文，可能泄露账户、资产与金额。导出前确认保存位置，不要上传到不可信服务。", 15, Color("8a4e37")))
	var explanation := _panel(content)
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 10)
	explanation.add_child(column)
	column.add_child(_label("流水表格", 21, Color("594a38")))
	column.add_child(_label("按入账序号导出全部已保存事件，包括已冲销事件。金额与数量保留原始十进制字符串；事件原文列保留完整字段。", 14, Color("665d50")))
	column.add_child(_label("CSV 仅是流水表格，不含完整账户、行情、金豆和生态状态，不能替代完整 JSON 备份。当前上限为 10,000 条或 16 MiB；超限会拒绝导出，不会截断。", 14, Color("665d50")))
	column.add_child(_label("当前使用 Godot 文件对话框；Android 系统文件选择器与外部目录写入仍待真机验证。", 13, Color("776c5c")))
	_path_label = _label("尚未选择导出位置", 14, Color("776c5c"))
	column.add_child(_path_label)
	_choose_button = _button("选择新 CSV 文件…", column)
	_choose_button.pressed.connect(func() -> void: _dialog.popup_centered_ratio(0.85))
	_export_button = _button("导出明文 CSV", column)
	_export_button.disabled = true
	_export_button.pressed.connect(_on_export_pressed)
	_dialog = FileDialog.new()
	_dialog.access = FileDialog.ACCESS_FILESYSTEM
	_dialog.file_mode = FileDialog.FILE_MODE_SAVE_FILE
	_dialog.add_filter("*.csv", "CSV 流水")
	_dialog.file_selected.connect(select_export_path)
	add_child(_dialog)


func _panel(parent: Control) -> PanelContainer:
	var panel := PanelContainer.new()
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var style := StyleBoxFlat.new()
	style.bg_color = Color("fffcf6")
	style.border_color = Color("e0d3be")
	style.set_border_width_all(1)
	style.set_corner_radius_all(10)
	style.set_content_margin_all(14)
	panel.add_theme_stylebox_override("panel", style)
	parent.add_child(panel)
	return panel


func _button(value: String, parent: Control) -> Button:
	var button := Button.new()
	button.text = value
	button.custom_minimum_size.y = 46
	button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	button.add_theme_font_size_override("font_size", 15)
	button.add_theme_color_override("font_color", Color("40372d"))
	button.add_theme_color_override("font_hover_color", Color("332b23"))
	button.add_theme_color_override("font_pressed_color", Color("332b23"))
	button.add_theme_color_override("font_disabled_color", Color("6d6459"))
	var style := StyleBoxFlat.new()
	style.bg_color = Color("f1e7d5")
	style.set_corner_radius_all(9)
	style.set_content_margin_all(10)
	button.add_theme_stylebox_override("normal", style)
	var hover := style.duplicate()
	hover.bg_color = Color("e9d8bc")
	button.add_theme_stylebox_override("hover", hover)
	button.add_theme_stylebox_override("pressed", hover)
	var disabled := style.duplicate()
	disabled.bg_color = Color("eee9e0")
	button.add_theme_stylebox_override("disabled", disabled)
	parent.add_child(button)
	return button


func _label(value: String, size: int, color: Color) -> Label:
	var label := Label.new()
	label.text = value
	label.add_theme_font_size_override("font_size", size)
	label.add_theme_color_override("font_color", color)
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return label
