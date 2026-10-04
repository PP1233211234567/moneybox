extends SceneTree

const Store = preload("res://scripts/data/project_store.gd")
const Ledger = preload("res://scripts/data/ledger_core.gd")
const Exporter = preload("res://scripts/export/ledger_csv_export_service.gd")

var checks := 0
var failures: Array[String] = []
var _directory := ""


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	_directory = ProjectSettings.globalize_path("res://").get_base_dir().path_join("tests").path_join(
		".csv-export-test-" + Crypto.new().generate_random_bytes(8).hex_encode())
	if DirAccess.make_dir_recursive_absolute(_directory) != OK:
		printerr("LEDGER CSV EXPORT FAIL: sandbox directory unavailable")
		quit(1)
		return
	_test_source_guards()
	_test_round_trip_and_no_overwrite()
	_test_encode_limits()
	if failures.is_empty():
		print("LEDGER CSV EXPORT PASS: %d checks" % checks)
		quit(0)
	else:
		for failure in failures:
			printerr("FAIL: " + failure)
		printerr("LEDGER CSV EXPORT FAIL: %d failures in %d checks" % [failures.size(), checks])
		quit(1)


func _test_source_guards() -> void:
	var exporter := Exporter.new()
	var empty_path := _directory.path_join("empty")
	_check(exporter.export_events(Store.new(empty_path), _directory.path_join("empty.csv")).error == \
		"NO_SAVED_PROJECT", "unsaved project cannot masquerade as saved event export")
	var demo_store := Store.new(_directory.path_join("demo"))
	var demo: Dictionary = demo_store.new_project()
	demo.data_kind = "demo"
	_check(demo_store.save_project(demo, 0).ok, "synthetic demo project saved")
	_check(exporter.export_events(demo_store, _directory.path_join("demo.csv")).error == \
		"NOT_PERSONAL_DATA", "demo events cannot export through personal service")
	_check(exporter.export_events(demo_store, "").error == "OUTPUT_PATH_REQUIRED",
		"explicit output path is required")
	_check(not FileAccess.file_exists(_directory.path_join("empty.csv")) and \
		not FileAccess.file_exists(_directory.path_join("demo.csv")),
		"source guards write no output files")


func _test_round_trip_and_no_overwrite() -> void:
	var store := Store.new(_directory.path_join("personal"))
	var state: Dictionary = store.new_project()
	var applied: Dictionary = Ledger.apply(state.ledger, {"command_id": "account-1", "type": "account_create",
		"account": {"id": "cash-1", "name": "合成账户", "currency": "CNY", "mode": "detail",
			"cost_method": "FIFO"}})
	_check(applied.ok, "synthetic account accepted")
	state.ledger = applied.state
	var unusual_id := "=2,3\"\nnext"
	var exact_amount := "5000.000000000000000123456789"
	applied = Ledger.apply(state.ledger, {"command_id": unusual_id, "type": "opening_cash",
		"account_id": "cash-1", "amount": exact_amount, "effective_at": "2026-09-27T00:00:00Z"})
	_check(applied.ok, "high precision opening event accepted")
	state.ledger = applied.state
	state.ledger.events[0]["memo"] = "原文,双引号\"与换行\n下一行"
	var exact_delta := "-0.000000000000000123456789"
	applied = Ledger.apply(state.ledger, {"command_id": "change-1", "type": "cash_delta",
		"account_id": "cash-1", "delta": exact_delta, "external": true,
		"effective_at": "2026-09-27T00:01:00Z"})
	_check(applied.ok, "high precision negative delta accepted")
	state.ledger = applied.state
	var saved: Dictionary = store.save_project(state, 0)
	_check(saved.ok and saved.generation == 1, "personal event journal saved")
	if not saved.ok:
		return
	var before: Dictionary = store.load_project()
	var before_sha := JSON.stringify(before.state).sha256_text()
	var output := _directory.path_join("saved-events.csv")
	var exported: Dictionary = Exporter.new().export_events(store, output)
	_check(exported.ok and exported.generation == 1 and exported.event_count == 2 and \
		exported.plaintext and FileAccess.file_exists(output),
		"explicit CSV export writes both saved events")
	if not exported.ok:
		return
	var bytes := FileAccess.get_file_as_bytes(output)
	var sha_context := HashingContext.new()
	sha_context.start(HashingContext.HASH_SHA256)
	sha_context.update(bytes)
	_check(bytes.size() == exported.byte_count and \
		sha_context.finish().hex_encode() == exported.sha256 and \
		bytes.size() >= 3 and bytes[0] == 239 and bytes[1] == 187 and bytes[2] == 191,
		"UTF-8 BOM, byte count and SHA256 match written file")
	var file := FileAccess.open(output, FileAccess.READ)
	var header := file.get_csv_line()
	var first := file.get_csv_line()
	var second := file.get_csv_line()
	file.close()
	_check(header.size() == Exporter.COLUMNS.size() and \
		header[0] == "project_generation" and first.size() == header.size() and \
		second.size() == header.size(), "CSV rows parse with stable column count")
	var id_index: int = Exporter.COLUMNS.find("id")
	var amount_index: int = Exporter.COLUMNS.find("amount")
	var delta_index: int = Exporter.COLUMNS.find("delta")
	var json_index: int = Exporter.COLUMNS.find("raw_event_json")
	_check(first[id_index] == "'" + unusual_id and first[amount_index] == exact_amount and \
		second[delta_index] == exact_delta and second[Exporter.COLUMNS.find("external")] == "true",
		"spreadsheet formula is neutralized while decimal strings remain exact")
	var first_raw: Dictionary = JSON.parse_string(first[json_index])
	_check(first_raw.id == unusual_id and first_raw.amount == exact_amount and \
		first_raw.memo == "原文,双引号\"与换行\n下一行" and \
		JSON.parse_string(second[json_index]).delta == exact_delta,
		"raw JSON preserves original ID, comma, quote, newline and decimal fields")
	var existing_bytes := FileAccess.get_file_as_bytes(output)
	_check(Exporter.new().export_events(store, output).error == "OUTPUT_EXISTS" and \
		FileAccess.get_file_as_bytes(output) == existing_bytes,
		"existing CSV remains byte-identical after refused second export")
	_check(Exporter.new().export_events(store, _directory.path_join("missing").path_join("x.csv")).error == \
		"OUTPUT_DIRECTORY_UNAVAILABLE", "missing folder fails without creating output")
	var after: Dictionary = Store.new(_directory.path_join("personal")).load_project()
	_check(after.generation == before.generation and \
		JSON.stringify(after.state).sha256_text() == before_sha,
		"export and refused retries never write the personal project")


func _test_encode_limits() -> void:
	var exporter := Exporter.new()
	var checkpoint := {"id": "asset-checkpoint", "type": "other_asset_value_set",
		"asset_id": "asset-1", "amount": "12.345", "valuation_basis": "=statement",
		"source_note": "@provider", "effective_at": "2026-09-27T00:00:00Z"}
	var checkpoint_encoded: Dictionary = exporter._encode([checkpoint], 1)
	var checkpoint_text: String = checkpoint_encoded.bytes.get_string_from_utf8() if checkpoint_encoded.ok else ""
	_check(checkpoint_encoded.ok and checkpoint_text.contains("\"asset-1\"") and \
		checkpoint_text.contains("\"'=statement\"") and checkpoint_text.contains("\"'@provider\"") and \
		checkpoint_text.contains(JSON.stringify(checkpoint).replace("\"", "\"\"")),
		"asset checkpoint fields are visible and formula-safe while raw JSON remains exact")
	_check(exporter._encode([{"id": "ok", "amount": "1e3"}], 1).error == \
		"INVALID_DECIMAL_FIELD", "invalid decimal text is rejected")
	var oversized := "x".repeat(Exporter.MAX_CSV_BYTES)
	_check(exporter._encode([{"id": "oversized", "memo": oversized}], 1).error == \
		"CSV_SIZE_LIMIT_EXCEEDED", "oversized CSV is rejected rather than truncated")
	var store := Store.new(_directory.path_join("many"))
	var state: Dictionary = store.new_project()
	state.ledger.events = []
	for index in Exporter.MAX_EVENTS + 1:
		state.ledger.events.append({"id": "e" + str(index), "type": "void",
			"target_event_id": "none", "effective_at": "2026-09-27T00:00:00Z",
			"sequence": index + 1})
	# A synthetic projected ledger with 10,001 void entries has no account balances.
	_check(store.save_project(state, 0).ok, "synthetic over-limit project saved")
	var output := _directory.path_join("many.csv")
	_check(exporter.export_events(store, output).error == "EVENT_LIMIT_EXCEEDED" and \
		not FileAccess.file_exists(output), "event limit rejects full export without a partial CSV")


func _check(condition: bool, label: String) -> void:
	checks += 1
	if not condition:
		failures.append(label)
