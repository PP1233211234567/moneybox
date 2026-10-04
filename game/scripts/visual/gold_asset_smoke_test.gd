extends SceneTree

const GOLD_ASSET := preload("res://assets/3d/gold_jar.glb")


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var model := GOLD_ASSET.instantiate()
	root.add_child(model)
	var required := [
		"BasicJar", "GlassOuterWall", "GlassInnerWall", "GlassTopLip",
		"ClosedLid", "GlassBaseDisk", "BeanPrototypes", "Bean_1g", "Bean_10g",
		"EcologyOuter", "EcoInnerGlass", "EcoOuterGlass", "EcoWaterShell",
		"EcoSeaweedJade", "EcoSeaweedSage", "EcoSeaweedShort", "EcoFish", "EcoShrimp"
	]
	for name in required:
		if model.find_child(name, true, false) == null:
			push_error("GOLD_ASSET_FAIL missing node: " + name)
			quit(1)
			return
	var one: MeshInstance3D = model.find_child("Bean_1g", true, false)
	var ten: MeshInstance3D = model.find_child("Bean_10g", true, false)
	var aabb_one := one.mesh.get_aabb()
	var aabb_ten := ten.mesh.get_aabb()
	var ratio := aabb_ten.size.length() / aabb_one.size.length()
	if absf(ratio - pow(10.0, 1.0 / 3.0)) > 0.04:
		push_error("GOLD_ASSET_FAIL 10g size ratio: " + str(ratio))
		quit(1)
		return
	var outer: MeshInstance3D = model.find_child("GlassOuterWall", true, false)
	var glass_material: Material = outer.mesh.surface_get_material(0)
	if not glass_material is BaseMaterial3D or glass_material.transparency == BaseMaterial3D.TRANSPARENCY_DISABLED:
		push_error("GOLD_ASSET_FAIL glass alpha material")
		quit(1)
		return
	var basic: Node3D = model.find_child("BasicJar", true, false)
	var bound := _bounds_of(basic)
	print("GOLD_ASSET_PASS: nodes=%d, 10g scale ratio=%.4f, dry jar bounds=%s, alpha glass=%s" % [required.size(), ratio, bound, glass_material.resource_name])
	quit(0)


func _bounds_of(parent: Node3D) -> AABB:
	var combined := AABB()
	var first := true
	for child in parent.get_children():
		if child is MeshInstance3D:
			var box: AABB = child.mesh.get_aabb()
			box = child.transform * box
			if first:
				combined = box
				first = false
			else:
				combined = combined.merge(box)
	return combined
