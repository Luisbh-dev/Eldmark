extends TestCase
## Inventory and progress end to end, without a platform (docs/progression.md §15 P8): a [ZoneServer] and three
## real clients ([NetClient] with ENet over 127.0.0.1, each in its own [SubViewport] with its own physics
## world, like [NetHarness]): Ana and Bruno from Vardheim and Carla from Solmarch, all ephemeral characters with
## inventory (§9.4). What §15 asks for:
## [br]- The level: Ana goes up to 3 (DEBUG_COMMAND 43) before the other two get in: Ana's SPAWN carries 3 to
## Bruno and 0 to Carla (§7.3); in the world she goes up to 4 and the LEVEL_UP reaches Bruno (his view and his nameplate, "Nv 4") and
## not Carla.
## [br]- Equipping the bow from the bag with the inventory window (double click, [method InventoryWindow.activate_item]):
## the optimistic view, the confirmation, the LOADOUT that changes Ana's weapons as seen by Bruno and Carla, Ana's
## action bar (the weapon swap with the bow) and no unexplained correction on any client. With Q, the
## bow goes to the hand: the weapon the others draw and the bar's attacks (UI-26).
## [br]- Drinking spends a potion from the bag: the CONSUME in the client's confirmed state and the bar's charges.
## [br]- A rejection returns the item: Ana splits her potions toward the first free slot at the same time that another
## potion is given by DEBUG_COMMAND 40, which the server puts in that slot before applying the split; the split comes
## back with NO_ROOM ("No cabe", it does not fit), its notice shows up in the chat and the stack returns whole to its cell.

const VARDHEIM: int = NetProtocol.Realm.VARDHEIM
const SOLMARCH: int = NetProtocol.Realm.SOLMARCH
const BAG: int = InventoryState.ContainerId.BAG
const EQUIPMENT: int = InventoryState.ContainerId.EQUIPMENT
const ZONE_ID: String = "test_world"
const WAIT_FRAMES: int = 900
const HUD_SCENE_PATH: String = "res://scenes/ui/hud.tscn"
const CAMERA_RIG_SCENE_PATH: String = "res://scenes/client/camera_rig.tscn"

var _root: Node
var _server_viewport: SubViewport
var _server: ZoneServer
var _clients: Array[NetClient] = []
var _viewports: Array[SubViewport] = []
var _port: int = 0


func before_each() -> void:
	_root = Node.new()
	_root.name = "ProgressLoopback"
	tree.root.add_child(_root)


func after_each() -> void:
	for viewport: SubViewport in _viewports:
		if is_instance_valid(viewport):
			viewport.free()
	_viewports.clear()
	_clients.clear()
	if is_instance_valid(_server_viewport):
		_server_viewport.free()
	_server_viewport = null
	_server = null
	if is_instance_valid(_root):
		tree.root.remove_child(_root)
		_root.free()
	_root = null
	await wait_process_frames()


# --- Helpers ----------------------------------------------------------------------------------

func _wait_until(condition: Callable, max_frames: int = WAIT_FRAMES) -> bool:
	for _i: int in max_frames:
		if condition.call():
			return true
		await tree.physics_frame
	return condition.call()


## A bot of [param realm] with seed [param bot_seed], standing still from the moment it enters.
func _add_client(realm: int, bot_seed: int) -> NetClient:
	var viewport: SubViewport = NetHarness.make_world_viewport(_root, "")
	_viewports.append(viewport)
	var client: NetClient = NetHarness.start_bot(viewport, _port, realm, bot_seed)
	_clients.append(client)
	return client


func _enters(client: NetClient) -> bool:
	var entered: bool = await _wait_until(func() -> bool:
		return client.get_state() == NetClient.State.IN_WORLD and client.get_inventory().has_inventory())
	if entered:
		_set_script(client, _idle)
	return entered


func _set_script(client: NetClient, script: Callable) -> void:
	var brain := CombatFixture.ScriptBrain.new(1)
	brain.script_fn = script
	(client.get_meta(&"controller") as LocalPlayerController).set_bot(brain)


func _idle(tick: int, _position: Vector3, yaw: float) -> PlayerInput:
	var input := PlayerInput.new()
	input.tick = tick
	input.look_yaw = yaw
	return input


## A real HUD for [param client] (in its viewport), looking toward −Z, as in [OnlineMain].
func _make_hud(client: NetClient, viewport: SubViewport) -> HUD:
	var character: PlayerCharacter = client.get_character()
	var rig: CameraRig = (load(CAMERA_RIG_SCENE_PATH) as PackedScene).instantiate() as CameraRig
	viewport.add_child(rig)
	rig.set_scripted_look(true)
	rig.set_target(character.get_camera_target(), character)
	rig.set_look(0.0, 0.0)
	var hud: HUD = (load(HUD_SCENE_PATH) as PackedScene).instantiate() as HUD
	viewport.add_child(hud)
	hud.bind(character, rig)
	hud.bind_net(client, NetHarness.get_world(viewport))
	return hud


## The level with which [param viewer] sees [param net_id] (−1 without a view).
func _seen_level(viewer: NetClient, net_id: int) -> int:
	var view: RemotePlayerView = viewer.get_remote_world().get_view(net_id)
	return view.get_level() if view != null else -1


## The weapon pair with which [param viewer] sees [param net_id] ((−1, −1) without a view).
func _seen_weapons(viewer: NetClient, net_id: int) -> Vector2i:
	var view: RemotePlayerView = viewer.get_remote_world().get_view(net_id)
	return view.get_weapons() if view != null else Vector2i(-1, -1)


func _server_progress(net_id: int) -> PlayerProgress:
	return _server.get_progress().get_player(net_id)


## Where [param def_id] is in [param state] (the first slot, container by container); (−1, −1) if it is not there.
func _find(state: InventoryState, def_id: StringName) -> Vector2i:
	for container: int in [BAG, EQUIPMENT]:
		for slot: int in state.slot_count(container):
			var item: ItemInstance = state.get_item(container, slot)
			if item != null and item.def_id == def_id:
				return Vector2i(container, slot)
	return Vector2i(-1, -1)


func _def_at(state: InventoryState, at: Vector2i) -> StringName:
	var item: ItemInstance = state.get_item(at.x, at.y) if state != null else null
	return item.def_id if item != null else &""


func _count_at(state: InventoryState, at: Vector2i) -> int:
	var item: ItemInstance = state.get_item(at.x, at.y) if state != null else null
	return item.count if item != null else 0


## The client's confirmed state and the server's inventory, slot by slot (uid, item and quantity).
func _same_inventory(client: InventoryState, server: InventoryState) -> bool:
	if client == null or server == null:
		return false
	for container: int in [BAG, EQUIPMENT]:
		for slot: int in server.slot_count(container):
			var a: ItemInstance = client.get_item(container, slot)
			var b: ItemInstance = server.get_item(container, slot)
			if (a == null) != (b == null):
				return false
			if a != null and (a.uid != b.uid or a.def_id != b.def_id or a.count != b.count or a.bound != b.bound):
				return false
	return true


# --- The test ----------------------------------------------------------------------------------

func test_inventory_levels_and_potions_over_the_network() -> void:
	_port = NetHarness.free_udp_port()
	_server_viewport = NetHarness.make_world_viewport(_root, "")
	var config := ServerConfig.new()
	config.port = _port
	config.zone_id = ZONE_ID
	config.max_players = 8
	config.debug_commands = true
	_server = NetHarness.start_server(_server_viewport, config)
	if not assert_true(_server != null, "the server starts"):
		return
	_server.get_progress().log_sink = func(_text: String) -> void: pass
	await wait_physics_frames(3)
	var curve: LevelCurve = LevelCurve.shared()
	var db: ItemDatabase = ItemDatabase.shared()
	var sword: int = CombatCatalog.weapon_id(&"sword_shield")
	var bow: int = CombatCatalog.weapon_id(&"bow")

	# --- Ana gets in alone and goes up to level 3 before the others get in. --------------------------------
	var ana: NetClient = _add_client(VARDHEIM, 1)
	if not assert_true(await _enters(ana), "Ana gets in with her inventory"):
		return
	var ana_id: int = ana.get_net_id()
	ana.send_debug_command(NetProtocol.DEBUG_XP_ADD, NetMessages.DebugCommand.xp_add(curve.total_to(3)).payload)
	var leveled: bool = await _wait_until(func() -> bool:
		return ana.get_progress().get_level() == 3 and _server.get_registry().get_entity(ana_id).level == 3, 300)
	if not assert_true(leveled, "Ana goes up to level 3 (PROGRESS_UPDATE and NetEntity.level)"):
		return

	# --- Bruno (her realm) and Carla (the other) receive Ana's SPAWN: 3 and 0. -----------------------------
	var bruno: NetClient = _add_client(VARDHEIM, 2)
	var carla: NetClient = _add_client(SOLMARCH, 3)
	if not assert_true(await _enters(bruno) and await _enters(carla), "Bruno and Carla get in"):
		return
	var bruno_id: int = bruno.get_net_id()
	var carla_id: int = carla.get_net_id()
	_server.teleport(ana_id, Vector3(0.0, 0.05, -6.0))
	_server.teleport(bruno_id, Vector3(-2.0, 0.05, 0.0))
	_server.teleport(carla_id, Vector3(2.0, 0.05, 0.0))
	var all_seen: bool = await _wait_until(func() -> bool:
		return _seen_level(bruno, ana_id) >= 0 and _seen_level(carla, ana_id) >= 0 \
				and _seen_level(ana, carla_id) >= 0 and _seen_level(ana, bruno_id) >= 0, 300)
	if not assert_true(all_seen, "each one sees the others"):
		return
	assert_eq(_seen_level(bruno, ana_id), 3, "Bruno, from the same realm, receives Ana's real level in the SPAWN")
	assert_eq(_seen_level(carla, ana_id), 0, "Carla, from the other realm, receives 0")
	assert_eq(_seen_level(ana, bruno_id), 1, "Ana sees Bruno's level 1")
	assert_eq(_seen_level(ana, carla_id), 0, "and Carla's 0")

	# --- In the world, Ana goes up to 4: the LEVEL_UP reaches Bruno and not Carla. -----------------------------------
	var bruno_hud: HUD = _make_hud(bruno, _viewports[1])
	var carla_hud: HUD = _make_hud(carla, _viewports[2])
	ana.send_debug_command(NetProtocol.DEBUG_XP_ADD,
			NetMessages.DebugCommand.xp_add(curve.total_to(4) - curve.total_to(3)).payload)
	var up: bool = await _wait_until(func() -> bool:
		return ana.get_progress().get_level() == 4 and _seen_level(bruno, ana_id) == 4, 300)
	if not assert_true(up, "Ana goes up to 4 and Bruno sees it through the LEVEL_UP"):
		return
	await wait_physics_frames(30)
	assert_eq(_seen_level(carla, ana_id), 0, "Carla still sees 0: she does not receive the LEVEL_UP from another realm")
	var plate_shown: bool = await _wait_until(func() -> bool:
		bruno_hud.get_nameplates().refresh(0.016)
		var plate: Nameplate = bruno_hud.get_nameplates().get_plate_for(ana_id)
		return plate != null and plate.get_level_text() == "Nv 4", 120)
	assert_true(plate_shown, "Ana's nameplate in Bruno's HUD says \"Nv 4\"")
	carla_hud.get_nameplates().refresh(0.016)
	var enemy_plate: Nameplate = carla_hud.get_nameplates().get_plate_for(ana_id)
	assert_eq(enemy_plate.get_level_text() if enemy_plate != null else "", "", "and in Carla's, without a level")

	# --- Ana equips the bow from her bag with the inventory window. ----------------------------------------------
	var ana_hud: HUD = _make_hud(ana, _viewports[0])
	await wait_physics_frames(5)
	var inventory: ClientInventory = ana.get_inventory()
	var window: InventoryWindow = ana_hud.get_inventory_window()
	var bar: ActionBar = ana_hud.get_action_bar()
	var bow_at: Vector2i = _find(inventory.get_view(), &"bow_vado")
	assert_eq(bow_at.x, BAG, "the squire kit's bow is in the bag")
	assert_eq(_def_at(inventory.get_view(), Vector2i(EQUIPMENT, 0)), &"sword_shield_vado", "with the sword equipped")
	assert_false(bar.get_slot(ActionBar.Slot.SWAP).enabled, "without a second weapon, the weapon swap is off")
	var bow_uid: int = inventory.get_view().get_item(bow_at.x, bow_at.y).uid
	var before_stats: Array[Dictionary] = []
	for client: NetClient in _clients:
		before_stats.append(client.get_stats())
	assert_eq(window.activate_item(bow_at), InventoryOps.Result.OK, "double click on the bow: equipping it is requested")
	var weapon_2 := Vector2i(EQUIPMENT, InventoryState.EquipmentSlot.WEAPON_2)
	assert_eq(_def_at(inventory.get_view(), weapon_2), &"bow_vado", "the view puts it in WEAPON_2 immediately")
	assert_eq(_def_at(inventory.get_confirmed(), weapon_2), &"", "still unconfirmed")
	assert_eq(inventory.get_pending_count(), 1, "with the request in flight")
	var equipped: bool = await _wait_until(func() -> bool:
		return inventory.get_pending_count() == 0 and _def_at(inventory.get_confirmed(), weapon_2) == &"bow_vado" \
				and _server.get_registry().get_entity(ana_id).get_character().combat.alt_weapon_id == bow \
				and ana.get_character().combat.alt_weapon_id == bow, 300)
	if not assert_true(equipped, "the server confirms it and the LOADOUT puts the bow in Ana's prediction"):
		return
	assert_eq(inventory.get_confirmed().get_item(weapon_2.x, weapon_2.y).uid, bow_uid, "the same uid")
	assert_true(inventory.get_confirmed().get_item(weapon_2.x, weapon_2.y).bound, "bound on equipping")
	var others_see: bool = await _wait_until(func() -> bool:
		return _seen_weapons(bruno, ana_id) == Vector2i(sword, bow) and _seen_weapons(carla, ana_id) == Vector2i(sword, bow),
			300)
	assert_true(others_see, "Bruno and Carla see Ana with the sword and the bow (LOADOUT)")
	var bar_shows: bool = await _wait_until(func() -> bool:
		var swap: ActionBar.ActionSlot = bar.get_slot(ActionBar.Slot.SWAP)
		return swap.enabled and swap.tooltip_text.contains(CombatText.weapon_title(bow)), 60)
	assert_true(bar_shows, "Ana's bar shows the swap to the bow")
	assert_true(_same_inventory(inventory.get_confirmed(), _server_progress(ana_id).record.inventory),
			"Ana's confirmed state is the server's inventory")
	# With Q, the equipped bow goes to the hand: the model the others see and the bar's attacks.
	var swap_at: int = ana.get_prediction().get_predicted_tick() + 10
	_set_script(ana, func(tick: int, position: Vector3, yaw: float) -> PlayerInput:
		var input: PlayerInput = _idle(tick, position, yaw)
		if tick >= swap_at and tick < swap_at + 2:
			input.buttons = PlayerInput.SWAP_WEAPON
		return input)
	var in_hand: bool = await _wait_until(func() -> bool:
		var bruno_view: RemotePlayerView = bruno.get_remote_world().get_view(ana_id)
		var carla_view: RemotePlayerView = carla.get_remote_world().get_view(ana_id)
		return _server.get_registry().get_entity(ana_id).get_character().combat.weapon_id == bow \
				and ana.get_character().combat.weapon_id == bow and bar.get_shown_weapon() == bow \
				and bruno_view.get_active_weapon_id() == bow and carla_view.get_active_weapon_id() == bow, 300)
	assert_true(in_hand, "Ana switches to the bow: Bruno and Carla see it in her hand and her bar shows the bow's attacks")
	_set_script(ana, _idle)
	await wait_physics_frames(30)

	# --- Drinking spends a potion from the bag. -------------------------------------------------------------------
	var potions_at: Vector2i = _find(inventory.get_confirmed(), &"potion_health")
	var potions: int = inventory.get_confirmed().count_of(&"potion_health")
	assert_eq([potions_at.x, potions], [BAG, 3], "three health potions in the bag")
	var charges_shown: bool = await _wait_until(func() -> bool:
		return bar.get_slot(ActionBar.Slot.CONSUMABLE_1).count == 3, 60)
	assert_true(charges_shown, "the bar shows its three charges")
	var consumed: Array[int] = []
	ana.inventory_delta_received.connect(func(delta: ProgressMessages.InventoryDelta) -> void:
		if delta.reason == EconomyReason.CONSUME:
			consumed.append(delta.revision))
	var press: int = ana.get_prediction().get_predicted_tick() + 10
	_set_script(ana, func(tick: int, _position: Vector3, yaw: float) -> PlayerInput:
		var input: PlayerInput = _idle(tick, _position, yaw)
		if tick >= press and tick < press + 2:
			input.buttons = PlayerInput.CONSUMABLE_1
		return input)
	var drank: bool = await _wait_until(func() -> bool:
		return consumed.size() == 1 and inventory.get_confirmed().count_of(&"potion_health") == 2 \
				and bar.get_slot(ActionBar.Slot.CONSUMABLE_1).count == 2, 600)
	if not assert_true(drank, "the CONSUME arrives: two potions in the bag and two charges on the bar"):
		return
	assert_eq(_server_progress(ana_id).record.inventory.count_of(&"potion_health"), 2, "and on the server")
	_set_script(ana, _idle)
	await wait_physics_frames(30)

	# --- A rejection returns the item. --------------------------------------------------------------------------
	potions_at = _find(inventory.get_confirmed(), &"potion_health")
	var free_slot: int = inventory.get_view().first_free(BAG)
	var rejections: Array[Array] = []
	inventory.request_rejected.connect(func(result: int, text: String) -> void: rejections.append([result, text]))
	ana.send_debug_command(NetProtocol.DEBUG_ITEM_GIVE,
			NetMessages.DebugCommand.item_give(db.net_id_of(&"potion_health"), 1).payload)
	assert_eq(inventory.request(inventory.make_split(potions_at, Vector2i(BAG, free_slot), 1)), InventoryOps.Result.OK,
			"the split is valid by what Ana sees")
	assert_eq(_count_at(inventory.get_view(), potions_at), 1, "in the view, the stack drops to 1")
	assert_eq(_count_at(inventory.get_view(), Vector2i(BAG, free_slot)), 1, "and a provisional stack appears")
	var answered: bool = await _wait_until(func() -> bool:
		return inventory.get_pending_count() == 0 and not rejections.is_empty(), 300)
	if not assert_true(answered, "the reply arrives"):
		return
	assert_eq(rejections, [[InventoryOps.Result.NO_ROOM, InventoryOps.result_text(InventoryOps.Result.NO_ROOM)]],
			"rejected with NO_ROOM (\"No cabe\", it does not fit): the server put the GM's potion in that slot first")
	assert_eq(_count_at(inventory.get_view(), potions_at), 2, "the stack returns whole to its cell")
	assert_eq(_count_at(inventory.get_view(), Vector2i(BAG, free_slot)), 1, "and in the slot, the given potion")
	assert_false(ClientInventory.is_provisional(inventory.get_view().get_item(BAG, free_slot)), "with its real uid")
	assert_true(_same_inventory(inventory.get_view(), _server_progress(ana_id).record.inventory),
			"Ana's view is the server's inventory")
	assert_true(ana_hud.get_chat().get_visible_text().contains(InventoryOps.result_text(InventoryOps.Result.NO_ROOM)),
			"the rejection notice shows up in the chat")
	var charged: bool = await _wait_until(func() -> bool:
		return bar.get_slot(ActionBar.Slot.CONSUMABLE_1).count == 3, 120)
	assert_true(charged, "the given potion adds its charge to the bar")

	# --- No unexplained correction. -------------------------------------------------------------------------------
	await wait_physics_frames(30)
	for index: int in _clients.size():
		var stats: Dictionary = _clients[index].get_stats()
		assert_eq(stats["unexplained_diffs"], 0, "%s predicts without unexplained failures" % _clients[index].get_config().display_name)
		assert_eq(stats["hard_resets"], 0, "nor hard resets")
		assert_eq(stats["malformed_packets"], 0, "nor malformed messages")
		print("[progreso] %s: diffs %d -> %d, correcciones %d -> %d" % [_clients[index].get_config().display_name,
				before_stats[index]["diffs"], stats["diffs"], before_stats[index]["corrections"], stats["corrections"]])
