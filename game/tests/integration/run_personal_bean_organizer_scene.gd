extends SceneTree

const Personal = preload("res://scripts/data/personal_flow.gd")
const Store = preload("res://scripts/data/project_store.gd")
const Inventory = preload("res://scripts/domain/jar_inventory.gd")
const Scene = preload("res://scenes/personal_bean_organizer.tscn")

var checks := 0
var failures: Array[String] = []


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var directory := ProjectSettings.globalize_path("res://").get_base_dir().path_join(
		"tests/integration/tmp")
	DirAccess.make_dir_recursive_absolute(directory)
	var path := directory.path_join("organizer-scene-" + str(Time.get_ticks_usec()))
	var opened := Personal.new(path).create_opening_cash("open", "cash", "Cash",
		"50000", "1000", "2026-09-27T02:00:00Z")
	_check(opened.ok, "setup isolated personal jar")
	if not opened.ok:
		_finish()
		return
	var store := Store.new(path)
	var before := store.load_project()
	var ledger_hash := Store.canonical_ledger_hash(before.state.ledger)
	var page: Control = Scene.instantiate()
	page.set("base_path", path)
	root.add_child(page)
	await process_frame
	var view: Dictionary = page.get("_view")
	var items: ItemList = page.get("_item_list")
	_check(view.ok and items.item_count == 50 and page.get("_mode") == "COMBINE",
		"combine page lists current one gram beans")
	items.select(0)
	page.call("_on_preview_pressed")
	_check(page.get("_confirm_button").disabled and
		str(page.get("_preview_label").text).contains("选 10 颗"),
		"one selected bean cannot be confirmed as ten")
	for index in 10:
		items.select(index, false)
	page.call("_on_preview_pressed")
	var preview: Dictionary = page.get("_shown_preview")
	_check(preview.ok and not page.get("_confirm_button").disabled
		and store.load_project().generation == before.generation,
		"full selection previews without writing project")
	items.select(10, false)
	page.call("_invalidate_preview")
	_check(page.get("_confirm_button").disabled,
		"changed selection invalidates confirmation")
	items.deselect(10)
	page.call("_on_preview_pressed")
	page.call("_on_confirm_pressed")
	var combined: Dictionary = store.load_project()
	_check(combined.ok and combined.generation == before.generation + 1
		and Inventory.active_beans(combined.state.inventory).size() == 41
		and Store.canonical_ledger_hash(combined.state.ledger) == ledger_hash,
		"UI confirm saves a 10 gram bean and leaves ledger unchanged")
	var jar: Node3D = load("res://scenes/jar_view.tscn").instantiate()
	root.add_child(jar)
	await process_frame
	var mapped: Dictionary = Personal.new(path).load()
	var applied: bool = mapped.ok and jar.apply_display_snapshot(mapped.display_snapshot)
	var ten_visible := 0
	for body in jar.get("_beans").values():
		if int(body.get_meta("denomination_grams")) == 10:
			ten_visible += 1
	_check(applied and jar.get_visual_metrics().bean_count == 41 and ten_visible == 1,
		"reopened formal jar builds one visible ten gram physics bean")
	page.call("_set_mode", "SPLIT")
	items = page.get("_item_list")
	_check(items.item_count == 1, "split page shows one ten gram bean")
	items.select(0)
	page.call("_on_preview_pressed")
	_check(page.get("_shown_preview").ok and store.load_project().generation ==
		combined.generation, "split preview does not save")
	page.call("_on_confirm_pressed")
	var split: Dictionary = store.load_project()
	_check(split.generation == combined.generation + 1
		and Inventory.active_beans(split.state.inventory).size() == 50
		and int(split.state.inventory.whole_grams) == 50,
		"UI split restores 50 one gram beans after restart")
	mapped = Personal.new(path).load()
	applied = mapped.ok and jar.apply_display_snapshot(mapped.display_snapshot)
	ten_visible = 0
	for body in jar.get("_beans").values():
		if int(body.get_meta("denomination_grams")) == 10:
			ten_visible += 1
	_check(applied and jar.get_visual_metrics().bean_count == 50 and ten_visible == 0,
		"same formal jar replaces ten gram body with ten one gram bodies")
	jar.queue_free()
	var pending: Dictionary = split.state.duplicate(true)
	pending.valuation_pending = {"reason": "TEST_PENDING",
		"ledger_hash": Store.canonical_ledger_hash(pending.ledger)}
	var pending_save := store.save_project(pending, split.generation)
	page.call("_refresh")
	_check(pending_save.ok and page.get("_view").snapshot_status == "PREVIOUS_COMPLETE"
		and str(page.get("_status_label").text).contains("待重估"),
		"pending jar remains visibly old during presentation-only organizing")
	var returned := [false]
	page.return_requested.connect(func() -> void: returned[0] = true)
	page.call("_on_return_pressed")
	_check(returned[0], "return action leads back toward personal jar")
	page.queue_free()
	await process_frame
	_finish()


func _check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)


func _finish() -> void:
	if failures.is_empty():
		print("PERSONAL BEAN ORGANIZER SCENE PASS: %d checks" % checks)
		quit(0)
	else:
		for failure in failures:
			printerr("FAIL: " + failure)
		printerr("PERSONAL BEAN ORGANIZER SCENE FAIL: %d/%d" % [
			failures.size(), checks])
		quit(1)
