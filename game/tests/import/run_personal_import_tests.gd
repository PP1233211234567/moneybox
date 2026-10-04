extends SceneTree

const Flow = preload("res://scripts/import/personal_import_flow.gd")
const PersonalFlow = preload("res://scripts/data/personal_flow.gd")
const Store = preload("res://scripts/data/project_store.gd")
const Ledger = preload("res://scripts/data/ledger_core.gd")

var failures: Array[String] = []
var checks := 0


func _initialize() -> void:
	_test_personal_commit_and_replay()
	_test_bad_batch_and_stale_preview()
	_test_demo_rejection()
	if failures.is_empty():
		print("PERSONAL IMPORT TESTS PASS: %d checks" % checks)
		quit(0)
	else:
		for failure in failures:
			printerr("FAIL: " + failure)
		printerr("PERSONAL IMPORT TESTS FAIL: %d failures in %d checks" % [failures.size(), checks])
		quit(1)


func _check(condition: bool, label: String) -> void:
	checks += 1
	if not condition:
		failures.append(label)


func _base_path(label: String) -> String:
	var directory := ProjectSettings.globalize_path("res://").get_base_dir().path_join("tests").path_join("tmp")
	DirAccess.make_dir_recursive_absolute(directory)
	return directory.path_join(label + "-" + str(Time.get_ticks_usec()))


func _setup_personal(label: String) -> Dictionary:
	var path := _base_path(label)
	var personal := PersonalFlow.new(path)
	var opening: Dictionary = personal.create_opening_cash("opening-" + label, "cash-1",
		"Synthetic Cash", "10000", "1000", "2026-01-01T00:00:00Z")
	if not opening.ok:
		failures.append("setup personal opening: " + str(opening.get("error", "unknown")))
		return {}
	var store := Store.new(path)
	var loaded: Dictionary = store.load_project()
	var instrument := Ledger.apply(loaded.state.ledger, {"command_id": "create-syn-instrument",
		"type": "instrument_create", "instrument": {"id": "syn-sh-cny",
			"symbol": "SYN", "market": "SH", "currency": "CNY"}})
	if not instrument.ok:
		failures.append("setup instrument: " + str(instrument.error))
		return {}
	var project: Dictionary = loaded.state.duplicate(true)
	project.ledger = instrument.state
	project.valuation_pending = {"reason": "TEST_FIXTURE_INSTRUMENT", \
		"ledger_hash": Store.canonical_ledger_hash(instrument.state)}
	var saved: Dictionary = store.save_project(project, int(loaded.generation))
	if not saved.ok:
		failures.append("setup project save: " + str(saved.error))
		return {}
	return {"path": path, "store": store, "generation": int(saved.generation)}


func _mapping() -> Dictionary:
	return {"column_map": {"type": "event", "account": "account",
		"effective_at": "date", "delta": "change", "external": "external",
		"instrument": "symbol", "quantity": "quantity", "unit_price": "unit_price",
		"fee": "fee", "tax_amount": "tax", "total_amount": "total",
		"amount_basis": "basis", "currency": "currency"},
		"account_ids": {"Cash": "cash-1"}, "instrument_ids": {"SYN": "syn-sh-cny"}}


func _csv() -> String:
	return "event,account,date,change,external,symbol,quantity,unit_price,fee,tax,total,basis,currency\n" + \
		"cash_delta,Cash,2026-02-01T00:00:00Z,1000,true,,,,,,,,CNY\n" + \
		"buy,Cash,2026-02-02T00:00:00Z,,,SYN,2,100,1,0,201,cash_flow,CNY\n" + \
		"cash_delta,Cash,2026-02-03T00:00:00Z,-50,false,,,,,,,,CNY\n"


func _confirm(preview: Dictionary) -> Dictionary:
	return {"confirmed": true, "content_sha256": preview.content_sha256}


func _test_personal_commit_and_replay() -> void:
	var fixture := _setup_personal("personal-import")
	if fixture.is_empty():
		return
	var flow := Flow.new(fixture.path)
	var csv := _csv()
	var mapping := _mapping()
	var before: Dictionary = fixture.store.load_project()
	var opening_events: int = before.state.ledger.events.size()
	var opening_mapping: Dictionary = before.state.mappings.back().duplicate(true)
	var preview := flow.preview_csv(csv, mapping)
	_check(preview.ok and not preview.duplicate and preview.row_count == 3
		and preview.row_errors.is_empty(), "personal CSV previews three cash and trade rows")
	_check(preview.resulting_projection.cash["cash-1"] == "10749" and
		preview.resulting_projection.positions["cash-1|syn-sh-cny"].quantity == "2" and
		preview.resulting_projection.asset_total == "10949",
		"preview computes cash, holding and total without saving")
	_check(fixture.store.load_project().generation == before.generation and
		fixture.store.load_project().state.ledger.events.size() == opening_events,
		"preview leaves project generation and ledger unchanged")
	var declined := flow.confirm_csv(csv, mapping, preview,
		{"confirmed": false, "content_sha256": preview.content_sha256})
	_check(not declined.ok and declined.error == "EXPLICIT_CONFIRMATION_REQUIRED" and
		fixture.store.load_project().generation == before.generation,
		"personal CSV requires explicit confirmation")
	var committed := flow.confirm_csv(csv, mapping, preview, _confirm(preview))
	_check(committed.ok and not committed.duplicate and
		committed.generation == before.generation + 1 and committed.row_count == 3,
		"confirmed CSV saves exactly one new project generation: " + str(committed.get("error", "")))
	if not committed.ok:
		return
	var restarted := Flow.new(fixture.path)
	var persisted: Dictionary = fixture.store.load_project()
	_check(persisted.ok and persisted.generation == committed.generation and
		persisted.state.ledger.events.size() == opening_events + 3 and
		persisted.state.ledger.import_batches.has(preview.content_sha256),
		"restart reads all imported rows and content-hash batch marker")
	_check(persisted.state.valuation_pending.reason == "CSV_IMPORT" and
		persisted.state.valuation_pending.ledger_hash == Store.canonical_ledger_hash(persisted.state.ledger),
		"same atomic save marks current ledger as awaiting valuation")
	_check(persisted.state.mappings.back() == opening_mapping and
		persisted.state.inventory.mapping_id == opening_mapping.id,
		"CSV import does not auto-remap beans or rewrite prior complete snapshot")
	var visible: Dictionary = PersonalFlow.new(fixture.path).load()
	_check(visible.ok and visible.valuation_pending.reason == "CSV_IMPORT" and
		visible.amount == opening_mapping.amount,
		"personal display contract labels old mapping as pending after restart")
	var cash_shortcut: Dictionary = PersonalFlow.new(fixture.path).record_cash_change(
		"cash-after-import", "cash-1", "1", "2026-02-04T00:00:00Z", persisted.generation)
	_check(not cash_shortcut.ok and cash_shortcut.error == "VALUATION_PENDING",
		"cash shortcut cannot auto-remap a pending imported securities ledger")
	var replay_preview := restarted.preview_csv(csv, mapping)
	var replay := restarted.confirm_csv(csv, mapping, replay_preview, _confirm(replay_preview))
	_check(replay_preview.ok and replay_preview.duplicate and replay.ok and replay.duplicate,
		"same CSV is duplicate after project restart")
	_check(replay.generation == persisted.generation and
		fixture.store.load_project().state.ledger.events.size() == opening_events + 3,
		"duplicate CSV creates no new generation or events")


func _test_bad_batch_and_stale_preview() -> void:
	var fixture := _setup_personal("personal-import-errors")
	if fixture.is_empty():
		return
	var flow := Flow.new(fixture.path)
	var header := "event,account,date,change,external,symbol,quantity,unit_price,fee,tax,total,basis,currency\n"
	var bad_csv := header
	for index in 1000:
		bad_csv += "cash_delta,%s,2026-02-01T00:00:00Z,1,false,,,,,,,,CNY\n" % (
			"Unmapped" if index == 999 else "Cash")
	var before: Dictionary = fixture.store.load_project()
	var ledger_before := JSON.stringify(before.state.ledger)
	var preview := flow.preview_csv(bad_csv, _mapping())
	_check(not preview.ok and preview.row_count == 1000 and preview.row_errors.size() == 1 and
		preview.row_errors[0].row == 1000 and
		preview.row_errors[0].code == "ACCOUNT_MAPPING_REQUIRED",
		"1000-row batch identifies one final critical mapping error")
	var rejected := flow.confirm_csv(bad_csv, _mapping(), preview, _confirm(preview))
	_check(not rejected.ok and rejected.error == "VALID_PREVIEW_REQUIRED" and
		fixture.store.load_project().generation == before.generation and
		JSON.stringify(fixture.store.load_project().state.ledger) == ledger_before,
		"invalid 1000-row batch has no partial save or generation change")
	var other_csv := header + "cash_delta,Cash,2026-02-04T00:00:00Z,5,true,,,,,,,,CNY\n"
	var stale_preview := flow.preview_csv(other_csv, _mapping())
	_check(stale_preview.ok, "valid preview exists before concurrent project change")
	var changed: Dictionary = fixture.store.load_project().state
	changed.presentation.privacy_mode = "hide_total"
	var saved: Dictionary = fixture.store.save_project(changed, int(before.generation))
	_check(saved.ok and saved.generation == before.generation + 1,
		"concurrent project setting advances generation")
	var stale := flow.confirm_csv(other_csv, _mapping(), stale_preview, _confirm(stale_preview))
	_check(not stale.ok and stale.error == "GENERATION_CONFLICT" and
		JSON.stringify(fixture.store.load_project().state.ledger) == ledger_before,
		"stale CSV preview cannot overwrite changed project")


func _test_demo_rejection() -> void:
	var path := _base_path("demo-import-reject")
	var store := Store.new(path)
	var demo := store.new_project()
	demo.data_kind = "demo"
	var saved := store.save_project(demo, 0)
	_check(saved.ok, "isolated demo fixture saved")
	if not saved.ok:
		return
	var result := Flow.new(path).preview_csv(_csv(), _mapping())
	_check(not result.ok and result.error == "PERSONAL_PROJECT_REQUIRED" and
		store.load_project().generation == 1,
		"demo project rejects personal CSV and remains unchanged")
