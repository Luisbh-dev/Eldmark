class_name FortressFields
extends RefCounted
## Ids of a fort's fields in OBJECT_STATE (docs/fuerte.md, section 2) and how each one travels: its
## value type in the message and its read and write on a [FortressState].
## [br][br]
## OBJECT_STATE carries, per field, [code]u8 field_id[/code], [code]u8 value_type[/code] and the
## value. The types are those of [enum ValueType] (1 u8, 2 u16, 3 u32, 4 s32). An unknown
## [code]field_id[/code] is skipped when decoding (forward compatibility); a known one with another
## value type is not valid.
## [br][br]
## Booleans travel as 0 or 1. Each realm's presence (fields 14 to 17) is a u8 per realm, from 0
## (neutral) to 3. Ticks are u32 and the capture speed, which can be negative, s32.
## [br][br]
## Shared: depends on neither the client nor the server.

## Value type of a field in the message.
enum ValueType { U8 = 1, U16 = 2, U32 = 3, S32 = 4 }

const OWNER: int = 1
const PHASE: int = 2
const PHASE_TICK: int = 3
const CAPTAIN_ALIVE: int = 4
const GUARDS_ALIVE: int = 5
const GATE_HEALTH: int = 6
const GATE_MAX: int = 7
const CAPTURE_REALM: int = 8
const CAPTURE_START_TICK: int = 9
const CAPTURE_RATE: int = 10
const CAPTURE_PROGRESS_AT_START: int = 11
const CONTESTED: int = 12
const UNDER_ATTACK_UNTIL_TICK: int = 13
## Presence of realm 0 (neutral); those of realms 1 to 3 are this id plus the realm code.
const PRESENCE_BASE: int = 14

const FIRST: int = OWNER
const LAST: int = PRESENCE_BASE + 3
## Realms with a presence field (network codes 0 to 3).
const PRESENCE_REALMS: int = 4

## Id -> [name, value type].
const _TABLE: Dictionary = {
	OWNER: [&"owner", ValueType.U8],
	PHASE: [&"phase", ValueType.U8],
	PHASE_TICK: [&"phase_tick", ValueType.U32],
	CAPTAIN_ALIVE: [&"captain_alive", ValueType.U8],
	GUARDS_ALIVE: [&"guards_alive", ValueType.U8],
	GATE_HEALTH: [&"gate_health", ValueType.U32],
	GATE_MAX: [&"gate_max", ValueType.U32],
	CAPTURE_REALM: [&"capture_realm", ValueType.U8],
	CAPTURE_START_TICK: [&"capture_start_tick", ValueType.U32],
	CAPTURE_RATE: [&"capture_rate", ValueType.S32],
	CAPTURE_PROGRESS_AT_START: [&"capture_progress_at_start", ValueType.U32],
	CONTESTED: [&"contested", ValueType.U8],
	UNDER_ATTACK_UNTIL_TICK: [&"under_attack_until_tick", ValueType.U32],
	PRESENCE_BASE: [&"presence_0", ValueType.U8],
	PRESENCE_BASE + 1: [&"presence_1", ValueType.U8],
	PRESENCE_BASE + 2: [&"presence_2", ValueType.U8],
	PRESENCE_BASE + 3: [&"presence_3", ValueType.U8],
}


## All field ids, in order.
static func all_ids() -> PackedInt32Array:
	var ids := PackedInt32Array()
	for id: int in range(FIRST, LAST + 1):
		ids.append(id)
	return ids


## true if [param field_id] is a known field (1 to 17).
static func is_known(field_id: int) -> bool:
	return _TABLE.has(field_id)


## Name of the field (that of the [FortressState] member); empty if unknown.
static func name_of(field_id: int) -> StringName:
	if not _TABLE.has(field_id):
		return &""
	return (_TABLE[field_id] as Array)[0]


## Value type ([enum ValueType]) the field travels with, or 0 if unknown.
static func value_type(field_id: int) -> int:
	if not _TABLE.has(field_id):
		return 0
	return (_TABLE[field_id] as Array)[1]


## Id of the presence field of realm [param realm_code] (0 to 3), or -1 if the code is not valid.
static func presence_field(realm_code: int) -> int:
	if realm_code < 0 or realm_code >= PRESENCE_REALMS:
		return -1
	return PRESENCE_BASE + realm_code


## Number of bytes of the value of a field of type [param type] (0 if the type does not exist).
static func value_size(type: int) -> int:
	match type:
		ValueType.U8:
			return 1
		ValueType.U16:
			return 2
		ValueType.U32, ValueType.S32:
			return 4
	return 0


## true if [param value] fits the type of field [param field_id].
static func fits(field_id: int, value: int) -> bool:
	match value_type(field_id):
		ValueType.U8:
			return value >= 0 and value <= 0xFF
		ValueType.U16:
			return value >= 0 and value <= 0xFFFF
		ValueType.U32:
			return value >= 0 and value <= 0xFFFFFFFF
		ValueType.S32:
			return value >= -0x80000000 and value <= 0x7FFFFFFF
	return false


## Integer value of field [param field_id] in [param state] (booleans as 0 or 1). 0 if the id is
## unknown.
static func get_value(state: FortressState, field_id: int) -> int:
	match field_id:
		OWNER:
			return state.owner
		PHASE:
			return state.phase
		PHASE_TICK:
			return state.phase_tick
		CAPTAIN_ALIVE:
			return 1 if state.captain_alive else 0
		GUARDS_ALIVE:
			return state.guards_alive
		GATE_HEALTH:
			return state.gate_health
		GATE_MAX:
			return state.gate_max
		CAPTURE_REALM:
			return state.capture_realm
		CAPTURE_START_TICK:
			return state.capture_start_tick
		CAPTURE_RATE:
			return state.capture_rate
		CAPTURE_PROGRESS_AT_START:
			return state.capture_progress_at_start
		CONTESTED:
			return 1 if state.contested else 0
		UNDER_ATTACK_UNTIL_TICK:
			return state.under_attack_until_tick
	if field_id >= PRESENCE_BASE and field_id <= LAST:
		return state.presence[field_id - PRESENCE_BASE]
	return 0


## Sets field [param field_id] of [param state] to [param value]. Returns false (touching nothing)
## if the id is unknown or the value does not fit the field's type.
static func set_value(state: FortressState, field_id: int, value: int) -> bool:
	if not is_known(field_id) or not fits(field_id, value):
		return false
	match field_id:
		OWNER:
			state.owner = value
		PHASE:
			state.phase = value
		PHASE_TICK:
			state.phase_tick = value
		CAPTAIN_ALIVE:
			state.captain_alive = value != 0
		GUARDS_ALIVE:
			state.guards_alive = value
		GATE_HEALTH:
			state.gate_health = value
		GATE_MAX:
			state.gate_max = value
		CAPTURE_REALM:
			state.capture_realm = value
		CAPTURE_START_TICK:
			state.capture_start_tick = value
		CAPTURE_RATE:
			state.capture_rate = value
		CAPTURE_PROGRESS_AT_START:
			state.capture_progress_at_start = value
		CONTESTED:
			state.contested = value != 0
		UNDER_ATTACK_UNTIL_TICK:
			state.under_attack_until_tick = value
		_:
			state.presence[field_id - PRESENCE_BASE] = value
	return true
