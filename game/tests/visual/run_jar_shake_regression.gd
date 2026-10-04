extends SceneTree

## Synthetic headless collision regression. Frame times include SceneTree scheduling
## and position sampling; they are not Android render FPS measurements.

const JAR_SCENE := preload("res://scenes/jar_view.tscn")
const SHAKE_FRAMES := 360
const CAPACITY_FRAMES := 90
const SAMPLE_TOLERANCE := 0.02


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var jar: JarView = JAR_SCENE.instantiate()
	root.add_child(jar)
	await process_frame
	jar.show_demo_beans(50)
	if not _check(jar.get_visual_metrics().bean_count == 50, "50 synthetic demo bodies created"):
		return
	var demo_bodies := _bodies(jar, "demo-", 50)
	if not _check(demo_bodies.size() == 50, "all demo rigid bodies found"):
		return

	var max_escape := 0.0
	var worst_body := ""
	var worst_frame := -1
	var fifty_times: Array[float] = []
	for frame in SHAKE_FRAMES:
		# 30 m/s² is the production sensor-input limit. Switch direction every
		# five ticks; 90-tick phases model upright, tilted, inverted and rotated.
		var lateral := 30.0 if frame % 10 < 5 else -30.0
		var gravity := _orientation_gravity(int(frame / 90))
		jar.set_motion_override(gravity, Vector3(lateral, 0.0, lateral * 0.65))
		var began := Time.get_ticks_usec()
		await physics_frame
		for body in demo_bodies:
			var escape := _normalized_escape(body)
			if escape > max_escape:
				max_escape = escape
				worst_body = body.name
				worst_frame = frame
		fifty_times.append(float(Time.get_ticks_usec() - began) / 1000.0)
	jar.clear_motion_override()
	print("JAR_SHAKE: 50 bodies, %d ticks, max_normalized_escape=%.4f, worst=%s@%d, headless_frame_ms_p50=%.3f, p95=%.3f" % [
		SHAKE_FRAMES, max_escape, worst_body, worst_frame, _percentile(fifty_times, 0.50), _percentile(fifty_times, 0.95)])
	# A fresh jar isolates the 300-body measurement from the preceding shake.
	jar.queue_free()
	await process_frame
	jar = JAR_SCENE.instantiate()
	root.add_child(jar)
	await process_frame
	var inventory: Array[Dictionary] = []
	for index in 300:
		inventory.append({"id": "capacity-%03d" % index, "denomination_grams": 1})
	if not _check(jar.apply_inventory_snapshot({"inventory_revision_id": "capacity-300", "skin_id": "basic", "beans": inventory}), "300 synthetic bodies fit"):
		return
	var capacity_bodies := _bodies(jar, "capacity-", 300)
	if not _check(capacity_bodies.size() == 300, "all capacity rigid bodies found"):
		return
	var three_hundred_times: Array[float] = []
	var capacity_escape := 0.0
	var capacity_worst_body := ""
	var capacity_worst_frame := -1
	var capacity_worst_position := Vector3.ZERO
	for frame in CAPACITY_FRAMES:
		var began := Time.get_ticks_usec()
		await physics_frame
		for body in capacity_bodies:
			var escape := _normalized_escape(body)
			if escape > capacity_escape:
				capacity_escape = escape
				capacity_worst_body = body.name
				capacity_worst_frame = frame
				capacity_worst_position = body.position
		three_hundred_times.append(float(Time.get_ticks_usec() - began) / 1000.0)
	print("JAR_CAPACITY: 300 bodies, %d ticks, max_normalized_escape=%.4f, worst=%s@%d position=%s, headless_frame_ms_p50=%.3f, p95=%.3f" % [
		CAPACITY_FRAMES, capacity_escape, capacity_worst_body, capacity_worst_frame, capacity_worst_position,
		_percentile(three_hundred_times, 0.50), _percentile(three_hundred_times, 0.95)])
	if not _check(max_escape <= 0.0, "50-bean shake left conservative sealed-shell bounds"):
		return
	if not _check(capacity_escape <= 0.0, "300-bean layout left conservative sealed-shell bounds"):
		return
	print("JAR_SHAKE_REGRESSION_PASS: synthetic 50-body shake and 300-body headless diagnostic")
	quit(0)


func _bodies(jar: JarView, prefix: String, count: int) -> Array[RigidBody3D]:
	var result: Array[RigidBody3D] = []
	for index in count:
		var node := jar.get_node_or_null("Bean_%s%03d" % [prefix, index])
		if node is RigidBody3D:
			result.append(node)
	return result


func _orientation_gravity(phase: int) -> Vector3:
	var g := JarView.GRAVITY_M_S2
	match phase:
		0:
			return Vector3(0.0, -g, 0.0)
		1:
			return Vector3(g * 0.7071, -g * 0.7071, 0.0)
		2:
			return Vector3(0.0, g, 0.0)
		_:
			return Vector3(-g * 0.7071, -g * 0.7071, 0.0)


func _normalized_escape(body: RigidBody3D) -> float:
	var bean_radius := JarView.BASE_BEAN_RADIUS * pow(float(body.get_meta("denomination_grams")), 1.0 / 3.0)
	var outer_radius := JarView.INNER_RADIUS + JarView.WALL_THICKNESS + bean_radius + SAMPLE_TOLERANCE
	var lower := -0.09 - bean_radius - SAMPLE_TOLERANCE
	var upper := JarView.INNER_HEIGHT + 0.09 + bean_radius + SAMPLE_TOLERANCE
	var radial := Vector2(body.position.x, body.position.z).length()
	return maxf(0.0, maxf((radial - outer_radius) / bean_radius,
		maxf((lower - body.position.y) / bean_radius, (body.position.y - upper) / bean_radius)))


func _percentile(samples: Array[float], fraction: float) -> float:
	var ordered := samples.duplicate()
	ordered.sort()
	return ordered[clampi(ceili(float(ordered.size()) * fraction) - 1, 0, ordered.size() - 1)]


func _check(condition: bool, detail: String) -> bool:
	if condition:
		return true
	printerr("JAR_SHAKE_REGRESSION_FAIL: ", detail)
	quit(1)
	return false
