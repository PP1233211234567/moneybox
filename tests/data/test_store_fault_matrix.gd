extends SceneTree
## Development JSON store failure matrix. This does not test Android process death or SQLite.

const Store = preload("res://scripts/data/project_store.gd")
const Ledger = preload("res://scripts/data/ledger_core.gd")

var failures: Array[String] = []
var checks := 0


func _initialize() -> void:
	var directory := ProjectSettings.globalize_path("res://project.godot").get_base_dir().get_base_dir().path_join("tests/tmp")
	DirAccess.make_dir_recursive_absolute(directory)
	var base := directory.path_join("fault-matrix-" + str(Time.get_ticks_usec()))
	var ledger := Ledger.new_state()
	var account := Ledger.apply(ledger, {"command_id": "fixture-account", "type": "account_create",
		"account": {"id": "safe-cash", "name": "Synthetic", "currency": "CNY",
			"mode": "detail", "cost_method": "FIFO"}})
	_check(account.ok, "fixture account")
	if not account.ok:
		_finish()
		return
	var opening := Ledger.apply(account.state, {"command_id": "fixture-opening",
		"type": "opening_cash", "account_id": "safe-cash", "amount": "123.45",
		"effective_at": "2026-01-01T00:00:00Z"})
	_check(opening.ok, "fixture opening")
	if not opening.ok:
		_finish()
		return
	var old_state := {"schema_version": 1, "ledger": opening.state}
	_write_envelope(base + ".1.json", old_state, 1, 1)
	var store := Store.new(base)
	var migrated := store.load_project()
	_check(migrated.ok and migrated.migrated and migrated.generation == 1,
		"v1 migrates in memory without advancing generation")
	_check(migrated.state.ledger.accounts.has("safe-cash") and
			migrated.state.ledger.events[0].id == "fixture-opening" and
			Ledger.project(migrated.state.ledger).asset_total == "123.45",
		"migration preserves account, event identity and exact decimal amount")
	_check(not FileAccess.file_exists(base + ".0.json"),
		"read-only migration does not overwrite an old slot")
	var first_save := store.save_project(migrated.state, 1)
	_check(first_save.ok and first_save.generation == 2 and first_save.path == base + ".0.json",
		"v2 writes inactive slot after v1 source")
	if not first_save.ok:
		_finish()
		return
	_write_text(base + ".0.json", "{interrupted")
	var previous := store.load_project()
	_check(previous.ok and previous.recovered and previous.generation == 1 and
			Ledger.project(previous.state.ledger).asset_total == "123.45",
		"truncated new slot rolls back to intact v1 balance")
	var second_save := store.save_project(previous.state, 1)
	_check(second_save.ok and second_save.generation == 2,
		"recovery can safely reapply in-memory migration")
	if not second_save.ok:
		_finish()
		return
	_write_text(base + ".1.json", "{interrupted-old-slot")
	var newest := store.load_project()
	_check(newest.ok and newest.recovered and newest.generation == 2 and
			newest.state.ledger.events[0].id == "fixture-opening" and
			Ledger.project(newest.state.ledger).asset_total == "123.45",
		"corrupt older slot cannot discard the complete current generation")
	var future: Dictionary = newest.state.duplicate(true)
	future.schema_version = 99
	_write_envelope(base + ".1.json", future, 99, 3)
	var future_block := store.load_project()
	_check(not future_block.ok and future_block.error == "UNSUPPORTED_FUTURE_SCHEMA",
		"newer future schema blocks older code from writing over it")
	_check(not store.save_project(newest.state, 2).ok and
			store.load_project().error == "UNSUPPORTED_FUTURE_SCHEMA",
		"save does not clobber unsupported future generation")
	_write_text(base + ".1.json", "{incomplete-future")
	var fallback := store.load_project()
	_check(fallback.ok and fallback.recovered and fallback.generation == 2 and
			Ledger.project(fallback.state.ledger).asset_total == "123.45",
		"damaged future slot falls back to complete prior generation")
	_finish()


func _write_envelope(path: String, state: Dictionary, schema: int, generation: int) -> void:
	var payload := JSON.stringify(state)
	_write_text(path, JSON.stringify({"format": "moneybox-state", "schema_version": schema,
		"generation": generation, "payload": payload, "sha256": payload.sha256_text()}))


func _write_text(path: String, value: String) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string(value)
	file.flush()
	file.close()


func _check(condition: bool, label: String) -> void:
	checks += 1
	if not condition:
		failures.append(label)


func _finish() -> void:
	for failure in failures:
		printerr("store fault matrix: ", failure)
	print("store fault matrix: %d checks, %d failures" % [checks, failures.size()])
	quit(0 if failures.is_empty() else 1)
