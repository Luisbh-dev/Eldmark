extends TestCase
## Lo de docs/progresion.md en el protocolo 7 (§4.6, §7.3, §10 y §12; paquete P4): [ProgressMessages] (0x50 a
## 0x55) de ida y vuelta, byte a byte y con cada malformación; el SPAWN de PLAYER con nivel y apariencia; el
## ENTITY_EVENT 16 LEVEL_UP; los DEBUG_COMMAND 40 a 43; que ninguno pasa de 1200 B; que
## [method NetEntity.encode_spawn] solo da el nivel real al dueño y a su reino y que [ZoneServer] reparte a cada
## receptor la variante de su reino en sus tres sitios; [method ItemDatabase.wire_hash] en el sim_hash; y la
## recepción en [NetClient] (señales) y en [SwarmBot] (descarte), que solo cuentan como mal formado lo que no se
## decodifica. Los decode nunca registran errores del motor (el ejecutor falla la prueba si se registra alguno).

const ARMOR_FIXTURES: String = "res://tests/fixtures/items/armor"
const CHARACTER_SCENE_PATH: String = "res://scenes/characters/player_character.tscn"
const VARDHEIM: int = NetProtocol.Realm.VARDHEIM
const SOLMARCH: int = NetProtocol.Realm.SOLMARCH
const ASKARRA: int = NetProtocol.Realm.ASKARRA
const FUZZ_SEED: int = 20261030
const FUZZ_BUFFERS: int = 6000
## La apariencia del ejemplo de docs/progresion.md §3.4 («AQAAAQEDAgE=»).
const APPEARANCE: PackedByteArray = [1, 0, 0, 1, 1, 3, 2, 1]

## Los cuatro objetos de data/items y las armaduras de prueba (con durabilidad), como test_item_instance.
var _db: ItemDatabase
var _nodes: Array[Node] = []
var _rig: NpcRig = null


## Una política de interés que lo ve todo, para que el reparto no dependa de las distancias.
class SeeAllPolicy:
	extends InterestPolicy

	func is_relevant(_observer: NetEntity, _entity: NetEntity, _was_relevant: bool) -> bool:
		return true


## Un transporte que no conecta nada y apunta lo que el servidor le manda a cada peer.
class RecordingTransport:
	extends NetTransport

	## peer_id -> mensajes en orden.
	var sent: Dictionary[int, Array] = {}

	func send(peer_id: int, _channel: int, bytes: PackedByteArray) -> Error:
		if not sent.has(peer_id):
			sent[peer_id] = []
		sent[peer_id].append(bytes)
		return OK

	func spawns_to(peer_id: int) -> Array[NetMessages.EntitySpawn]:
		var found: Array[NetMessages.EntitySpawn] = []
		for bytes: PackedByteArray in sent.get(peer_id, []):
			if NetMessages.peek_type(bytes) == NetProtocol.MSG_ENTITY_SPAWN:
				found.append(NetMessages.EntitySpawn.decode(bytes))
		return found


func before_each() -> void:
	var definitions: Array[ItemDefinition] = []
	for dir: String in [ItemDatabase.DATA_DIR.path_join("weapon"), ItemDatabase.DATA_DIR.path_join("consumable"),
			ARMOR_FIXTURES]:
		for file_name: String in DirAccess.get_files_at(dir):
			definitions.append(ResourceLoader.load(dir.path_join(file_name.trim_suffix(".remap"))) as ItemDefinition)
	_db = ItemDatabase.build_from_definitions(definitions)
	assert_eq(_db.errors, PackedStringArray(), "la base de la prueba vale")


func after_each() -> void:
	for node: Node in _nodes:
		if is_instance_valid(node):
			if node.get_parent() != null:
				node.get_parent().remove_child(node)
			node.free()
	_nodes.clear()
	if _rig != null:
		await _rig.stop()
	_rig = null
	await wait_process_frames()


# --- Constantes -------------------------------------------------------------------------------

func test_protocol_constants() -> void:
	assert_eq([NetProtocol.MSG_INVENTORY_REQUEST, NetProtocol.MSG_INVENTORY_DELTA, NetProtocol.MSG_INVENTORY_FULL,
			NetProtocol.MSG_INVENTORY_SYNC_REQUEST, NetProtocol.MSG_WALLET_UPDATE, NetProtocol.MSG_PROGRESS_UPDATE],
			[0x50, 0x51, 0x52, 0x53, 0x54, 0x55], "tipos 0x50 a 0x55")
	for message_type: int in range(0x50, 0x56):
		assert_eq(NetProtocol.channel_for_type(message_type), NetProtocol.CH_RELIABLE,
				"0x%02X va por el canal fiable" % message_type)
	assert_eq(NetMessages.EntityEvent.Kind.LEVEL_UP, 16, "LEVEL_UP es el evento 16")
	assert_eq([NetProtocol.DEBUG_ITEM_GIVE, NetProtocol.DEBUG_CURRENCY_ADD, NetProtocol.DEBUG_LEVEL_SET,
			NetProtocol.DEBUG_XP_ADD], [40, 41, 42, 43], "ids fijos 40 a 43")
	for command_name: StringName in [&"item_give", &"currency_add", &"level_set", &"xp_add"]:
		assert_true(NetProtocol.DEBUG_COMMAND_IDS.has(command_name), "%s en la tabla de ids" % command_name)
	assert_eq(ProgressMessages.MAX_LEVEL, LevelCurve.shared().level_cap, "el tope del protocolo es el de la curva")
	assert_eq(ProgressMessages.InventoryDelta.MAX_SIZE, 1120, "INVENTORY_DELTA ≤ 1120 B")
	assert_eq(ProgressMessages.InventoryFull.MAX_SIZE, 1089, "INVENTORY_FULL ≤ 1089 B")
	assert_eq(ProgressMessages.NO_SLOT, 0xFF, "destino de DESTROY")
	assert_eq(NetMessages.PLAYER_SPAWN_TAIL_SIZE, 9, "+9 B del SPAWN de PLAYER")
	assert_eq(NetProtocol.PROTOCOL_VERSION, 7, "sin subir la versión: es la de plataforma.md P4")


# --- INVENTORY_REQUEST ------------------------------------------------------------------------

func test_inventory_request_layout_and_round_trip() -> void:
	var request: InventoryOps.Request = InventoryOps.make_request(InventoryOps.Op.SPLIT, 0, 4, 0, 9, 3,
			0x0012345678ABCDEF)
	var message := ProgressMessages.InventoryRequest.from_request(0xBEEF, request)
	var bytes: PackedByteArray = message.encode()
	assert_eq(bytes.size(), 18, "18 B")
	assert_eq(bytes[0], 0x50, "u8 type")
	assert_eq(bytes.decode_u16(1), 0xBEEF, "u16 request_id en 1")
	assert_eq([bytes[3], bytes[4], bytes[5], bytes[6], bytes[7]], [2, 0, 4, 0, 9], "op y ranuras en 3 a 7")
	assert_eq(bytes.decode_u16(8), 3, "u16 count en 8")
	assert_eq(bytes.decode_u64(10), 0x0012345678ABCDEF, "u64 expected_uid en 10")
	var back: ProgressMessages.InventoryRequest = ProgressMessages.InventoryRequest.decode(bytes)
	if assert_not_null(back, "decode"):
		assert_eq(back.request_id, 0xBEEF, "request_id")
		var again: InventoryOps.Request = back.to_request()
		assert_eq([again.op, again.from_container, again.from_slot, again.to_container, again.to_slot,
				again.count, again.expected_uid], [2, 0, 4, 0, 9, 3, 0x0012345678ABCDEF], "la misma petición")

	# DESTROY: el destino viaja como 0xFF y vuelve igual.
	var destroy := ProgressMessages.InventoryRequest.from_request(1,
			InventoryOps.make_request(InventoryOps.Op.DESTROY, 1, 0, 0, 3, 0, 77))
	var destroy_bytes: PackedByteArray = destroy.encode()
	assert_eq([destroy_bytes[6], destroy_bytes[7]], [0xFF, 0xFF], "destino 0xFF en DESTROY")
	var destroy_back: ProgressMessages.InventoryRequest = ProgressMessages.InventoryRequest.decode(destroy_bytes)
	if assert_not_null(destroy_back, "DESTROY se decodifica"):
		assert_eq(destroy_back.to_request().to_container, InventoryOps.NO_SLOT, "a InventoryOps.NO_SLOT")
	var move := ProgressMessages.InventoryRequest.from_request(65535,
			InventoryOps.make_request(InventoryOps.Op.MOVE, 0, 119, 1, 1, 0, 5))
	assert_not_null(ProgressMessages.InventoryRequest.decode(move.encode()), "MOVE al equipo con el id 65535")

	# Lo que no admite el decode.
	var cases: Array[Array] = [
		[1, 0, "request_id 0"], [3, 0, "op 0"], [3, 4, "op 4"], [4, 4, "contenedor de origen 4"],
		[6, 4, "contenedor de destino 4"], [6, 0xFF, "MOVE con el destino de DESTROY"],
		[7, 0xFF, "MOVE a la ranura 0xFF"],
	]
	for entry: Array in cases:
		var tampered: PackedByteArray = move.encode()
		if entry[0] == 1:
			tampered.encode_u16(1, entry[1])
		else:
			tampered[entry[0]] = entry[1]
		assert_null(ProgressMessages.InventoryRequest.decode(tampered), entry[2])
	var half_destroy: PackedByteArray = destroy_bytes.duplicate()
	half_destroy[7] = 3
	assert_null(ProgressMessages.InventoryRequest.decode(half_destroy), "DESTROY con una ranura de destino")
	half_destroy = destroy_bytes.duplicate()
	half_destroy[6] = 0
	assert_null(ProgressMessages.InventoryRequest.decode(half_destroy), "DESTROY con un contenedor de destino")
	# Lo mismo al codificar: vacío.
	message.request_id = 0
	assert_true(message.encode().is_empty(), "sin request_id no se codifica")
	message.request_id = 70000
	assert_true(message.encode().is_empty(), "ni con uno que no cabe en u16")
	message.request_id = 5
	message.count = 70000
	assert_true(message.encode().is_empty(), "ni con una cantidad que no cabe")
	assert_eq(ProgressMessages.InventorySyncRequest.new().encode(), PackedByteArray([0x53]),
			"INVENTORY_SYNC_REQUEST: 1 B")
	assert_not_null(ProgressMessages.InventorySyncRequest.decode(PackedByteArray([0x53])), "se decodifica")


# --- INVENTORY_DELTA --------------------------------------------------------------------------

func test_inventory_delta_layout_and_round_trip() -> void:
	var potion: ItemInstance = _item(1025, &"potion_health", 3)
	var helm: ItemInstance = _item(1026, &"test_iron_helm", 1)
	helm.durability = 640
	helm.rarity = 2
	helm.seed = 0xDEADBEEF
	helm.affixes = PackedInt32Array([7, 65535])
	var delta := ProgressMessages.InventoryDelta.new()
	delta.revision = 0xFFFFFFFF
	delta.request_id = 12
	delta.result = InventoryOps.Result.OK
	delta.entries.append(ProgressMessages.Entry.make(0, 4, potion))
	delta.entries.append(ProgressMessages.Entry.make(0, 5, null))
	delta.entries.append(ProgressMessages.Entry.make(1, 6, helm))
	var bytes: PackedByteArray = delta.encode(_db)
	var potion_bytes: PackedByteArray = potion.encode(_db)
	var helm_bytes: PackedByteArray = helm.encode(_db)
	assert_eq(bytes.size(), 10 + 3 + potion_bytes.size() + 3 + 3 + helm_bytes.size(), "10 B + entradas")
	assert_eq(bytes[0], 0x51, "u8 type")
	assert_eq(bytes.decode_u32(1), 0xFFFFFFFF, "u32 revision en 1")
	assert_eq(bytes.decode_u16(5), 12, "u16 request_id en 5")
	assert_eq([bytes[7], bytes[8], bytes[9]], [0, 0, 3], "result, reason y entry_count")
	assert_eq([bytes[10], bytes[11], bytes[12]], [0, 4, 1], "container, slot y present")
	assert_eq(bytes.slice(13, 13 + potion_bytes.size()), potion_bytes, "y el objeto")
	var empty_at: int = 13 + potion_bytes.size()
	assert_eq([bytes[empty_at], bytes[empty_at + 1], bytes[empty_at + 2]], [0, 5, 0], "una ranura vacía")
	var back: ProgressMessages.InventoryDelta = ProgressMessages.InventoryDelta.decode(bytes, _db)
	if assert_not_null(back, "decode"):
		assert_eq([back.revision, back.request_id, back.result, back.reason], [0xFFFFFFFF, 12, 0, 0], "cabecera")
		assert_eq(back.entries.size(), 3, "entradas")
		for i: int in 3:
			assert_true(back.entries[i].equals(delta.entries[i]), "entrada %d igual" % i)

	# Un cambio del servidor: request_id 0, resultado OK y un motivo conocido.
	var state := InventoryState.new()
	state.set_item(0, 2, potion)
	var refill := ProgressMessages.InventoryDelta.for_slots(8, 0, InventoryOps.Result.OK,
			EconomyReason.CAMP_REFILL, state, [Vector2i(0, 2), Vector2i(0, 3)] as Array[Vector2i])
	var refill_back := ProgressMessages.InventoryDelta.decode(refill.encode())
	if assert_not_null(refill_back, "un cambio del servidor con la base compartida"):
		assert_eq(refill_back.reason, EconomyReason.CAMP_REFILL, "su motivo")
		assert_true(refill_back.entries[0].item.equals(potion), "la ranura 2 con la poción")
		assert_null(refill_back.entries[1].item, "la 3 vacía")
	# Un rechazo lleva el contenido real y su resultado.
	var rejected := ProgressMessages.InventoryDelta.for_slots(8, 3, InventoryOps.Result.STALE, 0, state,
			[Vector2i(0, 2)] as Array[Vector2i])
	assert_eq(ProgressMessages.InventoryDelta.decode(rejected.encode()).result, InventoryOps.Result.STALE,
			"un rechazo")
	# Cabeceras que no valen.
	var header_cases: Array[Array] = [
		[3, 0, EconomyReason.CAMP_REFILL, "una respuesta con motivo"],
		[0, InventoryOps.Result.STALE, EconomyReason.CAMP_REFILL, "un cambio del servidor rechazado"],
		[0, 0, 0, "un cambio del servidor sin motivo"], [0, 0, 200, "un motivo desconocido"],
		[3, 9, 0, "un resultado que no existe"],
	]
	for entry: Array in header_cases:
		var tampered: PackedByteArray = rejected.encode()
		tampered.encode_u16(5, entry[0])
		tampered[7] = entry[1]
		tampered[8] = entry[2]
		assert_null(ProgressMessages.InventoryDelta.decode(tampered), entry[3])
		var bad := ProgressMessages.InventoryDelta.for_slots(1, entry[0], entry[1], entry[2], state,
				[] as Array[Vector2i])
		assert_true(bad.encode().is_empty(), "%s no se codifica" % entry[3])
	# Entradas que no valen.
	var entry_cases: Array[Array] = [
		[0, 120, 0, "ranura 120 de la bolsa"], [1, 7, 0, "ranura 7 del equipo"], [4, 0, 0, "contenedor 4"],
		[0, 1, 2, "present 2"],
	]
	for entry: Array in entry_cases:
		var tampered := PackedByteArray([0x51, 1, 0, 0, 0, 1, 0, 0, 0, 1, entry[0], entry[1], entry[2]])
		assert_null(ProgressMessages.InventoryDelta.decode(tampered), entry[3])
	assert_not_null(ProgressMessages.InventoryDelta.decode(PackedByteArray([0x51, 1, 0, 0, 0, 1, 0, 0, 0, 1,
			2, 119, 0])), "el banco (2) con la ranura 119 viaja: lo rechaza el servidor")
	var twice := PackedByteArray([0x51, 1, 0, 0, 0, 1, 0, 0, 0, 2, 0, 1, 0, 0, 1, 0])
	assert_null(ProgressMessages.InventoryDelta.decode(twice), "una ranura repetida")
	var twice_delta := ProgressMessages.InventoryDelta.for_slots(1, 1, 0, 0, state,
			[Vector2i(0, 2), Vector2i(0, 2)] as Array[Vector2i])
	assert_true(twice_delta.encode().is_empty(), "no se codifica una ranura repetida")
	var bad_item: PackedByteArray = bytes.duplicate()
	bad_item[13] = 2
	assert_null(ProgressMessages.InventoryDelta.decode(bad_item, _db), "un objeto con el formato 2")
	var unknown := ItemInstance.new()
	unknown.uid = 5
	unknown.def_id = &"no_existe"
	var with_unknown := ProgressMessages.InventoryDelta.new()
	with_unknown.request_id = 1
	with_unknown.entries.append(ProgressMessages.Entry.make(0, 0, unknown))
	assert_true(with_unknown.encode(_db).is_empty(), "un objeto que no vale no se codifica")


## 30 entradas con objetos de seis afijos son el delta más grande: 1120 B. Con 31, nada.
func test_the_largest_delta_and_full_page_fit() -> void:
	var delta := ProgressMessages.InventoryDelta.new()
	delta.request_id = 1
	var page := ProgressMessages.InventoryFull.new()
	page.bag_slots = 120
	for slot: int in 30:
		var item: ItemInstance = _item(1000 + slot, &"potion_stamina", 15)
		item.affixes = PackedInt32Array([1, 2, 3, 4, 5, 6])
		delta.entries.append(ProgressMessages.Entry.make(0, slot, item))
		page.entries.append(ProgressMessages.Entry.make(0, slot, item))
	var delta_bytes: PackedByteArray = delta.encode()
	var page_bytes: PackedByteArray = page.encode()
	assert_eq(delta_bytes.size(), 1120, "el delta más grande")
	assert_eq(page_bytes.size(), 1089, "la página más grande")
	assert_not_null(ProgressMessages.InventoryDelta.decode(delta_bytes), "se decodifica")
	assert_not_null(ProgressMessages.InventoryFull.decode(page_bytes), "se decodifica")
	delta.entries.append(ProgressMessages.Entry.make(0, 30, null))
	assert_true(delta.encode().is_empty(), "31 entradas no se codifican")
	page.entries.append(ProgressMessages.Entry.make(0, 30, _item(2000, &"bow_vado", 1)))
	assert_true(page.encode().is_empty(), "ni en una página")
	var too_many: PackedByteArray = delta_bytes.duplicate()
	too_many[9] = 31
	assert_null(ProgressMessages.InventoryDelta.decode(too_many), "entry_count 31")
	var too_many_page: PackedByteArray = page_bytes.duplicate()
	too_many_page[8] = 31
	assert_null(ProgressMessages.InventoryFull.decode(too_many_page), "entry_count 31 en una página")


# --- INVENTORY_FULL ---------------------------------------------------------------------------

func test_inventory_full_layout_split_and_assemble() -> void:
	var state := InventoryState.new(InventoryState.BAG_SLOTS_MAX)
	for slot: int in InventoryState.BAG_SLOTS_MAX:
		state.set_item(0, slot, _item(5000 + slot, &"potion_health", 1 + slot % 15))
	state.set_item(1, 0, _item(9000, &"sword_shield_vado", 1))
	state.set_item(1, 1, _item(9001, &"bow_vado", 1))
	var pages: Array[ProgressMessages.InventoryFull] = ProgressMessages.InventoryFull.split(77, state)
	assert_eq(pages.size(), 5, "122 objetos en 5 páginas de 30")
	var decoded: Array[ProgressMessages.InventoryFull] = []
	for page: ProgressMessages.InventoryFull in pages:
		var bytes: PackedByteArray = page.encode()
		assert_true(not bytes.is_empty() and bytes.size() <= ProgressMessages.InventoryFull.MAX_SIZE,
				"la página %d cabe (%d B)" % [page.page_index, bytes.size()])
		var back: ProgressMessages.InventoryFull = ProgressMessages.InventoryFull.decode(bytes)
		if assert_not_null(back, "página %d" % page.page_index):
			decoded.append(back)
	if decoded.size() != 5:
		return
	var first: PackedByteArray = pages[0].encode()
	assert_eq(first[0], 0x52, "u8 type")
	assert_eq(first.decode_u32(1), 77, "u32 revision en 1")
	assert_eq([first[5], first[6], first[7], first[8]], [120, 0, 5, 30], "bag_slots, página, páginas y entradas")
	assert_eq([first[9], first[10]], [0, 0], "la primera entrada es la ranura 0 de la bolsa")
	assert_eq(decoded[4].entries.size(), 2, "la última página, las dos armas")
	assert_eq(decoded[4].entries[1].container, 1, "del equipo")
	# Juntas en otro orden, el mismo inventario.
	decoded.reverse()
	var assembled: InventoryState = ProgressMessages.InventoryFull.assemble(decoded)
	if assert_not_null(assembled, "se juntan"):
		assert_true(assembled.equals(state), "el mismo inventario")
	# Lo que no se junta.
	assert_null(ProgressMessages.InventoryFull.assemble(decoded.slice(0, 4)), "falta una página")
	var other_revision: Array[ProgressMessages.InventoryFull] = decoded.duplicate()
	var stale: ProgressMessages.InventoryFull = ProgressMessages.InventoryFull.decode(pages[2].encode())
	stale.revision = 78
	other_revision[2] = stale
	assert_null(ProgressMessages.InventoryFull.assemble(other_revision), "una página de otra revisión")
	var repeated: Array[ProgressMessages.InventoryFull] = decoded.duplicate()
	repeated[0] = decoded[1]
	assert_null(ProgressMessages.InventoryFull.assemble(repeated), "una página repetida")
	assert_null(ProgressMessages.InventoryFull.assemble([] as Array[ProgressMessages.InventoryFull]), "sin páginas")
	# Un inventario vacío es una página vacía.
	var empty_pages: Array[ProgressMessages.InventoryFull] = ProgressMessages.InventoryFull.split(1,
			InventoryState.new())
	assert_eq(empty_pages.size(), 1, "una página")
	var empty_bytes: PackedByteArray = empty_pages[0].encode()
	assert_eq(empty_bytes, PackedByteArray([0x52, 1, 0, 0, 0, 30, 0, 1, 0]), "9 B: bolsa de 30, página 0 de 1")
	var empty_back: InventoryState = ProgressMessages.InventoryFull.assemble(
			[ProgressMessages.InventoryFull.decode(empty_bytes)] as Array[ProgressMessages.InventoryFull])
	if assert_not_null(empty_back, "se junta"):
		assert_true(empty_back.equals(InventoryState.new()), "vacío, con 30 ranuras")
	# Cabeceras y entradas que no valen.
	var header_cases: Array[Array] = [
		[5, 0, "bag_slots 0"], [5, 121, "bag_slots 121"], [7, 0, "page_count 0"], [7, 9, "page_count 9"],
		[6, 1, "page_index igual a page_count"],
	]
	for entry: Array in header_cases:
		var tampered: PackedByteArray = empty_bytes.duplicate()
		tampered[entry[0]] = entry[1]
		assert_null(ProgressMessages.InventoryFull.decode(tampered), entry[2])
	var small := InventoryState.new(10)
	small.set_item(0, 9, _item(42, &"potion_health", 2))
	var small_bytes: PackedByteArray = ProgressMessages.InventoryFull.split(3, small)[0].encode()
	assert_not_null(ProgressMessages.InventoryFull.decode(small_bytes), "la ranura 9 de una bolsa de 10")
	small_bytes[9 + 1] = 10
	assert_null(ProgressMessages.InventoryFull.decode(small_bytes), "la 10 de una bolsa de 10 no existe")
	small_bytes[9 + 1] = 9
	small_bytes[9] = 1
	assert_null(ProgressMessages.InventoryFull.decode(small_bytes), "ni la 9 del equipo")
	var bank := ProgressMessages.InventoryFull.new()
	bank.entries.append(ProgressMessages.Entry.make(2, 0, _item(43, &"potion_health", 1)))
	var bank_page: ProgressMessages.InventoryFull = ProgressMessages.InventoryFull.decode(bank.encode())
	if assert_not_null(bank_page, "el banco viaja"):
		assert_null(ProgressMessages.InventoryFull.assemble([bank_page] as Array[ProgressMessages.InventoryFull]),
				"pero no se junta en la fase 5")
	var hole := ProgressMessages.InventoryFull.new()
	hole.entries.append(ProgressMessages.Entry.make(0, 0, null))
	assert_true(hole.encode().is_empty(), "una página no lleva ranuras vacías")


# --- WALLET_UPDATE y PROGRESS_UPDATE ---------------------------------------------------------

func test_wallet_update_layout_and_ranges() -> void:
	var update := ProgressMessages.WalletUpdate.make(Currency.Code.MERITS, Currency.CAP, -30,
			EconomyReason.GM_REMOVE)
	var bytes: PackedByteArray = update.encode()
	assert_eq(bytes.size(), 19, "19 B")
	assert_eq([bytes[0], bytes[1]], [0x54, 2], "type y moneda")
	assert_eq(bytes.decode_u64(2), Currency.CAP, "u64 balance en 2")
	assert_eq(bytes.decode_s64(10), -30, "s64 delta en 10")
	assert_eq(bytes[18], EconomyReason.GM_REMOVE, "u8 reason en 18")
	var back: ProgressMessages.WalletUpdate = ProgressMessages.WalletUpdate.decode(bytes)
	if assert_not_null(back, "decode"):
		assert_eq([back.currency, back.balance, back.delta, back.reason], [2, Currency.CAP, -30, 66], "campos")
	assert_not_null(ProgressMessages.WalletUpdate.decode(ProgressMessages.WalletUpdate.make(1, 0, 0, 0).encode()),
			"el estado inicial: delta 0 y sin motivo")
	var cases: Array[Array] = [
		[0, 10, 0, 0, "moneda 0"], [3, 10, 0, 0, "moneda 3"], [1, Currency.CAP + 1, 0, 0, "saldo por encima del tope"],
		[1, -1, 0, 0, "saldo negativo (u64 de 2^63 o más)"], [1, 0, -Currency.CAP - 1, 0, "delta por debajo del tope"],
		[1, 0, Currency.CAP + 1, 0, "delta por encima"], [1, 0, 5, 200, "motivo desconocido"],
	]
	for entry: Array in cases:
		var bad := ProgressMessages.WalletUpdate.make(entry[0], entry[1], entry[2], entry[3])
		assert_true(bad.encode().is_empty(), "%s no se codifica" % entry[4])
		var tampered: PackedByteArray = bytes.duplicate()
		tampered[1] = entry[0]
		tampered.encode_u64(2, entry[1])
		tampered.encode_s64(10, entry[2])
		tampered[18] = entry[3]
		assert_null(ProgressMessages.WalletUpdate.decode(tampered), entry[4])


func test_progress_update_layout_and_ranges() -> void:
	var curve: LevelCurve = LevelCurve.shared()
	var update: ProgressMessages.ProgressUpdate = ProgressMessages.ProgressUpdate.make(curve, 8, 12345, 300,
			ProgressMessages.XpSource.CAPTURE, 420)
	assert_eq(update.xp_in_level, 12345 - curve.total_to(8), "la XP desde el principio del nivel")
	assert_eq(update.xp_to_next, curve.xp_for_next(8), "la que pide el siguiente")
	assert_eq(update.attribute_points, 7, "un punto por nivel ganado")
	var bytes: PackedByteArray = update.encode()
	assert_eq(bytes.size(), 25, "25 B")
	assert_eq([bytes[0], bytes[1]], [0x55, 8], "type y level")
	assert_eq(bytes.decode_u32(2), update.xp_in_level, "u32 xp_in_level en 2")
	assert_eq(bytes.decode_u32(6), update.xp_to_next, "u32 xp_to_next en 6")
	assert_eq(bytes.decode_u32(10), 300, "u32 gained en 10")
	assert_eq(bytes[14], 3, "u8 source en 14")
	assert_eq(bytes.decode_u64(15), 420, "u64 realm_points en 15")
	assert_eq(bytes.decode_u16(23), 7, "u16 attribute_points en 23")
	var back: ProgressMessages.ProgressUpdate = ProgressMessages.ProgressUpdate.decode(bytes)
	if assert_not_null(back, "decode"):
		assert_eq([back.level, back.xp_in_level, back.xp_to_next, back.gained, back.source, back.realm_points,
				back.attribute_points], [8, update.xp_in_level, update.xp_to_next, 300, 3, 420, 7], "campos")
	# En el tope: 0 de XP del nivel y 0 al siguiente.
	var capped: ProgressMessages.ProgressUpdate = ProgressMessages.ProgressUpdate.make(curve, curve.level_cap,
			curve.total_to(curve.level_cap), 0, ProgressMessages.XpSource.STATE, 0)
	assert_eq([capped.xp_in_level, capped.xp_to_next], [0, 0], "en el tope")
	assert_not_null(ProgressMessages.ProgressUpdate.decode(capped.encode()), "se decodifica")
	var first: ProgressMessages.ProgressUpdate = ProgressMessages.ProgressUpdate.make(curve, 1, 0, 0,
			ProgressMessages.XpSource.STATE, 0)
	assert_eq([first.level, first.xp_in_level, first.xp_to_next, first.attribute_points], [1, 0, 500, 0], "nivel 1")
	var cases: Array[Array] = [
		[1, 0, "nivel 0"], [1, 41, "nivel 41"], [14, 5, "fuente 5"],
	]
	for entry: Array in cases:
		var tampered: PackedByteArray = bytes.duplicate()
		tampered[entry[0]] = entry[1]
		assert_null(ProgressMessages.ProgressUpdate.decode(tampered), entry[2])
	var over: PackedByteArray = bytes.duplicate()
	over.encode_u32(2, update.xp_to_next)
	assert_null(ProgressMessages.ProgressUpdate.decode(over), "la XP del nivel llega a la del siguiente")
	var capped_bytes: PackedByteArray = capped.encode()
	capped_bytes.encode_u32(2, 1)
	assert_null(ProgressMessages.ProgressUpdate.decode(capped_bytes), "XP del nivel en el tope")
	var rich: PackedByteArray = bytes.duplicate()
	rich.encode_u64(15, -1)
	assert_null(ProgressMessages.ProgressUpdate.decode(rich), "puntos de reino de 2^63 o más")
	update.source = 9
	assert_true(update.encode().is_empty(), "una fuente que no existe no se codifica")


# --- SPAWN de PLAYER, LEVEL_UP y DEBUG_COMMAND 40 a 43 ----------------------------------------

func test_player_spawn_carries_level_and_appearance() -> void:
	var spawn := NetMessages.EntitySpawn.new()
	spawn.net_id = 31
	spawn.realm = VARDHEIM
	spawn.state = PlayerState.new()
	spawn.display_name = "Aneira"
	spawn.level = 17
	spawn.appearance = APPEARANCE
	var bytes: PackedByteArray = spawn.encode()
	var name_end: int = 10 + PlayerState.ENCODED_SIZE + 1 + "Aneira".length()
	assert_eq(bytes.size(), name_end + 9, "+9 B tras el nombre")
	assert_eq(bytes[name_end], 17, "u8 level")
	assert_eq(bytes.slice(name_end + 1), APPEARANCE, "8 B de apariencia")
	var back: NetMessages.EntitySpawn = NetMessages.EntitySpawn.decode(bytes)
	if assert_not_null(back, "decode"):
		assert_eq(back.level, 17, "nivel")
		assert_eq(back.appearance, APPEARANCE, "apariencia")
	# La validez de la apariencia no es del decode; el nivel por encima del tope sí lo rechaza.
	var odd: PackedByteArray = bytes.duplicate()
	for i: int in 8:
		odd[name_end + 1 + i] = 0xEE
	assert_not_null(NetMessages.EntitySpawn.decode(odd), "una apariencia que no vale pasa el decode")
	odd[name_end] = 41
	assert_null(NetMessages.EntitySpawn.decode(odd), "nivel 41")
	spawn.level = 99
	assert_eq(spawn.encode()[name_end], 40, "al codificar se satura al tope")
	# Sin apariencia (o con otro tamaño), 8 B a 0.
	spawn.appearance = PackedByteArray([1, 2, 3])
	assert_eq(spawn.encode().slice(name_end + 1), PackedByteArray([0, 0, 0, 0, 0, 0, 0, 0]), "8 B a 0")
	assert_null(NetMessages.EntitySpawn.decode(bytes.slice(0, bytes.size() - 1)), "un byte de menos")
	# El PNJ no cambia: su u16 npc_def_id tras el nombre.
	spawn.kind = NetProtocol.EntityKind.NPC
	spawn.npc_def_id = 0x0102
	var npc: PackedByteArray = spawn.encode()
	assert_eq(npc.size(), name_end + 2, "el PNJ sigue con 2 B tras el nombre")
	assert_eq(npc.decode_u16(name_end), 0x0102, "su npc_def_id")
	var npc_back: NetMessages.EntitySpawn = NetMessages.EntitySpawn.decode(npc)
	if assert_not_null(npc_back, "decode del PNJ"):
		assert_eq([npc_back.npc_def_id, npc_back.level, npc_back.appearance.size()], [0x0102, 0, 0], "sin nivel")


func test_encode_spawn_gives_the_real_level_only_to_the_owner_and_its_realm() -> void:
	var entity := NetEntity.new()
	entity.net_id = 12
	entity.kind = NetProtocol.EntityKind.PLAYER
	entity.realm = VARDHEIM
	entity.display_name = "Brand"
	entity.level = 23
	entity.appearance = APPEARANCE
	var cases: Array[Array] = [
		[true, NetProtocol.Realm.NONE, 23, "el dueño"], [true, SOLMARCH, 23, "el dueño, con cualquier reino"],
		[false, VARDHEIM, 23, "su reino"], [false, SOLMARCH, 0, "otro reino"], [false, ASKARRA, 0, "Askarra"],
		[false, NetProtocol.Realm.NONE, 0, "sin reino receptor"],
	]
	for entry: Array in cases:
		var spawn: NetMessages.EntitySpawn = NetMessages.EntitySpawn.decode(
				entity.encode_spawn(40, entry[0], entry[1]))
		if assert_not_null(spawn, entry[3]):
			assert_eq(spawn.level, entry[2], "nivel para %s" % entry[3])
			assert_eq(spawn.appearance, APPEARANCE, "la apariencia la ve todo el mundo (%s)" % entry[3])
	assert_eq(NetMessages.EntitySpawn.decode(entity.encode_spawn(40, false)).level, 0,
			"sin reino receptor, nivel 0 (la llamada de antes del protocolo 7)")
	var fake := NetEntity.new()
	fake.kind = NetProtocol.EntityKind.PLAYER
	fake.realm = SOLMARCH
	var fake_spawn: NetMessages.EntitySpawn = NetMessages.EntitySpawn.decode(fake.encode_spawn(1, false, SOLMARCH))
	assert_eq([fake_spawn.level, fake_spawn.appearance], [0, PackedByteArray([0, 0, 0, 0, 0, 0, 0, 0])],
			"un jugador sin progreso (falso o efímero sin P5b): nivel 0 y sin apariencia")


func test_level_up_event() -> void:
	var event := NetMessages.EntityEvent.level_up(321, 123456, 9)
	var bytes: PackedByteArray = event.encode()
	assert_eq(bytes.size(), 10, "LEVEL_UP: 10 B")
	assert_eq([bytes[0], bytes.decode_u16(1), bytes.decode_u32(3), bytes[7], bytes[8], bytes[9]],
			[0x23, 321, 123456, 16, 1, 9], "type, net_id, tick, event 16, len 1 y level")
	var back: NetMessages.EntityEvent = NetMessages.EntityEvent.decode(bytes)
	if assert_not_null(back, "decode"):
		assert_eq([back.event, back.net_id, back.tick, back.level], [16, 321, 123456, 9], "campos")
		assert_eq(back.get_source(), CombatSource.NONE, "no tiene fuente")
	for level: int in [0, 41, 255]:
		var tampered: PackedByteArray = bytes.duplicate()
		tampered[9] = level
		assert_null(NetMessages.EntityEvent.decode(tampered), "nivel %d" % level)
	var long_bytes: PackedByteArray = bytes.duplicate()
	long_bytes.append(0)
	long_bytes[8] = 2
	assert_null(NetMessages.EntityEvent.decode(long_bytes), "con len 2")
	assert_eq(NetMessages.EntityEvent.level_up(1, 1, 60).encode()[9], 40, "se satura al tope al codificar")
	assert_eq(NetMessages.EntityEvent.level_up(1, 1, 0).encode()[9], 1, "y al nivel 1")


func test_debug_commands_40_to_43() -> void:
	var give := NetMessages.DebugCommand.item_give(3, 999)
	assert_eq(give.encode(), PackedByteArray([0x04, 40, 3, 0, 0xE7, 0x03]), "item_give: u16 def y u16 count")
	var give_back: NetMessages.DebugCommand = NetMessages.DebugCommand.decode(give.encode())
	if assert_not_null(give_back, "item_give"):
		assert_eq([give_back.get_item_net_id(), give_back.get_item_count()], [3, 999], "sus datos")
	var add := NetMessages.DebugCommand.currency_add(Currency.Code.GOLD, -50)
	var add_bytes: PackedByteArray = add.encode()
	assert_eq(add_bytes.size(), 7, "currency_add: 2 + 5 B")
	assert_eq([add_bytes[1], add_bytes[2], add_bytes.decode_s32(3)], [41, 1, -50], "u8 moneda y s32 cantidad")
	var add_back: NetMessages.DebugCommand = NetMessages.DebugCommand.decode(add_bytes)
	if assert_not_null(add_back, "currency_add"):
		assert_eq([add_back.get_currency(), add_back.get_currency_amount()], [1, -50], "sus datos")
	assert_eq(NetMessages.DebugCommand.currency_add(2, 1 << 40).get_currency_amount(), 0x7FFFFFFF,
			"se satura a s32")
	var level := NetMessages.DebugCommand.level_set(40)
	assert_eq(level.encode(), PackedByteArray([0x04, 42, 40]), "level_set: u8")
	assert_eq(NetMessages.DebugCommand.decode(level.encode()).get_level(), 40, "su nivel")
	var xp := NetMessages.DebugCommand.xp_add(10_000_000)
	assert_eq(xp.encode().size(), 6, "xp_add: u32")
	assert_eq(NetMessages.DebugCommand.decode(xp.encode()).get_xp_amount(), 10_000_000, "su XP")
	# Los getters de otro comando dan 0.
	assert_eq([level.get_item_count(), give.get_level(), xp.get_currency(), add.get_xp_amount()], [0, 0, 0, 0],
			"los datos de otro comando, 0")
	# Lo que el decode no admite.
	var invalid: Array[PackedByteArray] = [
		NetMessages.DebugCommand.item_give(0, 5).encode(), NetMessages.DebugCommand.item_give(3, 0).encode(),
		NetMessages.DebugCommand.item_give(3, 1000).encode(), PackedByteArray([0x04, 40, 3, 0, 1]),
		NetMessages.DebugCommand.currency_add(0, 5).encode(), NetMessages.DebugCommand.currency_add(3, 5).encode(),
		NetMessages.DebugCommand.currency_add(1, 0).encode(), PackedByteArray([0x04, 41, 1, 5, 0, 0]),
		NetMessages.DebugCommand.level_set(0).encode(), NetMessages.DebugCommand.level_set(41).encode(),
		PackedByteArray([0x04, 42]), NetMessages.DebugCommand.xp_add(0).encode(),
		NetMessages.DebugCommand.xp_add(10_000_001).encode(), PackedByteArray([0x04, 43, 1, 0, 0]),
	]
	for bytes: PackedByteArray in invalid:
		assert_null(NetMessages.DebugCommand.decode(bytes), "DEBUG_COMMAND %s" % bytes)
	for bytes: PackedByteArray in [NetMessages.DebugCommand.item_give(1, 1).encode(),
			NetMessages.DebugCommand.currency_add(2, -2147483648).encode(),
			NetMessages.DebugCommand.level_set(1).encode(), NetMessages.DebugCommand.xp_add(1).encode()]:
		assert_not_null(NetMessages.DebugCommand.decode(bytes), "los extremos valen: %s" % bytes)


# --- Tamaños, malformaciones y fuzz -----------------------------------------------------------

func test_no_message_passes_the_packet_limit() -> void:
	var longest_name := NetMessages.EntitySpawn.new()
	longest_name.state = PlayerState.new()
	longest_name.display_name = "ñ".repeat(24)
	longest_name.level = 40
	longest_name.appearance = APPEARANCE
	var sizes: Dictionary[String, int] = {
		"INVENTORY_REQUEST": ProgressMessages.InventoryRequest.SIZE,
		"INVENTORY_DELTA": ProgressMessages.InventoryDelta.MAX_SIZE,
		"INVENTORY_FULL": ProgressMessages.InventoryFull.MAX_SIZE,
		"INVENTORY_SYNC_REQUEST": ProgressMessages.InventorySyncRequest.SIZE,
		"WALLET_UPDATE": ProgressMessages.WalletUpdate.SIZE,
		"PROGRESS_UPDATE": ProgressMessages.ProgressUpdate.SIZE,
		"ENTITY_SPAWN de PLAYER": longest_name.encode().size(),
		"LEVEL_UP": NetMessages.EntityEvent.level_up(1, 1, 2).encode().size(),
	}
	for label: String in sizes:
		assert_true(sizes[label] > 0 and sizes[label] <= NetProtocol.MAX_PACKET_BYTES,
				"%s: %d B ≤ 1200" % [label, sizes[label]])
	assert_eq(sizes["ENTITY_SPAWN de PLAYER"], 10 + PlayerState.ENCODED_SIZE + 1 + 48 + 9, "el SPAWN más largo")


func test_malformed_messages_return_null() -> void:
	var samples: Array = _samples()
	for entry: Array in samples:
		var label: String = entry[0]
		var bytes: PackedByteArray = entry[1]
		var decoder: Callable = entry[2]
		assert_not_null(decoder.call(bytes), "%s: el mensaje válido se decodifica" % label)
		for length: int in bytes.size():
			if decoder.call(bytes.slice(0, length)) != null:
				fail("%s truncado a %d de %d B debería ser null" % [label, length, bytes.size()])
				break
		for extra: int in [1, 2, 20]:
			var longer: PackedByteArray = bytes.duplicate()
			longer.resize(bytes.size() + extra)
			if decoder.call(longer) != null:
				fail("%s con %d B de sobra debería ser null" % [label, extra])
		var wrong: PackedByteArray = bytes.duplicate()
		wrong[0] = 0x7F
		assert_null(decoder.call(wrong), "%s con el byte 0 cambiado" % label)
		for other: Array in samples:
			if other[2] != decoder and decoder.call(other[1]) != null:
				fail("%s decodificó bytes de %s" % [label, other[0]])
		assert_null(decoder.call(PackedByteArray()), "%s: búfer vacío" % label)
	# Los decodificadores de NetMessages no aceptan los mensajes nuevos.
	for decoder: Callable in _net_decoders():
		for entry: Array in samples:
			if decoder.call(entry[1]) != null:
				fail("un decodificador de NetMessages aceptó %s" % entry[0])


func test_fuzz_random_buffers_never_error() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = FUZZ_SEED
	var samples: Array = _samples()
	var decoders: Array[Callable] = _progress_decoders()
	decoders.append_array(_net_decoders())
	decoders.append_array([NetMessages.EntitySpawn.decode, NetMessages.EntityEvent.decode,
			NetMessages.DebugCommand.decode] as Array[Callable])
	var mutated_decoded: int = 0
	for i: int in FUZZ_BUFFERS:
		var bytes := PackedByteArray()
		if i % 2 == 0:
			var length: int = rng.randi_range(1, 140) if rng.randf() < 0.8 else rng.randi_range(0, 1300)
			bytes.resize(length)
			for j: int in length:
				bytes[j] = rng.randi() & 0xFF
			if length > 0:
				bytes[0] = rng.randi_range(0x50, 0x55) if rng.randf() < 0.7 else NetProtocol.MSG_ENTITY_SPAWN
		else:
			bytes = (samples[rng.randi() % samples.size()][1] as PackedByteArray).duplicate()
			for _k: int in rng.randi_range(0, 3):
				bytes[rng.randi() % bytes.size()] = rng.randi() & 0xFF
			if rng.randf() < 0.2:
				bytes.resize(rng.randi_range(0, bytes.size()))
		for decoder: Callable in decoders:
			if decoder.call(bytes) != null and i % 2 == 1:
				mutated_decoded += 1
	assert_true(mutated_decoded > 100, "el fuzz llega a mensajes válidos (%d)" % mutated_decoded)


# --- sim_hash ---------------------------------------------------------------------------------

func test_sim_hash_covers_the_item_database() -> void:
	var world := Node3D.new()
	tree.root.add_child(world)
	_nodes.append(world)
	var character: PlayerCharacter = (load(CHARACTER_SCENE_PATH) as PackedScene).instantiate() as PlayerCharacter
	world.add_child(character)
	await wait_physics_frames(2)
	var shared: ItemDatabase = ItemDatabase.shared()
	var before: int = NetProtocol.compute_sim_hash(character)
	assert_true(_db.wire_hash() != shared.wire_hash(), "la base de la prueba tiene otra huella (las armaduras)")
	ItemDatabase._shared = _db
	var with_armor: int = NetProtocol.compute_sim_hash(character)
	ItemDatabase._shared = shared
	assert_true(with_armor != before, "otra base de objetos da otro sim_hash")
	assert_eq(NetProtocol.compute_sim_hash(character), before, "y con la de siempre, el mismo")
	assert_eq(NetProtocol.result_text(NetProtocol.Result.SIM_HASH),
			"Los datos del juego no coinciden con los del servidor: actualiza el cliente", "el texto del REJECT")


# --- Servidor: las tres llamadas a encode_spawn ----------------------------------------------

## Dos de Vardheim y uno de Solmarch en el mundo con peer (montados a mano) y un recién llegado de cada reino:
## cada receptor recibe el SPAWN del recién llegado con el nivel solo si es de su reino, el recién llegado los de
## los demás con su reino y [method ZoneServer._refresh_interest] usa el del observador.
func test_zone_server_sends_each_receiver_the_spawn_of_its_realm() -> void:
	_rig = NpcRig.new()
	await _rig.start_flat(tree)
	var server: ZoneServer = _rig.server
	server.interest_policy = SeeAllPolicy.new()
	var recorder := RecordingTransport.new()
	_nodes.append(recorder)
	var ana: NetEntity = _player_with_peer(501, VARDHEIM, 7)
	var bo: NetEntity = _player_with_peer(502, VARDHEIM, 9)
	var cai: NetEntity = _player_with_peer(503, SOLMARCH, 12)
	var dag: NetEntity = _player_with_peer(504, VARDHEIM, 5)
	server._peers.erase(504)
	var s: int = server.get_tick()
	server._transport = recorder
	# Llega Dag (Vardheim): Ana y Bo lo ven con su nivel; Cai, con 0.
	server._announce_arrival(dag, _peer_of(dag, 504), s)
	server._transport = null
	var own: Array[NetMessages.EntitySpawn] = recorder.spawns_to(504)
	if assert_true(not own.is_empty(), "Dag recibe SPAWN"):
		assert_true(own[0].is_yours and own[0].net_id == dag.net_id and own[0].level == 5,
				"el primero, el propio con su nivel")
		assert_eq(_levels_by_net(own.slice(1)), {ana.net_id: 7, bo.net_id: 9, cai.net_id: 0},
				"los de los demás con el reino de Dag: Cai (Solmarch) sin nivel")
	for peer_id: int in [501, 502, 503]:
		var got: Array[NetMessages.EntitySpawn] = recorder.spawns_to(peer_id)
		if assert_eq(got.size(), 1, "el peer %d solo recibe el SPAWN de Dag" % peer_id):
			assert_eq(got[0].net_id, dag.net_id, "es Dag")
			assert_eq(got[0].level, 0 if peer_id == 503 else 5, "nivel para el peer %d" % peer_id)
			assert_eq(got[0].appearance, APPEARANCE, "la apariencia, para todos")
	# Cai vuelve a mirar (interés): los de Vardheim, sin nivel; y Ana ve el de Cai sin él y el de Bo con él.
	recorder.sent.clear()
	var cai_peer: ServerPeer = server._peers[503]
	cai_peer.relevant.clear()
	server._transport = recorder
	server._refresh_interest(cai_peer, server.get_registry().get_sorted(), s)
	var ana_peer: ServerPeer = server._peers[501]
	ana_peer.relevant.clear()
	server._refresh_interest(ana_peer, server.get_registry().get_sorted(), s)
	server._transport = null
	assert_eq(_levels_by_net(recorder.spawns_to(503)), {ana.net_id: 0, bo.net_id: 0, dag.net_id: 0},
			"Cai no ve ningún nivel de Vardheim")
	assert_eq(_levels_by_net(recorder.spawns_to(501)), {bo.net_id: 9, cai.net_id: 0, dag.net_id: 5},
			"Ana ve los de su reino")
	for peer_id: int in [501, 502, 503]:
		server._peers.erase(peer_id)


# --- Cliente y bot ----------------------------------------------------------------------------

func test_net_client_emits_the_progress_signals_and_counts_the_malformed() -> void:
	var client := NetClient.new()
	tree.root.add_child(client)
	_nodes.append(client)
	client._net_id = 5
	client._state = NetClient.State.IN_WORLD
	var received: Array = []
	client.inventory_delta_received.connect(func(delta: ProgressMessages.InventoryDelta) -> void:
		received.append(delta))
	client.inventory_full_received.connect(func(page: ProgressMessages.InventoryFull) -> void:
		received.append(page))
	client.wallet_updated.connect(func(update: ProgressMessages.WalletUpdate) -> void: received.append(update))
	client.progress_updated.connect(func(update: ProgressMessages.ProgressUpdate) -> void:
		received.append(update))
	var own_events: Array[NetMessages.EntityEvent] = []
	client.combat_event.connect(func(event: NetMessages.EntityEvent, is_own: bool) -> void:
		if is_own:
			own_events.append(event))
	for bytes: PackedByteArray in _server_samples():
		client._on_packet_received(NetClient.SERVER_PEER_ID, bytes)
	client._on_packet_received(NetClient.SERVER_PEER_ID, NetMessages.EntityEvent.level_up(5, 10, 2).encode())
	client._on_packet_received(NetClient.SERVER_PEER_ID, NetMessages.EntityEvent.level_up(6, 10, 3).encode())
	var stats: Dictionary = client.get_stats()
	assert_eq(stats["malformed_packets"], 0, "nada bien formado cuenta como malformado")
	assert_eq(received.size(), 4, "una señal por mensaje")
	assert_true(received[0] is ProgressMessages.InventoryDelta and received[1] is ProgressMessages.InventoryFull \
			and received[2] is ProgressMessages.WalletUpdate and received[3] is ProgressMessages.ProgressUpdate,
			"cada uno por la suya")
	assert_eq([stats["inventory_deltas"], stats["inventory_fulls"], stats["wallet_updates"],
			stats["progress_updates"]], [1, 1, 1, 1], "contados")
	assert_eq(own_events.size(), 1, "el LEVEL_UP propio llega al momento")
	assert_eq(stats["combat_events_pending"], 1, "el de un aliado espera a su tick de dibujo")
	# Rotos: cuentan y no salen. Los C→S tampoco valen de vuelta.
	var broken: Array[PackedByteArray] = []
	for bytes: PackedByteArray in _server_samples():
		broken.append(bytes.slice(0, bytes.size() - 1))
	broken.append(ProgressMessages.InventorySyncRequest.new().encode())
	broken.append(_request_sample())
	for bytes: PackedByteArray in broken:
		client._on_packet_received(NetClient.SERVER_PEER_ID, bytes)
	assert_eq(client.get_stats()["malformed_packets"], broken.size(), "cada uno roto cuenta")
	assert_eq(received.size(), 4, "y no sale")
	# Sin transporte ni sesión no se envía nada.
	client._state = NetClient.State.IDLE
	assert_false(client.send_inventory_request(ProgressMessages.InventoryRequest.decode(_request_sample())),
			"fuera del mundo no se pide nada")
	assert_false(client.send_inventory_sync_request(), "ni la sincronía")


func test_swarm_bot_discards_the_progress_messages() -> void:
	var bot := SwarmBot.new()
	_nodes.append(bot)
	for bytes: PackedByteArray in _server_samples():
		bot._on_packet_received(SwarmBot.SERVER_PEER_ID, bytes)
	bot._on_packet_received(SwarmBot.SERVER_PEER_ID, NetMessages.EntityEvent.level_up(9, 10, 2).encode())
	var stats: Dictionary = bot.get_stats()
	assert_eq(int(stats["malformed_packets"]), 0, "los bien formados no cuentan")
	assert_eq(int(stats.get("progress_messages_seen", -1)), 4, "los cuatro S→C, vistos y descartados")
	assert_eq(int(stats["events_seen"]), 1, "el LEVEL_UP es un evento más")
	var broken: Array[PackedByteArray] = [ProgressMessages.InventorySyncRequest.new().encode(), _request_sample()]
	for bytes: PackedByteArray in _server_samples():
		broken.append(PackedByteArray([bytes[0]]))
	for bytes: PackedByteArray in broken:
		bot._on_packet_received(SwarmBot.SERVER_PEER_ID, bytes)
	stats = bot.get_stats()
	assert_eq(int(stats["malformed_packets"]), broken.size(), "cada uno roto (y los C→S) cuenta")
	assert_eq(int(stats["progress_messages_seen"]), 4, "y no como visto")


# --- Ayudantes --------------------------------------------------------------------------------

func _item(uid: int, def_id: StringName, count: int) -> ItemInstance:
	var definition: ItemDefinition = _db.get_definition(def_id)
	return ItemInstance.create(uid, definition, count)


func _request_sample() -> PackedByteArray:
	return ProgressMessages.InventoryRequest.from_request(9,
			InventoryOps.make_request(InventoryOps.Op.MOVE, 0, 3, 1, 1, 0, 1025)).encode()


## Un ejemplo bien formado de cada mensaje S→C, con la base compartida (la que usan cliente y bot).
func _server_samples() -> Array[PackedByteArray]:
	var potion: ItemInstance = ItemInstance.create(1027, ItemDatabase.shared().get_definition(&"potion_health"), 3)
	var state := InventoryState.new()
	state.set_item(0, 1, potion)
	var delta := ProgressMessages.InventoryDelta.for_slots(2, 9, InventoryOps.Result.OK, 0, state,
			[Vector2i(0, 1), Vector2i(0, 3)] as Array[Vector2i])
	return [
		delta.encode(),
		ProgressMessages.InventoryFull.split(2, state)[0].encode(),
		ProgressMessages.WalletUpdate.make(Currency.Code.GOLD, 152, 50, EconomyReason.GM_GRANT).encode(),
		ProgressMessages.ProgressUpdate.make(LevelCurve.shared(), 3, 1200, 40, ProgressMessages.XpSource.NPC,
				20).encode(),
	]


## [etiqueta, bytes válidos, decodificador] de cada mensaje nuevo (con la base compartida).
func _samples() -> Array:
	var server: Array[PackedByteArray] = _server_samples()
	var spawn := NetMessages.EntitySpawn.new()
	spawn.state = PlayerState.new()
	spawn.display_name = "Aneira"
	spawn.level = 3
	spawn.appearance = APPEARANCE
	return [
		["INVENTORY_REQUEST", _request_sample(), ProgressMessages.InventoryRequest.decode],
		["INVENTORY_DELTA", server[0], ProgressMessages.InventoryDelta.decode],
		["INVENTORY_FULL", server[1], ProgressMessages.InventoryFull.decode],
		["INVENTORY_SYNC_REQUEST", ProgressMessages.InventorySyncRequest.new().encode(),
				ProgressMessages.InventorySyncRequest.decode],
		["WALLET_UPDATE", server[2], ProgressMessages.WalletUpdate.decode],
		["PROGRESS_UPDATE", server[3], ProgressMessages.ProgressUpdate.decode],
		["ENTITY_SPAWN PLAYER v7", spawn.encode(), NetMessages.EntitySpawn.decode],
		["ENTITY_EVENT LEVEL_UP", NetMessages.EntityEvent.level_up(4, 5, 6).encode(), NetMessages.EntityEvent.decode],
		["DEBUG_COMMAND item_give", NetMessages.DebugCommand.item_give(2, 10).encode(), NetMessages.DebugCommand.decode],
		["DEBUG_COMMAND currency_add", NetMessages.DebugCommand.currency_add(1, 50).encode(),
				NetMessages.DebugCommand.decode],
	]


func _progress_decoders() -> Array[Callable]:
	var result: Array[Callable] = [
		ProgressMessages.InventoryRequest.decode, ProgressMessages.InventoryDelta.decode,
		ProgressMessages.InventoryFull.decode, ProgressMessages.InventorySyncRequest.decode,
		ProgressMessages.WalletUpdate.decode, ProgressMessages.ProgressUpdate.decode,
	]
	return result


## Los decodificadores de [NetMessages] que no son de los mensajes de las muestras (el SPAWN, el evento y el
## DEBUG_COMMAND tienen los suyos en ellas).
func _net_decoders() -> Array[Callable]:
	var result: Array[Callable] = [
		NetMessages.Hello.decode, NetMessages.Welcome.decode, NetMessages.Reject.decode,
		NetMessages.InputBatch.decode, NetMessages.ClientReady.decode, NetMessages.ClientLeave.decode,
		NetMessages.Snapshot.decode, NetMessages.EntityDespawn.decode, NetMessages.Notice.decode,
		NetMessages.RespawnRequest.decode, NetMessages.LoadoutSelect.decode, NetMessages.ChatSend.decode,
		NetMessages.ChatMessage.decode, NetMessages.ObjectState.decode, NetMessages.Scoreboard.decode,
	]
	return result


## Un jugador falso de [param realm] con nivel [param level], la apariencia de ejemplo y un peer en el mundo
## montado a mano con el id [param peer_id].
func _player_with_peer(peer_id: int, realm: int, level: int) -> NetEntity:
	var net_id: int = _rig.add_player(realm, Vector3(peer_id - 500, 0.0, 0.0))
	var entity: NetEntity = _rig.entity(net_id)
	entity.level = level
	entity.appearance = APPEARANCE
	entity.owner_peer = peer_id
	var peer := ServerPeer.new(peer_id)
	peer.state = ServerPeer.State.IN_WORLD
	peer.realm = realm
	peer.entity = entity
	_rig.server._peers[peer_id] = peer
	return entity


func _peer_of(entity: NetEntity, peer_id: int) -> ServerPeer:
	var peer := ServerPeer.new(peer_id)
	peer.state = ServerPeer.State.IN_WORLD
	peer.realm = entity.realm
	peer.entity = entity
	return peer


## net_id -> nivel de los SPAWN de jugador de [param spawns].
func _levels_by_net(spawns: Array) -> Dictionary:
	var levels: Dictionary = {}
	for spawn: NetMessages.EntitySpawn in spawns:
		if spawn != null and spawn.kind == NetProtocol.EntityKind.PLAYER:
			levels[spawn.net_id] = spawn.level
	return levels
