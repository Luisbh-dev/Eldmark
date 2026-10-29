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
##                  RESPAWN_REQUEST, DEBUG_COMMAND; y las líneas de la consola
## tick += 1        s es el tick que se simula
## bajas            desconexión, LEAVE o expulsión -> DESPAWN (motivo 1) y el id en cuarentena
## simular          todas las entidades con cuerpo (jugadores, falsos y PNJ) por net_id ascendente,
##                  con la entrada de InputQueue.take(s); _check_motion
## combate          CombatDirector.process_tick(): congelar, resolver los golpes, aplicar (daño,
##                  controles, muertes), entorno (caída, volúmenes letales, y < -100),
##                  reapariciones y publicar la vida; los ENTITY_EVENT salen aquí
## altas            los READY pendientes: el jugador aparece con el estado «tras s»
## historial        StateHistory.record() de todas las entidades, ya con lo impuesto
## snapshots        SnapshotBuilder.begin(); interés cada 6 ticks, escalonado; un SNAPSHOT a cada
##                  cliente cada 2 ticks, escalonado por la paridad de su net_id
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
## [b]Seguridad[/b] (sección 12): limitadores por peer, avisos con expulsión a los 50 en 600 ticks
## (NOTICE de expulsión y corte), tope de conexiones por IP, tipos de mensaje inesperados según el
## estado de la sesión y comandos de depuración solo con [code]--debug-commands[/code].
## [br][br]
## [b]Jugadores falsos[/b] ([method add_fake_player]): jugadores sin red cuyas entradas salen de un
## [BotBrain] y entran directamente en su [InputQueue]; sirven para las pruebas y la carga.
## [br][br]
## [b]Combate[/b] (docs/combate.md): un [CombatDirector] lleva la vida, los golpes con rebobinado, las
## muertes y las reapariciones; los PNJ ([method add_npc], el maniquí de entrenamiento) son cuerpos
## simulados en el mismo bucle que los jugadores; los comandos de depuración y la consola pasan por el
## [CommandRegistry] y [code]--combat-log[/code] deja una línea por golpe resuelto.

## Se emite al terminar cada tick, ya enviado todo lo del tick.
signal tick_finished(tick: int)
## Un jugador (de red) ha entrado en el mundo.
signal player_joined(peer_id: int, net_id: int)
## Un jugador (de red) ha salido del mundo.
signal player_left(peer_id: int, net_id: int)
## La cuenta atrás de un cierre pedido por la consola ([code]shutdown <s>[/code]) ha llegado a 0:
## quien lleva el proceso ([ServerMain]) debe cerrar el servidor.
signal shutdown_requested(reason: String)

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
## Ticks que un peer puede estar conectado sin enviar el HELLO (1,5 s). Mucho menos que los 5 s de
## la autenticación de [SceneMultiplayer]: una conexión ociosa ocupa una de las plazas de ENet.
const HELLO_TIMEOUT_TICKS: int = 90
## Motivo con el que el informe cuenta (en [code]rejects[/code]) las conexiones cortadas por no
## mandar el HELLO a tiempo.
const HELLO_TIMEOUT_REASON: String = "sin HELLO a tiempo"
## Cada cuántos ticks se comprueba el plazo del HELLO.
const HELLO_CHECK_TICKS: int = 10
## Ticks que se espera, tras [method stop], a que los peers se vayan antes de cerrar el transporte.
const STOP_DRAIN_TICKS: int = 30
## Secciones del tick que aparecen en la línea de métricas (las mismas que mide el bucle).
const LOGGED_SECTIONS: Array[StringName] = [&"net", &"sim", &"combat", &"combat_resolve",
		&"combat_events", &"history", &"snapshot", &"flush"]
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
## Ticks de enfriamiento tras una expulsión ([constant KICK_COOLDOWN_TICKS] por defecto; las pruebas
## lo cambian).
var kick_cooldown_ticks: int = KICK_COOLDOWN_TICKS
## Solo pruebas: si es válido, se le pasa [code](peer_id: int, address: String) -> String[/code] y
## devuelve la dirección con la que se trata al peer. Sirve para fingir que unos clientes de
## loopback vienen de una IP externa y así probar el tope de conexiones por IP, del que el loopback
## está exento.
var remote_address_override: Callable = Callable()
## Fichas de jugador y expulsiones que conserva el informe ([constant MAX_LOGGED_PLAYERS] y
## [constant MAX_LOGGED_KICKS] por defecto; las pruebas los acortan).
var max_logged_players: int = MAX_LOGGED_PLAYERS
var max_logged_kicks: int = MAX_LOGGED_KICKS

var _run_state: _RunState = _RunState.IDLE
var _config: ServerConfig
var _world: Node3D
var _transport: NetTransport
var _auth: ServerAuth
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
# net_id -> cerebro de cada PNJ (maniquíes).
var _npcs: Dictionary[int, BotBrain] = {}
var _combat: CombatDirector
var _safe_areas: SafeAreas
var _commands: CommandRegistry = CommandRegistry.new()
var _console: ServerConsole = null
var _combat_log: FileAccess = null
# Tick en el que se cumple la cuenta atrás de un cierre pedido por la consola (-1 = ninguna).
var _shutdown_tick: int = -1
var _shutdown_announced: Dictionary[int, bool] = {}
var _events_sent: int = 0
var _event_bytes_sent: int = 0
var _dummies_created: int = 0
# Caché de objetivos de los bots de combate: tick de la última vez, posiciones e ids por reino, y qué
# reinos son hostiles entre sí.
var _targets_tick: int = -1
var _targets_by_realm: Dictionary = {}
var _targets_ids_by_realm: Dictionary = {}
var _hostile_cache: Dictionary = {}
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
# Jugadores falsos que se van en el siguiente tick (remove_fake_player).
var _fake_leaving: Array[int] = []
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
## [br]- [param auth_provider] decide la identidad de los clientes ([DevAuthProvider] en la fase 2).
## Devuelve el error de [method NetTransport.host] si no se puede abrir el puerto.
func start(config: ServerConfig, world: Node3D, transport: NetTransport,
		auth_provider: AuthProvider) -> Error:
	if _run_state != _RunState.IDLE:
		return ERR_ALREADY_IN_USE
	if config == null or world == null or not is_inside_tree() or not world.is_inside_tree():
		return ERR_UNCONFIGURED
	_config = config
	_world = world
	_transport = transport
	_players_root = Node3D.new()
	_players_root.name = "Players"
	add_child(_players_root)
	_sim_hash = _compute_sim_hash()
	_auth = ServerAuth.new(config, _sim_hash, NetZones.allowed_realms(config.zone_id),
			auth_provider)
	_auth.set_connected_names_source(get_connected_names)
	_spawn_picker = SpawnPicker.new(world)
	_safe_areas = SafeAreas.from_world(world)
	_combat = CombatDirector.new(_history, StringName(config.zone_id), world, _safe_areas,
			Callable(self, "_place"), Callable(self, "_pick_spawn_point"))
	_combat.event_emitted.connect(_on_combat_event)
	_combat.metrics = _metrics
	_commands.audit_sink = Callable(self, "_log")
	_register_commands()
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
			_transport.send(peer_id, NetProtocol.CH_RELIABLE, bytes)
			_transport.disconnect_after_flush(peer_id)
			peer.state = ServerPeer.State.LEAVING
		_transport.flush()
	for record: _PlayerRecord in _player_by_net.values():
		record.close(_tick)
	_clear_players()
	_pending_ready.clear()
	_leaving.clear()
	_fake_leaving.clear()
	_sync_byte_counters()
	_close_state_log()
	_close_combat_log()
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


## Jugadores que cuentan para el cupo: los peers aceptados (cargando la zona o ya dentro) más los
## jugadores falsos. Los que se están autenticando o se van no cuentan.
func get_player_count() -> int:
	var count: int = _fakes.size()
	for peer: ServerPeer in _peers.values():
		if peer.state == ServerPeer.State.LOADING or peer.state == ServerPeer.State.IN_WORLD:
			count += 1
	return count


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


## Huella de la simulación ([method NetProtocol.compute_sim_hash]) que el servidor exige a los
## clientes en el HELLO.
func get_sim_hash() -> int:
	return _sim_hash


## Crea un jugador sin red de [param realm] (un código de [enum NetProtocol.Realm]): en cada tick,
## antes de simular, su entrada sale de [code]brain.next_input()[/code], cuantizada y con el tick
## correspondiente, y entra directamente en su [InputQueue]. Devuelve su [code]net_id[/code], o -1
## si el servidor no está en marcha, está lleno ([member ServerConfig.max_players]) o no quedan ids.
## Se puede llamar entre dos ticks; el jugador aparece con el estado «tras el último tick» y su
## primera simulación es la del siguiente.
func add_fake_player(brain: BotBrain, realm: int) -> int:
	if _run_state != _RunState.RUNNING or brain == null:
		return -1
	if get_player_count() >= _config.max_players:
		return -1
	_fake_counter += 1
	var entity: NetEntity = _create_player("Bot-%02d" % _fake_counter, realm, 0, _tick)
	if entity == null:
		return -1
	_fakes[entity.net_id] = brain
	if brain.get_pattern() == BotBrain.Pattern.COMBAT and not brain.has_enemy_finder():
		brain.set_enemy_finder(_find_enemy_position.bind(entity.net_id))
	var record: _PlayerRecord = _player_by_net[entity.net_id]
	record.is_fake = true
	_announce_arrival(entity, null, _tick)
	_log("Alta de %s (jugador falso, net_id %d, %s); jugadores: %d" % [entity.display_name,
			entity.net_id, NetProtocol.realm_display_name(realm), get_player_count()])
	return entity.net_id


## Da de baja al jugador falso [param net_id] al empezar el siguiente tick: DESPAWN (motivo 1) a quien
## lo veía y el id en cuarentena, como si se hubiera desconectado. Devuelve false si no es un jugador
## falso (o ya se va). Sirve para las altas y bajas de las pruebas de carga.
func remove_fake_player(net_id: int) -> bool:
	if _run_state != _RunState.RUNNING or not _fakes.has(net_id) or _fake_leaving.has(net_id):
		return false
	_fake_leaving.append(net_id)
	return true


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
## quedan ids.
func add_npc(brain: BotBrain, display_name: String, realm: int, position: Vector3, yaw: float,
		immortal: bool = false) -> int:
	if _run_state != _RunState.RUNNING or brain == null:
		return -1
	var entity: NetEntity = _create_body(NetProtocol.EntityKind.NPC, display_name, realm, 0, _tick,
			position, yaw)
	if entity == null:
		return -1
	_npcs[entity.net_id] = brain
	_combat.get_combatant(entity.net_id).immortal = immortal
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
	_metrics.end_section(&"net")

	_tick += 1
	var s: int = _tick

	_check_loading_timeouts(s)
	_check_hello_timeouts(s)
	_process_departures(s)

	_metrics.begin_section(&"sim")
	_simulate_players(s, delta)
	_metrics.end_section(&"sim")

	_metrics.begin_section(&"combat")
	_combat.process_tick(s, _players_root.get_world_3d().direct_space_state)
	_metrics.end_section(&"combat")
	_check_shutdown_countdown(s)

	_process_arrivals(s)

	_metrics.begin_section(&"history")
	_record_history(s)
	_metrics.end_section(&"history")

	_metrics.begin_section(&"snapshot")
	_send_snapshots(s)
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
		if brain == null:
			brain = _npcs.get(entity.net_id)
		if brain != null:
			var generated: PlayerInput = brain.next_input(s, before, character.yaw)
			generated.tick = s
			queue.push(generated.quantized(), 0, s)
		var substitutions_before: int = queue.substitutions_total
		var input: PlayerInput = queue.take(s)
		var was_substituted: bool = queue.substitutions_total != substitutions_before
		if brain == null:
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
		peer.entity = entity
		peer.input_queue = _queues[entity.net_id]
		peer.state = ServerPeer.State.IN_WORLD
		var record: _PlayerRecord = _player_by_net[entity.net_id]
		record.peer = peer
		_world_peers.append(peer)
		_announce_arrival(entity, peer, s)
		player_joined.emit(peer_id, entity.net_id)
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
func _announce_arrival(entity: NetEntity, peer: ServerPeer, s: int) -> void:
	var own_spawn: PackedByteArray = entity.encode_spawn(s, true)
	var spawn: PackedByteArray = entity.encode_spawn(s, false)
	if peer != null:
		_send(peer, NetProtocol.CH_RELIABLE, own_spawn)
	for other: NetEntity in _registry.get_sorted():
		if other == entity:
			continue
		if peer != null and _is_relevant(entity, other, false):
			peer.relevant[other.net_id] = true
			_send(peer, NetProtocol.CH_RELIABLE, other.encode_spawn(s, false))
		var other_peer: ServerPeer = _peers.get(other.owner_peer)
		if other_peer != null and other_peer.state == ServerPeer.State.IN_WORLD \
				and _is_relevant(other, entity, false):
			other_peer.relevant[entity.net_id] = true
			_send(other_peer, NetProtocol.CH_RELIABLE, spawn)


# Cierra la sesión de los peers que se van: DESPAWN (motivo 1) a quien los tenía por relevantes, id
# en cuarentena, personaje liberado y pista del historial borrada.
func _process_departures(s: int) -> void:
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
		if peer.entity == null:
			continue
		var entity: NetEntity = peer.entity
		_remove_player(entity, s, NetProtocol.DespawnReason.DISCONNECTED)
		_world_peers.erase(peer)
		_left_total += 1
		player_left.emit(peer_id, entity.net_id)
		_log("Baja de %s (peer %d, net_id %d); jugadores: %d" % [entity.display_name, peer_id,
				entity.net_id, get_player_count()])


# Bajas de los jugadores falsos pedidas con remove_fake_player().
func _process_fake_departures(s: int) -> void:
	if _fake_leaving.is_empty():
		return
	var leaving: Array[int] = _fake_leaving.duplicate()
	_fake_leaving.clear()
	for net_id: int in leaving:
		var entity: NetEntity = _registry.get_entity(net_id)
		if entity == null or not _fakes.has(net_id):
			continue
		_remove_player(entity, s, NetProtocol.DespawnReason.DISCONNECTED)
		_left_total += 1
		_log("Baja de %s (jugador falso, net_id %d); jugadores: %d" % [entity.display_name, net_id,
				get_player_count()])


# Quita al jugador del mundo: DESPAWN a quien lo veía, id en cuarentena y personaje liberado.
func _remove_player(entity: NetEntity, s: int, reason: int) -> void:
	var net_id: int = entity.net_id
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
	_queues.erase(net_id)
	_fakes.erase(net_id)
	_npcs.erase(net_id)
	_combat.remove(net_id)
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
	if _combat != null:
		_combat.clear()
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
		var character: PlayerCharacter = entity.get_character()
		var position: Vector3 = entity.get_position()
		var yaw: float = 0.0
		var flags: int = (entity.teleport_counter & EntityRecord.TELEPORT_MASK) \
				<< EntityRecord.TELEPORT_SHIFT
		if character != null:
			yaw = character.yaw
			if character.grounded:
				flags |= EntityRecord.FLAG_GROUNDED
			# Banderas defensivas (bloqueo, parada, invulnerable, muerto) para el rebobinado.
			flags |= ActionMachine.defense_flags(character.combat, s)
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
			_send(peer, NetProtocol.CH_RELIABLE, entity.encode_spawn(s, false))
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


# --- Combate: eventos, enemigos, suelo ----------------------------------------------------------

# Un evento de combate: ENTITY_EVENT (canal fiable) a los dueños de las entidades implicadas
# (víctima, atacante, asesino y asistentes) y a quien tenga relevante a cualquiera de ellas.
func _on_combat_event(event: NetMessages.EntityEvent, involved: PackedInt32Array) -> void:
	if _transport == null or _world_peers.is_empty():
		return
	_metrics.begin_section(SECTION_COMBAT_EVENTS)
	var bytes: PackedByteArray = event.encode()
	for peer: ServerPeer in _world_peers:
		var receives: bool = involved.has(peer.entity.net_id)
		if not receives:
			for net_id: int in involved:
				if peer.relevant.get(net_id, false):
					receives = true
					break
		if receives:
			_transport.send(peer.peer_id, NetProtocol.CH_RELIABLE, bytes)
			_events_sent += 1
			_event_bytes_sent += bytes.size()
	_metrics.end_section(SECTION_COMBAT_EVENTS)


# Un punto de aparición del reino (para colocar a quien cae fuera del mundo mientras está muerto).
func _pick_spawn_point(realm: int) -> Transform3D:
	return _spawn_picker.pick(realm)


# Posición del enemigo vivo más cercano a [param position] para el jugador falso [param net_id] (el
# cerebro de combate de BotBrain), o null si no hay ninguno que pueda atacar o ser atacado: los
# maniquíes, los protegidos y los que están en la zona segura de su reino no cuentan, y quien está en
# la zona segura de su reino no ataca. Las posiciones objetivo se reúnen una vez por tick y por reino
# (con muchos bots, cada uno recorre solo los candidatos de los reinos que le son hostiles).
func _find_enemy_position(position: Vector3, net_id: int) -> Variant:
	var me: Combatant = _combat.get_combatant(net_id)
	if me == null or me.is_dead() or _safe_areas.contains_own(me.get_realm(), position):
		return null
	if _targets_tick != _tick:
		_rebuild_target_cache()
	var best: Variant = null
	var best_distance: float = INF
	for realm: int in _targets_by_realm:
		if not _is_hostile_realm(me.get_realm(), realm):
			continue
		var positions: PackedVector3Array = _targets_by_realm[realm]
		for index: int in positions.size():
			if _targets_ids_by_realm[realm][index] == net_id:
				continue
			var distance: float = position.distance_squared_to(positions[index])
			if distance < best_distance:
				best_distance = distance
				best = positions[index]
	return best


# Reúne, por reino, las posiciones de quien puede ser objetivo de un bot de combate en este tick.
func _rebuild_target_cache() -> void:
	_targets_tick = _tick
	_targets_by_realm.clear()
	_targets_ids_by_realm.clear()
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
		_targets_by_realm[realm].append(other_position)
		_targets_ids_by_realm[realm].append(other.get_id())


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
	if combatant == null or combatant.is_dead():
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
	if not _combat.set_weapon(combatant, weapon_id):
		ctx.note = "arma %d inexistente" % weapon_id
		return CommandRegistry.Result.BAD_ARGUMENTS
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


# -- Comandos de consola --

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
	if not _combat.set_weapon(combatant, weapon_id):
		return "No existe el arma «%s»" % ctx.args[1]
	return "%s lleva ahora %s" % [combatant.entity.display_name, ctx.args[1]]


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


# HELLO: se valida y se contesta WELCOME (y complete_auth) o REJECT (y corte ordenado).
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
		if _is_cooling_down(_cooldown_key_for_name(peer.remote_address, hello.display_name)):
			_reject(peer, NetProtocol.Result.TOO_MANY_CONNECTIONS)
			return
		result = _auth.validate(hello, peer.remote_address, get_player_count(),
				_connections_from(peer))
	if result != NetProtocol.Result.OK:
		_reject(peer, result)
		return
	peer.state = ServerPeer.State.LOADING
	peer.realm = hello.realm
	peer.display_name = hello.display_name
	peer.loading_since_tick = _tick
	var welcome := NetMessages.Welcome.new()
	welcome.server_tick = _tick
	welcome.tick_rate = Engine.physics_ticks_per_second
	welcome.realm = hello.realm
	welcome.zone_id = _config.zone_id
	var error: Error = _transport.send_auth(peer_id, welcome.encode())
	if error == OK:
		error = _transport.complete_auth(peer_id)
	if error != OK:
		_mark_leaving(peer)


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
	if peer.state == ServerPeer.State.AUTHENTICATING:
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
		_:
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
			_add_strike(peer, "comando de depuración desconocido (%d)" % command.command)
		CommandRegistry.Result.BAD_ARGUMENTS:
			_add_strike(peer, "comando de depuración con argumentos no válidos (%d)"
					% command.command)


# RESPAWN_REQUEST: un muerto pide reaparecer en el punto point_index de la lista de su reino. Fuera de
# plazo (vivo, o mucho antes de poder) es un aviso; un índice que ya no vale no lo es: el estado del
# cliente va atrasado y se usa el primer punto del reino.
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


# Suma un aviso y expulsa al peer si llega al límite (50 en 600 ticks).
func _add_strike(peer: ServerPeer, reason: String) -> void:
	_strikes_total += 1
	_strike_reasons[reason] = _strike_reasons.get(reason, 0) + 1
	if peer.add_strike(_tick, reason):
		_kick(peer, reason)


# NOTICE de expulsión y corte ordenado. El motivo queda en el informe. Con [param cooldown], su IP (o,
# desde loopback, su nombre) no puede volver a entrar durante kick_cooldown_ticks.
func _kick(peer: ServerPeer, reason: String, cooldown: bool = true) -> void:
	if peer.state == ServerPeer.State.LEAVING:
		return
	if cooldown:
		_start_cooldown(peer)
	var notice := NetMessages.Notice.new()
	notice.code = NetProtocol.NoticeCode.KICK
	notice.text = "Expulsado del servidor: %s" % reason
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
# desde loopback, donde no hay tope por IP y se usa el nombre normalizado, si ya lo había dado.
func _start_cooldown(peer: ServerPeer) -> void:
	var key: String = _cooldown_key_for_address(peer.remote_address)
	if key.is_empty():
		key = _cooldown_key_for_name(peer.remote_address, peer.display_name)
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


# Clave de enfriamiento por nombre: solo desde loopback, que no tiene tope por IP.
func _cooldown_key_for_name(address: String, display_name: String) -> String:
	if display_name.is_empty() or not ServerAuth.is_loopback(address):
		return ""
	return "name:" + NameRules.normalize_key(display_name)


func _is_cooling_down(key: String) -> bool:
	return not key.is_empty() and _kick_until.get(key, 0) > _tick


func _mark_leaving(peer: ServerPeer) -> void:
	if peer.state == ServerPeer.State.LEAVING:
		return
	peer.state = ServerPeer.State.LEAVING
	_leaving.append(peer.peer_id)


# REJECT y corte ordenado: lo encolado sale antes de cortar.
func _reject(peer: ServerPeer, result: int) -> void:
	var reject := NetMessages.Reject.new()
	reject.result = result
	reject.text = NetProtocol.result_text(result)
	_transport.send_auth(peer.peer_id, reject.encode())
	_transport.disconnect_after_flush(peer.peer_id)
	var key: String = NetProtocol.result_text(result)
	_rejects[key] = _rejects.get(key, 0) + 1
	_log("Conexión rechazada de %s (peer %d): %s" % [peer.remote_address, peer.peer_id,
			reject.text])
	_mark_leaving(peer)


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
	_close_state_log()
	_metrics.unregister_monitors()
	_disconnect_transport()


# Línea de métricas cada 10 s: duración del tick, jugadores, entradas sustituidas y ancho de banda.
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
			+ "bajada %.1f KB/s" % kb_in)


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
	report["events_sent"] = _events_sent
	report["event_bytes_sent"] = _event_bytes_sent
	report["dummies"] = get_dummy_count() if _combat != null else 0
	report["dummies_created"] = _dummies_created
	report["suspicious"] = suspicious
	return report


func _count_fakes_in_log() -> int:
	var count: int = _archived_fakes
	for record: _PlayerRecord in _player_log:
		if record.is_fake:
			count += 1
	return count


func _log(text: String) -> void:
	if log_enabled:
		print("[Eldmark] %s" % text)
