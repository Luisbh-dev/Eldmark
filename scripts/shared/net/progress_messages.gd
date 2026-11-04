class_name ProgressMessages
extends RefCounted
## Inventory and progress messages (protocol 7; docs/progression.md §4.6 and §12), separate from
## [NetMessages] to avoid clashing with other lanes. All go over reliable channel 3; the S→C ones
## only to the owner.
## [br][br]
## [codeblock]
## 0x50 INVENTORY_REQUEST       C→S  18 B    move, split or destroy
## 0x51 INVENTORY_DELTA         S→C  ≤ 1120  slots that change (reply or server-side change)
## 0x52 INVENTORY_FULL          S→C  ≤ 1089  the whole inventory, in pages
## 0x53 INVENTORY_SYNC_REQUEST  C→S  1 B     asks for an INVENTORY_FULL
## 0x54 WALLET_UPDATE           S→C  19 B    the balance of one currency
## 0x55 PROGRESS_UPDATE         S→C  25 B    level, XP, realm and attribute points
## [/codeblock]
## As in [NetMessages], each class has [code]encode()[/code] and [code]static decode(bytes)[/code],
## which returns null if the message is malformed (exact size according to the counters, ranges and
## each object per [method ItemInstance.decode]) and never logs engine errors. An
## [code]encode()[/code] that could not be decoded (fields out of range, too many entries, an
## invalid object) returns an empty array: that is a bug in whoever builds the message. Those that
## carry objects use the net id of an [ItemDatabase] (null = [method ItemDatabase.shared]). Little
## endian, like the rest of the protocol. Shared: no clock, no randomness.

## Maximum level the protocol allows (the cap of [LevelCurve], docs/progression.md §6.1; checked by
## the test).
const MAX_LEVEL: int = 40
## Maximum entries in an INVENTORY_DELTA or in one page of INVENTORY_FULL.
const MAX_ENTRIES: int = 30
## Maximum pages in an INVENTORY_FULL (with 120 bag slots and 7 equipment slots, 5 are enough).
const MAX_PAGES: int = 8
## Destination container and slot of a DESTROY on the wire.
const NO_SLOT: int = InventoryOps.NO_SLOT
## Highest container the wire allows (0 bag, 1 equipment, 2 bank and 3 reserved; the server rejects
## 2 and 3 in phase 5).
const MAX_CONTAINER: int = 3

## Source of what was gained in a PROGRESS_UPDATE: 0 is the state (on entry or after a command that
## adds no XP).
enum XpSource { STATE = 0, PVP = 1, NPC = 2, CAPTURE = 3, GM = 4 }


## A slot of an INVENTORY_DELTA or an INVENTORY_FULL: its content ([member item]; null = empty,
## only in a delta).
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


	## true if [param other] is the same slot with the same content.
	func equals(other: Entry) -> bool:
		if other == null or other.container != container or other.slot != slot:
			return false
		if item == null or other.item == null:
			return item == null and other.item == null
		return item.equals(other.item)


## INVENTORY_REQUEST (C→S, 18 B): [code]u8 type, u16 request_id, u8 op, u8 from_container, u8
## from_slot, u8 to_container, u8 to_slot, u16 count, u64 expected_uid[/code]. [member request_id]
## ranges from 1 to 65535 (the client increments it on every request and skips 0); [member op],
## from 1 to 3 ([enum InventoryOps.Op]); containers, from 0 to 3, except the destination of a
## DESTROY, which is [constant NO_SLOT] in container and slot. MOVE carries [member count] 0;
## SPLIT, the ones that leave; DESTROY, the ones destroyed (0 = the whole stack). [method decode]
## does not check the inventory rules (that is [method InventoryOps.apply]): only the format.
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


	## The request [param request] with id [param id]. In DESTROY the destination becomes
	## [constant NO_SLOT].
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


	## The [InventoryOps.Request] it carries (without the [member request_id]).
	func to_request() -> InventoryOps.Request:
		return InventoryOps.make_request(op, from_container, from_slot, to_container, to_slot, count,
				expected_uid)


	## Empty if any field does not fit or [method decode] would not accept it.
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


	## null if it is not 18 B of type 0x50, [member request_id] is 0, the operation is not 1, 2 or 3, a
	## container exceeds 3 or the destination of a DESTROY is not [constant NO_SLOT] (or that of
	## another operation is).
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


## INVENTORY_DELTA (S→C, 10 B + entries, ≤ [constant MAX_SIZE] B): [code]u8 type, u32 revision, u16
## request_id, u8 result, u8 reason, u8 entry_count[/code] and, per entry, [code]u8 container, u8
## slot, u8 present[/code] (0 empty, 1 with item) and, if [code]present[/code],
## [method ItemInstance.encode]. It answers a request ([member request_id] ≠ 0, [member reason] 0
## and [member result] one of [enum InventoryOps.Result]: on a rejection, the entries carry the
## real content of the slots the request touched and the revision does not increase) or gives a
## change decided by the server ([member request_id] 0, [member result] OK and [member reason] the
## [EconomyReason] motive). The revision increases by 1 with each applied change
## (docs/progression.md §4.6).
class InventoryDelta:
	const HEADER_SIZE: int = 10
	## 10 + 30 × (3 + 34).
	const MAX_SIZE: int = HEADER_SIZE + MAX_ENTRIES * (3 + ItemInstance.HEADER_SIZE + 2 * ItemInstance.MAX_AFFIXES)

	## u32: the inventory revision after applying.
	var revision: int = 0
	## 0 = change decided by the server.
	var request_id: int = 0
	## [enum InventoryOps.Result].
	var result: int = InventoryOps.Result.OK
	## Motive ([EconomyReason]) of a server-side change; 0 in replies.
	var reason: int = 0
	var entries: Array[Entry] = []


	## A delta with the current content of [param slots] (container, slot pairs) of [param state]: what
	## changed with an applied request ([member InventoryOps.Outcome.changed]) or what a rejected one
	## touched.
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


	## Empty if there are more than [constant MAX_ENTRIES] entries, any field would not be accepted by
	## [method decode] or an object cannot be encoded ([method ItemInstance.encode] empty).
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


	## null if the type is not 0x51, the size does not match the entries, there are more than 30, a
	## [code]present[/code] is neither 0 nor 1, a slot is repeated or does not exist (container 0 to 3;
	## equipment slot 0 to 6 and the others 0 to 119), an object fails [method ItemInstance.decode],
	## [member result] is not an [enum InventoryOps.Result], a reply carries a reason or a server-side
	## change carries a result other than OK or an unknown reason.
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


## INVENTORY_FULL (S→C, ≤ [constant MAX_SIZE] B): [code]u8 type, u32 revision, u8 bag_slots, u8
## page_index, u8 page_count, u8 entry_count[/code] and, only for occupied slots,
## [code]u8 container, u8 slot[/code] and [method ItemInstance.encode]. It is sent on entering the
## world (after the player's own SPAWN), after the starter kit and in reply to an
## INVENTORY_SYNC_REQUEST. The client gathers the pages of one revision ([method assemble]) and
## only then replaces its state.
class InventoryFull:
	const HEADER_SIZE: int = 9
	## 9 + 30 × (2 + 34).
	const MAX_SIZE: int = HEADER_SIZE + MAX_ENTRIES * (2 + ItemInstance.HEADER_SIZE + 2 * ItemInstance.MAX_AFFIXES)

	var revision: int = 0
	## Bag slots (1 to [constant InventoryState.BAG_SLOTS_MAX]).
	var bag_slots: int = InventoryState.BAG_SLOTS_DEFAULT
	var page_index: int = 0
	var page_count: int = 1
	## Occupied slots only: [member Entry.item] is never null.
	var entries: Array[Entry] = []


	## The pages of [param state] with revision [param full_revision]: its occupied slots in the order
	## of [method InventoryState.occupied_slots], [constant MAX_ENTRIES] per page, and at least one
	## (empty if there is nothing). A state that does not fit in [constant MAX_PAGES] pages yields an
	## empty list.
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


	## The inventory formed by [param pages] (those of one revision, in any order), or null if pages
	## are missing or extra, they do not match in revision, slots or page count, a slot is repeated or
	## an object is in a container that does not exist in phase 5.
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


	## Empty if any field would not be accepted by [method decode], there are more than
	## [constant MAX_ENTRIES] entries or an empty one, or an object cannot be encoded.
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


	## null if the type is not 0x52, the size does not match the entries, there are more than 30,
	## [member bag_slots] is not between 1 and 120, [member page_count] is not between 1 and 8 or
	## [member page_index] is not less than it, a slot is repeated or does not exist (container 0 to
	## 3; the bag, below [member bag_slots]; equipment, 0 to 6; the rest, 0 to 119) or an object fails
	## [method ItemInstance.decode].
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


## INVENTORY_SYNC_REQUEST (C→S, 1 B): type only. Asks for an INVENTORY_FULL (one every 5 s; more
## triggers a warning).
class InventorySyncRequest:
	const SIZE: int = 1


	func encode() -> PackedByteArray:
		return PackedByteArray([NetProtocol.MSG_INVENTORY_SYNC_REQUEST])


	static func decode(bytes: PackedByteArray) -> InventorySyncRequest:
		if bytes.size() != SIZE or bytes[0] != NetProtocol.MSG_INVENTORY_SYNC_REQUEST:
			return null
		return InventorySyncRequest.new()


## WALLET_UPDATE (S→C, 19 B): [code]u8 type, u8 currency, u64 balance, s64 delta, u8 reason[/code].
## The balance of a currency ([enum Currency.Code]) after adding [member delta] (0 in the initial
## state, on entry); at most one every 10 ticks per currency, with the summed delta. [member reason]
## is the motive ([EconomyReason]) of the last change, or 0.
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


	## Empty if any field would not be accepted by [method decode].
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


	## null if it is not 19 B of type 0x54, the currency does not exist, the balance is outside 0 … cap,
	## the delta exceeds the cap in absolute value or the motive is neither 0 nor one of
	## [EconomyReason].
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


## PROGRESS_UPDATE (S→C, 25 B): [code]u8 type, u8 level, u32 xp_in_level, u32 xp_to_next, u32
## gained, u8 source, u64 realm_points, u16 attribute_points[/code]. [member xp_in_level] is the XP
## since the start of the level and [member xp_to_next] the XP the next one requires (0 at the cap,
## where [member xp_in_level] is also 0); [member gained], what was gained since the previous one
## with source [member source] ([enum XpSource]). At most one every 10 ticks per player, with the
## sum of what was gained (docs/progression.md §6.3).
class ProgressUpdate:
	const SIZE: int = 25

	var level: int = 1
	var xp_in_level: int = 0
	var xp_to_next: int = 0
	var gained: int = 0
	var source: int = XpSource.STATE
	var realm_points: int = 0
	var attribute_points: int = 0


	## The state of a character of level [param new_level] with [param xp_total] XP on [param curve]
	## ([method LevelCurve.total_to] and [method LevelCurve.xp_for_next]) and its unspent attribute
	## points ([method ProgressionRules.attribute_points] with [param spent_points] spent).
	## [param amount] saturates to u32. With [param new_level] = [method LevelCurve.level_for] of
	## [param xp_total] (I8) the level's XP is always less than the next level's; if it were not, it is
	## clamped so the message can be encoded.
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


	## Empty if any field would not be accepted by [method decode].
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


	## null if it is not 25 B of type 0x55, the level is not between 1 and [constant MAX_LEVEL], the
	## level's XP is not less than what the next one requires (or is not 0 at the cap), the source is
	## not an [enum XpSource] or the realm points exceed 2^63 − 1.
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


## true if slot [param slot] of [param container] can travel: container from 0 to
## [constant MAX_CONTAINER]; in the bag, below [param bag_slots]; in equipment, below
## [constant InventoryState.EQUIPMENT_SLOTS]; in the others, below
## [constant InventoryState.BAG_SLOTS_MAX].
static func slot_in_range(container: int, slot: int, bag_slots: int) -> bool:
	if slot < 0:
		return false
	match container:
		InventoryState.ContainerId.BAG:
			return slot < mini(bag_slots, InventoryState.BAG_SLOTS_MAX)
		InventoryState.ContainerId.EQUIPMENT:
			return slot < InventoryState.EQUIPMENT_SLOTS
	return container >= 0 and container <= MAX_CONTAINER and slot < InventoryState.BAG_SLOTS_MAX
