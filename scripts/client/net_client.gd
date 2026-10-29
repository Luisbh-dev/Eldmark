class_name NetClient
extends Node
## Cliente de red (docs/red.md, secciones 3, 6, 7 y 9.4): conecta con la zona, predice al jugador
## local, reconcilia con el servidor y dibuja a los demás.
## [br][br]
## [b]Conexión[/b] (sección 3), desde el lado del cliente:
## [codeblock]
## peer_authenticating(1)  ->  HELLO (send_auth) y se apunta hello_local_tick
## auth_received           ->  REJECT: señal rejected          WELCOME: rtt_hello = local_tick -
##                             hello_local_tick, se comprueba tick_rate y complete_auth(1)
## peer_connected(1)       ->  señal welcomed: quien tenga la zona la carga y llama a
##                             notify_zone_ready(), que envía CLIENT_READY y apunta ready_local_tick
## ENTITY_SPAWN propio     ->  rtt_ticks = min(rtt_hello, local_tick - ready_local_tick);
##                             P0 = TickSync.start(S, rtt_ticks); se instancia el personaje local y
##                             ClientPrediction.start(S, estado, P0); señal local_spawned
## [/codeblock]
## Nada se envía con [method NetTransport.send] antes de [signal NetTransport.peer_connected]
## (en el cliente, el peer 1), y el INPUT_BATCH no sale hasta el SPAWN propio.
## [br][br]
## [b]Tick[/b] (sección 6.2, normativo): un único [method _physics_process] con
## [code]process_physics_priority = -100[/code] lo orquesta todo, con
## [member LocalPlayerController.auto_step] en false: recibir (poll), reconciliar con el snapshot
## más nuevo, dar los pasos de predicción que decide [TickSync], enviar el INPUT_BATCH, avanzar el
## reloj de interpolación, suavizar y vaciar (flush). Los snapshots que llegan desordenados solo
## alimentan a los interpoladores ([InterpolationClock] y [RemoteWorld]), nunca a la reconciliación.
## [br][br]
## [b]INPUT_BATCH[/b] (5.4), una vez por tick: de [code]max(input_ack_tick + 1, newest - R + 1,
## first_real_tick)[/code] a [code]newest[/code] (sin pasar de newest), con R = 4, o R = 8 si en los
## últimos [constant LOSSY_WINDOW_TICKS] ticks subió [code]substitutions[/code] o ENet mide más de un
## [constant LOSS_THRESHOLD] de pérdida. Cada entrada lleva su [code]view_offset_q[/code]
## ([code](tick - render_tick visto) × 16[/code]).
## [br][br]
## [b]Estadísticas[/b] ([method get_stats], [method write_report]): ver las claves en
## [method get_stats]. Con [member ClientConfig.state_log_path] se escribe
## [code]server_tick,hex(predicho),hex(servidor)[/code] por cada snapshot con estado propio.
## [br][br]
## [b]Bot tramposo[/b] ([member ClientConfig.bot_cheat], solo en modo BOT): un [BotCheater] falsea
## el HELLO ([code]version[/code]) o envía tráfico de más tras el lote honrado de cada tick
## ([code]future[/code], [code]dupes[/code], [code]garbage[/code], [code]flood[/code]). El bot
## sigue prediciendo con sus entradas honradas; lo que se comprueba es que el servidor no se deja.

## Se emite al completar la autenticación en los dos lados: es el momento de cargar la zona
## [code]welcome.zone_id[/code] y llamar a [method notify_zone_ready].
signal welcomed(welcome: NetMessages.Welcome)
## El servidor ha rechazado la conexión. [param text] está en español.
signal rejected(result: int, text: String)
## El personaje local ya existe y la predicción ha arrancado (cámara, HUD, bot...).
signal local_spawned(character: PlayerCharacter)
## Se acabó la conexión (cierre del servidor, expulsión, corte, fallo al conectar o
## [method leave]). [param text] está en español.
signal disconnected(text: String)
## NOTICE del servidor: [param code] es un [enum NetProtocol.NoticeCode].
signal notice_received(code: int, text: String)

enum State {
	## Sin [method start].
	IDLE,
	## Conectando: esperando a que ENet empiece la autenticación.
	CONNECTING,
	## HELLO enviado: esperando WELCOME o REJECT.
	HELLO_SENT,
	## Autenticado: la zona se está cargando.
	WELCOMED,
	## CLIENT_READY enviado: esperando el SPAWN propio.
	READY_SENT,
	## Con personaje local y predicción en marcha.
	IN_WORLD,
	## Se ha pedido salir: esperando a que se cierre la conexión.
	LEAVING,
	## Rechazado, desconectado o fallo de conexión: ya no hay sesión.
	CLOSED,
}

const PLAYER_SCENE_PATH: String = "res://scenes/characters/player_character.tscn"
## Tiempo de espera de ENet al conectar (ms): el fallo se detecta en el doble como mucho.
const CONNECT_TIMEOUT_MS: int = 3000
## Id con el que el cliente ve al servidor.
const SERVER_PEER_ID: int = 1
## Ticks tras una subida de las sustituciones del servidor en los que se envía con R = 8.
const LOSSY_WINDOW_TICKS: int = 120
## Pérdida de ENet (0 a 1) a partir de la cual se envía con R = 8.
const LOSS_THRESHOLD: float = 0.02
## Cada cuántos ticks se consulta la pérdida de ENet.
const LOSS_SAMPLE_TICKS: int = 30
## Escalas de los campos del INPUT_BATCH: retardo de interpolación × 8, desfase de vista × 16.
const INTERP_DELAY_SCALE: float = 8.0
const VIEW_OFFSET_SCALE: float = 16.0
## Resincronizaciones de TickSync (pasos de golpe) y reinicios que se recuerdan con su tick.
const MAX_REMEMBERED_EVENTS: int = 64
## Mensajes de [signal disconnected].
const TEXT_CONNECT_FAILED: String = "No se pudo conectar con el servidor %s:%d"
const TEXT_CONNECTION_LOST: String = "Se perdió la conexión con el servidor"
const TEXT_LEFT: String = "Has salido de la zona"
const TEXT_BAD_REPLY: String = "Respuesta del servidor no válida"
const TEXT_BAD_VERSION: String = "Versión del protocolo incompatible con la del servidor"
const TEXT_BAD_TICK_RATE: String = "El servidor simula a %d ticks por segundo y este cliente a %d"

## Gancho de pruebas (y del futuro bot tramposo, TEC-46): se llama con el HELLO justo antes de
## enviarlo y puede modificarlo (versión, huella, reino...). Debe estar puesto antes de que el
## transporte empiece a autenticar, es decir, justo después de [method start].
var hello_hook: Callable = Callable()
## Tiempo de espera de ENet al conectar (ms). [constant CONNECT_TIMEOUT_MS] salvo que quien llama a
## [method start] ponga otro antes (el modo [code]--local[/code] usa uno corto para reintentar).
var connect_timeout_ms: int = CONNECT_TIMEOUT_MS

var _state: State = State.IDLE
var _config: ClientConfig = null
var _cheater: BotCheater = null
var _cheat_packets_sent: int = 0
var _transport: NetTransport = null
var _controller: LocalPlayerController = null
var _prediction: ClientPrediction = ClientPrediction.new()
var _smoother: CorrectionSmoother = CorrectionSmoother.new()
var _tick_sync: TickSync = TickSync.new()
var _interp_clock: InterpolationClock = InterpolationClock.new()
var _remote_world: RemoteWorld = RemoteWorld.new()
var _character: PlayerCharacter = null
var _world_root: Node3D = null
var _welcome: NetMessages.Welcome = null
var _sim_hash: int = 0
var _local_tick: int = 0
var _hello_local_tick: int = 0
var _ready_local_tick: int = 0
var _rtt_hello_ticks: int = 0
var _rtt_ticks: int = 0
var _net_id: int = 0
var _spawn_tick: int = 0
var _own_teleport: int = 0
var _last_notice_text: String = ""
var _rejected: bool = false
var _reject_result: int = 0
var _reject_text: String = ""
var _last_disconnect_text: String = ""

# Snapshots.
var _latest: NetMessages.Snapshot = null
var _newest_snapshot_tick: int = 0
var _last_snapshot_tick: int = 0
var _input_ack_tick: int = 0
var _last_server_state: PlayerState = null
var _last_input_margin: int = NetProtocol.NO_MARGIN
var _snapshots_received: int = 0
var _snapshots_late: int = 0
var _snapshots_with_state: int = 0
var _malformed_packets: int = 0

# Envío de entradas.
var _view_offsets_q: PackedInt32Array = PackedInt32Array()
var _batches_sent: int = 0
var _server_substitutions: int = -1
var _substitutions_total: int = 0
var _substitution_rises: int = 0
var _lossy_until_tick: int = -1
var _loss_sampled_tick: int = 0
var _high_loss: bool = false

# Resultados de la reconciliación.
var _diffs: int = 0
var _explained_diffs: int = 0
var _unexplained_diffs: int = 0
var _teleport_diffs: int = 0
var _consecutive_matches: int = 0
var _last_result: int = ClientPrediction.Result.IGNORED
var _resyncs: int = 0
var _hard_reset_ticks: Array[int] = []
var _resync_ticks: Array[int] = []
var _unexplained_ticks: Array[int] = []

var _state_log: FileAccess = null
var _state_log_failed: bool = false


func _init() -> void:
	name = "NetClient"
	process_physics_priority = -100
	_view_offsets_q.resize(ClientPrediction.HISTORY_SIZE)
	_view_offsets_q.fill(0)
	_remote_world.setup(_interp_clock)


func _ready() -> void:
	# No hay nada que hacer hasta start().
	set_physics_process(_state != State.IDLE and _state != State.CLOSED)


func _exit_tree() -> void:
	_close_state_log()


func _notification(what: int) -> void:
	# El RemoteWorld solo entra en el árbol al avisar de que la zona está lista: si la sesión acaba
	# antes (rechazo, fallo de conexión), nadie más lo liberaría.
	if what == NOTIFICATION_PREDELETE:
		if is_instance_valid(_remote_world) and _remote_world.get_parent() == null:
			_remote_world.free()


# --- API pública ------------------------------------------------------------------------------

## Empieza la sesión: prepara la predicción, calcula la huella de la simulación (sim_hash) y
## empieza a conectar con [member ClientConfig.address]:[member ClientConfig.port] a través de
## [param transport] (que debe estar en el árbol). [param controller] es el controlador del
## personaje local: se le pone [code]auto_step = false[/code] y la predicción lo usa para
## construir las entradas. Devuelve el error de [method NetTransport.connect_to] si no se puede
## empezar a conectar.
func start(config: ClientConfig, transport: NetTransport,
		controller: LocalPlayerController) -> Error:
	if _state != State.IDLE:
		return ERR_ALREADY_IN_USE
	if config == null or transport == null or controller == null or not is_inside_tree() \
			or not transport.is_inside_tree():
		return ERR_UNCONFIGURED
	_config = config
	_transport = transport
	_controller = controller
	_controller.auto_step = false
	_sim_hash = _compute_sim_hash()
	_cheater = _make_cheater(config)
	_connect_transport()
	_transport.set_net_sim_spec(config.net_sim_spec)
	var error: Error = _transport.connect_to(config.address, config.port, connect_timeout_ms)
	if error != OK:
		_disconnect_transport()
		return error
	_state = State.CONNECTING
	set_physics_process(true)
	return OK


## Envía CLIENT_READY (solo tras [signal welcomed]) y apunta el tick local. [param world_root]
## recibe el [RemoteWorld] y, cuando llegue el SPAWN propio, al personaje local. Lo normal es
## llamarlo cuando la zona ya está cargada y en el árbol, con [param world_root] dentro de ella o
## la propia zona.
func notify_zone_ready(world_root: Node3D) -> void:
	if _state != State.WELCOMED:
		push_warning("[Eldmark] notify_zone_ready() fuera de lugar (estado %s)"
				% State.keys()[_state])
		return
	if world_root == null:
		push_error("[Eldmark] notify_zone_ready() sin nodo raíz de la zona")
		return
	_world_root = world_root
	if _remote_world.get_parent() == null:
		_world_root.add_child(_remote_world)
	_ready_local_tick = _local_tick
	var error: Error = _transport.send(SERVER_PEER_ID, NetProtocol.CH_RELIABLE,
			NetMessages.ClientReady.new().encode())
	if error != OK:
		_close_session(TEXT_CONNECTION_LOST)
		return
	_state = State.READY_SENT


## Sale de la zona: envía CLIENT_LEAVE (baja inmediata sin esperar al timeout) y pide el corte
## ordenado. [signal disconnected] llega cuando la conexión se cierra. Antes de estar conectado,
## simplemente cancela.
func leave() -> void:
	if _state == State.IDLE or _state == State.CLOSED or _state == State.LEAVING:
		return
	if _state == State.WELCOMED or _state == State.READY_SENT or _state == State.IN_WORLD:
		var leave_message := NetMessages.ClientLeave.new()
		leave_message.reason = NetMessages.ClientLeave.REASON_QUIT
		_transport.send(SERVER_PEER_ID, NetProtocol.CH_RELIABLE, leave_message.encode())
		_transport.disconnect_after_flush(SERVER_PEER_ID)
		_state = State.LEAVING
		return
	_close_session(TEXT_LEFT)


## Envía un DEBUG_COMMAND ([constant NetProtocol.DEBUG_TELEPORT]...). El servidor solo lo acepta
## con [code]--debug-commands[/code].
func send_debug_command(command: int, payload: PackedByteArray) -> void:
	if _state != State.IN_WORLD:
		return
	var message := NetMessages.DebugCommand.new()
	message.command = command
	message.payload = payload
	_transport.send(SERVER_PEER_ID, NetProtocol.CH_RELIABLE, message.encode())


## Personaje local (null hasta [signal local_spawned]).
func get_character() -> PlayerCharacter:
	return _character


func get_prediction() -> ClientPrediction:
	return _prediction


func get_remote_world() -> RemoteWorld:
	return _remote_world


func get_tick_sync() -> TickSync:
	return _tick_sync


func get_interpolation_clock() -> InterpolationClock:
	return _interp_clock


## Ticks de física que lleva el cliente desde [method start].
func get_local_tick() -> int:
	return _local_tick


## Último estado propio del servidor que se reconcilió (null si aún no ha llegado ninguno).
func get_last_server_state() -> PlayerState:
	return _last_server_state


func get_state() -> State:
	return _state


## Id de red del personaje local (0 hasta el SPAWN propio).
func get_net_id() -> int:
	return _net_id


## Tick del servidor en el que apareció el personaje local (0 hasta el SPAWN propio).
func get_spawn_tick() -> int:
	return _spawn_tick


func get_welcome() -> NetMessages.Welcome:
	return _welcome


func get_controller() -> LocalPlayerController:
	return _controller


func get_config() -> ClientConfig:
	return _config


func get_transport() -> NetTransport:
	return _transport


## RTT en ticks con el que arrancó la predicción (0 antes del SPAWN propio).
func get_rtt_ticks() -> int:
	return _rtt_ticks


## Texto del último NOTICE del servidor ("" si no ha llegado ninguno).
func get_last_notice_text() -> String:
	return _last_notice_text


## Estadísticas de la sesión (todas desde el SPAWN propio salvo que se diga lo contrario):
## [br]- [code]local_ticks[/code], [code]spawn_tick[/code], [code]first_real_tick[/code],
## [code]predicted_tick[/code], [code]server_tick[/code] (último snapshot reconciliado),
## [code]rtt_hello_ticks[/code], [code]rtt_ticks[/code].
## [br]- [code]snapshots[/code] recibidos, [code]late_snapshots[/code] (desordenados),
## [code]snapshots_with_state[/code] (con estado propio reconciliado), [code]malformed_packets[/code].
## [br]- [code]matches[/code] (coincidencias exactas), [code]ignored[/code], [code]diffs[/code]
## (estados que no coincidían y se repitieron), [code]explained_diffs[/code] (con una subida de
## [code]substitutions[/code] o un teletransporte), [code]unexplained_diffs[/code],
## [code]teleport_diffs[/code], [code]corrections[/code] (las de más de 1 mm),
## [code]resimulated_ticks[/code], [code]last_correction[/code], [code]max_correction[/code],
## [code]consecutive_matches[/code] (racha actual), [code]last_result[/code].
## [br]- [code]hard_resets[/code] (de la predicción), [code]hard_reset_ticks[/code] (tick local de
## cada uno), [code]resyncs[/code] (resincronizaciones duras de TickSync), [code]resync_ticks[/code],
## [code]tick_sync_adjustments[/code], [code]target_margin[/code], [code]window_min[/code],
## [code]last_input_margin[/code].
## [br]- [code]substitutions[/code] (contador del servidor), [code]substitution_rises[/code] y
## [code]substitutions_total[/code].
## [br]- [code]delay_ticks[/code], [code]jitter_ticks[/code], [code]render_tick[/code],
## [code]batches_sent[/code], [code]cheat_packets[/code] (paquetes de más del bot tramposo),
## [code]remote_views[/code].
func get_stats() -> Dictionary:
	var prediction_stats: Dictionary = _prediction.get_stats()
	return {
		"local_ticks": _local_tick,
		"spawn_tick": _spawn_tick,
		"first_real_tick": _prediction.get_first_real_tick(),
		"predicted_tick": _prediction.get_predicted_tick(),
		"server_tick": _last_snapshot_tick,
		"rtt_hello_ticks": _rtt_hello_ticks,
		"rtt_ticks": _rtt_ticks,
		"snapshots": _snapshots_received,
		"late_snapshots": _snapshots_late,
		"snapshots_with_state": _snapshots_with_state,
		"malformed_packets": _malformed_packets,
		"matches": prediction_stats["matches"],
		"ignored": prediction_stats["ignored"],
		"diffs": _diffs,
		"explained_diffs": _explained_diffs,
		"unexplained_diffs": _unexplained_diffs,
		"teleport_diffs": _teleport_diffs,
		"corrections": prediction_stats["corrections"],
		"resimulated_ticks": prediction_stats["resimulated_ticks"],
		"last_correction": prediction_stats["last_correction"],
		"max_correction": prediction_stats["max_correction"],
		"consecutive_matches": _consecutive_matches,
		"last_result": _last_result,
		"hard_resets": prediction_stats["hard_resets"],
		"hard_reset_ticks": _hard_reset_ticks.duplicate(),
		"resyncs": _resyncs,
		"resync_ticks": _resync_ticks.duplicate(),
		"unexplained_ticks": _unexplained_ticks.duplicate(),
		"tick_sync_adjustments": _tick_sync.adjustments,
		"target_margin": _tick_sync.get_target_margin(),
		"window_min": _tick_sync.get_window_min(),
		"last_input_margin": _last_input_margin,
		"substitutions": maxi(_server_substitutions, 0),
		"substitution_rises": _substitution_rises,
		"substitutions_total": _substitutions_total,
		"delay_ticks": _interp_clock.get_delay_ticks(),
		"jitter_ticks": _interp_clock.get_jitter_ticks(),
		"render_tick": _interp_clock.get_render_tick(),
		"batches_sent": _batches_sent,
		"cheat_packets": _cheat_packets_sent,
		"remote_views": _remote_world.get_view_count(),
	}


## Escribe el informe JSON de la sesión en [param path] (los directorios que falten se crean). Sus
## claves son las de [method get_stats] más: [code]version[/code], [code]name[/code],
## [code]realm[/code], [code]mode[/code], [code]address[/code], [code]port[/code],
## [code]net_sim[/code], [code]seed[/code], [code]cheat[/code] (modo del bot tramposo, o ""),
## [code]zone[/code], [code]net_id[/code],
## [code]state[/code], [code]rejected[/code] (con [code]reject_result[/code] y
## [code]reject_text[/code] si el servidor rechazó la conexión), [code]disconnect_text[/code] y
## [code]final[/code]: [code]{predicted_tick,
## predicted_state, server_tick, server_state, exact, position, velocity}[/code], donde los estados
## son los bytes de [method PlayerState.encode] en hexadecimal y [code]exact[/code] dice si el
## estado predicho para el último tick del servidor es idéntico al suyo.
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


# --- Bucle del tick (6.2) ---------------------------------------------------------------------

func _physics_process(_delta: float) -> void:
	_local_tick += 1
	_transport.poll(_local_tick)
	if _state == State.IN_WORLD:
		_reconcile_latest()
		var steps: int = _tick_sync.next_steps(_prediction.get_predicted_tick())
		if steps > 2:
			_resyncs += 1
			_remember(_resync_ticks, _local_tick)
		if steps == 0:
			_controller.accumulate_presses()
		for _i: int in steps:
			var tick: int = _prediction.get_predicted_tick() + 1
			_view_offsets_q[tick % ClientPrediction.HISTORY_SIZE] = _view_offset_q(tick)
			_prediction.step()
		_send_input_batch()
	_interp_clock.advance(_local_tick)
	_smoother.physics_step()
	_transport.flush()


# Reconcilia con el snapshot más nuevo que no se haya reconciliado ya (los desordenados no).
func _reconcile_latest() -> void:
	var snapshot: NetMessages.Snapshot = _latest
	_latest = null
	if snapshot == null or snapshot.server_tick <= _last_snapshot_tick:
		return
	_last_snapshot_tick = snapshot.server_tick
	_tick_sync.set_jitter(_interp_clock.get_jitter_ticks())
	_tick_sync.on_snapshot(snapshot.input_ack_tick, snapshot.input_margin)
	_input_ack_tick = maxi(_input_ack_tick, snapshot.input_ack_tick)
	_last_input_margin = snapshot.input_margin
	var substitutions_rose: bool = _note_substitutions(snapshot.substitutions)
	if snapshot.own_state == null:
		return
	_snapshots_with_state += 1
	var teleported: bool = snapshot.own_teleport != _own_teleport
	_own_teleport = snapshot.own_teleport
	var logging: bool = _open_state_log()
	var predicted_hex: String = ""
	if logging:
		var predicted: PlayerState = _prediction.get_predicted_state(snapshot.server_tick)
		if predicted != null:
			predicted_hex = predicted.encode().hex_encode()
	var result: int = _prediction.on_server_state(snapshot.server_tick, snapshot.own_state,
			teleported)
	_record_result(result, substitutions_rose, teleported)
	_last_server_state = snapshot.own_state
	if logging:
		_state_log.store_line("%d,%s,%s" % [snapshot.server_tick, predicted_hex,
				snapshot.own_state.encode().hex_encode()])
		_state_log.flush()


# Apunta qué hizo la predicción con el estado del servidor. Una diferencia se da por explicada si
# coincide con una subida del contador de sustituciones del servidor (una entrada perdida o tardía)
# o con un teletransporte; si no, es un fallo de la predicción.
func _record_result(result: int, substitutions_rose: bool, teleported: bool) -> void:
	_last_result = result
	match result:
		ClientPrediction.Result.MATCH:
			_consecutive_matches += 1
			return
		ClientPrediction.Result.CORRECTED:
			_diffs += 1
			if teleported:
				_teleport_diffs += 1
				_explained_diffs += 1
			elif substitutions_rose:
				_explained_diffs += 1
			else:
				_unexplained_diffs += 1
				_remember(_unexplained_ticks, _local_tick)
		ClientPrediction.Result.HARD_RESET:
			_remember(_hard_reset_ticks, _local_tick)
	_consecutive_matches = 0


# Contador de entradas sustituidas del servidor (módulo 65536, acumulado). Devuelve true si subió
# desde el último snapshot reconciliado, y en ese caso pasa a enviar con redundancia R = 8 durante
# un rato.
func _note_substitutions(value: int) -> bool:
	if _server_substitutions < 0:
		_server_substitutions = value
		return false
	var rise: int = (value - _server_substitutions) & 0xFFFF
	_server_substitutions = value
	if rise == 0:
		return false
	_substitution_rises += 1
	_substitutions_total += rise
	_lossy_until_tick = _local_tick + LOSSY_WINDOW_TICKS
	return true


# --- Entradas ---------------------------------------------------------------------------------

# INPUT_BATCH de 5.4. Se envía una vez por tick de física, también en los ticks de 0 pasos.
func _send_input_batch() -> void:
	var newest: int = _prediction.get_predicted_tick()
	var first_real: int = _prediction.get_first_real_tick()
	if newest < first_real:
		return
	var redundancy: int = NetProtocol.INPUT_REDUNDANCY
	if _is_lossy():
		redundancy = NetProtocol.INPUT_REDUNDANCY_LOSSY
	var oldest: int = maxi(maxi(_input_ack_tick + 1, newest - redundancy + 1), first_real)
	oldest = mini(oldest, newest)
	var batch := NetMessages.InputBatch.new()
	batch.ack_snapshot_tick = _newest_snapshot_tick
	batch.interp_delay_q = clampi(roundi(_interp_clock.get_delay_ticks() * INTERP_DELAY_SCALE),
			0, 255)
	batch.newest_tick = newest
	for tick: int in range(oldest, newest + 1):
		var input: PlayerInput = _prediction.get_input(tick)
		if input == null:
			# Un hueco en el anillo: solo valen las entradas seguidas hasta newest.
			batch.inputs.clear()
			batch.view_offsets_q.clear()
			continue
		batch.inputs.append(input)
		batch.view_offsets_q.append(_view_offsets_q[tick % ClientPrediction.HISTORY_SIZE])
	if batch.inputs.is_empty():
		return
	var bytes: PackedByteArray = batch.encode()
	if bytes.is_empty():
		return
	if _transport.send(SERVER_PEER_ID, NetProtocol.CH_INPUT, bytes) == OK:
		_batches_sent += 1
	if _cheater != null:
		for extra: BotCheater.Extra in _cheater.extra_packets(batch):
			if _transport.send(SERVER_PEER_ID, extra.channel, extra.bytes) == OK:
				_cheat_packets_sent += 1


# true si hay que enviar con R = 8: subieron las sustituciones hace poco o ENet mide pérdida.
func _is_lossy() -> bool:
	if _local_tick - _loss_sampled_tick >= LOSS_SAMPLE_TICKS:
		_loss_sampled_tick = _local_tick
		_high_loss = _transport.get_packet_loss(SERVER_PEER_ID) > LOSS_THRESHOLD
	return _high_loss or _local_tick < _lossy_until_tick


# Desfase de la vista del input del tick [param tick]: (tick - render_tick visto) × 16, entre 0 y
# 65535. Antes de que el reloj de interpolación arranque (render_tick = 0) no hay vista que medir.
func _view_offset_q(tick: int) -> int:
	var drawn: float = _remote_world.get_last_drawn_render_tick()
	if drawn <= 0.0:
		return 0
	return clampi(roundi((float(tick) - drawn) * VIEW_OFFSET_SCALE), 0,
			NetMessages.MAX_VIEW_OFFSET_Q)


# --- Conexión ---------------------------------------------------------------------------------

func _connect_transport() -> void:
	_transport.peer_authenticating.connect(_on_peer_authenticating)
	_transport.auth_received.connect(_on_auth_received)
	_transport.peer_connected.connect(_on_peer_connected)
	_transport.peer_disconnected.connect(_on_peer_disconnected)
	_transport.packet_received.connect(_on_packet_received)
	_transport.connection_failed.connect(_on_connection_failed)


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
	if _transport.connection_failed.is_connected(_on_connection_failed):
		_transport.connection_failed.disconnect(_on_connection_failed)


# ENet ha conectado y empieza la autenticación: HELLO.
func _on_peer_authenticating(peer_id: int) -> void:
	if peer_id != SERVER_PEER_ID or _state != State.CONNECTING:
		return
	var hello := NetMessages.Hello.new()
	hello.protocol_version = NetProtocol.PROTOCOL_VERSION
	hello.sim_hash = _sim_hash
	hello.realm = _config.realm
	if _config.mode == ClientConfig.Mode.BOT:
		hello.flags |= NetMessages.Hello.FLAG_BOT
	hello.display_name = _config.display_name
	if _cheater != null:
		_cheater.tamper_hello(hello)
	if hello_hook.is_valid():
		hello_hook.call(hello)
	_hello_local_tick = _local_tick
	if _transport.send_auth(SERVER_PEER_ID, hello.encode()) != OK:
		_close_session(TEXT_CONNECTION_LOST)
		return
	_state = State.HELLO_SENT


# WELCOME o REJECT.
func _on_auth_received(peer_id: int, bytes: PackedByteArray) -> void:
	if peer_id != SERVER_PEER_ID or _state != State.HELLO_SENT:
		return
	var kind: int = NetMessages.peek_auth_result(bytes)
	if kind > 0:
		var reject: NetMessages.Reject = NetMessages.Reject.decode(bytes)
		if reject == null:
			_close_session(TEXT_BAD_REPLY)
			return
		_rejected = true
		_reject_result = reject.result
		_reject_text = reject.text
		_state = State.CLOSED
		_transport.close()
		set_physics_process(false)
		rejected.emit(reject.result, reject.text)
		return
	var welcome: NetMessages.Welcome = NetMessages.Welcome.decode(bytes) if kind == 0 else null
	if welcome == null:
		_close_session(TEXT_BAD_REPLY)
		return
	_rtt_hello_ticks = maxi(_local_tick - _hello_local_tick, 0)
	if welcome.protocol_version != NetProtocol.PROTOCOL_VERSION:
		_close_session(TEXT_BAD_VERSION)
		return
	if welcome.tick_rate != Engine.physics_ticks_per_second:
		_close_session(TEXT_BAD_TICK_RATE % [welcome.tick_rate, Engine.physics_ticks_per_second])
		return
	_welcome = welcome
	if _transport.complete_auth(SERVER_PEER_ID) != OK:
		_close_session(TEXT_CONNECTION_LOST)


# Autenticación completada en los dos lados: ya se puede enviar.
func _on_peer_connected(peer_id: int) -> void:
	if peer_id != SERVER_PEER_ID or _state != State.HELLO_SENT or _welcome == null:
		return
	_state = State.WELCOMED
	welcomed.emit(_welcome)


func _on_peer_disconnected(peer_id: int) -> void:
	if peer_id != SERVER_PEER_ID or _state == State.CLOSED:
		return
	if _state == State.LEAVING:
		_close_session(TEXT_LEFT)
	elif not _last_notice_text.is_empty():
		_close_session(_last_notice_text)
	else:
		_close_session(TEXT_CONNECTION_LOST)


func _on_connection_failed() -> void:
	if _state == State.CLOSED or _rejected:
		return
	_close_session(TEXT_CONNECT_FAILED % [_config.address, _config.port])


# Termina la sesión: ya no se simula ni se envía, y se avisa una sola vez.
func _close_session(text: String) -> void:
	if _state == State.CLOSED:
		return
	_state = State.CLOSED
	_last_disconnect_text = text
	if is_instance_valid(_transport):
		_transport.close()
	set_physics_process(false)
	disconnected.emit(text)


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
			var despawn: NetMessages.EntityDespawn = NetMessages.EntityDespawn.decode(bytes)
			if despawn == null:
				_malformed_packets += 1
			else:
				_remote_world.on_despawn(despawn)
		NetProtocol.MSG_NOTICE:
			var notice: NetMessages.Notice = NetMessages.Notice.decode(bytes)
			if notice == null:
				_malformed_packets += 1
			else:
				_last_notice_text = notice.text
				notice_received.emit(notice.code, notice.text)
		_:
			_malformed_packets += 1


# Un SNAPSHOT alimenta siempre al reloj de interpolación y a los remotos; el más nuevo se guarda
# para reconciliar en el siguiente paso del tick.
func _on_snapshot(bytes: PackedByteArray) -> void:
	var snapshot: NetMessages.Snapshot = NetMessages.Snapshot.decode(bytes)
	if snapshot == null:
		_malformed_packets += 1
		return
	_snapshots_received += 1
	if snapshot.server_tick < _newest_snapshot_tick:
		_snapshots_late += 1
	_newest_snapshot_tick = maxi(_newest_snapshot_tick, snapshot.server_tick)
	_interp_clock.on_snapshot(snapshot.server_tick, _local_tick)
	_remote_world.on_snapshot(snapshot)
	if _latest == null or snapshot.server_tick > _latest.server_tick:
		_latest = snapshot


func _on_spawn(bytes: PackedByteArray) -> void:
	var spawn: NetMessages.EntitySpawn = NetMessages.EntitySpawn.decode(bytes)
	if spawn == null:
		_malformed_packets += 1
		return
	if spawn.is_yours:
		_on_own_spawn(spawn)
	else:
		_remote_world.on_spawn(spawn)


# SPAWN propio (sección 3, punto 5): arranca la predicción con el estado de aparición.
func _on_own_spawn(spawn: NetMessages.EntitySpawn) -> void:
	if _state != State.READY_SENT:
		push_warning("[Eldmark] ENTITY_SPAWN propio inesperado (estado %s)" % State.keys()[_state])
		return
	_rtt_ticks = maxi(mini(_rtt_hello_ticks, _local_tick - _ready_local_tick), 0)
	var first_real_tick: int = _tick_sync.start(spawn.spawn_tick, _rtt_ticks)
	var character: PlayerCharacter = _instantiate_character()
	if character == null:
		_close_session(TEXT_BAD_REPLY)
		return
	if not is_instance_valid(_world_root):
		character.free()
		_close_session(TEXT_CONNECTION_LOST)
		return
	character.name = "LocalPlayer"
	_world_root.add_child(character)
	_character = character
	_net_id = spawn.net_id
	_spawn_tick = spawn.spawn_tick
	_own_teleport = spawn.teleport_counter
	_controller.auto_step = false
	_controller.setup(character, null)
	var targets: Array[Node3D] = []
	var visual: Node3D = character.get_node_or_null(^"Visual") as Node3D
	if visual != null:
		targets.append(visual)
	targets.append(character.get_camera_target())
	_smoother.setup(character, targets)
	_prediction.setup(character, _controller, _smoother,
			1.0 / float(Engine.physics_ticks_per_second))
	_prediction.start(spawn.spawn_tick, spawn.state, first_real_tick)
	_state = State.IN_WORLD
	local_spawned.emit(character)


# --- Auxiliares -------------------------------------------------------------------------------

func _instantiate_character() -> PlayerCharacter:
	var scene: PackedScene = load(PLAYER_SCENE_PATH) as PackedScene
	if scene == null:
		push_error("[Eldmark] No se pudo cargar la escena %s" % PLAYER_SCENE_PATH)
		return null
	return scene.instantiate() as PlayerCharacter


# El bot tramposo de [param config], o null si no hay trampa que hacer. Solo los bots hacen trampa;
# un modo desconocido se avisa y el bot juega limpio.
func _make_cheater(config: ClientConfig) -> BotCheater:
	if config.bot_cheat.is_empty():
		return null
	if config.mode != ClientConfig.Mode.BOT:
		push_warning("[Eldmark] --bot-cheat solo tiene efecto junto con --bot; se juega limpio")
		return null
	if not BotCheater.is_valid_mode(config.bot_cheat):
		push_warning("[Eldmark] Modo de --bot-cheat desconocido '%s' (hay: %s); se juega limpio"
				% [config.bot_cheat, ", ".join(BotCheater.MODES)])
		return null
	print("[Eldmark] Bot tramposo: modo '%s'" % config.bot_cheat)
	return BotCheater.new(config.bot_cheat, config.bot_seed)


# Huella de la simulación (sección 3), calculada sobre una instancia dentro del árbol después de
# _ready().
func _compute_sim_hash() -> int:
	var character: PlayerCharacter = _instantiate_character()
	if character == null:
		return 0
	add_child(character)
	var hash_value: int = NetProtocol.compute_sim_hash(character)
	remove_child(character)
	character.free()
	return hash_value


# Añade un elemento a una lista de sucesos recordados sin pasar de MAX_REMEMBERED_EVENTS.
func _remember(list: Array[int], value: int) -> void:
	if list.size() < MAX_REMEMBERED_EVENTS:
		list.append(value)


# Abre el registro de estados ([member ClientConfig.state_log_path]) la primera vez que hace falta.
# Devuelve true si hay un registro abierto en el que escribir.
func _open_state_log() -> bool:
	if _state_log != null:
		return true
	if _state_log_failed or _config.state_log_path.is_empty():
		return false
	var directory: String = _config.state_log_path.get_base_dir()
	if not directory.is_empty() and not DirAccess.dir_exists_absolute(directory):
		DirAccess.make_dir_recursive_absolute(directory)
	_state_log = FileAccess.open(_config.state_log_path, FileAccess.WRITE)
	if _state_log == null:
		_state_log_failed = true
		push_warning("[Eldmark] No se pudo abrir el registro de estados '%s' (error %d)"
				% [_config.state_log_path, FileAccess.get_open_error()])
		return false
	return true


func _close_state_log() -> void:
	if _state_log != null:
		_state_log.close()
		_state_log = null


func _build_report() -> Dictionary:
	var report: Dictionary = get_stats()
	report["version"] = 1
	report["name"] = _config.display_name if _config != null else ""
	report["realm"] = NetProtocol.realm_display_name(_config.realm) if _config != null else ""
	report["mode"] = ClientConfig.Mode.keys()[_config.mode] if _config != null else ""
	report["address"] = _config.address if _config != null else ""
	report["port"] = _config.port if _config != null else 0
	report["net_sim"] = _config.net_sim_spec if _config != null else ""
	report["seed"] = _config.bot_seed if _config != null else 0
	report["zone"] = _welcome.zone_id if _welcome != null else ""
	report["net_id"] = _net_id
	report["state"] = State.keys()[_state]
	report["cheat"] = _cheater.get_mode() if _cheater != null else ""
	report["rejected"] = _rejected
	report["reject_result"] = _reject_result
	report["reject_text"] = _reject_text
	report["disconnect_text"] = _last_disconnect_text
	var final_state: Dictionary = {
		"predicted_tick": _prediction.get_predicted_tick(),
		"server_tick": _last_snapshot_tick,
	}
	if _character != null and is_instance_valid(_character):
		var predicted_now: PlayerState = _character.get_state()
		final_state["predicted_state"] = predicted_now.encode().hex_encode()
		final_state["position"] = [predicted_now.position.x, predicted_now.position.y,
				predicted_now.position.z]
		final_state["velocity"] = [predicted_now.velocity.x, predicted_now.velocity.y,
				predicted_now.velocity.z]
	if _last_server_state != null:
		final_state["server_state"] = _last_server_state.encode().hex_encode()
		var at_server_tick: PlayerState = _prediction.get_predicted_state(_last_snapshot_tick)
		final_state["exact"] = at_server_tick != null \
				and at_server_tick.equals_exact(_last_server_state)
	report["final"] = final_state
	return report
