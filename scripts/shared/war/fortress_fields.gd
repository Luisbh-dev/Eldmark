class_name FortressFields
extends RefCounted
## Ids de los campos de una fortaleza en OBJECT_STATE (docs/fuerte.md, sección 2) y cómo viaja
## cada uno: su tipo de valor en el mensaje y su lectura y escritura sobre un [FortressState].
## [br][br]
## OBJECT_STATE lleva, por campo, [code]u8 field_id[/code], [code]u8 value_type[/code] y el valor. Los
## tipos son los de [enum ValueType] (1 u8, 2 u16, 3 u32, 4 s32). Un [code]field_id[/code]
## desconocido se salta al decodificar (compatibilidad hacia delante); uno conocido con otro tipo
## de valor no es válido.
## [br][br]
## Los booleanos viajan como 0 o 1. La presencia de cada reino (campos 14 a 17) es un u8 por reino,
## de 0 (neutral) a 3. Los ticks son u32 y la velocidad de captura, que puede ser negativa, s32.
## [br][br]
## Compartido: no depende del cliente ni del servidor.

## Tipo de valor de un campo en el mensaje.
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
## Presencia del reino 0 (neutral); los de los reinos 1 a 3 son este id más el código de reino.
const PRESENCE_BASE: int = 14

const FIRST: int = OWNER
const LAST: int = PRESENCE_BASE + 3
## Reinos con campo de presencia (códigos de red 0 a 3).
const PRESENCE_REALMS: int = 4

## Id -> [nombre, tipo de valor].
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


## Todos los ids de campo, en orden.
static func all_ids() -> PackedInt32Array:
	var ids := PackedInt32Array()
	for id: int in range(FIRST, LAST + 1):
		ids.append(id)
	return ids


## true si [param field_id] es un campo conocido (1 a 17).
static func is_known(field_id: int) -> bool:
	return _TABLE.has(field_id)


## Nombre del campo (el del miembro de [FortressState]); vacío si es desconocido.
static func name_of(field_id: int) -> StringName:
	if not _TABLE.has(field_id):
		return &""
	return (_TABLE[field_id] as Array)[0]


## Tipo de valor ([enum ValueType]) con el que viaja el campo, o 0 si es desconocido.
static func value_type(field_id: int) -> int:
	if not _TABLE.has(field_id):
		return 0
	return (_TABLE[field_id] as Array)[1]


## Id del campo de presencia del reino [param realm_code] (0 a 3), o -1 si el código no vale.
static func presence_field(realm_code: int) -> int:
	if realm_code < 0 or realm_code >= PRESENCE_REALMS:
		return -1
	return PRESENCE_BASE + realm_code


## Número de bytes del valor de un campo de tipo [param type] (0 si el tipo no existe).
static func value_size(type: int) -> int:
	match type:
		ValueType.U8:
			return 1
		ValueType.U16:
			return 2
		ValueType.U32, ValueType.S32:
			return 4
	return 0


## true si [param value] cabe en el tipo del campo [param field_id].
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


## Valor entero del campo [param field_id] en [param state] (los booleanos como 0 o 1). 0 si el id
## es desconocido.
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


## Pone el campo [param field_id] de [param state] a [param value]. Devuelve false (sin tocar
## nada) si el id es desconocido o el valor no cabe en el tipo del campo.
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
