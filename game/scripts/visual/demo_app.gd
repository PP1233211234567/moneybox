extends Node3D

## Isolated, persisted demonstration of ledger → mapping → inventory → physics.
const DemoFlow = preload("res://scripts/data/demo_flow.gd")
@onready var jar: JarView = $JarView
var _skin_button: Button
var _privacy_button: Button
var _amount_label: Label
var _source_label: Label
var _status_label: Label
var _demo_flow: RefCounted


func _ready() -> void:
	var test_path := OS.get_environment("MONEYBOX_DEMO_STATE_PATH")
	_demo_flow = DemoFlow.new(test_path if not test_path.is_empty() else "user://demo/moneybox")
	_build_overlay()
	_show_committed(_demo_flow.load_or_create())


func _notification(what: int) -> void:
	if not is_node_ready():
		return
	if what == NOTIFICATION_APPLICATION_PAUSED:
		jar.set_active_visible(false)
	elif what == NOTIFICATION_APPLICATION_RESUMED:
		jar.set_active_visible(true)


func _unhandled_key_input(event: InputEvent) -> void:
	if not event is InputEventKey or event.echo:
		return
	if event.pressed:
		match event.keycode:
			KEY_LEFT:
				jar.set_motion_override(Vector3(-GRAVITY, -GRAVITY, 0).normalized() * GRAVITY)
			KEY_RIGHT:
				jar.set_motion_override(Vector3(GRAVITY, -GRAVITY, 0).normalized() * GRAVITY)
			KEY_UP:
				jar.set_motion_override(Vector3(0, GRAVITY, 0))
			KEY_DOWN:
				jar.set_motion_override(Vector3(0, -GRAVITY, -GRAVITY).normalized() * GRAVITY)
			KEY_SPACE:
				jar.set_motion_override(Vector3(0, -GRAVITY, 0), Vector3(16, 0, 0))
	else:
		jar.clear_motion_override()


const GRAVITY := 9.81


func _build_overlay() -> void:
	var canvas := CanvasLayer.new()
	canvas.name = "DemoOverlay"
	add_child(canvas)
	var ui := Control.new()
	ui.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	canvas.add_child(ui)
	var header := VBoxContainer.new()
	header.anchor_right = 1.0
	header.offset_left = 24.0
	header.offset_right = -24.0
	header.offset_top = 36.0
	ui.add_child(header)
	var title := _label("金豆罐 · 演示", 38, Color("34312c"))
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	header.add_child(title)
	_amount_label = _label("正在读取演示状态", 22, Color("665d50"))
	_amount_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	header.add_child(_amount_label)
	_source_label = _label("演示资产不进入正式账本", 18, Color("8d806d"))
	_source_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	header.add_child(_source_label)
	_status_label = _label("", 16, Color("6d675f"))
	_status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	header.add_child(_status_label)

	var footer := VBoxContainer.new()
	footer.anchor_top = 1.0
	footer.anchor_right = 1.0
	footer.anchor_bottom = 1.0
	footer.offset_left = 32.0
	footer.offset_right = -32.0
	footer.offset_top = -248.0
	footer.offset_bottom = -24.0
	footer.add_theme_constant_override("separation", 12)
	ui.add_child(footer)
	var update_buttons := HBoxContainer.new()
	update_buttons.add_theme_constant_override("separation", 12)
	footer.add_child(update_buttons)
	var add_button := _button("演示 +¥1000")
	add_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	add_button.pressed.connect(func() -> void: _record_change("1000"))
	update_buttons.add_child(add_button)
	var reduce_button := _button("演示 -¥1000")
	reduce_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	reduce_button.pressed.connect(func() -> void: _record_change("-1000"))
	update_buttons.add_child(reduce_button)
	var visual_buttons := HBoxContainer.new()
	visual_buttons.add_theme_constant_override("separation", 12)
	footer.add_child(visual_buttons)
	_skin_button = _button("切换生态罐")
	_skin_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_skin_button.pressed.connect(_toggle_skin)
	visual_buttons.add_child(_skin_button)
	_privacy_button = _button("隐藏演示金额")
	_privacy_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_privacy_button.pressed.connect(_toggle_privacy)
	visual_buttons.add_child(_privacy_button)
	var reset_button := _button("重置演示")
	reset_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	reset_button.pressed.connect(jar.reset_demo_layout)
	visual_buttons.add_child(reset_button)
	var personal_button := _button("打开独立个人账本")
	personal_button.pressed.connect(func() -> void: get_tree().change_scene_to_file("res://scenes/personal_main.tscn"))
	footer.add_child(personal_button)
	var hint := _label("方向键倾斜 / 空格摇晃 · 手机使用运动传感器", 16, Color("6d675f"))
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	footer.add_child(hint)


func _toggle_skin() -> void:
	var next_skin := "basic" if jar.get_visual_metrics()["skin_id"] == "ecology" else "ecology"
	_show_committed(_demo_flow.set_skin(next_skin))


func _toggle_privacy() -> void:
	var next_mode := "show_total" if _privacy_button.text == "显示演示金额" else "hide_total"
	_show_committed(_demo_flow.set_privacy_mode(next_mode))


func _record_change(delta: String) -> void:
	_show_committed(_demo_flow.record_cash_change(delta))


func _show_committed(result: Dictionary) -> void:
	if not result.ok:
		_status_label.text = "保存失败：%s；原展示保持不变" % str(result.get("error", "未知错误"))
		return
	var display: Dictionary = result.display_snapshot
	if not jar.apply_display_snapshot(display):
		_status_label.text = "画面更新失败；已保存版本 %d" % int(result.generation)
		return
	if display.snapshot_status != "CURRENT":
		_amount_label.text = "演示金豆为上次完整快照 · 金额待核验"
		_source_label.text = "演示数据 · 当前罐 %d 颗豆" % display.beans.size()
		_status_label.text = "本地版本 %d · 展示快照未匹配当前账本" % int(result.generation)
	else:
		_amount_label.text = "演示金额已隐藏 · 黄金等值 %s g" % display.equivalent_grams if display.privacy_mode == "hide_total" else "演示总资产 ¥%s · 黄金等值 %s g" % [display.display_amount, display.equivalent_grams]
		_source_label.text = "演示数据 · 当前罐 %d 颗豆" % display.beans.size() if display.privacy_mode == "hide_total" else "手工演示金价 ¥%s/g · 当前罐 %d 颗豆" % [result.manual_price, display.beans.size()]
		_status_label.text = "已保存本地版本 %d · 共 %d 个罐" % [int(result.generation), int(display.jar_count)]
	_skin_button.text = "切换基础罐" if display.skin_id == "ecology" else "切换生态罐"
	_privacy_button.text = "显示演示金额" if result.privacy_mode == "hide_total" else "隐藏演示金额"


func _label(value: String, font_size: int, color: Color) -> Label:
	var label := Label.new()
	label.text = value
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", color)
	return label


func _button(value: String) -> Button:
	var button := Button.new()
	button.text = value
	button.custom_minimum_size.y = 60.0
	button.add_theme_font_size_override("font_size", 18)
	button.add_theme_color_override("font_color", Color("34312c"))
	var style := StyleBoxFlat.new()
	style.bg_color = Color("f1e7d5")
	style.corner_radius_top_left = 14
	style.corner_radius_top_right = 14
	style.corner_radius_bottom_left = 14
	style.corner_radius_bottom_right = 14
	button.add_theme_stylebox_override("normal", style)
	var hover := style.duplicate()
	hover.bg_color = Color("ead6b0")
	button.add_theme_stylebox_override("hover", hover)
	return button
