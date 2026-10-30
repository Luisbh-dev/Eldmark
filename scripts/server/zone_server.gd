class_name ZoneServer
extends Node
## Servidor autoritativo de una zona (docs/red.md, secciones 3, 8, 9, 10, 11, 12 y 13).
## [br][br]
## Une las piezas puras del servidor ([NetEntityRegistry], [InputQueue], [SnapshotBuilder],
## [StateHistory], [ServerAuth], [InterestPolicy], [ServerMetrics]...) con el transporte
## ([NetTransport]) y el mundo de la zona. El cliente solo envía intenciones: el servidor simula a
## todos los jugadores, nunca acepta un estado del cliente.
## [br][br]
## [b]Orden del tick[/b] ([method _physics_process], prioridad -100; es normativo):
## [codeblock]
## poll             recibir: autenticación, READY, LEAVE, INPUT_BATCH -> InputQueue.push(),
##                  RESPAWN_REQUEST, DEBUG_COMMAND, LOADOUT_SELECT (la plantilla pendiente), el chat y
##                  los grupos (SocialService); y las líneas de la consola. Con la plataforma
##                  (docs/plataforma.md §14.3), después: ZonePlatform.take_events() repartido por kind en
##                  el orden de llegada (claim al AuthProvider, heartbeat a la zona; instance_closed al
##                  final), AuthProvider.take_completed() (cada 200: reino, cupo y WELCOME) y los
##                  VERIFYING vencidos (7 s en tiempo real desde la conexión, REJECT UNAVAILABLE)
## tick += 1        s es el tick que se simula
## bajas            desconexión, LEAVE o expulsión -> SocialService.on_peer_left (sale de su grupo, el
##                  mando pasa al más antiguo, se cancelan sus invitaciones), DESPAWN (motivo 1) y el id
##                  en cuarentena; la baja de un derribado es antes su muerte (DEATH y KILL)
## cerebros (paso 0) los PNJ piensan con el estado tras s - 1 y empujan su entrada de s a su InputQueue
##                  (cada 6 ticks; entre medias repiten su plan)
## simular          todas las entidades con cuerpo (jugadores, falsos y PNJ) por net_id ascendente,
##                  con la entrada de InputQueue.take(s); _check_motion. Justo antes de la suya, cada
##                  falso piensa (su BotBrain, con su estado de combate tras s - 1 para el kit de H5) y
##                  empuja su entrada de s; las vistas de asedio, sus objetivos y, para los de asedio
##                  (F6b), los golpes avisados en curso y los aliados se reúnen una vez por tick
## combate          CombatDirector.process_tick(), pasos 2 a 9 de docs/habilidades.md, sección 4.1:
##                  congelar (golpe activo, compromiso y muro de cada uno), disparos y efectos propios
##                  de quien compromete un ataque o una habilidad, resolver los golpes de ataques y
##                  habilidades (también contra las puertas de los fuertes) y el vuelo de los
##                  proyectiles, aplicar (daño, bloqueo, controles, efectos al objetivo, interrupciones,
##                  derribos y muertes), efectos de estado (pulsos y caducidades), el derribado
##                  (desangrado, levantar y rematar), entorno (caída, volúmenes letales, y < -100),
##                  reapariciones con su plantilla, la recarga del campamento y publicar la vida; los
##                  ENTITY_EVENT y los ENTITY_SPAWN y ENTITY_DESPAWN de los proyectiles salen aquí, y
##                  al final, los avisos TELEGRAPH de los ataques fuertes de PNJ que empiezan en s
## fuertes          FortressController.step() (paso 4b): presencia en el círculo, avance del estado de
##                  cada fortaleza, capas de la puerta (valen desde s + 1), avisos WAR y OBJECT_STATE;
##                  /atascado; cuerpos que se quedan tras una baja en combate
## PNJ              NpcSpawnerSystem.step(): altas y retiradas de PNJ según los generadores y las
##                  fortalezas, cadáveres
## altas            los READY pendientes: el jugador aparece con el estado «tras s» y el equipo de su
##                  plantilla (la pendiente o la de por defecto), SPAWN y LOADOUT
## social           SocialService.step(): caducan las invitaciones de grupo (PARTY_INVITATION caducada y
##                  aviso a quien invitó) y cada grupo manda su PARTY_STATUS (2 Hz, escalonado por el id
##                  del grupo) con el estado ya tras las altas
## historial        StateHistory.record() de todas las entidades, ya con lo impuesto
## snapshots        SnapshotBuilder.begin(); interés cada 6 ticks, escalonado; un SNAPSHOT a cada
##                  cliente cada 2 ticks, escalonado por la paridad de su net_id; el SCOREBOARD de la
##                  zona cada 2 s
## flush            vaciar lo enviado
## métricas         ServerMetrics y, cada 10 s, una línea en el registro
## [/codeblock]
## Las altas van después de simular, así que la primera simulación de un jugador nuevo es la del
## tick [code]s + 1[/code], sin desfase de un tick. Las bajas van antes de simular.
## [br][br]
## [b]Conexión[/b] (sección 3): el HELLO llega por [signal NetTransport.auth_received] y lo valida
## [ServerAuth]; con éxito se responde WELCOME y [method NetTransport.complete_auth] (el peer pasa a
## [constant ServerPeer.State.LOADING]) y, si no, REJECT y un corte ordenado. Nada se envía por
## [code]send[/code] hasta que llega [signal NetTransport.peer_connected]. El jugador aparece al
## final del tick en el que llega CLIENT_READY.
## [br][br]
## [b]Con la plataforma[/b] (docs/plataforma.md §5.2, [TicketAuthProvider] y [ZonePlatform]): un HELLO con
## billete válido deja al peer en [constant ServerPeer.State.VERIFYING] (cuenta para el cupo) mientras la
## plataforma lo reclama; con el 200, la zona mira que admite su reino (REALM) y que cabe (FULL) y le manda el
## WELCOME con el reino y el nombre del personaje, nunca los del HELLO. Una baja en VERIFYING cancela la espera
## (si la reclamación llega después, se libera); una en LOADING libera el arrendamiento sin guardar. Hasta
## [code]CharacterSaver[/code] (P5), un jugador que sale del mundo libera su arrendamiento cuando su cuerpo se
## va. El latido trae los [code]revoked[/code], que expulsan con su texto (uno con otro lease_id no expulsa a
## nadie).
## [br][br]
## [b]Seguridad[/b] (sección 12): limitadores por peer, avisos con expulsión a los 50 en 600 ticks
## (NOTICE de expulsión y corte), tope de conexiones por IP, tipos de mensaje inesperados según el
## estado de la sesión y comandos de depuración solo con [code]--debug-commands[/code].
## [br][br]
## [b]Jugadores falsos[/b] ([method add_fake_player]): jugadores sin red cuyas entradas salen de un
## [BotBrain] y entran directamente en su [InputQueue]; sirven para las pruebas y la carga. Con un
## [FillerKeeper] ([method set_filler_keeper], [code]--max-realm-diff[/code]) los de relleno siguen las altas y
## bajas de personas y no ocupan sus plazas: un HELLO que llega con el servidor lleno solo por ellos entra, uno le aparta
## la suya y se va cuando esa persona entra en el mundo (GUE-43; docs/fuerte.md, sección 7). Los de combate y
## asedio ven a sus enemigos (y los de asedio, a los PNJ que defienden el fuerte) con su velocidad y su derribo
## ([BotTarget]) y, desde H5, pelean con el kit de la fase 4 (docs/habilidades.md, sección 7.1): leen su estado de
## combate y su vida del servidor y los de combate levantan a los aliados derribados (los de asedio siguen su plan).
## Los de asedio, además, evitan los golpes avisados de los PNJ y cuentan a los suyos en la reunión (F6b).
## [br][br]
## [b]Combate[/b] (docs/combate.md): un [CombatDirector] lleva la vida, los golpes con rebobinado, las
## muertes y las reapariciones; los PNJ ([method add_npc], el maniquí de entrenamiento) son cuerpos
## simulados en el mismo bucle que los jugadores; los comandos de depuración y la consola pasan por el
## [CommandRegistry] y [code]--combat-log[/code] deja una línea por golpe resuelto. Un [NpcSpawnerSystem]
## ([method get_npc_system]) crea y retira los PNJ de los generadores de la zona (Huecos, Capitán del Vado,
## guarnición del dueño y Guardianes de la Puerta) con el cerebro [HfsmBrain]; [code]--no-npcs[/code] lo apaga.
## [br][br]
## [b]Fortalezas[/b] (docs/fuerte.md): un [FortressController] lleva el estado de cada fortaleza de la zona,
## su puerta (blanco de los golpes), los avisos de guerra y el OBJECT_STATE; [method get_fortresses] lo
## expone a los PNJ. [code]--battle-log[/code] deja los eventos de guerra y las muertes en JSON Lines.
## Quien sale o se desconecta en combate deja el cuerpo [constant LINGER_TICKS] ticks en el mundo
## (GUE-41), el comando /atascado ([UnstuckTracker]) teletransporta a quien lo pide y el marcador
## ([ScoreKeeper]) se manda a toda la zona cada [constant SCOREBOARD_INTERVAL_TICKS] ticks.

## Se emite al terminar cada tick, ya enviado todo lo del tick.
signal tick_finished(tick: int)
## Un jugador (de red) ha entrado en el mundo.
signal player_joined(peer_id: int, net_id: int)
## Un jugador (de red) ha salido del mundo.
signal player_left(peer_id: int, net_id: int)
## La cuenta atrás de un cierre pedido por la consola ([code]shutdown <s>[/code]) ha llegado a 0:
## quien lleva el proceso ([ServerMain]) debe cerrar el servidor.
signal shutdown_requested(reason: String)
## La plataforma ha cerrado esta instancia ([code]instance_lost[/code], [code]instance_replaced[/code] o
## [code]instance_stopped[/code], docs/plataforma.md §6.1): lo atiende [ServerMain].
signal instance_closed(code: String)

## Escena del personaje. En el servidor se le libera el nodo [code]Visual[/code].
const PLAYER_SCENE: PackedScene = preload("res://scenes/characters/player_character.tscn")
## Distancia máxima que puede recorrer un personaje en un tick (la velocidad terminal da 0,83 m).
const MAX_STEP_DISTANCE: float = 1.5
## Por debajo de esta altura el personaje muere (cae fuera del mundo).
const FALL_LIMIT_Y: float = CombatDirector.VOID_LIMIT_Y
## Cada cuántos ticks se recalcula el interés de cada peer (escalonado por net_id).
const INTEREST_INTERVAL_TICKS: int = 6
## Ticks que un peer puede estar cargando la zona sin enviar CLIENT_READY (60 s).
const LOADING_TIMEOUT_TICKS: int = 3600
## Cada cuántos ticks se vuelca a disco el registro de estados (1 s): si matan al servidor, lo
## anterior no se pierde.
const STATE_LOG_FLUSH_TICKS: int = 60
## Cada cuántos ticks se escribe la línea de métricas en el registro (10 s).
const METRICS_LOG_TICKS: int = 600
## Ticks durante los que no puede volver a entrar quien ha sido expulsado (30 s): su IP o, desde
## loopback, su nombre reciben un REJECT nada más conectar.
const KICK_COOLDOWN_TICKS: int = 1800
## Margen (ticks) que se suma al RTT de ENet y al retardo del simulador al acotar el RTT que declara
## el cliente con sus acks: los snapshots salen cada 2 ticks y hay que procesarlos.
const RTT_SLACK_TICKS: int = 3
## Motivo del aviso por cada paquete que el transporte descarta por no ser del protocolo.
const DISCARDED_REASON: String = "paquete ajeno al protocolo"
## Ticks que un peer puede estar conectado sin enviar el HELLO (1,5 s). Mucho menos que los 10 s de
## la autenticación de [SceneMultiplayer]: una conexión ociosa ocupa una de las plazas de ENet.
const HELLO_TIMEOUT_TICKS: int = 90
## Motivo con el que el informe cuenta (en [code]rejects[/code]) las conexiones cortadas por no
## mandar el HELLO a tiempo.
const HELLO_TIMEOUT_REASON: String = "sin HELLO a tiempo"
## Cada cuántos ticks se comprueba el plazo del HELLO.
const HELLO_CHECK_TICKS: int = 10
## Plazo de un peer en VERIFYING desde que conectó (ms, en tiempo real): pasado, REJECT UNAVAILABLE. Menos que el
## [constant NetTransport.AUTH_TIMEOUT_SECONDS] de 10 s, así que el REJECT siempre llega (docs/plataforma.md §5.2).
const VERIFY_TIMEOUT_MS: int = 7000
## Motivo con el que se registra el plazo de VERIFYING vencido.
const VERIFY_TIMEOUT_REASON: String = "la plataforma no ha contestado a tiempo"
## Ticks que se espera, tras [method stop], a que los peers se vayan antes de cerrar el transporte.
const STOP_DRAIN_TICKS: int = 30
## Secciones del tick que aparecen en la línea de métricas (las mismas que mide el bucle).
const LOGGED_SECTIONS: Array[StringName] = [&"net", &"platform", &"npc_brains", &"sim", &"combat", &"combat_resolve",
		&"combat_projectiles", &"combat_events", &"war", &"npc", &"social", &"history", &"snapshot", &"flush"]
## Secciones de [ServerMetrics] de los PNJ: los cerebros (paso 0) y el sistema de generadores.
const SECTION_NPC_BRAINS: StringName = &"npc_brains"
## Sección de las métricas con el reparto de los eventos de la plataforma y los finales de las reclamaciones (dentro
## de «net»; docs/plataforma.md §16).
const SECTION_PLATFORM: StringName = &"platform"
const SECTION_NPC: StringName = &"npc"
## Sección de [ServerMetrics] del paso de las fortalezas (4b del tick).
const SECTION_WAR: StringName = &"war"
## Sección de [ServerMetrics] del paso social (caducidad de invitaciones y PARTY_STATUS). El chat y los
## mensajes de grupo que llegan se atienden en el poll y cuentan en la sección «net».
const SECTION_SOCIAL: StringName = &"social"
## Cada cuántos ticks se manda el SCOREBOARD a toda la zona (2 s).
const SCOREBOARD_INTERVAL_TICKS: int = 120
## Ticks que el cuerpo de quien sale o se desconecta «en combate» sigue en el mundo, quieto y atacable
## (15 s, GUE-41).
const LINGER_TICKS: int = 900
## Usos de /atascado que conserva el informe (los más recientes).
const MAX_LOGGED_UNSTUCK: int = 200
## Sección de [ServerMetrics] del envío de los ENTITY_EVENT (dentro de la de combate).
const SECTION_COMBAT_EVENTS: StringName = &"combat_events"
## Fichas de jugador y expulsiones que el informe conserva (las más recientes); lo anterior se resume
## en totales. Sin tope, un cliente que entra y sale en bucle haría crecer la memoria sin límite.
const MAX_LOGGED_PLAYERS: int = 1000
const MAX_LOGGED_KICKS: int = 200
## Avisos de error de física que se escriben en el registro (el resto solo se cuenta).
const MAX_LOGGED_PHYSICS_ERRORS: int = 10
## Coordenada máxima (en valor absoluto) que admite un teletransporte de depuración.
const MAX_TELEPORT_COORDINATE: float = 5000.0
## Texto del NOTICE de cierre por defecto.
const DEFAULT_SHUTDOWN_TEXT: String = "El servidor se está cerrando"
## Maniquíes de entrenamiento como mucho (los de las zonas y los del comando spawn_dummy).
const MAX_DUMMIES: int = 16
## Distancia (m) delante del jugador a la que aparece un maniquí del comando spawn_dummy.
const DUMMY_SPAWN_DISTANCE: float = 3.0
## Nombre del maniquí de entrenamiento.
const DUMMY_NAME: String = "Maniquí"
## Nombre de los jugadores falsos ([method add_fake_player]) con su número: «Bot-01». El guion y las cifras lo dejan
## fuera de [NameRules] a propósito: el cliente no ofrece acciones sociales a un nombre que no las cumple
## ([code]SocialTarget.is_social_target[/code]), porque un falso no tiene conexión y el servidor contestaría «no está
## conectado» a la invitación o al susurro (docs/social.md, sección 12.6).
const FAKE_NAME_FORMAT: String = "Bot-%02d"
## Cabecera del registro de combate (--combat-log).
const COMBAT_LOG_HEADER: String = "tick,atacante,objetivo,ataque,view_tick,rebobinado,resultado,daño"
## Segundos restantes en los que una cuenta atrás de cierre avisa a los jugadores.
const SHUTDOWN_NOTICE_SECONDS: Array[int] = [60, 30, 10, 5, 4, 3, 2, 1]
## Trazo (m) del rayo con el que se busca el suelo bajo un punto de maniquí.
const _GROUND_PROBE_UP: float = 4.0
const _GROUND_PROBE_DOWN: float = 12.0
## Trazo de la sonda que decide si un punto de aparición está en el suelo.
const _PROBE_UP: float = 0.1
const _PROBE_DOWN: float = 0.3
## Ticks de cada hueco de la ventana de la medida del RTT, y huecos que la forman.
const _RTT_BUCKET_TICKS: int = 30
const _RTT_BUCKETS: int = 4
const _INT_MAX: int = 0x7FFFFFFF

enum _RunState { IDLE, RUNNING, STOPPING, STOPPED }

## Política de interés: qué entidades ve cada jugador. La base lo considera todo relevante.
var interest_policy: InterestPolicy = InterestPolicy.new():
	set(value):
		interest_policy = value if value != null else InterestPolicy.new()
		_snapshot_builder = SnapshotBuilder.new(interest_policy)
## Escribe en el registro las altas, las bajas, las expulsiones y las métricas.
var log_enabled: bool = true
## Ticks que un peer puede estar cargando la zona sin enviar CLIENT_READY antes de que se le
## expulse ([constant LOADING_TIMEOUT_TICKS] por defecto; las pruebas lo acortan).
var loading_timeout_ticks: int = LOADING_TIMEOUT_TICKS
## Ticks que un peer puede estar conectado sin enviar el HELLO antes de que se le corte
## ([constant HELLO_TIMEOUT_TICKS] por defecto; las pruebas lo cambian).
var hello_timeout_ticks: int = HELLO_TIMEOUT_TICKS
## Plazo de VERIFYING en ms ([constant VERIFY_TIMEOUT_MS] por defecto; las pruebas lo cambian).
var verify_timeout_ms: int = VERIFY_TIMEOUT_MS
## Ticks de enfriamiento tras una expulsión ([constant KICK_COOLDOWN_TICKS] por defecto; las pruebas
## lo cambian).
var kick_cooldown_ticks: int = KICK_COOLDOWN_TICKS
## Solo pruebas: si es válido, se le pasa [code](peer_id: int, address: String) -> String[/code] y
## devuelve la dirección con la que se trata al peer. Sirve para fingir que unos clientes de
## loopback vienen de una IP externa y así probar el tope de conexiones por IP, del que el loopback
## está exento.
var remote_address_override: Callable = Callable()
## Ticks que el cuerpo de quien sale o se desconecta en combate sigue en el mundo
## ([constant LINGER_TICKS] por defecto; las pruebas lo acortan).
var linger_ticks: int = LINGER_TICKS
## Fichas de jugador y expulsiones que conserva el informe ([constant MAX_LOGGED_PLAYERS] y
## [constant MAX_LOGGED_KICKS] por defecto; las pruebas los acortan).
var max_logged_players: int = MAX_LOGGED_PLAYERS
var max_logged_kicks: int = MAX_LOGGED_KICKS

var _run_state: _RunState = _RunState.IDLE
var _config: ServerConfig
var _world: Node3D
var _transport: NetTransport
var _auth: ServerAuth
var _auth_provider: AuthProvider = null
## La plataforma (null sin [code]--platform[/code]: personajes efímeros, docs/progresion.md §9.4).
var _platform: ZonePlatform = null
## Arrendamientos de los cuerpos en el mundo (net_id -> reclamación): hasta CharacterSaver (P5) se liberan sin
## guardar cuando el cuerpo se va (también tras la salida en combate).
var _claims_by_net: Dictionary[int, ClaimedCharacter] = {}
var _sim_hash: int = 0
var _tick: int = 0
var _drain_ticks: int = 0
var _registry: NetEntityRegistry = NetEntityRegistry.new()
var _history: StateHistory = StateHistory.new()
var _metrics: ServerMetrics = ServerMetrics.new()
var _snapshot_builder: SnapshotBuilder
var _spawn_picker: SpawnPicker
var _players_root: Node3D
# peer_id -> peer (en cualquier estado).
var _peers: Dictionary[int, ServerPeer] = {}
# Peers en el mundo, para repartir los snapshots.
var _world_peers: Array[ServerPeer] = []
# net_id -> cola de entradas (de los jugadores de red y de los falsos).
var _queues: Dictionary[int, InputQueue] = {}
# net_id -> cerebro de cada jugador falso.
var _fakes: Dictionary[int, BotBrain] = {}
# Los falsos de relleno de --max-realm-diff (null sin equilibrio; ver set_filler_keeper).
var _filler_keeper: FillerKeeper = null
# net_id -> cerebro de cada PNJ (maniquíes).
var _npcs: Dictionary[int, BotBrain] = {}
var _combat: CombatDirector
var _fortresses: FortressController = null
var _npc_system: NpcSpawnerSystem = null
var _scores: ScoreKeeper = ScoreKeeper.new()
var _battle_log: BattleLog = null
var _unstuck: UnstuckTracker = UnstuckTracker.new()
# Chat y grupos (SOC-04, SOC-06); se crea en start().
var _social: SocialService = null
var _unstuck_log: Array[Dictionary] = []
var _unstuck_uses: int = 0
# net_id -> tick en el que se retira el cuerpo de quien salió en combate (GUE-41).
var _lingering: Dictionary[int, int] = {}
var _lingering_total: int = 0
# Clave del nombre -> net_id de quien está canalizando /atascado.
var _unstuck_players: Dictionary[String, int] = {}
var _object_states_sent: int = 0
var _telegraphs_sent: int = 0
var _scoreboards_sent: int = 0
var _safe_areas: SafeAreas
var _commands: CommandRegistry = CommandRegistry.new()
var _console: ServerConsole = null
var _combat_log: FileAccess = null
# Tick en el que se cumple la cuenta atrás de un cierre pedido por la consola (-1 = ninguna).
var _shutdown_tick: int = -1
var _shutdown_announced: Dictionary[int, bool] = {}
var _events_sent: int = 0
var _event_bytes_sent: int = 0
# Proyectiles (docs/habilidades.md, sección 4.4): los peers que recibieron el ENTITY_SPAWN de cada uno (los
# mismos reciben su ENTITY_DESPAWN) y lo enviado.
var _projectile_viewers: Dictionary[int, PackedInt32Array] = {}
var _projectile_messages_sent: int = 0
var _projectile_bytes_sent: int = 0
var _dummies_created: int = 0
# Caché de objetivos de los bots de combate: tick de la última vez, posiciones e ids por reino, y qué
# reinos son hostiles entre sí.
var _targets_tick: int = -1
var _targets_by_realm: Dictionary = {}
var _targets_ids_by_realm: Dictionary = {}
# Por reino, 1 si el objetivo del mismo índice es un PNJ (lo que buscan primero los falsos SIEGE).
var _targets_npc_by_realm: Dictionary = {}
# Kit de los falsos (H5): la velocidad de cada objetivo y si está derribado, en el mismo orden.
var _targets_velocity_by_realm: Dictionary = {}
var _targets_downed_by_realm: Dictionary = {}
var _hostile_cache: Dictionary = {}
# Asedio de los falsos con cerebro SIEGE (GUE-15): la vista de cada fortaleza, que comparten todos y se pone al
# día en cada tick, y las rutas de aproximación de la zona (data/routes/<zona>.tres; null si no hay).
var _siege_views: Dictionary[StringName, SiegeView] = {}
var _siege_routes: ApproachRoutes = null
var _siege_routes_loaded: bool = false
# Golpes avisados (TELEGRAPH) que los falsos SIEGE evitan (F6b): tick de la lista, los golpes en curso de los PNJ y el
# reino de cada PNJ que golpea.
var _threats_tick: int = -1
var _threats: Array[BotBrain.Threat] = []
var _threat_realms: PackedInt32Array = PackedInt32Array()
# Jugadores vivos por reino (posiciones e ids) con los que los falsos SIEGE cuentan a los suyos en el punto de reunión
# (GUE-44), y el tick de la lista.
var _allies_tick: int = -1
var _allies_by_realm: Dictionary[int, PackedVector3Array] = {}
var _ally_ids_by_realm: Dictionary[int, PackedInt32Array] = {}
# peer_id -> medida del RTT en ticks.
var _rtt: Dictionary[int, _RttWindow] = {}
# Peers con CLIENT_READY recibido, en orden de llegada.
var _pending_ready: Array[int] = []
# Peers que se van (bajas del tick siguiente).
var _leaving: Array[int] = []
# net_id -> ficha del jugador vivo; _player_log guarda las últimas max_logged_players, también las de
# los que se han ido (las más viejas de los que se fueron se resumen en _archived_*).
var _player_by_net: Dictionary[int, _PlayerRecord] = {}
var _player_log: Array[_PlayerRecord] = []
var _archived_players: int = 0
var _archived_fakes: int = 0
var _archived_inputs: int = 0
var _archived_substituted: int = 0
var _archived_late: int = 0
var _archived_too_early: int = 0
var _fake_counter: int = 0
var _peak_players: int = 0
var _players_at_stop: int = 0
# Estado de las fortalezas en el cierre, para el informe que se escribe después de stop().
var _war_fortresses_at_stop: Array[Dictionary] = []
var _joined_total: int = 0
var _left_total: int = 0
var _strikes_total: int = 0
var _strike_reasons: Dictionary[String, int] = {}
var _kicks: Array[Dictionary] = []
var _kicks_total: int = 0
# Clave («ip:<grupo>» o «name:<nombre normalizado>») -> tick hasta el que no puede volver a entrar.
var _kick_until: Dictionary[String, int] = {}
var _rejects: Dictionary[String, int] = {}
var _physics_errors: int = 0
var _teleports: int = 0
var _respawns: int = 0
var _synced_wire_in: int = 0
var _synced_wire_out: int = 0
var _log_last_usec: int = 0
# Reloj de ticks «reales» (a la cadencia nominal), para saber cuántos ticks ha perdido el servidor
# entre dos polls. _clock_origin_usec es el instante de start().
var _clock_origin_usec: int = 0
var _last_poll_real_tick: int = 0
var _log_last_wire_out: int = 0
var _log_last_wire_in: int = 0
var _state_log: FileAccess = null
# net_id -> 1 si la entrada del tick se sustituyó (solo se rellena con --state-log).
var _substituted_now: Dictionary[int, int] = {}
# Jugadores falsos que se van en el siguiente tick (remove_fake_player), y los de relleno que se retiran sin muerte
# aunque estén derribados (retire_filler).
var _fake_leaving: Array[int] = []
var _fake_leaving_quietly: Dictionary[int, bool] = {}
# Medidas de la carga (informe): µs de simulate() por llamada y de construir snapshots.
var _simulate_calls: int = 0
var _simulate_usec_total: int = 0
var _simulate_usec_max: int = 0
var _snapshots_sent: int = 0
var _snapshot_bytes_total: int = 0
var _snapshot_bytes_max: int = 0
var _snapshot_build_usec: int = 0


## Ficha de un jugador para el informe: lo que se sabe de él mientras está y al irse.
class _PlayerRecord:
	var net_id: int = 0
	var peer_id: int = 0
	var display_name: String = ""
	var realm: int = 0
	var is_fake: bool = false
	var joined_tick: int = 0
	var left_tick: int = -1
	var inputs: int = 0
	var substituted: int = 0
	var late: int = 0
	var too_early: int = 0
	var strikes: int = 0
	var suspicion: int = 0
	var rewind_rejects: int = 0
	var swings: int = 0
	var swings_landed: int = 0
	var kicked: bool = false
	var kick_reason: String = ""
	var queue: InputQueue = null
	var peer: ServerPeer = null
	var entity: NetEntity = null
	## Última posición conocida (la de ahora mientras el jugador está; la de la baja, después).
	var last_position: Vector3 = Vector3.ZERO


	# Copia los contadores vivos de la cola y del peer y la posición del personaje.
	func refresh() -> void:
		if queue != null:
			substituted = queue.substitutions_total
			late = queue.late_count
			too_early = queue.too_early_count
		if peer != null:
			strikes = peer.strikes_total
			suspicion = peer.suspicion_score
			rewind_rejects = peer.rewind_rejects
			swings = peer.swings
			swings_landed = peer.swings_landed
		if left_tick < 0 and entity != null and is_instance_valid(entity.node):
			last_position = entity.get_position()


	# El jugador se va en el tick [param tick]: copia los contadores y la posición y suelta la cola,
	# el peer y la entidad, que si no se quedarían en memoria mientras la ficha siga en el informe.
	func close(tick: int) -> void:
		refresh()
		left_tick = tick
		queue = null
		peer = null
		entity = null


	func to_dictionary() -> Dictionary:
		refresh()
		return {
			"net_id": net_id,
			"peer_id": peer_id,
			"name": display_name,
			"realm": NetProtocol.realm_display_name(realm),
			"fake": is_fake,
			"joined_tick": joined_tick,
			"left_tick": left_tick,
			"inputs": inputs,
			"substituted_inputs": substituted,
			"late_inputs": late,
			"too_early_inputs": too_early,
			"strikes": strikes,
			"suspicion": suspicion,
			"rewind_rejects": rewind_rejects,
			"swings": swings,
			"swings_landed": swings_landed,
			"kicked": kicked,
			"kick_reason": kick_reason,
			"position": [last_position.x, last_position.y, last_position.z],
		}


## Mínimo y máximo del RTT en ticks de los últimos 90-120 ticks, en cuatro huecos de 30 ticks.
class _RttWindow:
	var _ids: PackedInt32Array = PackedInt32Array()
	var _mins: PackedInt32Array = PackedInt32Array()
	var _maxs: PackedInt32Array = PackedInt32Array()


	func _init() -> void:
		_ids.resize(_RTT_BUCKETS)
		_ids.fill(-1)
		_mins.resize(_RTT_BUCKETS)
		_mins.fill(_INT_MAX)
		_maxs.resize(_RTT_BUCKETS)
		_maxs.fill(-1)


	func add(now_tick: int, sample: int) -> void:
		var bucket_id: int = now_tick / _RTT_BUCKET_TICKS
		var slot: int = bucket_id % _RTT_BUCKETS
		if _ids[slot] != bucket_id:
			_ids[slot] = bucket_id
			_mins[slot] = _INT_MAX
			_maxs[slot] = -1
		_mins[slot] = mini(_mins[slot], sample)
		_maxs[slot] = maxi(_maxs[slot], sample)


	# Mínimo de la ventana, o -1 si no hay muestras en ella.
	func get_min(now_tick: int) -> int:
		var current: int = now_tick / _RTT_BUCKET_TICKS
		var best: int = _INT_MAX
		for slot: int in _RTT_BUCKETS:
			if _ids[slot] > current - _RTT_BUCKETS and _ids[slot] <= current:
				best = mini(best, _mins[slot])
		return best if best != _INT_MAX else -1


	# Máximo de la ventana, o -1 si no hay muestras en ella.
	func get_max(now_tick: int) -> int:
		var current: int = now_tick / _RTT_BUCKET_TICKS
		var best: int = -1
		for slot: int in _RTT_BUCKETS:
			if _ids[slot] > current - _RTT_BUCKETS and _ids[slot] <= current:
				best = maxi(best, _maxs[slot])
		return best


func _init() -> void:
	process_physics_priority = -100
	_snapshot_builder = SnapshotBuilder.new(interest_policy)


func _ready() -> void:
	# No hay nada que simular hasta start().
	set_physics_process(false)


func _exit_tree() -> void:
	_release_resources()


# --- API pública ------------------------------------------------------------------------------

## Pone en marcha el servidor de la zona [param world] (que ya debe estar en el árbol, igual que
## este nodo) con [param config].
## [br]- Calcula el [code]sim_hash[/code] sobre una instancia del personaje dentro del árbol.
## [br]- Si [param transport] todavía no escucha, aplica [member ServerConfig.net_sim_spec] y abre
## [member ServerConfig.port] con sitio para [member ServerConfig.max_players] más 4 conexiones (las
## 4 de más permiten contestar «servidor lleno» con un REJECT). Si ya escucha, lo usa tal cual.
## [br]- [param transport] puede ser null: el servidor corre sin red, solo con jugadores falsos
## ([method add_fake_player]), que es lo que usan las pruebas.
## [br]- [param auth_provider] decide la identidad de los clientes ([DevAuthProvider] sin plataforma,
## [TicketAuthProvider] con ella).
## [br]- [param platform] es la plataforma ya arrancada ([signal ZonePlatform.startup_finished]); null sin
## [code]--platform[/code]. Sus eventos se reparten en el paso «poll» de cada tick (las fortalezas que cargó
## las aplica P6 antes de abrir el puerto).
## Devuelve el error de [method NetTransport.host] si no se puede abrir el puerto.
func start(config: ServerConfig, world: Node3D, transport: NetTransport,
		auth_provider: AuthProvider, platform: ZonePlatform = null) -> Error:
	if _run_state != _RunState.IDLE:
		return ERR_ALREADY_IN_USE
	if config == null or world == null or not is_inside_tree() or not world.is_inside_tree():
		return ERR_UNCONFIGURED
	_config = config
	_world = world
	_transport = transport
	_auth_provider = auth_provider
	_platform = platform
	if _platform != null:
		_platform.player_count_source = get_player_count
	_players_root = Node3D.new()
	_players_root.name = "Players"
	add_child(_players_root)
	_sim_hash = _compute_sim_hash()
	_auth = ServerAuth.new(config, _sim_hash, NetZones.allowed_realms(config.zone_id),
			auth_provider)
	_auth.set_connected_names_source(get_connected_names)
	_auth.set_realm_counts_source(get_realm_counts)
	_spawn_picker = SpawnPicker.new(world)
	_safe_areas = SafeAreas.from_world(world)
	_combat = CombatDirector.new(_history, StringName(config.zone_id), world, _safe_areas,
			Callable(self, "_place"), Callable(self, "_pick_spawn_point"))
	_combat.event_emitted.connect(_on_combat_event)
	_combat.metrics = _metrics
	# Los proyectiles toman su id del espacio de las entidades (con su cuarentena).
	_combat.projectiles.registry = _registry
	_combat.projectiles.spawned.connect(_on_projectile_spawned)
	_combat.projectiles.despawned.connect(_on_projectile_despawned)
	_projectile_viewers.clear()
	_war_fortresses_at_stop = []
	_setup_fortresses(world)
	_setup_npcs(world)
	_commands.audit_sink = Callable(self, "_log")
	_register_commands()
	_social = SocialService.new(Callable(self, "_social_peers"), Callable(self, "_social_send"),
			Callable(self, "_add_strike"))
	if _transport != null:
		_connect_transport()
		if not _transport.is_server():
			_transport.set_net_sim_spec(config.net_sim_spec)
			var error: Error = _transport.host(config.port, config.max_players + 4)
			if error != OK:
				_disconnect_transport()
				_transport = null
				_players_root.queue_free()
				_players_root = null
				return error
	_open_state_log()
	_open_combat_log()
	_open_battle_log()
	_metrics.register_monitors()
	_log_last_usec = Time.get_ticks_usec()
	_clock_origin_usec = _log_last_usec
	_last_poll_real_tick = 0
	_run_state = _RunState.RUNNING
	set_physics_process(true)
	return OK


## Cierra el servidor: avisa a todos los clientes con un NOTICE de cierre (código
## [constant NetProtocol.NoticeCode.SHUTDOWN]) con [param notice_text] (por defecto, un texto
## estándar), vacía lo enviado, pide el corte ordenado de cada peer y libera a todos los
## personajes. Los datos del informe se conservan ([method write_report]). El transporte se cierra
## cuando los peers se han ido o pasados [constant STOP_DRAIN_TICKS] ticks; [method is_stopped]
## dice cuándo.
func stop(notice_text: String = "") -> void:
	if _run_state != _RunState.RUNNING:
		return
	_log("Cerrando el servidor de la zona '%s' (tick %d)" % [_config.zone_id, _tick])
	_players_at_stop = get_player_count()
	if _transport != null:
		var notice := NetMessages.Notice.new()
		notice.code = NetProtocol.NoticeCode.SHUTDOWN
		notice.text = notice_text if not notice_text.is_empty() else DEFAULT_SHUTDOWN_TEXT
		var bytes: PackedByteArray = notice.encode()
		for peer_id: int in get_peer_ids():
			var peer: ServerPeer = _peers[peer_id]
			if peer.state == ServerPeer.State.LEAVING:
				continue
			_leave_auth_states(peer)
			_transport.send(peer_id, NetProtocol.CH_RELIABLE, bytes)
			_transport.disconnect_after_flush(peer_id)
			peer.state = ServerPeer.State.LEAVING
		_transport.flush()
	for record: _PlayerRecord in _player_by_net.values():
		record.close(_tick)
	_war_fortresses_at_stop = _fortress_entries()
	_clear_players()
	_pending_ready.clear()
	_leaving.clear()
	_fake_leaving.clear()
	_fake_leaving_quietly.clear()
	_sync_byte_counters()
	_close_state_log()
	_close_combat_log()
	_close_battle_log()
	if _console != null:
		_console.stop()
	_metrics.unregister_monitors()
	_drain_ticks = 0
	if _transport == null or _peers.is_empty():
		_finish_stop()
	else:
		_run_state = _RunState.STOPPING


## true cuando [method stop] ha terminado: los peers se han ido (o se agotó la espera) y el
## transporte está cerrado.
func is_stopped() -> bool:
	return _run_state == _RunState.STOPPED


## Tick actual: el último que se ha simulado (0 antes de empezar). El primero es el 1.
func get_tick() -> int:
	return _tick


## El peer con ese id (en cualquier estado) o null.
func get_peer(peer_id: int) -> ServerPeer:
	return _peers.get(peer_id)


## Ids de todos los peers conocidos, ordenados.
func get_peer_ids() -> PackedInt32Array:
	var ids := PackedInt32Array(_peers.keys())
	ids.sort()
	return ids


## Jugadores que cuentan para el cupo: los peers que verifican su billete con la plataforma (docs/plataforma.md
## §5.2: varias entradas a la vez no pasan de max_players), los aceptados (cargando la zona o ya dentro) y los
## jugadores falsos. Los que aún no han mandado el HELLO o se van (también los falsos con la baja pedida, que
## desaparecen al empezar el siguiente tick) no cuentan. Los falsos de relleno sí cuentan aquí, pero ceden su
## plaza a las personas (ver [method set_filler_keeper]): mientras una persona carga la zona en la plaza que le ha
## apartado uno, cuentan los dos (uno de más), y el falso se va cuando ella entra en el mundo.
func get_player_count() -> int:
	var count: int = _fakes.size() - _fake_leaving.size()
	for peer: ServerPeer in _peers.values():
		if peer.state == ServerPeer.State.VERIFYING or peer.state == ServerPeer.State.LOADING \
				or peer.state == ServerPeer.State.IN_WORLD:
			count += 1
	return count


## Personas por reino (Vardheim, Solmarch, Askarra; ver [RealmBalance]): los clientes aceptados de verdad,
## cargando la zona o ya dentro (con [param in_world_only], solo los que ya están dentro). Los jugadores falsos y
## los cuerpos que quedan tras una baja en combate no cuentan. [param excluded] no se cuenta (el que acaba de
## entrar, para su WELCOME). Es el recuento del WELCOME y el del REJECT 9 IMBALANCE.
func get_realm_counts(in_world_only: bool = false, excluded: ServerPeer = null) -> PackedInt32Array:
	var counts: PackedInt32Array = RealmBalance.empty_counts()
	for peer: ServerPeer in _peers.values():
		if peer == excluded:
			continue
		var counted: bool = peer.state == ServerPeer.State.IN_WORLD \
				or (not in_world_only and peer.state == ServerPeer.State.LOADING)
		if counted and peer.realm >= 1 and peer.realm <= RealmBalance.REALM_COUNT:
			counts[peer.realm - 1] += 1
	return counts


## Entradas del enfriamiento tras expulsiones (vigentes o aún sin purgar). Se purgan al apuntar la
## siguiente expulsión, así que el diccionario no crece más que las expulsiones de los últimos
## [constant KICK_COOLDOWN_TICKS] ticks.
func get_cooldown_count() -> int:
	return _kick_until.size()


## Nombres de los jugadores presentes en la zona: los peers aceptados (cargando o ya dentro) y los
## jugadores falsos. [ServerAuth] rechaza con NAME un HELLO cuyo nombre repite alguno de ellos.
func get_connected_names() -> PackedStringArray:
	var names := PackedStringArray()
	for peer: ServerPeer in _peers.values():
		if peer.state == ServerPeer.State.LOADING or peer.state == ServerPeer.State.IN_WORLD:
			names.append(peer.display_name)
	for net_id: int in _fakes:
		var record: _PlayerRecord = _player_by_net.get(net_id)
		if record != null:
			names.append(record.display_name)
	# El nombre de quien salió en combate sigue reservado mientras su cuerpo está en el mundo (GUE-41).
	for net_id: int in _lingering:
		var body: NetEntity = _registry.get_entity(net_id)
		if body != null:
			names.append(body.display_name)
	return names


func get_registry() -> NetEntityRegistry:
	return _registry


func get_history() -> StateHistory:
	return _history


func get_metrics() -> ServerMetrics:
	return _metrics


## El director del combate (vida, golpes, muertes y reapariciones). null antes de [method start].
func get_combat() -> CombatDirector:
	return _combat


## Plazos del combate en ticks (reaparición, protección...). Las pruebas los acortan.
func get_combat_timing() -> CombatTiming:
	return _combat.timing if _combat != null else null


## Registro de comandos de administración (red y consola).
func get_commands() -> CommandRegistry:
	return _commands


## Zonas seguras de la zona.
func get_safe_areas() -> SafeAreas:
	return _safe_areas


## Las fortalezas de la zona (estado, puerta, avisos). null antes de [method start]. Es la interfaz de
## los generadores de PNJ: [method FortressController.get_fortress_state],
## [method FortressController.on_captain_died] y [method FortressController.set_guards_alive].
func get_fortresses() -> FortressController:
	return _fortresses


## El sistema de generadores de PNJ (puestos, navegación, fichas). null antes de [method start] o con
## [code]--no-npcs[/code].
func get_npc_system() -> NpcSpawnerSystem:
	return _npc_system


## net_id de todos los PNJ con cuerpo (los de los generadores, los maniquíes y los sueltos), ordenados.
func get_npc_ids() -> Array[int]:
	var ids: Array[int] = []
	ids.assign(_npcs.keys())
	ids.sort()
	return ids


## El cerebro del PNJ [param net_id], o null.
func get_npc_brain(net_id: int) -> BotBrain:
	return _npcs.get(net_id)


## El espacio de física del mundo del servidor (línea de visión de los PNJ). null antes de [method start].
func get_physics_space() -> PhysicsDirectSpaceState3D:
	return _players_root.get_world_3d().direct_space_state if _players_root != null else null


## El marcador de la batalla (bajas, muertes, asistencias, daño a la puerta, círculo y méritos).
func get_scores() -> ScoreKeeper:
	return _scores


## El control del comando /atascado (canalizaciones y reutilizaciones).
func get_social() -> SocialService:
	return _social


func get_unstuck() -> UnstuckTracker:
	return _unstuck


## Cuerpos que siguen en el mundo tras la baja de un jugador en combate (GUE-41).
func get_lingering_count() -> int:
	return _lingering.size()


## true si [param net_id] es el cuerpo de un jugador que ha salido en combate y espera su retirada.
func is_lingering(net_id: int) -> bool:
	return _lingering.has(net_id)


## Huella de la simulación ([method NetProtocol.compute_sim_hash]) que el servidor exige a los
## clientes en el HELLO.
func get_sim_hash() -> int:
	return _sim_hash


## Crea un jugador sin red de [param realm] (un código de [enum NetProtocol.Realm]): en cada tick,
## antes de simular, su entrada sale de [code]brain.next_input()[/code], cuantizada y con el tick
## correspondiente, y entra directamente en su [InputQueue]. Aparece con la plantilla de equipo
## [param template_id] (0 = la de por defecto; [code]--fake-loadout[/code]) y la conserva al reaparecer.
## Devuelve su [code]net_id[/code], o -1 si el servidor no está en marcha, está lleno
## ([member ServerConfig.max_players]) o no quedan ids. Se puede llamar entre dos ticks; el jugador aparece
## con el estado «tras el último tick» y su primera simulación es la del siguiente.
func add_fake_player(brain: BotBrain, realm: int, template_id: int = 0) -> int:
	if _run_state != _RunState.RUNNING or brain == null:
		return -1
	if _occupied_seats() >= _config.max_players:
		return -1
	_fake_counter += 1
	var entity: NetEntity = _create_player(FAKE_NAME_FORMAT % _fake_counter, realm, 0, _tick)
	if entity == null:
		return -1
	var combatant: Combatant = _combat.get_combatant(entity.net_id)
	_combat.equip_template(combatant, template_id)
	_fakes[entity.net_id] = brain
	var pattern: BotBrain.Pattern = brain.get_pattern()
	var fighter: bool = pattern == BotBrain.Pattern.COMBAT or pattern == BotBrain.Pattern.SIEGE
	if fighter and not brain.has_enemy_finder():
		brain.set_enemy_finder(_find_enemy_target.bind(entity.net_id))
	if fighter and not brain.has_combat_source():
		# El kit de la fase 4 (H5): el estado de combate del servidor tras el último tick, la vida y los aliados
		# derribados.
		brain.set_combat_source(_fake_combat_state.bind(entity.net_id))
		brain.set_health_source(_fake_health_fraction.bind(entity.net_id))
		brain.set_ally_finder(_find_downed_ally.bind(entity.net_id))
	if pattern == BotBrain.Pattern.SIEGE and not brain.has_siege():
		brain.set_siege(get_siege_view(), get_approach_routes(), realm)
	if pattern == BotBrain.Pattern.SIEGE and not brain.has_threat_finder():
		brain.set_threat_finder(_find_threats.bind(entity.net_id))
	if pattern == BotBrain.Pattern.SIEGE and not brain.has_defender_finder():
		brain.set_defender_finder(_find_enemy_target.bind(entity.net_id, true))
	if pattern == BotBrain.Pattern.SIEGE and not brain.has_ally_counter():
		brain.set_ally_counter(_count_allies.bind(entity.net_id))
	if pattern == BotBrain.Pattern.SIEGE and not brain.has_line_of_sight():
		# El arco del kit solo tira si la flecha llega (la empalizada, la puerta cerrada, también la propia).
		brain.set_line_of_sight(_bot_line_of_sight)
	var record: _PlayerRecord = _player_by_net[entity.net_id]
	record.is_fake = true
	_announce_arrival(entity, null, _tick)
	if combatant.template_id > 0:
		_combat.announce_loadout(combatant, _tick, true)
	_log("Alta de %s (jugador falso, net_id %d, %s); jugadores: %d" % [entity.display_name,
			entity.net_id, NetProtocol.realm_display_name(realm), get_player_count()])
	return entity.net_id


## La vista de asedio de la fortaleza [param fortress_id] (vacío = la primera de la zona) que usan los
## jugadores falsos con el cerebro [constant BotBrain.Pattern.SIEGE]: se crea la primera vez que se pide, lleva
## las posiciones de la puerta y el círculo y se pone al día en cada tick con el estado vivo de la fortaleza
## ([method SiegeView.update_from_state]). null si la zona no tiene fortalezas.
func get_siege_view(fortress_id: StringName = &"") -> SiegeView:
	if _fortresses == null or not _fortresses.has_fortresses():
		return null
	var id: StringName = fortress_id if not fortress_id.is_empty() else _fortresses.get_fortress_ids()[0]
	var state: FortressState = _fortresses.get_fortress_state(id)
	if state == null:
		return null
	var view: SiegeView = _siege_views.get(id)
	if view == null:
		view = SiegeView.new()
		view.fortress_id = id
		var gate: FortGate = _fortresses.get_gate(id)
		var circle: Dictionary = _fortresses.get_circle(id)
		view.set_places(gate.global_position if gate != null else circle["center"], circle["center"],
				circle["radius"])
		var routes: ApproachRoutes = get_approach_routes()
		if routes != null:
			view.enclosure_size = routes.enclosure_size
		view.update_from_state(state)
		_siege_views[id] = view
	return view


## Las rutas de aproximación de la zona (data/routes/<zona>.tres), o null si no tiene.
func get_approach_routes() -> ApproachRoutes:
	if not _siege_routes_loaded:
		_siege_routes_loaded = true
		var path: String = "res://data/routes/%s.tres" % _config.zone_id
		if ResourceLoader.exists(path):
			_siege_routes = load(path) as ApproachRoutes
	return _siege_routes


## Le da al servidor los falsos de relleno de [code]--max-realm-diff[/code] (GUE-42 y GUE-43; los crea y los
## conecta [ServerMain]; null los quita). Desde entonces el servidor le avisa de las altas
## ([method FillerKeeper.on_person_joined]) y bajas ([method FillerKeeper.on_person_left]) de personas y de cada
## falso que se va ([method FillerKeeper.forget]), y los falsos de relleno no ocupan plazas de personas: el FULL
## solo cuenta a las personas y a los demás falsos ([method ServerAuth.validate]), y si un HELLO que se acepta
## encuentra el servidor lleno, un falso de relleno le aparta su plaza ([method FillerKeeper.reserve_seat]) y se va
## cuando esa persona entra en el mundo. Si se va antes, la plaza se libera ([method FillerKeeper.release_seat]) sin
## que ningún falso se haya movido: un HELLO seguido de una desconexión, en bucle, no saca a nadie del combate ni manda
## altas y bajas a los demás. Nunca entran más personas que [member ServerConfig.max_players].
func set_filler_keeper(keeper: FillerKeeper) -> void:
	_filler_keeper = keeper


## Da de baja al jugador falso [param net_id] al empezar el siguiente tick: DESPAWN (motivo 1) a quien
## lo veía y el id en cuarentena, como si se hubiera desconectado. Devuelve false si no es un jugador
## falso (o ya se va). Sirve para las altas y bajas de las pruebas de carga. Si está derribado, su baja es antes
## una muerte (DEATH y KILL), como la de cualquiera que sale derribado.
func remove_fake_player(net_id: int) -> bool:
	if _run_state != _RunState.RUNNING or not _fakes.has(net_id) or _fake_leaving.has(net_id):
		return false
	_fake_leaving.append(net_id)
	return true


## Retira al falso de relleno [param net_id] que cede su sitio a una persona (GUE-42 y GUE-43; lo pide
## [FillerKeeper]): como [method remove_fake_player], pero su baja nunca es una muerte, ni aunque esté derribado (solo
## DESPAWN, sin DEATH ni KILL para quien lo derribó): que entre una persona no mata a nadie (revisión de la integración
## de las habilidades). Devuelve false si no es un jugador falso (o ya se va).
func retire_filler(net_id: int) -> bool:
	if not remove_fake_player(net_id):
		return false
	_fake_leaving_quietly[net_id] = true
	return true


## true si retirar ya al jugador falso [param net_id] no corta nada: no está derribado ni levantando o rematando a
## nadie (muerto esperando a reaparecer, también). El [member FillerKeeper.calm_check] de los falsos de relleno.
func is_fake_calm(net_id: int) -> bool:
	var combatant: Combatant = _combat.get_combatant(net_id)
	return combatant == null or (not combatant.is_downed() and not combatant.is_interacting())


## Teletransporte autoritativo del jugador [param net_id] a [param position]: velocidad 0, estado
## redondeado por [code]encode/decode[/code] (el que reconstruirá el cliente) y contador de
## teletransporte +1 (módulo 4), para que los clientes no interpolen el salto. Conserva el yaw y
## las pulsaciones previas. No hace nada con un id desconocido o una posición que no es finita.
func teleport(net_id: int, position: Vector3) -> void:
	var entity: NetEntity = _registry.get_entity(net_id)
	if entity == null or entity.get_character() == null or not position.is_finite():
		return
	_place(entity, position, entity.get_character().yaw)
	_teleports += 1


## Crea un PNJ humanoide de nombre [param display_name] y bando [param realm] (0 = los Huecos, hostiles
## a todos) en [param position] mirando a [param yaw]: un [PlayerCharacter] simulado en el mismo bucle
## que los jugadores con las entradas de [param brain] (como las de un jugador falso), con vida y
## grabado en el historial. Con [param immortal] es un maniquí: la vida no baja de 1 y se cura del todo
## a los 5 s sin daño. Devuelve su [code]net_id[/code], o -1 si el servidor no está en marcha o no
## quedan ids. Con [param definition] (una [NpcDefinition]) el PNJ toma de ella su vida, su arma, si ignora las
## zonas seguras y su número del catálogo (el [code]npc_def_id[/code] del ENTITY_SPAWN).
func add_npc(brain: BotBrain, display_name: String, realm: int, position: Vector3, yaw: float,
		immortal: bool = false, definition: NpcDefinition = null) -> int:
	if _run_state != _RunState.RUNNING or brain == null:
		return -1
	var entity: NetEntity = _create_body(NetProtocol.EntityKind.NPC, display_name, realm, 0, _tick,
			position, yaw)
	if entity == null:
		return -1
	_npcs[entity.net_id] = brain
	var combatant: Combatant = _combat.get_combatant(entity.net_id)
	if definition != null:
		# Su definición manda: vida, arma, zona segura y el número que ve el cliente (modelo y barra de jefe).
		entity.npc_def_id = NpcCatalog.number_of(definition.id)
		combatant.max_health = definition.max_health
		combatant.health = definition.max_health
		combatant.ignores_safe_area = definition.ignores_safe_area
		_combat.set_weapon(combatant, CombatCatalog.weapon_id(definition.weapon_id))
		entity.set_health_view(combatant.health, combatant.max_health, 0, 0)
		immortal = immortal or definition.immortal
	combatant.immortal = immortal
	if immortal:
		_dummies_created += 1
	_announce_arrival(entity, null, _tick)
	_log("Alta del PNJ %s (net_id %d)%s en %s" % [display_name, entity.net_id,
			", inmortal" if immortal else "", position])
	return entity.net_id


## Da de baja al PNJ [param net_id] (DESPAWN a quien lo veía). Devuelve false si no es un PNJ.
func remove_npc(net_id: int) -> bool:
	var entity: NetEntity = _registry.get_entity(net_id)
	if entity == null or not _npcs.has(net_id):
		return false
	_remove_player(entity, _tick, NetProtocol.DespawnReason.DISCONNECTED)
	return true


## Crea un maniquí de entrenamiento (PNJ inmortal del bando neutral) en [param position] mirando a
## [param yaw], con el modo [param mode] ([enum NpcBrain.Mode]). La posición se baja al suelo si hay
## uno debajo. Devuelve su net_id, o -1 si no cabe ([constant MAX_DUMMIES]) o no se puede crear.
func spawn_dummy(position: Vector3, yaw: float, mode: int = NpcBrain.Mode.STILL) -> int:
	if get_dummy_count() >= MAX_DUMMIES:
		return -1
	return add_npc(NpcBrain.new(mode), DUMMY_NAME, RealmCatalog.NEUTRAL_CODE,
			_ground_position(position), yaw, true)


## Coloca un maniquí quieto en cada marcador del grupo [code]dummy_points[/code] de la zona (uno en
## el mundo de pruebas y uno junto a cada campamento del Vado Gris). Devuelve cuántos ha creado.
func spawn_zone_dummies() -> int:
	var created: int = 0
	for marker: Node3D in NetZones.get_dummy_points(_world):
		var transform: Transform3D = marker.global_transform
		if spawn_dummy(transform.origin, CombatDirector._yaw_of(transform)) > 0:
			created += 1
	return created


## Doble de pruebas del capitán de [param fortress_id] mientras no hay generador de PNJ: un PNJ mortal
## y quieto en el [code]CaptainSpawn[/code] de la fortaleza, del bando del dueño, registrado como su
## capitán ([method FortressController.register_captain]). Al morir (de un golpe o con
## [code]fort_kill_captain[/code]) abre el círculo de captura. Devuelve su net_id, o -1 si no se puede.
func spawn_captain_double(fortress_id: StringName) -> int:
	if _fortresses == null:
		return -1
	var node: Node3D = _fortresses.get_node_of(fortress_id)
	var state: FortressState = _fortresses.get_fortress_state(fortress_id)
	if node == null or state == null:
		return -1
	var marker: Node3D = node.get_node_or_null(^"CaptainSpawn") as Node3D
	var transform: Transform3D = marker.global_transform if marker != null else node.global_transform
	var net_id: int = add_npc(NpcBrain.new(NpcBrain.Mode.STILL), "Capitán (prueba)", state.owner,
			transform.origin, _yaw_of(transform))
	if net_id > 0:
		_fortresses.register_captain(fortress_id, net_id)
	return net_id


## Maniquíes vivos (PNJ inmortales).
func get_dummy_count() -> int:
	var count: int = 0
	for net_id: int in _npcs:
		var combatant: Combatant = _combat.get_combatant(net_id)
		if combatant != null and combatant.immortal:
			count += 1
	return count


## Ejecuta una línea de la consola ([code]kick Ana[/code]) y devuelve la respuesta. Es lo que hace el
## servidor con cada línea de la entrada estándar; las pruebas la llaman directamente.
func console_command(line: String) -> String:
	return _commands.execute_console(line)


## Arranca la consola de la entrada estándar (hilo lector, sin bloquear el tick). Devuelve false si no
## hay entrada estándar utilizable o ya estaba en marcha.
func start_console() -> bool:
	if _console == null:
		_console = ServerConsole.new()
	return _console.start()


## La consola ([ServerConsole]), o null si no se ha arrancado ni se le ha dado una línea.
func get_console() -> ServerConsole:
	return _console


## Mete una línea en la cola de la consola como si se hubiera escrito en la entrada estándar; se
## ejecuta al principio del siguiente tick.
func push_console_line(line: String) -> void:
	if _console == null:
		_console = ServerConsole.new()
	_console.push_line(line)


## Escribe el informe JSON de la ejecución en [param path] (los directorios que falten se crean).
## Claves:
## [codeblock]
## version, zone, port, ticks, tick_rate, sim_hash
## closed    false mientras el servidor está en marcha (informe periódico), true tras stop()
## players   {current, at_stop, fake, peak, joined_total, left_total, archived}
## inputs    {consumed, substituted, late, too_early, substituted_percent}  (solo jugadores de red)
## bytes     {wire_in, wire_out, app_in, app_out}  (acumulados; ver NetTransport.get_byte_counters)
## strikes   {total, by_reason, kicks_total}
## kicks     [{tick, peer_id, net_id, name, reason}]  (las últimas max_logged_kicks)
## rejects   {motivo: veces}
## physics_errors, teleports, respawns
## simulate  {calls, total_us, avg_us, max_us}        µs de cada PlayerCharacter.simulate()
## snapshots {sent, bytes, avg_bytes, max_bytes, build_us, avg_build_us}   build_us: construir cada
##           snapshot y encolarlo (sin el cálculo del interés ni el envío real de ENet)
## metrics   ServerMetrics.summary() (p50/p99/máx de cada sección en µs, KB/s, jugadores...)
## npcs      NpcSpawnerSystem.get_report(): puestos, PNJ vivos, altas, muertes, ataques fuertes avisados,
##           fichas de ataque, rutas calculadas...
## player_list  una ficha por jugador que ha pasado por el servidor (también los que se fueron),
##           las últimas max_logged_players; de las anteriores solo quedan los totales
##           (players.archived cuenta las fichas resumidas)
## [/codeblock]
func write_report(path: String) -> Error:
	if path.is_empty():
		return ERR_INVALID_PARAMETER
	var directory: String = path.get_base_dir()
	if not directory.is_empty() and not DirAccess.dir_exists_absolute(directory):
		var made: Error = DirAccess.make_dir_recursive_absolute(directory)
		if made != OK:
			return made
	var file: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return FileAccess.get_open_error()
	file.store_string(JSON.stringify(_build_report(), "\t"))
	file.close()
	return OK


# --- Bucle del tick ---------------------------------------------------------------------------

func _physics_process(delta: float) -> void:
	if _run_state == _RunState.STOPPING:
		_drain_stop()
		return
	if _run_state != _RunState.RUNNING:
		return
	_metrics.begin_tick()

	_metrics.begin_section(&"net")
	if _transport != null:
		_grant_stall_credit()
		_transport.poll(_tick)
	_run_console_lines()
	_metrics.begin_section(SECTION_PLATFORM)
	_poll_platform()
	_metrics.end_section(SECTION_PLATFORM)
	_metrics.end_section(&"net")

	_tick += 1
	var s: int = _tick

	_check_loading_timeouts(s)
	_check_hello_timeouts(s)
	_process_departures(s)

	_metrics.begin_section(SECTION_NPC_BRAINS)
	_run_npc_brains(s)
	_metrics.end_section(SECTION_NPC_BRAINS)

	_metrics.begin_section(&"sim")
	_refresh_siege_views()
	_simulate_players(s, delta)
	_metrics.end_section(&"sim")

	_metrics.begin_section(&"combat")
	_combat.process_tick(s, _players_root.get_world_3d().direct_space_state)
	_emit_npc_telegraphs(s)
	_metrics.end_section(&"combat")

	# Paso 4b (docs/fuerte.md, 1.7): las fortalezas, con lo que ha dejado el combate.
	_metrics.begin_section(SECTION_WAR)
	_fortresses.step(s)
	_process_unstuck(s)
	_metrics.end_section(SECTION_WAR)
	if _npc_system != null:
		_metrics.begin_section(SECTION_NPC)
		_npc_system.step(s)
		_metrics.end_section(SECTION_NPC)
	_check_shutdown_countdown(s)

	_process_arrivals(s)
	_metrics.begin_section(SECTION_SOCIAL)
	_social.step(s)
	_metrics.end_section(SECTION_SOCIAL)

	_metrics.begin_section(&"history")
	_record_history(s)
	_metrics.end_section(&"history")

	_metrics.begin_section(&"snapshot")
	_send_snapshots(s)
	if s % SCOREBOARD_INTERVAL_TICKS == 0:
		_send_scoreboard()
	_metrics.end_section(&"snapshot")

	_metrics.begin_section(&"flush")
	if _transport != null:
		_transport.flush()
	_metrics.end_section(&"flush")

	_metrics.end_tick(s)
	if s % METRICS_LOG_TICKS == 0:
		_log_metrics(s)
	tick_finished.emit(s)


# Si el servidor ha perdido ticks respecto al reloj (un parón del proceso: Godot solo recupera 8 por
# fotograma), los clientes siguieron enviando un lote por tick y todo llega junto en este poll, con
# el tick del servidor sin avanzar: el cubo no se recargaría y lo más nuevo se descartaría como
# exceso de ritmo. Se da a cada peer el crédito de los ticks perdidos (ver
# ServerPeer.grant_stall_credit). Los ticks reales son un reloj entero, así que la suma de lo
# concedido no pasa de los ticks que de verdad han transcurrido.
func _grant_stall_credit() -> void:
	var elapsed_usec: int = Time.get_ticks_usec() - _clock_origin_usec
	var real_tick: int = elapsed_usec * Engine.physics_ticks_per_second / 1000000
	var missed_ticks: int = real_tick - _last_poll_real_tick - 1
	_last_poll_real_tick = real_tick
	if missed_ticks <= 0:
		return
	for peer: ServerPeer in _peers.values():
		peer.grant_stall_credit(_tick, missed_ticks)


# Paso 0 del tick (docs/fuerte.md, 1.7): los cerebros de los PNJ piensan con el estado de los cuerpos tras s - 1
# (antes de simular a nadie) y empujan su entrada de s a su cola, por net_id ascendente. Entre pensamientos
# repiten su plan.
func _run_npc_brains(s: int) -> void:
	if _npcs.is_empty():
		return
	if _npc_system != null:
		_npc_system.begin_tick(s)
	var ids: Array[int] = []
	ids.assign(_npcs.keys())
	ids.sort()
	for net_id: int in ids:
		var entity: NetEntity = _registry.get_entity(net_id)
		var queue: InputQueue = _queues.get(net_id)
		var brain: BotBrain = _npcs.get(net_id)
		if entity == null or queue == null or brain == null or entity.get_character() == null:
			continue
		var character: PlayerCharacter = entity.get_character()
		var generated: PlayerInput = brain.next_input(s, character.global_position, character.yaw)
		generated.tick = s
		queue.push(generated.quantized(), 0, s)


# Aviso TELEGRAPH (docs/fuerte.md, sección 5) de cada ataque fuerte que un PNJ lanza en el tick [param s]: la zona
# de peligro (un sector delante de él, con el alcance del golpe) y los ticks que faltan hasta el impacto, para que
# el cliente la dibuje y la rellene. Los ligeros no se avisan: su anticipación ya se ve en el movimiento.
func _emit_npc_telegraphs(s: int) -> void:
	for net_id: int in _npcs:
		var entity: NetEntity = _registry.get_entity(net_id)
		var character: PlayerCharacter = entity.get_character() if entity != null else null
		if character == null:
			continue
		var state: CombatState = character.combat
		if state.action != CombatState.Action.HEAVY or state.action_tick != s:
			continue
		var attack: AttackTicks = CombatCatalog.attack(state.action_id)
		if attack == null or attack.shape == null:
			continue
		_telegraphs_sent += 1
		_combat.emit_event(NetMessages.EntityEvent.telegraph(net_id, s, attack.id,
				NetMessages.EntityEvent.SHAPE_SECTOR, entity.get_position(), character.yaw,
				roundi(attack.shape.range_m * 100.0), attack.windup_ticks), PackedInt32Array([net_id]))


# Pone al día las vistas de asedio con el estado vivo de las fortalezas (el de después del tick anterior, como los
# cerebros de los PNJ): lo que ven los falsos con cerebro SIEGE al decidir su entrada del tick s.
func _refresh_siege_views() -> void:
	for fortress_id: StringName in _siege_views:
		var state: FortressState = _fortresses.get_fortress_state(fortress_id)
		if state != null:
			_siege_views[fortress_id].update_from_state(state)


# Simula a todas las entidades con cuerpo (jugadores, falsos y PNJ) por net_id ascendente con la
# entrada de take(s).
func _simulate_players(s: int, delta: float) -> void:
	var inputs_consumed: int = 0
	var inputs_substituted: int = 0
	var logging_states: bool = _state_log != null
	for entity: NetEntity in _registry.get_sorted():
		var character: PlayerCharacter = entity.get_character()
		var queue: InputQueue = _queues.get(entity.net_id)
		if character == null or queue == null:
			continue
		var before: Vector3 = character.global_position
		var brain: BotBrain = _fakes.get(entity.net_id)
		# Los PNJ ya empujaron su entrada en el paso 0 (_run_npc_brains); los falsos la generan aquí.
		var synthetic: bool = brain != null or _npcs.has(entity.net_id)
		if brain != null:
			var generated: PlayerInput = brain.next_input(s, before, character.yaw)
			generated.tick = s
			queue.push(generated.quantized(), 0, s)
		elif _npcs.has(entity.net_id):
			pass
		elif _lingering.has(entity.net_id):
			# El cuerpo de quien salió en combate: entradas neutras de verdad (sin botones), quieto.
			synthetic = true
			queue.push(NetProtocol.neutral_input(s, character.yaw), 0, s)
		var substitutions_before: int = queue.substitutions_total
		var input: PlayerInput = queue.take(s)
		var was_substituted: bool = queue.substitutions_total != substitutions_before
		if not synthetic:
			inputs_consumed += 1
			if was_substituted:
				inputs_substituted += 1
			var record: _PlayerRecord = _player_by_net.get(entity.net_id)
			if record != null:
				record.inputs += 1
		if logging_states:
			_substituted_now[entity.net_id] = 1 if was_substituted else 0
		var simulate_start: int = Time.get_ticks_usec()
		character.simulate(input, delta)
		var simulate_usec: int = Time.get_ticks_usec() - simulate_start
		_simulate_calls += 1
		_simulate_usec_total += simulate_usec
		_simulate_usec_max = maxi(_simulate_usec_max, simulate_usec)
		_check_motion(entity, before)
	if inputs_consumed > 0:
		_metrics.add_counter(ServerMetrics.COUNTER_INPUTS, inputs_consumed)
		_metrics.add_counter(ServerMetrics.COUNTER_SUBSTITUTIONS, inputs_substituted)


# El servidor no acepta estado del cliente, así que estas comprobaciones solo detectan errores
# propios: un salto de más de 1,5 m en un tick se anota como error de física, y una posición que no
# es finita devuelve al jugador a su punto de aparición. (Caer por debajo de FALL_LIMIT_Y es una
# muerte: la resuelve el paso de combate.) Un muerto no se comprueba: su cuerpo lo coloca el combate.
func _check_motion(entity: NetEntity, before: Vector3) -> void:
	var character: PlayerCharacter = entity.get_character()
	if character.combat.action == CombatState.Action.DEAD:
		return
	var after: Vector3 = character.global_position
	if not after.is_finite() or after.distance_to(before) > MAX_STEP_DISTANCE:
		_physics_errors += 1
		if _physics_errors <= MAX_LOGGED_PHYSICS_ERRORS:
			push_warning("[Eldmark] Error de física: %s se movió %.2f m en un tick (de %s a %s)"
					% [entity.display_name, after.distance_to(before), before, after])
	if not after.is_finite():
		var spawn: Transform3D = _spawn_picker.pick(entity.realm)
		_place(entity, spawn.origin, _yaw_of(spawn))
		_respawns += 1
		_log("%s tiene una posición no válida y reaparece en %s" % [entity.display_name,
				spawn.origin])


# Coloca al personaje en [param position] con el [param yaw] dado y velocidad 0. El estado pasa por
# encode/decode (es el que reconstruirá el cliente) y el contador de teletransporte sube.
func _place(entity: NetEntity, position: Vector3, yaw: float) -> void:
	var character: PlayerCharacter = entity.get_character()
	var state: PlayerState = character.get_state()
	state.position = position
	state.velocity = Vector3.ZERO
	state.yaw = PlayerState.to_f32(yaw)
	state.grounded = _probe_grounded(position)
	state.coyote_ticks = 0
	state.jump_buffer_ticks = 0
	character.set_state(PlayerState.decode(state.encode()))
	entity.teleport_counter = (entity.teleport_counter + 1) & EntityRecord.TELEPORT_MASK


# --- Altas y bajas ----------------------------------------------------------------------------

# Da de alta, con el estado «tras s», a los peers cuyo CLIENT_READY llegó en este tick.
func _process_arrivals(s: int) -> void:
	if _pending_ready.is_empty():
		return
	var pending: Array[int] = _pending_ready.duplicate()
	_pending_ready.clear()
	for peer_id: int in pending:
		var peer: ServerPeer = _peers.get(peer_id)
		if peer == null or peer.state != ServerPeer.State.LOADING:
			continue
		var entity: NetEntity = _create_player(peer.display_name, peer.realm, peer_id, s)
		if entity == null:
			_kick(peer, "no queda sitio en la zona", false)
			continue
		if peer.claimed != null:
			# Desde aquí el arrendamiento es del cuerpo: se libera cuando se va (P5: con su guardado final).
			entity.is_staff = peer.claimed.is_staff()
			_claims_by_net[entity.net_id] = peer.claimed
		peer.entity = entity
		peer.input_queue = _queues[entity.net_id]
		peer.state = ServerPeer.State.IN_WORLD
		var record: _PlayerRecord = _player_by_net[entity.net_id]
		record.peer = peer
		_world_peers.append(peer)
		# La plantilla pendiente (LOADOUT_SELECT, también antes de CLIENT_READY) o la de por defecto: el SPAWN ya
		# sale con sus armas y sus cargas, y el LOADOUT detrás.
		var combatant: Combatant = _combat.get_combatant(entity.net_id)
		_combat.equip_template(combatant, maxi(peer.pending_template_id, 0))
		peer.pending_template_id = -1
		_announce_arrival(entity, peer, s)
		if combatant.template_id > 0:
			_combat.announce_loadout(combatant, s, true)
		player_joined.emit(peer_id, entity.net_id)
		if _filler_keeper != null:
			_filler_keeper.on_person_joined(peer.realm, peer_id)
		_log("Alta de %s (peer %d, net_id %d, %s) en %s; jugadores: %d" % [entity.display_name,
				peer_id, entity.net_id, NetProtocol.realm_display_name(peer.realm),
				entity.get_position(), get_player_count()])


# Crea la entidad y el personaje de un jugador en un punto de aparición de su reino y le da su
# combate. Ver _create_body.
func _create_player(display_name: String, realm: int, owner_peer: int, s: int) -> NetEntity:
	var spawn: Transform3D = _spawn_picker.pick(realm)
	var entity: NetEntity = _create_body(NetProtocol.EntityKind.PLAYER, display_name, realm,
			owner_peer, s, spawn.origin, _yaw_of(spawn))
	if entity == null:
		return null
	var queue: InputQueue = _queues[entity.net_id]

	var record := _PlayerRecord.new()
	record.net_id = entity.net_id
	record.peer_id = owner_peer
	record.display_name = display_name
	record.realm = realm
	record.joined_tick = s
	record.queue = queue
	record.entity = entity
	_player_by_net[entity.net_id] = record
	_player_log.append(record)
	_trim_player_log()
	_joined_total += 1
	_metrics.add_counter(ServerMetrics.COUNTER_PLAYERS, 1)
	_peak_players = maxi(_peak_players, _metrics.get_counter(ServerMetrics.COUNTER_PLAYERS))
	return entity


# Crea la entidad de tipo [param kind] con su cuerpo (un PlayerCharacter) en [param spawn_origin]
# mirando a [param spawn_yaw], su cola de entradas, su pista del historial y su combate. El estado es
# «el estado tras s», redondeado por encode/decode; la cola empieza con el tick s ya consumido y la
# entrada neutra como última aplicada. null si no quedan ids.
func _create_body(kind: int, display_name: String, realm: int, owner_peer: int, s: int,
		spawn_origin: Vector3, spawn_yaw: float) -> NetEntity:
	var entity: NetEntity = _registry.allocate(kind, s)
	if entity == null:
		return null
	entity.realm = realm
	entity.owner_peer = owner_peer
	entity.display_name = display_name

	var character: PlayerCharacter = _instantiate_character()
	character.name = ("Player%d" if kind == NetProtocol.EntityKind.PLAYER else "Npc%d") % entity.net_id
	_players_root.add_child(character)
	# Después de _ready() (que reescribe la máscara): las puertas cerradas de los fuertes paran a
	# los reinos que no son su dueño. El cliente hace lo mismo con su personaje local.
	character.set_realm_collision(realm)
	var state := PlayerState.new()
	state.position = spawn_origin
	state.yaw = PlayerState.to_f32(spawn_yaw)
	state.grounded = _probe_grounded(spawn_origin)
	state.last_input_tick = s
	state = PlayerState.decode(state.encode())
	character.set_state(state)
	entity.node = character

	var queue := InputQueue.new()
	queue.reset(s, NetProtocol.neutral_input(s, state.yaw))
	_queues[entity.net_id] = queue
	_history.add_entity(entity.net_id)
	_combat.add(entity, queue, _peers.get(owner_peer))
	return entity


# Mantiene el anillo del informe en max_logged_players fichas: saca la más antigua de las de quien ya
# se ha ido (las de quien sigue dentro se quedan, aunque el anillo se pase) y la resume en totales.
func _trim_player_log() -> void:
	while _player_log.size() > max_logged_players:
		var index: int = -1
		for i: int in _player_log.size():
			if _player_log[i].left_tick >= 0:
				index = i
				break
		if index < 0:
			return
		var record: _PlayerRecord = _player_log[index]
		_player_log.remove_at(index)
		_archived_players += 1
		if record.is_fake:
			_archived_fakes += 1
		else:
			_archived_inputs += record.inputs
			_archived_substituted += record.substituted
			_archived_late += record.late
			_archived_too_early += record.too_early


# Mensajes de un alta (sección 3): el SPAWN propio, los de todo lo relevante para el recién
# llegado y el suyo para quien lo tenga por relevante. [param peer] es null en un jugador falso.
# El SPAWN de un jugador lleva su nivel solo hacia su reino (protocolo 7, docs/progresion.md §7.3): el del
# recién llegado se codifica una vez por reino receptor (tres variantes como mucho) y los de los demás hacia él,
# con su reino.
func _announce_arrival(entity: NetEntity, peer: ServerPeer, s: int) -> void:
	var spawn_by_realm: Dictionary[int, PackedByteArray] = {}
	if peer != null:
		_send(peer, NetProtocol.CH_RELIABLE, entity.encode_spawn(s, true))
	for other: NetEntity in _registry.get_sorted():
		if other == entity:
			continue
		if peer != null and _is_relevant(entity, other, false):
			peer.relevant[other.net_id] = true
			_send(peer, NetProtocol.CH_RELIABLE, other.encode_spawn(s, false, entity.realm))
		var other_peer: ServerPeer = _peers.get(other.owner_peer)
		if other_peer != null and other_peer.state == ServerPeer.State.IN_WORLD \
				and _is_relevant(other, entity, false):
			other_peer.relevant[entity.net_id] = true
			if not spawn_by_realm.has(other.realm):
				spawn_by_realm[other.realm] = entity.encode_spawn(s, false, other.realm)
			_send(other_peer, NetProtocol.CH_RELIABLE, spawn_by_realm[other.realm])


# Cierra la sesión de los peers que se van: DESPAWN (motivo 1) a quien los tenía por relevantes, id
# en cuarentena, personaje liberado y pista del historial borrada.
func _process_departures(s: int) -> void:
	_process_lingering(s)
	_process_fake_departures(s)
	if _leaving.is_empty():
		return
	var leaving: Array[int] = _leaving.duplicate()
	_leaving.clear()
	for peer_id: int in leaving:
		var peer: ServerPeer = _peers.get(peer_id)
		if peer == null:
			continue
		_peers.erase(peer_id)
		_rtt.erase(peer_id)
		_social.on_peer_left(peer, s)
		if peer.entity == null:
			# Se va sin haber entrado: si el relleno le había apartado una plaza, se libera (GUE-43; ningún falso se
			# había ido).
			if _filler_keeper != null:
				_filler_keeper.release_seat(peer_id)
			continue
		var entity: NetEntity = peer.entity
		# Fuera de la lista antes de nada: lo que salga de su baja (la muerte de un derribado) ya no es para él.
		_world_peers.erase(peer)
		var lingers: bool = not peer.drop_body_at_once and _should_linger(entity, s)
		if lingers:
			_start_lingering(entity, s)
		else:
			_remove_player(entity, s, NetProtocol.DespawnReason.DISCONNECTED)
		_left_total += 1
		player_left.emit(peer_id, entity.net_id)
		if _filler_keeper != null:
			_filler_keeper.on_person_left(peer.realm)
		var linger_note: String = ""
		if lingers:
			linger_note = "; su cuerpo se queda %.0f s por estar en combate" \
					% (float(linger_ticks) / float(Engine.physics_ticks_per_second))
		_log("Baja de %s (peer %d, net_id %d); jugadores: %d%s" % [entity.display_name, peer_id,
				entity.net_id, get_player_count(), linger_note])


# Bajas de los jugadores falsos pedidas con remove_fake_player().
func _process_fake_departures(s: int) -> void:
	if _fake_leaving.is_empty():
		return
	var leaving: Array[int] = _fake_leaving.duplicate()
	var quietly: Dictionary[int, bool] = _fake_leaving_quietly.duplicate()
	_fake_leaving.clear()
	_fake_leaving_quietly.clear()
	for net_id: int in leaving:
		var entity: NetEntity = _registry.get_entity(net_id)
		if entity == null or not _fakes.has(net_id):
			continue
		_remove_player(entity, s, NetProtocol.DespawnReason.DISCONNECTED, not quietly.has(net_id))
		_left_total += 1
		if _filler_keeper != null:
			_filler_keeper.forget(net_id)
		_log("Baja de %s (jugador falso, net_id %d); jugadores: %d" % [entity.display_name, net_id,
				get_player_count()])


# Quita al jugador del mundo: DESPAWN a quien lo veía, id en cuarentena y personaje liberado. La baja de un
# derribado (salida, desconexión, --fake-churn, fin del cuerpo de GUE-41) es antes una muerte en ese tick: DEATH
# y KILL con quien le hizo el último daño o lo derribó, y la fuente «desangrado» (docs/habilidades.md, 4.5). Sin
# [param bleed] (el falso de relleno que cede su sitio a una persona, retire_filler), no: solo el DESPAWN.
func _remove_player(entity: NetEntity, s: int, reason: int, bleed: bool = true) -> void:
	var net_id: int = entity.net_id
	var leaving: Combatant = _combat.get_combatant(net_id)
	if bleed and leaving != null and leaving.is_downed():
		_combat.kill_downed(leaving, s)
	var despawn := NetMessages.EntityDespawn.new()
	despawn.net_id = net_id
	despawn.despawn_tick = s
	despawn.reason = reason
	var bytes: PackedByteArray = despawn.encode()
	for other: ServerPeer in _world_peers:
		if other.entity == entity:
			continue
		if other.relevant.erase(net_id):
			_send(other, NetProtocol.CH_RELIABLE, bytes)
		other.priority.erase(net_id)
	var record: _PlayerRecord = _player_by_net.get(net_id)
	if record != null:
		record.close(s)
		_player_by_net.erase(net_id)
	_release_claim_of(net_id)
	_queues.erase(net_id)
	_fakes.erase(net_id)
	_npcs.erase(net_id)
	_lingering.erase(net_id)
	_scores.forget(net_id)
	_combat.remove(net_id, s)
	_history.forget(net_id)
	_substituted_now.erase(net_id)
	var character: PlayerCharacter = entity.get_character()
	if character != null:
		if character.get_parent() != null:
			character.get_parent().remove_child(character)
		character.queue_free()
	entity.node = null
	_registry.release(net_id, s)
	if entity.kind == NetProtocol.EntityKind.PLAYER:
		_metrics.add_counter(ServerMetrics.COUNTER_PLAYERS, -1)


# Libera a todos los jugadores (cierre del servidor), sin enviar DESPAWN.
func _clear_players() -> void:
	for net_id: int in _claims_by_net.keys():
		_release_claim_of(net_id)
	for entity: NetEntity in _registry.get_sorted().duplicate():
		var character: PlayerCharacter = entity.get_character()
		if character != null:
			if character.get_parent() != null:
				character.get_parent().remove_child(character)
			character.queue_free()
		entity.node = null
		_registry.release(entity.net_id, _tick)
	_world_peers.clear()
	_queues.clear()
	_fakes.clear()
	_npcs.clear()
	_lingering.clear()
	_scores.clear()
	if _fortresses != null:
		_fortresses.clear()
	if _combat != null:
		_combat.clear()
	_projectile_viewers.clear()
	_player_by_net.clear()
	_substituted_now.clear()
	for peer: ServerPeer in _peers.values():
		peer.entity = null
		peer.input_queue = null
		peer.relevant.clear()
		peer.priority.clear()
	_metrics.add_counter(ServerMetrics.COUNTER_PLAYERS,
			-_metrics.get_counter(ServerMetrics.COUNTER_PLAYERS))


# Peers que llevan demasiado cargando la zona sin enviar CLIENT_READY.
func _check_loading_timeouts(s: int) -> void:
	if s % 60 != 0:
		return
	for peer: ServerPeer in _peers.values():
		if peer.state == ServerPeer.State.LOADING \
				and s - peer.loading_since_tick >= loading_timeout_ticks:
			_kick(peer, "se agotó el tiempo de carga de la zona")


# Peers que llevan demasiado conectados sin mandar el HELLO: cada conexión ociosa ocupa una plaza de
# ENet (max_players + 4) hasta que vence el plazo de 5 s de SceneMultiplayer, y reabrirla cuesta un
# RTT. Se cortan con un plazo propio mucho más corto, sin REJECT (no hay nada a lo que contestar).
func _check_hello_timeouts(s: int) -> void:
	if s % HELLO_CHECK_TICKS != 0:
		return
	for peer: ServerPeer in _peers.values():
		if peer.state == ServerPeer.State.AUTHENTICATING \
				and s - peer.connected_tick >= hello_timeout_ticks:
			_rejects[HELLO_TIMEOUT_REASON] = _rejects.get(HELLO_TIMEOUT_REASON, 0) + 1
			_log("Conexión de %s (peer %d) cortada: %s" % [peer.remote_address, peer.peer_id,
					HELLO_TIMEOUT_REASON])
			_transport.disconnect_after_flush(peer.peer_id)
			_mark_leaving(peer)


# --- Historial, interés y snapshots -----------------------------------------------------------

# StateHistory.record() de todas las entidades (y el CSV de --state-log), tras simular y dar de
# alta: es el estado «tras s».
func _record_history(s: int) -> void:
	for entity: NetEntity in _registry.get_sorted():
		if entity.kind == NetProtocol.EntityKind.STRUCTURE:
			continue
		var character: PlayerCharacter = entity.get_character()
		var position: Vector3 = entity.get_position()
		var yaw: float = 0.0
		var flags: int = (entity.teleport_counter & EntityRecord.TELEPORT_MASK) \
				<< EntityRecord.TELEPORT_SHIFT
		if character != null:
			yaw = character.yaw
			if character.grounded:
				flags |= EntityRecord.FLAG_GROUNDED
			# Banderas defensivas (bloqueo, parada, invulnerable, muerto, bloqueo ancho) para el
			# rebobinado, sobre los bits 0-2 del registro: el bit 3 del registro (ranura 2, que aquí no se
			# escribe) nunca entra, porque en el historial es DEFENSE_BLOCKING (docs/habilidades.md, 3.6).
			flags = (flags & EntityRecord.HISTORY_FLAGS_MASK) \
					| ActionMachine.defense_flags(character.combat, s)
		else:
			flags |= EntityRecord.FLAG_GROUNDED
			if is_instance_valid(entity.node):
				yaw = entity.node.rotation.y
		_history.record(s, entity.net_id, position, yaw, flags)
		# El registro de estados es solo de jugadores: un PNJ no tiene cliente con el que compararse.
		if _state_log != null and character != null \
				and entity.kind == NetProtocol.EntityKind.PLAYER:
			_state_log.store_line("%d,%d,%d,%s" % [s, entity.net_id,
					_substituted_now.get(entity.net_id, 0),
					character.get_state().encode().hex_encode()])
	if _state_log != null and s % STATE_LOG_FLUSH_TICKS == 0:
		_state_log.flush()
	if _combat_log != null and s % STATE_LOG_FLUSH_TICKS == 0:
		_combat_log.flush()
	if _battle_log != null and s % STATE_LOG_FLUSH_TICKS == 0:
		_battle_log.flush()
	_substituted_now.clear()


# Interés escalonado y un SNAPSHOT a cada cliente cada SNAPSHOT_INTERVAL_TICKS ticks, escalonado
# por la paridad de su net_id.
func _send_snapshots(s: int) -> void:
	if _world_peers.is_empty() or _transport == null:
		return
	var entities: Array[NetEntity] = _registry.get_sorted()
	for peer: ServerPeer in _world_peers:
		if (s + peer.entity.net_id) % INTEREST_INTERVAL_TICKS == 0:
			_refresh_interest(peer, entities, s)
	var receivers: Array[ServerPeer] = []
	for peer: ServerPeer in _world_peers:
		var interval: int = NetProtocol.SNAPSHOT_INTERVAL_TICKS
		if s % interval == peer.entity.net_id % interval:
			receivers.append(peer)
	if receivers.is_empty():
		return
	var build_start: int = Time.get_ticks_usec()
	_snapshot_builder.begin(s, entities)
	for peer: ServerPeer in receivers:
		var packet: PackedByteArray = _snapshot_builder.build_for(peer)
		_snapshots_sent += 1
		_snapshot_bytes_total += packet.size()
		_snapshot_bytes_max = maxi(_snapshot_bytes_max, packet.size())
		_transport.send(peer.peer_id, NetProtocol.CH_SNAPSHOT, packet)
	_snapshot_build_usec += Time.get_ticks_usec() - build_start


# Recalcula lo que ve [param peer]: cada cambio genera un SPAWN o un DESPAWN (motivo 0).
func _refresh_interest(peer: ServerPeer, entities: Array[NetEntity], s: int) -> void:
	var observer: NetEntity = peer.entity
	for entity: NetEntity in entities:
		if entity == observer:
			continue
		var was_relevant: bool = peer.relevant.get(entity.net_id, false)
		var now_relevant: bool = _is_relevant(observer, entity, was_relevant)
		if now_relevant == was_relevant:
			continue
		if now_relevant:
			peer.relevant[entity.net_id] = true
			_send(peer, NetProtocol.CH_RELIABLE, entity.encode_spawn(s, false, observer.realm))
		else:
			peer.relevant.erase(entity.net_id)
			peer.priority.erase(entity.net_id)
			var despawn := NetMessages.EntityDespawn.new()
			despawn.net_id = entity.net_id
			despawn.despawn_tick = s
			despawn.reason = NetProtocol.DespawnReason.OUT_OF_INTEREST
			_send(peer, NetProtocol.CH_RELIABLE, despawn.encode())


# Las entidades con ALWAYS_RELEVANT no pasan por la política.
func _is_relevant(observer: NetEntity, entity: NetEntity, was_relevant: bool) -> bool:
	if (entity.flags & NetEntity.FLAG_ALWAYS_RELEVANT) != 0:
		return true
	return interest_policy.is_relevant(observer, entity, was_relevant)


func _send(peer: ServerPeer, channel: int, bytes: PackedByteArray) -> void:
	if _transport != null:
		_transport.send(peer.peer_id, channel, bytes)


# Lo que el servicio social necesita del servidor: los peers en el mundo y enviar por el canal fiable.
func _social_peers() -> Array[ServerPeer]:
	return _world_peers


func _social_send(peer_id: int, bytes: PackedByteArray) -> void:
	if _transport != null:
		_transport.send(peer_id, NetProtocol.CH_RELIABLE, bytes)


# --- Combate: eventos, enemigos, suelo ----------------------------------------------------------

# Un evento de combate: ENTITY_EVENT (canal fiable) a los dueños de las entidades implicadas
# (víctima, atacante, asesino y asistentes) y a quien tenga relevante a cualquiera de ellas. Los KILL y los
# DOWNED van a toda la zona (el registro de bajas lo ve todo el mundo, docs/fuerte.md sección 6, y
# docs/habilidades.md, sección 5.4). STATUS, HEAL e INTERACT van a los dueños de los implicados y a quien
# tenga relevante al afectado (no al autor). LOADOUT ([signal CombatDirector.event_emitted]): la del dueño
# ([param involved] con el jugador) solo a él; la pública ([param involved] vacío, cargas 0) a quien tenga
# relevante al jugador, sin el dueño. Antes de enviarlo se apunta en el marcador y en el registro de batalla.
func _on_combat_event(event: NetMessages.EntityEvent, involved: PackedInt32Array) -> void:
	_track_battle(event)
	if _transport == null or _world_peers.is_empty():
		return
	_metrics.begin_section(SECTION_COMBAT_EVENTS)
	var bytes: PackedByteArray = event.encode()
	var kind: int = event.event
	var to_everyone: bool = kind == NetMessages.EntityEvent.Kind.KILL \
			or kind == NetMessages.EntityEvent.Kind.DOWNED
	var seen_by: PackedInt32Array = involved
	if kind == NetMessages.EntityEvent.Kind.STATUS or kind == NetMessages.EntityEvent.Kind.HEAL \
			or kind == NetMessages.EntityEvent.Kind.INTERACT:
		seen_by = PackedInt32Array([event.net_id])
	elif kind == NetMessages.EntityEvent.Kind.LOADOUT:
		# La del dueño no la ve nadie más; la pública, quien lo tenga relevante.
		seen_by = PackedInt32Array() if not involved.is_empty() else PackedInt32Array([event.net_id])
	for peer: ServerPeer in _world_peers:
		if kind == NetMessages.EntityEvent.Kind.LOADOUT and involved.is_empty() \
				and peer.entity.net_id == event.net_id:
			continue
		var receives: bool = to_everyone or involved.has(peer.entity.net_id)
		if not receives:
			for net_id: int in seen_by:
				if peer.relevant.get(net_id, false):
					receives = true
					break
		if receives:
			_transport.send(peer.peer_id, NetProtocol.CH_RELIABLE, bytes)
			_events_sent += 1
			_event_bytes_sent += bytes.size()
	_metrics.end_section(SECTION_COMBAT_EVENTS)


# Alta de un proyectil (docs/habilidades.md, sección 4.4): ENTITY_SPAWN de kind 3 (canal fiable) al dueño del
# tirador y a quien lo tenga relevante, en ese momento. Se apunta quién lo recibió para mandarle la baja.
func _on_projectile_spawned(spawn: NetMessages.EntitySpawn, involved: PackedInt32Array) -> void:
	if _transport == null or _world_peers.is_empty():
		return
	_metrics.begin_section(SECTION_COMBAT_EVENTS)
	var bytes: PackedByteArray = spawn.encode()
	var viewers := PackedInt32Array()
	for peer: ServerPeer in _world_peers:
		var receives: bool = involved.has(peer.entity.net_id)
		if not receives:
			for net_id: int in involved:
				if peer.relevant.get(net_id, false):
					receives = true
					break
		if receives:
			_transport.send(peer.peer_id, NetProtocol.CH_RELIABLE, bytes)
			viewers.append(peer.peer_id)
			_projectile_messages_sent += 1
			_projectile_bytes_sent += bytes.size()
	if not viewers.is_empty():
		_projectile_viewers[spawn.net_id] = viewers
	_metrics.end_section(SECTION_COMBAT_EVENTS)


# Baja de un proyectil: ENTITY_DESPAWN (motivo 4 impacto o 5 caducado) a los que recibieron su alta y siguen
# en el mundo, aunque ya no tengan relevante al tirador.
func _on_projectile_despawned(projectile_id: int, tick: int, reason: int,
		_involved: PackedInt32Array) -> void:
	var viewers: PackedInt32Array = _projectile_viewers.get(projectile_id, PackedInt32Array())
	_projectile_viewers.erase(projectile_id)
	if _transport == null or viewers.is_empty():
		return
	var despawn := NetMessages.EntityDespawn.new()
	despawn.net_id = projectile_id
	despawn.despawn_tick = tick
	despawn.reason = reason
	var bytes: PackedByteArray = despawn.encode()
	for peer_id: int in viewers:
		var peer: ServerPeer = _peers.get(peer_id)
		if peer == null or peer.state != ServerPeer.State.IN_WORLD:
			continue
		_transport.send(peer_id, NetProtocol.CH_RELIABLE, bytes)
		_projectile_messages_sent += 1
		_projectile_bytes_sent += bytes.size()


# Marcador y registro de batalla: una muerte suma una muerte a la víctima (si es un jugador) y queda en el
# registro; un KILL suma una baja al asesino y una asistencia a cada asistente (si son jugadores).
func _track_battle(event: NetMessages.EntityEvent) -> void:
	match event.event:
		NetMessages.EntityEvent.Kind.DEATH:
			var victim: NetEntity = _registry.get_entity(event.net_id)
			if victim == null:
				return
			if victim.kind == NetProtocol.EntityKind.PLAYER:
				_scores.add_death(victim.net_id)
			if _battle_log != null:
				_battle_log.log_death(event.tick, victim,
						_registry.get_entity(event.killer) if event.killer != 0 else null,
						event.attack_id, victim.get_position())
		NetMessages.EntityEvent.Kind.KILL:
			if _is_player(event.killer):
				_scores.add_kill(event.killer)
			for assistant: int in event.assistants:
				if _is_player(assistant):
					_scores.add_assist(assistant)


func _is_player(net_id: int) -> bool:
	var entity: NetEntity = _registry.get_entity(net_id)
	return entity != null and entity.kind == NetProtocol.EntityKind.PLAYER


# Un punto de aparición del reino (para colocar a quien cae fuera del mundo mientras está muerto).
func _pick_spawn_point(realm: int) -> Transform3D:
	return _spawn_picker.pick(realm)


# El enemigo vivo (o derribado) más cercano a [param position] para el jugador falso [param net_id] (el cerebro de
# combate de BotBrain): un BotTarget con sus pies, su velocidad y si está derribado (lo que usa el kit para el tiro
# adelantado del arco y para rematar, H5), o null si no hay ninguno que pueda atacar o ser atacado: los maniquíes,
# los protegidos y los que están en la zona segura de su reino no cuentan, y quien está en la zona segura de su
# reino (o no está en pie) no ataca. Los objetivos se reúnen una vez por tick y por reino (con muchos bots, cada uno
# recorre solo los candidatos de los reinos que le son hostiles). Con [param npcs_only], solo los PNJ (el buscador de
# defensores del cerebro SIEGE, F6b). «Más cercano» con la altura pesada (BotBrain.target_distance_squared, GUE-45):
# el de su nivel antes que el de la pasarela.
func _find_enemy_target(position: Vector3, net_id: int, npcs_only: bool = false) -> Variant:
	var me: Combatant = _combat.get_combatant(net_id)
	if me == null or not me.is_alive() or _safe_areas.contains_own(me.get_realm(), position):
		return null
	if _targets_tick != _tick:
		_rebuild_target_cache()
	var best_realm: int = -1
	var best_index: int = -1
	var best_distance: float = INF
	for realm: int in _targets_by_realm:
		if not _is_hostile_realm(me.get_realm(), realm):
			continue
		var positions: PackedVector3Array = _targets_by_realm[realm]
		var npc_flags: PackedByteArray = _targets_npc_by_realm[realm]
		for index: int in positions.size():
			if _targets_ids_by_realm[realm][index] == net_id or (npcs_only and npc_flags[index] == 0):
				continue
			var distance: float = BotBrain.target_distance_squared(position, positions[index])
			if distance < best_distance:
				best_distance = distance
				best_realm = realm
				best_index = index
	if best_index < 0:
		return null
	return BotTarget.new(_targets_by_realm[best_realm][best_index],
			_targets_velocity_by_realm[best_realm][best_index],
			_targets_downed_by_realm[best_realm][best_index] != 0,
			_targets_ids_by_realm[best_realm][best_index])


# Kit de los falsos (H5): el estado de combate del jugador falso [param net_id] tras el último tick (null si ya
# no está).
func _fake_combat_state(net_id: int) -> CombatState:
	var entity: NetEntity = _registry.get_entity(net_id)
	var character: PlayerCharacter = entity.get_character() if entity != null else null
	return character.combat if character != null else null


# Kit de los falsos de asedio: la línea de tiro del arco (BotBrain.set_line_of_sight) en el mundo del servidor.
func _bot_line_of_sight(from_feet: Vector3, to_feet: Vector3, left_shoulder: bool) -> bool:
	return BotBrain.bow_sight_clear(get_physics_space(), from_feet, to_feet, left_shoulder)


# Kit de los falsos: la fracción de vida del jugador falso [param net_id] (0 derribado o muerto).
func _fake_health_fraction(net_id: int) -> float:
	var combatant: Combatant = _combat.get_combatant(net_id)
	if combatant == null or combatant.max_health <= 0:
		return 1.0
	return float(combatant.health) / float(combatant.max_health)


# Kit de los falsos: los pies del aliado derribado (un jugador de su reino) más cercano a [param position] para el
# jugador falso [param net_id], o null. Sin derribados en la zona no recorre a nadie.
func _find_downed_ally(position: Vector3, net_id: int) -> Variant:
	if _combat.downed.downed_count() == 0:
		return null
	var me: Combatant = _combat.get_combatant(net_id)
	if me == null or not me.is_alive():
		return null
	var best: Variant = null
	var best_distance: float = INF
	for other: Combatant in _combat.get_sorted():
		if other == me or not other.is_downed() or other.get_realm() != me.get_realm() \
				or not _is_player(other.get_id()):
			continue
		var feet: Vector3 = other.entity.get_position()
		var distance: float = position.distance_squared_to(feet)
		if distance < best_distance:
			best_distance = distance
			best = feet
	return best


# Los golpes avisados (TELEGRAPH) en curso que pueden dañar al jugador falso [param net_id] (el cerebro SIEGE, F6b):
# los fuertes de los PNJ de un reino hostil desde que empiezan hasta que acaba su ventana activa, con la posición y el
# rumbo del PNJ en este momento (gira y avanza un poco mientras carga) y el alcance del golpe. La lista se reúne una
# vez por tick.
func _find_threats(_position: Vector3, net_id: int) -> Array[BotBrain.Threat]:
	var found: Array[BotBrain.Threat] = []
	var me: Combatant = _combat.get_combatant(net_id)
	if me == null or me.is_dead():
		return found
	if _threats_tick != _tick:
		_rebuild_threats()
	for index: int in _threats.size():
		if _is_hostile_realm(_threat_realms[index], me.get_realm()):
			found.append(_threats[index])
	return found


# Cuántos jugadores vivos del reino del jugador falso [param net_id], sin contarle a él, están a menos de [param radius]
# metros en horizontal de [param center] (el contador de aliados del cerebro SIEGE para la reunión, GUE-44). Cuentan
# personas y falsos, no los PNJ ni los cuerpos de quien salió en combate. Las posiciones se reúnen una vez por tick, así
# que todos los que esperan en el mismo tick ven el mismo recuento y salen a la vez.
func _count_allies(center: Vector3, radius: float, net_id: int) -> int:
	var me: Combatant = _combat.get_combatant(net_id)
	if me == null:
		return 0
	if _allies_tick != _tick:
		_rebuild_ally_cache()
	var realm: int = me.get_realm()
	if not _allies_by_realm.has(realm):
		return 0
	var positions: PackedVector3Array = _allies_by_realm[realm]
	var ids: PackedInt32Array = _ally_ids_by_realm[realm]
	var limit: float = radius * radius
	var count: int = 0
	for index: int in positions.size():
		if ids[index] == net_id:
			continue
		var dx: float = positions[index].x - center.x
		var dz: float = positions[index].z - center.z
		if dx * dx + dz * dz <= limit:
			count += 1
	return count


# Reúne, por reino, las posiciones de los jugadores vivos (personas y falsos) en este tick. Un derribado (H3c) no está
# vivo: no cuenta en la reunión ni como uno de los suyos peleando en el fuerte. Lo mismo que los bots del cliente
# (BotAllySight para --bot, SwarmBot.is_standing_record para --bots), que lo ven por su acción dibujada, DOWNED: su vida
# publicada no es 0 (Combatant.publish la da como la de derribado).
func _rebuild_ally_cache() -> void:
	_allies_tick = _tick
	_allies_by_realm.clear()
	_ally_ids_by_realm.clear()
	for other: Combatant in _combat.get_sorted():
		if not other.is_alive() or other.entity.kind != NetProtocol.EntityKind.PLAYER or _lingering.has(other.get_id()):
			continue
		var realm: int = other.get_realm()
		if not _allies_by_realm.has(realm):
			_allies_by_realm[realm] = PackedVector3Array()
			_ally_ids_by_realm[realm] = PackedInt32Array()
		_allies_by_realm[realm].append(other.entity.get_position())
		_ally_ids_by_realm[realm].append(other.get_id())


# Reúne los fuertes avisados de los PNJ que siguen en curso tras el último tick (los que avisa _emit_npc_telegraphs).
func _rebuild_threats() -> void:
	_threats_tick = _tick
	_threats.clear()
	_threat_realms.clear()
	for net_id: int in _npcs:
		var entity: NetEntity = _registry.get_entity(net_id)
		var character: PlayerCharacter = entity.get_character() if entity != null else null
		if character == null:
			continue
		var state: CombatState = character.combat
		if state.action != CombatState.Action.HEAVY:
			continue
		var attack: AttackTicks = CombatCatalog.attack(state.action_id)
		if attack == null or attack.shape == null \
				or _tick - state.action_tick > attack.windup_ticks + attack.active_ticks:
			continue
		_threats.append(BotBrain.Threat.new(entity.get_position(), character.yaw, attack.shape.range_m))
		_threat_realms.append(entity.realm)


# Reúne, por reino, las posiciones de quien puede ser objetivo de un bot de combate en este tick.
func _rebuild_target_cache() -> void:
	_targets_tick = _tick
	_targets_by_realm.clear()
	_targets_ids_by_realm.clear()
	_targets_npc_by_realm.clear()
	_targets_velocity_by_realm.clear()
	_targets_downed_by_realm.clear()
	for other: Combatant in _combat.get_sorted():
		if other.is_dead() or other.immortal or other.is_protected(_tick):
			continue
		var other_position: Vector3 = other.entity.get_position()
		if _safe_areas.contains_own(other.get_realm(), other_position):
			continue
		var realm: int = other.get_realm()
		if not _targets_by_realm.has(realm):
			_targets_by_realm[realm] = PackedVector3Array()
			_targets_ids_by_realm[realm] = PackedInt32Array()
			_targets_npc_by_realm[realm] = PackedByteArray()
			_targets_velocity_by_realm[realm] = PackedVector3Array()
			_targets_downed_by_realm[realm] = PackedByteArray()
		var character: PlayerCharacter = other.entity.get_character()
		_targets_by_realm[realm].append(other_position)
		_targets_ids_by_realm[realm].append(other.get_id())
		_targets_npc_by_realm[realm].append(1 if _npcs.has(other.get_id()) else 0)
		_targets_velocity_by_realm[realm].append(character.velocity if character != null else Vector3.ZERO)
		_targets_downed_by_realm[realm].append(1 if other.is_downed() else 0)


# true si un bot de [param my_realm] puede dañar a uno de [param other_realm] en esta zona.
func _is_hostile_realm(my_realm: int, other_realm: int) -> bool:
	var key: int = my_realm * 16 + other_realm
	if not _hostile_cache.has(key):
		_hostile_cache[key] = FactionRules.can_damage(my_realm, other_realm,
				StringName(_config.zone_id))
	return _hostile_cache[key]


# El suelo bajo [param position]: el punto donde un rayo desde unos metros más arriba toca el mundo, o
# [param position] si no hay suelo debajo. El rayo va ligeramente inclinado: los verticales pueden fallar
# contra HeightMapShape3D.
func _ground_position(position: Vector3) -> Vector3:
	var space: PhysicsDirectSpaceState3D = _players_root.get_world_3d().direct_space_state
	var from: Vector3 = position + Vector3(0.0, _GROUND_PROBE_UP, 0.0)
	var query := PhysicsRayQueryParameters3D.create(from,
			from + Vector3(0.001, -(_GROUND_PROBE_UP + _GROUND_PROBE_DOWN), 0.0),
			PlayerCharacter.WORLD_COLLISION_LAYER)
	var hit: Dictionary = space.intersect_ray(query)
	if hit.is_empty():
		return position
	return (hit["position"] as Vector3) + Vector3(0.0, 0.05, 0.0)


func _open_combat_log() -> void:
	if _config.combat_log_path.is_empty():
		return
	var directory: String = _config.combat_log_path.get_base_dir()
	if not directory.is_empty() and not DirAccess.dir_exists_absolute(directory):
		DirAccess.make_dir_recursive_absolute(directory)
	_combat_log = FileAccess.open(_config.combat_log_path, FileAccess.WRITE)
	if _combat_log == null:
		push_warning("[Eldmark] No se pudo abrir el registro de combate '%s' (error %d)"
				% [_config.combat_log_path, FileAccess.get_open_error()])
		return
	_combat_log.store_line(COMBAT_LOG_HEADER)
	_combat.combat_log = _combat_log


func _close_combat_log() -> void:
	if _combat_log != null:
		if _combat != null:
			_combat.combat_log = null
		_combat_log.close()
		_combat_log = null


# --- Comandos y consola ------------------------------------------------------------------------

# Registra los comandos de administración: los seis de red (ids fijos de NetProtocol) con su versión
# de consola, y los que son solo de consola.
func _register_commands() -> void:
	_commands.register(&"teleport", "teleport <jugador> <x> <y> <z>", _console_teleport,
			_net_teleport)
	_commands.register(&"heal", "heal <jugador>", _console_heal, _net_heal)
	_commands.register(&"kill", "kill <jugador>", _console_kill, _net_kill)
	_commands.register(&"stamina_inf", "stamina_inf <jugador> [on|off]", _console_stamina_inf,
			_net_stamina_inf)
	_commands.register(&"set_weapon", "set_weapon <jugador> <arma>", _console_set_weapon,
			_net_set_weapon)
	_commands.register(&"spawn_dummy", "spawn_dummy <x> <y> <z> [quieto|bloqueando|girando]",
			_console_spawn_dummy, _net_spawn_dummy)
	_commands.register(&"cooldowns_off", "cooldowns_off <jugador> [on|off]", _console_cooldowns_off,
			_net_cooldowns_off)
	_commands.register(&"apply_status", "apply_status <jugador> <efecto> [ticks]", _console_apply_status,
			_net_apply_status)
	_commands.register(&"down", "down <jugador>", _console_down, _net_down)
	_commands.register(&"refill", "refill <jugador>", _console_refill, _net_refill)
	_fortresses.register_commands(_commands, Callable(self, "_next_tick"))
	if _npc_system != null:
		_npc_system.register_commands(_commands)
	_commands.register(&"unstuck", "unstuck <jugador>", _console_unstuck, _net_unstuck)
	_commands.register(&"announce", "announce <texto>", _console_announce)
	_commands.register(&"kick", "kick <jugador> [motivo]", _console_kick)
	_commands.register(&"shutdown", "shutdown <segundos> | shutdown cancel", _console_shutdown)
	_commands.register(&"players", "players", _console_players)


# Ejecuta las líneas que ha escrito alguien en la consola desde el tick anterior.
func _run_console_lines() -> void:
	if _console == null:
		return
	for line: String in _console.take_lines():
		var response: String = _commands.execute_console(line)
		if not response.is_empty():
			_log(response)


# Un jugador, jugador falso o PNJ por net_id o por nombre (sin distinguir mayúsculas), o null.
func _find_entity(text: String) -> NetEntity:
	var wanted: String = text.strip_edges()
	if wanted.is_valid_int():
		var by_id: NetEntity = _registry.get_entity(wanted.to_int())
		if by_id != null:
			return by_id
	var key: String = NameRules.normalize_key(wanted)
	for entity: NetEntity in _registry.get_sorted():
		if NameRules.normalize_key(entity.display_name) == key:
			return entity
	return null


func _is_valid_teleport_target(target: Vector3) -> bool:
	return target.is_finite() and absf(target.x) <= MAX_TELEPORT_COORDINATE \
			and absf(target.y) <= MAX_TELEPORT_COORDINATE \
			and absf(target.z) <= MAX_TELEPORT_COORDINATE


# Posición de un maniquí del comando spawn_dummy: delante del jugador, mirando hacia él.
func _dummy_spawn_for(entity: NetEntity) -> Transform3D:
	var yaw: float = entity.get_character().yaw
	var forward: Vector3 = Basis(Vector3.UP, yaw) * Vector3.FORWARD
	return Transform3D(Basis(Vector3.UP, yaw + PI),
			entity.get_position() + forward * DUMMY_SPAWN_DISTANCE)


func _combatant_of_peer(ctx: CommandRegistry.Context) -> Combatant:
	if ctx.peer == null or ctx.peer.entity == null:
		return null
	return _combat.get_combatant(ctx.peer.entity.net_id)


# -- Comandos de red (actúan sobre quien los envía) --

func _net_teleport(ctx: CommandRegistry.Context) -> int:
	if ctx.payload.size() != NetMessages.DebugCommand.TELEPORT_PAYLOAD_SIZE:
		return CommandRegistry.Result.BAD_ARGUMENTS
	var target := Vector3(ctx.payload.decode_float(0), ctx.payload.decode_float(4),
			ctx.payload.decode_float(8))
	if not _is_valid_teleport_target(target):
		ctx.note = "destino fuera de rango"
		return CommandRegistry.Result.BAD_ARGUMENTS
	teleport(ctx.peer.entity.net_id, target)
	ctx.note = str(target)
	return CommandRegistry.Result.OK


func _net_heal(ctx: CommandRegistry.Context) -> int:
	var combatant: Combatant = _combatant_of_peer(ctx)
	if combatant == null or not combatant.is_alive():
		return CommandRegistry.Result.REFUSED
	_combat.heal(combatant)
	return CommandRegistry.Result.OK


func _net_kill(ctx: CommandRegistry.Context) -> int:
	var combatant: Combatant = _combatant_of_peer(ctx)
	if combatant == null or combatant.is_dead():
		return CommandRegistry.Result.REFUSED
	_combat.kill(combatant, _tick + 1)
	return CommandRegistry.Result.OK


func _net_stamina_inf(ctx: CommandRegistry.Context) -> int:
	var combatant: Combatant = _combatant_of_peer(ctx)
	if combatant == null:
		return CommandRegistry.Result.REFUSED
	var enabled: bool
	match ctx.payload.size():
		0:
			enabled = (combatant.get_character().combat.combat_flags
					& CombatState.FLAG_INFINITE_STAMINA) == 0
		1:
			enabled = ctx.payload[0] != 0
		_:
			return CommandRegistry.Result.BAD_ARGUMENTS
	_combat.set_infinite_stamina(combatant, enabled)
	ctx.note = "activada" if enabled else "desactivada"
	return CommandRegistry.Result.OK


func _net_set_weapon(ctx: CommandRegistry.Context) -> int:
	var combatant: Combatant = _combatant_of_peer(ctx)
	if combatant == null:
		return CommandRegistry.Result.REFUSED
	if ctx.payload.size() != 2:
		return CommandRegistry.Result.BAD_ARGUMENTS
	var weapon_id: int = ctx.payload.decode_u16(0)
	if CombatCatalog.weapon(weapon_id) == null:
		ctx.note = "arma %d inexistente" % weapon_id
		return CommandRegistry.Result.BAD_ARGUMENTS
	# El 5 es set_loadout con el arma en la ranura 1 (docs/habilidades.md, sección 3.5), con su LOADOUT.
	if not _combat.set_weapon(combatant, weapon_id, _tick + 1):
		return CommandRegistry.Result.REFUSED
	return CommandRegistry.Result.OK


# 13 cooldowns_off (docs/habilidades.md, sección 5.1): u8 0 o 1, el bit 7 de combat_flags2.
func _net_cooldowns_off(ctx: CommandRegistry.Context) -> int:
	var combatant: Combatant = _combatant_of_peer(ctx)
	if combatant == null:
		return CommandRegistry.Result.REFUSED
	if ctx.payload.size() != 1 or ctx.payload[0] > 1:
		return CommandRegistry.Result.BAD_ARGUMENTS
	var enabled: bool = ctx.payload[0] == 1
	_combat.set_cooldowns_off(combatant, enabled)
	ctx.note = "sin reutilizaciones" if enabled else "con reutilizaciones"
	return CommandRegistry.Result.OK


# 14 apply_status: u8 status_id y u16 ticks (0 = los del dato). Se lo aplica quien lo envía, sin autor, en
# el tick que va a simular el servidor.
func _net_apply_status(ctx: CommandRegistry.Context) -> int:
	var combatant: Combatant = _combatant_of_peer(ctx)
	if combatant == null:
		return CommandRegistry.Result.REFUSED
	if ctx.payload.size() != NetMessages.DebugCommand.APPLY_STATUS_PAYLOAD_SIZE:
		return CommandRegistry.Result.BAD_ARGUMENTS
	var status_id: int = ctx.payload.decode_u8(0)
	var ticks: int = ctx.payload.decode_u16(1)
	if CombatCatalog.status(status_id) == null:
		ctx.note = "efecto %d inexistente" % status_id
		return CommandRegistry.Result.BAD_ARGUMENTS
	if not _combat.apply_status(combatant, status_id, _tick + 1, ticks):
		return CommandRegistry.Result.REFUSED
	ctx.note = "%s, %d ticks" % [CombatCatalog.status(status_id).name, ticks]
	return CommandRegistry.Result.OK


# 15 down (docs/habilidades.md, sección 4.5): se derriba a sí mismo sin autor (al desangrarse, DEATH sin KILL), en
# el tick que va a simular el servidor. Rechazado fuera de las zonas RVR, en la zona segura propia o sin estar vivo.
func _net_down(ctx: CommandRegistry.Context) -> int:
	if not ctx.payload.is_empty():
		return CommandRegistry.Result.BAD_ARGUMENTS
	var combatant: Combatant = _combatant_of_peer(ctx)
	if combatant == null or not _combat.down(combatant, _tick + 1):
		return CommandRegistry.Result.REFUSED
	return CommandRegistry.Result.OK


# 16 refill: repone las cargas de los consumibles de su plantilla (set_charges, con LOADOUT al dueño).
func _net_refill(ctx: CommandRegistry.Context) -> int:
	if not ctx.payload.is_empty():
		return CommandRegistry.Result.BAD_ARGUMENTS
	var combatant: Combatant = _combatant_of_peer(ctx)
	if combatant == null or not _combat.refill(combatant, _tick + 1):
		return CommandRegistry.Result.REFUSED
	return CommandRegistry.Result.OK


func _net_spawn_dummy(ctx: CommandRegistry.Context) -> int:
	if ctx.peer == null or ctx.peer.entity == null:
		return CommandRegistry.Result.REFUSED
	var mode: int = NpcBrain.Mode.STILL
	match ctx.payload.size():
		0:
			pass
		1:
			mode = ctx.payload[0]
			if mode < NpcBrain.Mode.STILL or mode > NpcBrain.Mode.SPIN:
				return CommandRegistry.Result.BAD_ARGUMENTS
		_:
			return CommandRegistry.Result.BAD_ARGUMENTS
	var spawn: Transform3D = _dummy_spawn_for(ctx.peer.entity)
	var net_id: int = spawn_dummy(spawn.origin, CombatDirector._yaw_of(spawn), mode)
	if net_id < 0:
		return CommandRegistry.Result.REFUSED
	ctx.note = "net_id %d, %s" % [net_id, NpcBrain.mode_name(mode)]
	return CommandRegistry.Result.OK


func _net_unstuck(ctx: CommandRegistry.Context) -> int:
	if not ctx.payload.is_empty():
		return CommandRegistry.Result.BAD_ARGUMENTS
	if ctx.peer == null or ctx.peer.entity == null:
		return CommandRegistry.Result.REFUSED
	return CommandRegistry.Result.OK \
			if _request_unstuck(ctx.peer) == UnstuckTracker.RequestResult.STARTED \
			else CommandRegistry.Result.REFUSED


# -- Comandos de consola --

# Teletransporta ya al jugador al punto seguro más cercano de su reino (sin canalización ni
# reutilización: es una herramienta de administración).
func _console_unstuck(ctx: CommandRegistry.Context) -> String:
	if ctx.args.size() != 1:
		return "Uso: unstuck <jugador>"
	var entity: NetEntity = _find_entity(ctx.args[0])
	if entity == null or entity.kind != NetProtocol.EntityKind.PLAYER:
		return "No hay ningún jugador «%s»" % ctx.args[0]
	_teleport_unstuck(entity, _tick + 1)
	return "%s llevado al punto seguro más cercano de su reino" % entity.display_name


func _console_teleport(ctx: CommandRegistry.Context) -> String:
	if ctx.args.size() != 4:
		return "Uso: teleport <jugador> <x> <y> <z>"
	var entity: NetEntity = _find_entity(ctx.args[0])
	if entity == null or entity.get_character() == null:
		return "No hay ningún jugador «%s»" % ctx.args[0]
	for i: int in range(1, 4):
		if not ctx.args[i].is_valid_float():
			return "Coordenada no válida: %s" % ctx.args[i]
	var target := Vector3(ctx.args[1].to_float(), ctx.args[2].to_float(), ctx.args[3].to_float())
	if not _is_valid_teleport_target(target):
		return "Destino fuera de rango"
	teleport(entity.net_id, target)
	return "%s teletransportado a %s" % [entity.display_name, target]


func _console_heal(ctx: CommandRegistry.Context) -> String:
	if ctx.args.size() != 1:
		return "Uso: heal <jugador>"
	var combatant: Combatant = _combatant_by_name(ctx.args[0])
	if combatant == null:
		return "No hay ningún jugador «%s»" % ctx.args[0]
	if combatant.is_dead():
		return "%s está muerto" % combatant.entity.display_name
	if combatant.is_downed():
		return "%s está derribado" % combatant.entity.display_name
	_combat.heal(combatant)
	return "%s curado" % combatant.entity.display_name


func _console_kill(ctx: CommandRegistry.Context) -> String:
	if ctx.args.size() != 1:
		return "Uso: kill <jugador>"
	var combatant: Combatant = _combatant_by_name(ctx.args[0])
	if combatant == null:
		return "No hay ningún jugador «%s»" % ctx.args[0]
	if combatant.is_dead() or combatant.immortal:
		return "%s no se puede matar" % combatant.entity.display_name
	_combat.kill(combatant, _tick + 1)
	return "%s muerto" % combatant.entity.display_name


func _console_stamina_inf(ctx: CommandRegistry.Context) -> String:
	if ctx.args.is_empty() or ctx.args.size() > 2:
		return "Uso: stamina_inf <jugador> [on|off]"
	var combatant: Combatant = _combatant_by_name(ctx.args[0])
	if combatant == null:
		return "No hay ningún jugador «%s»" % ctx.args[0]
	var enabled: bool = (combatant.get_character().combat.combat_flags
			& CombatState.FLAG_INFINITE_STAMINA) == 0
	if ctx.args.size() == 2:
		match ctx.args[1].to_lower():
			"on", "1", "si", "sí":
				enabled = true
			"off", "0", "no":
				enabled = false
			_:
				return "Uso: stamina_inf <jugador> [on|off]"
	_combat.set_infinite_stamina(combatant, enabled)
	return "Resistencia infinita %s para %s" % ["activada" if enabled else "desactivada",
			combatant.entity.display_name]


func _console_set_weapon(ctx: CommandRegistry.Context) -> String:
	if ctx.args.size() != 2:
		return "Uso: set_weapon <jugador> <arma>"
	var combatant: Combatant = _combatant_by_name(ctx.args[0])
	if combatant == null:
		return "No hay ningún jugador «%s»" % ctx.args[0]
	var weapon_id: int = CombatCatalog.weapon_id(StringName(ctx.args[1]))
	if weapon_id == 0 and ctx.args[1].is_valid_int():
		weapon_id = ctx.args[1].to_int()
	if CombatCatalog.weapon(weapon_id) == null:
		return "No existe el arma «%s»" % ctx.args[1]
	if not _combat.set_weapon(combatant, weapon_id, _tick + 1):
		return "%s está derribado" % combatant.entity.display_name
	return "%s lleva ahora %s" % [combatant.entity.display_name, ctx.args[1]]


func _console_cooldowns_off(ctx: CommandRegistry.Context) -> String:
	if ctx.args.is_empty() or ctx.args.size() > 2:
		return "Uso: cooldowns_off <jugador> [on|off]"
	var combatant: Combatant = _combatant_by_name(ctx.args[0])
	if combatant == null:
		return "No hay ningún jugador «%s»" % ctx.args[0]
	var enabled: bool = (combatant.get_character().combat.combat_flags2
			& CombatState.FLAG2_NO_COOLDOWNS) == 0
	if ctx.args.size() == 2:
		match ctx.args[1].to_lower():
			"on", "1", "si", "sí":
				enabled = true
			"off", "0", "no":
				enabled = false
			_:
				return "Uso: cooldowns_off <jugador> [on|off]"
	_combat.set_cooldowns_off(combatant, enabled)
	return "%s para %s" % ["Sin reutilizaciones" if enabled else "Con reutilizaciones",
			combatant.entity.display_name]


func _console_apply_status(ctx: CommandRegistry.Context) -> String:
	if ctx.args.size() < 2 or ctx.args.size() > 3:
		return "Uso: apply_status <jugador> <efecto> [ticks]"
	var combatant: Combatant = _combatant_by_name(ctx.args[0])
	if combatant == null:
		return "No hay ningún jugador «%s»" % ctx.args[0]
	var status_id: int = CombatCatalog.status_id(StringName(ctx.args[1]))
	if status_id == 0 and ctx.args[1].is_valid_int():
		status_id = ctx.args[1].to_int()
	if CombatCatalog.status(status_id) == null:
		return "No existe el efecto «%s»" % ctx.args[1]
	var ticks: int = 0
	if ctx.args.size() == 3:
		if not ctx.args[2].is_valid_int() or ctx.args[2].to_int() < 0 \
				or ctx.args[2].to_int() > 0xFFFF:
			return "Uso: apply_status <jugador> <efecto> [ticks]"
		ticks = ctx.args[2].to_int()
	if not _combat.apply_status(combatant, status_id, _tick + 1, ticks):
		return "%s no está en pie" % combatant.entity.display_name
	return "%s aplicado a %s" % [CombatCatalog.status(status_id).name, combatant.entity.display_name]


func _console_down(ctx: CommandRegistry.Context) -> String:
	if ctx.args.size() != 1:
		return "Uso: down <jugador>"
	var combatant: Combatant = _combatant_by_name(ctx.args[0])
	if combatant == null:
		return "No hay ningún jugador «%s»" % ctx.args[0]
	if not _combat.down(combatant, _tick + 1):
		return "%s no puede quedar derribado aquí" % combatant.entity.display_name
	return "%s derribado" % combatant.entity.display_name


func _console_refill(ctx: CommandRegistry.Context) -> String:
	if ctx.args.size() != 1:
		return "Uso: refill <jugador>"
	var combatant: Combatant = _combatant_by_name(ctx.args[0])
	if combatant == null:
		return "No hay ningún jugador «%s»" % ctx.args[0]
	if not _combat.refill(combatant, _tick + 1):
		return "%s no tiene cargas que reponer" % combatant.entity.display_name
	return "Cargas de %s repuestas" % combatant.entity.display_name


func _console_spawn_dummy(ctx: CommandRegistry.Context) -> String:
	if ctx.args.size() < 3 or ctx.args.size() > 4:
		return "Uso: spawn_dummy <x> <y> <z> [quieto|bloqueando|girando]"
	for i: int in 3:
		if not ctx.args[i].is_valid_float():
			return "Coordenada no válida: %s" % ctx.args[i]
	var target := Vector3(ctx.args[0].to_float(), ctx.args[1].to_float(), ctx.args[2].to_float())
	if not _is_valid_teleport_target(target):
		return "Posición fuera de rango"
	var mode: int = NpcBrain.Mode.STILL
	if ctx.args.size() == 4:
		mode = NpcBrain.mode_from_name(ctx.args[3])
		if mode < 0:
			return "Modo desconocido: %s (quieto, bloqueando o girando)" % ctx.args[3]
	var net_id: int = spawn_dummy(target, 0.0, mode)
	if net_id < 0:
		return "No se puede crear otro maniquí (hay %d como mucho)" % MAX_DUMMIES
	return "Maniquí %s creado (net_id %d)" % [NpcBrain.mode_name(mode), net_id]


func _console_announce(ctx: CommandRegistry.Context) -> String:
	if ctx.args.is_empty():
		return "Uso: announce <texto>"
	var count: int = _broadcast_notice(" ".join(ctx.args))
	return "Anuncio enviado a %d jugadores" % count


func _console_kick(ctx: CommandRegistry.Context) -> String:
	if ctx.args.is_empty():
		return "Uso: kick <jugador> [motivo]"
	var entity: NetEntity = _find_entity(ctx.args[0])
	if entity == null or entity.kind != NetProtocol.EntityKind.PLAYER:
		return "No hay ningún jugador «%s»" % ctx.args[0]
	var reason: String = "expulsado desde la consola"
	if ctx.args.size() > 1:
		reason += ": " + " ".join(ctx.args.slice(1))
	if _fakes.has(entity.net_id):
		remove_fake_player(entity.net_id)
		return "Jugador falso %s dado de baja" % entity.display_name
	var peer: ServerPeer = _peers.get(entity.owner_peer)
	if peer == null:
		return "%s no está conectado" % entity.display_name
	_kick(peer, reason, false)
	return "%s expulsado" % entity.display_name


func _console_shutdown(ctx: CommandRegistry.Context) -> String:
	if ctx.args.size() != 1:
		return "Uso: shutdown <segundos> | shutdown cancel"
	if ctx.args[0].to_lower() == "cancel":
		if _shutdown_tick < 0:
			return "No hay ningún cierre pendiente"
		_shutdown_tick = -1
		_broadcast_notice("Cierre del servidor cancelado")
		return "Cierre cancelado"
	if not ctx.args[0].is_valid_int() or ctx.args[0].to_int() < 0 or ctx.args[0].to_int() > 86400:
		return "Uso: shutdown <segundos> | shutdown cancel"
	var seconds: int = ctx.args[0].to_int()
	_shutdown_tick = _tick + seconds * Engine.physics_ticks_per_second
	if seconds > 0:
		_broadcast_notice("El servidor se cerrará en %d s" % seconds)
	return "Cierre dentro de %d s" % seconds


func _console_players(_ctx: CommandRegistry.Context) -> String:
	var lines := PackedStringArray()
	for entity: NetEntity in _registry.get_sorted():
		if entity.kind == NetProtocol.EntityKind.STRUCTURE:
			continue
		var combatant: Combatant = _combat.get_combatant(entity.net_id)
		lines.append("%d %s (%s%s) vida %d/%d" % [entity.net_id, entity.display_name,
				NetProtocol.realm_display_name(entity.realm),
				", PNJ" if entity.kind == NetProtocol.EntityKind.NPC else "",
				combatant.health if combatant != null else 0,
				combatant.max_health if combatant != null else 0])
	return "%d entidades: %s" % [lines.size(), "; ".join(lines)]


func _combatant_by_name(text: String) -> Combatant:
	var entity: NetEntity = _find_entity(text)
	return _combat.get_combatant(entity.net_id) if entity != null else null


# NOTICE informativo a todos los jugadores que están en el mundo. Devuelve cuántos lo reciben.
func _broadcast_notice(text: String) -> int:
	if _transport == null:
		return 0
	var notice := NetMessages.Notice.new()
	notice.code = NetProtocol.NoticeCode.INFO
	notice.text = text
	var bytes: PackedByteArray = notice.encode()
	for peer: ServerPeer in _world_peers:
		_transport.send(peer.peer_id, NetProtocol.CH_RELIABLE, bytes)
	return _world_peers.size()


# Cuenta atrás de un cierre pedido por la consola: avisos en los segundos señalados y, al llegar a 0,
# shutdown_requested.
func _check_shutdown_countdown(s: int) -> void:
	if _shutdown_tick < 0:
		return
	var remaining: int = _shutdown_tick - s
	if remaining <= 0:
		_shutdown_tick = -1
		_log("Cuenta atrás de cierre cumplida")
		shutdown_requested.emit("cierre pedido desde la consola")
		return
	var rate: int = Engine.physics_ticks_per_second
	@warning_ignore("integer_division")
	var seconds_left: int = remaining / rate
	if remaining % rate == 0 and SHUTDOWN_NOTICE_SECONDS.has(seconds_left):
		_broadcast_notice("El servidor se cerrará en %d s" % seconds_left)


# --- Fortalezas, marcador, salida en combate y /atascado -------------------------------------------

# Crea el controlador de las fortalezas de la zona y lo conecta con el combate: los golpes a la puerta,
# los DEATH y HIT de los defensores, los puntos de reaparición que valen y las oleadas.
func _setup_fortresses(world: Node3D) -> void:
	_fortresses = FortressController.new()
	_fortresses.score_keeper = _scores
	_fortresses.candidates_source = Callable(self, "_presence_candidates")
	_fortresses.bodies_source = Callable(self, "_gate_blockers")
	_fortresses.captain_killer = Callable(self, "_kill_captain_npc")
	_fortresses.setup(world, _registry, _tick)
	_fortresses.war_event_emitted.connect(_on_war_event)
	_fortresses.object_state_emitted.connect(_on_object_state)
	_fortresses.gate_damage_started.connect(_on_gate_damage_started)
	_combat.event_emitted.connect(_fortresses.on_combat_event)
	_combat.structure_hit.connect(_fortresses.on_structure_hit)
	_combat.set_structure_targets(_fortresses.get_structure_targets())
	_combat.fortress_states = Callable(_fortresses, "get_states")
	if _fortresses.has_fortresses():
		# Oleadas de reaparición cada 10 s en las zonas con fortaleza (GUE-14).
		_combat.timing.respawn_wave_ticks = CombatTiming.WAVE_TICKS


# Crea el sistema de generadores de PNJ de la zona (puestos, navegación, fichas) y lo conecta con el combate y las
# fortalezas, salvo con --no-npcs.
func _setup_npcs(world: Node3D) -> void:
	if _config.no_npcs:
		return
	_npc_system = NpcSpawnerSystem.new()
	_npc_system.log_sink = Callable(self, "_log")
	_npc_system.setup(self, world, _config.zone_id)


# El tick que va a simular el servidor: el de las órdenes de depuración que llegan en el poll.
func _next_tick() -> int:
	return _tick + 1


# Los jugadores (de red y falsos, no los PNJ) que pueden contar en el círculo: vivos, con la última
# entrada real que han mandado y sin ser el cuerpo que queda tras una baja.
func _presence_candidates(_tick_now: int) -> Array:
	var candidates: Array = []
	for entity: NetEntity in _registry.get_sorted():
		if entity.kind != NetProtocol.EntityKind.PLAYER:
			continue
		var combatant: Combatant = _combat.get_combatant(entity.net_id)
		var queue: InputQueue = _queues.get(entity.net_id)
		if combatant == null or queue == null or entity.get_character() == null:
			continue
		var candidate: FortressController.PlayerCandidate = FortressController.PlayerCandidate \
				.make_player(entity.net_id, entity.realm, entity.get_position(),
				queue.get_last_real_tick())
		candidate.alive = combatant.is_alive()
		candidate.connected = not _lingering.has(entity.net_id)
		candidates.append(candidate)
	return candidates


# Los pies de los personajes vivos o derribados (jugadores y PNJ): los que impiden cerrar la puerta si solapan
# el vano (docs/habilidades.md, sección 4.5: la puerta no se repara con un derribado en el vano).
func _gate_blockers() -> PackedVector3Array:
	var positions := PackedVector3Array()
	for entity: NetEntity in _registry.get_sorted():
		if entity.get_character() == null:
			continue
		var combatant: Combatant = _combat.get_combatant(entity.net_id)
		if combatant != null and not combatant.is_dead():
			positions.append(entity.get_position())
	return positions


# Mata al PNJ capitán registrado (para fort_kill_captain). Devuelve false si no se puede.
func _kill_captain_npc(net_id: int) -> bool:
	var combatant: Combatant = _combat.get_combatant(net_id)
	if combatant == null or combatant.is_dead() or combatant.immortal:
		return false
	_combat.kill(combatant, _tick + 1)
	return true


# Un aviso de guerra a toda la zona (ENTITY_EVENT WAR) y al registro de batalla.
func _on_war_event(event: NetMessages.EntityEvent) -> void:
	if _battle_log != null:
		var fortress_id: StringName = _fortresses.get_fortress_id_of(event.net_id)
		_battle_log.log_war(event.tick, event.war_event, event.war_realm, fortress_id,
				_fortresses.get_circle(fortress_id)["center"])
	if _transport == null or _world_peers.is_empty():
		return
	var bytes: PackedByteArray = event.encode()
	for peer: ServerPeer in _world_peers:
		_transport.send(peer.peer_id, NetProtocol.CH_RELIABLE, bytes)
		_events_sent += 1
		_event_bytes_sent += bytes.size()


# El OBJECT_STATE de una fortaleza a toda la zona (canal fiable).
func _on_object_state(object_state: NetMessages.ObjectState) -> void:
	_object_states_sent += 1
	if _transport == null or _world_peers.is_empty():
		return
	var bytes: PackedByteArray = object_state.encode()
	if bytes.is_empty():
		return
	for peer: ServerPeer in _world_peers:
		_transport.send(peer.peer_id, NetProtocol.CH_RELIABLE, bytes)


func _on_gate_damage_started(fortress_id: StringName, tick: int) -> void:
	if _battle_log == null:
		return
	var gate: FortGate = _fortresses.get_gate(fortress_id)
	_battle_log.log_gate_damage_started(tick, fortress_id,
			gate.global_position if gate != null else Vector3.ZERO)


# El marcador de la zona a todos los jugadores (páginas de 66 filas como mucho).
func _send_scoreboard() -> void:
	if _transport == null or _world_peers.is_empty():
		return
	var ids: Array[int] = []
	for entity: NetEntity in _registry.get_sorted():
		if entity.kind == NetProtocol.EntityKind.PLAYER:
			ids.append(entity.net_id)
	var rows: Array[NetMessages.ScoreRow] = _scores.build_rows(ids)
	for page: NetMessages.Scoreboard in NetMessages.Scoreboard.split(rows):
		var bytes: PackedByteArray = page.encode()
		for peer: ServerPeer in _world_peers:
			_transport.send(peer.peer_id, NetProtocol.CH_RELIABLE, bytes)
	_scoreboards_sent += 1


# -- Salida y desconexión en combate (GUE-41) --

# true si quien se va ha dado o recibido daño hace menos de 10 s y sigue vivo: su cuerpo se queda.
func _should_linger(entity: NetEntity, s: int) -> bool:
	if entity.kind != NetProtocol.EntityKind.PLAYER or _run_state != _RunState.RUNNING:
		return false
	var combatant: Combatant = _combat.get_combatant(entity.net_id)
	return combatant != null and combatant.is_alive() and combatant.is_in_combat(s)


# El cuerpo queda LINGER_TICKS ticks en el mundo con entradas neutras (quieto, sin botones), atacable, sin
# contar en el círculo y con el nombre reservado. Deja de ser de ningún peer.
func _start_lingering(entity: NetEntity, s: int) -> void:
	var net_id: int = entity.net_id
	var record: _PlayerRecord = _player_by_net.get(net_id)
	if record != null:
		record.close(s)
		_player_by_net.erase(net_id)
	var combatant: Combatant = _combat.get_combatant(net_id)
	if combatant != null:
		combatant.peer = null
	entity.owner_peer = 0
	_unstuck.cancel(NameRules.normalize_key(entity.display_name))
	_lingering[net_id] = s + linger_ticks
	_lingering_total += 1


# Retira los cuerpos cuyo plazo ha vencido o a los que han matado (su muerte ya se acreditó como cualquier
# otra).
func _process_lingering(s: int) -> void:
	if _lingering.is_empty():
		return
	for net_id: int in _lingering.keys():
		var entity: NetEntity = _registry.get_entity(net_id)
		if entity == null:
			_lingering.erase(net_id)
			continue
		var combatant: Combatant = _combat.get_combatant(net_id)
		if s >= _lingering[net_id] or combatant == null or combatant.is_dead():
			_log("Se retira el cuerpo de %s (net_id %d)" % [entity.display_name, net_id])
			_remove_player(entity, s, NetProtocol.DespawnReason.DISCONNECTED)


# -- /atascado (MUN-41) --

# UNSTUCK_REQUEST o comando 7: empieza la canalización si procede y avisa al jugador de cómo ha ido.
func _request_unstuck(peer: ServerPeer) -> int:
	var entity: NetEntity = peer.entity
	var combatant: Combatant = _combat.get_combatant(entity.net_id) if entity != null else null
	if combatant == null:
		return UnstuckTracker.RequestResult.DEAD
	var s: int = _tick + 1
	var key: String = NameRules.normalize_key(entity.display_name)
	var result: int = _unstuck.request(key, s, combatant.is_alive(), combatant.is_in_combat(s))
	var text: String = "/atascado: te llevaré al punto más cercano de tu reino en %.0f s si no " \
			% (float(_unstuck.channel_ticks) / float(Engine.physics_ticks_per_second)) \
			+ "entras en combate"
	match result:
		UnstuckTracker.RequestResult.STARTED:
			_unstuck_players[key] = entity.net_id
		UnstuckTracker.RequestResult.IN_COMBAT:
			text = "/atascado: no se puede usar en combate"
		UnstuckTracker.RequestResult.COOLDOWN:
			text = "/atascado: disponible de nuevo en %d s" % ceili(
					float(_unstuck.cooldown_remaining(key, s)) / 60.0)
		UnstuckTracker.RequestResult.ALREADY_CHANNELING:
			text = "/atascado: ya lo estás usando"
		UnstuckTracker.RequestResult.DEAD:
			text = "/atascado: no se puede usar estando muerto"
	_send_notice(peer, text)
	return result


# Avanza las canalizaciones de /atascado: el combate o la muerte las interrumpen y al final se teletransporta.
func _process_unstuck(s: int) -> void:
	for key: String in _unstuck.get_channeling():
		var entity: NetEntity = _registry.get_entity(_unstuck_players.get(key, 0))
		var combatant: Combatant = _combat.get_combatant(entity.net_id) if entity != null else null
		if combatant == null:
			_unstuck.cancel(key)
			_unstuck_players.erase(key)
			continue
		var outcome: int = _unstuck.update(key, s, combatant.is_alive(), combatant.is_in_combat(s))
		if outcome == UnstuckTracker.UpdateResult.CHANNELING:
			continue
		_unstuck_players.erase(key)
		var peer: ServerPeer = _peers.get(entity.owner_peer)
		if outcome == UnstuckTracker.UpdateResult.INTERRUPTED:
			if peer != null:
				_send_notice(peer, "/atascado: interrumpido")
		else:
			_teleport_unstuck(entity, s)
			if peer != null:
				_send_notice(peer, "/atascado: ya estás en un punto seguro de tu reino")


# Teletransporta a [param entity] al punto de reaparición válido más cercano de su reino (o, si no hay,
# a un punto de aparición) y anota el uso (zona, posición de origen y de destino) para arreglar el mapa.
func _teleport_unstuck(entity: NetEntity, s: int) -> void:
	var from: Vector3 = entity.get_position()
	var destination: Transform3D = _nearest_safe_point(entity, s)
	_place(entity, destination.origin, CombatDirector._yaw_of(destination))
	_unstuck_uses += 1
	_unstuck_log.append({
		"tick": s, "net_id": entity.net_id, "name": entity.display_name, "zone": _config.zone_id,
		"from": [from.x, from.y, from.z],
		"to": [destination.origin.x, destination.origin.y, destination.origin.z],
	})
	while _unstuck_log.size() > MAX_LOGGED_UNSTUCK:
		_unstuck_log.pop_front()
	_log("/atascado: %s (net_id %d, zona %s) pasa de %s a %s" % [entity.display_name,
			entity.net_id, _config.zone_id, from, destination.origin])


# El punto de reaparición que vale para el reino de [param entity] más cercano a ella.
func _nearest_safe_point(entity: NetEntity, s: int) -> Transform3D:
	var points: Array[Node3D] = _combat.get_all_respawn_points()
	var position: Vector3 = entity.get_position()
	var best: Node3D = null
	var best_distance: float = INF
	for index: int in _combat.get_valid_respawn_points(entity.realm, s):
		var distance: float = points[index].global_position.distance_squared_to(position)
		if distance < best_distance:
			best_distance = distance
			best = points[index]
	if best == null:
		return _spawn_picker.pick(entity.realm)
	return best.global_transform


func _send_notice(peer: ServerPeer, text: String) -> void:
	if _transport == null or peer.state != ServerPeer.State.IN_WORLD:
		return
	var notice := NetMessages.Notice.new()
	notice.code = NetProtocol.NoticeCode.INFO
	notice.text = text
	_transport.send(peer.peer_id, NetProtocol.CH_RELIABLE, notice.encode())


# -- Registro de batalla (GUE-17) --

func _open_battle_log() -> void:
	if _config.battle_log_path.is_empty():
		return
	_battle_log = BattleLog.open(_config.battle_log_path)
	if _battle_log == null:
		return
	var fortresses: Array[Dictionary] = []
	for fortress_id: StringName in _fortresses.get_fortress_ids():
		var node: Node3D = _fortresses.get_node_of(fortress_id)
		var gate: FortGate = _fortresses.get_gate(fortress_id)
		var circle: Dictionary = _fortresses.get_circle(fortress_id)
		fortresses.append({
			"id": fortress_id, "position": node.global_position,
			"gate": gate.global_position if gate != null else node.global_position,
			"circle": circle["center"], "radius": circle["radius"],
		})
	_battle_log.log_start(_config.zone_id, fortresses)


func _close_battle_log() -> void:
	if _battle_log != null:
		_battle_log.close()
		_battle_log = null


# --- Transporte -------------------------------------------------------------------------------

func _connect_transport() -> void:
	_transport.peer_authenticating.connect(_on_peer_authenticating)
	_transport.auth_received.connect(_on_auth_received)
	_transport.peer_connected.connect(_on_peer_connected)
	_transport.peer_disconnected.connect(_on_peer_disconnected)
	_transport.packet_received.connect(_on_packet_received)
	_transport.packets_discarded.connect(_on_packets_discarded)


func _disconnect_transport() -> void:
	if _transport == null or not is_instance_valid(_transport):
		return
	if _transport.peer_authenticating.is_connected(_on_peer_authenticating):
		_transport.peer_authenticating.disconnect(_on_peer_authenticating)
	if _transport.auth_received.is_connected(_on_auth_received):
		_transport.auth_received.disconnect(_on_auth_received)
	if _transport.peer_connected.is_connected(_on_peer_connected):
		_transport.peer_connected.disconnect(_on_peer_connected)
	if _transport.peer_disconnected.is_connected(_on_peer_disconnected):
		_transport.peer_disconnected.disconnect(_on_peer_disconnected)
	if _transport.packet_received.is_connected(_on_packet_received):
		_transport.packet_received.disconnect(_on_packet_received)
	if _transport.packets_discarded.is_connected(_on_packets_discarded):
		_transport.packets_discarded.disconnect(_on_packets_discarded)


# Un cliente ha conectado y empieza a autenticarse: se espera su HELLO.
func _on_peer_authenticating(peer_id: int) -> void:
	if _run_state != _RunState.RUNNING:
		return
	var peer := ServerPeer.new(peer_id)
	peer.remote_address = _transport.get_remote_address(peer_id)
	if remote_address_override.is_valid():
		peer.remote_address = str(remote_address_override.call(peer_id, peer.remote_address))
	peer.connected_tick = _tick
	peer.connected_at_msec = Time.get_ticks_msec()
	_peers[peer_id] = peer
	# Quien ha sido expulsado hace poco no vuelve a entrar en un RTT con los avisos a 0 y los cubos
	# llenos: su IP recibe un REJECT nada más conectar (se reutiliza TOO_MANY_CONNECTIONS para no
	# subir PROTOCOL_VERSION).
	if _is_cooling_down(_cooldown_key_for_address(peer.remote_address)):
		_reject(peer, NetProtocol.Result.TOO_MANY_CONNECTIONS)
		return
	# El tope por IP se aplica ya al conectar, no solo al llegar el HELLO: una IP que abre conexiones
	# sin mandar nada ocuparía todas las plazas de ENet y los clientes legítimos quedarían sin
	# respuesta. Las que pasan del tope reciben un REJECT y se cortan.
	if _connections_from(peer) >= _config.max_connections_per_ip \
			and not ServerAuth.is_loopback(peer.remote_address):
		_reject(peer, NetProtocol.Result.TOO_MANY_CONNECTIONS)


# HELLO: se valida y se contesta WELCOME (y complete_auth) o REJECT (y corte ordenado). Con billete, el peer
# queda en VERIFYING hasta que la plataforma conteste a la reclamación (_apply_auth_outcome).
func _on_auth_received(peer_id: int, bytes: PackedByteArray) -> void:
	var peer: ServerPeer = _peers.get(peer_id)
	if peer == null or _run_state != _RunState.RUNNING or peer.state == ServerPeer.State.LEAVING:
		return
	if peer.state != ServerPeer.State.AUTHENTICATING:
		_add_strike(peer, "mensaje de autenticación inesperado")
		return
	var hello: NetMessages.Hello = NetMessages.Hello.decode(bytes)
	var result: int = NetProtocol.Result.MALFORMED
	if hello != null:
		peer.character_id = hello.character_id if _auth.uses_tickets() else 0
		if _is_cooling_down(_cooldown_key_for_identity(peer.remote_address, hello.display_name,
				peer.character_id)):
			_reject(peer, NetProtocol.Result.TOO_MANY_CONNECTIONS)
			return
		result = _auth.validate(peer_id, hello, peer.remote_address, _occupied_seats(),
				_connections_from(peer), _filler_seats())
		if result == NetProtocol.Result.OK and not _make_room_for(peer, hello.realm, hello.display_name,
				_occupied_seats()):
			result = NetProtocol.Result.FULL
	if result == AuthProvider.PENDING:
		peer.state = ServerPeer.State.VERIFYING
		return
	if result != NetProtocol.Result.OK:
		var text: String = ""
		if result == NetProtocol.Result.TICKET and hello != null and hello.ticket.is_empty() \
				and _auth.uses_tickets():
			text = TicketAuthProvider.NO_TICKET_TEXT
		_reject(peer, result, text)
		return
	_welcome(peer, hello.realm, hello.display_name)


# WELCOME y complete_auth: el peer pasa a LOADING con [param realm] y [param display_name] (los del HELLO sin
# plataforma; los de la reclamación con ella).
func _welcome(peer: ServerPeer, realm: int, display_name: String) -> void:
	peer.state = ServerPeer.State.LOADING
	peer.realm = realm
	peer.display_name = display_name
	peer.loading_since_tick = _tick
	var welcome := NetMessages.Welcome.new()
	welcome.server_tick = _tick
	welcome.tick_rate = Engine.physics_ticks_per_second
	welcome.realm = realm
	welcome.channel = _config.channel
	welcome.zone_id = _config.zone_id
	welcome.realm_counts = get_realm_counts(false, peer)
	var error: Error = _transport.send_auth(peer.peer_id, welcome.encode())
	if error == OK:
		error = _transport.complete_auth(peer.peer_id)
	if error != OK:
		_mark_leaving(peer)


# --- Plataforma (docs/plataforma.md §5.2 y §14.3) ------------------------------------------------

# Paso «poll» con la plataforma: los eventos, por kind y en orden de llegada (instance_closed al final), los
# finales del AuthProvider y los VERIFYING vencidos.
func _poll_platform() -> void:
	if _platform != null:
		var closed_code: String = ""
		for event: PlatformEvent in _platform.take_events():
			match event.kind:
				PlatformEvent.KIND_CLAIM:
					if _auth_provider != null:
						_auth_provider.on_platform_event(event)
				PlatformEvent.KIND_HEARTBEAT:
					_on_heartbeat_event(event)
				PlatformEvent.KIND_INSTANCE_CLOSED:
					closed_code = event.error_code
				_:
					# save (CharacterSaver, P5), id_block, progress_op y progress_ledger (ProgressService,
					# progresion.md P5a y P5d), fortress (P6), ignore, report y sanction (P7b): sin consumidor
					# todavía.
					pass
		if not closed_code.is_empty():
			_log("La plataforma ha cerrado esta instancia (%s)" % closed_code)
			instance_closed.emit(closed_code)
	if _auth_provider != null:
		for outcome: AuthOutcome in _auth_provider.take_completed():
			_apply_auth_outcome(outcome)
	_check_verify_timeouts()


# El final de una reclamación (tabla de §5.2). Con OK, en orden: (1) la zona admite el reino del personaje
# (REALM); (2) cabe (FULL); (3) ProgressService.prepare (progresion.md P5a); (4) WELCOME con el reino y el nombre
# del personaje. Si falla alguno, REJECT y se libera el arrendamiento.
func _apply_auth_outcome(outcome: AuthOutcome) -> void:
	var peer: ServerPeer = _peers.get(outcome.peer_id)
	if peer == null or peer.state != ServerPeer.State.VERIFYING:
		# Se fue en el mismo tick: el proveedor ya no lo esperaba, pero por si acaso no queda nada colgado.
		if outcome.result == NetProtocol.Result.OK and outcome.claimed != null and _platform != null:
			_platform.release(outcome.claimed.character_id, outcome.claimed.lease_id)
		return
	if outcome.result != NetProtocol.Result.OK:
		_reject(peer, outcome.result, outcome.text)
		return
	var claimed: ClaimedCharacter = outcome.claimed
	var rejection: int = NetProtocol.Result.OK
	if not _auth.is_realm_allowed(claimed.realm):
		rejection = NetProtocol.Result.REALM
	else:
		# Él ya cuenta en _occupied_seats (VERIFYING): el cupo se mira sin él, como en ServerAuth.
		var others: int = _occupied_seats() - 1
		if others - _filler_seats() >= _config.max_players \
				or not _make_room_for(peer, claimed.realm, claimed.display_name, others):
			rejection = NetProtocol.Result.FULL
	if rejection != NetProtocol.Result.OK:
		_platform.release(claimed.character_id, claimed.lease_id)
		_reject(peer, rejection)
		return
	peer.claimed = claimed
	_welcome(peer, claimed.realm, claimed.display_name)
	if peer.state == ServerPeer.State.LOADING:
		_log("%s (personaje %d, cuenta %d, %s) entra con billete (peer %d)" % [claimed.display_name,
				claimed.character_id, claimed.account_id, claimed.role, peer.peer_id])


# Los peers en VERIFYING desde hace más de verify_timeout_ms (tiempo real, desde la conexión): REJECT
# UNAVAILABLE. Si la reclamación llega después, el proveedor la libera.
func _check_verify_timeouts() -> void:
	var now: int = Time.get_ticks_msec()
	for peer: ServerPeer in _peers.values():
		if peer.state == ServerPeer.State.VERIFYING and now - peer.connected_at_msec >= verify_timeout_ms:
			_log("Conexión de %s (peer %d): %s" % [peer.remote_address, peer.peer_id, VERIFY_TIMEOUT_REASON])
			_reject(peer, NetProtocol.Result.UNAVAILABLE)


# Respuesta del latido: los revoked (§6). Cada entrada lleva el lease_id; la que no casa con el arrendamiento
# actual del personaje en esta zona no expulsa a nadie. lease_lost es la baja sin guardado (sin liberar: el
# arrendamiento ya no es de la zona); los demás expulsan con el texto de la plataforma (hasta P5, sin guardado
# final: se libera al irse el cuerpo, o en el acto si estaba cargando). Los silencios son de P7b y el
# mantenimiento, de P5.
func _on_heartbeat_event(event: PlatformEvent) -> void:
	if not event.is_success():
		return
	for value: Variant in PlatformJson.array_in(event.body_dict(), "revoked"):
		var revoked: Dictionary = value if value is Dictionary else {}
		var character_id: int = PlatformJson.id_of(revoked.get("character_id"))
		var lease_id: String = PlatformJson.text_in(revoked, "lease_id")
		var reason: String = PlatformJson.text_in(revoked, "reason")
		var text: String = PlatformJson.text_in(revoked, "text")
		if character_id < 1 or lease_id.is_empty():
			continue
		_revoke(character_id, lease_id, reason, text)


func _revoke(character_id: int, lease_id: String, reason: String, text: String) -> void:
	var lease_lost: bool = reason == "lease_lost"
	for peer: ServerPeer in _peers.values():
		if peer.claimed == null or peer.claimed.character_id != character_id \
				or peer.claimed.lease_id != lease_id:
			continue
		if peer.state != ServerPeer.State.LOADING and peer.state != ServerPeer.State.IN_WORLD:
			continue
		_log("La plataforma revoca a %s (personaje %d): %s" % [peer.display_name, character_id, reason])
		if lease_lost:
			# El arrendamiento ya no es de esta zona: ni se libera ni se guarda, y el cuerpo sale en el acto.
			peer.claimed = null
			if peer.entity != null:
				_claims_by_net.erase(peer.entity.net_id)
			peer.drop_body_at_once = true
		_kick(peer, reason, false, text if not text.is_empty() else "Tu sesión ha terminado: vuelve a entrar")
		return
	# Un cuerpo que se queda tras una salida en combate: un lease_lost no se libera al irse.
	if lease_lost:
		for net_id: int in _claims_by_net.keys():
			var claim: ClaimedCharacter = _claims_by_net[net_id]
			if claim.character_id == character_id and claim.lease_id == lease_id:
				_claims_by_net.erase(net_id)


# Libera sin guardar el arrendamiento del cuerpo [param net_id], si tiene uno.
func _release_claim_of(net_id: int) -> void:
	var claim: ClaimedCharacter = _claims_by_net.get(net_id)
	if claim == null:
		return
	_claims_by_net.erase(net_id)
	if _platform != null:
		_platform.release(claim.character_id, claim.lease_id)


# Un peer que deja VERIFYING o LOADING sin llegar al mundo (§5.2): en VERIFYING se cancela la espera de su
# reclamación; en LOADING se libera su arrendamiento sin guardar (y ProgressService.cancel_prepared, P5a).
func _leave_auth_states(peer: ServerPeer) -> void:
	match peer.state:
		ServerPeer.State.VERIFYING:
			if _auth_provider != null:
				_auth_provider.cancel(peer.peer_id)
		ServerPeer.State.LOADING:
			if peer.claimed != null and _platform != null:
				_platform.release(peer.claimed.character_id, peer.claimed.lease_id)
				peer.claimed = null


# Autenticación completada en los dos lados: ya se puede enviar a este peer.
func _on_peer_connected(peer_id: int) -> void:
	var peer: ServerPeer = _peers.get(peer_id)
	if peer == null or peer.state != ServerPeer.State.LOADING:
		return
	_log("Conexión de %s (peer %d, %s, %s): cargando la zona" % [peer.display_name, peer_id,
			peer.remote_address, NetProtocol.realm_display_name(peer.realm)])


func _on_peer_disconnected(peer_id: int) -> void:
	var peer: ServerPeer = _peers.get(peer_id)
	if peer == null:
		return
	if _run_state == _RunState.STOPPING:
		_peers.erase(peer_id)
		return
	_mark_leaving(peer)


# El transporte ha descartado [param count] paquetes de este peer por no ser del protocolo (SYS que no
# es autenticación antes del HELLO; después, cualquier cosa que no sea un paquete de aplicación): un
# cliente de verdad nunca los manda. Cada uno suma un aviso; a los 50 se le expulsa. Con más de 50
# de golpe no hace falta contarlos todos.
func _on_packets_discarded(peer_id: int, count: int) -> void:
	var peer: ServerPeer = _peers.get(peer_id)
	if peer == null or _run_state != _RunState.RUNNING or peer.state == ServerPeer.State.LEAVING:
		return
	for _i: int in mini(count, ServerPeer.STRIKE_LIMIT):
		_add_strike(peer, DISCARDED_REASON)
		if peer.state == ServerPeer.State.LEAVING:
			return


func _on_packet_received(peer_id: int, bytes: PackedByteArray) -> void:
	var peer: ServerPeer = _peers.get(peer_id)
	if peer == null or _run_state != _RunState.RUNNING or bytes.is_empty():
		return
	if peer.state == ServerPeer.State.LEAVING:
		return
	var msg_type: int = NetMessages.peek_type(bytes)
	# Limitadores por peer: lo que sobra se descarta y suma un aviso.
	var limiter: RateLimiter = peer.limiter_unreliable \
			if msg_type == NetProtocol.MSG_INPUT_BATCH else peer.limiter_reliable
	if not limiter.try_consume(_tick) or not peer.limiter_bytes.try_consume(_tick,
			float(bytes.size())):
		_add_strike(peer, "exceso de ritmo")
		return
	if peer.state == ServerPeer.State.AUTHENTICATING or peer.state == ServerPeer.State.VERIFYING:
		_add_strike(peer, "mensaje antes de autenticarse")
		return
	match msg_type:
		NetProtocol.MSG_INPUT_BATCH:
			_handle_input_batch(peer, bytes)
		NetProtocol.MSG_CLIENT_READY:
			_handle_client_ready(peer, bytes)
		NetProtocol.MSG_CLIENT_LEAVE:
			_handle_client_leave(peer, bytes)
		NetProtocol.MSG_DEBUG_COMMAND:
			_handle_debug_command(peer, bytes)
		NetProtocol.MSG_RESPAWN_REQUEST:
			_handle_respawn_request(peer, bytes)
		NetProtocol.MSG_UNSTUCK_REQUEST:
			_handle_unstuck_request(peer, bytes)
		NetProtocol.MSG_LOADOUT_SELECT:
			_handle_loadout_select(peer, bytes)
		_:
			# El chat y los grupos (0x40 a 0x4F) los atiende el servicio social.
			if not _social.handle_packet(peer, msg_type, bytes, _tick):
				_add_strike(peer, "tipo de mensaje inesperado (0x%02X)" % msg_type)


func _handle_input_batch(peer: ServerPeer, bytes: PackedByteArray) -> void:
	if peer.state != ServerPeer.State.IN_WORLD:
		_add_strike(peer, "entradas antes de entrar en el mundo")
		return
	var batch: NetMessages.InputBatch = NetMessages.InputBatch.decode(bytes)
	if batch == null:
		_add_strike(peer, "lote de entradas mal formado")
		return
	# El retardo de interpolación del cliente no pasa de 12 ticks (× 8): más es un cliente falso.
	peer.interp_delay_q = mini(batch.interp_delay_q, NetProtocol.MAX_INTERP_DELAY_Q)
	if batch.interp_delay_q > NetProtocol.MAX_INTERP_DELAY_Q:
		_add_strike(peer, "retardo de interpolación fuera de rango")
	# El ack no puede ir por delante del servidor ni retroceder; con él se mide el RTT en ticks.
	if batch.ack_snapshot_tick > 0 and batch.ack_snapshot_tick <= _tick \
			and batch.ack_snapshot_tick >= peer.ack_snapshot_tick:
		peer.ack_snapshot_tick = batch.ack_snapshot_tick
		var window: _RttWindow = _rtt.get(peer.peer_id)
		if window == null:
			window = _RttWindow.new()
			_rtt[peer.peer_id] = window
		var next_tick: int = _tick + 1
		window.add(next_tick, next_tick - batch.ack_snapshot_tick)
		var plausible: int = _max_plausible_rtt_ticks(peer)
		peer.rtt_ticks = mini(maxi(window.get_min(next_tick), 0), plausible)
		peer.rtt_peak_ticks = mini(maxi(window.get_max(next_tick), peer.rtt_ticks), plausible)
	# Cota inferior del RTT: el de ENet, que el cliente no controla (lo usa el rebobinado como mínimo).
	if _transport != null:
		peer.rtt_floor_ticks = floori(_transport.get_rtt_ms(peer.peer_id)
				* float(Engine.physics_ticks_per_second) / 1000.0)
	for i: int in batch.inputs.size():
		peer.input_queue.push(batch.inputs[i], batch.view_offsets_q[i], _tick + 1)


# Cota del RTT en ticks que puede declarar un cliente con sus acks. El ack lo decide el cliente: uno
# que atrasara sus acks se haría pasar por alguien con lag y obtendría el rebobinado máximo de la fase
# 3. La cota sale de fuentes que no controla: el RTT de ENet, el retardo que añade el simulador de
# red del propio servidor y un margen. (El --net-sim del cliente no cuenta: en producción sería
# fingir lag; para probar con lag se usa el del servidor.)
func _max_plausible_rtt_ticks(peer: ServerPeer) -> int:
	var enet_ticks: int = 0
	var sim_ticks: int = 0
	if _transport != null:
		enet_ticks = ceili(_transport.get_rtt_ms(peer.peer_id) \
				* float(Engine.physics_ticks_per_second) / 1000.0)
		sim_ticks = _transport.get_sim_round_trip_ticks()
	return enet_ticks + sim_ticks + RTT_SLACK_TICKS


func _handle_client_ready(peer: ServerPeer, bytes: PackedByteArray) -> void:
	if peer.state != ServerPeer.State.LOADING or _pending_ready.has(peer.peer_id):
		_add_strike(peer, "CLIENT_READY inesperado")
		return
	if NetMessages.ClientReady.decode(bytes) == null:
		_add_strike(peer, "CLIENT_READY mal formado")
		return
	_pending_ready.append(peer.peer_id)


func _handle_client_leave(peer: ServerPeer, bytes: PackedByteArray) -> void:
	if NetMessages.ClientLeave.decode(bytes) == null:
		_add_strike(peer, "CLIENT_LEAVE mal formado")
		return
	_transport.disconnect_after_flush(peer.peer_id)
	_mark_leaving(peer)


func _handle_debug_command(peer: ServerPeer, bytes: PackedByteArray) -> void:
	if peer.state != ServerPeer.State.IN_WORLD:
		_add_strike(peer, "comando de depuración antes de entrar en el mundo")
		return
	if not _config.debug_commands:
		_add_strike(peer, "comando de depuración no permitido")
		return
	var command: NetMessages.DebugCommand = NetMessages.DebugCommand.decode(bytes)
	if command == null:
		_add_strike(peer, "comando de depuración mal formado")
		return
	var result: int = _commands.execute_network(peer, command.command, command.payload)
	match result:
		CommandRegistry.Result.UNKNOWN:
			# Un id fijo del protocolo cuyo manejador no existe en este servidor (el de un comando que se haya
			# quitado, o el de npc_debug con --no-npcs) se acepta sin hacer nada: no es un cliente defectuoso.
			if not NetProtocol.DEBUG_COMMAND_IDS.values().has(command.command):
				_add_strike(peer, "comando de depuración desconocido (%d)" % command.command)
		CommandRegistry.Result.BAD_ARGUMENTS:
			_add_strike(peer, "comando de depuración con argumentos no válidos (%d)"
					% command.command)


# RESPAWN_REQUEST: un muerto pide reaparecer en el punto point_index de la lista estática de la zona
# (NetZones.get_all_respawn_points). Fuera de plazo (vivo, o mucho antes de poder) es un aviso; un índice que
# ya no vale (un campamento ajeno, un fuerte que ha cambiado de manos o está atacado) no lo es: el estado del
# cliente va atrasado y se usa el primer campamento válido de su reino.
func _handle_respawn_request(peer: ServerPeer, bytes: PackedByteArray) -> void:
	if peer.state != ServerPeer.State.IN_WORLD:
		_add_strike(peer, "petición de reaparición antes de entrar en el mundo")
		return
	var request: NetMessages.RespawnRequest = NetMessages.RespawnRequest.decode(bytes)
	if request == null:
		_add_strike(peer, "petición de reaparición mal formada")
		return
	var result: int = _combat.request_respawn(peer.entity.net_id, request.point_index, _tick + 1)
	if result != CombatDirector.RespawnRequestResult.ACCEPTED:
		_add_strike(peer, "petición de reaparición fuera de plazo")


# UNSTUCK_REQUEST (/atascado, docs/fuerte.md sección 5): sin necesidad de --debug-commands. Canalización
# de 10 s fuera de combate, que el combate interrumpe, con 5 min de reutilización; ver _request_unstuck.
func _handle_unstuck_request(peer: ServerPeer, bytes: PackedByteArray) -> void:
	if peer.state != ServerPeer.State.IN_WORLD:
		_add_strike(peer, "petición de /atascado antes de entrar en el mundo")
		return
	if NetMessages.UnstuckRequest.decode(bytes) == null:
		_add_strike(peer, "petición de /atascado mal formada")
		return
	_request_unstuck(peer)


# LOADOUT_SELECT (docs/habilidades.md, secciones 4.6 y 5.1): la plantilla de la siguiente aparición. Vale en
# LOADING (desde el WELCOME, antes de CLIENT_READY) e IN_WORLD; ya ha pasado por el limitador de fiables. 0 = la
# de por defecto, sin aviso; un id que no existe o no se puede elegir cuenta un aviso y no cambia nada.
func _handle_loadout_select(peer: ServerPeer, bytes: PackedByteArray) -> void:
	if peer.state != ServerPeer.State.LOADING and peer.state != ServerPeer.State.IN_WORLD:
		_add_strike(peer, "LOADOUT_SELECT inesperado")
		return
	var select: NetMessages.LoadoutSelect = NetMessages.LoadoutSelect.decode(bytes)
	if select == null:
		_add_strike(peer, "LOADOUT_SELECT mal formado")
		return
	if select.template_id != 0:
		var template: EquipmentTemplate = CombatCatalog.template(select.template_id)
		if template == null or not template.selectable:
			_add_strike(peer, "plantilla de equipo no válida (%d)" % select.template_id)
			return
	peer.pending_template_id = select.template_id


# Suma un aviso y expulsa al peer si llega al límite (50 en 600 ticks).
func _add_strike(peer: ServerPeer, reason: String) -> void:
	_strikes_total += 1
	_strike_reasons[reason] = _strike_reasons.get(reason, 0) + 1
	if peer.add_strike(_tick, reason):
		_kick(peer, reason)


# NOTICE de expulsión y corte ordenado. El motivo queda en el informe. Con [param cooldown], su IP (o,
# desde loopback, su nombre o su personaje) no puede volver a entrar durante kick_cooldown_ticks. Con
# [param notice_text] el NOTICE lleva ese texto tal cual (el de un revoked de la plataforma).
func _kick(peer: ServerPeer, reason: String, cooldown: bool = true, notice_text: String = "") -> void:
	if peer.state == ServerPeer.State.LEAVING:
		return
	if cooldown:
		_start_cooldown(peer)
	var notice := NetMessages.Notice.new()
	notice.code = NetProtocol.NoticeCode.KICK
	notice.text = notice_text if not notice_text.is_empty() else "Expulsado del servidor: %s" % reason
	_transport.send(peer.peer_id, NetProtocol.CH_RELIABLE, notice.encode())
	_transport.disconnect_after_flush(peer.peer_id)
	var net_id: int = peer.entity.net_id if peer.entity != null else 0
	_kicks.append({
		"tick": _tick, "peer_id": peer.peer_id, "net_id": net_id, "name": peer.display_name,
		"reason": reason,
	})
	_kicks_total += 1
	while _kicks.size() > max_logged_kicks:
		_kicks.pop_front()
	var record: _PlayerRecord = _player_by_net.get(net_id)
	if record != null:
		record.kicked = true
		record.kick_reason = reason
	_log("Expulsión de %s (peer %d): %s" % [peer.display_name, peer.peer_id, reason])
	_mark_leaving(peer)


# Apunta el enfriamiento de un peer expulsado y purga los vencidos. Por IP (las IPv6, por /64) salvo
# desde loopback, donde no hay tope por IP y se usa el nombre normalizado, si ya lo había dado (con billete, el
# personaje: character:<id>, docs/plataforma.md §5.4).
func _start_cooldown(peer: ServerPeer) -> void:
	var key: String = _cooldown_key_for_address(peer.remote_address)
	if key.is_empty():
		key = _cooldown_key_for_identity(peer.remote_address, peer.display_name, peer.character_id)
	if key.is_empty():
		return
	for old_key: String in _kick_until.keys():
		if _kick_until[old_key] <= _tick:
			_kick_until.erase(old_key)
	_kick_until[key] = _tick + kick_cooldown_ticks


# Clave de enfriamiento por dirección, o vacía si es loopback o no se conoce.
func _cooldown_key_for_address(address: String) -> String:
	if address.is_empty() or ServerAuth.is_loopback(address):
		return ""
	return "ip:" + ServerAuth.address_group(address)


# Clave de enfriamiento por identidad: solo desde loopback, que no tiene tope por IP. Con billete, el personaje
# ([param character_id] > 0); sin él, el nombre del HELLO.
func _cooldown_key_for_identity(address: String, display_name: String, character_id: int) -> String:
	if not ServerAuth.is_loopback(address):
		return ""
	if character_id > 0:
		return "character:%d" % character_id
	if display_name.is_empty():
		return ""
	return "name:" + NameRules.normalize_key(display_name)


func _is_cooling_down(key: String) -> bool:
	return not key.is_empty() and _kick_until.get(key, 0) > _tick


func _mark_leaving(peer: ServerPeer) -> void:
	if peer.state == ServerPeer.State.LEAVING:
		return
	_leave_auth_states(peer)
	peer.state = ServerPeer.State.LEAVING
	_leaving.append(peer.peer_id)


# REJECT y corte ordenado: lo encolado sale antes de cortar. [param text] vacío = el de
# NetProtocol.result_text (el informe cuenta siempre por ese, no por el texto propio).
func _reject(peer: ServerPeer, result: int, text: String = "") -> void:
	var reject := NetMessages.Reject.new()
	reject.result = result
	reject.text = text if not text.is_empty() else NetProtocol.result_text(result)
	_transport.send_auth(peer.peer_id, reject.encode())
	_transport.disconnect_after_flush(peer.peer_id)
	var key: String = NetProtocol.result_text(result)
	_rejects[key] = _rejects.get(key, 0) + 1
	_log("Conexión rechazada de %s (peer %d): %s" % [peer.remote_address, peer.peer_id,
			reject.text])
	_mark_leaving(peer)


# Falsos de relleno vivos, sin los que ya tienen la baja pedida (esos ya no cuentan en get_player_count).
func _live_fillers() -> int:
	if _filler_keeper == null:
		return 0
	var count: int = 0
	for net_id: int in _fakes:
		if _filler_keeper.is_filler(net_id) and not _fake_leaving.has(net_id):
			count += 1
	return count


# Plazas que el relleno tiene apartadas para personas que aún cargan la zona (GUE-43): como mucho, una por falso de
# relleno vivo. Cada una es un jugador de más hasta que esa persona entra en el mundo y su falso se va.
func _reserved_seats() -> int:
	if _filler_keeper == null:
		return 0
	return mini(_filler_keeper.reserved_count(), _live_fillers())


# Plazas ocupadas para el cupo: los jugadores de get_player_count() menos los falsos de relleno que ya han apartado su
# plaza a alguien (se van cuando entra).
func _occupied_seats() -> int:
	return get_player_count() - _reserved_seats()


# Falsos de relleno que aún pueden ceder su plaza a una persona (GUE-43): los vivos que no la han apartado ya.
func _filler_seats() -> int:
	return maxi(_live_fillers() - _reserved_seats(), 0)


# Un HELLO aceptado con el servidor lleno solo por los falsos de relleno: el guardián le aparta la plaza de uno, que se
# va cuando la persona entra en el mundo (FillerKeeper.on_person_joined). false si no hay sitio (no debería pasar:
# ServerAuth ya ha comprobado que el relleno basta). [param occupied] son las plazas ocupadas sin contarle a él.
func _make_room_for(peer: ServerPeer, realm: int, display_name: String, occupied: int) -> bool:
	if occupied < _config.max_players:
		return true
	if _filler_keeper == null or _filler_seats() <= 0:
		return false
	if not _filler_keeper.reserve_seat(peer.peer_id, realm):
		return false
	_log("Servidor lleno de relleno: un falso de relleno aparta su plaza a %s (peer %d, %s); se irá cuando entre"
			% [display_name, peer.peer_id, NetProtocol.realm_display_name(realm)])
	return true


# Conexiones abiertas desde la misma IP que [param peer], sin contarlo a él (las IPv6 se cuentan por
# prefijo /64, ver ServerAuth.address_group).
func _connections_from(peer: ServerPeer) -> int:
	if peer.remote_address.is_empty():
		return 0
	var group: String = ServerAuth.address_group(peer.remote_address)
	var count: int = 0
	for other: ServerPeer in _peers.values():
		if other != peer and other.state != ServerPeer.State.LEAVING \
				and ServerAuth.address_group(other.remote_address) == group:
			count += 1
	return count


# Tras stop(): sigue sondeando hasta que los peers se han ido o pasan STOP_DRAIN_TICKS ticks.
func _drain_stop() -> void:
	_drain_ticks += 1
	if _transport != null:
		_transport.poll(_tick + _drain_ticks)
		_transport.flush()
	if _peers.is_empty() or _drain_ticks >= STOP_DRAIN_TICKS:
		_finish_stop()


func _finish_stop() -> void:
	_peers.clear()
	_disconnect_transport()
	if _transport != null and is_instance_valid(_transport):
		_sync_byte_counters()
		_transport.close()
	_run_state = _RunState.STOPPED
	set_physics_process(false)


# --- Auxiliares -------------------------------------------------------------------------------

# Personaje del servidor: una instancia de player_character.tscn sin su nodo Visual (mallas), sin
# proceso propio. Solo ZoneServer lo simula.
func _instantiate_character() -> PlayerCharacter:
	var character: PlayerCharacter = PLAYER_SCENE.instantiate() as PlayerCharacter
	var visual: Node = character.get_node_or_null(^"Visual")
	if visual != null:
		character.remove_child(visual)
		visual.free()
	character.set_physics_process(false)
	character.set_process(false)
	character.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	return character


# Huella de la simulación, calculada sobre una instancia dentro del árbol después de _ready().
func _compute_sim_hash() -> int:
	var character: PlayerCharacter = _instantiate_character()
	_players_root.add_child(character)
	var hash_value: int = NetProtocol.compute_sim_hash(character)
	_players_root.remove_child(character)
	character.free()
	return hash_value


# true si hay suelo justo bajo [param position] (a menos de lo que alcanza el ajuste al suelo del
# personaje): el estado de aparición nace entonces con grounded = true. El rayo va ligeramente
# inclinado porque los verticales pueden fallar contra HeightMapShape3D.
func _probe_grounded(position: Vector3) -> bool:
	var space: PhysicsDirectSpaceState3D = _players_root.get_world_3d().direct_space_state
	var from: Vector3 = position + Vector3(0.0, _PROBE_UP, 0.0)
	var query := PhysicsRayQueryParameters3D.create(from,
			from + Vector3(0.001, -(_PROBE_UP + _PROBE_DOWN), 0.0),
			PlayerCharacter.WORLD_COLLISION_LAYER)
	return not space.intersect_ray(query).is_empty()


# Yaw (misma convención que Node3D.rotation.y) hacia el que mira una base.
static func _yaw_of(transform: Transform3D) -> float:
	var forward: Vector3 = -transform.basis.z
	return atan2(-forward.x, -forward.z)


# Acumula los bytes de ENet del transporte en las métricas.
func _sync_byte_counters() -> void:
	if _transport == null or not is_instance_valid(_transport):
		return
	var counters: Dictionary = _transport.get_byte_counters()
	var wire_in: int = counters.get("wire_in", 0)
	var wire_out: int = counters.get("wire_out", 0)
	_metrics.add_counter(ServerMetrics.COUNTER_BYTES_IN, wire_in - _synced_wire_in)
	_metrics.add_counter(ServerMetrics.COUNTER_BYTES_OUT, wire_out - _synced_wire_out)
	_synced_wire_in = wire_in
	_synced_wire_out = wire_out


func _open_state_log() -> void:
	if _config.state_log_path.is_empty():
		return
	var directory: String = _config.state_log_path.get_base_dir()
	if not directory.is_empty() and not DirAccess.dir_exists_absolute(directory):
		DirAccess.make_dir_recursive_absolute(directory)
	_state_log = FileAccess.open(_config.state_log_path, FileAccess.WRITE)
	if _state_log == null:
		push_warning("[Eldmark] No se pudo abrir el registro de estados '%s' (error %d)"
				% [_config.state_log_path, FileAccess.get_open_error()])


func _close_state_log() -> void:
	if _state_log != null:
		_state_log.close()
		_state_log = null


func _release_resources() -> void:
	if _npc_system != null:
		_npc_system.dispose()
		_npc_system = null
	_close_state_log()
	_metrics.unregister_monitors()
	_disconnect_transport()


# Línea de métricas cada 10 s: duración del tick, jugadores, entradas sustituidas, ancho de banda y, al final, los PNJ
# que se simulan en ese momento (los de guerra y los maniquíes; GUE-16: la carga con PNJ los sigue a lo largo de la
# batalla).
func _log_metrics(s: int) -> void:
	_sync_byte_counters()
	var now_usec: int = Time.get_ticks_usec()
	var seconds: float = maxf(float(now_usec - _log_last_usec) / 1000000.0, 0.001)
	_log_last_usec = now_usec
	var kb_out: float = float(_synced_wire_out - _log_last_wire_out) / 1024.0 / seconds
	var kb_in: float = float(_synced_wire_in - _log_last_wire_in) / 1024.0 / seconds
	_log_last_wire_out = _synced_wire_out
	_log_last_wire_in = _synced_wire_in
	var sections := PackedStringArray()
	for section: StringName in LOGGED_SECTIONS:
		sections.append("%s %d" % [section, _metrics.get_percentile_us(section, 0.99)])
	_log("Métricas (tick %d): %d jugadores, tick p50 %d µs / p99 %d µs / máx %d µs "
			% [s, _metrics.get_counter(ServerMetrics.COUNTER_PLAYERS),
			_metrics.get_percentile_us(ServerMetrics.SECTION_TICK, 0.5),
			_metrics.get_percentile_us(ServerMetrics.SECTION_TICK, 0.99),
			_metrics.get_max_us(ServerMetrics.SECTION_TICK)]
			+ "(p99 por sección: %s), entradas sustituidas %.2f %%, subida %.1f KB/s, "
			% [", ".join(sections), _metrics.get_substituted_percent(), kb_out]
			+ "bajada %.1f KB/s, %d PNJ" % [kb_in, _npcs.size()])


func _build_report() -> Dictionary:
	_sync_byte_counters()
	var network_bytes: Dictionary = {}
	if _transport != null and is_instance_valid(_transport):
		network_bytes = _transport.get_byte_counters()
	var player_list: Array[Dictionary] = []
	var inputs: int = _archived_inputs
	var substituted: int = _archived_substituted
	var late: int = _archived_late
	var too_early: int = _archived_too_early
	for record: _PlayerRecord in _player_log:
		player_list.append(record.to_dictionary())
		if not record.is_fake:
			inputs += record.inputs
			substituted += record.substituted
			late += record.late
			too_early += record.too_early
	var substituted_percent: float = 0.0
	if inputs > 0:
		substituted_percent = 100.0 * float(substituted) / float(inputs)
	return {
		"version": 1,
		"zone": _config.zone_id if _config != null else "",
		"port": _config.port if _config != null else 0,
		"ticks": _tick,
		"tick_rate": Engine.physics_ticks_per_second,
		"sim_hash": _sim_hash,
		"closed": _run_state == _RunState.STOPPING or _run_state == _RunState.STOPPED,
		"players": {
			"current": get_player_count(),
			"at_stop": _players_at_stop,
			"fake": _count_fakes_in_log(),
			"peak": _peak_players,
			"joined_total": _joined_total,
			"left_total": _left_total,
			"archived": _archived_players,
		},
		"inputs": {
			"consumed": inputs,
			"substituted": substituted,
			"late": late,
			"too_early": too_early,
			"substituted_percent": substituted_percent,
		},
		"bytes": network_bytes,
		"strikes": {"total": _strikes_total, "by_reason": _strike_reasons,
				"kicks_total": _kicks_total},
		"kicks": _kicks,
		"rejects": _rejects,
		"physics_errors": _physics_errors,
		"teleports": _teleports,
		"respawns": _respawns + _combat_stat(&"respawns") + _combat_stat(&"voids"),
		"combat": _combat_report(),
		"war": _war_report(),
		"npcs": _npc_report(),
		"social": _social.get_stats() if _social != null else {},
		"simulate": {
			"calls": _simulate_calls,
			"total_us": _simulate_usec_total,
			"avg_us": float(_simulate_usec_total) / float(_simulate_calls) \
					if _simulate_calls > 0 else 0.0,
			"max_us": _simulate_usec_max,
		},
		"snapshots": {
			"sent": _snapshots_sent,
			"bytes": _snapshot_bytes_total,
			"avg_bytes": float(_snapshot_bytes_total) / float(_snapshots_sent) \
					if _snapshots_sent > 0 else 0.0,
			"max_bytes": _snapshot_bytes_max,
			"build_us": _snapshot_build_usec,
			"avg_build_us": float(_snapshot_build_usec) / float(_snapshots_sent) \
					if _snapshots_sent > 0 else 0.0,
		},
		"metrics": _metrics.summary(),
		"player_list": player_list,
	}


func _combat_stat(stat: StringName) -> int:
	return _combat.stats.get(stat, 0) if _combat != null else 0


# Resumen del combate para el informe: los contadores del director, los eventos enviados y la
# puntuación de sospecha por peer (solo los sospechosos).
func _combat_report() -> Dictionary:
	var suspicious: Array[Dictionary] = []
	for record: _PlayerRecord in _player_log:
		record.refresh()
		if record.suspicion > 0:
			suspicious.append({"net_id": record.net_id, "name": record.display_name,
					"suspicion": record.suspicion, "rewind_rejects": record.rewind_rejects})
	var report: Dictionary = {}
	if _combat != null:
		for stat: StringName in _combat.stats:
			report[String(stat)] = _combat.stats[stat]
		# Los efectos de estado (docs/habilidades.md, 4.3): aplicados, quitados, pulsos y vida curada.
		for stat: StringName in _combat.status.stats:
			report[String(stat)] = _combat.status.stats[stat]
		# Los proyectiles (docs/habilidades.md, 4.4): disparos, impactos, bajas, criba y pico de vivos.
		for stat: StringName in _combat.projectiles.stats:
			report[String(stat)] = _combat.projectiles.stats[stat]
		report["projectiles_live"] = _combat.projectiles.live_count()
		# El derribado (docs/habilidades.md, 4.5): derribos, levantados, rematados, desangrados e interacciones.
		for stat: StringName in _combat.downed.stats:
			report[String(stat)] = _combat.downed.stats[stat]
		report["downed_now"] = _combat.downed.downed_count()
	report["projectile_messages_sent"] = _projectile_messages_sent
	report["projectile_bytes_sent"] = _projectile_bytes_sent
	report["events_sent"] = _events_sent
	report["event_bytes_sent"] = _event_bytes_sent
	report["dummies"] = get_dummy_count() if _combat != null else 0
	report["dummies_created"] = _dummies_created
	report["suspicious"] = suspicious
	return report


# Resumen de los PNJ para el informe: lo del sistema de generadores y los avisos de ataques fuertes.
func _npc_report() -> Dictionary:
	var report: Dictionary = _npc_system.get_report() if _npc_system != null else {}
	report["npcs_now"] = _npcs.size()
	report["telegraphs"] = _telegraphs_sent
	return report


# Resumen de la guerra para el informe: el estado de cada fortaleza, el marcador, las salidas en combate y los
# usos de /atascado.
func _war_report() -> Dictionary:
	# Tras stop() el controlador ya no tiene fortalezas (se liberan con los jugadores): el informe final
	# lleva su estado en el momento del cierre.
	var fortresses: Array[Dictionary] = _fortress_entries()
	if fortresses.is_empty():
		fortresses = _war_fortresses_at_stop
	return {
		"fortresses": fortresses,
		"object_states_sent": _object_states_sent,
		"scoreboards_sent": _scoreboards_sent,
		"lingering_total": _lingering_total,
		"lingering_now": _lingering.size(),
		"unstuck": {
			"uses": _unstuck_uses,
			"completed": _unstuck.completed_count,
			"interrupted": _unstuck.interrupted_count,
			"log": _unstuck_log,
		},
	}


# El estado de cada fortaleza viva para el informe.
func _fortress_entries() -> Array[Dictionary]:
	var fortresses: Array[Dictionary] = []
	if _fortresses == null:
		return fortresses
	for fortress_id: StringName in _fortresses.get_fortress_ids():
		var state: FortressState = _fortresses.get_fortress_state(fortress_id)
		fortresses.append({
			"id": String(fortress_id), "owner": state.owner, "phase": state.phase,
			"gate_health": state.gate_health, "gate_max": state.gate_max,
			"captain_alive": state.captain_alive, "guards_alive": state.guards_alive,
		})
	return fortresses


func _count_fakes_in_log() -> int:
	var count: int = _archived_fakes
	for record: _PlayerRecord in _player_log:
		if record.is_fake:
			count += 1
	return count


func _log(text: String) -> void:
	if log_enabled:
		print("[Eldmark] %s" % text)
