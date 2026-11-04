extends SceneTree
## Sets the import settings of model textures (everything under
## [code]res://assets/models[/code]): VRAM compression (BPTC/S3TC) with mipmaps, as docs/art.md (4.2)
## requires, and normal-map compression on the [code]*_normal.png[/code] files.
##
## It is needed because Godot's 3D detection ([code]detect_3d[/code]) only acts inside the
## editor: in a headless import the glTF textures would be left uncompressed and without
## mipmaps (more VRAM, shimmering and flicker on distant stone). With [code]detect_3d/compress_to=0[/code]
## the editor no longer rewrites them when it opens.
## [br][br]
## Usage (with the editor closed; you then have to re-import):
## [codeblock]
## godot --headless --path . -s res://tools/assets/apply_texture_import_presets.gd
## godot --headless --path . --import
## [/codeblock]
## tools/assets/copy_vado_gris_assets.gd also calls it when it finishes. It preserves the rest of the
## .import (uid, paths), so uid references stay valid. It is idempotent.

## Folders that are traversed (recursively).
const ROOTS: PackedStringArray = ["res://assets/models"]
## Textures with alpha cutout (leaves, grass, flowers): with all the mipmaps the mean alpha
## falls below the cutout threshold and distant foliage dissolves; the levels are limited so that at
## a distance it still has body.
const FOLIAGE_TEXTURES: PackedStringArray = [
	"grass.png", "leaf_pine_c.png", "leaves_normal_tree_c.png", "flowers.png",
	"leaves.png", "leaves_twisted_tree_c.png",
]
## Mipmap levels of the foliage textures (1024 px -> down to 128 px).
const FOLIAGE_MIP_LIMIT: int = 4

## Values of [code]compress/normal_map[/code] of the texture importer.
const NORMAL_MAP_ENABLE: int = 1
const NORMAL_MAP_DISABLE: int = 2
## [code]compress/mode[/code] = VRAM compressed.
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


## Import settings that the texture [param png_path] must have.
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


## Writes (or fixes) the .import of [param png_path] with [method preset_for]. Returns true if
## anything changed.
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


## PNGs under [param dir], recursively and sorted.
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
