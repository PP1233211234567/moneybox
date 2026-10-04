"""Render inspection samples from gold_jar.blend without changing the source.

Run after create_gold_jar.py:
    blender --background art_source/blender/gold_jar.blend --python tools/blender/render_gold_jar_preview.py
"""

from __future__ import annotations

import os

import bpy
from mathutils import Vector


ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
OUT_DIR = os.path.join(ROOT, "art_source", "blender", "previews")


def descendants(obj):
    yield obj
    for child in obj.children:
        yield from descendants(child)


def show_tree(name: str, visible: bool):
    for obj in descendants(bpy.data.objects[name]):
        obj.hide_render = not visible


def aim(obj, point):
    direction = Vector(point) - obj.location
    obj.rotation_euler = direction.to_track_quat("-Z", "Y").to_euler()


def add_area(name, location, energy, size, color):
    lamp = bpy.data.lights.new(name, "AREA")
    lamp.energy = energy
    lamp.shape = "DISK"
    lamp.size = size
    lamp.color = color
    obj = bpy.data.objects.new(name, lamp)
    bpy.context.scene.collection.objects.link(obj)
    obj.location = location
    aim(obj, (0, 0, 0.12))


def prepare_stage():
    scene = bpy.context.scene
    scene.render.engine = "CYCLES"
    scene.cycles.samples = 24
    scene.render.resolution_x = 576
    scene.render.resolution_y = 768
    scene.render.resolution_percentage = 100
    scene.render.image_settings.file_format = "PNG"
    scene.view_settings.view_transform = "AgX"
    scene.view_settings.exposure = -0.7
    scene.world.use_nodes = True
    world_bg = scene.world.node_tree.nodes.get("Background")
    world_bg.inputs["Color"].default_value = (0.65, 0.63, 0.59, 1.0)
    world_bg.inputs["Strength"].default_value = 0.55

    camera_data = bpy.data.cameras.new("PreviewCamera")
    camera = bpy.data.objects.new("PreviewCamera", camera_data)
    scene.collection.objects.link(camera)
    camera.location = (0.26, -0.50, 0.25)
    aim(camera, (0, 0, 0.125))
    camera_data.type = "ORTHO"
    camera_data.ortho_scale = 0.36
    scene.camera = camera

    floor_mat = bpy.data.materials.new("Preview floor only")
    floor_mat.diffuse_color = (0.70, 0.67, 0.62, 1.0)
    floor_mat.use_nodes = True
    floor_mat.node_tree.nodes["Principled BSDF"].inputs["Base Color"].default_value = (0.70, 0.67, 0.62, 1.0)
    bpy.ops.mesh.primitive_plane_add(size=2.0, location=(0, 0, -0.014))
    floor = bpy.context.object
    floor.name = "PreviewFloorOnly"
    floor.data.materials.append(floor_mat)
    add_area("PreviewKey", (-0.25, -0.30, 0.48), 17, 0.38, (1.0, 0.93, 0.81))
    add_area("PreviewRim", (0.25, 0.14, 0.37), 20, 0.28, (0.78, 0.88, 1.0))
    add_area("PreviewFill", (0.13, -0.37, 0.18), 5, 0.28, (1.0, 1.0, 1.0))


def preview_beans():
    source = bpy.data.objects["Bean_1g"]
    placements = []
    for layer in range(3):
        for gx in range(-4, 5):
            for gy in range(-4, 5):
                x, y = gx * 0.020, gy * 0.020
                if (x * x + y * y) ** 0.5 < 0.072:
                    placements.append((x, y, 0.011 + layer * 0.019))
    beans = []
    for i, position in enumerate(placements[:50]):
        obj = source.copy()
        obj.data = source.data
        obj.name = "PreviewBean%02d" % i
        bpy.context.scene.collection.objects.link(obj)
        obj.parent = None
        obj.location = position
        obj.hide_render = False
        obj.rotation_euler.z = (i % 7) * 0.39
        beans.append(obj)
    return beans


def render(name: str):
    path = os.path.join(OUT_DIR, name)
    bpy.context.scene.render.filepath = path
    bpy.ops.render.render(write_still=True)
    print("GOLD_JAR_PREVIEW=" + path)


def main():
    os.makedirs(OUT_DIR, exist_ok=True)
    prepare_stage()
    show_tree("BeanPrototypes", False)
    show_tree("EcologyOuter", False)
    render("gold_jar_empty.png")
    preview_beans()
    render("gold_jar_50beans.png")
    show_tree("EcologyOuter", True)
    render("gold_jar_ecology.png")


if __name__ == "__main__":
    main()
