extends Control
## P15 local plaintext backup/restore page for the personal project.

const Store = preload("res://scripts/data/project_store.gd")
const Backup = preload("res://scripts/backup/backup_service.gd")
const DEFAULT_PATH := "user://personal/moneybox"
const RETURN_SCENE := "res://scenes/personal_main.tscn"
const COUNT_LABELS := {
	"accounts": "账户", "instruments": "证券", "other_assets": "其他资产", "events": "流水", "quotes": "行情",
	"mappings": "黄金映射", "beans": "金豆", "ecology_entries": "生态记录",
}

@export var base_path := DEFAULT_PATH
@export var safety_directory := ""

var _store: RefCounted
var _backup: RefCounted
var _allowed := false
var _export_path := ""
var _restore_path := ""
var _shown_preview: Dictionary = {}
var _dialog_armed := false

var _status_label: Label
var _export_path_label: Label
var _restore_path_label: Label
var _preview_label: Label
var _export_choose_button: Button
var _export_button: Button
var _restore_choose_button: Button
var _preview_button: Button
var _confirm_button: Button
var _back_button: Button
var _export_dialog: FileDialog
var _restore_dialog: FileDialog
var _confirmation_dialog: ConfirmationDialog


func _ready() -> void:
	if base_path == DEFAULT_PATH:
		var test_path := OS.get_environment("MONEYBOX_PERSONAL_STATE_PATH")
		if not test_path.is_empty():
			base_path = test_path
	_store = Store.new(base_path)
	_backup = Backup.new(safety_directory) if not safety_directory.is_empty() else Backup.new()
	_build_ui()
	_refresh_current()


func get_export_choose_button() -> Button:
	return _export_choose_button


func get_export_button() -> Button:
	return _export_button


func get_restore_choose_button() -> Button:
	return _restore_choose_button


func get_preview_button() -> Button:
	return _preview_button


func get_confirm_button() -> Button:
	return _confirm_button


func get_confirmation_dialog() -> ConfirmationDialog:
	return _confirmation_dialog


func get_back_button() -> Button:
	return _back_button


func get_status_text() -> String:
	return _status_label.text


func get_preview_text() -> String:
	return _preview_label.text


func get_export_path_text() -> String:
	return _export_path_label.text


func get_restore_path_text() -> String:
	return _restore_path_label.text


func select_export_path(path: String) -> void:
	# Called by the file dialog; tests invoke the same callback with a synthetic path.
	_export_path = ""
	_export_button.disabled = true
	if not _allowed or path.is_empty():
		return
	if FileAccess.file_exists(path):
		_export_path_label.text = "目标文件已存在。请重新选择一个新文件；不会覆盖。"
		return
	_export_path = path
	_export_path_label.text = "已选择新文件：" + path.get_file()
	_export_button.disabled = false


func select_restore_path(path: String) -> void:
	# Choosing another file always discards a previous preview and confirmation.
	_invalidate_preview()
	_restore_path = ""
	_preview_button.disabled = true
	if not _allowed or path.is_empty():
		return
	if not FileAccess.file_exists(path):
		_restore_path_label.text = "备份文件不存在，请重新选择。"
		return
	_restore_path = path
	_restore_path_label.text = "已选择备份：" + path.get_file()
	_preview_button.disabled = false


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
	content.add_child(_label("备份与恢复", 27, Color("34312c")))
	_back_button = _button("返回个人金豆罐", content)
	_back_button.pressed.connect(_on_back_pressed)
	_status_label = _label("正在读取个人项目…", 15, Color("665d50"))
	content.add_child(_status_label)
	var warning := _panel(content)
	warning.add_child(_label("当前导出是明文 JSON，文件中包含完整账本。任何能读取文件的人都可能看到资产数据；不适合上传或放在共享云盘。", 15, Color("8a4e37")))
	content.add_child(_label("此页使用 Godot 文件对话框；Android 系统文件选择器尚未验证。", 13, Color("776c5c")))
	var export_panel := _panel(content)
	var export_content := _column(export_panel)
	export_content.add_child(_label("导出完整项目", 21, Color("594a38")))
	export_content.add_child(_label("先选择一个不存在的 JSON 文件，再点击导出。页面和服务都会拒绝覆盖现有文件。", 14, Color("665d50")))
	_export_path_label = _label("尚未选择导出位置", 14, Color("776c5c"))
	export_content.add_child(_export_path_label)
	_export_choose_button = _button("选择新文件…", export_content)
	_export_choose_button.pressed.connect(func() -> void: _export_dialog.popup_centered_ratio(0.85))
	_export_button = _button("导出明文 JSON", export_content)
	_export_button.disabled = true
	_export_button.pressed.connect(_on_export_pressed)
	var restore_panel := _panel(content)
	var restore_content := _column(restore_panel)
	restore_content.add_child(_label("恢复完整项目", 21, Color("594a38")))
	restore_content.add_child(_label("恢复会替换当前项目。先选择备份并比较记录数量；确认前不会写入。", 14, Color("665d50")))
	_restore_path_label = _label("尚未选择备份文件", 14, Color("776c5c"))
	restore_content.add_child(_restore_path_label)
	_restore_choose_button = _button("选择备份文件…", restore_content)
	_restore_choose_button.pressed.connect(func() -> void: _restore_dialog.popup_centered_ratio(0.85))
	_preview_button = _button("预览恢复差异", restore_content)
	_preview_button.disabled = true
	_preview_button.pressed.connect(_on_preview_pressed)
	_preview_label = _label("预览会校验格式、哈希和数据结构，并显示备份与当前项目的差异。", 14, Color("665d50"))
	restore_content.add_child(_preview_label)
	_confirm_button = _button("继续恢复…", restore_content)
	_confirm_button.disabled = true
	_confirm_button.pressed.connect(_on_continue_restore_pressed)
	_export_dialog = FileDialog.new()
	_export_dialog.access = FileDialog.ACCESS_FILESYSTEM
	_export_dialog.file_mode = FileDialog.FILE_MODE_SAVE_FILE
	_export_dialog.add_filter("*.json", "JSON 备份")
	_export_dialog.file_selected.connect(select_export_path)
	add_child(_export_dialog)
	_restore_dialog = FileDialog.new()
	_restore_dialog.access = FileDialog.ACCESS_FILESYSTEM
	_restore_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	_restore_dialog.add_filter("*.json", "JSON 备份")
	_restore_dialog.file_selected.connect(select_restore_path)
	add_child(_restore_dialog)
	_confirmation_dialog = ConfirmationDialog.new()
	_confirmation_dialog.title = "确认恢复个人项目"
	_confirmation_dialog.ok_button_text = "确认替换并恢复"
	_confirmation_dialog.confirmed.connect(_on_restore_confirmed)
	_confirmation_dialog.canceled.connect(_on_restore_canceled)
	add_child(_confirmation_dialog)


func _refresh_current() -> void:
	var loaded: Dictionary = _store.load_project()
	_allowed = loaded.ok and loaded.state.get("data_kind", "") == "personal"
	_export_choose_button.disabled = not _allowed
	_restore_choose_button.disabled = not _allowed
	_export_button.disabled = not _allowed or _export_path.is_empty()
	_preview_button.disabled = not _allowed or _restore_path.is_empty()
	if not _allowed:
		_invalidate_preview()
		_status_label.text = "无法读取个人项目；演示项目不能通过此页备份或恢复。" if loaded.ok else \
			"读取项目失败：" + str(loaded.get("error", "UNKNOWN"))
		return
	_status_label.text = "当前个人项目第 %d 版。恢复前会另存一份当前状态。" % int(loaded.generation)


func _on_export_pressed() -> void:
	if not _allowed or _export_path.is_empty():
		return
	var result: Dictionary = _backup.export_project(_store, _export_path)
	if not result.ok:
		_status_label.text = "导出失败：" + str(result.error) + "。请重新选择新文件。"
		_export_path = ""
		_export_button.disabled = true
		return
	_export_path = ""
	_export_path_label.text = "明文 JSON 已导出。请在安全位置保管该文件。"
	_export_button.disabled = true
	_status_label.text = "导出成功；当前项目未改变。"


func _on_preview_pressed() -> void:
	_invalidate_preview()
	if not _allowed or _restore_path.is_empty():
		return
	var result: Dictionary = _backup.preview_backup(_restore_path, _store)
	if not result.ok:
		_preview_label.text = "预览失败：" + str(result.error) + "。当前项目未改变。"
		return
	_shown_preview = result
	_preview_label.text = _format_preview(result)
	_confirm_button.disabled = false


func _on_continue_restore_pressed() -> void:
	if _shown_preview.is_empty() or not _allowed or _restore_path.is_empty():
		return
	_dialog_armed = true
	_confirmation_dialog.dialog_text = "将按预览替换当前个人项目。恢复前会保存当前项目的私有安全副本。\n\n" + \
		_format_preview(_shown_preview) + "\n\n确认恢复？"
	_confirmation_dialog.popup_centered_ratio(0.86)


func _on_restore_confirmed() -> void:
	if not _dialog_armed or _shown_preview.is_empty() or _restore_path.is_empty() or not _allowed:
		return
	_dialog_armed = false
	var result: Dictionary = _backup.restore_project(_store, _restore_path, _shown_preview)
	_invalidate_preview()
	if not result.ok:
		_preview_label.text = "恢复未完成：" + str(result.error) + "。请重新读取项目状态并预览。"
		_refresh_current()
		return
	_restore_path = ""
	_restore_path_label.text = "恢复完成；再次恢复须重新选择备份。"
	_preview_button.disabled = true
	_refresh_current()
	_preview_label.text = "已恢复到新的项目版本；恢复前状态已保存在应用私有备份目录。"


func _on_restore_canceled() -> void:
	_dialog_armed = false


func _on_back_pressed() -> void:
	get_tree().change_scene_to_file(RETURN_SCENE)


func _invalidate_preview() -> void:
	_shown_preview = {}
	_dialog_armed = false
	if _confirm_button != null:
		_confirm_button.disabled = true
	if _preview_label != null:
		_preview_label.text = "预览已失效；请重新预览当前备份。"


func _format_preview(preview: Dictionary) -> String:
	var lines: Array[String] = []
	var backup_generation: Variant = preview.get("backup_generation", null)
	if (typeof(backup_generation) == TYPE_INT or typeof(backup_generation) == TYPE_FLOAT) and \
			int(backup_generation) >= 0:
		lines.append("备份文件声明的来源第 %d 版 → 当前第 %d 版（版本差 %+d）" % [
			int(backup_generation), int(preview.current_generation),
			int(backup_generation) - int(preview.current_generation)])
	else:
		lines.append("备份来源版本未知 → 当前第 %d 版；无法比较版本差。" % int(preview.current_generation))
	lines.append("备份 Schema：%d。记录数量对比（备份 → 当前）：" % int(preview.backup_schema_version))
	var backup_counts: Dictionary = preview.backup_counts
	var current_counts: Dictionary = preview.current_counts
	for key in ["accounts", "instruments", "other_assets", "events", "quotes", "mappings", "beans", "ecology_entries"]:
		var backup_count := int(backup_counts.get(key, 0))
		var current_count := int(current_counts.get(key, 0))
		lines.append("%s：%d → %d（差 %+d）" % [COUNT_LABELS[key], backup_count,
			current_count, backup_count - current_count])
	lines.append("这是明文 JSON；确认恢复后替换当前项目。")
	return "\n".join(lines)


func _column(parent: Control) -> VBoxContainer:
	var column := VBoxContainer.new()
	column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	column.add_theme_constant_override("separation", 9)
	parent.add_child(column)
	return column


func _panel(parent: Control) -> PanelContainer:
	var panel := PanelContainer.new()
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var style := StyleBoxFlat.new()
	style.bg_color = Color("fffcf6")
	style.border_color = Color("e0d3be")
	style.set_border_width_all(1)
	style.set_corner_radius_all(10)
	style.content_margin_left = 14.0
	style.content_margin_right = 14.0
	style.content_margin_top = 12.0
	style.content_margin_bottom = 12.0
	panel.add_theme_stylebox_override("panel", style)
	parent.add_child(panel)
	return panel


func _label(value: String, size: int, color: Color) -> Label:
	var label := Label.new()
	label.text = value
	label.add_theme_font_size_override("font_size", size)
	label.add_theme_color_override("font_color", color)
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return label


func _button(value: String, parent: Control) -> Button:
	var button := Button.new()
	button.text = value
	button.custom_minimum_size.y = 42.0
	button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	button.add_theme_font_size_override("font_size", 15)
	button.add_theme_color_override("font_color", Color("40372d"))
	button.add_theme_color_override("font_hover_color", Color("332b23"))
	button.add_theme_color_override("font_pressed_color", Color("332b23"))
	button.add_theme_color_override("font_focus_color", Color("40372d"))
	button.add_theme_color_override("font_disabled_color", Color("6d6459"))
	var style := StyleBoxFlat.new()
	style.bg_color = Color("f1e7d5")
	style.set_corner_radius_all(9)
	style.content_margin_left = 10.0
	style.content_margin_right = 10.0
	button.add_theme_stylebox_override("normal", style)
	var hover := style.duplicate()
	hover.bg_color = Color("e9d8bc")
	button.add_theme_stylebox_override("hover", hover)
	var pressed := style.duplicate()
	pressed.bg_color = Color("ddc9a8")
	button.add_theme_stylebox_override("pressed", pressed)
	var disabled := style.duplicate()
	disabled.bg_color = Color("eee9e0")
	button.add_theme_stylebox_override("disabled", disabled)
	parent.add_child(button)
	return button
