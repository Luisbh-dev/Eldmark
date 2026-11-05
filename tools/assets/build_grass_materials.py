"""Generates the instancer's grass materials (ART-59): assets/materials/vegetation/grass_blade_*.tres.

Each one uses grass_blade.gdshader with the base of its zone's terrain color (green for Eldrun,
dry, vivid for Solmarch, frosted for Vardheim) and its mesh's height. Usage: python tools/assets/build_grass_materials.py
"""
from pathlib import Path

OUT = Path(__file__).resolve().parents[2] / "assets" / "materials" / "vegetation"

# name: (base color, tip color, model height in m)
MATERIALS = {
    "grass_blade_green": ((0.30, 0.31, 0.20), (0.40, 0.45, 0.28), 1.3),
    "grass_blade_dry": ((0.32, 0.30, 0.2), (0.5, 0.46, 0.31), 1.3),
    "grass_blade_wispy": ((0.32, 0.30, 0.2), (0.48, 0.45, 0.31), 1.07),
    "grass_blade_lush": ((0.25, 0.32, 0.16), (0.33, 0.50, 0.21), 1.3),
    "grass_blade_frost": ((0.31, 0.34, 0.28), (0.45, 0.52, 0.43), 1.3),
    "grass_blade_tall": ((0.30, 0.31, 0.20), (0.42, 0.46, 0.29), 1.87),
}

TEMPLATE = """[gd_resource type="ShaderMaterial" format=3]

[ext_resource type="Shader" path="res://assets/materials/shaders/grass_blade.gdshader" id="1_shader"]
[ext_resource type="Texture2D" path="res://assets/models/environment/nature/grass.png" id="2_tex"]

[resource]
render_priority = 0
shader = ExtResource("1_shader")
shader_parameter/albedo_texture = ExtResource("2_tex")
shader_parameter/alpha_scissor = 0.5
shader_parameter/base_color = Color({b0}, {b1}, {b2}, 1)
shader_parameter/tip_color = Color({t0}, {t1}, {t2}, 1)
shader_parameter/reference_luminance = 0.83
shader_parameter/blade_height = {h}
shader_parameter/wind_strength = 0.12
shader_parameter/wind_speed = 1.1
shader_parameter/translucency = 0.35
"""

for name, (base, tip, height) in MATERIALS.items():
    text = TEMPLATE.format(b0=base[0], b1=base[1], b2=base[2], t0=tip[0], t1=tip[1], t2=tip[2], h=height)
    (OUT / f"{name}.tres").write_text(text, encoding="utf-8")
    print("escrito", name)
