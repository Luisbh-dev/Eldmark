class_name SwarmBot
extends Node
## Lightweight bot of the load swarm (docs/networking.md, sections 14, 15 and 17.5; TEC-11).
## [br][br]
## It neither simulates nor loads the zone: it has no [PlayerCharacter] of its own, nor
## [ClientPrediction], nor [RemoteWorld]. It is the bare minimum for the server to treat it like a real
## client and to measure what it costs:
## [codeblock]
## HELLO -> WELCOME -> CLIENT_READY 1 s after connecting (no zone to load; see READY_DELAY_TICKS)
##            -> own SPAWN
## every tick: poll, TickSync steps -> BotBrain inputs (guided by the position of the own
##            state in the last snapshot) -> INPUT_BATCH with ack_snapshot_tick -> flush
## every SNAPSHOT: only the header is read (the tick, the ack, the margin, the substitutions and the
##            own state) and its records are counted; it feeds TickSync and InterpolationClock
## [/codeblock]
## [TickSync] and [InterpolationClock] are the real ones, so the bot runs ahead of the server just
## enough and its inputs arrive on time, like a client's; the only difference is that the position the
## [BotBrain] decides with is the snapshot's (with the network delay), not that of a local simulation.
## Each bot has its own [NetTransport] (and therefore its own [SceneMultiplayer], registered under its
## node's path).
## [br][br]
## [b]Combat brain[/b] ([code]--bot-brain=combat[/code], [member ClientConfig.bot_brain]): the bot
## fights with [constant BotBrain.Pattern.COMBAT] like a real player, without simulating anything. It
## knows who is an enemy from the ENTITY_SPAWN messages (realm and kind; only players the server would
## let it damage) and where they are from the snapshots, of which it decodes only a fraction of the
## records in each ([constant ENEMY_SCAN_STRIDE]): with 128 bots, decoding them all would cost more than
## the server, and a bot is fine with positions a few tenths of a second old. Each input carries the
## [code]view_offset_q[/code] a client would send (its tick minus the draw tick), so the server does the
## real rewind, and when it dies it asks to respawn as soon as it can (RESPAWN_REQUEST).
## [br][br]
## [b]Siege brain[/b] ([code]--bot-brain=siege[/code], GUE-15): like the combat one (enemies from the
## ENTITY_SPAWN messages, including the war NPCs, and positions from the snapshots), but with
## [constant BotBrain.Pattern.SIEGE]: it follows its realm's route (the points of
## [code]data/routes/<zone>.tres[/code], in a straight line from one to the next: the server simulates
## the movement and sets the ground), hits the fort's gate, enters the circle and fights the nearest
## enemy. The [SiegeView] is filled by hand with the fields of the fortress's ENTITY_SPAWN and of each
## OBJECT_STATE ([method SiegeView.update_from_fields]), with no [FortressView] or scene; the positions of
## the gate and the circle come from the routes ([method SiegeView.set_places_from_routes]). Since F6b it
## looks for the war NPCs first ([method BotBrain.set_defender_finder]) and dodges hits announced with
## TELEGRAPH ([BotThreatSight]). Since GUE-44 it also tracks the players of its realm (spawns and the
## same snapshot records) to count its own at its camp's rally point
## ([method BotBrain.set_ally_counter]).
## [br][br]
## [b]Statistics[/b] ([method get_stats]): ENet upload and download bytes since it appeared (with ENet
## headers, without UDP/IP ones), snapshots received and their average size, records per snapshot, and
## what [BotSwarm] dumps into its report; with the siege brain, also the server tick at which it reached
## the fort ([code]fort_reached_tick[/code], GUE-16).

## Session phase.
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
## Id under which the bot sees the server.
const SERVER_PEER_ID: int = 1
## ENet timeout when connecting (ms).
const CONNECT_TIMEOUT_MS: int = 3000
## Radius (m) within which each bot wanders around its spawn point.
const BOT_RADIUS: float = 30.0
## Realms the bots are divided among when the configuration does not fix any (those of the zones with
## camps: Vado Gris).
const DEFAULT_REALMS: Array[int] = [NetProtocol.Realm.VARDHEIM, NetProtocol.Realm.SOLMARCH]
## Recent inputs kept for redundancy (more than NetProtocol.INPUT_REDUNDANCY_LOSSY).
const INPUT_RING_SIZE: int = 16
## Ticks, after a rise in the server's substitutions, during which it sends with R = 8.
const LOSSY_WINDOW_TICKS: int = 120
## Scale of the interpolation delay in the INPUT_BATCH (× 8) and of the view offset (× 16).
const INTERP_DELAY_SCALE: float = 8.0
const VIEW_OFFSET_SCALE: float = 16.0
## Combat brain: from each snapshot only one in this many records is decoded (rotating).
const ENEMY_SCAN_STRIDE: int = 6
## Combat brain: minimum ticks between two respawn requests.
const RESPAWN_RETRY_TICKS: int = 30
## Ticks it waits before CLIENT_READY after connecting (1 s), like a client loading the zone. The
## authentication confirmation travels on ENet channel 0 and CLIENT_READY on channel 3, which are not
## ordered relative to each other: if the confirmation is lost (with 64 bots on one machine, the server's
## UDP buffer fills up during its 70 ms stalls) and CLIENT_READY arrives first, the server drops it as a
## "paquete ajeno al protocolo" (packet foreign to the protocol) and the bot stays stuck loading until it
## is kicked out (2 of every 3 runs of 64 bots, docs/platform.md §19.18). After 1 s, ENet has already
## resent the confirmation.
const READY_DELAY_TICKS: int = 60
const TEXT_CONNECT_FAILED: String = "No se pudo conectar con el servidor %s:%d"
const TEXT_CONNECTION_LOST: String = "Se perdió la conexión con el servidor"
const TEXT_LEFT: String = "Ha salido de la zona"
const TEXT_BAD_REPLY: String = "Respuesta del servidor no válida"

## Fingerprint of the simulation, computed only once per process (it is the same for all the bots).
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
# Siege brain: what it knows about the fort (OBJECT_STATE fields), the zone's routes and the fortress it follows.
var _siege_mode: bool = false
var _siege_view: SiegeView = null
var _siege_routes: ApproachRoutes = null
var _threat_sight: BotThreatSight = null
var _fortress_net_id: int = 0
var _object_states_applied: int = 0
# Server tick (the snapshot's) at which the siege bot first gets within BotBrain.SIEGE_RALLY_FORT_RADIUS
# of the circle; -1 until it does (GUE-16: the load run checks that they are at the fort).
var _fort_reached_tick: int = -1
var _local_tick: int = 0
var _hello_tick: int = 0
var _ready_tick: int = 0
# Local tick at which CLIENT_READY is sent (READY_DELAY_TICKS after connecting).
var _ready_due_tick: int = 0
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

# Combat brain: the enemies it knows from the ENTITY_SPAWN messages (net_id -> last known position)
# and which are still alive, and the rotation offset with which the records are decoded.
var _enemy_positions: Dictionary[int, Vector3] = {}
# Maximum number of enemies known at once during the session (for the report).
var _enemies_known_max: int = 0
var _enemy_alive: Dictionary[int, bool] = {}
# Siege brain: the known enemies that are war NPCs (the ones it looks for first).
var _enemy_npcs: Dictionary[int, bool] = {}
# Siege brain: the players of its realm it knows from the ENTITY_SPAWN messages (net_id -> last known position) and
# which are still alive, to count them at the rally (GUE-44).
var _ally_positions: Dictionary[int, Vector3] = {}
var _ally_alive: Dictionary[int, bool] = {}
var _scan_phase: int = 0

# Statistics.
var _snapshots: int = 0
var _snapshots_late: int = 0
var _snapshots_with_state: int = 0
var _snapshot_bytes: int = 0
var _snapshot_records: int = 0
var _max_snapshot_bytes: int = 0
var _max_snapshot_records: int = 0
var _batches_sent: int = 0
var _spawns_seen: int = 0
var _projectile_spawns_seen: int = 0
var _despawns_seen: int = 0
var _events_seen: int = 0
var _event_bytes: int = 0
var _hit_events_seen: int = 0
var _respawn_requests: int = 0
var _last_respawn_request_tick: int = -1000
var _dead: bool = false
# Well-formed CHAT_MESSAGE and PARTY_* messages that have arrived (they are discarded).
var _chat_messages_seen: int = 0
var _party_messages_seen: int = 0
# Well-formed INVENTORY_DELTA, INVENTORY_FULL, WALLET_UPDATE and PROGRESS_UPDATE (protocol 7; they are discarded).
var _progress_messages_seen: int = 0
var _malformed_packets: int = 0
var _bytes_at_join: Dictionary = {}
var _bytes_final: Dictionary = {}
var _closed_local_tick: int = -1


func _init() -> void:
	_inputs.resize(INPUT_RING_SIZE)
	_view_offsets.resize(INPUT_RING_SIZE)


## Prepares swarm bot number [param index] with [param config] and starts connecting. The node must
## already be in the tree. Name: [code]NameRules.bot_name(bot_seed + index)[/code]; realm: the
## configuration's or one of [constant DEFAULT_REALMS] according to the index; brain: [BotBrain] with the
## seed [code]bot_seed + index[/code]. With [param dtls] (the pinned zone certificate, the same for the
## whole swarm) it connects over DTLS with the name [member ClientConfig.dtls_name] (docs/platform.md
## §10.2).
func setup(index: int, config: ClientConfig, dtls: TLSOptions = null) -> void:
	if _state != State.IDLE:
		return
	_index = index
	_config = config
	_siege_mode = config.bot_brain == ClientConfig.BOT_BRAIN_SIEGE
	_combat = config.bot_brain == ClientConfig.BOT_BRAIN_COMBAT or _siege_mode
	if _siege_mode:
		_siege_view = SiegeView.new()
		_threat_sight = BotThreatSight.new(_is_enemy_npc)
	_display_name = config.bot_names[index] if index < config.bot_names.size() 			else NameRules.bot_name(config.bot_seed + index)
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
	var error: Error = _transport.connect_to(config.address, config.port, CONNECT_TIMEOUT_MS,
			config.dtls_name if dtls != null else "", dtls)
	if error != OK:
		_close(TEXT_CONNECT_FAILED % [config.address, config.port])
		return
	_state = State.CONNECTING


## Leaves the zone: CLIENT_LEAVE and an orderly disconnect. [method get_state] changes to
## [constant State.CLOSED] when the connection closes.
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


## true if it already has a character on the server and is playing.
func is_in_world() -> bool:
	return _state == State.IN_WORLD


## Network id of the character (0 until the own SPAWN).
func get_net_id() -> int:
	return _net_id


## The server tick of the most recent snapshot it has received (0 if none yet).
func get_newest_server_tick() -> int:
	return _newest_snapshot_tick


func get_local_tick() -> int:
	return _local_tick


## Last own state from the server (position from the last snapshot with state).
func get_position() -> Vector3:
	return _position


## The [SiegeView] it fills with the OBJECT_STATE messages (null if it does not use the siege brain).
func get_siege_view() -> SiegeView:
	return _siege_view


## The bot's brain (null until it spawns).
func get_brain() -> BotBrain:
	return _brain


func get_tick_sync() -> TickSync:
	return _tick_sync


func get_interpolation_clock() -> InterpolationClock:
	return _interp_clock


## Text of the server's last NOTICE ("" if none arrived).
func get_last_notice_text() -> String:
	return _last_notice_text


## Bot statistics:
## [br]- [code]index[/code], [code]name[/code], [code]realm[/code], [code]state[/code], [code]net_id[/code],
## [code]spawn_tick[/code], [code]rtt_ticks[/code], [code]rejected[/code] ([code]reject_result[/code],
## [code]reject_text[/code]), [code]disconnect_text[/code], [code]last_notice[/code].
## [br]- [code]local_ticks[/code] (physics ticks since it started), [code]world_ticks[/code] (those it has
## been playing, from the own SPAWN until closing or now).
## [br]- [code]snapshots[/code] received, [code]late_snapshots[/code], [code]snapshots_with_state[/code],
## [code]snapshot_bytes[/code] (sum of their sizes), [code]avg_snapshot_bytes[/code],
## [code]max_snapshot_bytes[/code], [code]avg_snapshot_records[/code], [code]max_snapshot_records[/code].
## [br]- [code]bytes_up[/code] and [code]bytes_down[/code]: ENet bytes since the own SPAWN;
## [code]kb_up_per_s[/code] and [code]kb_down_per_s[/code] over [code]world_ticks[/code];
## [code]total_bytes_up[/code] and [code]total_bytes_down[/code] for the whole session.
## [br]- [code]batches_sent[/code], [code]target_margin[/code], [code]last_input_margin[/code],
## [code]tick_sync_adjustments[/code], [code]resyncs[/code], [code]substitution_rises[/code],
## [code]substitutions[/code] (server counter), [code]spawns_seen[/code], [code]despawns_seen[/code],
## [code]projectile_spawns_seen[/code] (protocol 6 projectiles, which the bot ignores; their DESPAWN count in
## [code]despawns_seen[/code]), [code]delay_ticks[/code], [code]jitter_ticks[/code], [code]malformed_packets[/code].
## [br]- From chat and parties (protocol 5), which the bot decodes and discards: [code]chat_messages_seen[/code]
## (CHAT_MESSAGE) and [code]party_messages_seen[/code] (PARTY_INVITATION, PARTY_ROSTER and PARTY_STATUS).
## [br]- From inventory and progression (protocol 7, docs/progression.md §4.6), which it also decodes and discards:
## [code]progress_messages_seen[/code] (INVENTORY_DELTA, INVENTORY_FULL, WALLET_UPDATE and PROGRESS_UPDATE).
## [br]- From combat: [code]combat[/code] (whether it fights), [code]events_seen[/code] and [code]event_bytes[/code]
## (ENTITY_EVENT messages received and their size), [code]hit_events_seen[/code], [code]enemies_known[/code] (and its maximum, [code]enemies_known_max[/code]),
## [code]dead[/code] and [code]respawn_requests[/code].
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
	var stats: Dictionary = {
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
		"projectile_spawns_seen": _projectile_spawns_seen,
		"despawns_seen": _despawns_seen,
		"events_seen": _events_seen,
		"event_bytes": _event_bytes,
		"hit_events_seen": _hit_events_seen,
		"combat": _combat,
		"enemies_known": _enemy_positions.size(),
		"enemies_known_max": _enemies_known_max,
		"dead": _dead,
		"respawn_requests": _respawn_requests,
		"delay_ticks": _interp_clock.get_delay_ticks(),
		"jitter_ticks": _interp_clock.get_jitter_ticks(),
		"malformed_packets": _malformed_packets,
		"chat_messages_seen": _chat_messages_seen,
		"party_messages_seen": _party_messages_seen,
		"progress_messages_seen": _progress_messages_seen,
		"siege": _siege_mode,
	}
	if _siege_mode:
		stats["siege_task"] = BotBrain.SiegeTask.keys()[_brain.get_siege_task()] if _brain != null else "NONE"
		stats["siege_route"] = String(_brain.get_siege_route()) if _brain != null else ""
		stats["fortress_known"] = _siege_view.known
		stats["object_states_applied"] = _object_states_applied
		stats["fort_reached_tick"] = _fort_reached_tick
	return stats


# Siege: records the server tick [param server_tick] the first time the bot is within
# [constant BotBrain.SIEGE_RALLY_FORT_RADIUS] (horizontally) of the circle's center, the same distance
# the brain uses to count its own as "fighting at the fort".
func _note_fort_reached(server_tick: int) -> void:
	if not _siege_mode or _fort_reached_tick >= 0 or _siege_view.circle_radius <= 0.0:
		return
	var center: Vector3 = _siege_view.circle_center
	if Vector2(_position.x - center.x, _position.z - center.z).length() <= BotBrain.SIEGE_RALLY_FORT_RADIUS:
		_fort_reached_tick = server_tick


# --- Tick loop --------------------------------------------------------------------------------

func _physics_process(_delta: float) -> void:
	if _state == State.IDLE or _state == State.CLOSED:
		return
	_local_tick += 1
	_transport.poll(_local_tick)
	if _state == State.WELCOMED and _local_tick >= _ready_due_tick:
		_send_client_ready()
	if _state == State.IN_WORLD:
		_play_tick()
	_interp_clock.advance(_local_tick)
	_transport.flush()


# The prediction steps decided by TickSync each generate the input for the next tick, and the batch is
# sent. There is no simulation: the position for the brain is that of the last own state.
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


# INPUT_BATCH from 5.4: from max(ack + 1, newest - R + 1, first real tick) to newest, with R = 4 (8 if the
# server's substitutions rose recently).
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


# View offset of the input at tick [param tick] ((tick - draw tick) × 16): what a client would send, so
# the server does the real rewind. Only with the combat brain; without it (and before the interpolation
# clock starts) there is no view to measure.
func _view_offset_q(tick: int) -> int:
	if not _combat:
		return 0
	var drawn: float = _interp_clock.get_render_tick()
	if drawn <= 0.0:
		return 0
	return clampi(roundi((float(tick) - drawn) * VIEW_OFFSET_SCALE), 0, NetMessages.MAX_VIEW_OFFSET_Q)


# --- Connection -------------------------------------------------------------------------------

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
	if _siege_mode:
		_load_siege_data(welcome.zone_id)
	if _transport.complete_auth(SERVER_PEER_ID) != OK:
		_close(TEXT_CONNECTION_LOST)


# Authenticated on both sides: there is no zone to load, but CLIENT_READY waits READY_DELAY_TICKS (see the constant).
func _on_peer_connected(peer_id: int) -> void:
	if peer_id != SERVER_PEER_ID or _state != State.HELLO_SENT or _welcome == null:
		return
	_state = State.WELCOMED
	_ready_due_tick = _local_tick + READY_DELAY_TICKS


func _send_client_ready() -> void:
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


# Ends the session: stops playing and closes the transport.
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
			_despawns_seen += 1
			if _combat:
				var despawn: NetMessages.EntityDespawn = NetMessages.EntityDespawn.decode(bytes)
				if despawn != null:
					_enemy_positions.erase(despawn.net_id)
					_enemy_alive.erase(despawn.net_id)
					_enemy_npcs.erase(despawn.net_id)
					_ally_positions.erase(despawn.net_id)
					_ally_alive.erase(despawn.net_id)
					if _threat_sight != null:
						_threat_sight.forget(despawn.net_id)
		NetProtocol.MSG_ENTITY_EVENT:
			# Combat events do nothing to a bot, but they must be well formed.
			var event: NetMessages.EntityEvent = NetMessages.EntityEvent.decode(bytes)
			if event == null:
				_malformed_packets += 1
			else:
				_events_seen += 1
				_event_bytes += bytes.size()
				if event.event == NetMessages.EntityEvent.Kind.HIT:
					_hit_events_seen += 1
				elif _threat_sight != null:
					_threat_sight.note(event)
		NetProtocol.MSG_NOTICE:
			var notice: NetMessages.Notice = NetMessages.Notice.decode(bytes)
			if notice == null:
				_malformed_packets += 1
			else:
				_last_notice_text = notice.text
		NetProtocol.MSG_OBJECT_STATE:
			var object_state: NetMessages.ObjectState = NetMessages.ObjectState.decode(bytes)
			if object_state == null:
				_malformed_packets += 1
			elif _siege_mode:
				_apply_fortress_fields(object_state)
		NetProtocol.MSG_SCOREBOARD:
			if NetMessages.Scoreboard.decode(bytes) == null:
				_malformed_packets += 1
		# Chat and parties (protocol 5, docs/social.md 12.7): the server treats the bot as a player, so it
		# receives its realm's "zona" (zone) and "decir" (say) messages, whispers and invitations (with their
		# system notice). It answers none of them (an invitation expires on its own); it only decodes and
		# discards them.
		NetProtocol.MSG_CHAT_MESSAGE:
			if NetMessages.ChatMessage.decode(bytes) == null:
				_malformed_packets += 1
			else:
				_chat_messages_seen += 1
		NetProtocol.MSG_PARTY_INVITATION:
			if NetMessages.PartyInvitation.decode(bytes) == null:
				_malformed_packets += 1
			else:
				_party_messages_seen += 1
		NetProtocol.MSG_PARTY_ROSTER:
			if NetMessages.PartyRoster.decode(bytes) == null:
				_malformed_packets += 1
			else:
				_party_messages_seen += 1
		NetProtocol.MSG_PARTY_STATUS:
			if NetMessages.PartyStatus.decode(bytes) == null:
				_malformed_packets += 1
			else:
				_party_messages_seen += 1
		# Inventory and progression (protocol 7, docs/progression.md §4.6): owner only. The bot has no inventory
		# window: it decodes and discards them, and only what fails to decode counts as malformed.
		NetProtocol.MSG_INVENTORY_DELTA, NetProtocol.MSG_INVENTORY_FULL, NetProtocol.MSG_WALLET_UPDATE, \
				NetProtocol.MSG_PROGRESS_UPDATE:
			if _decode_progress_message(bytes) == null:
				_malformed_packets += 1
			else:
				_progress_messages_seen += 1
		_:
			_malformed_packets += 1


# The decoded inventory or progression message (null if malformed or not one of the S→C ones).
static func _decode_progress_message(bytes: PackedByteArray) -> RefCounted:
	match NetMessages.peek_type(bytes):
		NetProtocol.MSG_INVENTORY_DELTA:
			return ProgressMessages.InventoryDelta.decode(bytes)
		NetProtocol.MSG_INVENTORY_FULL:
			return ProgressMessages.InventoryFull.decode(bytes)
		NetProtocol.MSG_WALLET_UPDATE:
			return ProgressMessages.WalletUpdate.decode(bytes)
		NetProtocol.MSG_PROGRESS_UPDATE:
			return ProgressMessages.ProgressUpdate.decode(bytes)
	return null


# Only the SNAPSHOT header is read (see NetMessages.Snapshot): this bot draws nobody, and decoding the
# records of 57 players in every bot of a swarm would cost more than the server.
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
		# The own state is followed by the extra block (health), which always accompanies it.
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
			_note_fort_reached(server_tick)
		if _combat:
			_note_extra_block(bytes, server_tick)


# Combat brain: decodes the position and health of one in every ENEMY_SCAN_STRIDE records of the
# snapshot (rotating the offset on each snapshot) and updates only the enemies (and, with the siege
# brain, the allies) it already knows.
func _scan_enemies(bytes: PackedByteArray, section_offset: int) -> void:
	if section_offset >= bytes.size() or (_enemy_positions.is_empty() and _ally_positions.is_empty()):
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
			elif _ally_positions.has(net_id):
				_ally_positions[net_id] = NetMath.unpack_position(bytes.decode_u64(record_offset + 2))
				_ally_alive[net_id] = is_standing_record(bytes, record_offset)
			record += ENEMY_SCAN_STRIDE
		running += count
		offset += count * EntityRecord.SIZE


## true if the record in [param bytes] at [param record_offset] ([EntityRecord]) belongs to someone alive
## and standing: its health is not [constant EntityRecord.HEALTH_Q_DEAD] and its action (byte 19, the low
## 4 bits) is not DOWNED. A downed player publishes its downed health, which is never 0
## ([code]Combatant.publish[/code]): without looking at the action it would count as alive. These are the
## allies it counts at the rally (GUE-44), like [code]ZoneServer._count_allies[/code] and [BotAllySight].
static func is_standing_record(bytes: PackedByteArray, record_offset: int) -> bool:
	return bytes[record_offset + 20] != EntityRecord.HEALTH_Q_DEAD \
			and (bytes[record_offset + 19] & 15) != CombatState.Action.DOWNED


# Combat brain: reads the snapshot's extra block (health, state, respawn tick) and, if dead, asks to
# respawn as soon as it can.
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


# Combat brain: the living enemy closest to [param position] (the last position known of it; with the
# height weighted, BotBrain.target_distance_squared), or null.
func _find_enemy(position: Vector3) -> Variant:
	var best: Variant = null
	var best_distance: float = INF
	for net_id: int in _enemy_positions:
		if not _enemy_alive[net_id]:
			continue
		var enemy_position: Vector3 = _enemy_positions[net_id]
		var distance: float = BotBrain.target_distance_squared(position, enemy_position)
		if distance < best_distance:
			best_distance = distance
			best = enemy_position
	return best


# Siege brain: the living enemy war NPC closest to [param position], or null.
func _find_defender(position: Vector3) -> Variant:
	var best: Variant = null
	var best_distance: float = INF
	for net_id: int in _enemy_npcs:
		if not _enemy_alive.get(net_id, false):
			continue
		var enemy_position: Vector3 = _enemy_positions[net_id]
		var distance: float = BotBrain.target_distance_squared(position, enemy_position)
		if distance < best_distance:
			best_distance = distance
			best = enemy_position
	return best


# Siege brain: how many players of its realm, alive and standing (is_standing_record) and not counting
# itself, are within [param radius] meters (horizontally) of [param center], according to their last
# known position (the rally counter, GUE-44).
func _count_allies(center: Vector3, radius: float) -> int:
	var limit: float = radius * radius
	var found: int = 0
	for net_id: int in _ally_positions:
		if not _ally_alive[net_id]:
			continue
		var ally: Vector3 = _ally_positions[net_id]
		var dx: float = ally.x - center.x
		var dz: float = ally.z - center.z
		if dx * dx + dz * dz <= limit:
			found += 1
	return found


# Siege brain: true if NPC [param net_id] is one of the enemy war NPCs it knows from their spawns (the
# only ones whose telegraphed hits it avoids: those of its own realm's NPCs do not damage it).
func _is_enemy_npc(net_id: int) -> bool:
	return _enemy_npcs.has(net_id)


# Siege brain: the telegraphed hits still active at the tick of the input being decided.
func _find_threats(_position: Vector3) -> Array[BotBrain.Threat]:
	if _threat_sight == null:
		return []
	return _threat_sight.find(_predicted_tick)


# Snapshot records, summing the counters of its sections without decoding them.
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


# Counter of the server's substituted inputs (mod 65536): if it rises, it is sent with more redundancy.
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
	# A projectile (kind 3, protocol 6) is not an entity to the bot: neither an enemy nor its own character.
	if spawn.kind == NetProtocol.EntityKind.PROJECTILE:
		_projectile_spawns_seen += 1
		return
	if not spawn.is_yours:
		_spawns_seen += 1
		if spawn.kind == NetProtocol.EntityKind.STRUCTURE:
			# The fortress: the spawn carries its full fields (like an OBJECT_STATE).
			if _siege_mode and _fortress_net_id == 0:
				_fortress_net_id = spawn.net_id
				_apply_fortress_fields(spawn.to_object_state())
			return
		if _combat and _is_enemy_spawn(spawn):
			_enemy_positions[spawn.net_id] = spawn.state.position
			_enemies_known_max = maxi(_enemies_known_max, _enemy_positions.size())
			_enemy_alive[spawn.net_id] = true
			if spawn.kind == NetProtocol.EntityKind.NPC:
				_enemy_npcs[spawn.net_id] = true
		elif _siege_mode and _is_ally_spawn(spawn):
			_ally_positions[spawn.net_id] = spawn.state.position
			_ally_alive[spawn.net_id] = true
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
	if _siege_mode:
		_brain = BotBrain.new(_config.bot_seed + _index, BotBrain.Pattern.SIEGE, _position, BOT_RADIUS)
		_brain.set_enemy_finder(_find_enemy)
		_brain.set_defender_finder(_find_defender)
		_brain.set_threat_finder(_find_threats)
		_brain.set_ally_counter(_count_allies)
		_brain.set_siege(_siege_view, _siege_routes, _realm)
	elif _combat:
		_brain = BotBrain.new(_config.bot_seed + _index, BotBrain.Pattern.COMBAT, _position, BOT_RADIUS)
		_brain.set_enemy_finder(_find_enemy)
	else:
		_brain = BotBrain.new(_config.bot_seed + _index, BotBrain.Pattern.WANDER, _position, BOT_RADIUS)
	_joined_local_tick = _local_tick
	_bytes_at_join = _byte_counters()
	_state = State.IN_WORLD


# --- Siege --------------------------------------------------------------------------------------

# true if spawn [param spawn] belongs to someone this bot can attack: a player of another realm and, with
# the siege brain, also a war NPC (the Hollow and the defenders have a definition id; the dummies do
# not).
func _is_enemy_spawn(spawn: NetMessages.EntitySpawn) -> bool:
	if spawn.state == null:
		return false
	var attackable_kind: bool = spawn.kind == NetProtocol.EntityKind.PLAYER \
			or (_siege_mode and spawn.kind == NetProtocol.EntityKind.NPC and spawn.npc_def_id > 0)
	return attackable_kind and FactionRules.can_damage(_realm, spawn.realm, StringName(_welcome.zone_id))


# true if spawn [param spawn] belongs to a player of its realm (other than itself): those it counts at the rally (GUE-44).
func _is_ally_spawn(spawn: NetMessages.EntitySpawn) -> bool:
	return spawn.state != null and spawn.kind == NetProtocol.EntityKind.PLAYER and spawn.realm == _realm


# The routes of the WELCOME's zone and, with them, where the fort's gate and circle are.
func _load_siege_data(zone_id: String) -> void:
	var path: String = "res://data/routes/%s.tres" % zone_id
	if ResourceLoader.exists(path):
		_siege_routes = load(path) as ApproachRoutes
	_siege_view.set_places_from_routes(_siege_routes)


# Passes the fields of an OBJECT_STATE (or of the spawn) of the fortress to the SiegeView, without going through FortressView.
func _apply_fortress_fields(object_state: NetMessages.ObjectState) -> void:
	if object_state == null or (_fortress_net_id != 0 and object_state.net_id != _fortress_net_id):
		return
	var values: Dictionary = {}
	for field: NetMessages.ObjectField in object_state.fields:
		values[field.field_id] = field.value
	_siege_view.update_from_fields(values)
	_object_states_applied += 1


# --- Helpers ----------------------------------------------------------------------------------

# ENet bytes of the transport (the last known if it has already closed).
func _byte_counters() -> Dictionary:
	if is_instance_valid(_transport):
		_bytes_final = _transport.get_byte_counters()
	return _bytes_final


# Fingerprint of the simulation (section 3), computed once per process on a character instance inside
# the tree, after _ready().
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
