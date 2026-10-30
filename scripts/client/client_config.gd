class_name ClientConfig
extends RefCounted
## Configuración del cliente en red (docs/red.md, secciones 1.2 y 17.5).
## [br][br]
## Se rellena con [method from_args] a partir de los argumentos de usuario (los que van tras
## [code]--[/code]):
## [codeblock]
## --connect=<host>[:<puerto>]  --local  --bot  --bots=N  --realm=<reino>  --name=<nombre>
## --port=<puerto>  --net-sim=rtt=120,jitter=20,loss=5,dup=0,seed=1  --bot-seed=N
## --bot-cheat=<modo>  --bot-brain=<wander|combat|siege>  --quit-after-ticks=N  --quit-at-server-tick=N
## --report=<ruta.json>  --state-log=<ruta.csv>  --dev-lock-path=<ruta.json>  --loadout=<plantilla>
## [/codeblock]
## [br]El modo ([enum Mode]) sale de ellos con esta prioridad: [code]--bots[/code] ([constant SWARM])
## > [code]--bot[/code] ([constant BOT]) > [code]--local[/code] ([constant LOCAL]) >
## [code]--connect[/code] ([constant ONLINE]) > nada ([constant OFFLINE], el sandbox de la fase 1).
## [code]--server[/code] lo resuelve antes [code]boot.gd[/code] y no es un modo de cliente.
## [br][br]
## Un valor que no es válido (un puerto fuera de rango, un número mal escrito, un reino que no existe)
## se ignora, se queda el valor por defecto y se anota en [member warnings]: el cliente nunca
## arranca con una configuración absurda por un error al teclear. La zona no se elige aquí: la dicta
## el servidor en el WELCOME.

## Modo de arranque del cliente.
enum Mode {
	## Sandbox sin red de la fase 1 ([ClientMain]).
	OFFLINE,
	## Cliente en red contra [member address]:[member port].
	ONLINE,
	## Cliente contra un servidor local, que se lanza si no hay ninguno.
	LOCAL,
	## Cliente que predice sin cámara ni HUD, guiado por [BotBrain].
	BOT,
	## Enjambre de [member bot_count] clientes ligeros que no simulan.
	SWARM,
}

## Cerebros de los bots ([member bot_brain], [code]--bot-brain[/code]): pasear (por defecto), pelear o
## asediar un fuerte. Valen para [code]--bot[/code] y para [code]--bots[/code].
const BOT_BRAIN_WANDER: String = "wander"
const BOT_BRAIN_COMBAT: String = "combat"
const BOT_BRAIN_SIEGE: String = "siege"
const BOT_BRAINS: Array[String] = [BOT_BRAIN_WANDER, BOT_BRAIN_COMBAT, BOT_BRAIN_SIEGE]
## Prefijo de los nombres por defecto: «Jugadorabcd» (ver [method NameRules.default_name]).
const DEFAULT_NAME_PREFIX: String = NameRules.DEFAULT_PREFIX
## Máximo de ticks, bots y semilla que se aceptan.
const _MAX_INT: int = 2147483647
const _MAX_PORT: int = 65535
const _MAX_BOTS: int = 4096

var mode: Mode = Mode.OFFLINE
var address: String = "127.0.0.1"
var port: int = NetProtocol.DEFAULT_PORT
## Código de [enum NetProtocol.Realm]. [constant NetProtocol.Realm.NONE] si no se indicó.
var realm: int = NetProtocol.Realm.NONE
var display_name: String = ""
var net_sim_spec: String = ""
var bot_seed: int = 1
var bot_count: int = 0
## Modo del bot tramposo ([code]--bot-cheat=<modo>[/code], [constant BotCheater.MODES]): de tráfico
## ([code]version[/code], [code]future[/code], [code]dupes[/code], [code]garbage[/code], [code]flood[/code]) o de
## combate ([code]rewind[/code], [code]reach[/code], [code]rate[/code] y, desde la fase 4, [code]reuse[/code],
## [code]potion[/code] e [code]interact[/code]). Vacío = honrado. Lo valida [NetClient] al arrancar.
var bot_cheat: String = ""
## Cerebro de los bots ([constant BOT_BRAINS]): vacío o [constant BOT_BRAIN_WANDER] pasea;
## [constant BOT_BRAIN_COMBAT] busca al enemigo más cercano y pelea ([constant BotBrain.Pattern.COMBAT]);
## [constant BOT_BRAIN_SIEGE] sigue la ruta de su reino hasta el fuerte, rompe la puerta, captura el círculo y
## lo defiende ([constant BotBrain.Pattern.SIEGE]).
var bot_brain: String = ""
var quit_after_ticks: int = 0
## Solo el enjambre ([constant Mode.SWARM]): sale cuando alguno de sus bots ha recibido un snapshot de este tick del
## servidor o posterior ([code]--quit-at-server-tick=N[/code]; 0 = no). Las pruebas de carga cierran así el enjambre
## por el reloj del servidor, que con muchos jugadores va más despacio que el tiempo real; [member quit_after_ticks]
## queda como cota.
var quit_at_server_tick: int = 0
var report_path: String = ""
var state_log_path: String = ""
## Archivo de bloqueo del servidor local que consulta el modo [constant Mode.LOCAL] en lugar de
## [constant LocalServerLauncher.LOCK_PATH] ([code]--dev-lock-path=<ruta>[/code]); se reenvía al
## servidor que se lanza. Vacío = el de siempre. Lo usan las pruebas de procesos.
var dev_lock_path: String = ""
## Plantilla de equipo para la siguiente aparición ([code]--loadout=<plantilla>[/code], el
## [member EquipmentTemplate.id] de una que se pueda elegir, como [code]marksman[/code]; docs/habilidades.md,
## sección 4.6): [NetClient] la manda en un LOADOUT_SELECT nada más llegar el WELCOME. Vacía = la de por
## defecto (no se manda nada). La cambian también la elección de reino y la pantalla de muerte.
var loadout: String = ""
## Avisos para el usuario sobre argumentos de red que no se han podido interpretar.
var warnings: PackedStringArray = PackedStringArray()


## Lee [param args] (los argumentos de usuario) y devuelve la configuración. Los argumentos que no
## son de red ([code]--zone[/code], [code]--demo[/code]...) se ignoran sin avisar.
static func from_args(args: PackedStringArray) -> ClientConfig:
	var config := ClientConfig.new()
	var connect_text: String = _string_option(args, "--connect=")
	var has_connect: bool = _has_option(args, "--connect=")
	var is_local: bool = args.has("--local")
	var is_bot: bool = args.has("--bot")
	var has_swarm: bool = _has_option(args, "--bots=")

	if has_connect:
		config._parse_connect(connect_text)
	config.port = _int_option(args, "--port=", config.port, 1, _MAX_PORT, config.warnings)
	config.bot_seed = _int_option(args, "--bot-seed=", config.bot_seed, -_MAX_INT, _MAX_INT,
			config.warnings)
	config.quit_after_ticks = _int_option(args, "--quit-after-ticks=", config.quit_after_ticks,
			0, _MAX_INT, config.warnings)
	config.quit_at_server_tick = _int_option(args, "--quit-at-server-tick=", config.quit_at_server_tick,
			0, _MAX_INT, config.warnings)
	config.bot_count = _int_option(args, "--bots=", config.bot_count, 1, _MAX_BOTS,
			config.warnings)
	config.net_sim_spec = _string_option(args, "--net-sim=")
	config.bot_cheat = _string_option(args, "--bot-cheat=").to_lower()
	config.bot_brain = _string_option(args, "--bot-brain=").to_lower()
	if not config.bot_brain.is_empty() and not BOT_BRAINS.has(config.bot_brain):
		config.warnings.append("Cerebro de bot desconocido '%s' (hay: %s); se usa %s" % [
				config.bot_brain, ", ".join(BOT_BRAINS), BOT_BRAIN_WANDER])
		config.bot_brain = ""
	config.report_path = _clean_path(_string_option(args, "--report="))
	config.state_log_path = _clean_path(_string_option(args, "--state-log="))
	config.dev_lock_path = _clean_path(_string_option(args, "--dev-lock-path="))
	var loadout_text: String = _string_option(args, "--loadout=").to_lower()
	if not loadout_text.is_empty():
		if is_selectable_template(loadout_text):
			config.loadout = loadout_text
		else:
			config.warnings.append("Plantilla de equipo desconocida '%s'; se usa la de por defecto"
					% loadout_text)

	if _has_option(args, "--realm="):
		config.realm = NetZones.parse_realm_arg(args)
		if config.realm == NetProtocol.Realm.NONE:
			config.warnings.append("Reino desconocido '%s'" % _string_option(args, "--realm="))
	config.display_name = _string_option(args, "--name=")
	if config.display_name.is_empty():
		# Los bots usan un nombre fijo por semilla (válido para NameRules); los jugadores, uno al azar.
		config.display_name = NameRules.bot_name(config.bot_seed) if is_bot or has_swarm \
				else default_name()

	if has_swarm and config.bot_count > 0:
		config.mode = Mode.SWARM
	elif is_bot:
		config.mode = Mode.BOT
	elif is_local:
		config.mode = Mode.LOCAL
	elif has_connect:
		config.mode = Mode.ONLINE
	return config


## Nombre por defecto de un jugador: «Jugador» y cuatro letras al azar (siempre válido).
static func default_name() -> String:
	return NameRules.default_name(randi_range(0, 456975))


## true si [param template_name] es el [member EquipmentTemplate.id] de una plantilla del catálogo que el
## jugador puede elegir ([member EquipmentTemplate.selectable]).
static func is_selectable_template(template_name: String) -> bool:
	var id: int = CombatCatalog.template_id(StringName(template_name))
	var template: EquipmentTemplate = CombatCatalog.template(id) if id > 0 else null
	return template != null and template.selectable


## Id del catálogo de [member loadout] (0 si no hay o no es una plantilla que se pueda elegir).
func get_loadout_template_id() -> int:
	if loadout.is_empty() or not is_selectable_template(loadout):
		return 0
	return CombatCatalog.template_id(StringName(loadout))


## true si el modo conecta con un servidor (todos menos [constant OFFLINE]).
func is_online() -> bool:
	return mode != Mode.OFFLINE


## Interpreta una dirección de servidor: [code]host[/code], [code]host:puerto[/code],
## [code][::1][/code] o [code][::1]:puerto[/code] (un IPv6 sin corchetes, con varios ':', se toma
## entero como host). Devuelve [code]{"host": String, "port": int, "error": String}[/code]:
## [code]port[/code] es 0 si no viene o no es válido y [code]error[/code] (en español) está vacío si
## todo es válido. Con un puerto no válido el host sí se devuelve.
static func parse_address(text: String) -> Dictionary:
	var clean: String = text.strip_edges()
	var result: Dictionary = {"host": "", "port": 0, "error": ""}
	if clean.is_empty():
		result["error"] = "Escribe la dirección del servidor"
		return result
	var host: String = clean
	var port_text: String = ""
	if clean.begins_with("["):
		var close: int = clean.find("]")
		if close < 0:
			result["error"] = "Dirección mal escrita: «%s»" % clean
			return result
		host = clean.substr(1, close - 1)
		var rest: String = clean.substr(close + 1)
		if rest.begins_with(":"):
			port_text = rest.substr(1)
	elif clean.count(":") == 1:
		host = clean.get_slice(":", 0)
		port_text = clean.get_slice(":", 1)
	if host.strip_edges().is_empty():
		result["error"] = "Dirección sin servidor: «%s»" % clean
		return result
	result["host"] = host.strip_edges()
	if not port_text.is_empty():
		if port_text.is_valid_int() and port_text.to_int() >= 1 and port_text.to_int() <= _MAX_PORT:
			result["port"] = port_text.to_int()
		else:
			result["error"] = "Puerto no válido «%s»" % port_text
	return result


# Interpreta el valor de --connect con [method parse_address]. Una dirección que no se entiende se
# ignora con un aviso; un puerto no válido deja el puerto por defecto.
func _parse_connect(text: String) -> void:
	if text.is_empty():
		warnings.append("--connect necesita una dirección (por ejemplo --connect=127.0.0.1:24600)")
		return
	var parsed: Dictionary = parse_address(text)
	if String(parsed["host"]).is_empty():
		warnings.append(String(parsed["error"]))
		return
	address = parsed["host"]
	if int(parsed["port"]) > 0:
		port = int(parsed["port"])
	elif not String(parsed["error"]).is_empty():
		warnings.append("%s; se usa %d" % [parsed["error"], port])


static func _has_option(args: PackedStringArray, prefix: String) -> bool:
	for arg: String in args:
		if arg.begins_with(prefix):
			return true
	return false


# Valor de la primera opción [param prefix], sin espacios ni comillas alrededor ("" si no viene).
static func _string_option(args: PackedStringArray, prefix: String) -> String:
	for arg: String in args:
		if arg.begins_with(prefix):
			return arg.trim_prefix(prefix).strip_edges().trim_prefix("\"").trim_suffix("\"") \
					.strip_edges()
	return ""


# Valor entero de la opción, o [param fallback] (con un aviso) si no es un entero en el rango.
static func _int_option(args: PackedStringArray, prefix: String, fallback: int, min_value: int,
		max_value: int, out_warnings: PackedStringArray) -> int:
	if not _has_option(args, prefix):
		return fallback
	var text: String = _string_option(args, prefix)
	if not text.is_valid_int() or text.to_int() < min_value or text.to_int() > max_value:
		out_warnings.append("Valor no válido en %s'%s'; se usa %d" % [prefix, text, fallback])
		return fallback
	return text.to_int()


# Ruta con barras normales (Windows escribe barras invertidas).
static func _clean_path(value: String) -> String:
	return value.replace("\\", "/")
