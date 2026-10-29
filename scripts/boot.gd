extends Node
## Escena de arranque (escena principal del proyecto).
##
## Lee los argumentos de usuario de la línea de comandos (los que van después
## de [code]--[/code]) y decide en qué modo arranca el juego:
## [br]- [code]--server[/code]: servidor dedicado de una zona ([ServerMain], siempre con
## [code]--headless[/code]; opciones en [ServerConfig]). Tiene prioridad sobre el resto.
## [br]- Cualquier otro caso es un modo de cliente y lo resuelve [code]ClientLauncher[/code]
## (escena [constant CLIENT_LAUNCHER_SCENE]), que este script instancia por su ruta:
## [br]    - [code]--bots=N[/code]: enjambre de N clientes ligeros para pruebas de carga.
## Tiene prioridad sobre el resto de modos de cliente.
## [br]    - [code]--connect=<host>[:<puerto>][/code] o [code]--bot[/code]: cliente en red (ver
## [code]ClientConfig[/code]). Tiene prioridad sobre el sandbox.
## [br]    - [code]--local[/code]: cliente en red contra un servidor local que se lanza solo si no
## hay ninguno ([code]LocalServerLauncher[/code]).
## [br]    - Sin nada de lo anterior, el sandbox sin red ([code]ClientMain[/code]; también en modo
## headless), con las opciones de [method parse_client_options]:
## [br]        - [code]--zone=<id>[/code]: zona que se carga ([code]vado_gris[/code] por defecto,
## [code]test_world[/code] para el circuito de la fase 1). Ver [Zones].
## [br]        - [code]--realm=<reino>[/code]: reino del jugador ([code]vardheim[/code] por defecto o
## [code]solmarch[/code]); decide en qué punto de aparición de la zona se empieza.
## [br]        - [code]--demo[/code]: entrada guionizada.
## [br]        - [code]--shots=<carpeta absoluta>[/code]: durante la demo, guarda una captura
## PNG cada 90 ticks en esa carpeta ([code]shot_000.png[/code], ...) y, al terminar, una desde
## cada cámara de revisión de la zona ([code]zona_<nombre>.png[/code]).
## [br]        - [code]--quit-after-demo[/code]: cierra el juego cuando termina la demo.
## [br]Sin argumentos (también en modo headless) arranca el cliente en el Vado Gris.
## [br][br]
## [b]Este script no nombra ninguna clase de [code]scripts/client/[/code][/b]: el servidor dedicado
## ejecuta también la escena principal, y cada referencia de clase que contenga arrastra el script de
## esa clase y, en cadena, la interfaz, los ajustes y el audio. Lo comprueba
## [code]tests/test_architecture.gd[/code] con un proceso de verdad arrancado con [code]--server[/code].
## [br][br]Ejemplo:
## [code]godot --path . -- --zone=vado_gris --realm=solmarch --demo --shots=C:/ruta/capturas --quit-after-demo[/code]

const SERVER_MAIN_SCENE: String = "res://scenes/server/server_main.tscn"
## Escena del nodo que elige el modo de cliente (ver [code]ClientLauncher[/code]). Solo se carga si no es
## el servidor.
const CLIENT_LAUNCHER_SCENE: String = "res://scenes/client/client_launcher.tscn"
## Metadato del nodo del cliente con la función que interpreta los argumentos del sandbox. Es el mismo
## nombre que [code]ClientLauncher.PARSER_META[/code]; lo comprueba [code]tests/test_client_launcher.gd[/code].
const CLIENT_PARSER_META: StringName = &"client_options_parser"
const SERVER_ARG: String = "--server"
const DEMO_ARG: String = "--demo"
const SHOTS_ARG_PREFIX: String = "--shots="
const QUIT_AFTER_DEMO_ARG: String = "--quit-after-demo"
const ZONE_ARG_PREFIX: String = "--zone="
const REALM_ARG_PREFIX: String = "--realm="
## Argumentos de los modos en red (docs/red.md, sección 1.2) que el sandbox ignora sin avisar: los
## interpretan [ServerConfig] y los modos de cliente en red, no [method parse_client_options].
const NETWORK_ARGS: Array[String] = ["--local", "--bot"]
const NETWORK_ARG_PREFIXES: Array[String] = [
	"--connect=", "--bots=", "--name=", "--port=", "--net-sim=", "--quit-after-ticks=",
	"--report=", "--state-log=", "--bot-seed=", "--bot-cheat=", "--bot-brain=",
]


func _ready() -> void:
	var args: PackedStringArray = OS.get_cmdline_user_args()
	if args.has(SERVER_ARG):
		_start_server(args)
		return
	_start_client()


## Interpreta los argumentos de usuario del cliente. Devuelve un diccionario con
## [code]zone[/code] y [code]realm[/code] ([StringName]), [code]demo[/code] y
## [code]quit_after_demo[/code] ([bool]), [code]shots_dir[/code] ([String]) y
## [code]warnings[/code] ([PackedStringArray], avisos para el usuario). Una zona o un reino
## desconocidos se sustituyen por los de por defecto, con aviso.
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


## true si [param arg] es un argumento de los modos en red (ver [constant NETWORK_ARGS]).
static func _is_network_arg(arg: String) -> bool:
	if NETWORK_ARGS.has(arg):
		return true
	for prefix: String in NETWORK_ARG_PREFIXES:
		if arg.begins_with(prefix):
			return true
	return false


## Rellena [member ServerMain.config] con los argumentos de usuario y cambia a la escena del
## servidor dedicado.
func _start_server(args: PackedStringArray) -> void:
	ServerMain.config = ServerConfig.from_args(args)
	get_tree().change_scene_to_file.call_deferred(SERVER_MAIN_SCENE)


## Monta el nodo que elige el modo de cliente (enjambre, red o sandbox) a partir de los argumentos de
## usuario, por la ruta de su escena: el servidor dedicado no llega aquí y nunca la carga. Le deja en
## un metadato [constant CLIENT_PARSER_META] la función [method parse_client_options].
func _start_client() -> void:
	var packed: PackedScene = load(CLIENT_LAUNCHER_SCENE) as PackedScene
	if packed == null:
		push_error("[Eldmark] No se pudo cargar la escena del cliente (%s)" % CLIENT_LAUNCHER_SCENE)
		get_tree().quit(1)
		return
	var launcher: Node = packed.instantiate()
	launcher.set_meta(CLIENT_PARSER_META, parse_client_options)
	add_child(launcher)


## Valor de una opción sin espacios ni comillas alrededor, en minúsculas.
static func _clean_value(value: String) -> String:
	return value.strip_edges().trim_prefix("\"").trim_suffix("\"").to_lower()


## Ruta de una opción sin espacios ni comillas alrededor y con barras normales.
static func _clean_path(value: String) -> String:
	return value.strip_edges().trim_prefix("\"").trim_suffix("\"").replace("\\", "/")
