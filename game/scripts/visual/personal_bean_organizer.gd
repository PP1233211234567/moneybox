extends Control
## A local, confirmed 1g/10g arrangement page. It never submits finance commands.

signal return_requested

const Flow = preload("res://scripts/domain/personal_bean_organizer_flow.gd")
const DEFAULT_PATH := "user://personal/moneybox"

@export var base_path := DEFAULT_PATH

var _flow: RefCounted
var _view: Dictionary = {}
var _shown_preview: Dictionary = {}
var _mode := "COMBINE"
var _jar_picker: OptionButton
var _item_list: ItemList
var _item_bean_ids: Array[String] = []
var _status_label: Label
var _preview_label: Label
var _confirm_button: Button
var _return_button: Button


func _ready() -> void:
	var test_path := OS.get_environment("MONEYBOX_PERSONAL_STATE_PATH")
	_flow = Flow.new(test_path if base_path == DEFAULT_PATH and not test_path.is_empty()
		else base_path)
	_build()
	_refresh()


func _build() -> void:
	var background := ColorRect.new()
	background.color = Color("faf7f0")
	background.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(background)
	var scroller := ScrollContainer.new()
	scroller.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	scroller.offset_left = 22.0
	scroller.offset_right = -22.0
	scroller.offset_top = 28.0
	scroller.offset_bottom = -20.0
	add_child(scroller)
	var content := VBoxContainer.new()
	content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content.add_theme_constant_override("separation", 12)
	scroller.add_child(content)
	var title := _label("整理金豆", 30)
	content.add_child(title)
	content.add_child(_label("只改变 1 克与 10 克外观；总克数、账本和行情不会改变。", 15))
	_status_label = _label("读取个人项目…", 15)
	content.add_child(_status_label)
	_jar_picker = OptionButton.new()
	_jar_picker.custom_minimum_size.y = 44.0
	_style_button(_jar_picker)
	_jar_picker.item_selected.connect(func(_index: int) -> void: _change_jar())
	content.add_child(_jar_picker)
	var mode_row := HBoxContainer.new()
	mode_row.add_theme_constant_override("separation", 8)
	content.add_child(mode_row)
	var combine_button := _button("选十颗 1 克合成")
	combine_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	combine_button.pressed.connect(func() -> void: _set_mode("COMBINE"))
	mode_row.add_child(combine_button)
	var split_button := _button("选一颗 10 克拆分")
	split_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	split_button.pressed.connect(func() -> void: _set_mode("SPLIT"))
	mode_row.add_child(split_button)
	_item_list = ItemList.new()
	_item_list.custom_minimum_size.y = 310.0
	_item_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_item_list.add_theme_font_size_override("font_size", 15)
	_item_list.add_theme_color_override("font_color", Color("34312c"))
	_item_list.add_theme_color_override("font_selected_color", Color("34312c"))
	var list_style := StyleBoxFlat.new()
	list_style.bg_color = Color("fffdf8")
	list_style.border_color = Color("dacbb5")
	list_style.set_border_width_all(1)
	list_style.set_corner_radius_all(10)
	_item_list.add_theme_stylebox_override("panel", list_style)
	var selected_style := StyleBoxFlat.new()
	selected_style.bg_color = Color("ebd7ad")
	selected_style.set_corner_radius_all(5)
	_item_list.add_theme_stylebox_override("selected", selected_style)
	_item_list.add_theme_stylebox_override("selected_focus", selected_style)
	_item_list.select_mode = ItemList.SELECT_MULTI
	_item_list.item_selected.connect(func(_index: int) -> void: _invalidate_preview())
	_item_list.multi_selected.connect(func(_index: int, _selected: bool) -> void:
		_invalidate_preview())
	content.add_child(_item_list)
	var preview_button := _button("预览选择")
	preview_button.pressed.connect(_on_preview_pressed)
	content.add_child(preview_button)
	_preview_label = _label("请在当前罐选择金豆，再预览操作。", 16)
	_preview_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	content.add_child(_preview_label)
	_confirm_button = _button("确认并保存整理")
	_confirm_button.disabled = true
	_confirm_button.pressed.connect(_on_confirm_pressed)
	content.add_child(_confirm_button)
	_return_button = _button("返回个人金豆罐")
	_return_button.pressed.connect(_on_return_pressed)
	content.add_child(_return_button)


func _refresh() -> void:
	_invalidate_preview()
	_view = _flow.load()
	_jar_picker.clear()
	_item_list.clear()
	_item_bean_ids.clear()
	if not _view.ok:
		_status_label.text = "个人罐尚未可整理：" + str(_view.get("error", "读取失败"))
		return
	for jar in _view.jars:
		_jar_picker.add_item("%s · 1 克 %d 颗 · 10 克 %d 颗" % [
			str(jar.id), int(jar.one_count), int(jar.ten_count)])
	var selected_index := 0
	for index in _view.jars.size():
		if str(_view.jars[index].id) == str(_view.selected_jar):
			selected_index = index
	_jar_picker.select(selected_index)
	_status_label.text = "个人项目第 %d 版 · %s · 总完整克数 %s" % [
		int(_view.generation),
		"上次完整快照，待重估" if _view.snapshot_status != "CURRENT" else "当前完整快照",
		str(_view.whole_grams)]
	_render_items()


func _set_mode(mode: String) -> void:
	_mode = mode
	_item_list.select_mode = ItemList.SELECT_MULTI if mode == "COMBINE" else ItemList.SELECT_SINGLE
	_render_items()
	_invalidate_preview()


func _change_jar() -> void:
	_render_items()
	_invalidate_preview()


func _render_items() -> void:
	_item_list.clear()
	_item_bean_ids.clear()
	if not _view.get("ok", false) or _jar_picker.selected < 0 \
			or _jar_picker.selected >= _view.jars.size():
		return
	var jar: Dictionary = _view.jars[_jar_picker.selected]
	for bean in jar.beans:
		var grams := int(bean.denomination_grams)
		if (_mode == "COMBINE" and grams != 1) or (_mode == "SPLIT" and grams != 10):
			continue
		_item_list.add_item("%d 克 · %s" % [grams, str(bean.id)])
		_item_bean_ids.append(str(bean.id))
	if _item_bean_ids.is_empty():
		_preview_label.text = "当前罐没有适合这项操作的金豆。"


func _on_preview_pressed() -> void:
	_invalidate_preview()
	if not _view.get("ok", false) or _jar_picker.selected < 0:
		_preview_label.text = "请先建立个人金豆罐。"
		return
	var ids: Array = []
	for index in _item_list.get_selected_items():
		ids.append(_item_bean_ids[index])
	if ids.size() != (10 if _mode == "COMBINE" else 1):
		_preview_label.text = "合成请选 10 颗 1 克豆；拆分请选 1 颗 10 克豆。"
		return
	var jar_id := str(_view.jars[_jar_picker.selected].id)
	var result: Dictionary = _flow.preview_combine(jar_id, ids,
		int(_view.generation)) if _mode == "COMBINE" else \
		_flow.preview_split(jar_id, str(ids[0]), int(_view.generation))
	if not result.ok:
		_preview_label.text = "预览失败：" + str(result.get("error", "未知错误"))
		return
	_shown_preview = result
	_preview_label.text = "%s · %s：当前罐 %d → %d 颗；总完整克数仍为 %s。预览尚未保存。" % [
		"合成" if _mode == "COMBINE" else "拆分", jar_id,
		int(result.before_objects), int(result.after_objects), str(result.whole_grams)]
	_confirm_button.disabled = false


func _on_confirm_pressed() -> void:
	if _shown_preview.is_empty():
		return
	var result: Dictionary = _flow.confirm(_shown_preview, true)
	if not result.ok:
		_invalidate_preview()
		_preview_label.text = "未保存：" + str(result.get("error", "未知错误")) + "。请刷新并重新预览。"
		return
	_refresh()
	_preview_label.text = "已保存整理；总克数不变。可返回罐体查看结果。"


func _invalidate_preview() -> void:
	_shown_preview = {}
	if _confirm_button != null:
		_confirm_button.disabled = true


func _on_return_pressed() -> void:
	return_requested.emit()
	if get_tree().current_scene == self:
		get_tree().change_scene_to_file("res://scenes/personal_main.tscn")


func _label(value: String, size: int) -> Label:
	var label := Label.new()
	label.text = value
	label.add_theme_font_size_override("font_size", size)
	label.add_theme_color_override("font_color", Color("36312a"))
	return label


func _button(value: String) -> Button:
	var button := Button.new()
	button.text = value
	button.custom_minimum_size.y = 46.0
	_style_button(button)
	return button


func _style_button(button: Button) -> void:
	button.add_theme_font_size_override("font_size", 16)
	button.add_theme_color_override("font_color", Color("34312c"))
	button.add_theme_color_override("font_hover_color", Color("34312c"))
	button.add_theme_color_override("font_pressed_color", Color("34312c"))
	button.add_theme_color_override("font_disabled_color", Color("82796c"))
	var style := StyleBoxFlat.new()
	style.bg_color = Color("f1e5cf")
	style.set_corner_radius_all(10)
	button.add_theme_stylebox_override("normal", style)
	var hover := style.duplicate()
	hover.bg_color = Color("e8d4ad")
	button.add_theme_stylebox_override("hover", hover)
	var pressed := style.duplicate()
	pressed.bg_color = Color("dec594")
	button.add_theme_stylebox_override("pressed", pressed)
	var disabled := style.duplicate()
	disabled.bg_color = Color("e8e3d9")
	button.add_theme_stylebox_override("disabled", disabled)
