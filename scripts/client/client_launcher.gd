class_name ClientLauncher
extends Node
## Chooses the client start-up mode (docs/networking.md, section 1.2) and switches to its scene.
## [br][br]
## It is the half of the start-up that [code]boot.gd[/code] cannot have: the main scene is also run by
## the dedicated server, and each class reference it contains drags in that class's script (and, in
## a chain, the UI, settings, audio...), so a server was loading 56 of the client's 69 scripts. That is
## why [code]boot.gd[/code] only knows the scene path of this node
## ([code]scenes/client/client_launcher.tscn[/code]) and instantiates it when it is [b]not[/b] the
## server; here [ClientConfig], [OnlineMain], [BotSwarm] and [ClientMain] are named.
## [br][br]
## Mode priority: [code]--bots=N[/code] (swarm, [BotSwarm]) >
## [code]--connect[/code] / [code]--bot[/code] / [code]--local[/code] (networked client, [OnlineMain];
## [code]--local[/code] first launches a local server if there is none, see [LocalServerLauncher]) >
## [code]--title[/code] / [code]--platform[/code] (title screen with an account, [FrontMain]; docs/platform.md §5.5) >
## no arguments: the title screen in an export and, from the editor, the offline
## sandbox ([ClientMain], with [code]--zone[/code], [code]--realm[/code], [code]--demo[/code],
## [code]--shots[/code] and [code]--quit-after-demo[/code]). The sandbox arguments are interpreted by the
## function that [code]boot.gd[/code] passes in the [constant PARSER_META] metadata (the same as ever,
## [code]Boot.parse_client_options[/code]), so this script does not depend on the start-up one.

## Metadata with the [Callable] that parses the sandbox arguments (it receives the user arguments and
## returns a dictionary with [code]zone[/code], [code]realm[/code], [code]demo[/code],
## [code]quit_after_demo[/code], [code]shots_dir[/code] and [code]warnings[/code]).
const PARSER_META: StringName = &"client_options_parser"
const CLIENT_MAIN_SCENE: String = "res://scenes/client/client_main.tscn"
const ONLINE_MAIN_SCENE: String = "res://scenes/client/online_main.tscn"
## Scene of the lightweight client swarm ([code]--bots=N[/code]).
const SWARM_SCENE: String = "res://scenes/client/bot_swarm.tscn"
## Scene of the title screen with an account ([code]--title[/code], [code]--platform[/code] or an export with no arguments).
const FRONT_MAIN_SCENE: String = "res://scenes/client/front_main.tscn"


func _ready() -> void:
	var args: PackedStringArray = OS.get_cmdline_user_args()
	# Priority from section 1.2 and docs/platform.md §13.3: --bots > --bot > --connect/--local >
	# --title/--platform > sandbox (in the editor) or title screen (in an export).
	var config: ClientConfig = ClientConfig.from_args(args, not OS.has_feature("editor"))
	match config.mode:
		ClientConfig.Mode.SWARM:
			BotSwarm.config = config
			_change_scene(SWARM_SCENE)
		ClientConfig.Mode.ONLINE, ClientConfig.Mode.BOT, ClientConfig.Mode.LOCAL:
			# --local: OnlineMain first reuses or launches the local server (LocalServerLauncher,
			# docs/networking.md 1.4) and points the client at its port.
			OnlineMain.config = config
			_change_scene(ONLINE_MAIN_SCENE)
		ClientConfig.Mode.TITLE:
			FrontMain.config = config
			_change_scene(FRONT_MAIN_SCENE)
		_:
			_start_sandbox(args)


## Passes the options to [ClientMain] through its static variables and switches to the client's
## (offline) sandbox scene.
func _start_sandbox(args: PackedStringArray) -> void:
	var options: Dictionary = _parse_sandbox_options(args)
	for warning: String in options["warnings"]:
		push_warning("[Eldmark] %s" % warning)
	if DisplayServer.get_name() == "headless":
		print("[Eldmark] Sin pantalla (headless): arrancando el cliente")
	ClientMain.zone_id = options["zone"]
	ClientMain.realm = options["realm"]
	ClientMain.demo_mode = options["demo"]
	ClientMain.shots_dir = options["shots_dir"]
	ClientMain.quit_after_demo = options["quit_after_demo"]
	_change_scene(CLIENT_MAIN_SCENE)


# Parses the sandbox arguments with the function boot.gd left; without it (this scene opened on its
# own) the default options are used.
func _parse_sandbox_options(args: PackedStringArray) -> Dictionary:
	if has_meta(PARSER_META):
		var parser: Callable = get_meta(PARSER_META) as Callable
		if parser.is_valid():
			return parser.call(args) as Dictionary
	return {
		"zone": ClientMain.zone_id, "realm": ClientMain.realm, "demo": false, "shots_dir": "",
		"quit_after_demo": false, "warnings": PackedStringArray(),
	}


func _change_scene(path: String) -> void:
	get_tree().change_scene_to_file.call_deferred(path)
