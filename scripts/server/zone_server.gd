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
## [b]Connection[/b] (section 3): the HELLO arrives through [signal NetTransport.auth_received] and is
## validated by [ServerAuth]; on success WELCOME is answered and [method NetTransport.complete_auth]
## (the peer moves to [constant ServerPeer.State.LOADING]) and, otherwise, REJECT and an orderly
## disconnect. Nothing is sent through [code]send[/code] until [signal NetTransport.peer_connected]
## arrives. The player appears at the end of the tick in which CLIENT_READY arrives.
## [br][br]
## [b]With the platform[/b] (docs/platform.md §5.2, [TicketAuthProvider] and [ZonePlatform]): a HELLO
## with a valid ticket leaves the peer in [constant ServerPeer.State.VERIFYING] (it counts toward capacity)
## while the platform claims it; on the 200, the zone checks that it admits its realm (REALM) and that
## there is room (FULL) and sends it the WELCOME with the realm and the character name, never those from
## the HELLO. A removal in VERIFYING cancels the wait (if the claim arrives later, it is released); one in
## LOADING releases the lease without saving.
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
## [b]Moderation[/b] (docs/platform.md §9, [ModerationService], [method get_moderation]): the chat GM
## channel carries [code]/gm[/code] (through the [CommandRegistry], with the claim's role),
## [code]/ignorar[/code] (ignore), [code]/designorar[/code] (unignore) and [code]/reportar[/code]
## (report); with the platform, DEBUG_COMMAND additionally requires the minimum role of each command. An
## invisible GM ([method set_gm_invisible]) does not enter anyone's interest, neither deals nor receives
## damage, is not a target of NPCs or bots and does not count in the circle or on the scoreboard. The
## commands that move, heal or show a character mark it with [member NetEntity.gm_forced] (with the
## platform). Chat is per character ([method SocialService.on_peer_joined]); mutes, ignored players and
## the report ring are applied by [ChatRouter]; the audit and messages go to the platform batches;
## moderation notices go out on entry.
## [br][br]
## [b]Security[/b] (section 12): per-peer limiters, warnings with a kick at 50 in 600 ticks (kick NOTICE
## and disconnect), a cap on connections per IP, unexpected message types according to the session state
## and debug commands only with [code]--debug-commands[/code].
## [br][br]
## [b]Fake players[/b] ([method add_fake_player]): network-less players whose inputs come from a
## [BotBrain] and go straight into their [InputQueue]; they serve for tests and load. With a
## [FillerKeeper] ([method set_filler_keeper], [code]--max-realm-diff[/code]) the filler bots follow the
## joins and leaves of people and do not take their slots: a HELLO that arrives with the server full only
## because of them gets in, one displaces one of theirs and it leaves when that person enters the world
## (GUE-43; docs/fortress.md, section 7). Combat and siege bots see their enemies (and the siege ones, the
## NPCs defending the fort) with their velocity and knockdown ([BotTarget]) and, since H5, fight with the
## phase 4 kit (docs/abilities.md, section 7.1): they read their combat state and health from the
## server and the combat ones revive knocked-down allies (the siege ones follow their plan). The siege
## ones also avoid the telegraphed strikes of NPCs and count their own in the rally (F6b).
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

## Character scene. On the server its [code]Visual[/code] node is freed.
const PLAYER_SCENE: PackedScene = preload("res://scenes/characters/player_character.tscn")
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
## How many ticks between checks of the HELLO deadline.
const HELLO_CHECK_TICKS: int = 10
## Deadline of a peer in VERIFYING since it connected (ms, real time): once past, REJECT UNAVAILABLE.
## Less than the 10 s [constant NetTransport.AUTH_TIMEOUT_SECONDS], so the REJECT always arrives
## (docs/platform.md §5.2).
const VERIFY_TIMEOUT_MS: int = 7000
## Reason with which the expired VERIFYING deadline is logged.
const VERIFY_TIMEOUT_REASON: String = "la plataforma no ha contestado a tiempo"
## Ticks to wait, after [method stop], for the peers to leave before closing the transport.
const STOP_DRAIN_TICKS: int = 30
## Ticks to wait at most, after [method stop] or [method close_instance], for the platform to answer
## the final saves and for nothing to remain queued or in flight (10 s, docs/platform.md §7.2 and §6.1).
const SAVE_DRAIN_TICKS: int = 600
## Kick NOTICE of the §6.1 shutdown, after the final saves.
const INSTANCE_CLOSED_TEXT: String = "El servidor de la zona se ha reiniciado: vuelve a entrar"
## NOTICE of the removal without saving (§7.3): a rejected save and a lease_lost.
const SAVE_REJECTED_TEXT: String = "No se ha podido guardar tu personaje; vuelve a entrar"
const LEASE_LOST_TEXT: String = "Tu personaje ha entrado en otro servidor"
## Seconds before the platform maintenance at which a warning is given (docs/platform.md §7.2 and §12).
const MAINTENANCE_NOTICE_SECONDS: Array[int] = [600, 300, 60, 30, 10]
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
## Uses of /atascado (unstuck) kept by the report (the most recent ones).
const MAX_LOGGED_UNSTUCK: int = 200
## [ServerMetrics] section for sending the ENTITY_EVENT messages (inside the combat one).
const SECTION_COMBAT_EVENTS: StringName = &"combat_events"
## Player records and kicks that the report keeps (the most recent ones); anything older is summarized
## in totals. Without a cap, a client that joins and leaves in a loop would make memory grow without limit.
const MAX_LOGGED_PLAYERS: int = 1000
const MAX_LOGGED_KICKS: int = 200
## Physics error warnings written to the log (the rest are only counted).
const MAX_LOGGED_PHYSICS_ERRORS: int = 10
## Maximum coordinate (in absolute value) that a debug teleport accepts.
const MAX_TELEPORT_COORDINATE: float = 5000.0
## Text of the default shutdown NOTICE.
const DEFAULT_SHUTDOWN_TEXT: String = "El servidor se está cerrando"
## Training dummies at most (those of the zones and those of the spawn_dummy command).
const MAX_DUMMIES: int = 16
## Distance (m) in front of the player at which a dummy from the spawn_dummy command appears.
const DUMMY_SPAWN_DISTANCE: float = 3.0
## Name of the training dummy.
const DUMMY_NAME: String = "Maniquí"
## Name of the fake players ([method add_fake_player]) with their number: "Bot-01". The hyphen and the
## digits deliberately leave it outside [NameRules]: the client does not offer social actions to a name that
## does not satisfy them ([code]SocialTarget.is_social_target[/code]), because a fake has no connection and
## the server would answer "not connected" to the invitation or the whisper (docs/social.md, section 12.6).
const FAKE_NAME_FORMAT: String = "Bot-%02d"
## Header of the combat log (--combat-log).
const COMBAT_LOG_HEADER: String = "tick,atacante,objetivo,ataque,view_tick,rebobinado,resultado,daño"
## Remaining seconds at which a shutdown countdown warns the players.
const SHUTDOWN_NOTICE_SECONDS: Array[int] = [60, 30, 10, 5, 4, 3, 2, 1]
## Length (m) of the ray used to find the ground under a dummy point.
const _GROUND_PROBE_UP: float = 4.0
const _GROUND_PROBE_DOWN: float = 12.0
## Length of the probe that decides whether a spawn point is on the ground.
const _PROBE_UP: float = 0.1
const _PROBE_DOWN: float = 0.3
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
var _drain_ticks: int = 0
# Ticks of the wait for peers to leave (since the shutdown NOTICE).
var _peer_drain_ticks: int = 0
# §6.1 shutdown: the kick NOTICE goes out when the final saves already have an answer.
var _kick_after_saves: bool = false
# Reason for the final save (CharacterSaver.Reason) of the body that remains after an in-combat exit.
var _lingering_save_reasons: Dictionary[int, int] = {}
# Maintenance announced by the heartbeat: its Unix time (0 = none), its text and the warnings already
# given (seconds of MAINTENANCE_NOTICE_SECONDS).
var _maintenance_at_unix: int = 0
var _maintenance_message: String = ""
var _maintenance_announced: Array[int] = []
# The last maintenance whose time has already arrived: the heartbeat may keep announcing it until the zone stops.
var _maintenance_fired_at_unix: int = 0
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
# Name key -> net_id of whoever is channeling /atascado (unstuck).
var _unstuck_players: Dictionary[String, int] = {}
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
# Cache of targets for the combat bots: tick of the last time, positions and ids per realm, and which
# realms are hostile to each other.
var _targets_tick: int = -1
var _targets_by_realm: Dictionary = {}
var _targets_ids_by_realm: Dictionary = {}
# Per realm, 1 if the target at the same index is an NPC (what the SIEGE fakes look for first).
var _targets_npc_by_realm: Dictionary = {}
# Fakes' kit (H5): the velocity of each target and whether it is knocked down, in the same order.
var _targets_velocity_by_realm: Dictionary = {}
var _targets_downed_by_realm: Dictionary = {}
var _hostile_cache: Dictionary = {}
# Siege of the fakes with the SIEGE brain (GUE-15): the view of each fortress, shared by all and updated
# every tick, and the approach routes of the zone (data/routes/<zone>.tres; null if there are none).
var _siege_views: Dictionary[StringName, SiegeView] = {}
var _siege_routes: ApproachRoutes = null
var _siege_routes_loaded: bool = false
# Telegraphed strikes (TELEGRAPH) that the SIEGE fakes avoid (F6b): tick of the list, the NPCs' strikes in
# progress and the realm of each striking NPC.
var _threats_tick: int = -1
var _threats: Array[BotBrain.Threat] = []
var _threat_realms: PackedInt32Array = PackedInt32Array()
# Living players per realm (positions and ids) with which the SIEGE fakes count their own at the rally
# point (GUE-44), and the tick of the list.
var _allies_tick: int = -1
var _allies_by_realm: Dictionary[int, PackedVector3Array] = {}
var _ally_ids_by_realm: Dictionary[int, PackedInt32Array] = {}
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
var _fake_counter: int = 0
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
# Key ("ip:<group>" or "name:<normalized name>") -> tick until which it cannot rejoin.
var _kick_until: Dictionary[String, int] = {}
var _rejects: Dictionary[String, int] = {}
var _physics_errors: int = 0
var _teleports: int = 0
var _respawns: int = 0
var _synced_wire_in: int = 0
var _synced_wire_out: int = 0
var _log_last_usec: int = 0
# "Real" tick clock (at the nominal rate), to know how many ticks the server has lost between two polls.
# _clock_origin_usec is the instant of start().
var _clock_origin_usec: int = 0
var _last_poll_real_tick: int = 0
var _log_last_wire_out: int = 0
var _log_last_wire_in: int = 0
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
		_platform.player_count_source = get_player_count
		_saver = CharacterSaver.new(_platform, maxi(config.save_interval_s, 1) * Engine.physics_ticks_per_second)
		_saver.log_sink = Callable(self, "_log")
		_saver.save_rejected.connect(_on_save_rejected)
	# The progress section is registered first (progression.md §9.2): before any other.
	_progress = ProgressService.new()
	_progress.log_sink = Callable(self, "_log")
	_progress.send_sink = Callable(self, "_progress_send")
	_progress.strike_sink = Callable(self, "_add_strike")
	_progress.notice_sink = Callable(self, "_send_notice")
	_progress.level_up_sink = Callable(self, "_announce_level_up")
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
	_auth.set_connected_names_source(get_connected_names)
	_auth.set_realm_counts_source(get_realm_counts)
	_spawn_picker = SpawnPicker.new(world)
	_safe_areas = SafeAreas.from_world(world)
	_combat = CombatDirector.new(_history, StringName(config.zone_id), world, _safe_areas,
			Callable(self, "_place"), Callable(self, "_pick_spawn_point"))
	_combat.event_emitted.connect(_on_combat_event)
	_combat.metrics = _metrics
	# Whoever has an inventory respawns with their equipment and refills their bag at the camp (progression.md §4.4 and §8).
	_combat.loadout_source = _progress.loadout_for
	_combat.camp_step = _progress.camp_step
	# Projectiles take their id from the entity id space (with its quarantine).
	_combat.projectiles.registry = _registry
	_combat.projectiles.spawned.connect(_on_projectile_spawned)
	_combat.projectiles.despawned.connect(_on_projectile_despawned)
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
	_register_commands()
	_social = SocialService.new(Callable(self, "_social_peers"), Callable(self, "_social_send"),
			Callable(self, "_add_strike"))
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
	if _run_state != _RunState.RUNNING:
		return
	_log("Cerrando el servidor de la zona '%s' (tick %d)" % [_config.zone_id, _tick])
	_players_at_stop = get_player_count()
	# Whatever changed in the fortresses goes out before emptying the world (the instance stays live until the removal).
	if _fortress_persistence != null:
		_fortress_persistence.flush(_tick)
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
	_wind_down()
	_begin_drain(false)


## The shutdown of docs/platform.md §6.1, when the platform deems the instance lost, replaced or stopped
## ([param code]; [ServerMain] calls it with [signal instance_closed]): first the final save of everyone and the
## release of those in LOADING, without kicking anyone (the zone stops reading their inputs and giving rewards);
## those in VERIFYING receive REJECT UNAVAILABLE. Once the platform has answered the finals and nothing is
## pending (or after [member save_drain_ticks]), a kick NOTICE "El servidor de la zona se ha reiniciado:
## vuelve a entrar" (the zone server has restarted: rejoin) to everyone and disconnect: whoever rejoins right away
## loads their final save, not the previous one.
func close_instance(code: String) -> void:
	if _run_state != _RunState.RUNNING:
		return
	_log("La plataforma ha cerrado esta instancia (%s): guardados finales antes de echar a nadie (tick %d)"
			% [code, _tick])
	_players_at_stop = get_player_count()
	# The fortresses no longer belong to this instance: no records and no events.
	if _fortress_persistence != null:
		_fortress_persistence.close()
	if _transport != null:
		for peer_id: int in get_peer_ids():
			var peer: ServerPeer = _peers[peer_id]
			match peer.state:
				ServerPeer.State.AUTHENTICATING, ServerPeer.State.VERIFYING:
					_reject(peer, NetProtocol.Result.UNAVAILABLE)
				ServerPeer.State.LOADING:
					_leave_auth_states(peer)
		_transport.flush()
	_wind_down()
	_begin_drain(true)


## true when [method stop] or [method close_instance] have finished: the peers have left and the saves
## have an answer (or the wait ran out) and the transport is closed.
func is_stopped() -> bool:
	return _run_state == _RunState.STOPPED


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
	return _maintenance_at_unix


## Current tick: the last one simulated (0 before starting). The first one is 1.
func get_tick() -> int:
	return _tick


## The peer with that id (in any state) or null.
func get_peer(peer_id: int) -> ServerPeer:
	return _peers.get(peer_id)


## Ids of all known peers, sorted.
func get_peer_ids() -> PackedInt32Array:
	var ids := PackedInt32Array(_peers.keys())
	ids.sort()
	return ids


## Players that count toward capacity: the peers verifying their ticket with the platform (docs/platform.md
## §5.2: several simultaneous entries do not exceed max_players), the accepted ones (loading the zone or already
## inside) and the fake players. Those that have not yet sent the HELLO or are leaving (also fakes with a
## requested removal, which disappear at the start of the next tick) do not count. Filler fakes do count here, but
## yield their slot to people (see [method set_filler_keeper]): while a person loads the zone in the slot a fake
## set aside for them, both count (one too many), and the fake leaves when the person enters the world.
func get_player_count() -> int:
	var count: int = _fakes.size() - _fake_leaving.size()
	for peer: ServerPeer in _peers.values():
		if peer.state == ServerPeer.State.VERIFYING or peer.state == ServerPeer.State.LOADING \
				or peer.state == ServerPeer.State.IN_WORLD:
			count += 1
	return count


## People per realm (Vardheim, Solmarch, Askarra; see [RealmBalance]): the truly accepted clients, loading the
## zone or already inside (with [param in_world_only], only those already inside). Fake players and the bodies
## that remain after an in-combat removal do not count. [param excluded] is not counted (the one who just
## entered, for their WELCOME). It is the count of the WELCOME and of the REJECT 9 IMBALANCE.
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


## Entries of the cooldown after kicks (in force or not yet purged). They are purged when the next kick is
## recorded, so the dictionary does not grow beyond the kicks of the last [constant KICK_COOLDOWN_TICKS] ticks.
func get_cooldown_count() -> int:
	return _kick_until.size()


## Names of the players present in the zone: the accepted peers (loading or already inside) and the fake
## players. [ServerAuth] rejects with NAME a HELLO whose name repeats any of them.
func get_connected_names() -> PackedStringArray:
	var names := PackedStringArray()
	for peer: ServerPeer in _peers.values():
		if peer.state == ServerPeer.State.LOADING or peer.state == ServerPeer.State.IN_WORLD:
			names.append(peer.display_name)
	for net_id: int in _fakes:
		var record: _PlayerRecord = _player_by_net.get(net_id)
		if record != null:
			names.append(record.display_name)
	# The name of whoever left in combat stays reserved while their body is in the world (GUE-41).
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
	if _transport == null:
		peer.kicked = true
		_mark_leaving(peer)
		return
	_kick(peer, reason, true, notice_text)


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
	return _unstuck


## The key of [param entity] in the [UnstuckTracker]: with the platform, [code]"character:<id>"[/code] (that of
## the saved [code]unstuck[/code] timer, docs/progression.md §8); without it, that of its name (rejoining with the
## same name does not skip the reuse cooldown).
func unstuck_key_of(entity: NetEntity) -> String:
	var character_id: int = _progress.character_id_of(entity.net_id) if _progress != null else 0
	if character_id > 0:
		return "character:%d" % character_id
	return NameRules.normalize_key(entity.display_name)


## Places [param entity] at [param position] facing [param yaw] (the return-to-world rule of the SAFE zones,
## docs/progression.md §8) if the spot is valid: finite, within the zone limits and with ground. true if it places it.
func place_returning(entity: NetEntity, position: Vector3, yaw: float) -> bool:
	if entity == null or entity.get_character() == null or not _is_valid_teleport_target(position) \
			or not is_finite(yaw) or not _probe_grounded(position):
		return false
	_place(entity, position, yaw)
	return true


## Bodies that remain in the world after the removal of a player in combat (GUE-41).
func get_lingering_count() -> int:
	return _lingering.size()


## true if [param net_id] is the body of a player who left in combat and is waiting to be removed.
func is_lingering(net_id: int) -> bool:
	return _lingering.has(net_id)


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
	combatant.requests_respawn_on_death = true
	_fakes[entity.net_id] = brain
	var pattern: BotBrain.Pattern = brain.get_pattern()
	var fighter: bool = pattern == BotBrain.Pattern.COMBAT or pattern == BotBrain.Pattern.SIEGE
	if fighter and not brain.has_enemy_finder():
		brain.set_enemy_finder(_find_enemy_target.bind(entity.net_id))
	if fighter and not brain.has_combat_source():
		# The phase 4 kit (H5): the server's combat state after the last tick, the health and the knocked-down allies.
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
		# The kit's bow only fires if the arrow lands (the palisade, the closed gate, also its own).
		brain.set_line_of_sight(_bot_line_of_sight)
	var record: _PlayerRecord = _player_by_net[entity.net_id]
	record.is_fake = true
	_announce_arrival(entity, null, _tick)
	if combatant.template_id > 0:
		_combat.announce_loadout(combatant, _tick, true)
	_log("Alta de %s (jugador falso, net_id %d, %s); jugadores: %d" % [entity.display_name,
			entity.net_id, NetProtocol.realm_display_name(realm), get_player_count()])
	return entity.net_id


## The siege view of fortress [param fortress_id] (empty = the first of the zone) used by fake players with the
## [constant BotBrain.Pattern.SIEGE] brain: it is created the first time it is requested, carries the gate and
## circle positions and is updated every tick with the live state of the fortress
## ([method SiegeView.update_from_state]). null if the zone has no fortresses.
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


## The approach routes of the zone (data/routes/<zone>.tres), or null if it has none.
func get_approach_routes() -> ApproachRoutes:
	if not _siege_routes_loaded:
		_siege_routes_loaded = true
		var path: String = "res://data/routes/%s.tres" % _config.zone_id
		if ResourceLoader.exists(path):
			_siege_routes = load(path) as ApproachRoutes
	return _siege_routes


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
	if _run_state != _RunState.RUNNING or not _fakes.has(net_id) or _fake_leaving.has(net_id):
		return false
	_fake_leaving.append(net_id)
	return true


## Withdraws filler fake [param net_id], which yields its slot to a person (GUE-42 and GUE-43; requested by
## [FillerKeeper]): like [method remove_fake_player], but its removal is never a death, not even if it is knocked
## down (only DESPAWN, no DEATH or KILL for whoever knocked it down): a person entering kills nobody (review of
## the abilities integration). Returns false if it is not a fake player (or is already leaving).
func retire_filler(net_id: int) -> bool:
	if not remove_fake_player(net_id):
		return false
	_fake_leaving_quietly[net_id] = true
	return true


## true if withdrawing fake player [param net_id] right now cuts nothing off: it is not knocked down nor reviving or
## finishing off anyone (dead and waiting to respawn, too). The [member FillerKeeper.calm_check] of the filler fakes.
func is_fake_calm(net_id: int) -> bool:
	var combatant: Combatant = _combat.get_combatant(net_id)
	return combatant == null or (not combatant.is_downed() and not combatant.is_interacting())


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
	if _run_state != _RunState.RUNNING or brain == null:
		return -1
	var entity: NetEntity = _create_body(NetProtocol.EntityKind.NPC, display_name, realm, 0, _tick,
			position, yaw)
	if entity == null:
		return -1
	_npcs[entity.net_id] = brain
	var combatant: Combatant = _combat.get_combatant(entity.net_id)
	if definition != null:
		# Its definition rules: health, weapon, safe zone and the number the client sees (model and boss bar).
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


## Removes NPC [param net_id] (DESPAWN to whoever saw it). Returns false if it is not an NPC.
func remove_npc(net_id: int) -> bool:
	var entity: NetEntity = _registry.get_entity(net_id)
	if entity == null or not _npcs.has(net_id):
		return false
	_remove_player(entity, _tick, NetProtocol.DespawnReason.DISCONNECTED)
	return true


## Creates a training dummy (immortal NPC of the neutral side) at [param position] facing
## [param yaw], with mode [param mode] ([enum NpcBrain.Mode]). The position is lowered to the ground if there is
## one below. Returns its net_id, or -1 if there is no room ([constant MAX_DUMMIES]) or it cannot be created.
func spawn_dummy(position: Vector3, yaw: float, mode: int = NpcBrain.Mode.STILL) -> int:
	if get_dummy_count() >= MAX_DUMMIES:
		return -1
	return add_npc(NpcBrain.new(mode), DUMMY_NAME, RealmCatalog.NEUTRAL_CODE,
			_ground_position(position), yaw, true)


## Places a still dummy at each marker of the zone's [code]dummy_points[/code] group (one in
## the test world and one next to each camp of Vado Gris). Returns how many it created.
func spawn_zone_dummies() -> int:
	var created: int = 0
	for marker: Node3D in NetZones.get_dummy_points(_world):
		var transform: Transform3D = marker.global_transform
		if spawn_dummy(transform.origin, CombatDirector._yaw_of(transform)) > 0:
			created += 1
	return created


## Test double of the captain of [param fortress_id] while there is no NPC spawner: a mortal, still NPC
## at the fortress's [code]CaptainSpawn[/code], on the owner's side, registered as its
## captain ([method FortressController.register_captain]). On death (from a hit or with
## [code]fort_kill_captain[/code]) it opens the capture circle. Returns its net_id, or -1 if it cannot.
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


## Living dummies (immortal NPCs).
func get_dummy_count() -> int:
	var count: int = 0
	for net_id: int in _npcs:
		var combatant: Combatant = _combat.get_combatant(net_id)
		if combatant != null and combatant.immortal:
			count += 1
	return count


## Executes a console line ([code]kick Ana[/code]) and returns the response. It is what the server does with
## each line of standard input; tests call it directly.
func console_command(line: String) -> String:
	return _commands.execute_console(line)


## Starts the standard input console (reader thread, without blocking the tick). Returns false if there is no
## usable standard input or it was already running.
func start_console() -> bool:
	if _console == null:
		_console = ServerConsole.new()
	return _console.start()


## The console ([ServerConsole]), or null if it has not been started nor given a line.
func get_console() -> ServerConsole:
	return _console


## Pushes a line into the console queue as if it had been typed on standard input; it is executed at the start
## of the next tick.
func push_console_line(line: String) -> void:
	if _console == null:
		_console = ServerConsole.new()
	_console.push_line(line)


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
	if path.is_empty():
		return ERR_INVALID_PARAMETER
	var directory: String = path.get_base_dir()
	if not directory.is_empty() and not DirAccess.dir_exists_absolute(directory):
		var made: Error = DirAccess.make_dir_recursive_absolute(directory)
		if made != OK:
			return made
	# Written to a temporary file and renamed into place, so a server killed mid-write (SIGKILL,
	# docker stop) never leaves an empty or truncated report: readers see the old one or the new one.
	var temp_path: String = path + ".tmp"
	var file: FileAccess = FileAccess.open(temp_path, FileAccess.WRITE)
	if file == null:
		return FileAccess.get_open_error()
	file.store_string(JSON.stringify(_build_report(), "\t"))
	file.close()
	var renamed: Error = DirAccess.rename_absolute(temp_path, path)
	if renamed != OK and FileAccess.file_exists(path):
		# Some platforms refuse to rename onto an existing file: replace it explicitly.
		DirAccess.remove_absolute(path)
		renamed = DirAccess.rename_absolute(temp_path, path)
	return renamed


# --- Tick loop --------------------------------------------------------------------------------

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
	if _run_state != _RunState.RUNNING:
		# The instance shutdown (instance_closed) has already emptied the world: there is nothing left to simulate.
		return

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
	_process_unstuck(s)
	_metrics.end_section(SECTION_WAR)
	if _npc_system != null:
		_metrics.begin_section(SECTION_NPC)
		_npc_system.step(s)
		_metrics.end_section(SECTION_NPC)
	_check_shutdown_countdown(s)
	_check_maintenance()
	if _run_state != _RunState.RUNNING:
		# A completed countdown has shut the server down on this tick (stop has already emptied the world).
		return

	_process_arrivals(s)
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


# Updates the siege views with the live state of the fortresses (the one after the previous tick, like the NPC
# brains): what the fakes with a SIEGE brain see when deciding their input for tick s.
func _refresh_siege_views() -> void:
	for fortress_id: StringName in _siege_views:
		var state: FortressState = _fortresses.get_fortress_state(fortress_id)
		if state != null:
			_siege_views[fortress_id].update_from_state(state)


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
	state.grounded = _probe_grounded(position)
	state.coyote_ticks = 0
	state.jump_buffer_ticks = 0
	character.set_state(PlayerState.decode(state.encode()))
	entity.teleport_counter = (entity.teleport_counter + 1) & EntityRecord.TELEPORT_MASK


# --- Joins and leaves -------------------------------------------------------------------------

# Spawns, with the state "after s", the peers whose CLIENT_READY arrived on this tick.
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
			# From here the lease belongs to the body: it is saved (track before ProgressService.on_arrival, which
			# may mark it critical) and its final save goes out when it leaves (docs/platform.md §7.2).
			entity.is_staff = peer.claimed.is_staff()
			# The pvp totals from the claim: the base of its section (docs/platform.md §8).
			_scores.load_totals(entity.net_id, peer.claimed.pvp)
			if _saver != null:
				_saver.track(entity.net_id, peer.claimed.character_id, peer.claimed.lease_id, s)
		# Progress (progression.md §9.1 step 4): the prepared one or, without the platform, an ephemeral one is bound to
		# the body; the return-to-world rule, the first-entry kit (critical in this tick's step), level and appearance
		# for the SPAWN, and the equipment from its inventory instead of the template.
		var loadout: ProgressService.Loadout = _progress.on_arrival(entity, peer, s) if _progress != null else null
		peer.entity = entity
		peer.input_queue = _queues[entity.net_id]
		peer.state = ServerPeer.State.IN_WORLD
		var record: _PlayerRecord = _player_by_net[entity.net_id]
		record.peer = peer
		_world_peers.append(peer)
		# With the platform, chat is per character: it recovers the state if it left recently, and takes from the claim
		# its account, the players it ignores and its mute (docs/platform.md §9.2).
		_social.on_peer_joined(peer, s)
		# With an inventory, its equipment; otherwise, the pending template (LOADOUT_SELECT, also before CLIENT_READY) or
		# the default one: the SPAWN already goes out with its weapons and charges, and the LOADOUT after it.
		var combatant: Combatant = _combat.get_combatant(entity.net_id)
		if loadout != null:
			_combat.equip_inventory(combatant, loadout.weapon_1, loadout.weapon_2, loadout.second_active,
					loadout.charges)
		else:
			_combat.equip_template(combatant, maxi(peer.pending_template_id, 0))
		peer.pending_template_id = -1
		_announce_arrival(entity, peer, s)
		if combatant.template_id > 0 or loadout != null:
			_combat.announce_loadout(combatant, s, true)
		# INVENTORY_FULL, WALLET_UPDATE and PROGRESS_UPDATE after the own SPAWN (progression.md §9.1 step 5).
		if _progress != null:
			_progress.after_spawn(entity, peer, s)
		# The moderation notices the account has not seen (docs/platform.md §9.5).
		_moderation.on_arrival(peer)
		player_joined.emit(peer_id, entity.net_id)
		if _filler_keeper != null:
			_filler_keeper.on_person_joined(peer.realm, peer_id)
		_log("Alta de %s (peer %d, net_id %d, %s) en %s; jugadores: %d" % [entity.display_name,
				peer_id, entity.net_id, NetProtocol.realm_display_name(peer.realm),
				entity.get_position(), get_player_count()])


# Creates the entity and the character of a player at a spawn point of their realm and gives it its
# combat. See _create_body.
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


# Creates the entity of type [param kind] with its body (a PlayerCharacter) at [param spawn_origin]
# facing [param spawn_yaw], its input queue, its history track and its combat. The state is
# "the state after s", rounded by encode/decode; the queue starts with tick s already consumed and the
# neutral input as the last applied. null if no ids are left.
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
	# After _ready() (which rewrites the mask): the closed gates of the forts stop the realms that are not
	# their owner. The client does the same with its local character.
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


# Keeps the report ring at max_logged_players records: removes the oldest of those of someone who has
# already left (those of whoever is still inside stay, even if the ring overflows) and summarizes it in totals.
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


# Messages of a spawn (section 3): the own SPAWN, those of everything relevant to the newcomer and theirs
# for whoever considers them relevant. [param peer] is null for a fake player.
# A player's SPAWN carries their level only toward their realm (protocol 7, docs/progression.md §7.3): the
# newcomer's is encoded once per receiving realm (three variants at most) and those of the others toward them,
# with their realm.
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


# Closes the session of the peers that are leaving: DESPAWN (reason 1) to whoever had them as relevant, id
# into quarantine, character released and history track deleted.
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
			# Leaves without having entered: if the filler had set aside a slot for them, it is released (GUE-43; no fake
			# had left).
			if _filler_keeper != null:
				_filler_keeper.release_seat(peer_id)
			continue
		var entity: NetEntity = peer.entity
		# Out of the list first of all: whatever comes out of their removal (the death of a knocked-down player) is no longer for them.
		_world_peers.erase(peer)
		var save_reason: int = CharacterSaver.Reason.KICK if peer.kicked else CharacterSaver.Reason.LOGOUT
		var lingers: bool = not peer.drop_body_at_once and _should_linger(entity, s)
		if lingers:
			_start_lingering(entity, s)
			_lingering_save_reasons[entity.net_id] = save_reason
		else:
			_remove_player(entity, s, NetProtocol.DespawnReason.DISCONNECTED, true, save_reason)
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


# Removals of fake players requested with remove_fake_player().
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


# Removes the player from the world: DESPAWN to whoever saw them, id into quarantine and character released.
# The removal of a knocked-down player (exit, disconnect, --fake-churn, end of the GUE-41 body) is preceded by a
# death on that tick: DEATH and KILL with whoever did them the last damage or knocked them down, and the
# "bled out" source (docs/abilities.md, 4.5). Without [param bleed] (the filler fake yielding its slot to a
# person, retire_filler), it does not: only the DESPAWN. With the platform, the "Exit" of docs/platform.md
# §7.2: the final save ([param save_reason]) before ScoreKeeper.forget; after a removal without saving (drop)
# that finish does nothing.
func _remove_player(entity: NetEntity, s: int, reason: int, bleed: bool = true,
		save_reason: int = CharacterSaver.Reason.LOGOUT) -> void:
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
	if _saver != null:
		_saver.finish(net_id, save_reason)
	_queues.erase(net_id)
	_fakes.erase(net_id)
	_npcs.erase(net_id)
	_lingering.erase(net_id)
	_lingering_save_reasons.erase(net_id)
	_scores.forget(net_id)
	if _progress != null:
		_progress.on_departure(net_id)
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


# Releases all players (server shutdown), without sending DESPAWN. The final saves have already gone out
# (_wind_down).
func _clear_players() -> void:
	for entity: NetEntity in _registry.get_sorted().duplicate():
		if _progress != null:
			_progress.on_departure(entity.net_id)
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
	_lingering_save_reasons.clear()
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


# Peers that have spent too long loading the zone without sending CLIENT_READY.
func _check_loading_timeouts(s: int) -> void:
	if s % 60 != 0:
		return
	for peer: ServerPeer in _peers.values():
		if peer.state == ServerPeer.State.LOADING \
				and s - peer.loading_since_tick >= loading_timeout_ticks:
			_kick(peer, "se agotó el tiempo de carga de la zona")


# Peers that have been connected too long without sending the HELLO: each idle connection takes an ENet slot
# (max_players + 4) until the 5 s deadline of SceneMultiplayer expires, and reopening it costs one
# RTT. They are cut with their own much shorter deadline, without REJECT (there is nothing to answer).
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

# A combat event: ENTITY_EVENT (reliable channel) to the owners of the entities involved
# (victim, attacker, killer and assistants) and to whoever has any of them as relevant. KILL and
# DOWNED go to the whole zone (everyone sees the kill feed, docs/fortress.md section 6, and
# docs/abilities.md, section 5.4). STATUS, HEAL and INTERACT go to the owners of those involved and to whoever
# has the affected one as relevant (not the author). LOADOUT ([signal CombatDirector.event_emitted]): the owner's
# ([param involved] with the player) only to them; the public one ([param involved] empty, charges 0) to whoever has
# the player as relevant, without the owner. Before sending it, it is recorded on the scoreboard and in the battle log.
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
		# The owner's is seen by nobody else; the public one, by whoever has them as relevant.
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


# Spawn of a projectile (docs/abilities.md, section 4.4): ENTITY_SPAWN of kind 3 (reliable channel) to the
# shooter's owner and to whoever has them as relevant, at that moment. It records who received it to send them the removal.
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


# Removal of a projectile: ENTITY_DESPAWN (reason 4 impact or 5 expired) to those who received its spawn and are still
# in the world, even if they no longer have the shooter as relevant.
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


# Scoreboard and battle log: a death adds a death to the victim (if a player) and goes into the
# log; a KILL adds a kill to the killer and an assist to each assistant (if players). Respawning
# clears the GM command flag (gm_forced, docs/progression.md §6.2). Rewards (progression.md §6.2): an NPC's
# death pays its contributors and a player's KILL, the PvP merits.
func _track_battle(event: NetMessages.EntityEvent) -> void:
	match event.event:
		NetMessages.EntityEvent.Kind.RESPAWN:
			var respawned: NetEntity = _registry.get_entity(event.net_id)
			if respawned != null:
				respawned.gm_forced = false
		NetMessages.EntityEvent.Kind.DEATH:
			var victim: NetEntity = _registry.get_entity(event.net_id)
			if victim == null:
				return
			if victim.kind == NetProtocol.EntityKind.PLAYER:
				_scores.add_death(victim.net_id)
			elif victim.kind == NetProtocol.EntityKind.NPC:
				_reward_npc_death(victim, event.tick)
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
			_reward_kill(event)


# The PvP merits of a KILL (progression.md §6.2; the scoreboard's provisional ones until PRG-09): those of the kill
# to the killer and those of the assist to each assistant. ProgressService only pays them with a persistent victim of
# another realm.
func _reward_kill(event: NetMessages.EntityEvent) -> void:
	if _progress == null or not _is_player(event.net_id):
		return
	_progress.on_merits(event.killer, ScoreKeeper.MERITS_PER_KILL, EconomyReason.PVP_KILL, event.net_id, event.tick)
	for assistant: int in event.assistants:
		_progress.on_merits(assistant, ScoreKeeper.MERITS_PER_ASSIST, EconomyReason.PVP_ASSIST, event.net_id,
				event.tick)


# The reward of an NPC that dies at tick [param s] (progression.md §6.2) to those who did at least 10 % of the
# damage in the window. It is checked on its DEATH, which arrives here before FortressController: the defender is
# still registered and the forced-change flag is that of its death (fort_kill_captain sets it before killing). A
# defender of a fortress in a forced cycle pays nothing.
func _reward_npc_death(victim: NetEntity, s: int) -> void:
	if _progress == null:
		return
	var definition: NpcDefinition = _npc_definition_of(victim)
	if definition == null or (definition.xp_reward <= 0 and definition.gold_reward <= 0):
		return
	var fortress_id: StringName = _fortresses.fortress_of_defender(victim.net_id) if _fortresses != null else &""
	if not fortress_id.is_empty() and _fortresses.is_forced(fortress_id):
		return
	var combatant: Combatant = _combat.get_combatant(victim.net_id)
	if combatant != null:
		_progress.on_npc_killed(definition, combatant.ledger.contributors(s), s)


# The definition of NPC [param entity] (that of the spawner system, which may override the catalog's in tests), or
# null if it has none.
func _npc_definition_of(entity: NetEntity) -> NpcDefinition:
	var definition: NpcDefinition = NpcCatalog.get_by_number(entity.npc_def_id) if entity.npc_def_id > 0 else null
	if definition != null and _npc_system != null:
		definition = _npc_system.get_definition(definition.id)
	return definition


# ENTITY_EVENT LEVEL_UP of [param net_id], who goes up to [param level] at tick [param s] (progression.md §6.3): to the
# owner and to those of their realm who have them as relevant, for the effect; it does not reach the enemy.
func _announce_level_up(net_id: int, level: int, s: int) -> void:
	var entity: NetEntity = _registry.get_entity(net_id)
	if entity == null or _transport == null or _world_peers.is_empty():
		return
	var bytes: PackedByteArray = NetMessages.EntityEvent.level_up(net_id, s, level).encode()
	for peer: ServerPeer in _world_peers:
		if peer.entity == entity or (peer.entity.realm == entity.realm and peer.relevant.get(net_id, false)):
			_transport.send(peer.peer_id, NetProtocol.CH_RELIABLE, bytes)
			_events_sent += 1
			_event_bytes_sent += bytes.size()


func _is_player(net_id: int) -> bool:
	var entity: NetEntity = _registry.get_entity(net_id)
	return entity != null and entity.kind == NetProtocol.EntityKind.PLAYER


# A spawn point of the realm (to place whoever falls out of the world while dead).
func _pick_spawn_point(realm: int) -> Transform3D:
	return _spawn_picker.pick(realm)


# The nearest living (or knocked-down) enemy to [param position] for fake player [param net_id] (the combat brain
# of BotBrain): a BotTarget with its feet, its velocity and whether it is knocked down (what the kit uses for the
# bow's lead shot and for finishing off, H5), or null if there is none that can attack or be attacked: dummies,
# protected ones and those in their realm's safe zone do not count, and whoever is in their realm's safe zone (or
# is not standing) does not attack. Targets are gathered once per tick and per realm (with many bots, each one
# only traverses the candidates of the realms hostile to it). With [param npcs_only], only NPCs (the defender finder
# of the SIEGE brain, F6b). "Nearest" with height weighted (BotBrain.target_distance_squared, GUE-45): the one on
# its own level before the one on the walkway.
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


# The fakes' kit (H5): the combat state of fake player [param net_id] after the last tick (null if it is no longer
# there).
func _fake_combat_state(net_id: int) -> CombatState:
	var entity: NetEntity = _registry.get_entity(net_id)
	var character: PlayerCharacter = entity.get_character() if entity != null else null
	return character.combat if character != null else null


# The siege fakes' kit: the bow's line of fire (BotBrain.set_line_of_sight) in the server world.
func _bot_line_of_sight(from_feet: Vector3, to_feet: Vector3, left_shoulder: bool) -> bool:
	return BotBrain.bow_sight_clear(get_physics_space(), from_feet, to_feet, left_shoulder)


# The fakes' kit: the health fraction of fake player [param net_id] (0 knocked down or dead).
func _fake_health_fraction(net_id: int) -> float:
	var combatant: Combatant = _combat.get_combatant(net_id)
	if combatant == null or combatant.max_health <= 0:
		return 1.0
	return float(combatant.health) / float(combatant.max_health)


# The fakes' kit: the feet of the knocked-down ally (a player of their realm) nearest to [param position] for fake
# player [param net_id], or null. With nobody knocked down in the zone it traverses no one.
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


# The telegraphed strikes (TELEGRAPH) in progress that can damage fake player [param net_id] (the SIEGE brain, F6b):
# the heavy attacks of NPCs of a hostile realm from when they start until their active window ends, with the NPC's
# position and heading at this moment (it turns and advances a little while charging) and the reach of the hit. The
# list is gathered once per tick.
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


# How many living players of the realm of fake player [param net_id], not counting itself, are within [param radius]
# meters horizontally of [param center] (the SIEGE brain's ally counter for the rally, GUE-44). People and fakes
# count, not NPCs nor the bodies of those who left in combat. Positions are gathered once per tick, so everyone waiting
# on the same tick sees the same count and leaves at once.
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


# Gathers, per realm, the positions of living players (people and fakes) on this tick. A knocked-down one (H3c) is not
# alive: it does not count in the rally nor as one of their own fighting at the fort. The same as the client bots
# (BotAllySight for --bot, SwarmBot.is_standing_record for --bots), which see it through its drawn action, DOWNED: its
# published health is not 0 (Combatant.publish gives it as that of the knocked-down).
func _rebuild_ally_cache() -> void:
	_allies_tick = _tick
	_allies_by_realm.clear()
	_ally_ids_by_realm.clear()
	for other: Combatant in _combat.get_sorted():
		if not other.is_alive() or other.entity.kind != NetProtocol.EntityKind.PLAYER or _lingering.has(other.get_id()) \
				or other.is_gm_invisible():
			continue
		var realm: int = other.get_realm()
		if not _allies_by_realm.has(realm):
			_allies_by_realm[realm] = PackedVector3Array()
			_ally_ids_by_realm[realm] = PackedInt32Array()
		_allies_by_realm[realm].append(other.entity.get_position())
		_ally_ids_by_realm[realm].append(other.get_id())


# Gathers the telegraphed heavy attacks of NPCs that are still in progress after the last tick (those announced by
# _emit_npc_telegraphs).
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


# Gathers, per realm, the positions of whoever can be a combat bot's target on this tick.
func _rebuild_target_cache() -> void:
	_targets_tick = _tick
	_targets_by_realm.clear()
	_targets_ids_by_realm.clear()
	_targets_npc_by_realm.clear()
	_targets_velocity_by_realm.clear()
	_targets_downed_by_realm.clear()
	for other: Combatant in _combat.get_sorted():
		if other.is_dead() or other.immortal or other.is_protected(_tick) or other.is_gm_invisible():
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


# true if a bot of [param my_realm] can damage one of [param other_realm] in this zone.
func _is_hostile_realm(my_realm: int, other_realm: int) -> bool:
	var key: int = my_realm * 16 + other_realm
	if not _hostile_cache.has(key):
		_hostile_cache[key] = FactionRules.can_damage(my_realm, other_realm,
				StringName(_config.zone_id))
	return _hostile_cache[key]


# The ground under [param position]: the point where a ray from a few meters above touches the world, or
# [param position] if there is no ground below. The ray is slightly tilted: vertical ones can miss
# against HeightMapShape3D.
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


# --- Commands and console ----------------------------------------------------------------------

# Registers the administration commands: the six network ones (fixed NetProtocol ids) with their console
# version, and those that are console-only.
# Each command with its minimum role for /gm and, with the platform, for DEBUG_COMMAND (docs/platform.md §9.1): gm by
# default (the network ones: teleport, health, fort); kick, announce and shutdown, and their /gm names anuncio and apagar,
# admin (the kick from the zone by moderators is /gm expulsar, from ModerationService). Those that create or keep
# value of a persistent character or skip their equipment require admin (progression.md §10, P5d): 5 set_weapon and
# 13 cooldowns_off, also through /gm; 16 refill, through DEBUG_COMMAND (through /gm it is a GM operation like item_give, with
# gm). Those of §10 (40–43 and the console ones) are registered by ProgressService.setup.
func _register_commands() -> void:
	var admin: StringName = CommandRegistry.ROLE_ADMIN
	var gm: StringName = CommandRegistry.ROLE_GM
	_commands.register(&"teleport", "teleport <jugador> <x> <y> <z> | teleport <jugador> <otro jugador>",
			_console_teleport, _net_teleport)
	_commands.register(&"heal", "heal <jugador>", _console_heal, _net_heal)
	_commands.register(&"kill", "kill <jugador>", _console_kill, _net_kill)
	_commands.register(&"stamina_inf", "stamina_inf <jugador> [on|off]", _console_stamina_inf,
			_net_stamina_inf)
	_commands.register(&"set_weapon", "set_weapon <jugador> <arma>", _console_set_weapon,
			_net_set_weapon, admin)
	_commands.register(&"spawn_dummy", "spawn_dummy <x> <y> <z> [quieto|bloqueando|girando]",
			_console_spawn_dummy, _net_spawn_dummy)
	_commands.register(&"cooldowns_off", "cooldowns_off <jugador> [on|off]", _console_cooldowns_off,
			_net_cooldowns_off, admin)
	_commands.register(&"apply_status", "apply_status <jugador> <efecto> [ticks]", _console_apply_status,
			_net_apply_status)
	_commands.register(&"down", "down <jugador>", _console_down, _net_down)
	_commands.register(&"refill", "refill <jugador> [motivo… (con plataforma, obligatorio)]", _console_refill,
			_net_refill, gm, admin)
	_fortresses.register_commands(_commands, Callable(self, "_next_tick"))
	if _npc_system != null:
		_npc_system.register_commands(_commands)
	_commands.register(&"unstuck", "unstuck <jugador>", _console_unstuck, _net_unstuck)
	_commands.register(&"announce", "announce <texto>", _console_announce, Callable(), admin)
	_commands.register(&"anuncio", "anuncio <texto>", _console_announce, Callable(), admin)
	_commands.register(&"kick", "kick <jugador> [motivo]", _console_kick, Callable(), admin)
	_commands.register(&"shutdown", "shutdown <segundos> | shutdown cancel", _console_shutdown, Callable(), admin)
	_commands.register(&"apagar", "apagar <segundos> | apagar cancelar", _console_shutdown, Callable(), admin)
	_commands.register(&"players", "players", _console_players)


# Executes the lines someone has typed in the console since the previous tick.
func _run_console_lines() -> void:
	if _console == null:
		return
	for line: String in _console.take_lines():
		var response: String = _commands.execute_console(line)
		if not response.is_empty():
			_log(response)


# A player, fake player or NPC by net_id or by name (case-insensitive), or null.
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


# Position of a dummy from the spawn_dummy command: in front of the player, facing them.
func _dummy_spawn_for(entity: NetEntity) -> Transform3D:
	var yaw: float = entity.get_character().yaw
	var forward: Vector3 = Basis(Vector3.UP, yaw) * Vector3.FORWARD
	return Transform3D(Basis(Vector3.UP, yaw + PI),
			entity.get_position() + forward * DUMMY_SPAWN_DISTANCE)


func _combatant_of_peer(ctx: CommandRegistry.Context) -> Combatant:
	if ctx.peer == null or ctx.peer.entity == null:
		return null
	return _combat.get_combatant(ctx.peer.entity.net_id)


# With the platform, a GM command that moves, heals or shows a character flags it until it respawns
# (progression.md §6.2; docs/platform.md §9.1): it does not enter the capture list nor earn merits or NPC rewards.
func _mark_gm_forced(entity: NetEntity) -> void:
	if _platform != null and entity != null and entity.kind == NetProtocol.EntityKind.PLAYER:
		entity.gm_forced = true


# The player (or fake or NPC) that [param text] names for a command, recorded as its target in the audit.
func _command_target(ctx: CommandRegistry.Context, text: String) -> NetEntity:
	var entity: NetEntity = _find_entity(text)
	ctx.target = entity
	return entity


# -- Network commands (they act on whoever sends them) --

func _net_teleport(ctx: CommandRegistry.Context) -> int:
	if ctx.payload.size() != NetMessages.DebugCommand.TELEPORT_PAYLOAD_SIZE:
		return CommandRegistry.Result.BAD_ARGUMENTS
	var target := Vector3(ctx.payload.decode_float(0), ctx.payload.decode_float(4),
			ctx.payload.decode_float(8))
	if not _is_valid_teleport_target(target):
		ctx.note = "destino fuera de rango"
		return CommandRegistry.Result.BAD_ARGUMENTS
	teleport(ctx.peer.entity.net_id, target)
	_mark_gm_forced(ctx.peer.entity)
	ctx.note = str(target)
	ctx.audit_args = {"position": [target.x, target.y, target.z]}
	return CommandRegistry.Result.OK


func _net_heal(ctx: CommandRegistry.Context) -> int:
	var combatant: Combatant = _combatant_of_peer(ctx)
	if combatant == null or not combatant.is_alive():
		return CommandRegistry.Result.REFUSED
	_combat.heal(combatant)
	_mark_gm_forced(combatant.entity)
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
	_mark_gm_forced(combatant.entity)
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
	# 5 is set_loadout with the weapon in slot 1 (docs/abilities.md, section 3.5), with its LOADOUT.
	if not _combat.set_weapon(combatant, weapon_id, _tick + 1):
		return CommandRegistry.Result.REFUSED
	return CommandRegistry.Result.OK


# 13 cooldowns_off (docs/abilities.md, section 5.1): u8 0 or 1, bit 7 of combat_flags2.
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


# 14 apply_status: u8 status_id and u16 ticks (0 = those from the data). It is applied to whoever sends it, with no
# author, on the tick the server is about to simulate.
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


# 15 down (docs/abilities.md, section 4.5): knocks itself down with no author (on bleeding out, DEATH without KILL),
# on the tick the server is about to simulate. Rejected outside RvR zones, in one's own safe zone or when not alive.
func _net_down(ctx: CommandRegistry.Context) -> int:
	if not ctx.payload.is_empty():
		return CommandRegistry.Result.BAD_ARGUMENTS
	var combatant: Combatant = _combatant_of_peer(ctx)
	if combatant == null or not _combat.down(combatant, _tick + 1):
		return CommandRegistry.Result.REFUSED
	return CommandRegistry.Result.OK


# 16 refill: restores the charges of the consumables of its template (set_charges, with LOADOUT to the owner). With an
# inventory, without the platform, a forced CAMP_REFILL of its bag (progression.md §4.4); with the platform, a GM
# operation with a GM_GRANT for what is missing and the note "debug" (progression.md §4.4 and §10, P5d; requires admin).
func _net_refill(ctx: CommandRegistry.Context) -> int:
	if not ctx.payload.is_empty():
		return CommandRegistry.Result.BAD_ARGUMENTS
	var combatant: Combatant = _combatant_of_peer(ctx)
	if combatant == null:
		return CommandRegistry.Result.REFUSED
	if _progress.has_inventory(combatant.get_id()):
		if _platform != null:
			return _progress.gm_commands().net_refill(ctx)
		return CommandRegistry.Result.OK if _progress.force_refill(combatant.get_id(), _tick + 1) \
				else CommandRegistry.Result.REFUSED
	if not _combat.refill(combatant, _tick + 1):
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


# -- Console commands --

# Teleports the player right away to the nearest safe point of their realm (with no channeling or
# reuse cooldown: it is an administration tool).
func _console_unstuck(ctx: CommandRegistry.Context) -> String:
	if ctx.args.size() != 1:
		return "Uso: unstuck <jugador>"
	var entity: NetEntity = _command_target(ctx, ctx.args[0])
	if entity == null or entity.kind != NetProtocol.EntityKind.PLAYER:
		return "No hay ningún jugador «%s»" % ctx.args[0]
	_teleport_unstuck(entity, _tick + 1)
	_mark_gm_forced(entity)
	return "%s llevado al punto seguro más cercano de su reino" % entity.display_name


# teleport <player> <x> <y> <z>, or teleport <player> <other> (next to the other). With the platform it flags the one
# who moves (gm_forced, progression.md §6.2).
func _console_teleport(ctx: CommandRegistry.Context) -> String:
	var usage: String = "Uso: teleport <jugador> <x> <y> <z> | teleport <jugador> <otro jugador>"
	if ctx.args.size() != 4 and ctx.args.size() != 2:
		return usage
	var entity: NetEntity = _command_target(ctx, ctx.args[0])
	if entity == null or entity.get_character() == null:
		return "No hay ningún jugador «%s»" % ctx.args[0]
	var target: Vector3
	if ctx.args.size() == 2:
		var other: NetEntity = _find_entity(ctx.args[1])
		if other == null or other.get_character() == null or (other.gm_invisible and other != entity):
			return "No hay ningún jugador «%s»" % ctx.args[1]
		target = other.get_position()
	else:
		for i: int in range(1, 4):
			if not ctx.args[i].is_valid_float():
				return "Coordenada no válida: %s" % ctx.args[i]
		target = Vector3(ctx.args[1].to_float(), ctx.args[2].to_float(), ctx.args[3].to_float())
	if not _is_valid_teleport_target(target):
		return "Destino fuera de rango"
	teleport(entity.net_id, target)
	_mark_gm_forced(entity)
	ctx.audit_args = {"position": [target.x, target.y, target.z]}
	return "%s teletransportado a %s" % [entity.display_name, target]


func _console_heal(ctx: CommandRegistry.Context) -> String:
	if ctx.args.size() != 1:
		return "Uso: heal <jugador>"
	var combatant: Combatant = _combatant_by_name(ctx.args[0], ctx)
	if combatant == null:
		return "No hay ningún jugador «%s»" % ctx.args[0]
	if combatant.is_dead():
		return "%s está muerto" % combatant.entity.display_name
	if combatant.is_downed():
		return "%s está derribado" % combatant.entity.display_name
	_combat.heal(combatant)
	_mark_gm_forced(combatant.entity)
	return "%s curado" % combatant.entity.display_name


func _console_kill(ctx: CommandRegistry.Context) -> String:
	if ctx.args.size() != 1:
		return "Uso: kill <jugador>"
	var combatant: Combatant = _combatant_by_name(ctx.args[0], ctx)
	if combatant == null:
		return "No hay ningún jugador «%s»" % ctx.args[0]
	if combatant.is_dead() or combatant.immortal:
		return "%s no se puede matar" % combatant.entity.display_name
	_combat.kill(combatant, _tick + 1)
	return "%s muerto" % combatant.entity.display_name


func _console_stamina_inf(ctx: CommandRegistry.Context) -> String:
	if ctx.args.is_empty() or ctx.args.size() > 2:
		return "Uso: stamina_inf <jugador> [on|off]"
	var combatant: Combatant = _combatant_by_name(ctx.args[0], ctx)
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
	_mark_gm_forced(combatant.entity)
	return "Resistencia infinita %s para %s" % ["activada" if enabled else "desactivada",
			combatant.entity.display_name]


func _console_set_weapon(ctx: CommandRegistry.Context) -> String:
	if ctx.args.size() != 2:
		return "Uso: set_weapon <jugador> <arma>"
	var combatant: Combatant = _combatant_by_name(ctx.args[0], ctx)
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
	var combatant: Combatant = _combatant_by_name(ctx.args[0], ctx)
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
	var combatant: Combatant = _combatant_by_name(ctx.args[0], ctx)
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
	var combatant: Combatant = _combatant_by_name(ctx.args[0], ctx)
	if combatant == null:
		return "No hay ningún jugador «%s»" % ctx.args[0]
	if not _combat.down(combatant, _tick + 1):
		return "%s no puede quedar derribado aquí" % combatant.entity.display_name
	return "%s derribado" % combatant.entity.display_name


# refill <player>: without the platform, like 16; with it, for whoever has an inventory, the GM operation of 16 with the
# written reason (refill <player> <reason…>; progression.md P5d).
func _console_refill(ctx: CommandRegistry.Context) -> String:
	if ctx.args.is_empty() or (ctx.args.size() != 1 and _platform == null):
		return "Uso: refill <jugador>" + (" <motivo…>" if _platform != null else "")
	var combatant: Combatant = _combatant_by_name(ctx.args[0], ctx)
	if combatant == null:
		return "No hay ningún jugador «%s»" % ctx.args[0]
	if _progress.has_inventory(combatant.get_id()):
		if _platform != null:
			return _progress.gm_commands().console_refill(ctx, combatant.get_id())
		if not _progress.force_refill(combatant.get_id(), _tick + 1):
			return "%s no puede reponer ahora" % combatant.entity.display_name
		return "Pociones de %s repuestas" % combatant.entity.display_name
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
	var entity: NetEntity = _command_target(ctx, ctx.args[0])
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
	if ctx.args[0].to_lower() == "cancel" or ctx.args[0].to_lower() == "cancelar":
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


# The combat of whoever [param text] names; with [param ctx], it becomes the command's target in the audit.
func _combatant_by_name(text: String, ctx: CommandRegistry.Context = null) -> Combatant:
	var entity: NetEntity = _command_target(ctx, text) if ctx != null else _find_entity(text)
	return _combat.get_combatant(entity.net_id) if entity != null else null


# Informational NOTICE to all players in the world. Returns how many receive it.
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


# Countdown of a shutdown requested through the console: warnings at the indicated seconds and, on reaching 0,
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


# The maintenance brought by the heartbeat (docs/platform.md §6 and §12): {at_unix, message} or null (none, or
# cancelled). A new at_unix restarts the warnings.
func _set_maintenance(value: Variant) -> void:
	var maintenance: Dictionary = value if value is Dictionary else {}
	if maintenance.is_empty() or not PlatformJson.is_int(maintenance.get("at_unix"), 1, PlatformJson.MAX_SAFE_INT):
		if _maintenance_at_unix > 0:
			_log("La plataforma ya no anuncia el mantenimiento")
			if not _maintenance_announced.is_empty():
				_broadcast_notice("Mantenimiento cancelado: el servidor sigue abierto")
		_maintenance_at_unix = 0
		_maintenance_message = ""
		_maintenance_announced.clear()
		return
	var at_unix: int = int(maintenance["at_unix"])
	if at_unix == _maintenance_fired_at_unix:
		return
	_maintenance_message = PlatformJson.text_in(maintenance, "message").left(200)
	if at_unix == _maintenance_at_unix:
		return
	_maintenance_at_unix = at_unix
	_maintenance_announced.clear()
	_log("La plataforma anuncia mantenimiento a las %s UTC (dentro de %d s)" % [
			Time.get_datetime_string_from_unix_time(at_unix, true), at_unix - _platform.now_unix()])


# Maintenance warnings at 10, 5 and 1 min, at 30 s and at 10 s (those already past when announced are
# merged into one warning with what remains) and, at its time, the orderly shutdown (shutdown_requested), like the rest
# of the triggers. The time is the platform's (ZonePlatform.now_unix).
func _check_maintenance() -> void:
	if _maintenance_at_unix <= 0 or _platform == null:
		return
	var remaining: int = _maintenance_at_unix - _platform.now_unix()
	if remaining <= 0:
		_maintenance_fired_at_unix = _maintenance_at_unix
		_maintenance_at_unix = 0
		_maintenance_announced.clear()
		_log("Hora del mantenimiento de la plataforma: cierre ordenado")
		shutdown_requested.emit("mantenimiento de la plataforma")
		return
	var due: bool = false
	for seconds: int in MAINTENANCE_NOTICE_SECONDS:
		if remaining <= seconds and not _maintenance_announced.has(seconds):
			_maintenance_announced.append(seconds)
			due = true
	if due:
		_broadcast_notice(maintenance_notice_text(remaining, _maintenance_message))


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
	_fortresses.captain_killer = Callable(self, "_kill_captain_npc")
	_fortresses.setup(world, _registry, _tick)
	_fortresses.war_event_emitted.connect(_on_war_event)
	_fortresses.object_state_emitted.connect(_on_object_state)
	_fortresses.gate_damage_started.connect(_on_gate_damage_started)
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


# Kills the registered captain NPC (for fort_kill_captain). Returns false if it cannot.
func _kill_captain_npc(net_id: int) -> bool:
	var combatant: Combatant = _combat.get_combatant(net_id)
	if combatant == null or combatant.is_dead() or combatant.immortal:
		return false
	_combat.kill(combatant, _tick + 1)
	return true


# A war notice to the whole zone (ENTITY_EVENT WAR) and to the battle log.
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


# The OBJECT_STATE of a fortress to the whole zone (reliable channel).
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


# The zone scoreboard to all players (pages of at most 66 rows).
func _send_scoreboard() -> void:
	if _transport == null or _world_peers.is_empty():
		return
	var ids: Array[int] = []
	for entity: NetEntity in _registry.get_sorted():
		# An invisible GM does not appear on the scoreboard (docs/platform.md §9.1).
		if entity.kind == NetProtocol.EntityKind.PLAYER and not entity.gm_invisible:
			ids.append(entity.net_id)
	var rows: Array[NetMessages.ScoreRow] = _scores.build_rows(ids)
	for page: NetMessages.Scoreboard in NetMessages.Scoreboard.split(rows):
		var bytes: PackedByteArray = page.encode()
		for peer: ServerPeer in _world_peers:
			_transport.send(peer.peer_id, NetProtocol.CH_RELIABLE, bytes)
	_scoreboards_sent += 1


# -- Exit and disconnect in combat (GUE-41) --

# true if whoever leaves has dealt or received damage less than 10 s ago and is still alive: their body stays.
func _should_linger(entity: NetEntity, s: int) -> bool:
	if entity.kind != NetProtocol.EntityKind.PLAYER or _run_state != _RunState.RUNNING:
		return false
	var combatant: Combatant = _combat.get_combatant(entity.net_id)
	return combatant != null and combatant.is_alive() and combatant.is_in_combat(s)


# The body stays LINGER_TICKS ticks in the world with neutral inputs (still, no buttons), attackable, not
# counting in the circle and with its name reserved. It stops belonging to any peer.
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
	_unstuck.cancel(unstuck_key_of(entity))
	_lingering[net_id] = s + linger_ticks
	_lingering_total += 1


# Removes the bodies whose deadline has expired or that have been killed (their death was already credited like any
# other).
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
			# Now its final save goes out (docs/platform.md §7.2: "when the body leaves").
			_remove_player(entity, s, NetProtocol.DespawnReason.DISCONNECTED, true,
					_lingering_save_reasons.get(net_id, CharacterSaver.Reason.LOGOUT))


# -- /atascado (MUN-41) --

# UNSTUCK_REQUEST or command 7: starts the channeling if applicable and tells the player how it went.
func _request_unstuck(peer: ServerPeer) -> int:
	var entity: NetEntity = peer.entity
	var combatant: Combatant = _combat.get_combatant(entity.net_id) if entity != null else null
	if combatant == null:
		return UnstuckTracker.RequestResult.DEAD
	var s: int = _tick + 1
	var key: String = unstuck_key_of(entity)
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


# Advances the /atascado channelings: combat or death interrupts them and at the end the player is teleported.
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
			# With the platform, the reuse cooldown is saved as the unstuck timer (progression.md §8).
			_progress.set_timer(entity.net_id, ProgressService.TIMER_UNSTUCK, _unstuck.get_ready_at(key), s)
			if peer != null:
				_send_notice(peer, "/atascado: ya estás en un punto seguro de tu reino")


# Teleports [param entity] to the nearest valid respawn point of its realm (or, if there is none,
# to a spawn point) and records the use (zone, origin and destination position) to fix the map.
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


# The respawn point that is valid for the realm of [param entity] nearest to it.
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


# A client has connected and starts authenticating: its HELLO is awaited.
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
	# Whoever was kicked recently does not get back in within an RTT with warnings at 0 and full buckets: their IP
	# receives a REJECT right on connecting (TOO_MANY_CONNECTIONS is reused so as not to bump PROTOCOL_VERSION).
	if _is_cooling_down(_cooldown_key_for_address(peer.remote_address)):
		_reject(peer, NetProtocol.Result.TOO_MANY_CONNECTIONS)
		return
	# The per-IP cap is applied already on connect, not only when the HELLO arrives: an IP that opens connections
	# without sending anything would take up all the ENet slots and legitimate clients would be left without a
	# response. Those that exceed the cap receive a REJECT and are cut.
	if _connections_from(peer) >= _config.max_connections_per_ip \
			and not ServerAuth.is_loopback(peer.remote_address):
		_reject(peer, NetProtocol.Result.TOO_MANY_CONNECTIONS)


# HELLO: it is validated and answered with WELCOME (and complete_auth) or REJECT (and orderly disconnect). With a ticket,
# the peer stays in VERIFYING until the platform answers the claim (_apply_auth_outcome).
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


# WELCOME and complete_auth: the peer moves to LOADING with [param realm] and [param display_name] (those of the HELLO
# without the platform; those of the claim with it).
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


# --- Platform (docs/platform.md §5.2 and §14.3) ------------------------------------------------

# "poll" step with the platform: the events, by kind and in arrival order (instance_closed last), the finals of the
# AuthProvider and the expired VERIFYING peers. While shutting down (STOPPING) only the responses to saves and claims
# count (those that arrive late are released): the heartbeat no longer kicks or warns.
func _poll_platform() -> void:
	var running: bool = _run_state == _RunState.RUNNING
	if _platform != null:
		var closed_code: String = ""
		for event: PlatformEvent in _platform.take_events():
			match event.kind:
				PlatformEvent.KIND_CLAIM:
					if _auth_provider != null:
						_auth_provider.on_platform_event(event)
				PlatformEvent.KIND_SAVE:
					if _saver != null:
						_saver.on_platform_event(event)
				PlatformEvent.KIND_HEARTBEAT:
					if running:
						_on_heartbeat_event(event)
				PlatformEvent.KIND_INSTANCE_CLOSED:
					closed_code = event.error_code
				PlatformEvent.KIND_ID_BLOCK, PlatformEvent.KIND_PROGRESS_OP, PlatformEvent.KIND_PROGRESS_LEDGER:
					if _progress != null:
						_progress.on_platform_event(event)
				PlatformEvent.KIND_FORTRESS:
					if _fortress_persistence != null:
						_fortress_persistence.on_platform_event(event)
				PlatformEvent.KIND_IGNORE, PlatformEvent.KIND_REPORT, PlatformEvent.KIND_SANCTION:
					if running:
						_moderation.on_platform_event(event)
		if not closed_code.is_empty():
			_log("La plataforma ha cerrado esta instancia (%s)" % closed_code)
			if running:
				instance_closed.emit(closed_code)
	if _auth_provider != null:
		for outcome: AuthOutcome in _auth_provider.take_completed():
			_apply_auth_outcome(outcome)
	if running:
		_check_verify_timeouts()


# The outcome of a claim (table of §5.2). With OK, in order: (1) the zone admits the character's realm
# (REALM); (2) there is room (FULL); (3) ProgressService.prepare (progression.md §9.1: if the record cannot be read,
# UNAVAILABLE with "No se ha podido cargar el personaje" (the character could not be loaded) and an alert); (4) WELCOME
# with the realm and the character name. If any fails, REJECT and the lease is released.
func _apply_auth_outcome(outcome: AuthOutcome) -> void:
	var peer: ServerPeer = _peers.get(outcome.peer_id)
	if peer == null or peer.state != ServerPeer.State.VERIFYING:
		# It left on the same tick: the provider was no longer waiting for it, but just in case nothing is left hanging.
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
		# It already counts in _occupied_seats (VERIFYING): capacity is checked without it, as in ServerAuth.
		var others: int = _occupied_seats() - 1
		if others - _filler_seats() >= _config.max_players \
				or not _make_room_for(peer, claimed.realm, claimed.display_name, others):
			rejection = NetProtocol.Result.FULL
	if rejection != NetProtocol.Result.OK:
		_platform.release(claimed.character_id, claimed.lease_id)
		_reject(peer, rejection)
		return
	if not _progress.prepare(peer.peer_id, claimed):
		_log("Alerta: no se ha podido cargar el personaje %d (peer %d): se rechaza y se libera"
				% [claimed.character_id, peer.peer_id])
		_platform.release(claimed.character_id, claimed.lease_id)
		_reject(peer, NetProtocol.Result.UNAVAILABLE, ProgressService.PREPARE_FAILED_TEXT)
		return
	peer.claimed = claimed
	_welcome(peer, claimed.realm, claimed.display_name)
	if peer.state == ServerPeer.State.LOADING:
		_log("%s (personaje %d, cuenta %d, %s) entra con billete (peer %d)" % [claimed.display_name,
				claimed.character_id, claimed.account_id, claimed.role, peer.peer_id])


# Peers in VERIFYING for more than verify_timeout_ms (real time, since connecting): REJECT
# UNAVAILABLE. If the claim arrives later, the provider releases it.
func _check_verify_timeouts() -> void:
	var now: int = Time.get_ticks_msec()
	for peer: ServerPeer in _peers.values():
		if peer.state == ServerPeer.State.VERIFYING and now - peer.connected_at_msec >= verify_timeout_ms:
			_log("Conexión de %s (peer %d): %s" % [peer.remote_address, peer.peer_id, VERIFY_TIMEOUT_REASON])
			_reject(peer, NetProtocol.Result.UNAVAILABLE)


# Heartbeat response: the revoked ones (§6) and maintenance (§12). Each revoked carries the lease_id; one that does not
# match the character's current lease in this zone kicks nobody. lease_lost is the removal without saving
# (without releasing: the lease is no longer the zone's); the others kick with the platform's text and a final save
# when the body leaves (in LOADING, release without saving). Mutes go to moderation (§9.5).
func _on_heartbeat_event(event: PlatformEvent) -> void:
	if not event.is_success():
		return
	_set_maintenance(event.body_dict().get("maintenance"))
	_moderation.on_heartbeat(event)
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
	var lease_lost: bool = reason == CharacterSaver.LEASE_LOST
	for peer: ServerPeer in _peers.values():
		if peer.claimed == null or peer.claimed.character_id != character_id \
				or peer.claimed.lease_id != lease_id:
			continue
		if peer.state != ServerPeer.State.LOADING and peer.state != ServerPeer.State.IN_WORLD:
			continue
		_log("La plataforma revoca a %s (personaje %d): %s" % [peer.display_name, character_id, reason])
		if lease_lost:
			# The removal without saving (§7.2): the lease is no longer this zone's, so it is neither released nor
			# saved, and the body leaves immediately (no in-combat exit).
			if peer.entity != null and _saver != null:
				_saver.drop(peer.entity.net_id, CharacterSaver.LEASE_LOST)
			peer.claimed = null
			peer.drop_body_at_once = true
		_kick(peer, reason, false, text if not text.is_empty() else "Tu sesión ha terminado: vuelve a entrar")
		return
	# A body that remains after an in-combat exit: with lease_lost it leaves now, without saving or release. With the
	# other reasons its owner already left: the final save goes out when it is withdrawn.
	if lease_lost and _saver != null:
		var net_id: int = _saver.net_id_of(character_id, lease_id)
		if net_id > 0 and _lingering.has(net_id):
			_log("La plataforma revoca el cuerpo que queda del personaje %d: lease_lost" % character_id)
			_saver.drop(net_id, CharacterSaver.LEASE_LOST)
			_lingering[net_id] = 0


# A save definitively rejected before its final (CharacterSaver.save_rejected, docs/platform.md
# §7.2 and §7.3): the removal without saving. (1) drop, which releases except with lease_lost; (2) NOTICE and kick with
# the body removed immediately, no in-combat exit (the one that remained after an in-combat exit is withdrawn now); (3)
# ScoreKeeper.forget and ProgressService.on_departure, on the body's removal, whose finish no longer does anything.
func _on_save_rejected(net_id: int, character_id: int, code: String) -> void:
	if _saver != null:
		_saver.drop(net_id, code)
	var text: String = LEASE_LOST_TEXT if code == CharacterSaver.LEASE_LOST else SAVE_REJECTED_TEXT
	var entity: NetEntity = _registry.get_entity(net_id)
	if entity == null:
		return
	if _lingering.has(net_id):
		_log("Se retira ya el cuerpo del personaje %d: su guardado se ha rechazado (%s)" % [character_id, code])
		_lingering[net_id] = 0
		return
	var peer: ServerPeer = _peers.get(entity.owner_peer)
	if peer == null or peer.entity != entity:
		return
	peer.drop_body_at_once = true
	if _transport != null:
		_kick(peer, "guardado rechazado (%s)" % code, false, text)
	else:
		_mark_leaving(peer)


# A peer that leaves VERIFYING or LOADING without reaching the world (§5.2): in VERIFYING the wait for its
# claim is cancelled; in LOADING its lease is released without saving and its prepared progress is discarded
# (ProgressService.cancel_prepared, progression.md §9.1 step 3).
func _leave_auth_states(peer: ServerPeer) -> void:
	match peer.state:
		ServerPeer.State.VERIFYING:
			if _auth_provider != null:
				_auth_provider.cancel(peer.peer_id)
		ServerPeer.State.LOADING:
			if _progress != null:
				_progress.cancel_prepared(peer.peer_id)
			if peer.claimed != null and _platform != null:
				_platform.release(peer.claimed.character_id, peer.claimed.lease_id)
				peer.claimed = null


# Authentication completed on both sides: it is now possible to send to this peer.
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


# The transport has discarded [param count] packets from this peer for not being part of the protocol (SYS that is not
# authentication before the HELLO; afterwards, anything that is not an application packet): a real client never
# sends them. Each adds a warning; at 50 it is kicked. With more than 50 at once there is no need to count them all.
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
	# Per-peer limiters: what exceeds them is discarded and adds a warning.
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
		NetProtocol.MSG_INVENTORY_REQUEST, NetProtocol.MSG_INVENTORY_SYNC_REQUEST:
			# The inventory (progression.md §4.2 and §4.6): RATE on arrival and the ProgressService.apply_pending queue.
			_progress.handle_packet(peer, bytes)
		_:
			# Chat and parties (0x40 to 0x4F) are handled by the social service.
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
	# The client's interpolation delay does not exceed 12 ticks (× 8): more is a fake client.
	peer.interp_delay_q = mini(batch.interp_delay_q, NetProtocol.MAX_INTERP_DELAY_Q)
	if batch.interp_delay_q > NetProtocol.MAX_INTERP_DELAY_Q:
		_add_strike(peer, "retardo de interpolación fuera de rango")
	# The ack cannot go ahead of the server nor go backward; with it the RTT is measured in ticks.
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
	# Lower bound of the RTT: ENet's, which the client does not control (used by the rewind as a minimum).
	if _transport != null:
		peer.rtt_floor_ticks = floori(_transport.get_rtt_ms(peer.peer_id)
				* float(Engine.physics_ticks_per_second) / 1000.0)
	for i: int in batch.inputs.size():
		peer.input_queue.push(batch.inputs[i], batch.view_offsets_q[i], _tick + 1)


# Bound on the RTT in ticks that a client can declare with its acks. The ack is decided by the client: one
# that delayed its acks would pass for someone with lag and obtain the maximum phase 3 rewind.
# The bound comes from sources it does not control: ENet's RTT, the delay added by the server's own
# network simulator and a margin. (The client's --net-sim does not count: in production it would be
# faking lag; to test with lag, the server's is used.)
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
	# With the platform, in addition to --debug-commands, the command's minimum role (docs/platform.md §9.1) with that of the
	# claim; without it, a warning and nothing is executed.
	var role: StringName = &""
	if _platform != null:
		role = peer.claimed.role if peer.claimed != null else CommandRegistry.ROLE_PLAYER
	var result: int = _commands.execute_network(peer, command.command, command.payload, role)
	match result:
		CommandRegistry.Result.FORBIDDEN:
			_add_strike(peer, "comando de depuración sin permiso (%d)" % command.command)
		CommandRegistry.Result.UNKNOWN:
			# A fixed protocol id whose handler does not exist on this server (that of a command that has been
			# removed, or that of npc_debug with --no-npcs) is accepted without doing anything: it is not a faulty client.
			if not NetProtocol.DEBUG_COMMAND_IDS.values().has(command.command):
				_add_strike(peer, "comando de depuración desconocido (%d)" % command.command)
		CommandRegistry.Result.BAD_ARGUMENTS:
			_add_strike(peer, "comando de depuración con argumentos no válidos (%d)"
					% command.command)


# RESPAWN_REQUEST: a dead player asks to respawn at point point_index of the zone's static list
# (NetZones.get_all_respawn_points). Out of the window (alive, or long before being able to) is a warning; an index that
# is no longer valid (an enemy camp, a fort that has changed hands or is under attack) is not: the client's state is
# stale and the first valid camp of its realm is used.
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


# UNSTUCK_REQUEST (/atascado, docs/fortress.md section 5): no need for --debug-commands. A 10 s channeling
# out of combat, interrupted by combat, with a 5 min reuse cooldown; see _request_unstuck.
func _handle_unstuck_request(peer: ServerPeer, bytes: PackedByteArray) -> void:
	if peer.state != ServerPeer.State.IN_WORLD:
		_add_strike(peer, "petición de /atascado antes de entrar en el mundo")
		return
	if NetMessages.UnstuckRequest.decode(bytes) == null:
		_add_strike(peer, "petición de /atascado mal formada")
		return
	_request_unstuck(peer)


# LOADOUT_SELECT (docs/abilities.md, sections 4.6 and 5.1): the template for the next spawn. Valid in
# LOADING (from the WELCOME, before CLIENT_READY) and IN_WORLD; it has already gone through the reliable limiter. 0 = the
# default one, with no warning; an id that does not exist or cannot be chosen counts a warning and changes nothing.
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
	# Whoever has an inventory already has their equipment: after the spawn nothing changes (progression.md §2.5).
	if peer.entity != null and _progress.has_inventory(peer.entity.net_id):
		return
	peer.pending_template_id = select.template_id


# Adds a warning and kicks the peer if it reaches the limit (50 in 600 ticks).
func _add_strike(peer: ServerPeer, reason: String) -> void:
	_strikes_total += 1
	_strike_reasons[reason] = _strike_reasons.get(reason, 0) + 1
	if peer.add_strike(_tick, reason):
		_kick(peer, reason)


# Kick NOTICE and orderly disconnect. The reason stays in the report. With [param cooldown], their IP (or,
# from loopback, their name or their character) cannot rejoin for kick_cooldown_ticks. With
# [param notice_text] the NOTICE carries that text as is (that of a platform revoked).
func _kick(peer: ServerPeer, reason: String, cooldown: bool = true, notice_text: String = "") -> void:
	if peer.state == ServerPeer.State.LEAVING:
		return
	if cooldown:
		_start_cooldown(peer)
	peer.kicked = true
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


# Records the cooldown of a kicked peer and purges the expired ones. By IP (IPv6, by /64) except
# from loopback, where there is no per-IP cap and the normalized name is used, if it had already been given (with a ticket, the
# character: character:<id>, docs/platform.md §5.4).
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


# Cooldown key by address, or empty if it is loopback or unknown.
func _cooldown_key_for_address(address: String) -> String:
	if address.is_empty() or ServerAuth.is_loopback(address):
		return ""
	return "ip:" + ServerAuth.address_group(address)


# Cooldown key by identity: only from loopback, which has no per-IP cap. With a ticket, the character
# ([param character_id] > 0); without it, the HELLO name.
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


# REJECT and orderly disconnect: what is queued goes out before cutting. [param text] empty = that of
# NetProtocol.result_text (the report always counts by that, not by the custom text).
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


# Living filler fakes, without those with a requested removal (those no longer count in get_player_count).
func _live_fillers() -> int:
	if _filler_keeper == null:
		return 0
	var count: int = 0
	for net_id: int in _fakes:
		if _filler_keeper.is_filler(net_id) and not _fake_leaving.has(net_id):
			count += 1
	return count


# Slots the filler has set aside for people still loading the zone (GUE-43): at most one per living filler
# fake. Each one is one player too many until that person enters the world and their fake leaves.
func _reserved_seats() -> int:
	if _filler_keeper == null:
		return 0
	return mini(_filler_keeper.reserved_count(), _live_fillers())


# Slots occupied for capacity: the players of get_player_count() minus the filler fakes that have already set aside
# their slot for someone (they leave when that person enters).
func _occupied_seats() -> int:
	return get_player_count() - _reserved_seats()


# Filler fakes that can still yield their slot to a person (GUE-43): the living ones that have not already set it aside.
func _filler_seats() -> int:
	return maxi(_live_fillers() - _reserved_seats(), 0)


# An accepted HELLO with the server full only because of filler fakes: the keeper sets aside the slot of one, which
# leaves when the person enters the world (FillerKeeper.on_person_joined). false if there is no room (it should not
# happen: ServerAuth has already checked that the filler suffices). [param occupied] is the occupied slots not counting them.
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


# Open connections from the same IP as [param peer], not counting it (IPv6 ones are counted by
# /64 prefix, see ServerAuth.address_group).
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


# What stop() and close_instance() have in common: closes the report records, sends the final save of each body with a
# lease (with the SHUTDOWN reason) before emptying the world, closes the logs and asks the platform to
# push out whatever is pending (begin_flush).
func _wind_down() -> void:
	for record: _PlayerRecord in _player_by_net.values():
		record.close(_tick)
	_war_fortresses_at_stop = _fortress_entries()
	if _saver != null:
		for net_id: int in _saver.tracked_net_ids():
			_saver.finish(net_id, CharacterSaver.Reason.SHUTDOWN)
	_clear_players()
	_pending_ready.clear()
	_leaving.clear()
	_fake_leaving.clear()
	_fake_leaving_quietly.clear()
	_maintenance_at_unix = 0
	_maintenance_announced.clear()
	_shutdown_tick = -1
	_sync_byte_counters()
	_close_state_log()
	_close_combat_log()
	_close_battle_log()
	if _console != null:
		_console.stop()
	_metrics.unregister_monitors()
	if _platform != null:
		_platform.begin_flush()


# Moves to STOPPING, or finishes right away if there are no peers and nothing pending on the platform. With [param kick_after_saves]
# (the §6.1 shutdown) the peers receive their kick NOTICE when the saves already have an answer.
func _begin_drain(kick_after_saves: bool) -> void:
	_drain_ticks = 0
	_peer_drain_ticks = 0
	_kick_after_saves = kick_after_saves
	if (_transport == null or _peers.is_empty()) and _saves_settled():
		_kick_after_saves = false
		_finish_stop()
	else:
		_run_state = _RunState.STOPPING


# true if the saves all have their definitive answer and the platform has nothing queued or in flight.
func _saves_settled() -> bool:
	return (_saver == null or _saver.pending_count() == 0) and (_platform == null or _platform.is_flushed())


# After stop() or close_instance(): keeps polling the network and the platform (the answers to the final saves and
# the claims that arrive late) until the saves are answered (or save_drain_ticks pass) and the
# peers have left (or STOP_DRAIN_TICKS pass since their NOTICE).
func _drain_stop() -> void:
	_drain_ticks += 1
	if _transport != null:
		_transport.poll(_tick + _drain_ticks)
	_poll_platform()
	var saves_done: bool = _saves_settled() or _drain_ticks >= save_drain_ticks
	if _kick_after_saves:
		if not saves_done:
			return
		_kick_after_saves = false
		_kick_everyone(INSTANCE_CLOSED_TEXT)
	else:
		_peer_drain_ticks += 1
	if _transport != null:
		_transport.flush()
	if saves_done and (_peers.is_empty() or _peer_drain_ticks >= STOP_DRAIN_TICKS):
		if not _saves_settled():
			push_warning("[Eldmark] Cierre de la zona: la plataforma no ha contestado a tiempo (%d guardados sin respuesta)"
					% (_saver.pending_count() if _saver != null else 0))
		_finish_stop()


# Kick NOTICE with [param text] and orderly disconnect of all remaining peers (the §6.1 shutdown).
func _kick_everyone(text: String) -> void:
	if _transport == null:
		return
	for peer_id: int in get_peer_ids():
		var peer: ServerPeer = _peers[peer_id]
		if peer.state != ServerPeer.State.LEAVING:
			_kick(peer, "la plataforma ha cerrado la instancia", false, text)
	_transport.flush()


func _finish_stop() -> void:
	_peers.clear()
	_disconnect_transport()
	if _transport != null and is_instance_valid(_transport):
		_sync_byte_counters()
		_transport.close()
	_run_state = _RunState.STOPPED
	set_physics_process(false)


# --- Helpers ----------------------------------------------------------------------------------

# Server character: an instance of player_character.tscn without its Visual node (meshes), without its own
# process. Only ZoneServer simulates it.
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


# Simulation fingerprint, computed over an instance inside the tree after _ready().
func _compute_sim_hash() -> int:
	var character: PlayerCharacter = _instantiate_character()
	_players_root.add_child(character)
	var hash_value: int = NetProtocol.compute_sim_hash(character)
	_players_root.remove_child(character)
	character.free()
	return hash_value


# true if there is ground right under [param position] (within what the character's ground snap
# reaches): the spawn state is then born with grounded = true. The ray is slightly tilted
# because vertical ones can miss against HeightMapShape3D.
func _probe_grounded(position: Vector3) -> bool:
	var space: PhysicsDirectSpaceState3D = _players_root.get_world_3d().direct_space_state
	var from: Vector3 = position + Vector3(0.0, _PROBE_UP, 0.0)
	var query := PhysicsRayQueryParameters3D.create(from,
			from + Vector3(0.001, -(_PROBE_UP + _PROBE_DOWN), 0.0),
			PlayerCharacter.WORLD_COLLISION_LAYER)
	return not space.intersect_ray(query).is_empty()


# Yaw (same convention as Node3D.rotation.y) that a basis faces.
static func _yaw_of(transform: Transform3D) -> float:
	var forward: Vector3 = -transform.basis.z
	return atan2(-forward.x, -forward.z)


# Accumulates the transport's ENet bytes into the metrics.
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


# Metrics line every 10 s: tick duration, players, substituted inputs, bandwidth and, at the end, the NPCs
# simulated at that moment (the war ones and the dummies; GUE-16: the load with NPCs follows them throughout the
# battle).
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
		# Whether the port was opened over DTLS (docs/platform.md §10.2; the transport is already closed in the final report).
		"dtls": _config != null and _config.dtls != null and _transport != null,
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
		"moderation": _moderation.get_stats() if _moderation != null else {},
		"saves": _saver.get_stats() if _saver != null else {},
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


# Combat summary for the report: the director's counters, the events sent and the
# suspicion score per peer (only the suspicious ones).
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
		# Status effects (docs/abilities.md, 4.3): applied, removed, pulses and health healed.
		for stat: StringName in _combat.status.stats:
			report[String(stat)] = _combat.status.stats[stat]
		# Projectiles (docs/abilities.md, 4.4): shots, impacts, kills, culling and peak of living ones.
		for stat: StringName in _combat.projectiles.stats:
			report[String(stat)] = _combat.projectiles.stats[stat]
		report["projectiles_live"] = _combat.projectiles.live_count()
		# The knocked-down state (docs/abilities.md, 4.5): knockdowns, revives, finishers, bleed-outs and interactions.
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


# NPC summary for the report: what the spawner system has and the heavy attack notices.
func _npc_report() -> Dictionary:
	var report: Dictionary = _npc_system.get_report() if _npc_system != null else {}
	report["npcs_now"] = _npcs.size()
	report["telegraphs"] = _telegraphs_sent
	return report


# War summary for the report: the state of each fortress, the scoreboard, the in-combat exits and the
# uses of /atascado (unstuck).
func _war_report() -> Dictionary:
	# After stop() the controller no longer has fortresses (they are freed with the players): the final report
	# carries their state at the moment of shutdown.
	var fortresses: Array[Dictionary] = _fortress_entries()
	if fortresses.is_empty():
		fortresses = _war_fortresses_at_stop
	return {
		"fortresses": fortresses,
		"persistence": _fortress_persistence.get_stats() if _fortress_persistence != null else {},
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


# The state of each live fortress for the report.
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
