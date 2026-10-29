class_name ServerConfig
extends RefCounted
## Configuración del servidor dedicado de una zona (docs/red.md, secciones 1.2 y 17.4).
## [br][br]
## Se rellena con [method from_args] a partir de los argumentos de usuario (los que van tras
## [code]--[/code]):
## [codeblock]
## --server --port=24600 --zone=<id> --max-players=64 --max-per-ip=4 --idle-quit=<s>
## --fake-players=N --fake-layout=<cluster|spread> --fake-churn=<ticks> --fake-brain=combat
## --fake-center=<x>,<z>
## --debug-commands --dev-lock --dev-lock-path=<ruta>
## --quit-after-ticks=N --report=<ruta.json> --state-log=<ruta.csv> --net-sim=rtt=120,jitter=20
## --stop-file=<ruta> --combat-log=<ruta.csv> --console --no-dummies
## [/codeblock]
## [code]--combat-log=<ruta>[/code] escribe un CSV con una línea por golpe resuelto
## ([code]tick,atacante,objetivo,ataque,view_tick,rebobinado,resultado,daño[/code]; en el proyecto
## usa otra extensión, p. ej. [code].txt[/code], porque el importador convierte los [code].csv[/code]
## en traducciones). [code]--console[/code] lee comandos de la entrada estándar (anunciar, expulsar,
## cerrar...; ver [CommandRegistry]) y [code]--no-dummies[/code] no coloca los maniquíes de la zona.
## SIGTERM y SIGINT (Ctrl+C, [code]docker stop[/code], systemd) matan el proceso de Godot sin pasar
## por GDScript, así que no hay cierre ordenado. Para pararlo desde fuera con NOTICE de cierre,
## informe y borrado del bloqueo de [code]--dev-lock[/code] está [code]--stop-file=<ruta>[/code]: el
## servidor mira cada segundo si el archivo existe (por ejemplo, un [code]ExecStop[/code] que lo
## cree con [code]touch[/code]).
## Un valor que no es un número válido o está fuera de rango se ignora y se queda el valor por
## defecto: el servidor nunca arranca con una configuración absurda por un error al teclear.

## Puerto UDP en el que escucha.
var port: int = NetProtocol.DEFAULT_PORT
## Id de la zona que sirve ([method NetZones.default_zone_id] si no se indica). No se comprueba
## aquí que exista: [code]ServerMain[/code] lo hace con [method NetZones.scene_path].
var zone_id: String = ""
## Jugadores como mucho (los falsos cuentan).
var max_players: int = 64
## Conexiones simultáneas como mucho desde una misma IP (salvo loopback).
var max_connections_per_ip: int = 4
## Segundos sin jugadores tras los que el servidor se cierra solo. 0 = nunca.
var idle_quit_seconds: int = 0
## Ticks tras los que el servidor se cierra solo. 0 = nunca.
var quit_after_ticks: int = 0
## Ruta del informe JSON que se escribe al cerrar. Vacío = ninguno.
var report_path: String = ""
## Ruta del CSV con el estado de cada jugador en cada tick. Vacío = ninguno.
var state_log_path: String = ""
## Ruta de un archivo cuya existencia pide el cierre ordenado del servidor (se comprueba cada
## segundo; se borra al cerrar, y si ya existía al arrancar es de una parada anterior y se borra).
## Vacío = ninguno.
var stop_file_path: String = ""
## Especificación del simulador de red ([code]rtt=120,jitter=20,loss=5,dup=0,seed=1[/code]).
## Vacío = sin simulador.
var net_sim_spec: String = ""
## Jugadores falsos (sin red) que se crean al arrancar.
var fake_players: int = 0
## Dónde se reparten los jugadores falsos (pruebas de carga): [constant LAYOUT_CLUSTER] (todos en un
## mismo punto, a menos de 60 m unos de otros), [constant LAYOUT_SPREAD] (repartidos por la zona) o
## vacío (cada uno cerca del campamento de su reino).
var fake_layout: String = ""
## Cada cuántos ticks sale el jugador falso más antiguo y entra uno nuevo, para medir altas y bajas
## (60 = una alta y una baja por segundo). 0 = ninguna.
var fake_churn_ticks: int = 0
## Admite los comandos de depuración del cliente (teletransporte, curar, matar...; ver
## [CommandRegistry]).
var debug_commands: bool = false
## Ruta del registro de combate (CSV). Vacío = ninguno.
var combat_log_path: String = ""
## Cerebro de los jugadores falsos: vacío = el de paseo y [constant FAKE_BRAIN_COMBAT] = el de combate
## (buscan al enemigo más cercano, atacan, bloquean y esquivan).
var fake_brain: String = ""
## Con el cerebro de combate y [constant LAYOUT_CLUSTER]: punto (x, z) de la zona, a nivel del suelo,
## en torno al que se juntan los falsos en lugar del campamento del primer reino (donde la zona segura
## les impide pelear). [constant NO_FAKE_CENTER] = ninguno ([method has_fake_center]).
var fake_center: Vector2 = NO_FAKE_CENTER
## Lee los comandos de la consola de la entrada estándar (en un hilo, sin bloquear el tick).
var console: bool = false
## No coloca los maniquíes de entrenamiento de los marcadores [code]dummy_points[/code] de la zona.
var no_dummies: bool = false
## Escribe [code]user://dev_server.json[/code] para que [code]--local[/code] reutilice el servidor.
var dev_lock: bool = false
## Dónde se escribe el bloqueo de [member dev_lock] en lugar de [code]user://dev_server.json[/code]
## ([code]--dev-lock-path=<ruta>[/code]): las pruebas de procesos lo usan para no pisar el servidor
## local real de quien las ejecuta. Vacío = el de siempre.
var dev_lock_path: String = ""

## Valores de [member fake_layout].
const LAYOUT_CLUSTER: String = "cluster"
const LAYOUT_SPREAD: String = "spread"
## Valor de [member fake_brain] para el cerebro de combate.
const FAKE_BRAIN_COMBAT: String = "combat"
## Valor de [member fake_center] cuando no se indica.
const NO_FAKE_CENTER: Vector2 = Vector2(INF, INF)
## Coordenada máxima (en valor absoluto, m) que admite [member fake_center].
const MAX_FAKE_CENTER: float = 5000.0
const _MAX_PORT: int = 65535
## Tope razonable de jugadores y de jugadores falsos (los ids de red son de 16 bits).
const _MAX_PLAYERS_LIMIT: int = 4096


## Lee [param args] (los argumentos de usuario) y devuelve la configuración. Todo lo que no
## viene se queda en su valor por defecto; la zona, en [method NetZones.default_zone_id].
static func from_args(args: PackedStringArray) -> ServerConfig:
	var config := ServerConfig.new()
	config.zone_id = NetZones.parse_zone_arg(args)
	if config.zone_id.is_empty():
		config.zone_id = NetZones.default_zone_id()

	config.port = _int_option(args, "--port=", config.port, 1, _MAX_PORT)
	config.max_players = _int_option(args, "--max-players=", config.max_players, 1,
			_MAX_PLAYERS_LIMIT)
	config.max_connections_per_ip = _int_option(args, "--max-per-ip=",
			config.max_connections_per_ip, 1, _MAX_PLAYERS_LIMIT)
	config.idle_quit_seconds = _int_option(args, "--idle-quit=", config.idle_quit_seconds, 0,
			2147483647)
	config.quit_after_ticks = _int_option(args, "--quit-after-ticks=", config.quit_after_ticks, 0,
			2147483647)
	config.fake_players = _int_option(args, "--fake-players=", config.fake_players, 0,
			_MAX_PLAYERS_LIMIT)
	config.fake_churn_ticks = _int_option(args, "--fake-churn=", config.fake_churn_ticks, 0,
			2147483647)
	var layout: String = _string_option(args, "--fake-layout=").to_lower()
	if layout == LAYOUT_CLUSTER or layout == LAYOUT_SPREAD:
		config.fake_layout = layout
	var brain: String = _string_option(args, "--fake-brain=").to_lower()
	if brain == FAKE_BRAIN_COMBAT:
		config.fake_brain = brain
	var center_parts: PackedStringArray = _string_option(args, "--fake-center=").split(",")
	if center_parts.size() == 2 and center_parts[0].strip_edges().is_valid_float() \
			and center_parts[1].strip_edges().is_valid_float():
		var center := Vector2(center_parts[0].strip_edges().to_float(),
				center_parts[1].strip_edges().to_float())
		if center.is_finite() and absf(center.x) <= MAX_FAKE_CENTER and absf(center.y) <= MAX_FAKE_CENTER:
			config.fake_center = center
	config.combat_log_path = _string_option(args, "--combat-log=").replace("\\", "/")
	config.console = args.has("--console")
	config.no_dummies = args.has("--no-dummies")
	config.report_path = _string_option(args, "--report=")
	config.state_log_path = _string_option(args, "--state-log=")
	config.stop_file_path = _string_option(args, "--stop-file=")
	config.net_sim_spec = _string_option(args, "--net-sim=")
	config.debug_commands = args.has("--debug-commands")
	config.dev_lock = args.has("--dev-lock")
	config.dev_lock_path = _string_option(args, "--dev-lock-path=").replace("\\", "/")
	return config


## true si se indicó [member fake_center].
func has_fake_center() -> bool:
	return fake_center.is_finite()


## Valor entero de la primera opción [param prefix] (por ejemplo [code]"--port="[/code]) de
## [param args], o [param fallback] si no viene, no es un entero o está fuera de
## [[param min_value], [param max_value]].
static func _int_option(args: PackedStringArray, prefix: String, fallback: int, min_value: int,
		max_value: int) -> int:
	var text: String = _string_option(args, prefix)
	if not text.is_valid_int():
		return fallback
	var value: int = text.to_int()
	if value < min_value or value > max_value:
		return fallback
	return value


## Valor de la primera opción [param prefix] de [param args] sin espacios ni comillas alrededor,
## o una cadena vacía si no viene.
static func _string_option(args: PackedStringArray, prefix: String) -> String:
	for arg: String in args:
		if arg.begins_with(prefix):
			return arg.trim_prefix(prefix).strip_edges().trim_prefix("\"").trim_suffix("\"") \
					.strip_edges()
	return ""

