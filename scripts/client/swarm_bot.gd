class_name SwarmBot
extends Node
## Bot ligero del enjambre de carga (docs/red.md, secciones 14, 15 y 17.5; TEC-11).
## [br][br]
## No simula ni carga la zona: no tiene [PlayerCharacter] propio, ni [ClientPrediction], ni
## [RemoteWorld]. Es lo mínimo para que el servidor lo trate como a un cliente de verdad y para medir
## lo que le cuesta:
## [codeblock]
## HELLO -> WELCOME -> CLIENT_READY en cuanto conecta (no hay zona que cargar) -> SPAWN propio
## cada tick: poll, pasos de TickSync -> entradas de BotBrain (guiado por la posición del estado
##            propio del último snapshot) -> INPUT_BATCH con ack_snapshot_tick -> flush
## cada SNAPSHOT: se lee solo la cabecera (el tick, el ack, el margen, las sustituciones y el estado
##            propio) y se cuentan sus registros; alimenta a TickSync y a InterpolationClock
## [/codeblock]
## [TickSync] e [InterpolationClock] son los de verdad, así que el bot se adelanta al servidor lo
## justo y sus entradas llegan a tiempo, como las de un cliente; lo único que cambia es que la
## posición con la que el [BotBrain] decide es la del snapshot (con el retraso de la red), no la de
## una simulación local. Cada bot tiene su propio [NetTransport] (y por tanto su propio
## [SceneMultiplayer], registrado por la ruta de su nodo).
## [br][br]
## [b]Cerebro de combate[/b] ([code]--bot-brain=combat[/code], [member ClientConfig.bot_brain]): el bot
## pelea con [constant BotBrain.Pattern.COMBAT] como un jugador de verdad, sin simular nada. Sabe quién
## es enemigo por los ENTITY_SPAWN (reino y tipo; solo jugadores a los que el servidor dejaría dañar) y
## dónde está por los snapshots, de los que solo decodifica una fracción de los registros en cada uno
## ([constant ENEMY_SCAN_STRIDE]): con 128 bots, decodificarlos todos costaría más que el servidor, y a
## un bot le basta con posiciones de hace unas décimas de segundo. Cada entrada lleva el
## [code]view_offset_q[/code] que mandaría un cliente (su tick menos el de dibujo), así que el servidor
## hace el rebobinado de verdad, y al morir pide reaparecer en cuanto puede (RESPAWN_REQUEST).
## [br][br]
## [b]Estadísticas[/b] ([method get_stats]): bytes de subida y de bajada de ENet desde que apareció
## (con las cabeceras de ENet, sin las de UDP/IP), snapshots recibidos y su tamaño medio, registros por
## snapshot, y lo que [BotSwarm] vuelca en su informe.

## Fase de la sesión.
enum State {
	IDLE,
	CONNECTING,
	HELLO_SENT,
	WELCOMED,
	READY_SENT,
	IN_WORLD,
	LEAVING,
	CLOSED,
}

const PLAYER_SCENE_PATH: String = "res://scenes/characters/player_character.tscn"
## Id con el que el bot ve al servidor.
const SERVER_PEER_ID: int = 1
## Tiempo de espera de ENet al conectar (ms).
const CONNECT_TIMEOUT_MS: int = 3000
## Radio (m) por el que pasea cada bot alrededor de su punto de aparición.
const BOT_RADIUS: float = 30.0
## Reinos que se reparten los bots cuando la configuración no fija ninguno (los de las zonas con
## campamentos: el Vado Gris).
const DEFAULT_REALMS: Array[int] = [NetProtocol.Realm.VARDHEIM, NetProtocol.Realm.SOLMARCH]
## Entradas recientes que se guardan para la redundancia (más que NetProtocol.INPUT_REDUNDANCY_LOSSY).
const INPUT_RING_SIZE: int = 16
## Ticks, tras una subida de las sustituciones del servidor, en los que se envía con R = 8.
const LOSSY_WINDOW_TICKS: int = 120
## Escala del retardo de interpolación en el INPUT_BATCH (× 8) y del desfase de vista (× 16).
const INTERP_DELAY_SCALE: float = 8.0
const VIEW_OFFSET_SCALE: float = 16.0
## Cerebro de combate: de cada snapshot solo se decodifica uno de cada tantos registros (rotando).
const ENEMY_SCAN_STRIDE: int = 6
## Cerebro de combate: ticks mínimos entre dos peticiones de reaparición.
const RESPAWN_RETRY_TICKS: int = 30
const TEXT_CONNECT_FAILED: String = "No se pudo conectar con el servidor %s:%d"
const TEXT_CONNECTION_LOST: String = "Se perdió la conexión con el servidor"
const TEXT_LEFT: String = "Ha salido de la zona"
const TEXT_BAD_REPLY: String = "Respuesta del servidor no válida"

## Huella de la simulación que se calcula una sola vez por proceso (es la misma para todos los bots).
static var _cached_sim_hash: int = -1

var _index: int = 0
var _config: ClientConfig = null
var _transport: NetTransport = null
var _state: State = State.IDLE
var _display_name: String = ""
var _realm: int = NetProtocol.Realm.NONE
var _tick_sync: TickSync = TickSync.new()
var _interp_clock: InterpolationClock = InterpolationClock.new()
var _brain: BotBrain = null
var _combat: bool = false
var _local_tick: int = 0
var _hello_tick: int = 0
var _ready_tick: int = 0
var _rtt_hello_ticks: int = 0
var _rtt_ticks: int = 0
var _net_id: int = 0
var _spawn_tick: int = 0
var _first_real_tick: int = 0
var _predicted_tick: int = 0
var _joined_local_tick: int = -1
var _position: Vector3 = Vector3.ZERO
var _yaw: float = 0.0
var _inputs: Array[PlayerInput] = []
var _view_offsets: PackedInt32Array = PackedInt32Array()
var _newest_snapshot_tick: int = 0
var _last_own_tick: int = 0
var _input_ack_tick: int = 0
var _server_substitutions: int = -1
var _substitution_rises: int = 0
var _lossy_until_tick: int = -1
var _last_input_margin: int = NetProtocol.NO_MARGIN
var _resyncs: int = 0
var _welcome: NetMessages.Welcome = null
var _rejected: bool = false
var _reject_result: int = 0
var _reject_text: String = ""
var _disconnect_text: String = ""
var _last_notice_text: String = ""

# Cerebro de combate: los enemigos que conoce por los ENTITY_SPAWN (net_id -> última posición conocida)
# y cuáles siguen vivos, y el desfase de la rotación con la que se decodifican los registros.
var _enemy_positions: Dictionary[int, Vector3] = {}
var _enemy_alive: Dictionary[int, bool] = {}
var _scan_phase: int = 0

# Estadísticas.
var _snapshots: int = 0
var _snapshots_late: int = 0
var _snapshots_with_state: int = 0
var _snapshot_bytes: int = 0
var _snapshot_records: int = 0
var _max_snapshot_bytes: int = 0
var _max_snapshot_records: int = 0
var _batches_sent: int = 0
var _spawns_seen: int = 0
var _despawns_seen: int = 0
var _events_seen: int = 0
var _event_bytes: int = 0
var _hit_events_seen: int = 0
var _respawn_requests: int = 0
var _last_respawn_request_tick: int = -1000
var _dead: bool = false
var _malformed_packets: int = 0
var _bytes_at_join: Dictionary = {}
var _bytes_final: Dictionary = {}
var _closed_local_tick: int = -1


func _init() -> void:
	_inputs.resize(INPUT_RING_SIZE)
	_view_offsets.resize(INPUT_RING_SIZE)


## Prepara el bot número [param index] del enjambre con [param config] y empieza a conectar. El nodo
## debe estar ya en el árbol. Nombre: [code]NameRules.bot_name(bot_seed + index)[/code]; reino: el de
## la configuración o uno de [constant DEFAULT_REALMS] según el índice; cerebro: [BotBrain] con la
## semilla [code]bot_seed + index[/code].
func setup(index: int, config: ClientConfig) -> void:
	if _state != State.IDLE:
		return
	_index = index
	_config = config
	_combat = config.bot_brain == ClientConfig.BOT_BRAIN_COMBAT
	_display_name = NameRules.bot_name(config.bot_seed + index)
	_realm = config.realm if config.realm != NetProtocol.Realm.NONE \
			else DEFAULT_REALMS[index % DEFAULT_REALMS.size()]
	name = "SwarmBot%d" % index
	_transport = NetTransport.new()
	_transport.name = "NetTransport"
	add_child(_transport)
	_transport.peer_authenticating.connect(_on_peer_authenticating)
	_transport.auth_received.connect(_on_auth_received)
	_transport.peer_connected.connect(_on_peer_connected)
	_transport.peer_disconnected.connect(_on_peer_disconnected)
	_transport.packet_received.connect(_on_packet_received)
	_transport.connection_failed.connect(_on_connection_failed)
	_transport.set_net_sim_spec(config.net_sim_spec)
	process_physics_priority = -100
	var error: Error = _transport.connect_to(config.address, config.port, CONNECT_TIMEOUT_MS)
	if error != OK:
		_close(TEXT_CONNECT_FAILED % [config.address, config.port])
		return
	_state = State.CONNECTING


## Sale de la zona: CLIENT_LEAVE y corte ordenado. [method get_state] pasa a [constant State.CLOSED]
## cuando la conexión se cierra.
func leave() -> void:
	if _state == State.IDLE or _state == State.CLOSED or _state == State.LEAVING:
		return
	if _state == State.WELCOMED or _state == State.READY_SENT or _state == State.IN_WORLD:
		var message := NetMessages.ClientLeave.new()
		message.reason = NetMessages.ClientLeave.REASON_QUIT
		_transport.send(SERVER_PEER_ID, NetProtocol.CH_RELIABLE, message.encode())
		_transport.disconnect_after_flush(SERVER_PEER_ID)
		_state = State.LEAVING
		return
	_close(TEXT_LEFT)


func get_bot_index() -> int:
	return _index


func get_state() -> State:
	return _state


func get_display_name() -> String:
	return _display_name


## true si ya tiene personaje en el servidor y juega.
func is_in_world() -> bool:
	return _state == State.IN_WORLD


## Id de red del personaje (0 hasta el SPAWN propio).
func get_net_id() -> int:
	return _net_id


func get_local_tick() -> int:
	return _local_tick


## Último estado propio del servidor (posición del último snapshot con estado).
func get_position() -> Vector3:
	return _position


func get_tick_sync() -> TickSync:
	return _tick_sync


func get_interpolation_clock() -> InterpolationClock:
	return _interp_clock


## Texto del último NOTICE del servidor ("" si no llegó ninguno).
func get_last_notice_text() -> String:
	return _last_notice_text


## Estadísticas del bot:
## [br]- [code]index[/code], [code]name[/code], [code]realm[/code], [code]state[/code], [code]net_id[/code],
## [code]spawn_tick[/code], [code]rtt_ticks[/code], [code]rejected[/code] ([code]reject_result[/code],
## [code]reject_text[/code]), [code]disconnect_text[/code], [code]last_notice[/code].
## [br]- [code]local_ticks[/code] (ticks de física desde que empezó), [code]world_ticks[/code] (los que lleva
## jugando, desde el SPAWN propio hasta el cierre o ahora).
## [br]- [code]snapshots[/code] recibidos, [code]late_snapshots[/code], [code]snapshots_with_state[/code],
## [code]snapshot_bytes[/code] (suma de sus tamaños), [code]avg_snapshot_bytes[/code],
## [code]max_snapshot_bytes[/code], [code]avg_snapshot_records[/code], [code]max_snapshot_records[/code].
## [br]- [code]bytes_up[/code] y [code]bytes_down[/code]: bytes de ENet desde el SPAWN propio;
## [code]kb_up_per_s[/code] y [code]kb_down_per_s[/code] sobre [code]world_ticks[/code]; [code]total_bytes_up[/code] y
## [code]total_bytes_down[/code] de toda la sesión.
## [br]- [code]batches_sent[/code], [code]target_margin[/code], [code]last_input_margin[/code],
## [code]tick_sync_adjustments[/code], [code]resyncs[/code], [code]substitution_rises[/code],
## [code]substitutions[/code] (contador del servidor), [code]spawns_seen[/code], [code]despawns_seen[/code],
## [code]delay_ticks[/code], [code]jitter_ticks[/code], [code]malformed_packets[/code].
## [br]- Del combate: [code]combat[/code] (si pelea), [code]events_seen[/code] y [code]event_bytes[/code]
## (ENTITY_EVENT recibidos y su tamaño), [code]hit_events_seen[/code], [code]enemies_known[/code],
## [code]dead[/code] y [code]respawn_requests[/code].
func get_stats() -> Dictionary:
	var counters: Dictionary = _byte_counters()
	var up: int = int(counters.get("wire_out", 0)) - int(_bytes_at_join.get("wire_out", 0))
	var down: int = int(counters.get("wire_in", 0)) - int(_bytes_at_join.get("wire_in", 0))
	if _joined_local_tick < 0:
		up = 0
		down = 0
	var end_tick: int = _closed_local_tick if _closed_local_tick >= 0 else _local_tick
	var world_ticks: int = maxi(end_tick - _joined_local_tick, 0) if _joined_local_tick >= 0 else 0
	var seconds: float = float(world_ticks) / float(Engine.physics_ticks_per_second)
	return {
		"index": _index,
		"name": _display_name,
		"realm": NetProtocol.realm_display_name(_realm),
		"state": State.keys()[_state],
		"net_id": _net_id,
		"spawn_tick": _spawn_tick,
		"rtt_ticks": _rtt_ticks,
		"rejected": _rejected,
		"reject_result": _reject_result,
		"reject_text": _reject_text,
		"disconnect_text": _disconnect_text,
		"last_notice": _last_notice_text,
		"local_ticks": _local_tick,
		"world_ticks": world_ticks,
		"snapshots": _snapshots,
		"late_snapshots": _snapshots_late,
		"snapshots_with_state": _snapshots_with_state,
		"snapshot_bytes": _snapshot_bytes,
		"avg_snapshot_bytes": float(_snapshot_bytes) / float(_snapshots) if _snapshots > 0 else 0.0,
		"max_snapshot_bytes": _max_snapshot_bytes,
		"avg_snapshot_records": float(_snapshot_records) / float(_snapshots) if _snapshots > 0 else 0.0,
		"max_snapshot_records": _max_snapshot_records,
		"bytes_up": up,
		"bytes_down": down,
		"kb_up_per_s": float(up) / 1024.0 / seconds if seconds > 0.0 else 0.0,
		"kb_down_per_s": float(down) / 1024.0 / seconds if seconds > 0.0 else 0.0,
		"total_bytes_up": int(counters.get("wire_out", 0)),
		"total_bytes_down": int(counters.get("wire_in", 0)),
		"batches_sent": _batches_sent,
		"target_margin": _tick_sync.get_target_margin(),
		"last_input_margin": _last_input_margin,
		"tick_sync_adjustments": _tick_sync.adjustments,
		"resyncs": _resyncs,
		"substitution_rises": _substitution_rises,
		"substitutions": maxi(_server_substitutions, 0),
		"spawns_seen": _spawns_seen,
		"despawns_seen": _despawns_seen,
		"events_seen": _events_seen,
		"event_bytes": _event_bytes,
		"hit_events_seen": _hit_events_seen,
		"combat": _combat,
		"enemies_known": _enemy_positions.size(),
		"dead": _dead,
		"respawn_requests": _respawn_requests,
		"delay_ticks": _interp_clock.get_delay_ticks(),
		"jitter_ticks": _interp_clock.get_jitter_ticks(),
		"malformed_packets": _malformed_packets,
	}


# --- Bucle del tick ---------------------------------------------------------------------------

func _physics_process(_delta: float) -> void:
	if _state == State.IDLE or _state == State.CLOSED:
		return
	_local_tick += 1
	_transport.poll(_local_tick)
	if _state == State.IN_WORLD:
		_play_tick()
	_interp_clock.advance(_local_tick)
	_transport.flush()


# Los pasos de predicción que decide TickSync generan, cada uno, la entrada del siguiente tick, y se
# envía el lote. No hay simulación: la posición para el cerebro es la del último estado propio.
func _play_tick() -> void:
	var steps: int = _tick_sync.next_steps(_predicted_tick)
	if steps > 2:
		_resyncs += 1
	for _i: int in steps:
		_predicted_tick += 1
		if _predicted_tick >= _first_real_tick:
			var input: PlayerInput = _brain.next_input(_predicted_tick, _position, _yaw).quantized()
			_inputs[_predicted_tick % INPUT_RING_SIZE] = input
			_view_offsets[_predicted_tick % INPUT_RING_SIZE] = _view_offset_q(_predicted_tick)
	_send_input_batch()


# INPUT_BATCH de 5.4: de max(ack + 1, newest - R + 1, primer tick real) a newest, con R = 4 (8 si las
# sustituciones del servidor subieron hace poco).
func _send_input_batch() -> void:
	var newest: int = _predicted_tick
	if newest < _first_real_tick:
		return
	var redundancy: int = NetProtocol.INPUT_REDUNDANCY
	if _local_tick < _lossy_until_tick:
		redundancy = NetProtocol.INPUT_REDUNDANCY_LOSSY
	var oldest: int = mini(maxi(maxi(_input_ack_tick + 1, newest - redundancy + 1),
			_first_real_tick), newest)
	var batch := NetMessages.InputBatch.new()
	batch.ack_snapshot_tick = _newest_snapshot_tick
	batch.interp_delay_q = clampi(roundi(_interp_clock.get_delay_ticks() * INTERP_DELAY_SCALE), 0, 255)
	batch.newest_tick = newest
	for tick: int in range(oldest, newest + 1):
		var input: PlayerInput = _inputs[tick % INPUT_RING_SIZE]
		if input == null or input.tick != tick:
			batch.inputs.clear()
			batch.view_offsets_q.clear()
			continue
		batch.inputs.append(input)
		batch.view_offsets_q.append(_view_offsets[tick % INPUT_RING_SIZE])
	if batch.inputs.is_empty():
		return
	var bytes: PackedByteArray = batch.encode()
	if not bytes.is_empty() and _transport.send(SERVER_PEER_ID, NetProtocol.CH_INPUT, bytes) == OK:
		_batches_sent += 1


# Desfase de la vista de la entrada del tick [param tick] ((tick - tick de dibujo) × 16): lo que mandaría
# un cliente, para que el servidor haga el rebobinado de verdad. Solo con el cerebro de combate; sin él
# (y antes de que arranque el reloj de interpolación) no hay vista que medir.
func _view_offset_q(tick: int) -> int:
	if not _combat:
		return 0
	var drawn: float = _interp_clock.get_render_tick()
	if drawn <= 0.0:
		return 0
	return clampi(roundi((float(tick) - drawn) * VIEW_OFFSET_SCALE), 0, NetMessages.MAX_VIEW_OFFSET_Q)


# --- Conexión ---------------------------------------------------------------------------------

func _on_peer_authenticating(peer_id: int) -> void:
	if peer_id != SERVER_PEER_ID or _state != State.CONNECTING:
		return
	var hello := NetMessages.Hello.new()
	hello.protocol_version = NetProtocol.PROTOCOL_VERSION
	hello.sim_hash = _get_sim_hash()
	hello.realm = _realm
	hello.flags |= NetMessages.Hello.FLAG_BOT
	hello.display_name = _display_name
	_hello_tick = _local_tick
	if _transport.send_auth(SERVER_PEER_ID, hello.encode()) != OK:
		_close(TEXT_CONNECTION_LOST)
		return
	_state = State.HELLO_SENT


func _on_auth_received(peer_id: int, bytes: PackedByteArray) -> void:
	if peer_id != SERVER_PEER_ID or _state != State.HELLO_SENT:
		return
	var kind: int = NetMessages.peek_auth_result(bytes)
	if kind > 0:
		var reject: NetMessages.Reject = NetMessages.Reject.decode(bytes)
		if reject == null:
			_close(TEXT_BAD_REPLY)
			return
		_rejected = true
		_reject_result = reject.result
		_reject_text = reject.text
		_close(reject.text)
		return
	var welcome: NetMessages.Welcome = NetMessages.Welcome.decode(bytes) if kind == 0 else null
	if welcome == null or welcome.protocol_version != NetProtocol.PROTOCOL_VERSION \
			or welcome.tick_rate != Engine.physics_ticks_per_second:
		_close(TEXT_BAD_REPLY)
		return
	_rtt_hello_ticks = maxi(_local_tick - _hello_tick, 0)
	_welcome = welcome
	if _transport.complete_auth(SERVER_PEER_ID) != OK:
		_close(TEXT_CONNECTION_LOST)


# Autenticado en los dos lados: no hay zona que cargar, así que CLIENT_READY sale ya.
func _on_peer_connected(peer_id: int) -> void:
	if peer_id != SERVER_PEER_ID or _state != State.HELLO_SENT or _welcome == null:
		return
	_ready_tick = _local_tick
	if _transport.send(SERVER_PEER_ID, NetProtocol.CH_RELIABLE,
			NetMessages.ClientReady.new().encode()) != OK:
		_close(TEXT_CONNECTION_LOST)
		return
	_state = State.READY_SENT


func _on_peer_disconnected(peer_id: int) -> void:
	if peer_id != SERVER_PEER_ID or _state == State.CLOSED:
		return
	if _state == State.LEAVING:
		_close(TEXT_LEFT)
	elif not _last_notice_text.is_empty():
		_close(_last_notice_text)
	else:
		_close(TEXT_CONNECTION_LOST)


func _on_connection_failed() -> void:
	if _state == State.CLOSED or _rejected:
		return
	_close(TEXT_CONNECT_FAILED % [_config.address, _config.port])


# Termina la sesión: deja de jugar y cierra el transporte.
func _close(text: String) -> void:
	if _state == State.CLOSED:
		return
	_state = State.CLOSED
	_disconnect_text = text
	_closed_local_tick = _local_tick
	if is_instance_valid(_transport):
		_bytes_final = _byte_counters()
		_transport.close()
	set_physics_process(false)


# --- Paquetes ---------------------------------------------------------------------------------

func _on_packet_received(peer_id: int, bytes: PackedByteArray) -> void:
	if peer_id != SERVER_PEER_ID or bytes.is_empty():
		return
	match NetMessages.peek_type(bytes):
		NetProtocol.MSG_SNAPSHOT:
			_on_snapshot(bytes)
		NetProtocol.MSG_ENTITY_SPAWN:
			_on_spawn(bytes)
		NetProtocol.MSG_ENTITY_DESPAWN:
			_despawns_seen += 1
			if _combat:
				var despawn: NetMessages.EntityDespawn = NetMessages.EntityDespawn.decode(bytes)
				if despawn != null:
					_enemy_positions.erase(despawn.net_id)
					_enemy_alive.erase(despawn.net_id)
		NetProtocol.MSG_ENTITY_EVENT:
			# Los eventos de combate no hacen nada a un bot, pero tienen que estar bien formados.
			var event: NetMessages.EntityEvent = NetMessages.EntityEvent.decode(bytes)
			if event == null:
				_malformed_packets += 1
			else:
				_events_seen += 1
				_event_bytes += bytes.size()
				if event.event == NetMessages.EntityEvent.Kind.HIT:
					_hit_events_seen += 1
		NetProtocol.MSG_NOTICE:
			var notice: NetMessages.Notice = NetMessages.Notice.decode(bytes)
			if notice == null:
				_malformed_packets += 1
			else:
				_last_notice_text = notice.text
		_:
			_malformed_packets += 1


# Solo se lee la cabecera del SNAPSHOT (ver NetMessages.Snapshot): este bot no dibuja a nadie, y
# decodificar los registros de 57 jugadores en cada bot de un enjambre costaría más que el servidor.
func _on_snapshot(bytes: PackedByteArray) -> void:
	var size: int = bytes.size()
	if size < NetMessages.SNAPSHOT_HEADER_SIZE:
		_malformed_packets += 1
		return
	var flags: int = bytes.decode_u8(12)
	var section_offset: int = 13
	var has_state: bool = (flags & NetMessages.FLAG_OWN_STATE) != 0
	if has_state:
		if size < NetMessages.SNAPSHOT_HEADER_SIZE_WITH_STATE:
			_malformed_packets += 1
			return
		# El estado propio va seguido del bloque extra (vida), que siempre lo acompaña.
		section_offset += PlayerState.ENCODED_SIZE + NetMessages.SNAPSHOT_EXTRA_SIZE
	var server_tick: int = bytes.decode_u32(1)
	if _combat and _state == State.IN_WORLD:
		_scan_enemies(bytes, section_offset)
	_snapshots += 1
	_snapshot_bytes += size
	_max_snapshot_bytes = maxi(_max_snapshot_bytes, size)
	var records: int = _count_records(bytes, section_offset)
	_snapshot_records += records
	_max_snapshot_records = maxi(_max_snapshot_records, records)
	if server_tick < _newest_snapshot_tick:
		_snapshots_late += 1
	_newest_snapshot_tick = maxi(_newest_snapshot_tick, server_tick)
	_interp_clock.on_snapshot(server_tick, _local_tick)
	if _state != State.IN_WORLD or server_tick <= _last_own_tick:
		return
	_last_own_tick = server_tick
	var input_ack_tick: int = bytes.decode_u32(5)
	var input_margin: int = bytes.decode_s8(9)
	_tick_sync.set_jitter(_interp_clock.get_jitter_ticks())
	_tick_sync.on_snapshot(input_ack_tick, input_margin)
	_input_ack_tick = maxi(_input_ack_tick, input_ack_tick)
	_last_input_margin = input_margin
	_note_substitutions(bytes.decode_u16(10))
	if has_state:
		_snapshots_with_state += 1
		var state: PlayerState = PlayerState.decode(bytes.slice(13, 13 + PlayerState.ENCODED_SIZE))
		if state != null:
			_position = state.position
			_yaw = state.yaw
		if _combat:
			_note_extra_block(bytes, server_tick)


# Cerebro de combate: decodifica la posición y la vida de uno de cada ENEMY_SCAN_STRIDE registros del
# snapshot (rotando el desfase en cada snapshot) y actualiza solo a los enemigos que ya conoce.
func _scan_enemies(bytes: PackedByteArray, section_offset: int) -> void:
	if section_offset >= bytes.size() or _enemy_positions.is_empty():
		return
	var sections: int = bytes.decode_u8(section_offset)
	var offset: int = section_offset + 1
	var phase: int = _scan_phase
	_scan_phase = (_scan_phase + 1) % ENEMY_SCAN_STRIDE
	var running: int = 0
	for _i: int in sections:
		if offset + 2 > bytes.size():
			break
		var count: int = bytes[offset + 1]
		offset += 2
		var record: int = posmod(phase - running, ENEMY_SCAN_STRIDE)
		while record < count:
			var record_offset: int = offset + record * EntityRecord.SIZE
			if record_offset + EntityRecord.SIZE > bytes.size():
				break
			var net_id: int = bytes.decode_u16(record_offset)
			if _enemy_positions.has(net_id):
				_enemy_positions[net_id] = NetMath.unpack_position(bytes.decode_u64(record_offset + 2))
				_enemy_alive[net_id] = bytes[record_offset + 20] != EntityRecord.HEALTH_Q_DEAD
			record += ENEMY_SCAN_STRIDE
		running += count
		offset += count * EntityRecord.SIZE


# Cerebro de combate: lee el bloque extra del snapshot (vida, estado, tick de reaparición) y, estando
# muerto, pide reaparecer en cuanto se puede.
func _note_extra_block(bytes: PackedByteArray, server_tick: int) -> void:
	var extra_offset: int = 13 + PlayerState.ENCODED_SIZE
	var status: int = bytes.decode_u8(extra_offset + 4)
	var respawn_tick: int = bytes.decode_u32(extra_offset + 5)
	_dead = (status & NetMessages.STATUS_DEAD) != 0
	if not _dead or server_tick < respawn_tick:
		return
	if _local_tick - _last_respawn_request_tick < RESPAWN_RETRY_TICKS:
		return
	_last_respawn_request_tick = _local_tick
	var request := NetMessages.RespawnRequest.new()
	if _transport.send(SERVER_PEER_ID, NetProtocol.CH_RELIABLE, request.encode()) == OK:
		_respawn_requests += 1


# Cerebro de combate: el enemigo vivo más cercano a [param position] (la última posición que se sabe de
# él), o null.
func _find_enemy(position: Vector3) -> Variant:
	var best: Variant = null
	var best_distance: float = INF
	for net_id: int in _enemy_positions:
		if not _enemy_alive[net_id]:
			continue
		var enemy_position: Vector3 = _enemy_positions[net_id]
		var distance: float = position.distance_squared_to(enemy_position)
		if distance < best_distance:
			best_distance = distance
			best = enemy_position
	return best


# Registros del snapshot, sumando los contadores de sus secciones sin decodificarlos.
func _count_records(bytes: PackedByteArray, section_offset: int) -> int:
	if section_offset >= bytes.size():
		return 0
	var sections: int = bytes.decode_u8(section_offset)
	var offset: int = section_offset + 1
	var total: int = 0
	for _i: int in sections:
		if offset + 2 > bytes.size():
			break
		var count: int = bytes[offset + 1]
		total += count
		offset += 2 + count * EntityRecord.SIZE
	return total


# Contador de entradas sustituidas del servidor (mod 65536): si sube, se envía con más redundancia.
func _note_substitutions(value: int) -> void:
	if _server_substitutions < 0:
		_server_substitutions = value
		return
	var rise: int = (value - _server_substitutions) & 0xFFFF
	_server_substitutions = value
	if rise > 0:
		_substitution_rises += 1
		_lossy_until_tick = _local_tick + LOSSY_WINDOW_TICKS


func _on_spawn(bytes: PackedByteArray) -> void:
	var spawn: NetMessages.EntitySpawn = NetMessages.EntitySpawn.decode(bytes)
	if spawn == null:
		_malformed_packets += 1
		return
	if not spawn.is_yours:
		_spawns_seen += 1
		if _combat and spawn.kind == NetProtocol.EntityKind.PLAYER and spawn.state != null \
				and FactionRules.can_damage(_realm, spawn.realm, StringName(_welcome.zone_id)):
			_enemy_positions[spawn.net_id] = spawn.state.position
			_enemy_alive[spawn.net_id] = true
		return
	if _state != State.READY_SENT:
		return
	_rtt_ticks = maxi(mini(_rtt_hello_ticks, _local_tick - _ready_tick), 0)
	_first_real_tick = _tick_sync.start(spawn.spawn_tick, _rtt_ticks)
	_net_id = spawn.net_id
	_spawn_tick = spawn.spawn_tick
	_predicted_tick = spawn.spawn_tick
	_position = spawn.state.position
	_yaw = spawn.state.yaw
	_last_own_tick = spawn.spawn_tick
	if _combat:
		_brain = BotBrain.new(_config.bot_seed + _index, BotBrain.Pattern.COMBAT, _position, BOT_RADIUS)
		_brain.set_enemy_finder(_find_enemy)
	else:
		_brain = BotBrain.new(_config.bot_seed + _index, BotBrain.Pattern.WANDER, _position, BOT_RADIUS)
	_joined_local_tick = _local_tick
	_bytes_at_join = _byte_counters()
	_state = State.IN_WORLD


# --- Auxiliares -------------------------------------------------------------------------------

# Bytes de ENet del transporte (el último conocido si ya se cerró).
func _byte_counters() -> Dictionary:
	if is_instance_valid(_transport):
		_bytes_final = _transport.get_byte_counters()
	return _bytes_final


# Huella de la simulación (sección 3), calculada una vez por proceso sobre una instancia del
# personaje dentro del árbol, después de _ready().
func _get_sim_hash() -> int:
	if _cached_sim_hash >= 0:
		return _cached_sim_hash
	var scene: PackedScene = load(PLAYER_SCENE_PATH) as PackedScene
	var character: PlayerCharacter = scene.instantiate() as PlayerCharacter if scene != null else null
	if character == null:
		return 0
	add_child(character)
	_cached_sim_hash = NetProtocol.compute_sim_hash(character)
	remove_child(character)
	character.free()
	return _cached_sim_hash
