extends Node3D
## Separate personal cash flow. Demo state is never read or promoted here.

const PersonalFlow = preload("res://scripts/data/personal_flow.gd")
const ProjectStore = preload("res://scripts/data/project_store.gd")
@onready var jar: JarView = $JarView
@onready var _camera: Camera3D = $Camera3D

var _flow: RefCounted
var _store: RefCounted
var _ecology_state: Dictionary = {}
var _generation := 0
var _account_id := ""
var _jar_ids: Array[String] = []
var _selected_jar := ""
var _skin_id := "basic"
var _privacy_mode := "show_total"
var _pending_opening_id := ""
var _footer: VBoxContainer
var _actions: HBoxContainer
var _onboarding: VBoxContainer
var _updating: VBoxContainer
var _name_input: LineEdit
var _amount_input: LineEdit
var _gold_input: LineEdit
var _delta_input: LineEdit
var _update_button: Button
var _amount_label: Label
var _source_label: Label
var _status_label: Label
var _skin_button: Button
var _privacy_button: Button
var _jar_button: Button
var _asset_button: Button
var _revaluation_button: Button
var _more_button: MenuButton
var _ecology_panel: VBoxContainer
var _ecology_label: Label
var _ecology_feed_button: Button
var _ecology_plant_button: Button


func _ready() -> void:
	var test_path := OS.get_environment("MONEYBOX_PERSONAL_STATE_PATH")
	var base_path := test_path if not test_path.is_empty() else "user://personal/moneybox"
	_flow = PersonalFlow.new(base_path)
	_store = ProjectStore.new(base_path)
	_pending_opening_id = _new_id("opening")
	_build_overlay()
	_show(_flow.load())


func _notification(what: int) -> void:
	if not is_node_ready():
		return
	if what == NOTIFICATION_APPLICATION_PAUSED:
		jar.set_active_visible(false)
	elif what == NOTIFICATION_APPLICATION_RESUMED:
		jar.set_active_visible(true)


func _build_overlay() -> void:
	var canvas := CanvasLayer.new()
	canvas.name = "PersonalOverlay"
	add_child(canvas)
	var ui := Control.new()
	ui.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	canvas.add_child(ui)
	var header := Control.new()
	header.anchor_right = 1.0
	header.offset_left = 24.0
	header.offset_right = -24.0
	header.offset_top = 36.0
	header.offset_bottom = 160.0
	ui.add_child(header)
	var title := _label("金豆罐 · 个人账本", 34, Color("34312c"))
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_place_header_line(title, 0.0, 44.0)
	header.add_child(title)
	_amount_label = _label("正在读取个人账本", 21, Color("665d50"))
	_amount_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_place_header_line(_amount_label, 48.0, 73.0)
	header.add_child(_amount_label)
	_source_label = _label("", 17, Color("8d806d"))
	_source_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_place_header_line(_source_label, 76.0, 97.0)
	header.add_child(_source_label)
	_status_label = _label("", 16, Color("6d675f"))
	_status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_place_header_line(_status_label, 100.0, 122.0)
	header.add_child(_status_label)

	_footer = VBoxContainer.new()
	_footer.anchor_top = 1.0
	_footer.anchor_right = 1.0
	_footer.anchor_bottom = 1.0
	_footer.offset_left = 32.0
	_footer.offset_right = -32.0
	_footer.offset_top = -350.0
	_footer.offset_bottom = -22.0
	_footer.add_theme_constant_override("separation", 8)
	ui.add_child(_footer)
	_onboarding = VBoxContainer.new()
	_onboarding.add_theme_constant_override("separation", 8)
	_footer.add_child(_onboarding)
	var intro := _label("先记录一个人民币现金账户，再输入自己确认的手工黄金参考价。", 15, Color("665d50"))
	intro.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_onboarding.add_child(intro)
	_name_input = _line_input("账户名称，例如现金或银行卡")
	_onboarding.add_child(_name_input)
	_amount_input = _line_input("期初现金，人民币十进制金额")
	_onboarding.add_child(_amount_input)
	_gold_input = _line_input("手工黄金参考价，人民币/克")
	_onboarding.add_child(_gold_input)
	var create_button := _button("确认并保存个人账本")
	create_button.pressed.connect(_create_opening)
	_onboarding.add_child(create_button)

	_updating = VBoxContainer.new()
	_updating.add_theme_constant_override("separation", 8)
	_footer.add_child(_updating)
	var change_label := _label("增减现金：正数增加，负数减少", 15, Color("665d50"))
	_updating.add_child(change_label)
	var update_row := HBoxContainer.new()
	update_row.add_theme_constant_override("separation", 10)
	_updating.add_child(update_row)
	_delta_input = _line_input("如 1000 或 -1000")
	_delta_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	update_row.add_child(_delta_input)
	_update_button = _button("确认保存")
	_update_button.pressed.connect(_record_change)
	update_row.add_child(_update_button)

	_actions = HBoxContainer.new()
	_actions.add_theme_constant_override("separation", 8)
	_footer.add_child(_actions)
	_skin_button = _button("生态罐")
	_skin_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_skin_button.pressed.connect(_toggle_skin)
	_actions.add_child(_skin_button)
	_privacy_button = _button("隐藏金额")
	_privacy_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_privacy_button.pressed.connect(_toggle_privacy)
	_actions.add_child(_privacy_button)
	_jar_button = _button("下一罐")
	_jar_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_jar_button.pressed.connect(_next_jar)
	_actions.add_child(_jar_button)
	_asset_button = _button("记录资产")
	_asset_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_asset_button.pressed.connect(func() -> void: get_tree().change_scene_to_file("res://scenes/personal_asset_entry.tscn"))
	_actions.add_child(_asset_button)
	_revaluation_button = _button("手工重估")
	_revaluation_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_revaluation_button.pressed.connect(func() -> void: get_tree().change_scene_to_file("res://scenes/personal_manual_revaluation.tscn"))
	_actions.add_child(_revaluation_button)
	_more_button = MenuButton.new()
	_more_button.flat = false
	_more_button.text = "更多"
	_more_button.custom_minimum_size.y = 56.0
	_more_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_more_button.add_theme_font_size_override("font_size", 17)
	_more_button.add_theme_color_override("font_color", Color("34312c"))
	var more_style := StyleBoxFlat.new()
	more_style.bg_color = Color("f1e7d5")
	more_style.set_corner_radius_all(12)
	_more_button.add_theme_stylebox_override("normal", more_style)
	var more_popup := _more_button.get_popup()
	more_popup.add_item("总览与账户", 1)
	more_popup.add_item("整理金豆", 2)
	more_popup.add_item("交易草稿", 3)
	more_popup.add_item("粘贴 CSV", 4)
	more_popup.add_item("备份与恢复", 5)
	more_popup.add_item("账户对账", 6)
	more_popup.add_item("流水记录", 7)
	more_popup.add_item("导出流水 CSV", 8)
	more_popup.id_pressed.connect(_open_more)
	_actions.add_child(_more_button)
	_ecology_panel = VBoxContainer.new()
	_ecology_panel.add_theme_constant_override("separation", 7)
	_footer.add_child(_ecology_panel)
	_ecology_label = _label("外层生态独立于账本和金豆", 14, Color("517565"))
	_ecology_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_ecology_panel.add_child(_ecology_label)
	var life_row := HBoxContainer.new()
	life_row.add_theme_constant_override("separation", 8)
	_ecology_panel.add_child(life_row)
	var fish_button := _button("添小鱼")
	fish_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	fish_button.pressed.connect(_add_fish)
	life_row.add_child(fish_button)
	var shrimp_button := _button("添小虾")
	shrimp_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	shrimp_button.pressed.connect(_add_shrimp)
	life_row.add_child(shrimp_button)
	var care_row := HBoxContainer.new()
	care_row.add_theme_constant_override("separation", 8)
	_ecology_panel.add_child(care_row)
	_ecology_plant_button = _button("种海草")
	_ecology_plant_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_ecology_plant_button.pressed.connect(_add_or_move_plant)
	care_row.add_child(_ecology_plant_button)
	_ecology_feed_button = _button("投喂鱼虾")
	_ecology_feed_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_ecology_feed_button.pressed.connect(_feed_first_organism)
	care_row.add_child(_ecology_feed_button)
	_ecology_panel.visible = false
	var demo_button := _button("返回隔离演示罐")
	demo_button.pressed.connect(func() -> void: get_tree().change_scene_to_file("res://scenes/main.tscn"))
	_footer.add_child(demo_button)


func _create_opening() -> void:
	var result: Dictionary = _flow.create_opening_cash(_pending_opening_id, "cash-1",
		_name_input.text, _amount_input.text, _gold_input.text, _now_utc())
	_show(result)


func _record_change() -> void:
	var result: Dictionary = _flow.record_cash_change(_new_id("cash"), _account_id,
		_delta_input.text, _now_utc(), _generation)
	if result.ok:
		_delta_input.clear()
	_show(result)


func _toggle_skin() -> void:
	_submit_ecology({"type": "SET_SKIN", "skin_id": "basic" if _skin_id == "ecology" else "ecology"})


func _add_fish() -> void:
	var count: int = _ecology_state.get("organisms", []).size()
	_submit_ecology({"type": "ADD_ORGANISM", "species_id": "small-fish", "kind": "fish",
		"x_per_mille": 250 + (count * 173) % 500, "y_per_mille": 400 + (count * 89) % 350})


func _add_shrimp() -> void:
	var count: int = _ecology_state.get("organisms", []).size()
	_submit_ecology({"type": "ADD_ORGANISM", "species_id": "ornamental-shrimp", "kind": "shrimp",
		"x_per_mille": 700 - (count * 137) % 500, "y_per_mille": 650 + (count * 73) % 300})


func _add_or_move_plant() -> void:
	var plants: Array = _ecology_state.get("plants", [])
	if plants.is_empty():
		_submit_ecology({"type": "ADD_PLANT", "species_id": "seagrass-jade",
			"x_per_mille": 300, "depth_per_mille": 800})
	else:
		var plant: Dictionary = plants[0]
		_submit_ecology({"type": "MOVE_PLANT", "plant_id": plant.id,
			"x_per_mille": (int(plant.anchor.x_per_mille) + 200) % 1001,
			"depth_per_mille": int(plant.anchor.depth_per_mille)})


func _feed_first_organism() -> void:
	var organisms: Array = _ecology_state.get("organisms", [])
	if organisms.is_empty():
		_status_label.text = "请先添一条鱼或一只虾"
		return
	_submit_ecology({"type": "FEED", "organism_id": organisms[0].id})


func _submit_ecology(fields: Dictionary) -> void:
	if _ecology_state.is_empty():
		_status_label.text = "生态状态尚未可用"
		return
	var command := {"command_id": _new_id("ecology"),
		"expected_version": int(_ecology_state.scene.version),
		"effective_at": _now_utc()}
	command.merge(fields)
	var saved: Dictionary = _store.commit_ecology_command(command, _generation)
	if not saved.ok:
		_status_label.text = "生态操作未保存：%s" % str(saved.get("error", "未知错误"))
		return
	_show(_flow.load())


func _toggle_privacy() -> void:
	_show(_flow.set_presentation("privacy_mode", "show_total" if _privacy_mode == "hide_total" else "hide_total", _generation))


func _next_jar() -> void:
	if _jar_ids.is_empty():
		return
	var next := (_jar_ids.find(_selected_jar) + 1) % _jar_ids.size()
	_show(_flow.select_jar(_jar_ids[next], _generation))


func _open_more(id: int) -> void:
	var scene_path := ""
	match id:
		1:
			scene_path = "res://scenes/personal_overview.tscn"
		2:
			scene_path = "res://scenes/personal_bean_organizer.tscn"
		3:
			scene_path = "res://scenes/personal_trade_draft.tscn"
		4:
			scene_path = "res://scenes/personal_csv_import.tscn"
		5:
			scene_path = "res://scenes/personal_backup_restore.tscn"
		6:
			scene_path = "res://scenes/personal_reconciliation.tscn"
		7:
			scene_path = "res://scenes/personal_ledger_history.tscn"
		8:
			scene_path = "res://scenes/personal_csv_export.tscn"
	if not scene_path.is_empty():
		get_tree().change_scene_to_file(scene_path)


func _show(result: Dictionary) -> void:
	if not result.ok:
		_status_label.text = "操作未保存：%s" % str(result.get("error", "未知错误"))
		return
	_generation = int(result.generation)
	if not jar.apply_display_snapshot(result.display_snapshot):
		_status_label.text = "数据已保存；罐体显示失败，请重新打开页面"
		return
	var ecology_ok := _refresh_ecology(_generation)
	if not result.initialized:
		_amount_label.text = "尚无个人资产记录 · 空罐"
		_source_label.text = "可以返回隔离演示罐体验画面"
		_status_label.text = "本地个人账本尚未建立"
		_onboarding.visible = true
		_updating.visible = false
		_actions.visible = false
		_ecology_panel.visible = false
		_footer.offset_top = -350.0
		_skin_button.disabled = true
		_privacy_button.disabled = true
		_jar_button.disabled = true
		_asset_button.disabled = true
		_revaluation_button.disabled = true
		_more_button.disabled = true
		_camera.size = 5.4
		_camera.position.y = 0.99
		return
	_account_id = str(result.account_id)
	_jar_ids.assign(result.jar_ids)
	_selected_jar = str(result.selected_jar)
	_skin_id = str(result.display_snapshot.skin_id)
	_privacy_mode = str(result.privacy_mode)
	_onboarding.visible = false
	_updating.visible = true
	_actions.visible = true
	_ecology_panel.visible = _skin_id == "ecology"
	_footer.offset_top = -390.0 if _ecology_panel.visible else -235.0
	_camera.size = 7.0 if _ecology_panel.visible else 5.4
	_camera.position.y = 0.59 if _ecology_panel.visible else 0.99
	_skin_button.disabled = false
	_privacy_button.disabled = false
	_jar_button.visible = _jar_ids.size() >= 2
	_jar_button.disabled = _jar_ids.size() < 2
	_asset_button.disabled = false
	_revaluation_button.disabled = false
	_more_button.disabled = false
	var pending: bool = result.display_snapshot.snapshot_status != "CURRENT"
	_revaluation_button.text = "去重估" if pending else "手工重估"
	var cash_only: bool = result.get("cash_only", false)
	_update_button.disabled = pending or not cash_only
	_delta_input.editable = not pending and cash_only
	if pending:
		_amount_label.text = "账本已保存 · 金豆为上次完整快照"
		_source_label.text = "上次完整快照 · 当前罐 %d 颗" % result.display_snapshot.beans.size()
		_status_label.text = "账本已保存版本 %d · 当前快照尚待完整校验或重估" % _generation
	else:
		_amount_label.text = "金额已隐藏 · 黄金等值 %s g" % result.equivalent_grams if _privacy_mode == "hide_total" else "总资产 ¥%s · 黄金等值 %s g" % [result.amount, result.equivalent_grams]
		var reference: Dictionary = result.get("gold_reference", {})
		var price: String = str(reference.get("price_per_gram", ""))
		var source: String = str(reference.get("source", ""))
		var quoted_at: String = str(reference.get("quoted_at", ""))
		if _privacy_mode == "hide_total":
			_source_label.text = "手工参考价已隐藏 · 当前罐 %d 颗" % result.display_snapshot.beans.size() if source == "USER_MANUAL" else \
				"参考金价已隐藏 · 来源 %s · %s · 当前罐 %d 颗" % [source, quoted_at, result.display_snapshot.beans.size()]
		elif source == "USER_MANUAL":
			_source_label.text = "手工参考金价 ¥%s/g · 当前罐 %d 颗" % [price, result.display_snapshot.beans.size()]
		else:
			_source_label.text = "参考金价 ¥%s/g · 来源 %s · %s · 当前罐 %d 颗" % [price, source, quoted_at, result.display_snapshot.beans.size()]
		_status_label.text = "已保存版本 %d · %s · 第 %d/%d 罐" % [
			_generation, result.account_name, _jar_ids.find(_selected_jar) + 1, _jar_ids.size()]
		if not cash_only:
			_status_label.text = "已保存版本 %d · 现金快捷录入不适用于证券账本" % _generation
	_skin_button.text = "基础罐" if _skin_id == "ecology" else "生态罐"
	_privacy_button.text = "显示金额" if _privacy_mode == "hide_total" else "隐藏金额"
	_ecology_feed_button.disabled = _ecology_state.get("organisms", []).is_empty()
	_ecology_plant_button.text = "种海草" if _ecology_state.get("plants", []).is_empty() else "移动海草"
	var ecology_metrics := jar.get_ecology_metrics()
	_ecology_label.text = "鱼虾 %d · 海草 %d · %s · 不影响资产" % [
		ecology_metrics.organism_count, ecology_metrics.plant_count,
		"夜间" if ecology_metrics.phase == "night" else "白天"]
	if not ecology_ok:
		_status_label.text += " · 生态状态读取失败"


func _refresh_ecology(expected_generation: int) -> bool:
	var loaded: Dictionary = _store.load_project()
	if not loaded.ok or int(loaded.generation) != expected_generation \
			or typeof(loaded.state.get("ecology", null)) != TYPE_DICTIONARY:
		return false
	var ecology: Dictionary = loaded.state.ecology
	if not jar.apply_ecology_state(ecology):
		return false
	_ecology_state = ecology.duplicate(true)
	return true


func _now_utc() -> String:
	return Time.get_datetime_string_from_system(true, false) + "Z"


func _new_id(prefix: String) -> String:
	return prefix + "-" + Crypto.new().generate_random_bytes(16).hex_encode()


func _place_header_line(label: Label, top: float, bottom: float) -> void:
	label.anchor_right = 1.0
	label.offset_top = top
	label.offset_bottom = bottom


func _line_input(placeholder: String) -> LineEdit:
	var field := LineEdit.new()
	field.placeholder_text = placeholder
	field.custom_minimum_size.y = 54.0
	field.add_theme_font_size_override("font_size", 18)
	field.add_theme_color_override("font_color", Color("34312c"))
	field.add_theme_color_override("font_placeholder_color", Color("8d806d"))
	var style := StyleBoxFlat.new()
	style.bg_color = Color("fffcf6")
	style.border_color = Color("d7c9b4")
	style.set_border_width_all(1)
	style.set_corner_radius_all(10)
	style.content_margin_left = 12.0
	style.content_margin_right = 12.0
	field.add_theme_stylebox_override("normal", style)
	var focus := style.duplicate()
	focus.border_color = Color("b99559")
	focus.set_border_width_all(2)
	field.add_theme_stylebox_override("focus", focus)
	return field


func _label(value: String, font_size: int, color: Color) -> Label:
	var label := Label.new()
	label.text = value
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", color)
	return label


func _button(value: String) -> Button:
	var button := Button.new()
	button.text = value
	button.custom_minimum_size.y = 56.0
	button.add_theme_font_size_override("font_size", 17)
	button.add_theme_color_override("font_color", Color("34312c"))
	var style := StyleBoxFlat.new()
	style.bg_color = Color("f1e7d5")
	style.corner_radius_top_left = 12
	style.corner_radius_top_right = 12
	style.corner_radius_bottom_left = 12
	style.corner_radius_bottom_right = 12
	button.add_theme_stylebox_override("normal", style)
	var hover := style.duplicate()
	hover.bg_color = Color("ead6b0")
	button.add_theme_stylebox_override("hover", hover)
	return button
