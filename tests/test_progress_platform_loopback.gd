extends TestCase
## The persistent character end to end with the fake platform (docs/progresion.md §15 P8): a [ZoneServer] with
## [FakeZonePlatform] (plataforma.md §14.3) and [TicketAuthProvider], and real clients ([NetClient] over ENet on
## 127.0.0.1, each in its own [SubViewport]) that get in with test tickets signed with the zone's key. The
## flat zone carries the Vardheim camp (the safe zone around its two spawn points). What §15 asks for:
## [br]- A character created with [code]marksman[/code] ([method FakeZonePlatform.claim_progress]) receives that kit on
## its first entry (STARTER_KIT in the critical save) with the uids from the id block the platform gives
## ([member FakeZonePlatform.next_block_first]), even if the client sends a LOADOUT_SELECT for another template before
## CLIENT_READY; in the world, LOADOUT_SELECT changes nothing either.
## [br]- Drinking (CONSUME), refilling at the camp (CAMP_REFILL) and /atascado (with its 5 min timer).
## [br]- Leaving and coming back: the next claim brings the last thing saved and the character returns with the same uids and
## the same equipment, the same active weapon (the second, after switching with Q), its balances (the gold from a DEBUG_COMMAND 41
## from its [code]admin[/code] account) and the /atascado reuse delay minus the time it was away (100 s of the platform's
## time); and it returns to its realm's camp (RVR zone), not to where it left.

const VARDHEIM: int = NetProtocol.Realm.VARDHEIM
const BAG: int = InventoryState.ContainerId.BAG
const EQUIPMENT: int = InventoryState.ContainerId.EQUIPMENT
const ZONE_ID: String = "test_world"
const WAIT_FRAMES: int = 900
## The fake platform's Unix time on the first entry; the second, 100 s later.
const NOW: int = 1_800_000_000
const AWAY_S: int = 100
const KEY_ID: int = 2
const KEY_HEX: String = "02b7825be38fdd5396a4a058286884eaf93a9df85b874f78b4010a76103fb858"
const FIRST_TICKET_ID: int = 9007199254740001
const CHARACTER_ID: int = 4242
const ACCOUNT_ID: int = 78
## The first id of the first block the fake platform gives (not the default one, to see that it is used).
const FIRST_ID: int = 70_001
const CAMP: Vector3 = Vector3(-20.0, 0.0, 0.0)
const CAMP_RADIUS: float = 24.0
## Far from the camp (outside the safe zone) and inside the flat zone.
const AWAY: Vector3 = Vector3(60.0, 0.05, 60.0)
const UNSTUCK_COOLDOWN_S: int = 300

var _root: Node
var _server_viewport: SubViewport
var _world: Node3D
var _server: ZoneServer
var _platform: FakeZonePlatform
var _keys: Dictionary[int, PackedByteArray] = {}
var _port: int = 0
var _next_ticket_id: int = FIRST_TICKET_ID
var _viewports: Array[SubViewport] = []


func before_each() -> void:
	_root = Node.new()
	_root.name = "ProgressPlatformLoopback"
	tree.root.add_child(_root)
	_keys = {KEY_ID: KEY_HEX.hex_decode()}


func after_each() -> void:
	for viewport: SubViewport in _viewports:
		if is_instance_valid(viewport):
			viewport.free()
	_viewports.clear()
	if is_instance_valid(_server_viewport):
		_server_viewport.free()
	_server_viewport = null
	_server = null
	_platform = null
	_world = null
	_next_ticket_id = FIRST_TICKET_ID
	if is_instance_valid(_root):
		tree.root.remove_child(_root)
		_root.free()
	_root = null
	await wait_process_frames()


# --- Setup ------------------------------------------------------------------------------------

## The flat zone with the Vardheim camp, the fake platform started and live (with its first block of
## ids) and the server listening with tickets.
func _start() -> bool:
	_server_viewport = NetHarness.make_world_viewport(_root, "")
	_world = NetHarness.get_world(_server_viewport)
	NpcRig.add_safe_area(_world, &"vardheim", CAMP, CAMP_RADIUS)
	var transport := NetTransport.new()
	transport.name = "ServerTransport"
	_server_viewport.add_child(transport)
	_platform = FakeZonePlatform.new()
	_platform.name = "Platform"
	_platform.log_sink = func(_text: String) -> void: pass
	_platform.fake_now_unix = NOW
	_platform.next_block_first = FIRST_ID
	_server_viewport.add_child(_platform)
	_server = ZoneServer.new()
	_server.name = "ZoneServer"
	_server.log_enabled = false
	_server_viewport.add_child(_server)
	await wait_physics_frames(3)
	var config := ServerConfig.new()
	config.zone_id = ZONE_ID
	config.max_players = 8
	config.debug_commands = true
	config.platform_url = "http://fake"
	# Checkpoints every 10 min: in the test only the critical and final ones go out.
	config.save_interval_s = 600
	_port = NetHarness.free_udp_port()
	config.port = _port
	var finished: Array = []
	_platform.startup_finished.connect(func(ok: bool, error: String) -> void: finished.append([ok, error]))
	_platform.start(config, {"token": "token", "ticket_keys": _keys})
	for _i: int in 120:
		if not finished.is_empty():
			break
		await wait_process_frames()
	if not assert_eq(finished, [[true, ""]], "the fake platform starts"):
		return false
	var provider := TicketAuthProvider.new(_platform, config.world_id, config.zone_id, config.channel, _keys)
	provider.log_sink = func(_text: String) -> void: pass
	if not assert_eq(_server.start(config, _world, transport, provider, _platform), OK, "the server opens the port"):
		return false
	_server.get_progress().log_sink = func(_text: String) -> void: pass
	_platform.go_live()
	var ready: bool = await _wait_until(func() -> bool: return _server.get_progress().get_ids().available() > 0)
	return assert_true(ready, "the first id block arrives")


func _wait_until(condition: Callable, max_frames: int = WAIT_FRAMES) -> bool:
	for _i: int in max_frames:
		if condition.call():
			return true
		await tree.physics_frame
	return condition.call()


## A test ticket for the character, signed with the zone's key and issued with the platform's time.
func _ticket() -> PackedByteArray:
	var ticket := HandoffTicket.new()
	ticket.key_id = KEY_ID
	ticket.world_id = 1
	ticket.ticket_id = _next_ticket_id
	_next_ticket_id += 1
	ticket.character_id = CHARACTER_ID
	ticket.zone_key = HandoffTicket.zone_key_of(ZONE_ID)
	ticket.realm = VARDHEIM
	ticket.flags = HandoffTicket.FLAG_FROM_MENU
	ticket.issued_at = _platform.now_unix()
	ticket.expires_at = ticket.issued_at + 10
	return ticket.sign(_keys[KEY_ID])


## A client that gets in with a ticket (like the one from [code]enter[/code]: character and ticket in the configuration) and asks for
## [param loadout] with LOADOUT_SELECT before CLIENT_READY. It returns when it is in the world with its inventory,
## standing still.
func _enter(loadout: String) -> NetClient:
	var viewport: SubViewport = NetHarness.make_world_viewport(_root, "")
	_viewports.append(viewport)
	var ticket: PackedByteArray = _ticket()
	var client: NetClient = NetHarness.start_bot(viewport, _port, VARDHEIM, _viewports.size(), "", "", "", loadout,
			func(config: ClientConfig) -> void:
				config.ticket = ticket
				config.character_id = CHARACTER_ID)
	var entered: bool = await _wait_until(func() -> bool:
		return client.get_state() == NetClient.State.IN_WORLD and client.get_inventory().has_inventory() \
				and client.get_progress().has_wallet())
	if not assert_true(entered, "character %d gets in with a ticket" % CHARACTER_ID):
		return null
	_set_script(client, _idle)
	return client


func _set_script(client: NetClient, script: Callable) -> void:
	var brain := CombatFixture.ScriptBrain.new(1)
	brain.script_fn = script
	(client.get_meta(&"controller") as LocalPlayerController).set_bot(brain)


func _idle(tick: int, _position: Vector3, yaw: float) -> PlayerInput:
	var input := PlayerInput.new()
	input.tick = tick
	input.look_yaw = yaw
	return input


## Presses [param button] for two ticks, 10 after the last predicted one.
func _press(client: NetClient, button: int) -> void:
	var at: int = client.get_prediction().get_predicted_tick() + 10
	_set_script(client, func(tick: int, position: Vector3, yaw: float) -> PlayerInput:
		var input: PlayerInput = _idle(tick, position, yaw)
		if tick >= at and tick < at + 2:
			input.buttons = button
		return input)


func _peer_of(net_id: int) -> ServerPeer:
	for peer_id: int in _server.get_peer_ids():
		var peer: ServerPeer = _server.get_peer(peer_id)
		if peer.entity != null and peer.entity.net_id == net_id:
			return peer
	return null


func _player(client: NetClient) -> PlayerProgress:
	return _server.get_progress().get_player(client.get_net_id())


func _combat(client: NetClient) -> CombatState:
	return _server.get_registry().get_entity(client.get_net_id()).get_character().combat


## [code]{"contenedor:ranura": "uid def_id ×n"}[/code] of an inventory: what has to come back the same.
func _layout(state: InventoryState) -> Dictionary:
	var layout: Dictionary = {}
	for container: int in [BAG, EQUIPMENT]:
		for slot: int in state.slot_count(container):
			var item: ItemInstance = state.get_item(container, slot)
			if item != null:
				layout["%d:%d" % [container, slot]] = "%d %s ×%d%s" % [item.uid, item.def_id, item.count,
						" ligado" if item.bound else ""]
	return layout


func _def_at(state: InventoryState, container: int, slot: int) -> StringName:
	var item: ItemInstance = state.get_item(container, slot)
	return item.def_id if item != null else &""


func _saves() -> Array[Dictionary]:
	return _platform.sent(PlatformEvent.KIND_SAVE)


## The operations of type [param kind] of all the saves sent.
func _ops_of_kind(kind: int) -> Array[Dictionary]:
	var found: Array[Dictionary] = []
	for body: Dictionary in _saves():
		var progress: Variant = body.get("progress")
		if not progress is Dictionary:
			continue
		for op: Variant in (progress as Dictionary).get("ops", []):
			if op is Dictionary and int((op as Dictionary).get("kind", 0)) == kind:
				found.append(op)
	return found


# --- The test ----------------------------------------------------------------------------------

func test_a_persistent_character_keeps_everything_across_two_sessions() -> void:
	if not await _start():
		return
	var catalog: AppearanceCatalog = AppearanceCatalog.shared()
	var appearance: CharacterAppearance = CharacterAppearance.default_for(catalog, catalog.race_index(&"race_vardheim"))
	_platform.add_character(CHARACTER_ID, ACCOUNT_ID, &"admin", VARDHEIM,
			FakeZonePlatform.claim_progress(&"race_vardheim", appearance.encode(), &"marksman"))
	var bow: int = CombatCatalog.weapon_id(&"bow")
	var sword: int = CombatCatalog.weapon_id(&"sword_shield")
	var squire: int = CombatCatalog.template_id(&"squire")

	# --- First entry: the marksman kit with the block's ids; LOADOUT_SELECT changes nothing. -------------
	var ana: NetClient = await _enter("squire")
	if ana == null:
		return
	var ana_id: int = ana.get_net_id()
	assert_eq(ana.get_stats()["loadout_selects"], 1, "the client asked for the squire before CLIENT_READY")
	var inventory: ClientInventory = ana.get_inventory()
	var confirmed: InventoryState = inventory.get_confirmed()
	assert_eq([_def_at(confirmed, EQUIPMENT, 0), _def_at(confirmed, EQUIPMENT, 1)], [&"bow_vado", &"sword_shield_vado"],
			"with the marksman kit (the one from its creation), not the squire's")
	assert_eq([confirmed.count_of(&"potion_health"), confirmed.count_of(&"potion_stamina")], [3, 2],
			"and the camp potions")
	for item: ItemInstance in confirmed.all_items():
		assert_true(item.uid >= FIRST_ID and item.uid < FIRST_ID + 1024,
				"uid %d of %s comes from the platform's block" % [item.uid, item.def_id])
	assert_eq(_server.get_combat().get_combatant(ana_id).template_id, 0, "the equipment of its inventory, without a template")
	assert_eq([_combat(ana).weapon_id, _combat(ana).alt_weapon_id], [bow, sword], "with the bow in hand")
	assert_eq([ana.get_character().combat.weapon_id, ana.get_character().combat.alt_weapon_id], [bow, sword],
			"also in its prediction")
	var kit_saved: bool = await _wait_until(func() -> bool:
		return _ops_of_kind(EconomyOp.Kind.STARTER_KIT).size() == 1 and _server.get_saver().pending_count() == 0)
	assert_true(kit_saved, "the kit goes out in a STARTER_KIT, in the critical save on arrival")
	var kit_events: Array = _ops_of_kind(EconomyOp.Kind.STARTER_KIT)[0]["items"]
	assert_eq(kit_events.size(), confirmed.all_items().size(), "one event per kit stack")
	assert_true(ana.send_loadout_select(squire), "asks for the squire in the world")
	await wait_physics_frames(30)
	assert_eq(_peer_of(ana_id).pending_template_id, -1, "with an inventory nothing is left pending")
	assert_eq([_combat(ana).weapon_id, _combat(ana).alt_weapon_id], [bow, sword], "and the weapons do not change")

	# --- Drinking and refilling at the camp. -------------------------------------------------------------------------
	var reasons: Array[int] = []
	ana.inventory_delta_received.connect(func(delta: ProgressMessages.InventoryDelta) -> void:
		if delta.request_id == 0:
			reasons.append(delta.reason))
	var potions_at: Vector2i = Vector2i(-1, -1)
	for slot: int in confirmed.slot_count(BAG):
		if _def_at(confirmed, BAG, slot) == &"potion_health":
			potions_at = Vector2i(BAG, slot)
	var potion_uid: int = confirmed.get_item(potions_at.x, potions_at.y).uid
	_press(ana, PlayerInput.CONSUMABLE_1)
	var drank: bool = await _wait_until(func() -> bool:
		return reasons.has(EconomyReason.CONSUME) and inventory.get_confirmed().count_of(&"potion_health") == 2, 600)
	if not assert_true(drank, "drinking spends a potion from the bag (CONSUME)"):
		return
	_set_script(ana, _idle)
	var refilled: bool = await _wait_until(func() -> bool:
		return reasons.has(EconomyReason.CAMP_REFILL) and inventory.get_confirmed().count_of(&"potion_health") == 3,
			300)
	assert_true(refilled, "the camp refills it (CAMP_REFILL)")
	assert_eq(reasons.slice(reasons.find(EconomyReason.CONSUME)), [EconomyReason.CONSUME, EconomyReason.CAMP_REFILL],
			"first the CONSUME and then the refill")
	assert_eq(inventory.get_confirmed().get_item(potions_at.x, potions_at.y).uid, potion_uid, "in the same stack")

	# --- /atascado far from the camp: it returns to its realm and leaves a 5 min reuse delay. ---------------------------
	var unstuck: UnstuckTracker = _server.get_unstuck()
	unstuck.channel_ticks = 30
	var key: String = _server.unstuck_key_of(_server.get_registry().get_entity(ana_id))
	assert_eq(key, "character:%d" % CHARACTER_ID, "with a platform, /atascado goes through the character")
	_server.teleport(ana_id, AWAY)
	await wait_physics_frames(10)
	var transport: NetTransport = ana.get_meta(&"transport") as NetTransport
	transport.send(NetClient.SERVER_PEER_ID, NetProtocol.CH_RELIABLE, NetMessages.UnstuckRequest.new().encode())
	var moved: bool = await _wait_until(func() -> bool: return unstuck.completed_count == 1, 300)
	if not assert_true(moved, "/atascado completes"):
		return
	var position: Vector3 = _server.get_registry().get_entity(ana_id).get_position()
	assert_true(position.distance_to(CAMP) < CAMP_RADIUS, "and leaves it at a point in its realm: %s" % position)
	assert_eq(_player(ana).record.timers.get("unstuck", 0), NOW + UNSTUCK_COOLDOWN_S,
			"the unstuck timer ends 5 min later, in Unix time")

	# --- Gold (its account is admin), the second weapon in hand and far from the camp. -------------------------------
	ana.send_debug_command(NetProtocol.DEBUG_CURRENCY_ADD,
			NetMessages.DebugCommand.currency_add(Currency.Code.GOLD, 50).payload)
	var paid: bool = await _wait_until(func() -> bool:
		return ana.get_progress().get_balance(Currency.Code.GOLD) == 50 \
				and _ops_of_kind(EconomyOp.Kind.GM).size() == 1, 300)
	assert_true(paid, "50 gold through DEBUG_COMMAND 41 (a GM operation, in a critical save)")
	_press(ana, PlayerInput.SWAP_WEAPON)
	var swapped: bool = await _wait_until(func() -> bool:
		return _combat(ana).weapon_id == sword and ana.get_character().combat.weapon_id == sword \
				and _combat(ana).action == CombatState.Action.NONE, 300)
	if not assert_true(swapped, "switches to the sword (the second slot)"):
		return
	_set_script(ana, _idle)
	assert_eq(_combat(ana).combat_flags2 & CombatState.FLAG2_SECOND_SLOT, CombatState.FLAG2_SECOND_SLOT,
			"the active slot is the second")
	_server.teleport(ana_id, AWAY)
	await wait_physics_frames(20)

	# --- It leaves: the final save carries everything. ---------------------------------------------------------------------
	var layout: Dictionary = _layout(_player(ana).record.inventory)
	assert_eq(_layout(inventory.get_confirmed()), layout, "the client had the same as the server")
	var saves_before: int = _saves().size()
	ana.leave()
	var released: bool = await _wait_until(func() -> bool:
		return _server.get_progress().get_player(ana_id) == null and _server.get_saver().pending_count() == 0 \
				and _saves().size() > saves_before, 300)
	if not assert_true(released, "the body leaves with its final save"):
		return
	var final: Dictionary = _platform.applied(CHARACTER_ID)["progress"]
	assert_eq(int(final["active_weapon_slot"]), 1, "the active second slot is saved")
	var timers: Array = final["timers"]
	assert_eq(timers.map(func(timer: Dictionary) -> Array: return [timer["key"], int(timer["ends_at_unix"])]),
			[["unstuck", NOW + UNSTUCK_COOLDOWN_S]], "and /atascado")
	assert_true(Vector3(final["location"]["x"], final["location"]["y"], final["location"]["z"]).distance_to(AWAY) < 1.0,
			"and where it left")

	# --- It returns 100 s later. ----------------------------------------------------------------------------------------
	_platform.fake_now_unix = NOW + AWAY_S
	var again: NetClient = await _enter("")
	if again == null:
		return
	var again_id: int = again.get_net_id()
	var arrival: int = _server.get_tick()
	assert_eq(_layout(_player(again).record.inventory), layout, "on the server, the same uids, slots and stacks")
	assert_eq(_layout(again.get_inventory().get_confirmed()), layout, "and on the client")
	assert_eq(_ops_of_kind(EconomyOp.Kind.STARTER_KIT).size(), 1, "without another kit")
	assert_eq(again.get_progress().get_balance(Currency.Code.GOLD), 50, "with its gold")
	assert_eq([_combat(again).weapon_id, _combat(again).alt_weapon_id], [sword, bow],
			"with the sword in hand: the second slot is still active")
	assert_eq(again.get_character().combat.weapon_id, sword, "also in its prediction")
	var back: Vector3 = _server.get_registry().get_entity(again_id).get_position()
	var at_camp: bool = false
	for spawn: Vector3 in ZoneFixture.VARDHEIM_SPAWNS:
		at_camp = at_camp or Vector3(back.x, 0.0, back.z).distance_to(spawn) < 0.5
	assert_true(at_camp, "at its realm's camp (RVR zone), not where it left: %s" % back)
	var left_ticks: int = unstuck.get_ready_at(key) - arrival
	assert_true(absi(left_ticks - (UNSTUCK_COOLDOWN_S - AWAY_S) * 60) <= 60,
			"the /atascado reuse delay, minus the 100 s away: %d ticks" % left_ticks)
	var notices: Array[String] = []
	again.notice_received.connect(func(_code: int, text: String) -> void: notices.append(text))
	(again.get_meta(&"transport") as NetTransport).send(NetClient.SERVER_PEER_ID, NetProtocol.CH_RELIABLE,
			NetMessages.UnstuckRequest.new().encode())
	var refused: bool = await _wait_until(func() -> bool: return not notices.is_empty(), 120)
	assert_true(refused and notices[0].begins_with("/atascado: disponible de nuevo en"),
			"and it cannot be used: %s" % [notices])
	assert_eq(again.get_stats()["unexplained_diffs"], 0, "predicts without unexplained failures")
	assert_eq(ana.get_stats()["unexplained_diffs"], 0, "also in the first session")
