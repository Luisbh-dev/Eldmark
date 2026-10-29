class_name ServerConfig
extends RefCounted
## Configuración del servidor dedicado de una zona (docs/red.md, secciones 1.2 y 17.4).
## [br][br]
## Se rellena con [method from_args] a partir de los argumentos de usuario (los que van tras
## [code]--[/code]):
## [codeblock]
## --server --port=24600 --zone=<id> --max-players=64 --max-per-ip=4 --idle-quit=<s>
## --fake-players=N --debug-commands --dev-lock
## --quit-after-ticks=N --report=<ruta.json> --state-log=<ruta.csv> --net-sim=rtt=120,jitter=20
## [/codeblock]
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
## Especificación del simulador de red ([code]rtt=120,jitter=20,loss=5,dup=0,seed=1[/code]).
## Vacío = sin simulador.
var net_sim_spec: String = ""
## Jugadores falsos (sin red) que se crean al arrancar.
var fake_players: int = 0
## Admite los comandos de depuración del cliente (teletransporte).
var debug_commands: bool = false
## Escribe [code]user://dev_server.json[/code] para que [code]--local[/code] reutilice el servidor.
var dev_lock: bool = false

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
	config.report_path = _string_option(args, "--report=")
	config.state_log_path = _string_option(args, "--state-log=")
	config.net_sim_spec = _string_option(args, "--net-sim=")
	config.debug_commands = args.has("--debug-commands")
	config.dev_lock = args.has("--dev-lock")
	return config


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
