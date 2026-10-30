class_name ServerConfig
extends RefCounted
## Configuración del servidor dedicado de una zona (docs/red.md, secciones 1.2 y 17.4).
## [br][br]
## Se rellena con [method from_args] a partir de los argumentos de usuario (los que van tras
## [code]--[/code]):
## [codeblock]
## --server --port=24600 --zone=<id> --max-players=N --max-per-ip=4 --idle-quit=<s>
## --fake-players=N --fake-layout=<cluster|spread> --fake-churn=<ticks> --fake-brain=<combat|siege>
## --fake-center=<x>,<z> --fake-loadout=<plantilla>[:<porcentaje>] --fake-archers=<porcentaje>
## --max-realm-diff=N --run-at=<tick>:<orden>
## --debug-commands --dev-lock --dev-lock-path=<ruta>
## --quit-after-ticks=N --report=<ruta.json> --state-log=<ruta.csv> --net-sim=rtt=120,jitter=20
## --stop-file=<ruta> --combat-log=<ruta.csv> --console --no-dummies --no-npcs --battle-log=<ruta.jsonl>
## [/codeblock]
## [code]--combat-log=<ruta>[/code] escribe un CSV con una línea por golpe resuelto
## ([code]tick,atacante,objetivo,ataque,view_tick,rebobinado,resultado,daño[/code]; en el proyecto
## usa otra extensión, p. ej. [code].txt[/code], porque el importador convierte los [code].csv[/code]
## en traducciones). [code]--console[/code] lee comandos de la entrada estándar (anunciar, expulsar,
## cerrar...; ver [CommandRegistry]), [code]--no-dummies[/code] no coloca los maniquíes de la zona y
## [code]--no-npcs[/code] no crea los PNJ de sus generadores (Huecos, Capitán, guarnición y Guardianes; [NpcSpawnerSystem]).
## [code]--battle-log=<ruta>[/code] escribe los eventos de guerra y las muertes en JSON Lines
## ([BattleLog]; lo resume [code]tools/war/summarize_battle.gd[/code], GUE-17).
## [code]--fake-loadout=<plantilla>[:<porcentaje>][/code] (docs/habilidades.md, sección 4.6) da a los jugadores
## falsos la plantilla de equipo con ese nombre ([code]marksman[/code], [code]squire[/code]…): a todos o, con un
## porcentaje, a esa parte repartida en orden de creación (con 50, uno de cada dos); los demás, la de por defecto.
## [code]--fake-archers=<porcentaje>[/code] (pruebas de carga, H5) hace arqueros puros de los falsos que llevan el arco
## en la mano: no cambian a la espada ([member BotBrain.kit_ranged_only]) y ese porcentaje de ellos (de 0 a 100,
## repartido en orden) dispara al cielo ([member BotBrain.kit_aim_raise]): sus flechas viven los 2 s y llenan el tope
## de proyectiles de la zona.
## [code]--max-realm-diff=N[/code] (GUE-42) limita la diferencia de personas conectadas entre los reinos de la zona:
## el HELLO de quien entraría en un reino y dejaría más de N personas de ventaja sobre el reino con menos
## recibe un REJECT 9 (IMBALANCE); 0 = sin límite. Con N > 0 los jugadores falsos de reino automático
## rellenan el bando corto y se retiran al entrar personas (ver [RealmBalance]).
## [code]--run-at=<tick>:<orden>[/code] (repetible) ejecuta una orden de la consola ([CommandRegistry],
## por ejemplo [code]fort_kill_captain[/code]) al terminar el tick dado: así una prueba de carga sin
## entrada estándar puede abrir el círculo del fuerte.
## SIGTERM y SIGINT (Ctrl+C, [code]docker stop[/code], systemd) matan el proceso de Godot sin pasar
## por GDScript, así que no hay cierre ordenado. Para pararlo desde fuera con NOTICE de cierre,
## informe y borrado del bloqueo de [code]--dev-lock[/code] está [code]--stop-file=<ruta>[/code]: el
## servidor mira cada segundo si el archivo existe (por ejemplo, un [code]ExecStop[/code] que lo
## cree con [code]touch[/code]).
## Sin [code]--max-players[/code], el aforo es el de la zona ([method NetZones.max_players]: 40 en el Vado Gris,
## el límite de jugadores por batalla medido con el kit de la fase 4, docs/red.md, sección 14) o, si la zona no
## tiene uno propio, [constant DEFAULT_MAX_PLAYERS].
## Un valor que no es un número válido o está fuera de rango se ignora y se queda el valor por
## defecto: el servidor nunca arranca con una configuración absurda por un error al teclear.

## Puerto UDP en el que escucha.
var port: int = NetProtocol.DEFAULT_PORT
## Id de la zona que sirve ([method NetZones.default_zone_id] si no se indica). No se comprueba
## aquí que exista: [code]ServerMain[/code] lo hace con [method NetZones.scene_path].
var zone_id: String = ""
## Aforo de una zona sin uno propio ([method NetZones.max_players]).
const DEFAULT_MAX_PLAYERS: int = 64

## Jugadores como mucho (los falsos cuentan). [method from_args] pone el de la zona si no se indica.
var max_players: int = DEFAULT_MAX_PLAYERS
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
## Ruta del registro de batalla (JSON Lines: avisos de guerra y muertes). Vacío = ninguno.
var battle_log_path: String = ""
## Cerebro de los jugadores falsos: vacío = el de paseo, [constant FAKE_BRAIN_COMBAT] = el de combate
## (buscan al enemigo más cercano, atacan, bloquean y esquivan) y [constant FAKE_BRAIN_SIEGE] = el de asedio
## (siguen la ruta de su reino hasta el fuerte, rompen la puerta, capturan y defienden; GUE-15).
var fake_brain: String = ""
## Con el cerebro de combate y [constant LAYOUT_CLUSTER]: punto (x, z) de la zona, a nivel del suelo,
## en torno al que se juntan los falsos en lugar del campamento del primer reino (donde la zona segura
## les impide pelear). [constant NO_FAKE_CENTER] = ninguno ([method has_fake_center]).
var fake_center: Vector2 = NO_FAKE_CENTER
## Plantilla de equipo de los jugadores falsos ([code]--fake-loadout[/code]): su nombre en el catálogo de combate
## (vacío = la de por defecto) y a qué porcentaje de ellos se da (1 a 100).
var fake_loadout: StringName = &""
var fake_loadout_percent: int = 100
## Arqueros puros entre los falsos con arco ([code]--fake-archers[/code]; pruebas de carga): -1 = no; si no, el
## porcentaje de ellos que dispara al cielo.
var fake_archers_sky_percent: int = -1
## Diferencia máxima de personas conectadas entre los reinos de la zona (GUE-42); 0 = sin límite. Los
## jugadores falsos no cuentan para rechazar a una persona.
var max_realm_diff: int = 0
## Órdenes de consola programadas ([code]--run-at=<tick>:<orden>[/code]): diccionarios con
## [code]tick[/code] y [code]line[/code], en el orden en que se dieron.
var scheduled_commands: Array[Dictionary] = []
## Lee los comandos de la consola de la entrada estándar (en un hilo, sin bloquear el tick).
var console: bool = false
## No coloca los maniquíes de entrenamiento de los marcadores [code]dummy_points[/code] de la zona.
var no_dummies: bool = false
## No crea los PNJ de los generadores de la zona (Huecos, Capitán del Vado, guarnición y Guardianes de la
## Puerta; [NpcSpawnerSystem]).
var no_npcs: bool = false
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
## Valor de [member fake_brain] para el cerebro de asedio ([constant BotBrain.Pattern.SIEGE]).
const FAKE_BRAIN_SIEGE: String = "siege"
## Valor de [member fake_center] cuando no se indica.
const NO_FAKE_CENTER: Vector2 = Vector2(INF, INF)
## Coordenada máxima (en valor absoluto, m) que admite [member fake_center].
const MAX_FAKE_CENTER: float = 5000.0
## Prefijo de la opción de las órdenes programadas.
const RUN_AT_PREFIX: String = "--run-at="
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
	# El aforo de la zona si lo tiene (revisión de H5: el Vado Gris, el límite medido por batalla).
	var zone_capacity: int = NetZones.max_players(config.zone_id)
	if zone_capacity > 0:
		config.max_players = zone_capacity
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
	if brain == FAKE_BRAIN_COMBAT or brain == FAKE_BRAIN_SIEGE:
		config.fake_brain = brain
	var center_parts: PackedStringArray = _string_option(args, "--fake-center=").split(",")
	if center_parts.size() == 2 and center_parts[0].strip_edges().is_valid_float() \
			and center_parts[1].strip_edges().is_valid_float():
		var center := Vector2(center_parts[0].strip_edges().to_float(),
				center_parts[1].strip_edges().to_float())
		if center.is_finite() and absf(center.x) <= MAX_FAKE_CENTER and absf(center.y) <= MAX_FAKE_CENTER:
			config.fake_center = center
	_parse_fake_loadout(config, _string_option(args, "--fake-loadout="))
	config.fake_archers_sky_percent = _int_option(args, "--fake-archers=", -1, 0, 100)
	config.max_realm_diff = _int_option(args, "--max-realm-diff=", config.max_realm_diff, 0,
			_MAX_PLAYERS_LIMIT)
	config.scheduled_commands = _scheduled_commands(args)
	config.combat_log_path = _string_option(args, "--combat-log=").replace("\\", "/")
	config.battle_log_path = _string_option(args, "--battle-log=").replace("\\", "/")
	config.console = args.has("--console")
	config.no_dummies = args.has("--no-dummies")
	config.no_npcs = args.has("--no-npcs")
	config.report_path = _string_option(args, "--report=")
	config.state_log_path = _string_option(args, "--state-log=")
	config.stop_file_path = _string_option(args, "--stop-file=")
	config.net_sim_spec = _string_option(args, "--net-sim=")
	config.debug_commands = args.has("--debug-commands")
	config.dev_lock = args.has("--dev-lock")
	config.dev_lock_path = _string_option(args, "--dev-lock-path=").replace("\\", "/")
	return config


## La plantilla de [code]--fake-loadout=<plantilla>[:<porcentaje>][/code]: una plantilla del catálogo de combate
## que se pueda elegir y, si se da, un porcentaje de 1 a 100. Si algo no vale se ignora entera.
static func _parse_fake_loadout(config: ServerConfig, text: String) -> void:
	var value: String = text.strip_edges()
	if value.is_empty():
		return
	var parts: PackedStringArray = value.split(":")
	if parts.size() > 2:
		return
	var template_name := StringName(parts[0].strip_edges())
	var template: EquipmentTemplate = CombatCatalog.template(CombatCatalog.template_id(template_name))
	if template == null or not template.selectable:
		return
	var percent: int = 100
	if parts.size() == 2:
		var percent_text: String = parts[1].strip_edges()
		if not percent_text.is_valid_int() or percent_text.to_int() < 1 or percent_text.to_int() > 100:
			return
		percent = percent_text.to_int()
	config.fake_loadout = template_name
	config.fake_loadout_percent = percent


## La plantilla del jugador falso número [param index] (0, 1, 2…) según [code]--fake-loadout[/code]: su id en el
## catálogo o 0 (la de por defecto). Con un porcentaje se reparte en orden: el falso [param index] la lleva si el
## recuento acumulado sube al contarlo ([code]⌊(i + 1)·p / 100⌋ > ⌊i·p / 100⌋[/code]).
func fake_template_for(index: int) -> int:
	if fake_loadout.is_empty():
		return 0
	@warning_ignore("integer_division")
	var takes: bool = (index + 1) * fake_loadout_percent / 100 > index * fake_loadout_percent / 100
	return CombatCatalog.template_id(fake_loadout) if takes else 0


## true si el arquero puro número [param archer_index] (0, 1, 2…, en orden de creación entre los falsos con arco)
## dispara al cielo según [code]--fake-archers[/code] (el mismo reparto que [method fake_template_for]).
func is_sky_archer(archer_index: int) -> bool:
	if fake_archers_sky_percent <= 0:
		return false
	@warning_ignore("integer_division")
	return (archer_index + 1) * fake_archers_sky_percent / 100 > archer_index * fake_archers_sky_percent / 100


## Las órdenes programadas de [param args] ([code]--run-at=<tick>:<orden>[/code]): las que tienen un tick
## entero no negativo y una orden no vacía, en el orden en que se dieron.
static func _scheduled_commands(args: PackedStringArray) -> Array[Dictionary]:
	var commands: Array[Dictionary] = []
	for arg: String in args:
		if not arg.begins_with(RUN_AT_PREFIX):
			continue
		var text: String = arg.trim_prefix(RUN_AT_PREFIX).strip_edges().trim_prefix("\"") \
				.trim_suffix("\"").strip_edges()
		var colon: int = text.find(":")
		if colon <= 0:
			continue
		var tick_text: String = text.substr(0, colon).strip_edges()
		var line: String = text.substr(colon + 1).strip_edges()
		if not tick_text.is_valid_int() or tick_text.to_int() < 0 or line.is_empty():
			continue
		commands.append({"tick": tick_text.to_int(), "line": line})
	return commands


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

