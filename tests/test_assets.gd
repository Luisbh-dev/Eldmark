extends TestCase
## Validador de assets (ART-05, solo la parte automática; la escena de estrés es de TEC-21).
## [br][br]
## Falla si en el repositorio aparece:
## [br]- un [code].scn[/code] o un [code].res[/code] que no sea una región de Terrain3D
## ([code]scenes/world/zones/<zona>/terrain/*.res[/code]): escenas y recursos van en texto;
## [br]- una textura de más de [constant MAX_TEXTURE_SIZE] px en algún lado;
## [br]- una carpeta de [code]assets/models[/code], [code]assets/animations[/code] o
## [code]assets/textures[/code] con archivos y sin entrada en [code]assets/LICENCIAS.md[/code];
## [br]- una escena de personaje cuya cápsula de colisión no mida 1,8 m de alto.
## [br][br]
## Los addons ([code]addons/[/code]) son de terceros y no se miran. Si un asset ya existente
## incumpliera una regla, no se borra: se anota en la lista de excepciones conocidas de más
## abajo, con el motivo.

## Lado máximo (px) de una textura.
const MAX_TEXTURE_SIZE: int = 2048
## Altura (m) de la cápsula de colisión del personaje.
const CAPSULE_HEIGHT: float = 1.8
const CHARACTER_SCENE: String = "res://scenes/characters/player_character.tscn"
const LICENSES_FILE: String = "res://assets/LICENCIAS.md"
## Carpetas que se recorren para buscar [code].scn[/code] y [code].res[/code] (la raíz del
## proyecto menos estas).
const SKIPPED_DIRS: Array[String] = ["addons", "build", "exports"]
## Raíces cuyas subcarpetas llevan un pack y tienen que estar en LICENCIAS.md.
const PACK_ROOTS: Array[String] = [
	"res://assets/models", "res://assets/animations", "res://assets/textures",
]
## Carpetas donde se buscan texturas.
const TEXTURE_ROOTS: Array[String] = ["res://assets", "res://scenes"]
const TEXTURE_EXTENSIONS: Array[String] = [
	"png", "jpg", "jpeg", "webp", "tga", "bmp", "exr", "hdr",
]
## Archivos que no cuentan como contenido de un pack (los genera o acompaña a Godot).
const IGNORED_EXTENSIONS: Array[String] = ["uid", "import"]

# --- Excepciones conocidas -------------------------------------------------------------------
# Hoy ninguna: todos los assets cumplen las reglas. Si algún día entra uno que no, se anota aquí
# con una línea de motivo (ruta de res:// -> motivo) en lugar de borrarlo.

## .scn o .res permitidos aunque no sean una región de Terrain3D.
const KNOWN_BINARY_EXCEPTIONS: Dictionary = {}
## Texturas de más de MAX_TEXTURE_SIZE px permitidas.
const KNOWN_OVERSIZED_TEXTURES: Dictionary = {}
## Carpetas con archivos que no figuran en LICENCIAS.md (ruta sin res:// ni barra final).
const KNOWN_UNLISTED_FOLDERS: Dictionary = {}


# --- Binarios (.scn / .res) ------------------------------------------------------------------

func test_no_binary_scenes_or_resources_except_terrain_regions() -> void:
	var offenders: Array[String] = []
	var scanned: int = 0
	var binaries_seen: int = 0
	for path: String in _collect_files("res://", SKIPPED_DIRS):
		scanned += 1
		var extension: String = path.get_extension().to_lower()
		if extension != "scn" and extension != "res":
			continue
		binaries_seen += 1
		if is_terrain_region(path) or KNOWN_BINARY_EXCEPTIONS.has(path):
			continue
		offenders.append(path)
	# Que el recorrido ve de verdad el proyecto (y llega a las regiones de Terrain3D).
	assert_true(scanned > 100 and binaries_seen > 0,
			"se recorre el proyecto (%d archivos, %d binarios)" % [scanned, binaries_seen])
	assert_true(offenders.is_empty(),
			"Escenas y recursos van en texto (.tscn/.tres); solo se admiten los .res de las "
			+ "regiones de Terrain3D (scenes/world/zones/*/terrain/*.res). Sobran: %s" % [offenders])


func test_terrain_region_rule() -> void:
	# La regla en sí: solo scenes/world/zones/<zona>/terrain/<archivo>.res.
	assert_true(is_terrain_region("res://scenes/world/zones/vado_gris/terrain/terrain3d_00_00.res"),
			"una región del Vado Gris")
	assert_true(is_terrain_region("res://scenes/world/zones/eldrun/terrain/x.res"), "otra zona")
	assert_false(is_terrain_region("res://scenes/world/zones/vado_gris/terrain/x.scn"),
			"un .scn nunca")
	assert_false(is_terrain_region("res://scenes/world/zones/vado_gris/x.res"), "fuera de terrain/")
	assert_false(is_terrain_region("res://scenes/world/zones/vado_gris/terrain/sub/x.res"),
			"en una subcarpeta de terrain/")
	assert_false(is_terrain_region("res://assets/models/x.res"), "en assets/")
	assert_false(is_terrain_region("res://scenes/world/zones/terrain/x.res"), "sin zona")
	assert_false(is_terrain_region("res://x.res"), "en la raíz")
	# Y existen regiones de verdad, para que la prueba anterior no pase por no ver nada.
	var regions: int = 0
	for path: String in _collect_files("res://scenes/world/zones", []):
		if is_terrain_region(path):
			regions += 1
	assert_true(regions > 0, "el Vado Gris tiene regiones de Terrain3D")


# --- Texturas ---------------------------------------------------------------------------------

func test_textures_are_at_most_2048_px() -> void:
	var checked: int = 0
	var offenders: Array[String] = []
	for root: String in TEXTURE_ROOTS:
		for path: String in _collect_files(root, SKIPPED_DIRS):
			if not TEXTURE_EXTENSIONS.has(path.get_extension().to_lower()):
				continue
			if KNOWN_OVERSIZED_TEXTURES.has(path):
				continue
			var size: Vector2i = image_size(path)
			checked += 1
			if size.x < 0:
				offenders.append("%s (no se pudo leer)" % path)
			elif size.x > MAX_TEXTURE_SIZE or size.y > MAX_TEXTURE_SIZE:
				offenders.append("%s (%d x %d)" % [path, size.x, size.y])
	assert_true(checked > 0, "se han encontrado texturas que comprobar")
	assert_true(offenders.is_empty(),
			"Texturas de más de %d px (se reducen antes de entrar, ver LICENCIAS.md): %s" % [
			MAX_TEXTURE_SIZE, offenders])


func test_image_size_reader() -> void:
	# El lector tiene que ver bien los tamaños, o la prueba anterior no valdría de nada.
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://build"))
	var cases: Array[Vector2i] = [Vector2i(4, 3), Vector2i(2048, 1), Vector2i(1, 2049)]
	for size: Vector2i in cases:
		var path: String = "res://build/test_assets_%dx%d.png" % [size.x, size.y]
		var image: Image = Image.create(size.x, size.y, false, Image.FORMAT_RGBA8)
		if not assert_eq(image.save_png(path), OK, "se guarda %s" % path):
			continue
		assert_eq(image_size(path), size, "tamaño de %s" % path)
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	assert_eq(image_size("res://build/no_existe.png"), Vector2i(-1, -1), "un archivo que no existe")
	# Y con las texturas reales del repo da tamaños, no errores.
	var unreadable: Array[String] = []
	var read: int = 0
	for path: String in _collect_files("res://assets", []):
		if path.get_extension().to_lower() == "png":
			read += 1
			if image_size(path).x <= 0:
				unreadable.append(path)
	assert_true(read > 0 and unreadable.is_empty(),
			"se leen los PNG de assets/ (%d; no se leen: %s)" % [read, unreadable])


# --- Carpetas de pack y LICENCIAS.md ----------------------------------------------------------

func test_every_pack_folder_has_a_license_entry() -> void:
	var listed: Array[String] = listed_paths(FileAccess.get_file_as_string(LICENSES_FILE))
	if not assert_false(listed.is_empty(), "LICENCIAS.md lista carpetas de assets"):
		return
	var checked: int = 0
	var offenders: Array[String] = []
	for root: String in PACK_ROOTS:
		for directory: String in _collect_folders_with_files(root):
			var relative: String = directory.trim_prefix("res://")
			checked += 1
			if is_covered(relative, listed) or KNOWN_UNLISTED_FOLDERS.has(relative):
				continue
			offenders.append(relative)
	assert_true(checked > 0, "se han encontrado carpetas de pack que comprobar")
	assert_true(offenders.is_empty(),
			"Carpetas de assets sin entrada en assets/LICENCIAS.md (anota autor, versión, fecha, "
			+ "URL y licencia del pack): %s" % [offenders])


func test_license_coverage_rule() -> void:
	var text: String = "\n".join([
		"| Carpeta en el repo | `assets/animations/ual1/` (y `assets/animations/rig/mapa.tres`) |",
		"| Carpeta en el repo | `assets/models/environment/village/` (`meshes/*.tres` extraídas) |",
		"- Materiales `assets/models/characters/**/materials/*.tres` y `assets/materials/{a,b}/`.",
		"- `assets/models/environment/custom/puente.tres` (malla propia).",
		"Texto con `ruta/que/no/es/de/assets` y `docs/otra.md`.",
	])
	var listed: Array[String] = listed_paths(text)
	assert_eq(listed, [
		"assets/animations/ual1", "assets/animations/rig", "assets/models/environment/village",
		"assets/models/environment/custom",
	] as Array[String], "rutas de carpeta sacadas del texto (sin comodines ni archivos sueltos)")
	assert_true(is_covered("assets/animations/ual1", listed), "la propia carpeta")
	assert_true(is_covered("assets/models/environment/village/meshes", listed), "una subcarpeta")
	assert_true(is_covered("assets/animations/rig", listed), "la carpeta de un archivo listado")
	assert_true(is_covered("assets/models/environment/custom", listed), "idem")
	assert_false(is_covered("assets/animations/ual3", listed), "otra carpeta del mismo nivel")
	assert_false(is_covered("assets/animations/ual1x", listed), "un prefijo de texto no cuenta")
	assert_false(is_covered("assets/models/characters/base", listed),
			"los comodines no dan cobertura")
	assert_false(is_covered("assets/animations", listed), "la carpeta madre no basta")


# --- Escena de personaje ----------------------------------------------------------------------

func test_character_scene_has_a_1_8_m_capsule() -> void:
	var scene: PackedScene = load(CHARACTER_SCENE) as PackedScene
	if not assert_not_null(scene, "se carga %s" % CHARACTER_SCENE):
		return
	var character: Node = scene.instantiate()
	var collision: CollisionShape3D = character.get_node_or_null("Collision") as CollisionShape3D
	if assert_not_null(collision, "el personaje tiene un nodo Collision"):
		var capsule: CapsuleShape3D = collision.shape as CapsuleShape3D
		if assert_not_null(capsule, "y su forma es una cápsula"):
			assert_near(capsule.height, CAPSULE_HEIGHT, 1e-4, "la cápsula mide 1,8 m de alto")
			assert_true(capsule.radius > 0.0 and capsule.radius * 2.0 <= capsule.height,
					"con un radio razonable (%s)" % capsule.radius)
			# Los pies en el origen: la cápsula entera por encima del suelo del personaje.
			assert_near(collision.position.y - capsule.height * 0.5, 0.0, 1e-4,
					"el borde inferior de la cápsula está en y = 0")
	character.free()


# --- Utilidades -------------------------------------------------------------------------------

## true si [param path] es una región de Terrain3D: un [code].res[/code] directamente dentro de
## [code]scenes/world/zones/<zona>/terrain/[/code].
static func is_terrain_region(path: String) -> bool:
	if path.get_extension().to_lower() != "res":
		return false
	var parts: PackedStringArray = path.trim_prefix("res://").split("/")
	return parts.size() == 6 and parts[0] == "scenes" and parts[1] == "world" \
			and parts[2] == "zones" and parts[4] == "terrain"


## Rutas de carpeta (sin [code]res://[/code] ni barra final) que cita [param markdown] entre
## comillas de código y empiezan por [code]assets/[/code]. De un archivo se toma su carpeta; las
## rutas con comodines ([code]*[/code], [code]{[/code]) se descartan porque no dicen qué carpeta
## concreta cubren.
static func listed_paths(markdown: String) -> Array[String]:
	var result: Array[String] = []
	var regex := RegEx.new()
	regex.compile("`([^`\n]+)`")
	for found: RegExMatch in regex.search_all(markdown):
		var entry: String = found.get_string(1).strip_edges().trim_suffix("/")
		if not entry.begins_with("assets/") or entry.contains("*") or entry.contains("{"):
			continue
		if entry.get_extension() != "":
			entry = entry.get_base_dir()
		if not result.has(entry):
			result.append(entry)
	return result


## true si la carpeta [param directory] (sin [code]res://[/code]) es una de las [param listed] o
## está dentro de una.
static func is_covered(directory: String, listed: Array[String]) -> bool:
	for entry: String in listed:
		if directory == entry or directory.begins_with(entry + "/"):
			return true
	return false


## Tamaño en píxeles del archivo de imagen [param path], o (-1, -1) si no se puede leer. Los PNG se
## leen de su cabecera (rápido, sin decodificar); el resto, con [method Image.load_from_file].
static func image_size(path: String) -> Vector2i:
	if path.get_extension().to_lower() == "png":
		var file: FileAccess = FileAccess.open(path, FileAccess.READ)
		if file == null:
			return Vector2i(-1, -1)
		var header: PackedByteArray = file.get_buffer(24)
		if header.size() == 24 and header.slice(1, 4).get_string_from_ascii() == "PNG":
			# Después de la firma (8 B) y del tamaño y el tipo del chunk IHDR (8 B), el ancho y
			# el alto, de 4 B cada uno y en orden de red.
			return Vector2i(_big_endian_u32(header, 16), _big_endian_u32(header, 20))
	var image: Image = Image.load_from_file(path)
	if image == null or image.is_empty():
		return Vector2i(-1, -1)
	return image.get_size()


static func _big_endian_u32(bytes: PackedByteArray, offset: int) -> int:
	return (bytes[offset] << 24) | (bytes[offset + 1] << 16) | (bytes[offset + 2] << 8) \
			| bytes[offset + 3]


## Todos los archivos bajo [param root] (rutas [code]res://[/code]), sin entrar en las carpetas
## ocultas ni en las de [param skipped] (nombres, solo a nivel de [param root]).
static func _collect_files(root: String, skipped: Array[String]) -> Array[String]:
	var files: Array[String] = []
	var folders: Array[String] = []
	_walk(root, skipped, files, folders, true)
	return files


## Carpetas bajo [param root] que tienen archivos propios (sin contar los [code].uid[/code] ni los
## [code].import[/code]).
static func _collect_folders_with_files(root: String) -> Array[String]:
	var files: Array[String] = []
	var folders: Array[String] = []
	_walk(root, [], files, folders, true)
	return folders


static func _walk(directory: String, skipped: Array[String], files: Array[String],
		folders: Array[String], is_top: bool) -> void:
	var own_files: int = 0
	for file_name: String in DirAccess.get_files_at(directory):
		files.append(directory.path_join(file_name))
		if not IGNORED_EXTENSIONS.has(file_name.get_extension().to_lower()):
			own_files += 1
	if own_files > 0:
		folders.append(directory)
	for sub_name: String in DirAccess.get_directories_at(directory):
		if is_top and skipped.has(sub_name):
			continue
		_walk(directory.path_join(sub_name), skipped, files, folders, false)
