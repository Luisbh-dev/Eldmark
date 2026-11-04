class_name NetMessages
extends RefCounted
## Phase 2 network protocol messages and their serialization (docs/red.md, section 5).
## [br][br]
## Each inner class has [code]encode() -> PackedByteArray[/code] and
## [code]static decode(bytes) -> <Class>[/code], which returns null if the message is malformed:
## mismatched size, type, counters or lengths, extra bytes or text that is not valid
## UTF-8. The [code]decode[/code] functions check sizes before reading, so they never log
## engine errors, not even with random bytes (the server decodes what untrusted
## clients send).
## [br][br]
## Everything is little-endian. The first three (HELLO, WELCOME and REJECT) are authentication
## messages: they start with the magic [constant NetProtocol.MAGIC]. The rest start with their
## type ([code]NetProtocol.MSG_*[/code]) and travel through [code]send_bytes[/code].

## Size of the header of a SNAPSHOT without own state, including the
## [code]section_count[/code] byte.
const SNAPSHOT_HEADER_SIZE: int = 14
## Size of the extra own block of a SNAPSHOT (health, max health, status and respawn
## tick), which goes after the own state.
const SNAPSHOT_EXTRA_SIZE: int = 9
## Size of the header of a SNAPSHOT with own state, including the state, the extra block (which
## always accompanies the state) and the [code]section_count[/code] byte.
const SNAPSHOT_HEADER_SIZE_WITH_STATE: int = \
		SNAPSHOT_HEADER_SIZE + PlayerState.ENCODED_SIZE + SNAPSHOT_EXTRA_SIZE
## Maximum records per section (the counter is a u8).
const MAX_SECTION_RECORDS: int = 255
## Maximum bytes of a NOTICE's text.
const MAX_NOTICE_BYTES: int = 200
## Maximum bytes of a REJECT's text (the counter is a u8).
const MAX_REJECT_TEXT_BYTES: int = 255
## Maximum bytes of data of a DEBUG_COMMAND.
const MAX_DEBUG_PAYLOAD_BYTES: int = 64
## Maximum fields of an OBJECT_STATE or of a structure's ENTITY_SPAWN (the counter is a u8,
## but phase 4 does not exceed 17).
const MAX_OBJECT_FIELDS: int = 32
## Header of an OBJECT_STATE: [code]u8 type, u16 net_id, u32 tick, u8 field_count[/code].
const OBJECT_STATE_HEADER_SIZE: int = 8
## Bytes that its [code]u16 npc_def_id[/code] adds to an NPC's ENTITY_SPAWN.
const NPC_SPAWN_TAIL_SIZE: int = 2
## Bytes added to a player's ENTITY_SPAWN after the name (protocol 7, docs/progresion.md §7.3): the
## [code]u8 level[/code] and the 8 B of [CharacterAppearance].
const PLAYER_SPAWN_TAIL_SIZE: int = 1 + CharacterAppearance.ENCODED_SIZE
## Bytes of the per-realm count at the end of the WELCOME ([code]u8 × 3[/code]).
const WELCOME_REALM_COUNTS_SIZE: int = 3

## [code]status[/code] bits of the own extra block of a SNAPSHOT (and of the compact state of a
## PARTY_STATUS).
const STATUS_IN_COMBAT: int = 1 << 0
const STATUS_PROTECTED: int = 1 << 1
const STATUS_DEAD: int = 1 << 2
## Knocked down (protocol 6; docs/habilidades.md, section 5.2). Never together with [constant STATUS_DEAD]: a
## knocked down character is not dead. With it, the extra block's health is the downed health and the maximum, the
## rules' downed maximum.
const STATUS_DOWNED: int = 1 << 3

## Bit 0 of a SNAPSHOT's flags: it carries the own state.
const FLAG_OWN_STATE: int = 1 << 0
## Bit 3 of a SNAPSHOT's flags: it carries the own extra block. It is present if and only if the own
## state is present (bit 0).
const FLAG_OWN_EXTRA: int = 1 << 3
## Shift and mask of the teleport counter in the flags (2 bits).
const TELEPORT_SHIFT: int = 1
const TELEPORT_MASK: int = 0b11
## Header of an INPUT_BATCH and size of each of its records.
const INPUT_BATCH_HEADER_SIZE: int = 11
const INPUT_RECORD_SIZE: int = 10
## Header of an ENTITY_SPAWN, before the entity's data.
const SPAWN_HEADER_SIZE: int = 10
## Bit 3 of the [code]flags[/code] of an ENTITY_SPAWN header (protocol 7, docs/plataforma.md §5.4): the
## character belongs to the game staff (moderator or higher), for the tag (SOC-14). It is not bit 3 of the
## snapshot record's [code]flags[/code] (slot 2 active, from docs/habilidades.md).
const SPAWN_FLAG_STAFF: int = 1 << 3
## Maximum of [code]view_offset_q[/code] (u16).
const MAX_VIEW_OFFSET_Q: int = 0xFFFF


## Type of a message (its byte 0), or -1 if [param bytes] is empty.
static func peek_type(bytes: PackedByteArray) -> int:
	return bytes[0] if bytes.size() > 0 else -1


## Result of an authentication message: -1 if it does not start with the magic, 0 if it is a WELCOME
## and a value greater than 0 ([enum NetProtocol.Result]) if it is a REJECT.
static func peek_auth_result(bytes: PackedByteArray) -> int:
	if bytes.size() < 5 or bytes.decode_u32(0) != NetProtocol.MAGIC:
		return -1
	return bytes[4]


## true if the [param length] bytes from [param offset] are valid UTF-8 and contain no null
## byte. [method String.get_string_from_utf8] logs an error with invalid bytes, so
## network texts are checked with this before converting them.
static func is_valid_utf8(bytes: PackedByteArray, offset: int, length: int) -> bool:
	var end: int = offset + length
	if offset < 0 or length < 0 or end > bytes.size():
		return false
	var i: int = offset
	while i < end:
		var lead: int = bytes[i]
		if lead == 0:
			return false
		if lead < 0x80:
			i += 1
			continue
		var extra: int = 0
		var low: int = 0x80
		var high: int = 0xBF
		if lead >= 0xC2 and lead <= 0xDF:
			extra = 1
		elif lead == 0xE0:
			extra = 2
			low = 0xA0
		elif lead == 0xED:
			extra = 2
			high = 0x9F
		elif lead >= 0xE1 and lead <= 0xEF:
			extra = 2
		elif lead == 0xF0:
			extra = 3
			low = 0x90
		elif lead == 0xF4:
			extra = 3
			high = 0x8F
		elif lead >= 0xF1 and lead <= 0xF3:
			extra = 3
		else:
			return false
		if i + extra >= end:
			return false
		var second: int = bytes[i + 1]
		if second < low or second > high:
			return false
		for k: int in range(2, extra + 1):
			var continuation: int = bytes[i + k]
			if continuation < 0x80 or continuation > 0xBF:
				return false
		i += extra + 1
	return true


## true if all characters of [param text] are printable ASCII (0x20-0x7E). It must be checked
## before [method String.to_ascii_buffer], which logs an engine error with other characters.
static func is_printable_ascii_text(text: String) -> bool:
	for i: int in text.length():
		var code: int = text.unicode_at(i)
		if code < 0x20 or code > 0x7E:
			return false
	return true


## [param text] in UTF-8, trimmed to [param max_bytes] without splitting any character.
static func utf8_limited(text: String, max_bytes: int) -> PackedByteArray:
	var bytes: PackedByteArray = text.to_utf8_buffer()
	if bytes.size() <= max_bytes:
		return bytes
	var cut: int = max_bytes
	while cut > 0 and (bytes[cut] & 0xC0) == 0x80:
		cut -= 1
	return bytes.slice(0, cut)


## UTF-8 text of [param length] bytes from [param offset]. It must have been validated beforehand with
## [method is_valid_utf8]. Note: [method PackedByteArray.get_string_from_utf8] skips a BOM (EF BB BF) at the
## start, so some non-empty bytes can be read as an empty string; whoever requires a name checks it
## after reading it.
static func read_text(bytes: PackedByteArray, offset: int, length: int) -> String:
	if length <= 0:
		return ""
	return bytes.slice(offset, offset + length).get_string_from_utf8()


## true if the [param length] bytes from [param offset] are printable ASCII (0x20-0x7E), like
## zone ids.
static func is_printable_ascii(bytes: PackedByteArray, offset: int, length: int) -> bool:
	for i: int in range(offset, offset + length):
		var value: int = bytes[i]
		if value < 0x20 or value > 0x7E:
			return false
	return true


## true if [param fields] can be written into an OBJECT_STATE or a structure's ENTITY_SPAWN:
## 1 to [constant MAX_OBJECT_FIELDS] fields, with a known value type and no repeated id.
static func are_fields_encodable(fields: Array[ObjectField]) -> bool:
	if fields.size() < 1 or fields.size() > MAX_OBJECT_FIELDS:
		return false
	var seen: Dictionary = {}
	for field: ObjectField in fields:
		if field == null or ObjectField.size_of_type(field.value_type) == 0 \
				or seen.has(field.field_id):
			return false
		seen[field.field_id] = true
	return true


## Bytes taken by [param fields] ([code]2 + value size[/code] each).
static func fields_size(fields: Array[ObjectField]) -> int:
	var total: int = 0
	for field: ObjectField in fields:
		total += field.encoded_size()
	return total


## Writes [param fields] into [param bytes] from [param offset] (the buffer is already large
## enough) and returns the next offset.
static func write_fields(bytes: PackedByteArray, offset: int, fields: Array[ObjectField]) -> int:
	var cursor: int = offset
	for field: ObjectField in fields:
		cursor = field.write_to(bytes, cursor)
	return cursor


## Reads [param count] fields from [param bytes] from [param offset] and appends them to [param out].
## Returns the next offset, or -1 if a field does not fit, has an unknown value type or
## repeats another's id. A [code]field_id[/code] unknown to whoever reads it is kept (whoever
## interprets it is the one who skips it). Never logs engine errors.
static func read_fields(bytes: PackedByteArray, offset: int, count: int,
		out: Array[ObjectField]) -> int:
	var cursor: int = offset
	var seen: Dictionary = {}
	for _i: int in count:
		var field: ObjectField = ObjectField.read_from(bytes, cursor)
		if field == null or seen.has(field.field_id):
			return -1
		seen[field.field_id] = true
		out.append(field)
		cursor += field.encoded_size()
	return cursor


## A field of an OBJECT_STATE or of a structure's ENTITY_SPAWN: [code]u8 field_id, u8
## value_type[/code] and the value (docs/fuerte.md, section 2). Field ids are defined by whoever
## replicates the object ([FortressFields] for fortresses); here they only travel.
class ObjectField:
	## Type of the value in the message.
	enum ValueType { U8 = 1, U16 = 2, U32 = 3, S32 = 4 }

	## Header of a field: [code]u8 field_id, u8 value_type[/code].
	const HEADER_SIZE: int = 2

	var field_id: int = 0
	## [enum ValueType].
	var value_type: int = ValueType.U8
	var value: int = 0


	static func make(id: int, type: int, field_value: int) -> ObjectField:
		var field := ObjectField.new()
		field.field_id = id
		field.value_type = type
		field.value = field_value
		return field


	## Bytes of the value of a type ([param type]), or 0 if the type does not exist.
	static func size_of_type(type: int) -> int:
		match type:
			ValueType.U8:
				return 1
			ValueType.U16:
				return 2
			ValueType.U32, ValueType.S32:
				return 4
		return 0


	## Bytes taken by the whole field.
	func encoded_size() -> int:
		return HEADER_SIZE + size_of_type(value_type)


	## true if the type is known, the id fits in a u8 and the value fits in the type.
	func is_valid() -> bool:
		if field_id < 0 or field_id > 0xFF:
			return false
		match value_type:
			ValueType.U8:
				return value >= 0 and value <= 0xFF
			ValueType.U16:
				return value >= 0 and value <= 0xFFFF
			ValueType.U32:
				return value >= 0 and value <= 0xFFFFFFFF
			ValueType.S32:
				return value >= -0x80000000 and value <= 0x7FFFFFFF
		return false


	## Writes the field into [param bytes] from [param offset] (with room to spare) and returns the
	## next offset. A value that does not fit in its type is saturated.
	func write_to(bytes: PackedByteArray, offset: int) -> int:
		bytes.encode_u8(offset, field_id & 0xFF)
		bytes.encode_u8(offset + 1, value_type)
		match value_type:
			ValueType.U8:
				bytes.encode_u8(offset + 2, clampi(value, 0, 0xFF))
			ValueType.U16:
				bytes.encode_u16(offset + 2, clampi(value, 0, 0xFFFF))
			ValueType.U32:
				bytes.encode_u32(offset + 2, clampi(value, 0, 0xFFFFFFFF))
			ValueType.S32:
				bytes.encode_s32(offset + 2, clampi(value, -0x80000000, 0x7FFFFFFF))
		return offset + encoded_size()


	## The field starting at [param offset], or null if it does not fit or its value type is unknown.
	static func read_from(bytes: PackedByteArray, offset: int) -> ObjectField:
		if offset < 0 or offset + HEADER_SIZE > bytes.size():
			return null
		var type: int = bytes.decode_u8(offset + 1)
		var value_size: int = size_of_type(type)
		if value_size == 0 or offset + HEADER_SIZE + value_size > bytes.size():
			return null
		var field := ObjectField.new()
		field.field_id = bytes.decode_u8(offset)
		field.value_type = type
		match type:
			ValueType.U8:
				field.value = bytes.decode_u8(offset + 2)
			ValueType.U16:
				field.value = bytes.decode_u16(offset + 2)
			ValueType.U32:
				field.value = bytes.decode_u32(offset + 2)
			ValueType.S32:
				field.value = bytes.decode_s32(offset + 2)
		return field


## HELLO (C→S, authentication): 23 B + name + ticket.
class Hello:
	## Bit 0 of [member flags]: the client is a bot.
	const FLAG_BOT: int = 1 << 0
	const MIN_SIZE: int = 23

	var protocol_version: int = NetProtocol.PROTOCOL_VERSION
	var sim_hash: int = 0
	var realm: int = NetProtocol.Realm.NONE
	var flags: int = 0
	var character_id: int = 0
	var display_name: String = ""
	var ticket: PackedByteArray = PackedByteArray()


	func is_bot() -> bool:
		return (flags & FLAG_BOT) != 0


	func encode() -> PackedByteArray:
		var name_bytes: PackedByteArray = NetMessages.utf8_limited(display_name,
				NetProtocol.MAX_NAME_BYTES)
		var ticket_size: int = mini(ticket.size(), NetProtocol.MAX_TICKET_BYTES)
		var bytes := PackedByteArray()
		bytes.resize(MIN_SIZE + name_bytes.size() + ticket_size)
		bytes.encode_u32(0, NetProtocol.MAGIC)
		bytes.encode_u16(4, protocol_version & 0xFFFF)
		bytes.encode_u32(6, sim_hash & 0xFFFFFFFF)
		bytes.encode_u8(10, realm & 0xFF)
		bytes.encode_u8(11, flags & 0xFF)
		bytes.encode_u64(12, character_id)
		bytes.encode_u8(20, name_bytes.size())
		for i: int in name_bytes.size():
			bytes[21 + i] = name_bytes[i]
		var ticket_offset: int = 21 + name_bytes.size()
		bytes.encode_u16(ticket_offset, ticket_size)
		for i: int in ticket_size:
			bytes[ticket_offset + 2 + i] = ticket[i]
		return bytes


	static func decode(bytes: PackedByteArray) -> Hello:
		var size: int = bytes.size()
		if size < MIN_SIZE or bytes.decode_u32(0) != NetProtocol.MAGIC:
			return null
		var name_len: int = bytes.decode_u8(20)
		if name_len > NetProtocol.MAX_NAME_BYTES or size < 23 + name_len:
			return null
		var ticket_offset: int = 21 + name_len
		var ticket_len: int = bytes.decode_u16(ticket_offset)
		if ticket_len > NetProtocol.MAX_TICKET_BYTES or size != 23 + name_len + ticket_len:
			return null
		if not NetMessages.is_valid_utf8(bytes, 21, name_len):
			return null
		var hello := Hello.new()
		hello.protocol_version = bytes.decode_u16(4)
		hello.sim_hash = bytes.decode_u32(6)
		hello.realm = bytes.decode_u8(10)
		hello.flags = bytes.decode_u8(11)
		hello.character_id = bytes.decode_u64(12)
		hello.display_name = NetMessages.read_text(bytes, 21, name_len)
		hello.ticket = bytes.slice(ticket_offset + 2, ticket_offset + 2 + ticket_len)
		return hello


## WELCOME (S→C, authentication): 18 B + zone id + 3 B with the per-realm count.
## [br][br]
## After the zone id come three [code]u8[/code] with the players of Vardheim, Solmarch and Askarra in
## the zone ([member realm_counts]), so that realm selection offers the emptiest one (docs/fuerte.md,
## section 7).
class Welcome:
	## Bytes without the zone id: the 18 B header and the per-realm count.
	const MIN_SIZE: int = 18 + WELCOME_REALM_COUNTS_SIZE
	## Offset of the zone id.
	const ZONE_OFFSET: int = 18

	var protocol_version: int = NetProtocol.PROTOCOL_VERSION
	var server_tick: int = 0
	var tick_rate: int = 60
	var snapshot_interval: int = NetProtocol.SNAPSHOT_INTERVAL_TICKS
	var max_input_batch: int = NetProtocol.MAX_INPUTS_PER_BATCH
	var max_rewind_ticks: int = NetProtocol.MAX_REWIND_TICKS
	var realm: int = NetProtocol.Realm.NONE
	var channel: int = 0
	var zone_id: String = ""
	## Players per realm in the zone: position 0 = Vardheim, 1 = Solmarch, 2 = Askarra (one u8
	## each; they saturate at 255).
	var realm_counts: PackedInt32Array = PackedInt32Array([0, 0, 0])


	## Players of realm [param realm_code] ([enum NetProtocol.Realm], 1 to 3); 0 if the code does not belong to
	## a playable realm.
	func get_realm_count(realm_code: int) -> int:
		var index: int = realm_code - 1
		if index < 0 or index >= realm_counts.size() or index >= WELCOME_REALM_COUNTS_SIZE:
			return 0
		return realm_counts[index]


	func encode() -> PackedByteArray:
		var zone_bytes: PackedByteArray = zone_id.to_ascii_buffer()
		if zone_bytes.size() > NetProtocol.MAX_ZONE_ID_BYTES:
			zone_bytes = zone_bytes.slice(0, NetProtocol.MAX_ZONE_ID_BYTES)
		var bytes := PackedByteArray()
		bytes.resize(MIN_SIZE + zone_bytes.size())
		bytes.encode_u32(0, NetProtocol.MAGIC)
		bytes.encode_u8(4, NetProtocol.Result.OK)
		bytes.encode_u16(5, protocol_version & 0xFFFF)
		bytes.encode_u32(7, server_tick & 0xFFFFFFFF)
		bytes.encode_u8(11, tick_rate & 0xFF)
		bytes.encode_u8(12, snapshot_interval & 0xFF)
		bytes.encode_u8(13, max_input_batch & 0xFF)
		bytes.encode_u8(14, max_rewind_ticks & 0xFF)
		bytes.encode_u8(15, realm & 0xFF)
		bytes.encode_u8(16, channel & 0xFF)
		bytes.encode_u8(17, zone_bytes.size())
		for i: int in zone_bytes.size():
			bytes[ZONE_OFFSET + i] = zone_bytes[i]
		var counts_offset: int = ZONE_OFFSET + zone_bytes.size()
		for i: int in WELCOME_REALM_COUNTS_SIZE:
			var count: int = realm_counts[i] if i < realm_counts.size() else 0
			bytes.encode_u8(counts_offset + i, clampi(count, 0, 0xFF))
		return bytes


	static func decode(bytes: PackedByteArray) -> Welcome:
		var size: int = bytes.size()
		if size < MIN_SIZE or bytes.decode_u32(0) != NetProtocol.MAGIC:
			return null
		if bytes.decode_u8(4) != NetProtocol.Result.OK:
			return null
		var zone_len: int = bytes.decode_u8(17)
		if zone_len > NetProtocol.MAX_ZONE_ID_BYTES or size != MIN_SIZE + zone_len:
			return null
		if not NetMessages.is_printable_ascii(bytes, ZONE_OFFSET, zone_len):
			return null
		var welcome := Welcome.new()
		welcome.protocol_version = bytes.decode_u16(5)
		welcome.server_tick = bytes.decode_u32(7)
		welcome.tick_rate = bytes.decode_u8(11)
		welcome.snapshot_interval = bytes.decode_u8(12)
		welcome.max_input_batch = bytes.decode_u8(13)
		welcome.max_rewind_ticks = bytes.decode_u8(14)
		welcome.realm = bytes.decode_u8(15)
		welcome.channel = bytes.decode_u8(16)
		welcome.zone_id = NetMessages.read_text(bytes, ZONE_OFFSET, zone_len)
		var counts_offset: int = ZONE_OFFSET + zone_len
		for i: int in WELCOME_REALM_COUNTS_SIZE:
			welcome.realm_counts[i] = bytes.decode_u8(counts_offset + i)
		return welcome


## REJECT (S→C, authentication): 6 B + text.
class Reject:
	const MIN_SIZE: int = 6

	## Reason ([enum NetProtocol.Result]); it cannot be OK.
	var result: int = NetProtocol.Result.MALFORMED
	var text: String = ""


	func encode() -> PackedByteArray:
		var text_bytes: PackedByteArray = NetMessages.utf8_limited(text,
				MAX_REJECT_TEXT_BYTES)
		var bytes := PackedByteArray()
		bytes.resize(MIN_SIZE + text_bytes.size())
		bytes.encode_u32(0, NetProtocol.MAGIC)
		bytes.encode_u8(4, result & 0xFF)
		bytes.encode_u8(5, text_bytes.size())
		for i: int in text_bytes.size():
			bytes[6 + i] = text_bytes[i]
		return bytes


	static func decode(bytes: PackedByteArray) -> Reject:
		var size: int = bytes.size()
		if size < MIN_SIZE or bytes.decode_u32(0) != NetProtocol.MAGIC:
			return null
		var result_code: int = bytes.decode_u8(4)
		if result_code == NetProtocol.Result.OK:
			return null
		var text_len: int = bytes.decode_u8(5)
		if size != MIN_SIZE + text_len or not NetMessages.is_valid_utf8(bytes, 6, text_len):
			return null
		var reject := Reject.new()
		reject.result = result_code
		reject.text = NetMessages.read_text(bytes, 6, text_len)
		return reject


## INPUT_BATCH (C→S, channel 1): 11 + 10·n B (n from 1 to 8).
## [br][br]
## The ticks of the records do not travel: record [i]i[/i] belongs to tick
## [code]newest_tick - count + 1 + i[/code], so a batch with gaps cannot even be
## written. [method encode] returns an empty buffer if [member inputs] does not satisfy that.
class InputBatch:
	## `server_tick` of the newest snapshot received (0 = none).
	var ack_snapshot_tick: int = 0
	## Current interpolation delay × 8, in ticks.
	var interp_delay_q: int = 0
	## Tick of the newest input.
	var newest_tick: int = 0
	## From oldest to newest, with consecutive ticks ending at [member newest_tick].
	var inputs: Array[PlayerInput] = []
	## Same size as [member inputs]: (tick - render_tick seen) × 16, between 0 and 65535.
	var view_offsets_q: PackedInt32Array = PackedInt32Array()


	func encode() -> PackedByteArray:
		var count: int = inputs.size()
		if count < 1 or count > NetProtocol.MAX_INPUTS_PER_BATCH or newest_tick < count:
			return PackedByteArray()
		var first_tick: int = newest_tick - count + 1
		for i: int in count:
			if inputs[i].tick != first_tick + i:
				return PackedByteArray()
		var bytes := PackedByteArray()
		bytes.resize(INPUT_BATCH_HEADER_SIZE + INPUT_RECORD_SIZE * count)
		bytes.encode_u8(0, NetProtocol.MSG_INPUT_BATCH)
		bytes.encode_u32(1, ack_snapshot_tick & 0xFFFFFFFF)
		bytes.encode_u8(5, clampi(interp_delay_q, 0, 255))
		bytes.encode_u32(6, newest_tick & 0xFFFFFFFF)
		bytes.encode_u8(10, count)
		for i: int in count:
			var offset: int = INPUT_BATCH_HEADER_SIZE + INPUT_RECORD_SIZE * i
			# Bytes 4-11 of PlayerInput.encode() (move, look_yaw, look_pitch and buttons) are
			# the first 8 of the record.
			bytes.encode_u64(offset, inputs[i].encode().decode_u64(4))
			var view_offset: int = view_offsets_q[i] if i < view_offsets_q.size() else 0
			bytes.encode_u16(offset + 8, clampi(view_offset, 0, MAX_VIEW_OFFSET_Q))
		return bytes


	## Inputs come from [method PlayerInput.decode] (which normalizes out-of-range values)
	## with buttons limited to [constant NetProtocol.VALID_BUTTONS]. It requires
	## [code]count[/code] from 1 to 8, an exact size of [code]11 + 10 · count[/code] and
	## [code]newest_tick >= count[/code].
	static func decode(bytes: PackedByteArray) -> InputBatch:
		var size: int = bytes.size()
		if size < INPUT_BATCH_HEADER_SIZE + INPUT_RECORD_SIZE:
			return null
		if bytes[0] != NetProtocol.MSG_INPUT_BATCH:
			return null
		var count: int = bytes.decode_u8(10)
		if count < 1 or count > NetProtocol.MAX_INPUTS_PER_BATCH:
			return null
		if size != INPUT_BATCH_HEADER_SIZE + INPUT_RECORD_SIZE * count:
			return null
		var newest: int = bytes.decode_u32(6)
		if newest < count:
			return null
		var batch := InputBatch.new()
		batch.ack_snapshot_tick = bytes.decode_u32(1)
		batch.interp_delay_q = bytes.decode_u8(5)
		batch.newest_tick = newest
		batch.view_offsets_q.resize(count)
		# The 12 B of PlayerInput.decode: the tick first and then the first 8 bytes of the record.
		var scratch := PackedByteArray()
		scratch.resize(PlayerInput.ENCODED_SIZE)
		for i: int in count:
			var offset: int = INPUT_BATCH_HEADER_SIZE + INPUT_RECORD_SIZE * i
			scratch.encode_u32(0, newest - count + 1 + i)
			scratch.encode_u64(4, bytes.decode_u64(offset))
			var input: PlayerInput = PlayerInput.decode(scratch)
			input.buttons &= NetProtocol.VALID_BUTTONS
			batch.inputs.append(input)
			batch.view_offsets_q[i] = bytes.decode_u16(offset + 8)
		return batch


## CLIENT_READY (C→S, channel 3): 2 B.
class ClientReady:
	## Reserved (0).
	var flags: int = 0


	func encode() -> PackedByteArray:
		return PackedByteArray([NetProtocol.MSG_CLIENT_READY, flags & 0xFF])


	static func decode(bytes: PackedByteArray) -> ClientReady:
		if bytes.size() != 2 or bytes[0] != NetProtocol.MSG_CLIENT_READY:
			return null
		var ready := ClientReady.new()
		ready.flags = bytes[1]
		return ready


## CLIENT_LEAVE (C→S, channel 3): 2 B.
class ClientLeave:
	const REASON_QUIT: int = 0
	const REASON_ERROR: int = 1

	## 0 quit, 1 error.
	var reason: int = REASON_QUIT


	func encode() -> PackedByteArray:
		return PackedByteArray([NetProtocol.MSG_CLIENT_LEAVE, reason & 0xFF])


	static func decode(bytes: PackedByteArray) -> ClientLeave:
		if bytes.size() != 2 or bytes[0] != NetProtocol.MSG_CLIENT_LEAVE:
			return null
		var leave := ClientLeave.new()
		leave.reason = bytes[1]
		return leave


## DEBUG_COMMAND (C→S, channel 3): 2 B + data. The server only accepts it with
## [code]--debug-commands[/code].
## [br][br]
## [method decode] validates the data of fixed-format commands: 1 [code]teleport[/code] requires
## 12 B; 7 [code]unstuck[/code], 8 [code]fort_reset[/code] and 10 [code]fort_kill_captain[/code], 0 B;
## 9 [code]fort_owner[/code], 1 B with the realm (0 to 3); 11 [code]fort_capture_speed[/code], 1 B with the
## factor (1 to 255); 12 [code]npc_debug[/code], 1 B (0 or 1). Since protocol 6 (docs/habilidades.md,
## section 5.1): 13 [code]cooldowns_off[/code], 1 B (0 or 1); 14 [code]apply_status[/code], 3 B
## ([code]u8 status_id[/code] from 1 to 255 and [code]u16[/code] ticks, 0 = those from the data); 15 [code]down[/code]
## and 16 [code]refill[/code], 0 B. Since protocol 7 (docs/progresion.md §10), the progression GM ones:
## 40 [code]item_give[/code], 4 B ([code]u16[/code] object net id from 1 and [code]u16[/code] quantity from 1 to
## 999); 41 [code]currency_add[/code], 5 B ([code]u8[/code] currency, 1 or 2, and [code]s32[/code] nonzero
## amount); 42 [code]level_set[/code], 1 B (from 1 to [constant ProgressMessages.MAX_LEVEL]); and 43 [code]xp_add[/code], 4
## B ([code]u32[/code] from 1 to 10,000,000). Whether the net id exists is checked by the server. Commands 2 to 6 are
## validated by the server (up to [constant NetMessages.MAX_DEBUG_PAYLOAD_BYTES]).
class DebugCommand:
	## Bytes of data of a teleport (3 × f32).
	const TELEPORT_PAYLOAD_SIZE: int = 12
	## Bytes of data of [constant NetProtocol.DEBUG_ITEM_GIVE]: [code]u16 def, u16 count[/code].
	const ITEM_GIVE_PAYLOAD_SIZE: int = 4
	## Bytes of data of [constant NetProtocol.DEBUG_CURRENCY_ADD]: [code]u8 currency, s32 amount[/code].
	const CURRENCY_ADD_PAYLOAD_SIZE: int = 5
	## Bytes of data of [constant NetProtocol.DEBUG_XP_ADD]: [code]u32 amount[/code].
	const XP_ADD_PAYLOAD_SIZE: int = 4
	## Maximum quantity of [constant NetProtocol.DEBUG_ITEM_GIVE] (the largest stack, docs/progresion.md §2.1).
	const MAX_ITEM_GIVE_COUNT: int = 999
	## Maximum XP of [constant NetProtocol.DEBUG_XP_ADD].
	const MAX_XP_ADD: int = 10_000_000
	## Bytes of data of [constant NetProtocol.DEBUG_APPLY_STATUS]: [code]u8 status_id, u16 ticks[/code].
	const APPLY_STATUS_PAYLOAD_SIZE: int = 3
	## Highest realm accepted by [constant NetProtocol.DEBUG_FORT_OWNER].
	const MAX_FORT_OWNER_REALM: int = 3

	var command: int = 0
	var payload: PackedByteArray = PackedByteArray()


	## Teleport command to [param position] (14 B).
	static func teleport(position: Vector3) -> DebugCommand:
		var debug_command := DebugCommand.new()
		debug_command.command = NetProtocol.DEBUG_TELEPORT
		debug_command.payload.resize(TELEPORT_PAYLOAD_SIZE)
		debug_command.payload.encode_float(0, position.x)
		debug_command.payload.encode_float(4, position.y)
		debug_command.payload.encode_float(8, position.z)
		return debug_command


	## Command with no data ([constant NetProtocol.DEBUG_UNSTUCK], [constant NetProtocol.DEBUG_FORT_RESET]
	## or [constant NetProtocol.DEBUG_FORT_KILL_CAPTAIN]; works for any id).
	static func simple(command_id: int) -> DebugCommand:
		var debug_command := DebugCommand.new()
		debug_command.command = command_id
		return debug_command


	## Command [constant NetProtocol.DEBUG_FORT_OWNER]: give the fortress to realm [param realm_code].
	static func fort_owner(realm_code: int) -> DebugCommand:
		var debug_command := DebugCommand.simple(NetProtocol.DEBUG_FORT_OWNER)
		debug_command.payload = PackedByteArray([realm_code & 0xFF])
		return debug_command


	## Command [constant NetProtocol.DEBUG_FORT_CAPTURE_SPEED]: multiply capture by
	## [param factor] (from 1 to 255).
	static func fort_capture_speed(factor: int) -> DebugCommand:
		var debug_command := DebugCommand.simple(NetProtocol.DEBUG_FORT_CAPTURE_SPEED)
		debug_command.payload = PackedByteArray([factor & 0xFF])
		return debug_command


	## Command [constant NetProtocol.DEBUG_NPC_DEBUG]: turn NPC logging on or off.
	static func npc_debug(enabled: bool) -> DebugCommand:
		var debug_command := DebugCommand.simple(NetProtocol.DEBUG_NPC_DEBUG)
		debug_command.payload = PackedByteArray([1 if enabled else 0])
		return debug_command


	## Command [constant NetProtocol.DEBUG_COOLDOWNS_OFF]: abilities with no cooldown (or with it
	## again).
	static func cooldowns_off(enabled: bool) -> DebugCommand:
		var debug_command := DebugCommand.simple(NetProtocol.DEBUG_COOLDOWNS_OFF)
		debug_command.payload = PackedByteArray([1 if enabled else 0])
		return debug_command


	## Command [constant NetProtocol.DEBUG_APPLY_STATUS]: apply the catalog effect [param status_id] to oneself
	## for [param ticks] ticks (0 = the duration from the data; saturates to u16).
	static func apply_status(status_id: int, ticks: int = 0) -> DebugCommand:
		var debug_command := DebugCommand.simple(NetProtocol.DEBUG_APPLY_STATUS)
		debug_command.payload.resize(APPLY_STATUS_PAYLOAD_SIZE)
		debug_command.payload.encode_u8(0, status_id & 0xFF)
		debug_command.payload.encode_u16(1, clampi(ticks, 0, 0xFFFF))
		return debug_command


	## Command [constant NetProtocol.DEBUG_ITEM_GIVE]: give oneself [param count] (1 to 999) of the object with net id
	## [param item_net_id] ([method ItemDatabase.net_id_of]).
	static func item_give(item_net_id: int, count: int) -> DebugCommand:
		var debug_command := DebugCommand.simple(NetProtocol.DEBUG_ITEM_GIVE)
		debug_command.payload.resize(ITEM_GIVE_PAYLOAD_SIZE)
		debug_command.payload.encode_u16(0, item_net_id & 0xFFFF)
		debug_command.payload.encode_u16(2, count & 0xFFFF)
		return debug_command


	## Command [constant NetProtocol.DEBUG_CURRENCY_ADD]: add [param amount] (nonzero; negative subtracts) of
	## currency [param currency] ([enum Currency.Code]). Saturates to s32.
	static func currency_add(currency: int, amount: int) -> DebugCommand:
		var debug_command := DebugCommand.simple(NetProtocol.DEBUG_CURRENCY_ADD)
		debug_command.payload.resize(CURRENCY_ADD_PAYLOAD_SIZE)
		debug_command.payload.encode_u8(0, currency & 0xFF)
		debug_command.payload.encode_s32(1, clampi(amount, -0x80000000, 0x7FFFFFFF))
		return debug_command


	## Command [constant NetProtocol.DEBUG_LEVEL_SET]: set the level to [param level].
	static func level_set(level: int) -> DebugCommand:
		var debug_command := DebugCommand.simple(NetProtocol.DEBUG_LEVEL_SET)
		debug_command.payload = PackedByteArray([level & 0xFF])
		return debug_command


	## Command [constant NetProtocol.DEBUG_XP_ADD]: add [param amount] of XP (1 to 10,000,000).
	static func xp_add(amount: int) -> DebugCommand:
		var debug_command := DebugCommand.simple(NetProtocol.DEBUG_XP_ADD)
		debug_command.payload.resize(XP_ADD_PAYLOAD_SIZE)
		debug_command.payload.encode_u32(0, clampi(amount, 0, 0xFFFFFFFF))
		return debug_command


	## Object net id of a [constant NetProtocol.DEBUG_ITEM_GIVE] (0 if it is not one with its data).
	func get_item_net_id() -> int:
		return payload.decode_u16(0) if _has_payload(NetProtocol.DEBUG_ITEM_GIVE, ITEM_GIVE_PAYLOAD_SIZE) else 0


	## Quantity of a [constant NetProtocol.DEBUG_ITEM_GIVE] (0 if it is not one with its data).
	func get_item_count() -> int:
		return payload.decode_u16(2) if _has_payload(NetProtocol.DEBUG_ITEM_GIVE, ITEM_GIVE_PAYLOAD_SIZE) else 0


	## Currency of a [constant NetProtocol.DEBUG_CURRENCY_ADD] (0 if it is not one with its data).
	func get_currency() -> int:
		return payload.decode_u8(0) \
				if _has_payload(NetProtocol.DEBUG_CURRENCY_ADD, CURRENCY_ADD_PAYLOAD_SIZE) else 0


	## Quantity (signed) of a [constant NetProtocol.DEBUG_CURRENCY_ADD] (0 if it is not one with its data).
	func get_currency_amount() -> int:
		return payload.decode_s32(1) \
				if _has_payload(NetProtocol.DEBUG_CURRENCY_ADD, CURRENCY_ADD_PAYLOAD_SIZE) else 0


	## Level of a [constant NetProtocol.DEBUG_LEVEL_SET] (0 if it is not one with its data).
	func get_level() -> int:
		return payload.decode_u8(0) if _has_payload(NetProtocol.DEBUG_LEVEL_SET, 1) else 0


	## XP of a [constant NetProtocol.DEBUG_XP_ADD] (0 if it is not one with its data).
	func get_xp_amount() -> int:
		return payload.decode_u32(0) if _has_payload(NetProtocol.DEBUG_XP_ADD, XP_ADD_PAYLOAD_SIZE) else 0


	## Effect id of a [constant NetProtocol.DEBUG_APPLY_STATUS] (0 if it carries no data).
	func get_status_id() -> int:
		return payload.decode_u8(0) if payload.size() == APPLY_STATUS_PAYLOAD_SIZE else 0


	## Ticks of a [constant NetProtocol.DEBUG_APPLY_STATUS] (0 = those from the data, or without its data).
	func get_status_ticks() -> int:
		return payload.decode_u16(1) if payload.size() == APPLY_STATUS_PAYLOAD_SIZE else 0


	## Position of a teleport command ([constant NetProtocol.DEBUG_TELEPORT]).
	func get_teleport_position() -> Vector3:
		if payload.size() < TELEPORT_PAYLOAD_SIZE:
			return Vector3.ZERO
		return Vector3(payload.decode_float(0), payload.decode_float(4), payload.decode_float(8))


	func encode() -> PackedByteArray:
		var data_size: int = mini(payload.size(), MAX_DEBUG_PAYLOAD_BYTES)
		var bytes := PackedByteArray()
		bytes.resize(2 + data_size)
		bytes.encode_u8(0, NetProtocol.MSG_DEBUG_COMMAND)
		bytes.encode_u8(1, command & 0xFF)
		for i: int in data_size:
			bytes[2 + i] = payload[i]
		return bytes


	## A teleport requires exactly [constant TELEPORT_PAYLOAD_SIZE] bytes of data and
	## commands 7 to 16 and 40 to 43 those of their format (see the class description); the other commands
	## accept up to [constant NetMessages.MAX_DEBUG_PAYLOAD_BYTES].
	static func decode(bytes: PackedByteArray) -> DebugCommand:
		var size: int = bytes.size()
		if size < 2 or bytes[0] != NetProtocol.MSG_DEBUG_COMMAND:
			return null
		var data_size: int = size - 2
		if data_size > MAX_DEBUG_PAYLOAD_BYTES:
			return null
		if not _payload_is_valid(bytes[1], bytes.slice(2)):
			return null
		var debug_command := DebugCommand.new()
		debug_command.command = bytes[1]
		debug_command.payload = bytes.slice(2)
		return debug_command


	# Fixed-format commands require their data; the remaining ids pass as is (they are validated by whoever
	# runs them or counted as unknown).
	static func _payload_is_valid(command_id: int, data: PackedByteArray) -> bool:
		match command_id:
			NetProtocol.DEBUG_TELEPORT:
				return data.size() == TELEPORT_PAYLOAD_SIZE
			NetProtocol.DEBUG_UNSTUCK, NetProtocol.DEBUG_FORT_RESET, \
					NetProtocol.DEBUG_FORT_KILL_CAPTAIN, NetProtocol.DEBUG_DOWN, NetProtocol.DEBUG_REFILL:
				return data.is_empty()
			NetProtocol.DEBUG_FORT_OWNER:
				return data.size() == 1 and data[0] <= MAX_FORT_OWNER_REALM
			NetProtocol.DEBUG_FORT_CAPTURE_SPEED:
				return data.size() == 1 and data[0] >= 1
			NetProtocol.DEBUG_NPC_DEBUG, NetProtocol.DEBUG_COOLDOWNS_OFF:
				return data.size() == 1 and data[0] <= 1
			NetProtocol.DEBUG_APPLY_STATUS:
				return data.size() == APPLY_STATUS_PAYLOAD_SIZE and data[0] >= 1
			NetProtocol.DEBUG_ITEM_GIVE:
				if data.size() != ITEM_GIVE_PAYLOAD_SIZE:
					return false
				var count: int = data.decode_u16(2)
				return data.decode_u16(0) >= 1 and count >= 1 and count <= MAX_ITEM_GIVE_COUNT
			NetProtocol.DEBUG_CURRENCY_ADD:
				return data.size() == CURRENCY_ADD_PAYLOAD_SIZE and Currency.is_valid(data[0]) \
						and data.decode_s32(1) != 0
			NetProtocol.DEBUG_LEVEL_SET:
				return data.size() == 1 and data[0] >= 1 and data[0] <= ProgressMessages.MAX_LEVEL
			NetProtocol.DEBUG_XP_ADD:
				if data.size() != XP_ADD_PAYLOAD_SIZE:
					return false
				var amount: int = data.decode_u32(0)
				return amount >= 1 and amount <= MAX_XP_ADD
		return true


	# true if it is command [param command_id] with exactly [param size] B of data.
	func _has_payload(command_id: int, size: int) -> bool:
		return command == command_id and payload.size() == size


## SNAPSHOT (S→C, channel 2): 14 B header without own state or, with it, of
## [constant SNAPSHOT_HEADER_SIZE_WITH_STATE] B (in both cases, including the
## [code]section_count[/code] byte) and sections of [constant EntityRecord.SIZE] B records.
## [br][br]
## Header: [code]u8 type, u32 server_tick, u32 input_ack_tick, s8 input_margin,
## u16 substitutions, u8 flags[/code] (bit 0 = own state; bits 1-2 = own teleport
## counter; bit 3 = own extra block) and, if bit 0, the unquantized [PlayerState]
## ([constant PlayerState.ENCODED_SIZE] B) and the own extra block of
## [constant SNAPSHOT_EXTRA_SIZE] B: [code]u16 health, u16 max_health, u8 status, u32
## respawn_tick[/code]. Bit 3 is present if and only if bit 0 is: [method decode] rejects one without the
## other. Then, [code]u8 section_count[/code] and, per section, [code]u8 kind, u8 count[/code] and
## the records. There are only player records ([constant NetProtocol.EntityKind.PLAYER]) and
## NPC records ([constant NetProtocol.EntityKind.NPC]).
class Snapshot:
	var server_tick: int = 0
	var input_ack_tick: int = 0
	## Minimum lead time of the inputs since the previous snapshot, in [-127, 127]; -128 if there is
	## no data.
	var input_margin: int = NetProtocol.NO_MARGIN
	## Substituted inputs, accumulated (mod 65536).
	var substitutions: int = 0
	## Teleport counter of the own player (mod 4).
	var own_teleport: int = 0
	## Own state of the player, or null if the snapshot does not carry it.
	var own_state: PlayerState = null
	## Own extra block (only with [member own_state]): health of the own player.
	var health: int = 0
	## Own extra block: maximum health.
	var max_health: int = 0
	## Own extra block: bits [constant NetMessages.STATUS_IN_COMBAT],
	## [constant NetMessages.STATUS_PROTECTED], [constant NetMessages.STATUS_DEAD] and
	## [constant NetMessages.STATUS_DOWNED].
	var status: int = 0
	## Own extra block: tick at which respawning can be requested (0 if alive).
	var respawn_tick: int = 0
	## Records of the other entities, grouped by section in the message's order.
	var records: Array[EntityRecord] = []


	## true if the own player is in combat (extra block bit).
	func is_in_combat() -> bool:
		return (status & NetMessages.STATUS_IN_COMBAT) != 0


	## true if the own player has respawn protection.
	func is_protected() -> bool:
		return (status & NetMessages.STATUS_PROTECTED) != 0


	## true if the own player is dead.
	func is_dead() -> bool:
		return (status & NetMessages.STATUS_DEAD) != 0


	## true if the own player is knocked down: [member health] and [member max_health] are then the downed
	## health and its maximum.
	func is_downed() -> bool:
		return (status & NetMessages.STATUS_DOWNED) != 0


	## Writes the header into [param bytes] without creating any object and returns the offset where
	## [code]section_count[/code] starts (13 without own state; with it, 13 plus the state and the
	## extra block). Grows the buffer if it is shorter than the header and leaves
	## [code]section_count[/code] at 0: whoever builds the snapshot fills it in afterwards.
	## [param own_state_bytes] is [code]PlayerState.encode()[/code]
	## ([constant PlayerState.ENCODED_SIZE] B) or an empty buffer if there is no own state. With
	## own state the extra block is also written with [param health], [param max_health],
	## [param status] and [param respawn_tick]; without it, those four are ignored.
	static func write_header(bytes: PackedByteArray, server_tick: int, input_ack_tick: int,
			input_margin: int, substitutions: int, own_teleport: int,
			own_state_bytes: PackedByteArray, health: int = 0, max_health: int = 0,
			status: int = 0, respawn_tick: int = 0) -> int:
		var has_state: bool = own_state_bytes.size() == PlayerState.ENCODED_SIZE
		var extra_offset: int = 13 + PlayerState.ENCODED_SIZE
		var section_offset: int = 13
		if has_state:
			section_offset = extra_offset + SNAPSHOT_EXTRA_SIZE
		if bytes.size() < section_offset + 1:
			bytes.resize(section_offset + 1)
		bytes.encode_u8(0, NetProtocol.MSG_SNAPSHOT)
		bytes.encode_u32(1, server_tick & 0xFFFFFFFF)
		bytes.encode_u32(5, input_ack_tick & 0xFFFFFFFF)
		bytes.encode_s8(9, clampi(input_margin, -128, 127))
		bytes.encode_u16(10, substitutions & 0xFFFF)
		var flags: int = (own_teleport & TELEPORT_MASK) << TELEPORT_SHIFT
		if has_state:
			flags |= FLAG_OWN_STATE | FLAG_OWN_EXTRA
			for i: int in PlayerState.ENCODED_SIZE:
				bytes[13 + i] = own_state_bytes[i]
			bytes.encode_u16(extra_offset, clampi(health, 0, 0xFFFF))
			bytes.encode_u16(extra_offset + 2, clampi(max_health, 0, 0xFFFF))
			bytes.encode_u8(extra_offset + 4, status & 0xFF)
			bytes.encode_u32(extra_offset + 5, respawn_tick & 0xFFFFFFFF)
		bytes.encode_u8(12, flags)
		bytes.encode_u8(section_offset, 0)
		return section_offset


	## Groups [member records] by [code]kind[/code] (in order of appearance) into sections of at most 255
	## records. It does not limit the size: whoever builds it respects
	## [constant NetProtocol.MAX_PACKET_BYTES].
	func encode() -> PackedByteArray:
		var own_state_bytes: PackedByteArray = PackedByteArray()
		if own_state != null:
			own_state_bytes = own_state.encode()
		var by_kind: Dictionary = {}
		for record: EntityRecord in records:
			if not by_kind.has(record.kind):
				by_kind[record.kind] = []
			(by_kind[record.kind] as Array).append(record)
		var section_count: int = 0
		var total_size: int = SNAPSHOT_HEADER_SIZE_WITH_STATE \
				if own_state != null else SNAPSHOT_HEADER_SIZE
		for kind: int in by_kind:
			var group_size: int = (by_kind[kind] as Array).size()
			var group_sections: int = ceili(group_size / float(MAX_SECTION_RECORDS))
			section_count += group_sections
			total_size += 2 * group_sections + EntityRecord.SIZE * group_size
		var bytes := PackedByteArray()
		bytes.resize(total_size)
		var offset: int = write_header(bytes, server_tick, input_ack_tick, input_margin,
				substitutions, own_teleport, own_state_bytes, health, max_health, status,
				respawn_tick)
		bytes.encode_u8(offset, mini(section_count, 255))
		offset += 1
		for kind: int in by_kind:
			var group: Array = by_kind[kind]
			var written: int = 0
			while written < group.size():
				var chunk: int = mini(group.size() - written, MAX_SECTION_RECORDS)
				bytes.encode_u8(offset, kind & 0xFF)
				bytes.encode_u8(offset + 1, chunk)
				offset += 2
				for i: int in chunk:
					(group[written + i] as EntityRecord).encode_into(bytes, offset)
					offset += EntityRecord.SIZE
				written += chunk
		return bytes


	## Returns null if the size does not match, if bit 3 of the flags (extra block) does not match
	## bit 0 (own state) or if the health is greater than the maximum.
	static func decode(bytes: PackedByteArray) -> Snapshot:
		var size: int = bytes.size()
		if size < SNAPSHOT_HEADER_SIZE or bytes[0] != NetProtocol.MSG_SNAPSHOT:
			return null
		var flags: int = bytes.decode_u8(12)
		var has_state: bool = (flags & FLAG_OWN_STATE) != 0
		if has_state != ((flags & FLAG_OWN_EXTRA) != 0):
			return null
		var offset: int = 13
		var state: PlayerState = null
		var snapshot := Snapshot.new()
		if has_state:
			if size < SNAPSHOT_HEADER_SIZE_WITH_STATE:
				return null
			state = PlayerState.decode(bytes.slice(13, 13 + PlayerState.ENCODED_SIZE))
			offset += PlayerState.ENCODED_SIZE
			snapshot.health = bytes.decode_u16(offset)
			snapshot.max_health = bytes.decode_u16(offset + 2)
			snapshot.status = bytes.decode_u8(offset + 4)
			snapshot.respawn_tick = bytes.decode_u32(offset + 5)
			if snapshot.health > snapshot.max_health:
				return null
			offset += SNAPSHOT_EXTRA_SIZE
		var section_count: int = bytes.decode_u8(offset)
		offset += 1
		snapshot.server_tick = bytes.decode_u32(1)
		snapshot.input_ack_tick = bytes.decode_u32(5)
		snapshot.input_margin = bytes.decode_s8(9)
		snapshot.substitutions = bytes.decode_u16(10)
		snapshot.own_teleport = (flags >> TELEPORT_SHIFT) & TELEPORT_MASK
		snapshot.own_state = state
		for _section: int in section_count:
			if offset + 2 > size:
				return null
			var kind: int = bytes[offset]
			var count: int = bytes[offset + 1]
			offset += 2
			if kind != NetProtocol.EntityKind.PLAYER and kind != NetProtocol.EntityKind.NPC:
				return null
			if offset + count * EntityRecord.SIZE > size:
				return null
			for _i: int in count:
				snapshot.records.append(EntityRecord.decode_from(bytes, offset, kind))
				offset += EntityRecord.SIZE
		if offset != size:
			return null
		return snapshot


## ENTITY_SPAWN (S→C, channel 3): 10 B + data depending on the entity type ([member kind]):
## [br]- [code]PLAYER[/code]: its [PlayerState] ([constant PlayerState.ENCODED_SIZE] B, the state after
## [member spawn_tick]), a `u8` with the name length, the name (up to 48 B) and, since protocol 7
## (docs/progresion.md §7.3), [constant NetMessages.PLAYER_SPAWN_TAIL_SIZE] B: the [code]u8 level[/code]
## ([member level]: 0 if the receiver is not of its realm) and the 8 B of [CharacterAppearance]
## ([member appearance]). [method decode] only checks its size and that the level does not exceed the cap; the validity of the
## appearance is checked by whoever draws it (an invalid one is replaced by the race's default).
## [br]- [code]NPC[/code]: the same as a player without the level or appearance and, after the name, a
## [code]u16 npc_def_id[/code] ([member npc_def_id]).
## [br]- [code]STRUCTURE[/code]: [code]u8 def_len[/code], the definition id in ASCII
## ([member definition_id]), [code]u8 field_count[/code] and the complete fields ([member fields]); it
## carries no player state or name. Without repeating type, net_id or tick: they are those of the header.
## [br]- [code]PROJECTILE[/code] (protocol 6; docs/habilidades.md, section 5.3): 22 B after the header,
## [constant PROJECTILE_SIZE] in total: [code]u16 owner, u16 projectile_def_id, u16 source, u8
## volley_index, u8 proj_flags, u64 position, s16 × 3 velocity[/code]. [member net_id] is the
## projectile's, [member realm] the shooter's and [member spawn_tick] the tick of the shot. The header
## flags go to 0: [member is_yours] never (an arrow is "yours" if [member owner_id] is your
## [code]net_id[/code]) and no teleport counter (a projectile does not teleport). The position
## ([member origin]) is packed as in the entity record (1 cm) and the velocity
## ([member velocity]) in cm/s: the same as [method Ballistics.quantize].
class EntitySpawn:
	## Bytes of a projectile ENTITY_SPAWN: the header and its 22 B.
	const PROJECTILE_SIZE: int = SPAWN_HEADER_SIZE + 22
	## Bit 0 of [member projectile_flags]: the arrow is harmless (it flies and collides with the world, but does not
	## test characters). The remaining bits go to 0.
	const PROJECTILE_FLAG_HARMLESS: int = 1 << 0
	## Bits of [member projectile_flags] that exist.
	const PROJECTILE_FLAGS_VALID: int = PROJECTILE_FLAG_HARMLESS

	var net_id: int = 0
	var kind: int = NetProtocol.EntityKind.PLAYER
	var spawn_tick: int = 0
	var realm: int = NetProtocol.Realm.NONE
	## Bit 0 of the flags: it is the client's own character.
	var is_yours: bool = false
	## Teleport counter (mod 4).
	var teleport_counter: int = 0
	## Bit 3 of the flags ([constant NetMessages.SPAWN_FLAG_STAFF], protocol 7): game staff. Only on
	## players and NPCs.
	var is_staff: bool = false
	var state: PlayerState = null
	var display_name: String = ""
	## NPC: id of its definition in the NPC catalog ([code]NpcCatalog[/code], ids 1..n in alphabetical
	## order; 0 = no definition). Comes after the name.
	var npc_def_id: int = 0
	## PLAYER (protocol 7): character level, from 1 to [constant ProgressMessages.MAX_LEVEL]; 0 if the
	## receiver is not of its realm (the enemy's level does not cross over) or it is not known. Saturates to the cap when encoding.
	var level: int = 0
	## PLAYER (protocol 7): the 8 B of [CharacterAppearance], unvalidated. Any other size is encoded as 8 B at 0
	## (no appearance: the client uses the default one for its realm's race).
	var appearance: PackedByteArray = PackedByteArray()
	## STRUCTURE: ASCII id of the definition (for example [code]vado_gris_fort[/code]), from 1 to
	## [constant NetProtocol.MAX_DEFINITION_ID_BYTES] characters.
	var definition_id: String = ""
	## STRUCTURE: the object's complete fields (from 1 to [constant NetMessages.MAX_OBJECT_FIELDS]).
	var fields: Array[ObjectField] = []
	## PROJECTILE: [code]net_id[/code] of the shooter.
	var owner_id: int = 0
	## PROJECTILE: id of its [ProjectileDefinition] in the combat catalog.
	var projectile_def_id: int = 0
	## PROJECTILE: source of the attack or ability that fired it ([CombatSource]).
	var source: int = 0
	## PROJECTILE: position within the shot (0 to n − 1; the fan releases several at once).
	var volley_index: int = 0
	## PROJECTILE: combination of the [code]PROJECTILE_FLAG_*[/code].
	var projectile_flags: int = 0
	## PROJECTILE: origin of the flight ([code]p0[/code] of [method Ballistics.position]); quantized to 1 cm.
	var origin: Vector3 = Vector3.ZERO
	## PROJECTILE: launch velocity ([code]v0[/code], m/s); quantized to 1 cm/s.
	var velocity: Vector3 = Vector3.ZERO


	## SPAWN of the fortress [param net_id] with the full [param state]: type STRUCTURE, realm 0 (the
	## [code]owner[/code] field decides) and all the fields of [FortressFields].
	static func for_fortress(net_id: int, spawn_tick: int, definition_id: String,
			state: FortressState) -> EntitySpawn:
		var spawn := EntitySpawn.new()
		spawn.net_id = net_id
		spawn.kind = NetProtocol.EntityKind.STRUCTURE
		spawn.spawn_tick = spawn_tick
		spawn.definition_id = definition_id
		spawn.fields = ObjectState.from_fortress(net_id, spawn_tick, state).fields
		return spawn


	## SPAWN of the projectile [param net_id] fired at [param spawn_tick] by [param shooter_id] (of realm
	## [param shooter_realm]) from [param p0] with velocity [param v0]. [param p0] and [param v0] should
	## already come from [method Ballistics.quantize] (the server flies with what travels), although the message
	## quantizes them anyway.
	static func for_projectile(net_id: int, spawn_tick: int, shooter_realm: int, shooter_id: int,
			definition: int, source_of_shot: int, index_in_volley: int, harmless: bool, p0: Vector3,
			v0: Vector3) -> EntitySpawn:
		var spawn := EntitySpawn.new()
		spawn.net_id = net_id
		spawn.kind = NetProtocol.EntityKind.PROJECTILE
		spawn.spawn_tick = spawn_tick
		spawn.realm = shooter_realm
		spawn.owner_id = shooter_id
		spawn.projectile_def_id = definition
		spawn.source = source_of_shot
		spawn.volley_index = index_in_volley
		spawn.projectile_flags = PROJECTILE_FLAG_HARMLESS if harmless else 0
		spawn.origin = p0
		spawn.velocity = v0
		return spawn


	## true if it is a harmless projectile (bit [constant PROJECTILE_FLAG_HARMLESS]).
	func is_harmless() -> bool:
		return (projectile_flags & PROJECTILE_FLAG_HARMLESS) != 0


	## The fields of a structure SPAWN as an [ObjectState] of the spawn tick, to apply them
	## the same way as those of an OBJECT_STATE.
	func to_object_state() -> ObjectState:
		var object_state := ObjectState.new()
		object_state.net_id = net_id
		object_state.tick = spawn_tick
		object_state.fields = fields.duplicate()
		return object_state


	## An empty buffer if [member kind] is not player, NPC, projectile or structure, or if a structure does not
	## have a valid definition id or writable fields.
	func encode() -> PackedByteArray:
		if kind == NetProtocol.EntityKind.STRUCTURE:
			return _encode_structure()
		if kind == NetProtocol.EntityKind.PROJECTILE:
			return _encode_projectile()
		if kind != NetProtocol.EntityKind.PLAYER and kind != NetProtocol.EntityKind.NPC:
			return PackedByteArray()
		var state_bytes: PackedByteArray = (state if state != null else PlayerState.new()).encode()
		var name_bytes: PackedByteArray = NetMessages.utf8_limited(display_name,
				NetProtocol.MAX_NAME_BYTES)
		var bytes := PackedByteArray()
		var name_offset: int = SPAWN_HEADER_SIZE + PlayerState.ENCODED_SIZE
		var tail_size: int = _tail_size(kind)
		bytes.resize(name_offset + 1 + name_bytes.size() + tail_size)
		bytes.encode_u8(0, NetProtocol.MSG_ENTITY_SPAWN)
		bytes.encode_u16(1, net_id & 0xFFFF)
		bytes.encode_u8(3, kind)
		bytes.encode_u32(4, spawn_tick & 0xFFFFFFFF)
		bytes.encode_u8(8, realm & 0xFF)
		var flags: int = (teleport_counter & TELEPORT_MASK) << TELEPORT_SHIFT
		if is_yours:
			flags |= 1
		if is_staff:
			flags |= SPAWN_FLAG_STAFF
		bytes.encode_u8(9, flags)
		for i: int in PlayerState.ENCODED_SIZE:
			bytes[SPAWN_HEADER_SIZE + i] = state_bytes[i]
		bytes.encode_u8(name_offset, name_bytes.size())
		for i: int in name_bytes.size():
			bytes[name_offset + 1 + i] = name_bytes[i]
		var tail_offset: int = name_offset + 1 + name_bytes.size()
		if kind == NetProtocol.EntityKind.NPC:
			bytes.encode_u16(tail_offset, npc_def_id & 0xFFFF)
		else:
			bytes.encode_u8(tail_offset, clampi(level, 0, ProgressMessages.MAX_LEVEL))
			if appearance.size() == CharacterAppearance.ENCODED_SIZE:
				for i: int in CharacterAppearance.ENCODED_SIZE:
					bytes[tail_offset + 1 + i] = appearance[i]
		return bytes


	## Returns null if the type has no format, if the size does not match the one the
	## lengths state, if a text is not valid, if a player carries a level above the cap or, in a
	## structure, if the definition id is not
	## ASCII of 1 to 32 B, the field counter is not between 1 and 32, a field has an unknown
	## value type or an id is repeated. A projectile, if it does not take exactly [constant PROJECTILE_SIZE] B,
	## carries any flag in the header (the [code]is_yours[/code] bit or a teleport counter) or a bit
	## of [code]proj_flags[/code] that does not exist.
	static func decode(bytes: PackedByteArray) -> EntitySpawn:
		var size: int = bytes.size()
		var name_offset: int = SPAWN_HEADER_SIZE + PlayerState.ENCODED_SIZE
		if size >= SPAWN_HEADER_SIZE and bytes[0] == NetProtocol.MSG_ENTITY_SPAWN \
				and bytes[3] == NetProtocol.EntityKind.STRUCTURE:
			return _decode_structure(bytes)
		if size >= SPAWN_HEADER_SIZE and bytes[0] == NetProtocol.MSG_ENTITY_SPAWN \
				and bytes[3] == NetProtocol.EntityKind.PROJECTILE:
			return _decode_projectile(bytes)
		if size < name_offset + 1 or bytes[0] != NetProtocol.MSG_ENTITY_SPAWN:
			return null
		var kind_code: int = bytes[3]
		if kind_code != NetProtocol.EntityKind.PLAYER and kind_code != NetProtocol.EntityKind.NPC:
			return null
		var name_len: int = bytes[name_offset]
		var tail_size: int = _tail_size(kind_code)
		if name_len > NetProtocol.MAX_NAME_BYTES or size != name_offset + 1 + name_len + tail_size:
			return null
		if not NetMessages.is_valid_utf8(bytes, name_offset + 1, name_len):
			return null
		var spawn := EntitySpawn.new()
		spawn.net_id = bytes.decode_u16(1)
		spawn.kind = kind_code
		spawn.spawn_tick = bytes.decode_u32(4)
		spawn.realm = bytes[8]
		var flags: int = bytes[9]
		spawn.is_yours = (flags & 1) != 0
		spawn.teleport_counter = (flags >> TELEPORT_SHIFT) & TELEPORT_MASK
		spawn.is_staff = (flags & SPAWN_FLAG_STAFF) != 0
		spawn.state = PlayerState.decode(
				bytes.slice(SPAWN_HEADER_SIZE, name_offset))
		spawn.display_name = NetMessages.read_text(bytes, name_offset + 1, name_len)
		var tail_offset: int = name_offset + 1 + name_len
		if kind_code == NetProtocol.EntityKind.NPC:
			spawn.npc_def_id = bytes.decode_u16(tail_offset)
		else:
			spawn.level = bytes[tail_offset]
			if spawn.level > ProgressMessages.MAX_LEVEL:
				return null
			spawn.appearance = bytes.slice(tail_offset + 1, tail_offset + 1 + CharacterAppearance.ENCODED_SIZE)
		return spawn


	# Bytes after the name: an NPC's definition id and, since protocol 7, a player's level and
	# appearance.
	static func _tail_size(entity_kind: int) -> int:
		if entity_kind == NetProtocol.EntityKind.NPC:
			return NetMessages.NPC_SPAWN_TAIL_SIZE
		return NetMessages.PLAYER_SPAWN_TAIL_SIZE


	# STRUCTURE: u8 def_len, ASCII id, u8 field_count and the fields, after the header.
	func _encode_structure() -> PackedByteArray:
		if definition_id.is_empty() or definition_id.length() > NetProtocol.MAX_DEFINITION_ID_BYTES \
				or not NetMessages.is_printable_ascii_text(definition_id) \
				or not NetMessages.are_fields_encodable(fields):
			return PackedByteArray()
		var definition_bytes: PackedByteArray = definition_id.to_ascii_buffer()
		var bytes := PackedByteArray()
		var fields_offset: int = SPAWN_HEADER_SIZE + 2 + definition_bytes.size()
		bytes.resize(fields_offset + NetMessages.fields_size(fields))
		bytes.encode_u8(0, NetProtocol.MSG_ENTITY_SPAWN)
		bytes.encode_u16(1, net_id & 0xFFFF)
		bytes.encode_u8(3, kind)
		bytes.encode_u32(4, spawn_tick & 0xFFFFFFFF)
		bytes.encode_u8(8, realm & 0xFF)
		var flags: int = (teleport_counter & TELEPORT_MASK) << TELEPORT_SHIFT
		if is_yours:
			flags |= 1
		bytes.encode_u8(9, flags)
		bytes.encode_u8(SPAWN_HEADER_SIZE, definition_bytes.size())
		for i: int in definition_bytes.size():
			bytes[SPAWN_HEADER_SIZE + 1 + i] = definition_bytes[i]
		bytes.encode_u8(fields_offset - 1, fields.size())
		NetMessages.write_fields(bytes, fields_offset, fields)
		return bytes


	# PROJECTILE: 22 B after the header; the header flags at 0 (neither is_yours nor teleport).
	func _encode_projectile() -> PackedByteArray:
		var bytes := PackedByteArray()
		bytes.resize(PROJECTILE_SIZE)
		bytes.encode_u8(0, NetProtocol.MSG_ENTITY_SPAWN)
		bytes.encode_u16(1, net_id & 0xFFFF)
		bytes.encode_u8(3, kind)
		bytes.encode_u32(4, spawn_tick & 0xFFFFFFFF)
		bytes.encode_u8(8, realm & 0xFF)
		bytes.encode_u8(9, 0)
		bytes.encode_u16(10, owner_id & 0xFFFF)
		bytes.encode_u16(12, projectile_def_id & 0xFFFF)
		bytes.encode_u16(14, source & 0xFFFF)
		bytes.encode_u8(16, volley_index & 0xFF)
		bytes.encode_u8(17, projectile_flags & PROJECTILE_FLAGS_VALID)
		bytes.encode_u64(18, NetMath.pack_position(origin))
		bytes.encode_s16(26, NetMath.quantize_velocity(velocity.x))
		bytes.encode_s16(28, NetMath.quantize_velocity(velocity.y))
		bytes.encode_s16(30, NetMath.quantize_velocity(velocity.z))
		return bytes


	static func _decode_projectile(bytes: PackedByteArray) -> EntitySpawn:
		if bytes.size() != PROJECTILE_SIZE:
			return null
		var flags_of_projectile: int = bytes[17]
		if bytes[9] != 0 or (flags_of_projectile & ~PROJECTILE_FLAGS_VALID) != 0:
			return null
		var spawn := EntitySpawn.new()
		spawn.net_id = bytes.decode_u16(1)
		spawn.kind = NetProtocol.EntityKind.PROJECTILE
		spawn.spawn_tick = bytes.decode_u32(4)
		spawn.realm = bytes[8]
		spawn.is_yours = false
		spawn.owner_id = bytes.decode_u16(10)
		spawn.projectile_def_id = bytes.decode_u16(12)
		spawn.source = bytes.decode_u16(14)
		spawn.volley_index = bytes[16]
		spawn.projectile_flags = flags_of_projectile
		spawn.origin = NetMath.unpack_position(bytes.decode_u64(18))
		spawn.velocity = Vector3(NetMath.dequantize_velocity(bytes.decode_s16(26)),
				NetMath.dequantize_velocity(bytes.decode_s16(28)),
				NetMath.dequantize_velocity(bytes.decode_s16(30)))
		return spawn


	static func _decode_structure(bytes: PackedByteArray) -> EntitySpawn:
		var size: int = bytes.size()
		if size < SPAWN_HEADER_SIZE + 1:
			return null
		var definition_len: int = bytes[SPAWN_HEADER_SIZE]
		var count_offset: int = SPAWN_HEADER_SIZE + 1 + definition_len
		if definition_len < 1 or definition_len > NetProtocol.MAX_DEFINITION_ID_BYTES \
				or size < count_offset + 1:
			return null
		if not NetMessages.is_printable_ascii(bytes, SPAWN_HEADER_SIZE + 1, definition_len):
			return null
		var field_count: int = bytes[count_offset]
		if field_count < 1 or field_count > NetMessages.MAX_OBJECT_FIELDS:
			return null
		var spawn := EntitySpawn.new()
		var end: int = NetMessages.read_fields(bytes, count_offset + 1, field_count, spawn.fields)
		if end != size:
			return null
		spawn.net_id = bytes.decode_u16(1)
		spawn.kind = NetProtocol.EntityKind.STRUCTURE
		spawn.spawn_tick = bytes.decode_u32(4)
		spawn.realm = bytes[8]
		var flags: int = bytes[9]
		spawn.is_yours = (flags & 1) != 0
		spawn.teleport_counter = (flags >> TELEPORT_SHIFT) & TELEPORT_MASK
		spawn.definition_id = NetMessages.read_text(bytes, SPAWN_HEADER_SIZE + 1, definition_len)
		return spawn


## ENTITY_DESPAWN (S→C, channel 3): 8 B.
class EntityDespawn:
	const SIZE: int = 8

	var net_id: int = 0
	## The client removes the entity when its `render_tick` reaches this tick.
	var despawn_tick: int = 0
	## [enum NetProtocol.DespawnReason].
	var reason: int = NetProtocol.DespawnReason.OUT_OF_INTEREST


	func encode() -> PackedByteArray:
		var bytes := PackedByteArray()
		bytes.resize(SIZE)
		bytes.encode_u8(0, NetProtocol.MSG_ENTITY_DESPAWN)
		bytes.encode_u16(1, net_id & 0xFFFF)
		bytes.encode_u32(3, despawn_tick & 0xFFFFFFFF)
		bytes.encode_u8(7, reason & 0xFF)
		return bytes


	static func decode(bytes: PackedByteArray) -> EntityDespawn:
		if bytes.size() != SIZE or bytes[0] != NetProtocol.MSG_ENTITY_DESPAWN:
			return null
		var despawn := EntityDespawn.new()
		despawn.net_id = bytes.decode_u16(1)
		despawn.despawn_tick = bytes.decode_u32(3)
		despawn.reason = bytes[7]
		return despawn


## NOTICE (S→C, channel 3): 3 B + text (up to 200 B).
class Notice:
	const MIN_SIZE: int = 3

	## [enum NetProtocol.NoticeCode].
	var code: int = NetProtocol.NoticeCode.INFO
	var text: String = ""


	func encode() -> PackedByteArray:
		var text_bytes: PackedByteArray = NetMessages.utf8_limited(text, MAX_NOTICE_BYTES)
		var bytes := PackedByteArray()
		bytes.resize(MIN_SIZE + text_bytes.size())
		bytes.encode_u8(0, NetProtocol.MSG_NOTICE)
		bytes.encode_u8(1, code & 0xFF)
		bytes.encode_u8(2, text_bytes.size())
		for i: int in text_bytes.size():
			bytes[3 + i] = text_bytes[i]
		return bytes


	static func decode(bytes: PackedByteArray) -> Notice:
		var size: int = bytes.size()
		if size < MIN_SIZE or bytes[0] != NetProtocol.MSG_NOTICE:
			return null
		var text_len: int = bytes[2]
		if text_len > MAX_NOTICE_BYTES or size != MIN_SIZE + text_len:
			return null
		if not NetMessages.is_valid_utf8(bytes, 3, text_len):
			return null
		var notice := Notice.new()
		notice.code = bytes[1]
		notice.text = NetMessages.read_text(bytes, 3, text_len)
		return notice


## CHAT_SEND (C→S, channel 3, protocol 5): 5 B + recipient + text (docs/social.md, section 12).
## The player wants to say something on a channel.
## [br][br]
## [code]u8 type, u8 channel, u8 recipient_len, u16 text_len[/code], the recipient (UTF-8, only in a
## whisper: the character's name as the player typed it) and the text (UTF-8). The text carries
## at most [constant ChatText.MAX_CHARS] characters and [constant ChatText.MAX_BYTES] B; the server
## sanitizes it ([ChatText]) before distributing it. A message, all told, takes at most 821 B.
## [br][br]
## [method decode] returns null if the size does not match, the channel does not exist or is the system one (which only the server
## sends), a whisper has no recipient or any other channel has one, any text is not
## valid UTF-8, the recipient exceeds [constant NetProtocol.MAX_NAME_CHARS] characters or the text exceeds
## [constant ChatText.MAX_CHARS]. An empty text does decode: it is the server that decides what to do.
class ChatSend:
	## Bytes of the header, before the recipient and the text.
	const HEADER_SIZE: int = 5

	## [enum ChatChannel.Id].
	var channel: int = ChatChannel.Id.SAY
	## Name of the recipient (only in a whisper; empty on other channels).
	var recipient: String = ""
	var text: String = ""


	## Texts are trimmed to their limits without splitting any character.
	func encode() -> PackedByteArray:
		var recipient_bytes: PackedByteArray = NetMessages.utf8_limited(
				recipient.substr(0, NetProtocol.MAX_NAME_CHARS), NetProtocol.MAX_NAME_BYTES)
		var text_bytes: PackedByteArray = NetMessages.utf8_limited(
				text.substr(0, ChatText.MAX_CHARS), ChatText.MAX_BYTES)
		var bytes := PackedByteArray()
		bytes.resize(HEADER_SIZE + recipient_bytes.size() + text_bytes.size())
		bytes.encode_u8(0, NetProtocol.MSG_CHAT_SEND)
		bytes.encode_u8(1, channel & 0xFF)
		bytes.encode_u8(2, recipient_bytes.size())
		bytes.encode_u16(3, text_bytes.size())
		for i: int in recipient_bytes.size():
			bytes[HEADER_SIZE + i] = recipient_bytes[i]
		var text_offset: int = HEADER_SIZE + recipient_bytes.size()
		for i: int in text_bytes.size():
			bytes[text_offset + i] = text_bytes[i]
		return bytes


	static func decode(bytes: PackedByteArray) -> ChatSend:
		var size: int = bytes.size()
		if size < HEADER_SIZE or bytes[0] != NetProtocol.MSG_CHAT_SEND:
			return null
		var channel_id: int = bytes[1]
		var recipient_len: int = bytes[2]
		var text_len: int = bytes.decode_u16(3)
		if not ChatChannel.is_client_sendable(channel_id):
			return null
		if recipient_len > NetProtocol.MAX_NAME_BYTES or text_len > ChatText.MAX_BYTES \
				or size != HEADER_SIZE + recipient_len + text_len:
			return null
		if (channel_id == ChatChannel.Id.WHISPER) != (recipient_len > 0):
			return null
		if not NetMessages.is_valid_utf8(bytes, HEADER_SIZE, recipient_len) \
				or not NetMessages.is_valid_utf8(bytes, HEADER_SIZE + recipient_len, text_len):
			return null
		var message := ChatSend.new()
		message.channel = channel_id
		message.recipient = NetMessages.read_text(bytes, HEADER_SIZE, recipient_len)
		message.text = NetMessages.read_text(bytes, HEADER_SIZE + recipient_len, text_len)
		if message.recipient.length() > NetProtocol.MAX_NAME_CHARS \
				or message.text.length() > ChatText.MAX_CHARS:
			return null
		# A name that reads as empty (only a UTF-8 BOM, which get_string_from_utf8 skips) is not a name.
		if channel_id == ChatChannel.Id.WHISPER and message.recipient.is_empty():
			return null
		return message


## CHAT_MESSAGE (S→C, channel 3, protocol 5): 11 B + sender + recipient + text (docs/social.md,
## section 12). A chat message already sanitized and distributed by the server, only to whoever should see it.
## [br][br]
## [code]u8 type, u8 channel, u8 sender_realm, u32 tick, u8 sender_len, u8 recipient_len, u16
## text_len[/code], the sender (UTF-8), the recipient (UTF-8, only in a whisper) and the text (UTF-8).
## [member tick] is the server tick when distributing it. In a whisper both receive it: the recipient
## reads it as a whisper from [member sender] and the sender as the copy of what they sent. The one on the
## system channel carries no sender. All told, it takes at most 875 B.
## [br][br]
## [method decode] returns null if the size does not match, the channel or realm does not exist, a
## system message carries a sender or recipient, another channel carries no sender, only a whisper carries a recipient, the
## text is not valid UTF-8 or exceeds [constant ChatText.MAX_CHARS] characters.
class ChatMessage:
	## Bytes of the header, before the names and the text.
	const HEADER_SIZE: int = 11

	## [enum ChatChannel.Id].
	var channel: int = ChatChannel.Id.SAY
	## Realm of the sender ([enum NetProtocol.Realm]); 0 in system messages.
	var sender_realm: int = NetProtocol.Realm.NONE
	## Server tick when distributing it.
	var tick: int = 0
	## Name of the sender (empty on the system channel).
	var sender: String = ""
	## Name of the recipient (only in a whisper).
	var recipient: String = ""
	var text: String = ""


	func encode() -> PackedByteArray:
		var sender_bytes: PackedByteArray = NetMessages.utf8_limited(sender, NetProtocol.MAX_NAME_BYTES)
		var recipient_bytes: PackedByteArray = NetMessages.utf8_limited(recipient,
				NetProtocol.MAX_NAME_BYTES)
		var text_bytes: PackedByteArray = NetMessages.utf8_limited(
				text.substr(0, ChatText.MAX_CHARS), ChatText.MAX_BYTES)
		var bytes := PackedByteArray()
		bytes.resize(HEADER_SIZE + sender_bytes.size() + recipient_bytes.size() + text_bytes.size())
		bytes.encode_u8(0, NetProtocol.MSG_CHAT_MESSAGE)
		bytes.encode_u8(1, channel & 0xFF)
		bytes.encode_u8(2, sender_realm & 0xFF)
		bytes.encode_u32(3, tick & 0xFFFFFFFF)
		bytes.encode_u8(7, sender_bytes.size())
		bytes.encode_u8(8, recipient_bytes.size())
		bytes.encode_u16(9, text_bytes.size())
		var offset: int = HEADER_SIZE
		for part: PackedByteArray in [sender_bytes, recipient_bytes, text_bytes]:
			for i: int in part.size():
				bytes[offset + i] = part[i]
			offset += part.size()
		return bytes


	static func decode(bytes: PackedByteArray) -> ChatMessage:
		var size: int = bytes.size()
		if size < HEADER_SIZE or bytes[0] != NetProtocol.MSG_CHAT_MESSAGE:
			return null
		var channel_id: int = bytes[1]
		var realm: int = bytes[2]
		var sender_len: int = bytes[7]
		var recipient_len: int = bytes[8]
		var text_len: int = bytes.decode_u16(9)
		if not ChatChannel.is_valid(channel_id) or realm > NetProtocol.Realm.ASKARRA:
			return null
		if sender_len > NetProtocol.MAX_NAME_BYTES or recipient_len > NetProtocol.MAX_NAME_BYTES \
				or text_len > ChatText.MAX_BYTES \
				or size != HEADER_SIZE + sender_len + recipient_len + text_len:
			return null
		if (channel_id == ChatChannel.Id.SYSTEM) != (sender_len == 0):
			return null
		if (channel_id == ChatChannel.Id.WHISPER) != (recipient_len > 0):
			return null
		var recipient_offset: int = HEADER_SIZE + sender_len
		var text_offset: int = recipient_offset + recipient_len
		if not NetMessages.is_valid_utf8(bytes, HEADER_SIZE, sender_len) \
				or not NetMessages.is_valid_utf8(bytes, recipient_offset, recipient_len) \
				or not NetMessages.is_valid_utf8(bytes, text_offset, text_len):
			return null
		var message := ChatMessage.new()
		message.channel = channel_id
		message.sender_realm = realm
		message.tick = bytes.decode_u32(3)
		message.sender = NetMessages.read_text(bytes, HEADER_SIZE, sender_len)
		message.recipient = NetMessages.read_text(bytes, recipient_offset, recipient_len)
		message.text = NetMessages.read_text(bytes, text_offset, text_len)
		if message.text.length() > ChatText.MAX_CHARS:
			return null
		if (channel_id != ChatChannel.Id.SYSTEM and message.sender.is_empty()) \
				or (channel_id == ChatChannel.Id.WHISPER and message.recipient.is_empty()):
			return null
		return message


## PARTY_INVITE, PARTY_KICK and PARTY_LEADER (C→S, channel 3, protocol 5): 2 B + name. They ask the server to
## invite a player of your realm, kick a party member or hand them the leadership
## (docs/social.md, section 12.4).
## [br][br]
## [code]u8 type, u8 name_len[/code] and the player's name (UTF-8, from 1 to [constant NetProtocol.MAX_NAME_BYTES]
## B and [constant NetProtocol.MAX_NAME_CHARS] characters), as typed by the sender: the server
## looks it up ignoring case and accents. [member type] is the message type.
## [br][br]
## [method decode] returns null if the type is not one of the three, the size does not match, the name is empty
## or too long, or is not valid UTF-8.
class PartyTargetRequest:
	const HEADER_SIZE: int = 2

	## [constant NetProtocol.MSG_PARTY_INVITE], [constant NetProtocol.MSG_PARTY_KICK] or
	## [constant NetProtocol.MSG_PARTY_LEADER].
	var type: int = NetProtocol.MSG_PARTY_INVITE
	var target: String = ""


	static func make(message_type: int, target_name: String) -> PartyTargetRequest:
		var request := PartyTargetRequest.new()
		request.type = message_type
		request.target = target_name
		return request


	static func is_request_type(message_type: int) -> bool:
		return message_type == NetProtocol.MSG_PARTY_INVITE or message_type == NetProtocol.MSG_PARTY_KICK \
				or message_type == NetProtocol.MSG_PARTY_LEADER


	func encode() -> PackedByteArray:
		var name_bytes: PackedByteArray = NetMessages.utf8_limited(
				target.substr(0, NetProtocol.MAX_NAME_CHARS), NetProtocol.MAX_NAME_BYTES)
		var bytes := PackedByteArray()
		bytes.resize(HEADER_SIZE + name_bytes.size())
		bytes.encode_u8(0, type & 0xFF)
		bytes.encode_u8(1, name_bytes.size())
		for i: int in name_bytes.size():
			bytes[HEADER_SIZE + i] = name_bytes[i]
		return bytes


	static func decode(bytes: PackedByteArray) -> PartyTargetRequest:
		var size: int = bytes.size()
		if size < HEADER_SIZE or not is_request_type(bytes[0]):
			return null
		var name_len: int = bytes[1]
		if name_len < 1 or name_len > NetProtocol.MAX_NAME_BYTES or size != HEADER_SIZE + name_len:
			return null
		if not NetMessages.is_valid_utf8(bytes, HEADER_SIZE, name_len):
			return null
		var request := PartyTargetRequest.new()
		request.type = bytes[0]
		request.target = NetMessages.read_text(bytes, HEADER_SIZE, name_len)
		if request.target.is_empty() or request.target.length() > NetProtocol.MAX_NAME_CHARS:
			return null
		return request


## PARTY_RESPONSE (C→S, channel 3, protocol 5): 3 B + name. Accepts or declines the invitation from [member
## inviter] (docs/social.md, section 12.4).
## [br][br]
## [code]u8 type, u8 accept, u8 name_len[/code] and the name of whoever invited. [member accept] is 1 (accept) or 0
## (decline). [method decode] returns null if the size does not match, [code]accept[/code] is neither 0 nor 1, the name
## is empty or too long, or is not valid UTF-8.
class PartyResponse:
	const HEADER_SIZE: int = 3

	var accept: bool = false
	var inviter: String = ""


	func encode() -> PackedByteArray:
		var name_bytes: PackedByteArray = NetMessages.utf8_limited(
				inviter.substr(0, NetProtocol.MAX_NAME_CHARS), NetProtocol.MAX_NAME_BYTES)
		var bytes := PackedByteArray()
		bytes.resize(HEADER_SIZE + name_bytes.size())
		bytes.encode_u8(0, NetProtocol.MSG_PARTY_RESPONSE)
		bytes.encode_u8(1, 1 if accept else 0)
		bytes.encode_u8(2, name_bytes.size())
		for i: int in name_bytes.size():
			bytes[HEADER_SIZE + i] = name_bytes[i]
		return bytes


	static func decode(bytes: PackedByteArray) -> PartyResponse:
		var size: int = bytes.size()
		if size < HEADER_SIZE or bytes[0] != NetProtocol.MSG_PARTY_RESPONSE or bytes[1] > 1:
			return null
		var name_len: int = bytes[2]
		if name_len < 1 or name_len > NetProtocol.MAX_NAME_BYTES or size != HEADER_SIZE + name_len:
			return null
		if not NetMessages.is_valid_utf8(bytes, HEADER_SIZE, name_len):
			return null
		var response := PartyResponse.new()
		response.accept = bytes[1] == 1
		response.inviter = NetMessages.read_text(bytes, HEADER_SIZE, name_len)
		if response.inviter.is_empty() or response.inviter.length() > NetProtocol.MAX_NAME_CHARS:
			return null
		return response


## PARTY_LEAVE (C→S, channel 3, protocol 5): 1 B. The player leaves their party.
class PartyLeave:
	const SIZE: int = 1


	func encode() -> PackedByteArray:
		return PackedByteArray([NetProtocol.MSG_PARTY_LEAVE])


	static func decode(bytes: PackedByteArray) -> PartyLeave:
		if bytes.size() != SIZE or bytes[0] != NetProtocol.MSG_PARTY_LEAVE:
			return null
		return PartyLeave.new()


## PARTY_INVITATION (S→C, channel 3, protocol 5): 7 B + name. An invitation to [member inviter]'s party:
## newly received, expired or canceled (docs/social.md, section 12.4).
## [br][br]
## [code]u8 type, u8 state, u32 tick, u8 name_len[/code] and the canonical name of whoever invited. With
## [constant State.OFFERED], [member tick] is the server tick at which it expires; with the other states,
## the one at which it stopped being valid. The client shows the notice with accept and decline while it is valid and removes it with
## [constant State.EXPIRED] or [constant State.CANCELLED].
## [br][br]
## [method decode] returns null if the size does not match, the state does not exist or the name is empty, too
## long or not valid UTF-8.
class PartyInvitation:
	const HEADER_SIZE: int = 7

	enum State {
		## New invitation: the notice is shown until [member tick].
		OFFERED = 0,
		## It has expired (60 s without a response).
		EXPIRED = 1,
		## It is no longer valid: it was answered, or whoever invited left or disconnected.
		CANCELLED = 2,
	}

	var state: int = State.OFFERED
	var tick: int = 0
	var inviter: String = ""


	func encode() -> PackedByteArray:
		var name_bytes: PackedByteArray = NetMessages.utf8_limited(inviter, NetProtocol.MAX_NAME_BYTES)
		var bytes := PackedByteArray()
		bytes.resize(HEADER_SIZE + name_bytes.size())
		bytes.encode_u8(0, NetProtocol.MSG_PARTY_INVITATION)
		bytes.encode_u8(1, state & 0xFF)
		bytes.encode_u32(2, tick & 0xFFFFFFFF)
		bytes.encode_u8(6, name_bytes.size())
		for i: int in name_bytes.size():
			bytes[HEADER_SIZE + i] = name_bytes[i]
		return bytes


	static func decode(bytes: PackedByteArray) -> PartyInvitation:
		var size: int = bytes.size()
		if size < HEADER_SIZE or bytes[0] != NetProtocol.MSG_PARTY_INVITATION or bytes[1] > State.CANCELLED:
			return null
		var name_len: int = bytes[6]
		if name_len < 1 or name_len > NetProtocol.MAX_NAME_BYTES or size != HEADER_SIZE + name_len:
			return null
		if not NetMessages.is_valid_utf8(bytes, HEADER_SIZE, name_len):
			return null
		var invitation := PartyInvitation.new()
		invitation.state = bytes[1]
		invitation.tick = bytes.decode_u32(2)
		invitation.inviter = NetMessages.read_text(bytes, HEADER_SIZE, name_len)
		if invitation.inviter.is_empty():
			return null
		return invitation


## PARTY_ROSTER (S→C, channel 3, protocol 5): 3 B + 3 B and name per member (≤ 258 B). The list of members of the
## player's party, in the order they joined, with who holds the lead; the server sends it every time
## it changes (someone joins or leaves, the leader changes) and, with [member members] empty, when the player is no longer
## in a party (docs/social.md, section 12.4).
## [br][br]
## [code]u8 type, u8 count, u8 leader_index[/code] (from 0 to [constant NetProtocol.PARTY_MAX_SIZE]) and, per
## member, [code]u16 net_id, u8 name_len[/code] and the name (UTF-8). [member leader_index] is the position of the
## leader in the list (0 if there is no party).
## [br][br]
## [method decode] returns null if the size does not match, there are more than [constant NetProtocol.PARTY_MAX_SIZE]
## members, the leader is not one of them, a name is empty or too long or not valid UTF-8, or a
## net_id is repeated.
class PartyRoster:
	const HEADER_SIZE: int = 3
	const MEMBER_HEADER_SIZE: int = 3

	## A member: their network id and name.
	class Member:
		var net_id: int = 0
		var display_name: String = ""

		static func make(player_id: int, player_name: String) -> Member:
			var member := Member.new()
			member.net_id = player_id
			member.display_name = player_name
			return member

	var leader_index: int = 0
	var members: Array[Member] = []


	func is_empty() -> bool:
		return members.is_empty()


	## net_id of the leader (0 if there is no party).
	func get_leader_id() -> int:
		if leader_index < 0 or leader_index >= members.size():
			return 0
		return members[leader_index].net_id


	func encode() -> PackedByteArray:
		var count: int = mini(members.size(), NetProtocol.PARTY_MAX_SIZE)
		var bytes := PackedByteArray()
		bytes.resize(HEADER_SIZE)
		bytes.encode_u8(0, NetProtocol.MSG_PARTY_ROSTER)
		bytes.encode_u8(1, count)
		bytes.encode_u8(2, leader_index & 0xFF)
		for i: int in count:
			var member: Member = members[i]
			var name_bytes: PackedByteArray = NetMessages.utf8_limited(member.display_name,
					NetProtocol.MAX_NAME_BYTES)
			var offset: int = bytes.size()
			bytes.resize(offset + MEMBER_HEADER_SIZE + name_bytes.size())
			bytes.encode_u16(offset, member.net_id & 0xFFFF)
			bytes.encode_u8(offset + 2, name_bytes.size())
			for k: int in name_bytes.size():
				bytes[offset + MEMBER_HEADER_SIZE + k] = name_bytes[k]
		return bytes


	static func decode(bytes: PackedByteArray) -> PartyRoster:
		var size: int = bytes.size()
		if size < HEADER_SIZE or bytes[0] != NetProtocol.MSG_PARTY_ROSTER:
			return null
		var count: int = bytes[1]
		var leader: int = bytes[2]
		if count > NetProtocol.PARTY_MAX_SIZE or (count == 0 and leader != 0) \
				or (count > 0 and leader >= count):
			return null
		var roster := PartyRoster.new()
		roster.leader_index = leader
		var offset: int = HEADER_SIZE
		var seen: Dictionary = {}
		for _i: int in count:
			if offset + MEMBER_HEADER_SIZE > size:
				return null
			var net_id: int = bytes.decode_u16(offset)
			var name_len: int = bytes[offset + 2]
			if name_len < 1 or name_len > NetProtocol.MAX_NAME_BYTES \
					or offset + MEMBER_HEADER_SIZE + name_len > size or seen.has(net_id):
				return null
			if not NetMessages.is_valid_utf8(bytes, offset + MEMBER_HEADER_SIZE, name_len):
				return null
			seen[net_id] = true
			var member_name: String = NetMessages.read_text(bytes, offset + MEMBER_HEADER_SIZE, name_len)
			if member_name.is_empty():
				return null
			roster.members.append(Member.make(net_id, member_name))
			offset += MEMBER_HEADER_SIZE + name_len
		if offset != size:
			return null
		return roster


## PARTY_STATUS (S→C, channel 3, protocol 5): 2 B + 17 B per member (≤ 87 B). The compact state of the
## party members, which the server sends at 2 Hz to all members even if they are outside the others' radius of
## interest (docs/social.md, section 12.4; docs/red.md, section 9).
## [br][br]
## [code]u8 type, u8 count[/code] and, per member, [code]u16 net_id, u8 health_q, u8 stamina_q, u8 status, f32 x,
## f32 y, f32 z[/code]. [member MemberStatus.health_q] is the quantized health of the snapshot record
## ([method EntityRecord.quantize_health]: 0 dead, 1 to 255 alive), [member MemberStatus.stamina_q] the
## stamina in 255 steps and [member MemberStatus.status] the bits [constant STATUS_IN_COMBAT],
## [constant STATUS_PROTECTED], [constant STATUS_DEAD] and (protocol 6) [constant STATUS_DOWNED].
## [br][br]
## [method decode] returns null if the size does not match, there are more than [constant NetProtocol.PARTY_MAX_SIZE]
## members, a status bit is unknown, a position is not finite or a net_id is repeated.
class PartyStatus:
	const HEADER_SIZE: int = 2
	const MEMBER_SIZE: int = 17
	## Valid status bits.
	const VALID_STATUS: int = STATUS_IN_COMBAT | STATUS_PROTECTED | STATUS_DEAD | STATUS_DOWNED

	## The state of a member.
	class MemberStatus:
		var net_id: int = 0
		var health_q: int = 0
		var stamina_q: int = 0
		var status: int = 0
		var position: Vector3 = Vector3.ZERO

		static func make(player_id: int, quantized_health: int, quantized_stamina: int,
				status_bits: int, world_position: Vector3) -> MemberStatus:
			var member := MemberStatus.new()
			member.net_id = player_id
			member.health_q = quantized_health
			member.stamina_q = quantized_stamina
			member.status = status_bits
			member.position = world_position
			return member

		func is_dead() -> bool:
			return (status & STATUS_DEAD) != 0

		func is_downed() -> bool:
			return (status & STATUS_DOWNED) != 0

	var members: Array[MemberStatus] = []


	func encoded_size() -> int:
		return HEADER_SIZE + MEMBER_SIZE * mini(members.size(), NetProtocol.PARTY_MAX_SIZE)


	func encode() -> PackedByteArray:
		var count: int = mini(members.size(), NetProtocol.PARTY_MAX_SIZE)
		var bytes := PackedByteArray()
		bytes.resize(encoded_size())
		bytes.encode_u8(0, NetProtocol.MSG_PARTY_STATUS)
		bytes.encode_u8(1, count)
		for i: int in count:
			var member: MemberStatus = members[i]
			var offset: int = HEADER_SIZE + MEMBER_SIZE * i
			bytes.encode_u16(offset, member.net_id & 0xFFFF)
			bytes.encode_u8(offset + 2, clampi(member.health_q, 0, 255))
			bytes.encode_u8(offset + 3, clampi(member.stamina_q, 0, 255))
			bytes.encode_u8(offset + 4, member.status & VALID_STATUS)
			bytes.encode_float(offset + 5, member.position.x)
			bytes.encode_float(offset + 9, member.position.y)
			bytes.encode_float(offset + 13, member.position.z)
		return bytes


	static func decode(bytes: PackedByteArray) -> PartyStatus:
		var size: int = bytes.size()
		if size < HEADER_SIZE or bytes[0] != NetProtocol.MSG_PARTY_STATUS:
			return null
		var count: int = bytes[1]
		if count > NetProtocol.PARTY_MAX_SIZE or size != HEADER_SIZE + MEMBER_SIZE * count:
			return null
		var status := PartyStatus.new()
		var seen: Dictionary = {}
		for i: int in count:
			var offset: int = HEADER_SIZE + MEMBER_SIZE * i
			var net_id: int = bytes.decode_u16(offset)
			var status_bits: int = bytes[offset + 4]
			var position := Vector3(bytes.decode_float(offset + 5), bytes.decode_float(offset + 9),
					bytes.decode_float(offset + 13))
			if (status_bits & ~VALID_STATUS) != 0 or not position.is_finite() or seen.has(net_id):
				return null
			seen[net_id] = true
			status.members.append(MemberStatus.make(net_id, bytes[offset + 2], bytes[offset + 3],
					status_bits, position))
		return status


## OBJECT_STATE (S→C, channel 3): 8 B + fields (docs/fuerte.md, section 2). The replicated state of an
## object that is not a player or an NPC, today that of a fortress.
## [br][br]
## [code]u8 type, u16 net_id, u32 tick, u8 field_count[/code] (from 1 to 32) and, per field, [code]u8
## field_id, u8 value_type[/code] (1 u8, 2 u16, 3 u32, 4 s32) and the value ([ObjectField]). [member tick]
## is the server tick after which the state holds. A message carries only the fields that have
## changed; the full state travels in the structure's ENTITY_SPAWN.
## [br][br]
## [method decode] returns null if the size does not match, a [code]value_type[/code] is unknown, the
## counter is outside 1 to 32 or a field is repeated. An unknown [code]field_id[/code] with a valid
## type is kept: whoever interprets the object ([method apply_to_fortress]) skips it, so a
## newer server can add fields without breaking the client.
class ObjectState:
	## Network id of the structure.
	var net_id: int = 0
	## Server tick after which the state holds.
	var tick: int = 0
	var fields: Array[ObjectField] = []


	## State of the fortress [param state] with all its fields ([FortressFields.all_ids]).
	static func from_fortress(object_id: int, state_tick: int, state: FortressState) -> ObjectState:
		return from_fortress_fields(object_id, state_tick, state, FortressFields.all_ids())


	## State of the fortress [param state] with only the fields [param field_ids].
	static func from_fortress_fields(object_id: int, state_tick: int, state: FortressState,
			field_ids: PackedInt32Array) -> ObjectState:
		var object_state := ObjectState.new()
		object_state.net_id = object_id
		object_state.tick = state_tick
		for field_id: int in field_ids:
			if not FortressFields.is_known(field_id):
				continue
			object_state.fields.append(ObjectField.make(field_id,
					FortressFields.value_type(field_id), FortressFields.get_value(state, field_id)))
		return object_state


	## The fields of [param state] that have changed relative to [param previous]
	## ([method FortressState.changed_fields_since]). With no changes, [member fields] stays empty and
	## [method encode] returns an empty buffer: there is nothing to send.
	static func from_fortress_changes(object_id: int, state_tick: int, state: FortressState,
			previous: FortressState) -> ObjectState:
		return from_fortress_fields(object_id, state_tick, state,
				state.changed_fields_since(previous))


	func add_field(field_id: int, type: int, field_value: int) -> void:
		fields.append(ObjectField.make(field_id, type, field_value))


	## The field [param field_id], or null if the message does not carry it.
	func get_field(field_id: int) -> ObjectField:
		for field: ObjectField in fields:
			if field.field_id == field_id:
				return field
		return null


	func has_field(field_id: int) -> bool:
		return get_field(field_id) != null


	## Value of the field [param field_id], or [param default] if the message does not carry it.
	func get_value(field_id: int, default: int = 0) -> int:
		var field: ObjectField = get_field(field_id)
		return field.value if field != null else default


	## Applies the [FortressFields] fields that the message carries to [param state] and returns how many
	## it applied. Skips unknown ids (forward compatibility) and those that carry a different
	## value type than the field's.
	func apply_to_fortress(state: FortressState) -> int:
		var applied: int = 0
		for field: ObjectField in fields:
			if FortressFields.is_known(field.field_id) \
					and FortressFields.value_type(field.field_id) == field.value_type \
					and FortressFields.set_value(state, field.field_id, field.value):
				applied += 1
		return applied


	## true if all the known [FortressFields] fields carry the value type that
	## corresponds to them (unknown ones do not count).
	func is_valid_for_fortress() -> bool:
		for field: ObjectField in fields:
			if FortressFields.is_known(field.field_id) \
					and FortressFields.value_type(field.field_id) != field.value_type:
				return false
		return true


	## Bytes taken by the message.
	func encoded_size() -> int:
		return OBJECT_STATE_HEADER_SIZE + NetMessages.fields_size(fields)


	## An empty buffer if [member fields] cannot be written: no fields, more than 32, with an unknown
	## value type or with a repeated id.
	func encode() -> PackedByteArray:
		if not NetMessages.are_fields_encodable(fields):
			return PackedByteArray()
		var bytes := PackedByteArray()
		bytes.resize(encoded_size())
		bytes.encode_u8(0, NetProtocol.MSG_OBJECT_STATE)
		bytes.encode_u16(1, net_id & 0xFFFF)
		bytes.encode_u32(3, tick & 0xFFFFFFFF)
		bytes.encode_u8(7, fields.size())
		NetMessages.write_fields(bytes, OBJECT_STATE_HEADER_SIZE, fields)
		return bytes


	static func decode(bytes: PackedByteArray) -> ObjectState:
		var size: int = bytes.size()
		if size < OBJECT_STATE_HEADER_SIZE + ObjectField.HEADER_SIZE + 1 \
				or bytes[0] != NetProtocol.MSG_OBJECT_STATE:
			return null
		var field_count: int = bytes[7]
		if field_count < 1 or field_count > MAX_OBJECT_FIELDS:
			return null
		var object_state := ObjectState.new()
		var end: int = NetMessages.read_fields(bytes, OBJECT_STATE_HEADER_SIZE, field_count,
				object_state.fields)
		if end != size:
			return null
		object_state.net_id = bytes.decode_u16(1)
		object_state.tick = bytes.decode_u32(3)
		return object_state


## ENTITY_EVENT (S→C, channel 3): 9 B + data depending on the event (docs/combate.md, section 6).
## [br][br]
## [code]u8 type, u16 net_id, u32 tick, u8 event, u8 len[/code] and [code]len[/code] bytes of
## data. [member net_id] is the entity the event is attached to: the victim in HIT, DEATH and
## KILL, and the entity that respawns in RESPAWN. [member tick] is the server tick at which it
## happened.
## [br]- [code]HIT[/code] (17 B): [code]u16 attacker, u16 amount, u8 damage_type, u8 flags,
## u16 attack_id[/code]. The flags are the [code]HIT_FLAG_*[/code].
## [br]- [code]DEATH[/code] (13 B): [code]u16 killer, u16 attack_id[/code] (killer 0 = the
## environment).
## [br]- [code]KILL[/code] (14 + 2n B): [code]u16 killer, u16 attack_id, u8 n[/code] and
## [code]n × u16[/code] assistants.
## [br]- [code]RESPAWN[/code] (10 B): [code]u8 point[/code].
## [br]- [code]WAR[/code] (11 B, docs/fuerte.md section 5): [code]u8 war_event, u8 realm[/code].
## [member net_id] is the fortress; [member war_event] is an id from [WarEvents] and [member war_realm]
## the realm that accompanies it ([method FortressState.event_realm]). It goes to the whole zone and is applied on the
## draw tick.
## [br]- [code]TELEGRAPH[/code] (26 B): [code]u16 attack_id, u8 shape, u64 position, u16 yaw, u16
## radius_cm, u16 impact_in_ticks[/code]. [member net_id] is the NPC preparing the attack, [member
## shape] 0 circle or 1 sector, [member position] the origin (packed as in the entity
## record) and [member impact_in_ticks] the ticks remaining until the hit. It is a warning: it is applied on
## arrival.
## [br][br]
## Since protocol 6 (docs/habilidades.md, section 5.4) the [code]attack_id[/code] of HIT, DEATH, KILL and
## TELEGRAPH is a [b]source[/b] ([CombatSource]: kind in bits 14-15, id in 0-13; phase 3
## attacks keep their number), and there are five more events:
## [br]- [code]STATUS[/code] (18 B): [code]u16 source_entity, u8 op, u8 status_id, u8 stacks, u32
## until_tick[/code]. [member net_id] is the affected one, [member source_entity] whoever applied it (0 = no author),
## [member op] 1 applied or renewed and 2 removed ([enum StatusOp]) and [member until_tick] the end (exclusive).
## [br]- [code]HEAL[/code] (15 B): [code]u16 healer, u16 amount, u16 source[/code]. [member net_id] is the
## healed one, [member healer] whoever heals (0 = themselves) and the source goes in [member attack_id].
## [br]- [code]LOADOUT[/code] (15 B): [code]u8 template_id, u16 weapon_1, u16 weapon_2, u8 charges[/code].
## [member net_id] is the player; the weapons, in slot order (0 = none); [member charges], those of the
## two potions (bits 0-3 and 4-7; 0 for whoever is not the owner).
## [br]- [code]DOWNED[/code] (13 B): [code]u16 attacker, u16 source[/code]. [member net_id] is the knocked down one;
## the source goes in [member attack_id].
## [br]- [code]INTERACT[/code] (16 B): [code]u16 actor, u8 op, u32 end_tick[/code]. [member net_id] is the
## knocked down one, [member actor] whoever revives or executes them, [member op] one of [enum InteractOp] and
## [member end_tick] the tick at which it would end.
## [br][br]
## Since protocol 7 (docs/progresion.md §6.3): [code]LEVEL_UP[/code] (16; 10 B), [code]u8 level[/code] from 1
## to [constant ProgressMessages.MAX_LEVEL]. [member net_id] is whoever levels up; it goes to the owner and to those of their realm who
## find it relevant, for the visual effect (it does not reach the enemy). 16 leaves a gap for the phase 4 events.
## [br][br]
## With [method hit], [method death], [method kill], [method respawn], [method war], [method telegraph],
## [method status], [method heal], [method loadout], [method downed], [method interact] and [method level_up] they are
## created already filled in.
class EntityEvent:
	## Event ([member event]).
	enum Kind { HIT = 1, DEATH = 2, KILL = 3, RESPAWN = 4, WAR = 5, TELEGRAPH = 6, STATUS = 7, HEAL = 8,
			LOADOUT = 9, DOWNED = 10, INTERACT = 11, LEVEL_UP = 16 }
	## [member op] of a STATUS.
	enum StatusOp { APPLIED = 1, REMOVED = 2 }
	## [member op] of an INTERACT: starts reviving, revive cut off, revived, starts executing and
	## execute cut off.
	enum InteractOp { REVIVE = 1, REVIVE_CUT = 2, REVIVED = 3, EXECUTE = 4, EXECUTE_CUT = 5 }

	## Bytes of the header, before the data.
	const HEADER_SIZE: int = 9
	const HIT_DATA_SIZE: int = 8
	const DEATH_DATA_SIZE: int = 4
	const KILL_MIN_DATA_SIZE: int = 5
	const RESPAWN_DATA_SIZE: int = 1
	const WAR_DATA_SIZE: int = 2
	const TELEGRAPH_DATA_SIZE: int = 17
	const STATUS_DATA_SIZE: int = 9
	const HEAL_DATA_SIZE: int = 6
	const LOADOUT_DATA_SIZE: int = 6
	const DOWNED_DATA_SIZE: int = 4
	const INTERACT_DATA_SIZE: int = 7
	const LEVEL_UP_DATA_SIZE: int = 1
	## Shape of a TELEGRAPH ([member shape]).
	const SHAPE_CIRCLE: int = 0
	const SHAPE_SECTOR: int = 1
	## Highest realm that accompanies a WAR (the codes of [enum NetProtocol.Realm]).
	const MAX_WAR_REALM: int = 3
	## Maximum assistants of a KILL (each did at least 10% of the damage, so there are never
	## more than 10).
	const MAX_ASSISTANTS: int = 16

	## Bits of [member hit_flags] of a HIT.
	const HIT_FLAG_CRITICAL: int = 1 << 0
	const HIT_FLAG_BLOCKED: int = 1 << 1
	const HIT_FLAG_PARRIED: int = 1 << 2
	const HIT_FLAG_GUARD_BREAK: int = 1 << 3
	const HIT_FLAG_LETHAL: int = 1 << 4
	## The hit interrupted the victim: drinking, a marked cast, reviving or executing (protocol
	## 6).
	const HIT_FLAG_INTERRUPTED: int = 1 << 5
	## The hit knocked the victim down (protocol 6).
	const HIT_FLAG_DOWNED: int = 1 << 6

	## Entity the event is attached to (the victim, or whoever respawns).
	var net_id: int = 0
	## Server tick at which it happened.
	var tick: int = 0
	## [enum Kind].
	var event: int = Kind.HIT
	## HIT and DOWNED: net_id of the attacker.
	var attacker: int = 0
	## HIT: damage that reached health (with block and armor already applied). HEAL: health healed.
	var amount: int = 0
	## HIT: [enum DamageFormula.DamageType].
	var damage_type: int = 0
	## HIT: combination of the [code]HIT_FLAG_*[/code].
	var hit_flags: int = 0
	## HIT, DEATH, KILL, TELEGRAPH, HEAL and DOWNED: the source ([CombatSource]); for an attack, its catalog
	## id (the name is from phase 3, when there were only attacks).
	var attack_id: int = 0
	## DEATH and KILL: net_id of whoever dealt the killing blow (0 = the environment).
	var killer: int = 0
	## KILL: net_id of the assistants.
	var assistants: PackedInt32Array = PackedInt32Array()
	## RESPAWN: index of the respawn point.
	var point: int = 0
	## WAR: id from [WarEvents] ([constant WarEvents.FIRST] to [constant WarEvents.LAST]).
	var war_event: int = 0
	## WAR: realm code that accompanies the notice (0 = the Hollow / none).
	var war_realm: int = 0
	## TELEGRAPH: [constant SHAPE_CIRCLE] or [constant SHAPE_SECTOR]. The attack id goes in
	## [member attack_id].
	var shape: int = SHAPE_CIRCLE
	## TELEGRAPH: origin of the danger zone (quantized to 1 cm when encoding).
	var position: Vector3 = Vector3.ZERO
	## TELEGRAPH: rotation of the zone, in radians (quantized to 16 bits).
	var yaw: float = 0.0
	## TELEGRAPH: radius (reach) of the zone, in centimeters.
	var radius_cm: int = 0
	## TELEGRAPH: ticks remaining until impact.
	var impact_in_ticks: int = 0
	## STATUS: net_id of whoever applied the effect (0 = no author).
	var source_entity: int = 0
	## STATUS ([enum StatusOp]) and INTERACT ([enum InteractOp]).
	var op: int = 0
	## STATUS: id of the effect in the combat catalog (1 to 255).
	var status_id: int = 0
	## STATUS: stacks (at least 1 if applied; 0 when removed).
	var stacks: int = 0
	## STATUS: tick at which it ends (exclusive).
	var until_tick: int = 0
	## HEAL: net_id of whoever heals (0 = the healed one themselves).
	var healer: int = 0
	## LOADOUT: id of the equipment template.
	var template_id: int = 0
	## LOADOUT: weapons in slot order (0 = none).
	var weapon_1: int = 0
	var weapon_2: int = 0
	## LOADOUT: charges of the two potions (bits 0-3 and 4-7); 0 if the receiver is not the owner.
	var charges: int = 0
	## INTERACT: net_id of whoever revives or executes.
	var actor: int = 0
	## INTERACT: tick at which the revive or execute would end.
	var end_tick: int = 0
	## LEVEL_UP (protocol 7): the level reached (1 to [constant ProgressMessages.MAX_LEVEL]).
	var level: int = 0


	static func hit(victim_id: int, event_tick: int, attacker_id: int, damage: int,
			type_of_damage: int, flags: int, id_of_attack: int) -> EntityEvent:
		var created := EntityEvent.new()
		created.event = Kind.HIT
		created.net_id = victim_id
		created.tick = event_tick
		created.attacker = attacker_id
		created.amount = damage
		created.damage_type = type_of_damage
		created.hit_flags = flags
		created.attack_id = id_of_attack
		return created


	static func death(victim_id: int, event_tick: int, killer_id: int,
			id_of_attack: int) -> EntityEvent:
		var created := EntityEvent.new()
		created.event = Kind.DEATH
		created.net_id = victim_id
		created.tick = event_tick
		created.killer = killer_id
		created.attack_id = id_of_attack
		return created


	static func kill(victim_id: int, event_tick: int, killer_id: int, id_of_attack: int,
			assistant_ids: PackedInt32Array) -> EntityEvent:
		var created := EntityEvent.new()
		created.event = Kind.KILL
		created.net_id = victim_id
		created.tick = event_tick
		created.killer = killer_id
		created.attack_id = id_of_attack
		created.assistants = assistant_ids
		return created


	static func respawn(entity_id: int, event_tick: int, point_index: int) -> EntityEvent:
		var created := EntityEvent.new()
		created.event = Kind.RESPAWN
		created.net_id = entity_id
		created.tick = event_tick
		created.point = point_index
		return created


	## War notice of the fortress [param fortress_id]: [param war_event_id] is an id from
	## [WarEvents] and [param realm_code] the realm that accompanies it.
	static func war(fortress_id: int, event_tick: int, war_event_id: int,
			realm_code: int) -> EntityEvent:
		var created := EntityEvent.new()
		created.event = Kind.WAR
		created.net_id = fortress_id
		created.tick = event_tick
		created.war_event = war_event_id
		created.war_realm = realm_code
		return created


	## Telegraph of the attack [param id_of_attack] being prepared by the NPC [param npc_id].
	static func telegraph(npc_id: int, event_tick: int, id_of_attack: int, area_shape: int,
			origin: Vector3, area_yaw: float, area_radius_cm: int,
			ticks_to_impact: int) -> EntityEvent:
		var created := EntityEvent.new()
		created.event = Kind.TELEGRAPH
		created.net_id = npc_id
		created.tick = event_tick
		created.attack_id = id_of_attack
		created.shape = area_shape
		created.position = origin
		created.yaw = area_yaw
		created.radius_cm = area_radius_cm
		created.impact_in_ticks = ticks_to_impact
		return created


	## Effect [param id_of_status] applied or renewed ([constant StatusOp.APPLIED]) or removed
	## ([constant StatusOp.REMOVED]) on [param target_id] by [param author_id] (0 = no author).
	static func status(target_id: int, event_tick: int, author_id: int, operation: int,
			id_of_status: int, stack_count: int, ends_at: int) -> EntityEvent:
		var created := EntityEvent.new()
		created.event = Kind.STATUS
		created.net_id = target_id
		created.tick = event_tick
		created.source_entity = author_id
		created.op = operation
		created.status_id = id_of_status
		created.stacks = stack_count
		created.until_tick = ends_at
		return created


	## [param healed_amount] of health healed on [param target_id] by [param healer_id] (0 = self) with the
	## source [param source].
	static func heal(target_id: int, event_tick: int, healer_id: int, healed_amount: int,
			source: int) -> EntityEvent:
		var created := EntityEvent.new()
		created.event = Kind.HEAL
		created.net_id = target_id
		created.tick = event_tick
		created.healer = healer_id
		created.amount = healed_amount
		created.attack_id = source
		return created


	## Loadout of [param player_id]: the template, its weapons in slot order and the potion charges
	## (0 for whoever is not the owner).
	static func loadout(player_id: int, event_tick: int, id_of_template: int, first_weapon: int,
			second_weapon: int, consumable_charges: int) -> EntityEvent:
		var created := EntityEvent.new()
		created.event = Kind.LOADOUT
		created.net_id = player_id
		created.tick = event_tick
		created.template_id = id_of_template
		created.weapon_1 = first_weapon
		created.weapon_2 = second_weapon
		created.charges = consumable_charges
		return created


	## [param victim_id] is knocked down by [param attacker_id] with the source [param source].
	static func downed(victim_id: int, event_tick: int, attacker_id: int, source: int) -> EntityEvent:
		var created := EntityEvent.new()
		created.event = Kind.DOWNED
		created.net_id = victim_id
		created.tick = event_tick
		created.attacker = attacker_id
		created.attack_id = source
		return created


	## [param actor_id] starts reviving or executing the knocked down [param downed_id], it is cut off or finishes
	## ([param operation], from [enum InteractOp]); [param ends_at] is the tick at which it would end.
	static func interact(downed_id: int, event_tick: int, actor_id: int, operation: int,
			ends_at: int) -> EntityEvent:
		var created := EntityEvent.new()
		created.event = Kind.INTERACT
		created.net_id = downed_id
		created.tick = event_tick
		created.actor = actor_id
		created.op = operation
		created.end_tick = ends_at
		return created


	## [param player_id] levels up to [param new_level] (protocol 7). Saturates to 1 … cap when encoding.
	static func level_up(player_id: int, event_tick: int, new_level: int) -> EntityEvent:
		var created := EntityEvent.new()
		created.event = Kind.LEVEL_UP
		created.net_id = player_id
		created.tick = event_tick
		created.level = new_level
		return created


	## The event's source ([CombatSource]): the [member attack_id] of a HIT, DEATH, KILL, TELEGRAPH, HEAL or
	## DOWNED; 0 in the others.
	func get_source() -> int:
		match event:
			Kind.HIT, Kind.DEATH, Kind.KILL, Kind.TELEGRAPH, Kind.HEAL, Kind.DOWNED:
				return attack_id
		return CombatSource.NONE


	## Radius of a TELEGRAPH in meters.
	func get_radius() -> float:
		return radius_cm / 100.0


	## true if [member hit_flags] has the bit [param flag] (a [code]HIT_FLAG_*[/code]).
	func has_hit_flag(flag: int) -> bool:
		return (hit_flags & flag) != 0


	## Bytes of data the event takes, or -1 if [member event] is not a [enum Kind].
	func data_size() -> int:
		match event:
			Kind.HIT:
				return HIT_DATA_SIZE
			Kind.DEATH:
				return DEATH_DATA_SIZE
			Kind.KILL:
				return KILL_MIN_DATA_SIZE + 2 * mini(assistants.size(), MAX_ASSISTANTS)
			Kind.RESPAWN:
				return RESPAWN_DATA_SIZE
			Kind.WAR:
				return WAR_DATA_SIZE
			Kind.TELEGRAPH:
				return TELEGRAPH_DATA_SIZE
			Kind.STATUS:
				return STATUS_DATA_SIZE
			Kind.HEAL:
				return HEAL_DATA_SIZE
			Kind.LOADOUT:
				return LOADOUT_DATA_SIZE
			Kind.DOWNED:
				return DOWNED_DATA_SIZE
			Kind.INTERACT:
				return INTERACT_DATA_SIZE
			Kind.LEVEL_UP:
				return LEVEL_UP_DATA_SIZE
		return -1


	## An empty buffer if [member event] is not a [enum Kind]. A KILL with more than
	## [constant MAX_ASSISTANTS] assistants is trimmed.
	func encode() -> PackedByteArray:
		var size_of_data: int = data_size()
		if size_of_data < 0:
			return PackedByteArray()
		var bytes := PackedByteArray()
		bytes.resize(HEADER_SIZE + size_of_data)
		bytes.encode_u8(0, NetProtocol.MSG_ENTITY_EVENT)
		bytes.encode_u16(1, net_id & 0xFFFF)
		bytes.encode_u32(3, tick & 0xFFFFFFFF)
		bytes.encode_u8(7, event)
		bytes.encode_u8(8, size_of_data)
		match event:
			Kind.HIT:
				bytes.encode_u16(9, attacker & 0xFFFF)
				bytes.encode_u16(11, clampi(amount, 0, 0xFFFF))
				bytes.encode_u8(13, damage_type & 0xFF)
				bytes.encode_u8(14, hit_flags & 0xFF)
				bytes.encode_u16(15, attack_id & 0xFFFF)
			Kind.DEATH:
				bytes.encode_u16(9, killer & 0xFFFF)
				bytes.encode_u16(11, attack_id & 0xFFFF)
			Kind.KILL:
				var count: int = mini(assistants.size(), MAX_ASSISTANTS)
				bytes.encode_u16(9, killer & 0xFFFF)
				bytes.encode_u16(11, attack_id & 0xFFFF)
				bytes.encode_u8(13, count)
				for i: int in count:
					bytes.encode_u16(14 + 2 * i, assistants[i] & 0xFFFF)
			Kind.RESPAWN:
				bytes.encode_u8(9, point & 0xFF)
			Kind.WAR:
				bytes.encode_u8(9, war_event & 0xFF)
				bytes.encode_u8(10, war_realm & 0xFF)
			Kind.TELEGRAPH:
				bytes.encode_u16(9, attack_id & 0xFFFF)
				bytes.encode_u8(11, shape & 0xFF)
				bytes.encode_u64(12, NetMath.pack_position(position))
				bytes.encode_u16(20, NetMath.quantize_yaw16(yaw))
				bytes.encode_u16(22, clampi(radius_cm, 0, 0xFFFF))
				bytes.encode_u16(24, clampi(impact_in_ticks, 0, 0xFFFF))
			Kind.STATUS:
				bytes.encode_u16(9, source_entity & 0xFFFF)
				bytes.encode_u8(11, op & 0xFF)
				bytes.encode_u8(12, status_id & 0xFF)
				bytes.encode_u8(13, clampi(stacks, 0, 0xFF))
				bytes.encode_u32(14, until_tick & 0xFFFFFFFF)
			Kind.HEAL:
				bytes.encode_u16(9, healer & 0xFFFF)
				bytes.encode_u16(11, clampi(amount, 0, 0xFFFF))
				bytes.encode_u16(13, attack_id & 0xFFFF)
			Kind.LOADOUT:
				bytes.encode_u8(9, template_id & 0xFF)
				bytes.encode_u16(10, weapon_1 & 0xFFFF)
				bytes.encode_u16(12, weapon_2 & 0xFFFF)
				bytes.encode_u8(14, charges & 0xFF)
			Kind.DOWNED:
				bytes.encode_u16(9, attacker & 0xFFFF)
				bytes.encode_u16(11, attack_id & 0xFFFF)
			Kind.INTERACT:
				bytes.encode_u16(9, actor & 0xFFFF)
				bytes.encode_u8(11, op & 0xFF)
				bytes.encode_u32(12, end_tick & 0xFFFFFFFF)
			Kind.LEVEL_UP:
				bytes.encode_u8(9, clampi(level, 1, ProgressMessages.MAX_LEVEL))
		return bytes


	## Returns null if the type, the event, the declared length or the total size do not match
	## (HIT 8 B of data, DEATH 4, RESPAWN 1, WAR 2, TELEGRAPH 17, KILL 5 + 2n with the declared n and n
	## at most [constant MAX_ASSISTANTS], STATUS 9, HEAL 6, LOADOUT 6, DOWNED 4, INTERACT 7 and LEVEL_UP 1), if a
	## WAR carries a notice that is not from [WarEvents] or a realm greater than 3, if a TELEGRAPH carries a shape that
	## is neither 0 nor 1, if a STATUS or an INTERACT carries an [member op] that does not exist, if an applied STATUS
	## carries 0 stacks or if a LEVEL_UP carries a level outside 1 … cap.
	static func decode(bytes: PackedByteArray) -> EntityEvent:
		var size: int = bytes.size()
		if size < HEADER_SIZE or bytes[0] != NetProtocol.MSG_ENTITY_EVENT:
			return null
		var event_code: int = bytes[7]
		var declared: int = bytes[8]
		if size != HEADER_SIZE + declared:
			return null
		var parsed := EntityEvent.new()
		parsed.net_id = bytes.decode_u16(1)
		parsed.tick = bytes.decode_u32(3)
		parsed.event = event_code
		match event_code:
			Kind.HIT:
				if declared != HIT_DATA_SIZE:
					return null
				parsed.attacker = bytes.decode_u16(9)
				parsed.amount = bytes.decode_u16(11)
				parsed.damage_type = bytes.decode_u8(13)
				parsed.hit_flags = bytes.decode_u8(14)
				parsed.attack_id = bytes.decode_u16(15)
			Kind.DEATH:
				if declared != DEATH_DATA_SIZE:
					return null
				parsed.killer = bytes.decode_u16(9)
				parsed.attack_id = bytes.decode_u16(11)
			Kind.KILL:
				if declared < KILL_MIN_DATA_SIZE:
					return null
				var count: int = bytes.decode_u8(13)
				if count > MAX_ASSISTANTS or declared != KILL_MIN_DATA_SIZE + 2 * count:
					return null
				parsed.killer = bytes.decode_u16(9)
				parsed.attack_id = bytes.decode_u16(11)
				for i: int in count:
					parsed.assistants.append(bytes.decode_u16(14 + 2 * i))
			Kind.RESPAWN:
				if declared != RESPAWN_DATA_SIZE:
					return null
				parsed.point = bytes.decode_u8(9)
			Kind.WAR:
				if declared != WAR_DATA_SIZE:
					return null
				parsed.war_event = bytes.decode_u8(9)
				parsed.war_realm = bytes.decode_u8(10)
				if not WarEvents.is_valid(parsed.war_event) or parsed.war_realm > MAX_WAR_REALM:
					return null
			Kind.TELEGRAPH:
				if declared != TELEGRAPH_DATA_SIZE:
					return null
				parsed.attack_id = bytes.decode_u16(9)
				parsed.shape = bytes.decode_u8(11)
				if parsed.shape != SHAPE_CIRCLE and parsed.shape != SHAPE_SECTOR:
					return null
				parsed.position = NetMath.unpack_position(bytes.decode_u64(12))
				parsed.yaw = NetMath.dequantize_yaw16(bytes.decode_u16(20))
				parsed.radius_cm = bytes.decode_u16(22)
				parsed.impact_in_ticks = bytes.decode_u16(24)
			Kind.STATUS:
				if declared != STATUS_DATA_SIZE:
					return null
				parsed.source_entity = bytes.decode_u16(9)
				parsed.op = bytes.decode_u8(11)
				parsed.status_id = bytes.decode_u8(12)
				parsed.stacks = bytes.decode_u8(13)
				parsed.until_tick = bytes.decode_u32(14)
				if parsed.op != StatusOp.APPLIED and parsed.op != StatusOp.REMOVED:
					return null
				if parsed.op == StatusOp.APPLIED and parsed.stacks == 0:
					return null
			Kind.HEAL:
				if declared != HEAL_DATA_SIZE:
					return null
				parsed.healer = bytes.decode_u16(9)
				parsed.amount = bytes.decode_u16(11)
				parsed.attack_id = bytes.decode_u16(13)
			Kind.LOADOUT:
				if declared != LOADOUT_DATA_SIZE:
					return null
				parsed.template_id = bytes.decode_u8(9)
				parsed.weapon_1 = bytes.decode_u16(10)
				parsed.weapon_2 = bytes.decode_u16(12)
				parsed.charges = bytes.decode_u8(14)
			Kind.DOWNED:
				if declared != DOWNED_DATA_SIZE:
					return null
				parsed.attacker = bytes.decode_u16(9)
				parsed.attack_id = bytes.decode_u16(11)
			Kind.INTERACT:
				if declared != INTERACT_DATA_SIZE:
					return null
				parsed.actor = bytes.decode_u16(9)
				parsed.op = bytes.decode_u8(11)
				parsed.end_tick = bytes.decode_u32(12)
				if parsed.op < InteractOp.REVIVE or parsed.op > InteractOp.EXECUTE_CUT:
					return null
			Kind.LEVEL_UP:
				if declared != LEVEL_UP_DATA_SIZE:
					return null
				parsed.level = bytes.decode_u8(9)
				if parsed.level < 1 or parsed.level > ProgressMessages.MAX_LEVEL:
					return null
			_:
				return null
		return parsed


## RESPAWN_REQUEST (C→S, channel 3): 2 B. The dead player asks to respawn at point
## [member point_index] of their realm's list of points (docs/combate.md, section 5). Out of
## time or with an invalid index the server counts a warning.
class RespawnRequest:
	const SIZE: int = 2

	var point_index: int = 0


	func encode() -> PackedByteArray:
		return PackedByteArray([NetProtocol.MSG_RESPAWN_REQUEST, point_index & 0xFF])


	static func decode(bytes: PackedByteArray) -> RespawnRequest:
		if bytes.size() != SIZE or bytes[0] != NetProtocol.MSG_RESPAWN_REQUEST:
			return null
		var request := RespawnRequest.new()
		request.point_index = bytes[1]
		return request


## UNSTUCK_REQUEST (C→S, channel 3): 1 B. The player requests /atascado (docs/fuerte.md, section 5): it is its own
## message and is valid without [code]--debug-commands[/code]. The server decides whether it proceeds (out of
## combat, 5 min cooldown...).
class UnstuckRequest:
	const SIZE: int = 1


	func encode() -> PackedByteArray:
		return PackedByteArray([NetProtocol.MSG_UNSTUCK_REQUEST])


	static func decode(bytes: PackedByteArray) -> UnstuckRequest:
		if bytes.size() != SIZE or bytes[0] != NetProtocol.MSG_UNSTUCK_REQUEST:
			return null
		return UnstuckRequest.new()


## LOADOUT_SELECT (C→S, channel 3, protocol 6): 2 B, [code]u8 type, u8 template_id[/code]. The equipment
## template the player wants for their next spawn (docs/habilidades.md, sections 4.6 and 5.1). Valid
## from the WELCOME, also before CLIENT_READY. [member template_id] is a combat catalog id
## ([method CombatCatalog.template_id]) or 0, the default one; the server counts a warning if it does not exist or
## cannot be chosen. [method decode] only checks the size and the type.
class LoadoutSelect:
	const SIZE: int = 2

	var template_id: int = 0


	static func make(id_of_template: int) -> LoadoutSelect:
		var select := LoadoutSelect.new()
		select.template_id = id_of_template
		return select


	func encode() -> PackedByteArray:
		return PackedByteArray([NetProtocol.MSG_LOADOUT_SELECT, template_id & 0xFF])


	static func decode(bytes: PackedByteArray) -> LoadoutSelect:
		if bytes.size() != SIZE or bytes[0] != NetProtocol.MSG_LOADOUT_SELECT:
			return null
		return LoadoutSelect.make(bytes[1])


## A scoreboard row: what counts for a player (docs/fuerte.md, section 6), 18 B.
## [code]u16 net_id, u16 kills, u16 deaths, u16 assists, u32 gate_damage, u16 circle_seconds, u32
## merits[/code]. Counters saturate at their maximum when encoding.
class ScoreRow:
	const SIZE: int = 18

	var net_id: int = 0
	## Kills.
	var kills: int = 0
	## Deaths.
	var deaths: int = 0
	## Assists.
	var assists: int = 0
	## Damage dealt to the fortress gate.
	var gate_damage: int = 0
	## Seconds spent inside the capture circle.
	var circle_seconds: int = 0
	## Merits.
	var merits: int = 0


	static func make(player_id: int, kill_count: int, death_count: int, assist_count: int,
			damage_to_gate: int, seconds_in_circle: int, merit_points: int) -> ScoreRow:
		var row := ScoreRow.new()
		row.net_id = player_id
		row.kills = kill_count
		row.deaths = death_count
		row.assists = assist_count
		row.gate_damage = damage_to_gate
		row.circle_seconds = seconds_in_circle
		row.merits = merit_points
		return row


	func write_to(bytes: PackedByteArray, offset: int) -> void:
		bytes.encode_u16(offset, net_id & 0xFFFF)
		bytes.encode_u16(offset + 2, clampi(kills, 0, 0xFFFF))
		bytes.encode_u16(offset + 4, clampi(deaths, 0, 0xFFFF))
		bytes.encode_u16(offset + 6, clampi(assists, 0, 0xFFFF))
		bytes.encode_u32(offset + 8, clampi(gate_damage, 0, 0xFFFFFFFF))
		bytes.encode_u16(offset + 12, clampi(circle_seconds, 0, 0xFFFF))
		bytes.encode_u32(offset + 14, clampi(merits, 0, 0xFFFFFFFF))


	static func read_from(bytes: PackedByteArray, offset: int) -> ScoreRow:
		var row := ScoreRow.new()
		row.net_id = bytes.decode_u16(offset)
		row.kills = bytes.decode_u16(offset + 2)
		row.deaths = bytes.decode_u16(offset + 4)
		row.assists = bytes.decode_u16(offset + 6)
		row.gate_damage = bytes.decode_u32(offset + 8)
		row.circle_seconds = bytes.decode_u16(offset + 12)
		row.merits = bytes.decode_u32(offset + 14)
		return row


## SCOREBOARD (S→C, channel 3): 4 B + 18 B per row (docs/fuerte.md, section 6). The zone's scoreboard,
## every 2 s to all players.
## [br][br]
## [code]u8 type, u8 page_index, u8 page_count, u8 row_count[/code] and [code]row_count[/code] rows
## ([ScoreRow]). A page does not exceed [constant MAX_ROWS] rows (the message fits in
## [constant NetProtocol.MAX_PACKET_BYTES]); with more players the scoreboard is split into several pages
## ([method split]), which the client joins by [member page_index] out of [member page_count].
class Scoreboard:
	## Header: type, page, total pages and rows.
	const HEADER_SIZE: int = 4
	## Rows per page: ⌊(1200 − 4) / 18⌋ = 66, a message of 1192 B.
	const MAX_ROWS: int = 66
	## Maximum pages (the total is a u8).
	const MAX_PAGES: int = 255

	## Index of this page, starting at 0.
	var page_index: int = 0
	## Total pages of the scoreboard (from 1 to 255).
	var page_count: int = 1
	var rows: Array[ScoreRow] = []


	## Splits [param all_rows] into pages of up to [constant MAX_ROWS] rows, in order. With no
	## rows it returns a single empty page (the client empties the scoreboard). Anything beyond
	## [constant MAX_PAGES] pages is discarded.
	static func split(all_rows: Array[ScoreRow]) -> Array[Scoreboard]:
		var pages: Array[Scoreboard] = []
		var total: int = clampi(ceili(all_rows.size() / float(MAX_ROWS)), 1, MAX_PAGES)
		for page: int in total:
			var board := Scoreboard.new()
			board.page_index = page
			board.page_count = total
			var first: int = page * MAX_ROWS
			for i: int in range(first, mini(first + MAX_ROWS, all_rows.size())):
				board.rows.append(all_rows[i])
			pages.append(board)
		return pages


	## Bytes taken by the message.
	func encoded_size() -> int:
		return HEADER_SIZE + ScoreRow.SIZE * rows.size()


	## An empty buffer if there are more than [constant MAX_ROWS] rows or the page is not valid (total outside
	## 1 to 255 or [member page_index] not less than it): whoever sends uses [method split].
	func encode() -> PackedByteArray:
		if rows.size() > MAX_ROWS or page_count < 1 or page_count > MAX_PAGES \
				or page_index < 0 or page_index >= page_count:
			return PackedByteArray()
		var bytes := PackedByteArray()
		bytes.resize(encoded_size())
		bytes.encode_u8(0, NetProtocol.MSG_SCOREBOARD)
		bytes.encode_u8(1, page_index)
		bytes.encode_u8(2, page_count)
		bytes.encode_u8(3, rows.size())
		for i: int in rows.size():
			rows[i].write_to(bytes, HEADER_SIZE + ScoreRow.SIZE * i)
		return bytes


	## Returns null if the size is not exactly that of the header plus [code]row_count[/code]
	## rows, if there are more than [constant MAX_ROWS], if the total pages is 0 or if the index is not
	## less than the total.
	static func decode(bytes: PackedByteArray) -> Scoreboard:
		var size: int = bytes.size()
		if size < HEADER_SIZE or bytes[0] != NetProtocol.MSG_SCOREBOARD:
			return null
		var board := Scoreboard.new()
		board.page_index = bytes[1]
		board.page_count = bytes[2]
		var row_count: int = bytes[3]
		if board.page_count < 1 or board.page_index >= board.page_count or row_count > MAX_ROWS:
			return null
		if size != HEADER_SIZE + ScoreRow.SIZE * row_count:
			return null
		for i: int in row_count:
			board.rows.append(ScoreRow.read_from(bytes, HEADER_SIZE + ScoreRow.SIZE * i))
		return board
