class_name ProgressService
extends RefCounted
## Character progress in the zone (docs/progresion.md §4, §8 and §9): loading before the WELCOME
## ([method prepare]), registration ([method on_arrival] and [method after_spawn]), the inventory over the network
## ([method handle_packet] and [method apply_pending]), what the server changes on its own (CONSUME in
## [method after_simulate], CAMP_REFILL in [method camp_step]), the [code]progress[/code] section of
## [CharacterSaver] ([method setup] registers it first) and departure ([method on_departure]). Each character with a
## peer has a [PlayerProgress] tied to its [code]net_id[/code] from registration to departure; fake players have none,
## and every hook by [code]net_id[/code] on one without a [PlayerProgress] does nothing (§9.2).
## [br][br]
## [b]With a platform[/b] every player with a peer is persistent: its record arrives in the claim ([method
## prepare]) and is saved. [b]Without one[/b] (§9.4) it is ephemeral: registration creates a new character of its realm
## with the kit of the LOADOUT_SELECT template (or the default one), local ids and nothing to save.
## [br][br]
## [b]Registration[/b] (§8 and §9.1): the rule for returning to the world (in RvR zones, the realm's camp, where the
## zone already puts it; in SAFE ones, the saved spot if valid), the saved health with regeneration for the offline
## time, the /atascado (/stuck) timer, the first-entry kit (critical), the level and appearance on the entity, and the
## [ProgressService.Loadout] with which the zone equips it instead of the template. After its own SPAWN,
## [method after_spawn] sends INVENTORY_FULL, one WALLET_UPDATE per currency and one PROGRESS_UPDATE.
## [br][br]
## [b]Requests[/b] (§4.2): RATE on arrival (8 per second with a burst of 16, and 2 SPLIT or DESTROY per second with a
## burst of 10; after the first ten, discards in each 10 s each add a strike), queued and applied at the end of the
## tick after registrations, in arrival order. Each one receives its INVENTORY_DELTA; a change of the weapon slots
## imposes the weapons ([method ActionMachine.set_weapons], without restarting cooldowns) with its LOADOUT, and one of
## a consumable's quantity, the charges ([code]min(15, bag)[/code], §4.4).
## [br][br]
## [b]Ids[/b] ([IdAllocator], §4.5): without a platform, [method IdAllocator.local]; with one, the blocks that arrive
## as [code]id_block[/code] events (the first, from the platform startup, in the first "poll") and a new one each time
## few remain ([signal IdAllocator.running_low]), with at most one in flight.
## [br][br]
## [b]Rewards[/b] (§6.2, P5c): PvP merits ([method on_merits]: only with a persistent victim of another realm) and
## objective merits ([method on_objective_ticks]: one merit per second in the active circle of a real cycle), with
## [code]merits × 10[/code] of XP; XP and gold from NPCs to each contributor ([method on_npc_killed]); and the capture
## reward ([method on_capture]: 300 XP and 20 gold, once per character and fortress every 30 min, with the
## [code]capture:<fortress_id>[/code] timer). Whoever has a [PlayerProgress] and is not marked by a GM command
## ([member NetEntity.gm_forced]) is paid; with a platform and [code]--fake-players[/code], nobody. What is earned
## changes the balance immediately (aggregate, §5.2) and reaches the owner through [method flush]; levelling up sets
## [member NetEntity.level], sends the LEVEL_UP ([member level_up_sink]) and marks the save as critical, as does
## collecting a capture reward.

## The section's key in the save body (plataforma.md §7.1).
const SECTION: StringName = &"progress"
## Text of the REJECT UNAVAILABLE if the record cannot be read (plataforma.md §5.2).
const PREPARE_FAILED_TEXT: String = "No se ha podido cargar el personaje"
## Criticality of the starter kit (§9.2).
const CRITICAL_STARTER_KIT: StringName = &"starter_kit"
## NOTICE for a CAMP_REFILL with no room in the bag (§4.4), once per entry into the safe zone.
const BAG_FULL_TEXT: String = "Bolsa llena"
## RATE (§4.2): requests per tick and burst.
const REQUEST_RATE_PER_TICK: float = 8.0 / 60.0
const REQUEST_BURST: float = 16.0
## RATE of SPLIT and DESTROY, which spend ids: per tick and burst.
const ID_REQUEST_RATE_PER_TICK: float = 2.0 / 60.0
const ID_REQUEST_BURST: float = 10.0
## INVENTORY_SYNC_REQUEST: one every 5 s; more, a strike (§4.6).
const SYNC_INTERVAL_TICKS: int = 300
## WALLET_UPDATE and PROGRESS_UPDATE: at most one every 10 ticks per player (§12).
const FLUSH_INTERVAL_TICKS: int = 10
## The /atascado (/stuck) timer (§8).
const TIMER_UNSTUCK: String = "unstuck"
## Prefix of the capture reward timer (§6.2 and §8): [code]capture:<fortress_id>[/code].
const TIMER_CAPTURE_PREFIX: String = "capture:"
## Criticalities of levelling up and of the capture reward (§9.2).
const CRITICAL_LEVEL_UP: StringName = &"level_up"
const CRITICAL_CAPTURE: StringName = &"capture"
## Capture reward (§6.2): XP and gold to each one on the list, once per character and fortress every
## [constant CAPTURE_COOLDOWN_S] seconds.
const CAPTURE_XP: int = 300
const CAPTURE_GOLD: int = 20
const CAPTURE_COOLDOWN_S: int = 1800
## Ticks in the active circle that give one objective merit: one per second, the scoreboard's provisional values
## ([ScoreKeeper], fuerte.md) until PRG-09 changes them.
const OBJECTIVE_TICKS_PER_MERIT: int = 60
## Log line when starting with a platform and [code]--fake-players[/code] (§6.2).
const FAKE_PLAYERS_TEXT: String = "Progreso: con --fake-players y la plataforma, la zona no da recompensas persistentes"
## SAFE zones (§8): the character returns to the saved spot if it was saved less than this long ago (s).
const RETURN_WINDOW_S: int = 900
## Reasons for the strikes (red.md §12).
const STRIKE_NOT_IN_WORLD: String = "petición de inventario antes de entrar en el mundo"
const STRIKE_MALFORMED: String = "petición de inventario mal formada"
const STRIKE_INVALID: String = "petición de inventario no válida"
const STRIKE_RATE: String = "peticiones de inventario demasiado rápidas"
const STRIKE_SYNC: String = "sincronías de inventario demasiado seguidas"


## The weapons, the active slot and the charges with which registration and respawn equip the character instead of
## the template (§8).
class Loadout:
	extends RefCounted
	## [CombatCatalog] ids of equipment slots 0 and 1 (0 = empty).
	var weapon_1: int = 0
	var weapon_2: int = 0
	## Slot 1 is active (bit0 of [code]combat_flags2[/code]).
	var second_active: bool = false
	## Packed as [member CombatState.consumable_charges]: [code]min(15, bag)[/code] of each consumable.
	var charges: int = 0


# The network state of a player with an inventory in the world: its peer, its pacing and the last thing sent to it.
class _Session:
	extends RefCounted
	var net_id: int = 0
	var peer: ServerPeer = null
	var player: PlayerProgress = null
	## The body's combat (the same from registration to departure; null on a registration without combat, which does not
	## happen).
	var combatant: Combatant = null
	var requests: RateLimiter = RateLimiter.new(ProgressService.REQUEST_RATE_PER_TICK, ProgressService.REQUEST_BURST)
	var id_requests: RateLimiter = RateLimiter.new(ProgressService.ID_REQUEST_RATE_PER_TICK,
			ProgressService.ID_REQUEST_BURST)
	var flood: ChatPeerState.FloodWindow = ChatPeerState.FloodWindow.new()
	var last_sync_tick: int = -ProgressService.SYNC_INTERVAL_TICKS
	## The charges before step 1 of the tick (−1 = no body): CONSUME looks at how much they have dropped.
	var charges_before: int = -1
	## The last CAMP_REFILL (tick); the full-bag notice goes out once per entry into the safe zone.
	var last_camp_tick: int = -1
	var bag_full_noticed: bool = false
	## The last thing sent: balances (index = currency) and [level, xp_total, realm points].
	var sent_wallets: PackedInt64Array = PackedInt64Array()
	var sent_progress: Array[int] = []
	## Capture reward: timer key ([code]capture:<id>[/code]) → tick from which it pays again.
	var capture_ready: Dictionary[String, int] = {}
	## Circle ticks that do not yet add up to an objective merit.
	var objective_ticks: int = 0


# A request queued until the end of the tick (request null = INVENTORY_SYNC_REQUEST).
class _Pending:
	extends RefCounted
	var session: _Session = null
	var request_id: int = 0
	var request: InventoryOps.Request = null


## Log (a [Callable] with a text); without it, print.
var log_sink: Callable = Callable()
## [code](peer: ServerPeer, bytes: PackedByteArray) -> void[/code]: sends over the reliable channel (set by the zone).
var send_sink: Callable = Callable()
## [code](peer: ServerPeer, reason: String) -> void[/code]: adds a strike to the peer (red.md §12).
var strike_sink: Callable = Callable()
## [code](peer: ServerPeer, text: String) -> void[/code]: an informational NOTICE.
var notice_sink: Callable = Callable()
## [code](net_id: int, level: int, s: int) -> void[/code]: the LEVEL_UP ENTITY_EVENT to the owner and to those of its
## realm for whom it is relevant (§6.3; set by the zone).
var level_up_sink: Callable = Callable()
## [code](peer: ServerPeer, text: String) -> void[/code]: a response line of a [code]/gm[/code] command through the
## chat's system channel (P5d; set by the zone).
var reply_sink: Callable = Callable()
## [code]() -> int[/code]: Unix time without a platform (P5d: the [code]detail.at_unix[/code] of GM operations on
## ephemeral characters; set by the zone). With a platform, [method ZonePlatform.now_unix] rules.
var clock_unix: Callable = Callable()

var _zone: ZoneServer = null
var _platform: ZonePlatform = null
var _saver: CharacterSaver = null
var _commands: CommandRegistry = null
## The GM commands of §10 (P5d); null without a command registry.
var _gm: ProgressCommands = null
var _ids: IdAllocator = null
var _db: ItemDatabase = null
## peer_id -> what was prepared in the claim, until registration or departure during LOADING.
var _prepared: Dictionary[int, PlayerProgress] = {}
## net_id -> the body's progress.
var _players: Dictionary[int, PlayerProgress] = {}
## net_id -> the player's network state (peer, pacing and last thing sent).
var _sessions: Dictionary[int, _Session] = {}
## The same ones, in a list (each tick's steps walk it without creating a new array).
var _session_list: Array[_Session] = []
## The tick's requests in arrival order.
var _pending: Array[_Pending] = []
## A block requested and not yet answered (the first one arrives from the platform startup).
var _block_pending: bool = false
## With a platform and --fake-players no reward is paid (§6.2).
var _rewards_blocked: bool = false
## Text id → its u32 fingerprint (ref_id of NPCs and fortresses, §5.2).
var _ref_ids: Dictionary[StringName, int] = {}
var _stats: Dictionary[StringName, int] = {
	&"prepared": 0, &"prepare_failed": 0, &"appearance_replaced": 0, &"cancelled": 0, &"arrivals": 0,
	&"ephemeral": 0, &"kits": 0, &"kits_deferred": 0, &"departures": 0, &"blocks": 0, &"block_requests": 0,
	&"unbuilt": 0, &"requests": 0, &"applied": 0, &"rejected": 0, &"rate_limited": 0, &"not_in_world": 0,
	&"syncs": 0, &"weapon_changes": 0, &"consumed": 0, &"camp_refills": 0, &"bag_full_notices": 0, &"refills": 0,
	&"returned_to_spot": 0, &"merits": 0, &"xp": 0, &"gold": 0, &"npc_rewards": 0, &"captures_paid": 0,
	&"captures_on_cooldown": 0, &"level_ups": 0, &"rewards_blocked": 0,
}


## Hooks the service to [param zone]: with [param platform] and [param saver] (null without a platform, §9.4), it
## registers the [code]progress[/code] section in [param saver] (the first one: it is the only one that can return
## [code]{}[/code], and [CharacterSaver] does not undo what another built earlier in that attempt) and uses the
## platform's blocks; without one, local ids. In [param commands] it registers the GM commands of §10
## ([ProgressCommands], P5d).
func setup(zone: ZoneServer, platform: ZonePlatform, saver: CharacterSaver, commands: CommandRegistry) -> void:
	_zone = zone
	_platform = platform
	_saver = saver
	_commands = commands
	_db = ItemDatabase.shared()
	if _commands != null:
		_gm = ProgressCommands.new(self, zone, platform)
		_gm.register_commands(_commands)
	if _platform == null:
		_ids = IdAllocator.local()
	else:
		_ids = IdAllocator.new()
		var max_players: int = zone.get_config().max_players if zone != null and zone.get_config() != null \
				else ServerConfig.DEFAULT_MAX_PLAYERS
		_ids.build_reserve = 2 * maxi(max_players, 1)
		_ids.running_low.connect(_check_ids)
	if _saver != null:
		_saver.register_section(SECTION, _build, _acknowledge, _is_dirty)
	var config: ServerConfig = zone.get_config() if zone != null else null
	_rewards_blocked = _platform != null and config != null and config.fake_players > 0
	if _rewards_blocked:
		_log(FAKE_PLAYERS_TEXT)


## Zone startup at tick [param s]: with a platform, the first block is already requested (requested by the
## [ZonePlatform] startup before [signal ZonePlatform.startup_finished]) and arrives as an event in the first "poll".
func start(_s: int) -> void:
	_block_pending = _platform != null


## Step (3) of plataforma.md §5.2, before the WELCOME (§9.1 step 2): reads the record from the claim
## ([method ProgressRecord.from_dictionary]), validates the appearance against the character's race and realm (an
## invalid one is replaced by its race's default, with a warning, without kicking the player) and prepares its
## [PlayerProgress] for registration. false if the record cannot be read: the zone answers REJECT UNAVAILABLE
## ([constant PREPARE_FAILED_TEXT]), logs it as an alert and releases.
func prepare(peer_id: int, claimed: ClaimedCharacter) -> bool:
	if claimed == null:
		return false
	var record: ProgressRecord = ProgressRecord.from_dictionary(claimed.progress, _db)
	if record == null:
		_stats[&"prepare_failed"] += 1
		_alert("el registro del personaje %d no se puede leer: se rechaza su entrada" % claimed.character_id)
		return false
	_check_appearance(record, claimed)
	var player := PlayerProgress.new(record, true, _ids, _db)
	player.character_id = claimed.character_id
	player.account_id = claimed.account_id
	_prepared[peer_id] = player
	_stats[&"prepared"] += 1
	return true


## Departure during LOADING (§9.1 step 3): discards what was prepared for [param peer_id]. With nothing, nothing.
func cancel_prepared(peer_id: int) -> void:
	if _prepared.erase(peer_id):
		_stats[&"cancelled"] += 1


## Registration of [param entity] (§9.1 step 4), after [method CharacterSaver.track] and before the SPAWN: ties to the
## [code]net_id[/code] the [PlayerProgress] prepared for [param peer] or, without a platform, a new ephemeral one (§9.4);
## applies the rule for returning to the world (§8: spot and health), restores the /atascado (/stuck) timer, takes the
## body's snapshot as confirmed (entering without changing anything does not make it dirty), gives the first-entry kit
## (critical, §2.5) and sets the level and appearance on the entity. Returns the [ProgressService.Loadout] with which
## registration equips the character instead of the template; null without a peer or, with a platform, with nothing
## prepared (the template, as for a fake player).
func on_arrival(entity: NetEntity, peer: ServerPeer, s: int) -> Loadout:
	if entity == null or peer == null:
		return null
	var player: PlayerProgress = _prepared.get(peer.peer_id)
	if player != null:
		_prepared.erase(peer.peer_id)
	elif _platform == null:
		player = _new_ephemeral(peer)
		_stats[&"ephemeral"] += 1
	else:
		return null
	var net_id: int = entity.net_id
	player.arrival_tick = s
	player.played_base = player.record.played_seconds
	# A method Callable (no lambda): it holds no strong reference to the service or to the progress itself.
	player.live_source = Callable(self, "_live_of").bind(net_id)
	_players[net_id] = player
	_return_to_world(entity, player)
	_restore_timers(entity, player, s)
	player.confirm_current()
	_stats[&"arrivals"] += 1
	if not player.record.starter_granted:
		if player.grant_starter_kit(player.record.starter_template_id):
			_stats[&"kits"] += 1
			if _saver != null:
				_saver.mark_critical(net_id, CRITICAL_STARTER_KIT)
		else:
			_stats[&"kits_deferred"] += 1
			_log("Progreso: el kit de inicio del personaje %d se aplaza (sin ids del servidor)" % player.character_id)
	entity.level = player.record.level
	entity.appearance = player.record.appearance.duplicate()
	var session := _Session.new()
	session.net_id = net_id
	session.peer = peer
	session.player = player
	session.combatant = _combatant(net_id)
	_sessions[net_id] = session
	_session_list.append(session)
	_restore_capture_timers(session, s)
	return _loadout(player, true)


## After its own SPAWN (§9.1 step 5): INVENTORY_FULL (in pages), one WALLET_UPDATE per currency (delta 0) and one
## PROGRESS_UPDATE of the state. Without a [PlayerProgress], nothing.
func after_spawn(entity: NetEntity, _peer: ServerPeer, _s: int) -> void:
	var session: _Session = _sessions.get(entity.net_id) if entity != null else null
	if session == null:
		return
	var player: PlayerProgress = session.player
	_send_full(session)
	session.sent_wallets = player.record.wallets.duplicate()
	for code: int in Currency.codes():
		_send(session, ProgressMessages.WalletUpdate.make(code, player.record.wallets[code], 0, 0).encode())
	player.pending_xp_gain = 0
	player.pending_xp_source = ProgressMessages.XpSource.STATE
	_send_progress(session)


## The equipment with which [param net_id] respawns (§8): its weapons, slot 1 active only if WEAPON_1 is empty and the
## charges of its bag. null without a [PlayerProgress] (the caller uses the template, as with a fake player).
func loadout_for(net_id: int) -> Loadout:
	var player: PlayerProgress = _players.get(net_id)
	return _loadout(player, false) if player != null else null


## true if [param net_id] has a [PlayerProgress] (a player with a peer).
func has_inventory(net_id: int) -> bool:
	return _players.has(net_id)


## The level of [param net_id]; 0 without a [PlayerProgress].
func level_of(net_id: int) -> int:
	var player: PlayerProgress = _players.get(net_id)
	return player.record.level if player != null else 0


## The persistent [code]character_id[/code] of [param net_id]; 0 without a [PlayerProgress] or if it is ephemeral.
func character_id_of(net_id: int) -> int:
	var player: PlayerProgress = _players.get(net_id)
	return player.character_id if player != null and player.persistent else 0


## INVENTORY_REQUEST (0x50) or INVENTORY_SYNC_REQUEST (0x53) from [param peer], in the "poll": outside the world or
## malformed adds a strike; RATE is checked on arrival, before anything else (it answers immediately with the real
## contents of the slots concerned); the rest goes to the queue of [method apply_pending]. A sync within 5 s adds a
## strike and is not answered.
func handle_packet(peer: ServerPeer, bytes: PackedByteArray) -> void:
	if peer == null or bytes.is_empty() or peer.state == ServerPeer.State.LEAVING:
		return
	var tick: int = _zone.get_tick() if _zone != null else 0
	var session: _Session = null
	if peer.state == ServerPeer.State.IN_WORLD and peer.entity != null:
		session = _sessions.get(peer.entity.net_id)
	if session == null or session.peer != peer:
		_stats[&"not_in_world"] += 1
		_strike(peer, STRIKE_NOT_IN_WORLD)
		return
	match bytes[0]:
		NetProtocol.MSG_INVENTORY_REQUEST:
			var message: ProgressMessages.InventoryRequest = ProgressMessages.InventoryRequest.decode(bytes)
			if message == null:
				_strike(peer, STRIKE_MALFORMED)
				return
			_stats[&"requests"] += 1
			var request: InventoryOps.Request = message.to_request()
			var spends_id: bool = request.op == InventoryOps.Op.SPLIT or request.op == InventoryOps.Op.DESTROY
			if session.requests.get_tokens(tick) < 1.0 \
					or (spends_id and session.id_requests.get_tokens(tick) < 1.0):
				_stats[&"rate_limited"] += 1
				var state: InventoryState = session.player.record.inventory
				_send(session, ProgressMessages.InventoryDelta.for_slots(session.player.revision, message.request_id,
						InventoryOps.Result.RATE, 0, state, _touched(state, request)).encode(_db))
				if session.flood.note(tick):
					_strike(peer, STRIKE_RATE)
				return
			session.requests.try_consume(tick)
			if spends_id:
				session.id_requests.try_consume(tick)
			var pending := _Pending.new()
			pending.session = session
			pending.request_id = message.request_id
			pending.request = request
			_pending.append(pending)
		NetProtocol.MSG_INVENTORY_SYNC_REQUEST:
			if ProgressMessages.InventorySyncRequest.decode(bytes) == null:
				_strike(peer, STRIKE_MALFORMED)
				return
			if tick - session.last_sync_tick < SYNC_INTERVAL_TICKS:
				_strike(peer, STRIKE_SYNC)
				return
			session.last_sync_tick = tick
			var sync := _Pending.new()
			sync.session = session
			_pending.append(sync)
		_:
			_strike(peer, STRIKE_MALFORMED)


## The requests of tick [param s] (§4.2), at the end of the tick and after registrations, in arrival order: each with
## the [InventoryOps.Context] of the server's [CombatState] (the active slot, whether it can touch equipment and whether
## it is drinking), its INVENTORY_DELTA as the response and, if applied, the imposed weapons and charges. INVALID adds a
## strike. Syncs get their INVENTORY_FULL with the state of that moment.
func apply_pending(s: int) -> void:
	if _pending.is_empty():
		return
	var pending: Array[_Pending] = _pending
	_pending = []
	for entry: _Pending in pending:
		var session: _Session = entry.session
		if _sessions.get(session.net_id) != session:
			continue
		if entry.request == null:
			_stats[&"syncs"] += 1
			_send_full(session)
		else:
			_apply_request(session, entry, s)


## Before step 1 (simulate) of tick [param s]: the charges of each player with an inventory, so that
## [method after_simulate] sees how much they have dropped.
func before_simulate(_s: int) -> void:
	for session: _Session in _session_list:
		session.charges_before = session.combatant.get_character().combat.consumable_charges \
				if session.combatant != null else -1


## After step 1 of tick [param s] (§4.4): CONSUME. If a consumable's charge dropped (the commitment to drink,
## habilidades.md §3.3 rule 5), that amount is removed from the stack of its definition with the lowest bag slot
## (aggregate), its INVENTORY_DELTA goes out and the charges are imposed ([code]min(15, bag)[/code]: with more than 15,
## the charge goes back to 15 with a LOADOUT). An interrupted drink does not lower the charge and spends nothing.
func after_simulate(s: int) -> void:
	for session: _Session in _session_list:
		var before: int = session.charges_before
		session.charges_before = -1
		if before < 0:
			continue
		var combatant: Combatant = session.combatant
		var combat: CombatState = combatant.get_character().combat
		if combat.consumable_charges == before:
			continue
		var consumed: bool = false
		for index: int in range(CombatState.CONSUMABLE_SLOTS):
			var spent: int = ((before >> (4 * index)) & CombatState.MAX_CHARGES) - combat.charges_of(index)
			if spent <= 0:
				continue
			var definition: ItemDefinition = _db.consumable_definition(index)
			if definition == null:
				_alert("el consumible %d no tiene objeto: no se descuenta lo que ha bebido el net_id %d"
						% [index, session.net_id])
				continue
			var outcome: InventoryOps.Outcome = session.player.take_items(definition.id, spent,
					EconomyReason.CONSUME)
			if not outcome.is_ok():
				_alert("el net_id %d ha bebido %d de %s sin tenerlas en la bolsa" % [session.net_id, spent,
						definition.id])
				continue
			consumed = true
			_stats[&"consumed"] += spent
			_send_server_delta(session, outcome.changed, EconomyReason.CONSUME)
		if consumed:
			_impose_charges(session, combatant, s)


## CAMP_REFILL of [param entity] at tick [param s] (§4.4): called by the camp restock (step 8, every 60 ticks, alive,
## out of combat and in its realm's safe zone) instead of the template's. Restocks the total of each definition with
## [member ItemDefinition.camp_refill] (aggregate), with its INVENTORY_DELTA and the charges; with no room for a new
## stack, NOTICE "Bolsa llena" (bag full) once per entry into the safe zone (an entry: not having restocked in the
## previous restock). Without a [PlayerProgress], nothing.
func camp_step(entity: NetEntity, s: int) -> void:
	var session: _Session = _sessions.get(entity.net_id) if entity != null else null
	var combatant: Combatant = session.combatant if session != null else null
	if combatant == null:
		return
	if session.last_camp_tick != s - CombatDirector.RECHARGE_INTERVAL_TICKS:
		session.bag_full_noticed = false
	session.last_camp_tick = s
	var outcome: InventoryOps.Outcome = session.player.camp_refill()
	if not outcome.changed.is_empty():
		_stats[&"camp_refills"] += 1
		_send_server_delta(session, outcome.changed, EconomyReason.CAMP_REFILL)
		_impose_charges(session, combatant, s)
	if outcome.bag_full and not session.bag_full_noticed:
		session.bag_full_noticed = true
		_stats[&"bag_full_notices"] += 1
		if notice_sink.is_valid() and _is_reachable(session):
			notice_sink.call(session.peer, BAG_FULL_TEXT)


## The command 16 [code]refill[/code] (and the console's [code]refill[/code]) for whoever has an inventory (§4.4):
## without a platform, a forced CAMP_REFILL (aggregate) ignoring zone and combat, with its delta, the charges and
## LOADOUT to the owner. false if [param net_id] has no inventory or is not alive; also with a platform, where it is a
## GM operation ([method ProgressCommands.net_refill], P5d).
func force_refill(net_id: int, s: int) -> bool:
	var session: _Session = _sessions.get(net_id)
	var combatant: Combatant = session.combatant if session != null else null
	if combatant == null or not combatant.is_alive() or _platform != null:
		return false
	var outcome: InventoryOps.Outcome = session.player.camp_refill()
	if not outcome.changed.is_empty():
		_send_server_delta(session, outcome.changed, EconomyReason.CAMP_REFILL)
	_stats[&"refills"] += 1
	_impose_charges(session, combatant, s, true)
	return true


## WALLET_UPDATE and PROGRESS_UPDATE of tick [param s] (§12): to each player, at most one every
## [constant FLUSH_INTERVAL_TICKS] ticks (staggered by [code]net_id[/code]), with the summed delta of each currency that
## has changed (and the reason for its last change) and, if the level, XP or realm points changed, the progress with
## what was gained since the previous one.
func flush(s: int) -> void:
	for session: _Session in _session_list:
		if (s + session.net_id) % FLUSH_INTERVAL_TICKS != 0:
			continue
		var player: PlayerProgress = session.player
		for code: int in Currency.codes():
			var balance: int = player.record.wallets[code]
			if session.sent_wallets.size() <= code or balance == session.sent_wallets[code]:
				continue
			_send(session, ProgressMessages.WalletUpdate.make(code, balance, balance - session.sent_wallets[code],
					player.last_currency_reasons[code]).encode())
			session.sent_wallets[code] = balance
		if player.pending_xp_gain > 0 or session.sent_progress != _progress_key(player):
			_send_progress(session)


## Stores in the record of [param net_id] the timer [param key] that expires at tick [param ready_tick], seen at tick
## [param s] (§8: [code]ends_at_unix[/code] with the platform's time). An expired one is removed. Without a platform
## (or on an ephemeral character) there are no timers to save.
func set_timer(net_id: int, key: String, ready_tick: int, s: int) -> void:
	var player: PlayerProgress = _players.get(net_id)
	var now: int = _platform.now_unix() if _platform != null else 0
	if player == null or not player.persistent or now <= 0:
		return
	if ready_tick <= s:
		player.record.timers.erase(key)
	else:
		player.record.timers[key] = PlayerProgress.ends_at_unix_for(ready_tick, s, now)


## PRG-09 merits for [param net_id] at tick [param s] (§6.2): [param amount] of [param reason]
## (PVP_KILL, PVP_ASSIST or OBJECTIVE) and [code]amount × 10[/code] of XP. PvP ones only with a persistent victim
## ([param victim_net_id]) of another realm: that of an NPC, a fake player or an ephemeral character gives nothing, and
## its ledger entry carries the victim's [code]character_id[/code]. Objective ones go without a victim (0). Raises realm
## points with what is recorded (I9). Nothing without a [PlayerProgress], with [member NetEntity.gm_forced] or with a
## platform and [code]--fake-players[/code].
func on_merits(net_id: int, amount: int, reason: int, victim_net_id: int, s: int) -> void:
	if amount <= 0 or not EconomyReason.gives_realm_points(reason):
		return
	var session: _Session = _collector(net_id)
	if session == null:
		return
	if reason == EconomyReason.OBJECTIVE:
		if victim_net_id == 0:
			_pay_merits(session, amount, reason, LedgerEntry.RefKind.NONE, 0, ProgressMessages.XpSource.CAPTURE, s)
		return
	var victim: PlayerProgress = _players.get(victim_net_id)
	var victim_entity: NetEntity = _entity(victim_net_id)
	var entity: NetEntity = _entity(net_id)
	if victim == null or not victim.persistent or victim_entity == null or entity == null \
			or victim_entity.realm == entity.realm:
		return
	_pay_merits(session, amount, reason, LedgerEntry.RefKind.CHARACTER, victim.character_id,
			ProgressMessages.XpSource.PVP, s)


## [param ticks] more of [param net_id] in the active circle of [param fortress_id] at tick [param s] (the signal
## [signal FortressController.objective_time]: real cycle and without [member NetEntity.gm_forced]): every
## [constant OBJECTIVE_TICKS_PER_MERIT] accumulated ticks are one objective merit (reason OBJECTIVE, with the fortress
## as reference) and its XP.
func on_objective_ticks(fortress_id: StringName, net_id: int, ticks: int, s: int) -> void:
	if ticks <= 0:
		return
	var session: _Session = _collector(net_id)
	if session == null:
		return
	session.objective_ticks += ticks
	@warning_ignore("integer_division")
	var merits: int = session.objective_ticks / OBJECTIVE_TICKS_PER_MERIT
	if merits <= 0:
		return
	session.objective_ticks -= merits * OBJECTIVE_TICKS_PER_MERIT
	_pay_merits(session, merits, EconomyReason.OBJECTIVE, LedgerEntry.RefKind.FORTRESS, _ref_id(fortress_id),
			ProgressMessages.XpSource.CAPTURE, s)


## An NPC of [param npc] has died at tick [param s] (§6.2): each of [param contributors] (those who did at least 10 %
## of the window's damage, [method DamageLedger.contributors]) receives the whole reward:
## [member NpcDefinition.xp_reward] of XP and [member NpcDefinition.gold_reward] of gold (NPC_KILL, with the NPC as
## reference). No merits. The zone does not call it if the NPC was defending a fortress in a forced cycle.
func on_npc_killed(npc: NpcDefinition, contributors: PackedInt32Array, s: int) -> void:
	if npc == null or (npc.xp_reward <= 0 and npc.gold_reward <= 0):
		return
	for net_id: int in contributors:
		var session: _Session = _collector(net_id)
		if session == null:
			continue
		_stats[&"npc_rewards"] += 1
		if npc.gold_reward > 0:
			_stats[&"gold"] += session.player.gain_currency(Currency.Code.GOLD, npc.gold_reward, EconomyReason.NPC_KILL,
					LedgerEntry.RefKind.NPC, _ref_id(npc.id))
		_grant_xp(session, npc.xp_reward, ProgressMessages.XpSource.NPC, s)


## Real capture of [param fortress_id] by [param owner_realm] at tick [param s]
## ([signal FortressController.fortress_captured]): each one in [param in_circle] (the list from plataforma.md §8, the
## same one that [code]ScoreKeeper.captures[/code] adds up) of that realm receives [constant CAPTURE_XP] of XP and
## [constant CAPTURE_GOLD] of gold (OBJECTIVE, with the fortress as reference), once every
## [constant CAPTURE_COOLDOWN_S] s per fortress: with a platform, the [code]capture:<fortress_id>[/code] timer is saved
## and returns with the character (§8). Collecting marks the save as critical. A forced capture does not get here.
func on_capture(fortress_id: StringName, owner_realm: int, in_circle: PackedInt32Array, s: int) -> void:
	var key: String = TIMER_CAPTURE_PREFIX + String(fortress_id)
	for net_id: int in in_circle:
		var session: _Session = _collector(net_id)
		var entity: NetEntity = _entity(net_id)
		if session == null or entity == null or entity.realm != owner_realm:
			continue
		if session.capture_ready.get(key, 0) > s:
			_stats[&"captures_on_cooldown"] += 1
			continue
		var ready_tick: int = s + CAPTURE_COOLDOWN_S * PlayerProgress.TICKS_PER_SECOND
		session.capture_ready[key] = ready_tick
		set_timer(net_id, key, ready_tick, s)
		_stats[&"captures_paid"] += 1
		_stats[&"gold"] += session.player.gain_currency(Currency.Code.GOLD, CAPTURE_GOLD, EconomyReason.OBJECTIVE,
				LedgerEntry.RefKind.FORTRESS, _ref_id(fortress_id))
		_grant_xp(session, CAPTURE_XP, ProgressMessages.XpSource.CAPTURE, s)
		if _saver != null and session.player.persistent:
			_saver.mark_critical(net_id, CRITICAL_CAPTURE)
		_log("Progreso: net_id %d (%s) cobra la captura de %s" % [net_id, _who(session.player), fortress_id])


## true if the zone pays no rewards: with a platform and [code]--fake-players[/code] (§6.2).
func rewards_blocked() -> bool:
	return _rewards_blocked


## The progress tied to [param net_id], or null (tests and following packages).
func get_player(net_id: int) -> PlayerProgress:
	return _players.get(net_id)


## What was prepared for [param peer_id] and not yet registered, or null.
func get_prepared(peer_id: int) -> PlayerProgress:
	return _prepared.get(peer_id)


## The zone's id generator.
func get_ids() -> IdAllocator:
	return _ids


## Requests queued for the end of the tick (tests).
func pending_count() -> int:
	return _pending.size()


## A platform event of its own (§14.2): [code]id_block[/code] (a new block; if few remain, it requests another),
## [code]progress_op[/code] and [code]progress_ledger[/code] (the responses of [code]op_show[/code],
## [code]op_revert[/code] and [code]ledger_show[/code], handled by [ProgressCommands]). true if it was its own.
func on_platform_event(event: PlatformEvent) -> bool:
	match event.kind:
		PlatformEvent.KIND_ID_BLOCK:
			_block_pending = false
			var body: Dictionary = event.body_dict()
			var first: Variant = body.get("first")
			if event.is_success() and ProgressJson.is_id(first) \
					and ProgressJson.is_int(body.get("count"), 1, IdAllocator.BLOCK_SIZE * 64):
				_ids.add_block(ProgressJson.id_value(first), int(body["count"]))
				_stats[&"blocks"] += 1
			else:
				_alert("bloque de ids que no vale o rechazado: %s" % ZonePlatform.describe(event))
			_check_ids()
			return true
		PlatformEvent.KIND_PROGRESS_OP, PlatformEvent.KIND_PROGRESS_LEDGER:
			if _gm != null:
				_gm.on_platform_event(event)
			return true
	return false


## Departure of [param net_id] (§9.2), after [method CharacterSaver.finish] and [method ScoreKeeper.forget], or on a
## departure without a save: discards its state (and its queued requests). On a [code]net_id[/code] without a
## [PlayerProgress], nothing.
func on_departure(net_id: int) -> void:
	var session: _Session = _sessions.get(net_id)
	if session != null:
		_sessions.erase(net_id)
		_session_list.erase(session)
	if _players.erase(net_id):
		_stats[&"departures"] += 1


## Counters for the report and the tests.
func get_stats() -> Dictionary:
	var stats: Dictionary = {}
	for key: StringName in _stats:
		stats[String(key)] = _stats[key]
	stats["players"] = _players.size()
	stats["prepared_now"] = _prepared.size()
	stats["ids_available"] = _ids.available() if _ids != null and not _ids.is_local() else -1
	if _gm != null:
		stats["gm"] = _gm.get_stats()
	return stats


# --- What the GM commands use (P5d, [ProgressCommands]) ------------------------------------

## The GM commands of §10 (null without a command registry).
func gm_commands() -> ProgressCommands:
	return _gm


## Unix time: the platform's or, without one, that of [member clock_unix] (0 if there is none).
func now_unix() -> int:
	if _platform != null:
		return _platform.now_unix()
	return int(clock_unix.call()) if clock_unix.is_valid() else 0


## The [code]net_id[/code] of the player with progress connected in this zone that [param text] names (their
## [code]net_id[/code] or their name, ignoring case and accents), or 0.
func find_connected(text: String) -> int:
	var wanted: String = text.strip_edges()
	var key: String = NameRules.normalize_key(wanted)
	for session: _Session in _session_list:
		if not _is_reachable(session):
			continue
		if (wanted.is_valid_int() and wanted.to_int() == session.net_id) \
				or NameRules.normalize_key(session.peer.display_name) == key:
			return session.net_id
	return 0


## The [code]net_id[/code] of the persistent character [param character_id] if connected in this zone, or 0.
func connected_net_id_of(character_id: int) -> int:
	for session: _Session in _session_list:
		if session.player.persistent and session.player.character_id == character_id and _is_reachable(session):
			return session.net_id
	return 0


## true if [param net_id] has progress and its peer is still in the world with that body.
func is_connected_player(net_id: int) -> bool:
	var session: _Session = _sessions.get(net_id)
	return session != null and _is_reachable(session)


## The peer of [param net_id] if it is still in the world with that body, or null.
func peer_of(net_id: int) -> ServerPeer:
	var session: _Session = _sessions.get(net_id)
	return session.peer if session != null and _is_reachable(session) else null


## The [code]net_id[/code]s with a [PlayerProgress] (including the body that stays after a combat exit).
func player_net_ids() -> PackedInt32Array:
	return PackedInt32Array(_players.keys())


## The active weapon slot of [param net_id] (bit0 of [code]combat_flags2[/code] of the [CombatState]; without a body,
## the record's).
func active_weapon_slot(net_id: int) -> int:
	var session: _Session = _sessions.get(net_id)
	if session != null and session.combatant != null:
		return 1 if session.combatant.get_character().combat.is_second_slot() else 0
	var player: PlayerProgress = _players.get(net_id)
	return player.saved_active_slot() if player != null else 0


## true if the weapons of [param net_id] can be changed now (with no action in progress: [method
## ActionMachine.set_weapons] is only valid with the NONE action).
func can_change_weapons(net_id: int) -> bool:
	var session: _Session = _sessions.get(net_id)
	return session != null and session.combatant != null \
			and session.combatant.get_character().combat.action == CombatState.Action.NONE


## true if [param net_id] has a body and is alive.
func is_alive(net_id: int) -> bool:
	var session: _Session = _sessions.get(net_id)
	return session != null and session.combatant != null and session.combatant.is_alive()


## What a GM command has changed in the inventory of [param net_id] at tick [param s] (§4.4): the server's
## INVENTORY_DELTA with [param reason], the weapons if it touched the weapon slots ([param weapons_changed]) and the
## charges, with LOADOUT to the owner if they change (or always, with [param always_loadout]: the 16).
func after_gm_change(net_id: int, changed: Array[Vector2i], weapons_changed: bool, reason: int, s: int,
		always_loadout: bool = false) -> void:
	var session: _Session = _sessions.get(net_id)
	if session == null:
		return
	var unique: Array[Vector2i] = []
	for position: Vector2i in changed:
		if not unique.has(position):
			unique.append(position)
	if not unique.is_empty():
		_send_server_delta(session, unique, reason)
	if session.combatant == null:
		return
	if weapons_changed:
		_impose_weapons(session, session.combatant, s)
	_impose_charges(session, session.combatant, s, always_loadout)


## After a GM level change of [param net_id] (who had [param old_level]) at tick [param s]: the level on the entity (the
## following SPAWNs) and, if it goes up, the LEVEL_UP (§6.3). PROGRESS_UPDATE goes out in [method flush].
func after_level_change(net_id: int, old_level: int, s: int) -> void:
	var player: PlayerProgress = _players.get(net_id)
	if player == null or player.record.level == old_level:
		return
	var entity: NetEntity = _entity(net_id)
	if entity != null:
		entity.level = player.record.level
	if player.record.level > old_level:
		_stats[&"level_ups"] += 1
		if level_up_sink.is_valid():
			level_up_sink.call(net_id, player.record.level, s)


## A GM command has changed the character of [param net_id]: critical save [code]gm[/code] (§9.2).
func mark_gm_critical(net_id: int) -> void:
	var player: PlayerProgress = _players.get(net_id)
	if _saver != null and player != null and player.persistent:
		_saver.mark_critical(net_id, ProgressCommands.CRITICAL_GM)


## A response line to [param peer] through the chat's system channel (the [code]/gm[/code] commands).
func reply(peer: ServerPeer, text: String) -> void:
	if reply_sink.is_valid() and peer != null:
		reply_sink.call(peer, text)


## A line for the zone log.
func log_line(text: String) -> void:
	_log(text)


## An informational NOTICE to [param net_id] if still in the world (the reason for a rejected DEBUG_COMMAND).
func notice(net_id: int, text: String) -> void:
	var session: _Session = _sessions.get(net_id)
	if session != null and notice_sink.is_valid() and _is_reachable(session):
		notice_sink.call(session.peer, text)


# --- The progress section of CharacterSaver (§9.2) ------------------------------------------------

func _build(net_id: int, seq: int) -> Dictionary:
	var player: PlayerProgress = _players.get(net_id)
	if player == null:
		_alert("se pide el guardado del net_id %d, que no tiene progreso" % net_id)
		return {}
	var section: Dictionary = player.build_section(seq)
	if section.is_empty():
		_stats[&"unbuilt"] += 1
		_alert("sin ids para cerrar lo agregado del personaje %d: el guardado se aplaza" % player.character_id)
	return section


func _acknowledge(net_id: int, seq: int) -> void:
	var player: PlayerProgress = _players.get(net_id)
	if player != null:
		player.acknowledge(seq)


func _is_dirty(net_id: int) -> bool:
	var player: PlayerProgress = _players.get(net_id)
	return player != null and player.is_dirty()


# --- Inventory over the network ------------------------------------------------------------------------

func _apply_request(session: _Session, entry: _Pending, s: int) -> void:
	var player: PlayerProgress = session.player
	var combatant: Combatant = session.combatant
	var outcome: InventoryOps.Outcome
	if combatant == null:
		# No body: NOT_NOW ("no character or outside the world", §4.2).
		outcome = InventoryOps.Outcome.new()
		outcome.result = InventoryOps.Result.NOT_NOW
		outcome.changed = _touched(player.record.inventory, entry.request)
	else:
		var combat: CombatState = combatant.get_character().combat
		var context := InventoryOps.Context.new()
		context.active_weapon_slot = 1 if combat.is_second_slot() else 0
		context.can_touch_equipment = combatant.is_alive() and not combatant.is_in_combat(s) \
				and combat.action == CombatState.Action.NONE
		context.drinking = _is_drinking(combat)
		outcome = player.apply_request(entry.request, context)
	if outcome.result == InventoryOps.Result.INVALID:
		_strike(session.peer, STRIKE_INVALID)
	_send(session, ProgressMessages.InventoryDelta.for_slots(player.revision, entry.request_id, outcome.result, 0,
			player.record.inventory, outcome.changed).encode(_db))
	if not outcome.is_ok():
		_stats[&"rejected"] += 1
		return
	_stats[&"applied"] += 1
	_log_request(session, entry, outcome)
	if outcome.weapons_changed:
		_impose_weapons(session, combatant, s)
	if entry.request.op == InventoryOps.Op.DESTROY:
		# Only DESTROY changes the quantity of a definition (move, split and merge do not, I4).
		_impose_charges(session, combatant, s)


# After a confirmed change of the weapon slots (§4.1): saves the cooldowns of the weapons that were in each slot and
# sets those of the equipment with their own saved ones ([method ActionMachine.set_weapons]: without resetting anything
# else), the same active slot (or the other if it has been left without a weapon) and LOADOUT to the owner and, if the
# weapons change, to whoever has it relevant.
func _impose_weapons(session: _Session, combatant: Combatant, s: int) -> void:
	var character: PlayerCharacter = combatant.get_character()
	var combat: CombatState = character.combat
	if combat.action != CombatState.Action.NONE:
		# Does not happen: touching equipment with an action in progress is NOT_NOW.
		_alert("armas del net_id %d sin imponer: acción %d en curso" % [session.net_id, combat.action])
		return
	var player: PlayerProgress = session.player
	var second_active: bool = combat.is_second_slot()
	var before: PackedInt32Array = CombatDirector.weapons_in_slot_order(combat)
	var active_ready: PackedInt64Array = combat.ability_ready.slice(0, CombatState.ABILITY_SLOTS)
	var other_ready: PackedInt64Array = combat.ability_ready.slice(CombatState.ABILITY_SLOTS,
			2 * CombatState.ABILITY_SLOTS)
	player.stash_ready(before[0], other_ready if second_active else active_ready)
	player.stash_ready(before[1], active_ready if second_active else other_ready)
	var weapons: PackedInt32Array = player.weapons()
	if second_active and weapons[1] == 0 and weapons[0] != 0:
		second_active = false
	elif not second_active and weapons[0] == 0 and weapons[1] != 0:
		second_active = true
	ActionMachine.set_weapons(combat, weapons[0], weapons[1], second_active, player.stashed_ready(weapons[0]),
			player.stashed_ready(weapons[1]))
	CombatDirector.commit_state(character)
	_stats[&"weapon_changes"] += 1
	_zone.get_combat().announce_loadout(combatant, s, before != CombatDirector.weapons_in_slot_order(combat))


# The consumable charges: min(15, bag) of each (§4.4), with LOADOUT to the owner if they change (or always, with
# [param always]: command 16).
func _impose_charges(session: _Session, combatant: Combatant, s: int, always: bool = false) -> void:
	var character: PlayerCharacter = combatant.get_character()
	var charges: int = session.player.charges()
	if character.combat.consumable_charges == charges and not always:
		return
	ActionMachine.set_charges(character.combat, charges)
	CombatDirector.commit_state(character)
	_zone.get_combat().announce_loadout(combatant, s, false)


func _send_full(session: _Session) -> void:
	var player: PlayerProgress = session.player
	var pages: Array[ProgressMessages.InventoryFull] = ProgressMessages.InventoryFull.split(player.revision,
			player.record.inventory)
	if pages.is_empty():
		_alert("el inventario del net_id %d no cabe en INVENTORY_FULL" % session.net_id)
		return
	for page: ProgressMessages.InventoryFull in pages:
		_send(session, page.encode(_db))


func _send_server_delta(session: _Session, changed: Array[Vector2i], reason: int) -> void:
	_send(session, ProgressMessages.InventoryDelta.for_slots(session.player.revision, 0, InventoryOps.Result.OK,
			reason, session.player.record.inventory, changed).encode(_db))


func _send_progress(session: _Session) -> void:
	var player: PlayerProgress = session.player
	var source: int = player.pending_xp_source if player.pending_xp_gain > 0 else ProgressMessages.XpSource.STATE
	_send(session, ProgressMessages.ProgressUpdate.make(LevelCurve.shared(), player.record.level,
			player.record.xp_total, player.pending_xp_gain, source, player.record.realm_points).encode())
	player.pending_xp_gain = 0
	player.pending_xp_source = ProgressMessages.XpSource.STATE
	session.sent_progress = _progress_key(player)


static func _progress_key(player: PlayerProgress) -> Array[int]:
	return [player.record.level, player.record.xp_total, player.record.realm_points]


func _send(session: _Session, bytes: PackedByteArray) -> void:
	if bytes.is_empty():
		_alert("un mensaje de progreso para el net_id %d no se ha podido codificar" % session.net_id)
		return
	if send_sink.is_valid() and _is_reachable(session):
		send_sink.call(session.peer, bytes)


# The peer is still the body's owner and is in the world (the body that stays after a combat exit has no one left to
# send anything to).
func _is_reachable(session: _Session) -> bool:
	return session.peer != null and session.peer.state == ServerPeer.State.IN_WORLD \
			and session.peer.entity != null and session.peer.entity.net_id == session.net_id


func _strike(peer: ServerPeer, reason: String) -> void:
	if strike_sink.is_valid():
		strike_sink.call(peer, reason)


# The slots that exist among those [param request] touches (the real contents carried by a rejection's delta).
static func _touched(state: InventoryState, request: InventoryOps.Request) -> Array[Vector2i]:
	var slots: Array[Vector2i] = []
	if request == null:
		return slots
	var from := Vector2i(request.from_container, request.from_slot)
	if state.has_slot(from.x, from.y):
		slots.append(from)
	var to := Vector2i(request.to_container, request.to_slot)
	if request.op != InventoryOps.Op.DESTROY and to != from and state.has_slot(to.x, to.y):
		slots.append(to)
	return slots


static func _is_drinking(combat: CombatState) -> bool:
	if combat.action != CombatState.Action.ABILITY:
		return false
	var ability: AbilityTicks = CombatCatalog.ability(combat.action_id)
	return ability != null and ability.is_consumable()


func _log_request(session: _Session, entry: _Pending, outcome: InventoryOps.Outcome) -> void:
	var request: InventoryOps.Request = entry.request
	var who: String = _who(session.player)
	var target: String = "-" if request.op == InventoryOps.Op.DESTROY \
			else "%d:%d" % [request.to_container, request.to_slot]
	_log("Inventario: net_id %d (%s) %s %d:%d -> %s ×%d uid %d%s: OK" % [session.net_id, who,
			_op_name(request.op), request.from_container, request.from_slot, target, request.count,
			request.expected_uid, " (nuevo %d)" % outcome.new_id if outcome.new_id != 0 else ""])


static func _op_name(op: int) -> String:
	match op:
		InventoryOps.Op.MOVE:
			return "MOVE"
		InventoryOps.Op.SPLIT:
			return "SPLIT"
		InventoryOps.Op.DESTROY:
			return "DESTROY"
	return str(op)


# --- Registration ----------------------------------------------------------------------------------

# An ephemeral character (§9.4): new, from the peer's realm's folk with its default appearance and with the kit of the
# LOADOUT_SELECT template (the one that arrived before CLIENT_READY) or the default one; local ids and nothing to
# save.
func _new_ephemeral(peer: ServerPeer) -> PlayerProgress:
	var record: ProgressRecord = ProgressRecord.new_character()
	var catalog: AppearanceCatalog = AppearanceCatalog.shared()
	var race: RaceDefinition = catalog.race_for_realm(RealmCatalog.id_of_code(peer.realm))
	if race != null:
		record.race_id = race.id
		var appearance: CharacterAppearance = CharacterAppearance.default_for(catalog, catalog.race_index(race.id))
		if appearance != null:
			record.appearance = appearance.encode()
	var template: EquipmentTemplate = CombatCatalog.template(
			CombatDirector.resolve_template(maxi(peer.pending_template_id, 0)))
	record.starter_template_id = template.id if template != null else &""
	return PlayerProgress.new(record, false, _ids, _db)


func _loadout(player: PlayerProgress, at_arrival: bool) -> Loadout:
	var weapons: PackedInt32Array = player.weapons()
	var loadout := Loadout.new()
	loadout.weapon_1 = weapons[0]
	loadout.weapon_2 = weapons[1]
	if at_arrival:
		loadout.second_active = player.saved_active_slot() == 1 and weapons[1] != 0
	else:
		loadout.second_active = weapons[0] == 0 and weapons[1] != 0
	loadout.charges = player.charges()
	return loadout


# The rule for returning to the world (§8). Spot: in RvR zones (all those of phase 5), the realm's spawn point, where
# the zone has already put it on creating it; in SAFE ones, the saved one if it is from this instance, less than 900 s
# old, out of combat, alive, with ground and outside another realm's safe zone. Health: the saved one plus
# regeneration for the offline time, not exceeding the maximum; full with null or 0 or with no saved position.
func _return_to_world(entity: NetEntity, player: PlayerProgress) -> void:
	var record: ProgressRecord = player.record
	var location: Dictionary = record.location
	var now: int = _platform.now_unix() if _platform != null else 0
	var saved_at: int = int(location.get(ProgressRecord.LOCATION_CLAIM_KEY, 0))
	var config: ServerConfig = _zone.get_config() if _zone != null else null
	if config != null and not NetZones.is_rvr(config.zone_id) and _can_return(entity, record, config, now, saved_at):
		var spot := Vector3(float(location["x"]), float(location["y"]), float(location["z"]))
		if _zone.place_returning(entity, spot, float(location["yaw"])):
			_stats[&"returned_to_spot"] += 1
	var combatant: Combatant = _combatant(entity.net_id)
	if combatant == null or record.health <= 0 or location.is_empty():
		return
	var elapsed: int = maxi(now - saved_at, 0) if now > 0 and saved_at > 0 else 0
	var regen: int = CombatCatalog.rules().health_regen_per_s
	combatant.health = mini(combatant.max_health, record.health + regen * elapsed)


func _can_return(entity: NetEntity, record: ProgressRecord, config: ServerConfig, now: int, saved_at: int) -> bool:
	var location: Dictionary = record.location
	if location.is_empty() or now <= 0 or saved_at <= 0 or now - saved_at >= RETURN_WINDOW_S:
		return false
	if String(location.get("zone_id", "")) != config.zone_id or int(location.get("channel", -1)) != config.channel:
		return false
	if bool(location.get("in_combat", true)) or record.health == 0:
		return false
	var spot := Vector3(float(location.get("x", 0.0)), float(location.get("y", 0.0)), float(location.get("z", 0.0)))
	var safe: SafeAreas = _zone.get_safe_areas()
	if safe != null:
		for realm: int in NetProtocol.Realm.values():
			if realm != NetProtocol.Realm.NONE and realm != entity.realm and safe.contains_own(realm, spot):
				return false
	return true


# The /atascado (/stuck) timer (§8): the saved one, with its key ("character:<id>"), in the UnstuckTracker; expired
# ones are discarded from the record.
func _restore_timers(entity: NetEntity, player: PlayerProgress, s: int) -> void:
	var now: int = _platform.now_unix() if _platform != null else 0
	if now <= 0 or not player.persistent:
		return
	for key: String in player.record.timers.keys():
		if player.record.timers[key] <= now:
			player.record.timers.erase(key)
	if player.record.timers.has(TIMER_UNSTUCK) and _zone != null:
		_zone.get_unstuck().set_ready_at(_zone.unstuck_key_of(entity),
				PlayerProgress.ready_tick_for(player.record.timers[TIMER_UNSTUCK], now, s))


# --- Rewards (§6.2) --------------------------------------------------------------------------

# The session of whoever can collect a reward: with a [PlayerProgress] (a player with a peer, also the body that stays
# after a combat exit), without the mark of a GM command and not an invisible GM (plataforma.md P7b: it also does no
# damage and does not count in the circle); null with a platform and --fake-players.
func _collector(net_id: int) -> _Session:
	if _rewards_blocked:
		_stats[&"rewards_blocked"] += 1
		return null
	var session: _Session = _sessions.get(net_id)
	if session == null:
		return null
	var entity: NetEntity = _entity(net_id)
	# Neither one marked by a GM command nor an invisible GM collects (§6.2; plataforma.md §9.1).
	if entity == null or entity.gm_forced or entity.gm_invisible:
		return null
	return session


func _pay_merits(session: _Session, amount: int, reason: int, ref_kind: int, ref_id: int, source: int,
		s: int) -> void:
	_stats[&"merits"] += session.player.gain_currency(Currency.Code.MERITS, amount, reason, ref_kind, ref_id)
	_grant_xp(session, amount * ProgressionRules.XP_PER_MERIT, source, s)


# Adds XP; if it levels up: the level on the entity (the following SPAWNs), the LEVEL_UP and the critical save (§6.3).
# PROGRESS_UPDATE goes out in flush with what was gained.
func _grant_xp(session: _Session, amount: int, source: int, s: int) -> void:
	if amount <= 0:
		return
	var result: ProgressionRules.XpResult = session.player.add_xp(amount, source)
	_stats[&"xp"] += result.applied
	if result.levels_gained <= 0:
		return
	_stats[&"level_ups"] += 1
	var entity: NetEntity = _entity(session.net_id)
	if entity != null:
		entity.level = result.level
	if level_up_sink.is_valid():
		level_up_sink.call(session.net_id, result.level, s)
	if _saver != null and session.player.persistent:
		_saver.mark_critical(session.net_id, CRITICAL_LEVEL_UP)
	_log("Progreso: net_id %d (%s) sube al nivel %d" % [session.net_id, _who(session.player), result.level])


# The saved capture timers (§8), in ticks of this session: expired ones were already removed by registration.
func _restore_capture_timers(session: _Session, s: int) -> void:
	var now: int = _platform.now_unix() if _platform != null else 0
	if now <= 0 or not session.player.persistent:
		return
	var timers: Dictionary[String, int] = session.player.record.timers
	for key: String in timers:
		if key.begins_with(TIMER_CAPTURE_PREFIX):
			session.capture_ready[key] = PlayerProgress.ready_tick_for(timers[key], now, s)


# The u32 fingerprint of a text id (the ref_id of an NPC or a fortress, §5.2).
func _ref_id(text_id: StringName) -> int:
	if not _ref_ids.has(text_id):
		_ref_ids[text_id] = HandoffTicket.zone_key_of(String(text_id))
	return _ref_ids[text_id]


static func _who(player: PlayerProgress) -> String:
	return "personaje %d" % player.character_id if player.persistent else "efímero"


# --- Internal -------------------------------------------------------------------------------------

func _entity(net_id: int) -> NetEntity:
	return _zone.get_registry().get_entity(net_id) if _zone != null and _zone.get_registry() != null else null


func _combatant(net_id: int) -> Combatant:
	if _zone == null or _zone.get_combat() == null:
		return null
	var combatant: Combatant = _zone.get_combat().get_combatant(net_id)
	return combatant if combatant != null and combatant.get_character() != null else null


# Requests a block if few remain and none is in flight.
func _check_ids() -> void:
	if _platform == null or _block_pending or not _ids.needs_block():
		return
	_block_pending = true
	_stats[&"block_requests"] += 1
	_platform.request_id_block()


# §7.2: the appearance is valid for the record's race and the character's realm; otherwise, the race's default (or, if
# the race does not belong to that realm, the realm's folk's), with a warning. Race and appearance are read-only: the
# change only lives in the zone.
func _check_appearance(record: ProgressRecord, claimed: ClaimedCharacter) -> void:
	var catalog: AppearanceCatalog = AppearanceCatalog.shared()
	var appearance: CharacterAppearance = CharacterAppearance.decode(record.appearance)
	if appearance != null and appearance.validate(catalog, claimed.realm, record.race_id):
		return
	var race_index: int = catalog.race_index(record.race_id)
	var race: RaceDefinition = catalog.races[race_index] if race_index >= 0 else null
	if race == null or race.realm != RealmCatalog.id_of_code(claimed.realm):
		race = catalog.race_for_realm(RealmCatalog.id_of_code(claimed.realm))
		race_index = catalog.race_index(race.id) if race != null else -1
	var fallback: CharacterAppearance = CharacterAppearance.default_for(catalog, race_index)
	_stats[&"appearance_replaced"] += 1
	if fallback == null:
		_alert("la apariencia del personaje %d no vale y su reino no tiene raza: se deja como está"
				% claimed.character_id)
		return
	_alert("la apariencia del personaje %d no vale para %s: se usa la de por defecto de %s" % [claimed.character_id,
			record.race_id, race.id])
	record.race_id = race.id
	record.appearance = fallback.encode()


# What the body of [param net_id] contributes to the snapshot of its progress; null if it no longer has a body or
# progress.
func _live_of(net_id: int) -> PlayerProgress.Live:
	var player: PlayerProgress = _players.get(net_id)
	if _zone == null or player == null:
		return null
	var entity: NetEntity = _zone.get_registry().get_entity(net_id)
	var character: PlayerCharacter = entity.get_character() if entity != null else null
	var combatant: Combatant = _zone.get_combat().get_combatant(net_id) if _zone.get_combat() != null else null
	if character == null or combatant == null:
		return null
	var tick: int = _zone.get_tick()
	var config: ServerConfig = _zone.get_config()
	var position: Vector3 = entity.get_position()
	var live := PlayerProgress.Live.new()
	live.location = {
		"zone_id": config.zone_id if config != null else "",
		"channel": config.channel if config != null else 0,
		"x": PlayerState.to_f32(position.x), "y": PlayerState.to_f32(position.y),
		"z": PlayerState.to_f32(position.z), "yaw": PlayerState.to_f32(character.yaw),
		"in_combat": combatant.is_in_combat(tick),
	}
	live.health = -1 if combatant.health >= combatant.max_health else maxi(combatant.health, 0)
	live.active_weapon_slot = 1 if character.combat.is_second_slot() else 0
	var elapsed_ticks: int = maxi(tick - player.arrival_tick, 0)
	live.played_seconds = player.played_base + elapsed_ticks / maxi(Engine.physics_ticks_per_second, 1)
	live.now_unix = _platform.now_unix() if _platform != null else 0
	return live


func _alert(text: String) -> void:
	push_warning("[Eldmark] Progreso: alerta: %s" % text)
	_log("Progreso: alerta: %s" % text)


func _log(text: String) -> void:
	if log_sink.is_valid():
		log_sink.call(text)
	else:
		print("[Eldmark] %s" % text)
