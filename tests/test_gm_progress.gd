extends TestCase
## Pruebas de los comandos de GM de la progresión (docs/progresion.md §10 y §15, P5d; PRG-16): dar un objeto,
## dividirlo y juntarlo y revertirlo (el total baja lo dado y están el GM_GRANT, la REVERSAL y sus apuntes); la
## segunda reversión, también la que llega antes de guardar la primera; DEBUG_COMMAND con plataforma y su rol (41 de un
## [code]player[/code], 40 y 16 de un [code]gm[/code]: aviso y nada; el 16 de un [code]admin[/code], una GM que el
## guardado acepta; el 5 y el 13, solo la auditoría); la regla de los propios personajes (también en [code]dev[/code]);
## el objetivo por su [code]character_id[/code]; la zona cercada; [code]level_set[/code] y [code]xp_add[/code] con su
## [code]detail[/code]; [code]ledger_show[/code] y [code]op_show[/code] por las rutas; y sin plataforma, el diario.
## Además, la base: los uids de los eventos del cuerpo frente a lo guardado (S4) y [method PlayerProgress.abort_op].
## [br][br]
## Un [ZoneServer] sin red sobre la zona plana con la fortaleza de pruebas, con [FakeZonePlatform] (el reloj fijo) y
## peers montados a mano con su reclamación, como test_zone_moderation.gd. Las respuestas de las rutas de §13.2 se
## guionizan con [method FakeZonePlatform.script_next] a partir de lo que de verdad se guardó, y cada cuerpo guardado
## pasa por las comprobaciones de forma de S2, S4 y S5 que se pueden hacer sin base ([method _assert_saves_accepted]).

const VARDHEIM: int = NetProtocol.Realm.VARDHEIM
const ZONE_ID: String = "test_world"
const NOW: int = 1_800_000_000
const KEY_HEX: String = "02b7825be38fdd5396a4a058286884eaf93a9df85b874f78b4010a76103fb858"
const BAG: int = InventoryState.ContainerId.BAG
const EQUIPMENT: int = InventoryState.ContainerId.EQUIPMENT
const POTION: StringName = &"potion_health"
const STAMINA: StringName = &"potion_stamina"
const GOLD: int = Currency.Code.GOLD
## Las claves de detail que admite S2 (progresion.md §10; checks.go de P7).
const DETAIL_KEYS: Array[String] = ["command", "args", "source", "actor_character_id", "at_unix", "level_before",
		"level_after", "xp_before", "xp_after", "xp_delta"]
const PLATFORM_DOWN: String = "El servicio de cuentas no responde; inténtalo más tarde."
const OWN: String = "No puedes usarlo sobre tus personajes."


## Un transporte que no conecta nada y apunta lo que el servidor manda a cada peer (sin los SNAPSHOT).
class RecordingTransport:
	extends NetTransport

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
var _request_id: int = 0
var _console: PackedStringArray = PackedStringArray()


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
	_console = PackedStringArray()
	await wait_process_frames()


# --- Montaje ----------------------------------------------------------------------------------

## La zona plana con la fortaleza de pruebas y el servidor sin red, con [code]--debug-commands[/code]; con
## [param with_platform], la plataforma falsa (con [param env]) arrancada y viva, con el reloj en [constant NOW] y sin
## latidos solos.
func _start(with_platform: bool, env: StringName = &"test") -> bool:
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
	config.debug_commands = true
	var keys: Dictionary[int, PackedByteArray] = {2: KEY_HEX.hex_decode()}
	if with_platform:
		config.platform_url = "http://fake"
		config.save_interval_s = 600
		_platform = FakeZonePlatform.new()
		_platform.name = "Platform"
		_platform.log_sink = func(_text: String) -> void: pass
		_platform.fake_now_unix = NOW
		_platform.fake_heartbeat_s = 600.0
		_platform.fake_env = env
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
		if not assert_eq(finished, [[true, ""]], "la plataforma falsa arranca"):
			return false
		var tickets := TicketAuthProvider.new(_platform, config.world_id, config.zone_id, config.channel, keys)
		tickets.log_sink = func(_text: String) -> void: pass
		provider = tickets
	if not assert_eq(_server.start(config, _world, null, provider, _platform), OK, "el servidor arranca"):
		return false
	# Lo que los comandos dejan en el registro (las respuestas de la consola que llegan tarde).
	_progress().log_sink = func(text: String) -> void: _console.append(text)
	_server.get_moderation().log_sink = func(_text: String) -> void: pass
	_server.set_physics_process(false)
	_recorder = RecordingTransport.new()
	_server._transport = _recorder
	_stepper = FortressFixture.Stepper.new()
	_stepper.server = _server
	_viewport.add_child(_stepper)
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


func _advance_until(condition: Callable, max_ticks: int = 600) -> bool:
	var elapsed: int = 0
	while elapsed < max_ticks:
		if condition.call():
			return true
		await _advance(2)
		await wait_process_frames()
		elapsed += 2
	return bool(condition.call())


## El personaje [param character_id] (cuenta [code]character_id × 10[/code], [param role]) entra con el peer
## [param peer_id]. Devuelve el peer, ya en el mundo.
func _join(peer_id: int, character_id: int, display_name: String, role: StringName = &"player") -> ServerPeer:
	_platform.add_character(character_id, character_id * 10, role, VARDHEIM, {}, {}, display_name)
	var answer: Array = _platform._claim_answer({"character_id": str(character_id), "ticket_id": "1"})
	return await _enter(peer_id, ClaimedCharacter.from_claim(JSON.parse_string(JSON.stringify(answer[1]))),
			display_name)


func _enter(peer_id: int, claimed: ClaimedCharacter, display_name: String) -> ServerPeer:
	var peer := ServerPeer.new(peer_id)
	peer.state = ServerPeer.State.LOADING
	peer.realm = claimed.realm if claimed != null else VARDHEIM
	peer.display_name = claimed.display_name if claimed != null else display_name
	peer.loading_since_tick = _server.get_tick()
	peer.remote_address = "127.0.0.1"
	_server._peers[peer_id] = peer
	if claimed != null:
		peer.claimed = claimed
		assert_true(_progress().prepare(peer_id, claimed), "se prepara el registro")
	_server._pending_ready.append(peer_id)
	await _advance(1)
	assert_not_null(peer.entity, "el peer %d entra en el mundo" % peer_id)
	return peer


## Espera a que no quede nada por guardar: ningún guardado en vuelo y los diarios confirmados.
func _settle() -> bool:
	return await _advance_until(func() -> bool:
		if _server.get_saver().pending_count() > 0:
			return false
		for net_id: int in _progress().player_net_ids():
			if not _progress().get_player(net_id).journal().is_empty():
				return false
		return true)


func _receive(peer: ServerPeer, bytes: PackedByteArray) -> void:
	_server._on_packet_received(peer.peer_id, bytes)


## Una línea de [code]/gm[/code] (lo que manda el cliente por el canal GM, sin la barra) y las [param replies]
## respuestas nuevas del canal del sistema.
func _gm(peer: ServerPeer, line: String, replies: int = 1) -> PackedStringArray:
	# La ficha de hablar: uno por segundo.
	await _advance(60)
	var before: int = _system_texts(peer).size()
	var message := NetMessages.ChatSend.new()
	message.channel = ChatChannel.Id.GM
	message.text = line
	_receive(peer, message.encode())
	await _advance_until(func() -> bool: return _system_texts(peer).size() >= before + replies, 300)
	return _system_texts(peer).slice(before)


func _system_texts(peer: ServerPeer) -> PackedStringArray:
	var texts := PackedStringArray()
	for bytes: PackedByteArray in _recorder.sent.get(peer.peer_id, []):
		if NetMessages.peek_type(bytes) != NetProtocol.MSG_CHAT_MESSAGE:
			continue
		var message: NetMessages.ChatMessage = NetMessages.ChatMessage.decode(bytes)
		if message != null and message.channel == ChatChannel.Id.SYSTEM:
			texts.append(message.text)
	return texts


func _messages(peer: ServerPeer, type: int) -> Array[PackedByteArray]:
	var found: Array[PackedByteArray] = []
	for bytes: PackedByteArray in _recorder.sent.get(peer.peer_id, []):
		if NetMessages.peek_type(bytes) == type:
			found.append(bytes)
	return found


## Los ENTITY_EVENT LOADOUT del propio jugador que ha recibido [param peer].
func _loadouts(peer: ServerPeer) -> int:
	var count: int = 0
	for bytes: PackedByteArray in _messages(peer, NetProtocol.MSG_ENTITY_EVENT):
		var decoded: NetMessages.EntityEvent = NetMessages.EntityEvent.decode(bytes)
		if decoded != null and decoded.event == NetMessages.EntityEvent.Kind.LOADOUT \
				and decoded.net_id == peer.entity.net_id:
			count += 1
	return count


func _player(peer: ServerPeer) -> PlayerProgress:
	return _progress().get_player(peer.entity.net_id)


func _count(peer: ServerPeer, def_id: StringName) -> int:
	return _player(peer).record.inventory.count_of(def_id)


func _last_op(peer: ServerPeer) -> EconomyOp:
	var journal: Array[EconomyOp] = _player(peer).journal()
	return journal.back() if not journal.is_empty() else null


func _request(peer: ServerPeer, op: int, from_container: int, from_slot: int, to_container: int, to_slot: int,
		count: int, uid: int) -> void:
	_request_id += 1
	var request: InventoryOps.Request = InventoryOps.make_request(op, from_container, from_slot, to_container,
			to_slot, count, uid)
	_receive(peer, ProgressMessages.InventoryRequest.from_request(_request_id, request).encode())


## La ranura de la bolsa de [param def_id] que no es ninguna de [param skip] (−1 si no hay).
func _bag_slot_of(peer: ServerPeer, def_id: StringName, skip: Array[int] = []) -> int:
	var state: InventoryState = _player(peer).record.inventory
	for slot: int in range(state.bag_slots):
		var item: ItemInstance = state.get_item(BAG, slot)
		if item != null and item.def_id == def_id and not skip.has(slot):
			return slot
	return -1


## Los cuerpos de guardado de [param character_id], en orden (sin los reintentos del mismo seq).
func _saves_of(character_id: int) -> Array[Dictionary]:
	var bodies: Array[Dictionary] = []
	var last_seq: int = -1
	for body: Dictionary in _platform.sent(PlatformEvent.KIND_SAVE):
		if body.get("character_id") == str(character_id) and body.get("progress") is Dictionary \
				and int(body.get("seq", 0)) != last_seq:
			last_seq = int(body["seq"])
			bodies.append(body)
	return bodies


## La operación [param op_id] tal como la guardó [param character_id] (la entrada de ops de §9.3), o vacía.
func _saved_op(character_id: int, op_id: int) -> Dictionary:
	for body: Dictionary in _saves_of(character_id):
		for op: Dictionary in body["progress"]["ops"]:
			if op["op_id"] == str(op_id):
				return op
	return {}


## El cuerpo de [code]GET /internal/v1/ops/{op_id}[/code] (§13.2) de lo que [param character_id] guardó, con
## [param reversed_by] y las filas de los uids de sus eventos (de la última foto guardada que los lleva).
func _route_body(character_id: int, op_id: int, reversed_by: int = 0) -> Dictionary:
	var op: Dictionary = _saved_op(character_id, op_id)
	var ledger: Array = []
	var seq: int = 0
	for entry: Dictionary in op.get("ledger", []):
		seq += 1
		ledger.append({"character_id": str(character_id), "currency": entry["currency"], "seq": seq,
				"delta": entry["delta"], "balance_after": entry["balance_after"], "reason": entry["reason"],
				"ref_kind": entry["ref_kind"], "ref_id": entry["ref_id"]})
	var items: Array = []
	var instances: Array = []
	for event: Dictionary in op.get("items", []):
		items.append({"character_id": str(character_id), "uid": event["uid"], "def_id": event["def_id"],
				"count_delta": event["count_delta"], "reason": event["reason"]})
		if event["uid"] != null:
			var row: Dictionary = _instance_row(character_id, String(event["uid"]))
			if not row.is_empty():
				instances.append(row)
	return {"op": {"op_id": str(op_id), "kind": op.get("kind"), "actor_account_id": op.get("actor_account_id"),
			"ref_op_id": op.get("ref_op_id"), "zone_id": ZONE_ID, "note": op.get("note"), "detail": op.get("detail"),
			"created_at_unix": NOW, "participants": [str(character_id)],
			"reversed_by": str(reversed_by) if reversed_by != 0 else null, "ledger": ledger, "items": items,
			"instances": instances}}


func _instance_row(character_id: int, uid: String) -> Dictionary:
	var bodies: Array[Dictionary] = _saves_of(character_id)
	for i: int in range(bodies.size() - 1, -1, -1):
		for item: Dictionary in bodies[i]["progress"]["items"]:
			if item["uid"] == uid:
				return {"uid": uid, "def_id": item["def_id"], "count": item["count"], "durability": item["durability"],
						"rarity": item["rarity"], "bound": item["bound"], "seed": item["seed"],
						"affixes": item["affixes"], "retired": i < bodies.size() - 1}
	return {}


## Las comprobaciones de forma de S2, S4 y S5 que se pueden hacer sin base (progresion.md §13.3) sobre cada cuerpo
## guardado de [param character_id], en orden: cada operación con los motivos de su tipo y, GM y REVERSAL, con
## [code]note[/code] y un [code]detail[/code] que S2 lee (sus claves, [code]source[/code], [code]args[/code] en
## cadenas y [code]at_unix[/code]); por definición, lo guardado más los eventos es la foto; un evento con uid que suma
## es de uno que no estaba guardado y uno que resta, de uno que sí; y la ranura activa con arma.
func _assert_saves_accepted(character_id: int) -> void:
	var saved: Dictionary = {}
	for body: Dictionary in _saves_of(character_id):
		var progress: Dictionary = body["progress"]
		var totals: Dictionary = {}
		for uid: String in saved:
			totals[saved[uid][0]] = int(totals.get(saved[uid][0], 0)) + int(saved[uid][1])
		for op: Dictionary in progress["ops"]:
			var parsed: EconomyOp = EconomyOp.from_dictionary(op)
			if not assert_not_null(parsed, "la operación %s se lee" % op.get("op_id")):
				continue
			assert_true(parsed.is_consistent(), "S2: los motivos de su tipo y la note (%s)" % op["op_id"])
			if parsed.kind == EconomyOp.Kind.GM or parsed.kind == EconomyOp.Kind.REVERSAL:
				for key: String in parsed.detail:
					assert_true(DETAIL_KEYS.has(key), "S2: detail sin la clave %s" % key)
				assert_true(["gm", "console", "debug"].has(parsed.detail.get("source")), "S2: source")
				assert_eq(int(parsed.detail.get("at_unix", -1)), NOW, "S2: at_unix de la zona")
				for arg: Variant in parsed.detail.get("args", []):
					assert_true(arg is String, "S2: args en cadenas")
				var console: bool = parsed.detail.get("source") == "console"
				assert_eq(parsed.actor_account_id == 0, console, "S2: actor solo fuera de la consola")
			for event: Dictionary in op["items"]:
				var def_id: String = event["def_id"]
				totals[def_id] = int(totals.get(def_id, 0)) + int(event["count_delta"])
				if event["uid"] == null:
					continue
				if int(event["count_delta"]) > 0:
					assert_false(saved.has(event["uid"]), "S4: suma a un uid que no estaba (%s)" % event["uid"])
				else:
					assert_eq((saved.get(event["uid"], ["", 0]) as Array)[0], def_id,
							"S4: resta de un uid que estaba (%s)" % event["uid"])
		saved = {}
		var weapons: Array[int] = []
		for item: Dictionary in progress["items"]:
			totals[item["def_id"]] = int(totals.get(item["def_id"], 0)) - int(item["count"])
			saved[item["uid"]] = [item["def_id"], item["count"]]
			if int(item["container"]) == EQUIPMENT:
				weapons.append(int(item["slot"]))
		for def_id: String in totals:
			assert_eq(totals[def_id], 0, "S4: %s cuadra en el guardado %d" % [def_id, int(body["seq"])])
		assert_true(weapons.has(int(progress["active_weapon_slot"])), "S5: la ranura activa con arma (I10)")


func _audit_entries() -> Array[Dictionary]:
	var entries: Array[Dictionary] = []
	for batch: Dictionary in _platform.sent(&"audit"):
		for entry: Dictionary in batch.get("entries", []):
			entries.append(entry)
	for entry: Dictionary in _platform.queued(&"audit"):
		entries.append(JSON.parse_string(JSON.stringify(entry)))
	return entries


func _audit_of(command: String) -> Array[Dictionary]:
	var found: Array[Dictionary] = []
	for entry: Dictionary in _audit_entries():
		if entry.get("command") == command:
			found.append(entry)
	return found


func _audit_with_key(key: String) -> Dictionary:
	for entry: Dictionary in _audit_entries():
		if entry.get("key") == key:
			return entry
	return {}


# --- Dar, dividir, juntar y revertir --------------------------------------------------------------

func test_give_split_merge_and_revert_lower_the_total_by_what_was_given() -> void:
	if not await _start(true):
		return
	var ana: ServerPeer = await _join(1, 42, "Ana")
	var gema: ServerPeer = await _join(2, 41, "Gema", &"gm")
	if ana == null or ana.entity == null or gema == null or gema.entity == null:
		return
	assert_true(await _settle(), "el kit de los dos, guardado")
	var potions: int = _count(ana, POTION)
	var replies: PackedStringArray = await _gm(gema, "gm item_give Ana potion_health 5 regalo de prueba")
	var given: EconomyOp = _last_op(ana)
	if not assert_not_null(given, "una operación en el diario de Ana"):
		return
	assert_eq(replies, PackedStringArray(["Dados 5 × potion_health a Ana (operación %d)." % given.op_id]))
	assert_eq(_count(ana, POTION), potions + 5, "cinco más")
	assert_eq([given.kind, given.actor_account_id, given.note], [EconomyOp.Kind.GM, 410, "regalo de prueba"])
	assert_eq(given.detail, {"command": "item_give", "args": ["42", "potion_health", "5"], "source": "gm",
			"actor_character_id": "41", "at_unix": NOW}, "el rastro de §10, con el objetivo por su character_id")
	var gift_uid: int = given.items[0].uid
	assert_eq([given.items.size(), given.items[0].count_delta, given.items[0].reason],
			[1, 5, EconomyReason.GM_GRANT], "un GM_GRANT de una pila nueva")
	var gift_slot: int = _player(ana).record.inventory.find_uid(gift_uid).y
	assert_true(await _settle(), "el guardado crítico de la GM")
	# Ana divide la pila en 3 y 2 y junta las 2 con la del kit.
	var free: int = _player(ana).record.inventory.first_free(BAG)
	_request(ana, InventoryOps.Op.SPLIT, BAG, gift_slot, BAG, free, 2, gift_uid)
	await _advance(2)
	var kit_slot: int = _bag_slot_of(ana, POTION, [gift_slot, free])
	var split: ItemInstance = _player(ana).record.inventory.get_item(BAG, free)
	if not assert_not_null(split, "la pila dividida") or not assert_true(kit_slot >= 0, "la pila del kit"):
		return
	_request(ana, InventoryOps.Op.MOVE, BAG, free, BAG, kit_slot, 0, split.uid)
	await _advance(2)
	assert_eq(_player(ana).record.inventory.get_item(BAG, gift_slot).count, 3, "3 en la pila dada")
	assert_null(_player(ana).record.inventory.get_item(BAG, free), "las 2 se han juntado")
	assert_eq(_count(ana, POTION), potions + 5, "dividir y juntar no cambian el total")
	assert_true(await _settle())
	# La reversión: la plataforma devuelve la operación guardada.
	_platform.script_next(PlatformEvent.KIND_PROGRESS_OP, 200, _route_body(42, given.op_id))
	replies = await _gm(gema, "gm op_revert %d mal dado" % given.op_id, 2)
	var reversal: EconomyOp = _last_op(ana)
	if not assert_not_null(reversal, "la REVERSAL en el diario"):
		return
	assert_eq(replies, PackedStringArray(["Pedido al servicio de cuentas: operación %d para revertirla." % given.op_id,
			"Operación %d de Ana revertida (operación %d)." % [given.op_id, reversal.op_id]]))
	assert_eq(_count(ana, POTION), potions, "el total baja 5: dividir o juntar no la esquiva")
	assert_eq([reversal.kind, reversal.ref_op_id, reversal.note, reversal.actor_account_id],
			[EconomyOp.Kind.REVERSAL, given.op_id, "mal dado", 410])
	var removed: int = 0
	for event: ItemEvent in reversal.items:
		assert_eq([event.reason, event.def_id], [EconomyReason.REVERSAL, POTION])
		removed += event.count_delta
	assert_eq(removed, -5, "cinco menos con motivo REVERSAL")
	assert_eq([reversal.items[0].uid, reversal.items[0].count_delta], [gift_uid, -3], "primero del uid dado")
	var requests: Array[Dictionary] = _platform.sent(PlatformEvent.KIND_PROGRESS_OP)
	assert_eq(requests.back().get("path"), "/internal/v1/ops/%d?zone_instance_id=%s" % [given.op_id,
			_platform.instance_id()], "la ruta con la instancia")
	assert_true(await _settle(), "el guardado crítico de la REVERSAL")
	# En lo guardado: el GM_GRANT, la REVERSAL y sus apuntes; en la auditoría, una entrada por operación.
	var saved_gift: Dictionary = _saved_op(42, given.op_id)
	var saved_reversal: Dictionary = _saved_op(42, reversal.op_id)
	assert_eq(saved_gift["items"][0]["reason"], EconomyReason.GM_GRANT, "el GM_GRANT guardado")
	assert_eq([int(saved_reversal["kind"]), saved_reversal["ref_op_id"]], [EconomyOp.Kind.REVERSAL,
			str(given.op_id)])
	assert_eq(saved_reversal["items"].size(), 2, "sus dos eventos")
	_assert_saves_accepted(42)
	_assert_saves_accepted(41)
	var gift_entry: Dictionary = _audit_with_key("op:%d" % given.op_id)
	var reversal_entry: Dictionary = _audit_with_key("op:%d" % reversal.op_id)
	assert_eq([gift_entry.get("command"), gift_entry.get("source"), gift_entry.get("actor_account_id"),
			gift_entry.get("actor_character_id"), gift_entry.get("target_character_id"),
			gift_entry.get("target_account_id")], ["item_give", "zone", "410", "41", "42", "420"])
	assert_eq(gift_entry.get("args"), {"args": ["42", "potion_health", "5"]}, "los args de la fila de S8")
	assert_eq(int(gift_entry.get("at_unix", 0)), NOW, "la hora de detail.at_unix")
	assert_eq([reversal_entry.get("command"), reversal_entry.get("target_character_id")], ["op_revert", "42"])
	assert_false(JSON.stringify(gift_entry).contains("Ana") or JSON.stringify(given.detail).contains("Ana"),
			"ni el nombre del objetivo")
	assert_eq(_audit_of("op_revert").size(), 1, "op_revert con plataforma deja una sola entrada, la de su operación")
	# Una segunda reversión, ya guardada la primera: la ruta dice quién la revirtió.
	_platform.script_next(PlatformEvent.KIND_PROGRESS_OP, 200, _route_body(42, given.op_id, reversal.op_id))
	replies = await _gm(gema, "gm op_revert %d otra vez" % given.op_id, 2)
	assert_eq(replies[1] if replies.size() > 1 else "", "Esa operación ya está revertida.")
	assert_eq(_count(ana, POTION), potions, "nada cambia")
	assert_true(_player(ana).journal().is_empty(), "ni se crea otra operación")


func test_a_second_revert_before_the_first_is_saved_is_refused() -> void:
	if not await _start(true):
		return
	var ana: ServerPeer = await _join(1, 42, "Ana")
	var gema: ServerPeer = await _join(2, 41, "Gema", &"gm")
	if ana == null or ana.entity == null or gema == null or gema.entity == null:
		return
	assert_true(await _settle())
	var replies: PackedStringArray = await _gm(gema, "gm currency_add Ana oro +50 devolución del fallo 12")
	var gift: EconomyOp = _last_op(ana)
	if not assert_not_null(gift):
		return
	assert_eq(replies[0], "Oro de Ana: +50, queda en 50 (operación %d)." % gift.op_id)
	assert_eq(gift.ledger.size(), 1)
	assert_true(gift.ledger[0].equals(LedgerEntry.create(GOLD, 50, 50, EconomyReason.GM_GRANT, 0, 0)),
			"el apunte GM_GRANT")
	assert_eq(gift.detail["args"], ["42", "oro", "50"])
	assert_true(await _settle())
	# Dos a la vez: la segunda llega mientras la primera espera la ruta.
	_platform.script_next(PlatformEvent.KIND_PROGRESS_OP, 200, _route_body(42, gift.op_id), 0.3)
	await _advance(60)
	var before: int = _system_texts(gema).size()
	for _i: int in 2:
		var message := NetMessages.ChatSend.new()
		message.channel = ChatChannel.Id.GM
		message.text = "gm op_revert %d error" % gift.op_id
		_receive(gema, message.encode())
	assert_eq(_system_texts(gema).slice(before), PackedStringArray([
			"Pedido al servicio de cuentas: operación %d para revertirla." % gift.op_id,
			"Esa operación ya se está revirtiendo."]), "la segunda, rechazada")
	# La REVERSAL se queda en vuelo: su guardado tarda.
	_platform.script_next(PlatformEvent.KIND_SAVE, 200, FakeZonePlatform.DEFAULT, 2.0)
	await _advance_until(func() -> bool: return _system_texts(gema).size() >= before + 3, 300)
	var reversal: EconomyOp = _last_op(ana)
	if not assert_not_null(reversal) or not assert_eq(reversal.kind, EconomyOp.Kind.REVERSAL):
		return
	assert_eq(_player(ana).record.wallets[GOLD], 0, "el oro vuelve a 0")
	assert_eq(reversal.ledger.size(), 1)
	assert_true(reversal.ledger[0].equals(LedgerEntry.create(GOLD, -50, 0, EconomyReason.REVERSAL,
			LedgerEntry.RefKind.OP, gift.op_id)), "el apunte contrario, con ref_kind 4 y la original")
	replies = await _gm(gema, "gm op_revert %d otra" % gift.op_id)
	assert_eq(replies[0], "Esa operación ya se está revirtiendo.", "la REVERSAL aún sin guardar")
	assert_eq(_platform.sent(PlatformEvent.KIND_PROGRESS_OP).size(), 1, "sin pedir la ruta otra vez")
	assert_true(await _settle())
	_assert_saves_accepted(42)
	# Un saldo que ya se gastó: no se revierte nada y se dice lo que falta.
	await _gm(gema, "gm currency_add Ana oro 30 premio")
	var prize: EconomyOp = _last_op(ana)
	assert_true(await _settle())
	_server.console_command("currency_add Ana oro -20 gasto")
	assert_true(await _settle())
	_platform.script_next(PlatformEvent.KIND_PROGRESS_OP, 200, _route_body(42, prize.op_id))
	replies = await _gm(gema, "gm op_revert %d no tocaba" % prize.op_id, 2)
	assert_eq(replies[1] if replies.size() > 1 else "", "A Ana le faltan 20 de oro: no se revierte nada.")
	assert_eq(_player(ana).record.wallets[GOLD], 10, "el saldo no cambia")
	assert_true(_player(ana).journal().is_empty(), "ni queda la REVERSAL")


# --- DEBUG_COMMAND con plataforma ---------------------------------------------------------------------

func test_debug_commands_with_platform_need_admin() -> void:
	if not await _start(true):
		return
	var pablo: ServerPeer = await _join(1, 43, "Pablo")
	var gema: ServerPeer = await _join(2, 41, "Gema", &"gm")
	var ada: ServerPeer = await _join(3, 40, "Ada", &"admin")
	if pablo == null or pablo.entity == null or gema == null or gema.entity == null or ada.entity == null:
		return
	assert_true(await _settle())
	var saves: int = _platform.sent(PlatformEvent.KIND_SAVE).size()
	# 41 de un player: aviso y el saldo igual.
	var strikes: int = pablo.strikes_total
	_receive(pablo, NetMessages.DebugCommand.currency_add(GOLD, 100).encode())
	await _advance(2)
	assert_eq(pablo.strikes_total, strikes + 1, "41 sin rol: aviso")
	assert_eq(_player(pablo).record.wallets[GOLD], 0, "y el saldo no cambia")
	# 40 de un gm: también admin; ni objeto ni guardado.
	var potions: int = _count(gema, POTION)
	strikes = gema.strikes_total
	_receive(gema, NetMessages.DebugCommand.item_give(ItemDatabase.shared().net_id_of(POTION), 2).encode())
	await _advance(2)
	assert_eq(gema.strikes_total, strikes + 1, "40 de un gm: aviso")
	assert_eq(_count(gema, POTION), potions, "ni objeto")
	# El 16 de un gm: aviso.
	_receive(gema, NetMessages.DebugCommand.simple(NetProtocol.DEBUG_REFILL).encode())
	await _advance(2)
	assert_eq(gema.strikes_total, strikes + 2, "16 de un gm: aviso")
	# El 5 y el 13 de un gm: también admin.
	var weapon := NetMessages.DebugCommand.simple(NetProtocol.DEBUG_SET_WEAPON)
	weapon.payload = PackedByteArray([0, 0])
	weapon.payload.encode_u16(0, CombatCatalog.weapon_id(&"bow"))
	_receive(gema, weapon.encode())
	_receive(gema, NetMessages.DebugCommand.cooldowns_off(true).encode())
	await _advance(2)
	assert_eq(gema.strikes_total, strikes + 4, "5 y 13 de un gm: aviso")
	await _advance(30)
	assert_eq(_platform.sent(PlatformEvent.KIND_SAVE).size(), saves, "nada que guardar")
	for peer: ServerPeer in [pablo, gema]:
		assert_true(_player(peer).journal().is_empty(), "ni operaciones de %s" % peer.display_name)
	# El admin: le falta una poción (la quita la consola) y el 16 la repone con una GM «debug».
	var uid: int = _player(ada).record.inventory.get_item(BAG, _bag_slot_of(ada, POTION)).uid
	assert_true(_server.console_command("item_take Ada %d 1 prueba" % uid).begins_with("Quitados 1 × potion_health"))
	var taken: EconomyOp = _last_op(ada)
	assert_eq([taken.detail["source"], taken.detail["actor_character_id"], taken.actor_account_id],
			["console", null, 0], "desde la consola, sin actor")
	assert_true(await _settle())
	var loadouts: int = _loadouts(ada)
	_receive(ada, NetMessages.DebugCommand.simple(NetProtocol.DEBUG_REFILL).encode())
	await _advance(1)
	var refill: EconomyOp = _last_op(ada)
	if not assert_not_null(refill, "el 16 de un admin crea una operación"):
		return
	assert_eq([refill.kind, refill.note, refill.actor_account_id], [EconomyOp.Kind.GM, "debug", 400])
	assert_eq(refill.detail, {"command": "refill", "args": ["40"], "source": "debug", "actor_character_id": "40",
			"at_unix": NOW})
	assert_eq(refill.items.size(), 1)
	assert_eq([refill.items[0].def_id, refill.items[0].count_delta, refill.items[0].reason],
			[POTION, 1, EconomyReason.GM_GRANT], "un GM_GRANT por lo que falta")
	assert_eq(_count(ada, POTION), 3, "repuesta")
	assert_eq(_loadouts(ada), loadouts + 1, "y el LOADOUT al dueño, como siempre con el 16")
	assert_true(await _settle(), "el guardado lo acepta")
	_assert_saves_accepted(40)
	var saved_refill: Dictionary = _saved_op(40, refill.op_id)
	assert_eq(saved_refill["items"][0]["uid"], null, "suma a la pila guardada: el cuerpo no lleva su uid (S4)")
	# El 5 y el 13 de un admin: sin operación y con su entrada de auditoría.
	_receive(ada, weapon.encode())
	_receive(ada, NetMessages.DebugCommand.cooldowns_off(true).encode())
	await _advance(2)
	assert_true(_player(ada).journal().is_empty(), "el 5 y el 13 no crean operación")
	for command: String in ["set_weapon", "cooldowns_off"]:
		var entries: Array[Dictionary] = _audit_of(command)
		if assert_eq(entries.size(), 1, "una entrada de %s" % command):
			assert_true(String(entries[0]["key"]).begins_with(_platform.instance_id() + ":"), "con su clave de instancia")
			assert_eq(entries[0]["target_character_id"], "40")
	# Y el 40 de un admin sobre sí mismo sí vale.
	_receive(ada, NetMessages.DebugCommand.item_give(ItemDatabase.shared().net_id_of(STAMINA), 4).encode())
	await _advance(1)
	var give: EconomyOp = _last_op(ada)
	assert_eq([give.detail["command"], give.detail["args"], give.note], ["item_give", ["40", "potion_stamina", "4"],
			"debug"])
	assert_eq(_audit_with_key("op:%d" % give.op_id).get("command"), "item_give", "auditada con su op:<op_id>")


# --- Los propios personajes, la zona cercada y el nivel --------------------------------------------------

func test_own_characters_need_admin_even_in_dev() -> void:
	if not await _start(true, &"dev"):
		return
	var gema: ServerPeer = await _join(1, 41, "Gema", &"gm")
	var ada: ServerPeer = await _join(2, 40, "Ada", &"admin")
	if gema == null or gema.entity == null or ada == null or ada.entity == null:
		return
	assert_true(await _settle())
	var potions: int = _count(gema, POTION)
	var replies: PackedStringArray = await _gm(gema, "gm item_give Gema potion_health 1 para mí")
	assert_eq(replies[0], OWN, "un gm sobre su propio personaje, en dev")
	assert_eq(_count(gema, POTION), potions)
	assert_true(_player(gema).journal().is_empty(), "sin operación")
	# Una operación de la consola sobre Gema y su reversión por ella misma.
	assert_true(_server.console_command("currency_add Gema oro 7 prueba").begins_with("Oro de Gema: +7"))
	var gift: EconomyOp = _last_op(gema)
	assert_true(await _settle())
	_platform.script_next(PlatformEvent.KIND_PROGRESS_OP, 200, _route_body(41, gift.op_id))
	replies = await _gm(gema, "gm op_revert %d me lo quito" % gift.op_id, 2)
	assert_eq(replies[1] if replies.size() > 1 else "", OWN, "op_revert sobre lo suyo, rechazado")
	assert_eq(_player(gema).record.wallets[GOLD], 7)
	assert_true(_player(gema).journal().is_empty())
	# El admin sí puede sobre los suyos.
	replies = await _gm(ada, "gm item_give Ada potion_health 1 para mí")
	assert_true(replies[0].begins_with("Dados 1 × potion_health a Ada"), replies[0])
	assert_true(await _settle())
	_assert_saves_accepted(40)


func test_a_fenced_zone_refuses_what_changes_something() -> void:
	if not await _start(true):
		return
	var ana: ServerPeer = await _join(1, 42, "Ana")
	var gema: ServerPeer = await _join(2, 41, "Gema", &"gm")
	if ana == null or ana.entity == null or gema == null or gema.entity == null:
		return
	assert_true(await _settle())
	_platform.set_fenced(true)
	var potions: int = _count(ana, POTION)
	var replies: PackedStringArray = await _gm(gema, "gm item_give Ana potion_health 2 regalo")
	assert_eq(replies[0], PLATFORM_DOWN, "item_give en una zona cercada")
	assert_eq(_count(ana, POTION), potions)
	assert_true(_player(ana).journal().is_empty(), "sin crear la operación")
	assert_eq(_server.console_command("level_set Ana 3 prueba"), PLATFORM_DOWN, "tampoco desde la consola")
	assert_eq(_server.console_command("op_revert 5000 prueba"), PLATFORM_DOWN)
	assert_eq(_player(ana).record.level, 1)
	# Las consultas que no piden nada a la plataforma siguen.
	assert_true(_server.console_command("inv_show Ana").begins_with("Inventario de Ana (personaje 42)"))
	_platform.set_fenced(false)
	replies = await _gm(gema, "gm item_give Ana potion_health 2 regalo")
	assert_true(replies[0].begins_with("Dados 2"), "fuera del cerco, sí")


func test_level_set_and_xp_add_leave_before_and_after_in_detail() -> void:
	if not await _start(true):
		return
	var ana: ServerPeer = await _join(1, 42, "Ana")
	var gema: ServerPeer = await _join(2, 41, "Gema", &"gm")
	if ana == null or ana.entity == null or gema == null or gema.entity == null:
		return
	assert_true(await _settle())
	var curve: LevelCurve = LevelCurve.shared()
	var replies: PackedStringArray = await _gm(gema, "gm level_set Ana 5 pruebas de nivel")
	var op: EconomyOp = _last_op(ana)
	if not assert_not_null(op):
		return
	assert_eq(replies[0], "Ana pasa del nivel 1 al 5 (%d de XP; operación %d)." % [curve.total_to(5), op.op_id])
	assert_eq(op.detail, {"command": "level_set", "args": ["42", "5"], "source": "gm", "actor_character_id": "41",
			"at_unix": NOW, "level_before": 1, "level_after": 5, "xp_before": 0, "xp_after": curve.total_to(5),
			"xp_delta": curve.total_to(5)}, "antes y después, y at_unix")
	assert_true(op.is_empty(), "una GM sin apuntes ni eventos")
	assert_eq([_player(ana).record.level, ana.entity.level], [5, 5], "el nivel en el registro y en la entidad")
	var level_ups: int = 0
	for bytes: PackedByteArray in _messages(ana, NetProtocol.MSG_ENTITY_EVENT):
		var decoded: NetMessages.EntityEvent = NetMessages.EntityEvent.decode(bytes)
		if decoded != null and decoded.event == NetMessages.EntityEvent.Kind.LEVEL_UP:
			level_ups += 1
	assert_eq(level_ups, 1, "su LEVEL_UP")
	assert_true(await _settle())
	# xp_add, como una fuente más; y bajar el nivel con level_set.
	replies = await _gm(gema, "gm xp_add Ana 100 más")
	op = _last_op(ana)
	assert_eq([op.detail["xp_before"], op.detail["xp_after"], op.detail["xp_delta"], op.detail["level_after"]],
			[curve.total_to(5), curve.total_to(5) + 100, 100, 5])
	replies = await _gm(gema, "gm level_set Ana 2 demasiado")
	op = _last_op(ana)
	assert_eq([op.detail["level_before"], op.detail["level_after"], op.detail["xp_delta"]],
			[5, 2, curve.total_to(2) - curve.total_to(5) - 100], "la XP baja con una GM")
	assert_eq(ana.entity.level, 2)
	assert_true(await _settle())
	_assert_saves_accepted(42)
	var saved: Dictionary = _saves_of(42).back()["progress"]
	assert_eq([int(saved["level"]), int(saved["xp_total"])], [2, curve.total_to(2)])
	# Revertir el level_set resta su xp_delta.
	_platform.script_next(PlatformEvent.KIND_PROGRESS_OP, 200, _route_body(42, op.op_id))
	replies = await _gm(gema, "gm op_revert %d era bueno" % op.op_id, 2)
	assert_eq([_player(ana).record.level, _player(ana).record.xp_total], [5, curve.total_to(5) + 100],
			"vuelve a donde estaba")
	assert_eq(ana.entity.level, 5)
	assert_true(await _settle())
	_assert_saves_accepted(42)


func test_reverting_merits_lowers_the_realm_points_too() -> void:
	if not await _start(true):
		return
	var ana: ServerPeer = await _join(1, 42, "Ana")
	var gema: ServerPeer = await _join(2, 41, "Gema", &"gm")
	if ana == null or ana.entity == null or gema == null or gema.entity == null:
		return
	assert_true(await _settle())
	# Una baja de PvP (agregada, como la paga on_merits) y su GAMEPLAY guardada.
	var player: PlayerProgress = _player(ana)
	player.gain_currency(Currency.Code.MERITS, 10, EconomyReason.PVP_KILL, LedgerEntry.RefKind.CHARACTER, 99)
	assert_eq(player.record.realm_points, 10, "I9: los méritos de PvP suben los puntos de reino")
	_server.get_saver().mark_critical(ana.entity.net_id, &"prueba")
	await _advance(2)
	assert_true(await _settle())
	var gameplay: Dictionary = (_saves_of(42).back()["progress"]["ops"] as Array).back()
	assert_eq(int(gameplay["kind"]), EconomyOp.Kind.GAMEPLAY)
	var op_id: int = ProgressJson.id_value(gameplay["op_id"])
	_platform.script_next(PlatformEvent.KIND_PROGRESS_OP, 200, _route_body(42, op_id))
	var replies: PackedStringArray = await _gm(gema, "gm op_revert %d baja pactada" % op_id, 2)
	assert_true(replies.size() > 1 and replies[1].begins_with("Operación %d de Ana revertida" % op_id), str(replies))
	assert_eq([player.record.wallets[Currency.Code.MERITS], player.record.realm_points], [0, 0],
			"los méritos y los puntos de reino que dieron, fuera")
	var reversal: EconomyOp = _last_op(ana)
	assert_true(reversal.ledger[0].equals(LedgerEntry.create(Currency.Code.MERITS, -10, 0, EconomyReason.REVERSAL,
			LedgerEntry.RefKind.OP, op_id)))
	assert_true(await _settle())
	assert_eq(int(_saves_of(42).back()["progress"]["realm_points"]), 0, "S6: el guardado con los puntos bajados")
	_assert_saves_accepted(42)


# --- Consultas por las rutas ------------------------------------------------------------------------

func test_ledger_show_and_op_show_through_the_routes() -> void:
	if not await _start(true):
		return
	var ana: ServerPeer = await _join(1, 42, "Ana")
	var gema: ServerPeer = await _join(2, 41, "Gema", &"gm")
	if ana == null or ana.entity == null or gema == null or gema.entity == null:
		return
	assert_true(await _settle())
	await _gm(gema, "gm currency_add Ana oro 50 primero")
	var first: EconomyOp = _last_op(ana)
	assert_true(await _settle())
	# Otra sin guardar todavía: la del diario sale primero, marcada.
	_platform.script_next(PlatformEvent.KIND_SAVE, 200, FakeZonePlatform.DEFAULT, 3.0)
	await _gm(gema, "gm currency_add Ana meritos 4 segundo")
	var second: EconomyOp = _last_op(ana)
	_platform.script_next(PlatformEvent.KIND_PROGRESS_LEDGER, 200, {"entries": [{"entry_id": "9", "op_id":
			str(first.op_id), "currency": GOLD, "seq": 1, "delta": 50, "balance_after": 50,
			"reason": EconomyReason.GM_GRANT, "ref_kind": 0, "ref_id": "0", "created_at_unix": NOW}]})
	var replies: PackedStringArray = await _gm(gema, "gm ledger_show Ana 5", 4)
	assert_eq(replies, PackedStringArray(["Pedido al servicio de cuentas: libro de Ana.",
			"Libro de Ana (personaje 42), 2 apuntes:",
			"op %d · méritos +4 → 4 (gm_grant) · sin guardar" % second.op_id,
			"op %d · oro +50 → 50 (gm_grant)" % first.op_id]))
	var request: Dictionary = _platform.sent(PlatformEvent.KIND_PROGRESS_LEDGER).back()
	assert_eq(request.get("path"), "/internal/v1/characters/42/ledger?limit=5&zone_instance_id=%s"
			% _platform.instance_id(), "la ruta del libro con su límite")
	# op_show de una sin guardar: del diario, sin pedir nada.
	replies = await _gm(gema, "gm op_show %d" % second.op_id, 2)
	assert_eq(replies[0], "Operación %d (gm) de personaje 42, actor 410, nota «segundo», comando currency_add, sin guardar."
			% second.op_id)
	assert_eq(_platform.sent(PlatformEvent.KIND_PROGRESS_OP).size(), 0)
	# op_show de una guardada, por la ruta; y una que no existe.
	_platform.script_next(PlatformEvent.KIND_PROGRESS_OP, 200, _route_body(42, first.op_id))
	replies = await _gm(gema, "gm op_show %d" % first.op_id, 3)
	assert_eq(replies.slice(1), PackedStringArray([
			"Operación %d (gm) de personaje 42, actor 410, nota «primero», comando currency_add." % first.op_id,
			"Apunte: oro +50 → 50 (gm_grant)"]))
	replies = await _gm(gema, "gm op_show 999999", 2)
	assert_eq(replies[1] if replies.size() > 1 else "", "No hay ninguna operación 999999 de un personaje de esta zona.")
	# Las consultas también se auditan, con el objetivo por id.
	var entries: Array[Dictionary] = _audit_of("ledger_show")
	if assert_eq(entries.size(), 1):
		assert_eq([entries[0]["target_character_id"], entries[0]["args"]], ["42", {"args": ["42", "5"]}])
	assert_eq(_audit_of("op_show").size(), 3)
	assert_eq(_server.console_command("mastery_set Ana espada 3"), "No disponible hasta la fase 6.")


# --- Sin plataforma ---------------------------------------------------------------------------------

func test_without_platform_everything_comes_from_the_journal() -> void:
	if not await _start(false):
		return
	var ana: ServerPeer = await _enter(1, null, "Ana")
	if ana == null or ana.entity == null:
		return
	var potions: int = _count(ana, POTION)
	var reply: String = _server.console_command("item_give Ana potion_health 20 prueba")
	var given: EconomyOp = _last_op(ana)
	if not assert_not_null(given):
		return
	assert_eq(reply, "Dados 20 × potion_health a Ana (operación %d)." % given.op_id)
	assert_eq(given.items.size(), 2, "pilas nuevas de 15 y 5")
	assert_eq(given.detail["args"], ["0", "potion_health", "20"], "un efímero no tiene character_id")
	assert_eq(_count(ana, POTION), potions + 20)
	assert_true(_server.console_command("inv_show Ana").contains("potion_health ×15"))
	assert_true(_server.console_command("op_show %d" % given.op_id).begins_with(
			"Operación %d (gm) de un efímero, nota «prueba», comando item_give." % given.op_id))
	# DEBUG_COMMAND sin plataforma: con --debug-commands, sin rol.
	_receive(ana, NetMessages.DebugCommand.currency_add(GOLD, 25).encode())
	await _advance(1)
	assert_eq(_player(ana).record.wallets[GOLD], 25)
	assert_true(_server.console_command("ledger_show Ana").contains("oro +25 → 25 (gm_grant)"))
	# Revertir del diario; la segunda, ya revertida.
	reply = _server.console_command("op_revert %d sobraba" % given.op_id)
	assert_true(reply.begins_with("Operación %d de Ana revertida" % given.op_id), reply)
	assert_eq(_count(ana, POTION), potions)
	assert_eq(_server.console_command("op_revert %d otra" % given.op_id), "Esa operación ya está revertida.")
	var reversal: EconomyOp = _last_op(ana)
	assert_eq(_server.console_command("op_revert %d" % reversal.op_id), "Uso: op_revert <op_id> <motivo…>")
	assert_eq(_server.console_command("op_revert %d deshacer" % reversal.op_id),
			"Una operación de tipo REVERSAL no se revierte.")
	# item_take: la otra arma sí se quita; la única que queda, no (I10).
	var equipment: InventoryState = _player(ana).record.inventory
	var active: ItemInstance = equipment.get_item(EQUIPMENT, 0)
	var other: ItemInstance = equipment.get_item(EQUIPMENT, 1)
	if other != null:
		assert_true(_server.console_command("item_take Ana %d quitar" % other.uid).begins_with("Quitados 1 × "),
				"la de la ranura que no es la activa")
		assert_null(equipment.get_item(EQUIPMENT, 1))
	if assert_not_null(active, "el arma del kit"):
		assert_eq(_server.console_command("item_take Ana %d quitar" % active.uid),
				"Es la única arma de Ana: no se le puede quitar.")
	# El 16 sin plataforma sigue siendo el CAMP_REFILL de siempre (sin operación GM).
	var ops: int = _player(ana).journal().size()
	_receive(ana, NetMessages.DebugCommand.simple(NetProtocol.DEBUG_REFILL).encode())
	await _advance(1)
	assert_eq(_player(ana).journal().size(), ops, "sin operación")


# --- La base: los uids del cuerpo y deshacer una operación ---------------------------------------------

func test_body_event_uids_follow_what_the_platform_has() -> void:
	var ids := IdAllocator.new()
	ids.build_reserve = 2
	ids.add_block(1025, 1024)
	var record := ProgressRecord.new_character()
	record.starter_template_id = &"squire"
	var player := PlayerProgress.new(record, true, ids, ItemDatabase.shared())
	assert_true(player.grant_starter_kit(&"squire"))
	var first: Dictionary = player.build_section(1)
	for event: Dictionary in first["ops"][0]["items"]:
		assert_not_null(event["uid"], "el kit crea uids nuevos: los lleva")
	player.acknowledge(1)
	var state: InventoryState = player.record.inventory
	var stack := Vector2i(-1, -1)
	for slot: int in range(state.bag_slots):
		if state.get_item(BAG, slot) != null and state.get_item(BAG, slot).def_id == POTION:
			stack = Vector2i(BAG, slot)
	if not assert_true(stack.x >= 0, "las pociones del kit"):
		return
	var saved_uid: int = state.get_item(stack.x, stack.y).uid
	var context := InventoryOps.Context.new()
	# Dividir (uid nuevo, sin guardar) y destruir esa mitad antes del guardado siguiente.
	var free: int = state.first_free(BAG)
	var split: InventoryOps.Outcome = player.apply_request(InventoryOps.make_request(InventoryOps.Op.SPLIT, BAG,
			stack.y, BAG, free, 1, saved_uid), context)
	assert_eq(split.result, InventoryOps.Result.OK, "SPLIT")
	var split_uid: int = state.get_item(BAG, free).uid
	assert_true(player.apply_request(InventoryOps.make_request(InventoryOps.Op.DESTROY, BAG, free,
			InventoryOps.NO_SLOT, InventoryOps.NO_SLOT, 1, split_uid), InventoryOps.Context.new()).is_ok())
	# Una GM que suma a la pila guardada y otra que crea una pila nueva.
	var gm: EconomyOp = player.begin_op(EconomyOp.Kind.GM, 77, "prueba", {"command": "refill"})
	assert_true(player.op_add_items(gm, state.get_item(stack.x, stack.y).def_id, 1, EconomyReason.GM_GRANT).is_ok())
	assert_true(player.op_create_items(gm, &"potion_stamina", 2, EconomyReason.GM_GRANT).is_ok())
	var second: Dictionary = player.build_section(2)
	var destroy: Dictionary = second["ops"][0]
	assert_eq([destroy["kind"], destroy["items"][0]["uid"]], [EconomyOp.Kind.PLAYER, null],
			"la mitad dividida no estaba guardada: sin uid")
	assert_eq(second["ops"][1]["items"][0]["uid"], null, "sumar a una guardada: sin uid")
	assert_eq(second["ops"][1]["items"][1]["uid"], str(gm.items[1].uid), "la pila nueva sí lo lleva")
	assert_eq(player.journal()[0].items[0].uid, split_uid, "el diario conserva el uid de verdad")
	player.acknowledge(2)
	# Lo que creó el cuerpo 2 ya está guardado: quitar de ella lleva su uid.
	var take: EconomyOp = player.begin_op(EconomyOp.Kind.GM, 77, "prueba", {"command": "item_take"})
	assert_true(player.op_remove_items(take, &"potion_stamina", 1, EconomyReason.GM_REMOVE, gm.items[1].uid).is_ok())
	var third: Dictionary = player.build_section(3)
	assert_eq(third["ops"][0]["items"][0]["uid"], str(gm.items[1].uid))


func test_abort_op_undoes_the_whole_operation() -> void:
	var ids := IdAllocator.new()
	ids.build_reserve = 2
	ids.add_block(1025, 1024)
	var player := PlayerProgress.new(ProgressRecord.new_character(), true, ids, ItemDatabase.shared())
	assert_true(player.grant_starter_kit(&"marksman"))
	player.gain_currency(GOLD, 10, EconomyReason.NPC_KILL, LedgerEntry.RefKind.NPC, 7)
	var inventory: InventoryState = player.record.inventory.duplicate_state()
	var revision: int = player.revision
	var op: EconomyOp = player.begin_op(EconomyOp.Kind.REVERSAL, 77, "prueba", {})
	var journal: int = player.journal().size()
	assert_true(player.change_currency(op, GOLD, -10, EconomyReason.REVERSAL, LedgerEntry.RefKind.OP, 5))
	assert_true(player.op_create_items(op, POTION, 20, EconomyReason.REVERSAL).is_ok())
	player.record.xp_total = 900
	player.record.level = 2
	assert_true(player.abort_op(op))
	assert_true(player.record.inventory.equals(inventory), "el inventario de antes")
	assert_eq([player.record.wallets[GOLD], player.record.level, player.record.xp_total, player.revision],
			[10, 1, 0, revision], "saldos, nivel, XP y revisión de antes")
	assert_eq(player.journal().size(), journal - 1, "la operación sale del diario")
	assert_eq(player.journal().back().kind, EconomyOp.Kind.GAMEPLAY, "lo agregado que cerró se queda")
	assert_false(player.abort_op(op), "una vez")
	# Quitar sin tocar las ranuras protegidas.
	var state: InventoryState = player.record.inventory
	var weapon: ItemInstance = state.get_item(EQUIPMENT, 0)
	var protected: Array[Vector2i] = [Vector2i(EQUIPMENT, 0)]
	assert_eq(InventoryOps.count_outside(state, weapon.def_id, protected), 0)
	assert_eq(InventoryOps.remove_items(state.duplicate_state(), weapon.def_id, 1, EconomyReason.REVERSAL, weapon.uid,
			protected).result, InventoryOps.Result.STALE, "ni con su uid")
