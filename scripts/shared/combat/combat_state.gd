class_name CombatState
extends RefCounted
## Estado de combate de un personaje (docs/combate.md, sección 3.1). Va dentro de [PlayerState]
## y entra en [method PlayerState.encode], así que la reconciliación compara también la acción
## en curso, la resistencia y los controles impuestos por el servidor.
## [br][br]
## Formato de red ([constant ENCODED_SIZE] bytes, little-endian). La columna de la izquierda es el
## offset dentro de [PlayerState] (el combate empieza en el byte 35):
## [codeblock]
## 35   u8       action              Action
## 36   u16      action_id           ataque del catálogo (0 si no es un ataque)
## 38   u32      action_tick         tick en que empezó la acción
## 42   u8       combo_step          0-2: siguiente ligero del combo
## 43   u8       primary_held        ticks reales con PRIMARY pulsado desde su flanco (0 = ninguna)
## 44   u8       charge_ticks        ticks de carga al lanzar el fuerte
## 45   u8       buffered            bits 0-1 tipo (BUFFER_*), bits 2-5 ticks que le quedan
## 46   u16      stamina             0..stamina_max
## 48   u32      stamina_regen_tick  primer tick en que vuelve a regenerar
## 52   u8       combat_flags        FLAG_*
## 53   u16      action_dir          yaw cuantizado de la esquiva
## 55   u32      cc_until_tick       fin del control actual (exclusivo)
## 59   s16 x2   knockback           empuje horizontal (x, z) en cm/s
## 63   u32      parry_ready_tick    primer tick en que puede abrirse otra ventana de parada
## 67   u16      weapon_id           arma equipada
## [/codeblock]
## Todo son enteros salvo [member knockback], que se redondea a cm/s al codificar.

## Acciones. [constant NONE] es no hacer nada; [constant STAGGER], [constant STUN] y
## [constant DEAD] los impone el servidor.
enum Action { NONE, LIGHT, HEAVY, CHARGE, BLOCK, DODGE, STAGGER, STUN, DEAD }

## Tamaño en bytes de un estado de combate codificado.
const ENCODED_SIZE: int = 34

## Bit 0 de [member combat_flags]: agotado (sin esquiva ni bloqueo hasta superar el umbral).
const FLAG_EXHAUSTED: int = 1 << 0
## Bit 1: el último intento de acción falló por falta de resistencia (para la interfaz). Dura un
## solo tick: la máquina lo borra al principio del siguiente.
const FLAG_NO_STAMINA: int = 1 << 1
## Bit 2: resistencia infinita (comando de depuración): la máquina no gasta.
const FLAG_INFINITE_STAMINA: int = 1 << 2
## Bits 3-5: nivel que tenían DODGE, BLOCK y PRIMARY en el tick anterior. La máquina saca de ahí
## los flancos de subida, así que no depende de [member PlayerCharacter.prev_buttons].
const FLAG_DODGE_HELD: int = 1 << 3
const FLAG_BLOCK_HELD: int = 1 << 4
const FLAG_PRIMARY_HELD: int = 1 << 5

## Tipos del búfer de entradas ([member buffered], bits 0-1).
const BUFFER_NONE: int = 0
const BUFFER_PRIMARY: int = 1
const BUFFER_DODGE: int = 2
## Pulsación de PRIMARY dentro de la ventana de combo de un ligero: empieza el siguiente al acabar
## su recuperación, sin caducar antes.
const BUFFER_LINK: int = 3

## Pasos del yaw cuantizado de [member action_dir] (como [member PlayerInput.look_yaw]).
const YAW_STEPS: int = 65536
## Empuje: centímetros por m/s.
const KNOCKBACK_SCALE: float = 100.0

var action: int = Action.NONE
var action_id: int = 0
var action_tick: int = 0
var combo_step: int = 0
var primary_held: int = 0
var charge_ticks: int = 0
var buffered: int = 0
var stamina: int = 0
var stamina_regen_tick: int = 0
var combat_flags: int = 0
var action_dir: int = 0
var cc_until_tick: int = 0
## Empuje horizontal (x, z) en m/s, a cm/s de precisión.
var knockback: Vector2 = Vector2.ZERO
var parry_ready_tick: int = 0
var weapon_id: int = 0


## Estado de un personaje recién creado: sin acción y con la resistencia llena.
static func initial(rules: CombatRules, weapon: int) -> CombatState:
	var state := CombatState.new()
	state.stamina = rules.stamina_max
	state.weapon_id = weapon
	return state


## Redondea [param value] a la precisión de [member knockback] (cm/s), la que sobrevive a
## [method encode_into] y [method decode_from].
static func quantize_knockback(value: Vector2) -> Vector2:
	return Vector2(_knockback_q(value.x) / KNOCKBACK_SCALE, _knockback_q(value.y) / KNOCKBACK_SCALE)


## Yaw (rad) -> pasos de [member action_dir] (0..65535).
static func quantize_yaw(yaw: float) -> int:
	if not is_finite(yaw):
		return 0
	return roundi(fposmod(yaw, TAU) / TAU * YAW_STEPS) % YAW_STEPS


## Pasos de [member action_dir] -> yaw (rad) en [0, TAU).
static func dequantize_yaw(steps: int) -> float:
	return (steps % YAW_STEPS) / float(YAW_STEPS) * TAU


## Escribe el estado en [param bytes] a partir de [param offset]
## ([constant ENCODED_SIZE] bytes; el búfer ya debe tener ese tamaño).
func encode_into(bytes: PackedByteArray, offset: int) -> void:
	bytes.encode_u8(offset, action & 0xFF)
	bytes.encode_u16(offset + 1, action_id & 0xFFFF)
	bytes.encode_u32(offset + 3, action_tick & 0xFFFFFFFF)
	bytes.encode_u8(offset + 7, combo_step & 0xFF)
	bytes.encode_u8(offset + 8, clampi(primary_held, 0, 255))
	bytes.encode_u8(offset + 9, clampi(charge_ticks, 0, 255))
	bytes.encode_u8(offset + 10, buffered & 0xFF)
	bytes.encode_u16(offset + 11, clampi(stamina, 0, 0xFFFF))
	bytes.encode_u32(offset + 13, stamina_regen_tick & 0xFFFFFFFF)
	bytes.encode_u8(offset + 17, combat_flags & 0xFF)
	bytes.encode_u16(offset + 18, action_dir & 0xFFFF)
	bytes.encode_u32(offset + 20, cc_until_tick & 0xFFFFFFFF)
	bytes.encode_s16(offset + 24, _knockback_q(knockback.x))
	bytes.encode_s16(offset + 26, _knockback_q(knockback.y))
	bytes.encode_u32(offset + 28, parry_ready_tick & 0xFFFFFFFF)
	bytes.encode_u16(offset + 32, weapon_id & 0xFFFF)


## Lee un estado de [param bytes] a partir de [param offset]. Devuelve null si no caben
## [constant ENCODED_SIZE] bytes.
static func decode_from(bytes: PackedByteArray, offset: int) -> CombatState:
	if offset < 0 or offset + ENCODED_SIZE > bytes.size():
		return null
	var state := CombatState.new()
	state.action = bytes.decode_u8(offset)
	state.action_id = bytes.decode_u16(offset + 1)
	state.action_tick = bytes.decode_u32(offset + 3)
	state.combo_step = bytes.decode_u8(offset + 7)
	state.primary_held = bytes.decode_u8(offset + 8)
	state.charge_ticks = bytes.decode_u8(offset + 9)
	state.buffered = bytes.decode_u8(offset + 10)
	state.stamina = bytes.decode_u16(offset + 11)
	state.stamina_regen_tick = bytes.decode_u32(offset + 13)
	state.combat_flags = bytes.decode_u8(offset + 17)
	state.action_dir = bytes.decode_u16(offset + 18)
	state.cc_until_tick = bytes.decode_u32(offset + 20)
	state.knockback = Vector2(
		bytes.decode_s16(offset + 24) / KNOCKBACK_SCALE,
		bytes.decode_s16(offset + 26) / KNOCKBACK_SCALE,
	)
	state.parry_ready_tick = bytes.decode_u32(offset + 28)
	state.weapon_id = bytes.decode_u16(offset + 32)
	return state


## Copia exacta e independiente.
func duplicate_state() -> CombatState:
	var copy := CombatState.new()
	copy.copy_from(self)
	return copy


## Copia todos los campos de [param other] sobre este estado (sin crear objetos nuevos).
func copy_from(other: CombatState) -> void:
	action = other.action
	action_id = other.action_id
	action_tick = other.action_tick
	combo_step = other.combo_step
	primary_held = other.primary_held
	charge_ticks = other.charge_ticks
	buffered = other.buffered
	stamina = other.stamina
	stamina_regen_tick = other.stamina_regen_tick
	combat_flags = other.combat_flags
	action_dir = other.action_dir
	cc_until_tick = other.cc_until_tick
	knockback = other.knockback
	parry_ready_tick = other.parry_ready_tick
	weapon_id = other.weapon_id


## true si todos los campos coinciden tal y como viajan por la red (es decir, si
## [method encode_into] da los mismos bytes). Un [param other] null nunca es igual.
func equals(other: CombatState) -> bool:
	if other == null:
		return false
	var mine := PackedByteArray()
	mine.resize(ENCODED_SIZE)
	encode_into(mine, 0)
	var theirs := PackedByteArray()
	theirs.resize(ENCODED_SIZE)
	other.encode_into(theirs, 0)
	return mine == theirs


## Tipo del búfer de entradas ([constant BUFFER_NONE]...).
func buffered_type() -> int:
	return buffered & 3


## Ticks que le quedan a la pulsación del búfer.
func buffered_ticks() -> int:
	return (buffered >> 2) & 15


## true si el personaje está agotado.
func is_exhausted() -> bool:
	return (combat_flags & FLAG_EXHAUSTED) != 0


func _to_string() -> String:
	var text: String = "CombatState(action=%d, id=%d, tick=%d, combo=%d, held=%d, charge=%d, "
	text += "buffered=%d, stamina=%d, regen_tick=%d, flags=%d, dir=%d, cc_until=%d, kb=%s, "
	text += "parry_ready=%d, weapon=%d)"
	return text % [
		action, action_id, action_tick, combo_step, primary_held, charge_ticks, buffered, stamina,
		stamina_regen_tick, combat_flags, action_dir, cc_until_tick, knockback, parry_ready_tick,
		weapon_id,
	]


static func _knockback_q(value: float) -> int:
	if not is_finite(value):
		return 0
	return clampi(roundi(value * KNOCKBACK_SCALE), -32768, 32767)
