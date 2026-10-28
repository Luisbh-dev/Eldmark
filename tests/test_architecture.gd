extends TestCase
## Pruebas de arquitectura: [code]scripts/shared/[/code] no puede depender del cliente.
##
## El servidor dedicado (headless) carga [code]scripts/shared/[/code]; si algo de ahí usa Input,
## cámaras, UI, DisplayServer, el reloj o clases de [code]scripts/client/[/code], el servidor deja
## de funcionar o la simulación deja de ser determinista.
## [br][br]
## Se analiza el texto de los scripts sin los comentarios (la documentación puede mencionar
## Input o Camera3D); las cadenas sí cuentan, porque un
## [code]preload("res://scripts/client/...")[/code] es una dependencia real.

const SHARED_DIR: String = "res://scripts/shared"
const CLIENT_DIR: String = "res://scripts/client"
## Scripts compartidos que deben existir (si no, el análisis no estaría comprobando nada).
const REQUIRED_SHARED_SCRIPTS: Array[String] = [
	"player_input.gd", "player_state.gd", "player_character.gd",
]

## Referencias prohibidas en scripts/shared: [descripción, expresión regular].
const FORBIDDEN_REFERENCES: Array[Array] = [
	["Input.", "\\bInput\\."],
	["InputMap", "\\bInputMap\\b"],
	["scripts/client", "scripts/client"],
	["Camera3D", "\\bCamera3D\\b"],
	["DisplayServer", "\\bDisplayServer\\b"],
	["Time.get_", "\\bTime\\.get_"],
	# Mismo espíritu: eventos de entrada, otras cámaras y nodos de UI.
	["InputEvent*", "\\bInputEvent\\w*"],
	["Camera2D", "\\bCamera2D\\b"],
	["CanvasLayer", "\\bCanvasLayer\\b"],
	["Control", "\\bControl\\b"],
]

## Aleatoriedad global: rompe el determinismo entre cliente y servidor. Los métodos de un
## RandomNumberGenerator propio (rng.randf()) sí se permiten.
const FORBIDDEN_RANDOMNESS: Array[Array] = [
	["randf()", "(?<![\\w.])randf\\s*\\("],
	["randi()", "(?<![\\w.])randi\\s*\\("],
	["randf_range()", "(?<![\\w.])randf_range\\s*\\("],
	["randi_range()", "(?<![\\w.])randi_range\\s*\\("],
	["randfn()", "(?<![\\w.])randfn\\s*\\("],
	["randomize()", "(?<![\\w.])randomize\\s*\\("],
]

const CLASS_NAME_PATTERN: String = "(?m)^\\s*(?:@\\w+\\s+)*class_name\\s+([A-Za-z_]\\w*)"


func test_shared_scripts_exist() -> void:
	var files: PackedStringArray = _list_scripts(SHARED_DIR)
	for required: String in REQUIRED_SHARED_SCRIPTS:
		assert_true(files.has(SHARED_DIR.path_join(required)),
				"falta %s/%s" % [SHARED_DIR, required])


func test_scanner_detects_forbidden_references() -> void:
	# Comprueba el propio analizador para que las pruebas de arquitectura no pasen en vacío.
	var harmless: String = "\n".join([
		"var player_input: PlayerInput = PlayerInput.new()",
		"var mask: int = PlayerInput.JUMP # Input.is_action_pressed(\"jump\") en un comentario",
		"## Documentación que menciona Camera3D y DisplayServer.",
		"var hash_text: String = \"#\" # Input. tras un # dentro de una cadena",
		"var controller: LocalPlayerControllerLike",
		"var rng_value: float = rng.randf()",
	])
	assert_eq(_find_matches(harmless, FORBIDDEN_REFERENCES), PackedStringArray(),
			"PlayerInput, comentarios, documentación e identificadores parecidos no son "
			+ "referencias prohibidas")
	assert_eq(_find_matches(harmless, FORBIDDEN_RANDOMNESS), PackedStringArray(),
			"un RandomNumberGenerator con semilla propia sí se permite")

	var offending: Array[String] = [
		"if Input.is_action_pressed(\"jump\"):",
		"InputMap.add_action(&\"jump\")",
		"const Rig = preload(\"res://scripts/client/camera_rig.gd\") # rig",
		"var cam: Camera3D",
		"var size: Vector2i = DisplayServer.window_get_size()",
		"var now: int = Time.get_ticks_msec()",
		"func _input(event: InputEventMouseMotion) -> void:",
		"var hud: CanvasLayer",
		"var panel := Control.new()",
	]
	for line: String in offending:
		assert_eq(_find_matches(line, FORBIDDEN_REFERENCES).size(), 1, "debe detectar: %s" % line)
	assert_eq(_find_matches("var roll: float = randf()", FORBIDDEN_RANDOMNESS).size(), 1,
			"debe detectar randf()")
	assert_eq(_extract_class_names("@tool\nclass_name CameraRig\nextends Node3D\n"),
			PackedStringArray(["CameraRig"]), "extrae el class_name de un script")


func test_shared_does_not_reference_client_only_apis() -> void:
	var files: PackedStringArray = _list_scripts(SHARED_DIR)
	assert_false(files.is_empty(), "no se encontró ningún script en %s" % SHARED_DIR)
	for path: String in files:
		for found: String in _find_matches(_read_text(path), FORBIDDEN_REFERENCES):
			fail("%s usa %s, que solo existe o tiene sentido en el cliente" % [path, found])


func test_shared_does_not_reference_client_classes() -> void:
	var client_scripts: PackedStringArray = _list_scripts(CLIENT_DIR)
	var patterns: Array[Array] = []
	for path: String in client_scripts:
		for client_class: String in _extract_class_names(_read_text(path)):
			patterns.append([client_class, "\\b%s\\b" % client_class])
	if not client_scripts.is_empty():
		assert_false(patterns.is_empty(),
				"hay scripts en %s pero ninguno declara class_name" % CLIENT_DIR)
	for path: String in _list_scripts(SHARED_DIR):
		for found: String in _find_matches(_read_text(path), patterns):
			fail("%s usa la clase de cliente %s" % [path, found])


func test_shared_does_not_use_global_randomness() -> void:
	var files: PackedStringArray = _list_scripts(SHARED_DIR)
	assert_false(files.is_empty(), "no se encontró ningún script en %s" % SHARED_DIR)
	for path: String in files:
		for found: String in _find_matches(_read_text(path), FORBIDDEN_RANDOMNESS):
			fail("%s usa %s; la simulación compartida debe ser determinista" % [path, found])


# --- Utilidades -------------------------------------------------------------------------------

## Scripts .gd bajo [param dir], recursivamente, ordenados.
func _list_scripts(dir: String) -> PackedStringArray:
	var result: PackedStringArray = PackedStringArray()
	if not DirAccess.dir_exists_absolute(dir):
		return result
	for file_name: String in DirAccess.get_files_at(dir):
		if file_name.ends_with(".gd"):
			result.append(dir.path_join(file_name))
	for sub_dir: String in DirAccess.get_directories_at(dir):
		result.append_array(_list_scripts(dir.path_join(sub_dir)))
	result.sort()
	return result


func _read_text(path: String) -> String:
	return FileAccess.get_file_as_string(path)


## Descripciones de los patrones de [param patterns] ([descripción, regex]) que aparecen en
## [param text] fuera de los comentarios, con el número de línea.
func _find_matches(text: String, patterns: Array) -> PackedStringArray:
	var code: String = _strip_comments(text)
	var found: PackedStringArray = PackedStringArray()
	for pattern: Array in patterns:
		var regex := RegEx.new()
		if regex.compile(pattern[1]) != OK:
			fail("expresión regular inválida: %s" % pattern[1])
			continue
		for result: RegExMatch in regex.search_all(code):
			var line_number: int = code.substr(0, result.get_start()).count("\n") + 1
			found.append("%s (línea %d)" % [pattern[0], line_number])
	return found


## Nombres declarados con class_name en [param text].
static func _extract_class_names(text: String) -> PackedStringArray:
	var names: PackedStringArray = PackedStringArray()
	var regex := RegEx.new()
	regex.compile(CLASS_NAME_PATTERN)
	for result: RegExMatch in regex.search_all(_strip_comments(text)):
		names.append(result.get_string(1))
	return names


## Texto sin comentarios.
static func _strip_comments(text: String) -> String:
	var lines: PackedStringArray = PackedStringArray()
	for line: String in text.split("\n"):
		lines.append(_strip_comment(line))
	return "\n".join(lines)


## Quita el comentario de una línea respetando las cadenas ("..." y '...').
static func _strip_comment(line: String) -> String:
	var quote: String = ""
	var i: int = 0
	while i < line.length():
		var character: String = line[i]
		if quote.is_empty():
			if character == "#":
				return line.substr(0, i)
			if character == "\"" or character == "'":
				quote = character
		elif character == "\\":
			i += 1
		elif character == quote:
			quote = ""
		i += 1
	return line
