extends SceneTree
## Copia al repo, desde los paquetes originales de ../Eldmark-raw, solo los assets que usa la zona
## del Vado Gris, con nombres en snake_case y las texturas reescaladas.
##
## Uso (desde la raíz del proyecto, con el editor cerrado):
## [codeblock]
## godot --headless --path . -s res://tools/assets/copy_vado_gris_assets.gd [-- --raw=<carpeta>] [--only=models,terrain]
## godot --headless --path . --import
## godot --headless --path . -s res://tools/assets/extract_kit_meshes.gd
## [/codeblock]
## Por defecto la carpeta de paquetes es [code]../Eldmark-raw[/code] (junto al repo). Solo se
## copian los glTF (nunca FBX/OBJ) y las imágenes que referencian. Reglas de tamaño (ver
## docs/arte.md): texturas de modelos a 1024 px como mucho; terreno a 1024 px con la altura en
## el alfa. El script es determinista: se puede repetir y deja los mismos archivos.
## [br][br]
## Al terminar fija los .import de todas las texturas de modelos (VRAM comprimida con mipmaps,
## ver tools/assets/apply_texture_import_presets.gd) y de las del terreno, conservando su uid.
## Con [code]--only=[/code] se limita a un grupo: [code]models[/code] (glTF y sus texturas) o
## [code]terrain[/code] (texturas de Terrain3D).

const ImportPresets = preload("res://tools/assets/apply_texture_import_presets.gd")

const DEFAULT_RAW_DIR: String = "../Eldmark-raw"

const VILLAGE_DIR: String = "medieval_village_megakit/extracted/Medieval Village MegaKit[Standard]/glTF"
const NATURE_DIR: String = "stylized_nature_megakit/extracted/glTF"
const CASTLE_WALL_DIR: String = "castle_wall_kit/extracted"
const KENNEY_DIR: String = "kenney_castle_kit/extracted/Models/GLB format"
const WATERCOLOR_DIR: String = "watercolor_terrain/extracted/VoxelCoreLab_Watercolor_Terrain_Textures_1024px"

const VILLAGE_OUT: String = "res://assets/models/environment/village"
const NATURE_OUT: String = "res://assets/models/environment/nature"
const CASTLE_WALL_OUT: String = "res://assets/models/environment/castle_wall"
const KENNEY_OUT: String = "res://assets/models/blockout/kenney_castle"
const TERRAIN_OUT: String = "res://assets/textures/terrain/watercolor"

## Lado máximo de las texturas de modelos (las de los packs vienen a 2048).
const MODEL_TEXTURE_MAX: int = 1024
const TERRAIN_TEXTURE_SIZE: int = 1024
const FLAT_NORMAL_SIZE: int = 256

const VILLAGE_PIECES: PackedStringArray = [
	"Wall_UnevenBrick_Straight", "Wall_UnevenBrick_Window_Wide_Round", "Wall_UnevenBrick_Door_Round",
	"Floor_UnevenBrick", "Floor_WoodDark", "Prop_Brick1", "Prop_Brick3", "Prop_Chimney",
	"Prop_Crate", "Prop_Wagon", "Prop_WoodenFence_Single", "Roof_Tower_RoundTiles",
]
const NATURE_PIECES: PackedStringArray = [
	"Pine_1", "Pine_2", "Pine_3", "Pine_4", "Pine_5",
	"CommonTree_1", "CommonTree_2", "CommonTree_3", "CommonTree_4", "CommonTree_5",
	"DeadTree_1", "DeadTree_2", "DeadTree_3", "DeadTree_4", "DeadTree_5",
	"TwistedTree_1", "TwistedTree_2",
	"Rock_Medium_1", "Rock_Medium_2", "Rock_Medium_3",
	"Bush_Common_Flowers", "Grass_Common_Short", "Grass_Wispy_Short",
	"RockPath_Square_Wide", "RockPath_Round_Wide",
	# Sotobosque y detalle (ART-59): helecho, planta grande, hierba alta, guijarros y seta.
	"Fern_1", "Plant_1_Big", "Grass_Common_Tall", "Pebble_Round_2", "Pebble_Square_1",
	"Mushroom_Common",
]
const KENNEY_PIECES: PackedStringArray = ["flag-banner-long", "tree-log"]
## Texturas del Castle Wall Kit (su glTF no referencia imágenes): [origen, destino].
const CASTLE_WALL_TEXTURES: Array[Array] = [
	["Textures/BrickWall/Base Color_BrickWall.png", "brick_wall_albedo.png"],
	["Textures/BrickWall/NORMAL_BrickWall.png", "brick_wall_normal.png"],
	["Textures/BrickTrims/Base Color_BrickTrims.png", "brick_trims_albedo.png"],
	["Textures/BrickTrims/NORMAL_BrickTrims.png", "brick_trims_normal.png"],
	["Textures/BrickFloor/Base Color_BrickFloor.png", "brick_floor_albedo.png"],
	["Textures/WoodWall/Base Color_WoodWall.png", "wood_wall_albedo.png"],
	["Textures/WoodWall/NORMAL_WoodWall.png", "wood_wall_normal.png"],
	["Textures/DoorStickers/DoorSticker_DiffuseTransparent.png", "door_sticker_albedo.png"],
]
## Texturas del terreno: [archivo original, nombre en el repo, corrección de color]. El orden
## no importa aquí; los identificadores de Terrain3D se fijan en el generador del Vado Gris.
## Corrección: giro de tono (grados), factor de saturación y factor de valor (HSV), por píxel.
## La tierra de acuarela es un pardo rojizo muy saturado (media #4D3024) que en el juego se ve
## casi negra; se lleva hacia la "tierra quemada" de Eldrun (#5A4A3E) de la paleta de mundo.md.
const TERRAIN_TEXTURES: Array[Array] = [
	["Grass_02", "grass_02", {}], ["Grass_03", "grass_03", {}], ["Grass_04", "grass_04", {}],
	["Dirt_03", "dirt_03", {"hue": 9.0, "sat": 0.6, "val": 1.35}], ["Stone_01", "stone_01", {}],
	["Stone_03", "stone_03", {}], ["Stone_04", "stone_04", {}],
]

## Ajustes de importación de las texturas del terreno (albedo con altura en el alfa).
const TERRAIN_IMPORT_PARAMS: Dictionary = {
	"compress/mode": 2,
	"compress/high_quality": false,
	"mipmaps/generate": true,
	"detect_3d/compress_to": 0,
}
## Ajustes de la normal plana compartida (sin compresión de normales: lleva rugosidad en el alfa).
const FLAT_NORMAL_IMPORT_PARAMS: Dictionary = {
	"compress/mode": 2,
	"compress/normal_map": 2,
	"mipmaps/generate": true,
	"detect_3d/compress_to": 0,
}

var _raw_dir: String = ""
var _written: int = 0
var _bytes: int = 0
var _failed: bool = false


func _initialize() -> void:
	_raw_dir = ProjectSettings.globalize_path("res://").path_join(DEFAULT_RAW_DIR).simplify_path()
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--raw="):
			_raw_dir = arg.trim_prefix("--raw=").replace("\\", "/")
	if not DirAccess.dir_exists_absolute(_raw_dir):
		printerr("No existe la carpeta de paquetes: %s" % _raw_dir)
		quit(1)
		return
	print("Paquetes en %s" % _raw_dir)
	var groups: PackedStringArray = ["models", "terrain"]
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--only="):
			groups = arg.trim_prefix("--only=").split(",", false)

	if groups.has("models"):
		for piece: String in VILLAGE_PIECES:
			_copy_gltf(_raw_dir.path_join(VILLAGE_DIR), piece, VILLAGE_OUT)
		for piece: String in NATURE_PIECES:
			_copy_gltf(_raw_dir.path_join(NATURE_DIR), piece, NATURE_OUT)
		_copy_castle_wall()
		for piece: String in KENNEY_PIECES:
			_copy_kenney(piece)
		for png: String in ImportPresets.list_textures("res://assets/models"):
			ImportPresets.apply_preset(png)
	if groups.has("terrain"):
		_build_terrain_textures()

	print("Archivos escritos: %d (%.2f MB)" % [_written, _bytes / 1048576.0])
	quit(1 if _failed else 0)


# --- glTF con texturas sueltas (Quaternius) -------------------------------------------------

## Copia un .gltf, su .bin y sus imágenes con nombres en snake_case, reescribiendo las URI.
func _copy_gltf(src_dir: String, piece: String, out_dir: String) -> void:
	var src_path: String = src_dir.path_join(piece + ".gltf")
	var text: String = FileAccess.get_file_as_string(src_path)
	if text.is_empty():
		_fail("No se pudo leer %s" % src_path)
		return
	var json: Variant = JSON.parse_string(text)
	if typeof(json) != TYPE_DICTIONARY:
		_fail("JSON no válido en %s" % src_path)
		return
	var gltf: Dictionary = json
	_ensure_dir(out_dir)
	for buffer: Dictionary in gltf.get("buffers", []):
		var uri: String = buffer.get("uri", "")
		if uri.is_empty() or uri.begins_with("data:"):
			continue
		var new_uri: String = _snake_file(uri)
		_copy_bytes(src_dir.path_join(uri.uri_decode()), out_dir.path_join(new_uri))
		buffer["uri"] = new_uri
	for image: Dictionary in gltf.get("images", []):
		var uri: String = image.get("uri", "")
		if uri.is_empty() or uri.begins_with("data:"):
			continue
		var new_uri: String = _snake_file(uri)
		var dst: String = out_dir.path_join(new_uri)
		if not FileAccess.file_exists(dst):
			_copy_texture(src_dir.path_join(uri.uri_decode()), dst, MODEL_TEXTURE_MAX)
		image["uri"] = new_uri
	_write_text(out_dir.path_join(_snake_file(piece + ".gltf")), JSON.stringify(gltf, "  ", false))


func _copy_castle_wall() -> void:
	var src_dir: String = _raw_dir.path_join(CASTLE_WALL_DIR)
	_ensure_dir(CASTLE_WALL_OUT)
	_copy_bytes(src_dir.path_join("Godot/CastleWallsKit.gltf"),
			CASTLE_WALL_OUT.path_join("castle_walls_kit.gltf"))
	var tex_dir: String = CASTLE_WALL_OUT.path_join("textures")
	_ensure_dir(tex_dir)
	for pair: Array in CASTLE_WALL_TEXTURES:
		_copy_texture(src_dir.path_join(pair[0]), tex_dir.path_join(pair[1]), MODEL_TEXTURE_MAX)


## Los GLB de Kenney referencian "Textures/colormap.png": se copia con esa ruta relativa.
func _copy_kenney(piece: String) -> void:
	var src_dir: String = _raw_dir.path_join(KENNEY_DIR)
	_ensure_dir(KENNEY_OUT.path_join("Textures"))
	_copy_bytes(src_dir.path_join(piece + ".glb"), KENNEY_OUT.path_join(_snake_file(piece + ".glb")))
	var colormap: String = KENNEY_OUT.path_join("Textures/colormap.png")
	if not FileAccess.file_exists(colormap):
		_copy_texture(src_dir.path_join("Textures/colormap.png"), colormap, MODEL_TEXTURE_MAX)


# --- Terreno ---------------------------------------------------------------------------------

## Albedo de Terrain3D: RGB del original y altura en el alfa (luminancia estirada a 0..1), todas
## del mismo tamaño y formato (Terrain3D exige que coincidan). Más una normal plana compartida.
func _build_terrain_textures() -> void:
	_ensure_dir(TERRAIN_OUT)
	for pair: Array in TERRAIN_TEXTURES:
		var src: String = _raw_dir.path_join(WATERCOLOR_DIR).path_join(pair[0] + ".png")
		var image: Image = Image.load_from_file(src)
		if image == null or image.is_empty():
			_fail("No se pudo leer %s" % src)
			continue
		image.convert(Image.FORMAT_RGBA8)
		if image.get_width() != TERRAIN_TEXTURE_SIZE or image.get_height() != TERRAIN_TEXTURE_SIZE:
			image.resize(TERRAIN_TEXTURE_SIZE, TERRAIN_TEXTURE_SIZE, Image.INTERPOLATE_LANCZOS)
		# La altura se saca de la luminancia original, antes de la corrección de color.
		var packed: Image = _pack_luminance_as_height(image)
		_grade(packed, pair[2])
		var dst: String = TERRAIN_OUT.path_join(pair[1] + "_alb_ht.png")
		_save_png(packed, dst)
		_write_import(dst, TERRAIN_IMPORT_PARAMS)
	# Normal plana con la rugosidad en el alfa: evita que Terrain3D genere y guarde en el .tres
	# una normal de 1024 px por textura (decenas de MB de texto).
	var flat := Image.create_empty(FLAT_NORMAL_SIZE, FLAT_NORMAL_SIZE, false, Image.FORMAT_RGBA8)
	flat.fill(Color(0.5, 0.5, 1.0, 0.85))
	var flat_path: String = TERRAIN_OUT.path_join("flat_normal_rough_256.png")
	_save_png(flat, flat_path)
	_write_import(flat_path, FLAT_NORMAL_IMPORT_PARAMS)


## Corrección HSV por píxel (deja el alfa): [code]hue[/code] en grados, [code]sat[/code] y
## [code]val[/code] como factores.
static func _grade(image: Image, grade: Dictionary) -> void:
	if grade.is_empty():
		return
	var hue: float = float(grade.get("hue", 0.0)) / 360.0
	var sat: float = grade.get("sat", 1.0)
	var val: float = grade.get("val", 1.0)
	for y: int in image.get_height():
		for x: int in image.get_width():
			var c: Color = image.get_pixel(x, y)
			var graded: Color = Color.from_hsv(fposmod(c.h + hue, 1.0), clampf(c.s * sat, 0.0, 1.0),
					clampf(c.v * val, 0.0, 1.0), c.a)
			image.set_pixel(x, y, graded)


func _pack_luminance_as_height(rgb: Image) -> Image:
	var lo: float = 1.0
	var hi: float = 0.0
	for y: int in rgb.get_height():
		for x: int in rgb.get_width():
			var lum: float = rgb.get_pixel(x, y).get_luminance()
			lo = minf(lo, lum)
			hi = maxf(hi, lum)
	var span: float = maxf(hi - lo, 1e-5)
	var packed: Image = rgb.duplicate() as Image
	for y: int in packed.get_height():
		for x: int in packed.get_width():
			var c: Color = packed.get_pixel(x, y)
			c.a = (c.get_luminance() - lo) / span
			packed.set_pixel(x, y, c)
	return packed


# --- Utilidades ------------------------------------------------------------------------------

## Reescala (si pasa de [param max_size]) y guarda como PNG de 8 bits por canal. Los PNG de 16
## bits de algunos packs ocupan el doble sin ganar nada visible.
func _copy_texture(src: String, dst: String, max_size: int) -> void:
	var image: Image = Image.load_from_file(src)
	if image == null or image.is_empty():
		_fail("No se pudo leer la imagen %s" % src)
		return
	if image.is_compressed():
		image.decompress()
	var has_alpha: bool = image.detect_alpha() != Image.ALPHA_NONE
	image.convert(Image.FORMAT_RGBA8 if has_alpha else Image.FORMAT_RGB8)
	var largest: int = maxi(image.get_width(), image.get_height())
	if largest > max_size:
		var factor: float = float(max_size) / float(largest)
		image.resize(maxi(1, roundi(image.get_width() * factor)),
				maxi(1, roundi(image.get_height() * factor)), Image.INTERPOLATE_LANCZOS)
	# La compresión por bloques (BPTC/S3TC) necesita lados múltiplos de 4: las que no lo son
	# (flowers.png viene a 1008 x 981) se llevan a la potencia de dos más cercana. Las UV de los
	# glTF están normalizadas, así que el cambio de proporción no se nota.
	if image.get_width() % 4 != 0 or image.get_height() % 4 != 0:
		image.resize(mini(nearest_po2(image.get_width()), max_size),
				mini(nearest_po2(image.get_height()), max_size), Image.INTERPOLATE_LANCZOS)
	_save_png(image, dst)


func _save_png(image: Image, res_path: String) -> void:
	var error: Error = image.save_png(res_path)
	if error != OK:
		_fail("No se pudo guardar %s (%s)" % [res_path, error_string(error)])
		return
	_count(res_path)


func _copy_bytes(src: String, dst: String) -> void:
	var data: PackedByteArray = FileAccess.get_file_as_bytes(src)
	if data.is_empty():
		_fail("No se pudo leer %s" % src)
		return
	var file: FileAccess = FileAccess.open(dst, FileAccess.WRITE)
	if file == null:
		_fail("No se pudo escribir %s" % dst)
		return
	file.store_buffer(data)
	file.close()
	_count(dst)


## Escribe los [param params] en el .import de [param texture_path] conservando lo demás (uid,
## rutas): así un uid ya asignado no cambia y las referencias por uid siguen valiendo.
func _write_import(texture_path: String, params: Dictionary) -> void:
	var import_path: String = texture_path + ".import"
	var config := ConfigFile.new()
	if FileAccess.file_exists(import_path):
		config.load(import_path)
	else:
		config.set_value("remap", "importer", "texture")
		config.set_value("remap", "type", "CompressedTexture2D")
	for key: String in params:
		config.set_value("params", key, params[key])
	if config.save(import_path) != OK:
		_fail("No se pudo escribir %s" % import_path)
		return
	_count(import_path)


func _write_text(dst: String, text: String) -> void:
	var file: FileAccess = FileAccess.open(dst, FileAccess.WRITE)
	if file == null:
		_fail("No se pudo escribir %s" % dst)
		return
	file.store_string(text)
	file.close()
	_count(dst)


func _count(path: String) -> void:
	_written += 1
	var file: FileAccess = FileAccess.open(path, FileAccess.READ)
	if file != null:
		_bytes += file.get_length()


func _ensure_dir(res_dir: String) -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(res_dir))


## "T_WoodTrim_BaseColor.png" -> "t_wood_trim_base_color.png".
static func _snake_file(file_name: String) -> String:
	var decoded: String = file_name.uri_decode()
	return decoded.get_basename().to_snake_case().replace(" ", "_") + "." + decoded.get_extension().to_lower()


func _fail(message: String) -> void:
	_failed = true
	printerr(message)
