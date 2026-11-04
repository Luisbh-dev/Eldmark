extends Node
## Boot scene (the project's main scene).
##
## Reads the command-line user arguments (those after [code]--[/code]) and decides which mode the
## game starts in:
## [br]- [code]--server[/code]: dedicated server for a zone ([ServerMain], always with
## [code]--headless[/code]; options in [ServerConfig]). It takes priority over the rest.
## [br]- Any other case is a client mode and is resolved by [code]ClientLauncher[/code]
## (scene [constant CLIENT_LAUNCHER_SCENE]), which this script instantiates by its path:
## [br]    - [code]--bots=N[/code]: swarm of N lightweight clients for load testing.
## It takes priority over the other client modes.
## [br]    - [code]--connect=<host>[:<puerto>][/code] or [code]--bot[/code]: networked client (see
## [code]ClientConfig[/code]). It takes priority over the sandbox.
## [br]    - [code]--local[/code]: networked client against a local server that is launched on its own if
## there is none ([code]LocalServerLauncher[/code]).
## [br]    - [code]--title[/code] or [code]--platform=<url>[/code]: the title screen with account
## ([code]FrontMain[/code], docs/platform.md §5.5 and §13). An export with no arguments also opens it.
## [br]    - With none of the above, the offline sandbox ([code]ClientMain[/code]; also in headless
## mode), with the options from [method parse_client_options]:
## [br]        - [code]--zone=<id>[/code]: zone to load ([code]vado_gris[/code] by default,
## [code]test_world[/code] for the phase 1 course). See [Zones].
## [br]        - [code]--realm=<reino>[/code]: the player's realm ([code]vardheim[/code] by default or
## [code]solmarch[/code]); it decides which spawn point in the zone to start at.
## [br]        - [code]--demo[/code]: scripted entry.
## [br]        - [code]--shots=<carpeta absoluta>[/code]: during the demo, saves a PNG screenshot
## every 90 ticks into that folder ([code]shot_000.png[/code], ...) and, when finished, one from
## each of the zone's review cameras ([code]zona_<nombre>.png[/code]).
## [br]        - [code]--quit-after-demo[/code]: closes the game when the demo ends.
## [br]With no arguments (also in headless mode) it starts the client in Vado Gris.
## [br][br]
## [b]This script names no class from [code]scripts/client/[/code][/b]: the dedicated server also
## runs the main scene, and each class reference it contains drags in that class's script and, in
## a chain, the UI, the settings and the audio. This is checked by
## [code]tests/test_architecture.gd[/code] with a real process started with [code]--server[/code].
## [br][br]Example:
## [code]godot --path . -- --zone=vado_gris --realm=solmarch --demo --shots=C:/ruta/capturas --quit-after-demo[/code]

const SERVER_MAIN_SCENE: String = "res://scenes/server/server_main.tscn"
## Scene of the node that chooses the client mode (see [code]ClientLauncher[/code]). It is only
## loaded if this is not the server.
const CLIENT_LAUNCHER_SCENE: String = "res://scenes/client/client_launcher.tscn"
## Metadata of the client node with the function that interprets the sandbox's arguments. It is
## the same name as [code]ClientLauncher.PARSER_META[/code]; it is checked by [code]tests/test_client_launcher.gd[/code].
const CLIENT_PARSER_META: StringName = &"client_options_parser"
const SERVER_ARG: String = "--server"
const DEMO_ARG: String = "--demo"
const SHOTS_ARG_PREFIX: String = "--shots="
const QUIT_AFTER_DEMO_ARG: String = "--quit-after-demo"
const ZONE_ARG_PREFIX: String = "--zone="
const REALM_ARG_PREFIX: String = "--realm="
## Arguments of the networked modes (docs/networking.md, section 1.2) that the sandbox ignores silently:
## they are interpreted by [ServerConfig] and the networked client modes, not by [method parse_client_options].
const NETWORK_ARGS: Array[String] = ["--local", "--bot", "--title"]
const NETWORK_ARG_PREFIXES: Array[String] = [
	"--connect=", "--bots=", "--name=", "--port=", "--net-sim=", "--quit-after-ticks=",
	"--quit-at-server-tick=", "--report=", "--state-log=", "--bot-seed=", "--bot-cheat=", "--bot-brain=",
	"--loadout=", "--platform=", "--login=", "--password-file=", "--character=", "--world=", "--dtls-cert=",
	"--dtls-name=", "--bot-scenario=",
]


func _ready() -> void:
	var args: PackedStringArray = OS.get_cmdline_user_args()
	if args.has(SERVER_ARG):
		_start_server(args)
		return
	_start_client()


## Interprets the client's user arguments. Returns a dictionary with
## [code]zone[/code] and [code]realm[/code] ([StringName]), [code]demo[/code] and
## [code]quit_after_demo[/code] ([bool]), [code]shots_dir[/code] ([String]) and
## [code]warnings[/code] ([PackedStringArray], warnings for the user). An unknown zone or realm
## is replaced by the default one, with a warning.
static func parse_client_options(args: PackedStringArray) -> Dictionary:
	var options: Dictionary = {
		"zone": Zones.DEFAULT_ZONE,
		"realm": Zones.DEFAULT_REALM,
		"demo": false,
		"shots_dir": "",
		"quit_after_demo": false,
	}
	var warnings: PackedStringArray = PackedStringArray()

	for arg: String in args:
		if arg == DEMO_ARG:
			options["demo"] = true
		elif arg.begins_with(SHOTS_ARG_PREFIX):
			options["shots_dir"] = _clean_path(arg.trim_prefix(SHOTS_ARG_PREFIX))
		elif arg == QUIT_AFTER_DEMO_ARG:
			options["quit_after_demo"] = true
		elif arg.begins_with(ZONE_ARG_PREFIX):
			var zone: StringName = StringName(_clean_value(arg.trim_prefix(ZONE_ARG_PREFIX)))
			if Zones.has_zone(zone):
				options["zone"] = zone
			else:
				warnings.append("Zona desconocida '%s' (hay: %s); se usa %s" % [zone,
						", ".join(Zones.get_zone_ids()), Zones.DEFAULT_ZONE])
		elif arg.begins_with(REALM_ARG_PREFIX):
			var realm: StringName = StringName(_clean_value(arg.trim_prefix(REALM_ARG_PREFIX)))
			if Zones.is_realm(realm):
				options["realm"] = realm
			else:
				warnings.append("Reino desconocido '%s' (hay: %s); se usa %s" % [realm,
						", ".join(Zones.REALMS), Zones.DEFAULT_REALM])
		elif _is_network_arg(arg):
			continue
		else:
			warnings.append("Argumento desconocido: %s" % arg)

	if not options["demo"]:
		var demo_only: String = "%s solo tiene efecto junto con %s"
		if not String(options["shots_dir"]).is_empty():
			warnings.append(demo_only % [SHOTS_ARG_PREFIX, DEMO_ARG])
		if options["quit_after_demo"]:
			warnings.append(demo_only % [QUIT_AFTER_DEMO_ARG, DEMO_ARG])

	options["warnings"] = warnings
	return options


## true if [param arg] is an argument of the networked modes (see [constant NETWORK_ARGS]).
static func _is_network_arg(arg: String) -> bool:
	if NETWORK_ARGS.has(arg):
		return true
	for prefix: String in NETWORK_ARG_PREFIXES:
		if arg.begins_with(prefix):
			return true
	return false


## Fills [member ServerMain.config] with the user arguments and switches to the dedicated server scene.
func _start_server(args: PackedStringArray) -> void:
	ServerMain.config = ServerConfig.from_args(args)
	get_tree().change_scene_to_file.call_deferred(SERVER_MAIN_SCENE)


## Mounts the node that chooses the client mode (swarm, network or sandbox) from the user
## arguments, by its scene path: the dedicated server does not get here and never loads it. It
## leaves the function [method parse_client_options] on it in a [constant CLIENT_PARSER_META] metadata entry.
func _start_client() -> void:
	var packed: PackedScene = load(CLIENT_LAUNCHER_SCENE) as PackedScene
	if packed == null:
		push_error("[Eldmark] No se pudo cargar la escena del cliente (%s)" % CLIENT_LAUNCHER_SCENE)
		get_tree().quit(1)
		return
	var launcher: Node = packed.instantiate()
	launcher.set_meta(CLIENT_PARSER_META, parse_client_options)
	add_child(launcher)


## Value of an option without surrounding spaces or quotes, in lowercase.
static func _clean_value(value: String) -> String:
	return value.strip_edges().trim_prefix("\"").trim_suffix("\"").to_lower()


## Path of an option without surrounding spaces or quotes and with forward slashes.
static func _clean_path(value: String) -> String:
	return value.strip_edges().trim_prefix("\"").trim_suffix("\"").replace("\\", "/")
