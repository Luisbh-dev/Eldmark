class_name ProgressMessages
extends RefCounted
## Mensajes del inventario y del progreso (protocolo 7; docs/progresion.md §4.6 y §12), aparte de
## [NetMessages] para no chocar con otros carriles. Todos van por el canal fiable 3; los S→C solo al dueño.
## [br][br]
## [codeblock]
## 0x50 INVENTORY_REQUEST       C→S  18 B    mover, dividir o destruir
## 0x51 INVENTORY_DELTA         S→C  ≤ 1120  ranuras que cambian (respuesta o cambio del servidor)
## 0x52 INVENTORY_FULL          S→C  ≤ 1089  el inventario entero, por páginas
## 0x53 INVENTORY_SYNC_REQUEST  C→S  1 B     pide un INVENTORY_FULL
## 0x54 WALLET_UPDATE           S→C  19 B    el saldo de una moneda
## 0x55 PROGRESS_UPDATE         S→C  25 B    nivel, XP, puntos de reino y de atributo
## [/codeblock]
## Como en [NetMessages], cada clase tiene [code]encode()[/code] y [code]static decode(bytes)[/code], que
## devuelve null si el mensaje está malformado (tamaño exacto según los contadores, rangos y cada objeto según
## [method ItemInstance.decode]) y nunca registra errores del motor. Un [code]encode()[/code] que no se podría
## decodificar (campos fuera de rango, demasiadas entradas, un objeto que no vale) devuelve un array vacío: es
## un fallo de quien construye el mensaje. Los que llevan objetos usan el net id de una [ItemDatabase] (null =
## [method ItemDatabase.shared]). Little endian, como el resto del protocolo. Compartido: sin reloj ni azar.

## Nivel máximo que admite el protocolo (el tope de [LevelCurve], docs/progresion.md §6.1; lo comprueba la prueba).
const MAX_LEVEL: int = 40
## Entradas como mucho de un INVENTORY_DELTA o de una página de INVENTORY_FULL.
const MAX_ENTRIES: int = 30
## Páginas como mucho de un INVENTORY_FULL (con 120 ranuras de bolsa y 7 de equipo bastan 5).
const MAX_PAGES: int = 8
## Contenedor y ranura de destino de un DESTROY en el cable.
const NO_SLOT: int = InventoryOps.NO_SLOT
## Contenedor más alto que admite el cable (0 bolsa, 1 equipo, 2 banco y 3 reservado; el servidor rechaza el 2 y
## el 3 en la fase 5).
const MAX_CONTAINER: int = 3

## Fuente de lo ganado en un PROGRESS_UPDATE: 0 es el estado (al entrar o tras un comando que no suma XP).
enum XpSource { STATE = 0, PVP = 1, NPC = 2, CAPTURE = 3, GM = 4 }


## Una ranura de un INVENTORY_DELTA o de un INVENTORY_FULL: su contenido ([member item]; null = vacía, solo en
## un delta).
class Entry:
	var container: int = 0
	var slot: int = 0
	var item: ItemInstance = null


	static func make(entry_container: int, entry_slot: int, entry_item: ItemInstance) -> Entry:
		var entry := Entry.new()
		entry.container = entry_container
		entry.slot = entry_slot
		entry.item = entry_item
		return entry


	## true si [param other] es la misma ranura con el mismo contenido.
	func equals(other: Entry) -> bool:
		if other == null or other.container != container or other.slot != slot:
			return false
		if item == null or other.item == null:
			return item == null and other.item == null
		return item.equals(other.item)


## INVENTORY_REQUEST (C→S, 18 B): [code]u8 type, u16 request_id, u8 op, u8 from_container, u8 from_slot, u8
## to_container, u8 to_slot, u16 count, u64 expected_uid[/code]. [member request_id] va de 1 a 65535 (el cliente lo
## sube en cada petición y salta el 0); [member op], de 1 a 3 ([enum InventoryOps.Op]); los contenedores, de 0 a
## 3, salvo el destino de un DESTROY, que es [constant NO_SLOT] en contenedor y ranura. MOVE lleva
## [member count] 0; SPLIT, las que salen; DESTROY, las que se destruyen (0 = toda la pila). [method decode] no
## mira las reglas del inventario (eso es [method InventoryOps.apply]): solo el formato.
class InventoryRequest:
	const SIZE: int = 18

	var request_id: int = 0
	var op: int = 0
	var from_container: int = 0
	var from_slot: int = 0
	var to_container: int = 0
	var to_slot: int = 0
	var count: int = 0
	var expected_uid: int = 0


	## La petición [param request] con el id [param id]. En DESTROY el destino pasa a [constant NO_SLOT].
	static func from_request(id: int, request: InventoryOps.Request) -> InventoryRequest:
		var message := InventoryRequest.new()
		message.request_id = id
		message.op = request.op
		message.from_container = request.from_container
		message.from_slot = request.from_slot
		message.to_container = request.to_container
		message.to_slot = request.to_slot
		message.count = request.count
		message.expected_uid = request.expected_uid
		if request.op == InventoryOps.Op.DESTROY:
			message.to_container = NO_SLOT
			message.to_slot = NO_SLOT
		return message


	## La [InventoryOps.Request] que lleva (sin el [member request_id]).
	func to_request() -> InventoryOps.Request:
		return InventoryOps.make_request(op, from_container, from_slot, to_container, to_slot, count,
				expected_uid)


	## Vacío si algún campo no cabe o no lo admitiría [method decode].
	func encode() -> PackedByteArray:
		if not _fields_valid(request_id, op, from_container, from_slot, to_container, to_slot, count):
			return PackedByteArray()
		var bytes := PackedByteArray()
		bytes.resize(SIZE)
		bytes[0] = NetProtocol.MSG_INVENTORY_REQUEST
		bytes.encode_u16(1, request_id)
		bytes[3] = op
		bytes[4] = from_container
		bytes[5] = from_slot
		bytes[6] = to_container
		bytes[7] = to_slot
		bytes.encode_u16(8, count)
		bytes.encode_u64(10, expected_uid)
		return bytes


	## null si no son 18 B del tipo 0x50, el [member request_id] es 0, la operación no es 1, 2 o 3, un
	## contenedor pasa de 3 o el destino de un DESTROY no es [constant NO_SLOT] (o el de otra operación lo es).
	static func decode(bytes: PackedByteArray) -> InventoryRequest:
		if bytes.size() != SIZE or bytes[0] != NetProtocol.MSG_INVENTORY_REQUEST:
			return null
		var message := InventoryRequest.new()
		message.request_id = bytes.decode_u16(1)
		message.op = bytes[3]
		message.from_container = bytes[4]
		message.from_slot = bytes[5]
		message.to_container = bytes[6]
		message.to_slot = bytes[7]
		message.count = bytes.decode_u16(8)
		message.expected_uid = bytes.decode_u64(10)
		if not _fields_valid(message.request_id, message.op, message.from_container, message.from_slot,
				message.to_container, message.to_slot, message.count):
			return null
		return message


	static func _fields_valid(id: int, operation: int, source_container: int, source_slot: int,
			target_container: int, target_slot: int, amount: int) -> bool:
		if id < 1 or id > 0xFFFF or operation < InventoryOps.Op.MOVE or operation > InventoryOps.Op.DESTROY:
			return false
		if source_container < 0 or source_container > MAX_CONTAINER or source_slot < 0 or source_slot > 0xFF:
			return false
		if amount < 0 or amount > 0xFFFF:
			return false
		if operation == InventoryOps.Op.DESTROY:
			return target_container == NO_SLOT and target_slot == NO_SLOT
		return target_container >= 0 and target_container <= MAX_CONTAINER and target_slot >= 0 \
				and target_slot < NO_SLOT


## INVENTORY_DELTA (S→C, 10 B + entradas, ≤ [constant MAX_SIZE] B): [code]u8 type, u32 revision, u16 request_id,
## u8 result, u8 reason, u8 entry_count[/code] y, por entrada, [code]u8 container, u8 slot, u8 present[/code] (0
## vacía, 1 con objeto) y, si [code]present[/code], [method ItemInstance.encode]. Responde a una petición
## ([member request_id] ≠ 0, [member reason] 0 y [member result] uno de [enum InventoryOps.Result]: con un
## rechazo, las entradas traen el contenido real de las ranuras que tocaba la petición y la revisión no sube) o
## da un cambio que decide el servidor ([member request_id] 0, [member result] OK y [member reason] el motivo de
## [EconomyReason]). La revisión sube 1 con cada cambio aplicado (docs/progresion.md §4.6).
class InventoryDelta:
	const HEADER_SIZE: int = 10
	## 10 + 30 × (3 + 34).
	const MAX_SIZE: int = HEADER_SIZE + MAX_ENTRIES * (3 + ItemInstance.HEADER_SIZE + 2 * ItemInstance.MAX_AFFIXES)

	## u32: la revisión del inventario tras aplicar.
	var revision: int = 0
	## 0 = cambio que decide el servidor.
	var request_id: int = 0
	## [enum InventoryOps.Result].
	var result: int = InventoryOps.Result.OK
	## Motivo ([EconomyReason]) de un cambio del servidor; 0 en las respuestas.
	var reason: int = 0
	var entries: Array[Entry] = []


	## Un delta con el contenido actual de [param slots] (pares contenedor, ranura) de [param state]: lo que
	## cambió con una petición aplicada ([member InventoryOps.Outcome.changed]) o lo que tocaba una rechazada.
	static func for_slots(delta_revision: int, id: int, delta_result: int, delta_reason: int,
			state: InventoryState, slots: Array[Vector2i]) -> InventoryDelta:
		var delta := InventoryDelta.new()
		delta.revision = delta_revision
		delta.request_id = id
		delta.result = delta_result
		delta.reason = delta_reason
		for position: Vector2i in slots:
			delta.entries.append(Entry.make(position.x, position.y, state.get_item(position.x, position.y)))
		return delta


	## Vacío si hay más de [constant MAX_ENTRIES] entradas, algún campo no lo admitiría [method decode] o un objeto
	## no se puede codificar ([method ItemInstance.encode] vacío).
	func encode(db: ItemDatabase = null) -> PackedByteArray:
		if not _header_valid(revision, request_id, result, reason) or entries.size() > MAX_ENTRIES:
			return PackedByteArray()
		if db == null:
			db = ItemDatabase.shared()
		var bytes := PackedByteArray()
		bytes.resize(HEADER_SIZE)
		bytes[0] = NetProtocol.MSG_INVENTORY_DELTA
		bytes.encode_u32(1, revision)
		bytes.encode_u16(5, request_id)
		bytes[7] = result
		bytes[8] = reason
		bytes[9] = entries.size()
		var seen: Dictionary[int, bool] = {}
		for entry: Entry in entries:
			if entry == null or not ProgressMessages.slot_in_range(entry.container, entry.slot, InventoryState.BAG_SLOTS_MAX):
				return PackedByteArray()
			var key: int = entry.container * 256 + entry.slot
			if seen.has(key):
				return PackedByteArray()
			seen[key] = true
			bytes.append(entry.container)
			bytes.append(entry.slot)
			if entry.item == null:
				bytes.append(0)
				continue
			var item_bytes: PackedByteArray = entry.item.encode(db)
			if item_bytes.is_empty():
				return PackedByteArray()
			bytes.append(1)
			bytes.append_array(item_bytes)
		return bytes


	## null si el tipo no es 0x51, el tamaño no cuadra con las entradas, hay más de 30, un [code]present[/code] no
	## es 0 ni 1, una ranura se repite o no existe (contenedor de 0 a 3; ranura del equipo de 0 a 6 y de los
	## demás, de 0 a 119), un objeto no pasa [method ItemInstance.decode], [member result] no es de
	## [enum InventoryOps.Result], una respuesta trae motivo o un cambio del servidor trae un resultado que no es
	## OK o un motivo desconocido.
	static func decode(bytes: PackedByteArray, db: ItemDatabase = null) -> InventoryDelta:
		var size: int = bytes.size()
		if size < HEADER_SIZE or size > MAX_SIZE or bytes[0] != NetProtocol.MSG_INVENTORY_DELTA:
			return null
		var delta := InventoryDelta.new()
		delta.revision = bytes.decode_u32(1)
		delta.request_id = bytes.decode_u16(5)
		delta.result = bytes[7]
		delta.reason = bytes[8]
		var count: int = bytes[9]
		if count > MAX_ENTRIES or not _header_valid(delta.revision, delta.request_id, delta.result, delta.reason):
			return null
		if db == null:
			db = ItemDatabase.shared()
		var offset: int = HEADER_SIZE
		var seen: Dictionary[int, bool] = {}
		for _i: int in count:
			if offset + 3 > size:
				return null
			var container: int = bytes[offset]
			var slot: int = bytes[offset + 1]
			var present: int = bytes[offset + 2]
			offset += 3
			var key: int = container * 256 + slot
			if present > 1 or seen.has(key) \
					or not ProgressMessages.slot_in_range(container, slot, InventoryState.BAG_SLOTS_MAX):
				return null
			seen[key] = true
			var item: ItemInstance = null
			if present == 1:
				var item_size: int = ItemInstance.encoded_size_at(bytes, offset)
				if item_size < 0:
					return null
				item = ItemInstance.decode(bytes, offset, db)
				if item == null:
					return null
				offset += item_size
			delta.entries.append(Entry.make(container, slot, item))
		if offset != size:
			return null
		return delta


	static func _header_valid(delta_revision: int, id: int, delta_result: int, delta_reason: int) -> bool:
		if delta_revision < 0 or delta_revision > 0xFFFFFFFF or id < 0 or id > 0xFFFF:
			return false
		if delta_result < InventoryOps.Result.OK or delta_result > InventoryOps.Result.RATE:
			return false
		if id != 0:
			return delta_reason == 0
		return delta_result == InventoryOps.Result.OK and EconomyReason.is_known(delta_reason)


## INVENTORY_FULL (S→C, ≤ [constant MAX_SIZE] B): [code]u8 type, u32 revision, u8 bag_slots, u8 page_index, u8
## page_count, u8 entry_count[/code] y, solo de las ranuras ocupadas, [code]u8 container, u8 slot[/code] y
## [method ItemInstance.encode]. Va al entrar en el mundo (tras el SPAWN propio), tras el kit de inicio y como
## respuesta a un INVENTORY_SYNC_REQUEST. El cliente junta las páginas de una misma revisión ([method assemble]) y
## solo entonces sustituye su estado.
class InventoryFull:
	const HEADER_SIZE: int = 9
	## 9 + 30 × (2 + 34).
	const MAX_SIZE: int = HEADER_SIZE + MAX_ENTRIES * (2 + ItemInstance.HEADER_SIZE + 2 * ItemInstance.MAX_AFFIXES)

	var revision: int = 0
	## Ranuras de la bolsa (1 a [constant InventoryState.BAG_SLOTS_MAX]).
	var bag_slots: int = InventoryState.BAG_SLOTS_DEFAULT
	var page_index: int = 0
	var page_count: int = 1
	## Solo ranuras ocupadas: [member Entry.item] nunca es null.
	var entries: Array[Entry] = []


	## Las páginas de [param state] con la revisión [param full_revision]: sus ranuras ocupadas en el orden de
	## [method InventoryState.occupied_slots], [constant MAX_ENTRIES] por página, y al menos una (vacía si no hay
	## nada). Un estado que no cabe en [constant MAX_PAGES] páginas da una lista vacía.
	static func split(full_revision: int, state: InventoryState) -> Array[InventoryFull]:
		var pages: Array[InventoryFull] = []
		var slots: Array[Vector2i] = state.occupied_slots()
		var count: int = maxi(ceili(slots.size() / float(MAX_ENTRIES)), 1)
		if count > MAX_PAGES:
			return pages
		for index: int in count:
			var page := InventoryFull.new()
			page.revision = full_revision
			page.bag_slots = state.bag_slots
			page.page_index = index
			page.page_count = count
			for position: Vector2i in slots.slice(index * MAX_ENTRIES, (index + 1) * MAX_ENTRIES):
				page.entries.append(Entry.make(position.x, position.y, state.get_item(position.x, position.y)))
			pages.append(page)
		return pages


	## El inventario que forman [param pages] (las de una misma revisión, en cualquier orden), o null si faltan o
	## sobran páginas, no coinciden en revisión, ranuras o número de páginas, una ranura se repite o un objeto
	## está en un contenedor que no existe en la fase 5.
	static func assemble(pages: Array[InventoryFull]) -> InventoryState:
		if pages.is_empty() or pages[0] == null:
			return null
		var first: InventoryFull = pages[0]
		if pages.size() != first.page_count:
			return null
		var state := InventoryState.new(first.bag_slots)
		var seen_pages: Dictionary[int, bool] = {}
		for page: InventoryFull in pages:
			if page == null or page.revision != first.revision or page.bag_slots != first.bag_slots \
					or page.page_count != first.page_count or seen_pages.has(page.page_index):
				return null
			seen_pages[page.page_index] = true
			for entry: Entry in page.entries:
				if entry.item == null or not state.has_slot(entry.container, entry.slot) \
						or state.get_item(entry.container, entry.slot) != null:
					return null
				state.set_item(entry.container, entry.slot, entry.item)
		return state


	## Vacío si algún campo no lo admitiría [method decode], hay más de [constant MAX_ENTRIES] entradas o una
	## vacía, o un objeto no se puede codificar.
	func encode(db: ItemDatabase = null) -> PackedByteArray:
		if not _header_valid(revision, bag_slots, page_index, page_count) or entries.size() > MAX_ENTRIES:
			return PackedByteArray()
		if db == null:
			db = ItemDatabase.shared()
		var bytes := PackedByteArray()
		bytes.resize(HEADER_SIZE)
		bytes[0] = NetProtocol.MSG_INVENTORY_FULL
		bytes.encode_u32(1, revision)
		bytes[5] = bag_slots
		bytes[6] = page_index
		bytes[7] = page_count
		bytes[8] = entries.size()
		var seen: Dictionary[int, bool] = {}
		for entry: Entry in entries:
			if entry == null or entry.item == null \
					or not ProgressMessages.slot_in_range(entry.container, entry.slot, bag_slots):
				return PackedByteArray()
			var key: int = entry.container * 256 + entry.slot
			if seen.has(key):
				return PackedByteArray()
			seen[key] = true
			var item_bytes: PackedByteArray = entry.item.encode(db)
			if item_bytes.is_empty():
				return PackedByteArray()
			bytes.append(entry.container)
			bytes.append(entry.slot)
			bytes.append_array(item_bytes)
		return bytes


	## null si el tipo no es 0x52, el tamaño no cuadra con las entradas, hay más de 30, [member bag_slots] no está
	## entre 1 y 120, [member page_count] no está entre 1 y 8 o [member page_index] no es menor, una ranura se
	## repite o no existe (contenedor de 0 a 3; la bolsa, por debajo de [member bag_slots]; el equipo, de 0 a 6; el
	## resto, de 0 a 119) o un objeto no pasa [method ItemInstance.decode].
	static func decode(bytes: PackedByteArray, db: ItemDatabase = null) -> InventoryFull:
		var size: int = bytes.size()
		if size < HEADER_SIZE or size > MAX_SIZE or bytes[0] != NetProtocol.MSG_INVENTORY_FULL:
			return null
		var page := InventoryFull.new()
		page.revision = bytes.decode_u32(1)
		page.bag_slots = bytes[5]
		page.page_index = bytes[6]
		page.page_count = bytes[7]
		var count: int = bytes[8]
		if count > MAX_ENTRIES or not _header_valid(page.revision, page.bag_slots, page.page_index,
				page.page_count):
			return null
		if db == null:
			db = ItemDatabase.shared()
		var offset: int = HEADER_SIZE
		var seen: Dictionary[int, bool] = {}
		for _i: int in count:
			if offset + 2 > size:
				return null
			var container: int = bytes[offset]
			var slot: int = bytes[offset + 1]
			offset += 2
			var key: int = container * 256 + slot
			if seen.has(key) or not ProgressMessages.slot_in_range(container, slot, page.bag_slots):
				return null
			seen[key] = true
			var item_size: int = ItemInstance.encoded_size_at(bytes, offset)
			if item_size < 0:
				return null
			var item: ItemInstance = ItemInstance.decode(bytes, offset, db)
			if item == null:
				return null
			offset += item_size
			page.entries.append(Entry.make(container, slot, item))
		if offset != size:
			return null
		return page


	static func _header_valid(full_revision: int, slots: int, index: int, total: int) -> bool:
		return full_revision >= 0 and full_revision <= 0xFFFFFFFF and slots >= 1 \
				and slots <= InventoryState.BAG_SLOTS_MAX and total >= 1 and total <= MAX_PAGES and index >= 0 \
				and index < total


## INVENTORY_SYNC_REQUEST (C→S, 1 B): solo el tipo. Pide un INVENTORY_FULL (uno cada 5 s; más, aviso).
class InventorySyncRequest:
	const SIZE: int = 1


	func encode() -> PackedByteArray:
		return PackedByteArray([NetProtocol.MSG_INVENTORY_SYNC_REQUEST])


	static func decode(bytes: PackedByteArray) -> InventorySyncRequest:
		if bytes.size() != SIZE or bytes[0] != NetProtocol.MSG_INVENTORY_SYNC_REQUEST:
			return null
		return InventorySyncRequest.new()


## WALLET_UPDATE (S→C, 19 B): [code]u8 type, u8 currency, u64 balance, s64 delta, u8 reason[/code]. El saldo de
## una moneda ([enum Currency.Code]) tras sumar [member delta] (0 en el estado inicial, al entrar); uno cada 10
## ticks por moneda como mucho, con el delta sumado. [member reason] es el motivo ([EconomyReason]) del último
## cambio, o 0.
class WalletUpdate:
	const SIZE: int = 19

	var currency: int = Currency.Code.GOLD
	var balance: int = 0
	var delta: int = 0
	var reason: int = 0


	static func make(code: int, new_balance: int, change: int, change_reason: int) -> WalletUpdate:
		var update := WalletUpdate.new()
		update.currency = code
		update.balance = new_balance
		update.delta = change
		update.reason = change_reason
		return update


	## Vacío si algún campo no lo admitiría [method decode].
	func encode() -> PackedByteArray:
		if not _fields_valid(currency, balance, delta, reason):
			return PackedByteArray()
		var bytes := PackedByteArray()
		bytes.resize(SIZE)
		bytes[0] = NetProtocol.MSG_WALLET_UPDATE
		bytes[1] = currency
		bytes.encode_u64(2, balance)
		bytes.encode_s64(10, delta)
		bytes[18] = reason
		return bytes


	## null si no son 19 B del tipo 0x54, la moneda no existe, el saldo está fuera de 0 … tope, el delta pasa del
	## tope en valor absoluto o el motivo no es 0 ni uno de [EconomyReason].
	static func decode(bytes: PackedByteArray) -> WalletUpdate:
		if bytes.size() != SIZE or bytes[0] != NetProtocol.MSG_WALLET_UPDATE:
			return null
		var update := WalletUpdate.make(bytes[1], bytes.decode_u64(2), bytes.decode_s64(10), bytes[18])
		if not _fields_valid(update.currency, update.balance, update.delta, update.reason):
			return null
		return update


	static func _fields_valid(code: int, new_balance: int, change: int, change_reason: int) -> bool:
		if not Currency.is_valid(code):
			return false
		var cap: int = Currency.cap_of(code)
		return new_balance >= 0 and new_balance <= cap and change >= -cap and change <= cap \
				and (change_reason == 0 or EconomyReason.is_known(change_reason))


## PROGRESS_UPDATE (S→C, 25 B): [code]u8 type, u8 level, u32 xp_in_level, u32 xp_to_next, u32 gained, u8 source,
## u64 realm_points, u16 attribute_points[/code]. [member xp_in_level] es la XP desde el principio del nivel y
## [member xp_to_next] la que pide el siguiente (0 en el tope, donde [member xp_in_level] también es 0);
## [member gained], lo ganado desde el anterior con la fuente [member source] ([enum XpSource]). Uno cada 10 ticks
## por jugador como mucho, con la suma de lo ganado (docs/progresion.md §6.3).
class ProgressUpdate:
	const SIZE: int = 25

	var level: int = 1
	var xp_in_level: int = 0
	var xp_to_next: int = 0
	var gained: int = 0
	var source: int = XpSource.STATE
	var realm_points: int = 0
	var attribute_points: int = 0


	## El estado de un personaje de nivel [param new_level] con [param xp_total] de XP sobre [param curve]
	## ([method LevelCurve.total_to] y [method LevelCurve.xp_for_next]) y sus puntos de atributo sin gastar
	## ([method ProgressionRules.attribute_points] con [param spent_points] gastados). [param amount] se satura a
	## u32. Con [param new_level] = [method LevelCurve.level_for] de [param xp_total] (I8) la XP del nivel siempre
	## es menor que la del siguiente; si no lo fuera, se recorta para que el mensaje se pueda codificar.
	static func make(curve: LevelCurve, new_level: int, xp_total: int, amount: int, xp_source: int,
			points: int, spent_points: int = 0) -> ProgressUpdate:
		var update := ProgressUpdate.new()
		update.level = new_level
		update.xp_to_next = curve.xp_for_next(new_level)
		update.xp_in_level = mini(maxi(xp_total - curve.total_to(new_level), 0), maxi(update.xp_to_next - 1, 0))
		update.gained = clampi(amount, 0, 0xFFFFFFFF)
		update.source = xp_source
		update.realm_points = points
		update.attribute_points = clampi(ProgressionRules.attribute_points(curve, new_level, spent_points), 0,
				0xFFFF)
		return update


	## Vacío si algún campo no lo admitiría [method decode].
	func encode() -> PackedByteArray:
		if not _fields_valid(level, xp_in_level, xp_to_next, gained, source, realm_points, attribute_points):
			return PackedByteArray()
		var bytes := PackedByteArray()
		bytes.resize(SIZE)
		bytes[0] = NetProtocol.MSG_PROGRESS_UPDATE
		bytes[1] = level
		bytes.encode_u32(2, xp_in_level)
		bytes.encode_u32(6, xp_to_next)
		bytes.encode_u32(10, gained)
		bytes[14] = source
		bytes.encode_u64(15, realm_points)
		bytes.encode_u16(23, attribute_points)
		return bytes


	## null si no son 25 B del tipo 0x55, el nivel no está entre 1 y [constant MAX_LEVEL], la XP del nivel no es
	## menor que la que pide el siguiente (o no es 0 en el tope), la fuente no es de [enum XpSource] o los puntos
	## de reino pasan de 2^63 − 1.
	static func decode(bytes: PackedByteArray) -> ProgressUpdate:
		if bytes.size() != SIZE or bytes[0] != NetProtocol.MSG_PROGRESS_UPDATE:
			return null
		var update := ProgressUpdate.new()
		update.level = bytes[1]
		update.xp_in_level = bytes.decode_u32(2)
		update.xp_to_next = bytes.decode_u32(6)
		update.gained = bytes.decode_u32(10)
		update.source = bytes[14]
		update.realm_points = bytes.decode_u64(15)
		update.attribute_points = bytes.decode_u16(23)
		if not _fields_valid(update.level, update.xp_in_level, update.xp_to_next, update.gained, update.source,
				update.realm_points, update.attribute_points):
			return null
		return update


	static func _fields_valid(new_level: int, in_level: int, to_next: int, amount: int, xp_source: int,
			points: int, attributes: int) -> bool:
		if new_level < 1 or new_level > MAX_LEVEL or xp_source < XpSource.STATE or xp_source > XpSource.GM:
			return false
		if to_next < 0 or to_next > 0xFFFFFFFF or amount < 0 or amount > 0xFFFFFFFF or points < 0:
			return false
		if attributes < 0 or attributes > 0xFFFF or in_level < 0:
			return false
		return in_level < to_next if to_next > 0 else in_level == 0


## true si la ranura [param slot] de [param container] puede viajar: contenedor de 0 a [constant MAX_CONTAINER];
## en la bolsa, por debajo de [param bag_slots]; en el equipo, por debajo de
## [constant InventoryState.EQUIPMENT_SLOTS]; en los demás, por debajo de [constant InventoryState.BAG_SLOTS_MAX].
static func slot_in_range(container: int, slot: int, bag_slots: int) -> bool:
	if slot < 0:
		return false
	match container:
		InventoryState.ContainerId.BAG:
			return slot < mini(bag_slots, InventoryState.BAG_SLOTS_MAX)
		InventoryState.ContainerId.EQUIPMENT:
			return slot < InventoryState.EQUIPMENT_SLOTS
	return container >= 0 and container <= MAX_CONTAINER and slot < InventoryState.BAG_SLOTS_MAX
