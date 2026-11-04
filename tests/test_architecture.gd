extends TestCase
## Architecture tests: what the server loads cannot depend on the client.
##
## The dedicated (headless) server loads [code]scripts/shared/[/code] and, through the zone
## scenes, [code]scripts/world/[/code]; if anything in there uses Input, cameras, UI, DisplayServer, the
## clock or classes from [code]scripts/client/[/code], the server stops working or the simulation
## stops being deterministic. The dependency tree of each zone scene, of the
## character scene ([code]player_character.tscn[/code], which the server preloads) and of the
## server's own scene is also walked: they cannot pull in client scripts, animations or character visuals.
## [br][br]
## In addition, [code]scripts/server/[/code] and [code]scripts/client/[/code] do not depend on each other
## (docs/red.md, section 16), and [code]scripts/shared/[/code] does not depend on the server either: neither
## paths nor classes ([code]class_name[/code]) from the other side.
## [br][br]
## The text of the scripts is analyzed without the comments (the documentation may mention
## Input or Camera3D); strings do count, because a
## [code]preload("res://scripts/client/...")[/code] is a real dependency.

const SHARED_DIR: String = "res://scripts/shared"
## Folders the server loads (the shared simulation and the zone scripts).
const SERVER_DIRS: Array[String] = ["res://scripts/shared", "res://scripts/world"]
const CLIENT_DIR: String = "res://scripts/client"
## Audio is client-only (ART-10): folder of its scripts and the client services script.
const AUDIO_DIR: String = "res://scripts/client/audio"
const CLIENT_SERVICES_SCRIPT: String = "res://scripts/client/client_services.gd"
## Boot scripts loaded by both client and server: they name no client class.
const BOOT_SCRIPTS: Array[String] = ["res://scripts/boot.gd"]
const SERVER_DIR: String = "res://scripts/server"
## Scenes, besides the zone ones, that the dedicated server loads: the character (preloaded by
## [code]ZoneServer[/code]) and the server's root scene. They cannot depend on the client either.
const SERVER_SCENES: Array[String] = [
	"res://scenes/characters/player_character.tscn", "res://scenes/server/server_main.tscn",
]
## Paths no zone scene may pull in (the dedicated server loads them).
const ZONE_FORBIDDEN_DEPENDENCIES: Array[String] = [
	"res://scripts/client/", "res://assets/animations/", "res://scenes/characters/visuals/",
	"res://scenes/client/", "res://scenes/ui/", "res://assets/audio/",
]
## Realm materials: all must be used in some zone (the leftovers are deleted).
const REALM_MATERIALS_DIR: String = "res://assets/materials/realms"
## Shared scripts that must exist (otherwise the analysis would be checking nothing).
const REQUIRED_SHARED_SCRIPTS: Array[String] = [
	"player_input.gd", "player_state.gd", "player_character.gd", "bot_brain.gd",
	"net/net_protocol.gd", "net/net_zones.gd", "net/net_math.gd", "net/entity_record.gd",
	"net/net_messages.gd", "net/progress_messages.gd",
]

## Server scripts that must exist (otherwise the dependency rules would check nothing).
const REQUIRED_SERVER_SCRIPTS: Array[String] = [
	"server_config.gd", "server_peer.gd", "server_auth.gd", "auth_provider.gd",
	"dev_auth_provider.gd", "rate_limiter.gd", "input_queue.gd", "net_entity.gd",
	"net_entity_registry.gd", "spawn_picker.gd", "snapshot_builder.gd", "interest_policy.gd",
	"state_history.gd", "server_metrics.gd", "combatant.gd", "damage_ledger.gd",
	"combat_resolver.gd", "combat_director.gd", "command_registry.gd",
]

## Forbidden references in scripts/shared: [description, regular expression].
const FORBIDDEN_REFERENCES: Array[Array] = [
	["Input.", "\\bInput\\."],
	["InputMap", "\\bInputMap\\b"],
	["scripts/client", "scripts/client"],
	["Camera3D", "\\bCamera3D\\b"],
	["DisplayServer", "\\bDisplayServer\\b"],
	["Time.get_", "\\bTime\\.get_"],
	# Process frame counters: different on the client and the server.
	["Engine.get_*_frames", "\\bEngine\\.get_(?:physics|process)_frames\\b"],
	# Same spirit: input events, other cameras and UI nodes.
	["InputEvent*", "\\bInputEvent\\w*"],
	["Camera2D", "\\bCamera2D\\b"],
	["CanvasLayer", "\\bCanvasLayer\\b"],
	["Control", "\\bControl\\b"],
]

## Global randomness: it breaks determinism between client and server. The methods of a
## RandomNumberGenerator of one's own (rng.randf()) are allowed, with its seed fixed
## ([method test_random_generators_are_seeded]); [code]rng.randomize()[/code] is not, because it gives it a
## different seed in each process. [code]Array.pick_random()[/code] and [code]shuffle()[/code]
## use the global generator.
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

## NetZones is the network's only contact with zones.gd (docs/red.md, 1.5 and 17.3): in these folders
## no other script names [Zones]. Exceptions: [code]server_main.gd[/code] (the zone list of the
## unknown-zone notice and the realms with a camp for the fake players, section 19) and
## [code]client_main.gd[/code], the networkless sandbox of phase 1, which predates the network.
const ZONES_CONTACT_DIRS: Array[String] = [
	"res://scripts/server", "res://scripts/client", "res://scripts/shared/net",
]
const ZONES_CONTACT_EXCEPTIONS: Array[String] = [
	"res://scripts/shared/net/net_zones.gd", "res://scripts/server/server_main.gd",
	"res://scripts/client/client_main.gd",
]
const ZONES_PATTERN: Array[Array] = [["Zones.", "\\bZones\\."]]

const CLASS_NAME_PATTERN: String = "(?m)^\\s*(?:@\\w+\\s+)*class_name\\s+([A-Za-z_]\\w*)"

## Progression (docs/progresion.md §14.2): shared code does not see the time, the system or the input, and the
## progress server does not read the time (UTC is [code]ZonePlatform.now_unix()[/code]).
const PROGRESSION_SHARED_DIR: String = "res://scripts/shared/progression"
const PROGRESSION_SERVER_DIR: String = "res://scripts/server/progress"
const PROGRESSION_SHARED_FORBIDDEN: Array[Array] = [
	["Time", "\\bTime\\."], ["OS", "\\bOS\\."], ["Input", "\\bInput\\."],
]
const PROGRESSION_SERVER_FORBIDDEN: Array[Array] = [["Time", "\\bTime\\."]]
## Data that the server loads and that cannot carry textures, scenes or meshes (the server preset
## trims assets/): the paths of the pieces go as text (progresion.md §2.1 and §14.2).
const ASSET_FREE_DATA_DIRS: Array[String] = ["res://data/characters", "res://data/items", "res://data/progression"]
const ASSET_CLASSES: Array[String] = ["Texture2D", "Texture", "PackedScene", "Mesh", "ArrayMesh",
		"CompressedTexture2D", "ImageTexture"]
## Folders whose [code]class_name[/code] values cannot be repeated: Godot silently registers only one.
const CLASS_NAME_DIRS: Array[String] = ["res://scripts", "res://tests", "res://tools", "res://addons"]


func test_shared_scripts_exist() -> void:
	var files: PackedStringArray = _list_scripts(SHARED_DIR)
	for required: String in REQUIRED_SHARED_SCRIPTS:
		assert_true(files.has(SHARED_DIR.path_join(required)),
				"%s/%s is missing" % [SHARED_DIR, required])


func test_scanner_detects_forbidden_references() -> void:
	# Checks the analyzer itself so the architecture tests do not pass vacuously.
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
			"PlayerInput, comments, documentation and similar identifiers are not "
			+ "forbidden references")
	assert_eq(_find_matches(harmless, FORBIDDEN_RANDOMNESS), PackedStringArray(),
			"a RandomNumberGenerator with its own seed is allowed")

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
		assert_eq(_find_matches(line, FORBIDDEN_REFERENCES).size(), 1, "must detect: %s" % line)
	assert_eq(_find_matches("var roll: float = randf()", FORBIDDEN_RANDOMNESS).size(), 1,
			"must detect randf()")
	for line: String in [
		"var point: Node3D = points.pick_random()",
		"points.shuffle()",
		"rng.randomize()",
		"randomize()",
	]:
		assert_eq(_find_matches(line, FORBIDDEN_RANDOMNESS).size(), 1, "must detect: %s" % line)
	for line: String in [
		"var frame: int = Engine.get_physics_frames()",
		"var frame: int = Engine.get_process_frames()",
	]:
		assert_eq(_find_matches(line, FORBIDDEN_REFERENCES).size(), 1, "must detect: %s" % line)
	assert_eq(_extract_class_names("@tool\nclass_name CameraRig\nextends Node3D\n"),
			PackedStringArray(["CameraRig"]), "extracts the class_name of a script")


func test_shared_does_not_reference_client_only_apis() -> void:
	var files: PackedStringArray = _list_server_scripts()
	assert_false(files.is_empty(), "no script was found in %s" % [SERVER_DIRS])
	assert_true(files.has("res://scripts/world/zone_root.gd"), "scripts/world is analyzed too")
	for path: String in files:
		for found: String in _find_matches(_read_text(path), FORBIDDEN_REFERENCES):
			fail("%s uses %s, which only exists or makes sense on the client" % [path, found])


func test_shared_does_not_reference_client_classes() -> void:
	var client_scripts: PackedStringArray = _list_scripts(CLIENT_DIR)
	var patterns: Array[Array] = []
	for path: String in client_scripts:
		for client_class: String in _extract_class_names(_read_text(path)):
			patterns.append([client_class, "\\b%s\\b" % client_class])
	if not client_scripts.is_empty():
		assert_false(patterns.is_empty(),
				"there are scripts in %s but none declares class_name" % CLIENT_DIR)
	for path: String in _list_server_scripts():
		for found: String in _find_matches(_read_text(path), patterns):
			fail("%s uses the client class %s" % [path, found])


## Dependency tree of each zone scene (recursive, with ResourceLoader): nothing from the
## client, no animations or character visuals. And all realm materials are used.
func test_zone_scenes_do_not_depend_on_client() -> void:
	var used_materials: Dictionary = {}
	for zone_id: StringName in Zones.get_zone_ids():
		var scene_path: String = Zones.get_scene_path(zone_id)
		var visited: Dictionary = {}
		_collect_dependencies(scene_path, visited)
		assert_true(visited.has(scene_path), "%s: its scene is walked" % zone_id)
		for violation: String in _forbidden_dependencies(visited):
			fail("%s depends on %s" % [zone_id, violation])
		for path: String in visited:
			if path.begins_with(REALM_MATERIALS_DIR):
				used_materials[path] = true
	for realm_dir: String in DirAccess.get_directories_at(REALM_MATERIALS_DIR):
		for file_name: String in DirAccess.get_files_at(REALM_MATERIALS_DIR.path_join(realm_dir)):
			if file_name.get_extension() != "tres":
				continue
			var path: String = REALM_MATERIALS_DIR.path_join(realm_dir).path_join(file_name)
			assert_true(used_materials.has(path), "%s is not used by any zone" % path)


## What the server loads (scripts/shared and scripts/world): no global randomness.
## The character (preloaded by the server) and the server's root scene do not pull in anything from the
## client either: the visual (HumanoidVisual, CharacterAnimator) is attached by the client at runtime.
func test_server_scenes_do_not_depend_on_client() -> void:
	for scene_path: String in SERVER_SCENES:
		var visited: Dictionary = {}
		_collect_dependencies(scene_path, visited)
		assert_true(visited.has(scene_path), "%s: its scene is walked" % scene_path)
		assert_true(visited.size() > 1, "%s: has dependencies to walk" % scene_path)
		for violation: String in _forbidden_dependencies(visited):
			fail("%s depends on %s" % [scene_path, violation])
	var synthetic: Dictionary = {
		"res://scenes/characters/player_character.tscn": true,
		"res://scripts/client/character_animator.gd": true,
		"res://scenes/characters/visuals/humanoid.tscn": true,
		"res://scripts/shared/player_character.gd": true,
	}
	assert_eq(_forbidden_dependencies(synthetic).size(), 2,
			"the dependency filter detects a client script and a character visual")


func test_shared_and_world_do_not_use_global_randomness() -> void:
	var files: PackedStringArray = _list_server_scripts()
	assert_false(files.is_empty(), "no script was found in %s" % [SERVER_DIRS])
	assert_true(files.has("res://scripts/world/zone_root.gd"), "scripts/world is analyzed too")
	for path: String in files:
		for found: String in _find_matches(_read_text(path), FORBIDDEN_RANDOMNESS):
			fail("%s uses %s; what the server loads must be deterministic" % [path, found])


## A new [RandomNumberGenerator] has a different seed in each process: the script that creates it
## has to set it.
func test_random_generators_are_seeded() -> void:
	var created: int = 0
	for path: String in _list_server_scripts():
		var text: String = _read_text(path)
		if _creates_unseeded_generator(text):
			fail("%s creates a RandomNumberGenerator and does not set its seed (.seed = ...)" % path)
		if _strip_comments(text).contains("RandomNumberGenerator.new("):
			created += 1
	assert_true(created > 0, "there are random number generators to check (BotBrain, NetSim)")
	assert_true(_creates_unseeded_generator("var rng := RandomNumberGenerator.new()\nvar x: float = rng.randf()"),
			"without a seed, it detects it")
	assert_false(_creates_unseeded_generator("var rng := RandomNumberGenerator.new()\nfunc f() -> void:\n\trng.seed = 5"),
			"with a seed, it does not")
	assert_false(_creates_unseeded_generator("# RandomNumberGenerator.new() en un comentario"),
			"a comment does not count")


func test_server_scripts_exist() -> void:
	var files: PackedStringArray = _list_scripts(SERVER_DIR)
	for required: String in REQUIRED_SERVER_SCRIPTS:
		assert_true(files.has(SERVER_DIR.path_join(required)),
				"%s/%s is missing" % [SERVER_DIR, required])


## scripts/server does not use paths or classes from scripts/client.
func test_server_does_not_depend_on_client() -> void:
	var server_scripts: PackedStringArray = _list_scripts(SERVER_DIR)
	assert_false(server_scripts.is_empty(), "no script was found in %s" % SERVER_DIR)
	var patterns: Array[Array] = [["scripts/client", "scripts/client"]]
	patterns.append_array(_class_patterns(CLIENT_DIR))
	if not _list_scripts(CLIENT_DIR).is_empty():
		assert_true(patterns.size() > 1, "the scripts in %s declare class_name" % CLIENT_DIR)
	for path: String in server_scripts:
		for found: String in _find_matches(_read_text(path), patterns):
			fail("%s depends on the client: %s" % [path, found])


## scripts/client does not use paths or classes from scripts/server.
func test_client_does_not_depend_on_server() -> void:
	var client_scripts: PackedStringArray = _list_scripts(CLIENT_DIR)
	assert_false(client_scripts.is_empty(), "no script was found in %s" % CLIENT_DIR)
	var patterns: Array[Array] = [["scripts/server", "scripts/server"]]
	var server_patterns: Array[Array] = _class_patterns(SERVER_DIR)
	assert_false(server_patterns.is_empty(), "the scripts in %s declare class_name" % SERVER_DIR)
	patterns.append_array(server_patterns)
	for path: String in client_scripts:
		for found: String in _find_matches(_read_text(path), patterns):
			fail("%s depends on the server: %s" % [path, found])


## scripts/shared (and scripts/world, which the server also loads) do not use paths or classes from
## scripts/server: shared code cannot depend on whoever uses it.
func test_shared_does_not_depend_on_server() -> void:
	var patterns: Array[Array] = [["scripts/server", "scripts/server"]]
	var server_patterns: Array[Array] = _class_patterns(SERVER_DIR)
	assert_false(server_patterns.is_empty(), "the scripts in %s declare class_name" % SERVER_DIR)
	patterns.append_array(server_patterns)
	var files: PackedStringArray = _list_server_scripts()
	assert_false(files.is_empty(), "no script was found in %s" % [SERVER_DIRS])
	for path: String in files:
		for found: String in _find_matches(_read_text(path), patterns):
			fail("%s depends on the server: %s" % [path, found])


## The dedicated server does not load audio (ART-10): neither the scripts in [code]scripts/client/audio/[/code]
## nor [ClientServices] (which mounts them) appear in what the server loads (shared, world,
## server and the boot scripts), no zone or server scene depends on them or on
## [code]assets/audio/[/code], and the project declares no client autoloads (the server would load them).
## They are mounted by the client scene ([code]client_main.tscn[/code], [code]online_main.tscn[/code]).
func test_server_does_not_load_audio() -> void:
	var audio_scripts: PackedStringArray = _list_scripts(AUDIO_DIR)
	assert_true(audio_scripts.size() >= 2, "there are audio scripts to check")
	assert_true(audio_scripts.has(AUDIO_DIR.path_join("audio_director.gd")), "AudioDirector exists")
	assert_true(FileAccess.file_exists(CLIENT_SERVICES_SCRIPT), "ClientServices exists")
	var patterns: Array[Array] = [
		["scripts/client/audio", "scripts/client/audio"],
		["client_services", "client_services"],
		["ClientServices", "\\bClientServices\\b"],
	]
	patterns.append_array(_class_patterns(AUDIO_DIR))
	assert_true(patterns.size() >= 5, "the audio classes are known")
	var checked: PackedStringArray = _list_server_scripts()
	checked.append_array(_list_scripts(SERVER_DIR))
	checked.append_array(PackedStringArray(BOOT_SCRIPTS))
	for path: String in checked:
		for found: String in _find_matches(_read_text(path), patterns):
			fail("%s names the client audio: %s" % [path, found])
	# The analyzer detects a real use.
	assert_false(_find_matches("var director: AudioDirector = null", patterns).is_empty(),
			"detects an audio class")
	# The scenes the server loads do not depend on audio (the zone ones and the server ones already
	# forbid all of scripts/client/ and assets/audio/ in ZONE_FORBIDDEN_DEPENDENCIES).
	var synthetic: Dictionary = {"res://scripts/client/audio/audio_director.gd": true,
			"res://assets/audio/sfx/golpe.ogg": true}
	assert_eq(_forbidden_dependencies(synthetic).size(), 2, "the filter detects the audio")
	for scene_path: String in SERVER_SCENES:
		var visited: Dictionary = {}
		_collect_dependencies(scene_path, visited)
		assert_false(visited.has(CLIENT_SERVICES_SCRIPT), "%s does not mount the services" % scene_path)
	# No client autoloads in the project.
	var project: String = _read_text("res://project.godot")
	assert_false(project.contains("scripts/client"), "project.godot names no client scripts")
	assert_false(project.contains("[autoload]"), "and declares no autoloads (the server would load them)")
	# And the client scene does mount them.
	for scene_path: String in ["res://scenes/client/client_main.tscn",
			"res://scenes/client/online_main.tscn"]:
		var deps: Dictionary = {}
		_collect_dependencies(scene_path, deps)
		assert_true(deps.has(CLIENT_SERVICES_SCRIPT), "%s mounts ClientServices" % scene_path)


## Check in a separate process, the real one: the dedicated server's boot (the main scene
## with [code]--server[/code]) neither compiles nor loads any script from [code]scripts/client/[/code].
## [code]boot.gd[/code] is also run by the server, and every class reference it contains drags in
## that class's script and, in a chain, everything it names: naming [ClientMain] or [OnlineMain] loaded
## 56 of the client's 69 scripts (the UI, the settings, the audio buses script...) into the
## server, and a syntax error in any of them would have taken it down. That is why [code]boot.gd[/code]
## reaches the client modes through the path of a scene ([code]client_launcher.tscn[/code]), which is only
## loaded when it is not the server, and names no client class.
func test_the_dedicated_server_boot_loads_no_client_script() -> void:
	# Static analysis: boot.gd names no classes from scripts/client (a scene's path is fine).
	var client_patterns: Array[Array] = _class_patterns(CLIENT_DIR)
	assert_true(client_patterns.size() > 40, "the client classes are known (%d)" % client_patterns.size())
	for path: String in BOOT_SCRIPTS:
		for found: String in _find_matches(_read_text(path), client_patterns):
			fail("%s names a client class: %s" % [path, found])
	assert_false(_find_matches("OnlineMain.config = config", client_patterns).is_empty(),
			"the analysis detects a client class")
	# The main scene does not pull in client scripts or scenes either (the launcher goes by path).
	var boot_dependencies: Dictionary = {}
	_collect_dependencies("res://scenes/boot.tscn", boot_dependencies)
	assert_true(boot_dependencies.has("res://scripts/boot.gd"), "the main scene uses boot.gd")
	assert_eq(_forbidden_dependencies(boot_dependencies), PackedStringArray(),
			"the main scene does not depend on the client")
	# The real process: it starts like the project, with --server, and looks at what has loaded.
	var control_path: String = AUDIO_DIR.path_join("audio_buses.gd")
	var port: int = NetHarness.free_udp_port()
	var args: PackedStringArray = PackedStringArray(["--headless", "--path",
			ProjectSettings.globalize_path("res://"), "-s", "res://tests/probe_server_boot.gd",
			"--", "--server", "--zone=test_world", "--port=%d" % port, "--quit-after-ticks=3000",
			"--fake-players=2", "--probe-control=%s" % control_path])
	var output: Array = []
	var code: int = OS.execute(OS.get_executable_path(), args, output, true)
	var text: String = String(output[0]) if not output.is_empty() else ""
	assert_eq(code, 0, "the server starts in the helper process: %s" % text.right(600))
	var loaded: PackedStringArray = PackedStringArray()
	var total: int = -1
	var control_cached: bool = false
	for line: String in text.split("\n"):
		var parts: PackedStringArray = line.strip_edges().split(" ")
		if parts.size() == 2 and parts[0] == "LOADED":
			loaded.append(parts[1])
		elif parts.size() == 3 and parts[0] == "DONE":
			total = parts[1].trim_prefix("total=").to_int()
		elif parts.size() == 3 and parts[0] == "CONTROL" and parts[1] == control_path:
			control_cached = parts[2] == "true"
	assert_true(total > 60, "the helper process reviewed the client scripts (%d)" % total)
	assert_true(control_cached,
			"control: loading a client script on purpose does leave it in the cache (otherwise the test proves nothing)")
	assert_eq(loaded, PackedStringArray(),
			"the dedicated server must not load scripts from scripts/client/ (it loaded %d of %d)" % [loaded.size(), total])


## If zones.gd changes (the group or the metadata of the spawn points, a signature...), only
## NetZones and the few files of the exception are touched; not SpawnPicker or anything in the network.
func test_only_net_zones_talks_to_zones_in_the_network_code() -> void:
	assert_eq(_find_matches("var p: Array = Zones.get_spawn_points(_world)\nZones.SPAWN_GROUP", ZONES_PATTERN).size(), 2,
			"detects the calls to Zones")
	assert_eq(_find_matches("NetZones.scene_path(id)\nMyZones.x\n# Zones.x en un comentario", ZONES_PATTERN),
			PackedStringArray(), "but not NetZones, other names or comments")
	var checked: int = 0
	for dir: String in ZONES_CONTACT_DIRS:
		for path: String in _list_scripts(dir):
			if ZONES_CONTACT_EXCEPTIONS.has(path):
				continue
			checked += 1
			for found: String in _find_matches(_read_text(path), ZONES_PATTERN):
				fail("%s names Zones (%s); the network talks to zones.gd only through NetZones" % [path, found])
	assert_true(checked > 20, "the network scripts are reviewed (%d)" % checked)
	for excepted: String in ZONES_CONTACT_EXCEPTIONS:
		assert_true(FileAccess.file_exists(excepted), "the exception %s exists" % excepted)


## Shared progression names no Time, OS or Input (nor scripts/client or scripts/server, which the
## scripts/shared tests already check), and the server's does not read the time (progresion.md §14.2).
func test_progression_does_not_read_clock_os_or_input() -> void:
	var shared_scripts: PackedStringArray = _list_scripts(PROGRESSION_SHARED_DIR)
	assert_true(shared_scripts.has(PROGRESSION_SHARED_DIR.path_join("character_appearance.gd")),
			"the scripts in %s are reviewed (%d)" % [PROGRESSION_SHARED_DIR, shared_scripts.size()])
	for path: String in shared_scripts:
		for found: String in _find_matches(_read_text(path), PROGRESSION_SHARED_FORBIDDEN):
			fail("%s uses %s; shared progression does not see the time, the system or the input" % [path, found])
	for path: String in _list_scripts(PROGRESSION_SERVER_DIR):
		for found: String in _find_matches(_read_text(path), PROGRESSION_SERVER_FORBIDDEN):
			fail("%s uses %s; the progression time is ZonePlatform.now_unix()" % [path, found])
	assert_eq(_find_matches("var t: int = Time.get_unix_time_from_system()\nvar a: Array = OS.get_cmdline_args()",
			PROGRESSION_SHARED_FORBIDDEN).size(), 2, "the analysis detects Time and OS")
	assert_eq(_find_matches("var ostime: int = TimeLike.x # Time.now() en un comentario", PROGRESSION_SHARED_FORBIDDEN),
			PackedStringArray(), "but not other names or comments")


## No resource in data/characters/ or data/items/ (nor the curve) has texture, scene or
## mesh properties, neither declared nor with a value, also in their subresources (progresion.md §2.1 and §14.2).
func test_progression_data_holds_no_assets() -> void:
	var checked: int = 0
	for dir: String in ASSET_FREE_DATA_DIRS:
		for path: String in _list_files(dir, "tres"):
			checked += 1
			var text: String = _read_text(path)
			for asset_class: String in ASSET_CLASSES:
				assert_false(text.contains("type=\"%s\"" % asset_class), "%s links a %s" % [path, asset_class])
			var resource: Resource = ResourceLoader.load(path)
			assert_not_null(resource, "%s loads" % path)
			for violation: String in _asset_properties(resource, {}):
				fail("%s: %s" % [path, violation])
	assert_true(checked >= 5, "the catalog, the races and the curve are reviewed (%d)" % checked)
	var probe := Resource.new()
	probe.set_meta(&"icon", PlaceholderTexture2D.new())
	assert_false(_asset_properties(probe, {}).is_empty(), "the analysis detects a texture with a value")


## No class_name is repeated in scripts/, tests/, tools/ or addons/: Godot registers only one of the two
## without warning (progresion.md §14.2).
func test_class_names_are_unique() -> void:
	var owners: Dictionary[String, String] = {}
	for dir: String in CLASS_NAME_DIRS:
		for path: String in _list_scripts(dir):
			for declared: String in _extract_class_names(_read_text(path)):
				if owners.has(declared):
					fail("class_name %s is in %s and in %s" % [declared, owners[declared], path])
				else:
					owners[declared] = path
	assert_true(owners.size() > 100, "the project's class_names are reviewed (%d)" % owners.size())
	assert_true(owners.has("CharacterAppearance") and owners.has("TestCase"), "also those in tests/")


func test_dependency_scanner_detects_cross_references() -> void:
	# Checks the dependency analyzer between folders with synthetic text.
	var server_patterns: Array[Array] = [["scripts/server", "scripts/server"]]
	server_patterns.append_array(_class_patterns(SERVER_DIR))
	var offending: Array[String] = [
		"const Queue = preload(\"res://scripts/server/input_queue.gd\")",
		"var queue: InputQueue = InputQueue.new()",
		"func f(peer: ServerPeer) -> void:",
		"var builder := SnapshotBuilder.new(null)",
	]
	for line: String in offending:
		assert_false(_find_matches(line, server_patterns).is_empty(), "must detect: %s" % line)
	var harmless: String = "\n".join([
		"# usa InputQueue y scripts/server solo en un comentario",
		"## Documentación sobre SnapshotBuilder.",
		"var my_input_queue_size: int = 0",
		"var text: String = \"#\" # StateHistory tras un # dentro de una cadena",
		"var name_of_peer: String = \"ServerPeerless\"",
	])
	assert_eq(_find_matches(harmless, server_patterns), PackedStringArray(),
			"comments, documentation and similar identifiers are not dependencies")
	var client_patterns: Array[Array] = [["scripts/client", "scripts/client"]]
	client_patterns.append_array(_class_patterns(CLIENT_DIR))
	assert_false(_find_matches("var rig: CameraRig", client_patterns).is_empty(),
			"and the opposite direction detects the client classes")


# --- Utilities -------------------------------------------------------------------------------

## Scripts from all the folders in [constant SERVER_DIRS].
func _list_server_scripts() -> PackedStringArray:
	var files: PackedStringArray = PackedStringArray()
	for dir: String in SERVER_DIRS:
		files.append_array(_list_scripts(dir))
	return files


## Patterns [description, regex] of the classes ([code]class_name[/code]) of the scripts in
## [param dir].
func _class_patterns(dir: String) -> Array[Array]:
	var patterns: Array[Array] = []
	for path: String in _list_scripts(dir):
		for declared: String in _extract_class_names(_read_text(path)):
			patterns.append([declared, "\\b%s\\b" % declared])
	return patterns


## res:// paths that [param path] depends on, recursively (in [param visited]).
func _collect_dependencies(path: String, visited: Dictionary) -> void:
	if visited.has(path):
		return
	visited[path] = true
	for dependency: String in ResourceLoader.get_dependencies(path):
		# Format "uid://...::Type::res://path" (or just the path).
		var dep_path: String = dependency.get_slice("::", 2) if dependency.contains("::") else dependency
		if dep_path.begins_with("uid://"):
			dep_path = ResourceUID.get_id_path(ResourceUID.text_to_id(dep_path))
		if dep_path.begins_with("res://"):
			_collect_dependencies(dep_path, visited)


## Dependencies in [param visited] ([method _collect_dependencies]) that start with any path in
## [constant ZONE_FORBIDDEN_DEPENDENCIES], with the rule they violate.
func _forbidden_dependencies(visited: Dictionary) -> PackedStringArray:
	var violations := PackedStringArray()
	for path: String in visited:
		for forbidden: String in ZONE_FORBIDDEN_DEPENDENCIES:
			if path.begins_with(forbidden):
				violations.append("%s (prohibido: %s)" % [path, forbidden])
	return violations


## true if [param text] creates a [RandomNumberGenerator] and assigns it no seed.
func _creates_unseeded_generator(text: String) -> bool:
	var code: String = _strip_comments(text)
	if not code.contains("RandomNumberGenerator.new("):
		return false
	var seeded := RegEx.new()
	seeded.compile("\\.seed\\s*=|\\.set_seed\\s*\\(")
	return seeded.search(code) == null


## Files with extension [param extension] under [param dir], recursively, sorted (empty if the
## folder does not exist; in an exported project, without the [code].remap[/code]).
func _list_files(dir: String, extension: String) -> PackedStringArray:
	var result: PackedStringArray = PackedStringArray()
	if not DirAccess.dir_exists_absolute(dir):
		return result
	for file_name: String in DirAccess.get_files_at(dir):
		var clean: String = file_name.trim_suffix(".remap")
		if clean.get_extension() == extension and not result.has(dir.path_join(clean)):
			result.append(dir.path_join(clean))
	for sub_dir: String in DirAccess.get_directories_at(dir):
		result.append_array(_list_files(dir.path_join(sub_dir), extension))
	result.sort()
	return result


## Properties of [param resource] (and of its subresources and arrays, recursively) that are or declare a
## texture, a scene or a mesh.
func _asset_properties(resource: Object, visited: Dictionary) -> PackedStringArray:
	var violations := PackedStringArray()
	if resource == null or visited.has(resource.get_instance_id()):
		return violations
	visited[resource.get_instance_id()] = true
	var values: Array = []
	for property: Dictionary in resource.get_property_list():
		if not (property["usage"] & PROPERTY_USAGE_STORAGE):
			continue
		var declared: String = "%s %s" % [property["class_name"], property["hint_string"]]
		for asset_class: String in ASSET_CLASSES:
			if RegEx.create_from_string("\\b%s\\b" % asset_class).search(declared) != null:
				violations.append("%s se declara como %s" % [property["name"], asset_class])
		values.append(resource.get(property["name"]))
	for meta: StringName in resource.get_meta_list():
		values.append(resource.get_meta(meta))
	while not values.is_empty():
		var value: Variant = values.pop_back()
		if value is Array:
			values.append_array(value)
		elif value is Dictionary:
			values.append_array((value as Dictionary).values())
		elif value is Texture or value is PackedScene or value is Mesh:
			violations.append("tiene un %s" % (value as Object).get_class())
		elif value is Resource and not (value is Script):
			violations.append_array(_asset_properties(value, visited))
	return violations


## .gd scripts under [param dir], recursively, sorted.
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


## Descriptions of the patterns in [param patterns] ([description, regex]) that appear in
## [param text] outside comments, with the line number.
func _find_matches(text: String, patterns: Array) -> PackedStringArray:
	var code: String = _strip_comments(text)
	var found: PackedStringArray = PackedStringArray()
	for pattern: Array in patterns:
		var regex := RegEx.new()
		if regex.compile(pattern[1]) != OK:
			fail("invalid regular expression: %s" % pattern[1])
			continue
		for result: RegExMatch in regex.search_all(code):
			var line_number: int = code.substr(0, result.get_start()).count("\n") + 1
			found.append("%s (línea %d)" % [pattern[0], line_number])
	return found


## Names declared with class_name in [param text].
static func _extract_class_names(text: String) -> PackedStringArray:
	var names: PackedStringArray = PackedStringArray()
	var regex := RegEx.new()
	regex.compile(CLASS_NAME_PATTERN)
	for result: RegExMatch in regex.search_all(_strip_comments(text)):
		names.append(result.get_string(1))
	return names


## Text without comments.
static func _strip_comments(text: String) -> String:
	var lines: PackedStringArray = PackedStringArray()
	for line: String in text.split("\n"):
		lines.append(_strip_comment(line))
	return "\n".join(lines)


## Strips the comment from a line while respecting strings ("..." and '...').
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
