extends SceneTree

const Store = preload("res://scripts/data/project_store.gd")
const Ledger = preload("res://scripts/data/ledger_core.gd")
var failures := 0


func _initialize() -> void:
	var directory := ProjectSettings.globalize_path("res://").get_base_dir().path_join("tests").path_join("data").path_join("tmp")
	DirAccess.make_dir_recursive_absolute(directory)
	var unique := str(Time.get_ticks_usec())
	_test_two_slot_recovery(directory.path_join("recovery-" + unique))
	_test_migration(directory.path_join("migration-" + unique))
	print("store: %s" % ("passed" if failures == 0 else "%d failures" % failures))
	quit(0 if failures == 0 else 1)


func _equal(actual: Variant, expected: Variant, label: String) -> void:
	if actual != expected:
		printerr(label, ": got ", actual, " expected ", expected)
		failures += 1


func _test_two_slot_recovery(base: String) -> void:
	var store := Store.new(base)
	var empty := store.new_project()
	var first := store.save_project(empty)
	_equal(first.ok, true, "first save")
	var state := empty.duplicate(true)
	var result := Ledger.apply(state.ledger, {"command_id": "test-account", "type": "account_create", "account": {"id": "a", "currency": "CNY", "mode": "detail", "cost_method": "FIFO"}})
	state.ledger = result.state
	result = Ledger.apply(state.ledger, {"command_id": "test-opening", "type": "opening_cash", "account_id": "a", "amount": "123.45", "effective_at": "2026-01-01T00:00:00Z"})
	state.ledger = result.state
	var second := store.save_project(state)
	_equal(second.ok, true, "second save")
	_equal(Ledger.project(store.load_project().state.ledger).asset_total, "123.45", "reload complete state")
	_equal(store.save_project(empty, 0).error, "GENERATION_CONFLICT", "stale writer rejected")
	var broken := FileAccess.open(second.path, FileAccess.WRITE)
	broken.store_string("{partial write")
	broken.flush()
	broken.close()
	var recovered := store.load_project()
	_equal(recovered.ok, true, "previous slot recovered")
	_equal(recovered.recovered, true, "corruption flagged")
	_equal(recovered.generation, 1, "previous generation")
	_equal(recovered.state.ledger.events.size(), 0, "no partial ledger")


func _test_migration(base: String) -> void:
	var v1 := {"schema_version": 1, "ledger": Ledger.new_state()}
	var payload := JSON.stringify(v1)
	var envelope := {"format": "moneybox-state", "schema_version": 1, "generation": 1, "payload": payload, "sha256": payload.sha256_text()}
	var file := FileAccess.open(base + ".1.json", FileAccess.WRITE)
	file.store_string(JSON.stringify(envelope))
	file.flush()
	file.close()
	var store := Store.new(base)
	var loaded := store.load_project()
	_equal(loaded.ok, true, "v1 load")
	_equal(loaded.migrated, true, "v1 migrated in memory")
	_equal(loaded.state.schema_version, 2, "v2 schema")
	_equal(loaded.generation, 1, "migration does not overwrite source")
	var saved := store.save_project(loaded.state)
	_equal(saved.ok, true, "migrated save")
	_equal(store.load_project().generation, 2, "v2 generation")
	var future: Dictionary = loaded.state.duplicate(true)
	future.schema_version = 99
	var future_payload := JSON.stringify(future)
	var future_envelope := {"format": "moneybox-state", "schema_version": 99, "generation": 3, "payload": future_payload, "sha256": future_payload.sha256_text()}
	file = FileAccess.open(base + ".1.json", FileAccess.WRITE)
	file.store_string(JSON.stringify(future_envelope))
	file.flush()
	file.close()
	_equal(store.load_project().error, "UNSUPPORTED_FUTURE_SCHEMA", "future version protects current data")
