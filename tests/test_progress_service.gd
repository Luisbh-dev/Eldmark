extends TestCase
## Tests for the inventory in the zone (docs/progression.md §4, §8 and §9; §15, P5b): the join with the
## inventory's [ProgressService.Loadout] and the active slot; equipping and unequipping without resetting reuse timers;
## CONSUME on commit and not on interrupt; CAMP_REFILL by total and at the refill cadence, and the full-bag warning
## once per join; charges [code]min(15, bag)[/code]; requests before the world, malformed ones,
## consecutive syncs and RATE with its warning; a client that sends 10,000 SPLITs and merges (no event, ids bounded
## by RATE, another player keeps drinking and saving); /atascado (stuck) restored by its key; a dead player is saved so it
## can respawn (health and camp on return); and the squire who puts the bow in WEAPON_2, switches to it, unequips
## WEAPON_1, dies and respawns with the bow active, with a following save that passes S5.
## [br][br]
## A network-less [ZoneServer] on the flat zone of [ZoneFixture], advanced quickly with [FortressFixture.Stepper], with
## peers set up by hand (like a real join: LOADING, CLIENT_READY and, with a platform, the claim and
## [method ProgressService.prepare]), their inputs in their [InputQueue] and a transport that records what is sent to them.
## Those that save use [FakeZonePlatform] (platform.md §14.3).

const VARDHEIM: int = NetProtocol.Realm.VARDHEIM
const SOLMARCH: int = NetProtocol.Realm.SOLMARCH
const LOADOUT: int = NetMessages.EntityEvent.Kind.LOADOUT
const BAG: int = InventoryState.ContainerId.BAG
const EQUIPMENT: int = InventoryState.ContainerId.EQUIPMENT
const MOVE: int = InventoryOps.Op.MOVE
const SPLIT: int = InventoryOps.Op.SPLIT
const DESTROY: int = InventoryOps.Op.DESTROY
const NO_SLOT: int = ProgressMessages.NO_SLOT
const ZONE_ID: String = "test_world"
## The Unix time of the fake platform.
const NOW: int = 1_800_000_000
const KEYS: Dictionary = {2: "02b7825be38fdd5396a4a058286884eaf93a9df85b874f78b4010a76103fb858"}
## The Vardheim camp for the tests that ask for it: it covers its two spawn points.
const CAMP: Vector3 = Vector3(-20.0, 0.0, 0.0)
const CAMP_RADIUS: float = 24.0


## A transport that connects nothing and records what the server sends to each peer (excluding SNAPSHOTs), with the tick.
class RecordingTransport:
	extends NetTransport

	var server: ZoneServer = null
	## peer_id -> [[tick, bytes], …] in order.
	var sent: Dictionary[int, Array] = {}

	func send(peer_id: int, _channel: int, bytes: PackedByteArray) -> Error:
		if NetMessages.peek_type(bytes) == NetProtocol.MSG_SNAPSHOT:
			return OK
		if not sent.has(peer_id):
			sent[peer_id] = []
		sent[peer_id].append([server.get_tick() if server != null else 0, bytes])
		return OK


var _viewport: SubViewport = null
var _world: Node3D = null
var _server: ZoneServer = null
var _platform: FakeZonePlatform = null
var _stepper: FortressFixture.Stepper = null
var _recorder: RecordingTransport = null
var _events: Array[NetMessages.EntityEvent] = []
var _involved: Array[PackedInt32Array] = []
var _request_id: int = 0


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
	_events.clear()
	_involved.clear()
	_request_id = 0
	await wait_process_frames()


# --- Setup ------------------------------------------------------------------------------------

## The flat zone (with the Vardheim camp if [param camp]) and the network-less server; with [param with_platform], the
## fake platform already started and live, and the first block of ids received.
func _start(with_platform: bool, camp: bool = false) -> bool:
	_viewport = SubViewport.new()
	_viewport.own_world_3d = true
	_viewport.size = Vector2i(64, 64)
	tree.root.add_child(_viewport)
	_world = ZoneFixture.build_flat_zone(_viewport)
	if camp:
		NpcRig.add_safe_area(_world, &"vardheim", CAMP, CAMP_RADIUS)
	var config := ServerConfig.new()
	config.zone_id = ZONE_ID
	config.max_players = 16
	config.no_dummies = true
	config.debug_commands = true
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
	var keys: Dictionary[int, PackedByteArray] = {2: String(KEYS[2]).hex_decode()}
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
	_server.get_progress().log_sink = func(_text: String) -> void: pass
	_server.set_physics_process(false)
	_recorder = RecordingTransport.new()
	_recorder.server = _server
	_server._transport = _recorder
	_stepper = FortressFixture.Stepper.new()
	_stepper.server = _server
	_viewport.add_child(_stepper)
	_server.get_combat().event_emitted.connect(func(event: NetMessages.EntityEvent,
			involved: PackedInt32Array) -> void:
		_events.append(event)
		_involved.append(involved))
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


## Advances 2 ticks at a time until [param condition] is met (with a platform, its responses arrive between
## frames) or [param max_ticks] have passed.
func _advance_until(condition: Callable, max_ticks: int = 600) -> bool:
	var elapsed: int = 0
	while elapsed < max_ticks:
		if condition.call():
			return true
		await _advance(2)
		await wait_process_frames()
		elapsed += 2
	return bool(condition.call())


## Advances to the first tick that is a multiple of the camp refill (60) after the current one, inclusive.
func _advance_to_camp_tick() -> int:
	var interval: int = CombatDirector.RECHARGE_INTERVAL_TICKS
	var target: int = (_server.get_tick() / interval + 1) * interval
	await _advance(target - _server.get_tick())
	return target


## Sets up a peer like a real join: LOADING (with [param template_id] as the template pending from
## LOADOUT_SELECT), with a platform its claim and [method ProgressService.prepare], and CLIENT_READY: it appears at the
## end of the next tick.
func _enter(peer_id: int, realm: int, claimed: ClaimedCharacter = null, template_id: int = -1) -> ServerPeer:
	var peer := ServerPeer.new(peer_id)
	peer.state = ServerPeer.State.LOADING
	peer.realm = claimed.realm if claimed != null else realm
	peer.display_name = claimed.display_name if claimed != null else "Prueba%d" % peer_id
	peer.loading_since_tick = _server.get_tick()
	peer.pending_template_id = template_id
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
	var body: Variant = JSON.parse_string(JSON.stringify(answer[1]))
	return ClaimedCharacter.from_claim(body)


## [param peer] leaves (like a CLIENT_LEAVE) and waits for the platform to answer its final save.
func _leave(peer: ServerPeer) -> void:
	var saves_before: int = _platform.sent(PlatformEvent.KIND_SAVE).size() if _platform != null else 0
	_server._mark_leaving(peer)
	await _advance(1)
	if _platform != null:
		await _advance_until(func() -> bool:
			return _platform.sent(PlatformEvent.KIND_SAVE).size() > saves_before \
					and _server.get_saver().pending_count() == 0)
	_server._peers.erase(peer.peer_id)


## An input from [param peer] for tick [param tick] with [param buttons], looking at [param yaw].
func _push_input(peer: ServerPeer, tick: int, buttons: int, yaw: float) -> void:
	var input := PlayerInput.new()
	input.tick = tick
	input.buttons = buttons
	input.look_yaw = yaw
	peer.input_queue.push(input.quantized(), 0, _server.get_tick() + 1)


## Presses [param button] on ticks [param at] and [param at] + 1 and releases it on [param at] + 2 (the substitute inputs
## repeat the last input: the neutral one closes it).
func _press(peer: ServerPeer, button: int, at: int, yaw: float = 0.0) -> void:
	_push_input(peer, at, button, yaw)
	_push_input(peer, at + 1, button, yaw)
	_push_input(peer, at + 2, 0, yaw)


func _player(net_id: int) -> PlayerProgress:
	return _progress().get_player(net_id)


func _inventory(net_id: int) -> InventoryState:
	return _player(net_id).record.inventory


func _uid(net_id: int, container: int, slot: int) -> int:
	var item: ItemInstance = _inventory(net_id).get_item(container, slot)
	return item.uid if item != null else 0


func _def(net_id: int, container: int, slot: int) -> StringName:
	var item: ItemInstance = _inventory(net_id).get_item(container, slot)
	return item.def_id if item != null else &""


func _count(net_id: int, container: int, slot: int) -> int:
	var item: ItemInstance = _inventory(net_id).get_item(container, slot)
	return item.count if item != null else 0


func _combat(net_id: int) -> CombatState:
	return _server.get_registry().get_entity(net_id).get_character().combat


func _combatant(net_id: int) -> Combatant:
	return _server.get_combat().get_combatant(net_id)


func _weapon(weapon_name: StringName) -> int:
	return CombatCatalog.weapon_id(weapon_name)


## Sends an INVENTORY_REQUEST from [param peer] through the zone's network input (with the reliable-message
## limiter) and returns its request_id.
func _request(peer: ServerPeer, op: int, from_container: int, from_slot: int, to_container: int, to_slot: int,
		count: int, uid: int) -> int:
	_request_id += 1
	var request: InventoryOps.Request = InventoryOps.make_request(op, from_container, from_slot, to_container,
			to_slot, count, uid)
	_server._on_packet_received(peer.peer_id,
			ProgressMessages.InventoryRequest.from_request(_request_id, request).encode())
	return _request_id


func _messages(peer_id: int, type: int) -> Array[PackedByteArray]:
	var found: Array[PackedByteArray] = []
	for entry: Array in _recorder.sent.get(peer_id, []):
		if NetMessages.peek_type(entry[1]) == type:
			found.append(entry[1])
	return found


func _deltas(peer_id: int) -> Array[ProgressMessages.InventoryDelta]:
	var found: Array[ProgressMessages.InventoryDelta] = []
	for bytes: PackedByteArray in _messages(peer_id, NetProtocol.MSG_INVENTORY_DELTA):
		found.append(ProgressMessages.InventoryDelta.decode(bytes))
	return found


## The response to request [param request_id] (the last one), or null.
func _answer(peer_id: int, request_id: int) -> ProgressMessages.InventoryDelta:
	var found: ProgressMessages.InventoryDelta = null
	for delta: ProgressMessages.InventoryDelta in _deltas(peer_id):
		if delta != null and delta.request_id == request_id:
			found = delta
	return found


## The server's changes with [param reason], as [code][tick, delta][/code].
func _server_changes(peer_id: int, reason: int) -> Array[Array]:
	var found: Array[Array] = []
	for entry: Array in _recorder.sent.get(peer_id, []):
		if NetMessages.peek_type(entry[1]) != NetProtocol.MSG_INVENTORY_DELTA:
			continue
		var delta: ProgressMessages.InventoryDelta = ProgressMessages.InventoryDelta.decode(entry[1])
		if delta != null and delta.request_id == 0 and delta.reason == reason:
			found.append([entry[0], delta])
	return found


func _notice_texts(peer_id: int) -> PackedStringArray:
	var texts := PackedStringArray()
	for bytes: PackedByteArray in _messages(peer_id, NetProtocol.MSG_NOTICE):
		texts.append(NetMessages.Notice.decode(bytes).text)
	return texts


func _loadouts(net_id: int, owner_only: bool = false) -> Array[NetMessages.EntityEvent]:
	var found: Array[NetMessages.EntityEvent] = []
	for i: int in _events.size():
		var event: NetMessages.EntityEvent = _events[i]
		if event.event == LOADOUT and event.net_id == net_id and (not owner_only or not _involved[i].is_empty()):
			found.append(event)
	return found


## What S5 (§13.3) checks on the snapshot [param progress] without the database: no repeated uids, container 0–1, unique
## slots, bag below bag_slots and equipment 0–1, definition, quantity, durability, rarity 0 and no affixes, and in
## equipment one weapon per slot with the active one armed (I10). Empty if everything is valid.
func _s5_errors(progress: Dictionary) -> PackedStringArray:
	var errors := PackedStringArray()
	var db: ItemDatabase = ItemDatabase.shared()
	var uids: Dictionary[int, bool] = {}
	var slots: Dictionary[Vector2i, bool] = {}
	var bag_slots: int = int(progress.get("bag_slots", 0))
	for value: Variant in progress.get("items", []):
		var entry: Dictionary = value
		var item: ItemInstance = ItemInstance.from_dictionary(entry, db)
		if item == null:
			errors.append("objeto que no vale: %s" % entry)
			continue
		var position := Vector2i(int(entry["container"]), int(entry["slot"]))
		if uids.has(item.uid) or slots.has(position):
			errors.append("uid o ranura repetidos: %s" % entry)
		uids[item.uid] = true
		slots[position] = true
		var definition: ItemDefinition = db.get_definition(item.def_id)
		match position.x:
			BAG:
				if position.y >= bag_slots:
					errors.append("ranura de bolsa fuera de bag_slots: %s" % entry)
			EQUIPMENT:
				if position.y > 1 or definition.category != ItemDefinition.Category.WEAPON:
					errors.append("en el equipo, solo armas en 0–1: %s" % entry)
			_:
				errors.append("contenedor que no vale: %s" % entry)
		if item.rarity != 0 or not item.affixes.is_empty():
			errors.append("rareza o afijos en la fase 5: %s" % entry)
	var active := Vector2i(EQUIPMENT, int(progress.get("active_weapon_slot", -1)))
	if not slots.has(active):
		errors.append("la ranura activa %d no tiene arma (I10)" % active.y)
	return errors


func _progress_record(template: StringName, realm: int) -> ProgressRecord:
	var record: ProgressRecord = ProgressRecord.new_character()
	var catalog: AppearanceCatalog = AppearanceCatalog.shared()
	var race: RaceDefinition = catalog.race_for_realm(RealmCatalog.id_of_code(realm))
	record.race_id = race.id
	record.appearance = CharacterAppearance.default_for(catalog, catalog.race_index(race.id)).encode()
	record.starter_template_id = template
	return record


# --- Join -------------------------------------------------------------------------------------

func test_the_arrival_uses_the_inventory_loadout_and_the_active_slot() -> void:
	if not await _start(false):
		return
	var bow: int = _weapon(&"bow")
	var sword: int = _weapon(&"sword_shield")
	# Without a platform, ephemeral (§9.4): the marksman kit it requested with LOADOUT_SELECT before CLIENT_READY.
	var ana: ServerPeer = await _enter(201, VARDHEIM, null, CombatCatalog.template_id(&"marksman"))
	var net_id: int = ana.entity.net_id
	var player: PlayerProgress = _player(net_id)
	assert_true(player != null and not player.persistent, "ephemeral, with an inventory")
	assert_eq([_def(net_id, EQUIPMENT, 0), _def(net_id, EQUIPMENT, 1)], [&"bow_vado", &"sword_shield_vado"],
			"the marksman's weapons in slots 0 and 1")
	assert_eq([_def(net_id, BAG, 0), _count(net_id, BAG, 0), _def(net_id, BAG, 1), _count(net_id, BAG, 1)],
			[&"potion_health", 3, &"potion_stamina", 2], "the camp potions in the bag")
	var combat: CombatState = _combat(net_id)
	assert_eq([combat.weapon_id, combat.alt_weapon_id, combat.is_second_slot()], [bow, sword, false],
			"in hand, slot 0")
	assert_eq(combat.consumable_charges, CombatState.pack_charges(3, 2), "charges = potions in the bag")
	assert_eq(_combatant(net_id).template_id, 0, "no current template: the inventory's equipment")
	var loadouts: Array[NetMessages.EntityEvent] = _loadouts(net_id)
	if assert_eq(loadouts.size(), 2, "LOADOUT to the owner and the public one"):
		assert_eq([loadouts[0].template_id, loadouts[0].weapon_1, loadouts[0].weapon_2, loadouts[0].charges],
				[0, bow, sword, CombatState.pack_charges(3, 2)], "template 0 = the inventory's equipment")
	var catalog: AppearanceCatalog = AppearanceCatalog.shared()
	var race: RaceDefinition = catalog.race_for_realm(RealmCatalog.id_of_code(VARDHEIM))
	assert_eq(ana.entity.level, 1, "level on the entity")
	assert_eq(ana.entity.appearance, CharacterAppearance.default_for(catalog, catalog.race_index(race.id)).encode(),
			"and the default appearance of its people")
	# What it receives, in order: its SPAWN, the whole inventory, its two currencies and its progress.
	var types: Array[int] = []
	for entry: Array in _recorder.sent.get(201, []):
		types.append(NetMessages.peek_type(entry[1]))
	var spawn_at: int = types.find(NetProtocol.MSG_ENTITY_SPAWN)
	var full_at: int = types.find(NetProtocol.MSG_INVENTORY_FULL)
	assert_true(spawn_at >= 0 and full_at > spawn_at, "INVENTORY_FULL after its own SPAWN: %s" % [types])
	var pages: Array[ProgressMessages.InventoryFull] = []
	for bytes: PackedByteArray in _messages(201, NetProtocol.MSG_INVENTORY_FULL):
		pages.append(ProgressMessages.InventoryFull.decode(bytes))
	var assembled: InventoryState = ProgressMessages.InventoryFull.assemble(pages)
	assert_true(assembled != null and assembled.equals(_inventory(net_id)), "the FULL is the server's inventory")
	assert_eq(pages[0].revision, player.revision, "with its revision")
	var wallets: Array[PackedByteArray] = _messages(201, NetProtocol.MSG_WALLET_UPDATE)
	assert_eq(wallets.size(), 2, "one WALLET_UPDATE per currency")
	for bytes: PackedByteArray in wallets:
		var wallet: ProgressMessages.WalletUpdate = ProgressMessages.WalletUpdate.decode(bytes)
		assert_eq([wallet.balance, wallet.delta, wallet.reason], [0, 0, 0], "the initial state")
	var progress: Array[PackedByteArray] = _messages(201, NetProtocol.MSG_PROGRESS_UPDATE)
	if assert_eq(progress.size(), 1, "one PROGRESS_UPDATE"):
		var update: ProgressMessages.ProgressUpdate = ProgressMessages.ProgressUpdate.decode(progress[0])
		assert_eq([update.level, update.xp_in_level, update.xp_to_next, update.gained, update.source],
				[1, 0, 500, 0, ProgressMessages.XpSource.STATE], "level 1, 500 away from the next")
	# LOADOUT_SELECT no longer changes anything: no pending template and no warning, and it respawns with its equipment.
	var strikes: int = ana.strikes_total
	_server._on_packet_received(201, NetMessages.LoadoutSelect.make(CombatCatalog.template_id(&"squire")).encode())
	assert_eq([ana.pending_template_id, ana.strikes_total], [-1, strikes], "nothing pending and no warning")
	_server.get_combat().kill(_combatant(net_id), _server.get_tick() + 1)
	await _advance(1)
	var timing: CombatTiming = _server.get_combat_timing()
	await _advance(maxi(_combatant(net_id).respawn_tick - _server.get_tick(), 0) + 1)
	_events.clear()
	_involved.clear()
	assert_eq(_server.get_combat().request_respawn(net_id, 0, _server.get_tick() + 1),
			CombatDirector.RespawnRequestResult.ACCEPTED)
	await _advance(2)
	assert_true(_combatant(net_id).is_alive(), "respawns (deadline %d)" % timing.respawn)
	combat = _combat(net_id)
	assert_eq([combat.weapon_id, combat.alt_weapon_id, combat.consumable_charges],
			[bow, sword, CombatState.pack_charges(3, 2)], "with its equipment, not the squire's")
	var after: Array[NetMessages.EntityEvent] = _loadouts(net_id, true)
	assert_true(not after.is_empty() and after[0].template_id == 0, "and its LOADOUT, with template 0")

	# A saved record (prepared like the claim) with slot 1 active and 400 health.
	var record: ProgressRecord = _progress_record(&"marksman", VARDHEIM)
	var next_uid: Array[int] = [900_000]
	StarterKit.grant(record.inventory, &"marksman", ItemDatabase.shared(), func() -> int:
		next_uid[0] += 1
		return next_uid[0])
	record.starter_granted = true
	record.active_weapon_slot = 1
	record.health = 400
	record.location = {"zone_id": ZONE_ID, "channel": 0, "x": 5.0, "y": 0.0, "z": 5.0, "yaw": 0.0,
			"in_combat": false}
	var claimed := ClaimedCharacter.new()
	claimed.character_id = 3001
	claimed.account_id = 9
	claimed.world_id = 1
	claimed.realm = VARDHEIM
	claimed.display_name = "Bruno"
	claimed.lease_id = FakeZonePlatform.FAKE_LEASE_PREFIX + "000000003001"
	claimed.progress = JSON.parse_string(JSON.stringify(record.to_claim_dictionary(1_700_000_000)))
	var bruno: ServerPeer = await _enter(202, VARDHEIM, claimed)
	var bruno_id: int = bruno.entity.net_id
	combat = _combat(bruno_id)
	assert_eq([combat.weapon_id, combat.alt_weapon_id, combat.is_second_slot()], [sword, bow, true],
			"joins with slot 1 active (bit0 of combat_flags2)")
	assert_eq(_combatant(bruno_id).health, 400, "with its health (no clock, no regeneration)")
	assert_true(bruno.entity.get_position().distance_to(Vector3(5.0, 0.0, 5.0)) > 10.0,
			"and in an RvR zone, at its realm's camp, not where it was saved")


# --- Equip ------------------------------------------------------------------------------------

func test_equipping_and_unequipping_keep_the_cooldowns() -> void:
	if not await _start(false):
		return
	var bow: int = _weapon(&"bow")
	var sword: int = _weapon(&"sword_shield")
	var ana: ServerPeer = await _enter(211, VARDHEIM)
	var net_id: int = ana.entity.net_id
	assert_eq([_def(net_id, EQUIPMENT, 0), _def(net_id, BAG, 0)], [&"sword_shield_vado", &"bow_vado"],
			"the squire: the sword equipped and the bow in the bag")
	var s: int = _server.get_tick()
	var combat: CombatState = _combat(net_id)
	var sword_ready := PackedInt64Array([s + 900, s + 1000, s + 1100])
	for i: int in 3:
		combat.ability_ready[i] = sword_ready[i]
	CombatDirector.commit_state(ana.entity.get_character())
	var revision: int = _player(net_id).revision
	# Equip the bow in WEAPON_2.
	_events.clear()
	_involved.clear()
	var id: int = _request(ana, MOVE, BAG, 0, EQUIPMENT, 1, 0, _uid(net_id, BAG, 0))
	await _advance(1)
	var delta: ProgressMessages.InventoryDelta = _answer(211, id)
	if assert_not_null(delta, "it responds"):
		assert_eq([delta.result, delta.revision, delta.reason, delta.entries.size()],
				[InventoryOps.Result.OK, revision + 1, 0, 2], "OK, the next revision and both slots")
	combat = _combat(net_id)
	assert_eq([combat.weapon_id, combat.alt_weapon_id], [sword, bow], "the bow in slot 2")
	assert_eq(combat.ability_ready.slice(0, 3), sword_ready, "without touching the sword's reuse timers")
	assert_eq(combat.ability_ready.slice(3, 6), PackedInt64Array([0, 0, 0]), "the bow, with none")
	var loadouts: Array[NetMessages.EntityEvent] = _loadouts(net_id)
	if assert_eq(loadouts.size(), 2, "LOADOUT to the owner and, with new weapons, to the others"):
		assert_eq([loadouts[0].template_id, loadouts[0].weapon_1, loadouts[0].weapon_2], [0, sword, bow])
	# The bow with reuse timers; unequipping it and putting it back keeps them.
	var bow_ready := PackedInt64Array([s + 2000, s + 2100, s + 2200])
	for i: int in 3:
		combat.ability_ready[3 + i] = bow_ready[i]
	CombatDirector.commit_state(ana.entity.get_character())
	id = _request(ana, MOVE, EQUIPMENT, 1, BAG, 5, 0, _uid(net_id, EQUIPMENT, 1))
	await _advance(1)
	assert_eq(_answer(211, id).result, InventoryOps.Result.OK, "unequip the bow")
	combat = _combat(net_id)
	assert_eq([combat.weapon_id, combat.alt_weapon_id], [sword, 0])
	assert_eq(combat.ability_ready.slice(3, 6), PackedInt64Array([0, 0, 0]), "no weapon in slot 2")
	id = _request(ana, MOVE, BAG, 5, EQUIPMENT, 1, 0, _uid(net_id, BAG, 5))
	await _advance(1)
	assert_eq(_answer(211, id).result, InventoryOps.Result.OK, "equip it again")
	combat = _combat(net_id)
	assert_eq(combat.ability_ready.slice(3, 6), bow_ready, "it comes back with its own")
	assert_eq(combat.ability_ready.slice(0, 3), sword_ready, "and the sword keeps its own")
	# Swap the two slots: the active one (0) now has the bow, each weapon with its own reuse timers.
	id = _request(ana, MOVE, EQUIPMENT, 0, EQUIPMENT, 1, 0, _uid(net_id, EQUIPMENT, 0))
	await _advance(1)
	assert_eq(_answer(211, id).result, InventoryOps.Result.OK, "swap the weapons")
	combat = _combat(net_id)
	assert_eq([combat.weapon_id, combat.alt_weapon_id, combat.is_second_slot()], [bow, sword, false])
	assert_eq(combat.ability_ready.slice(0, 3), bow_ready, "the bow in hand, with its own")
	assert_eq(combat.ability_ready.slice(3, 6), sword_ready, "the sword in the other, with its own")
	# Leave the active slot empty: WEAPON_REQUIRED, with the real contents of both slots.
	revision = _player(net_id).revision
	id = _request(ana, MOVE, EQUIPMENT, 0, BAG, 6, 0, _uid(net_id, EQUIPMENT, 0))
	await _advance(1)
	delta = _answer(211, id)
	assert_eq([delta.result, delta.revision], [InventoryOps.Result.WEAPON_REQUIRED, revision], "no change")
	assert_eq([delta.entries[0].container, delta.entries[0].slot, delta.entries[0].item.def_id],
			[EQUIPMENT, 0, &"bow_vado"], "the bow stays in place")
	assert_eq([delta.entries[1].container, delta.entries[1].slot, delta.entries[1].item], [BAG, 6, null])
	# In combat: NOT_NOW.
	_combatant(net_id).mark_combat(_server.get_tick())
	id = _request(ana, MOVE, EQUIPMENT, 1, BAG, 6, 0, _uid(net_id, EQUIPMENT, 1))
	await _advance(1)
	assert_eq(_answer(211, id).result, InventoryOps.Result.NOT_NOW, "equipment cannot be changed in combat")
	assert_eq(_def(net_id, EQUIPMENT, 1), &"sword_shield_vado")
	# Two requests on the same tick are applied in order of arrival (the second moves what the first moved).
	var potion: int = _uid(net_id, BAG, 1)
	var first: int = _request(ana, MOVE, BAG, 1, BAG, 3, 0, potion)
	var second: int = _request(ana, MOVE, BAG, 3, BAG, 4, 0, potion)
	assert_eq(_progress().pending_count(), 2, "queued until the end of the tick")
	await _advance(1)
	assert_eq([_answer(211, first).result, _answer(211, second).result], [InventoryOps.Result.OK,
			InventoryOps.Result.OK], "both, in order")
	assert_eq(_uid(net_id, BAG, 4), potion)
	# An invalid one adds a warning.
	var strikes: int = ana.strikes_total
	id = _request(ana, MOVE, BAG, 4, BAG, 7, 3, potion)
	await _advance(1)
	assert_eq(_answer(211, id).result, InventoryOps.Result.INVALID)
	assert_eq(ana.strikes_total, strikes + 1, "INVALID adds a warning")
	assert_eq(ana.last_strike_reason, ProgressService.STRIKE_INVALID)


# --- Consumables ------------------------------------------------------------------------------

func test_drinking_spends_a_potion_on_commit_and_not_when_interrupted() -> void:
	if not await _start(false):
		return
	var potion: AbilityTicks = CombatCatalog.ability(CombatCatalog.ability_id(&"potion_health"))
	var light: AttackTicks = CombatCatalog.attack(CombatCatalog.attack_id(&"sword_light_1"))
	var ana: ServerPeer = await _enter(221, SOLMARCH)
	var net_id: int = ana.entity.net_id
	_server.teleport(net_id, Vector3(0.0, 0.05, -1.5))
	var holds: Array[Vector3i] = []
	var brain := CombatFixture.ScriptBrain.new(1)
	brain.script_fn = func(tick: int, _position: Vector3, _yaw: float) -> PlayerInput:
		var input := PlayerInput.new()
		input.tick = tick
		for entry: Vector3i in holds:
			if tick >= entry.y and tick < entry.z:
				input.buttons |= entry.x
		return input
	var attacker: int = _server.add_fake_player(brain, VARDHEIM)
	_server.teleport(attacker, Vector3(0.0, 0.05, 0.0))
	_push_input(ana, _server.get_tick() + 1, 0, PI)
	await _advance(3)
	assert_eq(_count(net_id, BAG, 1), 3, "3 health potions in the bag")
	# A hit interrupts before commitment: neither charge nor potion is spent.
	var drink: int = _server.get_tick() + 2
	_press(ana, PlayerInput.CONSUMABLE_1, drink, PI)
	holds.append(Vector3i(PlayerInput.PRIMARY, drink + 2, drink + 4))
	assert_true(drink + 2 + light.windup_ticks < drink + potion.cast_ticks, "the hit lands before commitment")
	await _advance(drink + potion.cast_ticks + 10 - _server.get_tick())
	assert_eq(_combat(net_id).charges_of(0), 3, "an interrupted drink does not spend the charge")
	assert_eq(_count(net_id, BAG, 1), 3, "nor the potion")
	assert_eq(_server_changes(221, EconomyReason.CONSUME).size(), 0, "and there is no CONSUME")
	# Without a hit: on commit, one potion fewer from the stack in the lowest slot.
	var revision: int = _player(net_id).revision
	_combat(net_id).consumable_ready_tick = 0
	CombatDirector.commit_state(ana.entity.get_character())
	var loadouts_before: int = _loadouts(net_id).size()
	drink = _server.get_tick() + 2
	_press(ana, PlayerInput.CONSUMABLE_1, drink, PI)
	var commit: int = drink + potion.cast_ticks
	await _advance(commit - 1 - _server.get_tick())
	assert_eq(_count(net_id, BAG, 1), 3, "drinking, nothing yet")
	await _advance(1)
	assert_eq(_combat(net_id).charges_of(0), 2, "commitment spends the charge")
	assert_eq(_count(net_id, BAG, 1), 2, "and the potion, on the same tick")
	var consumed: Array[Array] = _server_changes(221, EconomyReason.CONSUME)
	if assert_eq(consumed.size(), 1, "one server INVENTORY_DELTA"):
		var change: ProgressMessages.InventoryDelta = consumed[0][1]
		assert_eq(consumed[0][0], commit, "on the commitment tick")
		assert_eq([change.revision, change.entries.size(), change.entries[0].slot, change.entries[0].item.count],
				[revision + 1, 1, 1, 2], "with the slot that changed")
	assert_eq(_loadouts(net_id).size(), loadouts_before, "the charges already add up: no LOADOUT")
	assert_eq(_player(net_id).pending_aggregate_count(), 1, "aggregated (an event with no uid)")
	# With more than 15 in the bag: after drinking, the charge goes back to 15 with a LOADOUT to the owner.
	_player(net_id).gain_items(&"potion_health", 18, EconomyReason.CAMP_REFILL)
	assert_eq(_inventory(net_id).count_of(&"potion_health"), 20)
	_combat(net_id).consumable_ready_tick = 0
	CombatDirector.commit_state(ana.entity.get_character())
	drink = _server.get_tick() + 2
	_press(ana, PlayerInput.CONSUMABLE_1, drink, PI)
	await _advance(drink + potion.cast_ticks + 1 - _server.get_tick())
	assert_eq(_inventory(net_id).count_of(&"potion_health"), 19, "one fewer")
	assert_eq(_combat(net_id).charges_of(0), 15, "charges = min(15, bag)")
	var owner: Array[NetMessages.EntityEvent] = _loadouts(net_id, true)
	assert_eq(owner[-1].charges, CombatState.pack_charges(15, 2), "with its LOADOUT to the owner")


# --- Camp -------------------------------------------------------------------------------------

func test_the_camp_refills_the_total_with_the_recharge_cadence() -> void:
	if not await _start(false, true):
		return
	var ana: ServerPeer = await _enter(231, VARDHEIM)
	var net_id: int = ana.entity.net_id
	var safe: SafeAreas = _server.get_safe_areas()
	assert_true(safe.contains_own(VARDHEIM, ana.entity.get_position()), "spawns at the camp")
	# A fake player with a template at the same camp keeps the refill from abilities.md.
	var fake: int = _server.add_fake_player(CombatFixture.ScriptBrain.new(1), VARDHEIM)
	_server.teleport(fake, CAMP + Vector3(1.0, 0.05, 0.0))
	ActionMachine.set_charges(_combat(fake), 0)
	CombatDirector.commit_state(_server.get_registry().get_entity(fake).get_character())
	# Splitting the stack gives no more: the total is still 3.
	var id: int = _request(ana, SPLIT, BAG, 1, BAG, 5, 1, _uid(net_id, BAG, 1))
	await _advance(1)
	assert_eq(_answer(231, id).result, InventoryOps.Result.OK, "split 3 into 2 and 1")
	await _advance_to_camp_tick()
	await _advance(1)
	assert_eq(_server_changes(231, EconomyReason.CAMP_REFILL).size(), 0, "splitting gives no more potions")
	assert_eq(_combat(fake).consumable_charges, CombatCatalog.template_charges(CombatCatalog.default_template_id()),
			"the fake player, with the charges of its template")
	# Destroy the stack of 1: one of 3 is missing; the charges go down with its LOADOUT.
	id = _request(ana, DESTROY, BAG, 5, NO_SLOT, NO_SLOT, 0, _uid(net_id, BAG, 5))
	await _advance(1)
	assert_eq(_answer(231, id).result, InventoryOps.Result.OK, "destroy the stack of 1")
	assert_eq(_combat(net_id).consumable_charges, CombatState.pack_charges(2, 2), "2 health potions")
	assert_eq(_loadouts(net_id, true)[-1].charges, CombatState.pack_charges(2, 2), "with its LOADOUT")
	var camp_tick: int = await _advance_to_camp_tick()
	var refills: Array[Array] = _server_changes(231, EconomyReason.CAMP_REFILL)
	if assert_eq(refills.size(), 1, "CAMP_REFILL on the refill"):
		var change: ProgressMessages.InventoryDelta = refills[0][1]
		assert_eq(refills[0][0], camp_tick, "at the refill cadence (every 60 ticks)")
		assert_eq([change.entries.size(), change.entries[0].container, change.entries[0].slot,
				change.entries[0].item.count], [1, BAG, 1, 3], "to the stack in the lowest slot, up to 3")
	assert_eq(_combat(net_id).consumable_charges, CombatState.pack_charges(3, 2), "and the charges go back to 3")
	# Full bag without stamina potions: NOTICE once per entry into the camp.
	var player: PlayerProgress = _player(net_id)
	assert_true(player.gain_items(&"bow_vado", _inventory(net_id).free_count(BAG), EconomyReason.CAMP_REFILL),
			"the bag, full of bows")
	var stamina: int = _inventory(net_id).find_uid(_uid(net_id, BAG, 2)).y
	id = _request(ana, DESTROY, BAG, stamina, NO_SLOT, NO_SLOT, 0, _uid(net_id, BAG, stamina))
	await _advance(1)
	assert_eq(_answer(231, id).result, InventoryOps.Result.OK, "without stamina potions")
	assert_true(player.gain_items(&"bow_vado", 1, EconomyReason.CAMP_REFILL), "and its slot, also full")
	await _advance_to_camp_tick()
	assert_eq(Array(_notice_texts(231)).count(ProgressService.BAG_FULL_TEXT), 1, "\"Bolsa llena\" (bag full)")
	await _advance_to_camp_tick()
	assert_eq(Array(_notice_texts(231)).count(ProgressService.BAG_FULL_TEXT), 1, "once per entry")
	_server.teleport(net_id, Vector3(15.0, 0.05, 0.0))
	await _advance_to_camp_tick()
	await _advance_to_camp_tick()
	_server.teleport(net_id, CAMP + Vector3(0.0, 0.05, 2.0))
	await _advance_to_camp_tick()
	assert_eq(Array(_notice_texts(231)).count(ProgressService.BAG_FULL_TEXT), 2, "and another one on re-entering")
	assert_eq(_inventory(net_id).count_of(&"potion_stamina"), 0, "with no room, it is not restocked")


# --- Warnings and rate limits -----------------------------------------------------------------

func test_requests_outside_the_world_malformed_syncs_and_rate_strike() -> void:
	if not await _start(false):
		return
	# Before the world (LOADING): warning, a sync too.
	var loading := ServerPeer.new(241)
	loading.state = ServerPeer.State.LOADING
	loading.realm = VARDHEIM
	loading.display_name = "Cargando"
	_server._peers[241] = loading
	var request: PackedByteArray = ProgressMessages.InventoryRequest.from_request(1,
			InventoryOps.make_request(MOVE, BAG, 0, BAG, 1, 0, 5)).encode()
	_server._on_packet_received(241, request)
	assert_eq([loading.strikes_total, loading.last_strike_reason], [1, ProgressService.STRIKE_NOT_IN_WORLD],
			"a request before the world adds a warning")
	_server._on_packet_received(241, ProgressMessages.InventorySyncRequest.new().encode())
	assert_eq(loading.strikes_total, 2, "a sync too")
	_server._peers.erase(241)
	var ana: ServerPeer = await _enter(242, VARDHEIM)
	var net_id: int = ana.entity.net_id
	# Malformed.
	_server._on_packet_received(242, request.slice(0, request.size() - 1))
	assert_eq([ana.strikes_total, ana.last_strike_reason], [1, ProgressService.STRIKE_MALFORMED], "malformed")
	# Sync: one every 5 s; a second one right after adds a warning and is not answered.
	var fulls: int = _messages(242, NetProtocol.MSG_INVENTORY_FULL).size()
	_server._on_packet_received(242, ProgressMessages.InventorySyncRequest.new().encode())
	await _advance(1)
	assert_eq(_messages(242, NetProtocol.MSG_INVENTORY_FULL).size(), fulls + 1, "one INVENTORY_FULL")
	_server._on_packet_received(242, ProgressMessages.InventorySyncRequest.new().encode())
	await _advance(1)
	assert_eq([_messages(242, NetProtocol.MSG_INVENTORY_FULL).size(), ana.strikes_total], [fulls + 1, 2],
			"the second one within 5 s: warning and no response")
	await _advance(ProgressService.SYNC_INTERVAL_TICKS)
	_server._on_packet_received(242, ProgressMessages.InventorySyncRequest.new().encode())
	await _advance(1)
	assert_eq(_messages(242, NetProtocol.MSG_INVENTORY_FULL).size(), fulls + 2, "after 5 s, yes")
	# RATE: the burst of 16 passes; the following ones get RATE immediately, and after 10 drops, they warn.
	var strikes: int = ana.strikes_total
	var uid: int = _uid(net_id, BAG, 1)
	var rate_ids: Array[int] = []
	for i: int in 30:
		_request_id += 1
		var bytes: PackedByteArray = ProgressMessages.InventoryRequest.from_request(_request_id,
				InventoryOps.make_request(MOVE, BAG, 1, BAG, 3, 0, uid)).encode()
		_progress().handle_packet(ana, bytes)
		if i >= int(ProgressService.REQUEST_BURST):
			rate_ids.append(_request_id)
	assert_eq(_progress().pending_count(), int(ProgressService.REQUEST_BURST), "16 queued")
	for request_id: int in rate_ids:
		var answer: ProgressMessages.InventoryDelta = _answer(242, request_id)
		assert_true(answer != null and answer.result == InventoryOps.Result.RATE,
				"number %d responds RATE with the real contents" % request_id)
	assert_eq(ana.strikes_total, strikes + 14 - ChatPeerState.FLOOD_FREE_DISCARDS,
			"the first 10 drops do not warn; the following ones do")
	assert_eq(ana.last_strike_reason, ProgressService.STRIKE_RATE)
	await _advance(1)
	assert_eq(_progress().get_stats()["rate_limited"], 14)


func test_ten_thousand_splits_and_merges_leave_no_event_and_others_drink_and_save() -> void:
	if not await _start(true):
		return
	_platform.add_character(2101, 7, &"player", VARDHEIM, {})
	_platform.add_character(2102, 9, &"player", VARDHEIM, {})
	var abuser: ServerPeer = await _enter(251, VARDHEIM, _claim(2101))
	var other: ServerPeer = await _enter(252, VARDHEIM, _claim(2102))
	var abuser_id: int = abuser.entity.net_id
	var other_id: int = other.entity.net_id
	await _advance_until(func() -> bool: return _server.get_saver().pending_count() == 0)
	var cheater: PlayerProgress = _player(abuser_id)
	var ids: IdAllocator = _progress().get_ids()
	var taken_before: int = ids.taken_count()
	var started: int = _server.get_tick()
	# 10,000 requests (SPLIT and merge) in 100 ticks, above the reliable-message limiter.
	var potion: StringName = &"potion_health"
	var sent: int = 0
	var other_drink: int = started + 20
	_press(other, PlayerInput.CONSUMABLE_1, other_drink)
	for _tick: int in 100:
		# With the uids it sees (its last state, even if it has already been kicked).
		var stack: ItemInstance = cheater.record.inventory.get_item(BAG, 0)
		var split_off: ItemInstance = cheater.record.inventory.get_item(BAG, 5)
		for i: int in 50:
			var split: InventoryOps.Request = InventoryOps.make_request(SPLIT, BAG, 0, BAG, 5, 1,
					stack.uid if stack != null else 1)
			var merge: InventoryOps.Request = InventoryOps.make_request(MOVE, BAG, 5, BAG, 0, 0,
					split_off.uid if split_off != null else 1)
			for request: InventoryOps.Request in [split, merge]:
				_request_id = _request_id % 0xFFFF + 1
				_progress().handle_packet(abuser, ProgressMessages.InventoryRequest.from_request(_request_id,
						request).encode())
				sent += 1
		await _advance(1)
	assert_eq(sent, 10_000)
	var elapsed_s: float = float(_server.get_tick() - started) / 60.0
	var bound: int = int(ProgressService.ID_REQUEST_BURST) + ceili(elapsed_s * 2.0)
	assert_true(ids.taken_count() - taken_before <= bound + 2,
			"ids bounded by RATE: %d taken, at most %d" % [ids.taken_count() - taken_before, bound])
	assert_true(abuser.kicked or abuser.state == ServerPeer.State.LEAVING, "and the abuser is kicked by the warnings")
	for op: EconomyOp in cheater.journal():
		assert_eq(op.kind, EconomyOp.Kind.STARTER_KIT, "splitting and merging leave no operations")
	assert_eq(cheater.pending_aggregate_count(), 0, "nor anything aggregated")
	assert_eq(cheater.record.inventory.count_of(potion), 3, "nor do they change the total")
	# The other one has drunk and saves.
	assert_eq(_inventory(other_id).count_of(potion), 2, "the other one drinks")
	_server.get_saver().mark_critical(other_id, &"prueba")
	var saved: bool = await _advance_until(func() -> bool:
		var body: Dictionary = _platform.applied(2102)
		if body.is_empty():
			return false
		for op: Variant in (body["progress"] as Dictionary)["ops"]:
			for event: Variant in (op as Dictionary)["items"]:
				if (event as Dictionary)["reason"] == EconomyReason.CONSUME:
					return true
		return false)
	assert_true(saved, "and its save, with the CONSUME, is applied")
	# Without reaching the warnings (6 requests per second, 3 of them SPLIT), RATE leaves 2 ids per second.
	_platform.add_character(2103, 11, &"player", VARDHEIM, {})
	var steady: ServerPeer = await _enter(253, VARDHEIM, _claim(2103))
	var steady_id: int = steady.entity.net_id
	await _advance_until(func() -> bool: return _server.get_saver().pending_count() == 0)
	taken_before = ids.taken_count()
	started = _server.get_tick()
	var splits_sent: int = 0
	for _round: int in 90:
		var inventory: InventoryState = _inventory(steady_id)
		var split_slot: int = -1
		for slot: int in range(3, inventory.bag_slots):
			if inventory.get_item(BAG, slot) != null:
				split_slot = slot
				break
		if split_slot >= 0:
			_request_id = _request_id % 0xFFFF + 1
			_progress().handle_packet(steady, ProgressMessages.InventoryRequest.from_request(_request_id,
					InventoryOps.make_request(MOVE, BAG, split_slot, BAG, 0, 0, _uid(steady_id, BAG, split_slot)))
					.encode())
		var free: int = -1
		for slot: int in range(3, inventory.bag_slots):
			if inventory.get_item(BAG, slot) == null and slot != split_slot:
				free = slot
				break
		_request_id = _request_id % 0xFFFF + 1
		_progress().handle_packet(steady, ProgressMessages.InventoryRequest.from_request(_request_id,
				InventoryOps.make_request(SPLIT, BAG, 0, BAG, free, 1, _uid(steady_id, BAG, 0))).encode())
		splits_sent += 1
		await _advance(20)
	elapsed_s = float(_server.get_tick() - started) / 60.0
	var taken: int = ids.taken_count() - taken_before
	assert_eq(steady.state, ServerPeer.State.IN_WORLD, "it is not kicked")
	assert_true(taken <= int(ProgressService.ID_REQUEST_BURST) + ceili(elapsed_s * 2.0) + 1 and taken < splits_sent,
			"%d SPLITs in %.0f s: %d ids, those of RATE" % [splits_sent, elapsed_s, taken])
	assert_true(_progress().get_stats()["rate_limited"] > 0, "and the rest, RATE")
	for op: EconomyOp in _player(steady_id).journal():
		assert_eq(op.kind, EconomyOp.Kind.STARTER_KIT, "no split or merge operation")
	assert_eq(_inventory(steady_id).count_of(potion), 3, "and the total does not change")


# --- Join persistence -------------------------------------------------------------------------

func test_unstuck_is_restored_by_its_key() -> void:
	if not await _start(true):
		return
	_platform.add_character(2201, 7, &"player", VARDHEIM, {})
	var ana: ServerPeer = await _enter(261, VARDHEIM, _claim(2201))
	var unstuck: UnstuckTracker = _server.get_unstuck()
	unstuck.channel_ticks = 30
	var key: String = "character:2201"
	assert_eq(_server.unstuck_key_of(ana.entity), key, "with a platform, the key is the character")
	assert_eq(_server._request_unstuck(ana), UnstuckTracker.RequestResult.STARTED)
	await _advance(40)
	var ready_at: int = unstuck.get_ready_at(key)
	assert_true(ready_at > _server.get_tick(), "the reuse timer runs by its key")
	assert_eq(unstuck.get_ready_at(NameRules.normalize_key(ana.display_name)), 0, "not by name")
	assert_eq(_player(ana.entity.net_id).record.timers.get(ProgressService.TIMER_UNSTUCK),
			NOW + ceili((ready_at - _server.get_tick()) / 60.0), "the unstuck timer with its end in Unix time")
	await _leave(ana)
	var timers: Array = (_platform.applied(2201)["progress"] as Dictionary)["timers"]
	assert_eq(timers.size(), 1, "it is saved")
	assert_eq([timers[0]["key"], int(timers[0]["ends_at_unix"])], ["unstuck", NOW + 300], "5 min from use")
	# Another zone (another tracker), 100 s later: it comes back with what is left.
	unstuck.set_ready_at(key, 0)
	_platform.fake_now_unix = NOW + 100
	ana = await _enter(262, VARDHEIM, _claim(2201))
	var arrival: int = _server.get_tick()
	assert_eq(unstuck.get_ready_at(key), arrival + 200 * 60, "restored by its key: 200 s")
	assert_eq(_server._request_unstuck(ana), UnstuckTracker.RequestResult.COOLDOWN, "and it cannot be used")
	await _leave(ana)
	# Expired: discarded on join.
	unstuck.set_ready_at(key, 0)
	_platform.fake_now_unix = NOW + 400
	ana = await _enter(263, VARDHEIM, _claim(2201))
	assert_eq(unstuck.get_ready_at(key), 0, "an expired one is not restored")
	assert_false(_player(ana.entity.net_id).record.timers.has(ProgressService.TIMER_UNSTUCK), "and it leaves the record")


func test_health_is_restored_and_the_dead_respawn_full_at_the_camp() -> void:
	if not await _start(true):
		return
	_platform.add_character(2301, 7, &"player", VARDHEIM, {})
	var ana: ServerPeer = await _enter(271, VARDHEIM, _claim(2301))
	var net_id: int = ana.entity.net_id
	_server.teleport(net_id, Vector3(5.0, 0.05, 5.0))
	_combatant(net_id).health = 600
	await _advance(2)
	await _leave(ana)
	var saved: Dictionary = _platform.applied(2301)["progress"]
	assert_eq(int(saved["health"]), 600, "health is saved")
	# It comes back 5 s later: the saved health plus the regeneration of those 5 s.
	_platform.fake_now_unix = NOW + 5
	ana = await _enter(272, VARDHEIM, _claim(2301))
	net_id = ana.entity.net_id
	var regen: int = CombatCatalog.rules().health_regen_per_s
	assert_eq(_combatant(net_id).health, mini(600 + regen * 5, _combatant(net_id).max_health),
			"with the regeneration of the offline time")
	var spawns: Array[Vector3] = ZoneFixture.VARDHEIM_SPAWNS
	var at_camp: bool = false
	for spawn: Vector3 in spawns:
		at_camp = at_camp or ana.entity.get_position().distance_to(spawn) < 0.5
	assert_true(at_camp, "at its realm's camp (RvR zone), not where it left")
	# It dies and leaves dead: it is saved with 0 and comes back with full health, at the camp.
	_server.teleport(net_id, Vector3(8.0, 0.05, -8.0))
	_server.get_combat().kill(_combatant(net_id), _server.get_tick() + 1)
	await _advance(2)
	assert_true(_combatant(net_id).is_dead(), "dead")
	await _leave(ana)
	saved = _platform.applied(2301)["progress"]
	assert_eq(int(saved["health"]), 0, "a dead player is saved with 0")
	_platform.fake_now_unix = NOW + 10
	ana = await _enter(273, VARDHEIM, _claim(2301))
	net_id = ana.entity.net_id
	assert_true(_combatant(net_id).is_alive() and _combatant(net_id).health == _combatant(net_id).max_health,
			"comes back alive and with full health")
	at_camp = false
	for spawn: Vector3 in spawns:
		at_camp = at_camp or ana.entity.get_position().distance_to(spawn) < 0.5
	assert_true(at_camp, "at the camp")


func test_a_squire_with_the_bow_in_weapon_two_respawns_with_it_and_saves_valid() -> void:
	if not await _start(true):
		return
	var catalog: AppearanceCatalog = AppearanceCatalog.shared()
	var race: RaceDefinition = catalog.race_for_realm(RealmCatalog.id_of_code(VARDHEIM))
	_platform.add_character(2401, 7, &"player", VARDHEIM, FakeZonePlatform.claim_progress(race.id,
			CharacterAppearance.default_for(catalog, catalog.race_index(race.id)).encode(), &"squire"))
	var ana: ServerPeer = await _enter(281, VARDHEIM, _claim(2401))
	var net_id: int = ana.entity.net_id
	var bow: int = _weapon(&"bow")
	assert_eq([_def(net_id, EQUIPMENT, 0), _def(net_id, BAG, 0)], [&"sword_shield_vado", &"bow_vado"],
			"the squire")
	# The bow to WEAPON_2.
	var id: int = _request(ana, MOVE, BAG, 0, EQUIPMENT, 1, 0, _uid(net_id, BAG, 0))
	await _advance(1)
	assert_eq(_answer(281, id).result, InventoryOps.Result.OK, "the bow in WEAPON_2")
	# Q: switches to the bow (predicted and valid in combat; here, from the server).
	_press(ana, PlayerInput.SWAP_WEAPON, _server.get_tick() + 2)
	var swapped: bool = await _advance_until(func() -> bool:
		var combat: CombatState = _combat(net_id)
		return combat.is_second_slot() and combat.action == CombatState.Action.NONE, 120)
	if not assert_true(swapped, "switches to the bow"):
		return
	assert_eq(_combat(net_id).weapon_id, bow)
	# Unequip WEAPON_1 (the sword): the active one is 2, so it is allowed.
	id = _request(ana, MOVE, EQUIPMENT, 0, BAG, 0, 0, _uid(net_id, EQUIPMENT, 0))
	await _advance(1)
	assert_eq(_answer(281, id).result, InventoryOps.Result.OK, "unequip the sword with the bow in hand")
	var combat: CombatState = _combat(net_id)
	assert_eq([combat.weapon_id, combat.alt_weapon_id, combat.is_second_slot()], [bow, 0, true])
	# Dies and respawns: WEAPON_1 empty, so with 2 active.
	_server.get_combat().kill(_combatant(net_id), _server.get_tick() + 1)
	await _advance(2)
	await _advance(maxi(_combatant(net_id).respawn_tick - _server.get_tick(), 0) + 1)
	assert_eq(_server.get_combat().request_respawn(net_id, 0, _server.get_tick() + 1),
			CombatDirector.RespawnRequestResult.ACCEPTED)
	await _advance(2)
	assert_true(_combatant(net_id).is_alive(), "respawns")
	combat = _combat(net_id)
	assert_eq([combat.weapon_id, combat.alt_weapon_id, combat.is_second_slot()], [bow, 0, true],
			"with the bow active")
	var owner: Array[NetMessages.EntityEvent] = _loadouts(net_id, true)
	assert_eq([owner[-1].template_id, owner[-1].weapon_1, owner[-1].weapon_2], [0, 0, bow],
			"and its LOADOUT: slot 1 empty and the bow in 2")
	# Its next save passes S5 (I10: the active one with a weapon).
	var saves: int = _platform.sent(PlatformEvent.KIND_SAVE).size()
	_server.get_saver().mark_critical(net_id, &"prueba")
	await _advance_until(func() -> bool:
		return _platform.sent(PlatformEvent.KIND_SAVE).size() > saves and _server.get_saver().pending_count() == 0)
	var progress: Dictionary = _platform.applied(2401)["progress"]
	assert_eq(int(progress["active_weapon_slot"]), 1, "saves slot 2 as active")
	assert_eq(_s5_errors(progress), PackedStringArray(), "and the snapshot passes S5")
	# Disconnecting and coming back keeps the configuration (CMB-30): the bow in WEAPON_2, active, and the sword in the bag.
	var uids: Array[int] = [_uid(net_id, EQUIPMENT, 1), _uid(net_id, BAG, 0)]
	await _leave(ana)
	ana = await _enter(282, VARDHEIM, _claim(2401))
	net_id = ana.entity.net_id
	assert_eq([_uid(net_id, EQUIPMENT, 1), _uid(net_id, BAG, 0), _uid(net_id, EQUIPMENT, 0)], [uids[0], uids[1], 0],
			"the same items in the same slots")
	combat = _combat(net_id)
	assert_eq([combat.weapon_id, combat.alt_weapon_id, combat.is_second_slot()], [bow, 0, true],
			"and it comes back with the bow active")
