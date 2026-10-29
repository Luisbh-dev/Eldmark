extends Node
## Escena de arranque (escena principal del proyecto).
##
## Lee los argumentos de usuario de la línea de comandos (los que van después
## de [code]--[/code]) y decide en qué modo arranca el juego:
## [br]- [code]--server[/code]: servidor dedicado de una zona ([ServerMain], siempre con
## [code]--headless[/code]; opciones en [ServerConfig]). Tiene prioridad sobre el resto.
## [br]- [code]--connect=<host>[:<puerto>][/code] o [code]--bot[/code]: cliente en red
## ([OnlineMain], ver [ClientConfig]). Tiene prioridad sobre el sandbox. [code]--bots=N[/code]
## todavía no existe: avisa y cierra con código 1.
## [br]- [code]--local[/code]: cliente en red contra un servidor local que se lanza solo si no hay
## ninguno ([LocalServerLauncher]); ver [method _start_local].
## [br]- [code]--zone=<id>[/code]: zona que se carga ([code]vado_gris[/code] por defecto,
## [code]test_world[/code] para el circuito de la fase 1). Ver [Zones].
## [br]- [code]--realm=<reino>[/code]: reino del jugador ([code]vardheim[/code] por defecto o
## [code]solmarch[/code]); decide en qué punto de aparición de la zona se empieza.
## [br]- [code]--demo[/code]: sandbox del cliente con entrada guionizada ([DemoInput]).
## [br]- [code]--shots=<carpeta absoluta>[/code]: durante la demo, guarda una captura
## PNG cada 90 ticks en esa carpeta ([code]shot_000.png[/code], ...) y, al terminar, una desde
## cada cámara de revisión de la zona ([code]zona_<nombre>.png[/code]).
## [br]- [code]--quit-after-demo[/code]: cierra el juego cuando termina la demo.
## [br]Sin argumentos (también en modo headless) arranca el cliente en el Vado Gris.
## [br][br]Ejemplo:
## [code]godot --path . -- --zone=vado_gris --realm=solmarch --demo --shots=C:/ruta/capturas --quit-after-demo[/code]

const CLIENT_MAIN_SCENE: String = "res://scenes/client/client_main.tscn"
const SERVER_MAIN_SCENE: String = "res://scenes/server/server_main.tscn"
const ONLINE_MAIN_SCENE: String = "res://scenes/client/online_main.tscn"
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
	"--report=", "--state-log=", "--bot-seed=", "--bot-cheat=",
]


func _ready() -> void:
	var args: PackedStringArray = OS.get_cmdline_user_args()
	if args.has(SERVER_ARG):
		_start_server(args)
		return
	# Prioridad de la sección 1.2: --server > --bots > --connect/--local/--bot > sandbox.
	var config: ClientConfig = ClientConfig.from_args(args)
	if config.mode == ClientConfig.Mode.SWARM:
		_start_swarm(config)
		return
	match config.mode:
		ClientConfig.Mode.ONLINE, ClientConfig.Mode.BOT:
			_start_online(config)
		ClientConfig.Mode.LOCAL:
			_start_local(config)
		ClientConfig.Mode.SWARM:
			_reject_unavailable_mode(config)
		_:
			_start_client(args)


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


## Rellena [member OnlineMain.config] y cambia a la escena del cliente en red.
func _start_online(config: ClientConfig) -> void:
	OnlineMain.config = config
	get_tree().change_scene_to_file.call_deferred(ONLINE_MAIN_SCENE)


## [code]--local[/code] (servidor local que se lanza solo) y [code]--bots=N[/code] (enjambre de
## clientes ligeros) todavía no están implementados (TEC-45 y TEC-11). En lugar de arrancar el
## sandbox en silencio con unos argumentos que pedían otra cosa, avisa y cierra con código 1.
func _reject_unavailable_mode(config: ClientConfig) -> void:
	var option: String = "--local" if config.mode == ClientConfig.Mode.LOCAL else "--bots"
	push_error("[Eldmark] %s todavía no está disponible. Usa --connect=<host>[:<puerto>] contra un "
			% option + "servidor ya arrancado (--server), o --bot --connect=...")
	get_tree().quit(1)


## [code]--local[/code]: igual que un cliente en red, pero [OnlineMain] primero reutiliza o lanza el
## servidor local ([LocalServerLauncher], docs/red.md 1.4) y apunta el cliente a su puerto.
func _start_local(config: ClientConfig) -> void:
	_start_online(config)


## Pasa las opciones a [ClientMain] mediante sus variables estáticas y cambia
## a la escena del cliente.
func _start_client(args: PackedStringArray) -> void:
	var options: Dictionary = parse_client_options(args)
	for warning: String in options["warnings"]:
		push_warning("[Eldmark] %s" % warning)

	if DisplayServer.get_name() == "headless":
		print("[Eldmark] Sin pantalla (headless): arrancando el cliente")

	ClientMain.zone_id = options["zone"]
	ClientMain.realm = options["realm"]
	ClientMain.demo_mode = options["demo"]
	ClientMain.shots_dir = options["shots_dir"]
	ClientMain.quit_after_demo = options["quit_after_demo"]
	get_tree().change_scene_to_file.call_deferred(CLIENT_MAIN_SCENE)


## Valor de una opción sin espacios ni comillas alrededor, en minúsculas.
static func _clean_value(value: String) -> String:
	return value.strip_edges().trim_prefix("\"").trim_suffix("\"").to_lower()


## Ruta de una opción sin espacios ni comillas alrededor y con barras normales.
static func _clean_path(value: String) -> String:
	return value.strip_edges().trim_prefix("\"").trim_suffix("\"").replace("\\", "/")


# --- Enjambre de bots (TEC-11) ----------------------------------------------------------------

## Escena del enjambre de clientes ligeros ([code]--bots=N[/code]).
const SWARM_SCENE: String = "res://scenes/client/bot_swarm.tscn"


## Rellena [member BotSwarm.config] y cambia a la escena del enjambre de bots ([BotSwarm]).
func _start_swarm(config: ClientConfig) -> void:
	BotSwarm.config = config
	get_tree().change_scene_to_file.call_deferred(SWARM_SCENE)
