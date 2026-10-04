extends SceneTree

const Import = preload("res://scripts/import/csv_import_service.gd")
const Ledger = preload("res://scripts/data/ledger_core.gd")
const Store = preload("res://scripts/data/project_store.gd")

var failures: Array[String] = []
var checks := 0


func _initialize() -> void:
	_test_duplicate_batch_and_confirmation()
	_test_thousand_row_error()
	_test_semantic_rollback_and_trade_identity()
	_test_strict_csv_and_stale_preview()
	_test_persisted_batch_and_partial_marker()
	if failures.is_empty():
		print("IMPORT TESTS PASS: %d checks" % checks)
		quit(0)
	else:
		for failure in failures:
			printerr("FAIL: " + failure)
		printerr("IMPORT TESTS FAIL: %d failures in %d checks" % [failures.size(), checks])
		quit(1)


func _check(ok: bool, label: String) -> void:
	checks += 1
	if not ok:
		failures.append(label)


func _state() -> Dictionary:
	var state := Ledger.new_state()
	for command in [
		{"command_id": "account-main", "type": "account_create",
			"account": {"id": "main", "currency": "CNY", "mode": "detail", "cost_method": "FIFO"}},
		{"command_id": "instrument-test", "type": "instrument_create",
			"instrument": {"id": "test-sh-cny", "symbol": "TEST", "market": "SH", "currency": "CNY"}},
		{"command_id": "opening-main", "type": "opening_cash", "account_id": "main",
			"amount": "10000", "effective_at": "2026-01-01T00:00:00Z"},
	]:
		var result := Ledger.apply(state, command)
		if not result.ok:
			failures.append("fixture failed: " + str(result.error))
			return state
		state = result.state
	return state


func _cash_mapping() -> Dictionary:
	return {"column_map": {"type": "event", "account": "account", "effective_at": "date",
		"delta": "change", "external": "external"},
		"account_ids": {"Wallet, Demo": "main"}, "instrument_ids": {}}


func _cash_csv() -> String:
	return "event,account,date,change,external\r\n" + \
		"cash_delta,\"Wallet, Demo\",2026-02-01T00:00:00Z,10,true\r\n" + \
		"cash_delta,\"Wallet, Demo\",2026-02-02T00:00:00Z,5,false\r\n"


func _confirm(preview: Dictionary) -> Dictionary:
	return {"confirmed": true, "content_sha256": preview.content_sha256}


func _test_duplicate_batch_and_confirmation() -> void:
	var state := _state()
	var before := JSON.stringify(state)
	var csv := _cash_csv()
	var mapping := _cash_mapping()
	var preview := Import.preview_csv(state, csv, mapping)
	_check(preview.ok and not preview.duplicate and preview.row_count == 2 and preview.row_errors.is_empty(),
		"T29 CSV preview of both rows")
	_check(preview.resulting_projection.cash.main == "10015" and JSON.stringify(state) == before,
		"T29 preview calculates changes without mutation")
	var declined := Import.confirm(state, csv, mapping, preview,
		{"confirmed": false, "content_sha256": preview.content_sha256})
	_check(not declined.ok and declined.error == "EXPLICIT_CONFIRMATION_REQUIRED" and JSON.stringify(state) == before,
		"T29 explicit confirmation gate")
	var applied := Import.confirm(state, csv, mapping, preview, _confirm(preview))
	_check(applied.ok and not applied.duplicate and applied.state.events.size() == state.events.size() + 2,
		"T29 batch creates two events only after confirmation")
	if not applied.ok:
		return
	_check(JSON.stringify(state) == before and applied.state.import_batches.has(preview.content_sha256),
		"T29 source unchanged and content hash recorded")
	_check(applied.projection.cash.main == "10015" and applied.projection.external_net_invested == "10",
		"T29 imported cash and external flow projected")
	var replay_preview := Import.preview_csv(applied.state, csv, mapping)
	var replay := Import.confirm(applied.state, csv, mapping, replay_preview, _confirm(replay_preview))
	_check(replay_preview.ok and replay_preview.duplicate and replay.ok and replay.duplicate,
		"T29 identical CSV recognized as duplicate")
	_check(replay.state.events.size() == applied.state.events.size()
		and replay.state.import_batches.size() == 1, "T29 replay adds no events or batch")
	var remapped := mapping.duplicate(true)
	remapped.account_ids["Wallet, Demo"] = "main"
	_check(Import.preview_csv(applied.state, csv, remapped).duplicate,
		"T29 content hash detects replay independently of mapping object")


func _test_thousand_row_error() -> void:
	var state := _state()
	var before := JSON.stringify(state)
	var csv := "event,account,date,change,external\n"
	for row in 1000:
		var alias := "Unmapped" if row == 999 else "Wallet, Demo"
		csv += "cash_delta,\"%s\",2026-02-01T00:00:00Z,1,false\n" % alias
	var preview := Import.preview_csv(state, csv, _cash_mapping())
	_check(not preview.ok and preview.row_count == 1000 and preview.error == "ROW_VALIDATION_FAILED",
		"T29 1000-row batch rejected")
	_check(preview.row_errors.size() == 1 and preview.row_errors[0].row == 1000
		and preview.row_errors[0].line == 1001
		and preview.row_errors[0].code == "ACCOUNT_MAPPING_REQUIRED",
		"T29 key error identifies final CSV line")
	var attempted := Import.confirm(state, csv, _cash_mapping(), preview, _confirm(preview))
	_check(not attempted.ok and JSON.stringify(state) == before and not state.has("import_batches"),
		"T29 invalid batch leaves all 999 valid preceding rows unapplied")


func _test_semantic_rollback_and_trade_identity() -> void:
	var state := _state()
	var mapping := _cash_mapping()
	var csv := "event,account,date,change,external\n" + \
		"cash_delta,\"Wallet, Demo\",2026-02-01T00:00:00Z,1,false\n" + \
		"cash_delta,\"Wallet, Demo\",2026-02-02T00:00:00Z,-20000,false\n"
	var preview := Import.preview_csv(state, csv, mapping)
	_check(not preview.ok and preview.row_errors.size() == 1 and preview.row_errors[0].row == 2
		and preview.row_errors[0].code == "INSUFFICIENT_CASH" and state.events.size() == 1,
		"semantic error after valid row remains atomic")
	var trade_mapping := {"column_map": {"type": "event", "account": "account",
		"effective_at": "date", "instrument": "symbol", "quantity": "quantity",
		"unit_price": "unit_price", "fee": "fee", "tax_amount": "tax",
		"total_amount": "total", "amount_basis": "basis", "currency": "currency"},
		"account_ids": {"Wallet, Demo": "main"}, "instrument_ids": {"TEST": "test-sh-cny"}}
	var trade_csv := "event,account,date,symbol,quantity,unit_price,fee,tax,total,basis,currency\n" + \
		"buy,\"Wallet, Demo\",2026-02-03T00:00:00Z,TEST,2,100,1,0,201,cash_flow,CNY\n"
	var trade_preview := Import.preview_csv(state, trade_csv, trade_mapping)
	_check(trade_preview.ok and trade_preview.resulting_projection.positions["main|test-sh-cny"].quantity == "2",
		"trade import uses explicit instrument ID and amount equality")
	trade_mapping.instrument_ids = {}
	var unmatched := Import.preview_csv(state, trade_csv, trade_mapping)
	_check(not unmatched.ok and unmatched.row_errors[0].code == "INSTRUMENT_MAPPING_REQUIRED",
		"trade import never infers instrument from symbol")


func _test_strict_csv_and_stale_preview() -> void:
	var state := _state()
	var mapping := _cash_mapping()
	var bad_quote := Import.preview_csv(state,
		"event,account,date,change,external\n" + \
		"cash_delta,\"Wallet, Demo\"x,2026-02-01T00:00:00Z,1,false\n", mapping)
	_check(not bad_quote.ok and bad_quote.row_errors[0].code == "CSV_QUOTE_INVALID",
		"strict CSV rejects characters after closing quote")
	var escaped_mapping := mapping.duplicate(true)
	escaped_mapping.account_ids['Wallet "Demo"'] = "main"
	var escaped := Import.preview_csv(state,
		"event,account,date,change,external\n" + \
		'cash_delta,"Wallet ""Demo""",2026-02-01T00:00:00Z,1,false\n', escaped_mapping)
	_check(escaped.ok and escaped.resulting_projection.cash.main == "10001",
		"CSV doubled quotes decode to explicitly mapped account label")
	var multiline := Import.preview_csv(state,
		"event,account,date,change,external\n" + \
		"cash_delta,\"Wallet,\n Demo\",2026-02-01T00:00:00Z,1,false\n", mapping)
	_check(not multiline.ok and multiline.row_errors[0].line == 2,
		"quoted newline is parsed and reports original physical line")
	var csv := _cash_csv()
	var preview := Import.preview_csv(state, csv, mapping)
	var newer: Dictionary = Ledger.apply(state, {"command_id": "later", "type": "cash_delta",
		"account_id": "main", "delta": "1", "external": false,
		"effective_at": "2026-02-03T00:00:00Z"}).state
	var stale := Import.confirm(newer, csv, mapping, preview, _confirm(preview))
	_check(not stale.ok and stale.error == "CURRENT_STATE_CHANGED",
		"confirmation rejects a changed ledger")
	var changed_csv := Import.confirm(state, csv + "\n", mapping, preview, _confirm(preview))
	_check(not changed_csv.ok and changed_csv.error == "CSV_CHANGED",
		"confirmation rejects changed CSV bytes")


func _test_persisted_batch_and_partial_marker() -> void:
	var state := _state()
	var csv := _cash_csv()
	var mapping := _cash_mapping()
	var preview := Import.preview_csv(state, csv, mapping)
	var partial := Ledger.apply(state, preview.rows[0].command)
	_check(partial.ok and not partial.duplicate, "partial marker fixture created")
	if partial.ok:
		var recovered := Import.preview_csv(partial.state, csv, mapping)
		_check(not recovered.ok and recovered.row_errors[0].code == "PREEXISTING_ROW_COMMAND_ID",
			"row command without batch marker cannot silently complete batch")
	var applied := Import.confirm(state, csv, mapping, preview, _confirm(preview))
	if not applied.ok:
		_check(false, "persisted batch fixture confirmed")
		return
	var directory := ProjectSettings.globalize_path("res://").get_base_dir().path_join("tests").path_join("tmp")
	DirAccess.make_dir_recursive_absolute(directory)
	var store := Store.new(directory.path_join("csv-import-" + str(Time.get_ticks_usec())))
	var project := store.new_project()
	project.ledger = applied.state
	var saved := store.save_project(project)
	_check(saved.ok, "confirmed batch can be saved in whole project snapshot")
	if not saved.ok:
		return
	var loaded := store.load_project()
	_check(loaded.ok and loaded.state.ledger.import_batches.has(preview.content_sha256)
		and loaded.state.ledger.events.size() == applied.state.events.size(),
		"saved batch metadata and events reload together")
	if loaded.ok:
		_check(Import.preview_csv(loaded.state.ledger, csv, mapping).duplicate,
			"reloaded project rejects same CSV")
