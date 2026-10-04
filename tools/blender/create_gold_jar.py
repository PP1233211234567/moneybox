"""Build the editable Gold Bean Jar visual asset and export its GLB.

Run with Blender 5.2.2:
    blender --background --factory-startup --python tools/blender/create_gold_jar.py

The Blender model uses metres and Z up. glTF converts it to Y up; the Godot
renderer uniformly scales it by 10 while its separate physics shell preserves
0.24 m inner height and the normal-time 9.81 m/s² acceleration.
"""

from __future__ import annotations

import math
import os

import bpy
from mathutils import Vector


ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
BLEND_PATH = os.path.join(ROOT, "art_source", "blender", "gold_jar.blend")
GLB_PATH = os.path.join(ROOT, "game", "assets", "3d", "gold_jar.glb")
SEGMENTS = 64


def material(name: str, rgba: tuple[float, float, float, float], metallic=0.0, roughness=0.35):
    mat = bpy.data.materials.new(name)
    mat.use_nodes = True
    mat.diffuse_color = rgba
    bsdf = mat.node_tree.nodes.get("Principled BSDF")
    bsdf.inputs["Base Color"].default_value = rgba
    bsdf.inputs["Metallic"].default_value = metallic
    bsdf.inputs["Roughness"].default_value = roughness
    bsdf.inputs["Alpha"].default_value = rgba[3]
    if rgba[3] < 1.0:
        # Blender 5 uses surface_render_method. glTF then emits alphaMode BLEND.
        mat.surface_render_method = "BLENDED"
        mat.use_transparency_overlap = False
        mat.use_backface_culling = True
    return mat


def parent_empty(name: str, parent=None):
    obj = bpy.data.objects.new(name, None)
    bpy.context.scene.collection.objects.link(obj)
    obj.parent = parent
    return obj


def mesh_object(name: str, vertices, faces, mat, parent):
    mesh = bpy.data.meshes.new(name + "Mesh")
    mesh.from_pydata(vertices, [], faces)
    mesh.update()
    obj = bpy.data.objects.new(name, mesh)
    bpy.context.scene.collection.objects.link(obj)
    obj.parent = parent
    obj.data.materials.append(mat)
    for polygon in mesh.polygons:
        polygon.use_smooth = True
    return obj


def tube(name: str, inner: float, outer: float, bottom: float, top: float, mat, parent, segments=SEGMENTS):
    """Closed annulus with explicit inner, outer, upper and lower surfaces."""
    vertices = []
    for radius, height in ((outer, bottom), (outer, top), (inner, bottom), (inner, top)):
        for i in range(segments):
            angle = 2 * math.pi * i / segments
            vertices.append((radius * math.cos(angle), radius * math.sin(angle), height))
    faces = []
    for i in range(segments):
        j = (i + 1) % segments
        faces.append((i, j, segments + j, segments + i))
        faces.append((2 * segments + j, 2 * segments + i, 3 * segments + i, 3 * segments + j))
        faces.append((segments + i, segments + j, 3 * segments + j, 3 * segments + i))
        faces.append((2 * segments + i, 2 * segments + j, j, i))
    return mesh_object(name, vertices, faces, mat, parent)


def cylindrical_surface(name: str, radius: float, bottom: float, top: float, mat, parent, inside=False):
    """A single side of the glass wall; the other radius is a separate mesh."""
    vertices = []
    faces = []
    for height in (bottom, top):
        for i in range(SEGMENTS):
            angle = 2 * math.pi * i / SEGMENTS
            vertices.append((radius * math.cos(angle), radius * math.sin(angle), height))
    for i in range(SEGMENTS):
        nxt = (i + 1) % SEGMENTS
        face = (i, nxt, SEGMENTS + nxt, SEGMENTS + i)
        faces.append(tuple(reversed(face)) if inside else face)
    return mesh_object(name, vertices, faces, mat, parent)


def cylinder(name: str, radius: float, depth: float, z: float, mat, parent, bevel=0.0):
    bpy.ops.mesh.primitive_cylinder_add(vertices=SEGMENTS, radius=radius, depth=depth, location=(0, 0, z))
    obj = bpy.context.object
    obj.name = name
    obj.parent = parent
    obj.data.materials.append(mat)
    if bevel:
        modifier = obj.modifiers.new("Rounded metal edge", "BEVEL")
        modifier.width = bevel
        modifier.segments = 2
        bpy.context.view_layer.objects.active = obj
        bpy.ops.object.modifier_apply(modifier=modifier.name)
    for polygon in obj.data.polygons:
        polygon.use_smooth = True
    return obj


def torus(name: str, major: float, minor: float, z: float, mat, parent):
    bpy.ops.mesh.primitive_torus_add(major_segments=SEGMENTS, minor_segments=12,
                                     location=(0, 0, z), major_radius=major, minor_radius=minor)
    obj = bpy.context.object
    obj.name = name
    obj.parent = parent
    obj.data.materials.append(mat)
    for polygon in obj.data.polygons:
        polygon.use_smooth = True
    return obj


def bean(name: str, radius: float, mat, parent, x: float):
    rings, sectors = 12, 20
    vertices = []
    faces = []
    for ring in range(rings + 1):
        phi = math.pi * ring / rings
        for sector in range(sectors):
            theta = 2 * math.pi * sector / sectors
            wobble = 1.0 + 0.07 * math.sin(3 * theta + 1.2 * phi) + 0.035 * math.cos(5 * theta - 2 * phi)
            vertices.append((
                radius * math.cos(theta) * math.sin(phi) * 1.08 * wobble,
                radius * math.sin(theta) * math.sin(phi) * 0.91 * wobble,
                radius * math.cos(phi) * 0.82 * wobble,
            ))
    for ring in range(rings):
        for sector in range(sectors):
            next_sector = (sector + 1) % sectors
            a = ring * sectors + sector
            b = ring * sectors + next_sector
            c = (ring + 1) * sectors + next_sector
            d = (ring + 1) * sectors + sector
            faces.append((a, b, c, d))
    obj = mesh_object(name, vertices, faces, mat, parent)
    obj.location = (x, 0.0, 0.045)
    obj["denomination_grams"] = 1 if name.endswith("1g") else 10
    return obj


def seaweed(name: str, x: float, y: float, height: float, width: float, mat, parent, phase: float):
    rings, sides = 10, 7
    vertices = []
    faces = []
    for ring in range(rings + 1):
        t = ring / rings
        cx = x + 0.006 * math.sin(1.8 * math.pi * t + phase) * t
        cy = y + 0.004 * math.cos(1.4 * math.pi * t + phase) * t
        radius = width * (1.0 - 0.78 * t)
        for side in range(sides):
            angle = 2 * math.pi * side / sides
            vertices.append((cx + radius * math.cos(angle), cy + radius * math.sin(angle), 0.012 + height * t))
    for ring in range(rings):
        for side in range(sides):
            nxt = (side + 1) % sides
            faces.append((ring * sides + side, ring * sides + nxt,
                          (ring + 1) * sides + nxt, (ring + 1) * sides + side))
    faces.append(tuple(reversed(tuple(range(sides)))))
    faces.append(tuple(rings * sides + side for side in range(sides)))
    return mesh_object(name, vertices, faces, mat, parent)


def ellipsoid(name: str, location, scale, mat, parent, subdivisions=2):
    bpy.ops.mesh.primitive_ico_sphere_add(subdivisions=subdivisions, radius=1.0, location=location)
    obj = bpy.context.object
    obj.name = name
    obj.parent = parent
    obj.scale = scale
    bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)
    obj.data.materials.append(mat)
    for polygon in obj.data.polygons:
        polygon.use_smooth = True
    return obj


def build():
    os.makedirs(os.path.dirname(BLEND_PATH), exist_ok=True)
    os.makedirs(os.path.dirname(GLB_PATH), exist_ok=True)
    bpy.ops.object.select_all(action="SELECT")
    bpy.ops.object.delete(use_global=False)

    glass = material("Dry glass - clear", (0.48, 0.65, 0.69, 0.10), metallic=0.0, roughness=0.22)
    inner_glass = material("Dry glass - inner wall", (0.53, 0.69, 0.72, 0.035), roughness=0.22)
    glass_base = material("Dry glass - base", (0.53, 0.69, 0.72, 0.07), roughness=0.22)
    glass_edge = material("Glass edges - soft highlight", (0.50, 0.72, 0.76, 0.28), roughness=0.24)
    lid_mat = material("Lid - satin champagne", (0.48, 0.38, 0.24, 1.0), metallic=0.42, roughness=0.42)
    base_mat = material("Base - warm metal", (0.56, 0.51, 0.42, 1.0), metallic=0.36, roughness=0.44)
    gold = material("1g bean - warm gold", (0.74, 0.44, 0.07, 1.0), metallic=0.24, roughness=0.52)
    large_gold = material("10g bean - warm gold", (0.78, 0.48, 0.08, 1.0), metallic=0.26, roughness=0.51)
    water = material("Ecology water - pale blue", (0.32, 0.64, 0.72, 0.042), roughness=0.26)
    outer_glass = material("Ecology outer glass", (0.48, 0.68, 0.73, 0.065), roughness=0.22)
    ecology_inner_glass = material("Ecology inner glass", (0.53, 0.72, 0.76, 0.03), roughness=0.22)
    plant_a = material("Seaweed - jade", (0.18, 0.48, 0.34, 1.0), roughness=0.78)
    plant_b = material("Seaweed - sage", (0.38, 0.61, 0.42, 1.0), roughness=0.78)
    fish_mat = material("Fish - muted teal", (0.37, 0.65, 0.64, 1.0), metallic=0.12, roughness=0.55)
    shrimp_mat = material("Shrimp - coral", (0.82, 0.40, 0.33, 1.0), roughness=0.52)
    eye_mat = material("Eye - charcoal", (0.08, 0.12, 0.12, 1.0), roughness=0.3)

    root = parent_empty("GoldJarVisual")
    basic = parent_empty("BasicJar", root)
    ecology = parent_empty("EcologyOuter", root)
    prototypes = parent_empty("BeanPrototypes", root)

    # Dry chamber inner diameter 0.172 m, inner height 0.240 m.
    # Wall is 0.007 m thick. Separate surfaces make wall thickness inspectable.
    cylindrical_surface("GlassOuterWall", 0.0930, 0.0, 0.240, glass, basic)
    cylindrical_surface("GlassInnerWall", 0.0860, 0.0, 0.240, inner_glass, basic, inside=True)
    tube("GlassTopLip", 0.0860, 0.0930, 0.238, 0.241, glass_edge, basic)
    cylinder("GlassBaseDisk", 0.0930, 0.008, -0.004, glass_base, basic)
    torus("UpperHighlightRim", 0.092, 0.0025, 0.239, glass_edge, basic)
    torus("LowerHighlightRim", 0.092, 0.0035, 0.007, glass_edge, basic)
    cylinder("ClosedLid", 0.101, 0.012, 0.250, lid_mat, basic, bevel=0.002)
    cylinder("LidGrip", 0.036, 0.006, 0.259, base_mat, basic, bevel=0.001)
    torus("MetalBaseRing", 0.098, 0.004, -0.003, base_mat, basic)

    # Prototypes are intentionally in a separate node. JarView hides that node
    # and instances their mesh resources only for actual inventory beans.
    bean("Bean_1g", 0.010, gold, prototypes, -0.18)
    bean("Bean_10g", 0.010 * (10.0 ** (1.0 / 3.0)), large_gold, prototypes, 0.18)

    cylindrical_surface("EcoInnerGlass", 0.100, 0.0, 0.242, ecology_inner_glass, ecology, inside=True)
    cylindrical_surface("EcoWaterShell", 0.120, 0.009, 0.226, water, ecology)
    cylindrical_surface("EcoOuterGlass", 0.127, 0.0, 0.242, outer_glass, ecology)
    torus("EcoOuterRim", 0.124, 0.003, 0.241, glass_edge, ecology)
    seaweed("EcoSeaweedJade", -0.109, 0.005, 0.084, 0.004, plant_a, ecology, 0.4)
    seaweed("EcoSeaweedSage", 0.111, -0.012, 0.104, 0.0035, plant_b, ecology, 1.4)
    seaweed("EcoSeaweedShort", -0.087, -0.067, 0.058, 0.003, plant_b, ecology, 2.6)
    fish = parent_empty("EcoFish", ecology)
    ellipsoid("EcoFishBody", (0.104, 0.028, 0.152), (0.016, 0.0065, 0.007), fish_mat, fish)
    ellipsoid("EcoFishTail", (0.085, 0.028, 0.152), (0.004, 0.010, 0.004), fish_mat, fish)
    ellipsoid("EcoFishEye", (0.113, 0.032, 0.154), (0.0015, 0.0015, 0.0015), eye_mat, fish)
    shrimp = parent_empty("EcoShrimp", ecology)
    for i in range(5):
        ellipsoid("EcoShrimpSegment%02d" % i,
                  (-0.104 + i * 0.005, -0.025, 0.026 + 0.003 * math.sin(i * 0.8)),
                  (0.0035 - i * 0.00035, 0.0028, 0.003), shrimp_mat, shrimp)

    bpy.context.scene.render.engine = "CYCLES"
    bpy.context.scene.unit_settings.system = "METRIC"
    bpy.context.scene.unit_settings.scale_length = 1.0
    bpy.ops.wm.save_as_mainfile(filepath=BLEND_PATH)
    bpy.ops.export_scene.gltf(filepath=GLB_PATH, export_format="GLB", use_selection=False,
                              export_yup=True, export_apply=False)
    print("GOLD_JAR_BLEND=" + BLEND_PATH)
    print("GOLD_JAR_GLB=" + GLB_PATH)
    print("GOLD_JAR_OBJECTS=" + ",".join(sorted(obj.name for obj in bpy.data.objects if obj.type == "MESH")))


if __name__ == "__main__":
    build()
