extends SceneTree

const Organizer = preload("res://scripts/domain/personal_bean_organizer_flow.gd")
const Personal = preload("res://scripts/data/personal_flow.gd")
const Store = preload("res://scripts/data/project_store.gd")
const Inventory = preload("res://scripts/domain/jar_inventory.gd")

var checks := 0
var failures: Array[String] = []


func _initialize() -> void:
	var directory := ProjectSettings.globalize_path("res://").get_base_dir().path_join(
		"tests/domain/tmp")
	DirAccess.make_dir_recursive_absolute(directory)
	var suffix := str(Time.get_ticks_usec())
	_test_single_jar(directory.path_join("organizer-" + suffix))
	_test_second_jar(directory.path_join("organizer-multijar-" + suffix))
	if failures.is_empty():
		print("PERSONAL BEAN ORGANIZER PASS: %d checks" % checks)
		quit(0)
	else:
		for failure in failures:
			printerr("FAIL: " + failure)
		printerr("PERSONAL BEAN ORGANIZER FAIL: %d/%d" % [failures.size(), checks])
		quit(1)


func _test_single_jar(path: String) -> void:
	var flow := Organizer.new(path)
	_check(not flow.load().ok and flow.load().error == "NOT_INITIALIZED",
		"empty personal project does not expose inventory actions")
	var opened := Personal.new(path).create_opening_cash("open", "cash", "Cash", "50000",
		"1000", "2026-09-27T02:00:00Z")
	_check(opened.ok, "create isolated 50 bean personal fixture")
	if not opened.ok:
		return
	var before := Store.new(path).load_project()
	var ledger_hash := Store.canonical_ledger_hash(before.state.ledger)
	var mapping_count: int = before.state.mappings.size()
	var view := flow.load()
	_check(view.ok and view.jars.size() == 1 and view.jars[0].one_count == 50
		and view.jars[0].ten_count == 0 and view.snapshot_status == "CURRENT",
		"read-only inventory lists 50 current one gram beans")
	var ids: Array = []
	for bean in view.jars[0].beans.slice(0, 10):
		ids.append(str(bean.id))
	var preview := flow.preview_combine(str(view.jars[0].id), ids, view.generation)
	_check(preview.ok and preview.before_objects == 50 and preview.after_objects == 41
		and preview.whole_grams == "50", "combine preview conserves grams and predicts count")
	_check(Store.new(path).load_project().generation == before.generation,
		"preview does not save a generation")
	var declined := flow.confirm(preview, false)
	_check(not declined.ok and declined.error == "EXPLICIT_CONFIRMATION_REQUIRED"
		and Store.new(path).load_project().generation == before.generation,
		"explicit confirmation required")
	var tampered := preview.duplicate(true)
	tampered.bean_ids[0] = "invented-bean"
	var rejected := flow.confirm(tampered, true)
	_check(not rejected.ok and Store.new(path).load_project().generation == before.generation,
		"altered selection cannot reuse preview")
	var wrong_jar := flow.preview_combine("unknown-jar", ids, view.generation)
	_check(not wrong_jar.ok and wrong_jar.error == "SELECTION_NOT_IN_JAR",
		"a selected jar must own every source bean")
	var confirmed := flow.confirm(preview, true)
	_check(confirmed.ok and not confirmed.duplicate
		and confirmed.generation == before.generation + 1
		and confirmed.jars[0].one_count == 40 and confirmed.jars[0].ten_count == 1,
		"confirmed combine saves one inventory revision")
	if not confirmed.ok:
		return
	var persisted := Store.new(path).load_project()
	_check(persisted.ok and Inventory.validate(persisted.state.inventory)
		and Store.canonical_ledger_hash(persisted.state.ledger) == ledger_hash
		and persisted.state.mappings.size() == mapping_count
		and persisted.state.inventory.whole_grams == 50,
		"restart preserves conserved grams and unchanged ledger/mapping")
	var replay := flow.confirm(preview, true)
	_check(replay.ok and replay.duplicate and replay.generation == confirmed.generation,
		"confirm replay is idempotent across restart")
	var ten_id := ""
	for bean in confirmed.jars[0].beans:
		if int(bean.denomination_grams) == 10:
			ten_id = str(bean.id)
	var split_preview := flow.preview_split(str(confirmed.jars[0].id), ten_id,
		confirmed.generation)
	_check(split_preview.ok and split_preview.before_objects == 41
		and split_preview.after_objects == 50,
		"split preview predicts ten children without changing grams")
	var split_saved := flow.confirm(split_preview, true)
	_check(split_saved.ok and split_saved.jars[0].one_count == 50
		and split_saved.jars[0].ten_count == 0 and split_saved.whole_grams == "50"
		and Store.canonical_ledger_hash(Store.new(path).load_project().state.ledger) == ledger_hash,
		"split is persisted and never changes finance")
	var stale := flow.confirm(preview, true)
	_check(stale.ok and stale.duplicate, "older successfully applied operation remains replay safe")
	var invalid_split := flow.preview_split(str(split_saved.jars[0].id), ten_id,
		split_saved.generation)
	_check(not invalid_split.ok, "retired ten gram bean cannot be split again")
	var next_ids: Array = []
	for bean in split_saved.jars[0].beans.slice(0, 10):
		next_ids.append(str(bean.id))
	var unapplied_preview := flow.preview_combine(str(split_saved.jars[0].id),
		next_ids, split_saved.generation)
	var edited: Dictionary = Store.new(path).load_project()
	edited.state.presentation.skin_id = "ecology"
	var changed := Store.new(path).save_project(edited.state, edited.generation)
	var stale_unapplied := flow.confirm(unapplied_preview, true)
	_check(unapplied_preview.ok and changed.ok and not stale_unapplied.ok
		and stale_unapplied.error == "GENERATION_CONFLICT"
		and Store.new(path).load_project().generation == changed.generation,
		"unapplied preview cannot commit after another project generation")


func _test_second_jar(path: String) -> void:
	var opened := Personal.new(path).create_opening_cash("open-many", "cash", "Cash",
		"310000", "1000", "2026-09-27T02:00:00Z")
	_check(opened.ok, "create two jar fixture")
	if not opened.ok:
		return
	var flow := Organizer.new(path)
	var view := flow.load()
	_check(view.ok and view.jars.size() == 2 and view.jars[1].one_count == 10,
		"second jar contains ten one gram beans")
	if not view.ok or view.jars.size() != 2:
		return
	var ids: Array = []
	for bean in view.jars[1].beans:
		ids.append(str(bean.id))
	var preview := flow.preview_combine(str(view.jars[1].id), ids, view.generation)
	var saved := flow.confirm(preview, true) if preview.ok else {"ok": false}
	_check(preview.ok and saved.ok and saved.jars[1].one_count == 0
		and saved.jars[1].ten_count == 1 and saved.jars[0].one_count == 300,
		"combining second jar keeps resulting ten gram bean in selected jar")
	if not saved.ok:
		return
	var ten_id := str(saved.jars[1].beans[0].id)
	var split_preview := flow.preview_split(str(saved.jars[1].id), ten_id,
		saved.generation)
	var split := flow.confirm(split_preview, true) if split_preview.ok else {"ok": false}
	_check(split.ok and split.jars[1].one_count == 10
		and split.jars[0].one_count == 300 and split.whole_grams == "310",
		"splitting second jar restores ten one gram beans in same jar")


func _check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)
