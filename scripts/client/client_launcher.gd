class_name ClientLauncher
extends Node
## Elige el modo de arranque del cliente (docs/red.md, sección 1.2) y cambia a su escena.
## [br][br]
## Es la mitad del arranque que [code]boot.gd[/code] no puede tener: la escena principal la ejecuta
## también el servidor dedicado, y cada referencia de clase que contiene arrastra el script de esa
## clase (y, en cadena, la interfaz, los ajustes, el audio...), de modo que un servidor cargaba 56 de los
## 69 scripts del cliente. Por eso [code]boot.gd[/code] solo conoce la ruta de la escena de este nodo
## ([code]scenes/client/client_launcher.tscn[/code]) y la instancia cuando [b]no[/b] es el servidor;
## aquí sí se nombran [ClientConfig], [OnlineMain], [BotSwarm] y [ClientMain].
## [br][br]
## Prioridad de los modos: [code]--bots=N[/code] (enjambre, [BotSwarm]) >
## [code]--connect[/code] / [code]--bot[/code] / [code]--local[/code] (cliente en red, [OnlineMain];
## [code]--local[/code] lanza antes un servidor local si no hay ninguno, ver [LocalServerLauncher]) >
## [code]--title[/code] / [code]--platform[/code] (título con cuenta, [FrontMain]; docs/plataforma.md §5.5) >
## sin argumentos: el título en una exportación y, desde el editor, el
## sandbox sin red ([ClientMain], con [code]--zone[/code], [code]--realm[/code], [code]--demo[/code],
## [code]--shots[/code] y [code]--quit-after-demo[/code]). Los argumentos del sandbox los interpreta la
## función que pasa [code]boot.gd[/code] en el metadato [constant PARSER_META] (la misma de siempre,
## [code]Boot.parse_client_options[/code]), para que este script no dependa del de arranque.

## Metadato con el [Callable] que interpreta los argumentos del sandbox (recibe los argumentos de
## usuario y devuelve un diccionario con [code]zone[/code], [code]realm[/code], [code]demo[/code],
## [code]quit_after_demo[/code], [code]shots_dir[/code] y [code]warnings[/code]).
const PARSER_META: StringName = &"client_options_parser"
const CLIENT_MAIN_SCENE: String = "res://scenes/client/client_main.tscn"
const ONLINE_MAIN_SCENE: String = "res://scenes/client/online_main.tscn"
## Escena del enjambre de clientes ligeros ([code]--bots=N[/code]).
const SWARM_SCENE: String = "res://scenes/client/bot_swarm.tscn"
## Escena del título con cuenta ([code]--title[/code], [code]--platform[/code] o una exportación sin argumentos).
const FRONT_MAIN_SCENE: String = "res://scenes/client/front_main.tscn"


func _ready() -> void:
	var args: PackedStringArray = OS.get_cmdline_user_args()
	# Prioridad de la sección 1.2 y de docs/plataforma.md §13.3: --bots > --bot > --connect/--local >
	# --title/--platform > sandbox (en el editor) o título (en una exportación).
	var config: ClientConfig = ClientConfig.from_args(args, not OS.has_feature("editor"))
	match config.mode:
		ClientConfig.Mode.SWARM:
			BotSwarm.config = config
			_change_scene(SWARM_SCENE)
		ClientConfig.Mode.ONLINE, ClientConfig.Mode.BOT, ClientConfig.Mode.LOCAL:
			# --local: OnlineMain primero reutiliza o lanza el servidor local (LocalServerLauncher,
			# docs/red.md 1.4) y apunta el cliente a su puerto.
			OnlineMain.config = config
			_change_scene(ONLINE_MAIN_SCENE)
		ClientConfig.Mode.TITLE:
			FrontMain.config = config
			_change_scene(FRONT_MAIN_SCENE)
		_:
			_start_sandbox(args)


## Pasa las opciones a [ClientMain] mediante sus variables estáticas y cambia a la escena del
## sandbox del cliente (sin red).
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


# Interpreta los argumentos del sandbox con la función que dejó boot.gd; sin ella (esta escena abierta
# por su cuenta) se usan las opciones por defecto.
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
