extends SceneTree

const Scene = preload("res://scenes/personal_csv_import.tscn")
const Store = preload("res://scripts/data/project_store.gd")
const PersonalFlow = preload("res://scripts/data/personal_flow.gd")
const Ledger = preload("res://scripts/data/ledger_core.gd")

const HEADER := "event,account,date,change,external,symbol,quantity,unit_price,fee,tax,total,basis,currency\n"
const FIELD_MAP := {"type": "event", "account": "account", "effective_at": "date",
	"delta": "change", "external": "external", "instrument": "symbol",
	"quantity": "quantity", "unit_price": "unit_price", "fee": "fee",
	"tax_amount": "tax", "total_amount": "total", "amount_basis": "basis",
	"currency": "currency"}

var checks := 0
var failures: Array[String] = []


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var directory := ProjectSettings.globalize_path("res://").path_join("tests/tmp")
	DirAccess.make_dir_recursive_absolute(directory)
	var prefix := directory.path_join("personal-csv-scene-" + str(Time.get_ticks_usec()))
	await _test_guards(prefix + "-empty", prefix + "-demo")
	await _test_preview_commit_replay(prefix + "-complete")
	await _test_error_and_stale(prefix + "-error")
	_check(checks >= 20, "all CSV scene interaction checks reached")
	if failures.is_empty():
		print("PERSONAL CSV IMPORT SCENE PASS: %d checks" % checks)
		quit(0)
	else:
		for failure in failures:
			printerr("FAIL: " + failure)
		printerr("PERSONAL CSV IMPORT SCENE FAIL: %d failures in %d checks" % [
			failures.size(), checks])
		quit(1)


func _test_guards(empty_path: String, demo_path: String) -> void:
	var empty := await _mount(empty_path)
	_check(empty.get_column_button().disabled and empty.get_preview_button().disabled
		and empty.get_confirm_button().disabled and empty.get_status_text().contains("现金账户"),
		"uninitialized personal project cannot preview or confirm CSV")
	_check(empty.get_file_notice_text().contains("尚未接入系统文件选择器")
		and empty.get_file_notice_text().contains("不会读取设备文件"),
		"scene says pasted text only and does not claim a file picker")
	empty.queue_free()
	await process_frame
	var store := Store.new(demo_path)
	var demo := store.new_project()
	demo.data_kind = "demo"
	_check(store.save_project(demo, 0).ok, "demo fixture saved")
	var panel := await _mount(demo_path)
	_check(panel.get_column_button().disabled and panel.get_preview_button().disabled
		and panel.get_status_text().contains("演示项目"),
		"demo project never enables personal CSV controls")
	panel.queue_free()
	await process_frame


func _test_preview_commit_replay(path: String) -> void:
	var setup := _fixture(path)
	_check(setup.ok, "synthetic personal account and instrument initialized: " +
		str(setup.get("error", "")))
	if not setup.ok:
		return
	var store := Store.new(path)
	var before: Dictionary = store.load_project()
	var original_mapping: Dictionary = before.state.mappings.back().duplicate(true)
	var original_events: int = before.state.ledger.events.size()
	var csv := _valid_csv()
	var panel := await _mount(path)
	_configure(panel, csv)
	_check(panel.get_account_picker("Cash") != null
		and panel.get_instrument_picker("SYN") != null,
		"account and instrument source values require separate ID selection")
	_check(panel.get_confirm_button().disabled and
		store.load_project().generation == before.generation,
		"mapping choices do not write or enable confirmation")
	panel.get_preview_button().pressed.emit()
	_check(not panel.get_confirm_button().disabled and
		panel.get_summary_text().contains("3 行全部通过预检") and
		panel.get_row_list().item_count == 3 and
		panel.get_row_list().get_item_text(1).contains("买入"),
		"full three-row preview exposes cash and trade details")
	_check(store.load_project().generation == before.generation and
		store.load_project().state.ledger.events.size() == original_events,
		"preview leaves project and ledger untouched")
	var instrument_picker: OptionButton = panel.get_instrument_picker("SYN")
	instrument_picker.select(0)
	instrument_picker.item_selected.emit(0)
	_check(panel.get_confirm_button().disabled,
		"changing an ID mapping invalidates an already shown preview")
	_select(instrument_picker, "syn-sh-cny")
	panel.get_preview_button().pressed.emit()
	_check(not panel.get_confirm_button().disabled,
		"explicit re-preview is required after mapping changes")
	panel.get_confirm_button().pressed.emit()
	var persisted: Dictionary = store.load_project()
	_check(persisted.generation == before.generation + 1 and
		persisted.state.ledger.events.size() == original_events + 3 and
		persisted.state.ledger.import_batches.size() == 1,
		"explicit confirmation saves all rows in one generation")
	_check(persisted.state.valuation_pending.reason == "CSV_IMPORT" and
		persisted.state.valuation_pending.ledger_hash ==
		Store.canonical_ledger_hash(persisted.state.ledger) and
		persisted.state.mappings.back() == original_mapping,
		"same save marks pending valuation and preserves prior bean mapping")
	_check(panel.get_confirm_button().disabled and panel.get_csv_input().text.is_empty()
		and panel.get_summary_text().contains("等待重新估值"),
		"success clears pasted CSV and does not leave a second confirm action")
	panel.queue_free()
	await process_frame
	var restarted := await _mount(path)
	_check(restarted.get_status_text().contains("金豆等待重估") and
		Store.new(path).load_project().generation == persisted.generation,
		"scene restart reads pending-valuation status")
	_configure(restarted, csv)
	restarted.get_preview_button().pressed.emit()
	_check(restarted.get_summary_text().contains("已导入") and
		restarted.get_confirm_button().disabled and
		Store.new(path).load_project().generation == persisted.generation,
		"same CSV after restart shows duplicate and cannot resubmit")
	restarted.queue_free()
	await process_frame


func _test_error_and_stale(path: String) -> void:
	var setup := _fixture(path)
	_check(setup.ok, "error fixture initialized: " + str(setup.get("error", "")))
	if not setup.ok:
		return
	var store := Store.new(path)
	var before: Dictionary = store.load_project()
	var ledger_before := JSON.stringify(before.state.ledger)
	var panel := await _mount(path)
	var bad_csv := HEADER
	for index in 1000:
		bad_csv += "cash_delta,%s,2026-02-01T00:00:00Z,1,false,,,,,,,,CNY\n" % (
			"Unmapped" if index == 999 else "Cash")
	_configure(panel, bad_csv, false)
	_check(panel.get_account_picker("Unmapped") != null and
		panel.get_account_picker("Unmapped").selected == 0,
		"unmatched source account remains explicitly unmapped")
	panel.get_preview_button().pressed.emit()
	_check(panel.get_confirm_button().disabled and
		panel.get_summary_text().contains("1000 行中有 1 项错误") and
		panel.get_row_list().item_count == 1 and
		panel.get_row_list().get_item_text(0).contains("第 1001 行"),
		"one critical error rejects all 1000 rows and shows physical line")
	_check(store.load_project().generation == before.generation and
		JSON.stringify(store.load_project().state.ledger) == ledger_before,
		"invalid batch saves no partial ledger or generation")
	var valid := HEADER + "cash_delta,Cash,2026-02-04T00:00:00Z,5,true,,,,,,,,CNY\n"
	_configure(panel, valid, false)
	panel.get_preview_button().pressed.emit()
	_check(not panel.get_confirm_button().disabled, "valid CSV preview available")
	panel.get_csv_input().text += "\n" # Programmatic edit bypasses text_changed in Godot.
	panel.get_confirm_button().pressed.emit()
	_check(store.load_project().generation == before.generation and
		panel.get_confirm_button().disabled and panel.get_summary_text().contains("重新预览"),
		"changed CSV bytes cannot reuse a shown preview")
	_configure(panel, valid, false)
	panel.get_preview_button().pressed.emit()
	var changed: Dictionary = store.load_project().state
	changed.presentation.privacy_mode = "hide_total"
	var advanced: Dictionary = store.save_project(changed, int(before.generation))
	_check(advanced.ok and advanced.generation == before.generation + 1,
		"concurrent project change advances generation")
	panel.get_confirm_button().pressed.emit()
	_check(panel.get_confirm_button().disabled and
		panel.get_summary_text().contains("GENERATION_CONFLICT") and
		JSON.stringify(store.load_project().state.ledger) == ledger_before,
		"stale preview cannot overwrite newer project generation")
	panel.queue_free()
	await process_frame


func _fixture(path: String) -> Dictionary:
	var opened: Dictionary = PersonalFlow.new(path).create_opening_cash(
		"scene-opening", "cash-1", "Synthetic Cash", "10000", "1000",
		"2026-01-01T00:00:00Z")
	if not opened.ok:
		return opened
	var store := Store.new(path)
	var loaded: Dictionary = store.load_project()
	var instrument := Ledger.apply(loaded.state.ledger, {"command_id": "scene-instrument",
		"type": "instrument_create", "instrument": {"id": "syn-sh-cny",
			"symbol": "SYN", "market": "SH", "currency": "CNY"}})
	if not instrument.ok:
		return instrument
	var next: Dictionary = loaded.state.duplicate(true)
	next.ledger = instrument.state
	next.valuation_pending = {"reason": "TEST_FIXTURE_INSTRUMENT",
		"ledger_hash": Store.canonical_ledger_hash(instrument.state)}
	return store.save_project(next, int(loaded.generation))


func _valid_csv() -> String:
	return HEADER + \
		"cash_delta,Cash,2026-02-01T00:00:00Z,1000,true,,,,,,,,CNY\n" + \
		"buy,Cash,2026-02-02T00:00:00Z,,,SYN,2,100,1,0,201,cash_flow,CNY\n" + \
		"cash_delta,Cash,2026-02-03T00:00:00Z,-50,false,,,,,,,,CNY\n"


func _mount(path: String) -> Control:
	var panel := Scene.instantiate()
	panel.base_path = path
	root.add_child(panel)
	await process_frame
	return panel


func _configure(panel: Control, csv: String, include_instrument: bool = true) -> void:
	panel.get_csv_input().text = csv
	panel.get_column_button().pressed.emit()
	for field in FIELD_MAP:
		_select(panel.get_field_picker(str(field)), str(FIELD_MAP[field]))
	panel.get_identity_button().pressed.emit()
	_select(panel.get_account_picker("Cash"), "cash-1")
	if include_instrument:
		_select(panel.get_instrument_picker("SYN"), "syn-sh-cny")


func _select(picker: OptionButton, metadata: String) -> void:
	if picker == null:
		_check(false, "mapping picker missing for " + metadata)
		return
	for index in picker.item_count:
		if str(picker.get_item_metadata(index)) == metadata:
			picker.select(index)
			picker.item_selected.emit(index)
			return
	_check(false, "mapping option missing: " + metadata)


func _check(condition: bool, label: String) -> void:
	checks += 1
	if not condition:
		failures.append(label)
