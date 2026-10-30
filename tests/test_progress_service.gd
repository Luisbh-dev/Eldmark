extends TestCase
## Pruebas del inventario en la zona (docs/progresion.md §4, §8 y §9; §15, P5b): el alta con el
## [ProgressService.Loadout] del inventario y la ranura activa; equipar y desequipar sin reiniciar reutilizaciones;
## CONSUME al comprometer y no al interrumpir; CAMP_REFILL por total y con la cadencia de la recarga, y el aviso de
## la bolsa llena una vez por entrada; cargas [code]min(15, bolsa)[/code]; peticiones antes del mundo, mal formadas,
## sincronías seguidas y RATE con su aviso; un cliente que manda 10 000 SPLIT y juntar (ningún evento, ids acotados
## por RATE, otro jugador sigue bebiendo y guardando); /atascado restaurado por su clave; muerto se guarda para
## reaparecer (vida y campamento al volver); y el escudero que pone el arco en WEAPON_2, cambia a él, desequipa
## WEAPON_1, muere y reaparece con el arco activo, con un guardado siguiente que pasa S5.
## [br][br]
## Un [ZoneServer] sin red sobre la zona plana de [ZoneFixture], avanzado deprisa con [FortressFixture.Stepper], con
## peers montados a mano (como el alta de verdad: LOADING, CLIENT_READY y, con plataforma, la reclamación y
## [method ProgressService.prepare]), sus entradas en su [InputQueue] y un transporte que apunta lo que se les manda.
## Las que guardan usan [FakeZonePlatform] (plataforma.md §14.3).

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
## La hora Unix de la plataforma falsa.
const NOW: int = 1_800_000_000
const KEYS: Dictionary = {2: "02b7825be38fdd5396a4a058286884eaf93a9df85b874f78b4010a76103fb858"}
## El campamento de Vardheim de las pruebas que lo piden: cubre sus dos puntos de aparición.
const CAMP: Vector3 = Vector3(-20.0, 0.0, 0.0)
const CAMP_RADIUS: float = 24.0


## Un transporte que no conecta nada y apunta lo que el servidor manda a cada peer (sin los SNAPSHOT), con el tick.
class RecordingTransport:
	extends NetTransport

	var server: ZoneServer = null
	## peer_id -> [[tick, bytes], …] en orden.
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


# --- Montaje ----------------------------------------------------------------------------------

## La zona plana (con el campamento de Vardheim si [param camp]) y el servidor sin red; con [param with_platform], la
## plataforma falsa ya arrancada y en vivo, y el primer bloque de ids recibido.
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
		if not assert_eq(finished, [[true, ""]], "la plataforma falsa arranca"):
			return false
		var tickets := TicketAuthProvider.new(_platform, config.world_id, config.zone_id, config.channel, keys)
		tickets.log_sink = func(_text: String) -> void: pass
		provider = tickets
	if not assert_eq(_server.start(config, _world, null, provider, _platform), OK, "el servidor arranca"):
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
		if not assert_true(ready, "llega el primer bloque de ids"):
			return false
	return true


func _progress() -> ProgressService:
	return _server.get_progress()


func _advance(ticks: int) -> void:
	_stepper.remaining += ticks
	while _stepper.remaining > 0:
		await tree.physics_frame


## Avanza de 2 en 2 ticks hasta que se cumpla [param condition] (con plataforma, sus respuestas llegan entre
## fotogramas) o pasen [param max_ticks].
func _advance_until(condition: Callable, max_ticks: int = 600) -> bool:
	var elapsed: int = 0
	while elapsed < max_ticks:
		if condition.call():
			return true
		await _advance(2)
		await wait_process_frames()
		elapsed += 2
	return bool(condition.call())


## Avanza hasta el primer tick múltiplo de la recarga del campamento (60) posterior al actual, incluido.
func _advance_to_camp_tick() -> int:
	var interval: int = CombatDirector.RECHARGE_INTERVAL_TICKS
	var target: int = (_server.get_tick() / interval + 1) * interval
	await _advance(target - _server.get_tick())
	return target


## Monta un peer como el alta de verdad: LOADING (con [param template_id] como plantilla pendiente de
## LOADOUT_SELECT), con plataforma su reclamación y [method ProgressService.prepare], y CLIENT_READY: aparece al
## final del tick siguiente.
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
		assert_true(_progress().prepare(peer_id, claimed), "se prepara el registro")
	_server._pending_ready.append(peer_id)
	await _advance(1)
	assert_not_null(peer.entity, "el peer %d entra en el mundo" % peer_id)
	return peer


## La reclamación siguiente de [param character_id] en la plataforma falsa, con la ida y vuelta por JSON.
func _claim(character_id: int) -> ClaimedCharacter:
	var answer: Array = _platform._claim_answer({"character_id": str(character_id), "ticket_id": "1"})
	var body: Variant = JSON.parse_string(JSON.stringify(answer[1]))
	return ClaimedCharacter.from_claim(body)


## Sale [param peer] (como un CLIENT_LEAVE) y espera a que la plataforma conteste su guardado final.
func _leave(peer: ServerPeer) -> void:
	var saves_before: int = _platform.sent(PlatformEvent.KIND_SAVE).size() if _platform != null else 0
	_server._mark_leaving(peer)
	await _advance(1)
	if _platform != null:
		await _advance_until(func() -> bool:
			return _platform.sent(PlatformEvent.KIND_SAVE).size() > saves_before \
					and _server.get_saver().pending_count() == 0)
	_server._peers.erase(peer.peer_id)


## Una entrada de [param peer] para el tick [param tick] con [param buttons], mirando a [param yaw].
func _push_input(peer: ServerPeer, tick: int, buttons: int, yaw: float) -> void:
	var input := PlayerInput.new()
	input.tick = tick
	input.buttons = buttons
	input.look_yaw = yaw
	peer.input_queue.push(input.quantized(), 0, _server.get_tick() + 1)


## Pulsa [param button] en los ticks [param at] y [param at] + 1 y lo suelta en [param at] + 2 (las sustitutas
## repiten la última entrada: la neutra la cierra).
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


## Manda una INVENTORY_REQUEST de [param peer] por la entrada de la red de la zona (con el limitador de los
## fiables) y devuelve su request_id.
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


## La respuesta a la petición [param request_id] (la última), o null.
func _answer(peer_id: int, request_id: int) -> ProgressMessages.InventoryDelta:
	var found: ProgressMessages.InventoryDelta = null
	for delta: ProgressMessages.InventoryDelta in _deltas(peer_id):
		if delta != null and delta.request_id == request_id:
			found = delta
	return found


## Los cambios del servidor con [param reason], como [code][tick, delta][/code].
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


## Lo que S5 (§13.3) comprueba de la foto [param progress] sin la base: uids sin repetir, contenedor 0–1, ranuras
## únicas, bolsa por debajo de bag_slots y equipo 0–1, definición, cantidad, durabilidad, rareza 0 y sin afijos, y en
## el equipo un arma por ranura con la activa armada (I10). Vacío si todo vale.
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


# --- Alta -------------------------------------------------------------------------------------

func test_the_arrival_uses_the_inventory_loadout_and_the_active_slot() -> void:
	if not await _start(false):
		return
	var bow: int = _weapon(&"bow")
	var sword: int = _weapon(&"sword_shield")
	# Sin plataforma, efímero (§9.4): el kit del tirador que pidió con LOADOUT_SELECT antes de CLIENT_READY.
	var ana: ServerPeer = await _enter(201, VARDHEIM, null, CombatCatalog.template_id(&"marksman"))
	var net_id: int = ana.entity.net_id
	var player: PlayerProgress = _player(net_id)
	assert_true(player != null and not player.persistent, "efímero, con inventario")
	assert_eq([_def(net_id, EQUIPMENT, 0), _def(net_id, EQUIPMENT, 1)], [&"bow_vado", &"sword_shield_vado"],
			"las armas del tirador en las ranuras 0 y 1")
	assert_eq([_def(net_id, BAG, 0), _count(net_id, BAG, 0), _def(net_id, BAG, 1), _count(net_id, BAG, 1)],
			[&"potion_health", 3, &"potion_stamina", 2], "las pociones del campamento en la bolsa")
	var combat: CombatState = _combat(net_id)
	assert_eq([combat.weapon_id, combat.alt_weapon_id, combat.is_second_slot()], [bow, sword, false],
			"en la mano, la ranura 0")
	assert_eq(combat.consumable_charges, CombatState.pack_charges(3, 2), "cargas = pociones de la bolsa")
	assert_eq(_combatant(net_id).template_id, 0, "sin plantilla vigente: el equipo del inventario")
	var loadouts: Array[NetMessages.EntityEvent] = _loadouts(net_id)
	if assert_eq(loadouts.size(), 2, "LOADOUT del dueño y el público"):
		assert_eq([loadouts[0].template_id, loadouts[0].weapon_1, loadouts[0].weapon_2, loadouts[0].charges],
				[0, bow, sword, CombatState.pack_charges(3, 2)], "plantilla 0 = el equipo del inventario")
	var catalog: AppearanceCatalog = AppearanceCatalog.shared()
	var race: RaceDefinition = catalog.race_for_realm(RealmCatalog.id_of_code(VARDHEIM))
	assert_eq(ana.entity.level, 1, "nivel en la entidad")
	assert_eq(ana.entity.appearance, CharacterAppearance.default_for(catalog, catalog.race_index(race.id)).encode(),
			"y la apariencia por defecto de su pueblo")
	# Lo que recibe, en orden: su SPAWN, el inventario entero, sus dos monedas y su progreso.
	var types: Array[int] = []
	for entry: Array in _recorder.sent.get(201, []):
		types.append(NetMessages.peek_type(entry[1]))
	var spawn_at: int = types.find(NetProtocol.MSG_ENTITY_SPAWN)
	var full_at: int = types.find(NetProtocol.MSG_INVENTORY_FULL)
	assert_true(spawn_at >= 0 and full_at > spawn_at, "INVENTORY_FULL tras el SPAWN propio: %s" % [types])
	var pages: Array[ProgressMessages.InventoryFull] = []
	for bytes: PackedByteArray in _messages(201, NetProtocol.MSG_INVENTORY_FULL):
		pages.append(ProgressMessages.InventoryFull.decode(bytes))
	var assembled: InventoryState = ProgressMessages.InventoryFull.assemble(pages)
	assert_true(assembled != null and assembled.equals(_inventory(net_id)), "el FULL es el inventario del servidor")
	assert_eq(pages[0].revision, player.revision, "con su revisión")
	var wallets: Array[PackedByteArray] = _messages(201, NetProtocol.MSG_WALLET_UPDATE)
	assert_eq(wallets.size(), 2, "un WALLET_UPDATE por moneda")
	for bytes: PackedByteArray in wallets:
		var wallet: ProgressMessages.WalletUpdate = ProgressMessages.WalletUpdate.decode(bytes)
		assert_eq([wallet.balance, wallet.delta, wallet.reason], [0, 0, 0], "el estado inicial")
	var progress: Array[PackedByteArray] = _messages(201, NetProtocol.MSG_PROGRESS_UPDATE)
	if assert_eq(progress.size(), 1, "un PROGRESS_UPDATE"):
		var update: ProgressMessages.ProgressUpdate = ProgressMessages.ProgressUpdate.decode(progress[0])
		assert_eq([update.level, update.xp_in_level, update.xp_to_next, update.gained, update.source],
				[1, 0, 500, 0, ProgressMessages.XpSource.STATE], "nivel 1, a 500 del siguiente")
	# LOADOUT_SELECT ya no cambia nada: ni pendiente ni aviso, y reaparece con su equipo.
	var strikes: int = ana.strikes_total
	_server._on_packet_received(201, NetMessages.LoadoutSelect.make(CombatCatalog.template_id(&"squire")).encode())
	assert_eq([ana.pending_template_id, ana.strikes_total], [-1, strikes], "nada pendiente y sin aviso")
	_server.get_combat().kill(_combatant(net_id), _server.get_tick() + 1)
	await _advance(1)
	var timing: CombatTiming = _server.get_combat_timing()
	await _advance(maxi(_combatant(net_id).respawn_tick - _server.get_tick(), 0) + 1)
	_events.clear()
	_involved.clear()
	assert_eq(_server.get_combat().request_respawn(net_id, 0, _server.get_tick() + 1),
			CombatDirector.RespawnRequestResult.ACCEPTED)
	await _advance(2)
	assert_true(_combatant(net_id).is_alive(), "reaparece (plazo %d)" % timing.respawn)
	combat = _combat(net_id)
	assert_eq([combat.weapon_id, combat.alt_weapon_id, combat.consumable_charges],
			[bow, sword, CombatState.pack_charges(3, 2)], "con su equipo, no con el escudero")
	var after: Array[NetMessages.EntityEvent] = _loadouts(net_id, true)
	assert_true(not after.is_empty() and after[0].template_id == 0, "y su LOADOUT, con plantilla 0")

	# Un registro guardado (preparado como la reclamación) con la ranura 1 activa y 400 de vida.
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
			"entra con la ranura 1 activa (bit0 de combat_flags2)")
	assert_eq(_combatant(bruno_id).health, 400, "con su vida (sin reloj, sin regeneración)")
	assert_true(bruno.entity.get_position().distance_to(Vector3(5.0, 0.0, 5.0)) > 10.0,
			"y en una zona RVR, en el campamento de su reino, no donde se guardó")


# --- Equipar ----------------------------------------------------------------------------------

func test_equipping_and_unequipping_keep_the_cooldowns() -> void:
	if not await _start(false):
		return
	var bow: int = _weapon(&"bow")
	var sword: int = _weapon(&"sword_shield")
	var ana: ServerPeer = await _enter(211, VARDHEIM)
	var net_id: int = ana.entity.net_id
	assert_eq([_def(net_id, EQUIPMENT, 0), _def(net_id, BAG, 0)], [&"sword_shield_vado", &"bow_vado"],
			"el escudero: la espada puesta y el arco en la bolsa")
	var s: int = _server.get_tick()
	var combat: CombatState = _combat(net_id)
	var sword_ready := PackedInt64Array([s + 900, s + 1000, s + 1100])
	for i: int in 3:
		combat.ability_ready[i] = sword_ready[i]
	CombatDirector.commit_state(ana.entity.get_character())
	var revision: int = _player(net_id).revision
	# Equipar el arco en WEAPON_2.
	_events.clear()
	_involved.clear()
	var id: int = _request(ana, MOVE, BAG, 0, EQUIPMENT, 1, 0, _uid(net_id, BAG, 0))
	await _advance(1)
	var delta: ProgressMessages.InventoryDelta = _answer(211, id)
	if assert_not_null(delta, "responde"):
		assert_eq([delta.result, delta.revision, delta.reason, delta.entries.size()],
				[InventoryOps.Result.OK, revision + 1, 0, 2], "OK, la revisión siguiente y las dos ranuras")
	combat = _combat(net_id)
	assert_eq([combat.weapon_id, combat.alt_weapon_id], [sword, bow], "el arco en la ranura 2")
	assert_eq(combat.ability_ready.slice(0, 3), sword_ready, "sin tocar las reutilizaciones de la espada")
	assert_eq(combat.ability_ready.slice(3, 6), PackedInt64Array([0, 0, 0]), "el arco, sin ninguna")
	var loadouts: Array[NetMessages.EntityEvent] = _loadouts(net_id)
	if assert_eq(loadouts.size(), 2, "LOADOUT al dueño y, con armas nuevas, a los demás"):
		assert_eq([loadouts[0].template_id, loadouts[0].weapon_1, loadouts[0].weapon_2], [0, sword, bow])
	# El arco con reutilizaciones; desequiparlo y volver a ponerlo las conserva.
	var bow_ready := PackedInt64Array([s + 2000, s + 2100, s + 2200])
	for i: int in 3:
		combat.ability_ready[3 + i] = bow_ready[i]
	CombatDirector.commit_state(ana.entity.get_character())
	id = _request(ana, MOVE, EQUIPMENT, 1, BAG, 5, 0, _uid(net_id, EQUIPMENT, 1))
	await _advance(1)
	assert_eq(_answer(211, id).result, InventoryOps.Result.OK, "desequipar el arco")
	combat = _combat(net_id)
	assert_eq([combat.weapon_id, combat.alt_weapon_id], [sword, 0])
	assert_eq(combat.ability_ready.slice(3, 6), PackedInt64Array([0, 0, 0]), "sin arma en la ranura 2")
	id = _request(ana, MOVE, BAG, 5, EQUIPMENT, 1, 0, _uid(net_id, BAG, 5))
	await _advance(1)
	assert_eq(_answer(211, id).result, InventoryOps.Result.OK, "volver a equiparlo")
	combat = _combat(net_id)
	assert_eq(combat.ability_ready.slice(3, 6), bow_ready, "vuelve con las suyas")
	assert_eq(combat.ability_ready.slice(0, 3), sword_ready, "y la espada sigue con las suyas")
	# Intercambiar las dos ranuras: la activa (0) pasa a tener el arco, cada arma con sus reutilizaciones.
	id = _request(ana, MOVE, EQUIPMENT, 0, EQUIPMENT, 1, 0, _uid(net_id, EQUIPMENT, 0))
	await _advance(1)
	assert_eq(_answer(211, id).result, InventoryOps.Result.OK, "intercambiar las armas")
	combat = _combat(net_id)
	assert_eq([combat.weapon_id, combat.alt_weapon_id, combat.is_second_slot()], [bow, sword, false])
	assert_eq(combat.ability_ready.slice(0, 3), bow_ready, "el arco en la mano, con las suyas")
	assert_eq(combat.ability_ready.slice(3, 6), sword_ready, "la espada en la otra, con las suyas")
	# Dejar vacía la ranura activa: WEAPON_REQUIRED, con el contenido real de las dos ranuras.
	revision = _player(net_id).revision
	id = _request(ana, MOVE, EQUIPMENT, 0, BAG, 6, 0, _uid(net_id, EQUIPMENT, 0))
	await _advance(1)
	delta = _answer(211, id)
	assert_eq([delta.result, delta.revision], [InventoryOps.Result.WEAPON_REQUIRED, revision], "sin cambio")
	assert_eq([delta.entries[0].container, delta.entries[0].slot, delta.entries[0].item.def_id],
			[EQUIPMENT, 0, &"bow_vado"], "el arco sigue en su sitio")
	assert_eq([delta.entries[1].container, delta.entries[1].slot, delta.entries[1].item], [BAG, 6, null])
	# En combate: NOT_NOW.
	_combatant(net_id).mark_combat(_server.get_tick())
	id = _request(ana, MOVE, EQUIPMENT, 1, BAG, 6, 0, _uid(net_id, EQUIPMENT, 1))
	await _advance(1)
	assert_eq(_answer(211, id).result, InventoryOps.Result.NOT_NOW, "no se cambia el equipo en combate")
	assert_eq(_def(net_id, EQUIPMENT, 1), &"sword_shield_vado")
	# Dos peticiones en el mismo tick se aplican en orden de llegada (la segunda mueve lo que movió la primera).
	var potion: int = _uid(net_id, BAG, 1)
	var first: int = _request(ana, MOVE, BAG, 1, BAG, 3, 0, potion)
	var second: int = _request(ana, MOVE, BAG, 3, BAG, 4, 0, potion)
	assert_eq(_progress().pending_count(), 2, "en cola hasta el final del tick")
	await _advance(1)
	assert_eq([_answer(211, first).result, _answer(211, second).result], [InventoryOps.Result.OK,
			InventoryOps.Result.OK], "las dos, en orden")
	assert_eq(_uid(net_id, BAG, 4), potion)
	# Una que no vale suma un aviso.
	var strikes: int = ana.strikes_total
	id = _request(ana, MOVE, BAG, 4, BAG, 7, 3, potion)
	await _advance(1)
	assert_eq(_answer(211, id).result, InventoryOps.Result.INVALID)
	assert_eq(ana.strikes_total, strikes + 1, "INVALID suma un aviso")
	assert_eq(ana.last_strike_reason, ProgressService.STRIKE_INVALID)


# --- Consumibles ------------------------------------------------------------------------------

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
	assert_eq(_count(net_id, BAG, 1), 3, "3 pociones de vida en la bolsa")
	# Un golpe interrumpe antes del compromiso: ni carga ni poción.
	var drink: int = _server.get_tick() + 2
	_press(ana, PlayerInput.CONSUMABLE_1, drink, PI)
	holds.append(Vector3i(PlayerInput.PRIMARY, drink + 2, drink + 4))
	assert_true(drink + 2 + light.windup_ticks < drink + potion.cast_ticks, "el golpe llega antes del compromiso")
	await _advance(drink + potion.cast_ticks + 10 - _server.get_tick())
	assert_eq(_combat(net_id).charges_of(0), 3, "beber interrumpido no gasta la carga")
	assert_eq(_count(net_id, BAG, 1), 3, "ni la poción")
	assert_eq(_server_changes(221, EconomyReason.CONSUME).size(), 0, "ni hay CONSUME")
	# Sin golpe: al comprometer, una poción menos de la pila de la ranura más baja.
	var revision: int = _player(net_id).revision
	_combat(net_id).consumable_ready_tick = 0
	CombatDirector.commit_state(ana.entity.get_character())
	var loadouts_before: int = _loadouts(net_id).size()
	drink = _server.get_tick() + 2
	_press(ana, PlayerInput.CONSUMABLE_1, drink, PI)
	var commit: int = drink + potion.cast_ticks
	await _advance(commit - 1 - _server.get_tick())
	assert_eq(_count(net_id, BAG, 1), 3, "bebiendo, aún nada")
	await _advance(1)
	assert_eq(_combat(net_id).charges_of(0), 2, "el compromiso gasta la carga")
	assert_eq(_count(net_id, BAG, 1), 2, "y la poción, en el mismo tick")
	var consumed: Array[Array] = _server_changes(221, EconomyReason.CONSUME)
	if assert_eq(consumed.size(), 1, "un INVENTORY_DELTA del servidor"):
		var change: ProgressMessages.InventoryDelta = consumed[0][1]
		assert_eq(consumed[0][0], commit, "en el tick del compromiso")
		assert_eq([change.revision, change.entries.size(), change.entries[0].slot, change.entries[0].item.count],
				[revision + 1, 1, 1, 2], "con la ranura que cambió")
	assert_eq(_loadouts(net_id).size(), loadouts_before, "las cargas ya cuadran: sin LOADOUT")
	assert_eq(_player(net_id).pending_aggregate_count(), 1, "agregado (un evento sin uid)")
	# Con más de 15 en la bolsa: tras beber, la carga vuelve a 15 con un LOADOUT al dueño.
	_player(net_id).gain_items(&"potion_health", 18, EconomyReason.CAMP_REFILL)
	assert_eq(_inventory(net_id).count_of(&"potion_health"), 20)
	_combat(net_id).consumable_ready_tick = 0
	CombatDirector.commit_state(ana.entity.get_character())
	drink = _server.get_tick() + 2
	_press(ana, PlayerInput.CONSUMABLE_1, drink, PI)
	await _advance(drink + potion.cast_ticks + 1 - _server.get_tick())
	assert_eq(_inventory(net_id).count_of(&"potion_health"), 19, "una menos")
	assert_eq(_combat(net_id).charges_of(0), 15, "cargas = min(15, bolsa)")
	var owner: Array[NetMessages.EntityEvent] = _loadouts(net_id, true)
	assert_eq(owner[-1].charges, CombatState.pack_charges(15, 2), "con su LOADOUT al dueño")


# --- Campamento -------------------------------------------------------------------------------

func test_the_camp_refills_the_total_with_the_recharge_cadence() -> void:
	if not await _start(false, true):
		return
	var ana: ServerPeer = await _enter(231, VARDHEIM)
	var net_id: int = ana.entity.net_id
	var safe: SafeAreas = _server.get_safe_areas()
	assert_true(safe.contains_own(VARDHEIM, ana.entity.get_position()), "aparece en el campamento")
	# Un falso con plantilla en el mismo campamento sigue con la recarga de habilidades.md.
	var fake: int = _server.add_fake_player(CombatFixture.ScriptBrain.new(1), VARDHEIM)
	_server.teleport(fake, CAMP + Vector3(1.0, 0.05, 0.0))
	ActionMachine.set_charges(_combat(fake), 0)
	CombatDirector.commit_state(_server.get_registry().get_entity(fake).get_character())
	# Dividir la pila no da más: el total sigue siendo 3.
	var id: int = _request(ana, SPLIT, BAG, 1, BAG, 5, 1, _uid(net_id, BAG, 1))
	await _advance(1)
	assert_eq(_answer(231, id).result, InventoryOps.Result.OK, "dividir 3 en 2 y 1")
	await _advance_to_camp_tick()
	await _advance(1)
	assert_eq(_server_changes(231, EconomyReason.CAMP_REFILL).size(), 0, "dividir no da más pociones")
	assert_eq(_combat(fake).consumable_charges, CombatCatalog.template_charges(CombatCatalog.default_template_id()),
			"el falso, con las cargas de su plantilla")
	# Destruir la de 1: faltan una de 3; las cargas bajan con su LOADOUT.
	id = _request(ana, DESTROY, BAG, 5, NO_SLOT, NO_SLOT, 0, _uid(net_id, BAG, 5))
	await _advance(1)
	assert_eq(_answer(231, id).result, InventoryOps.Result.OK, "destruir la pila de 1")
	assert_eq(_combat(net_id).consumable_charges, CombatState.pack_charges(2, 2), "2 pociones de vida")
	assert_eq(_loadouts(net_id, true)[-1].charges, CombatState.pack_charges(2, 2), "con su LOADOUT")
	var camp_tick: int = await _advance_to_camp_tick()
	var refills: Array[Array] = _server_changes(231, EconomyReason.CAMP_REFILL)
	if assert_eq(refills.size(), 1, "CAMP_REFILL en la recarga"):
		var change: ProgressMessages.InventoryDelta = refills[0][1]
		assert_eq(refills[0][0], camp_tick, "con la cadencia de la recarga (cada 60 ticks)")
		assert_eq([change.entries.size(), change.entries[0].container, change.entries[0].slot,
				change.entries[0].item.count], [1, BAG, 1, 3], "a la pila de la ranura más baja, hasta 3")
	assert_eq(_combat(net_id).consumable_charges, CombatState.pack_charges(3, 2), "y las cargas vuelven a 3")
	# Bolsa llena sin pociones de resistencia: NOTICE una vez por entrada en el campamento.
	var player: PlayerProgress = _player(net_id)
	assert_true(player.gain_items(&"bow_vado", _inventory(net_id).free_count(BAG), EconomyReason.CAMP_REFILL),
			"la bolsa, llena de arcos")
	var stamina: int = _inventory(net_id).find_uid(_uid(net_id, BAG, 2)).y
	id = _request(ana, DESTROY, BAG, stamina, NO_SLOT, NO_SLOT, 0, _uid(net_id, BAG, stamina))
	await _advance(1)
	assert_eq(_answer(231, id).result, InventoryOps.Result.OK, "sin pociones de resistencia")
	assert_true(player.gain_items(&"bow_vado", 1, EconomyReason.CAMP_REFILL), "y su hueco, también lleno")
	await _advance_to_camp_tick()
	assert_eq(Array(_notice_texts(231)).count(ProgressService.BAG_FULL_TEXT), 1, "«Bolsa llena»")
	await _advance_to_camp_tick()
	assert_eq(Array(_notice_texts(231)).count(ProgressService.BAG_FULL_TEXT), 1, "una vez por entrada")
	_server.teleport(net_id, Vector3(15.0, 0.05, 0.0))
	await _advance_to_camp_tick()
	await _advance_to_camp_tick()
	_server.teleport(net_id, CAMP + Vector3(0.0, 0.05, 2.0))
	await _advance_to_camp_tick()
	assert_eq(Array(_notice_texts(231)).count(ProgressService.BAG_FULL_TEXT), 2, "y otra al volver a entrar")
	assert_eq(_inventory(net_id).count_of(&"potion_stamina"), 0, "sin sitio, no se repone")


# --- Avisos y ritmos --------------------------------------------------------------------------

func test_requests_outside_the_world_malformed_syncs_and_rate_strike() -> void:
	if not await _start(false):
		return
	# Antes del mundo (LOADING): aviso, también una sincronía.
	var loading := ServerPeer.new(241)
	loading.state = ServerPeer.State.LOADING
	loading.realm = VARDHEIM
	loading.display_name = "Cargando"
	_server._peers[241] = loading
	var request: PackedByteArray = ProgressMessages.InventoryRequest.from_request(1,
			InventoryOps.make_request(MOVE, BAG, 0, BAG, 1, 0, 5)).encode()
	_server._on_packet_received(241, request)
	assert_eq([loading.strikes_total, loading.last_strike_reason], [1, ProgressService.STRIKE_NOT_IN_WORLD],
			"una petición antes del mundo suma un aviso")
	_server._on_packet_received(241, ProgressMessages.InventorySyncRequest.new().encode())
	assert_eq(loading.strikes_total, 2, "una sincronía, también")
	_server._peers.erase(241)
	var ana: ServerPeer = await _enter(242, VARDHEIM)
	var net_id: int = ana.entity.net_id
	# Mal formada.
	_server._on_packet_received(242, request.slice(0, request.size() - 1))
	assert_eq([ana.strikes_total, ana.last_strike_reason], [1, ProgressService.STRIKE_MALFORMED], "mal formada")
	# Sincronía: una cada 5 s; la segunda seguida suma un aviso y no se contesta.
	var fulls: int = _messages(242, NetProtocol.MSG_INVENTORY_FULL).size()
	_server._on_packet_received(242, ProgressMessages.InventorySyncRequest.new().encode())
	await _advance(1)
	assert_eq(_messages(242, NetProtocol.MSG_INVENTORY_FULL).size(), fulls + 1, "un INVENTORY_FULL")
	_server._on_packet_received(242, ProgressMessages.InventorySyncRequest.new().encode())
	await _advance(1)
	assert_eq([_messages(242, NetProtocol.MSG_INVENTORY_FULL).size(), ana.strikes_total], [fulls + 1, 2],
			"la segunda antes de 5 s: aviso y sin respuesta")
	await _advance(ProgressService.SYNC_INTERVAL_TICKS)
	_server._on_packet_received(242, ProgressMessages.InventorySyncRequest.new().encode())
	await _advance(1)
	assert_eq(_messages(242, NetProtocol.MSG_INVENTORY_FULL).size(), fulls + 2, "pasados 5 s, sí")
	# RATE: la ráfaga de 16 pasa; las siguientes responden RATE al momento, y pasados 10 descartes, avisan.
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
	assert_eq(_progress().pending_count(), int(ProgressService.REQUEST_BURST), "16 en cola")
	for request_id: int in rate_ids:
		var answer: ProgressMessages.InventoryDelta = _answer(242, request_id)
		assert_true(answer != null and answer.result == InventoryOps.Result.RATE,
				"la %d responde RATE con el contenido real" % request_id)
	assert_eq(ana.strikes_total, strikes + 14 - ChatPeerState.FLOOD_FREE_DISCARDS,
			"los 10 primeros descartes no avisan; los siguientes, sí")
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
	# 10 000 peticiones (SPLIT y juntar) en 100 ticks, por encima del limitador de los fiables.
	var potion: StringName = &"potion_health"
	var sent: int = 0
	var other_drink: int = started + 20
	_press(other, PlayerInput.CONSUMABLE_1, other_drink)
	for _tick: int in 100:
		# Con los uid que ve (su último estado, aunque ya lo hayan echado).
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
			"ids acotados por RATE: %d tomados, como mucho %d" % [ids.taken_count() - taken_before, bound])
	assert_true(abuser.kicked or abuser.state == ServerPeer.State.LEAVING, "y el abusón sale por los avisos")
	for op: EconomyOp in cheater.journal():
		assert_eq(op.kind, EconomyOp.Kind.STARTER_KIT, "dividir y juntar no dejan operaciones")
	assert_eq(cheater.pending_aggregate_count(), 0, "ni nada agregado")
	assert_eq(cheater.record.inventory.count_of(potion), 3, "ni cambian el total")
	# El otro ha bebido y guarda.
	assert_eq(_inventory(other_id).count_of(potion), 2, "el otro bebe")
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
	assert_true(saved, "y su guardado, con el CONSUME, se aplica")
	# Sin llegar a los avisos (6 peticiones por segundo, 3 de ellas SPLIT), RATE deja 2 ids por segundo.
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
	assert_eq(steady.state, ServerPeer.State.IN_WORLD, "no lo echan")
	assert_true(taken <= int(ProgressService.ID_REQUEST_BURST) + ceili(elapsed_s * 2.0) + 1 and taken < splits_sent,
			"%d SPLIT en %.0f s: %d ids, los de RATE" % [splits_sent, elapsed_s, taken])
	assert_true(_progress().get_stats()["rate_limited"] > 0, "y lo demás, RATE")
	for op: EconomyOp in _player(steady_id).journal():
		assert_eq(op.kind, EconomyOp.Kind.STARTER_KIT, "ninguna operación de dividir ni juntar")
	assert_eq(_inventory(steady_id).count_of(potion), 3, "y el total no cambia")


# --- Persistencia del alta --------------------------------------------------------------------

func test_unstuck_is_restored_by_its_key() -> void:
	if not await _start(true):
		return
	_platform.add_character(2201, 7, &"player", VARDHEIM, {})
	var ana: ServerPeer = await _enter(261, VARDHEIM, _claim(2201))
	var unstuck: UnstuckTracker = _server.get_unstuck()
	unstuck.channel_ticks = 30
	var key: String = "character:2201"
	assert_eq(_server.unstuck_key_of(ana.entity), key, "con plataforma, la clave es el personaje")
	assert_eq(_server._request_unstuck(ana), UnstuckTracker.RequestResult.STARTED)
	await _advance(40)
	var ready_at: int = unstuck.get_ready_at(key)
	assert_true(ready_at > _server.get_tick(), "la reutilización corre por su clave")
	assert_eq(unstuck.get_ready_at(NameRules.normalize_key(ana.display_name)), 0, "no por el nombre")
	assert_eq(_player(ana.entity.net_id).record.timers.get(ProgressService.TIMER_UNSTUCK),
			NOW + ceili((ready_at - _server.get_tick()) / 60.0), "el temporizador unstuck con su fin en hora Unix")
	await _leave(ana)
	var timers: Array = (_platform.applied(2201)["progress"] as Dictionary)["timers"]
	assert_eq(timers.size(), 1, "se guarda")
	assert_eq([timers[0]["key"], int(timers[0]["ends_at_unix"])], ["unstuck", NOW + 300], "5 min desde el uso")
	# Otra zona (otro rastreador), 100 s después: vuelve con lo que le queda.
	unstuck.set_ready_at(key, 0)
	_platform.fake_now_unix = NOW + 100
	ana = await _enter(262, VARDHEIM, _claim(2201))
	var arrival: int = _server.get_tick()
	assert_eq(unstuck.get_ready_at(key), arrival + 200 * 60, "restaurado por su clave: 200 s")
	assert_eq(_server._request_unstuck(ana), UnstuckTracker.RequestResult.COOLDOWN, "y no se puede usar")
	await _leave(ana)
	# Vencido: se descarta al entrar.
	unstuck.set_ready_at(key, 0)
	_platform.fake_now_unix = NOW + 400
	ana = await _enter(263, VARDHEIM, _claim(2201))
	assert_eq(unstuck.get_ready_at(key), 0, "uno vencido no se restaura")
	assert_false(_player(ana.entity.net_id).record.timers.has(ProgressService.TIMER_UNSTUCK), "y sale del registro")


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
	assert_eq(int(saved["health"]), 600, "se guarda la vida")
	# Vuelve 5 s después: la vida guardada más la regeneración de esos 5 s.
	_platform.fake_now_unix = NOW + 5
	ana = await _enter(272, VARDHEIM, _claim(2301))
	net_id = ana.entity.net_id
	var regen: int = CombatCatalog.rules().health_regen_per_s
	assert_eq(_combatant(net_id).health, mini(600 + regen * 5, _combatant(net_id).max_health),
			"con la regeneración del tiempo sin conexión")
	var spawns: Array[Vector3] = ZoneFixture.VARDHEIM_SPAWNS
	var at_camp: bool = false
	for spawn: Vector3 in spawns:
		at_camp = at_camp or ana.entity.get_position().distance_to(spawn) < 0.5
	assert_true(at_camp, "en el campamento de su reino (zona RVR), no donde se fue")
	# Muere y sale muerto: se guarda con 0 y vuelve con la vida llena, en el campamento.
	_server.teleport(net_id, Vector3(8.0, 0.05, -8.0))
	_server.get_combat().kill(_combatant(net_id), _server.get_tick() + 1)
	await _advance(2)
	assert_true(_combatant(net_id).is_dead(), "muerto")
	await _leave(ana)
	saved = _platform.applied(2301)["progress"]
	assert_eq(int(saved["health"]), 0, "muerto se guarda con 0")
	_platform.fake_now_unix = NOW + 10
	ana = await _enter(273, VARDHEIM, _claim(2301))
	net_id = ana.entity.net_id
	assert_true(_combatant(net_id).is_alive() and _combatant(net_id).health == _combatant(net_id).max_health,
			"vuelve vivo y con la vida llena")
	at_camp = false
	for spawn: Vector3 in spawns:
		at_camp = at_camp or ana.entity.get_position().distance_to(spawn) < 0.5
	assert_true(at_camp, "en el campamento")


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
			"el escudero")
	# El arco a WEAPON_2.
	var id: int = _request(ana, MOVE, BAG, 0, EQUIPMENT, 1, 0, _uid(net_id, BAG, 0))
	await _advance(1)
	assert_eq(_answer(281, id).result, InventoryOps.Result.OK, "el arco en WEAPON_2")
	# Q: cambia al arco (predicho y válido en combate; aquí, del servidor).
	_press(ana, PlayerInput.SWAP_WEAPON, _server.get_tick() + 2)
	var swapped: bool = await _advance_until(func() -> bool:
		var combat: CombatState = _combat(net_id)
		return combat.is_second_slot() and combat.action == CombatState.Action.NONE, 120)
	if not assert_true(swapped, "cambia al arco"):
		return
	assert_eq(_combat(net_id).weapon_id, bow)
	# Desequipar WEAPON_1 (la espada): la activa es la 2, así que vale.
	id = _request(ana, MOVE, EQUIPMENT, 0, BAG, 0, 0, _uid(net_id, EQUIPMENT, 0))
	await _advance(1)
	assert_eq(_answer(281, id).result, InventoryOps.Result.OK, "desequipar la espada con el arco en la mano")
	var combat: CombatState = _combat(net_id)
	assert_eq([combat.weapon_id, combat.alt_weapon_id, combat.is_second_slot()], [bow, 0, true])
	# Muere y reaparece: WEAPON_1 vacía, así que con la 2 activa.
	_server.get_combat().kill(_combatant(net_id), _server.get_tick() + 1)
	await _advance(2)
	await _advance(maxi(_combatant(net_id).respawn_tick - _server.get_tick(), 0) + 1)
	assert_eq(_server.get_combat().request_respawn(net_id, 0, _server.get_tick() + 1),
			CombatDirector.RespawnRequestResult.ACCEPTED)
	await _advance(2)
	assert_true(_combatant(net_id).is_alive(), "reaparece")
	combat = _combat(net_id)
	assert_eq([combat.weapon_id, combat.alt_weapon_id, combat.is_second_slot()], [bow, 0, true],
			"con el arco activo")
	var owner: Array[NetMessages.EntityEvent] = _loadouts(net_id, true)
	assert_eq([owner[-1].template_id, owner[-1].weapon_1, owner[-1].weapon_2], [0, 0, bow],
			"y su LOADOUT: la ranura 1 vacía y el arco en la 2")
	# Su guardado siguiente pasa S5 (I10: la activa con arma).
	var saves: int = _platform.sent(PlatformEvent.KIND_SAVE).size()
	_server.get_saver().mark_critical(net_id, &"prueba")
	await _advance_until(func() -> bool:
		return _platform.sent(PlatformEvent.KIND_SAVE).size() > saves and _server.get_saver().pending_count() == 0)
	var progress: Dictionary = _platform.applied(2401)["progress"]
	assert_eq(int(progress["active_weapon_slot"]), 1, "guarda la ranura 2 activa")
	assert_eq(_s5_errors(progress), PackedStringArray(), "y la foto pasa S5")
	# Desconectar y volver conserva la configuración (CMB-30): el arco en WEAPON_2, activo, y la espada en la bolsa.
	var uids: Array[int] = [_uid(net_id, EQUIPMENT, 1), _uid(net_id, BAG, 0)]
	await _leave(ana)
	ana = await _enter(282, VARDHEIM, _claim(2401))
	net_id = ana.entity.net_id
	assert_eq([_uid(net_id, EQUIPMENT, 1), _uid(net_id, BAG, 0), _uid(net_id, EQUIPMENT, 0)], [uids[0], uids[1], 0],
			"los mismos objetos en las mismas ranuras")
	combat = _combat(net_id)
	assert_eq([combat.weapon_id, combat.alt_weapon_id, combat.is_second_slot()], [bow, 0, true],
			"y vuelve con el arco activo")
