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
## [b]Combate[/b] (docs/combate.md, secciones 5 y 6): de cada snapshot con estado propio se guarda el
## bloque extra (vida, vida máxima, estado y tick de reaparición; ver [method get_health]) y los
## ENTITY_EVENT se reparten por [signal combat_event]. Un evento [b]propio[/b] (el jugador local es
## atacante, víctima, asesino o asistente) se entrega nada más llegar; los demás esperan en un
## [CombatEventQueue] hasta que el tick de dibujo ([InterpolationClock]) alcanza su tick, para que la
## reacción visual de un remoto (destello, animación) coincida con lo que se ve. [method
## send_respawn_request] pide la reaparición tras morir.
## [br][br]
## [b]Fuerte[/b] (docs/fuerte.md, secciones 2, 3.2, 5 y 6; protocolo 4): el ENTITY_SPAWN de una estructura
## y los OBJECT_STATE los guarda [FortressView] (historia de cambios), que aplica la interfaz y los
## estandartes cuando el tick de dibujo alcanza el del mensaje y da la capa de la puerta de cada tick
## simulado por el gancho [member ClientPrediction.before_simulate], también en las repeticiones. Los
## avisos de guerra (WAR) esperan en su propia cola a su tick de dibujo ([signal war_event]); los
## TELEGRAPH se entregan al llegar ([signal telegraph_received]). El SCOREBOARD se junta por páginas en un
## [ScoreboardState] ([signal scoreboard_updated]) y [PlayerDirectory] recuerda nombre y reino de cada
## entidad vista, porque el marcador y los KILL de toda la zona solo llevan ids.
## [br][br]
## [b]Proyectiles[/b] (docs/habilidades.md, sección 5.3; protocolo 6): el ENTITY_SPAWN se reparte por
## [code]kind[/code] antes de mirar [code]is_yours[/code] (que en un proyectil siempre es 0: la flecha
## propia es la de [code]owner_id[/code] igual al [code]net_id[/code] local). Los de kind 3 no son
## personajes: salen por [signal projectile_spawned] y su ENTITY_DESPAWN por [signal projectile_despawned].
## [br][br]
## [b]Bot tramposo[/b] ([member ClientConfig.bot_cheat], solo en modo BOT): un [BotCheater] falsea
## el HELLO ([code]version[/code]), envía tráfico de más tras el lote honrado de cada tick
## ([code]future[/code], [code]dupes[/code], [code]garbage[/code], [code]flood[/code]) o falsea la vista
## que declara en sus entradas ([code]rewind[/code]; los modos [code]reach[/code] y [code]rate[/code]
## solo cambian cómo juega, con el cerebro de [method BotCheater.make_brain]). El bot sigue prediciendo
## con sus entradas honradas; lo que se comprueba es que el servidor no se deja.

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
## Un ENTITY_EVENT listo para mostrarse. Si [param is_own], el jugador local interviene (atacante,
## víctima, asesino o asistente) y se entrega al llegar; si no, cuando el tick de dibujo alcanza
## [code]event.tick[/code].
signal combat_event(event: NetMessages.EntityEvent, is_own: bool)
## Un aviso de guerra (WAR) de una fortaleza, ya en su tick de dibujo (docs/fuerte.md, sección 5). El
## texto sale de [method WarEvents.text] con [member NetMessages.EntityEvent.war_event] y
## [member NetMessages.EntityEvent.war_realm].
signal war_event(event: NetMessages.EntityEvent)
## Un TELEGRAPH (el PNJ [code]event.net_id[/code] prepara un ataque): se entrega al llegar, es un aviso.
signal telegraph_received(event: NetMessages.EntityEvent)
## Se ha publicado un marcador completo (todas sus páginas): ver [method get_scoreboard].
signal scoreboard_updated(scoreboard: ScoreboardState)
## Ha llegado un mensaje de chat (CHAT_MESSAGE, protocolo 5) ya saneado por el servidor. Se entrega al
## llegar: el chat no se temporiza con el tick de dibujo.
signal chat_received(message: NetMessages.ChatMessage)
## Ha llegado el ENTITY_SPAWN de un proyectil (kind 3, protocolo 6): balística, tirador y fuente. Se entrega
## al llegar; quien la dibuja decide cuándo se ve (la propia la sustituye, la remota espera a su tick).
signal projectile_spawned(spawn: NetMessages.EntitySpawn)
## Ha llegado el ENTITY_DESPAWN de un proyectil conocido: [param reason] es
## [constant NetProtocol.DespawnReason.IMPACT] (dio en algo en [param tick]) o
## [constant NetProtocol.DespawnReason.EXPIRED].
signal projectile_despawned(projectile_id: int, tick: int, reason: int)

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
## Una corrección de la predicción se da por explicada por un evento de combate propio (un golpe recibido
## o parado, una muerte, una reaparición: el servidor impone tambaleo, aturdimiento, empuje, resistencia
## gastada...) si el snapshot que la causó es del tick del evento o de los [constant COMBAT_EXPLAIN_TICKS]
## siguientes (los snapshots salen cada 2 ticks y alguno se pierde).
const COMBAT_EXPLAIN_TICKS: int = 12
## Ticks locales que se espera, antes de dar una diferencia por definitiva, a que llegue el evento que la
## explique: el ENTITY_EVENT va por el canal fiable y puede llegar después del snapshot.
const DIFF_SETTLE_TICKS: int = 90
## Eventos propios y diferencias pendientes que se recuerdan como mucho.
const MAX_TRACKED_DIFFS: int = 256
## Vida máxima que se supone mientras no ha llegado el bloque extra del snapshot.
const DEFAULT_MAX_HEALTH: int = 1000
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
## Gancho de pruebas: se llama con el [NetMessages.InputBatch] de cada tick justo antes de codificarlo y
## puede modificarlo (por ejemplo, falsear los [code]view_offsets_q[/code] del rebobinado). Lo mismo que
## hace el modo [code]rewind[/code] del bot tramposo ([BotCheater]), pero a medida para una prueba.
var batch_hook: Callable = Callable()
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
var _newest_snapshot_local_tick: int = 0

# Combate: bloque extra propio del último snapshot reconciliado y cola de eventos ajenos.
var _health: int = DEFAULT_MAX_HEALTH
var _max_health: int = DEFAULT_MAX_HEALTH
var _status: int = 0
var _respawn_tick: int = 0
var _has_extra: bool = false
var _event_queue: CombatEventQueue = CombatEventQueue.new()
var _events_received: int = 0
var _events_own: int = 0
var _respawn_requests: int = 0

# Fuerte (fase 4): vista de las fortalezas, avisos de guerra a la espera de su tick de dibujo, marcador y
# memoria de quién es cada id.
var _fortress_view: FortressView = FortressView.new()
var _war_queue: CombatEventQueue = CombatEventQueue.new()
var _scoreboard: ScoreboardState = ScoreboardState.new()
var _directory: PlayerDirectory = PlayerDirectory.new()
var _structure_spawns_received: int = 0
# Proyectiles (protocolo 6): ids de los que han llegado con SPAWN y aún no se han ido.
var _projectile_ids: Dictionary[int, bool] = {}
var _projectile_spawns_received: int = 0
var _object_states_received: int = 0
var _scoreboards_received: int = 0
var _war_events_received: int = 0
var _telegraphs_received: int = 0
var _chat_sent: int = 0
var _chat_received: int = 0
var _party: PartyState = PartyState.new()
var _party_messages_sent: int = 0
var _party_rosters: int = 0
var _party_statuses: int = 0
var _party_invitations: int = 0

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
var _combat_diffs: int = 0
var _teleport_diffs: int = 0
var _consecutive_matches: int = 0
var _last_result: int = ClientPrediction.Result.IGNORED
var _resyncs: int = 0
var _hard_reset_ticks: Array[int] = []
var _resync_ticks: Array[int] = []
var _unexplained_ticks: Array[int] = []
# Diferencias que ni una sustitución ni un teletransporte explican, a la espera de que llegue el evento
# de combate que las explique: (tick del servidor del snapshot, tick local en que se vio).
var _pending_diffs: Array[Vector2i] = []
# Ticks del servidor de los eventos de combate propios que imponen estado (golpe recibido, parada,
# muerte, reaparición).
var _imposed_ticks: PackedInt64Array = PackedInt64Array()

var _state_log: FileAccess = null
var _state_log_failed: bool = false


func _init() -> void:
	name = "NetClient"
	process_physics_priority = -100
	_view_offsets_q.resize(ClientPrediction.HISTORY_SIZE)
	_view_offsets_q.fill(0)
	_remote_world.setup(_interp_clock)
	_fortress_view.setup(_interp_clock)
	# La puerta del fuerte que tenía cada tick simulado, también en las repeticiones (fuerte.md, 3.2).
	_prediction.before_simulate = _fortress_view.before_simulate


func _ready() -> void:
	if _fortress_view.get_parent() == null:
		add_child(_fortress_view)
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
		if is_instance_valid(_fortress_view) and _fortress_view.get_parent() == null:
			_fortress_view.free()


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


## Pide reaparecer en el punto [param point_index] de la lista de puntos del reino (RESPAWN_REQUEST,
## docs/combate.md sección 5). Solo tiene sentido muerto y pasado el [method get_respawn_tick]: el
## servidor ignora (con un aviso) lo que llega fuera de plazo. Devuelve false si no hay sesión en el
## mundo o no se pudo enviar.
func send_respawn_request(point_index: int) -> bool:
	if _state != State.IN_WORLD:
		return false
	var request := NetMessages.RespawnRequest.new()
	request.point_index = clampi(point_index, 0, 255)
	if _transport.send(SERVER_PEER_ID, NetProtocol.CH_RELIABLE, request.encode()) != OK:
		return false
	_respawn_requests += 1
	return true


## Envía un mensaje de chat (CHAT_SEND, protocolo 5) por [param channel] ([enum ChatChannel.Id]). En un
## susurro [param recipient] es el nombre del destinatario; en los demás canales se ignora. El texto se
## sanea con [ChatText] antes de enviarlo (lo mismo que hará el servidor) y se recorta a sus límites.
## Devuelve false, sin enviar nada, si no hay sesión en el mundo, el canal no se puede enviar, el texto
## queda vacío o falta el destinatario de un susurro.
func send_chat(channel: int, recipient: String, text: String) -> bool:
	if _state != State.IN_WORLD or not ChatChannel.is_client_sendable(channel):
		return false
	var cleaned: String = ChatText.sanitize(text)
	var target: String = ChatText.clean(recipient) if channel == ChatChannel.Id.WHISPER else ""
	if cleaned.is_empty() or (channel == ChatChannel.Id.WHISPER and target.is_empty()):
		return false
	var message := NetMessages.ChatSend.new()
	message.channel = channel
	message.recipient = target
	message.text = cleaned
	if _transport.send(SERVER_PEER_ID, NetProtocol.CH_RELIABLE, message.encode()) != OK:
		return false
	_chat_sent += 1
	return true


## Invita a [param target_name], un jugador de tu reino, a tu grupo (PARTY_INVITE). El servidor decide y
## contesta por el canal del sistema del chat. Devuelve false si no hay sesión en el mundo o el nombre no vale.
func send_party_invite(target_name: String) -> bool:
	return _send_party_target(NetProtocol.MSG_PARTY_INVITE, target_name)


## Expulsa a [param target_name] del grupo (PARTY_KICK; solo vale si eres el líder).
func send_party_kick(target_name: String) -> bool:
	return _send_party_target(NetProtocol.MSG_PARTY_KICK, target_name)


## Cede el mando del grupo a [param target_name] (PARTY_LEADER; solo vale si eres el líder).
func send_party_leader(target_name: String) -> bool:
	return _send_party_target(NetProtocol.MSG_PARTY_LEADER, target_name)


## Acepta o rechaza la invitación de [param inviter] (PARTY_RESPONSE) y la quita de las pendientes. Devuelve
## false si no hay sesión en el mundo o el nombre no vale.
func send_party_response(inviter: String, accept: bool) -> bool:
	var response := NetMessages.PartyResponse.new()
	response.accept = accept
	response.inviter = ChatText.clean(inviter)
	var bytes: PackedByteArray = response.encode()
	if _state != State.IN_WORLD or NetMessages.PartyResponse.decode(bytes) == null:
		return false
	if _transport.send(SERVER_PEER_ID, NetProtocol.CH_RELIABLE, bytes) != OK:
		return false
	_party_messages_sent += 1
	_party.remove_invitation(inviter)
	return true


## Sale del grupo (PARTY_LEAVE). Devuelve false si no hay sesión en el mundo.
func send_party_leave() -> bool:
	if _state != State.IN_WORLD:
		return false
	if _transport.send(SERVER_PEER_ID, NetProtocol.CH_RELIABLE, NetMessages.PartyLeave.new().encode()) != OK:
		return false
	_party_messages_sent += 1
	return true


## Vida del jugador local según el último snapshot reconciliado (vida máxima por defecto hasta que
## llega el primer bloque extra). La vida la decide el servidor: no se predice.
func get_health() -> int:
	return _health


func get_max_health() -> int:
	return _max_health


## true si ya ha llegado al menos un bloque extra (la vida mostrada es la del servidor).
func has_health() -> bool:
	return _has_extra


## Bits [constant NetMessages.STATUS_IN_COMBAT], [constant NetMessages.STATUS_PROTECTED] y
## [constant NetMessages.STATUS_DEAD] del último bloque extra.
func get_status() -> int:
	return _status


func is_dead() -> bool:
	return (_status & NetMessages.STATUS_DEAD) != 0


func is_in_combat() -> bool:
	return (_status & NetMessages.STATUS_IN_COMBAT) != 0


func is_protected() -> bool:
	return (_status & NetMessages.STATUS_PROTECTED) != 0


## Tick del servidor en el que se puede pedir la reaparición (0 si el jugador está vivo).
func get_respawn_tick() -> int:
	return _respawn_tick


## Estimación del tick actual del servidor: el del último snapshot más los ticks locales que han
## pasado desde que llegó. Va por detrás del servidor real lo que tarda un snapshot en llegar
## (medio RTT), y eso es lo que conviene a la cuenta atrás de la reaparición: cuando la cuenta llega
## a 0 la petición, que tarda otro medio RTT, ya llega a tiempo.
func get_estimated_server_tick() -> int:
	if _newest_snapshot_tick <= 0:
		return 0
	return _newest_snapshot_tick + maxi(_local_tick - _newest_snapshot_local_tick, 0)


## Tick del último snapshot con estado propio que se reconcilió (0 si aún no ha llegado ninguno).
func get_last_snapshot_tick() -> int:
	return _last_snapshot_tick


## Eventos de combate ajenos que esperan a que el tick de dibujo alcance su tick.
func get_combat_queue() -> CombatEventQueue:
	return _event_queue


## true si el jugador local interviene en [param event]: atacante o víctima de un HIT, víctima o
## asesino de un DEATH, víctima, asesino o asistente de un KILL, o quien reaparece en un RESPAWN; y desde
## el protocolo 6 (docs/habilidades.md, sección 5.4), el afectado o el autor de un STATUS, el curado o quien
## cura en un HEAL, el dueño de un LOADOUT, el derribado o quien derriba en un DOWNED, y el derribado o
## quien lo levanta o lo remata en un INTERACT. Falso mientras no hay personaje local.
func is_own_event(event: NetMessages.EntityEvent) -> bool:
	if _net_id == 0 or event == null:
		return false
	match event.event:
		NetMessages.EntityEvent.Kind.HIT, NetMessages.EntityEvent.Kind.DOWNED:
			return event.net_id == _net_id or event.attacker == _net_id
		NetMessages.EntityEvent.Kind.DEATH:
			return event.net_id == _net_id or event.killer == _net_id
		NetMessages.EntityEvent.Kind.KILL:
			return event.net_id == _net_id or event.killer == _net_id \
					or event.assistants.has(_net_id)
		NetMessages.EntityEvent.Kind.RESPAWN, NetMessages.EntityEvent.Kind.LOADOUT:
			return event.net_id == _net_id
		NetMessages.EntityEvent.Kind.STATUS:
			return event.net_id == _net_id or event.source_entity == _net_id
		NetMessages.EntityEvent.Kind.HEAL:
			return event.net_id == _net_id or event.healer == _net_id
		NetMessages.EntityEvent.Kind.INTERACT:
			return event.net_id == _net_id or event.actor == _net_id
	return false


## Personaje local (null hasta [signal local_spawned]).
func get_character() -> PlayerCharacter:
	return _character


func get_prediction() -> ClientPrediction:
	return _prediction


func get_remote_world() -> RemoteWorld:
	return _remote_world


## Vista de las fortalezas (estado replicado, estandartes y la puerta de la predicción).
func get_fortress_view() -> FortressView:
	return _fortress_view


## Marcador de la zona (el último completo).
func get_scoreboard() -> ScoreboardState:
	return _scoreboard


## Nombre y reino de cada entidad vista (el marcador y los KILL solo llevan ids).
## Lo que se sabe del grupo del jugador local: miembros, líder, estado a 2 Hz e invitaciones (SOC-06).
func get_party() -> PartyState:
	return _party


func get_directory() -> PlayerDirectory:
	return _directory


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


## El bot tramposo de esta sesión (null si juega limpio o no es un bot).
func get_cheater() -> BotCheater:
	return _cheater


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
## [code]substitutions[/code], un teletransporte o un evento de combate propio),
## [code]combat_diffs[/code] (las explicadas por el combate: lo que impone el servidor y el cliente no
## predice), [code]unexplained_diffs[/code] (las demás: fallos de la predicción),
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
## [br]- [code]combat_events[/code] recibidos, [code]combat_events_own[/code] (los propios),
## [code]combat_events_pending[/code] (esperando a su tick de dibujo), [code]respawn_requests[/code],
## [code]health[/code] y [code]max_health[/code].
## [br]- [code]projectile_spawns[/code]: ENTITY_SPAWN de proyectiles recibidos (protocolo 6).
## [br]- [code]structure_spawns[/code], [code]object_states[/code], [code]scoreboards[/code],
## [code]war_events[/code] y [code]telegraphs[/code]: mensajes del protocolo 4 recibidos;
## [code]war_events_pending[/code] (avisos de guerra esperando a su tick de dibujo) y
## [code]fortress_hook_calls[/code] (veces que la predicción preguntó por la puerta).
## [br]- [code]chat_sent[/code] y [code]chat_received[/code]: mensajes de chat enviados y recibidos.
## [br]- [code]party_sent[/code] (peticiones de grupo enviadas) y [code]party_rosters[/code],
## [code]party_statuses[/code] y [code]party_invitations[/code]: mensajes de grupo recibidos.
func get_stats() -> Dictionary:
	var prediction_stats: Dictionary = _prediction.get_stats()
	# Las diferencias que aún esperan su evento cuentan ya, según lo que se sepa ahora.
	var provisional_combat: int = 0
	var provisional_unexplained: int = 0
	var unexplained_ticks: Array[int] = _unexplained_ticks.duplicate()
	for pending: Vector2i in _pending_diffs:
		if _is_imposed_at(pending.x):
			provisional_combat += 1
		else:
			provisional_unexplained += 1
			if unexplained_ticks.size() < MAX_REMEMBERED_EVENTS:
				unexplained_ticks.append(pending.y)
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
		"explained_diffs": _explained_diffs + provisional_combat,
		"combat_diffs": _combat_diffs + provisional_combat,
		"unexplained_diffs": _unexplained_diffs + provisional_unexplained,
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
		"unexplained_ticks": unexplained_ticks,
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
		"combat_events": _events_received,
		"combat_events_own": _events_own,
		"combat_events_pending": _event_queue.size(),
		"respawn_requests": _respawn_requests,
		"structure_spawns": _structure_spawns_received,
		"projectile_spawns": _projectile_spawns_received,
		"object_states": _object_states_received,
		"scoreboards": _scoreboards_received,
		"war_events": _war_events_received,
		"telegraphs": _telegraphs_received,
		"chat_sent": _chat_sent,
		"chat_received": _chat_received,
		"party_sent": _party_messages_sent,
		"party_rosters": _party_rosters,
		"party_statuses": _party_statuses,
		"party_invitations": _party_invitations,
		"war_events_pending": _war_queue.size(),
		"fortress_hook_calls": int(_fortress_view.get_stats()["hook_calls"]),
		"health": _health,
		"max_health": _max_health,
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
	_settle_pending_diffs()
	_interp_clock.advance(_local_tick)
	_fortress_view.advance(_interp_clock.get_render_tick())
	_deliver_due_events()
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
	_apply_extra_block(snapshot)
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


# Bloque extra propio del snapshot (vida, vida máxima, estado y tick de reaparición). Llega con
# todos los snapshots que traen el estado propio.
func _apply_extra_block(snapshot: NetMessages.Snapshot) -> void:
	_has_extra = true
	_health = snapshot.health
	_max_health = snapshot.max_health
	_status = snapshot.status
	_respawn_tick = snapshot.respawn_tick


# Entrega los eventos ajenos cuyo tick ya alcanzó el tick de dibujo.
func _deliver_due_events() -> void:
	if _war_queue.size() > 0:
		for war: NetMessages.EntityEvent in _war_queue.pop_due(_interp_clock.get_render_tick()):
			war_event.emit(war)
	if _event_queue.size() == 0:
		return
	for event: NetMessages.EntityEvent in _event_queue.pop_due(_interp_clock.get_render_tick()):
		combat_event.emit(event, false)


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
				# Puede explicarla un evento de combate propio que aún no ha llegado.
				_pending_diffs.append(Vector2i(_last_snapshot_tick, _local_tick))
				if _pending_diffs.size() > MAX_TRACKED_DIFFS:
					_settle_diff(_pending_diffs.pop_front())
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


# Da por definitivas las diferencias pendientes que llevan DIFF_SETTLE_TICKS esperando su evento.
func _settle_pending_diffs() -> void:
	while not _pending_diffs.is_empty() and _local_tick - _pending_diffs[0].y >= DIFF_SETTLE_TICKS:
		_settle_diff(_pending_diffs.pop_front())


# Una diferencia definitiva: de combate si un evento propio la explica, y si no un fallo de predicción.
func _settle_diff(pending: Vector2i) -> void:
	if _is_imposed_at(pending.x):
		_combat_diffs += 1
		_explained_diffs += 1
		return
	_unexplained_diffs += 1
	_remember(_unexplained_ticks, pending.y)


# true si un evento de combate propio del tick del servidor [param server_tick] o de los
# COMBAT_EXPLAIN_TICKS anteriores impuso estado al jugador local.
func _is_imposed_at(server_tick: int) -> bool:
	for imposed: int in _imposed_ticks:
		if server_tick >= imposed and server_tick <= imposed + COMBAT_EXPLAIN_TICKS:
			return true
	return false


# Anota los eventos propios con los que el servidor impone estado al jugador local, aunque el cliente no
# lo prediga: un golpe recibido (tambaleo, aturdimiento, empuje, resistencia gastada al bloquear, vida),
# su propio golpe parado (el atacante queda tambaleándose), su muerte y su reaparición.
func _note_imposed_state(event: NetMessages.EntityEvent) -> void:
	var imposed: bool = false
	match event.event:
		NetMessages.EntityEvent.Kind.HIT:
			imposed = event.net_id == _net_id or (event.attacker == _net_id
					and (event.hit_flags & NetMessages.EntityEvent.HIT_FLAG_PARRIED) != 0)
		NetMessages.EntityEvent.Kind.DEATH, NetMessages.EntityEvent.Kind.RESPAWN:
			imposed = event.net_id == _net_id
	if not imposed:
		return
	_imposed_ticks.append(event.tick)
	if _imposed_ticks.size() > MAX_TRACKED_DIFFS:
		_imposed_ticks.remove_at(0)


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
	if _cheater != null:
		_cheater.tamper_batch(batch)
	if batch_hook.is_valid():
		batch_hook.call(batch)
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
	_event_queue.clear()
	_war_queue.clear()
	_party.clear()
	if is_instance_valid(_transport):
		_transport.close()
	set_physics_process(false)
	disconnected.emit(text)


# PARTY_INVITE, PARTY_KICK o PARTY_LEADER para [param target_name] (sin controles ni BBCode).
func _send_party_target(msg_type: int, target_name: String) -> bool:
	var request := NetMessages.PartyTargetRequest.make(msg_type, ChatText.clean(target_name))
	var bytes: PackedByteArray = request.encode()
	if _state != State.IN_WORLD or NetMessages.PartyTargetRequest.decode(bytes) == null:
		return false
	if _transport.send(SERVER_PEER_ID, NetProtocol.CH_RELIABLE, bytes) != OK:
		return false
	_party_messages_sent += 1
	return true


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
			elif _projectile_ids.erase(despawn.net_id):
				projectile_despawned.emit(despawn.net_id, despawn.despawn_tick, despawn.reason)
			else:
				_remote_world.on_despawn(despawn)
		NetProtocol.MSG_ENTITY_EVENT:
			_on_entity_event(bytes)
		NetProtocol.MSG_NOTICE:
			var notice: NetMessages.Notice = NetMessages.Notice.decode(bytes)
			if notice == null:
				_malformed_packets += 1
			else:
				_last_notice_text = notice.text
				notice_received.emit(notice.code, notice.text)
		NetProtocol.MSG_OBJECT_STATE:
			_on_object_state(bytes)
		NetProtocol.MSG_SCOREBOARD:
			_on_scoreboard(bytes)
		NetProtocol.MSG_PARTY_ROSTER:
			var roster: NetMessages.PartyRoster = NetMessages.PartyRoster.decode(bytes)
			if roster == null:
				_malformed_packets += 1
			else:
				_party_rosters += 1
				_party.apply_roster(roster)
		NetProtocol.MSG_PARTY_STATUS:
			var party_status: NetMessages.PartyStatus = NetMessages.PartyStatus.decode(bytes)
			if party_status == null:
				_malformed_packets += 1
			else:
				_party_statuses += 1
				_party.apply_status(party_status)
		NetProtocol.MSG_PARTY_INVITATION:
			var invitation: NetMessages.PartyInvitation = NetMessages.PartyInvitation.decode(bytes)
			if invitation == null:
				_malformed_packets += 1
			else:
				_party_invitations += 1
				_party.apply_invitation(invitation)
		NetProtocol.MSG_CHAT_MESSAGE:
			var chat: NetMessages.ChatMessage = NetMessages.ChatMessage.decode(bytes)
			if chat == null:
				_malformed_packets += 1
			else:
				_chat_received += 1
				chat_received.emit(chat)
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
	if snapshot.server_tick > _newest_snapshot_tick:
		_newest_snapshot_local_tick = _local_tick
	_newest_snapshot_tick = maxi(_newest_snapshot_tick, snapshot.server_tick)
	_interp_clock.on_snapshot(snapshot.server_tick, _local_tick)
	_remote_world.on_snapshot(snapshot)
	if _latest == null or snapshot.server_tick > _latest.server_tick:
		_latest = snapshot


# OBJECT_STATE: FortressView guarda el cambio con su tick y lo aplica cuando el tick de dibujo lo
# alcanza (docs/fuerte.md, sección 2).
func _on_object_state(bytes: PackedByteArray) -> void:
	var object_state: NetMessages.ObjectState = NetMessages.ObjectState.decode(bytes)
	if object_state == null:
		_malformed_packets += 1
		return
	_object_states_received += 1
	_fortress_view.on_object_state(object_state)


# SCOREBOARD: se junta por páginas y, completo, se publica.
func _on_scoreboard(bytes: PackedByteArray) -> void:
	var scoreboard: NetMessages.Scoreboard = NetMessages.Scoreboard.decode(bytes)
	if scoreboard == null:
		_malformed_packets += 1
		return
	_scoreboards_received += 1
	if _scoreboard.apply(scoreboard):
		scoreboard_updated.emit(_scoreboard)


# ENTITY_EVENT: los propios se entregan ya; los ajenos esperan a su tick de dibujo.
func _on_entity_event(bytes: PackedByteArray) -> void:
	var event: NetMessages.EntityEvent = NetMessages.EntityEvent.decode(bytes)
	if event == null:
		_malformed_packets += 1
		return
	# Los avisos de guerra y de ataques de PNJ (protocolo v3) no son eventos de combate de nadie: se
	# cuentan aparte. El WAR espera a su tick de dibujo; el TELEGRAPH es un aviso y se entrega al llegar.
	if event.event == NetMessages.EntityEvent.Kind.WAR:
		_war_events_received += 1
		_war_queue.push(event)
		return
	if event.event == NetMessages.EntityEvent.Kind.TELEGRAPH:
		_telegraphs_received += 1
		telegraph_received.emit(event)
		return
	_events_received += 1
	if is_own_event(event):
		_events_own += 1
		_note_imposed_state(event)
		combat_event.emit(event, true)
	else:
		_event_queue.push(event)


func _on_spawn(bytes: PackedByteArray) -> void:
	var spawn: NetMessages.EntitySpawn = NetMessages.EntitySpawn.decode(bytes)
	if spawn == null:
		_malformed_packets += 1
		return
	# El tipo antes que is_yours: un proyectil nunca es el personaje propio (docs/habilidades.md, 5.3).
	if spawn.kind == NetProtocol.EntityKind.PROJECTILE:
		_projectile_spawns_received += 1
		_projectile_ids[spawn.net_id] = true
		projectile_spawned.emit(spawn)
		return
	# Un id que vuelve como entidad ya no es de un proyectil (los ids comparten espacio y cuarentena).
	_projectile_ids.erase(spawn.net_id)
	if spawn.is_yours:
		_on_own_spawn(spawn)
	elif spawn.kind == NetProtocol.EntityKind.STRUCTURE:
		# Estructura: FortressView crea la fortaleza con los campos completos del SPAWN.
		_structure_spawns_received += 1
		_fortress_view.on_spawn(spawn)
	else:
		_directory.remember_spawn(spawn)
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
	_directory.remember(spawn.net_id, _config.display_name if _config != null else spawn.display_name,
			spawn.realm, spawn.kind)
	_world_root.add_child(character)
	# Después de _ready() (que reescribe la máscara) y con el mismo reino que el servidor: las
	# puertas cerradas de los fuertes paran a los enemigos de su dueño. Los remotos no colisionan.
	character.set_realm_collision(spawn.realm)
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
