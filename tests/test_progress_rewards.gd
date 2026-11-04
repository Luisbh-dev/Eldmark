extends TestCase
## Tests for rewards (docs/progresion.md §6.2 and §6.3; §15, P5c): merits for a persistent victim of another
## realm with its ledger entry and its XP; killing a fake player or an NPC grants no merits; an NPC with two contributors pays
## both; two captures within 30 min pay one (also after leaving and coming back); objective merits are the seconds
## in the active circle; a character flagged by a GM command ([member NetEntity.gm_forced], what
## [code]/gm teleport[/code] and [code]/gm visible[/code] do, plataforma.md P7b) gets no capture, merits or NPC pay until
## it respawns, and afterwards it does; an invisible GM in the circle gets no capture pay (plataforma.md P7b); what a fort command causes ([code]fort_capture_speed[/code],
## [code]fort_owner[/code] and [code]fort_kill_captain[/code]) pays nobody; with [code]--fake-players[/code] and
## a platform, nothing; and a level-up sends LEVEL_UP only to the owner and their realm, sets the level on the entity and is
## critical. Without a platform, ephemeral players are paid for NPCs in memory and PvP between ephemeral players gives nothing.
## [br][br]
## A network-less [ZoneServer] on the flat zone with the test fort from [FortressFixture] (2 s capture and
## consolidation), with no NPC spawners, advanced quickly with [FortressFixture.Stepper]; the characters are
## peers set up by hand with their claim from [FakeZonePlatform] and a transport that records what is sent to them. Deaths
## are triggered with their damage ledger ([DamageLedger]) already written, as combat leaves it.

const VARDHEIM: int = NetProtocol.Realm.VARDHEIM
const SOLMARCH: int = NetProtocol.Realm.SOLMARCH
const FORTRESS: StringName = FortressFixture.FORTRESS_ID
const ZONE_ID: String = "test_world"
## The Unix time of the fake platform.
const NOW: int = 1_800_000_000
const KEY_HEX: String = "02b7825be38fdd5396a4a058286884eaf93a9df85b874f78b4010a76103fb858"
const GOLD: int = Currency.Code.GOLD
const MERITS: int = Currency.Code.MERITS
## The fingerprint of [code]hollow[/code] (progresion.md §5.2).
const HOLLOW_REF: int = 3021413298


## A transport that connects nothing and records what the server sends to each peer (excluding SNAPSHOTs).
class RecordingTransport:
	extends NetTransport

	## peer_id -> [bytes, …] in order.
	var sent: Dictionary[int, Array] = {}

	func send(peer_id: int, _channel: int, bytes: PackedByteArray) -> Error:
		if NetMessages.peek_type(bytes) == NetProtocol.MSG_SNAPSHOT:
			return OK
		if not sent.has(peer_id):
			sent[peer_id] = []
		sent[peer_id].append(bytes)
		return OK


var _viewport: SubViewport = null
var _world: Node3D = null
var _server: ZoneServer = null
var _platform: FakeZonePlatform = null
var _stepper: FortressFixture.Stepper = null
var _recorder: RecordingTransport = null


func after_each() -> void:
	if is_instance_valid(_stepper):
		_stepper.get_parent().remove_child(_stepper)
		_stepper.free()
	if is_instance_valid(_server):
		_server._transport = null
		_server.get_parent().remove_child(_server)
		_server.free()
	if is_instance_valid(_recorder):
		_recorder.free()
	if is_instance_valid(_viewport):
		_viewport.get_parent().remove_child(_viewport)
		_viewport.free()
	_stepper = null
	_server = null
	_recorder = null
	_platform = null
	_viewport = null
	_world = null
	await wait_process_frames()


# --- Setup ------------------------------------------------------------------------------------

## The flat zone with the test fort and the network-less server. With [param with_platform], the fake platform
## with its clock at [constant NOW], already started and alive, and the first block of ids received; [param fake_players] is
## the configuration's [code]--fake-players[/code] (the server does not create them: [ServerMain] does that).
func _start(with_platform: bool, fake_players: int = 0) -> bool:
	_viewport = SubViewport.new()
	_viewport.own_world_3d = true
	_viewport.size = Vector2i(64, 64)
	tree.root.add_child(_viewport)
	_world = ZoneFixture.build_flat_zone(_viewport)
	FortressFixture.add_fortress(_world, FortressFixture.make_definition())
	FortressFixture.add_respawn_points(_world)
	var config := ServerConfig.new()
	config.zone_id = ZONE_ID
	config.max_players = 16
	config.no_dummies = true
	config.no_npcs = true
	config.fake_players = fake_players
	var keys: Dictionary[int, PackedByteArray] = {2: KEY_HEX.hex_decode()}
	if with_platform:
		config.platform_url = "http://fake"
		config.save_interval_s = 600
		_platform = FakeZonePlatform.new()
		_platform.name = "Platform"
		_platform.log_sink = func(_text: String) -> void: pass
		_platform.fake_now_unix = NOW
		_viewport.add_child(_platform)
	_server = ZoneServer.new()
	_server.name = "ZoneServer"
	_server.log_enabled = false
	_viewport.add_child(_server)
	await wait_physics_frames(3)
	var provider: AuthProvider = DevAuthProvider.new()
	if with_platform:
		var finished: Array = []
		_platform.startup_finished.connect(func(ok: bool, error: String) -> void: finished.append([ok, error]))
		_platform.start(config, {"token": "token", "ticket_keys": keys})
		for _i: int in 120:
			if not finished.is_empty():
				break
			await wait_process_frames()
		if not assert_eq(finished, [[true, ""]], "the fake platform starts"):
			return false
		var tickets := TicketAuthProvider.new(_platform, config.world_id, config.zone_id, config.channel, keys)
		tickets.log_sink = func(_text: String) -> void: pass
		provider = tickets
	if not assert_eq(_server.start(config, _world, null, provider, _platform), OK, "the server starts"):
		return false
	_progress().log_sink = func(_text: String) -> void: pass
	_server.set_physics_process(false)
	_recorder = RecordingTransport.new()
	_server._transport = _recorder
	_stepper = FortressFixture.Stepper.new()
	_stepper.server = _server
	_viewport.add_child(_stepper)
	if with_platform:
		_platform.go_live()
		var ready: bool = await _advance_until(func() -> bool: return _progress().get_ids().available() > 0)
		if not assert_true(ready, "the first block of ids arrives"):
			return false
	return true


func _progress() -> ProgressService:
	return _server.get_progress()


func _advance(ticks: int) -> void:
	_stepper.remaining += ticks
	while _stepper.remaining > 0:
		await tree.physics_frame


## Advances 2 ticks at a time (with frames in between for the platform's responses) until [param condition] is met
## or [param max_ticks] have passed.
func _advance_until(condition: Callable, max_ticks: int = 600) -> bool:
	var elapsed: int = 0
	while elapsed < max_ticks:
		if condition.call():
			return true
		await _advance(2)
		await wait_process_frames()
		elapsed += 2
	return bool(condition.call())


## Registers character [param character_id] of [param realm] on the fake platform and has it join with
## peer [param peer_id] like a real join (claim, [method ProgressService.prepare], LOADING and
## CLIENT_READY). Returns the peer, already in the world.
func _join(peer_id: int, character_id: int, realm: int) -> ServerPeer:
	_platform.add_character(character_id, character_id * 10, &"player", realm, {})
	return await _enter(peer_id, _claim(character_id))


## Sets up a peer like a real join with [param claimed] (with a platform) or ephemeral for [param realm] (without one)
## and waits for it to join.
func _enter(peer_id: int, claimed: ClaimedCharacter, realm: int = VARDHEIM) -> ServerPeer:
	var peer := ServerPeer.new(peer_id)
	peer.state = ServerPeer.State.LOADING
	peer.realm = claimed.realm if claimed != null else realm
	peer.display_name = claimed.display_name if claimed != null else "Prueba%d" % peer_id
	peer.loading_since_tick = _server.get_tick()
	_server._peers[peer_id] = peer
	if claimed != null:
		peer.claimed = claimed
		assert_true(_progress().prepare(peer_id, claimed), "the record is prepared")
	_server._pending_ready.append(peer_id)
	await _advance(1)
	assert_not_null(peer.entity, "peer %d enters the world" % peer_id)
	return peer


## The next claim of [param character_id] on the fake platform, with the JSON round trip.
func _claim(character_id: int) -> ClaimedCharacter:
	var answer: Array = _platform._claim_answer({"character_id": str(character_id), "ticket_id": "1"})
	return ClaimedCharacter.from_claim(JSON.parse_string(JSON.stringify(answer[1])))


## [param peer] leaves (like a CLIENT_LEAVE) and waits for the platform to answer its final save.
func _leave(peer: ServerPeer) -> void:
	var saves_before: int = _platform.sent(PlatformEvent.KIND_SAVE).size()
	_server._mark_leaving(peer)
	await _advance(1)
	await _advance_until(func() -> bool:
		return _platform.sent(PlatformEvent.KIND_SAVE).size() > saves_before \
				and _server.get_saver().pending_count() == 0)
	_server._peers.erase(peer.peer_id)


## Kills [param victim] on the current tick with the damage ledger [param damage] ({attacker: damage}) already written and
## [param killer] as the author (0 = the environment): DEATH and, with an author, KILL with the ledger's assistants, as in
## combat.
func _kill(victim: int, killer: int, damage: Dictionary) -> void:
	var combatant: Combatant = _server.get_combat().get_combatant(victim)
	var tick: int = _server.get_tick()
	for attacker: int in damage:
		combatant.ledger.record(tick, attacker, int(damage[attacker]))
	_server.get_combat()._die(combatant, tick, killer, 0)


## An NPC of definition [param id] (from the Hollow) standing still at [param position].
func _npc(id: StringName, position: Vector3 = Vector3(0.0, 0.0, 10.0)) -> int:
	var definition: NpcDefinition = NpcCatalog.get_definition(id)
	return _server.add_npc(NpcBrain.new(NpcBrain.Mode.STILL), definition.display_name, RealmCatalog.NEUTRAL_CODE,
			position, 0.0, false, definition)


## A fake player of [param realm] standing still at [param position].
func _fake(realm: int, position: Vector3 = Vector3(0.0, 0.0, -10.0)) -> int:
	var net_id: int = _server.add_fake_player(CombatFixture.ScriptBrain.new(1), realm)
	_server.teleport(net_id, position)
	return net_id


func _player(peer: ServerPeer) -> PlayerProgress:
	return _progress().get_player(peer.entity.net_id)


func _wallet(peer: ServerPeer, currency: int) -> int:
	return _player(peer).record.wallets[currency]


func _xp(peer: ServerPeer) -> int:
	return _player(peer).record.xp_total


func _state() -> FortressState:
	return _server.get_fortresses().get_fortress_state(FORTRESS)


## The captain falls in combat at the hands of [param realm] and waits for [param realm] to capture with whoever is in the
## circle (and, with [param garrison], for its garrison to arrive). Advances 6 ticks at a time without waiting for the platform.
func _capture(realm: int, garrison: bool = true) -> bool:
	assert_true(_server.get_fortresses().on_captain_died(FORTRESS, _server.get_tick(), realm), "the captain falls")
	var captured: bool = await _advance_fast_until(func() -> bool: return _state().owner == realm, 400)
	if not captured:
		return false
	if garrison:
		return await _advance_fast_until(func() -> bool:
			return _state().phase == FortressState.Phase.GARRISONED, 400)
	return true


## Advances 6 ticks at a time (one physics frame each) until [param condition] is met or [param max_ticks]
## have passed.
func _advance_fast_until(condition: Callable, max_ticks: int) -> bool:
	var elapsed: int = 0
	while elapsed < max_ticks and not condition.call():
		await _advance(6)
		elapsed += 6
	return bool(condition.call())


## The messages of [param type] sent to [param peer_id].
func _messages(peer_id: int, type: int) -> Array[PackedByteArray]:
	var found: Array[PackedByteArray] = []
	for bytes: PackedByteArray in _recorder.sent.get(peer_id, []):
		if NetMessages.peek_type(bytes) == type:
			found.append(bytes)
	return found


## The LEVEL_UPs sent to [param peer_id].
func _level_ups(peer_id: int) -> Array[NetMessages.EntityEvent]:
	var found: Array[NetMessages.EntityEvent] = []
	for bytes: PackedByteArray in _messages(peer_id, NetProtocol.MSG_ENTITY_EVENT):
		var event: NetMessages.EntityEvent = NetMessages.EntityEvent.decode(bytes)
		if event != null and event.event == NetMessages.EntityEvent.Kind.LEVEL_UP:
			found.append(event)
	return found


## The ledger entries of the operations in the [code]progress[/code] section of the last applied save of
## [param character_id], with their [code]kind[/code]: [code][{kind, currency, delta, reason, ref_kind, ref_id}][/code].
func _saved_entries(character_id: int) -> Array[Dictionary]:
	var entries: Array[Dictionary] = []
	var progress: Dictionary = _platform.applied(character_id).get("progress", {})
	for op: Dictionary in progress.get("ops", []):
		for entry: Dictionary in op.get("ledger", []):
			entries.append({"kind": int(op["kind"]), "currency": int(entry["currency"]),
					"delta": int(entry["delta"]), "reason": int(entry["reason"]),
					"ref_kind": int(entry["ref_kind"]), "ref_id": String(entry["ref_id"])})
	return entries


## [param net_id] dies (console) and respawns as soon as it can (waves are 10 s long in a zone with a fort).
func _die_and_respawn(net_id: int) -> void:
	_server.console_command("kill %d" % net_id)
	await _advance(2)
	var combatant: Combatant = _server.get_combat().get_combatant(net_id)
	await _advance(maxi(combatant.respawn_tick - _server.get_tick() - 6, 0))
	assert_eq(_server.get_combat().request_respawn(net_id, 0, _server.get_tick() + 1),
			CombatDirector.RespawnRequestResult.ACCEPTED, "asks to respawn")
	await _advance(10)
	assert_true(combatant.is_alive(), "has respawned")


# --- Data -------------------------------------------------------------------------------------

func test_npc_rewards_are_the_design_values_and_contributors_need_ten_percent() -> void:
	var expected: Dictionary = {
		&"hollow": [40, 2], &"realm_guard": [60, 3], &"ford_captain": [400, 50], &"realm_captain": [400, 50],
		&"gate_guardian": [0, 0],
	}
	for id: StringName in expected:
		var definition: NpcDefinition = NpcCatalog.get_definition(id)
		if assert_not_null(definition, "%s exists" % id):
			assert_eq([definition.xp_reward, definition.gold_reward], expected[id], "%s: XP and gold from §6.2" % id)
	assert_eq(NpcCatalog.get_errors(), PackedStringArray(), "the NPC catalog has no errors")
	assert_eq(HandoffTicket.zone_key_of("hollow"), HOLLOW_REF, "the fingerprint of hollow (§5.2)")
	var ledger := DamageLedger.new(99)
	ledger.record(10, 7, 1500)
	ledger.record(20, 3, 900)
	ledger.record(30, 5, 100)
	ledger.record(40, 99, 500)
	assert_eq(ledger.contributors(40), PackedInt32Array([3, 7]), "at least 10 % damage share, by id; the victim does not count")
	assert_eq(ledger.contributors(10 + DamageLedger.WINDOW_TICKS), PackedInt32Array([3, 5]),
			"only the 900-tick window (the one at 1500 is no longer there)")
	assert_eq(DamageLedger.new(1).contributors(0), PackedInt32Array(), "no damage, nobody")


# --- PvP and NPCs ---------------------------------------------------------------------------------

func test_merits_of_a_persistent_enemy_victim_give_a_ledger_entry_and_xp() -> void:
	if not await _start(true):
		return
	var ana: ServerPeer = await _join(1, 101, VARDHEIM)
	var bruno: ServerPeer = await _join(2, 102, SOLMARCH)
	var cai: ServerPeer = await _join(3, 103, VARDHEIM)
	if ana == null or ana.entity == null or bruno.entity == null or cai.entity == null:
		return
	var ana_id: int = ana.entity.net_id
	var cai_id: int = cai.entity.net_id
	_kill(bruno.entity.net_id, ana_id, {ana_id: 700, cai_id: 300})
	assert_eq([_wallet(ana, MERITS), _player(ana).record.realm_points, _xp(ana)], [10, 10, 100],
			"the kill: 10 merits, 10 realm points and 100 XP")
	assert_eq([_wallet(cai, MERITS), _player(cai).record.realm_points, _xp(cai)], [5, 5, 50],
			"the assist: 5 merits and 50 XP")
	assert_eq(_wallet(ana, GOLD), 0, "PvP gives no gold")
	assert_eq([_wallet(bruno, MERITS), _xp(bruno)], [0, 0], "the victim gets nothing")
	# To the owner: WALLET_UPDATE of the merits with their reason and PROGRESS_UPDATE with what was earned (grouped per flush).
	await _advance(12)
	var wallet: ProgressMessages.WalletUpdate = null
	for bytes: PackedByteArray in _messages(1, NetProtocol.MSG_WALLET_UPDATE):
		var update: ProgressMessages.WalletUpdate = ProgressMessages.WalletUpdate.decode(bytes)
		if update != null and update.currency == MERITS and update.delta != 0:
			wallet = update
	if assert_not_null(wallet, "the WALLET_UPDATE of the merits arrives"):
		assert_eq([wallet.balance, wallet.delta, wallet.reason], [10, 10, EconomyReason.PVP_KILL])
	var progress: ProgressMessages.ProgressUpdate = ProgressMessages.ProgressUpdate.decode(
			_messages(1, NetProtocol.MSG_PROGRESS_UPDATE)[-1])
	assert_eq([progress.gained, progress.source, progress.realm_points], [100, ProgressMessages.XpSource.PVP, 10],
			"the PROGRESS_UPDATE of the kill")
	# A fake player of another realm and an NPC grant no merits (the NPC does give its XP and gold).
	var fake: int = _fake(SOLMARCH)
	_kill(fake, ana_id, {ana_id: 1000})
	assert_eq([_wallet(ana, MERITS), _xp(ana)], [10, 100], "killing a fake player gives nothing")
	var hollow: int = _npc(&"hollow")
	_kill(hollow, ana_id, {ana_id: 2500})
	assert_eq([_wallet(ana, MERITS), _xp(ana), _wallet(ana, GOLD)], [10, 140, 2],
			"an NPC: 40 XP and 2 gold, no merits")
	# The save carries the aggregated ledger entries in a GAMEPLAY, with their references.
	await _leave(ana)
	var entries: Array[Dictionary] = _saved_entries(101)
	assert_true(entries.has({"kind": EconomyOp.Kind.GAMEPLAY, "currency": MERITS, "delta": 10,
			"reason": EconomyReason.PVP_KILL, "ref_kind": LedgerEntry.RefKind.CHARACTER, "ref_id": "102"}),
			"the kill's ledger entry with the victim (%s)" % [entries])
	assert_true(entries.has({"kind": EconomyOp.Kind.GAMEPLAY, "currency": GOLD, "delta": 2,
			"reason": EconomyReason.NPC_KILL, "ref_kind": LedgerEntry.RefKind.NPC, "ref_id": str(HOLLOW_REF)}),
			"the Hollow's gold with its fingerprint")
	var saved: Dictionary = _platform.applied(101).get("progress", {})
	assert_eq([int(saved.get("xp_total", -1)), int(saved.get("realm_points", -1))], [140, 10], "the snapshot")


func test_an_npc_with_two_contributors_pays_both_and_not_the_one_under_ten_percent() -> void:
	if not await _start(true):
		return
	var ana: ServerPeer = await _join(1, 111, VARDHEIM)
	var cai: ServerPeer = await _join(2, 113, VARDHEIM)
	var dani: ServerPeer = await _join(3, 114, SOLMARCH)
	if ana == null or ana.entity == null or cai.entity == null or dani.entity == null:
		return
	var hollow: int = _npc(&"hollow")
	# Ana lands the killing blow with 60 %, Cai does 36 % and Dani 4 %.
	_kill(hollow, ana.entity.net_id, {ana.entity.net_id: 1500, cai.entity.net_id: 900, dani.entity.net_id: 100})
	assert_eq([_xp(ana), _wallet(ana, GOLD)], [40, 2], "the one who finishes it off is paid in full")
	assert_eq([_xp(cai), _wallet(cai, GOLD)], [40, 2], "the other contributor too, in full")
	assert_eq([_xp(dani), _wallet(dani, GOLD)], [0, 0], "with under 10 %, nothing")
	assert_eq([_wallet(ana, MERITS), _wallet(cai, MERITS)], [0, 0], "no merits")
	# An NPC killed by the environment with player damage in the window also pays that player (no KILL).
	var guard: int = _npc(&"realm_guard")
	_kill(guard, 0, {cai.entity.net_id: 800})
	assert_eq([_xp(cai), _wallet(cai, GOLD)], [100, 5], "the guard: 60 XP and 3 gold")
	assert_eq(_progress().get_stats()["npc_rewards"], 3, "three payouts")


func test_without_platform_ephemerals_collect_npcs_in_memory_and_pvp_gives_nothing() -> void:
	if not await _start(false):
		return
	var ana: ServerPeer = await _enter(1, null, VARDHEIM)
	var bruno: ServerPeer = await _enter(2, null, SOLMARCH)
	if ana == null or ana.entity == null or bruno.entity == null:
		return
	assert_false(_player(ana).persistent, "without a platform, ephemeral")
	_kill(bruno.entity.net_id, ana.entity.net_id, {ana.entity.net_id: 1000})
	assert_eq([_wallet(ana, MERITS), _xp(ana)], [0, 0], "the ephemeral victim gives no merits or XP")
	var hollow: int = _npc(&"hollow")
	_kill(hollow, ana.entity.net_id, {ana.entity.net_id: 2500})
	assert_eq([_xp(ana), _wallet(ana, GOLD)], [40, 2], "the NPC pays in memory")
	await _advance(12)
	var progress: ProgressMessages.ProgressUpdate = ProgressMessages.ProgressUpdate.decode(
			_messages(1, NetProtocol.MSG_PROGRESS_UPDATE)[-1])
	assert_eq([progress.gained, progress.source], [40, ProgressMessages.XpSource.NPC], "and tells the owner")


# --- Captures and objective -------------------------------------------------------------------------

func test_two_captures_in_thirty_minutes_pay_one_and_objective_merits_are_circle_seconds() -> void:
	if not await _start(true):
		return
	var circle: Vector3 = FortressFixture.circle_center()
	var ana: ServerPeer = await _join(1, 121, VARDHEIM)
	var sol: ServerPeer = await _join(2, 122, SOLMARCH)
	if ana == null or ana.entity == null or sol.entity == null:
		return
	var ana_id: int = ana.entity.net_id
	_server.teleport(ana_id, circle)
	_server.teleport(sol.entity.net_id, circle + Vector3(30.0, 0.0, 0.0))
	if not assert_true(await _capture(VARDHEIM), "Vardheim captures"):
		return
	var scores: ScoreKeeper = _server.get_scores()
	var merits: int = _wallet(ana, MERITS)
	assert_eq(scores.get_entry(ana_id).captures, 1)
	assert_eq(_wallet(ana, GOLD), ProgressService.CAPTURE_GOLD, "20 gold from the capture")
	assert_true(merits >= 2, "objective merits for the seconds in the active circle (%d)" % merits)
	@warning_ignore("integer_division")
	assert_eq(merits, scores.get_entry(ana_id).circle_ticks / 60, "one per whole second in the active circle")
	assert_eq(_player(ana).record.realm_points, merits, "objective merits raise the realm points")
	assert_eq(_xp(ana), ProgressService.CAPTURE_XP + 10 * merits, "300 XP from the capture and 10 per merit")
	var key: String = ProgressService.TIMER_CAPTURE_PREFIX + String(FORTRESS)
	assert_eq(_player(ana).record.timers.get(key, 0), NOW + ProgressService.CAPTURE_COOLDOWN_S,
			"the capture:<id> timer expires after 30 min")
	assert_eq(_server.get_saver().get_stats()["criticals_by_reason"].get("capture", 0), 1, "getting paid is critical")
	# Solmarch takes it and Vardheim retakes it within 30 min: the second pays nothing.
	_server.teleport(ana_id, circle + Vector3(30.0, 0.0, 0.0))
	_server.teleport(sol.entity.net_id, circle)
	if not assert_true(await _capture(SOLMARCH), "Solmarch takes it"):
		return
	assert_eq(_wallet(sol, GOLD), ProgressService.CAPTURE_GOLD, "Solmarch gets paid for theirs")
	_server.teleport(sol.entity.net_id, circle + Vector3(30.0, 0.0, 0.0))
	_server.teleport(ana_id, circle)
	if not assert_true(await _capture(VARDHEIM, false), "Vardheim retakes it"):
		return
	assert_eq(scores.get_entry(ana_id).captures, 2, "the capture counts on the scoreboard")
	assert_eq(_wallet(ana, GOLD), ProgressService.CAPTURE_GOLD, "but two captures within 30 min pay one")
	assert_eq(_progress().get_stats()["captures_on_cooldown"], 1)
	assert_eq(_xp(ana), ProgressService.CAPTURE_XP + 10 * _wallet(ana, MERITS), "only the objective merits")
	# Leaves and comes back after 10 min: the timer comes back with them.
	await _leave(ana)
	_platform.fake_now_unix = NOW + 600
	ana = await _enter(3, _claim(121))
	if ana == null or ana.entity == null:
		return
	assert_eq(_player(ana).record.timers.get(key, 0), NOW + ProgressService.CAPTURE_COOLDOWN_S, "saved")
	_progress().on_capture(FORTRESS, VARDHEIM, PackedInt32Array([ana.entity.net_id]), _server.get_tick())
	assert_eq(_wallet(ana, GOLD), ProgressService.CAPTURE_GOLD, "after 10 min it still does not pay")
	# After 30 min it pays again.
	await _leave(ana)
	_platform.fake_now_unix = NOW + ProgressService.CAPTURE_COOLDOWN_S + 1
	ana = await _enter(4, _claim(121))
	if ana == null or ana.entity == null:
		return
	assert_false(_player(ana).record.timers.has(key), "the expired one does not come back")
	_progress().on_capture(FORTRESS, VARDHEIM, PackedInt32Array([ana.entity.net_id]), _server.get_tick())
	assert_eq(_wallet(ana, GOLD), 2 * ProgressService.CAPTURE_GOLD, "after 30 min, it pays")
	assert_eq(_player(ana).record.timers.get(key, 0), NOW + 2 * ProgressService.CAPTURE_COOLDOWN_S + 1,
			"and counts again")
	# Another realm in the list (this does not happen: the list belongs to the capturer) gets no pay, even without a timer for that fort.
	var sol_gold: int = _wallet(sol, GOLD)
	_progress().on_capture(&"otro_fuerte", VARDHEIM, PackedInt32Array([sol.entity.net_id]), _server.get_tick())
	assert_eq(_wallet(sol, GOLD), sol_gold, "only the capturing realm gets paid")
	_progress().on_capture(&"otro_fuerte", SOLMARCH, PackedInt32Array([sol.entity.net_id]), _server.get_tick())
	assert_eq(_wallet(sol, GOLD), sol_gold + ProgressService.CAPTURE_GOLD, "the timer is per fort")


# --- GM flags and forced changes --------------------------------------------------------------------

func test_a_gm_forced_character_collects_nothing_until_it_respawns() -> void:
	if not await _start(true):
		return
	var circle: Vector3 = FortressFixture.circle_center()
	var ana: ServerPeer = await _join(1, 131, VARDHEIM)
	var cai: ServerPeer = await _join(2, 133, VARDHEIM)
	var bruno: ServerPeer = await _join(3, 132, SOLMARCH)
	var berta: ServerPeer = await _join(4, 134, SOLMARCH)
	if ana == null or ana.entity == null or cai.entity == null or bruno.entity == null or berta.entity == null:
		return
	var ana_id: int = ana.entity.net_id
	var cai_id: int = cai.entity.net_id
	# What /gm teleport and /gm visible will do (plataforma.md P7b): move it to the circle and flag it.
	_server.teleport(ana_id, circle)
	ana.entity.gm_forced = true
	_server.teleport(cai_id, circle + Vector3(1.0, 0.0, 0.0))
	_server.teleport(bruno.entity.net_id, circle + Vector3(30.0, 0.0, 0.0))
	_server.teleport(berta.entity.net_id, circle + Vector3(30.0, 0.0, 2.0))
	if not assert_true(await _capture(VARDHEIM, false), "Vardheim captures"):
		return
	assert_eq(_wallet(cai, GOLD), ProgressService.CAPTURE_GOLD, "Cai gets paid for the capture")
	assert_true(_wallet(cai, MERITS) > 0, "and objective merits")
	assert_eq([_wallet(ana, GOLD), _wallet(ana, MERITS), _xp(ana)], [0, 0, 0],
			"the flagged one gets no capture pay or objective merits")
	_kill(bruno.entity.net_id, ana_id, {ana_id: 1000})
	assert_eq([_wallet(ana, MERITS), _xp(ana)], [0, 0], "nor those of a kill")
	var hollow: int = _npc(&"hollow")
	_kill(hollow, ana_id, {ana_id: 2000, cai_id: 500})
	assert_eq([_wallet(ana, GOLD), _xp(ana)], [0, 0], "nor an NPC")
	assert_eq(_wallet(cai, GOLD), ProgressService.CAPTURE_GOLD + 2, "the other contributor does")
	_progress().on_capture(FORTRESS, VARDHEIM, PackedInt32Array([ana_id]), _server.get_tick())
	assert_eq(_wallet(ana, GOLD), 0, "even if it arrived in the list")
	# On respawn, the flag goes away and it gets paid again.
	await _die_and_respawn(ana_id)
	assert_false(ana.entity.gm_forced, "respawning removes the flag")
	_kill(berta.entity.net_id, ana_id, {ana_id: 1000})
	assert_eq([_wallet(ana, MERITS), _xp(ana)], [10, 100], "it now gets paid for a kill")
	var second: int = _npc(&"hollow", Vector3(0.0, 0.0, 14.0))
	_kill(second, ana_id, {ana_id: 2500})
	assert_eq([_wallet(ana, GOLD), _xp(ana)], [2, 140], "and an NPC")
	_progress().on_capture(FORTRESS, VARDHEIM, PackedInt32Array([ana_id]), _server.get_tick())
	assert_eq(_wallet(ana, GOLD), 2 + ProgressService.CAPTURE_GOLD, "and a capture")


func test_an_invisible_gm_in_the_circle_collects_no_capture() -> void:
	# plataforma.md §9.1 (P7b): an invisible GM does not count in the circle and gets no pay (§6.2).
	if not await _start(true):
		return
	var circle: Vector3 = FortressFixture.circle_center()
	var ana: ServerPeer = await _join(1, 141, VARDHEIM)
	var gema: ServerPeer = await _join(2, 142, VARDHEIM)
	var bruno: ServerPeer = await _join(3, 143, SOLMARCH)
	if ana == null or ana.entity == null or gema.entity == null or bruno.entity == null:
		return
	_server.teleport(ana.entity.net_id, circle)
	_server.teleport(gema.entity.net_id, circle + Vector3(1.0, 0.0, 0.0))
	_server.teleport(bruno.entity.net_id, circle + Vector3(30.0, 0.0, 0.0))
	_server.set_gm_invisible(gema.entity, true)
	if not assert_true(await _capture(VARDHEIM, false), "Vardheim captures"):
		return
	assert_eq(_wallet(ana, GOLD), ProgressService.CAPTURE_GOLD, "Ana gets paid for the capture")
	assert_true(_wallet(ana, MERITS) > 0, "and objective merits")
	assert_eq([_wallet(gema, GOLD), _wallet(gema, MERITS), _xp(gema)], [0, 0, 0],
			"the invisible one gets no capture pay or objective merits")
	var entry: ScoreKeeper.Entry = _server.get_scores().get_entry(gema.entity.net_id)
	assert_true(entry == null or (entry.captures == 0 and entry.circle_ticks == 0), "nor does it add to the capture or the circle")
	_progress().on_capture(FORTRESS, VARDHEIM, PackedInt32Array([gema.entity.net_id]), _server.get_tick())
	assert_eq(_wallet(gema, GOLD), 0, "even if it arrived in the list")
	_kill(bruno.entity.net_id, gema.entity.net_id, {gema.entity.net_id: 1000})
	assert_eq([_wallet(gema, MERITS), _xp(gema)], [0, 0], "nor a kill")


func test_fort_commands_pay_nobody_and_a_real_captain_kill_does() -> void:
	if not await _start(true):
		return
	var circle: Vector3 = FortressFixture.circle_center()
	var ana: ServerPeer = await _join(1, 141, VARDHEIM)
	if ana == null or ana.entity == null:
		return
	var ana_id: int = ana.entity.net_id
	var fortresses: FortressController = _server.get_fortresses()
	# A captain killed in combat is a real change: it pays whoever killed it.
	var captain: int = _npc(&"ford_captain", circle + Vector3(4.0, 0.0, 4.0))
	fortresses.register_captain(FORTRESS, captain)
	_kill(captain, ana_id, {ana_id: 30000})
	assert_eq([_xp(ana), _wallet(ana, GOLD)], [400, 50], "the real captain: 400 XP and 50 gold")
	assert_eq(_state().phase, FortressState.Phase.VULNERABLE)
	# fort_reset and fort_kill_captain: a captain killed by the command pays nothing, not even to whoever damaged it.
	_server.console_command("fort_reset")
	await _advance(2)
	var second: int = _npc(&"ford_captain", circle + Vector3(4.0, 0.0, -4.0))
	fortresses.register_captain(FORTRESS, second)
	_server.get_combat().get_combatant(second).ledger.record(_server.get_tick(), ana_id, 20000)
	_server.console_command("fort_kill_captain")
	await _advance(2)
	assert_true(_server.get_combat().get_combatant(second).is_dead(), "the command kills it")
	assert_eq([_xp(ana), _wallet(ana, GOLD)], [400, 50], "its death pays nothing")
	# The capture that follows fort_kill_captain is forced: no capture pay or objective merits.
	_server.teleport(ana_id, circle)
	await _advance_fast_until(func() -> bool: return _state().owner == VARDHEIM, 400)
	assert_eq(_state().owner, VARDHEIM, "Vardheim captures after the command")
	assert_eq([_xp(ana), _wallet(ana, GOLD), _wallet(ana, MERITS)], [400, 50, 0], "without getting paid anything")
	# fort_owner neither.
	_server.console_command("fort_owner solmarch")
	await _advance(12)
	assert_eq([_xp(ana), _wallet(ana, GOLD), _wallet(ana, MERITS)], [400, 50, 0], "fort_owner pays nothing")
	# With fort_capture_speed ≠ 1, even if the captain falls in combat, the capture is forced.
	await _advance_fast_until(func() -> bool: return _state().phase == FortressState.Phase.GARRISONED, 400)
	_server.console_command("fort_capture_speed 20")
	if not assert_true(await _capture(VARDHEIM, false), "Vardheim captures at x20"):
		return
	assert_eq([_xp(ana), _wallet(ana, GOLD), _wallet(ana, MERITS)], [400, 50, 0], "fort_capture_speed pays nothing")
	assert_eq(_progress().get_stats()["captures_paid"], 0, "no capture paid")


func test_fake_players_with_the_platform_pay_nothing_and_say_so() -> void:
	if not await _start(true, 2):
		return
	assert_true(_progress().rewards_blocked(), "--fake-players with a platform: no rewards")
	var lines: Array[String] = []
	var probe := ProgressService.new()
	probe.log_sink = func(text: String) -> void: lines.append(text)
	probe.setup(_server, _platform, null, null)
	assert_true(lines.has(ProgressService.FAKE_PLAYERS_TEXT), "and it says so in the log at startup")
	var circle: Vector3 = FortressFixture.circle_center()
	var ana: ServerPeer = await _join(1, 151, VARDHEIM)
	var bruno: ServerPeer = await _join(2, 152, SOLMARCH)
	if ana == null or ana.entity == null or bruno.entity == null:
		return
	var ana_id: int = ana.entity.net_id
	_kill(bruno.entity.net_id, ana_id, {ana_id: 1000})
	_kill(_npc(&"hollow"), ana_id, {ana_id: 2500})
	_server.teleport(ana_id, circle)
	if not assert_true(await _capture(VARDHEIM, false), "Vardheim captures"):
		return
	assert_eq([_xp(ana), _wallet(ana, GOLD), _wallet(ana, MERITS)], [0, 0, 0], "nothing at all")
	assert_eq(_server.get_scores().get_entry(ana_id).captures, 1, "the scoreboard does count")


# --- Level-up -----------------------------------------------------------------------------------

func test_a_level_up_goes_to_the_owner_and_its_realm_only_and_is_critical() -> void:
	if not await _start(true):
		return
	var ana: ServerPeer = await _join(1, 161, VARDHEIM)
	var cai: ServerPeer = await _join(2, 163, VARDHEIM)
	var sol: ServerPeer = await _join(3, 162, SOLMARCH)
	if ana == null or ana.entity == null or cai.entity == null or sol.entity == null:
		return
	var ana_id: int = ana.entity.net_id
	# Everyone sees each other (the default interest policy): the ally and the enemy both have Ana as relevant.
	await _advance(12)
	assert_true(cai.relevant.get(ana_id, false) and sol.relevant.get(ana_id, false), "both see Ana")
	var criticals_before: int = _server.get_saver().get_stats()["criticals_by_reason"].get("level_up", 0)
	var saves_before: int = _platform.sent(PlatformEvent.KIND_SAVE).size()
	# 400 from the captain does not reach 500; with 300 from a capture it goes up to 2.
	_kill(_npc(&"ford_captain"), ana_id, {ana_id: 30000})
	assert_eq(_player(ana).record.level, 1, "400 XP: level 1")
	assert_eq(_level_ups(1), [] as Array[NetMessages.EntityEvent], "without leveling up there is no LEVEL_UP")
	_progress().on_capture(FORTRESS, VARDHEIM, PackedInt32Array([ana_id]), _server.get_tick())
	assert_eq([_player(ana).record.level, _xp(ana)], [2, 700], "700 XP: level 2")
	assert_eq(ana.entity.level, 2, "the level on the entity, for the following SPAWNs")
	for peer_id: int in [1, 2]:
		var events: Array[NetMessages.EntityEvent] = _level_ups(peer_id)
		if assert_eq(events.size(), 1, "a LEVEL_UP to peer %d" % peer_id):
			assert_eq([events[0].net_id, events[0].level], [ana_id, 2])
	assert_eq(_level_ups(3).size(), 0, "it does not reach the enemy")
	assert_eq(_server.get_saver().get_stats()["criticals_by_reason"].get("level_up", 0), criticals_before + 1,
			"leveling up is critical")
	var saved: bool = await _advance_until(func() -> bool:
		return _platform.sent(PlatformEvent.KIND_SAVE).size() > saves_before \
				and int(_platform.applied(161).get("progress", {}).get("level", 0)) == 2, 60)
	assert_true(saved, "the critical save goes out right away with level 2")
	await _advance(12)
	var progress: ProgressMessages.ProgressUpdate = ProgressMessages.ProgressUpdate.decode(
			_messages(1, NetProtocol.MSG_PROGRESS_UPDATE)[-1])
	assert_eq([progress.level, progress.xp_in_level, progress.gained], [2, 200, 700],
			"the PROGRESS_UPDATE with the new level and what was earned")
	# A SPAWN of Ana toward her realm carries 2; toward the enemy, 0.
	var to_ally: NetMessages.EntitySpawn = NetMessages.EntitySpawn.decode(ana.entity.encode_spawn(_server.get_tick(),
			false, VARDHEIM))
	var to_enemy: NetMessages.EntitySpawn = NetMessages.EntitySpawn.decode(ana.entity.encode_spawn(
			_server.get_tick(), false, SOLMARCH))
	assert_eq([to_ally.level, to_enemy.level], [2, 0], "the level only toward her realm")
