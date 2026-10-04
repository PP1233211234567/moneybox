extends SceneTree

const Mapping = preload("res://scripts/domain/gold_mapping_service.gd")
const Inventory = preload("res://scripts/domain/jar_inventory.gd")
const Decimal = preload("res://scripts/data/decimal_text.gd")

var failures: Array[String] = []
var checks := 0


func _initialize() -> void:
	_test_mapping()
	_test_inventory()
	if failures.is_empty():
		print("DOMAIN TESTS PASS: %d checks" % checks)
		quit(0)
	else:
		for failure in failures:
			printerr(failure)
		printerr("DOMAIN TESTS FAIL: %d failures in %d checks" % [failures.size(), checks])
		quit(1)


func _test_mapping() -> void:
	var gross := Mapping.calculate("100000", "1000")
	_check(gross.ok and gross.equivalent_grams == "100", "T11 gross 100 grams")
	var net := Mapping.calculate("80000", "1000", "net_assets")
	_check(net.ok and net.equivalent_grams == "80" and net.metric == "net_assets", "T11 net 80 grams and label")
	var quote := {"id": "quote-troy", "price": "3110.34768", "currency": "USD",
		"unit": "CURRENCY_PER_TROY_OUNCE", "source": "TEST", "quoted_at": "2026-09-27T00:00:00Z"}
	var fx := {"id": "fx-usd-cny", "rate": "7", "from_currency": "USD", "to_currency": "CNY",
		"source": "TEST", "quoted_at": "2026-09-27T00:00:00Z"}
	var troy := Mapping.create_revision("snapshot-troy", "7000", "CNY", quote, fx)
	_check(troy.ok and troy.revision.price_per_gram == "700" and troy.revision.equivalent_grams == "10",
		"T12 troy ounce conversion exactly once")
	var partial := Mapping.calculate("23700", "1000")
	_check(partial.ok and partial.whole_grams == "23" and partial.fractional_grams == "0.7",
		"T13 23 beans plus 0.7 gram")
	var almost_one := Mapping.calculate("0.999999999999999999999999999999", "1")
	_check(almost_one.ok and almost_one.whole_grams == "0", "exact floor near one gram")
	var old_quote := {"id": "quote-old", "price": "1000", "currency": "CNY",
		"unit": "CURRENCY_PER_GRAM", "source": "TEST", "quoted_at": "2026-09-26T00:00:00Z"}
	var new_quote := {"id": "quote-new", "price": "1250", "currency": "CNY",
		"unit": "CURRENCY_PER_GRAM", "source": "TEST", "quoted_at": "2026-09-27T00:00:00Z"}
	var old_revision := Mapping.create_revision("snapshot-1", "100000", "CNY", old_quote)
	var repeated := Mapping.create_revision("snapshot-1", "100000", "CNY", old_quote, {}, "total_assets", old_revision.revision)
	_check(repeated.ok and not repeated.changed and repeated.revision.id == old_revision.revision.id,
		"T14 same source revision is idempotent")
	var repriced := Mapping.create_revision("snapshot-1", "100000", "CNY", new_quote, {}, "total_assets", old_revision.revision, "USER_REPRICE")
	_check(repriced.ok and repriced.revision.equivalent_grams == "80" and repriced.revision.amount == "100000"
		and repriced.revision.gold_price_change_grams == "-20", "T15 repricing changes grams, not assets")
	_check(not Mapping.calculate("100", "0").ok and not Mapping.calculate("100", "-1").ok,
		"T16 zero and negative gold quotes rejected")
	_check(not Mapping.price_per_gram({"price": "100", "currency": "CNY", "unit": "UNKNOWN"}, "CNY").ok,
		"T16 unknown unit rejected")
	_check(not Mapping.create_revision("snapshot", "100", "CNY",
		{"id": "missing-time", "price": "100", "currency": "CNY", "unit": "CURRENCY_PER_GRAM"}).ok,
		"quote provenance required before mapping")
	_check(not Mapping.price_per_gram(quote, "CNY", {"rate": "7", "from_currency": "USD",
		"to_currency": "CNY"}).ok, "cross-currency mapping requires FX provenance")
	_check(not Mapping.calculate("-1", "1000", "total_assets").ok,
		"negative gross assets rejected")
	var negative_net := Mapping.calculate("-100", "1000", "net_assets")
	_check(negative_net.ok and negative_net.negative_net_assets and negative_net.whole_grams == "0",
		"negative net assets preserve value but make no beans")


func _test_inventory() -> void:
	var state := Inventory.new_state(12, 12)
	_check(Inventory.validate(state), "initial empty state valid")
	var ten := Inventory.reconcile(state, 10, "0", "map-10", "cmd-10", state.revision)
	_check(ten.ok and Inventory.active_beans(ten.state).size() == 10 and Inventory.validate(ten.state),
		"ten grams make ten basic beans")
	state = ten.state
	var ids: Array = []
	for bean in Inventory.active_beans(state):
		ids.append(bean.id)
	var combined := Inventory.combine(state, ids, "combine-1", state.revision)
	_check(combined.ok and Inventory.active_beans(combined.state).size() == 1
		and Inventory.active_beans(combined.state)[0].denomination_grams == 10,
		"T17 combine ten 1g beans into one 10g bean")
	var replay := Inventory.combine(combined.state, ids, "combine-1", state.revision)
	_check(replay.ok and replay.duplicate and replay.state.state_hash == combined.state.state_hash,
		"T17 double click commits once")
	var restored: Dictionary = JSON.parse_string(JSON.stringify(combined.state))
	_check(Inventory.validate(restored) and restored.state_hash == combined.state.state_hash,
		"T18 serialized committed inventory survives reload")
	var restored_replay := Inventory.combine(restored, ids, "combine-1", ten.state.revision)
	_check(restored_replay.ok and restored_replay.duplicate and restored_replay.state.state_hash == restored.state_hash,
		"T18 reload does not recommit prior combine")
	var nine := Inventory.reconcile(restored, 9, "0", "map-9", "cmd-9", restored.revision)
	_check(nine.ok and Inventory.active_beans(nine.state).size() == 9
		and nine.automatic_splits.size() == 1 and Inventory.validate(nine.state),
		"T19 revaluation splits 10g then removes 1g")
	state = nine.state
	var many := Inventory.reconcile(state, 30, "0.7", "map-30", "cmd-30", state.revision)
	_check(many.ok and many.state.jars.size() >= 3 and Inventory.active_beans(many.state).size() == 30
		and many.state.fractional_grams == "0.7", "T20 multiple jars without forced combination")
	var original_hash: String = many.state.state_hash
	state = many.state
	for _i in 100:
		var duplicate := Inventory.reconcile(state, 30, "0.7", "map-30", "cmd-30", state.revision)
		if not duplicate.ok or not duplicate.duplicate:
			_check(false, "T14 replay must be duplicate")
			break
		state = duplicate.state
	_check(state.state_hash == original_hash and state.revision == many.state.revision,
		"T14 100 mapping replays leave inventory unchanged")
	var conflict := Inventory.reconcile(state, 31, "0", "map-31", "cmd-31", state.revision - 1)
	_check(not conflict.ok and conflict.error == "REVISION_CONFLICT" and state.state_hash == original_hash,
		"stale expected revision cannot overwrite inventory")
	var map_reuse := Inventory.reconcile(state, 29, "0", "map-30", "different-command", state.revision)
	_check(not map_reuse.ok and map_reuse.error == "MAPPING_ID_REUSED", "same mapping ID cannot change target")
	var split_bean := Inventory.split(combined.state, combined.output_id, "split-1", combined.state.revision)
	_check(split_bean.ok and Inventory.active_beans(split_bean.state).size() == 10
		and Decimal.compare(str(split_bean.state.whole_grams), "10") == 0, "manual split conserves ten grams")


func _check(condition: bool, label: String) -> void:
	checks += 1
	if not condition:
		failures.append("FAIL: " + label)
