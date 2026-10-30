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
## --title  --platform=<url>  --login=<correo>  --password-file=<ruta>  --character=<nombre>  --world=N
## --dtls-cert=<pem>  --dtls-name=<cn>  --bot-scenario=<escenario>
## [/codeblock]
## [br]El modo ([enum Mode]) sale de ellos con esta prioridad (docs/plataforma.md §13.3): [code]--bots[/code]
## ([constant SWARM]) > [code]--bot[/code] ([constant BOT]) > [code]--local[/code] ([constant LOCAL]) >
## [code]--connect[/code] ([constant ONLINE]) > [code]--title[/code] o [code]--platform[/code] ([constant TITLE], la
## pantalla de título con cuenta) > nada: el sandbox de la fase 1 ([constant OFFLINE]) desde el editor y el título en
## una exportación ([param exported] de [method from_args]). [code]--server[/code] lo resuelve antes
## [code]boot.gd[/code] y no es un modo de cliente.
## [br][br]
## [b]Con cuenta[/b] (docs/plataforma.md §5.5 y §13.3): [code]--platform=<url>[/code] es la API pública de la
## plataforma (sin él, el título usa el ajuste de proyecto [constant PLATFORM_URL_SETTING]); [code]--bot
## --platform[/code] inicia sesión con [code]--login[/code] y la contraseña de [code]--password-file[/code], crea el
## personaje [code]--character[/code] si falta y entra con billete. [member character_id], [member ticket] y
## [member dtls_cert_pem] no salen de los argumentos: los rellena [AccountFlow] con la respuesta de
## [code]enter[/code] para [OnlineMain] ([member from_front] si viene de [FrontMain]).
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
	## Pantalla de título con cuenta ([FrontMain], docs/plataforma.md §13): inicio de sesión, personajes y entrada
	## con billete.
	TITLE,
}

## Cerebros de los bots ([member bot_brain], [code]--bot-brain[/code]): pasear (por defecto), pelear o
## asediar un fuerte. Valen para [code]--bot[/code] y para [code]--bots[/code].
const BOT_BRAIN_WANDER: String = "wander"
const BOT_BRAIN_COMBAT: String = "combat"
const BOT_BRAIN_SIEGE: String = "siege"
const BOT_BRAINS: Array[String] = [BOT_BRAIN_WANDER, BOT_BRAIN_COMBAT, BOT_BRAIN_SIEGE]
## Escenarios del bot ([member bot_scenario], [code]--bot-scenario[/code]): [code]progress[/code] equipa el arco, se da
## 50 de oro y una poción por DEBUG_COMMAND y sale ([BotProgressScenario], docs/progresion.md §15 P8).
const BOT_SCENARIO_PROGRESS: String = "progress"
const BOT_SCENARIOS: Array[String] = [BOT_SCENARIO_PROGRESS]
## Prefijo de los nombres por defecto: «Jugadorabcd» (ver [method NameRules.default_name]).
const DEFAULT_NAME_PREFIX: String = NameRules.DEFAULT_PREFIX
## Máximo de ticks, bots y semilla que se aceptan.
const _MAX_INT: int = 2147483647
const _MAX_PORT: int = 65535
const _MAX_BOTS: int = 4096
const _MAX_WORLD: int = 65535
## Ajuste de proyecto con la URL de la API pública de la plataforma (la que usa el título sin
## [code]--platform[/code]).
const PLATFORM_URL_SETTING: String = "eldmark/platform/url"
## URL por defecto si el ajuste no existe: la plataforma de desarrollo en esta máquina.
const DEFAULT_PLATFORM_URL: String = "http://127.0.0.1:24680"
## Mundo por defecto (el único al lanzar, docs/plataforma.md §0).
const DEFAULT_WORLD_ID: int = 1

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
## Escenario guionizado del bot ([constant BOT_SCENARIOS], [code]--bot-scenario=<escenario>[/code]; solo en
## [constant Mode.BOT]): vacío = ninguno. Con uno, el bot lo corre al aparecer y, si no hay
## [member quit_after_ticks], sale al terminarlo; con él, sigue hasta esos ticks. Si falla, sale con código 1.
var bot_scenario: String = ""
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
## defecto (no se manda nada). La cambian también la elección de reino y la pantalla de muerte. Un bot con
## [code]--platform[/code] no la manda: es la plantilla de inicio del personaje que crea si aún no existe
## ([method AccountFlow.ensure_character], docs/progresion.md §2.5).
var loadout: String = ""
## Avisos para el usuario sobre argumentos de red que no se han podido interpretar.
var warnings: PackedStringArray = PackedStringArray()

# --- Cuenta y plataforma (docs/plataforma.md §13.3) ---
## URL de la API pública de la plataforma ([code]--platform=<url>[/code]). Vacía = sin plataforma (los modos de
## siempre); en [constant Mode.TITLE] nunca está vacía (sin la opción, el ajuste [constant PLATFORM_URL_SETTING]).
var platform_url: String = ""
## Correo con el que inicia sesión el bot ([code]--login=<correo>[/code]).
var login: String = ""
## Archivo con la contraseña del bot ([code]--password-file=<ruta>[/code]): nunca en la línea de órdenes.
var password_file: String = ""
## Personaje del bot ([code]--character=<nombre>[/code]); vacío = [method NameRules.bot_name] de la semilla.
var character_name: String = ""
## Mundo ([code]--world=N[/code], 1 por defecto).
var world_id: int = DEFAULT_WORLD_ID
## [code]--title[/code]: la pantalla de título aunque haya otras opciones de cliente sin modo.
var title: bool = false
## Certificado DTLS de la zona en PEM ([code]--dtls-cert=<ruta>[/code], contra zonas sin plataforma; §10.2).
var dtls_cert_path: String = ""
## Nombre (CN) del certificado DTLS de la zona ([code]--dtls-name=<cn>[/code]).
var dtls_name: String = ""
## Personaje con el que se entra con billete (de [code]enter[/code]); 0 = sin billete.
var character_id: int = 0
## Billete de 52 B de [code]enter[/code] (va en el HELLO); vacío = sin billete.
var ticket: PackedByteArray = PackedByteArray()
## Certificado DTLS en PEM que dio [code]enter[/code] (gana a [member dtls_cert_path]); vacío = sin DTLS.
var dtls_cert_pem: String = ""
## true si la sesión sale de [FrontMain]: tras un rechazo o una desconexión [OnlineMain] vuelve a la selección de
## personaje (la sesión de la cuenta sigue) en lugar de a [RealmSelect].
var from_front: bool = false


## Lee [param args] (los argumentos de usuario) y devuelve la configuración. Los argumentos que no
## son de red ([code]--zone[/code], [code]--demo[/code]...) se ignoran sin avisar. [param exported]: el
## cliente es una exportación (no el editor); sin ningún modo, una exportación abre el título y el editor el
## sandbox (docs/plataforma.md §5.5).
static func from_args(args: PackedStringArray, exported: bool = false) -> ClientConfig:
	var config := ClientConfig.new()
	var connect_text: String = _string_option(args, "--connect=")
	var has_connect: bool = _has_option(args, "--connect=")
	var is_local: bool = args.has("--local")
	var is_bot: bool = args.has("--bot")
	var has_swarm: bool = _has_option(args, "--bots=")
	config.title = args.has("--title")
	config._parse_account_options(args)

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
	config.bot_scenario = _string_option(args, "--bot-scenario=").to_lower()
	if not config.bot_scenario.is_empty() and not BOT_SCENARIOS.has(config.bot_scenario):
		config.warnings.append("Escenario de bot desconocido '%s' (hay: %s); se juega sin escenario" % [
				config.bot_scenario, ", ".join(BOT_SCENARIOS)])
		config.bot_scenario = ""
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
	elif config.title or not config.platform_url.is_empty() or exported:
		config.mode = Mode.TITLE
	if config.mode == Mode.TITLE and config.platform_url.is_empty():
		config.platform_url = default_platform_url()
	return config


## URL de la plataforma del ajuste de proyecto [constant PLATFORM_URL_SETTING] (o
## [constant DEFAULT_PLATFORM_URL] si no existe).
static func default_platform_url() -> String:
	var value: String = str(ProjectSettings.get_setting(PLATFORM_URL_SETTING, DEFAULT_PLATFORM_URL)).strip_edges()
	return value if not value.is_empty() else DEFAULT_PLATFORM_URL


## Motivo, en español, por el que [param url] no vale como URL de la plataforma (vacío si vale): tiene que
## empezar por [code]https://[/code] o, solo hacia esta máquina (loopback), por [code]http://[/code]
## (docs/plataforma.md §10.1), y llevar servidor.
static func platform_url_error(url: String) -> String:
	var clean: String = url.strip_edges()
	if clean.is_empty():
		return "Falta la dirección del servidor de cuentas"
	var scheme_end: int = clean.find("://")
	if scheme_end <= 0:
		return "Dirección del servidor de cuentas mal escrita: «%s»" % clean
	var scheme: String = clean.left(scheme_end).to_lower()
	var host: String = url_host(clean)
	if host.is_empty():
		return "Dirección del servidor de cuentas sin servidor: «%s»" % clean
	if scheme == "https":
		return ""
	if scheme == "http":
		if is_loopback_host(host):
			return ""
		return "El servidor de cuentas tiene que usar https:// (http:// solo hacia esta máquina)"
	return "Dirección del servidor de cuentas mal escrita: «%s»" % clean


## El servidor de una URL ([code]http://host:puerto/ruta[/code] → [code]host[/code]; un IPv6 sin corchetes).
static func url_host(url: String) -> String:
	var clean: String = url.strip_edges()
	var scheme_end: int = clean.find("://")
	var rest: String = clean.substr(scheme_end + 3) if scheme_end >= 0 else clean
	for separator: String in ["/", "?", "#"]:
		var cut: int = rest.find(separator)
		if cut >= 0:
			rest = rest.left(cut)
	var at: int = rest.rfind("@")
	if at >= 0:
		rest = rest.substr(at + 1)
	if rest.begins_with("["):
		var close: int = rest.find("]")
		return rest.substr(1, close - 1) if close > 0 else ""
	var colon: int = rest.rfind(":")
	return rest.left(colon) if colon >= 0 else rest


## true si [param host] es esta máquina: [code]localhost[/code], 127.0.0.0/8 o [code]::1[/code].
static func is_loopback_host(host: String) -> bool:
	var clean: String = host.strip_edges().to_lower()
	if clean == "localhost" or clean == "::1":
		return true
	if clean.is_valid_ip_address() and clean.begins_with("127."):
		return true
	return false


## true si la configuración entra con billete (de [code]enter[/code]).
func has_ticket() -> bool:
	return not ticket.is_empty()


## true si la conexión con la zona va por DTLS: con el certificado de [code]enter[/code] o con
## [code]--dtls-cert[/code].
func has_dtls() -> bool:
	return not dtls_cert_pem.is_empty() or not dtls_cert_path.is_empty()


## Una copia de la configuración para la sesión de un personaje: los mismos ajustes de red, bot e informe, sin
## billete ni personaje (los pone quien la pide). La usa [AccountFlow] para no tocar la de partida.
func duplicate_config() -> ClientConfig:
	var copy := ClientConfig.new()
	for property: Dictionary in get_property_list():
		if int(property["usage"]) & PROPERTY_USAGE_SCRIPT_VARIABLE == 0:
			continue
		var value: Variant = get(property["name"])
		if value is PackedStringArray or value is PackedByteArray:
			value = value.duplicate()
		copy.set(property["name"], value)
	return copy


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


# Opciones de la cuenta y de DTLS (docs/plataforma.md §13.3). Una URL de plataforma que no vale se conserva (quien
# la use falla con su motivo, en lugar de entrar sin plataforma) y se avisa.
func _parse_account_options(args: PackedStringArray) -> void:
	platform_url = _string_option(args, "--platform=")
	if _has_option(args, "--platform=") and platform_url.is_empty():
		warnings.append("--platform necesita una dirección (por ejemplo --platform=http://127.0.0.1:24680)")
	elif not platform_url.is_empty():
		var error: String = platform_url_error(platform_url)
		if not error.is_empty():
			warnings.append(error)
	login = _string_option(args, "--login=")
	password_file = _clean_path(_string_option(args, "--password-file="))
	character_name = _string_option(args, "--character=")
	world_id = _int_option(args, "--world=", world_id, 1, _MAX_WORLD, warnings)
	dtls_cert_path = _clean_path(_string_option(args, "--dtls-cert="))
	dtls_name = _string_option(args, "--dtls-name=")
	if not dtls_cert_path.is_empty() and dtls_name.is_empty():
		warnings.append("--dtls-cert necesita --dtls-name=<cn> (el nombre del certificado de la zona)")


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
