extends SceneTree
## Generates the realm materials (assets/materials/realms/<realm>/*.tres) and the water one from
## a table: the same kit texture, recolored with realm_surface.gdshader toward the palette
## of docs/world.md ("Palette per material").
##
## Usage: [code]godot --headless --path . -s res://tools/materials/build_realm_materials.gd[/code]
## It is deterministic; running it again overwrites the .tres files with the values of the table. To tweak a
## color, change it here, not by hand in the .tres.

const REALM_SHADER: String = "res://assets/materials/shaders/realm_surface.gdshader"
## Variant with cull_back for closed meshes (extra "closed" in the table).
const REALM_SHADER_CLOSED: String = "res://assets/materials/shaders/realm_surface_closed.gdshader"
const WATER_SHADER: String = "res://assets/materials/shaders/water.gdshader"
const OUT_DIR: String = "res://assets/materials/realms"
const WATER_OUT: String = "res://assets/materials/water/river_eldrun.tres"
const VEGETATION_DIR: String = "res://assets/materials/vegetation"

const CW: String = "res://assets/models/environment/castle_wall/textures/"
const VIL: String = "res://assets/models/environment/village/"
const NAT: String = "res://assets/models/environment/nature/"

## Base textures: [albedo, normal or ""].
const TEXTURES: Dictionary = {
	"stone_wall": [CW + "brick_wall_albedo.png", CW + "brick_wall_normal.png"],
	"stone_trim": [CW + "brick_trims_albedo.png", CW + "brick_trims_normal.png"],
	"stone_floor": [CW + "brick_floor_albedo.png", ""],
	"planks": [CW + "wood_wall_albedo.png", CW + "wood_wall_normal.png"],
	"door": [CW + "door_sticker_albedo.png", ""],
	"wood": [VIL + "t_wood_trim_base_color.png", VIL + "t_wood_trim_normal.png"],
	"ruin_stone": [VIL + "t_uneven_brick_base_color.png", VIL + "t_uneven_brick_normal.png"],
	"plaster": [VIL + "t_plaster_base_color.png", VIL + "t_plaster_normal.png"],
	"rock_trim": [VIL + "t_rock_trim_base_color.png", VIL + "t_rock_trim_normal.png"],
	"brick": [VIL + "t_brick_base_color.png", VIL + "t_brick_normal.png"],
	"roof_tiles": [VIL + "t_round_tiles_base_color.png", VIL + "t_round_tiles_normal.png"],
	"metal": [VIL + "t_metal_ornaments_base_color.png", ""],
	"bark": [NAT + "bark_normal_tree.png", NAT + "bark_normal_tree_normal.png"],
	"cloth": ["", ""],
}

## Layers per realm: [color, amount, threshold]. Solmarch's moss, barely saturated and only on
## nearly horizontal faces: more of it gave a green tint to all the limestone.
const LAYERS: Dictionary = {
	"vardheim": [Color("#e6edf1"), 0.75, 0.55],
	"solmarch": [Color("#6b7350"), 0.28, 0.78],
	"eldrun": [Color("#8f8a82"), 0.35, 0.6],
}

## Materials: name -> [base texture, target color, colorize, extras].
## Supported extras: hue, sat, bright, contrast, rough, metal, layer (multiplies the realm's
## layer; 1 by default), triplanar (repetitions per meter), faction (0..1), scissor, uv, emission, energy,
## detail, gain (final albedo gain), closed (true: closed mesh, shader with cull_back).
## Only the materials used by the scenes are here (test_vado_gris_zone checks that none is
## left over).
const REALMS: Dictionary = {
	"eldrun": {
		"stone_trim": ["stone_trim", Color("#a3a39a"), 0.72, {"detail": 0.8}],
		"stone_floor": ["stone_floor", Color("#8f8a82"), 0.6, {}],
		"stone_bridge": ["stone_wall", Color("#949389"), 0.75, {"uv": Vector2(1.0, 1.0), "detail": 0.8}],
		"wood": ["wood", Color("#6a6258"), 0.7, {"layer": 0.4}],
		"planks": ["planks", Color("#6a5d50"), 0.72, {"layer": 0.3}],
		"palisade_log": ["bark", Color("#5f5850"), 0.8, {"layer": 0.5, "uv": Vector2(1.0, 2.0), "closed": true}],
		"ruin_stone": ["ruin_stone", Color("#8a8b80"), 0.72, {"layer": 1.2}],
		"ruin_plaster": ["plaster", Color("#8c867c"), 0.65, {}],
		"ruin_trim": ["rock_trim", Color("#8f8d85"), 0.65, {}],
		"ruin_brick": ["brick", Color("#8f8a82"), 0.65, {}],
		"metal": ["metal", Color("#6e4a35"), 0.6, {"metal": 0.5, "rough": 0.6, "layer": 0.0}],
		"banner": ["cloth", RealmCatalog.HUECOS_COLOR, 1.0, {"faction": 1.0, "detail": 0.35, "layer": 0.0}],
		"ember": ["cloth", Color("#3a2a20"), 1.0, {"emission": Color("#ff8a2a"), "energy": 3.0, "layer": 0.0, "closed": true}],
	},
	"vardheim": {
		"stone_wall": ["stone_wall", Color("#737a80"), 0.8, {"detail": 0.8}],
		"stone_trim": ["stone_trim", Color("#8e959a"), 0.75, {"detail": 0.8}],
		"wood": ["wood", Color("#3a2f28"), 0.85, {"layer": 0.6}],
		# Hoardings: very dark wood, but with the grain visible (the earlier tone read as black).
		"planks": ["planks", Color("#4a3c31"), 0.8, {"layer": 0.8}],
		"door": ["door", Color("#3a2f28"), 0.55, {"scissor": 0.5, "layer": 0.0}],
		"metal": ["metal", Color("#3f4448"), 0.7, {"metal": 0.6, "rough": 0.5, "layer": 0.0}],
		"hide": ["cloth", Color("#7a5a3e"), 1.0, {"detail": 0.35, "layer": 0.5, "closed": true}],
		"banner": ["cloth", RealmCatalog.VARDHEIM_COLOR, 1.0, {"faction": 1.0, "detail": 0.35, "layer": 0.0}],
	},
	"solmarch": {
		# Light limestone of the palette: soft detail and some gain so that a lit face
		# reaches the palette tone without burning out the joints.
		"stone_wall": ["stone_wall", Color("#e8d8b6"), 0.94, {"detail": 0.6, "gain": 1.2}],
		"stone_trim": ["stone_trim", Color("#d6c6a4"), 0.88, {"detail": 0.6, "gain": 1.14}],
		"roof_slate": ["roof_tiles", Color("#46566e"), 0.97, {"layer": 0.6}],
		"wood": ["wood", Color("#8a6a4a"), 0.7, {"layer": 0.3}],
		"door": ["door", Color("#8a6a4a"), 0.5, {"scissor": 0.5, "layer": 0.0}],
		"metal": ["metal", Color("#c9a227"), 0.65, {"metal": 0.8, "rough": 0.35, "layer": 0.0}],
		"cloth": ["cloth", Color("#f5f2e9"), 1.0, {"detail": 0.3, "layer": 0.0, "closed": true}],
		"banner": ["cloth", RealmCatalog.SOLMARCH_COLOR, 1.0, {"faction": 1.0, "detail": 0.35, "layer": 0.0}],
	},
}

var _luminance_cache: Dictionary = {}
var _cloth_noise: NoiseTexture2D
var _failed: bool = false


func _initialize() -> void:
	var shader: Shader = load(REALM_SHADER) as Shader
	var closed_shader: Shader = load(REALM_SHADER_CLOSED) as Shader
	if shader == null or closed_shader == null:
		_fail("No se pudo cargar %s o %s" % [REALM_SHADER, REALM_SHADER_CLOSED])
		quit(1)
		return
	_cloth_noise = _make_cloth_noise()
	for realm: String in REALMS:
		var dir: String = OUT_DIR.path_join(realm)
		DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir))
		var table: Dictionary = REALMS[realm]
		for material_name: String in table:
			var spec: Array = table[material_name]
			var extras: Dictionary = spec[3]
			var material: ShaderMaterial = _build(closed_shader if extras.get("closed", false) else shader, realm, spec)
			_save(material, dir.path_join(material_name + ".tres"))
	_build_water()
	_build_vegetation()
	quit(1 if _failed else 0)


func _build(shader: Shader, realm: String, spec: Array) -> ShaderMaterial:
	var texture_key: String = spec[0]
	var extras: Dictionary = spec[3]
	var material := ShaderMaterial.new()
	material.shader = shader
	var paths: Array = TEXTURES[texture_key]
	var albedo_path: String = paths[0]
	var normal_path: String = paths[1]
	if albedo_path.is_empty():
		material.set_shader_parameter(&"albedo_texture", _cloth_noise)
		material.set_shader_parameter(&"reference_luminance", 0.5)
		material.set_shader_parameter(&"use_triplanar", true)
		material.set_shader_parameter(&"triplanar_scale", 0.35)
	else:
		material.set_shader_parameter(&"albedo_texture", load(albedo_path))
		material.set_shader_parameter(&"reference_luminance", _mean_luminance(albedo_path))
	if not normal_path.is_empty():
		material.set_shader_parameter(&"normal_texture", load(normal_path))
		material.set_shader_parameter(&"use_normal_map", true)
	material.set_shader_parameter(&"target_color", spec[1])
	material.set_shader_parameter(&"colorize", spec[2])
	var layer: Array = LAYERS[realm]
	material.set_shader_parameter(&"layer_color", layer[0])
	material.set_shader_parameter(&"layer_amount", clampf(float(layer[1]) * float(extras.get("layer", 1.0)), 0.0, 1.0))
	material.set_shader_parameter(&"layer_threshold", layer[2])
	if extras.has("triplanar"):
		material.set_shader_parameter(&"use_triplanar", true)
		material.set_shader_parameter(&"triplanar_scale", extras["triplanar"])
	var mapping: Dictionary = {
		"hue": &"hue_shift", "sat": &"saturation", "bright": &"brightness", "contrast": &"contrast",
		"rough": &"roughness", "metal": &"metallic", "faction": &"faction_mix",
		"scissor": &"alpha_scissor", "uv": &"uv_scale", "emission": &"emission_color",
		"energy": &"emission_energy", "detail": &"detail_strength", "gain": &"albedo_gain",
	}
	for key: String in mapping:
		if extras.has(key):
			material.set_shader_parameter(mapping[key], extras[key])
	return material


func _build_water() -> void:
	var shader: Shader = load(WATER_SHADER) as Shader
	var material := ShaderMaterial.new()
	material.shader = shader
	material.set_shader_parameter(&"wave_normal_a", _make_wave_normal(11, 0.012))
	material.set_shader_parameter(&"wave_normal_b", _make_wave_normal(23, 0.02))
	var foam := NoiseTexture2D.new()
	foam.width = 256
	foam.height = 256
	foam.seamless = true
	var foam_noise := FastNoiseLite.new()
	foam_noise.seed = 5
	foam_noise.frequency = 0.03
	foam_noise.fractal_octaves = 3
	foam.noise = foam_noise
	material.set_shader_parameter(&"foam_noise", foam)
	# Gray river of Eldrun (#5F7A86), slightly lighter at the banks.
	material.set_shader_parameter(&"shallow_color", Color("#8aa39c"))
	material.set_shader_parameter(&"deep_color", Color("#3c5560"))
	material.set_shader_parameter(&"min_alpha", 0.3)
	material.set_shader_parameter(&"foam_depth", 0.45)
	material.set_shader_parameter(&"depth_fade", 1.2)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(WATER_OUT.get_base_dir()))
	_save(material, WATER_OUT)


## Materials of the Terrain3D instancer: the kit's grass recolored (Eldrun) and the road
## slabs in the gray of Eld stone.
func _build_vegetation() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(VEGETATION_DIR))
	var grass_path: String = NAT + "grass.png"
	# Dry, greenish-gray grass of the Eldrun frontier. The kit texture is a very vivid green
	# and multiplying does not desaturate it: it is colorized with realm_surface (with alpha scissor), and the
	# base color is still set by the terrain.
	var shader: Shader = load(REALM_SHADER) as Shader
	for spec: Array in [["grass_green", Color("#66704a"), 0.6], ["grass_dry", Color("#877c5e"), 0.7]]:
		var material := ShaderMaterial.new()
		material.shader = shader
		material.set_shader_parameter(&"albedo_texture", load(grass_path))
		material.set_shader_parameter(&"reference_luminance", _mean_luminance(grass_path))
		material.set_shader_parameter(&"target_color", spec[1])
		material.set_shader_parameter(&"colorize", spec[2])
		material.set_shader_parameter(&"saturation", 0.6)
		material.set_shader_parameter(&"detail_strength", 0.7)
		material.set_shader_parameter(&"alpha_scissor", 0.5)
		material.set_shader_parameter(&"roughness", 1.0)
		material.set_shader_parameter(&"specular", 0.15)
		_save(material, VEGETATION_DIR.path_join(spec[0] + ".tres"))
	# Ferns and undergrowth plants (ART-59): the kit's leaves (an atlas with very vivid greens and
	# some blue and orange leaves) taken to the grayish green of the grass.
	var leaves := ShaderMaterial.new()
	leaves.shader = shader
	leaves.set_shader_parameter(&"albedo_texture", load(NAT + "leaves.png"))
	leaves.set_shader_parameter(&"reference_luminance", _mean_luminance(NAT + "leaves.png"))
	leaves.set_shader_parameter(&"target_color", Color("#5b6844"))
	leaves.set_shader_parameter(&"colorize", 0.7)
	leaves.set_shader_parameter(&"saturation", 0.6)
	leaves.set_shader_parameter(&"detail_strength", 0.8)
	leaves.set_shader_parameter(&"alpha_scissor", 0.5)
	leaves.set_shader_parameter(&"roughness", 1.0)
	leaves.set_shader_parameter(&"specular", 0.15)
	_save(leaves, VEGETATION_DIR.path_join("leaves_green.tres"))
	var stones := StandardMaterial3D.new()
	stones.albedo_texture = load(NAT + "path_rocks_diffuse.png") as Texture2D
	stones.albedo_color = Color(0.58, 0.6, 0.56)
	stones.roughness = 0.95
	_save(stones, VEGETATION_DIR.path_join("path_stones.tres"))
	_build_bark()
	# Leaves of the twisted trees (ART-59): the pack ships them red and pink (autumn) and they clash with
	# the gray valley; they are taken to a muted olive green while keeping the texture detail.
	var twisted := ShaderMaterial.new()
	twisted.shader = shader
	var twisted_path: String = NAT + "leaves_twisted_tree_c.png"
	twisted.set_shader_parameter(&"albedo_texture", load(twisted_path))
	twisted.set_shader_parameter(&"reference_luminance", _mean_luminance(twisted_path))
	twisted.set_shader_parameter(&"target_color", Color("#5d6445"))
	twisted.set_shader_parameter(&"colorize", 0.95)
	twisted.set_shader_parameter(&"saturation", 0.7)
	twisted.set_shader_parameter(&"detail_strength", 0.8)
	twisted.set_shader_parameter(&"alpha_scissor", 0.5)
	twisted.set_shader_parameter(&"roughness", 1.0)
	twisted.set_shader_parameter(&"specular", 0.15)
	_save(twisted, VEGETATION_DIR.path_join("leaves_twisted.tres"))


## Tree bark (ART-59). The kit's is terracotta (average #8C5843): in the gray valley it
## looked salmon. It is taken to a grayish brown from the Eldrun palette while keeping the texture
## detail, with the closed-mesh variant (cull_back, half the rasterization in the shadows).
## The tree glTFs use them as an external material (tools/assets/apply_nature_materials.gd).
## Each species has its own texture: [file, target color, colorize].
func _build_bark() -> void:
	var shader: Shader = load(REALM_SHADER_CLOSED) as Shader
	for spec: Array in [
		["bark_tree", "bark_normal_tree", Color("#554a40"), 0.85],
		["bark_twisted", "bark_twisted_tree", Color("#575049"), 0.7],
		["bark_dead", "bark_dead_tree", Color("#575148"), 0.75],
	]:
		var albedo_path: String = NAT + spec[1] + ".png"
		var material := ShaderMaterial.new()
		material.shader = shader
		material.set_shader_parameter(&"albedo_texture", load(albedo_path))
		material.set_shader_parameter(&"normal_texture", load(NAT + spec[1] + "_normal.png"))
		material.set_shader_parameter(&"use_normal_map", true)
		material.set_shader_parameter(&"reference_luminance", _mean_luminance(albedo_path))
		material.set_shader_parameter(&"target_color", spec[2])
		material.set_shader_parameter(&"colorize", spec[3])
		material.set_shader_parameter(&"saturation", 0.8)
		material.set_shader_parameter(&"detail_strength", 0.9)
		material.set_shader_parameter(&"roughness", 0.95)
		material.set_shader_parameter(&"specular", 0.15)
		_save(material, VEGETATION_DIR.path_join(spec[0] + ".tres"))


func _make_wave_normal(noise_seed: int, frequency: float) -> NoiseTexture2D:
	var texture := NoiseTexture2D.new()
	texture.width = 256
	texture.height = 256
	texture.seamless = true
	texture.as_normal_map = true
	texture.bump_strength = 6.0
	var noise := FastNoiseLite.new()
	noise.seed = noise_seed
	noise.frequency = frequency
	noise.fractal_octaves = 3
	texture.noise = noise
	return texture


func _make_cloth_noise() -> NoiseTexture2D:
	var texture := NoiseTexture2D.new()
	texture.width = 128
	texture.height = 128
	texture.seamless = true
	var noise := FastNoiseLite.new()
	noise.seed = 7
	noise.frequency = 0.05
	texture.noise = noise
	var ramp := Gradient.new()
	ramp.set_color(0, Color(0.42, 0.42, 0.42))
	ramp.set_color(1, Color(0.58, 0.58, 0.58))
	texture.color_ramp = ramp
	return texture


## Average luminance of the texture (over a small version), so that "colorize" keeps the
## average brightness of the target color.
func _mean_luminance(path: String) -> float:
	if _luminance_cache.has(path):
		return _luminance_cache[path]
	var image: Image = Image.load_from_file(ProjectSettings.globalize_path(path))
	if image == null or image.is_empty():
		_fail("No se pudo leer %s" % path)
		return 0.45
	image.convert(Image.FORMAT_RGBA8)
	image.resize(64, 64, Image.INTERPOLATE_BILINEAR)
	var total: float = 0.0
	var count: int = 0
	for y: int in 64:
		for x: int in 64:
			var c: Color = image.get_pixel(x, y)
			if c.a < 0.5:
				continue
			# Luminance in linear space, as the shader sees it (source_color).
			var linear: Color = c.srgb_to_linear()
			total += linear.r * 0.299 + linear.g * 0.587 + linear.b * 0.114
			count += 1
	var mean: float = clampf(total / maxf(count, 1.0), 0.05, 1.0)
	_luminance_cache[path] = mean
	return mean


func _save(material: Material, path: String) -> void:
	var error: Error = ResourceSaver.save(material, path)
	if error != OK:
		_fail("No se pudo guardar %s (%s)" % [path, error_string(error)])
	else:
		print("material: %s" % path)


func _fail(message: String) -> void:
	_failed = true
	printerr(message)
