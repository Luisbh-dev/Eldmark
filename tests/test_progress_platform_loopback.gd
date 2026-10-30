extends TestCase
## El personaje persistente de punta a punta con la plataforma falsa (docs/progresion.md §15 P8): un [ZoneServer] con
## [FakeZonePlatform] (plataforma.md §14.3) y [TicketAuthProvider], y clientes de verdad ([NetClient] sobre ENet en
## 127.0.0.1, cada uno en su [SubViewport]) que entran con billetes de prueba firmados con la clave de la zona. La
## zona plana lleva el campamento de Vardheim (la zona segura de sus dos puntos de aparición). Lo que pide §15:
## [br]- Un personaje creado con [code]marksman[/code] ([method FakeZonePlatform.claim_progress]) recibe ese kit en
## su primera entrada (STARTER_KIT en el guardado crítico) con los uids del bloque de ids que da la plataforma
## ([member FakeZonePlatform.next_block_first]), aunque el cliente mande un LOADOUT_SELECT de otra plantilla antes
## de CLIENT_READY; en el mundo, LOADOUT_SELECT tampoco cambia nada.
## [br]- Beber (CONSUME), reponer en el campamento (CAMP_REFILL) y /atascado (con su temporizador de 5 min).
## [br]- Salir y volver: la reclamación siguiente trae lo último guardado y el personaje vuelve con los mismos uids y
## el mismo equipo, la misma arma activa (la segunda, tras cambiar con Q), sus saldos (el oro de un DEBUG_COMMAND 41
## de su cuenta [code]admin[/code]) y la reutilización de /atascado menos el tiempo que estuvo fuera (100 s de la hora
## de la plataforma); y vuelve al campamento de su reino (zona RVR), no adonde se fue.

const VARDHEIM: int = NetProtocol.Realm.VARDHEIM
const BAG: int = InventoryState.ContainerId.BAG
const EQUIPMENT: int = InventoryState.ContainerId.EQUIPMENT
const ZONE_ID: String = "test_world"
const WAIT_FRAMES: int = 900
## La hora Unix de la plataforma falsa al entrar la primera vez; la segunda, 100 s después.
const NOW: int = 1_800_000_000
const AWAY_S: int = 100
const KEY_ID: int = 2
const KEY_HEX: String = "02b7825be38fdd5396a4a058286884eaf93a9df85b874f78b4010a76103fb858"
const FIRST_TICKET_ID: int = 9007199254740001
const CHARACTER_ID: int = 4242
const ACCOUNT_ID: int = 78
## El primer id del primer bloque que da la plataforma falsa (no el de por defecto, para ver que se usa).
const FIRST_ID: int = 70_001
const CAMP: Vector3 = Vector3(-20.0, 0.0, 0.0)
const CAMP_RADIUS: float = 24.0
## Lejos del campamento (fuera de la zona segura) y dentro de la zona plana.
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


# --- Montaje ----------------------------------------------------------------------------------

## La zona plana con el campamento de Vardheim, la plataforma falsa arrancada y en vivo (con su primer bloque de
## ids) y el servidor escuchando con billetes.
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
	# Puntos de control cada 10 min: en la prueba solo salen los críticos y los finales.
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
	if not assert_eq(finished, [[true, ""]], "la plataforma falsa arranca"):
		return false
	var provider := TicketAuthProvider.new(_platform, config.world_id, config.zone_id, config.channel, _keys)
	provider.log_sink = func(_text: String) -> void: pass
	if not assert_eq(_server.start(config, _world, transport, provider, _platform), OK, "el servidor abre el puerto"):
		return false
	_server.get_progress().log_sink = func(_text: String) -> void: pass
	_platform.go_live()
	var ready: bool = await _wait_until(func() -> bool: return _server.get_progress().get_ids().available() > 0)
	return assert_true(ready, "llega el primer bloque de ids")


func _wait_until(condition: Callable, max_frames: int = WAIT_FRAMES) -> bool:
	for _i: int in max_frames:
		if condition.call():
			return true
		await tree.physics_frame
	return condition.call()


## Un billete de prueba del personaje, firmado con la clave de la zona y emitido con la hora de la plataforma.
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


## Un cliente que entra con billete (como el de [code]enter[/code]: personaje y billete en la configuración) y pide
## [param loadout] con LOADOUT_SELECT antes de CLIENT_READY. Vuelve cuando está en el mundo con su inventario,
## quieto.
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
	if not assert_true(entered, "el personaje %d entra con billete" % CHARACTER_ID):
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


## Pulsa [param button] dos ticks, 10 después del último predicho.
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


## [code]{"contenedor:ranura": "uid def_id ×n"}[/code] de un inventario: lo que tiene que volver igual.
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


## Las operaciones de tipo [param kind] de todos los guardados mandados.
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


# --- La prueba ---------------------------------------------------------------------------------

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

	# --- Primera entrada: el kit del tirador con los ids del bloque; LOADOUT_SELECT no cambia nada. -------------
	var ana: NetClient = await _enter("squire")
	if ana == null:
		return
	var ana_id: int = ana.get_net_id()
	assert_eq(ana.get_stats()["loadout_selects"], 1, "el cliente pidió el escudero antes de CLIENT_READY")
	var inventory: ClientInventory = ana.get_inventory()
	var confirmed: InventoryState = inventory.get_confirmed()
	assert_eq([_def_at(confirmed, EQUIPMENT, 0), _def_at(confirmed, EQUIPMENT, 1)], [&"bow_vado", &"sword_shield_vado"],
			"con el kit del tirador (el de su creación), no el del escudero")
	assert_eq([confirmed.count_of(&"potion_health"), confirmed.count_of(&"potion_stamina")], [3, 2],
			"y las pociones del campamento")
	for item: ItemInstance in confirmed.all_items():
		assert_true(item.uid >= FIRST_ID and item.uid < FIRST_ID + 1024,
				"el uid %d de %s sale del bloque de la plataforma" % [item.uid, item.def_id])
	assert_eq(_server.get_combat().get_combatant(ana_id).template_id, 0, "el equipo de su inventario, sin plantilla")
	assert_eq([_combat(ana).weapon_id, _combat(ana).alt_weapon_id], [bow, sword], "con el arco en la mano")
	assert_eq([ana.get_character().combat.weapon_id, ana.get_character().combat.alt_weapon_id], [bow, sword],
			"también en su predicción")
	var kit_saved: bool = await _wait_until(func() -> bool:
		return _ops_of_kind(EconomyOp.Kind.STARTER_KIT).size() == 1 and _server.get_saver().pending_count() == 0)
	assert_true(kit_saved, "el kit sale en un STARTER_KIT, en el guardado crítico de la llegada")
	var kit_events: Array = _ops_of_kind(EconomyOp.Kind.STARTER_KIT)[0]["items"]
	assert_eq(kit_events.size(), confirmed.all_items().size(), "un evento por pila del kit")
	assert_true(ana.send_loadout_select(squire), "pide el escudero en el mundo")
	await wait_physics_frames(30)
	assert_eq(_peer_of(ana_id).pending_template_id, -1, "con inventario no queda nada pendiente")
	assert_eq([_combat(ana).weapon_id, _combat(ana).alt_weapon_id], [bow, sword], "y las armas no cambian")

	# --- Beber y reponer en el campamento. -------------------------------------------------------------------------
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
	if not assert_true(drank, "beber gasta una poción de la bolsa (CONSUME)"):
		return
	_set_script(ana, _idle)
	var refilled: bool = await _wait_until(func() -> bool:
		return reasons.has(EconomyReason.CAMP_REFILL) and inventory.get_confirmed().count_of(&"potion_health") == 3,
			300)
	assert_true(refilled, "el campamento la repone (CAMP_REFILL)")
	assert_eq(reasons.slice(reasons.find(EconomyReason.CONSUME)), [EconomyReason.CONSUME, EconomyReason.CAMP_REFILL],
			"primero el CONSUME y después la recarga")
	assert_eq(inventory.get_confirmed().get_item(potions_at.x, potions_at.y).uid, potion_uid, "en la misma pila")

	# --- /atascado lejos del campamento: vuelve a su reino y deja 5 min de reutilización. ---------------------------
	var unstuck: UnstuckTracker = _server.get_unstuck()
	unstuck.channel_ticks = 30
	var key: String = _server.unstuck_key_of(_server.get_registry().get_entity(ana_id))
	assert_eq(key, "character:%d" % CHARACTER_ID, "con plataforma, /atascado va por el personaje")
	_server.teleport(ana_id, AWAY)
	await wait_physics_frames(10)
	var transport: NetTransport = ana.get_meta(&"transport") as NetTransport
	transport.send(NetClient.SERVER_PEER_ID, NetProtocol.CH_RELIABLE, NetMessages.UnstuckRequest.new().encode())
	var moved: bool = await _wait_until(func() -> bool: return unstuck.completed_count == 1, 300)
	if not assert_true(moved, "/atascado se completa"):
		return
	var position: Vector3 = _server.get_registry().get_entity(ana_id).get_position()
	assert_true(position.distance_to(CAMP) < CAMP_RADIUS, "y la deja en un punto de su reino: %s" % position)
	assert_eq(_player(ana).record.timers.get("unstuck", 0), NOW + UNSTUCK_COOLDOWN_S,
			"el temporizador unstuck acaba 5 min después, en hora Unix")

	# --- Oro (su cuenta es admin), la segunda arma en la mano y lejos del campamento. -------------------------------
	ana.send_debug_command(NetProtocol.DEBUG_CURRENCY_ADD,
			NetMessages.DebugCommand.currency_add(Currency.Code.GOLD, 50).payload)
	var paid: bool = await _wait_until(func() -> bool:
		return ana.get_progress().get_balance(Currency.Code.GOLD) == 50 \
				and _ops_of_kind(EconomyOp.Kind.GM).size() == 1, 300)
	assert_true(paid, "50 de oro por DEBUG_COMMAND 41 (una operación GM, en un guardado crítico)")
	_press(ana, PlayerInput.SWAP_WEAPON)
	var swapped: bool = await _wait_until(func() -> bool:
		return _combat(ana).weapon_id == sword and ana.get_character().combat.weapon_id == sword \
				and _combat(ana).action == CombatState.Action.NONE, 300)
	if not assert_true(swapped, "cambia a la espada (la segunda ranura)"):
		return
	_set_script(ana, _idle)
	assert_eq(_combat(ana).combat_flags2 & CombatState.FLAG2_SECOND_SLOT, CombatState.FLAG2_SECOND_SLOT,
			"la ranura activa es la segunda")
	_server.teleport(ana_id, AWAY)
	await wait_physics_frames(20)

	# --- Sale: el guardado final lo lleva todo. ---------------------------------------------------------------------
	var layout: Dictionary = _layout(_player(ana).record.inventory)
	assert_eq(_layout(inventory.get_confirmed()), layout, "el cliente tenía lo mismo que el servidor")
	var saves_before: int = _saves().size()
	ana.leave()
	var released: bool = await _wait_until(func() -> bool:
		return _server.get_progress().get_player(ana_id) == null and _server.get_saver().pending_count() == 0 \
				and _saves().size() > saves_before, 300)
	if not assert_true(released, "el cuerpo se va con su guardado final"):
		return
	var final: Dictionary = _platform.applied(CHARACTER_ID)["progress"]
	assert_eq(int(final["active_weapon_slot"]), 1, "se guarda la segunda ranura activa")
	var timers: Array = final["timers"]
	assert_eq(timers.map(func(timer: Dictionary) -> Array: return [timer["key"], int(timer["ends_at_unix"])]),
			[["unstuck", NOW + UNSTUCK_COOLDOWN_S]], "y /atascado")
	assert_true(Vector3(final["location"]["x"], final["location"]["y"], final["location"]["z"]).distance_to(AWAY) < 1.0,
			"y dónde se fue")

	# --- Vuelve 100 s después. ----------------------------------------------------------------------------------------
	_platform.fake_now_unix = NOW + AWAY_S
	var again: NetClient = await _enter("")
	if again == null:
		return
	var again_id: int = again.get_net_id()
	var arrival: int = _server.get_tick()
	assert_eq(_layout(_player(again).record.inventory), layout, "en el servidor, los mismos uids, ranuras y pilas")
	assert_eq(_layout(again.get_inventory().get_confirmed()), layout, "y en el cliente")
	assert_eq(_ops_of_kind(EconomyOp.Kind.STARTER_KIT).size(), 1, "sin otro kit")
	assert_eq(again.get_progress().get_balance(Currency.Code.GOLD), 50, "con su oro")
	assert_eq([_combat(again).weapon_id, _combat(again).alt_weapon_id], [sword, bow],
			"con la espada en la mano: la segunda ranura sigue activa")
	assert_eq(again.get_character().combat.weapon_id, sword, "también en su predicción")
	var back: Vector3 = _server.get_registry().get_entity(again_id).get_position()
	var at_camp: bool = false
	for spawn: Vector3 in ZoneFixture.VARDHEIM_SPAWNS:
		at_camp = at_camp or Vector3(back.x, 0.0, back.z).distance_to(spawn) < 0.5
	assert_true(at_camp, "en el campamento de su reino (zona RVR), no donde se fue: %s" % back)
	var left_ticks: int = unstuck.get_ready_at(key) - arrival
	assert_true(absi(left_ticks - (UNSTUCK_COOLDOWN_S - AWAY_S) * 60) <= 60,
			"la reutilización de /atascado, menos los 100 s fuera: %d ticks" % left_ticks)
	var notices: Array[String] = []
	again.notice_received.connect(func(_code: int, text: String) -> void: notices.append(text))
	(again.get_meta(&"transport") as NetTransport).send(NetClient.SERVER_PEER_ID, NetProtocol.CH_RELIABLE,
			NetMessages.UnstuckRequest.new().encode())
	var refused: bool = await _wait_until(func() -> bool: return not notices.is_empty(), 120)
	assert_true(refused and notices[0].begins_with("/atascado: disponible de nuevo en"),
			"y no se puede usar: %s" % [notices])
	assert_eq(again.get_stats()["unexplained_diffs"], 0, "predice sin fallos sin explicar")
	assert_eq(ana.get_stats()["unexplained_diffs"], 0, "también en la primera sesión")
