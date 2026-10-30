extends TestCase
## El inventario y el progreso de punta a punta, sin plataforma (docs/progresion.md §15 P8): un [ZoneServer] y tres
## clientes de verdad ([NetClient] con ENet sobre 127.0.0.1, cada uno en su [SubViewport] con su propio mundo de
## física, como [NetHarness]): Ana y Bruno de Vardheim y Carla de Solmarch, todos personajes efímeros con inventario
## (§9.4). Lo que pide §15:
## [br]- El nivel: Ana sube al 3 (DEBUG_COMMAND 43) antes de que entren los otros dos: el SPAWN de Ana trae el 3 a
## Bruno y el 0 a Carla (§7.3); en el mundo sube al 4 y el LEVEL_UP llega a Bruno (su vista y su placa, «Nv 4») y no
## a Carla.
## [br]- Equipar el arco desde la bolsa con la ventana de inventario (doble clic, [method InventoryWindow.activate_item]):
## la vista optimista, la confirmación, el LOADOUT que cambia las armas de Ana en lo que ven Bruno y Carla, la barra
## de acciones de Ana (el cambio de arma con el arco) y ninguna corrección sin explicar en ningún cliente. Con Q, el
## arco pasa a la mano: el arma que los otros dibujan y los ataques de la barra (UI-26).
## [br]- Beber gasta una poción de la bolsa: el CONSUME en el confirmado del cliente y las cargas de la barra.
## [br]- Un rechazo devuelve el objeto: Ana divide sus pociones hacia la primera ranura libre a la vez que se da otra
## poción por DEBUG_COMMAND 40, que el servidor pone en esa ranura antes de aplicar la división; la división vuelve
## con NO_ROOM («No cabe»), su aviso sale en el chat y la pila vuelve entera a su casilla.

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


# --- Ayudantes --------------------------------------------------------------------------------

func _wait_until(condition: Callable, max_frames: int = WAIT_FRAMES) -> bool:
	for _i: int in max_frames:
		if condition.call():
			return true
		await tree.physics_frame
	return condition.call()


## Un bot de [param realm] con la semilla [param bot_seed], quieto desde que entra.
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


## Un HUD de verdad para [param client] (en su viewport), mirando hacia −Z, como en [OnlineMain].
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


## El nivel con el que [param viewer] ve a [param net_id] (−1 sin vista).
func _seen_level(viewer: NetClient, net_id: int) -> int:
	var view: RemotePlayerView = viewer.get_remote_world().get_view(net_id)
	return view.get_level() if view != null else -1


## La pareja de armas con la que [param viewer] ve a [param net_id] ((−1, −1) sin vista).
func _seen_weapons(viewer: NetClient, net_id: int) -> Vector2i:
	var view: RemotePlayerView = viewer.get_remote_world().get_view(net_id)
	return view.get_weapons() if view != null else Vector2i(-1, -1)


func _server_progress(net_id: int) -> PlayerProgress:
	return _server.get_progress().get_player(net_id)


## Dónde está [param def_id] en [param state] (la primera ranura, contenedor por contenedor); (−1, −1) si no está.
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


## El confirmado del cliente y el inventario del servidor, ranura a ranura (uid, objeto y cantidad).
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


# --- La prueba ---------------------------------------------------------------------------------

func test_inventory_levels_and_potions_over_the_network() -> void:
	_port = NetHarness.free_udp_port()
	_server_viewport = NetHarness.make_world_viewport(_root, "")
	var config := ServerConfig.new()
	config.port = _port
	config.zone_id = ZONE_ID
	config.max_players = 8
	config.debug_commands = true
	_server = NetHarness.start_server(_server_viewport, config)
	if not assert_true(_server != null, "el servidor arranca"):
		return
	_server.get_progress().log_sink = func(_text: String) -> void: pass
	await wait_physics_frames(3)
	var curve: LevelCurve = LevelCurve.shared()
	var db: ItemDatabase = ItemDatabase.shared()
	var sword: int = CombatCatalog.weapon_id(&"sword_shield")
	var bow: int = CombatCatalog.weapon_id(&"bow")

	# --- Ana entra sola y sube al nivel 3 antes de que entren los demás. ------------------------------------
	var ana: NetClient = _add_client(VARDHEIM, 1)
	if not assert_true(await _enters(ana), "Ana entra con su inventario"):
		return
	var ana_id: int = ana.get_net_id()
	ana.send_debug_command(NetProtocol.DEBUG_XP_ADD, NetMessages.DebugCommand.xp_add(curve.total_to(3)).payload)
	var leveled: bool = await _wait_until(func() -> bool:
		return ana.get_progress().get_level() == 3 and _server.get_registry().get_entity(ana_id).level == 3, 300)
	if not assert_true(leveled, "Ana sube al nivel 3 (PROGRESS_UPDATE y NetEntity.level)"):
		return

	# --- Bruno (su reino) y Carla (el otro) reciben el SPAWN de Ana: 3 y 0. ---------------------------------
	var bruno: NetClient = _add_client(VARDHEIM, 2)
	var carla: NetClient = _add_client(SOLMARCH, 3)
	if not assert_true(await _enters(bruno) and await _enters(carla), "entran Bruno y Carla"):
		return
	var bruno_id: int = bruno.get_net_id()
	var carla_id: int = carla.get_net_id()
	_server.teleport(ana_id, Vector3(0.0, 0.05, -6.0))
	_server.teleport(bruno_id, Vector3(-2.0, 0.05, 0.0))
	_server.teleport(carla_id, Vector3(2.0, 0.05, 0.0))
	var all_seen: bool = await _wait_until(func() -> bool:
		return _seen_level(bruno, ana_id) >= 0 and _seen_level(carla, ana_id) >= 0 \
				and _seen_level(ana, carla_id) >= 0 and _seen_level(ana, bruno_id) >= 0, 300)
	if not assert_true(all_seen, "cada uno ve a los otros"):
		return
	assert_eq(_seen_level(bruno, ana_id), 3, "Bruno, de su reino, recibe el nivel real de Ana en el SPAWN")
	assert_eq(_seen_level(carla, ana_id), 0, "Carla, del otro reino, recibe 0")
	assert_eq(_seen_level(ana, bruno_id), 1, "Ana ve el nivel 1 de Bruno")
	assert_eq(_seen_level(ana, carla_id), 0, "y el 0 de Carla")

	# --- En el mundo, Ana sube al 4: el LEVEL_UP llega a Bruno y no a Carla. -----------------------------------
	var bruno_hud: HUD = _make_hud(bruno, _viewports[1])
	var carla_hud: HUD = _make_hud(carla, _viewports[2])
	ana.send_debug_command(NetProtocol.DEBUG_XP_ADD,
			NetMessages.DebugCommand.xp_add(curve.total_to(4) - curve.total_to(3)).payload)
	var up: bool = await _wait_until(func() -> bool:
		return ana.get_progress().get_level() == 4 and _seen_level(bruno, ana_id) == 4, 300)
	if not assert_true(up, "Ana sube al 4 y Bruno lo ve por el LEVEL_UP"):
		return
	await wait_physics_frames(30)
	assert_eq(_seen_level(carla, ana_id), 0, "Carla sigue viendo 0: no recibe el LEVEL_UP de otro reino")
	var plate_shown: bool = await _wait_until(func() -> bool:
		bruno_hud.get_nameplates().refresh(0.016)
		var plate: Nameplate = bruno_hud.get_nameplates().get_plate_for(ana_id)
		return plate != null and plate.get_level_text() == "Nv 4", 120)
	assert_true(plate_shown, "la placa de Ana en el HUD de Bruno dice «Nv 4»")
	carla_hud.get_nameplates().refresh(0.016)
	var enemy_plate: Nameplate = carla_hud.get_nameplates().get_plate_for(ana_id)
	assert_eq(enemy_plate.get_level_text() if enemy_plate != null else "", "", "y en el de Carla, sin nivel")

	# --- Ana se equipa el arco de su bolsa con la ventana de inventario. ----------------------------------------
	var ana_hud: HUD = _make_hud(ana, _viewports[0])
	await wait_physics_frames(5)
	var inventory: ClientInventory = ana.get_inventory()
	var window: InventoryWindow = ana_hud.get_inventory_window()
	var bar: ActionBar = ana_hud.get_action_bar()
	var bow_at: Vector2i = _find(inventory.get_view(), &"bow_vado")
	assert_eq(bow_at.x, BAG, "el arco del kit del escudero está en la bolsa")
	assert_eq(_def_at(inventory.get_view(), Vector2i(EQUIPMENT, 0)), &"sword_shield_vado", "con la espada puesta")
	assert_false(bar.get_slot(ActionBar.Slot.SWAP).enabled, "sin segunda arma, el cambio de arma está apagado")
	var bow_uid: int = inventory.get_view().get_item(bow_at.x, bow_at.y).uid
	var before_stats: Array[Dictionary] = []
	for client: NetClient in _clients:
		before_stats.append(client.get_stats())
	assert_eq(window.activate_item(bow_at), InventoryOps.Result.OK, "doble clic en el arco: se pide equiparlo")
	var weapon_2 := Vector2i(EQUIPMENT, InventoryState.EquipmentSlot.WEAPON_2)
	assert_eq(_def_at(inventory.get_view(), weapon_2), &"bow_vado", "la vista lo pone en WEAPON_2 al momento")
	assert_eq(_def_at(inventory.get_confirmed(), weapon_2), &"", "aún sin confirmar")
	assert_eq(inventory.get_pending_count(), 1, "con la petición en vuelo")
	var equipped: bool = await _wait_until(func() -> bool:
		return inventory.get_pending_count() == 0 and _def_at(inventory.get_confirmed(), weapon_2) == &"bow_vado" \
				and _server.get_registry().get_entity(ana_id).get_character().combat.alt_weapon_id == bow \
				and ana.get_character().combat.alt_weapon_id == bow, 300)
	if not assert_true(equipped, "el servidor lo confirma y el LOADOUT pone el arco en la predicción de Ana"):
		return
	assert_eq(inventory.get_confirmed().get_item(weapon_2.x, weapon_2.y).uid, bow_uid, "el mismo uid")
	assert_true(inventory.get_confirmed().get_item(weapon_2.x, weapon_2.y).bound, "ligado al equipar")
	var others_see: bool = await _wait_until(func() -> bool:
		return _seen_weapons(bruno, ana_id) == Vector2i(sword, bow) and _seen_weapons(carla, ana_id) == Vector2i(sword, bow),
			300)
	assert_true(others_see, "Bruno y Carla ven a Ana con la espada y el arco (LOADOUT)")
	var bar_shows: bool = await _wait_until(func() -> bool:
		var swap: ActionBar.ActionSlot = bar.get_slot(ActionBar.Slot.SWAP)
		return swap.enabled and swap.tooltip_text.contains(CombatText.weapon_title(bow)), 60)
	assert_true(bar_shows, "la barra de Ana enseña el cambio al arco")
	assert_true(_same_inventory(inventory.get_confirmed(), _server_progress(ana_id).record.inventory),
			"el confirmado de Ana es el inventario del servidor")
	# Con Q, el arco equipado pasa a la mano: el modelo que ven los otros y los ataques de la barra.
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
	assert_true(in_hand, "Ana cambia al arco: Bruno y Carla se lo ven en la mano y su barra enseña los del arco")
	_set_script(ana, _idle)
	await wait_physics_frames(30)

	# --- Beber gasta una poción de la bolsa. -------------------------------------------------------------------
	var potions_at: Vector2i = _find(inventory.get_confirmed(), &"potion_health")
	var potions: int = inventory.get_confirmed().count_of(&"potion_health")
	assert_eq([potions_at.x, potions], [BAG, 3], "tres pociones de vida en la bolsa")
	var charges_shown: bool = await _wait_until(func() -> bool:
		return bar.get_slot(ActionBar.Slot.CONSUMABLE_1).count == 3, 60)
	assert_true(charges_shown, "la barra enseña sus tres cargas")
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
	if not assert_true(drank, "el CONSUME llega: dos pociones en la bolsa y dos cargas en la barra"):
		return
	assert_eq(_server_progress(ana_id).record.inventory.count_of(&"potion_health"), 2, "y en el servidor")
	_set_script(ana, _idle)
	await wait_physics_frames(30)

	# --- Un rechazo devuelve el objeto. --------------------------------------------------------------------------
	potions_at = _find(inventory.get_confirmed(), &"potion_health")
	var free_slot: int = inventory.get_view().first_free(BAG)
	var rejections: Array[Array] = []
	inventory.request_rejected.connect(func(result: int, text: String) -> void: rejections.append([result, text]))
	ana.send_debug_command(NetProtocol.DEBUG_ITEM_GIVE,
			NetMessages.DebugCommand.item_give(db.net_id_of(&"potion_health"), 1).payload)
	assert_eq(inventory.request(inventory.make_split(potions_at, Vector2i(BAG, free_slot), 1)), InventoryOps.Result.OK,
			"la división vale con lo que ve Ana")
	assert_eq(_count_at(inventory.get_view(), potions_at), 1, "en la vista, la pila baja a 1")
	assert_eq(_count_at(inventory.get_view(), Vector2i(BAG, free_slot)), 1, "y sale una pila provisional")
	var answered: bool = await _wait_until(func() -> bool:
		return inventory.get_pending_count() == 0 and not rejections.is_empty(), 300)
	if not assert_true(answered, "llega la respuesta"):
		return
	assert_eq(rejections, [[InventoryOps.Result.NO_ROOM, InventoryOps.result_text(InventoryOps.Result.NO_ROOM)]],
			"rechazada con NO_ROOM («No cabe»): el servidor puso antes la poción del GM en esa ranura")
	assert_eq(_count_at(inventory.get_view(), potions_at), 2, "la pila vuelve entera a su casilla")
	assert_eq(_count_at(inventory.get_view(), Vector2i(BAG, free_slot)), 1, "y en la ranura, la poción dada")
	assert_false(ClientInventory.is_provisional(inventory.get_view().get_item(BAG, free_slot)), "con su uid real")
	assert_true(_same_inventory(inventory.get_view(), _server_progress(ana_id).record.inventory),
			"la vista de Ana es el inventario del servidor")
	assert_true(ana_hud.get_chat().get_visible_text().contains(InventoryOps.result_text(InventoryOps.Result.NO_ROOM)),
			"el aviso del rechazo sale en el chat")
	var charged: bool = await _wait_until(func() -> bool:
		return bar.get_slot(ActionBar.Slot.CONSUMABLE_1).count == 3, 120)
	assert_true(charged, "la poción dada suma su carga en la barra")

	# --- Ninguna corrección sin explicar. -------------------------------------------------------------------------
	await wait_physics_frames(30)
	for index: int in _clients.size():
		var stats: Dictionary = _clients[index].get_stats()
		assert_eq(stats["unexplained_diffs"], 0, "%s predice sin fallos sin explicar" % _clients[index].get_config().display_name)
		assert_eq(stats["hard_resets"], 0, "ni reinicios duros")
		assert_eq(stats["malformed_packets"], 0, "ni mensajes mal formados")
		print("[progreso] %s: diffs %d -> %d, correcciones %d -> %d" % [_clients[index].get_config().display_name,
				before_stats[index]["diffs"], stats["diffs"], before_stats[index]["corrections"], stats["corrections"]])
