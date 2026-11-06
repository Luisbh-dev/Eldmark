class_name NetClient
extends Node
## Network client (docs/networking.md, sections 3, 6, 7 and 9.4): connects to the zone, predicts the local
## player, reconciles with the server and draws the others.
## [br][br]
## [b]Connection[/b] (section 3), from the client side:
## [codeblock]
## peer_authenticating(1)  ->  HELLO (send_auth) and hello_local_tick is recorded
## auth_received           ->  REJECT: signal rejected          WELCOME: rtt_hello = local_tick -
##                             hello_local_tick, tick_rate is checked and complete_auth(1)
## peer_connected(1)       ->  signal welcomed: whoever owns the zone loads it and calls
##                             notify_zone_ready(), which sends CLIENT_READY and records ready_local_tick
## own ENTITY_SPAWN        ->  rtt_ticks = min(rtt_hello, local_tick - ready_local_tick);
##                             P0 = TickSync.start(S, rtt_ticks); the local character is instantiated and
##                             ClientPrediction.start(S, state, P0); signal local_spawned
## [/codeblock]
## Nothing is sent with [method NetTransport.send] before [signal NetTransport.peer_connected]
## (on the client, peer 1), and the INPUT_BATCH does not go out until the own SPAWN.
## [br][br]
## [b]Tick[/b] (section 6.2, normative): a single [method _physics_process] with
## [code]process_physics_priority = -100[/code] orchestrates everything, with
## [member LocalPlayerController.auto_step] set to false: receive (poll), reconcile with the newest
## snapshot, take the prediction steps decided by [TickSync], send the INPUT_BATCH, advance the
## interpolation clock, smooth and flush. Snapshots that arrive out of order only
## feed the interpolators ([InterpolationClock] and [RemoteWorld]), never reconciliation.
## [br][br]
## [b]INPUT_BATCH[/b] (5.4), once per tick: from [code]max(input_ack_tick + 1, newest - R + 1,
## first_real_tick)[/code] to [code]newest[/code] (not past newest), with R = 4, or R = 8 if in the
## last [constant LOSSY_WINDOW_TICKS] ticks [code]substitutions[/code] went up or ENet measures more than a
## [constant LOSS_THRESHOLD] fraction of loss. Each input carries its [code]view_offset_q[/code]
## ([code](tick - render_tick seen) × 16[/code]).
## [br][br]
## [b]Statistics[/b] ([method get_stats], [method write_report]): see the keys in
## [method get_stats]. With [member ClientConfig.state_log_path],
## [code]server_tick,hex(predicted),hex(server)[/code] is written for every snapshot with own state.
## [br][br]
## [b]Combat[/b] (docs/combat.md, sections 5 and 6): from each snapshot with own state the
## extra block is stored (health, max health, status and respawn tick; see [method get_health]) and
## ENTITY_EVENTs are distributed through [signal combat_event]. An [b]own[/b] event (the local player is
## attacker, victim, killer or assistant) is delivered as soon as it arrives; the others wait in a
## [CombatEventQueue] until the render tick ([InterpolationClock]) reaches their tick, so that the
## visual reaction of a remote entity (flash, animation) matches what is seen. [method
## send_respawn_request] asks for respawn after dying.
## [br][br]
## [b]Fort[/b] (docs/fortress.md, sections 2, 3.2, 5 and 6; protocol 4): the ENTITY_SPAWN of a structure
## and the OBJECT_STATEs are stored by [FortressView] (change history), which applies the UI and the
## banners when the render tick reaches that of the message and gives the gate layer of each tick
## simulated through the [member ClientPrediction.before_simulate] hook, also in replays (the
## correction of ticks already predicted with the old gate counts as explained: [code]gate_diffs[/code]). War
## notices (WAR) wait in their own queue for their render tick ([signal war_event]); the
## TELEGRAPHs are delivered on arrival ([signal telegraph_received]). The SCOREBOARD is gathered by pages in a
## [ScoreboardState] ([signal scoreboard_updated]) and [PlayerDirectory] remembers the name and realm of each
## entity seen, because the scoreboard and the zone-wide KILLs only carry ids.
## [br][br]
## [b]Projectiles[/b] (docs/abilities.md, section 5.3; protocol 6): the ENTITY_SPAWN is dispatched by
## [code]kind[/code] before looking at [code]is_yours[/code] (which for a projectile is always 0: the own arrow
## is the one whose [code]owner_id[/code] equals the local [code]net_id[/code]). Those of kind 3 are not
## characters: they go to the [ProjectileWorld] (which draws the predicted arrow and others', section 6.2) and
## are emitted through [signal projectile_spawned] and their ENTITY_DESPAWN through [signal projectile_despawned].
## [br][br]
## [b]Abilities[/b] (docs/abilities.md, sections 4.6, 5.4 and 6): the STATUSes of each entity are stored,
## already timed, in a [StatusTracker] per entity ([method get_status_tracker]; they are removed by DEATH, DOWNED,
## RESPAWN and ENTITY_DESPAWN; a remote's tracker receives them all at its render tick, including own ones);
## a remote's LOADOUT gives its weapon pair to its view. The chosen
## template ([member ClientConfig.loadout]) goes out in a LOADOUT_SELECT as soon as the WELCOME arrives, and
## [method send_loadout_select] changes it afterwards. Prediction corrections are considered explained
## also by a movement STATUS on oneself, a DOWNED or INTERACT where one is the knocked-down player or the
## actor, and by the own LOADOUT ([method _note_imposed_state]).
## [br][br]
## [b]Inventory and progress[/b] (docs/progression.md §4.6 and §12; protocol 7): INVENTORY_DELTA, INVENTORY_FULL,
## WALLET_UPDATE and PROGRESS_UPDATE are decoded ([ProgressMessages]) and emitted on arrival through
## [signal inventory_delta_received], [signal inventory_full_received], [signal wallet_updated] and
## [signal progress_updated]; a malformed one counts in [code]malformed_packets[/code]. LEVEL_UP is just another
## ENTITY_EVENT ([signal combat_event]): the own one arrives at once and an ally's at its render tick.
## [method send_inventory_request] and [method send_inventory_sync_request] send the requests (only in the
## world). Each player's level and appearance come in their ENTITY_SPAWN.
## [br][br]
## [b]Player inventory[/b] (docs/progression.md §11.3, P6): a [ClientInventory] ([method get_inventory]) receives
## the INVENTORY_DELTAs and the INVENTORY_FULL pages before their signal, sends its requests through here and takes the
## context of each one ([method inventory_context]: level, active slot, "can touch equipment" and "drinking")
## from the local character's predicted state and the extra block; its 5 s timeout runs on every tick. A
## [ClientProgress] ([method get_progress]) stores the WALLET_UPDATEs, PROGRESS_UPDATEs and the level from the own SPAWN.
## An ally's LEVEL_UP raises the level of their view ([method RemoteWorld.on_level_up]).
## [br][br]
## [b]Cheating bot[/b] ([member ClientConfig.bot_cheat], only in BOT mode): a [BotCheater] fakes
## the HELLO ([code]version[/code]), sends extra traffic after each tick's honest batch
## ([code]future[/code], [code]dupes[/code], [code]garbage[/code], [code]flood[/code]) or fakes the view
## it declares in its inputs ([code]rewind[/code]; the [code]reach[/code] and [code]rate[/code] modes
## only change how it plays, with the brain from [method BotCheater.make_brain]). The bot keeps predicting
## with its honest inputs; what is checked is that the server does not let itself be fooled.

## Emitted when authentication completes on both sides: it is the moment to load the zone
## [code]welcome.zone_id[/code] and call [method notify_zone_ready].
signal welcomed(welcome: NetMessages.Welcome)
## The server rejected the connection. [param text] is in Spanish.
signal rejected(result: int, text: String)
## The local character now exists and prediction has started (camera, HUD, bot...).
signal local_spawned(character: PlayerCharacter)
## The connection ended (server shutdown, kick, cut, connection failure or
## [method leave]). [param text] is in Spanish.
signal disconnected(text: String)
## Server NOTICE: [param code] is a [enum NetProtocol.NoticeCode].
signal notice_received(code: int, text: String)
## An ENTITY_EVENT ready to be shown. If [param is_own], the local player is involved (attacker,
## victim, killer or assistant) and it is delivered on arrival; if not, when the render tick reaches
## [code]event.tick[/code].
signal combat_event(event: NetMessages.EntityEvent, is_own: bool)
## A war notice (WAR) from a fortress, already at its render tick (docs/fortress.md, section 5). The
## text comes from [method WarEvents.text] with [member NetMessages.EntityEvent.war_event] and
## [member NetMessages.EntityEvent.war_realm].
signal war_event(event: NetMessages.EntityEvent)
## A TELEGRAPH (NPC [code]event.net_id[/code] is preparing an attack): delivered on arrival, it is a warning.
signal telegraph_received(event: NetMessages.EntityEvent)
## A complete scoreboard has been published (all its pages): see [method get_scoreboard].
signal scoreboard_updated(scoreboard: ScoreboardState)
## A chat message has arrived (CHAT_MESSAGE, protocol 5), already sanitized by the server. It is delivered on
## arrival: chat is not timed with the render tick.
signal chat_received(message: NetMessages.ChatMessage)
## The ENTITY_SPAWN of a projectile has arrived (kind 3, protocol 6): ballistics, shooter and source. It is delivered
## on arrival; whoever draws it decides when it is visible (the own one replaces it, the remote one waits for its tick).
signal projectile_spawned(spawn: NetMessages.EntitySpawn)
## An INVENTORY_DELTA has arrived (protocol 7): the response to an own request or a server change.
signal inventory_delta_received(delta: ProgressMessages.InventoryDelta)
## A page of INVENTORY_FULL has arrived (protocol 7); whoever uses it gathers those of the same revision.
signal inventory_full_received(page: ProgressMessages.InventoryFull)
## The balance of a currency has arrived (WALLET_UPDATE, protocol 7).
signal wallet_updated(update: ProgressMessages.WalletUpdate)
## The level with its XP has arrived (PROGRESS_UPDATE, protocol 7).
signal progress_updated(update: ProgressMessages.ProgressUpdate)
## The ENTITY_DESPAWN of a known projectile has arrived: [param reason] is
## [constant NetProtocol.DespawnReason.IMPACT] (it hit something at [param tick]) or
## [constant NetProtocol.DespawnReason.EXPIRED].
signal projectile_despawned(projectile_id: int, tick: int, reason: int)

enum State {
	## Without [method start].
	IDLE,
	## Connecting: waiting for ENet to begin authentication.
	CONNECTING,
	## HELLO sent: waiting for WELCOME or REJECT.
	HELLO_SENT,
	## Authenticated: the zone is loading.
	WELCOMED,
	## CLIENT_READY sent: waiting for the own SPAWN.
	READY_SENT,
	## With a local character and prediction running.
	IN_WORLD,
	## Leaving was requested: waiting for the connection to close.
	LEAVING,
	## Rejected, disconnected or connection failure: there is no session any more.
	CLOSED,
}

const PLAYER_SCENE_PATH: String = "res://scenes/characters/player_character.tscn"
## ENet timeout when connecting (ms): failure is detected within twice that at most.
const CONNECT_TIMEOUT_MS: int = 3000
## Id with which the client sees the server.
const SERVER_PEER_ID: int = 1
## Ticks after a rise in the server's substitutions during which it sends with R = 8.
const LOSSY_WINDOW_TICKS: int = 120
## ENet loss (0 to 1) above which it sends with R = 8.
const LOSS_THRESHOLD: float = 0.02
## How many ticks between ENet loss queries.
const LOSS_SAMPLE_TICKS: int = 30
## Scales of the INPUT_BATCH fields: interpolation delay × 8, view offset × 16.
const INTERP_DELAY_SCALE: float = 8.0
const VIEW_OFFSET_SCALE: float = 16.0
## TickSync resyncs (step jumps) and resets remembered with their tick.
const MAX_REMEMBERED_EVENTS: int = 64
## A prediction correction is considered explained by an own combat event (a hit received
## or blocked, a death, a respawn: the server imposes stagger, stun, knockback, stamina
## spent...) if the snapshot that caused it is from the event's tick or the following
## [constant COMBAT_EXPLAIN_TICKS] ticks (snapshots go out every 2 ticks and some are lost).
## [br][br]
## It is also considered explained by the fort gate (phase 4 review, client): an OBJECT_STATE of tick
## [code]s[/code] that changes the movement layer of the own realm at the gate arrives when the prediction is already at
## [code]P[/code], and ticks [code]s + 1[/code] to [code]P[/code] were simulated with the old gate. It applies to the
## snapshots from [code]s + 1[/code] to [code]P[/code] plus these same ticks (the first one compared may be somewhat
## later). Statistic: [code]gate_diffs[/code].
const COMBAT_EXPLAIN_TICKS: int = 12
## Local ticks to wait, before treating a difference as final, for the event that
## explains it to arrive: the ENTITY_EVENT goes over the reliable channel and may arrive after the snapshot.
const DIFF_SETTLE_TICKS: int = 90
## Maximum own events and pending differences remembered.
const MAX_TRACKED_DIFFS: int = 256
## Maximum health assumed until the snapshot's extra block has arrived.
const DEFAULT_MAX_HEALTH: int = 1000
## Messages of [signal disconnected].
const TEXT_CONNECT_FAILED: String = "No se pudo conectar con el servidor %s:%d"
const TEXT_CONNECTION_LOST: String = "Se perdió la conexión con el servidor"
const TEXT_LEFT: String = "Has salido de la zona"
const TEXT_BAD_REPLY: String = "Respuesta del servidor no válida"
const TEXT_BAD_VERSION: String = "Versión del protocolo incompatible con la del servidor"
const TEXT_BAD_TICK_RATE: String = "El servidor simula a %d ticks por segundo y este cliente a %d"

## Test hook (and of the future cheating bot, TEC-46): it is called with the HELLO right before
## sending it and may modify it (version, fingerprint, realm...). It must be set before the
## transport starts authenticating, that is, right after [method start].
var hello_hook: Callable = Callable()
## Test hook: it is called with each tick's [NetMessages.InputBatch] right before encoding it and
## may modify it (for example, fake the [code]view_offsets_q[/code] of the rewind). The same as what
## the [code]rewind[/code] mode of the cheating bot ([BotCheater]) does, but tailored to a test.
var batch_hook: Callable = Callable()
## Extra fields for the report ([method write_report]): [OnlineMain] puts here the account data of a bot with
## [code]--platform[/code] (docs/platform.md §13.3).
var report_extra: Dictionary = {}
## ENet timeout when connecting (ms). [constant CONNECT_TIMEOUT_MS] unless whoever calls
## [method start] sets another before it (the [code]--local[/code] mode uses a short one to retry).
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

# Combat: own extra block from the last reconciled snapshot and queue of other entities' events.
var _health: int = DEFAULT_MAX_HEALTH
var _max_health: int = DEFAULT_MAX_HEALTH
var _status: int = 0
var _respawn_tick: int = 0
var _has_extra: bool = false
var _event_queue: CombatEventQueue = CombatEventQueue.new()
# Own events about a remote that wait in [member _event_queue] only for that remote's effects tracker
# (their signal already went out on arrival): this way the tracker follows the server's tick order.
var _tracker_only: Dictionary[NetMessages.EntityEvent, bool] = {}
var _events_received: int = 0
var _events_own: int = 0
var _respawn_requests: int = 0

# Fort (phase 4): view of the fortresses, war notices waiting for their render tick, scoreboard and
# memory of who each id is.
var _fortress_view: FortressView = FortressView.new()
var _war_queue: CombatEventQueue = CombatEventQueue.new()
var _scoreboard: ScoreboardState = ScoreboardState.new()
var _directory: PlayerDirectory = PlayerDirectory.new()
var _structure_spawns_received: int = 0
# Projectiles (protocol 6): ids of those that arrived with SPAWN and have not gone yet, and whoever draws them.
var _projectile_ids: Dictionary[int, bool] = {}
var _projectile_spawns_received: int = 0
var _projectile_world: ProjectileWorld = ProjectileWorld.new()
# Status effects of each entity (net_id -> StatusTracker), already timed (UI-45).
var _status_trackers: Dictionary[int, StatusTracker] = {}
var _loadout_selects_sent: int = 0
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
# Inventory and progress (protocol 7): requests sent and messages received.
var _inventory_requests_sent: int = 0
var _inventory_syncs_sent: int = 0
var _inventory_deltas: int = 0
var _inventory_fulls: int = 0
var _wallet_updates: int = 0
var _progress_updates: int = 0
# Inventory, coins and progress of the local player (P6) and the 8 B of appearance from their SPAWN.
var _inventory: ClientInventory = ClientInventory.new()
var _progress: ClientProgress = ClientProgress.new()
var _own_appearance: PackedByteArray = PackedByteArray()

# Sending inputs.
var _view_offsets_q: PackedInt32Array = PackedInt32Array()
var _batches_sent: int = 0
var _server_substitutions: int = -1
var _substitutions_total: int = 0
var _substitution_rises: int = 0
var _lossy_until_tick: int = -1
var _loss_sampled_tick: int = 0
var _high_loss: bool = false

# Reconciliation results.
var _diffs: int = 0
var _explained_diffs: int = 0
var _unexplained_diffs: int = 0
var _combat_diffs: int = 0
var _teleport_diffs: int = 0
var _gate_diffs: int = 0
var _consecutive_matches: int = 0
var _last_result: int = ClientPrediction.Result.IGNORED
var _resyncs: int = 0
var _hard_reset_ticks: Array[int] = []
var _resync_ticks: Array[int] = []
var _unexplained_ticks: Array[int] = []
# Differences that neither a substitution nor a teleport explains, waiting for the combat event
# that explains them to arrive: (server tick of the snapshot, local tick at which it was seen).
var _pending_diffs: Array[Vector2i] = []
# Server ticks of own combat events that impose state (hit received, block,
# death, respawn).
var _imposed_ticks: PackedInt64Array = PackedInt64Array()
# Server tick intervals (from, to) whose differences are explained by a change of the fort gate for the own
# realm that arrived with the prediction already ahead.
var _gate_changes: Array[Vector2i] = []

var _state_log: FileAccess = null
var _state_log_failed: bool = false


func _init() -> void:
	name = "NetClient"
	process_physics_priority = -100
	_view_offsets_q.resize(ClientPrediction.HISTORY_SIZE)
	_view_offsets_q.fill(0)
	_remote_world.setup(_interp_clock)
	_fortress_view.setup(_interp_clock)
	_projectile_world.setup(_interp_clock, _remote_world)
	# The fort gate that each simulated tick had, also in replays (fortress.md, 3.2).
	_prediction.before_simulate = _fortress_view.before_simulate
	# The inventory sends through here and takes the context of each request from the predicted state.
	_inventory.send_request = send_inventory_request
	_inventory.send_sync = send_inventory_sync_request
	_inventory.context_provider = inventory_context
	_inventory.in_combat_provider = is_in_combat


func _ready() -> void:
	if _fortress_view.get_parent() == null:
		add_child(_fortress_view)
	# Nothing to do until start().
	set_physics_process(_state != State.IDLE and _state != State.CLOSED)


func _exit_tree() -> void:
	_close_state_log()


func _notification(what: int) -> void:
	# The RemoteWorld only enters the tree when the zone is reported ready: if the session ends
	# before (rejection, connection failure), nobody else would free it.
	if what == NOTIFICATION_PREDELETE:
		if is_instance_valid(_remote_world) and _remote_world.get_parent() == null:
			_remote_world.free()
		if is_instance_valid(_fortress_view) and _fortress_view.get_parent() == null:
			_fortress_view.free()
		if is_instance_valid(_projectile_world) and _projectile_world.get_parent() == null:
			_projectile_world.free()


# --- Public API -------------------------------------------------------------------------------

## Starts the session: prepares prediction, computes the simulation fingerprint (sim_hash) and
## starts connecting to [member ClientConfig.address]:[member ClientConfig.port] through
## [param transport] (which must be in the tree). [param controller] is the local character's
## controller: it gets [code]auto_step = false[/code] and prediction uses it to
## build the inputs. Returns the error of [method NetTransport.connect_to] if it cannot
## start connecting.
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
	var dtls: TLSOptions = dtls_options(config)
	if dtls == null and config.has_dtls():
		_disconnect_transport()
		return ERR_INVALID_DATA
	var error: Error = _transport.connect_to(config.address, config.port, connect_timeout_ms, config.dtls_name,
			dtls)
	if error != OK:
		_disconnect_transport()
		return error
	_state = State.CONNECTING
	set_physics_process(true)
	return OK


## The pinned DTLS certificate of the zone ([method TLSOptions.client]) that [param config] says: the PEM from
## [code]enter[/code] ([member ClientConfig.dtls_cert_pem]) or, without a platform, the file from [code]--dtls-cert[/code].
## Null without DTLS or if the certificate cannot be read (docs/platform.md §10.2).
static func dtls_options(config: ClientConfig) -> TLSOptions:
	if config == null or not config.has_dtls():
		return null
	var certificate := X509Certificate.new()
	var error: Error = OK
	if not config.dtls_cert_pem.is_empty():
		error = certificate.load_from_string(config.dtls_cert_pem)
	elif FileAccess.file_exists(config.dtls_cert_path):
		error = certificate.load(config.dtls_cert_path)
	else:
		error = ERR_FILE_NOT_FOUND
	if error != OK:
		push_warning("[Eldmark] No se puede leer el certificado DTLS de la zona (%s)" % error_string(error))
		return null
	return TLSOptions.client(certificate)


## Sends CLIENT_READY (only after [signal welcomed]) and records the local tick. [param world_root]
## receives the [RemoteWorld] and, when the own SPAWN arrives, the local character. The normal usage is to
## call it when the zone is already loaded and in the tree, with [param world_root] inside it or
## the zone itself.
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
	if _projectile_world.get_parent() == null:
		_world_root.add_child(_projectile_world)
	_ready_local_tick = _local_tick
	var error: Error = _transport.send(SERVER_PEER_ID, NetProtocol.CH_RELIABLE,
			NetMessages.ClientReady.new().encode())
	if error != OK:
		_close_session(TEXT_CONNECTION_LOST)
		return
	_state = State.READY_SENT


## Leaves the zone: sends CLIENT_LEAVE (immediate removal without waiting for the timeout) and asks for the orderly
## disconnect. [signal disconnected] arrives when the connection closes. Before being connected,
## it simply cancels.
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


## Sends a DEBUG_COMMAND ([constant NetProtocol.DEBUG_TELEPORT]...). The server only accepts it
## with [code]--debug-commands[/code].
func send_debug_command(command: int, payload: PackedByteArray) -> void:
	if _state != State.IN_WORLD:
		return
	var message := NetMessages.DebugCommand.new()
	message.command = command
	message.payload = payload
	_transport.send(SERVER_PEER_ID, NetProtocol.CH_RELIABLE, message.encode())


## Asks to respawn at point [param point_index] of the realm's list of points (RESPAWN_REQUEST,
## docs/combat.md section 5). It only makes sense when dead and past [method get_respawn_tick]: the
## server ignores (with a warning) whatever arrives out of time. Returns false if there is no session in the
## world or it could not be sent.
func send_respawn_request(point_index: int) -> bool:
	if _state != State.IN_WORLD:
		return false
	var request := NetMessages.RespawnRequest.new()
	request.point_index = clampi(point_index, 0, 255)
	if _transport.send(SERVER_PEER_ID, NetProtocol.CH_RELIABLE, request.encode()) != OK:
		return false
	_respawn_requests += 1
	return true


## Sends a chat message (CHAT_SEND, protocol 5) on [param channel] ([enum ChatChannel.Id]). In a
## whisper [param recipient] is the recipient's name; in other channels it is ignored. The text is
## sanitized with [ChatText] before sending (the same as the server will do) and trimmed to its limits.
## Returns false, without sending anything, if there is no session in the world, the channel cannot be sent to, the text
## ends up empty or a whisper's recipient is missing.
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


## Asks for equipment template [param template_id] ([method CombatCatalog.template_id]; 0 = the default
## one) for the next spawn: LOADOUT_SELECT (docs/abilities.md, sections 4.6 and 5.1). Valid from
## the WELCOME, also before CLIENT_READY; the server does not answer: the template arrives with the respawn
## (LOADOUT event). It records it in [member ClientConfig.loadout] for later connections. Returns false,
## without sending anything, if there is no authenticated session or the id is not a selectable template.
func send_loadout_select(template_id: int) -> bool:
	if _state != State.WELCOMED and _state != State.READY_SENT and _state != State.IN_WORLD:
		return false
	var template: EquipmentTemplate = CombatCatalog.template(template_id) if template_id != 0 else null
	if template_id != 0 and (template == null or not template.selectable):
		return false
	if _transport.send(SERVER_PEER_ID, NetProtocol.CH_RELIABLE,
			NetMessages.LoadoutSelect.make(template_id).encode()) != OK:
		return false
	_loadout_selects_sent += 1
	if _config != null:
		_config.loadout = String(template.id) if template != null else ""
	return true


## Invites [param target_name], a player of your realm, to your party (PARTY_INVITE). The server decides and
## answers through the chat's system channel. Returns false if there is no session in the world or the name is not valid.
func send_party_invite(target_name: String) -> bool:
	return _send_party_target(NetProtocol.MSG_PARTY_INVITE, target_name)


## Kicks [param target_name] from the party (PARTY_KICK; only valid if you are the leader).
func send_party_kick(target_name: String) -> bool:
	return _send_party_target(NetProtocol.MSG_PARTY_KICK, target_name)


## Hands the party leadership to [param target_name] (PARTY_LEADER; only valid if you are the leader).
func send_party_leader(target_name: String) -> bool:
	return _send_party_target(NetProtocol.MSG_PARTY_LEADER, target_name)


## Accepts or declines the invitation from [param inviter] (PARTY_RESPONSE) and removes it from the pending ones. Returns
## false if there is no session in the world or the name is not valid.
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


## Leaves the party (PARTY_LEAVE). Returns false if there is no session in the world.
func send_party_leave() -> bool:
	if _state != State.IN_WORLD:
		return false
	if _transport.send(SERVER_PEER_ID, NetProtocol.CH_RELIABLE, NetMessages.PartyLeave.new().encode()) != OK:
		return false
	_party_messages_sent += 1
	return true


## Sends an inventory request (INVENTORY_REQUEST, protocol 7; docs/progression.md §4.6). Whoever sends it
## carries its [code]request_id[/code] and its optimistic state (§11.3). Returns false, without sending anything, if there is no
## session in the world (before, it would be a server warning) or the message cannot be encoded.
func send_inventory_request(message: ProgressMessages.InventoryRequest) -> bool:
	if _state != State.IN_WORLD or message == null or not is_instance_valid(_transport):
		return false
	var bytes: PackedByteArray = message.encode()
	if bytes.is_empty() or _transport.send(SERVER_PEER_ID, NetProtocol.CH_RELIABLE, bytes) != OK:
		return false
	_inventory_requests_sent += 1
	return true


## Asks for the whole inventory (INVENTORY_SYNC_REQUEST, protocol 7): at most one every 5 s, or the server
## counts a warning. Returns false if there is no session in the world or it could not be sent.
func send_inventory_sync_request() -> bool:
	if _state != State.IN_WORLD or not is_instance_valid(_transport):
		return false
	if _transport.send(SERVER_PEER_ID, NetProtocol.CH_RELIABLE,
			ProgressMessages.InventorySyncRequest.new().encode()) != OK:
		return false
	_inventory_syncs_sent += 1
	return true


## The local player's inventory (docs/progression.md §11.3): empty until the first INVENTORY_FULL.
func get_inventory() -> ClientInventory:
	return _inventory


## Coins, level and XP of the local player (WALLET_UPDATE, PROGRESS_UPDATE and the level from the own SPAWN).
func get_progress() -> ClientProgress:
	return _progress


## The 8 B of appearance from the own SPAWN (empty before spawning; all 0 if the zone has no progress).
func get_own_appearance() -> PackedByteArray:
	return _own_appearance


## The context of an inventory request now (docs/progression.md §4.1 and §11.3): the level from
## [method get_progress]; the active weapon slot, bit0 of [code]combat_flags2[/code] of the predicted state; and "can
## touch equipment" only when alive, not knocked down, out of combat (extra block) and with no predicted action. "Drinking", with
## a consumable ABILITY in progress.
func inventory_context() -> InventoryOps.Context:
	var context := InventoryOps.Context.new()
	context.level = _progress.get_level()
	if is_instance_valid(_character):
		var combat: CombatState = _character.combat
		context.active_weapon_slot = 1 if (combat.combat_flags2 & CombatState.FLAG2_SECOND_SLOT) != 0 else 0
		context.can_touch_equipment = combat.action == CombatState.Action.NONE and not is_dead() \
				and not is_downed() and not is_in_combat()
		var ability: AbilityTicks = CombatCatalog.ability(combat.action_id) \
				if combat.action == CombatState.Action.ABILITY else null
		context.drinking = ability != null and ability.is_consumable()
	else:
		context.can_touch_equipment = false
	return context


## Local player's health according to the last reconciled snapshot (default max health until
## the first extra block arrives). Health is decided by the server: it is not predicted.
func get_health() -> int:
	return _health


func get_max_health() -> int:
	return _max_health


## true if at least one extra block has arrived (the health shown is the server's).
func has_health() -> bool:
	return _has_extra


## Bits [constant NetMessages.STATUS_IN_COMBAT], [constant NetMessages.STATUS_PROTECTED],
## [constant NetMessages.STATUS_DEAD] and [constant NetMessages.STATUS_DOWNED] of the last extra block.
func get_status() -> int:
	return _status


func is_dead() -> bool:
	return (_status & NetMessages.STATUS_DEAD) != 0


## true if the local player is knocked down (bit [constant NetMessages.STATUS_DOWNED] of the extra block):
## then [method get_health] is the knocked-down health and [method get_max_health] its maximum.
func is_downed() -> bool:
	return (_status & NetMessages.STATUS_DOWNED) != 0


func is_in_combat() -> bool:
	return (_status & NetMessages.STATUS_IN_COMBAT) != 0


func is_protected() -> bool:
	return (_status & NetMessages.STATUS_PROTECTED) != 0


## Server tick at which respawn can be requested (0 if the player is alive).
func get_respawn_tick() -> int:
	return _respawn_tick


## Estimate of the server's current tick: that of the last snapshot plus the local ticks that have
## passed since it arrived. It runs behind the real server by the time a snapshot takes to arrive
## (half an RTT), and that suits the respawn countdown: when the count reaches
## 0 the request, which takes another half RTT, arrives on time.
func get_estimated_server_tick() -> int:
	if _newest_snapshot_tick <= 0:
		return 0
	return _newest_snapshot_tick + maxi(_local_tick - _newest_snapshot_local_tick, 0)


## Tick of the last snapshot with own state that was reconciled (0 if none has arrived yet).
func get_last_snapshot_tick() -> int:
	return _last_snapshot_tick


## Other entities' combat events waiting for the render tick to reach their tick.
func get_combat_queue() -> CombatEventQueue:
	return _event_queue


## true if the local player is involved in [param event]: attacker or victim of a HIT, victim or
## killer of a DEATH, victim, killer or assistant of a KILL, or whoever respawns in a RESPAWN; and since
## protocol 6 (docs/abilities.md, section 5.4), the affected party or the author of a STATUS, the healed or the
## healer in a HEAL, the owner of a LOADOUT, the knocked-down or the one knocking down in a DOWNED, and the knocked-down or
## the one who lifts or executes them in an INTERACT; and since protocol 7, whoever levels up in a LEVEL_UP. False
## while there is no local character.
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
		NetMessages.EntityEvent.Kind.RESPAWN, NetMessages.EntityEvent.Kind.LOADOUT, \
				NetMessages.EntityEvent.Kind.LEVEL_UP:
			return event.net_id == _net_id
		NetMessages.EntityEvent.Kind.STATUS:
			return event.net_id == _net_id or event.source_entity == _net_id
		NetMessages.EntityEvent.Kind.HEAL:
			return event.net_id == _net_id or event.healer == _net_id
		NetMessages.EntityEvent.Kind.INTERACT:
			return event.net_id == _net_id or event.actor == _net_id
	return false


## Status effects of entity [param net_id] according to the STATUSes that have arrived (null if it has never had
## any). Those of the local player, on arrival; those of a remote, at their render tick.
func get_status_tracker(net_id: int) -> StatusTracker:
	return _status_trackers.get(net_id)


## Whoever draws the arrows (the own predicted one and the others').
func get_projectile_world() -> ProjectileWorld:
	return _projectile_world


## Local character (null until [signal local_spawned]).
func get_character() -> PlayerCharacter:
	return _character


func get_prediction() -> ClientPrediction:
	return _prediction


func get_remote_world() -> RemoteWorld:
	return _remote_world


## View of the fortresses (replicated state, banners and the prediction's gate).
func get_fortress_view() -> FortressView:
	return _fortress_view


## The zone's scoreboard (the last complete one).
func get_scoreboard() -> ScoreboardState:
	return _scoreboard


## Name and realm of each entity seen (the scoreboard and KILLs only carry ids).
## What is known about the local player's party: members, leader, 2 Hz status and invitations (SOC-06).
func get_party() -> PartyState:
	return _party


func get_directory() -> PlayerDirectory:
	return _directory


func get_tick_sync() -> TickSync:
	return _tick_sync


func get_interpolation_clock() -> InterpolationClock:
	return _interp_clock


## Physics ticks the client has run since [method start].
func get_local_tick() -> int:
	return _local_tick


## Last own server state that was reconciled (null if none has arrived yet).
func get_last_server_state() -> PlayerState:
	return _last_server_state


func get_state() -> State:
	return _state


## Network id of the local character (0 until the own SPAWN).
func get_net_id() -> int:
	return _net_id


## Server tick at which the local character spawned (0 until the own SPAWN).
func get_spawn_tick() -> int:
	return _spawn_tick


func get_welcome() -> NetMessages.Welcome:
	return _welcome


func get_controller() -> LocalPlayerController:
	return _controller


func get_config() -> ClientConfig:
	return _config


## This session's cheating bot (null if it plays clean or is not a bot).
func get_cheater() -> BotCheater:
	return _cheater


func get_transport() -> NetTransport:
	return _transport


## RTT in ticks with which prediction started (0 before the own SPAWN).
func get_rtt_ticks() -> int:
	return _rtt_ticks


## Text of the last server NOTICE ("" if none has arrived).
func get_last_notice_text() -> String:
	return _last_notice_text


## Session statistics (all since the own SPAWN unless stated otherwise):
## [br]- [code]local_ticks[/code], [code]spawn_tick[/code], [code]first_real_tick[/code],
## [code]predicted_tick[/code], [code]server_tick[/code] (last reconciled snapshot),
## [code]rtt_hello_ticks[/code], [code]rtt_ticks[/code].
## [br]- [code]snapshots[/code] received, [code]late_snapshots[/code] (out of order),
## [code]snapshots_with_state[/code] (with own state reconciled), [code]malformed_packets[/code].
## [br]- [code]matches[/code] (exact matches), [code]ignored[/code], [code]diffs[/code]
## (states that did not match and were replayed), [code]explained_diffs[/code] (with a rise in
## [code]substitutions[/code], a teleport, an own combat event or a gate change),
## [code]combat_diffs[/code] (those explained by combat: what the server imposes and the client does not
## predict), [code]gate_diffs[/code] (those explained by a fort gate change that arrived with the
## prediction ahead), [code]unexplained_diffs[/code] (the rest: prediction failures),
## [code]teleport_diffs[/code], [code]corrections[/code] (those over 1 mm),
## [code]resimulated_ticks[/code], [code]last_correction[/code], [code]max_correction[/code],
## [code]consecutive_matches[/code] (current streak), [code]last_result[/code].
## [br]- [code]hard_resets[/code] (of the prediction), [code]hard_reset_ticks[/code] (local tick of
## each one), [code]resyncs[/code] (hard TickSync resyncs), [code]resync_ticks[/code],
## [code]tick_sync_adjustments[/code], [code]target_margin[/code], [code]window_min[/code],
## [code]last_input_margin[/code].
## [br]- [code]substitutions[/code] (server counter), [code]substitution_rises[/code] and
## [code]substitutions_total[/code].
## [br]- [code]delay_ticks[/code], [code]jitter_ticks[/code], [code]render_tick[/code],
## [code]batches_sent[/code], [code]cheat_packets[/code] (extra packets from the cheating bot),
## [code]remote_views[/code].
## [br]- [code]combat_events[/code] received, [code]combat_events_own[/code] (the own ones),
## [code]combat_events_pending[/code] (waiting for their render tick), [code]respawn_requests[/code],
## [code]health[/code] and [code]max_health[/code].
## [br]- [code]projectile_spawns[/code]: projectile ENTITY_SPAWNs received (protocol 6);
## [code]loadout_selects[/code]: LOADOUT_SELECTs sent; [code]status_trackers[/code]: entities with stored
## effects.
## [br]- [code]structure_spawns[/code], [code]object_states[/code], [code]scoreboards[/code],
## [code]war_events[/code] and [code]telegraphs[/code]: protocol 4 messages received;
## [code]war_events_pending[/code] (war notices waiting for their render tick) and
## [code]fortress_hook_calls[/code] (times the prediction asked about the gate).
## [br]- [code]chat_sent[/code] and [code]chat_received[/code]: chat messages sent and received.
## [br]- [code]party_sent[/code] (party requests sent) and [code]party_rosters[/code],
## [code]party_statuses[/code] and [code]party_invitations[/code]: party messages received.
## [br]- Of inventory and progress (protocol 7): [code]inventory_requests_sent[/code] and
## [code]inventory_syncs_sent[/code] (sent), [code]inventory_deltas[/code], [code]inventory_fulls[/code]
## (pages), [code]wallet_updates[/code] and [code]progress_updates[/code] (received well-formed).
func get_stats() -> Dictionary:
	var prediction_stats: Dictionary = _prediction.get_stats()
	# Differences still waiting for their event already count, according to what is known now.
	var provisional_combat: int = 0
	var provisional_gate: int = 0
	var provisional_unexplained: int = 0
	var unexplained_ticks: Array[int] = _unexplained_ticks.duplicate()
	for pending: Vector2i in _pending_diffs:
		if _is_imposed_at(pending.x):
			provisional_combat += 1
		elif _is_gate_change_at(pending.x):
			provisional_gate += 1
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
		"explained_diffs": _explained_diffs + provisional_combat + provisional_gate,
		"combat_diffs": _combat_diffs + provisional_combat,
		"gate_diffs": _gate_diffs + provisional_gate,
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
		"combat_events_pending": maxi(_event_queue.size() - _tracker_only.size(), 0),
		"respawn_requests": _respawn_requests,
		"structure_spawns": _structure_spawns_received,
		"projectile_spawns": _projectile_spawns_received,
		"loadout_selects": _loadout_selects_sent,
		"status_trackers": _status_trackers.size(),
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
		"inventory_requests_sent": _inventory_requests_sent,
		"inventory_syncs_sent": _inventory_syncs_sent,
		"inventory_deltas": _inventory_deltas,
		"inventory_fulls": _inventory_fulls,
		"wallet_updates": _wallet_updates,
		"progress_updates": _progress_updates,
		"war_events_pending": _war_queue.size(),
		"fortress_hook_calls": int(_fortress_view.get_stats()["hook_calls"]),
		"health": _health,
		"max_health": _max_health,
	}


## What the client knows about its progress, in the form of the record in docs/progression.md §3.4 to compare it with
## what is stored (§15 P8): [code]items[/code] (the inventory's confirmed state by container and slot, each with
## [method ItemInstance.to_dictionary]), [code]wallets[/code] ([code]{currency, balance}[/code] of each currency, from
## WALLET_UPDATE), [code]level[/code], [code]xp_in_level[/code], [code]realm_points[/code],
## [code]attribute_points[/code] (from PROGRESS_UPDATE), [code]bag_slots[/code], [code]active_weapon_slot[/code] (bit0
## of [code]combat_flags2[/code] of the predicted state), [code]revision[/code] and [code]pending[/code] (requests
## without a response). Empty without an inventory (before the first INVENTORY_FULL or in a zone without progress).
func progress_report() -> Dictionary:
	var confirmed: InventoryState = _inventory.get_confirmed()
	if confirmed == null:
		return {}
	var items: Array = []
	for container: int in [InventoryState.ContainerId.BAG, InventoryState.ContainerId.EQUIPMENT]:
		for slot: int in confirmed.slot_count(container):
			var item: ItemInstance = confirmed.get_item(container, slot)
			if item != null:
				items.append(item.to_dictionary(container, slot))
	var wallets: Array = []
	var codes: Array = Currency.Code.values()
	codes.sort()
	for code: Variant in codes:
		wallets.append({"currency": int(code), "balance": _progress.get_balance(int(code))})
	var active_slot: int = 0
	if is_instance_valid(_character):
		active_slot = 1 if (_character.combat.combat_flags2 & CombatState.FLAG2_SECOND_SLOT) != 0 else 0
	return {
		"items": items, "wallets": wallets, "level": _progress.get_level(), "xp_in_level": _progress.get_xp_in_level(),
		"realm_points": _progress.get_realm_points(), "attribute_points": _progress.get_attribute_points(),
		"bag_slots": confirmed.bag_slots, "active_weapon_slot": active_slot, "revision": _inventory.get_revision(),
		"pending": _inventory.get_pending_count(),
	}


## Writes the session's JSON report to [param path] (missing directories are created). Its
## keys are those of [method get_stats] plus: [code]version[/code], [code]name[/code],
## [code]realm[/code], [code]mode[/code], [code]address[/code], [code]port[/code],
## [code]net_sim[/code], [code]seed[/code], [code]cheat[/code] (cheating bot mode, or ""),
## [code]zone[/code], [code]net_id[/code],
## [code]state[/code], [code]rejected[/code] (with [code]reject_result[/code] and
## [code]reject_text[/code] if the server rejected the connection), [code]disconnect_text[/code] and
## [code]final[/code]: [code]{predicted_tick,
## predicted_state, server_tick, server_state, exact, position, velocity}[/code], where the states
## are the bytes of [method PlayerState.encode] in hexadecimal and [code]exact[/code] says whether the
## state predicted for the server's last tick is identical to its own. With an inventory, also
## [code]progress[/code] ([method progress_report]). The keys of [member report_extra] go on top.
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


# --- Tick loop (6.2) --------------------------------------------------------------------------

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
	_inventory.tick(Time.get_ticks_msec())
	_smoother.physics_step()
	_transport.flush()


# Reconciles with the newest snapshot that has not already been reconciled (out-of-order ones do not count).
func _reconcile_latest() -> void:
	var snapshot: NetMessages.Snapshot = _latest
	_latest = null
	if snapshot == null or snapshot.server_tick <= _last_snapshot_tick:
		return
	_last_snapshot_tick = snapshot.server_tick
	# How far the server has simulated: a predicted arrow without a SPAWN well after its tick is rejected.
	_projectile_world.on_server_tick(_last_snapshot_tick)
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


# Snapshot's own extra block (health, max health, status and respawn tick). It arrives with
# all snapshots that carry own state.
func _apply_extra_block(snapshot: NetMessages.Snapshot) -> void:
	_has_extra = true
	_health = snapshot.health
	_max_health = snapshot.max_health
	_status = snapshot.status
	_respawn_tick = snapshot.respawn_tick


# Delivers other entities' events whose tick the render tick has already reached.
func _deliver_due_events() -> void:
	if _war_queue.size() > 0:
		for war: NetMessages.EntityEvent in _war_queue.pop_due(_interp_clock.get_render_tick()):
			war_event.emit(war)
	if _event_queue.size() == 0:
		return
	for event: NetMessages.EntityEvent in _event_queue.pop_due(_interp_clock.get_render_tick()):
		if _tracker_only.erase(event):
			_track_status(event)
		else:
			_deliver_combat_event(event, false)
	if _event_queue.size() == 0:
		# No mark outlives its event (also if the full queue dropped one).
		_tracker_only.clear()


# Delivers an already-timed combat event: before the signal, STATUSes (and whatever clears them) go to the
# tracker of their entity and a remote's LOADOUT to its view. A remote's tracker always receives them at
# its render tick, including own ones (those placed or killed by the local player), which wait in the queue of
# others': otherwise an older foreign STATUS that was still waiting was applied after a newer own one and
# undid it (phase 4 review).
func _deliver_combat_event(event: NetMessages.EntityEvent, is_own: bool) -> void:
	if is_own and event.net_id != get_net_id() and _is_tracked_kind(event):
		_tracker_only[event] = true
		_event_queue.push(event)
	else:
		_track_status(event)
	if event.event == NetMessages.EntityEvent.Kind.LOADOUT and event.net_id != _net_id:
		_remote_world.on_loadout(event)
	elif event.event == NetMessages.EntityEvent.Kind.LEVEL_UP:
		if event.net_id == _net_id:
			_progress.on_level_up(event.level)
		else:
			_remote_world.on_level_up(event)
	combat_event.emit(event, is_own)


# true if [param event] matters to a [StatusTracker]: STATUS and whatever clears them (DEATH, DOWNED, RESPAWN).
static func _is_tracked_kind(event: NetMessages.EntityEvent) -> bool:
	match event.event:
		NetMessages.EntityEvent.Kind.STATUS, NetMessages.EntityEvent.Kind.DEATH, \
				NetMessages.EntityEvent.Kind.DOWNED, NetMessages.EntityEvent.Kind.RESPAWN:
			return true
	return false


# STATUS of an entity: to its tracker (created with the first one). DEATH, DOWNED and RESPAWN clear them.
func _track_status(event: NetMessages.EntityEvent) -> void:
	if not _is_tracked_kind(event):
		return
	var tracker: StatusTracker = _status_trackers.get(event.net_id)
	if tracker == null:
		if event.event != NetMessages.EntityEvent.Kind.STATUS:
			return
		tracker = StatusTracker.new()
		_status_trackers[event.net_id] = tracker
	tracker.handle_event(event)


# Records what the prediction did with the server's state. A difference is considered explained if
# it coincides with a rise in the server's substitution counter (a lost or late input)
# or with a teleport; if not, it is a prediction failure.
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
				# It may be explained by an own combat event that has not arrived yet.
				_pending_diffs.append(Vector2i(_last_snapshot_tick, _local_tick))
				if _pending_diffs.size() > MAX_TRACKED_DIFFS:
					_settle_diff(_pending_diffs.pop_front())
		ClientPrediction.Result.HARD_RESET:
			_remember(_hard_reset_ticks, _local_tick)
	_consecutive_matches = 0


# Server's substituted-inputs counter (modulo 65536, cumulative). Returns true if it rose
# since the last reconciled snapshot, in which case it switches to sending with redundancy R = 8 for
# a while.
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


# Settles the pending differences that have been waiting DIFF_SETTLE_TICKS for their event.
func _settle_pending_diffs() -> void:
	while not _pending_diffs.is_empty() and _local_tick - _pending_diffs[0].y >= DIFF_SETTLE_TICKS:
		_settle_diff(_pending_diffs.pop_front())


# A final difference: combat if an own event explains it, gate if a change of the fort
# gate explains it, and otherwise a prediction failure.
func _settle_diff(pending: Vector2i) -> void:
	if _is_imposed_at(pending.x):
		_combat_diffs += 1
		_explained_diffs += 1
		return
	if _is_gate_change_at(pending.x):
		_gate_diffs += 1
		_explained_diffs += 1
		return
	_unexplained_diffs += 1
	_remember(_unexplained_ticks, pending.y)


# true if a gate change for the own realm explains a difference in the snapshot of tick [param server_tick].
func _is_gate_change_at(server_tick: int) -> bool:
	for change: Vector2i in _gate_changes:
		if server_tick >= change.x and server_tick <= change.y:
			return true
	return false


# Movement layer of the own realm (its bit) at the gate of fortress [param fortress_id] for the last
# predicted tick, according to what is known now; -1 without a prediction running, without a realm or without that fortress's state.
func _own_gate_bit_at_prediction(fortress_id: int) -> int:
	if not _prediction.is_started():
		return -1
	var realm: int = _welcome.realm if _welcome != null else (_config.realm if _config != null else 0)
	var bit: int = PlayerCharacter.realm_layer(realm)
	if bit == 0:
		return -1
	var layers: int = _fortress_view.get_gate_layers_for_tick(fortress_id, _prediction.get_predicted_tick())
	return layers & bit if layers >= 0 else -1


# After applying [param object_state]: if the gate changes for the own realm in ticks that were already predicted with the
# old one ([param bit_before] is the bit from before applying it), records the interval of snapshots that this explains.
func _note_gate_change(object_state: NetMessages.ObjectState, bit_before: int) -> void:
	if bit_before < 0:
		return
	var predicted: int = _prediction.get_predicted_tick()
	if object_state.tick >= predicted:
		return
	var bit_after: int = _own_gate_bit_at_prediction(object_state.net_id)
	if bit_after < 0 or bit_after == bit_before:
		return
	_gate_changes.append(Vector2i(object_state.tick + 1, predicted + COMBAT_EXPLAIN_TICKS))
	if _gate_changes.size() > MAX_TRACKED_DIFFS:
		_gate_changes.remove_at(0)


# true if an own combat event from server tick [param server_tick] or the previous
# COMBAT_EXPLAIN_TICKS imposed state on the local player.
func _is_imposed_at(server_tick: int) -> bool:
	for imposed: int in _imposed_ticks:
		if server_tick >= imposed and server_tick <= imposed + COMBAT_EXPLAIN_TICKS:
			return true
	return false


# Records the own events with which the server imposes state on the local player, even if the client does not
# predict it: a hit received (stagger, stun, knockback, stamina spent when blocking, health; and
# since protocol 6 the interruption of drinking or lifting, bit 5, which is also a hit received),
# their own blocked hit (the attacker is left staggering), their death and their respawn; and (docs/abilities.md,
# section 5.4) a movement effect on themselves (slow or root STATUS: the server writes
# its slot), their knockdown (DOWNED), lifting or executing where they are the knocked-down or the actor (INTERACT: the
# server starts and cuts those actions) and their own LOADOUT (weapons and charges on spawning or at camp).
func _note_imposed_state(event: NetMessages.EntityEvent) -> void:
	var imposed: bool = false
	match event.event:
		NetMessages.EntityEvent.Kind.HIT:
			imposed = event.net_id == _net_id or (event.attacker == _net_id
					and (event.hit_flags & NetMessages.EntityEvent.HIT_FLAG_PARRIED) != 0)
		NetMessages.EntityEvent.Kind.DEATH, NetMessages.EntityEvent.Kind.RESPAWN, \
				NetMessages.EntityEvent.Kind.DOWNED, NetMessages.EntityEvent.Kind.LOADOUT:
			imposed = event.net_id == _net_id
		NetMessages.EntityEvent.Kind.STATUS:
			var status: StatusTicks = CombatCatalog.status(event.status_id)
			imposed = event.net_id == _net_id and status != null and status.is_movement()
		NetMessages.EntityEvent.Kind.INTERACT:
			imposed = event.net_id == _net_id or event.actor == _net_id
	if not imposed:
		return
	_imposed_ticks.append(event.tick)
	if _imposed_ticks.size() > MAX_TRACKED_DIFFS:
		_imposed_ticks.remove_at(0)


# --- Inputs -----------------------------------------------------------------------------------

# INPUT_BATCH from 5.4. It is sent once per physics tick, also on ticks with 0 steps.
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
			# A gap in the ring: only the consecutive inputs up to newest count.
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


# true if it must send with R = 8: substitutions rose recently or ENet measures loss.
func _is_lossy() -> bool:
	if _local_tick - _loss_sampled_tick >= LOSS_SAMPLE_TICKS:
		_loss_sampled_tick = _local_tick
		_high_loss = _transport.get_packet_loss(SERVER_PEER_ID) > LOSS_THRESHOLD
	return _high_loss or _local_tick < _lossy_until_tick


# View offset of the input of tick [param tick]: (tick - render_tick seen) × 16, between 0 and
# 65535. Before the interpolation clock starts (render_tick = 0) there is no view to measure.
func _view_offset_q(tick: int) -> int:
	var drawn: float = _remote_world.get_last_drawn_render_tick()
	if drawn <= 0.0:
		return 0
	return clampi(roundi((float(tick) - drawn) * VIEW_OFFSET_SCALE), 0,
			NetMessages.MAX_VIEW_OFFSET_Q)


# --- Connection -------------------------------------------------------------------------------

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


# ENet has connected and authentication begins: HELLO.
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
	# With a ticket (docs/platform.md §5.4): the character and the 52 B from enter; the realm and name are those of the
	# character, which the zone ignores (those of the claim take precedence).
	if _config.has_ticket():
		hello.character_id = _config.character_id
		hello.ticket = _config.ticket
	if _cheater != null:
		_cheater.tamper_hello(hello)
	if hello_hook.is_valid():
		hello_hook.call(hello)
	_hello_local_tick = _local_tick
	if _transport.send_auth(SERVER_PEER_ID, hello.encode()) != OK:
		_close_session(TEXT_CONNECTION_LOST)
		return
	_state = State.HELLO_SENT


# WELCOME or REJECT.
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


# Authentication completed on both sides: sending is now possible.
func _on_peer_connected(peer_id: int) -> void:
	if peer_id != SERVER_PEER_ID or _state != State.HELLO_SENT or _welcome == null:
		return
	_state = State.WELCOMED
	# The template chosen before connecting (realm choice or --loadout) already applies to the first
	# spawn: LOADOUT_SELECT is accepted from the WELCOME (docs/abilities.md, section 5.1).
	if _config != null and _config.get_loadout_template_id() != 0:
		send_loadout_select(_config.get_loadout_template_id())
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


# Ends the session: it no longer simulates or sends, and a notice is given only once.
func _close_session(text: String) -> void:
	if _state == State.CLOSED:
		return
	_state = State.CLOSED
	_last_disconnect_text = text
	_event_queue.clear()
	_tracker_only.clear()
	_war_queue.clear()
	_party.clear()
	_status_trackers.clear()
	if is_instance_valid(_projectile_world):
		_projectile_world.clear()
	if is_instance_valid(_transport):
		_transport.close()
	set_physics_process(false)
	disconnected.emit(text)


# PARTY_INVITE, PARTY_KICK or PARTY_LEADER for [param target_name] (without control characters or BBCode).
func _send_party_target(msg_type: int, target_name: String) -> bool:
	var request := NetMessages.PartyTargetRequest.make(msg_type, ChatText.clean(target_name))
	var bytes: PackedByteArray = request.encode()
	if _state != State.IN_WORLD or NetMessages.PartyTargetRequest.decode(bytes) == null:
		return false
	if _transport.send(SERVER_PEER_ID, NetProtocol.CH_RELIABLE, bytes) != OK:
		return false
	_party_messages_sent += 1
	return true


# --- Packets ----------------------------------------------------------------------------------

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
				_projectile_world.on_despawn(despawn.net_id, despawn.despawn_tick, despawn.reason)
				projectile_despawned.emit(despawn.net_id, despawn.despawn_tick, despawn.reason)
			else:
				_status_trackers.erase(despawn.net_id)
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
		NetProtocol.MSG_INVENTORY_DELTA, NetProtocol.MSG_INVENTORY_FULL, NetProtocol.MSG_WALLET_UPDATE, \
				NetProtocol.MSG_PROGRESS_UPDATE:
			_on_progress_message(bytes)
		_:
			_malformed_packets += 1


# Inventory and progress (protocol 7, docs/progression.md §4.6 and §12): they are decoded and emitted through their signal on
# arrival; malformed ones are counted.
func _on_progress_message(bytes: PackedByteArray) -> void:
	match NetMessages.peek_type(bytes):
		NetProtocol.MSG_INVENTORY_DELTA:
			var delta: ProgressMessages.InventoryDelta = ProgressMessages.InventoryDelta.decode(bytes)
			if delta == null:
				_malformed_packets += 1
				return
			_inventory_deltas += 1
			_inventory.on_delta(delta)
			inventory_delta_received.emit(delta)
		NetProtocol.MSG_INVENTORY_FULL:
			var page: ProgressMessages.InventoryFull = ProgressMessages.InventoryFull.decode(bytes)
			if page == null:
				_malformed_packets += 1
				return
			_inventory_fulls += 1
			_inventory.on_full_page(page)
			inventory_full_received.emit(page)
		NetProtocol.MSG_WALLET_UPDATE:
			var wallet: ProgressMessages.WalletUpdate = ProgressMessages.WalletUpdate.decode(bytes)
			if wallet == null:
				_malformed_packets += 1
				return
			_wallet_updates += 1
			_progress.on_wallet(wallet)
			wallet_updated.emit(wallet)
		NetProtocol.MSG_PROGRESS_UPDATE:
			var progress: ProgressMessages.ProgressUpdate = ProgressMessages.ProgressUpdate.decode(bytes)
			if progress == null:
				_malformed_packets += 1
				return
			_progress_updates += 1
			_progress.on_progress(progress)
			progress_updated.emit(progress)


# A SNAPSHOT always feeds the interpolation clock and the remotes; the newest is stored
# to reconcile in the tick's next step.
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


# OBJECT_STATE: FortressView stores the change with its tick and applies it when the render tick
# reaches it (docs/fortress.md, section 2).
func _on_object_state(bytes: PackedByteArray) -> void:
	var object_state: NetMessages.ObjectState = NetMessages.ObjectState.decode(bytes)
	if object_state == null:
		_malformed_packets += 1
		return
	_object_states_received += 1
	var gate_bit_before: int = _own_gate_bit_at_prediction(object_state.net_id)
	_fortress_view.on_object_state(object_state)
	_note_gate_change(object_state, gate_bit_before)


# SCOREBOARD: gathered by pages and, once complete, published.
func _on_scoreboard(bytes: PackedByteArray) -> void:
	var scoreboard: NetMessages.Scoreboard = NetMessages.Scoreboard.decode(bytes)
	if scoreboard == null:
		_malformed_packets += 1
		return
	_scoreboards_received += 1
	if _scoreboard.apply(scoreboard):
		scoreboard_updated.emit(_scoreboard)


# ENTITY_EVENT: own ones are delivered now; others' wait for their render tick.
func _on_entity_event(bytes: PackedByteArray) -> void:
	var event: NetMessages.EntityEvent = NetMessages.EntityEvent.decode(bytes)
	if event == null:
		_malformed_packets += 1
		return
	# War notices and NPC attack notices (protocol v3) are nobody's combat events: they are
	# counted separately. WAR waits for its render tick; TELEGRAPH is a warning and is delivered on arrival.
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
		_deliver_combat_event(event, true)
	else:
		_event_queue.push(event)


func _on_spawn(bytes: PackedByteArray) -> void:
	var spawn: NetMessages.EntitySpawn = NetMessages.EntitySpawn.decode(bytes)
	if spawn == null:
		_malformed_packets += 1
		return
	# The kind before is_yours: a projectile is never the own character (docs/abilities.md, 5.3).
	if spawn.kind == NetProtocol.EntityKind.PROJECTILE:
		_projectile_spawns_received += 1
		_projectile_ids[spawn.net_id] = true
		_projectile_world.on_spawn(spawn)
		projectile_spawned.emit(spawn)
		return
	# An id that comes back as an entity no longer belongs to a projectile (ids share a space and quarantine).
	_projectile_ids.erase(spawn.net_id)
	if spawn.is_yours:
		_on_own_spawn(spawn)
	elif spawn.kind == NetProtocol.EntityKind.STRUCTURE:
		# Structure: FortressView creates the fortress with the SPAWN's full fields.
		_structure_spawns_received += 1
		_fortress_view.on_spawn(spawn)
	else:
		_directory.remember_spawn(spawn)
		_remote_world.on_spawn(spawn)


# Own SPAWN (section 3, step 5): starts prediction with the spawn state.
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
	# After _ready() (which rewrites the mask) and with the same realm as the server: the
	# closed gates of forts stop their owner's enemies. Remotes do not collide.
	character.set_realm_collision(spawn.realm)
	_character = character
	_net_id = spawn.net_id
	_spawn_tick = spawn.spawn_tick
	_own_teleport = spawn.teleport_counter
	_own_appearance = spawn.appearance.duplicate()
	_progress.set_spawn_level(spawn.level)
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
	_projectile_world.set_local(spawn.net_id, spawn.realm,
			StringName(_welcome.zone_id) if _welcome != null else &"", character, _prediction, _rtt_ticks)
	_state = State.IN_WORLD
	local_spawned.emit(character)


# --- Helpers ----------------------------------------------------------------------------------

func _instantiate_character() -> PlayerCharacter:
	var scene: PackedScene = load(PLAYER_SCENE_PATH) as PackedScene
	if scene == null:
		push_error("[Eldmark] No se pudo cargar la escena %s" % PLAYER_SCENE_PATH)
		return null
	return scene.instantiate() as PlayerCharacter


# The cheating bot of [param config], or null if there is no cheating to do. Only bots cheat;
# an unknown mode is reported and the bot plays clean.
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


# Simulation fingerprint (section 3), computed on an instance inside the tree after
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


# Adds an element to a list of remembered events without exceeding MAX_REMEMBERED_EVENTS.
func _remember(list: Array[int], value: int) -> void:
	if list.size() < MAX_REMEMBERED_EVENTS:
		list.append(value)


# Opens the state log ([member ClientConfig.state_log_path]) the first time it is needed.
# Returns true if there is an open log to write to.
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
	report["build"] = BuildInfo.build_id()
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
	report["character_id"] = str(_config.character_id) if _config != null else "0"
	if _inventory.has_inventory():
		report["progress"] = progress_report()
	for key: Variant in report_extra:
		report[key] = report_extra[key]
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
