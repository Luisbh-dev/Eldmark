extends TestCase
## Tests of protocol 3 (docs/fuerte.md, sections 2, 5, 6 and 7; package F2): OBJECT_STATE, the
## ENTITY_SPAWN of structures and NPCs, the WAR and TELEGRAPH ENTITY_EVENTs, UNSTUCK_REQUEST,
## SCOREBOARD, the IMBALANCE REJECT, the per-realm count of the WELCOME and debug commands 7 to
## 12 ([NetMessages], [NetProtocol]).
## [br][br]
## As in test_net_messages.gd, the offsets and sizes are the ones from the document, written by hand
## on purpose: if the code and the document drift apart, these tests fail. The malformed messages and
## the fuzz also check that nothing logs engine errors (the runner counts them as a failure).

const DEFINITION_PATH: String = "res://data/fortresses/vado_gris.tres"
const FUZZ_BUFFERS: int = 8000
const FUZZ_SEED: int = 20261029
const DEFINITION_ID: String = "vado_gris_fort"

const U8: int = NetMessages.ObjectField.ValueType.U8
const U16: int = NetMessages.ObjectField.ValueType.U16
const U32: int = NetMessages.ObjectField.ValueType.U32
const S32: int = NetMessages.ObjectField.ValueType.S32


# --- Constants and channels -------------------------------------------------------------------

func test_protocol_3_constants_and_channels() -> void:
	assert_true(NetProtocol.PROTOCOL_VERSION >= 4, "the fort raises the protocol to version 4")
	assert_eq(NetProtocol.MSG_UNSTUCK_REQUEST, 0x06, "UNSTUCK_REQUEST is 0x06")
	assert_eq(NetProtocol.MSG_OBJECT_STATE, 0x22, "OBJECT_STATE is 0x22")
	assert_eq(NetProtocol.MSG_SCOREBOARD, 0x32, "SCOREBOARD is 0x32")
	assert_eq(NetProtocol.Result.IMBALANCE, 9, "REJECT 9 IMBALANCE")
	for message_type: int in [NetProtocol.MSG_UNSTUCK_REQUEST, NetProtocol.MSG_OBJECT_STATE,
			NetProtocol.MSG_SCOREBOARD, NetProtocol.MSG_ENTITY_EVENT]:
		assert_eq(NetProtocol.channel_for_type(message_type), NetProtocol.CH_RELIABLE,
				"0x%02X goes over channel 3" % message_type)
		assert_eq(NetProtocol.transfer_mode(NetProtocol.channel_for_type(message_type)),
				MultiplayerPeer.TRANSFER_MODE_RELIABLE, "0x%02X is reliable" % message_type)
	# Message types are not repeated.
	var seen: Dictionary = {}
	for message_type: int in [NetProtocol.MSG_INPUT_BATCH, NetProtocol.MSG_CLIENT_READY,
			NetProtocol.MSG_CLIENT_LEAVE, NetProtocol.MSG_DEBUG_COMMAND,
			NetProtocol.MSG_RESPAWN_REQUEST, NetProtocol.MSG_UNSTUCK_REQUEST,
			NetProtocol.MSG_SNAPSHOT, NetProtocol.MSG_ENTITY_SPAWN, NetProtocol.MSG_ENTITY_DESPAWN,
			NetProtocol.MSG_OBJECT_STATE, NetProtocol.MSG_ENTITY_EVENT, NetProtocol.MSG_NOTICE,
			NetProtocol.MSG_HANDOFF, NetProtocol.MSG_SCOREBOARD]:
		assert_false(seen.has(message_type), "type 0x%02X is not repeated" % message_type)
		seen[message_type] = true
	# The OBJECT_STATE value types are the same as those of FortressFields.
	assert_eq(U8, FortressFields.ValueType.U8, "u8")
	assert_eq(U16, FortressFields.ValueType.U16, "u16")
	assert_eq(U32, FortressFields.ValueType.U32, "u32")
	assert_eq(S32, FortressFields.ValueType.S32, "s32")
	for type: int in [0, U8, U16, U32, S32, 5, 255]:
		assert_eq(NetMessages.ObjectField.size_of_type(type), FortressFields.value_size(type),
				"size of type %d" % type)


func test_imbalance_reject_has_its_own_spanish_text() -> void:
	var text: String = NetProtocol.result_text(NetProtocol.Result.IMBALANCE)
	assert_false(text.is_empty(), "it has text")
	assert_true(text.contains("reino"), "it mentions the realm: %s" % text)
	for other: int in range(1, 9):
		assert_true(text != NetProtocol.result_text(other), "it is distinguished from reason %d" % other)
	var reject := NetMessages.Reject.new()
	reject.result = NetProtocol.Result.IMBALANCE
	reject.text = text
	var bytes: PackedByteArray = reject.encode()
	assert_eq(bytes.decode_u8(4), 9, "u8 result at 4: 9")
	assert_eq(NetMessages.peek_auth_result(bytes), 9, "peek_auth_result sees it")
	var back: NetMessages.Reject = NetMessages.Reject.decode(bytes)
	if assert_not_null(back, "decode of the REJECT"):
		assert_eq(back.result, NetProtocol.Result.IMBALANCE, "result")
		assert_eq(back.text, text, "text")
	assert_true(text.to_utf8_buffer().size() <= NetMessages.MAX_REJECT_TEXT_BYTES, "fits in a REJECT")


# --- WELCOME ----------------------------------------------------------------------------------

func test_welcome_ends_with_the_realm_counts() -> void:
	var welcome := NetMessages.Welcome.new()
	welcome.zone_id = "vado_gris"
	welcome.realm_counts = PackedInt32Array([12, 34, 56])
	var bytes: PackedByteArray = welcome.encode()
	assert_eq(bytes.size(), 18 + 9 + 3, "18 B + zone id + 3 B")
	assert_eq(bytes.slice(bytes.size() - 3), PackedByteArray([12, 34, 56]), "u8 × 3 at the end")
	var back: NetMessages.Welcome = NetMessages.Welcome.decode(bytes)
	if not assert_not_null(back, "decode"):
		return
	assert_eq(back.realm_counts, PackedInt32Array([12, 34, 56]), "count")
	assert_eq(back.get_realm_count(NetProtocol.Realm.SOLMARCH), 34, "Solmarch")
	assert_eq(back.zone_id, "vado_gris", "the zone is still where it was")
	# Without a zone, the count goes right after the header.
	var empty_zone := NetMessages.Welcome.new()
	empty_zone.realm_counts = PackedInt32Array([1, 2, 3])
	var empty_bytes: PackedByteArray = empty_zone.encode()
	assert_eq(empty_bytes.size(), 21, "21 B without a zone")
	assert_eq(empty_bytes.slice(18), PackedByteArray([1, 2, 3]), "count at 18")
	# Saturation and wrongly sized counts.
	var odd := NetMessages.Welcome.new()
	odd.realm_counts = PackedInt32Array([1000, -5])
	var odd_back: NetMessages.Welcome = NetMessages.Welcome.decode(odd.encode())
	if assert_not_null(odd_back, "decode with a short count"):
		assert_eq(odd_back.realm_counts, PackedInt32Array([255, 0, 0]), "saturates and pads with zeros")
	# The version 2 WELCOME (without count) is no longer valid, not even with extra bytes.
	assert_null(NetMessages.Welcome.decode(bytes.slice(0, bytes.size() - 3)), "without the count")
	assert_null(NetMessages.Welcome.decode(bytes.slice(0, bytes.size() - 1)), "half a count")
	var longer: PackedByteArray = bytes.duplicate()
	longer.append(0)
	assert_null(NetMessages.Welcome.decode(longer), "one extra byte")


# --- OBJECT_STATE -----------------------------------------------------------------------------

func test_object_state_layout_and_roundtrip() -> void:
	var message := NetMessages.ObjectState.new()
	message.net_id = 513
	message.tick = 0xFFFFFFF0
	message.add_field(1, U8, 3)
	message.add_field(2, U16, 0xBEEF)
	message.add_field(3, U32, 0xDEADBEEF)
	message.add_field(4, S32, -24)
	var bytes: PackedByteArray = message.encode()
	assert_eq(bytes.size(), 8 + 3 + 4 + 6 + 6, "8 B of header + fields")
	assert_eq(message.encoded_size(), bytes.size(), "encoded_size matches")
	assert_eq(bytes.decode_u8(0), 0x22, "u8 type at 0")
	assert_eq(bytes.decode_u16(1), 513, "u16 net_id at 1")
	assert_eq(bytes.decode_u32(3), 0xFFFFFFF0, "u32 tick at 3")
	assert_eq(bytes.decode_u8(7), 4, "u8 field_count at 7")
	assert_eq(bytes.decode_u8(8), 1, "field 1: field_id at 8")
	assert_eq(bytes.decode_u8(9), 1, "field 1: value_type u8")
	assert_eq(bytes.decode_u8(10), 3, "field 1: value")
	assert_eq(bytes.decode_u8(11), 2, "field 2: field_id at 11")
	assert_eq(bytes.decode_u8(12), 2, "field 2: value_type u16")
	assert_eq(bytes.decode_u16(13), 0xBEEF, "field 2: value")
	assert_eq(bytes.decode_u8(15), 3, "field 3: field_id at 15")
	assert_eq(bytes.decode_u8(16), 3, "field 3: value_type u32")
	assert_eq(bytes.decode_u32(17), 0xDEADBEEF, "field 3: value")
	assert_eq(bytes.decode_u8(21), 4, "field 4: field_id at 21")
	assert_eq(bytes.decode_u8(22), 4, "field 4: value_type s32")
	assert_eq(bytes.decode_s32(23), -24, "field 4: negative value")

	var back: NetMessages.ObjectState = NetMessages.ObjectState.decode(bytes)
	if not assert_not_null(back, "decode"):
		return
	assert_eq(back.net_id, 513, "net_id")
	assert_eq(back.tick, 0xFFFFFFF0, "tick u32")
	assert_eq(back.fields.size(), 4, "four fields")
	assert_eq(back.get_value(1), 3, "u8")
	assert_eq(back.get_value(2), 0xBEEF, "u16")
	assert_eq(back.get_value(3), 0xDEADBEEF, "u32")
	assert_eq(back.get_value(4), -24, "s32")
	assert_eq(back.get_field(4).value_type, S32, "type of field 4")
	assert_true(back.has_field(2) and not back.has_field(9), "has_field")
	assert_eq(back.get_value(9, -7), -7, "a missing field gives the default value")
	assert_null(back.get_field(9), "and there is no field")
	assert_eq(back.encode(), bytes, "re-encoding gives the same bytes")


func test_object_state_extremes_and_saturation() -> void:
	var message := NetMessages.ObjectState.new()
	message.net_id = 0xFFFF
	message.tick = 0
	message.add_field(0, U8, 255)
	message.add_field(255, S32, -0x80000000)
	message.add_field(10, S32, 0x7FFFFFFF)
	message.add_field(11, U32, 0xFFFFFFFF)
	var back: NetMessages.ObjectState = NetMessages.ObjectState.decode(message.encode())
	if assert_not_null(back, "the extremes are encoded"):
		assert_eq(back.net_id, 0xFFFF, "maximum net_id")
		assert_eq(back.get_value(0), 255, "field_id 0 and maximum u8")
		assert_eq(back.get_value(255), -0x80000000, "minimum s32, field_id 255")
		assert_eq(back.get_value(10), 0x7FFFFFFF, "maximum s32")
		assert_eq(back.get_value(11), 0xFFFFFFFF, "maximum u32")
	# A value that does not fit its type saturates instead of wrapping around.
	var over := NetMessages.ObjectState.new()
	over.add_field(1, U8, 300)
	over.add_field(2, U16, -3)
	over.add_field(3, U32, 0x1FFFFFFFF)
	over.add_field(4, S32, 0x90000000)
	over.add_field(5, S32, -0x90000000)
	var over_back: NetMessages.ObjectState = NetMessages.ObjectState.decode(over.encode())
	if assert_not_null(over_back, "out-of-range values"):
		assert_eq(over_back.get_value(1), 255, "saturated u8")
		assert_eq(over_back.get_value(2), 0, "negative u16 saturated to 0")
		assert_eq(over_back.get_value(3), 0xFFFFFFFF, "saturated u32")
		assert_eq(over_back.get_value(4), 0x7FFFFFFF, "s32 saturated at the top")
		assert_eq(over_back.get_value(5), -0x80000000, "s32 saturated at the bottom")
	assert_false(NetMessages.ObjectField.make(1, U8, 256).is_valid(), "256 does not fit in a u8")
	assert_true(NetMessages.ObjectField.make(1, U8, 255).is_valid(), "255 does")
	assert_false(NetMessages.ObjectField.make(1, U32, -1).is_valid(), "-1 does not fit in a u32")
	assert_true(NetMessages.ObjectField.make(1, S32, -1).is_valid(), "-1 fits in an s32")
	assert_false(NetMessages.ObjectField.make(256, U8, 1).is_valid(), "field_id larger than a u8")
	assert_false(NetMessages.ObjectField.make(1, 9, 1).is_valid(), "unknown type")


func test_object_state_field_count_limits() -> void:
	var full := NetMessages.ObjectState.new()
	for field_id: int in NetMessages.MAX_OBJECT_FIELDS:
		full.add_field(field_id + 1, U8, field_id)
	var bytes: PackedByteArray = full.encode()
	assert_eq(bytes.size(), 8 + 32 * 3, "32 one-byte fields")
	assert_eq(bytes.decode_u8(7), 32, "field_count 32")
	var back: NetMessages.ObjectState = NetMessages.ObjectState.decode(bytes)
	if assert_not_null(back, "32 fields are decoded"):
		assert_eq(back.fields.size(), 32, "all 32")
	full.add_field(100, U8, 0)
	assert_true(full.encode().is_empty(), "33 fields are not encoded")
	assert_true(NetMessages.ObjectState.new().encode().is_empty(), "no fields either")

	var forged: PackedByteArray = bytes.duplicate()
	forged.encode_u8(7, 33)
	forged.append_array(PackedByteArray([200, U8, 1]))
	assert_null(NetMessages.ObjectState.decode(forged), "field_count 33 with 33 fields")
	forged.encode_u8(7, 0)
	assert_null(NetMessages.ObjectState.decode(forged), "field_count 0")
	assert_null(NetMessages.ObjectState.decode(PackedByteArray([0x22, 1, 0, 0, 0, 0, 0, 0])),
			"field_count 0 without fields")


func test_object_state_rejects_malformed_fields() -> void:
	# Header of a one-field OBJECT_STATE: net_id 7, tick 100.
	var header := PackedByteArray([0x22, 7, 0, 100, 0, 0, 0, 1])
	assert_not_null(NetMessages.ObjectState.decode(_with(header, [5, U8, 9])), "the base case is valid")
	for bad_type: int in [0, 5, 9, 255]:
		assert_null(NetMessages.ObjectState.decode(_with(header, [5, bad_type, 9, 9, 9, 9])),
				"unknown value_type %d" % bad_type)
	assert_null(NetMessages.ObjectState.decode(_with(header, [5, U16, 9])), "u16 with 1 B of value")
	assert_null(NetMessages.ObjectState.decode(_with(header, [5, U32, 9, 0, 0])), "u32 with 3 B")
	assert_null(NetMessages.ObjectState.decode(_with(header, [5, S32, 9, 0])), "s32 with 2 B")
	assert_null(NetMessages.ObjectState.decode(_with(header, [5])), "a field without a type")
	assert_null(NetMessages.ObjectState.decode(_with(header, [5, U8, 9, 6, U8, 1])),
			"field_count less than the fields present")
	var two := PackedByteArray([0x22, 7, 0, 100, 0, 0, 0, 2])
	assert_null(NetMessages.ObjectState.decode(_with(two, [5, U8, 9])),
			"field_count greater than the fields present")
	assert_not_null(NetMessages.ObjectState.decode(_with(two, [5, U8, 9, 6, U8, 1])),
			"two different fields")
	assert_null(NetMessages.ObjectState.decode(_with(two, [5, U8, 9, 5, U8, 1])),
			"the same field_id twice")
	assert_null(NetMessages.ObjectState.decode(_with(two, [5, U8, 9, 5, U16, 1, 0])),
			"the same field_id with another type")
	assert_null(NetMessages.ObjectState.decode(_with(header, [5, U8, 9, 0])), "one extra byte")
	assert_null(NetMessages.ObjectState.decode(PackedByteArray([0x23, 7, 0, 100, 0, 0, 0, 1, 5, U8, 9])),
			"another message type")
	# An object that repeats an id is not encoded.
	var repeated := NetMessages.ObjectState.new()
	repeated.add_field(5, U8, 1)
	repeated.add_field(5, U8, 2)
	assert_true(repeated.encode().is_empty(), "repeated ids: not encoded")
	var bad_type := NetMessages.ObjectState.new()
	bad_type.add_field(5, 7, 1)
	assert_true(bad_type.encode().is_empty(), "unknown value type: not encoded")


func test_object_state_unknown_field_ids_are_kept_and_skipped() -> void:
	var def: FortressDefinition = load(DEFINITION_PATH) as FortressDefinition
	var state := FortressState.initial(def, 0)
	var message := NetMessages.ObjectState.new()
	message.net_id = 3
	message.tick = 500
	message.add_field(FortressFields.OWNER, U8, 2)
	message.add_field(200, U16, 4242)
	message.add_field(FortressFields.GATE_HEALTH, U32, 1234)
	message.add_field(201, S32, -9)
	var back: NetMessages.ObjectState = NetMessages.ObjectState.decode(message.encode())
	if not assert_not_null(back, "an unknown id with a valid type is not an error"):
		return
	assert_eq(back.fields.size(), 4, "and it is kept")
	assert_eq(back.get_value(200), 4242, "with its value")
	assert_eq(back.apply_to_fortress(state), 2, "the fortress only applies its own")
	assert_eq(state.owner, 2, "owner applied")
	assert_eq(state.gate_health, 1234, "gate_health applied")
	assert_true(back.is_valid_for_fortress(), "unknown ids do not invalidate the message")
	# A known field with another value type is skipped (and the message is not valid for a fortress).
	var wrong := NetMessages.ObjectState.new()
	wrong.add_field(FortressFields.OWNER, U16, 3)
	wrong.add_field(FortressFields.PHASE, U8, 2)
	assert_false(wrong.is_valid_for_fortress(), "owner is not a u16")
	var untouched := FortressState.initial(def, 0)
	assert_eq(wrong.apply_to_fortress(untouched), 1, "only the one carrying its own type is applied")
	assert_eq(untouched.owner, 0, "owner intact")
	assert_eq(untouched.phase, 2, "phase applied")


func test_object_state_from_fortress_roundtrip() -> void:
	var def: FortressDefinition = load(DEFINITION_PATH) as FortressDefinition
	var state: FortressState = _capturing_state(def)
	state.advance(def, 400, PackedInt32Array([0, 0, 1, 0]))
	assert_eq(state.capture_rate, FortressState.FOREIGN_DECAY_RATE, "the capture goes backwards (negative s32)")
	var full: NetMessages.ObjectState = NetMessages.ObjectState.from_fortress(9, 400, state)
	var bytes: PackedByteArray = full.encode()
	# 10 u8 fields (3 B), 6 u32 (6 B) and the s32 speed (6 B), after 8 B of header.
	assert_eq(bytes.size(), 8 + 10 * 3 + 6 * 6 + 6, "the full state takes 80 B")
	assert_eq(bytes.decode_u8(7), 17, "17 fields")
	var back: NetMessages.ObjectState = NetMessages.ObjectState.decode(bytes)
	if not assert_not_null(back, "decode"):
		return
	assert_true(back.is_valid_for_fortress(), "the types are those of FortressFields")
	var rebuilt := FortressState.initial(def, 0)
	assert_eq(back.apply_to_fortress(rebuilt), 17, "all 17 are applied")
	_assert_same_fields(rebuilt, state, "estado completo")
	assert_eq(rebuilt.capture_rate, -24, "the negative speed survives")
	assert_eq(rebuilt.progress_at(400.0), state.progress_at(400.0), "and with it, the progress")
	assert_eq(rebuilt.progress_at(420.0), state.progress_at(420.0), "and its evolution")


func test_object_state_carries_only_the_changed_fields() -> void:
	var def: FortressDefinition = load(DEFINITION_PATH) as FortressDefinition
	var state: FortressState = _capturing_state(def)
	var before: FortressState = state.duplicate_state()
	var unchanged: NetMessages.ObjectState = NetMessages.ObjectState.from_fortress_changes(
			9, 200, state, before)
	assert_true(unchanged.fields.is_empty(), "without changes there are no fields")
	assert_true(unchanged.encode().is_empty(), "and there is nothing to send")

	state.advance(def, 400, PackedInt32Array([0, 0, 1, 0]))
	var changes: NetMessages.ObjectState = NetMessages.ObjectState.from_fortress_changes(
			9, 400, state, before)
	var ids: PackedInt32Array = PackedInt32Array()
	for field: NetMessages.ObjectField in changes.fields:
		ids.append(field.field_id)
	assert_eq(ids, state.changed_fields_since(before), "those of changed_fields_since, in id order")
	assert_eq(ids, PackedInt32Array([FortressFields.CAPTURE_START_TICK, FortressFields.CAPTURE_RATE,
			FortressFields.CAPTURE_PROGRESS_AT_START, FortressFields.PRESENCE_BASE + 1,
			FortressFields.PRESENCE_BASE + 2]), "the capture re-anchors and the presence changes")
	var bytes: PackedByteArray = changes.encode()
	assert_eq(bytes.size(), 8 + 3 * 6 + 2 * 3, "5 fields: 2 u32, the speed (s32) and 2 u8")
	var applied: FortressState = before.duplicate_state()
	var back: NetMessages.ObjectState = NetMessages.ObjectState.decode(bytes)
	if assert_not_null(back, "decode"):
		assert_eq(back.apply_to_fortress(applied), 5, "all five are applied")
		_assert_same_fields(applied, state, "estado anterior más los cambios")

	# A custom list of ids; unknown ids do not get in.
	var some: NetMessages.ObjectState = NetMessages.ObjectState.from_fortress_fields(
			9, 400, state, PackedInt32Array([FortressFields.OWNER, 99, FortressFields.GATE_MAX]))
	assert_eq(some.fields.size(), 2, "owner and gate_max")
	assert_eq(some.get_value(FortressFields.GATE_MAX), state.gate_max, "value of gate_max")


# --- ENTITY_SPAWN of NPCs and structures ------------------------------------------------------

func test_npc_spawn_ends_with_the_definition_id() -> void:
	var spawn: NetMessages.EntitySpawn = _npc_spawn()
	var bytes: PackedByteArray = spawn.encode()
	var name_bytes: PackedByteArray = spawn.display_name.to_utf8_buffer()
	var name_offset: int = 10 + PlayerState.ENCODED_SIZE
	assert_eq(bytes.size(), name_offset + 1 + name_bytes.size() + 2, "10 B + state + name + 2 B")
	assert_eq(bytes.decode_u8(3), NetProtocol.EntityKind.NPC, "u8 kind at 3")
	assert_eq(bytes.decode_u8(name_offset), name_bytes.size(), "u8 name_len after the state")
	assert_eq(bytes.slice(name_offset + 1, name_offset + 1 + name_bytes.size()), name_bytes, "name")
	assert_eq(bytes.decode_u16(name_offset + 1 + name_bytes.size()), 3, "u16 npc_def_id after the name")
	var back: NetMessages.EntitySpawn = NetMessages.EntitySpawn.decode(bytes)
	if not assert_not_null(back, "decode of an NPC SPAWN"):
		return
	assert_eq(back.kind, NetProtocol.EntityKind.NPC, "kind")
	assert_eq(back.npc_def_id, 3, "npc_def_id")
	assert_eq(back.display_name, spawn.display_name, "name")
	assert_eq(back.net_id, 612, "net_id")
	assert_eq(back.spawn_tick, 7000, "spawn_tick")
	assert_eq(back.realm, NetProtocol.Realm.NONE, "the Hollow has no realm")
	assert_true(back.state.equals_exact(spawn.state), "the state is exact")
	assert_eq(back.encode(), bytes, "re-encoding gives the same bytes")

	spawn.display_name = ""
	spawn.npc_def_id = 0x1FFFF
	var plain: NetMessages.EntitySpawn = NetMessages.EntitySpawn.decode(spawn.encode())
	if assert_not_null(plain, "an NPC without a name"):
		assert_eq(plain.npc_def_id, 0xFFFF, "the id is truncated to 16 bits")
		assert_eq(spawn.encode().size(), name_offset + 1 + 2, "10 B + state + 1 B + 2 B")

	# Without the two extra bytes, or with them on a player, it is not valid.
	assert_null(NetMessages.EntitySpawn.decode(bytes.slice(0, bytes.size() - 2)),
			"an NPC without its npc_def_id")
	assert_null(NetMessages.EntitySpawn.decode(bytes.slice(0, bytes.size() - 1)),
			"an NPC with half an id")
	var as_player: PackedByteArray = bytes.duplicate()
	as_player.encode_u8(3, NetProtocol.EntityKind.PLAYER)
	assert_null(NetMessages.EntitySpawn.decode(as_player), "a player does not carry npc_def_id")
	var player: NetMessages.EntitySpawn = _npc_spawn()
	player.kind = NetProtocol.EntityKind.PLAYER
	player.npc_def_id = 9
	var player_bytes: PackedByteArray = player.encode()
	assert_eq(player_bytes.size(), name_offset + 1 + name_bytes.size() + NetMessages.PLAYER_SPAWN_TAIL_SIZE,
			"a player does not write npc_def_id even if it is set (it carries its level and appearance, v7)")
	var as_npc: PackedByteArray = player_bytes.duplicate()
	as_npc.encode_u8(3, NetProtocol.EntityKind.NPC)
	assert_null(NetMessages.EntitySpawn.decode(as_npc), "an NPC needs its npc_def_id")


func test_structure_spawn_layout_and_roundtrip() -> void:
	var def: FortressDefinition = load(DEFINITION_PATH) as FortressDefinition
	var state: FortressState = _capturing_state(def)
	var spawn: NetMessages.EntitySpawn = NetMessages.EntitySpawn.for_fortress(77, 1000,
			DEFINITION_ID, state)
	var bytes: PackedByteArray = spawn.encode()
	assert_eq(bytes.size(), 10 + 1 + 14 + 1 + (10 * 3 + 6 * 6 + 6), "10 B + def_len + id + count + fields")
	assert_eq(bytes.decode_u8(0), 0x20, "u8 type at 0")
	assert_eq(bytes.decode_u16(1), 77, "u16 net_id at 1")
	assert_eq(bytes.decode_u8(3), NetProtocol.EntityKind.STRUCTURE, "u8 kind at 3 (4)")
	assert_eq(bytes.decode_u32(4), 1000, "u32 spawn_tick at 4")
	assert_eq(bytes.decode_u8(8), 0, "u8 realm at 8: 0, the owner field rules")
	assert_eq(bytes.decode_u8(9), 0, "u8 flags at 9")
	assert_eq(bytes.decode_u8(10), 14, "u8 def_len at 10")
	assert_eq(bytes.slice(11, 25).get_string_from_ascii(), DEFINITION_ID, "definition id at 11")
	assert_eq(bytes.decode_u8(25), 17, "u8 field_count at 25")
	assert_eq(bytes.decode_u8(26), FortressFields.OWNER, "the first field, at 26")
	assert_eq(bytes.decode_u8(27), U8, "owner is a u8")
	assert_eq(bytes.decode_u8(28), state.owner, "value of owner")

	var back: NetMessages.EntitySpawn = NetMessages.EntitySpawn.decode(bytes)
	if not assert_not_null(back, "decode of a structure SPAWN"):
		return
	assert_eq(back.kind, NetProtocol.EntityKind.STRUCTURE, "kind")
	assert_eq(back.net_id, 77, "net_id")
	assert_eq(back.spawn_tick, 1000, "spawn_tick")
	assert_eq(back.realm, 0, "realm")
	assert_eq(back.definition_id, DEFINITION_ID, "definition_id")
	assert_eq(back.fields.size(), 17, "the 17 fields")
	assert_null(back.state, "a structure does not carry a PlayerState")
	assert_false(back.is_yours, "it is not a character")
	var rebuilt := FortressState.initial(def, 0)
	assert_eq(back.to_object_state().apply_to_fortress(rebuilt), 17, "the fields are applied")
	_assert_same_fields(rebuilt, state, "estado del SPAWN")
	assert_eq(back.to_object_state().tick, 1000, "to_object_state uses the tick of the spawn")
	assert_eq(back.to_object_state().net_id, 77, "and the net_id")
	assert_eq(back.encode(), bytes, "re-encoding gives the same bytes")

	# The header flags travel too.
	spawn.teleport_counter = 2
	spawn.realm = NetProtocol.Realm.SOLMARCH
	var flagged: NetMessages.EntitySpawn = NetMessages.EntitySpawn.decode(spawn.encode())
	if assert_not_null(flagged, "with flags and realm in the header"):
		assert_eq(flagged.teleport_counter, 2, "counter")
		assert_eq(flagged.realm, NetProtocol.Realm.SOLMARCH, "realm from the header")


func test_structure_spawn_rejects_what_cannot_be_encoded() -> void:
	var def: FortressDefinition = load(DEFINITION_PATH) as FortressDefinition
	var good: NetMessages.EntitySpawn = NetMessages.EntitySpawn.for_fortress(1, 1, DEFINITION_ID,
			FortressState.initial(def, 0))
	assert_false(good.encode().is_empty(), "the base case is encoded")
	for bad_id: String in ["", "x".repeat(33), "a\tb", "ñandú"]:
		good.definition_id = bad_id
		assert_true(good.encode().is_empty(), "invalid definition id \"%s\"" % bad_id.c_escape())
	good.definition_id = "x".repeat(32)
	assert_false(good.encode().is_empty(), "32 characters do fit")
	good.definition_id = DEFINITION_ID
	var fields: Array[NetMessages.ObjectField] = good.fields.duplicate()
	good.fields.clear()
	assert_true(good.encode().is_empty(), "without fields")
	good.fields = fields.duplicate()
	good.fields.append(NetMessages.ObjectField.make(FortressFields.OWNER, U8, 1))
	assert_true(good.encode().is_empty(), "with a repeated field")
	good.fields = fields.duplicate()
	for extra: int in 20:
		good.fields.append(NetMessages.ObjectField.make(100 + extra, U8, 1))
	assert_true(good.encode().is_empty(), "with more than 32 fields")


func test_structure_spawn_rejects_malformed_bytes() -> void:
	var def: FortressDefinition = load(DEFINITION_PATH) as FortressDefinition
	var spawn: NetMessages.EntitySpawn = NetMessages.EntitySpawn.for_fortress(1, 1, "ab",
			FortressState.initial(def, 0))
	var bytes: PackedByteArray = spawn.encode()
	assert_not_null(NetMessages.EntitySpawn.decode(bytes), "the base case is valid")
	# def_len at 10, id at 11-12, field_count at 13, first field at 14.
	assert_eq(bytes.decode_u8(10), 2, "def_len")
	assert_eq(bytes.decode_u8(13), 17, "field_count")
	for bad_length: int in [0, 1, 3, 33, 255]:
		var tampered: PackedByteArray = bytes.duplicate()
		tampered.encode_u8(10, bad_length)
		assert_null(NetMessages.EntitySpawn.decode(tampered), "def_len %d" % bad_length)
	for bad_byte: int in [0x00, 0x07, 0x1F, 0x7F, 0x80, 0xC3]:
		var tampered: PackedByteArray = bytes.duplicate()
		tampered.encode_u8(11, bad_byte)
		assert_null(NetMessages.EntitySpawn.decode(tampered), "id with byte 0x%02X" % bad_byte)
	for bad_count: int in [0, 16, 18, 33, 255]:
		var tampered: PackedByteArray = bytes.duplicate()
		tampered.encode_u8(13, bad_count)
		assert_null(NetMessages.EntitySpawn.decode(tampered), "field_count %d" % bad_count)
	var bad_type: PackedByteArray = bytes.duplicate()
	bad_type.encode_u8(15, 9)
	assert_null(NetMessages.EntitySpawn.decode(bad_type), "unknown value_type")
	var repeated: PackedByteArray = bytes.duplicate()
	repeated.encode_u8(17, repeated.decode_u8(14))
	assert_null(NetMessages.EntitySpawn.decode(repeated), "two fields with the same id")
	assert_null(NetMessages.EntitySpawn.decode(bytes.slice(0, 10)), "only the header")
	assert_null(NetMessages.EntitySpawn.decode(bytes.slice(0, 11)), "without a definition id")
	# A structure with a type that is not its own is not read as a player or as an NPC.
	var as_player: PackedByteArray = bytes.duplicate()
	as_player.encode_u8(3, NetProtocol.EntityKind.PLAYER)
	assert_null(NetMessages.EntitySpawn.decode(as_player), "as a player")
	as_player.encode_u8(3, NetProtocol.EntityKind.NPC)
	assert_null(NetMessages.EntitySpawn.decode(as_player), "as an NPC")
	as_player.encode_u8(3, NetProtocol.EntityKind.PROJECTILE)
	assert_null(NetMessages.EntitySpawn.decode(as_player), "as a projectile")


func test_projectile_spawn_has_a_format_and_none_does_not() -> void:
	var spawn: NetMessages.EntitySpawn = _npc_spawn()
	spawn.kind = NetProtocol.EntityKind.PROJECTILE
	assert_eq(spawn.encode().size(), NetMessages.EntitySpawn.PROJECTILE_SIZE,
			"a projectile has a format since protocol 6 (32 B, without state or name)")
	spawn.kind = NetProtocol.EntityKind.NONE
	assert_true(spawn.encode().is_empty(), "the NONE type has no format")


# --- ENTITY_EVENT WAR and TELEGRAPH -----------------------------------------------------------

func test_war_event_layout_and_roundtrip() -> void:
	var war: NetMessages.EntityEvent = NetMessages.EntityEvent.war(900, 123456,
			WarEvents.FORT_CAPTURED, NetProtocol.Realm.SOLMARCH)
	var bytes: PackedByteArray = war.encode()
	assert_eq(bytes.size(), 11, "WAR: 11 B")
	assert_eq(bytes.decode_u8(0), 0x23, "u8 type at 0")
	assert_eq(bytes.decode_u16(1), 900, "u16 net_id (the fortress) at 1")
	assert_eq(bytes.decode_u32(3), 123456, "u32 tick at 3")
	assert_eq(bytes.decode_u8(7), 5, "u8 event at 7: WAR")
	assert_eq(bytes.decode_u8(8), 2, "u8 len at 8")
	assert_eq(bytes.decode_u8(9), WarEvents.FORT_CAPTURED, "u8 war_event at 9")
	assert_eq(bytes.decode_u8(10), NetProtocol.Realm.SOLMARCH, "u8 realm at 10")
	var back: NetMessages.EntityEvent = NetMessages.EntityEvent.decode(bytes)
	if not assert_not_null(back, "decode of the WAR"):
		return
	assert_eq(back.event, NetMessages.EntityEvent.Kind.WAR, "event")
	assert_eq(back.net_id, 900, "net_id")
	assert_eq(back.tick, 123456, "tick")
	assert_eq(back.war_event, WarEvents.FORT_CAPTURED, "war_event")
	assert_eq(back.war_realm, NetProtocol.Realm.SOLMARCH, "war_realm")
	assert_eq(back.encode(), bytes, "re-encoding gives the same bytes")
	# All the alerts and all the realms travel.
	for war_event: int in WarEvents.all_ids():
		for realm: int in 4:
			var each: NetMessages.EntityEvent = NetMessages.EntityEvent.decode(
					NetMessages.EntityEvent.war(1, 2, war_event, realm).encode())
			if assert_not_null(each, "alert %d, realm %d" % [war_event, realm]):
				assert_eq(each.war_event, war_event)
				assert_eq(each.war_realm, realm)
	# The tick edges.
	var edge: NetMessages.EntityEvent = NetMessages.EntityEvent.decode(
			NetMessages.EntityEvent.war(0xFFFF, 0xFFFFFFFF, WarEvents.FORT_RESET, 0).encode())
	if assert_not_null(edge, "maximum net_id and tick"):
		assert_eq(edge.net_id, 0xFFFF)
		assert_eq(edge.tick, 0xFFFFFFFF)


func test_war_event_rejects_inconsistent_data() -> void:
	var good: PackedByteArray = NetMessages.EntityEvent.war(900, 5, WarEvents.GATE_BROKEN, 1).encode()
	for bad_war_event: int in [0, WarEvents.LAST + 1, 100, 255]:
		var tampered: PackedByteArray = good.duplicate()
		tampered.encode_u8(9, bad_war_event)
		assert_null(NetMessages.EntityEvent.decode(tampered), "unknown alert %d" % bad_war_event)
	for bad_realm: int in [4, 5, 255]:
		var tampered: PackedByteArray = good.duplicate()
		tampered.encode_u8(10, bad_realm)
		assert_null(NetMessages.EntityEvent.decode(tampered), "realm %d" % bad_realm)
	for wrong_len: int in [0, 1, 3, 255]:
		var tampered: PackedByteArray = good.duplicate()
		tampered.encode_u8(8, wrong_len)
		assert_null(NetMessages.EntityEvent.decode(tampered), "declared len %d" % wrong_len)
	var longer: PackedByteArray = good.duplicate()
	longer.append(0)
	longer.encode_u8(8, 3)
	assert_null(NetMessages.EntityEvent.decode(longer), "consistent len and size but longer")
	assert_null(NetMessages.EntityEvent.decode(good.slice(0, 10)), "without the realm")


func test_telegraph_event_layout_and_roundtrip() -> void:
	var origin := Vector3(-12.34, 6.25, 140.5)
	var telegraph: NetMessages.EntityEvent = NetMessages.EntityEvent.telegraph(433, 123500, 17,
			NetMessages.EntityEvent.SHAPE_SECTOR, origin, 2.5, 450, 36)
	var bytes: PackedByteArray = telegraph.encode()
	assert_eq(bytes.size(), 26, "TELEGRAPH: 26 B")
	assert_eq(bytes.decode_u8(0), 0x23, "u8 type at 0")
	assert_eq(bytes.decode_u16(1), 433, "u16 net_id (the NPC) at 1")
	assert_eq(bytes.decode_u32(3), 123500, "u32 tick at 3")
	assert_eq(bytes.decode_u8(7), 6, "u8 event at 7: TELEGRAPH")
	assert_eq(bytes.decode_u8(8), 17, "u8 len at 8")
	assert_eq(bytes.decode_u16(9), 17, "u16 attack_id at 9")
	assert_eq(bytes.decode_u8(11), 1, "u8 shape at 11: sector")
	assert_eq(bytes.decode_u64(12), NetMath.pack_position(origin), "u64 packed position at 12")
	assert_eq(bytes.decode_u16(20), NetMath.quantize_yaw16(2.5), "u16 yaw at 20")
	assert_eq(bytes.decode_u16(22), 450, "u16 radius_cm at 22")
	assert_eq(bytes.decode_u16(24), 36, "u16 impact_in_ticks at 24")
	var back: NetMessages.EntityEvent = NetMessages.EntityEvent.decode(bytes)
	if not assert_not_null(back, "decode of the TELEGRAPH"):
		return
	assert_eq(back.event, NetMessages.EntityEvent.Kind.TELEGRAPH, "event")
	assert_eq(back.net_id, 433, "net_id")
	assert_eq(back.tick, 123500, "tick")
	assert_eq(back.attack_id, 17, "attack_id")
	assert_eq(back.shape, NetMessages.EntityEvent.SHAPE_SECTOR, "shape")
	assert_vec_near(back.position, origin, 0.0051, "position to 1 cm")
	assert_near(back.yaw, 2.5, TAU / 65536.0, "yaw to 16 bits")
	assert_eq(back.radius_cm, 450, "radius_cm")
	assert_near(back.get_radius(), 4.5, 1e-9, "radius in meters")
	assert_eq(back.impact_in_ticks, 36, "impact_in_ticks")
	assert_eq(back.encode(), bytes, "re-encoding gives the same bytes")

	# A circle, with the values at their extremes.
	var circle: NetMessages.EntityEvent = NetMessages.EntityEvent.telegraph(0xFFFF, 0xFFFFFFFF,
			0xFFFF, NetMessages.EntityEvent.SHAPE_CIRCLE, Vector3(5000.0, -5000.0, 0.0), -1.0,
			70000, -4)
	var circle_back: NetMessages.EntityEvent = NetMessages.EntityEvent.decode(circle.encode())
	if assert_not_null(circle_back, "a circle with extreme values"):
		assert_eq(circle_back.shape, NetMessages.EntityEvent.SHAPE_CIRCLE, "circle")
		assert_eq(circle_back.attack_id, 0xFFFF, "maximum attack_id")
		assert_eq(circle_back.radius_cm, 0xFFFF, "saturated radius")
		assert_eq(circle_back.impact_in_ticks, 0, "negative ticks saturated to 0")
		assert_near(circle_back.yaw, TAU - 1.0, TAU / 65536.0, "negative yaw in [0, TAU)")
		assert_vec_near(circle_back.position, Vector3(5000.0, -5000.0, 0.0), 0.0051, "position")


func test_telegraph_event_rejects_inconsistent_data() -> void:
	var good: PackedByteArray = NetMessages.EntityEvent.telegraph(433, 5, 17,
			NetMessages.EntityEvent.SHAPE_SECTOR, Vector3(1.0, 2.0, 3.0), 1.0, 300, 20).encode()
	assert_not_null(NetMessages.EntityEvent.decode(good), "the base case is valid")
	for bad_shape: int in [2, 3, 255]:
		var tampered: PackedByteArray = good.duplicate()
		tampered.encode_u8(11, bad_shape)
		assert_null(NetMessages.EntityEvent.decode(tampered), "shape %d" % bad_shape)
	for wrong_len: int in [0, 16, 18, 255]:
		var tampered: PackedByteArray = good.duplicate()
		tampered.encode_u8(8, wrong_len)
		assert_null(NetMessages.EntityEvent.decode(tampered), "declared len %d" % wrong_len)
	var longer: PackedByteArray = good.duplicate()
	longer.append(0)
	longer.encode_u8(8, 18)
	assert_null(NetMessages.EntityEvent.decode(longer), "consistent len and size but longer")
	assert_null(NetMessages.EntityEvent.decode(good.slice(0, 25)), "without the last byte")
	# Combat events stay the same as before.
	for event: NetMessages.EntityEvent in [
			NetMessages.EntityEvent.hit(1, 2, 3, 4, 0, 0, 5), NetMessages.EntityEvent.death(1, 2, 3, 4),
			NetMessages.EntityEvent.kill(1, 2, 3, 4, PackedInt32Array([5])),
			NetMessages.EntityEvent.respawn(1, 2, 3)]:
		assert_eq(NetMessages.EntityEvent.decode(event.encode()).event, event.event,
				"event %d does not change" % event.event)


# --- UNSTUCK_REQUEST --------------------------------------------------------------------------

func test_unstuck_request_layout() -> void:
	var bytes: PackedByteArray = NetMessages.UnstuckRequest.new().encode()
	assert_eq(bytes, PackedByteArray([0x06]), "UNSTUCK_REQUEST: 1 B, type 0x06")
	assert_not_null(NetMessages.UnstuckRequest.decode(bytes), "decode")
	assert_null(NetMessages.UnstuckRequest.decode(PackedByteArray()), "empty")
	assert_null(NetMessages.UnstuckRequest.decode(PackedByteArray([0x06, 0])), "with one more byte")
	assert_null(NetMessages.UnstuckRequest.decode(PackedByteArray([0x05])), "another type")
	assert_eq(NetMessages.peek_type(bytes), NetProtocol.MSG_UNSTUCK_REQUEST, "peek_type")


# --- SCOREBOARD -------------------------------------------------------------------------------

func test_scoreboard_layout_and_roundtrip() -> void:
	var board := NetMessages.Scoreboard.new()
	board.page_index = 1
	board.page_count = 3
	board.rows.append(NetMessages.ScoreRow.make(0x1234, 12, 3, 7, 0xABCDEF01, 600, 0xFFFFFF00))
	board.rows.append(NetMessages.ScoreRow.make(2, 0, 0, 0, 0, 0, 0))
	var bytes: PackedByteArray = board.encode()
	assert_eq(bytes.size(), 4 + 2 * 18, "4 B of header + 18 B per row")
	assert_eq(bytes.decode_u8(0), 0x32, "u8 type at 0")
	assert_eq(bytes.decode_u8(1), 1, "u8 page_index at 1")
	assert_eq(bytes.decode_u8(2), 3, "u8 page_count at 2")
	assert_eq(bytes.decode_u8(3), 2, "u8 row_count at 3")
	assert_eq(bytes.decode_u16(4), 0x1234, "row 0: u16 net_id at 4")
	assert_eq(bytes.decode_u16(6), 12, "u16 kills at 6")
	assert_eq(bytes.decode_u16(8), 3, "u16 deaths at 8")
	assert_eq(bytes.decode_u16(10), 7, "u16 assists at 10")
	assert_eq(bytes.decode_u32(12), 0xABCDEF01, "u32 gate damage at 12")
	assert_eq(bytes.decode_u16(16), 600, "u16 seconds in the circle at 16")
	assert_eq(bytes.decode_u32(18), 0xFFFFFF00, "u32 merits at 18")
	assert_eq(bytes.decode_u16(22), 2, "row 1: u16 net_id at 22")
	var back: NetMessages.Scoreboard = NetMessages.Scoreboard.decode(bytes)
	if not assert_not_null(back, "decode"):
		return
	assert_eq(back.page_index, 1, "page_index")
	assert_eq(back.page_count, 3, "page_count")
	assert_eq(back.rows.size(), 2, "rows")
	var row: NetMessages.ScoreRow = back.rows[0]
	assert_eq(row.net_id, 0x1234, "net_id")
	assert_eq(row.kills, 12, "kills")
	assert_eq(row.deaths, 3, "deaths")
	assert_eq(row.assists, 7, "assists")
	assert_eq(row.gate_damage, 0xABCDEF01, "gate damage")
	assert_eq(row.circle_seconds, 600, "seconds in the circle")
	assert_eq(row.merits, 0xFFFFFF00, "merits")
	assert_eq(back.encode(), bytes, "re-encoding gives the same bytes")

	# The counters saturate, they do not wrap around.
	var big := NetMessages.Scoreboard.new()
	big.rows.append(NetMessages.ScoreRow.make(1, 70000, 65536, 99999, 0x1FFFFFFFF, 1000000, -5))
	var big_back: NetMessages.Scoreboard = NetMessages.Scoreboard.decode(big.encode())
	if assert_not_null(big_back, "huge counters"):
		var saturated: NetMessages.ScoreRow = big_back.rows[0]
		assert_eq(saturated.kills, 0xFFFF, "saturated kills")
		assert_eq(saturated.deaths, 0xFFFF, "saturated deaths")
		assert_eq(saturated.assists, 0xFFFF, "saturated assists")
		assert_eq(saturated.gate_damage, 0xFFFFFFFF, "saturated damage")
		assert_eq(saturated.circle_seconds, 0xFFFF, "saturated seconds")
		assert_eq(saturated.merits, 0, "negative merits to 0")


func test_scoreboard_page_limit_fits_one_packet() -> void:
	assert_eq(NetMessages.ScoreRow.SIZE, 18, "a row is 18 B")
	assert_eq(NetMessages.Scoreboard.MAX_ROWS, 66, "66 rows per page")
	var full := NetMessages.Scoreboard.new()
	for i: int in NetMessages.Scoreboard.MAX_ROWS:
		full.rows.append(NetMessages.ScoreRow.make(i + 1, i, i, i, i, i, i))
	var bytes: PackedByteArray = full.encode()
	assert_eq(bytes.size(), 4 + 66 * 18, "a full page: 1192 B")
	assert_true(bytes.size() <= NetProtocol.MAX_PACKET_BYTES, "fits in a packet")
	assert_true(4 + 67 * 18 > NetProtocol.MAX_PACKET_BYTES, "with one more row it would no longer fit")
	var back: NetMessages.Scoreboard = NetMessages.Scoreboard.decode(bytes)
	if assert_not_null(back, "the full page decodes"):
		assert_eq(back.rows.size(), 66, "66 rows")
		assert_eq(back.rows[65].net_id, 66, "and they arrive in order")
	full.rows.append(NetMessages.ScoreRow.make(99, 0, 0, 0, 0, 0, 0))
	assert_true(full.encode().is_empty(), "67 rows are not encoded: they have to be split with split()")
	# Without rows is also valid (the client clears the scoreboard).
	var empty := NetMessages.Scoreboard.new()
	assert_eq(empty.encode(), PackedByteArray([0x32, 0, 1, 0]), "an empty page is 4 B")
	assert_eq(NetMessages.Scoreboard.decode(empty.encode()).rows.size(), 0, "without rows")


func test_scoreboard_split_into_pages() -> void:
	var empty_pages: Array[NetMessages.Scoreboard] = NetMessages.Scoreboard.split(
			[] as Array[NetMessages.ScoreRow])
	assert_eq(empty_pages.size(), 1, "without rows, one empty page")
	assert_eq(empty_pages[0].rows.size(), 0)
	for count: int in [1, 66, 67, 132, 133, 200, 500]:
		var rows: Array[NetMessages.ScoreRow] = []
		for i: int in count:
			rows.append(NetMessages.ScoreRow.make(i + 1, i % 100, 1, 2, i * 10, i, i * 1000))
		var pages: Array[NetMessages.Scoreboard] = NetMessages.Scoreboard.split(rows)
		var expected_pages: int = ceili(count / 66.0)
		assert_eq(pages.size(), expected_pages, "%d rows: %d pages" % [count, expected_pages])
		var next_id: int = 1
		for page_index: int in pages.size():
			var page: NetMessages.Scoreboard = pages[page_index]
			assert_eq(page.page_index, page_index, "page index")
			assert_eq(page.page_count, expected_pages, "total pages")
			var bytes: PackedByteArray = page.encode()
			assert_false(bytes.is_empty(), "page %d is encoded" % page_index)
			assert_true(bytes.size() <= NetProtocol.MAX_PACKET_BYTES, "fits in a packet")
			var decoded: NetMessages.Scoreboard = NetMessages.Scoreboard.decode(bytes)
			if not assert_not_null(decoded, "page %d is decoded" % page_index):
				return
			assert_eq(decoded.page_index, page_index)
			assert_eq(decoded.page_count, expected_pages)
			if page_index < pages.size() - 1:
				assert_eq(decoded.rows.size(), 66, "the intermediate pages are full")
			for row: NetMessages.ScoreRow in decoded.rows:
				assert_eq(row.net_id, next_id, "the rows stay in order")
				next_id += 1
		assert_eq(next_id - 1, count, "no row is lost or repeated (%d)" % count)


func test_scoreboard_rejects_malformed_pages() -> void:
	var board := NetMessages.Scoreboard.new()
	board.page_index = 0
	board.page_count = 2
	board.rows.append(NetMessages.ScoreRow.make(1, 1, 1, 1, 1, 1, 1))
	var good: PackedByteArray = board.encode()
	assert_not_null(NetMessages.Scoreboard.decode(good), "the base case is valid")
	var no_pages: PackedByteArray = good.duplicate()
	no_pages.encode_u8(2, 0)
	assert_null(NetMessages.Scoreboard.decode(no_pages), "total pages 0")
	var out_of_range: PackedByteArray = good.duplicate()
	out_of_range.encode_u8(1, 2)
	assert_null(NetMessages.Scoreboard.decode(out_of_range), "index equal to the total")
	out_of_range.encode_u8(1, 255)
	assert_null(NetMessages.Scoreboard.decode(out_of_range), "index greater than the total")
	for wrong_rows: int in [0, 2, 67, 255]:
		var tampered: PackedByteArray = good.duplicate()
		tampered.encode_u8(3, wrong_rows)
		assert_null(NetMessages.Scoreboard.decode(tampered), "row_count %d that does not add up" % wrong_rows)
	var too_many := PackedByteArray([0x32, 0, 1, 67])
	too_many.resize(4 + 67 * 18)
	too_many.encode_u8(0, 0x32)
	too_many.encode_u8(2, 1)
	too_many.encode_u8(3, 67)
	assert_null(NetMessages.Scoreboard.decode(too_many), "67 rows even though the size adds up")
	assert_null(NetMessages.Scoreboard.decode(good.slice(0, good.size() - 1)), "half a row")
	assert_null(NetMessages.Scoreboard.decode(PackedByteArray([0x32, 0, 1])), "incomplete header")
	# Pages that are not encoded.
	var bad_page := NetMessages.Scoreboard.new()
	bad_page.page_count = 0
	assert_true(bad_page.encode().is_empty(), "total 0")
	bad_page.page_count = 2
	bad_page.page_index = 2
	assert_true(bad_page.encode().is_empty(), "index outside the total")
	bad_page.page_index = 0
	bad_page.page_count = 256
	assert_true(bad_page.encode().is_empty(), "more than 255 pages")


# --- Debug commands 7 to 12 -------------------------------------------------------------------

func test_debug_commands_7_to_12_validate_their_data() -> void:
	# Without data: 7 unstuck, 8 fort_reset, 10 fort_kill_captain.
	for command_id: int in [NetProtocol.DEBUG_UNSTUCK, NetProtocol.DEBUG_FORT_RESET,
			NetProtocol.DEBUG_FORT_KILL_CAPTAIN]:
		var simple: NetMessages.DebugCommand = NetMessages.DebugCommand.simple(command_id)
		assert_eq(simple.encode(), PackedByteArray([0x04, command_id]), "command %d without data" % command_id)
		var back: NetMessages.DebugCommand = NetMessages.DebugCommand.decode(simple.encode())
		if assert_not_null(back, "command %d without data" % command_id):
			assert_eq(back.command, command_id)
		assert_null(NetMessages.DebugCommand.decode(PackedByteArray([0x04, command_id, 0])),
				"command %d does not accept data" % command_id)
		assert_null(NetMessages.DebugCommand.decode(PackedByteArray([0x04, command_id, 1, 2])),
				"command %d does not accept more data" % command_id)
	# 9 fort_owner: a realm from 0 to 3.
	for realm: int in 4:
		var owner: NetMessages.DebugCommand = NetMessages.DebugCommand.fort_owner(realm)
		assert_eq(owner.encode(), PackedByteArray([0x04, 9, realm]), "fort_owner %d" % realm)
		assert_not_null(NetMessages.DebugCommand.decode(owner.encode()), "fort_owner %d is valid" % realm)
	for bad_realm: int in [4, 5, 255]:
		assert_null(NetMessages.DebugCommand.decode(PackedByteArray([0x04, 9, bad_realm])),
				"fort_owner with realm %d" % bad_realm)
	assert_null(NetMessages.DebugCommand.decode(PackedByteArray([0x04, 9])), "fort_owner without a realm")
	assert_null(NetMessages.DebugCommand.decode(PackedByteArray([0x04, 9, 1, 1])), "fort_owner with 2 B")
	# 11 fort_capture_speed: a factor from 1 to 255.
	for factor: int in [1, 2, 10, 255]:
		var speed: NetMessages.DebugCommand = NetMessages.DebugCommand.fort_capture_speed(factor)
		assert_eq(speed.encode(), PackedByteArray([0x04, 11, factor]), "fort_capture_speed %d" % factor)
		assert_not_null(NetMessages.DebugCommand.decode(speed.encode()), "factor %d is valid" % factor)
	assert_null(NetMessages.DebugCommand.decode(PackedByteArray([0x04, 11, 0])), "factor 0")
	assert_null(NetMessages.DebugCommand.decode(PackedByteArray([0x04, 11])), "without a factor")
	assert_null(NetMessages.DebugCommand.decode(PackedByteArray([0x04, 11, 2, 0])), "factor with 2 B")
	# 12 npc_debug: 0 or 1.
	assert_eq(NetMessages.DebugCommand.npc_debug(true).encode(), PackedByteArray([0x04, 12, 1]), "enable")
	assert_eq(NetMessages.DebugCommand.npc_debug(false).encode(), PackedByteArray([0x04, 12, 0]), "disable")
	assert_not_null(NetMessages.DebugCommand.decode(PackedByteArray([0x04, 12, 0])), "0 is valid")
	assert_not_null(NetMessages.DebugCommand.decode(PackedByteArray([0x04, 12, 1])), "1 is valid")
	assert_null(NetMessages.DebugCommand.decode(PackedByteArray([0x04, 12, 2])), "2 no")
	assert_null(NetMessages.DebugCommand.decode(PackedByteArray([0x04, 12])), "without data")
	# The phase 3 commands and the ids nobody knows still pass through as they are (the server judges them).
	# Those from 13 to 16 are validated by the decode since protocol 6 (test_net_messages_v6.gd).
	for command_id: int in [2, 3, 4, 5, 6, 17, 99, 255]:
		var other := PackedByteArray([0x04, command_id, 1, 2, 3])
		var other_back: NetMessages.DebugCommand = NetMessages.DebugCommand.decode(other)
		if assert_not_null(other_back, "command %d is not validated here" % command_id):
			assert_eq(other_back.payload, PackedByteArray([1, 2, 3]), "data of command %d" % command_id)


# --- Malformed messages and fuzz --------------------------------------------------------------

func test_malformed_v3_messages_return_null() -> void:
	var samples: Array = _samples()
	var decoders: Array[Callable] = _all_decoders()
	for entry: Array in samples:
		var label: String = entry[0]
		var bytes: PackedByteArray = entry[1]
		var decoder: Callable = entry[2]
		assert_not_null(decoder.call(bytes), "%s: the valid message decodes" % label)
		for length: int in bytes.size():
			if decoder.call(bytes.slice(0, length)) != null:
				fail("%s truncated to %d of %d B should be null" % [label, length, bytes.size()])
				break
		for extra: int in [1, 2, 20]:
			var longer: PackedByteArray = bytes.duplicate()
			longer.resize(bytes.size() + extra)
			if decoder.call(longer) != null:
				fail("%s with %d B extra should be null" % [label, extra])
		var wrong: PackedByteArray = bytes.duplicate()
		wrong[0] = 0x7F
		assert_null(decoder.call(wrong), "%s with byte 0 changed" % label)
		# No other decoder accepts these bytes.
		for other: Callable in decoders:
			if other != decoder and other.call(bytes) != null:
				fail("%s was decoded by another decoder" % label)
	for decoder: Callable in decoders:
		assert_null(decoder.call(PackedByteArray()), "empty buffer")
		assert_null(decoder.call(PackedByteArray([0])), "a single null byte")


func test_fuzz_v3_decoders_never_error() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = FUZZ_SEED
	var decoders: Array[Callable] = _all_decoders()
	var samples: Array = _samples()
	var type_bytes: Array[int] = [NetProtocol.MSG_ENTITY_SPAWN, NetProtocol.MSG_OBJECT_STATE,
			NetProtocol.MSG_ENTITY_EVENT, NetProtocol.MSG_UNSTUCK_REQUEST, NetProtocol.MSG_SCOREBOARD,
			NetProtocol.MSG_DEBUG_COMMAND]
	var decoded_count: int = 0
	var mutated_decoded: int = 0
	for i: int in FUZZ_BUFFERS:
		var bytes := PackedByteArray()
		var mode: int = i % 4
		if mode == 0:
			var length: int = rng.randi_range(0, 40)
			if rng.randf() >= 0.6:
				length = rng.randi_range(0, 1300)
			bytes.resize(length)
			for j: int in length:
				bytes[j] = rng.randi() & 0xFF
		elif mode == 1:
			var length: int = rng.randi_range(1, 120)
			bytes.resize(length)
			for j: int in length:
				bytes[j] = rng.randi() & 0xFF
			bytes[0] = type_bytes[rng.randi() % type_bytes.size()]
		elif mode == 2:
			# One of the example messages with a few bytes changed, trimmed or extended.
			bytes = (samples[rng.randi() % samples.size()][1] as PackedByteArray).duplicate()
			for _k: int in rng.randi_range(0, 3):
				bytes[rng.randi() % bytes.size()] = rng.randi() & 0xFF
			var roll: float = rng.randf()
			if roll < 0.2:
				bytes.resize(rng.randi_range(0, bytes.size()))
			elif roll < 0.3:
				bytes.append(rng.randi() & 0xFF)
		else:
			# An OBJECT_STATE or a structure SPAWN with random counters and types.
			var as_spawn: bool = rng.randf() < 0.5
			bytes = _random_fielded_message(rng, as_spawn)
		for decoder: Callable in decoders:
			var result: Variant = decoder.call(bytes)
			if result == null:
				continue
			decoded_count += 1
			if mode == 2:
				mutated_decoded += 1
			if result is NetMessages.ObjectState:
				var object_state: NetMessages.ObjectState = result
				assert_true(object_state.fields.size() >= 1 and object_state.fields.size() <= 32,
						"a decoded OBJECT_STATE has 1 to 32 fields")
				assert_eq(object_state.encode(), bytes, "and re-encodes the same")
			elif result is NetMessages.Scoreboard:
				var board: NetMessages.Scoreboard = result
				assert_true(board.rows.size() <= NetMessages.Scoreboard.MAX_ROWS, "bounded rows")
				assert_eq(board.encode(), bytes, "and re-encodes the same")
			elif result is NetMessages.EntitySpawn:
				var spawn: NetMessages.EntitySpawn = result
				if spawn.kind == NetProtocol.EntityKind.STRUCTURE:
					assert_true(spawn.definition_id.length() >= 1 and spawn.definition_id.length() <= 32,
							"a decoded structure has a valid definition id")
					assert_true(spawn.fields.size() >= 1 and spawn.fields.size() <= 32, "and its fields")
	assert_true(mutated_decoded > 100, "the fuzz reaches valid messages (%d)" % mutated_decoded)
	assert_true(decoded_count >= mutated_decoded, "consistent counters")


# --- Utilities --------------------------------------------------------------------------------

## [label, valid bytes, decoder] of each new message and of some from version 2.
func _samples() -> Array:
	var def: FortressDefinition = load(DEFINITION_PATH) as FortressDefinition
	var state: FortressState = _capturing_state(def)
	var board := NetMessages.Scoreboard.new()
	board.page_index = 1
	board.page_count = 2
	board.rows.append(NetMessages.ScoreRow.make(5, 1, 2, 3, 400, 50, 600))
	board.rows.append(NetMessages.ScoreRow.make(6, 7, 8, 9, 1000, 20, 3000))
	var hello := NetMessages.Hello.new()
	hello.display_name = "Ana"
	var welcome := NetMessages.Welcome.new()
	welcome.zone_id = "vado_gris"
	var reject := NetMessages.Reject.new()
	reject.result = NetProtocol.Result.IMBALANCE
	reject.text = NetProtocol.result_text(NetProtocol.Result.IMBALANCE)
	var notice := NetMessages.Notice.new()
	notice.text = "Hola"
	var despawn := NetMessages.EntityDespawn.new()
	despawn.net_id = 4
	var player := NetMessages.EntitySpawn.new()
	player.net_id = 9
	player.state = PlayerState.new()
	player.display_name = "Ana"
	return [
		["OBJECT_STATE", NetMessages.ObjectState.from_fortress(9, 400, state).encode(),
				NetMessages.ObjectState.decode],
		["OBJECT_STATE de un campo", _with(PackedByteArray([0x22, 7, 0, 100, 0, 0, 0, 1]),
				[5, U8, 9]), NetMessages.ObjectState.decode],
		["ENTITY_SPAWN STRUCTURE", NetMessages.EntitySpawn.for_fortress(77, 1000, DEFINITION_ID,
				state).encode(), NetMessages.EntitySpawn.decode],
		["ENTITY_SPAWN NPC", _npc_spawn().encode(), NetMessages.EntitySpawn.decode],
		["ENTITY_SPAWN PLAYER", player.encode(), NetMessages.EntitySpawn.decode],
		["ENTITY_EVENT WAR", NetMessages.EntityEvent.war(900, 5, WarEvents.CAPTURE_STARTED, 1).encode(),
				NetMessages.EntityEvent.decode],
		["ENTITY_EVENT TELEGRAPH", NetMessages.EntityEvent.telegraph(433, 5, 17,
				NetMessages.EntityEvent.SHAPE_CIRCLE, Vector3(1.0, 2.0, 3.0), 1.0, 300, 20).encode(),
				NetMessages.EntityEvent.decode],
		["ENTITY_EVENT HIT", NetMessages.EntityEvent.hit(1, 2, 3, 4, 0, 0, 5).encode(),
				NetMessages.EntityEvent.decode],
		["UNSTUCK_REQUEST", NetMessages.UnstuckRequest.new().encode(),
				NetMessages.UnstuckRequest.decode],
		["SCOREBOARD", board.encode(), NetMessages.Scoreboard.decode],
		["DEBUG_COMMAND fort_owner", NetMessages.DebugCommand.fort_owner(2).encode(),
				NetMessages.DebugCommand.decode],
		["DEBUG_COMMAND fort_reset", NetMessages.DebugCommand.simple(NetProtocol.DEBUG_FORT_RESET).encode(),
				NetMessages.DebugCommand.decode],
		["HELLO", hello.encode(), NetMessages.Hello.decode],
		["WELCOME", welcome.encode(), NetMessages.Welcome.decode],
		["REJECT", reject.encode(), NetMessages.Reject.decode],
		["CLIENT_READY", NetMessages.ClientReady.new().encode(), NetMessages.ClientReady.decode],
		["CLIENT_LEAVE", NetMessages.ClientLeave.new().encode(), NetMessages.ClientLeave.decode],
		["RESPAWN_REQUEST", NetMessages.RespawnRequest.new().encode(), NetMessages.RespawnRequest.decode],
		["NOTICE", notice.encode(), NetMessages.Notice.decode],
		["ENTITY_DESPAWN", despawn.encode(), NetMessages.EntityDespawn.decode],
		["SNAPSHOT", NetMessages.Snapshot.new().encode(), NetMessages.Snapshot.decode],
	]


func _all_decoders() -> Array[Callable]:
	var result: Array[Callable] = [
		NetMessages.Hello.decode, NetMessages.Welcome.decode, NetMessages.Reject.decode,
		NetMessages.InputBatch.decode, NetMessages.ClientReady.decode,
		NetMessages.ClientLeave.decode, NetMessages.DebugCommand.decode,
		NetMessages.Snapshot.decode, NetMessages.EntitySpawn.decode,
		NetMessages.EntityDespawn.decode, NetMessages.Notice.decode,
		NetMessages.EntityEvent.decode, NetMessages.RespawnRequest.decode,
		NetMessages.ObjectState.decode, NetMessages.UnstuckRequest.decode,
		NetMessages.Scoreboard.decode,
	]
	return result


## [param header] followed by [param tail] (loose bytes).
func _with(header: PackedByteArray, tail: Array[int]) -> PackedByteArray:
	var bytes: PackedByteArray = header.duplicate()
	for value: int in tail:
		bytes.append(value)
	return bytes


## A fortress from the Vado Gris definition with a capture in progress (2 attackers from
## Vardheim since tick 101).
func _capturing_state(def: FortressDefinition) -> FortressState:
	var state := FortressState.initial(def, 0)
	state.on_captain_died(100, NetProtocol.Realm.VARDHEIM)
	state.advance(def, 101, PackedInt32Array([0, 2, 0, 0]))
	return state


func _npc_spawn() -> NetMessages.EntitySpawn:
	var spawn := NetMessages.EntitySpawn.new()
	spawn.net_id = 612
	spawn.kind = NetProtocol.EntityKind.NPC
	spawn.spawn_tick = 7000
	spawn.realm = NetProtocol.Realm.NONE
	var state := PlayerState.new()
	state.position = Vector3(3.5, 0.0, -9.25)
	state.yaw = PlayerState.to_f32(1.0)
	state.grounded = true
	state.last_input_tick = 7000
	spawn.state = state
	spawn.display_name = "Hueco ñ"
	spawn.npc_def_id = 3
	return spawn


func _assert_same_fields(actual: FortressState, expected: FortressState, label: String) -> void:
	for field_id: int in FortressFields.all_ids():
		assert_eq(FortressFields.get_value(actual, field_id), FortressFields.get_value(expected, field_id),
				"%s: field %s" % [label, FortressFields.name_of(field_id)])


## An OBJECT_STATE ([param as_spawn] false) or a structure ENTITY_SPAWN with random counters, ids and
## value types.
func _random_fielded_message(rng: RandomNumberGenerator, as_spawn: bool) -> PackedByteArray:
	var bytes := PackedByteArray()
	if as_spawn:
		bytes.append(NetProtocol.MSG_ENTITY_SPAWN)
		for _i: int in 2:
			bytes.append(rng.randi() & 0xFF)
		bytes.append(NetProtocol.EntityKind.STRUCTURE)
		for _i: int in 6:
			bytes.append(rng.randi() & 0xFF)
		var definition_length: int = rng.randi_range(0, 34)
		bytes.append(definition_length)
		for _i: int in definition_length:
			bytes.append(rng.randi_range(0x20, 0x7E) if rng.randf() < 0.95 else rng.randi() & 0xFF)
	else:
		bytes.append(NetProtocol.MSG_OBJECT_STATE)
		for _i: int in 6:
			bytes.append(rng.randi() & 0xFF)
	var count: int = rng.randi_range(0, 34)
	bytes.append(count)
	for _i: int in count:
		bytes.append(rng.randi_range(0, 6))
		bytes.append(rng.randi_range(0, 5))
		for _j: int in rng.randi_range(0, 5):
			bytes.append(rng.randi() & 0xFF)
	return bytes
