extends SceneTree
## Generates the realm materials of the fort keep (ART-57): one folder per realm in
## assets/models/environment/custom/fort_keep/materials/<realm>/<material>.tres, with the same
## names as the GLB materials (keep_stone, keep_trim...), so that the game replaces the
## glTF ones with these and the keep takes on each realm's palette.
##
## Stone, cloth, wood, roof and earth use assets/materials/shaders/fort_keep_surface.gdshader
## (it recolors the texture towards the color in docs/world.md, "Palette per material", and reads the model's
## vertex color: value of each ashlar block, joint occlusion, dirt and wear mask).
## The fabrics use fort_keep_cloth.gdshader (emblem atlas, faction color, capture and wind per
## instance). The textures are the project's own from tools/blender/make_fort_keep_textures.py.
##
## Usage, after generating the textures and importing the GLB:
## [codeblock]
## godot --headless --path . -s res://tools/materials/build_fort_keep_materials.gd
## [/codeblock]
## It is deterministic; to adjust a color, change the table here, not the .tres.

const SURFACE_SHADER: String = "res://assets/materials/shaders/fort_keep_surface.gdshader"
const CLOTH_SHADER: String = "res://assets/materials/shaders/fort_keep_cloth.gdshader"
const OUT_DIR: String = "res://assets/models/environment/custom/fort_keep/materials"
const OWN: String = "res://assets/models/environment/custom/fort_keep/textures/"

## Base textures: [albedo, normal or ""].
const TEXTURES: Dictionary = {
	"stone": [OWN + "keep_stone_albedo.png", OWN + "keep_stone_normal.png"],
	"trim": [OWN + "keep_trim_albedo.png", OWN + "keep_trim_normal.png"],
	"wall": [OWN + "keep_wall_albedo.png", OWN + "keep_wall_normal.png"],
	"wood": [OWN + "keep_wood_albedo.png", OWN + "keep_wood_normal.png"],
	"shingle": [OWN + "keep_shingle_albedo.png", OWN + "keep_shingle_normal.png"],
	"flat": ["", ""],
}

## Layer on upward-facing surfaces: [color, amount, threshold] (snow, moss, dust, ash).
const LAYERS: Dictionary = {
	"vardheim": [Color("#e6edf1"), 0.75, 0.55],
	"solmarch": [Color("#6b7350"), 0.22, 0.78],
	"askarra": [Color("#c9a56a"), 0.30, 0.70],
	"eldrun": [Color("#8f8a82"), 0.32, 0.60],
}

## Vertex color weathering (lower area and streaks): [color, amount]. Moss and ivy in Solmarch,
## cold lichen in Vardheim, dust in Askarra, ash in Eldrun.
const WEATHER: Dictionary = {
	"vardheim": [Color("#6f7a66"), 0.38],
	"solmarch": [Color("#667a40"), 0.78],
	"askarra": [Color("#c9a56a"), 0.60],
	"eldrun": [Color("#7d7a73"), 0.50],
}

## Emissive embers in the cracks (Eldrun only): [color, energy].
const EMBERS: Dictionary = {
	"eldrun": [Color("#ff8a2a"), 4.0],
}

## Missing pieces of roof (Eldrun ruin, docs/art.md: "missing pieces").
const ROOF_HOLES: Dictionary = {
	"eldrun": 0.27,
}

## Earth skirt: multiplier of the vertex color per realm.
const EARTH_TINT: Dictionary = {
	"vardheim": Color("#eef3f6"),
	"solmarch": Color("#ffffff"),
	"askarra": Color("#fff1da"),
	"eldrun": Color("#f6f6f2"),
}

## material -> [texture, target color, tint, extras]. Extras: detail, gain, layer (factor on
## the realm's layer), weather (factor on the weathering), metal, rough, ember (0/1), holes (0/1),
## normal (normal map strength).
const REALMS: Dictionary = {
	"vardheim": {
		"keep_stone": ["stone", Color("#737a80"), 1.0, {"detail": 0.95}],
		"keep_wall": ["wall", Color("#737a80"), 1.0, {"detail": 0.95}],
		"keep_trim": ["trim", Color("#8e959a"), 1.0, {"detail": 0.9}],
		"keep_mortar": ["flat", Color("#2b2e31"), 1.0, {"detail": 0.0, "layer": 0.0, "weather": 0.0, "rough": 1.0}],
		"keep_wood": ["wood", Color("#3a2f28"), 1.0, {"detail": 1.0, "layer": 0.85, "weather": 0.0}],
		"keep_roof": ["shingle", Color("#5e564e"), 1.0, {"detail": 1.0, "layer": 1.0, "weather": 0.0}],
		"keep_iron": ["flat", Color("#3f4448"), 1.0, {"detail": 0.0, "layer": 0.0, "weather": 0.0, "metal": 0.6, "rough": 0.5}],
		"keep_dark": ["flat", Color("#0b0c0f"), 1.0, {"detail": 0.0, "layer": 0.0, "weather": 0.0, "rough": 1.0}],
		"keep_earth": ["flat", Color("#ffffff"), 0.0, {"detail": 0.0, "layer": 0.9, "weather": 0.0, "rough": 1.0}],
	},
	"solmarch": {
		"keep_stone": ["stone", Color("#dcd3c1"), 1.0, {"detail": 0.8, "gain": 0.97}],
		"keep_wall": ["wall", Color("#dcd3c1"), 1.0, {"detail": 0.8, "gain": 0.97}],
		"keep_trim": ["trim", Color("#f1ecdf"), 1.0, {"detail": 0.7, "gain": 1.0}],
		"keep_mortar": ["flat", Color("#6a604f"), 1.0, {"detail": 0.0, "layer": 0.0, "weather": 0.0, "rough": 1.0}],
		"keep_wood": ["wood", Color("#8a6a4a"), 1.0, {"detail": 1.0, "layer": 0.3, "weather": 0.0}],
		"keep_roof": ["shingle", Color("#4a5870"), 1.0, {"detail": 1.0, "layer": 0.6, "weather": 0.0}],
		"keep_iron": ["flat", Color("#c9a227"), 1.0, {"detail": 0.0, "layer": 0.0, "weather": 0.0, "metal": 0.8, "rough": 0.35}],
		"keep_dark": ["flat", Color("#14120f"), 1.0, {"detail": 0.0, "layer": 0.0, "weather": 0.0, "rough": 1.0}],
		"keep_earth": ["flat", Color("#ffffff"), 0.0, {"detail": 0.0, "layer": 0.0, "weather": 0.0, "rough": 1.0}],
	},
	"askarra": {
		"keep_stone": ["stone", Color("#a9583b"), 1.0, {"detail": 0.85}],
		"keep_wall": ["wall", Color("#a9583b"), 1.0, {"detail": 0.85}],
		"keep_trim": ["trim", Color("#c98a5e"), 1.0, {"detail": 0.8}],
		"keep_mortar": ["flat", Color("#4a2b20"), 1.0, {"detail": 0.0, "layer": 0.0, "weather": 0.0, "rough": 1.0}],
		"keep_wood": ["wood", Color("#7a4a2e"), 1.0, {"detail": 1.0, "layer": 0.5, "weather": 0.0}],
		"keep_roof": ["shingle", Color("#b9643a"), 1.0, {"detail": 1.0, "layer": 0.6, "weather": 0.0}],
		"keep_iron": ["flat", Color("#a97b3d"), 1.0, {"detail": 0.0, "layer": 0.0, "weather": 0.0, "metal": 0.75, "rough": 0.4}],
		"keep_dark": ["flat", Color("#120d0b"), 1.0, {"detail": 0.0, "layer": 0.0, "weather": 0.0, "rough": 1.0}],
		"keep_earth": ["flat", Color("#ffffff"), 0.0, {"detail": 0.0, "layer": 0.0, "weather": 0.0, "rough": 1.0}],
	},
	"eldrun": {
		"keep_stone": ["stone", Color("#8c8d84"), 1.0, {"detail": 0.9, "ember": 1.0}],
		"keep_wall": ["wall", Color("#8c8d84"), 1.0, {"detail": 0.9, "ember": 1.0}],
		"keep_trim": ["trim", Color("#a3a39a"), 1.0, {"detail": 0.85}],
		"keep_mortar": ["flat", Color("#33332f"), 1.0, {"detail": 0.0, "layer": 0.0, "weather": 0.0, "rough": 1.0, "ember": 1.0, "ember_vertex": 1.0}],
		"keep_wood": ["wood", Color("#5e5850"), 1.0, {"detail": 1.0, "layer": 0.35, "weather": 0.0}],
		"keep_roof": ["shingle", Color("#6b665e"), 1.0, {"detail": 1.0, "layer": 0.8, "weather": 0.0, "holes": 1.0}],
		"keep_iron": ["flat", Color("#6e4a35"), 1.0, {"detail": 0.0, "layer": 0.0, "weather": 0.0, "metal": 0.5, "rough": 0.6}],
		"keep_dark": ["flat", Color("#0d0d10"), 1.0, {"detail": 0.0, "layer": 0.0, "weather": 0.0, "rough": 1.0}],
		"keep_earth": ["flat", Color("#ffffff"), 0.0, {"detail": 0.0, "layer": 0.3, "weather": 0.0, "rough": 1.0}],
	},
}

## Fabrics: material -> [atlas, cells (columns, rows), capture axis, wind amplitude].
const CLOTHS: Dictionary = {
	"keep_cloth": [OWN + "keep_pennant_atlas.png", Vector2(1.0, 4.0), Vector2(1.0, 0.0), 0.36],
	"keep_pendant": [OWN + "keep_pendant_atlas.png", Vector2(4.0, 1.0), Vector2(0.0, 1.0), 0.14],
}

var _luminance_cache: Dictionary = {}
var _failed: bool = false


func _initialize() -> void:
	var surface: Shader = load(SURFACE_SHADER) as Shader
	var cloth: Shader = load(CLOTH_SHADER) as Shader
	if surface == null or cloth == null:
		printerr("No se pudo cargar %s o %s" % [SURFACE_SHADER, CLOTH_SHADER])
		quit(1)
		return
	for realm: String in REALMS:
		var dir: String = OUT_DIR.path_join(realm)
		DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir))
		var table: Dictionary = REALMS[realm]
		for material_name: String in table:
			var material: ShaderMaterial = _build(surface, realm, material_name, table[material_name])
			_save(material, dir.path_join(material_name + ".tres"))
		for cloth_name: String in CLOTHS:
			_save(_build_cloth(cloth, CLOTHS[cloth_name]), dir.path_join(cloth_name + ".tres"))
	quit(1 if _failed else 0)


func _build(shader: Shader, realm: String, material_name: String, spec: Array) -> ShaderMaterial:
	var extras: Dictionary = spec[3]
	var material := ShaderMaterial.new()
	material.shader = shader
	var paths: Array = TEXTURES[spec[0]]
	var albedo_path: String = paths[0]
	var normal_path: String = paths[1]
	if not albedo_path.is_empty():
		material.set_shader_parameter(&"albedo_texture", load(albedo_path))
		material.set_shader_parameter(&"reference_luminance", _mean_luminance(albedo_path))
	if not normal_path.is_empty():
		material.set_shader_parameter(&"normal_texture", load(normal_path))
		material.set_shader_parameter(&"use_normal_map", true)
		material.set_shader_parameter(&"normal_strength", float(extras.get("normal", 1.0)))
	material.set_shader_parameter(&"target_color", spec[1])
	material.set_shader_parameter(&"colorize", spec[2])
	var layer: Array = LAYERS[realm]
	material.set_shader_parameter(&"layer_color", layer[0])
	material.set_shader_parameter(&"layer_amount", clampf(float(layer[1]) * float(extras.get("layer", 1.0)), 0.0, 1.0))
	material.set_shader_parameter(&"layer_threshold", layer[2])
	var weather: Array = WEATHER[realm]
	material.set_shader_parameter(&"weather_color", weather[0])
	material.set_shader_parameter(&"weather_amount", clampf(float(weather[1]) * float(extras.get("weather", 1.0)), 0.0, 1.0))
	if EMBERS.has(realm) and float(extras.get("ember", 0.0)) > 0.0:
		var ember: Array = EMBERS[realm]
		material.set_shader_parameter(&"ember_color", ember[0])
		material.set_shader_parameter(&"ember_energy", ember[1])
		material.set_shader_parameter(&"ember_from_texture", float(extras.get("ember_vertex", 0.0)) <= 0.0)
	if ROOF_HOLES.has(realm) and float(extras.get("holes", 0.0)) > 0.0:
		material.set_shader_parameter(&"hole_amount", ROOF_HOLES[realm])
	if material_name == "keep_earth":
		material.set_shader_parameter(&"tint_color", EARTH_TINT[realm])
	var mapping: Dictionary = {
		"rough": &"roughness", "metal": &"metallic", "detail": &"detail_strength", "gain": &"albedo_gain",
	}
	for key: String in mapping:
		if extras.has(key):
			material.set_shader_parameter(mapping[key], extras[key])
	return material


func _build_cloth(shader: Shader, spec: Array) -> ShaderMaterial:
	var material := ShaderMaterial.new()
	material.shader = shader
	material.set_shader_parameter(&"atlas", load(spec[0]))
	material.set_shader_parameter(&"atlas_cells", spec[1])
	material.set_shader_parameter(&"progress_axis", spec[2])
	material.set_shader_parameter(&"wind_amplitude", spec[3])
	return material


## Mean luminance of the texture (over a small version), so that "tint" keeps the
## mean brightness of the target color. Alpha does not count: in stone it is the crack mask.
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
	for y: int in 64:
		for x: int in 64:
			# Luminance in linear space, as the shader sees it (source_color).
			var linear: Color = image.get_pixel(x, y).srgb_to_linear()
			total += linear.r * 0.299 + linear.g * 0.587 + linear.b * 0.114
	var mean: float = clampf(total / 4096.0, 0.05, 1.0)
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
