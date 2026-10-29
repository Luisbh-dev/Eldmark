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
## poll             recibir: autenticación, READY, LEAVE, INPUT_BATCH -> InputQueue.push()
## tick += 1        s es el tick que se simula
## bajas            desconexión, LEAVE o expulsión -> DESPAWN (motivo 1) y el id en cuarentena
## simular          por net_id ascendente, con la entrada de InputQueue.take(s); _check_motion
## altas            los READY pendientes: el jugador aparece con el estado «tras s»
## historial        StateHistory.record() de todas las entidades
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

## Se emite al terminar cada tick, ya enviado todo lo del tick.
signal tick_finished(tick: int)
## Un jugador (de red) ha entrado en el mundo.
signal player_joined(peer_id: int, net_id: int)
## Un jugador (de red) ha salido del mundo.
signal player_left(peer_id: int, net_id: int)

## Escena del personaje. En el servidor se le libera el nodo [code]Visual[/code].
const PLAYER_SCENE: PackedScene = preload("res://scenes/characters/player_character.tscn")
## Distancia máxima que puede recorrer un personaje en un tick (la velocidad terminal da 0,83 m).
const MAX_STEP_DISTANCE: float = 1.5
## Por debajo de esta altura el personaje reaparece en su punto de aparición.
const FALL_LIMIT_Y: float = -100.0
## Cada cuántos ticks se recalcula el interés de cada peer (escalonado por net_id).
const INTEREST_INTERVAL_TICKS: int = 6
## Ticks que un peer puede estar cargando la zona sin enviar CLIENT_READY (60 s).
const LOADING_TIMEOUT_TICKS: int = 3600
## Cada cuántos ticks se escribe la línea de métricas en el registro (10 s).
const METRICS_LOG_TICKS: int = 600
## Ticks que se espera, tras [method stop], a que los peers se vayan antes de cerrar el transporte.
const STOP_DRAIN_TICKS: int = 30
## Avisos de error de física que se escriben en el registro (el resto solo se cuenta).
const MAX_LOGGED_PHYSICS_ERRORS: int = 10
## Coordenada máxima (en valor absoluto) que admite un teletransporte de depuración.
const MAX_TELEPORT_COORDINATE: float = 5000.0
## Texto del NOTICE de cierre por defecto.
const DEFAULT_SHUTDOWN_TEXT: String = "El servidor se está cerrando"
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
# peer_id -> medida del RTT en ticks.
var _rtt: Dictionary[int, _RttWindow] = {}
# Peers con CLIENT_READY recibido, en orden de llegada.
var _pending_ready: Array[int] = []
# Peers que se van (bajas del tick siguiente).
var _leaving: Array[int] = []
# net_id -> ficha del jugador vivo; _player_log guarda todas, también las de los que se han ido.
var _player_by_net: Dictionary[int, _PlayerRecord] = {}
var _player_log: Array[_PlayerRecord] = []
var _fake_counter: int = 0
var _peak_players: int = 0
var _joined_total: int = 0
var _left_total: int = 0
var _strikes_total: int = 0
var _strike_reasons: Dictionary[String, int] = {}
var _kicks: Array[Dictionary] = []
var _rejects: Dictionary[String, int] = {}
var _physics_errors: int = 0
var _teleports: int = 0
var _respawns: int = 0
var _synced_wire_in: int = 0
var _synced_wire_out: int = 0
var _log_last_usec: int = 0
var _log_last_wire_out: int = 0
var _log_last_wire_in: int = 0
var _state_log: FileAccess = null
# net_id -> 1 si la entrada del tick se sustituyó (solo se rellena con --state-log).
var _substituted_now: Dictionary[int, int] = {}


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
	var kicked: bool = false
	var kick_reason: String = ""
	var queue: InputQueue = null
	var peer: ServerPeer = null


	# Copia los contadores vivos de la cola y del peer.
	func refresh() -> void:
		if queue != null:
			substituted = queue.substitutions_total
			late = queue.late_count
			too_early = queue.too_early_count
		if peer != null:
			strikes = peer.strikes_total


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
			"kicked": kicked,
			"kick_reason": kick_reason,
		}


## Mínimo del RTT en ticks de los últimos 90-120 ticks, en cuatro huecos de 30 ticks.
class _RttWindow:
	var _ids: PackedInt32Array = PackedInt32Array()
	var _mins: PackedInt32Array = PackedInt32Array()


	func _init() -> void:
		_ids.resize(_RTT_BUCKETS)
		_ids.fill(-1)
		_mins.resize(_RTT_BUCKETS)
		_mins.fill(_INT_MAX)


	func add(now_tick: int, sample: int) -> void:
		var bucket_id: int = now_tick / _RTT_BUCKET_TICKS
		var slot: int = bucket_id % _RTT_BUCKETS
		if _ids[slot] != bucket_id:
			_ids[slot] = bucket_id
			_mins[slot] = _INT_MAX
		_mins[slot] = mini(_mins[slot], sample)


	# Mínimo de la ventana, o -1 si no hay muestras en ella.
	func get_min(now_tick: int) -> int:
		var current: int = now_tick / _RTT_BUCKET_TICKS
		var best: int = _INT_MAX
		for slot: int in _RTT_BUCKETS:
			if _ids[slot] > current - _RTT_BUCKETS and _ids[slot] <= current:
				best = mini(best, _mins[slot])
		return best if best != _INT_MAX else -1


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
	_spawn_picker = SpawnPicker.new(world)
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
	_metrics.register_monitors()
	_log_last_usec = Time.get_ticks_usec()
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
		record.refresh()
		record.left_tick = _tick
	_clear_players()
	_pending_ready.clear()
	_leaving.clear()
	_sync_byte_counters()
	_close_state_log()
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


func get_registry() -> NetEntityRegistry:
	return _registry


func get_history() -> StateHistory:
	return _history


func get_metrics() -> ServerMetrics:
	return _metrics


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
	var record: _PlayerRecord = _player_by_net[entity.net_id]
	record.is_fake = true
	_announce_arrival(entity, null, _tick)
	_log("Alta de %s (jugador falso, net_id %d, %s); jugadores: %d" % [entity.display_name,
			entity.net_id, NetProtocol.realm_display_name(realm), get_player_count()])
	return entity.net_id


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


## Escribe el informe JSON de la ejecución en [param path] (los directorios que falten se crean).
## Claves:
## [codeblock]
## version, zone, port, ticks, tick_rate, sim_hash
## players   {current, fake, peak, joined_total, left_total}
## inputs    {consumed, substituted, late, too_early, substituted_percent}  (solo jugadores de red)
## bytes     {wire_in, wire_out, app_in, app_out}  (acumulados; ver NetTransport.get_byte_counters)
## strikes   {total, by_reason}      kicks [{tick, peer_id, net_id, name, reason}]
## rejects   {motivo: veces}
## physics_errors, teleports, respawns
## metrics   ServerMetrics.summary() (p50/p99/máx de cada sección en µs, KB/s, jugadores...)
## player_list  una ficha por jugador que ha pasado por el servidor (también los que se fueron)
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
		_transport.poll(_tick)
	_metrics.end_section(&"net")

	_tick += 1
	var s: int = _tick

	_check_loading_timeouts(s)
	_process_departures(s)

	_metrics.begin_section(&"sim")
	_simulate_players(s, delta)
	_metrics.end_section(&"sim")

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


# Simula a todos los jugadores por net_id ascendente con la entrada de take(s).
func _simulate_players(s: int, delta: float) -> void:
	var inputs_consumed: int = 0
	var inputs_substituted: int = 0
	var logging_states: bool = _state_log != null
	for entity: NetEntity in _registry.get_sorted():
		if entity.kind != NetProtocol.EntityKind.PLAYER:
			continue
		var character: PlayerCharacter = entity.get_character()
		var queue: InputQueue = _queues.get(entity.net_id)
		if character == null or queue == null:
			continue
		var before: Vector3 = character.global_position
		var brain: BotBrain = _fakes.get(entity.net_id)
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
		character.simulate(input, delta)
		_check_motion(entity, before)
	if inputs_consumed > 0:
		_metrics.add_counter(ServerMetrics.COUNTER_INPUTS, inputs_consumed)
		_metrics.add_counter(ServerMetrics.COUNTER_SUBSTITUTIONS, inputs_substituted)


# El servidor no acepta estado del cliente, así que estas comprobaciones solo detectan errores
# propios: un salto de más de 1,5 m en un tick se anota como error de física, y caer por debajo
# de FALL_LIMIT_Y devuelve al jugador a su punto de aparición.
func _check_motion(entity: NetEntity, before: Vector3) -> void:
	var character: PlayerCharacter = entity.get_character()
	var after: Vector3 = character.global_position
	if not after.is_finite() or after.distance_to(before) > MAX_STEP_DISTANCE:
		_physics_errors += 1
		if _physics_errors <= MAX_LOGGED_PHYSICS_ERRORS:
			push_warning("[Eldmark] Error de física: %s se movió %.2f m en un tick (de %s a %s)"
					% [entity.display_name, after.distance_to(before), before, after])
	if not after.is_finite() or after.y < FALL_LIMIT_Y:
		var spawn: Transform3D = _spawn_picker.pick(entity.realm)
		_place(entity, spawn.origin, _yaw_of(spawn))
		_respawns += 1
		_log("%s cayó fuera del mundo (y = %.1f) y reaparece en %s" % [entity.display_name,
				after.y if after.is_finite() else 0.0, spawn.origin])


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
			_kick(peer, "no queda sitio en la zona")
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


# Crea la entidad y el personaje de un jugador en un punto de aparición de su reino. El estado es
# «el estado tras s», redondeado por encode/decode; su cola de entradas empieza con el tick s ya
# consumido y la entrada neutra como última aplicada; y se le abre la pista del historial.
func _create_player(display_name: String, realm: int, owner_peer: int, s: int) -> NetEntity:
	var entity: NetEntity = _registry.allocate(NetProtocol.EntityKind.PLAYER, s)
	if entity == null:
		return null
	entity.realm = realm
	entity.owner_peer = owner_peer
	entity.display_name = display_name

	var character: PlayerCharacter = _instantiate_character()
	character.name = "Player%d" % entity.net_id
	_players_root.add_child(character)
	var spawn: Transform3D = _spawn_picker.pick(realm)
	var state := PlayerState.new()
	state.position = spawn.origin
	state.yaw = PlayerState.to_f32(_yaw_of(spawn))
	state.grounded = _probe_grounded(spawn.origin)
	state.last_input_tick = s
	state = PlayerState.decode(state.encode())
	character.set_state(state)
	entity.node = character

	var queue := InputQueue.new()
	queue.reset(s, NetProtocol.neutral_input(s, state.yaw))
	_queues[entity.net_id] = queue
	_history.add_entity(entity.net_id)

	var record := _PlayerRecord.new()
	record.net_id = entity.net_id
	record.peer_id = owner_peer
	record.display_name = display_name
	record.realm = realm
	record.joined_tick = s
	record.queue = queue
	_player_by_net[entity.net_id] = record
	_player_log.append(record)
	_joined_total += 1
	_metrics.add_counter(ServerMetrics.COUNTER_PLAYERS, 1)
	_peak_players = maxi(_peak_players, _metrics.get_counter(ServerMetrics.COUNTER_PLAYERS))
	return entity


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
		record.refresh()
		record.left_tick = s
		_player_by_net.erase(net_id)
	_queues.erase(net_id)
	_fakes.erase(net_id)
	_history.forget(net_id)
	_substituted_now.erase(net_id)
	var character: PlayerCharacter = entity.get_character()
	if character != null:
		if character.get_parent() != null:
			character.get_parent().remove_child(character)
		character.queue_free()
	entity.node = null
	_registry.release(net_id, s)
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
				and s - peer.loading_since_tick >= LOADING_TIMEOUT_TICKS:
			_kick(peer, "se agotó el tiempo de carga de la zona")


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
		else:
			flags |= EntityRecord.FLAG_GROUNDED
			if is_instance_valid(entity.node):
				yaw = entity.node.rotation.y
		_history.record(s, entity.net_id, position, yaw, flags)
		if _state_log != null and character != null:
			_state_log.store_line("%d,%d,%d,%s" % [s, entity.net_id,
					_substituted_now.get(entity.net_id, 0),
					character.get_state().encode().hex_encode()])
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
	_snapshot_builder.begin(s, entities)
	for peer: ServerPeer in receivers:
		_transport.send(peer.peer_id, NetProtocol.CH_SNAPSHOT, _snapshot_builder.build_for(peer))


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


# --- Transporte -------------------------------------------------------------------------------

func _connect_transport() -> void:
	_transport.peer_authenticating.connect(_on_peer_authenticating)
	_transport.auth_received.connect(_on_auth_received)
	_transport.peer_connected.connect(_on_peer_connected)
	_transport.peer_disconnected.connect(_on_peer_disconnected)
	_transport.packet_received.connect(_on_packet_received)


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


# Un cliente ha conectado y empieza a autenticarse: se espera su HELLO.
func _on_peer_authenticating(peer_id: int) -> void:
	if _run_state != _RunState.RUNNING:
		return
	var peer := ServerPeer.new(peer_id)
	peer.remote_address = _transport.get_remote_address(peer_id)
	_peers[peer_id] = peer


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
	peer.interp_delay_q = batch.interp_delay_q
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
		peer.rtt_ticks = maxi(window.get_min(next_tick), 0)
	for i: int in batch.inputs.size():
		peer.input_queue.push(batch.inputs[i], batch.view_offsets_q[i], _tick + 1)


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
	if command.command != NetProtocol.DEBUG_TELEPORT:
		_add_strike(peer, "comando de depuración desconocido (%d)" % command.command)
		return
	var target: Vector3 = command.get_teleport_position()
	if not target.is_finite() or absf(target.x) > MAX_TELEPORT_COORDINATE \
			or absf(target.y) > MAX_TELEPORT_COORDINATE \
			or absf(target.z) > MAX_TELEPORT_COORDINATE:
		_add_strike(peer, "teletransporte fuera de rango")
		return
	teleport(peer.entity.net_id, target)


# Suma un aviso y expulsa al peer si llega al límite (50 en 600 ticks).
func _add_strike(peer: ServerPeer, reason: String) -> void:
	_strikes_total += 1
	_strike_reasons[reason] = _strike_reasons.get(reason, 0) + 1
	if peer.add_strike(_tick, reason):
		_kick(peer, reason)


# NOTICE de expulsión y corte ordenado. El motivo queda en el informe.
func _kick(peer: ServerPeer, reason: String) -> void:
	if peer.state == ServerPeer.State.LEAVING:
		return
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
	var record: _PlayerRecord = _player_by_net.get(net_id)
	if record != null:
		record.kicked = true
		record.kick_reason = reason
	_log("Expulsión de %s (peer %d): %s" % [peer.display_name, peer.peer_id, reason])
	_mark_leaving(peer)


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


# Conexiones abiertas desde la misma IP que [param peer], sin contarlo a él.
func _connections_from(peer: ServerPeer) -> int:
	if peer.remote_address.is_empty():
		return 0
	var count: int = 0
	for other: ServerPeer in _peers.values():
		if other != peer and other.state != ServerPeer.State.LEAVING \
				and other.remote_address == peer.remote_address:
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
	_log("Métricas (tick %d): %d jugadores, tick p50 %d µs / p99 %d µs / máx %d µs, "
			% [s, _metrics.get_counter(ServerMetrics.COUNTER_PLAYERS),
			_metrics.get_percentile_us(ServerMetrics.SECTION_TICK, 0.5),
			_metrics.get_percentile_us(ServerMetrics.SECTION_TICK, 0.99),
			_metrics.get_max_us(ServerMetrics.SECTION_TICK)]
			+ "entradas sustituidas %.2f %%, subida %.1f KB/s, bajada %.1f KB/s"
			% [_metrics.get_substituted_percent(), kb_out, kb_in])


func _build_report() -> Dictionary:
	_sync_byte_counters()
	var network_bytes: Dictionary = {}
	if _transport != null and is_instance_valid(_transport):
		network_bytes = _transport.get_byte_counters()
	var player_list: Array[Dictionary] = []
	var inputs: int = 0
	var substituted: int = 0
	var late: int = 0
	var too_early: int = 0
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
		"players": {
			"current": get_player_count(),
			"fake": _count_fakes_in_log(),
			"peak": _peak_players,
			"joined_total": _joined_total,
			"left_total": _left_total,
		},
		"inputs": {
			"consumed": inputs,
			"substituted": substituted,
			"late": late,
			"too_early": too_early,
			"substituted_percent": substituted_percent,
		},
		"bytes": network_bytes,
		"strikes": {"total": _strikes_total, "by_reason": _strike_reasons},
		"kicks": _kicks,
		"rejects": _rejects,
		"physics_errors": _physics_errors,
		"teleports": _teleports,
		"respawns": _respawns,
		"metrics": _metrics.summary(),
		"player_list": player_list,
	}


func _count_fakes_in_log() -> int:
	var count: int = 0
	for record: _PlayerRecord in _player_log:
		if record.is_fake:
			count += 1
	return count


func _log(text: String) -> void:
	if log_enabled:
		print("[Eldmark] %s" % text)
