extends SceneTree
## Genera los materiales de reino del torreón del fuerte (ART-57): una carpeta por reino en
## assets/models/environment/custom/fort_keep/materials/<reino>/<material>.tres, con los mismos
## nombres que los materiales del GLB (keep_stone, keep_trim...), para que el juego sustituya los
## del glTF por estos y el torreón tome la paleta de cada reino con realm_surface.
##
## Es la misma receta que tools/materials/build_realm_materials.gd (textura del kit recoloreada
## con realm_surface hacia la paleta de docs/mundo.md), pero con las texturas propias del torreón
## (tools/blender/make_fort_keep_textures.py) en la piedra y la piedra labrada.
##
## Uso, después de generar las texturas y de importar el GLB:
## [codeblock]
## godot --headless --path . -s res://tools/materials/build_fort_keep_materials.gd
## [/codeblock]
## Es determinista; para ajustar un color se cambia la tabla de aquí, no el .tres.

const REALM_SHADER: String = "res://assets/materials/shaders/realm_surface.gdshader"
const OUT_DIR: String = "res://assets/models/environment/custom/fort_keep/materials"
const OWN: String = "res://assets/models/environment/custom/fort_keep/textures/"
const CW: String = "res://assets/models/environment/castle_wall/textures/"
const VIL: String = "res://assets/models/environment/village/"

## Texturas base: [albedo, normal o ""].
const TEXTURES: Dictionary = {
	"stone": [OWN + "keep_stone_albedo.jpg", OWN + "keep_stone_normal.png"],
	"trim": [OWN + "keep_trim_albedo.jpg", OWN + "keep_trim_normal.png"],
	"far": [CW + "brick_wall_albedo.png", CW + "brick_wall_normal.png"],
	"planks": [CW + "wood_wall_albedo.png", CW + "wood_wall_normal.png"],
	"roof": [VIL + "t_round_tiles_base_color.png", VIL + "t_round_tiles_normal.png"],
	"banner": [OWN + "keep_banner_albedo.png", ""],
	"flat": ["", ""],
}

## Capa extra en las caras que miran arriba: [color, cantidad, umbral] (igual que el kit).
const LAYERS: Dictionary = {
	"vardheim": [Color("#e6edf1"), 0.75, 0.55],
	"solmarch": [Color("#6b7350"), 0.28, 0.78],
	"eldrun": [Color("#8f8a82"), 0.35, 0.6],
}

## material -> [textura, color objetivo, colorear, extras]. Extras: detail, gain, layer, metal,
## rough, faction (los mismos nombres que en build_realm_materials.gd).
const REALMS: Dictionary = {
	"eldrun": {
		"keep_stone": ["stone", Color("#8c8d84"), 0.78, {"detail": 0.9}],
		"keep_mortar": ["flat", Color("#33332f"), 1.0, {"detail": 0.0, "layer": 0.0, "rough": 1.0}],
		"keep_trim": ["trim", Color("#a3a39a"), 0.72, {"detail": 0.85}],
		"keep_wood": ["planks", Color("#6a5d50"), 0.72, {"layer": 0.3}],
		"keep_iron": ["flat", Color("#2e2e32"), 1.0, {"detail": 0.0, "layer": 0.0, "metal": 0.7, "rough": 0.5}],
		"keep_dark": ["flat", Color("#0d0d10"), 1.0, {"detail": 0.0, "layer": 0.0, "rough": 1.0}],
		"keep_cloth": ["banner", Color("#bdb6a6"), 1.0, {"faction": 1.0, "detail": 0.9, "layer": 0.0}],
		"keep_roof": ["roof", Color("#7a7268"), 0.95, {"layer": 0.8}],
		"keep_stone_far": ["far", Color("#8c8d84"), 0.78, {"detail": 0.8}],
	},
	"vardheim": {
		"keep_stone": ["stone", Color("#737a80"), 0.8, {"detail": 0.9}],
		"keep_mortar": ["flat", Color("#2b2e31"), 1.0, {"detail": 0.0, "layer": 0.0, "rough": 1.0}],
		"keep_trim": ["trim", Color("#8e959a"), 0.75, {"detail": 0.85}],
		"keep_wood": ["planks", Color("#4a3c31"), 0.8, {"layer": 0.8}],
		"keep_iron": ["flat", Color("#3f4448"), 1.0, {"detail": 0.0, "layer": 0.0, "metal": 0.6, "rough": 0.5}],
		"keep_dark": ["flat", Color("#0b0c0f"), 1.0, {"detail": 0.0, "layer": 0.0, "rough": 1.0}],
		"keep_cloth": ["banner", Color("#7ec8e8"), 1.0, {"faction": 1.0, "detail": 0.9, "layer": 0.0}],
		"keep_roof": ["roof", Color("#5b5750"), 0.85, {"layer": 1.0}],
		"keep_stone_far": ["far", Color("#737a80"), 0.8, {"detail": 0.8}],
	},
	"solmarch": {
		"keep_stone": ["stone", Color("#e8d8b6"), 0.94, {"detail": 0.7, "gain": 1.2}],
		"keep_mortar": ["flat", Color("#6a604f"), 1.0, {"detail": 0.0, "layer": 0.0, "rough": 1.0}],
		"keep_trim": ["trim", Color("#d6c6a4"), 0.88, {"detail": 0.7, "gain": 1.14}],
		"keep_wood": ["planks", Color("#8a6a4a"), 0.7, {"layer": 0.3}],
		"keep_iron": ["flat", Color("#c9a227"), 1.0, {"detail": 0.0, "layer": 0.0, "metal": 0.8, "rough": 0.35}],
		"keep_dark": ["flat", Color("#14120f"), 1.0, {"detail": 0.0, "layer": 0.0, "rough": 1.0}],
		"keep_cloth": ["banner", Color("#e9c341"), 1.0, {"faction": 1.0, "detail": 0.9, "layer": 0.0}],
		"keep_roof": ["roof", Color("#46566e"), 0.97, {"layer": 0.6}],
		"keep_stone_far": ["far", Color("#e8d8b6"), 0.94, {"detail": 0.6, "gain": 1.2}],
	},
}

var _luminance_cache: Dictionary = {}
var _failed: bool = false


func _initialize() -> void:
	var shader: Shader = load(REALM_SHADER) as Shader
	if shader == null:
		printerr("No se pudo cargar %s" % REALM_SHADER)
		quit(1)
		return
	for realm: String in REALMS:
		var dir: String = OUT_DIR.path_join(realm)
		DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir))
		var table: Dictionary = REALMS[realm]
		for material_name: String in table:
			var material: ShaderMaterial = _build(shader, realm, table[material_name])
			_save(material, dir.path_join(material_name + ".tres"))
	quit(1 if _failed else 0)


func _build(shader: Shader, realm: String, spec: Array) -> ShaderMaterial:
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
	material.set_shader_parameter(&"target_color", spec[1])
	material.set_shader_parameter(&"colorize", spec[2])
	var layer: Array = LAYERS[realm]
	material.set_shader_parameter(&"layer_color", layer[0])
	material.set_shader_parameter(&"layer_amount", clampf(float(layer[1]) * float(extras.get("layer", 1.0)), 0.0, 1.0))
	material.set_shader_parameter(&"layer_threshold", layer[2])
	var mapping: Dictionary = {
		"rough": &"roughness", "metal": &"metallic", "faction": &"faction_mix",
		"detail": &"detail_strength", "gain": &"albedo_gain",
	}
	for key: String in mapping:
		if extras.has(key):
			material.set_shader_parameter(mapping[key], extras[key])
	return material


## Luminancia media de la textura (sobre una versión pequeña), para que "colorear" conserve el
## brillo medio del color objetivo.
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
			# Luminancia en espacio lineal, como la ve el shader (source_color).
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
