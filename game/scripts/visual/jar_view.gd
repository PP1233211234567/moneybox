class_name JarView
extends Node3D

const Ecology = preload("res://scripts/ecology/ecology_service.gd")

## Reusable presentation scene. All lengths below are real metres multiplied by WORLD_SCALE.
## Financial grams and bean identities arrive only through apply_inventory_snapshot().
const WORLD_SCALE := 10.0
const GRAVITY_M_S2 := 9.81
const INNER_HEIGHT_M := 0.24
const INNER_RADIUS_M := 0.086
const WALL_THICKNESS_M := 0.007
const COLLISION_WALL_THICKNESS_M := 0.022
const BASE_BEAN_RADIUS_M := 0.010
const MAX_ANIMATED_ADDITIONS := 20

const INNER_HEIGHT := INNER_HEIGHT_M * WORLD_SCALE
const INNER_RADIUS := INNER_RADIUS_M * WORLD_SCALE
const WALL_THICKNESS := WALL_THICKNESS_M * WORLD_SCALE
const COLLISION_WALL_THICKNESS := COLLISION_WALL_THICKNESS_M * WORLD_SCALE
const BASE_BEAN_RADIUS := BASE_BEAN_RADIUS_M * WORLD_SCALE

var _beans: Dictionary = {}
var _bean_meshes: Dictionary = {}
var _bean_shapes: Dictionary = {}
var _gold_material: StandardMaterial3D
var _using_imported_assets := false
var _imported_ecology: Node3D
var _skin_id := "basic"
var _inventory_revision_id := ""
var _has_snapshot := false
var _demo_active := false
var _active := true
var _motion_override := false
var _override_gravity := Vector3(0.0, -GRAVITY_M_S2, 0.0)
var _override_linear_acceleration := Vector3.ZERO
var _gravity_field := Vector3(0.0, -GRAVITY_M_S2 * WORLD_SCALE, 0.0)
var _ecology: Node3D
var _ecology_content: Node3D
var _fish: Node3D
var _shrimp: Node3D
var _plants: Array[Node3D] = []
var _ecology_time := 0.0
var _ecology_state: Dictionary = {}
var _personal_ecology_mode := false
var _organism_nodes: Dictionary = {}
var _plant_nodes: Dictionary = {}
var _fish_prototype: Node3D
var _shrimp_prototype: Node3D
var _plant_prototypes: Array[Node3D] = []


func _ready() -> void:
	_build_materials()
	_build_dry_jar()
	_build_ecology()
	_apply_imported_asset()
	set_skin(_skin_id)


## Snapshot contract: {"inventory_revision_id": String, "skin_id": String,
## "beans": [{"id": String, "denomination_grams": 1 or 10}, ...]}.
## The method is idempotent. The first snapshot lays out existing beans without replaying drops.
func apply_inventory_snapshot(snapshot: Dictionary) -> bool:
	var raw_beans: Variant = snapshot.get("beans", [])
	if not raw_beans is Array:
		push_error("JarView expected a beans array")
		return false
	var desired: Dictionary = {}
	for item in raw_beans:
		if not item is Dictionary:
			push_error("JarView expected bean dictionaries")
			return false
		var bean_id := str(item.get("id", ""))
		var denomination := int(item.get("denomination_grams", 0))
		if bean_id.is_empty() or desired.has(bean_id) or (denomination != 1 and denomination != 10):
			push_error("JarView received an invalid or duplicate bean")
			return false
		desired[bean_id] = denomination

	var incoming_demo := bool(snapshot.get("demo", false))
	var replacing_demo := _demo_active and not incoming_demo
	var first_layout := not _has_snapshot or replacing_demo
	var additions: Array[String] = []
	for bean_id in desired.keys():
		if replacing_demo or not _beans.has(bean_id) or int(_beans[bean_id].get_meta("denomination_grams")) != int(desired[bean_id]):
			additions.append(bean_id)
	additions.sort()
	var relayout := first_layout or additions.size() > MAX_ANIMATED_ADDITIONS
	var positions: Dictionary = _stable_layout(desired)
	if positions.size() != desired.size():
		push_error("JarView cannot fit all beans in this jar; select another jar or capacity profile")
		return false
	if replacing_demo:
		_clear_beans()
	for bean_id in _beans.keys():
		var body: RigidBody3D = _beans[bean_id]
		if not desired.has(bean_id) or int(body.get_meta("denomination_grams")) != int(desired[bean_id]):
			_beans.erase(bean_id)
			body.queue_free()
	for i in additions.size():
		var bean_id: String = additions[i]
		var denomination: int = desired[bean_id]
		var radius := _bean_radius(denomination)
		var start_position: Vector3 = positions.get(bean_id, _entry_position(i, radius))
		_beans[bean_id] = _create_bean(bean_id, denomination, start_position)
	if relayout:
		for bean_id in _beans.keys():
			var body: RigidBody3D = _beans[bean_id]
			body.position = positions.get(bean_id, body.position)
			body.linear_velocity = Vector3.ZERO
			body.angular_velocity = Vector3.ZERO
			body.sleeping = false
			body.reset_physics_interpolation()

	_inventory_revision_id = str(snapshot.get("inventory_revision_id", ""))
	_demo_active = incoming_demo
	_has_snapshot = true
	set_skin(str(snapshot.get("skin_id", _skin_id)))
	return true


## App and Wallpaper hosts consume the same committed, minimal read-only payload.
## The finance version is reduced to an opaque renderer revision key.
func apply_display_snapshot(snapshot: Dictionary) -> bool:
	if typeof(snapshot.get("schema_version")) != TYPE_INT or int(snapshot.schema_version) != 1 \
			or not ["EMPTY", "CURRENT", "PREVIOUS_COMPLETE"].has(snapshot.get("snapshot_status", "")) \
			or not ["personal", "demo"].has(snapshot.get("data_kind", "")) \
			or typeof(snapshot.get("demo_badge")) != TYPE_BOOL \
			or bool(snapshot.demo_badge) != (snapshot.data_kind == "demo") \
			or typeof(snapshot.get("mapping_revision_id")) != TYPE_STRING \
			or typeof(snapshot.get("inventory_revision")) != TYPE_STRING \
			or typeof(snapshot.get("skin_id")) != TYPE_STRING \
			or not ["basic", "ecology"].has(snapshot.skin_id) \
			or not snapshot.get("beans", null) is Array:
		push_error("JarView rejected an invalid display snapshot")
		return false
	if snapshot.snapshot_status == "EMPTY" and (not snapshot.beans.is_empty() \
			or not snapshot.mapping_revision_id.is_empty() \
			or not snapshot.inventory_revision.is_empty()):
		push_error("JarView rejected inventory data in an empty display snapshot")
		return false
	if snapshot.snapshot_status != "EMPTY" and (snapshot.mapping_revision_id.is_empty() \
			or snapshot.inventory_revision.is_empty()):
		push_error("JarView rejected an incomplete display revision")
		return false
	return apply_inventory_snapshot({
		"inventory_revision_id": "" if snapshot.snapshot_status == "EMPTY" else \
			snapshot.mapping_revision_id + ":" + snapshot.inventory_revision,
		"skin_id": snapshot.skin_id,
		"demo": snapshot.demo_badge,
		"beans": snapshot.beans
	})


func show_demo_beans(count: int = 50) -> void:
	var demo_beans: Array[Dictionary] = []
	for i in maxi(count, 0):
		demo_beans.append({"id": "demo-%03d" % i, "denomination_grams": 1})
	apply_inventory_snapshot({"inventory_revision_id": "demo", "demo": true, "beans": demo_beans})


func reset_demo_layout() -> void:
	if not _demo_active:
		return
	var desired: Dictionary = {}
	for bean_id in _beans.keys():
		desired[bean_id] = int(_beans[bean_id].get_meta("denomination_grams"))
	var positions := _stable_layout(desired)
	if positions.size() != desired.size():
		return
	for bean_id in _beans.keys():
		var body: RigidBody3D = _beans[bean_id]
		body.position = positions.get(bean_id, body.position)
		body.linear_velocity = Vector3.ZERO
		body.angular_velocity = Vector3.ZERO
		body.sleeping = false
		body.reset_physics_interpolation()


func set_skin(skin_id: String) -> void:
	_skin_id = "ecology" if skin_id == "ecology" else "basic"
	if _ecology != null:
		_ecology.visible = _skin_id == "ecology"
	if _imported_ecology != null:
		_imported_ecology.visible = _skin_id == "ecology"
	set_process(_active and _skin_id == "ecology")


## Called by the host on WallpaperService visibility or App foreground changes.
## Freezing prevents simulation of elapsed invisible time; positions remain transient cache.
func set_active_visible(is_active: bool) -> void:
	_active = is_active
	visible = is_active
	set_physics_process(is_active)
	set_process(is_active and _skin_id == "ecology")
	for body in _beans.values():
		body.freeze = not is_active
		if is_active:
			body.sleeping = false


## Host/test override in device coordinates (X right, Y up, Z toward viewer).
func set_motion_override(gravity_m_s2: Vector3, linear_acceleration_m_s2: Vector3 = Vector3.ZERO) -> void:
	_motion_override = true
	_override_gravity = gravity_m_s2
	_override_linear_acceleration = linear_acceleration_m_s2


func clear_motion_override() -> void:
	_motion_override = false


## Ecology is a separate, validated state stream. It never reads or writes beans.
func apply_ecology_state(state: Dictionary) -> bool:
	if not Ecology.validate(state):
		push_error("JarView rejected invalid ecology state")
		return false
	if (_fish_prototype == null and not state.organisms.is_empty()) \
			or (_shrimp_prototype == null and not state.organisms.is_empty()) \
			or (_plant_prototypes.is_empty() and not state.plants.is_empty()):
		push_error("JarView ecology GLB prototypes are unavailable")
		return false
	_ecology_state = state.duplicate(true)
	_personal_ecology_mode = true
	for plant in _plants:
		plant.visible = false
	_fish.visible = false
	_shrimp.visible = false
	var active_organisms: Dictionary = {}
	for organism in state.organisms:
		var organism_id := str(organism.id)
		active_organisms[organism_id] = true
		var source: Node3D = _fish_prototype if organism.kind == "fish" else _shrimp_prototype
		if not _organism_nodes.has(organism_id):
			_organism_nodes[organism_id] = _clone_ecology_prototype(source, organism_id, false)
		_layout_organism(_organism_nodes[organism_id], organism)
	for organism_id in _organism_nodes.keys():
		if not active_organisms.has(organism_id):
			_organism_nodes[organism_id].queue_free()
			_organism_nodes.erase(organism_id)
	var active_plants: Dictionary = {}
	for plant in state.plants:
		var plant_id := str(plant.id)
		active_plants[plant_id] = true
		if not _plant_nodes.has(plant_id):
			var variant := _plant_prototypes[abs(plant_id.hash()) % _plant_prototypes.size()]
			_plant_nodes[plant_id] = _clone_ecology_prototype(variant, plant_id, true)
		_layout_plant(_plant_nodes[plant_id], plant)
	for plant_id in _plant_nodes.keys():
		if not active_plants.has(plant_id):
			_plant_nodes[plant_id].queue_free()
			_plant_nodes.erase(plant_id)
	return true


func get_ecology_metrics() -> Dictionary:
	var organism_ids: Array = _organism_nodes.keys()
	var plant_ids: Array = _plant_nodes.keys()
	organism_ids.sort()
	plant_ids.sort()
	var kinds: Array[String] = []
	var feeding := 0
	for organism in _ecology_state.get("organisms", []):
		kinds.append(str(organism.kind))
		if ["foraging", "feeding"].has(organism.behavior_state):
			feeding += 1
	var plant_positions: Dictionary = {}
	for plant_id in _plant_nodes.keys():
		plant_positions[plant_id] = _plant_nodes[plant_id].get_meta("base_position")
	return {"organism_count": _organism_nodes.size(), "plant_count": _plant_nodes.size(),
		"organism_ids": organism_ids, "plant_ids": plant_ids, "kinds": kinds,
		"feeding_count": feeding, "plant_positions": plant_positions,
		"phase": str(_ecology_state.get("scene", {}).get("day_night_phase", ""))}


func get_scene_state() -> Dictionary:
	var bean_poses: Dictionary = {}
	for bean_id in _beans.keys():
		var body: RigidBody3D = _beans[bean_id]
		bean_poses[bean_id] = {
			"position": [body.position.x, body.position.y, body.position.z],
			"rotation": [body.quaternion.x, body.quaternion.y, body.quaternion.z, body.quaternion.w]
		}
	return {"inventory_revision_id": _inventory_revision_id, "poses": bean_poses}


func restore_scene_state(state: Dictionary) -> bool:
	if str(state.get("inventory_revision_id", "")) != _inventory_revision_id:
		return false
	var poses: Variant = state.get("poses", {})
	if not poses is Dictionary:
		return false
	for bean_id in _beans.keys():
		if not poses.has(bean_id):
			continue
		var pose: Variant = poses[bean_id]
		if not pose is Dictionary:
			continue
		var p: Variant = pose.get("position", [])
		var q: Variant = pose.get("rotation", [])
		if not p is Array or not q is Array or p.size() != 3 or q.size() != 4:
			continue
		var position_value := Vector3(float(p[0]), float(p[1]), float(p[2]))
		var radius := _bean_radius(int(_beans[bean_id].get_meta("denomination_grams")))
		if position_value.y < radius or position_value.y > INNER_HEIGHT - radius:
			continue
		if Vector2(position_value.x, position_value.z).length() > INNER_RADIUS - radius:
			continue
		var body: RigidBody3D = _beans[bean_id]
		body.position = position_value
		body.quaternion = Quaternion(float(q[0]), float(q[1]), float(q[2]), float(q[3])).normalized()
		body.linear_velocity = Vector3.ZERO
		body.angular_velocity = Vector3.ZERO
		body.reset_physics_interpolation()
	return true


func get_visual_metrics() -> Dictionary:
	return {
		"bean_count": _beans.size(),
		"inner_height_m": INNER_HEIGHT_M,
		"gravity_m_s2": GRAVITY_M_S2,
		"world_scale": WORLD_SCALE,
		"visual_asset": "gold_jar.glb" if _using_imported_assets else "procedural_fallback",
		"skin_id": _skin_id,
		"inventory_revision_id": _inventory_revision_id
	}


func _physics_process(delta: float) -> void:
	var gravity := Vector3(0.0, -GRAVITY_M_S2, 0.0)
	var linear_acceleration := Vector3.ZERO
	if _motion_override:
		gravity = _override_gravity
		linear_acceleration = _override_linear_acceleration
	else:
		var sensor_gravity := Input.get_gravity()
		if sensor_gravity.length() > 1.0:
			gravity = sensor_gravity.normalized() * GRAVITY_M_S2
			linear_acceleration = Input.get_accelerometer() - sensor_gravity
			if linear_acceleration.length() > 30.0:
				linear_acceleration = linear_acceleration.normalized() * 30.0
	var target := (gravity - linear_acceleration) * WORLD_SCALE
	var smoothing := 1.0 - exp(-delta / 0.07)
	var next_field := _gravity_field.lerp(target, smoothing)
	var field_change := (next_field - _gravity_field).length()
	_gravity_field = next_field
	if field_change < 0.5:
		return
	for body in _beans.values():
		body.constant_force = _gravity_field * body.mass
		if field_change > 3.0:
			body.sleeping = false


func _process(delta: float) -> void:
	_ecology_time += delta
	if _personal_ecology_mode:
		_animate_saved_ecology()
		return
	for i in _plants.size():
		_plants[i].rotation.z = 0.045 * sin(_ecology_time * 1.25 + float(i) * 1.8)
	var angle := _ecology_time * 0.65
	_fish.position = Vector3(cos(angle) * 1.12, 1.30 + 0.12 * sin(_ecology_time * 1.7), sin(angle) * 1.12)
	_fish.rotation.y = angle + PI / 2.0
	_shrimp.position = Vector3(-1.10, 0.24 + 0.025 * sin(_ecology_time * 1.8), 0.20)


func _animate_saved_ecology() -> void:
	for plant_id in _plant_nodes.keys():
		var plant: Node3D = _plant_nodes[plant_id]
		plant.rotation.z = 0.04 * sin(_ecology_time * 1.2 + float(abs(str(plant_id).hash() % 17)))
	for organism_id in _organism_nodes.keys():
		var body: Node3D = _organism_nodes[organism_id]
		var base: Vector3 = body.get_meta("base_position")
		var angle: float = body.get_meta("water_angle")
		var pace := 1.8 if body.get_meta("feeding") else 1.0
		if body.get_meta("kind") == "fish":
			var tangent := Vector3(-sin(angle), 0.0, cos(angle))
			body.position = base + tangent * (0.035 * sin(_ecology_time * pace)) \
				+ Vector3.UP * (0.018 * sin(_ecology_time * 1.7))
		else:
			body.position = base + Vector3.UP * (0.008 * sin(_ecology_time * pace))


func _build_materials() -> void:
	_gold_material = StandardMaterial3D.new()
	_gold_material.albedo_color = Color(0.90, 0.66, 0.30)
	_gold_material.metallic = 0.62
	_gold_material.roughness = 0.24
	_gold_material.specular_mode = BaseMaterial3D.SPECULAR_SCHLICK_GGX


func _build_dry_jar() -> void:
	var glass := StandardMaterial3D.new()
	glass.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	glass.albedo_color = Color(0.77, 0.89, 0.92, 0.07)
	glass.metallic = 0.08
	glass.roughness = 0.10
	glass.cull_mode = BaseMaterial3D.CULL_DISABLED
	var wall := MeshInstance3D.new()
	wall.name = "GlassWall"
	wall.mesh = _make_tube_mesh(INNER_RADIUS, INNER_RADIUS + WALL_THICKNESS, 0.0, INNER_HEIGHT)
	wall.material_override = glass
	add_child(wall)

	var trim := StandardMaterial3D.new()
	trim.albedo_color = Color(0.72, 0.78, 0.76)
	trim.metallic = 0.48
	trim.roughness = 0.27
	_add_torus("UpperRim", INNER_RADIUS + WALL_THICKNESS / 2.0, 0.025, INNER_HEIGHT, trim, self)
	_add_torus("LowerRim", INNER_RADIUS + WALL_THICKNESS / 2.0, 0.035, 0.02, trim, self)
	var cap_material := StandardMaterial3D.new()
	cap_material.albedo_color = Color(0.72, 0.61, 0.43)
	cap_material.metallic = 0.35
	cap_material.roughness = 0.34
	var lid := CylinderMesh.new()
	lid.top_radius = INNER_RADIUS + WALL_THICKNESS + 0.045
	lid.bottom_radius = lid.top_radius
	lid.height = 0.08
	_add_mesh("ClosedLid", lid, cap_material, Vector3(0.0, INNER_HEIGHT + 0.06, 0.0), self)
	var base := CylinderMesh.new()
	base.top_radius = INNER_RADIUS + WALL_THICKNESS + 0.06
	base.bottom_radius = base.top_radius
	base.height = 0.08
	_add_mesh("GlassBase", base, trim, Vector3(0.0, -0.045, 0.0), self)

	var shell := StaticBody3D.new()
	shell.name = "DryCollisionShell"
	shell.collision_layer = 1
	shell.collision_mask = 1
	add_child(shell)
	var physics_material := PhysicsMaterial.new()
	physics_material.friction = 0.4
	physics_material.bounce = 0.32
	shell.physics_material_override = physics_material
	# Keep the inner collision surface aligned with the visible glass. Thicker,
	# overlapping shapes prevent fast beans from slipping through panel seams.
	_add_cylinder_collider(shell, "Floor", INNER_RADIUS + COLLISION_WALL_THICKNESS, 0.20, -0.10)
	_add_cylinder_collider(shell, "ClosedTop", INNER_RADIUS + COLLISION_WALL_THICKNESS, 0.20, INNER_HEIGHT + 0.10)
	var segments := 16
	var centre_radius := INNER_RADIUS + COLLISION_WALL_THICKNESS / 2.0
	var panel_width := 2.0 * centre_radius * tan(PI / float(segments)) + 0.04
	for i in segments:
		var angle := TAU * float(i) / float(segments)
		var panel := CollisionShape3D.new()
		panel.name = "Wall%02d" % i
		var shape := BoxShape3D.new()
		shape.size = Vector3(panel_width, INNER_HEIGHT + 0.40, COLLISION_WALL_THICKNESS)
		panel.shape = shape
		panel.position = Vector3(cos(angle) * centre_radius, INNER_HEIGHT / 2.0, sin(angle) * centre_radius)
		panel.rotation.y = PI / 2.0 - angle
		shell.add_child(panel)


func _build_ecology() -> void:
	_ecology = Node3D.new()
	_ecology.name = "EcologyVisualOnly"
	# Ecology animation runs in _process, while bean physics uses interpolation.
	_ecology.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	add_child(_ecology)
	_ecology_content = Node3D.new()
	_ecology_content.name = "SavedEcologyVisuals"
	_ecology.add_child(_ecology_content)
	var outer_glass := StandardMaterial3D.new()
	outer_glass.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	outer_glass.albedo_color = Color(0.56, 0.82, 0.85, 0.09)
	outer_glass.roughness = 0.13
	outer_glass.cull_mode = BaseMaterial3D.CULL_DISABLED
	_add_mesh("OuterGlass", _make_tube_mesh(1.21, 1.27, -0.01, 2.43), outer_glass, Vector3.ZERO, _ecology)
	var water := StandardMaterial3D.new()
	water.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	water.albedo_color = Color(0.32, 0.74, 0.82, 0.045)
	water.cull_mode = BaseMaterial3D.CULL_DISABLED
	_add_mesh("WaterLayer", _make_tube_mesh(0.98, 1.20, 0.05, 2.28), water, Vector3.ZERO, _ecology)
	var seaweed := StandardMaterial3D.new()
	seaweed.albedo_color = Color(0.25, 0.58, 0.43)
	seaweed.roughness = 0.8
	for i in 3:
		var plant := Node3D.new()
		plant.name = "Seaweed%d" % i
		plant.position = Vector3(-1.11 if i != 1 else 1.11, 0.02, -0.03 + float(i) * 0.11)
		_ecology.add_child(plant)
		_plants.append(plant)
		for branch in 3:
			var stem := CylinderMesh.new()
			stem.top_radius = 0.014
			stem.bottom_radius = 0.025
			stem.height = 0.48 + 0.12 * float(branch)
			var stem_node := _add_mesh("Stem%d" % branch, stem, seaweed, Vector3(0.04 * float(branch - 1), stem.height / 2.0, 0.0), plant)
			stem_node.rotation.z = float(branch - 1) * 0.22
	var fish_material := StandardMaterial3D.new()
	fish_material.albedo_color = Color(0.48, 0.69, 0.65)
	fish_material.metallic = 0.15
	fish_material.roughness = 0.5
	_fish = Node3D.new()
	_fish.name = "SmallFishVisualOnly"
	_ecology.add_child(_fish)
	var fish_body := SphereMesh.new()
	fish_body.radius = 0.08
	fish_body.height = 0.16
	var fish_body_node := _add_mesh("Body", fish_body, fish_material, Vector3.ZERO, _fish)
	fish_body_node.scale = Vector3(1.6, 0.8, 0.7)
	var tail := SphereMesh.new()
	tail.radius = 0.06
	tail.height = 0.12
	var tail_node := _add_mesh("Tail", tail, fish_material, Vector3(-0.16, 0.0, 0.0), _fish)
	tail_node.scale = Vector3(0.45, 1.1, 0.35)
	var eye_material := StandardMaterial3D.new()
	eye_material.albedo_color = Color(0.11, 0.16, 0.16)
	var eye := SphereMesh.new()
	eye.radius = 0.012
	eye.height = 0.024
	_add_mesh("Eye", eye, eye_material, Vector3(0.055, 0.02, 0.055), _fish)
	var shrimp_material := StandardMaterial3D.new()
	shrimp_material.albedo_color = Color(0.88, 0.48, 0.38)
	shrimp_material.roughness = 0.55
	_shrimp = Node3D.new()
	_shrimp.name = "ShrimpVisualOnly"
	_ecology.add_child(_shrimp)
	for i in 4:
		var segment := SphereMesh.new()
		segment.radius = 0.035 - float(i) * 0.004
		segment.height = segment.radius * 2.0
		_add_mesh("Segment%d" % i, segment, shrimp_material, Vector3(float(i) * 0.045, 0.02 * sin(float(i) * 0.9), 0.0), _shrimp)
	# The ecology branch contains no CollisionObject3D and cannot affect the dry bean world.


func _apply_imported_asset() -> void:
	var asset_scene: PackedScene = load("res://assets/3d/gold_jar.glb")
	if asset_scene == null:
		push_warning("Gold jar GLB unavailable; using procedural visual fallback")
		return
	var model := asset_scene.instantiate()
	model.name = "GoldJarModel"
	model.scale = Vector3.ONE * WORLD_SCALE
	add_child(model)
	var basic := model.find_child("BasicJar", true, false)
	var ecology := model.find_child("EcologyOuter", true, false)
	var prototypes := model.find_child("BeanPrototypes", true, false)
	var one := model.find_child("Bean_1g", true, false)
	var ten := model.find_child("Bean_10g", true, false)
	if basic == null or ecology == null or prototypes == null or not one is MeshInstance3D or not ten is MeshInstance3D:
		model.queue_free()
		push_warning("Gold jar GLB is missing required separate nodes; using procedural visual fallback")
		return
	_using_imported_assets = true
	_imported_ecology = ecology
	_imported_ecology.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	_fish_prototype = ecology.find_child("EcoFish", true, false)
	_shrimp_prototype = ecology.find_child("EcoShrimp", true, false)
	for plant_name in ["EcoSeaweedJade", "EcoSeaweedSage", "EcoSeaweedShort"]:
		var prototype := ecology.find_child(plant_name, true, false)
		if prototype is Node3D:
			_plant_prototypes.append(prototype)
	prototypes.visible = false
	_bean_meshes[1] = one.mesh
	_bean_meshes[10] = ten.mesh
	for node_name in ["GlassWall", "UpperRim", "LowerRim", "ClosedLid", "GlassBase"]:
		var generated := get_node_or_null(node_name)
		if generated != null:
			generated.visible = false
	for node_name in ["OuterGlass", "WaterLayer"]:
		var generated := _ecology.get_node_or_null(node_name)
		if generated != null:
			generated.visible = false
	# The GLB organisms are source prototypes. The procedural ecology nodes above
	# animate fish, shrimp and plants outside the dry chamber at runtime.
	for node_name in ["EcoSeaweedJade", "EcoSeaweedSage", "EcoSeaweedShort", "EcoFish", "EcoShrimp"]:
		var static_organism := ecology.find_child(node_name, true, false)
		if static_organism != null:
			static_organism.visible = false


func _clone_ecology_prototype(source: Node3D, entity_id: String, is_plant: bool) -> Node3D:
	var holder := Node3D.new()
	holder.name = "SavedPlant_" + entity_id if is_plant else "SavedOrganism_" + entity_id
	_ecology_content.add_child(holder)
	var visual: Node3D = source.duplicate()
	visual.visible = true
	var bounds := _prototype_bounds(source)
	var centre := bounds.get_center()
	var anchor := Vector3(centre.x, bounds.position.y if is_plant else centre.y, centre.z)
	visual.position = -anchor
	holder.add_child(visual)
	return holder


func _prototype_bounds(source: Node3D) -> AABB:
	var accumulated := {"has_box": false, "box": AABB()}
	_accumulate_prototype_bounds(source, Transform3D.IDENTITY, accumulated)
	return accumulated.box


func _accumulate_prototype_bounds(node: Node3D, parent_transform: Transform3D, result: Dictionary) -> void:
	var transform_here := parent_transform * node.transform
	if node is MeshInstance3D and node.mesh != null:
		var box: AABB = transform_here * node.mesh.get_aabb()
		result.box = result.box.merge(box) if result.has_box else box
		result.has_box = true
	for child in node.get_children():
		if child is Node3D:
			_accumulate_prototype_bounds(child, transform_here, result)


func _layout_organism(node: Node3D, organism: Dictionary) -> void:
	var hint: Dictionary = organism.position_hint
	var horizontal := clampf(float(hint.x_per_mille) / 1000.0, 0.0, 1.0)
	var vertical := clampf(float(hint.y_per_mille) / 1000.0, 0.0, 1.0)
	var angle := lerpf(PI - 0.28, 0.28, horizontal)
	var radius := 1.12 if organism.kind == "fish" else 1.14
	var height := 0.40 + 1.56 * vertical if organism.kind == "fish" else 0.15 + 0.42 * vertical
	var base := Vector3(cos(angle) * radius, height, sin(angle) * radius)
	var scale_factor := 1.0 if organism.growth_stage == "adult" else \
		(0.86 if organism.growth_stage == "growing" else 0.70)
	node.position = base
	node.rotation.y = angle + PI / 2.0
	node.scale = Vector3.ONE * WORLD_SCALE * scale_factor * (1.45 if organism.kind == "fish" else 1.7)
	node.set_meta("base_position", base)
	node.set_meta("water_angle", angle)
	node.set_meta("kind", organism.kind)
	node.set_meta("feeding", ["foraging", "feeding"].has(organism.behavior_state))


func _layout_plant(node: Node3D, plant: Dictionary) -> void:
	var anchor: Dictionary = plant.anchor
	var horizontal := clampf(float(anchor.x_per_mille) / 1000.0, 0.0, 1.0)
	var depth := clampf(float(anchor.depth_per_mille) / 1000.0, 0.0, 1.0)
	var angle := lerpf(PI - 0.26, 0.26, horizontal)
	var radius := 1.05 + 0.14 * depth
	var base := Vector3(cos(angle) * radius, 0.05, sin(angle) * radius)
	var scale_factor := 1.0 if plant.growth_stage == "mature" else \
		(0.77 if plant.growth_stage == "young" else 0.56)
	node.position = base
	node.rotation.y = angle
	node.scale = Vector3.ONE * WORLD_SCALE * scale_factor
	node.set_meta("base_position", base)


func _create_bean(bean_id: String, denomination: int, start_position: Vector3) -> RigidBody3D:
	var body := RigidBody3D.new()
	body.name = "Bean_" + bean_id.replace("/", "_")
	body.set_meta("bean_id", bean_id)
	body.set_meta("denomination_grams", denomination)
	body.position = start_position
	body.mass = 0.001 * float(denomination)
	body.gravity_scale = 0.0
	body.constant_force = _gravity_field * body.mass
	body.linear_damp = 0.05
	body.angular_damp = 0.08
	body.continuous_cd = true
	body.can_sleep = true
	body.collision_layer = 1
	body.collision_mask = 1
	var physics_material := PhysicsMaterial.new()
	physics_material.friction = 0.4
	physics_material.bounce = 0.32
	body.physics_material_override = physics_material
	var mesh_node := MeshInstance3D.new()
	mesh_node.name = "GoldBeanVisual"
	mesh_node.mesh = _get_bean_mesh(denomination)
	if _using_imported_assets:
		mesh_node.scale = Vector3.ONE * WORLD_SCALE
	else:
		mesh_node.material_override = _gold_material
	body.add_child(mesh_node)
	var collider := CollisionShape3D.new()
	collider.name = "ConvexBeanCollider"
	collider.shape = _get_bean_shape(denomination)
	body.add_child(collider)
	add_child(body)
	body.reset_physics_interpolation()
	body.freeze = not _active
	return body


func _clear_beans() -> void:
	for body in _beans.values():
		body.queue_free()
	_beans.clear()


func _bean_radius(denomination: int) -> float:
	return BASE_BEAN_RADIUS * pow(float(denomination), 1.0 / 3.0)


func _entry_position(index: int, radius: float) -> Vector3:
	var angle := float(index) * 2.3999632297
	var radial := minf(0.42, 0.08 * sqrt(float(index + 1)))
	return Vector3(cos(angle) * radial, INNER_HEIGHT - radius - 0.14 - 0.03 * float(index % 5), sin(angle) * radial)


func _stable_layout(desired: Dictionary) -> Dictionary:
	var ids: Array = desired.keys()
	ids.sort()
	var result: Dictionary = {}
	var placed: Array[Dictionary] = []
	for bean_id in ids:
		var radius := _bean_radius(int(desired[bean_id]))
		var found := false
		for layer in 20:
			if found:
				break
			var y := radius + 0.018 + float(layer) * 0.225
			if y + radius > INNER_HEIGHT - 0.08:
				break
			for gx in range(-3, 4):
				if found:
					break
				for gz in range(-3, 4):
					var candidate := Vector3(float(gx) * 0.225, y, float(gz) * 0.225)
					if Vector2(candidate.x, candidate.z).length() + radius > INNER_RADIUS - 0.035:
						continue
					var clear := true
					for prior in placed:
						if candidate.distance_to(prior["position"]) < radius + float(prior["radius"]) + 0.012:
							clear = false
							break
					if clear:
						result[bean_id] = candidate
						placed.append({"position": candidate, "radius": radius})
						found = true
						break
		if not found:
			# An inventory manager must move excess beans to another jar.
			# Refuse the full snapshot before touching existing bodies.
			return {}
	return result


func _get_bean_mesh(denomination: int) -> ArrayMesh:
	if _bean_meshes.has(denomination):
		return _bean_meshes[denomination]
	var radius := _bean_radius(denomination)
	var surface := SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	var latitudes := 10
	var longitudes := 16
	for latitude in latitudes:
		var phi0 := PI * float(latitude) / float(latitudes)
		var phi1 := PI * float(latitude + 1) / float(latitudes)
		for longitude in longitudes:
			var theta0 := TAU * float(longitude) / float(longitudes)
			var theta1 := TAU * float(longitude + 1) / float(longitudes)
			var a := _bean_vertex(phi0, theta0, radius)
			var b := _bean_vertex(phi0, theta1, radius)
			var c := _bean_vertex(phi1, theta0, radius)
			var d := _bean_vertex(phi1, theta1, radius)
			_add_triangle(surface, a, b, c)
			_add_triangle(surface, b, d, c)
	var mesh := surface.commit()
	_bean_meshes[denomination] = mesh
	return mesh


func _get_bean_shape(denomination: int) -> ConvexPolygonShape3D:
	if _bean_shapes.has(denomination):
		return _bean_shapes[denomination]
	# A compact convex hull retains an uneven roll while avoiding the cost and
	# initial contact overlap of the old 74-point collision mesh.
	var radius := _bean_radius(denomination) * 0.89
	var points := PackedVector3Array()
	for latitude in range(1, 4):
		for longitude in 8:
			points.append(_bean_vertex(PI * float(latitude) / 4.0, TAU * float(longitude) / 8.0, radius))
	points.append(Vector3(0.0, radius * 0.82, 0.0))
	points.append(Vector3(0.0, -radius * 0.82, 0.0))
	var shape := ConvexPolygonShape3D.new()
	shape.points = points
	_bean_shapes[denomination] = shape
	return shape


func _bean_vertex(phi: float, theta: float, radius: float) -> Vector3:
	var wobble := 1.0 + 0.07 * sin(3.0 * theta + 1.2 * phi) + 0.035 * cos(5.0 * theta - 2.0 * phi)
	return Vector3(cos(theta) * sin(phi) * 1.08, cos(phi) * 0.82, sin(theta) * sin(phi) * 0.91) * radius * wobble


func _make_tube_mesh(inner_radius: float, outer_radius: float, bottom: float, top: float) -> ArrayMesh:
	var surface := SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	for i in 48:
		var a0 := TAU * float(i) / 48.0
		var a1 := TAU * float(i + 1) / 48.0
		var radial := Vector3(cos((a0 + a1) / 2.0), 0.0, sin((a0 + a1) / 2.0))
		var outer0 := Vector3(cos(a0) * outer_radius, bottom, sin(a0) * outer_radius)
		var outer1 := Vector3(cos(a1) * outer_radius, bottom, sin(a1) * outer_radius)
		var outer2 := Vector3(cos(a1) * outer_radius, top, sin(a1) * outer_radius)
		var outer3 := Vector3(cos(a0) * outer_radius, top, sin(a0) * outer_radius)
		var inner0 := Vector3(cos(a0) * inner_radius, bottom, sin(a0) * inner_radius)
		var inner1 := Vector3(cos(a1) * inner_radius, bottom, sin(a1) * inner_radius)
		var inner2 := Vector3(cos(a1) * inner_radius, top, sin(a1) * inner_radius)
		var inner3 := Vector3(cos(a0) * inner_radius, top, sin(a0) * inner_radius)
		_add_quad(surface, outer0, outer1, outer2, outer3, radial)
		_add_quad(surface, inner1, inner0, inner3, inner2, -radial)
		_add_quad(surface, outer3, outer2, inner2, inner3, Vector3.UP)
		_add_quad(surface, inner0, inner1, outer1, outer0, Vector3.DOWN)
	return surface.commit()


func _add_triangle(surface: SurfaceTool, a: Vector3, b: Vector3, c: Vector3) -> void:
	var normal := (b - a).cross(c - a).normalized()
	for vertex in [a, b, c]:
		surface.set_normal(normal)
		surface.add_vertex(vertex)


func _add_quad(surface: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, d: Vector3, normal: Vector3) -> void:
	for vertex in [a, b, c, a, c, d]:
		surface.set_normal(normal)
		surface.add_vertex(vertex)


func _add_mesh(node_name: String, mesh: Mesh, material: Material, at: Vector3, parent: Node3D) -> MeshInstance3D:
	var instance := MeshInstance3D.new()
	instance.name = node_name
	instance.mesh = mesh
	instance.material_override = material
	instance.position = at
	parent.add_child(instance)
	return instance


func _add_torus(node_name: String, major_radius: float, minor_radius: float, y: float, material: Material, parent: Node3D) -> void:
	var torus := TorusMesh.new()
	torus.inner_radius = major_radius - minor_radius
	torus.outer_radius = major_radius + minor_radius
	_add_mesh(node_name, torus, material, Vector3(0.0, y, 0.0), parent)


func _add_cylinder_collider(parent: StaticBody3D, node_name: String, radius: float, height: float, y: float) -> void:
	var collider := CollisionShape3D.new()
	collider.name = node_name
	var shape := CylinderShape3D.new()
	shape.radius = radius
	shape.height = height
	collider.shape = shape
	collider.position.y = y
	parent.add_child(collider)
