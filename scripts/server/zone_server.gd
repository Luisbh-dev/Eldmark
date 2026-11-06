class_name ZoneServer
extends Node
## Authoritative server of a zone (docs/networking.md, sections 3, 8, 9, 10, 11, 12 and 13).
## [br][br]
## It joins the pure server pieces ([NetEntityRegistry], [InputQueue], [SnapshotBuilder],
## [StateHistory], [ServerAuth], [InterestPolicy], [ServerMetrics]...) with the transport
## ([NetTransport]) and the zone world. The client only sends intents: the server simulates all
## players and never accepts a state from the client.
## [br][br]
## [b]Tick order[/b] ([method _physics_process], priority -100; it is normative):
## [codeblock]
## poll             receive: authentication, READY, LEAVE, INPUT_BATCH -> InputQueue.push(),
##                  RESPAWN_REQUEST, DEBUG_COMMAND, LOADOUT_SELECT (the pending template), chat and
##                  parties (SocialService), INVENTORY_REQUEST and INVENTORY_SYNC_REQUEST (RATE and into
##                  the progress queue, progression.md §4.2); and the console lines. With the platform
##                  (docs/platform.md §14.3), afterwards: ZonePlatform.take_events() dispatched by kind in
##                  arrival order (claim to the AuthProvider, heartbeat to the zone and its mutes to
##                  moderation, fortress to FortressPersistence, ignore, report and sanction to
##                  ModerationService; instance_closed last), AuthProvider.take_completed() (each 200: realm,
##                  capacity and WELCOME) and the expired VERIFYING peers (7 s in real time since connecting,
##                  REJECT UNAVAILABLE)
## tick += 1        s is the tick being simulated
## removals         disconnect, LEAVE or kick -> SocialService.on_peer_left (leaves its party, leadership
##                  passes to the oldest member, its invitations are cancelled), DESPAWN (reason 1) and the id
##                  goes into quarantine; the removal of a knocked-down player is preceded by their death (DEATH and KILL)
## brains (step 0)  NPCs think with the state after s - 1 and push their input for s into their InputQueue
##                  (every 6 ticks; in between they repeat their plan)
## simulate         all entities with a body (players, fakes and NPCs) by ascending net_id,
##                  with the input from InputQueue.take(s); _check_motion. Right before its own, each
##                  fake thinks (its BotBrain, with its combat state after s - 1 for the H5 kit) and
##                  pushes its input for s; the siege views, their targets and, for the siege bots
##                  (F6b), the telegraphed strikes in progress and the allies are gathered once per tick.
##                  Then, CONSUME: what each inventory-backed player drank is removed from their bag
##                  (progression.md §4.4)
## combat           CombatDirector.process_tick(), steps 2 to 9 of docs/abilities.md, section 4.1:
##                  freeze (active hit, commitment and wall of each), shots and own effects
##                  of whoever commits an attack or an ability, resolve the hits of attacks and
##                  abilities (also against the fort gates) and the flight of
##                  projectiles, apply (damage, block, controls, effects on the target, interrupts,
##                  knockdowns and deaths), status effects (pulses and expirations), the knocked-down state
##                  (bleed-out, revive and finish off), environment (fall, lethal volumes, and < -100),
##                  respawns with their template (with inventory, with their equipment), the camp refill
##                  (with inventory, CAMP_REFILL of the bag) and publish health; the
##                  ENTITY_EVENT and the ENTITY_SPAWN and ENTITY_DESPAWN of projectiles go out here, and
##                  at the end, the TELEGRAPH notices of the NPC heavy attacks starting at s; with each
##                  death, the rewards (progression.md §6.2): the NPC's to its contributors and the
##                  PvP merits of the KILL (and the LEVEL_UP of whoever levels up)
## forts            FortressController.step() (step 4b): presence in the circle, state advance of
##                  each fortress, gate layers (they apply from s + 1), WAR notices and OBJECT_STATE,
##                  captures and defending time on the scoreboard, and the capture reward and objective merits
##                  (progression.md §6.2); with the platform, FortressPersistence.step:
##                  the record of the one that changed (docs/platform.md §8); /atascado (unstuck); bodies that
##                  remain after a removal in combat
## NPCs             NpcSpawnerSystem.step(): NPC spawns and withdrawals according to the spawners and
##                  fortresses, corpses
## spawns           the pending READYs: the player appears with the state "after s" and the equipment from their
##                  inventory (progression.md §8; without it, that of their template: the pending one or the
##                  default), SPAWN, LOADOUT, INVENTORY_FULL, WALLET_UPDATE and PROGRESS_UPDATE; with the
##                  platform, CharacterSaver.track as soon as the entity exists
## inventory        ProgressService.apply_pending: the requests of the tick in arrival order, with their
##                  INVENTORY_DELTA and the imposed weapons and charges; flush: WALLET_UPDATE and PROGRESS_UPDATE
## saves            with the platform, CharacterSaver.step(s): the marked criticals and the checkpoints
##                  that are due (docs/platform.md §7.2); the snapshot is taken here, after the spawns
## social          SocialService.step(): party invitations expire (expired PARTY_INVITATION and a
##                  notice to whoever invited) and each party sends its PARTY_STATUS (2 Hz, staggered by the
##                  party id) with the state already after the spawns
## history          StateHistory.record() of all entities, already with what was imposed
## snapshots        SnapshotBuilder.begin(); interest every 6 ticks, staggered; one SNAPSHOT to each
##                  client every 2 ticks, staggered by the parity of its net_id; the zone SCOREBOARD
##                  every 2 s
## flush            flush what was sent
## metrics          ServerMetrics and, every 10 s, a line in the log
## [/codeblock]
## Spawns go after simulating, so the first simulation of a new player is that of tick
## [code]s + 1[/code], with no one-tick offset. Removals go before simulating.
## [br][br]
## [b]Saves[/b] (docs/platform.md §7.2, [CharacterSaver], [method get_saver]): each body with a lease
## is saved at its checkpoint and on critical events; when the body leaves (CLIENT_LEAVE, disconnect or end
## of the in-combat exit) its final save goes out with [code]release_lease[/code], in the order
## [code]finish[/code] → [code]ScoreKeeper.forget[/code] → (progression.md) [code]on_departure[/code]. A
## save that is definitively rejected or a [code]revoked[/code] [code]lease_lost[/code] is a removal
## without saving: [code]drop[/code], a kick with the body removed immediately (no in-combat exit) and
## the rest of the exit. The other [code]revoked[/code] responses of the heartbeat kick with their text and a
## final save (one with a different lease_id kicks nobody); its [code]maintenance[/code] warns at 10, 5 and
## 1 min, at 30 s and at 10 s and requests the shutdown at its time. [method stop] (the orderly shutdown
## of the five triggers) and [method close_instance] (the one from §6.1) send everyone's final saves and
## wait for the platform to answer them before finishing.
## [br][br]
## [b]Progress[/b] (docs/progression.md §4, §8 and §9, [ProgressService], [method get_progress]): with the
## platform, the claim record is prepared before the WELCOME (if it cannot be read, REJECT UNAVAILABLE and
## release), a removal in LOADING discards it and the spawn binds it to the body; without it, each player
## with a peer is an ephemeral character (§9.4). The spawn applies the return-to-world rule, gives the
## first-entry kit (critical) and equips the player with their inventory instead of the template;
## LOADOUT_SELECT no longer changes anything after it. The [code]progress[/code] section of the saves is
## the first one of [CharacterSaver]. The id blocks arrive as [code]id_block[/code] events. The inventory
## travels over the network (0x50–0x55) and the camp refill replenishes the bag. The rewards (§6.2): PvP
## merits come from the KILL (only with a persistent victim of another realm), an NPC's from its DEATH (to
## whoever did at least 10 % of the damage, except a defender of a fortress in a forced cycle), and the
## capture reward and objective merits, from [FortressController]; leveling up sends LEVEL_UP to the owner
## and to those of their realm who have it relevant. With the platform and [code]--fake-players[/code]
## nothing is paid out. The progression GM commands (§10, [ProgressCommands]: console, [code]/gm[/code] and
## DEBUG_COMMAND 40–43) change the character in a single GM or REVERSAL operation with its trail, critical
## save and audit; with the platform, 16 too.
## [br][br]
## [b]Combat[/b] (docs/combat.md): a [CombatDirector] carries health, hits with rewind, deaths and
## respawns; NPCs ([method add_npc], the training dummy) are bodies simulated in the same loop as
## players; the debug commands and the console go through the [CommandRegistry] and
## [code]--combat-log[/code] leaves one line per resolved hit. An [NpcSpawnerSystem]
## ([method get_npc_system]) creates and withdraws the NPCs of the zone spawners (the Hollow, the Ford
## Captain, the owner's garrison and the Gate Guardians) with the [HfsmBrain] brain; [code]--no-npcs[/code]
## turns it off.
## [br][br]
## [b]Fortresses[/b] (docs/fortress.md): a [FortressController] carries the state of each fortress of the
## zone, its gate (target of hits), the war notices and the OBJECT_STATE; [method get_fortresses] exposes
## it to the NPCs. With the platform (docs/platform.md §8, GUE-19), [FortressPersistence] applies in
## [method start], before opening the port, the records that [ZonePlatform] loaded, writes them on change
## and sends the capture and reset events to the history; the [ScoreKeeper] registers the [code]pvp[/code]
## section of the saves (behind [code]progress[/code]) with the claim totals plus those of the session.
## Respawning clears [member NetEntity.gm_forced]. [code]--battle-log[/code] leaves the war events and
## deaths in JSON Lines.
## Whoever leaves or disconnects in combat leaves the body in the world for [constant LINGER_TICKS] ticks
## (GUE-41), the /atascado command ([UnstuckTracker]) teleports whoever requests it and the scoreboard
## ([ScoreKeeper]) is sent to the whole zone every [constant SCOREBOARD_INTERVAL_TICKS] ticks.
## [br][br]
## [b]Subsystems[/b] (scripts/server/zone/, TEC-65): this file keeps the wiring ([method start]), the public API
## and the tick order above. Each concern has its own subsystem, built in [method _init] and reaching the zone
## through its [code]_z[/code]: [ZoneSessions] (connections, authentication, kicks and seats), [ZoneIntents]
## (what each client packet does), [ZoneBodies] (spawns and removals of players, fakes and NPCs), [ZoneEvents]
## (combat and war events, rewards, scoreboard), [ZoneCommands] (administration commands and the console),
## [ZoneLifecycle] (shutdown, maintenance and drain), [ZoneLingering] (bodies left in combat and /atascado),
## [ZoneBotSupport] (what fake players see) and [ZoneReport] (metrics line and JSON report). Which package
## touches which file is in docs/platform.md §14.

## Emitted at the end of each tick, once everything for the tick has been sent.
signal tick_finished(tick: int)
## A (network) player has entered the world.
signal player_joined(peer_id: int, net_id: int)
## A (network) player has left the world.
signal player_left(peer_id: int, net_id: int)
## The countdown of a shutdown requested through the console ([code]shutdown <s>[/code]) has reached 0:
## whoever runs the process ([ServerMain]) must shut the server down.
signal shutdown_requested(reason: String)
## The platform has closed this instance ([code]instance_lost[/code], [code]instance_replaced[/code] or
## [code]instance_stopped[/code], docs/platform.md §6.1): [ServerMain] handles it.
signal instance_closed(code: String)
## Maximum distance a character can travel in one tick (terminal velocity gives 0.83 m).
const MAX_STEP_DISTANCE: float = 1.5
## Below this height the character dies (falls out of the world).
const FALL_LIMIT_Y: float = CombatDirector.VOID_LIMIT_Y
## How many ticks between recomputations of each peer's interest (staggered by net_id).
const INTEREST_INTERVAL_TICKS: int = 6
## Ticks a peer may spend loading the zone without sending CLIENT_READY (60 s).
const LOADING_TIMEOUT_TICKS: int = 3600
## How many ticks between flushes of the state log to disk (1 s): if the server is killed, what came
## before is not lost.
const STATE_LOG_FLUSH_TICKS: int = 60
## How many ticks between metrics lines written to the log (10 s).
const METRICS_LOG_TICKS: int = 600
## Ticks during which a kicked player cannot rejoin (30 s): their IP or, from loopback, their name
## receive a REJECT right on connecting.
const KICK_COOLDOWN_TICKS: int = 1800
## Margin (ticks) added to the ENet RTT and to the simulator delay when bounding the RTT the client
## declares with its acks: snapshots go out every 2 ticks and have to be processed.
const RTT_SLACK_TICKS: int = 3
## Reason of the warning for each packet that the transport discards for not being part of the protocol.
const DISCARDED_REASON: String = "paquete ajeno al protocolo"
## Ticks a peer may stay connected without sending the HELLO (1.5 s). Much less than the 10 s of
## [SceneMultiplayer] authentication: an idle connection takes up one of the ENet slots.
const HELLO_TIMEOUT_TICKS: int = 90
## Reason with which the report counts (in [code]rejects[/code]) the connections cut for not sending
## the HELLO in time.
const HELLO_TIMEOUT_REASON: String = "sin HELLO a tiempo"
## Deadline of a peer in VERIFYING since it connected (ms, real time): once past, REJECT UNAVAILABLE.
## Less than the 10 s [constant NetTransport.AUTH_TIMEOUT_SECONDS], so the REJECT always arrives
## (docs/platform.md §5.2).
const VERIFY_TIMEOUT_MS: int = 7000
## Ticks to wait at most, after [method stop] or [method close_instance], for the platform to answer
## the final saves and for nothing to remain queued or in flight (10 s, docs/platform.md §7.2 and §6.1).
const SAVE_DRAIN_TICKS: int = 600
## Kick NOTICE of the §6.1 shutdown, after the final saves.
const INSTANCE_CLOSED_TEXT: String = "El servidor de la zona se ha reiniciado: vuelve a entrar"
## NOTICE of the removal without saving (§7.3): a rejected save and a lease_lost.
const SAVE_REJECTED_TEXT: String = "No se ha podido guardar tu personaje; vuelve a entrar"
const LEASE_LOST_TEXT: String = "Tu personaje ha entrado en otro servidor"
## Tick sections that appear in the metrics line (the same ones the loop measures).
const LOGGED_SECTIONS: Array[StringName] = [&"net", &"platform", &"npc_brains", &"sim", &"combat", &"combat_resolve",
		&"combat_projectiles", &"combat_events", &"war", &"npc", &"social", &"history", &"snapshot", &"flush"]
## [ServerMetrics] sections for NPCs: the brains (step 0) and the spawner system.
const SECTION_NPC_BRAINS: StringName = &"npc_brains"
## Metrics section with the dispatch of platform events and the finals of the claims (inside
## "net"; docs/platform.md §16).
const SECTION_PLATFORM: StringName = &"platform"
const SECTION_NPC: StringName = &"npc"
## [ServerMetrics] section for the fortress step (4b of the tick).
const SECTION_WAR: StringName = &"war"
## [ServerMetrics] section for the social step (invitation expiry and PARTY_STATUS). Incoming chat and
## party messages are handled in the poll and count in the "net" section.
const SECTION_SOCIAL: StringName = &"social"
## How many ticks between SCOREBOARD sends to the whole zone (2 s).
const SCOREBOARD_INTERVAL_TICKS: int = 120
## Ticks that the body of whoever leaves or disconnects "in combat" stays in the world, still and
## attackable (15 s, GUE-41).
const LINGER_TICKS: int = 900
## Player records and kicks that the report keeps (the most recent ones); anything older is summarized
## in totals. Without a cap, a client that joins and leaves in a loop would make memory grow without limit.
const MAX_LOGGED_PLAYERS: int = 1000
const MAX_LOGGED_KICKS: int = 200
## Physics error warnings written to the log (the rest are only counted).
const MAX_LOGGED_PHYSICS_ERRORS: int = 10
## Training dummies at most (those of the zones and those of the spawn_dummy command).
const MAX_DUMMIES: int = 16
## Name of the training dummy.
const DUMMY_NAME: String = "Maniquí"
## Header of the combat log (--combat-log).
const COMBAT_LOG_HEADER: String = "tick,atacante,objetivo,ataque,view_tick,rebobinado,resultado,daño"
## Ticks of each bucket of the RTT measurement window, and the buckets that make it up.
const _RTT_BUCKET_TICKS: int = 30
const _RTT_BUCKETS: int = 4
const _INT_MAX: int = 0x7FFFFFFF

enum _RunState { IDLE, RUNNING, STOPPING, STOPPED }

## Interest policy: which entities each player sees. The base considers everything relevant.
var interest_policy: InterestPolicy = InterestPolicy.new():
	set(value):
		interest_policy = value if value != null else InterestPolicy.new()
		_snapshot_builder = SnapshotBuilder.new(interest_policy)
## Writes joins, leaves, kicks and metrics to the log.
var log_enabled: bool = true
## Ticks a peer may spend loading the zone without sending CLIENT_READY before being kicked
## ([constant LOADING_TIMEOUT_TICKS] by default; tests shorten it).
var loading_timeout_ticks: int = LOADING_TIMEOUT_TICKS
## Ticks a peer may stay connected without sending the HELLO before being disconnected
## ([constant HELLO_TIMEOUT_TICKS] by default; tests change it).
var hello_timeout_ticks: int = HELLO_TIMEOUT_TICKS
## VERIFYING deadline in ms ([constant VERIFY_TIMEOUT_MS] by default; tests change it).
var verify_timeout_ms: int = VERIFY_TIMEOUT_MS
## Cooldown ticks after a kick ([constant KICK_COOLDOWN_TICKS] by default; tests change it).
var kick_cooldown_ticks: int = KICK_COOLDOWN_TICKS
## Tests only: if valid, it is called with [code](peer_id: int, address: String) -> String[/code] and
## returns the address with which the peer is treated. It is used to pretend that some loopback clients
## come from an external IP and thus test the per-IP connection cap, from which loopback is exempt.
var remote_address_override: Callable = Callable()
## Ticks that the body of whoever leaves or disconnects in combat stays in the world
## ([constant LINGER_TICKS] by default; tests shorten it).
var linger_ticks: int = LINGER_TICKS
## Player records and kicks that the report keeps ([constant MAX_LOGGED_PLAYERS] and
## [constant MAX_LOGGED_KICKS] by default; tests shorten them).
var max_logged_players: int = MAX_LOGGED_PLAYERS
var max_logged_kicks: int = MAX_LOGGED_KICKS
## Cap on the wait for saves on shutdown ([constant SAVE_DRAIN_TICKS] by default; tests change it).
var save_drain_ticks: int = SAVE_DRAIN_TICKS

var _run_state: _RunState = _RunState.IDLE
var _config: ServerConfig
var _world: Node3D
var _transport: NetTransport
var _auth: ServerAuth
var _auth_provider: AuthProvider = null
## The platform (null without [code]--platform[/code]: ephemeral characters, docs/progression.md §9.4).
var _platform: ZonePlatform = null
## The saves of the bodies with a lease (only with the platform).
var _saver: CharacterSaver = null
## Character progress (docs/progression.md §9); its section is the first one of [member _saver].
var _progress: ProgressService = null
var _sim_hash: int = 0
var _tick: int = 0
# Reason for the final save (CharacterSaver.Reason) of the body that remains after an in-combat exit.
var _lingering_save_reasons: Dictionary[int, int] = {}
var _registry: NetEntityRegistry = NetEntityRegistry.new()
var _history: StateHistory = StateHistory.new()
var _metrics: ServerMetrics = ServerMetrics.new()
var _snapshot_builder: SnapshotBuilder
var _spawn_picker: SpawnPicker
var _players_root: Node3D
# peer_id -> peer (in any state).
var _peers: Dictionary[int, ServerPeer] = {}
# Peers in the world, to distribute the snapshots.
var _world_peers: Array[ServerPeer] = []
# net_id -> input queue (of network players and fakes).
var _queues: Dictionary[int, InputQueue] = {}
# net_id -> brain of each fake player.
var _fakes: Dictionary[int, BotBrain] = {}
# The filler fakes of --max-realm-diff (null without balancing; see set_filler_keeper).
var _filler_keeper: FillerKeeper = null
# net_id -> brain of each NPC (dummies).
var _npcs: Dictionary[int, BotBrain] = {}
var _combat: CombatDirector
var _fortresses: FortressController = null
var _npc_system: NpcSpawnerSystem = null
var _scores: ScoreKeeper = ScoreKeeper.new()
# The fortress records and their history on the platform (docs/platform.md §8); null without it.
var _fortress_persistence: FortressPersistence = null
var _battle_log: BattleLog = null
var _unstuck: UnstuckTracker = UnstuckTracker.new()
# Chat and parties (SOC-04, SOC-06); created in start().
var _social: SocialService = null
## Moderation (docs/platform.md §9, P7b): /gm, ignored players, reports, mutes, audit and chat batch.
var _moderation: ModerationService = null
var _unstuck_log: Array[Dictionary] = []
var _unstuck_uses: int = 0
# net_id -> tick at which the body of whoever left in combat is removed (GUE-41).
var _lingering: Dictionary[int, int] = {}
var _lingering_total: int = 0
var _object_states_sent: int = 0
var _telegraphs_sent: int = 0
var _scoreboards_sent: int = 0
var _safe_areas: SafeAreas
var _commands: CommandRegistry = CommandRegistry.new()
var _console: ServerConsole = null
var _combat_log: FileAccess = null
# Tick at which the countdown of a shutdown requested through the console expires (-1 = none).
var _shutdown_tick: int = -1
var _shutdown_announced: Dictionary[int, bool] = {}
var _events_sent: int = 0
var _event_bytes_sent: int = 0
# Projectiles (docs/abilities.md, section 4.4): the peers that received the ENTITY_SPAWN of each one
# (the same ones receive its ENTITY_DESPAWN) and what was sent.
var _projectile_viewers: Dictionary[int, PackedInt32Array] = {}
var _projectile_messages_sent: int = 0
var _projectile_bytes_sent: int = 0
var _dummies_created: int = 0
## Tests only: the per-realm ids of the bot target cache (it lives in [ZoneBotSupport]).
var _targets_ids_by_realm: Dictionary:
	get:
		return _zone_bots._targets_ids_by_realm
# peer_id -> RTT measurement in ticks.
var _rtt: Dictionary[int, _RttWindow] = {}
# Peers with CLIENT_READY received, in arrival order.
var _pending_ready: Array[int] = []
# Peers that are leaving (removals of the next tick).
var _leaving: Array[int] = []
# net_id -> record of the living player; _player_log keeps the last max_logged_players, including those
# who have left (the oldest of those who left are summarized in _archived_*).
var _player_by_net: Dictionary[int, _PlayerRecord] = {}
var _player_log: Array[_PlayerRecord] = []
var _archived_players: int = 0
var _archived_fakes: int = 0
var _archived_inputs: int = 0
var _archived_substituted: int = 0
var _archived_late: int = 0
var _archived_too_early: int = 0
var _peak_players: int = 0
var _players_at_stop: int = 0
# State of the fortresses at shutdown, for the report written after stop().
var _war_fortresses_at_stop: Array[Dictionary] = []
var _joined_total: int = 0
var _left_total: int = 0
var _strikes_total: int = 0
var _strike_reasons: Dictionary[String, int] = {}
var _kicks: Array[Dictionary] = []
var _kicks_total: int = 0
var _rejects: Dictionary[String, int] = {}
var _physics_errors: int = 0
var _teleports: int = 0
var _respawns: int = 0
var _log_last_usec: int = 0
# "Real" tick clock (at the nominal rate), to know how many ticks the server has lost between two polls.
# _clock_origin_usec is the instant of start().
var _clock_origin_usec: int = 0
var _last_poll_real_tick: int = 0
var _state_log: FileAccess = null
# net_id -> 1 if the tick's input was substituted (only filled with --state-log).
var _substituted_now: Dictionary[int, int] = {}
# Fake players that leave on the next tick (remove_fake_player), and filler ones that are withdrawn without
# dying even if knocked down (retire_filler).
var _fake_leaving: Array[int] = []
var _fake_leaving_quietly: Dictionary[int, bool] = {}
# Load measurements (report): µs of simulate() per call and of building snapshots.
var _simulate_calls: int = 0
var _simulate_usec_total: int = 0
var _simulate_usec_max: int = 0
var _snapshots_sent: int = 0
var _snapshot_bytes_total: int = 0
var _snapshot_bytes_max: int = 0
var _snapshot_build_usec: int = 0

# The subsystems (scripts/server/zone/). They hold the logic of one concern each and reach the rest of the
# zone through their [code]_z[/code]; the tick order stays here, in _physics_process.
var _zone_commands: ZoneCommands
var _zone_sessions: ZoneSessions
var _zone_lifecycle: ZoneLifecycle
var _zone_report: ZoneReport
var _zone_bots: ZoneBotSupport
var _zone_lingering: ZoneLingering
var _zone_intents: ZoneIntents
var _zone_events: ZoneEvents
var _zone_bodies: ZoneBodies


## Player record for the report: what is known about them while present and on leaving.
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
	## Last known position (the current one while the player is present; the removal one, afterwards).
	var last_position: Vector3 = Vector3.ZERO


	# Copies the live counters of the queue and the peer and the character position.
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


	# The player leaves at tick [param tick]: copies the counters and the position and releases the queue,
	# the peer and the entity, which would otherwise stay in memory while the record remains in the report.
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


## Minimum and maximum RTT in ticks over the last 90-120 ticks, in four buckets of 30 ticks.
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


	# Minimum of the window, or -1 if there are no samples in it.
	func get_min(now_tick: int) -> int:
		var current: int = now_tick / _RTT_BUCKET_TICKS
		var best: int = _INT_MAX
		for slot: int in _RTT_BUCKETS:
			if _ids[slot] > current - _RTT_BUCKETS and _ids[slot] <= current:
				best = mini(best, _mins[slot])
		return best if best != _INT_MAX else -1


	# Maximum of the window, or -1 if there are no samples in it.
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
	_zone_commands = ZoneCommands.new(self)
	_zone_sessions = ZoneSessions.new(self)
	_zone_lifecycle = ZoneLifecycle.new(self)
	_zone_report = ZoneReport.new(self)
	_zone_bots = ZoneBotSupport.new(self)
	_zone_lingering = ZoneLingering.new(self)
	_zone_intents = ZoneIntents.new(self)
	_zone_events = ZoneEvents.new(self)
	_zone_bodies = ZoneBodies.new(self)


func _ready() -> void:
	# There is nothing to simulate until start().
	set_physics_process(false)


func _exit_tree() -> void:
	_release_resources()


# --- Public API -------------------------------------------------------------------------------

## Starts the server of zone [param world] (which must already be in the tree, like this node) with
## [param config].
## [br]- Computes the [code]sim_hash[/code] over a character instance inside the tree.
## [br]- If [param transport] is not listening yet, applies [member ServerConfig.net_sim_spec] and opens
## [member ServerConfig.port] with room for [member ServerConfig.max_players] plus 4 connections (the
## extra 4 allow answering "server full" with a REJECT), over DTLS if there is a [member ServerConfig.dtls]
## (docs/platform.md §10.2). If it is already listening, it uses it as is.
## [br]- [param transport] may be null: the server runs without a network, with fake players only
## ([method add_fake_player]), which is what tests use.
## [br]- [param auth_provider] decides the identity of the clients ([DevAuthProvider] without the platform,
## [TicketAuthProvider] with it).
## [br]- [param platform] is the already started platform ([signal ZonePlatform.startup_finished]); null
## without [code]--platform[/code]. Its events are dispatched in the "poll" step of each tick, and the
## fortresses it loaded ([method ZonePlatform.fortress_records]) are applied here before opening the port
## (docs/platform.md §8).
## Returns the error of [method NetTransport.host] if the port cannot be opened.
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
		_platform.player_count_source = _zone_sessions.get_player_count
		_saver = CharacterSaver.new(_platform, maxi(config.save_interval_s, 1) * Engine.physics_ticks_per_second)
		_saver.log_sink = Callable(self, "_log")
		_saver.save_rejected.connect(_zone_sessions._on_save_rejected)
	# The progress section is registered first (progression.md §9.2): before any other.
	_progress = ProgressService.new()
	_progress.log_sink = Callable(self, "_log")
	_progress.send_sink = Callable(self, "_progress_send")
	_progress.strike_sink = Callable(_zone_sessions, "_add_strike")
	_progress.notice_sink = Callable(self, "_send_notice")
	_progress.level_up_sink = Callable(_zone_events, "_announce_level_up")
	_progress.setup(self, _platform, _saver, _commands)
	# The pvp section, behind progress (docs/platform.md §7.1 and §8).
	if _saver != null:
		_scores.attach(_saver)
	_players_root = Node3D.new()
	_players_root.name = "Players"
	add_child(_players_root)
	_sim_hash = _compute_sim_hash()
	_auth = ServerAuth.new(config, _sim_hash, NetZones.allowed_realms(config.zone_id),
			auth_provider)
	_auth.set_connected_names_source(_zone_sessions.get_connected_names)
	_auth.set_realm_counts_source(_zone_sessions.get_realm_counts)
	_spawn_picker = SpawnPicker.new(world)
	_safe_areas = SafeAreas.from_world(world)
	_combat = CombatDirector.new(_history, StringName(config.zone_id), world, _safe_areas,
			Callable(self, "_place"), Callable(_zone_bodies, "_pick_spawn_point"))
	_combat.event_emitted.connect(_zone_events._on_combat_event)
	_combat.metrics = _metrics
	# Whoever has an inventory respawns with their equipment and refills their bag at the camp (progression.md §4.4 and §8).
	_combat.loadout_source = _progress.loadout_for
	_combat.camp_step = _progress.camp_step
	# Projectiles take their id from the entity id space (with its quarantine).
	_combat.projectiles.registry = _registry
	_combat.projectiles.spawned.connect(_zone_events._on_projectile_spawned)
	_combat.projectiles.despawned.connect(_zone_events._on_projectile_despawned)
	_projectile_viewers.clear()
	_war_fortresses_at_stop = []
	_setup_fortresses(world)
	if _platform != null:
		# The saved state of each fortress, before opening the port and before the NPCs read it (§8 step 4).
		_fortress_persistence = FortressPersistence.new(_platform, _fortresses)
		_fortress_persistence.log_sink = Callable(self, "_log")
		_fortress_persistence.load_records(_platform.fortress_records(), _tick)
		_fortresses.war_event_emitted.connect(_fortress_persistence.on_war_event)
	_setup_npcs(world)
	_commands.audit_sink = Callable(self, "_log")
	_zone_commands._register_commands()
	_social = SocialService.new(Callable(self, "_social_peers"), Callable(self, "_social_send"),
			Callable(_zone_sessions, "_add_strike"))
	# Moderation (docs/platform.md §9): its /gm commands, the GM chat channel and, with the platform, the audit
	# and chat batches.
	_moderation = ModerationService.new()
	_moderation.log_sink = Callable(self, "_log")
	_moderation.setup(self, _platform, _commands, _social)
	# The progression GM commands answer through chat and, without the platform, date their operations with the
	# system time (progression.md P5d).
	_progress.reply_sink = Callable(self, "_progress_reply")
	_progress.clock_unix = _moderation.now_unix
	if _transport != null:
		_connect_transport()
		if not _transport.is_server():
			_transport.set_net_sim_spec(config.net_sim_spec)
			# With the zone certificate, over DTLS (docs/platform.md §10.2, P9c).
			var error: Error = _transport.host(config.port, config.max_players + 4,
					config.dtls.server_options if config.dtls != null else null)
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
	_progress.start(_tick)
	_run_state = _RunState.RUNNING
	set_physics_process(true)
	return OK


## Shuts the server down (the orderly shutdown of docs/platform.md §7.2, that of the five triggers): warns
## all clients with a shutdown NOTICE (code [constant NetProtocol.NoticeCode.SHUTDOWN]) with
## [param notice_text] (by default, a standard text), releases the peers in LOADING and cancels those in
## VERIFYING, requests the orderly disconnect of each peer, sends the final save of each body with a lease
## (also those that remain after an in-combat exit) and releases all characters. The report data is
## kept ([method write_report]). It finishes when the peers have left (or after
## [constant STOP_DRAIN_TICKS] ticks) and the platform has answered the saves and has nothing queued or in
## flight (or after [member save_drain_ticks]); [method is_stopped] says when.
func stop(notice_text: String = "") -> void:
	_zone_lifecycle.stop(notice_text)


## The shutdown of docs/platform.md §6.1, when the platform deems the instance lost, replaced or stopped
## ([param code]; [ServerMain] calls it with [signal instance_closed]): first the final save of everyone and the
## release of those in LOADING, without kicking anyone (the zone stops reading their inputs and giving rewards);
## those in VERIFYING receive REJECT UNAVAILABLE. Once the platform has answered the finals and nothing is
## pending (or after [member save_drain_ticks]), a kick NOTICE "El servidor de la zona se ha reiniciado:
## vuelve a entrar" (the zone server has restarted: rejoin) to everyone and disconnect: whoever rejoins right away
## loads their final save, not the previous one.
func close_instance(code: String) -> void:
	_zone_lifecycle.close_instance(code)


## true when [method stop] or [method close_instance] have finished: the peers have left and the saves
## have an answer (or the wait ran out) and the transport is closed.
func is_stopped() -> bool:
	return _zone_lifecycle.is_stopped()


## The zone saves (null without the platform): [code]ProgressService[/code] registers its section here and marks
## the criticals (docs/progression.md §9.2).
func get_saver() -> CharacterSaver:
	return _saver


## Character progress (docs/progression.md §9); null before [method start].
func get_progress() -> ProgressService:
	return _progress


## The configuration the server was started with (null before [method start]).
func get_config() -> ServerConfig:
	return _config


## The Unix time of the maintenance announced by the heartbeat (0 = none).
func get_maintenance_at_unix() -> int:
	return _zone_lifecycle.get_maintenance_at_unix()


## Current tick: the last one simulated (0 before starting). The first one is 1.
func get_tick() -> int:
	return _tick


## The peer with that id (in any state) or null.
func get_peer(peer_id: int) -> ServerPeer:
	return _peers.get(peer_id)


## Ids of all known peers, sorted.
func get_peer_ids() -> PackedInt32Array:
	return _zone_sessions.get_peer_ids()


## Players that count toward capacity: the peers verifying their ticket with the platform (docs/platform.md
## §5.2: several simultaneous entries do not exceed max_players), the accepted ones (loading the zone or already
## inside) and the fake players. Those that have not yet sent the HELLO or are leaving (also fakes with a
## requested removal, which disappear at the start of the next tick) do not count. Filler fakes do count here, but
## yield their slot to people (see [method set_filler_keeper]): while a person loads the zone in the slot a fake
## set aside for them, both count (one too many), and the fake leaves when the person enters the world.
func get_player_count() -> int:
	return _zone_sessions.get_player_count()


## People per realm (Vardheim, Solmarch, Askarra; see [RealmBalance]): the truly accepted clients, loading the
## zone or already inside (with [param in_world_only], only those already inside). Fake players and the bodies
## that remain after an in-combat removal do not count. [param excluded] is not counted (the one who just
## entered, for their WELCOME). It is the count of the WELCOME and of the REJECT 9 IMBALANCE.
func get_realm_counts(in_world_only: bool = false, excluded: ServerPeer = null) -> PackedInt32Array:
	return _zone_sessions.get_realm_counts(in_world_only, excluded)


## Entries of the cooldown after kicks (in force or not yet purged). They are purged when the next kick is
## recorded, so the dictionary does not grow beyond the kicks of the last [constant KICK_COOLDOWN_TICKS] ticks.
func get_cooldown_count() -> int:
	return _zone_sessions.get_cooldown_count()


## Names of the players present in the zone: the accepted peers (loading or already inside) and the fake
## players. [ServerAuth] rejects with NAME a HELLO whose name repeats any of them.
func get_connected_names() -> PackedStringArray:
	return _zone_sessions.get_connected_names()


func get_registry() -> NetEntityRegistry:
	return _registry


func get_history() -> StateHistory:
	return _history


func get_metrics() -> ServerMetrics:
	return _metrics


## The combat director (health, hits, deaths and respawns). null before [method start].
func get_combat() -> CombatDirector:
	return _combat


## Combat deadlines in ticks (respawn, protection...). Tests shorten them.
func get_combat_timing() -> CombatTiming:
	return _combat.timing if _combat != null else null


## Registry of administration commands (network and console).
func get_commands() -> CommandRegistry:
	return _commands


## Safe areas of the zone.
func get_safe_areas() -> SafeAreas:
	return _safe_areas


## The fortresses of the zone (state, gate, notices). null before [method start]. It is the interface of the
## NPC spawners: [method FortressController.get_fortress_state],
## [method FortressController.on_captain_died] and [method FortressController.set_guards_alive].
func get_fortresses() -> FortressController:
	return _fortresses


## The NPC spawner system (posts, navigation, records). null before [method start] or with
## [code]--no-npcs[/code].
func get_npc_system() -> NpcSpawnerSystem:
	return _npc_system


## net_id of all NPCs with a body (those of the spawners, the dummies and the loose ones), sorted.
func get_npc_ids() -> Array[int]:
	var ids: Array[int] = []
	ids.assign(_npcs.keys())
	ids.sort()
	return ids


## The brain of NPC [param net_id], or null.
func get_npc_brain(net_id: int) -> BotBrain:
	return _npcs.get(net_id)


## The physics space of the server world (NPC line of sight). null before [method start].
func get_physics_space() -> PhysicsDirectSpaceState3D:
	return _players_root.get_world_3d().direct_space_state if _players_root != null else null


## The battle scoreboard (kills, deaths, assists, gate damage, circle, captures, defending time and merits);
## with the platform, also the [code]pvp[/code] section of the saves.
func get_scores() -> ScoreKeeper:
	return _scores


## The fortress records on the platform (docs/platform.md §8); null without the platform.
func get_fortress_persistence() -> FortressPersistence:
	return _fortress_persistence


## The control of the /atascado (unstuck) command (channelings and reuses).
func get_social() -> SocialService:
	return _social


## Moderation (docs/platform.md §9, P7b); null before [method start].
func get_moderation() -> ModerationService:
	return _moderation


## The peers that are in the world with their character.
func get_world_peers() -> Array[ServerPeer]:
	return _world_peers


## Informational NOTICE to [param peer] (only if it is in the world).
func send_notice(peer: ServerPeer, text: String) -> void:
	_send_notice(peer, text)


## Kicks [param peer] with the NOTICE [param notice_text] and its final save (reason 5, [code]KICK[/code]), with
## the usual cooldown; [param reason] stays in the log and in the report (moderation, P7b).
func kick_peer(peer: ServerPeer, reason: String, notice_text: String) -> void:
	_zone_sessions.kick_peer(peer, reason, notice_text)


## Makes [param entity] invisible (or visible) (docs/platform.md §9.1, [code]/gm invisible[/code]): it stops
## entering other players' interest, and each peer immediately receives its ENTITY_DESPAWN (or its ENTITY_SPAWN
## on return). It neither deals nor receives damage, does not count in the circle or on the scoreboard and
## does not earn rewards ([member NetEntity.gm_invisible]).
func set_gm_invisible(entity: NetEntity, invisible: bool) -> void:
	if entity.gm_invisible == invisible:
		return
	entity.gm_invisible = invisible
	_log("%s se hace %s (net_id %d)" % [entity.display_name, "invisible" if invisible else "visible", entity.net_id])
	for peer: ServerPeer in _world_peers:
		if peer.entity == null or peer.entity == entity:
			continue
		var was_relevant: bool = peer.relevant.get(entity.net_id, false)
		var now_relevant: bool = _is_relevant(peer.entity, entity, was_relevant)
		if now_relevant == was_relevant:
			continue
		if now_relevant:
			peer.relevant[entity.net_id] = true
			_send(peer, NetProtocol.CH_RELIABLE, entity.encode_spawn(_tick, false, peer.entity.realm))
		else:
			peer.relevant.erase(entity.net_id)
			peer.priority.erase(entity.net_id)
			var despawn := NetMessages.EntityDespawn.new()
			despawn.net_id = entity.net_id
			despawn.despawn_tick = _tick
			despawn.reason = NetProtocol.DespawnReason.OUT_OF_INTEREST
			_send(peer, NetProtocol.CH_RELIABLE, despawn.encode())


func get_unstuck() -> UnstuckTracker:
	return _zone_lingering.get_unstuck()


## The key of [param entity] in the [UnstuckTracker]: with the platform, [code]"character:<id>"[/code] (that of
## the saved [code]unstuck[/code] timer, docs/progression.md §8); without it, that of its name (rejoining with the
## same name does not skip the reuse cooldown).
func unstuck_key_of(entity: NetEntity) -> String:
	return _zone_lingering.unstuck_key_of(entity)


## Places [param entity] at [param position] facing [param yaw] (the return-to-world rule of the SAFE zones,
## docs/progression.md §8) if the spot is valid: finite, within the zone limits and with ground. true if it places it.
func place_returning(entity: NetEntity, position: Vector3, yaw: float) -> bool:
	if entity == null or entity.get_character() == null or not _zone_commands._is_valid_teleport_target(position) \
			or not is_finite(yaw) or not _zone_bodies._probe_grounded(position):
		return false
	_place(entity, position, yaw)
	return true


## Bodies that remain in the world after the removal of a player in combat (GUE-41).
func get_lingering_count() -> int:
	return _zone_lingering.get_lingering_count()


## true if [param net_id] is the body of a player who left in combat and is waiting to be removed.
func is_lingering(net_id: int) -> bool:
	return _zone_lingering.is_lingering(net_id)


## Simulation fingerprint ([method NetProtocol.compute_sim_hash]) that the server requires from clients in the
## HELLO.
func get_sim_hash() -> int:
	return _sim_hash


## Creates a network-less player of [param realm] (a code of [enum NetProtocol.Realm]): on each tick, before
## simulating, its input comes from [code]brain.next_input()[/code], quantized and with the corresponding tick,
## and goes straight into its [InputQueue]. It appears with the equipment template [param template_id] (0 = the
## default one; [code]--fake-loadout[/code]) and keeps it when respawning. On death it requests the respawn as
## soon as it can ([member Combatant.requests_respawn_on_death]), like a person pressing the button or a
## [code]SwarmBot[/code]: with waves, it respawns in the first one that applies to it. Returns its
## [code]net_id[/code], or -1 if the server is not running, is full ([member ServerConfig.max_players]) or no
## ids are left. It can be called between two ticks; the player appears with the state "after the last tick" and
## its first simulation is the next one.
func add_fake_player(brain: BotBrain, realm: int, template_id: int = 0) -> int:
	return _zone_bodies.add_fake_player(brain, realm, template_id)


## The siege view of fortress [param fortress_id] (empty = the first of the zone) used by fake players with the
## [constant BotBrain.Pattern.SIEGE] brain: it is created the first time it is requested, carries the gate and
## circle positions and is updated every tick with the live state of the fortress
## ([method SiegeView.update_from_state]). null if the zone has no fortresses.
func get_siege_view(fortress_id: StringName = &"") -> SiegeView:
	return _zone_bots.get_siege_view(fortress_id)


## The approach routes of the zone (data/routes/<zone>.tres), or null if it has none.
func get_approach_routes() -> ApproachRoutes:
	return _zone_bots.get_approach_routes()


## Gives the server the filler fakes of [code]--max-realm-diff[/code] (GUE-42 and GUE-43; [ServerMain] creates
## and connects them; null removes them). From then on the server notifies it of the joins
## ([method FillerKeeper.on_person_joined]) and leaves ([method FillerKeeper.on_person_left]) of people and of each
## fake that leaves ([method FillerKeeper.forget]), and the filler fakes do not take people's slots: FULL
## only counts people and the other fakes ([method ServerAuth.validate]), and if an accepted HELLO
## finds the server full, a filler fake sets aside its slot for them ([method FillerKeeper.reserve_seat]) and leaves
## when that person enters the world. If they leave earlier, the slot is released ([method FillerKeeper.release_seat])
## without any fake having moved: a HELLO followed by a disconnect, in a loop, pulls nobody out of combat nor sends
## joins and leaves to the others. No more people ever enter than [member ServerConfig.max_players].
func set_filler_keeper(keeper: FillerKeeper) -> void:
	_filler_keeper = keeper


## Removes fake player [param net_id] at the start of the next tick: DESPAWN (reason 1) to whoever
## saw it and the id into quarantine, as if it had disconnected. Returns false if it is not a fake
## player (or is already leaving). Used for the joins and leaves of load tests. If it is knocked down, its removal is
## preceded by a death (DEATH and KILL), like that of anyone who leaves knocked down.
func remove_fake_player(net_id: int) -> bool:
	return _zone_bodies.remove_fake_player(net_id)


## Withdraws filler fake [param net_id], which yields its slot to a person (GUE-42 and GUE-43; requested by
## [FillerKeeper]): like [method remove_fake_player], but its removal is never a death, not even if it is knocked
## down (only DESPAWN, no DEATH or KILL for whoever knocked it down): a person entering kills nobody (review of
## the abilities integration). Returns false if it is not a fake player (or is already leaving).
func retire_filler(net_id: int) -> bool:
	return _zone_bodies.retire_filler(net_id)


## true if withdrawing fake player [param net_id] right now cuts nothing off: it is not knocked down nor reviving or
## finishing off anyone (dead and waiting to respawn, too). The [member FillerKeeper.calm_check] of the filler fakes.
func is_fake_calm(net_id: int) -> bool:
	return _zone_bodies.is_fake_calm(net_id)


## Authoritative teleport of player [param net_id] to [param position]: velocity 0, state rounded by
## [code]encode/decode[/code] (the one the client will reconstruct) and teleport counter +1 (modulo 4), so
## clients do not interpolate the jump. It keeps the yaw and the previous key presses. It does nothing with an
## unknown id or a position that is not finite.
func teleport(net_id: int, position: Vector3) -> void:
	var entity: NetEntity = _registry.get_entity(net_id)
	if entity == null or entity.get_character() == null or not position.is_finite():
		return
	_place(entity, position, entity.get_character().yaw)
	_teleports += 1


## Creates a humanoid NPC named [param display_name] on side [param realm] (0 = the Hollow, hostile to
## everyone) at [param position] facing [param yaw]: a [PlayerCharacter] simulated in the same loop as the
## players with the inputs of [param brain] (like those of a fake player), with health and recorded in the
## history. With [param immortal] it is a dummy: health does not drop below 1 and it heals fully after 5 s
## without damage. Returns its [code]net_id[/code], or -1 if the server is not running or no ids are left. With
## [param definition] (an [NpcDefinition]) the NPC takes from it its health, its weapon, whether it ignores safe
## zones and its catalog number (the [code]npc_def_id[/code] of the ENTITY_SPAWN).
func add_npc(brain: BotBrain, display_name: String, realm: int, position: Vector3, yaw: float,
		immortal: bool = false, definition: NpcDefinition = null) -> int:
	return _zone_bodies.add_npc(brain, display_name, realm, position, yaw, immortal, definition)


## Removes NPC [param net_id] (DESPAWN to whoever saw it). Returns false if it is not an NPC.
func remove_npc(net_id: int) -> bool:
	return _zone_bodies.remove_npc(net_id)


## Creates a training dummy (immortal NPC of the neutral side) at [param position] facing
## [param yaw], with mode [param mode] ([enum NpcBrain.Mode]). The position is lowered to the ground if there is
## one below. Returns its net_id, or -1 if there is no room ([constant MAX_DUMMIES]) or it cannot be created.
func spawn_dummy(position: Vector3, yaw: float, mode: int = NpcBrain.Mode.STILL) -> int:
	return _zone_bodies.spawn_dummy(position, yaw, mode)


## Places a still dummy at each marker of the zone's [code]dummy_points[/code] group (one in
## the test world and one next to each camp of Vado Gris). Returns how many it created.
func spawn_zone_dummies() -> int:
	return _zone_bodies.spawn_zone_dummies()


## Test double of the captain of [param fortress_id] while there is no NPC spawner: a mortal, still NPC
## at the fortress's [code]CaptainSpawn[/code], on the owner's side, registered as its
## captain ([method FortressController.register_captain]). On death (from a hit or with
## [code]fort_kill_captain[/code]) it opens the capture circle. Returns its net_id, or -1 if it cannot.
func spawn_captain_double(fortress_id: StringName) -> int:
	return _zone_bodies.spawn_captain_double(fortress_id)


## Living dummies (immortal NPCs).
func get_dummy_count() -> int:
	return _zone_bodies.get_dummy_count()


## Executes a console line ([code]kick Ana[/code]) and returns the response. It is what the server does with
## each line of standard input; tests call it directly.
func console_command(line: String) -> String:
	return _zone_commands.console_command(line)


## Starts the standard input console (reader thread, without blocking the tick). Returns false if there is no
## usable standard input or it was already running.
func start_console() -> bool:
	return _zone_commands.start_console()


## The console ([ServerConsole]), or null if it has not been started nor given a line.
func get_console() -> ServerConsole:
	return _zone_commands.get_console()


## Pushes a line into the console queue as if it had been typed on standard input; it is executed at the start
## of the next tick.
func push_console_line(line: String) -> void:
	_zone_commands.push_console_line(line)


## Writes the JSON report of the run to [param path] (missing directories are created).
## Keys:
## [codeblock]
## version, zone, port, ticks, tick_rate, sim_hash
## closed    false while the server is running (periodic report), true after stop()
## players   {current, at_stop, fake, peak, joined_total, left_total, archived}
## inputs    {consumed, substituted, late, too_early, substituted_percent}  (network players only)
## bytes     {wire_in, wire_out, app_in, app_out}  (cumulative; see NetTransport.get_byte_counters)
## strikes   {total, by_reason, kicks_total}
## kicks     [{tick, peer_id, net_id, name, reason}]  (the last max_logged_kicks)
## rejects   {reason: times}
## physics_errors, teleports, respawns
## simulate  {calls, total_us, avg_us, max_us}        µs of each PlayerCharacter.simulate()
## snapshots {sent, bytes, avg_bytes, max_bytes, build_us, avg_build_us}   build_us: building each
##           snapshot and queuing it (without the interest computation or the real ENet send)
## metrics   ServerMetrics.summary() (p50/p99/max of each section in µs, KB/s, players...)
## npcs      NpcSpawnerSystem.get_report(): posts, living NPCs, spawns, deaths, telegraphed heavy attacks,
##           attack tokens, computed routes...
## player_list  one record per player who has passed through the server (also those who left),
##           the last max_logged_players; of the earlier ones only the totals remain
##           (players.archived counts the summarized records)
## [/codeblock]
func write_report(path: String) -> Error:
	return _zone_report.write_report(path)


# --- Tick loop --------------------------------------------------------------------------------

func _physics_process(delta: float) -> void:
	if _run_state == _RunState.STOPPING:
		_zone_lifecycle._drain_stop()
		return
	if _run_state != _RunState.RUNNING:
		return
	_metrics.begin_tick()

	_metrics.begin_section(&"net")
	if _transport != null:
		_grant_stall_credit()
		_transport.poll(_tick)
	_zone_commands._run_console_lines()
	_metrics.begin_section(SECTION_PLATFORM)
	_zone_sessions._poll_platform()
	_metrics.end_section(SECTION_PLATFORM)
	_metrics.end_section(&"net")
	if _run_state != _RunState.RUNNING:
		# The instance shutdown (instance_closed) has already emptied the world: there is nothing left to simulate.
		return

	_tick += 1
	var s: int = _tick

	_zone_sessions._check_loading_timeouts(s)
	_zone_sessions._check_hello_timeouts(s)
	_zone_bodies._process_departures(s)

	_metrics.begin_section(SECTION_NPC_BRAINS)
	_run_npc_brains(s)
	_metrics.end_section(SECTION_NPC_BRAINS)

	_metrics.begin_section(&"sim")
	_zone_bots._refresh_siege_views()
	_progress.before_simulate(s)
	_simulate_players(s, delta)
	# CONSUME (progression.md §4.4): what each player drank is removed from their bag, after step 1.
	_progress.after_simulate(s)
	_metrics.end_section(&"sim")

	_metrics.begin_section(&"combat")
	_combat.process_tick(s, _players_root.get_world_3d().direct_space_state)
	_emit_npc_telegraphs(s)
	_metrics.end_section(&"combat")

	# Step 4b (docs/fortress.md, 1.7): the fortresses, with what combat left behind.
	_metrics.begin_section(SECTION_WAR)
	_fortresses.step(s)
	if _fortress_persistence != null:
		_fortress_persistence.step(s)
	_zone_lingering._process_unstuck(s)
	_metrics.end_section(SECTION_WAR)
	if _npc_system != null:
		_metrics.begin_section(SECTION_NPC)
		_npc_system.step(s)
		_metrics.end_section(SECTION_NPC)
	_zone_lifecycle._check_shutdown_countdown(s)
	_zone_lifecycle._check_maintenance()
	if _run_state != _RunState.RUNNING:
		# A completed countdown has shut the server down on this tick (stop has already emptied the world).
		return

	_zone_bodies._process_arrivals(s)
	# The inventory requests of the tick, after the spawns and before the saves snapshot (progression.md §4.2),
	# and the grouped WALLET_UPDATE and PROGRESS_UPDATE.
	_progress.apply_pending(s)
	_progress.flush(s)
	if _saver != null:
		_saver.step(s)
	_metrics.begin_section(SECTION_SOCIAL)
	_social.step(s)
	_metrics.end_section(SECTION_SOCIAL)

	_metrics.begin_section(&"history")
	_record_history(s)
	_metrics.end_section(&"history")

	_metrics.begin_section(&"snapshot")
	_send_snapshots(s)
	if s % SCOREBOARD_INTERVAL_TICKS == 0:
		_zone_events._send_scoreboard()
	_metrics.end_section(&"snapshot")

	_metrics.begin_section(&"flush")
	if _transport != null:
		_transport.flush()
	_metrics.end_section(&"flush")

	_metrics.end_tick(s)
	if s % METRICS_LOG_TICKS == 0:
		_zone_report._log_metrics(s)
	tick_finished.emit(s)


# If the server has lost ticks relative to the clock (a process stall: Godot only catches up 8 per
# frame), clients kept sending one batch per tick and everything arrives together in this poll, with
# the server tick not advancing: the bucket would not refill and the newest would be discarded as
# exceeding the rate. Each peer is given the credit of the lost ticks (see
# ServerPeer.grant_stall_credit). Real ticks are an integer clock, so the sum of what is
# granted never exceeds the ticks that have actually elapsed.
func _grant_stall_credit() -> void:
	var elapsed_usec: int = Time.get_ticks_usec() - _clock_origin_usec
	var real_tick: int = elapsed_usec * Engine.physics_ticks_per_second / 1000000
	var missed_ticks: int = real_tick - _last_poll_real_tick - 1
	_last_poll_real_tick = real_tick
	if missed_ticks <= 0:
		return
	for peer: ServerPeer in _peers.values():
		peer.grant_stall_credit(_tick, missed_ticks)


# Step 0 of the tick (docs/fortress.md, 1.7): the NPC brains think with the state of the bodies after s - 1
# (before simulating anyone) and push their input for s into their queue, by ascending net_id. Between thinks
# they repeat their plan.
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


# TELEGRAPH notice (docs/fortress.md, section 5) of each heavy attack an NPC launches at tick [param s]: the danger
# zone (a sector in front of it, with the reach of the hit) and the ticks remaining until impact, so the
# client draws and fills it. Light attacks are not telegraphed: their windup is already visible in the movement.
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


# Simulates all entities with a body (players, fakes and NPCs) by ascending net_id with the
# input from take(s).
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
		# NPCs already pushed their input in step 0 (_run_npc_brains); the fakes generate it here.
		var synthetic: bool = brain != null or _npcs.has(entity.net_id)
		if brain != null:
			var generated: PlayerInput = brain.next_input(s, before, character.yaw)
			generated.tick = s
			queue.push(generated.quantized(), 0, s)
		elif _npcs.has(entity.net_id):
			pass
		elif _lingering.has(entity.net_id):
			# The body of whoever left in combat: truly neutral inputs (no buttons), standing still.
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


# The server does not accept client state, so these checks only detect its own errors: a jump of more
# than 1.5 m in one tick is logged as a physics error, and a position that is not finite sends the
# player back to their spawn point. (Falling below FALL_LIMIT_Y is a death: the combat step resolves it.)
# A dead player is not checked: their body is placed by combat.
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


# Places the character at [param position] with the given [param yaw] and velocity 0. The state goes through
# encode/decode (it is the one the client will reconstruct) and the teleport counter goes up.
func _place(entity: NetEntity, position: Vector3, yaw: float) -> void:
	var character: PlayerCharacter = entity.get_character()
	var state: PlayerState = character.get_state()
	state.position = position
	state.velocity = Vector3.ZERO
	state.yaw = PlayerState.to_f32(yaw)
	state.grounded = _zone_bodies._probe_grounded(position)
	state.coyote_ticks = 0
	state.jump_buffer_ticks = 0
	character.set_state(PlayerState.decode(state.encode()))
	entity.teleport_counter = (entity.teleport_counter + 1) & EntityRecord.TELEPORT_MASK


# --- Joins and leaves -------------------------------------------------------------------------


# Messages of a spawn (section 3): the own SPAWN, those of everything relevant to the newcomer and theirs
# for whoever considers them relevant. [param peer] is null for a fake player.
# A player's SPAWN carries their level only toward their realm (protocol 7, docs/progression.md §7.3): the
# newcomer's is encoded once per receiving realm (three variants at most) and those of the others toward them,
# with their realm.
func _announce_arrival(entity: NetEntity, peer: ServerPeer, s: int) -> void:
	_zone_bodies._announce_arrival(entity, peer, s)


# --- History, interest and snapshots ----------------------------------------------------------

# StateHistory.record() of all entities (and the --state-log CSV), after simulating and spawning: it is the
# state "after s".
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
			# Defensive flags (block, parry, invulnerable, dead, wide block) for the rewind, over bits 0-2 of the record:
			# bit 3 of the record (slot 2, which is not written here) never gets in, because in the history it is
			# DEFENSE_BLOCKING (docs/abilities.md, 3.6).
			flags = (flags & EntityRecord.HISTORY_FLAGS_MASK) \
					| ActionMachine.defense_flags(character.combat, s)
		else:
			flags |= EntityRecord.FLAG_GROUNDED
			if is_instance_valid(entity.node):
				yaw = entity.node.rotation.y
		_history.record(s, entity.net_id, position, yaw, flags)
		# The state log is for players only: an NPC has no client to compare against.
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


# Staggered interest and one SNAPSHOT to each client every SNAPSHOT_INTERVAL_TICKS ticks, staggered
# by the parity of its net_id.
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


# Recomputes what [param peer] sees: each change generates a SPAWN or a DESPAWN (reason 0).
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


# Entities with ALWAYS_RELEVANT do not go through the policy. An invisible GM does not enter anyone else's
# interest (docs/platform.md §9.1), whatever the policy.
func _is_relevant(observer: NetEntity, entity: NetEntity, was_relevant: bool) -> bool:
	if entity.gm_invisible and entity != observer:
		return false
	if (entity.flags & NetEntity.FLAG_ALWAYS_RELEVANT) != 0:
		return true
	return interest_policy.is_relevant(observer, entity, was_relevant)


func _send(peer: ServerPeer, channel: int, bytes: PackedByteArray) -> void:
	if _transport != null:
		_transport.send(peer.peer_id, channel, bytes)


# What the social service needs from the server: the peers in the world and sending over the reliable channel.
func _social_peers() -> Array[ServerPeer]:
	return _world_peers


func _social_send(peer_id: int, bytes: PackedByteArray) -> void:
	if _transport != null:
		_transport.send(peer_id, NetProtocol.CH_RELIABLE, bytes)


# What progress sends (INVENTORY_DELTA, INVENTORY_FULL, WALLET_UPDATE and PROGRESS_UPDATE): over the reliable
# channel and only to the owner (progression.md §4.6).
func _progress_send(peer: ServerPeer, bytes: PackedByteArray) -> void:
	_send(peer, NetProtocol.CH_RELIABLE, bytes)


# A reply line from a progression GM command over the chat system channel (progression.md P5d).
func _progress_reply(peer: ServerPeer, text: String) -> void:
	if _social != null and peer != null and peer.state == ServerPeer.State.IN_WORLD:
		_social.get_chat().send_system(peer, text, _tick)


# --- Combat: events, enemies, ground ------------------------------------------------------------


func _is_player(net_id: int) -> bool:
	var entity: NetEntity = _registry.get_entity(net_id)
	return entity != null and entity.kind == NetProtocol.EntityKind.PLAYER


# Gathers, per realm, the positions of whoever can be a combat bot's target on this tick.
func _rebuild_target_cache() -> void:
	_zone_bots._rebuild_target_cache()


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


# --- Commands and console ----------------------------------------------------------------------


# -- Network commands (they act on whoever sends them) --


# -- Console commands --


## The maintenance NOTICE at [param remaining] seconds (in minutes from 60 s), with the platform's text if there is one.
static func maintenance_notice_text(remaining: int, message: String) -> String:
	var left: String = "%d s" % remaining
	if remaining >= 60:
		left = "%d min" % ceili(float(remaining) / 60.0)
	var text: String = "El servidor se cerrará por mantenimiento en %s" % left
	if not message.is_empty():
		text += ": " + message
	return text


# --- Fortresses, scoreboard, in-combat exit and /atascado -------------------------------------------

# Creates the zone's fortress controller and connects it with combat: hits on the gate, the DEATH and HIT of
# defenders, the respawn points that are valid and the waves.
func _setup_fortresses(world: Node3D) -> void:
	_fortresses = FortressController.new()
	_fortresses.score_keeper = _scores
	_fortresses.candidates_source = Callable(self, "_presence_candidates")
	_fortresses.bodies_source = Callable(self, "_gate_blockers")
	_fortresses.captain_killer = Callable(_zone_bodies, "_kill_captain_npc")
	_fortresses.setup(world, _registry, _tick)
	_fortresses.war_event_emitted.connect(_zone_events._on_war_event)
	_fortresses.object_state_emitted.connect(_zone_events._on_object_state)
	_fortresses.gate_damage_started.connect(_zone_events._on_gate_damage_started)
	_combat.event_emitted.connect(_fortresses.on_combat_event)
	_combat.structure_hit.connect(_fortresses.on_structure_hit)
	# Rewards (progression.md §6.2): the capture reward and objective merits.
	if _progress != null:
		_fortresses.fortress_captured.connect(_progress.on_capture)
		_fortresses.objective_time.connect(_progress.on_objective_ticks)
	_combat.set_structure_targets(_fortresses.get_structure_targets())
	_combat.fortress_states = Callable(_fortresses, "get_states")
	if _fortresses.has_fortresses():
		# Respawn waves every 10 s in zones with a fortress (GUE-14).
		_combat.timing.respawn_wave_ticks = CombatTiming.WAVE_TICKS


# Creates the zone's NPC spawner system (posts, navigation, records) and connects it with combat and the
# fortresses, except with --no-npcs.
func _setup_npcs(world: Node3D) -> void:
	if _config.no_npcs:
		return
	_npc_system = NpcSpawnerSystem.new()
	_npc_system.log_sink = Callable(self, "_log")
	_npc_system.setup(self, world, _config.zone_id)


# The tick the server is about to simulate: that of the debug commands that arrive in the poll.
func _next_tick() -> int:
	return _tick + 1


# The players (network and fake, not NPCs) that may count in the circle: alive, with the last real
# input they sent and not being the body left after a removal. Invisible GMs are not included.
func _presence_candidates(_tick_now: int) -> Array:
	var candidates: Array = []
	for entity: NetEntity in _registry.get_sorted():
		# An invisible GM does not count in the circle (docs/platform.md §9.1).
		if entity.kind != NetProtocol.EntityKind.PLAYER or entity.gm_invisible:
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
		candidate.gm_forced = entity.gm_forced
		candidates.append(candidate)
	return candidates


# The feet of living or knocked-down characters (players and NPCs): those that prevent closing the gate if they overlap
# the doorway (docs/abilities.md, section 4.5: the gate is not repaired with a knocked-down player in the doorway).
func _gate_blockers() -> PackedVector3Array:
	var positions := PackedVector3Array()
	for entity: NetEntity in _registry.get_sorted():
		if entity.get_character() == null or entity.gm_invisible:
			continue
		var combatant: Combatant = _combat.get_combatant(entity.net_id)
		if combatant != null and not combatant.is_dead():
			positions.append(entity.get_position())
	return positions


# The zone scoreboard to all players (pages of at most 66 rows).
func _send_scoreboard() -> void:
	_zone_events._send_scoreboard()


# -- Exit and disconnect in combat (GUE-41) --


# -- /atascado (MUN-41) --

# UNSTUCK_REQUEST or command 7: starts the channeling if applicable and tells the player how it went.
func _request_unstuck(peer: ServerPeer) -> int:
	return _zone_lingering._request_unstuck(peer)


func _send_notice(peer: ServerPeer, text: String) -> void:
	if _transport == null or peer.state != ServerPeer.State.IN_WORLD:
		return
	var notice := NetMessages.Notice.new()
	notice.code = NetProtocol.NoticeCode.INFO
	notice.text = text
	_transport.send(peer.peer_id, NetProtocol.CH_RELIABLE, notice.encode())


# -- Battle log (GUE-17) --

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


# --- Transport --------------------------------------------------------------------------------

func _connect_transport() -> void:
	_transport.peer_authenticating.connect(_zone_sessions._on_peer_authenticating)
	_transport.auth_received.connect(_zone_sessions._on_auth_received)
	_transport.peer_connected.connect(_zone_sessions._on_peer_connected)
	_transport.peer_disconnected.connect(_zone_sessions._on_peer_disconnected)
	_transport.packet_received.connect(_zone_intents._on_packet_received)
	_transport.packets_discarded.connect(_zone_sessions._on_packets_discarded)


func _disconnect_transport() -> void:
	if _transport == null or not is_instance_valid(_transport):
		return
	if _transport.peer_authenticating.is_connected(_zone_sessions._on_peer_authenticating):
		_transport.peer_authenticating.disconnect(_zone_sessions._on_peer_authenticating)
	if _transport.auth_received.is_connected(_zone_sessions._on_auth_received):
		_transport.auth_received.disconnect(_zone_sessions._on_auth_received)
	if _transport.peer_connected.is_connected(_zone_sessions._on_peer_connected):
		_transport.peer_connected.disconnect(_zone_sessions._on_peer_connected)
	if _transport.peer_disconnected.is_connected(_zone_sessions._on_peer_disconnected):
		_transport.peer_disconnected.disconnect(_zone_sessions._on_peer_disconnected)
	if _transport.packet_received.is_connected(_zone_intents._on_packet_received):
		_transport.packet_received.disconnect(_zone_intents._on_packet_received)
	if _transport.packets_discarded.is_connected(_zone_sessions._on_packets_discarded):
		_transport.packets_discarded.disconnect(_zone_sessions._on_packets_discarded)


# --- Platform (docs/platform.md §5.2 and §14.3) ------------------------------------------------


func _on_packet_received(peer_id: int, bytes: PackedByteArray) -> void:
	_zone_intents._on_packet_received(peer_id, bytes)


func _mark_leaving(peer: ServerPeer) -> void:
	_zone_sessions._mark_leaving(peer)


# --- Helpers ----------------------------------------------------------------------------------


# Simulation fingerprint, computed over an instance inside the tree after _ready().
func _compute_sim_hash() -> int:
	var character: PlayerCharacter = _zone_bodies._instantiate_character()
	_players_root.add_child(character)
	var hash_value: int = NetProtocol.compute_sim_hash(character)
	_players_root.remove_child(character)
	character.free()
	return hash_value


# Yaw (same convention as Node3D.rotation.y) that a basis faces.
static func _yaw_of(transform: Transform3D) -> float:
	var forward: Vector3 = -transform.basis.z
	return atan2(-forward.x, -forward.z)


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


# Combat summary for the report: the director's counters, the events sent and the
# suspicion score per peer (only the suspicious ones).
func _combat_report() -> Dictionary:
	return _zone_report._combat_report()


func _log(text: String) -> void:
	if log_enabled:
		print("[Eldmark] %s" % text)
