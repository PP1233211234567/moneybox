extends SceneTree

const DemoFlow = preload("res://scripts/data/demo_flow.gd")


func _initialize() -> void:
	var directory := ProjectSettings.globalize_path("res://").get_base_dir().path_join("tests").path_join("data").path_join("tmp")
	DirAccess.make_dir_recursive_absolute(directory)
	var base := directory.path_join("demo-" + str(Time.get_ticks_usec()))
	var flow := DemoFlow.new(base)
	var initial := flow.load_or_create()
	if not initial.ok:
		printerr("demo flow failure: initial state ", initial.get("error", "unknown"), " ", initial.get("detail", ""))
		quit(1)
		return
	_assert(initial.bean_count == 50 and initial.amount == "50000" and initial.equivalent_grams == "50", "initial amount and beans")
	var change := flow.record_cash_change("1000")
	_assert(change.ok, "demo change committed")
	_assert(change.bean_count == 51 and change.amount == "51000" and change.equivalent_grams == "51", "new amount and bean")
	var restarted := DemoFlow.new(base).load_or_create()
	_assert(restarted.ok and restarted.bean_count == 51 and restarted.generation == change.generation, "restart restores without replay")
	var reduced := DemoFlow.new(base).record_cash_change("-1000")
	_assert(reduced.ok and reduced.bean_count == 50 and reduced.amount == "50000", "decrease reconciles")
	var switched := DemoFlow.new(base).set_skin("ecology")
	_assert(switched.ok and switched.view.skin_id == "ecology" and switched.bean_count == 50, "skin changes without altering finance")
	var skin_restart := DemoFlow.new(base).load_or_create()
	_assert(skin_restart.ok and skin_restart.view.skin_id == "ecology" and skin_restart.equivalent_grams == "50", "skin persists on restart")
	var hidden := DemoFlow.new(base).set_privacy_mode("hide_total")
	_assert(hidden.ok and hidden.privacy_mode == "hide_total" and hidden.amount == "50000", "hiding amount does not change ledger")
	var privacy_restart := DemoFlow.new(base).load_or_create()
	_assert(privacy_restart.ok and privacy_restart.privacy_mode == "hide_total" and privacy_restart.bean_count == 50, "privacy choice persists on restart")
	var repeated_hide := DemoFlow.new(base).set_privacy_mode("hide_total")
	_assert(repeated_hide.ok and repeated_hide.generation == hidden.generation, "repeated privacy selection does not rewrite state")
	print("demo flow: passed")
	quit(0)


func _assert(condition: bool, label: String) -> void:
	if not condition:
		printerr("demo flow failure: ", label)
		quit(1)
