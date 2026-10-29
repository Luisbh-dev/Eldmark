extends TestCase
## Pruebas de arquitectura: lo que carga el servidor no puede depender del cliente.
##
## El servidor dedicado (headless) carga [code]scripts/shared/[/code] y, a través de las escenas
## de zona, [code]scripts/world/[/code]; si algo de ahí usa Input, cámaras, UI, DisplayServer, el
## reloj o clases de [code]scripts/client/[/code], el servidor deja de funcionar o la simulación
## deja de ser determinista. También se recorre el árbol de dependencias de cada escena de zona, de
## la escena del personaje ([code]player_character.tscn[/code], que precarga el servidor) y de la
## del propio servidor: no pueden arrastrar scripts del cliente, animaciones ni visuales de personaje.
## [br][br]
## Además, [code]scripts/server/[/code] y [code]scripts/client/[/code] no dependen el uno del otro
## (docs/red.md, sección 16), y [code]scripts/shared/[/code] tampoco depende del servidor: ni
## rutas ni clases ([code]class_name[/code]) del otro lado.
## [br][br]
## Se analiza el texto de los scripts sin los comentarios (la documentación puede mencionar
## Input o Camera3D); las cadenas sí cuentan, porque un
## [code]preload("res://scripts/client/...")[/code] es una dependencia real.

const SHARED_DIR: String = "res://scripts/shared"
## Carpetas que carga el servidor (la simulación compartida y los scripts de las zonas).
const SERVER_DIRS: Array[String] = ["res://scripts/shared", "res://scripts/world"]
const CLIENT_DIR: String = "res://scripts/client"
## El audio es solo del cliente (ART-10): carpeta de sus scripts y script de servicios del cliente.
const AUDIO_DIR: String = "res://scripts/client/audio"
const CLIENT_SERVICES_SCRIPT: String = "res://scripts/client/client_services.gd"
## Scripts de arranque que cargan cliente y servidor (nombran a ClientMain, pero no al audio).
const BOOT_SCRIPTS: Array[String] = ["res://scripts/boot.gd"]
const SERVER_DIR: String = "res://scripts/server"
## Escenas, además de las de zona, que carga el servidor dedicado: el personaje (lo precarga
## [code]ZoneServer[/code]) y la escena raíz del servidor. Tampoco pueden depender del cliente.
const SERVER_SCENES: Array[String] = [
	"res://scenes/characters/player_character.tscn", "res://scenes/server/server_main.tscn",
]
## Rutas que ninguna escena de zona puede arrastrar (las carga el servidor dedicado).
const ZONE_FORBIDDEN_DEPENDENCIES: Array[String] = [
	"res://scripts/client/", "res://assets/animations/", "res://scenes/characters/visuals/",
	"res://scenes/client/", "res://scenes/ui/", "res://assets/audio/",
]
## Materiales de reino: todos deben usarse en alguna zona (los que sobran se borran).
const REALM_MATERIALS_DIR: String = "res://assets/materials/realms"
## Scripts compartidos que deben existir (si no, el análisis no estaría comprobando nada).
const REQUIRED_SHARED_SCRIPTS: Array[String] = [
	"player_input.gd", "player_state.gd", "player_character.gd", "bot_brain.gd",
	"net/net_protocol.gd", "net/net_zones.gd", "net/net_math.gd", "net/entity_record.gd",
	"net/net_messages.gd",
]

## Scripts del servidor que deben existir (si no, las reglas de dependencias no comprobarían nada).
const REQUIRED_SERVER_SCRIPTS: Array[String] = [
	"server_config.gd", "server_peer.gd", "server_auth.gd", "auth_provider.gd",
	"dev_auth_provider.gd", "rate_limiter.gd", "input_queue.gd", "net_entity.gd",
	"net_entity_registry.gd", "spawn_picker.gd", "snapshot_builder.gd", "interest_policy.gd",
	"state_history.gd", "server_metrics.gd", "combatant.gd", "damage_ledger.gd",
	"combat_resolver.gd", "combat_director.gd", "command_registry.gd",
]

## Referencias prohibidas en scripts/shared: [descripción, expresión regular].
const FORBIDDEN_REFERENCES: Array[Array] = [
	["Input.", "\\bInput\\."],
	["InputMap", "\\bInputMap\\b"],
	["scripts/client", "scripts/client"],
	["Camera3D", "\\bCamera3D\\b"],
	["DisplayServer", "\\bDisplayServer\\b"],
	["Time.get_", "\\bTime\\.get_"],
	# Contadores de fotogramas del proceso: distintos en el cliente y en el servidor.
	["Engine.get_*_frames", "\\bEngine\\.get_(?:physics|process)_frames\\b"],
	# Mismo espíritu: eventos de entrada, otras cámaras y nodos de UI.
	["InputEvent*", "\\bInputEvent\\w*"],
	["Camera2D", "\\bCamera2D\\b"],
	["CanvasLayer", "\\bCanvasLayer\\b"],
	["Control", "\\bControl\\b"],
]

## Aleatoriedad global: rompe el determinismo entre cliente y servidor. Los métodos de un
## RandomNumberGenerator propio (rng.randf()) sí se permiten, con su semilla fijada
## ([method test_random_generators_are_seeded]); [code]rng.randomize()[/code] no, porque le da una
## semilla distinta en cada proceso. [code]Array.pick_random()[/code] y [code]shuffle()[/code]
## usan el generador global.
const FORBIDDEN_RANDOMNESS: Array[Array] = [
	["randf()", "(?<![\\w.])randf\\s*\\("],
	["randi()", "(?<![\\w.])randi\\s*\\("],
	["randf_range()", "(?<![\\w.])randf_range\\s*\\("],
	["randi_range()", "(?<![\\w.])randi_range\\s*\\("],
	["randfn()", "(?<![\\w.])randfn\\s*\\("],
	["randomize()", "(?<![\\w.])randomize\\s*\\("],
	[".randomize()", "\\.randomize\\s*\\("],
	[".pick_random()", "\\.pick_random\\s*\\("],
	[".shuffle()", "\\.shuffle\\s*\\("],
]

## NetZones es el único contacto de la red con zones.gd (docs/red.md, 1.5 y 17.3): en estas carpetas
## ningún otro script nombra [Zones]. Excepciones: [code]server_main.gd[/code] (la lista de zonas del
## aviso de zona desconocida y los reinos con campamento de los jugadores falsos, sección 19) y
## [code]client_main.gd[/code], el sandbox sin red de la fase 1, que es anterior a la red.
const ZONES_CONTACT_DIRS: Array[String] = [
	"res://scripts/server", "res://scripts/client", "res://scripts/shared/net",
]
const ZONES_CONTACT_EXCEPTIONS: Array[String] = [
	"res://scripts/shared/net/net_zones.gd", "res://scripts/server/server_main.gd",
	"res://scripts/client/client_main.gd",
]
const ZONES_PATTERN: Array[Array] = [["Zones.", "\\bZones\\."]]

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
		"var camera: Camera = get_viewport().get_camera_3d()",
		"var reshuffled: int = shuffle_count + pick_random_name.length()",
		"var frames: int = Engine.get_frames_per_second()",
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
	for line: String in [
		"var point: Node3D = points.pick_random()",
		"points.shuffle()",
		"rng.randomize()",
		"randomize()",
	]:
		assert_eq(_find_matches(line, FORBIDDEN_RANDOMNESS).size(), 1, "debe detectar: %s" % line)
	for line: String in [
		"var frame: int = Engine.get_physics_frames()",
		"var frame: int = Engine.get_process_frames()",
	]:
		assert_eq(_find_matches(line, FORBIDDEN_REFERENCES).size(), 1, "debe detectar: %s" % line)
	assert_eq(_extract_class_names("@tool\nclass_name CameraRig\nextends Node3D\n"),
			PackedStringArray(["CameraRig"]), "extrae el class_name de un script")


func test_shared_does_not_reference_client_only_apis() -> void:
	var files: PackedStringArray = _list_server_scripts()
	assert_false(files.is_empty(), "no se encontró ningún script en %s" % [SERVER_DIRS])
	assert_true(files.has("res://scripts/world/zone_root.gd"), "también se analiza scripts/world")
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
	for path: String in _list_server_scripts():
		for found: String in _find_matches(_read_text(path), patterns):
			fail("%s usa la clase de cliente %s" % [path, found])


## Árbol de dependencias de cada escena de zona (recursivo, con ResourceLoader): nada del
## cliente, ni animaciones ni visuales de personaje. Y todos los materiales de reino se usan.
func test_zone_scenes_do_not_depend_on_client() -> void:
	var used_materials: Dictionary = {}
	for zone_id: StringName in Zones.get_zone_ids():
		var scene_path: String = Zones.get_scene_path(zone_id)
		var visited: Dictionary = {}
		_collect_dependencies(scene_path, visited)
		assert_true(visited.has(scene_path), "%s: se recorre su escena" % zone_id)
		for violation: String in _forbidden_dependencies(visited):
			fail("%s depende de %s" % [zone_id, violation])
		for path: String in visited:
			if path.begins_with(REALM_MATERIALS_DIR):
				used_materials[path] = true
	for realm_dir: String in DirAccess.get_directories_at(REALM_MATERIALS_DIR):
		for file_name: String in DirAccess.get_files_at(REALM_MATERIALS_DIR.path_join(realm_dir)):
			if file_name.get_extension() != "tres":
				continue
			var path: String = REALM_MATERIALS_DIR.path_join(realm_dir).path_join(file_name)
			assert_true(used_materials.has(path), "%s no lo usa ninguna zona" % path)


## Lo que carga el servidor (scripts/shared y scripts/world): nada de aleatoriedad global.
## El personaje (lo precarga el servidor) y la escena raíz del servidor tampoco arrastran nada del
## cliente: el visual (HumanoidVisual, CharacterAnimator) lo cuelga el cliente en tiempo de ejecución.
func test_server_scenes_do_not_depend_on_client() -> void:
	for scene_path: String in SERVER_SCENES:
		var visited: Dictionary = {}
		_collect_dependencies(scene_path, visited)
		assert_true(visited.has(scene_path), "%s: se recorre su escena" % scene_path)
		assert_true(visited.size() > 1, "%s: tiene dependencias que recorrer" % scene_path)
		for violation: String in _forbidden_dependencies(visited):
			fail("%s depende de %s" % [scene_path, violation])
	var synthetic: Dictionary = {
		"res://scenes/characters/player_character.tscn": true,
		"res://scripts/client/character_animator.gd": true,
		"res://scenes/characters/visuals/humanoid.tscn": true,
		"res://scripts/shared/player_character.gd": true,
	}
	assert_eq(_forbidden_dependencies(synthetic).size(), 2,
			"el filtro de dependencias detecta un script del cliente y un visual de personaje")


func test_shared_and_world_do_not_use_global_randomness() -> void:
	var files: PackedStringArray = _list_server_scripts()
	assert_false(files.is_empty(), "no se encontró ningún script en %s" % [SERVER_DIRS])
	assert_true(files.has("res://scripts/world/zone_root.gd"), "también se analiza scripts/world")
	for path: String in files:
		for found: String in _find_matches(_read_text(path), FORBIDDEN_RANDOMNESS):
			fail("%s usa %s; lo que carga el servidor debe ser determinista" % [path, found])


## Un [RandomNumberGenerator] nuevo tiene una semilla distinta en cada proceso: el script que lo crea
## tiene que fijársela.
func test_random_generators_are_seeded() -> void:
	var created: int = 0
	for path: String in _list_server_scripts():
		var text: String = _read_text(path)
		if _creates_unseeded_generator(text):
			fail("%s crea un RandomNumberGenerator y no le fija la semilla (.seed = ...)" % path)
		if _strip_comments(text).contains("RandomNumberGenerator.new("):
			created += 1
	assert_true(created > 0, "hay generadores de números aleatorios que comprobar (BotBrain, NetSim)")
	assert_true(_creates_unseeded_generator("var rng := RandomNumberGenerator.new()\nvar x: float = rng.randf()"),
			"sin semilla, lo detecta")
	assert_false(_creates_unseeded_generator("var rng := RandomNumberGenerator.new()\nfunc f() -> void:\n\trng.seed = 5"),
			"con semilla, no")
	assert_false(_creates_unseeded_generator("# RandomNumberGenerator.new() en un comentario"),
			"un comentario no cuenta")


func test_server_scripts_exist() -> void:
	var files: PackedStringArray = _list_scripts(SERVER_DIR)
	for required: String in REQUIRED_SERVER_SCRIPTS:
		assert_true(files.has(SERVER_DIR.path_join(required)),
				"falta %s/%s" % [SERVER_DIR, required])


## scripts/server no usa rutas ni clases de scripts/client.
func test_server_does_not_depend_on_client() -> void:
	var server_scripts: PackedStringArray = _list_scripts(SERVER_DIR)
	assert_false(server_scripts.is_empty(), "no se encontró ningún script en %s" % SERVER_DIR)
	var patterns: Array[Array] = [["scripts/client", "scripts/client"]]
	patterns.append_array(_class_patterns(CLIENT_DIR))
	if not _list_scripts(CLIENT_DIR).is_empty():
		assert_true(patterns.size() > 1, "los scripts de %s declaran class_name" % CLIENT_DIR)
	for path: String in server_scripts:
		for found: String in _find_matches(_read_text(path), patterns):
			fail("%s depende del cliente: %s" % [path, found])


## scripts/client no usa rutas ni clases de scripts/server.
func test_client_does_not_depend_on_server() -> void:
	var client_scripts: PackedStringArray = _list_scripts(CLIENT_DIR)
	assert_false(client_scripts.is_empty(), "no se encontró ningún script en %s" % CLIENT_DIR)
	var patterns: Array[Array] = [["scripts/server", "scripts/server"]]
	var server_patterns: Array[Array] = _class_patterns(SERVER_DIR)
	assert_false(server_patterns.is_empty(), "los scripts de %s declaran class_name" % SERVER_DIR)
	patterns.append_array(server_patterns)
	for path: String in client_scripts:
		for found: String in _find_matches(_read_text(path), patterns):
			fail("%s depende del servidor: %s" % [path, found])


## scripts/shared (y scripts/world, que también carga el servidor) no usan rutas ni clases de
## scripts/server: lo compartido no puede depender de quien lo usa.
func test_shared_does_not_depend_on_server() -> void:
	var patterns: Array[Array] = [["scripts/server", "scripts/server"]]
	var server_patterns: Array[Array] = _class_patterns(SERVER_DIR)
	assert_false(server_patterns.is_empty(), "los scripts de %s declaran class_name" % SERVER_DIR)
	patterns.append_array(server_patterns)
	var files: PackedStringArray = _list_server_scripts()
	assert_false(files.is_empty(), "no se encontró ningún script en %s" % [SERVER_DIRS])
	for path: String in files:
		for found: String in _find_matches(_read_text(path), patterns):
			fail("%s depende del servidor: %s" % [path, found])


## El servidor dedicado no carga el audio (ART-10): ni los scripts de [code]scripts/client/audio/[/code]
## ni [ClientServices] (que los monta) aparecen en lo que carga el servidor (compartido, mundo,
## servidor y los scripts de arranque), ninguna escena de zona ni del servidor depende de ellos o de
## [code]assets/audio/[/code], y el proyecto no declara autoloads del cliente (los cargaría el servidor).
## Los monta la escena del cliente ([code]client_main.tscn[/code], [code]online_main.tscn[/code]).
func test_server_does_not_load_audio() -> void:
	var audio_scripts: PackedStringArray = _list_scripts(AUDIO_DIR)
	assert_true(audio_scripts.size() >= 2, "hay scripts de audio que comprobar")
	assert_true(audio_scripts.has(AUDIO_DIR.path_join("audio_director.gd")), "existe AudioDirector")
	assert_true(FileAccess.file_exists(CLIENT_SERVICES_SCRIPT), "existe ClientServices")
	var patterns: Array[Array] = [
		["scripts/client/audio", "scripts/client/audio"],
		["client_services", "client_services"],
		["ClientServices", "\\bClientServices\\b"],
	]
	patterns.append_array(_class_patterns(AUDIO_DIR))
	assert_true(patterns.size() >= 5, "se conocen las clases de audio")
	var checked: PackedStringArray = _list_server_scripts()
	checked.append_array(_list_scripts(SERVER_DIR))
	checked.append_array(PackedStringArray(BOOT_SCRIPTS))
	for path: String in checked:
		for found: String in _find_matches(_read_text(path), patterns):
			fail("%s nombra el audio del cliente: %s" % [path, found])
	# El analizador detecta un uso real.
	assert_false(_find_matches("var director: AudioDirector = null", patterns).is_empty(),
			"detecta una clase de audio")
	# Las escenas que carga el servidor no dependen del audio (las zonas y las del servidor ya
	# prohíben todo scripts/client/ y assets/audio/ en ZONE_FORBIDDEN_DEPENDENCIES).
	var synthetic: Dictionary = {"res://scripts/client/audio/audio_director.gd": true,
			"res://assets/audio/sfx/golpe.ogg": true}
	assert_eq(_forbidden_dependencies(synthetic).size(), 2, "el filtro detecta el audio")
	for scene_path: String in SERVER_SCENES:
		var visited: Dictionary = {}
		_collect_dependencies(scene_path, visited)
		assert_false(visited.has(CLIENT_SERVICES_SCRIPT), "%s no monta los servicios" % scene_path)
	# Sin autoloads de cliente en el proyecto.
	var project: String = _read_text("res://project.godot")
	assert_false(project.contains("scripts/client"), "project.godot no nombra scripts del cliente")
	assert_false(project.contains("[autoload]"), "y no declara autoloads (los cargaría el servidor)")
	# Y sí los monta la escena del cliente.
	for scene_path: String in ["res://scenes/client/client_main.tscn",
			"res://scenes/client/online_main.tscn"]:
		var deps: Dictionary = {}
		_collect_dependencies(scene_path, deps)
		assert_true(deps.has(CLIENT_SERVICES_SCRIPT), "%s monta ClientServices" % scene_path)


## Si zones.gd cambia (el grupo o el metadato de los puntos de aparición, una firma...), solo se
## tocan NetZones y los pocos archivos de la excepción; no SpawnPicker ni nada de la red.
func test_only_net_zones_talks_to_zones_in_the_network_code() -> void:
	assert_eq(_find_matches("var p: Array = Zones.get_spawn_points(_world)\nZones.SPAWN_GROUP", ZONES_PATTERN).size(), 2,
			"detecta las llamadas a Zones")
	assert_eq(_find_matches("NetZones.scene_path(id)\nMyZones.x\n# Zones.x en un comentario", ZONES_PATTERN),
			PackedStringArray(), "pero no NetZones, otros nombres ni los comentarios")
	var checked: int = 0
	for dir: String in ZONES_CONTACT_DIRS:
		for path: String in _list_scripts(dir):
			if ZONES_CONTACT_EXCEPTIONS.has(path):
				continue
			checked += 1
			for found: String in _find_matches(_read_text(path), ZONES_PATTERN):
				fail("%s nombra Zones (%s); la red habla con zones.gd solo a través de NetZones" % [path, found])
	assert_true(checked > 20, "se revisan los scripts de la red (%d)" % checked)
	for excepted: String in ZONES_CONTACT_EXCEPTIONS:
		assert_true(FileAccess.file_exists(excepted), "existe la excepción %s" % excepted)


func test_dependency_scanner_detects_cross_references() -> void:
	# Comprueba el analizador de dependencias entre carpetas con texto sintético.
	var server_patterns: Array[Array] = [["scripts/server", "scripts/server"]]
	server_patterns.append_array(_class_patterns(SERVER_DIR))
	var offending: Array[String] = [
		"const Queue = preload(\"res://scripts/server/input_queue.gd\")",
		"var queue: InputQueue = InputQueue.new()",
		"func f(peer: ServerPeer) -> void:",
		"var builder := SnapshotBuilder.new(null)",
	]
	for line: String in offending:
		assert_false(_find_matches(line, server_patterns).is_empty(), "debe detectar: %s" % line)
	var harmless: String = "\n".join([
		"# usa InputQueue y scripts/server solo en un comentario",
		"## Documentación sobre SnapshotBuilder.",
		"var my_input_queue_size: int = 0",
		"var text: String = \"#\" # StateHistory tras un # dentro de una cadena",
		"var name_of_peer: String = \"ServerPeerless\"",
	])
	assert_eq(_find_matches(harmless, server_patterns), PackedStringArray(),
			"comentarios, documentación e identificadores parecidos no son dependencias")
	var client_patterns: Array[Array] = [["scripts/client", "scripts/client"]]
	client_patterns.append_array(_class_patterns(CLIENT_DIR))
	assert_false(_find_matches("var rig: CameraRig", client_patterns).is_empty(),
			"y la dirección contraria detecta las clases del cliente")


# --- Utilidades -------------------------------------------------------------------------------

## Scripts de todas las carpetas de [constant SERVER_DIRS].
func _list_server_scripts() -> PackedStringArray:
	var files: PackedStringArray = PackedStringArray()
	for dir: String in SERVER_DIRS:
		files.append_array(_list_scripts(dir))
	return files


## Patrones [descripción, regex] de las clases ([code]class_name[/code]) de los scripts de
## [param dir].
func _class_patterns(dir: String) -> Array[Array]:
	var patterns: Array[Array] = []
	for path: String in _list_scripts(dir):
		for declared: String in _extract_class_names(_read_text(path)):
			patterns.append([declared, "\\b%s\\b" % declared])
	return patterns


## Rutas res:// de las que depende [param path], recursivamente (en [param visited]).
func _collect_dependencies(path: String, visited: Dictionary) -> void:
	if visited.has(path):
		return
	visited[path] = true
	for dependency: String in ResourceLoader.get_dependencies(path):
		# Formato "uid://...::Tipo::res://ruta" (o solo la ruta).
		var dep_path: String = dependency.get_slice("::", 2) if dependency.contains("::") else dependency
		if dep_path.begins_with("uid://"):
			dep_path = ResourceUID.get_id_path(ResourceUID.text_to_id(dep_path))
		if dep_path.begins_with("res://"):
			_collect_dependencies(dep_path, visited)


## Dependencias de [param visited] ([method _collect_dependencies]) que empiezan por alguna ruta de
## [constant ZONE_FORBIDDEN_DEPENDENCIES], con la regla que incumplen.
func _forbidden_dependencies(visited: Dictionary) -> PackedStringArray:
	var violations := PackedStringArray()
	for path: String in visited:
		for forbidden: String in ZONE_FORBIDDEN_DEPENDENCIES:
			if path.begins_with(forbidden):
				violations.append("%s (prohibido: %s)" % [path, forbidden])
	return violations


## true si [param text] crea un [RandomNumberGenerator] y no le asigna ninguna semilla.
func _creates_unseeded_generator(text: String) -> bool:
	var code: String = _strip_comments(text)
	if not code.contains("RandomNumberGenerator.new("):
		return false
	var seeded := RegEx.new()
	seeded.compile("\\.seed\\s*=|\\.set_seed\\s*\\(")
	return seeded.search(code) == null


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
