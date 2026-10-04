extends SceneTree

const Store = preload("res://scripts/data/project_store.gd")
const Backup = preload("res://scripts/backup/backup_service.gd")
const Ledger = preload("res://scripts/data/ledger_core.gd")
const Mapping = preload("res://scripts/domain/gold_mapping_service.gd")
const Inventory = preload("res://scripts/domain/jar_inventory.gd")

var failures: Array[String] = []
var checks := 0
var _work_directory := ""


func _initialize() -> void:
	_work_directory = ProjectSettings.globalize_path("res://").path_join("tests").path_join("tmp").path_join(
		"backup-" + Crypto.new().generate_random_bytes(8).hex_encode())
	if DirAccess.make_dir_recursive_absolute(_work_directory) != OK:
		printerr("BACKUP TESTS FAIL: sandbox directory unavailable")
		quit(1)
		return
	_run_tests()
	if failures.is_empty():
		print("BACKUP TESTS PASS: %d checks" % checks)
		quit(0)
	else:
		for failure in failures:
			printerr(failure)
		printerr("BACKUP TESTS FAIL: %d failures in %d checks" % [failures.size(), checks])
		quit(1)


func _run_tests() -> void:
	var source := Store.new(_work_directory.path_join("source"))
	var service := Backup.new(_work_directory.path_join("private-safety"))
	var state := _sample_project(source)
	if state.is_empty():
		_check(false, "sample state construction")
		return
	var saved: Dictionary = source.save_project(state)
	_check(saved.ok, "initial project saved")
	_check(service._valid_project_shape(state), "sample backup structural shape")
	_check(source._valid_state(state), "sample backup store validation")
	if not saved.ok:
		return
	var loaded: Dictionary = source.load_project()
	_check(loaded.ok and service._valid_project_shape(loaded.state), "loaded backup structural shape")
	_check(loaded.ok and source._valid_state(loaded.state), "loaded backup store validation")
	var backup_path := _work_directory.path_join("full.json")
	var exported: Dictionary = service.export_project(source, backup_path)
	_check(exported.ok and FileAccess.file_exists(backup_path), "T30 full JSON export exists: " + str(exported.get("error", "OK")))
	var manifest: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(backup_path))
	_check(int(manifest.manifest.get("source_generation", -1)) == int(saved.generation),
		"export manifest records source project generation, not only schema")
	_check(not service.export_project(source, backup_path).ok, "export cannot overwrite an existing file")
	var preview: Dictionary = service.preview_backup(backup_path, source)
	_check(preview.ok and preview.backup_counts.accounts == 1 and preview.backup_counts.events == 1 and \
		preview.backup_counts.instruments == 1 and preview.backup_counts.quotes == 1 and \
		preview.backup_counts.mappings == 1 and preview.backup_counts.beans == 5 and preview.backup_counts.ecology_entries == 1,
		"T30 preview reports full state counts: " + str(preview.get("error", "OK")))
	_check(preview.ok and int(preview.backup_generation) == int(saved.generation),
		"restore preview distinguishes source generation from schema version")
	var legacy: Dictionary = manifest.duplicate(true)
	legacy.manifest.erase("source_generation")
	var legacy_path := _work_directory.path_join("legacy-manifest.json")
	_write(legacy_path, JSON.stringify(legacy))
	var legacy_preview: Dictionary = service.preview_backup(legacy_path, source)
	_check(legacy_preview.ok and int(legacy_preview.backup_generation) == -1,
		"older version 1 backup without generation remains readable as unknown")
	var invalid_generation: Dictionary = manifest.duplicate(true)
	invalid_generation.manifest.source_generation = -1
	var invalid_generation_path := _work_directory.path_join("invalid-generation.json")
	_write(invalid_generation_path, JSON.stringify(invalid_generation))
	var invalid_preview: Dictionary = service.preview_backup(invalid_generation_path, source)
	_check(not invalid_preview.ok and invalid_preview.error == "BACKUP_MANIFEST_INVALID",
		"negative source generation is rejected")
	if not preview.ok:
		return
	var original_hash := JSON.stringify(loaded.state).sha256_text()
	var changed := Ledger.apply(state.ledger, {"command_id": "change-1", "type": "cash_delta",
		"account_id": "test-cash", "delta": "1000", "external": true,
		"effective_at": "2026-09-27T01:00:00Z"})
	_check(changed.ok, "new ledger event created")
	if not changed.ok:
		return
	var modified := state.duplicate(true)
	modified.ledger = changed.state
	_check(source.save_project(modified).ok, "new event saved after backup")
	var modified_hash := JSON.stringify(source.load_project().state).sha256_text()
	var stale := service.restore_project(source, backup_path, preview)
	_check(not stale.ok and stale.error == "CURRENT_STATE_CHANGED" and \
		JSON.stringify(source.load_project().state).sha256_text() == modified_hash,
		"stale preview cannot replace newer data: " + str(stale.get("error", "OK")))
	preview = service.preview_backup(backup_path, source)
	var restored := service.restore_project(source, backup_path, preview)
	_check(restored.ok and JSON.stringify(source.load_project().state).sha256_text() == original_hash,
		"T30 restore matches backup ledger, mapping, inventory and ecology: " + str(restored.get("error", "OK")))
	if restored.ok:
		var restored_state: Dictionary = source.load_project().state
		_check(restored_state.ledger.quotes.has("test-security") and \
			restored_state.ledger.fx_rates.has("USD") and restored_state.ledger.quote_history.size() == 1 and \
			restored_state.ledger.accounts["test-cash"].cost_method == "FIFO" and \
			restored_state.presentation.skin_id == "test-skin", "T30 quote, FX, cost setting and skin restored")
	if restored.ok:
		var safety_preview := service.preview_backup(restored.safety_backup_path, source)
		_check(safety_preview.ok and safety_preview.backup_counts.events == 2
			and int(safety_preview.backup_generation) == int(preview.current_generation),
			"T30 pre-restore safety backup preserves later event")
		_check(restored.safety_backup_path.begins_with(_work_directory.path_join("private-safety")),
			"pre-restore copy stays in configured private directory")
	var restored_hash := JSON.stringify(source.load_project().state).sha256_text()
	_check(not service.restore_project(source, backup_path, {}).ok and \
		JSON.stringify(source.load_project().state).sha256_text() == restored_hash,
		"restore requires explicit preview token")
	_test_bad_inputs(service, source, backup_path, restored_hash)
	_test_opening_position_export(service)
	_test_extended_event_export(service)
	var clean := Store.new(_work_directory.path_join("clean-install"))
	var clean_preview := service.preview_backup(backup_path, clean)
	var clean_result := service.restore_project(clean, backup_path, clean_preview)
	_check(clean_result.ok and JSON.stringify(clean.load_project().state).sha256_text() == original_hash,
		"T30 clean install restores complete logical state: " + str(clean_result.get("error", "OK")))


func _test_opening_position_export(service: RefCounted) -> void:
	var store := Store.new(_work_directory.path_join("replacement-source"))
	var state: Dictionary = store.new_project()
	var commands := [
		{"command_id": "aggregate-account", "type": "account_create", "account": {"id": "old-total", "currency": "CNY", "mode": "aggregate", "cost_method": "FIFO"}},
		{"command_id": "opening-aggregate", "type": "opening_cash", "account_id": "old-total", "amount": "1000", "effective_at": "2026-01-01T00:00:00Z"},
		{"command_id": "instrument-replacement", "type": "instrument_create", "instrument": {"id": "asset", "market": "TEST", "symbol": "ASSET", "currency": "CNY"}},
		{"command_id": "replace-aggregate", "type": "aggregate_replace", "account_id": "old-total", "effective_at": "2026-02-01T00:00:00Z", "detail_accounts": [
			{"account": {"id": "cash", "currency": "CNY", "mode": "detail", "cost_method": "FIFO"}, "opening_amount": "400"},
			{"account": {"id": "holdings", "currency": "CNY", "mode": "detail", "cost_method": "FIFO"}, "opening_positions": [{"instrument_id": "asset", "quantity": "1", "reference_price": "600"}]},
		]},
	]
	for command in commands:
		var result := Ledger.apply(state.ledger, command)
		if not result.ok:
			_check(false, "opening position fixture")
			return
		state.ledger = result.state
	_check(store.save_project(state).ok, "opening position state saved")
	var path := _work_directory.path_join("replacement.json")
	var exported: Dictionary = service.export_project(store, path)
	_check(exported.ok, "opening position event supported in full export")
	var preview: Dictionary = service.preview_backup(path, store)
	_check(preview.ok, "opening position event supported in restore preview")


func _test_extended_event_export(service: RefCounted) -> void:
	var store := Store.new(_work_directory.path_join("extended-source"))
	var state: Dictionary = store.new_project()
	var commands := [
		{"command_id": "cash-account", "type": "account_create", "account": {"id": "cash", "currency": "CNY", "mode": "detail", "cost_method": "FIFO"}},
		{"command_id": "cash-opening", "type": "opening_cash", "account_id": "cash", "amount": "1000", "effective_at": "2026-01-01T00:00:00Z"},
		{"command_id": "restricted-account", "type": "account_create", "account": {"id": "pension", "currency": "CNY", "mode": "detail", "cost_method": "FIFO", "asset_kind": "PENSION"}},
		{"command_id": "restricted-checkpoint", "type": "restricted_balance_set", "account_id": "pension", "amount": "500", "source_note": "Statement balance", "effective_at": "2026-01-02T00:00:00Z"},
		{"command_id": "security", "type": "instrument_create", "instrument": {"id": "fund", "market": "TEST", "symbol": "FUND", "currency": "CNY"}},
		{"command_id": "dividend-suggest", "type": "dividend_suggest", "account_id": "cash", "instrument_id": "fund", "gross_amount": "100", "source": "Statement", "effective_at": "2026-01-03T00:00:00Z"},
		{"command_id": "dividend-confirm", "type": "dividend_confirm", "suggestion_event_id": "dividend-suggest", "gross_amount": "100", "withholding_tax": "10", "effective_at": "2026-01-04T00:00:00Z"},
		{"command_id": "correct-opening", "type": "void_replace", "target_event_id": "cash-opening", "replacement": {"type": "opening_cash", "account_id": "cash", "amount": "900", "effective_at": "2026-01-01T00:00:00Z"}, "effective_at": "2026-01-05T00:00:00Z"},
	]
	for command in commands:
		var result := Ledger.apply(state.ledger, command)
		if not result.ok:
			_check(false, "extended event fixture: " + str(result.get("error", "unknown")))
			return
		state.ledger = result.state
	var before := Ledger.project(state.ledger)
	_check(before.ok and before.cash.cash == "990" and before.restricted_balances.pension == "500" and \
		before.dividends["dividend-suggest"].status == "confirmed", "extended event projection before backup")
	if not before.ok:
		return
	_check(store.save_project(state).ok, "restricted, dividend and void events saved")
	var path := _work_directory.path_join("extended.json")
	var exported: Dictionary = service.export_project(store, path)
	_check(exported.ok, "restricted, dividend and void events exported: " + str(exported.get("error", "OK")))
	if not exported.ok:
		return
	var preview: Dictionary = service.preview_backup(path, store)
	_check(preview.ok and preview.backup_counts.events == 6,
		"restricted, dividend and void events survive backup preview")
	if not preview.ok:
		return
	var clean := Store.new(_work_directory.path_join("extended-clean"))
	var clean_preview: Dictionary = service.preview_backup(path, clean)
	var restored: Dictionary = service.restore_project(clean, path, clean_preview)
	var after: Dictionary = Ledger.project(clean.load_project().state.ledger) if restored.ok else {}
	_check(restored.ok and after.ok and after.cash.cash == "990" and \
		after.restricted_balances.pension == "500" and \
		after.dividends["dividend-suggest"].status == "confirmed",
		"restricted, dividend and void events restore exactly")


func _test_bad_inputs(service: RefCounted, store: RefCounted, good_path: String, expected_hash: String) -> void:
	var original: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(good_path))
	var corrupt := original.duplicate(true)
	corrupt.payload = corrupt.payload + " "
	var corrupt_path := _work_directory.path_join("corrupt.json")
	_write(corrupt_path, JSON.stringify(corrupt))
	var corrupt_preview: Dictionary = service.preview_backup(corrupt_path, store)
	_check(not corrupt_preview.ok and corrupt_preview.error == "BACKUP_CHECKSUM_INVALID" and \
		JSON.stringify(store.load_project().state).sha256_text() == expected_hash,
		"T31 corrupt backup is rejected without changing current state")
	var future := original.duplicate(true)
	future.manifest.project_schema_version = Store.CURRENT_SCHEMA + 1
	var future_path := _work_directory.path_join("future.json")
	_write(future_path, JSON.stringify(future))
	var future_preview: Dictionary = service.preview_backup(future_path, store)
	_check(not future_preview.ok and future_preview.error == "FUTURE_SCHEMA_UNSUPPORTED" and \
		JSON.stringify(store.load_project().state).sha256_text() == expected_hash,
		"T31 future schema is rejected without changing current state")
	var malformed := original.duplicate(true)
	var malformed_state: Dictionary = JSON.parse_string(malformed.payload)
	malformed_state.ledger.events = "bad-type"
	malformed.payload = JSON.stringify(malformed_state)
	malformed.manifest.content_sha256 = malformed.payload.sha256_text()
	malformed.manifest.content_bytes = malformed.payload.to_utf8_buffer().size()
	var malformed_path := _work_directory.path_join("malformed.json")
	_write(malformed_path, JSON.stringify(malformed))
	var malformed_preview: Dictionary = service.preview_backup(malformed_path, store)
	_check(not malformed_preview.ok and malformed_preview.error == "BACKUP_PAYLOAD_INVALID" and \
		JSON.stringify(store.load_project().state).sha256_text() == expected_hash,
		"malformed but checksummed state is rejected")
	var missing_field := original.duplicate(true)
	var missing_state: Dictionary = JSON.parse_string(missing_field.payload)
	missing_state.ledger.events[0].erase("amount")
	missing_field.payload = JSON.stringify(missing_state)
	missing_field.manifest.content_sha256 = missing_field.payload.sha256_text()
	missing_field.manifest.content_bytes = missing_field.payload.to_utf8_buffer().size()
	var missing_path := _work_directory.path_join("missing-field.json")
	_write(missing_path, JSON.stringify(missing_field))
	var missing_preview: Dictionary = service.preview_backup(missing_path, store)
	_check(not missing_preview.ok and missing_preview.error == "BACKUP_PAYLOAD_INVALID" and \
		JSON.stringify(store.load_project().state).sha256_text() == expected_hash,
		"checksummed state with missing event field is rejected")
	var changed_preview: Dictionary = service.preview_backup(good_path, store)
	var changed_result: Dictionary = service.restore_project(store, corrupt_path, changed_preview)
	_check(not changed_result.ok and JSON.stringify(store.load_project().state).sha256_text() == expected_hash,
		"T31 backup changed after preview cannot replace current state")


func _sample_project(store: RefCounted) -> Dictionary:
	var state: Dictionary = store.new_project()
	var account := Ledger.apply(state.ledger, {"command_id": "account-1", "type": "account_create",
		"account": {"id": "test-cash", "name": "Test cash", "currency": "CNY",
		"mode": "detail", "cost_method": "FIFO"}})
	if not account.ok:
		return {}
	var opening := Ledger.apply(account.state, {"command_id": "opening-1", "type": "opening_cash",
		"account_id": "test-cash", "amount": "5000", "effective_at": "2026-09-27T00:00:00Z"})
	if not opening.ok:
		return {}
	var instrument := Ledger.apply(opening.state, {"command_id": "instrument-1", "type": "instrument_create",
		"instrument": {"id": "test-security", "market": "TEST", "symbol": "TEST",
		"currency": "CNY"}})
	if not instrument.ok:
		return {}
	var market_quote := Ledger.apply(instrument.state, {"command_id": "quote-1", "type": "quote_update",
		"quote": {"instrument_id": "test-security", "price": "12.34",
		"quoted_at": "2026-09-27T00:00:00Z", "source": "test-manual"}})
	if not market_quote.ok:
		return {}
	var fx := Ledger.apply(market_quote.state, {"command_id": "fx-1", "type": "fx_update",
		"fx": {"currency": "USD", "rate_to_base": "7.1",
		"quoted_at": "2026-09-27T00:00:00Z", "source": "test-manual"}})
	if not fx.ok:
		return {}
	state.ledger = fx.state
	var quote := {"id": "test-gold", "price": "1000", "currency": "CNY",
		"unit": "CURRENCY_PER_GRAM", "source": "test-manual", "quoted_at": "2026-09-27T00:00:00Z"}
	var mapping := Mapping.create_revision("snapshot-1", "5000", "CNY", quote)
	if not mapping.ok:
		return {}
	var inventory := Inventory.apply_mapping(Inventory.new_state(), mapping.revision, "inventory-1")
	if not inventory.ok:
		return {}
	state.mappings.append(mapping.revision)
	state.inventory = inventory.state
	state.presentation.skin_id = "test-skin"
	state.ecology = {"test-fish-1": {"species": "test-fish", "growth_stage": 2}}
	return state


func _write(path: String, data: String) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string(data)
	file.close()


func _check(condition: bool, label: String) -> void:
	checks += 1
	if not condition:
		failures.append("FAIL: " + label)
