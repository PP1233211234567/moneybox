"""Create a small low-poly wooden field crate and export it as GLB."""

import bpy
import os
from mathutils import Vector


ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
BLEND_PATH = os.path.join(ROOT, "art_source", "blender", "pipeline_asset.blend")
GLB_PATH = os.path.join(ROOT, "game", "assets", "3d", "pipeline_asset.glb")


def make_material(name: str, color: tuple[float, float, float, float]):
    mat = bpy.data.materials.new(name)
    mat.diffuse_color = color
    mat.use_nodes = True
    mat.node_tree.nodes["Principled BSDF"].inputs["Base Color"].default_value = color
    mat.node_tree.nodes["Principled BSDF"].inputs["Roughness"].default_value = 0.82
    return mat


def add_beam(name: str, location, scale, material, bevel=0.025):
    bpy.ops.mesh.primitive_cube_add(size=1, location=location)
    obj = bpy.context.object
    obj.name = name
    obj.dimensions = scale
    bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)
    obj.data.materials.append(material)
    if bevel:
        mod = obj.modifiers.new("Soft cut edges", "BEVEL")
        mod.width = bevel
        mod.segments = 1
        obj.modifiers.new("Weighted corner normals", "WEIGHTED_NORMAL")
    return obj


def main():
    os.makedirs(os.path.dirname(BLEND_PATH), exist_ok=True)
    os.makedirs(os.path.dirname(GLB_PATH), exist_ok=True)

    bpy.ops.object.select_all(action="SELECT")
    bpy.ops.object.delete(use_global=False)

    wood = make_material("Warm field oak", (0.38, 0.19, 0.075, 1.0))
    light_wood = make_material("Sunlit oak", (0.58, 0.34, 0.14, 1.0))
    dark_wood = make_material("Oak end grain", (0.25, 0.11, 0.045, 1.0))

    # Open-topped crate, centered on the ground plane.
    add_beam("Crate floor", (0, 0, 0.12), (1.55, 1.15, 0.18), dark_wood)
    for y in (-0.51, 0.51):
        add_beam("Long side lower rail", (0, y, 0.28), (1.55, 0.12, 0.14), wood)
        add_beam("Long side upper rail", (0, y, 0.91), (1.55, 0.12, 0.14), light_wood)
        for z in (0.47, 0.66):
            add_beam("Long side slat", (0, y, z), (1.42, 0.095, 0.12), wood)
    for x in (-0.72, 0.72):
        add_beam("End lower rail", (x, 0, 0.28), (0.12, 0.90, 0.14), wood)
        add_beam("End upper rail", (x, 0, 0.91), (0.12, 0.90, 0.14), light_wood)
        for z in (0.47, 0.66):
            add_beam("End slat", (x, 0, z), (0.095, 0.78, 0.12), wood)

    # A few faceted produce shapes make the asset read clearly as a field crate.
    produce = make_material("Leaf green", (0.19, 0.42, 0.12, 1.0))
    for loc, radius in [((-0.32, -0.12, 1.01), 0.20), ((0.12, 0.02, 1.03), 0.22), ((0.43, -0.16, 1.00), 0.17)]:
        bpy.ops.mesh.primitive_ico_sphere_add(subdivisions=1, radius=radius, location=loc)
        obj = bpy.context.object
        obj.name = "Field produce"
        obj.data.materials.append(produce)

    # Move origin to the center of the crate footprint for easy placement.
    bpy.ops.object.select_all(action="SELECT")
    bpy.context.scene.cursor.location = (0, 0, 0)
    bpy.ops.object.origin_set(type="ORIGIN_CURSOR")

    bpy.ops.wm.save_as_mainfile(filepath=BLEND_PATH)
    bpy.ops.export_scene.gltf(filepath=GLB_PATH, export_format="GLB", use_selection=False)
    print(f"PIPELINE_ASSET_BLEND={BLEND_PATH}")
    print(f"PIPELINE_ASSET_GLB={GLB_PATH}")


if __name__ == "__main__":
    main()
