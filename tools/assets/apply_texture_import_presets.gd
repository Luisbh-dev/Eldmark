extends SceneTree
## Fija los ajustes de importación de las texturas de modelos (todo lo que hay bajo
## [code]res://assets/models[/code]): VRAM comprimida (BPTC/S3TC) con mipmaps, como pide
## docs/arte.md (4.2), y compresión de mapa de normales en los [code]*_normal.png[/code].
##
## Hace falta porque la detección 3D de Godot ([code]detect_3d[/code]) solo actúa dentro del
## editor: en una importación headless las texturas de los glTF se quedarían sin comprimir y sin
## mipmaps (más VRAM, brillos y parpadeo en la piedra lejana). Con [code]detect_3d/compress_to=0[/code]
## el editor ya no las reescribe al abrirse.
## [br][br]
## Uso (con el editor cerrado; después hay que volver a importar):
## [codeblock]
## godot --headless --path . -s res://tools/assets/apply_texture_import_presets.gd
## godot --headless --path . --import
## [/codeblock]
## También lo llama tools/assets/copy_vado_gris_assets.gd al terminar. Conserva el resto del
## .import (uid, rutas), así que las referencias por uid siguen valiendo. Es idempotente.

## Carpetas que se recorren (recursivamente).
const ROOTS: PackedStringArray = ["res://assets/models"]
## Texturas con recorte por alfa (hojas, hierba, flores): con todos los mipmaps el alfa medio
## baja del umbral de recorte y el follaje lejano se deshace; se limitan los niveles para que a
## distancia siga teniendo cuerpo.
const FOLIAGE_TEXTURES: PackedStringArray = [
	"grass.png", "leaf_pine_c.png", "leaves_normal_tree_c.png", "flowers.png",
	"leaves.png", "leaves_twisted_tree_c.png",
]
## Niveles de mipmap de las texturas de follaje (1024 px -> hasta 128 px).
const FOLIAGE_MIP_LIMIT: int = 4

## Valores de [code]compress/normal_map[/code] del importador de texturas.
const NORMAL_MAP_ENABLE: int = 1
const NORMAL_MAP_DISABLE: int = 2
## [code]compress/mode[/code] = VRAM comprimida.
const COMPRESS_VRAM: int = 2


func _initialize() -> void:
	var changed: int = 0
	var total: int = 0
	for root_dir: String in ROOTS:
		for png: String in list_textures(root_dir):
			total += 1
			if apply_preset(png):
				changed += 1
				print("ajustado: %s" % png)
	print("Texturas: %d, ajustadas: %d" % [total, changed])
	quit(0)


## Ajustes de importación que debe tener la textura [param png_path].
static func preset_for(png_path: String) -> Dictionary:
	var file_name: String = png_path.get_file().to_lower()
	var params: Dictionary = {
		"compress/mode": COMPRESS_VRAM,
		"compress/high_quality": false,
		"compress/normal_map": NORMAL_MAP_DISABLE,
		"mipmaps/generate": true,
		"mipmaps/limit": -1,
		"detect_3d/compress_to": 0,
	}
	if file_name.get_basename().ends_with("_normal"):
		params["compress/normal_map"] = NORMAL_MAP_ENABLE
	if FOLIAGE_TEXTURES.has(file_name):
		params["mipmaps/limit"] = FOLIAGE_MIP_LIMIT
	return params


## Escribe (o corrige) el .import de [param png_path] con [method preset_for]. Devuelve true si
## ha cambiado algo.
static func apply_preset(png_path: String) -> bool:
	var import_path: String = png_path + ".import"
	var config := ConfigFile.new()
	if FileAccess.file_exists(import_path):
		if config.load(import_path) != OK:
			printerr("No se pudo leer %s" % import_path)
			return false
	else:
		config.set_value("remap", "importer", "texture")
		config.set_value("remap", "type", "CompressedTexture2D")
	var changed: bool = false
	var params: Dictionary = preset_for(png_path)
	for key: String in params:
		if not config.has_section_key("params", key) or config.get_value("params", key) != params[key]:
			config.set_value("params", key, params[key])
			changed = true
	if changed and config.save(import_path) != OK:
		printerr("No se pudo escribir %s" % import_path)
		return false
	return changed


## PNG bajo [param dir], recursivamente y ordenados.
static func list_textures(dir: String) -> PackedStringArray:
	var result: PackedStringArray = PackedStringArray()
	if not DirAccess.dir_exists_absolute(dir):
		return result
	for file_name: String in DirAccess.get_files_at(dir):
		if file_name.get_extension().to_lower() == "png":
			result.append(dir.path_join(file_name))
	for sub_dir: String in DirAccess.get_directories_at(dir):
		result.append_array(list_textures(dir.path_join(sub_dir)))
	result.sort()
	return result
