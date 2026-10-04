extends SceneTree

const JAR_SCENE := preload("res://scenes/jar_view.tscn")
const TICK := 1.0 / 60.0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var host := Node3D.new()
	root.add_child(host)
	var jar: JarView = JAR_SCENE.instantiate()
	host.add_child(jar)
	jar.show_demo_beans(50)
	_check(jar.get_visual_metrics()["bean_count"] == 50, "50 demo bodies")
	_check(jar.get_visual_metrics()["visual_asset"] == "gold_jar.glb", "formal GLB drives visual meshes")
	_check(not jar.get_node("GoldJarModel").find_child("BeanPrototypes", true, false).visible, "prototype beans are hidden")
	_check(not jar.get_node("GlassWall").visible, "procedural jar visual is hidden")
	var before := jar.get_node("Bean_demo-000")
	jar.show_demo_beans(50)
	_check(jar.get_node("Bean_demo-000") == before, "same snapshot does not respawn beans")
	jar.apply_inventory_snapshot({"inventory_revision_id": "test-1", "beans": [{"id": "one", "denomination_grams": 1}, {"id": "ten", "denomination_grams": 10}]})
	_check(jar.get_visual_metrics()["bean_count"] == 2, "authoritative snapshot replaces demo")
	var small: RigidBody3D = jar.get_node("Bean_one")
	var large: RigidBody3D = jar.get_node("Bean_ten")
	_check(is_equal_approx(small.mass, 0.001), "1 g body mass")
	_check(is_equal_approx(large.mass, 0.010), "10 g body mass")
	_check(small.get_node("ConvexBeanCollider").shape is ConvexPolygonShape3D, "convex collision shape")
	_check(small.get_node("GoldBeanVisual").scale == Vector3.ONE * JarView.WORLD_SCALE, "imported bean mesh uses uniform world scale")
	jar.set_skin("ecology")
	_check(jar.get_visual_metrics()["skin_id"] == "ecology", "skin switch")
	_check(jar.get_node("GoldJarModel").find_child("EcologyOuter", true, false).visible, "formal outer shell toggles with skin")
	_check(_count_collision_objects(jar.get_node("EcologyVisualOnly")) == 0, "ecology has no physics colliders")
	jar.set_active_visible(false)
	_check(small.freeze and large.freeze, "visibility pauses physics")
	jar.set_active_visible(true)
	_check(not small.freeze and not large.freeze, "visibility resumes physics")
	var saved := jar.get_scene_state()
	_check(jar.restore_scene_state(saved), "transient layout restoration")
	jar.set_skin("basic")
	for denomination in [1, 10]:
		for height_m in [0.10, 0.20]:
			await _measure_drop(jar, denomination, height_m)
	print("JAR_SMOKE_PASS: snapshot, mass, collider, ecology isolation, lifecycle, 4 drops")
	quit(0)


func _measure_drop(jar: JarView, denomination: int, height_m: float) -> void:
	var bean_id := "drop-%d" % denomination
	_check(jar.apply_inventory_snapshot({"inventory_revision_id": bean_id, "beans": [{"id": bean_id, "denomination_grams": denomination}]}), "drop snapshot")
	var body: RigidBody3D = jar.get_node("Bean_" + bean_id)
	body.contact_monitor = true
	body.max_contacts_reported = 8
	body.freeze = true
	await physics_frame
	var radius := 0.10 * pow(float(denomination), 1.0 / 3.0)
	var body_bottom_offset := radius * 0.82
	body.position = Vector3(0.0, body_bottom_offset + height_m * 10.0, 0.0)
	body.linear_velocity = Vector3.ZERO
	body.angular_velocity = Vector3.ZERO
	body.sleeping = false
	body.freeze = false
	var contact_frame := -1
	for frame in 30:
		await physics_frame
		if not body.get_colliding_bodies().is_empty():
			contact_frame = frame + 1
			break
	_check(contact_frame > 0, "first floor contact")
	var elapsed := float(contact_frame) * TICK
	var expected := sqrt(2.0 * height_m / JarView.GRAVITY_M_S2)
	print("DROP: %dg from %.2fm first contact %.3fs, theory %.3fs" % [denomination, height_m, elapsed, expected])
	_check(absf(elapsed - expected) <= expected * 0.20 + TICK, "normal-time fall")
	await physics_frame


func _count_collision_objects(node: Node) -> int:
	var count := 1 if node is CollisionObject3D else 0
	for child in node.get_children():
		count += _count_collision_objects(child)
	return count


func _check(condition: bool, description: String) -> void:
	if condition:
		return
	push_error("JAR_SMOKE_FAIL: " + description)
	quit(1)
