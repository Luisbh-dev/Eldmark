class_name CombatState
extends RefCounted
## Estado de combate de un personaje (docs/combate.md, sección 3.1, ampliada a la versión 5 en
## docs/habilidades.md, sección 3.1). Va dentro de [PlayerState] y entra en
## [method PlayerState.encode], así que la reconciliación compara también la acción en curso, la
## resistencia, los controles impuestos por el servidor, las reutilizaciones, las cargas de los
## consumibles y los efectos de movimiento.
## [br][br]
## Formato de red ([constant ENCODED_SIZE] bytes, little-endian). La columna de la izquierda es el
## offset dentro de [PlayerState] (el combate empieza en el byte 35):
## [codeblock]
## 35   u8       action                 Action
## 36   u16      action_id              ataque (LIGHT, HEAVY, CHARGE) o habilidad (ABILITY) del catálogo
## 38   u32      action_tick            tick en que empezó la acción
## 42   u8       combo_step             0-2: siguiente ligero del combo
## 43   u8       primary_held           ticks reales con PRIMARY pulsado desde su flanco (0 = ninguna)
## 44   u8       charge_ticks           ticks de carga al lanzar el fuerte
## 45   u8       buffered               bits 0-3 tipo (BUFFER_*), bits 4-7 ticks que le quedan
## 46   u16      stamina                0..stamina_max
## 48   u32      stamina_regen_tick     primer tick en que vuelve a regenerar
## 52   u8       combat_flags           FLAG_* (bits 0-6)
## 53   u16      action_dir             yaw cuantizado de la esquiva o del avance de una habilidad
## 55   u32      cc_until_tick          fin del control actual (exclusivo)
## 59   s16 x2   knockback              empuje horizontal (x, z) en cm/s
## 63   u32      parry_ready_tick       primer tick en que puede abrirse otra ventana de parada
## 67   u16      weapon_id              arma activa
## 69   u16      alt_weapon_id          arma de la otra ranura (0 = ninguna)
## 71   u8       combat_flags2          FLAG2_* (ranura activa, botones del tick anterior, comando)
## 72   u32 x3   ability_ready[0..2]    primer tick en que vuelve a valer cada habilidad del arma activa
## 84   u32 x3   ability_ready[3..5]    ídem, arma de la otra ranura
## 96   u32      consumable_ready_tick  reutilización compartida de los consumibles
## 100  u8       consumable_charges     bits 0-3 poción 1, bits 4-7 poción 2
## 101  u8 + u32 move_effect 0          id del efecto de movimiento (0 = libre) y su fin (exclusivo)
## 106  u8 + u32 move_effect 1          ídem
## [/codeblock]
## Todo son enteros salvo [member knockback], que se redondea a cm/s al codificar. Los ticks son
## absolutos (como [member cc_until_tick]): restaurar un estado no tiene ambigüedad y el tiempo de
## las reutilizaciones corre aunque el arma esté guardada.

## Acciones. [constant NONE] es no hacer nada; [constant STAGGER], [constant STUN], [constant DEAD],
## [constant DOWNED], [constant REVIVE] y [constant EXECUTE] los impone el servidor.
## [constant ABILITY] es una habilidad o un consumible ([member action_id] es la habilidad) y
## [constant SWAP], el cambio de arma (docs/habilidades.md, sección 3). 14 y 15 quedan libres (la
## acción ocupa 4 bits en el byte de acción del registro).
enum Action {
	NONE, LIGHT, HEAVY, CHARGE, BLOCK, DODGE, STAGGER, STUN, DEAD,
	ABILITY, SWAP, DOWNED, REVIVE, EXECUTE,
}

## Tamaño en bytes de un estado de combate codificado.
const ENCODED_SIZE: int = 76
## Ranuras de habilidad de un arma.
const ABILITY_SLOTS: int = 3
## Ranuras de efectos de movimiento (ralentizar, enraizar).
const MOVE_EFFECT_SLOTS: int = 2
## Consumibles (pociones) de las reglas.
const CONSUMABLE_SLOTS: int = 2
## Cargas máximas de cada consumible (4 bits).
const MAX_CHARGES: int = 15

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
## Bit 6: el ligero en curso empezó mientras la pulsación viva de PRIMARY estaba abajo (del flanco o
## del búfer o enlace que ella dejó), así que mantenerla lo convierte en carga. No se deduce de
## [member primary_held] y el tick actual porque una entrada sustituida no suma a esa cuenta y abriría
## un hueco para siempre. Lo pone y lo borra la máquina de acciones (solo tiene sentido con un ligero
## en curso).
const FLAG_LIGHT_OF_PRESS: int = 1 << 6

## Bit 0 de [member combat_flags2]: el arma activa es la de la ranura 2 ([member weapon_id] es la
## segunda arma de la plantilla y [member alt_weapon_id], la primera).
const FLAG2_SECOND_SLOT: int = 1 << 0
## Bits 1-6: nivel que tenían ABILITY_1, ABILITY_2, ABILITY_3, SWAP_WEAPON, CONSUMABLE_1 y
## CONSUMABLE_2 en el tick anterior (para sacar sus flancos, como los bits 3-5 de
## [member combat_flags]).
const FLAG2_ABILITY_1_HELD: int = 1 << 1
const FLAG2_ABILITY_2_HELD: int = 1 << 2
const FLAG2_ABILITY_3_HELD: int = 1 << 3
const FLAG2_SWAP_HELD: int = 1 << 4
const FLAG2_CONSUMABLE_1_HELD: int = 1 << 5
const FLAG2_CONSUMABLE_2_HELD: int = 1 << 6
## Los bits 1-6 juntos.
const FLAG2_HELD_MASK: int = 0b0111_1110
## Bit 7: sin reutilizaciones ni gasto de cargas (comando de depuración 13).
const FLAG2_NO_COOLDOWNS: int = 1 << 7

## Tipos del búfer de entradas ([member buffered], bits 0-3).
const BUFFER_NONE: int = 0
const BUFFER_PRIMARY: int = 1
const BUFFER_DODGE: int = 2
## Pulsación de PRIMARY dentro de la ventana de combo de un ligero: empieza el siguiente al acabar
## su recuperación, sin caducar antes.
const BUFFER_LINK: int = 3
## Habilidades de las ranuras 1-3 (4, 5 y 6).
const BUFFER_ABILITY_1: int = 4
const BUFFER_ABILITY_2: int = 5
const BUFFER_ABILITY_3: int = 6
const BUFFER_SWAP: int = 7
## Consumibles 1 y 2 (8 y 9).
const BUFFER_CONSUMABLE_1: int = 8
const BUFFER_CONSUMABLE_2: int = 9
## Bits del tipo del búfer y desplazamiento de sus ticks.
const BUFFER_TYPE_MASK: int = 15
const BUFFER_TICKS_SHIFT: int = 4

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
## Arma activa.
var weapon_id: int = 0
## Arma de la otra ranura (0 = ninguna).
var alt_weapon_id: int = 0
## FLAG2_*: ranura activa, botones del tick anterior y sin reutilizaciones.
var combat_flags2: int = 0
## Primer tick en que vuelve a valer cada habilidad: índices 0-2 las del arma activa, 3-5 las de la
## otra ranura (6 valores; [method copy_from] copia el contenido, no la referencia).
var ability_ready: PackedInt64Array
## Primer tick en que vuelve a valer cualquier consumible (reutilización compartida).
var consumable_ready_tick: int = 0
## Cargas de los consumibles: bits 0-3 la poción 1 y bits 4-7 la poción 2 ([method charges_of]).
var consumable_charges: int = 0
## Id ([StatusTicks]) de cada ranura de efecto de movimiento; 0 = libre (2 valores).
var move_effect_ids: PackedInt32Array
## Fin (exclusivo) de cada ranura de efecto de movimiento (2 valores).
var move_effect_until: PackedInt64Array


func _init() -> void:
	# Arrays propios de cada estado: los Packed*Array se pasan por referencia y un valor por defecto
	# compartido haría que dos estados se pisaran.
	ability_ready = PackedInt64Array()
	ability_ready.resize(ABILITY_SLOTS * 2)
	move_effect_ids = PackedInt32Array()
	move_effect_ids.resize(MOVE_EFFECT_SLOTS)
	move_effect_until = PackedInt64Array()
	move_effect_until.resize(MOVE_EFFECT_SLOTS)


## Estado de un personaje recién creado: sin acción, con la resistencia llena, el arma
## [param weapon] activa, [param alt_weapon] en la otra ranura y las cargas [param charges]
## (empaquetadas como [member consumable_charges]).
static func initial(rules: CombatRules, weapon: int, alt_weapon: int = 0,
		charges: int = 0) -> CombatState:
	var state := CombatState.new()
	state.stamina = rules.stamina_max
	state.weapon_id = weapon
	state.alt_weapon_id = alt_weapon
	state.consumable_charges = charges & 0xFF
	return state


## Empaqueta las cargas de los dos consumibles como [member consumable_charges] (cada una se limita
## a 0..[constant MAX_CHARGES]).
static func pack_charges(first: int, second: int) -> int:
	return clampi(first, 0, MAX_CHARGES) | (clampi(second, 0, MAX_CHARGES) << 4)


## Empaqueta un búfer de tipo [param kind] (BUFFER_*) con [param ticks] ticks de vida.
static func pack_buffer(kind: int, ticks: int) -> int:
	return (kind & BUFFER_TYPE_MASK) | (clampi(ticks, 0, 15) << BUFFER_TICKS_SHIFT)


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
	# Versión 5 (docs/habilidades.md, sección 3.1).
	bytes.encode_u16(offset + 34, alt_weapon_id & 0xFFFF)
	bytes.encode_u8(offset + 36, combat_flags2 & 0xFF)
	for i: int in ABILITY_SLOTS * 2:
		bytes.encode_u32(offset + 37 + 4 * i, ability_ready[i] & 0xFFFFFFFF)
	bytes.encode_u32(offset + 61, consumable_ready_tick & 0xFFFFFFFF)
	bytes.encode_u8(offset + 65, consumable_charges & 0xFF)
	for i: int in MOVE_EFFECT_SLOTS:
		bytes.encode_u8(offset + 66 + 5 * i, move_effect_ids[i] & 0xFF)
		bytes.encode_u32(offset + 67 + 5 * i, move_effect_until[i] & 0xFFFFFFFF)


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
	state.alt_weapon_id = bytes.decode_u16(offset + 34)
	state.combat_flags2 = bytes.decode_u8(offset + 36)
	for i: int in ABILITY_SLOTS * 2:
		state.ability_ready[i] = bytes.decode_u32(offset + 37 + 4 * i)
	state.consumable_ready_tick = bytes.decode_u32(offset + 61)
	state.consumable_charges = bytes.decode_u8(offset + 65)
	for i: int in MOVE_EFFECT_SLOTS:
		state.move_effect_ids[i] = bytes.decode_u8(offset + 66 + 5 * i)
		state.move_effect_until[i] = bytes.decode_u32(offset + 67 + 5 * i)
	return state


## Copia exacta e independiente.
func duplicate_state() -> CombatState:
	var copy := CombatState.new()
	copy.copy_from(self)
	return copy


## Copia todos los campos de [param other] sobre este estado (sin crear objetos nuevos: los arrays
## se copian elemento a elemento).
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
	alt_weapon_id = other.alt_weapon_id
	combat_flags2 = other.combat_flags2
	for i: int in ABILITY_SLOTS * 2:
		ability_ready[i] = other.ability_ready[i]
	consumable_ready_tick = other.consumable_ready_tick
	consumable_charges = other.consumable_charges
	for i: int in MOVE_EFFECT_SLOTS:
		move_effect_ids[i] = other.move_effect_ids[i]
		move_effect_until[i] = other.move_effect_until[i]


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
	return buffered & BUFFER_TYPE_MASK


## Ticks que le quedan a la pulsación del búfer.
func buffered_ticks() -> int:
	return (buffered >> BUFFER_TICKS_SHIFT) & 15


## Cargas que le quedan al consumible [param index] (0 o 1); 0 para un índice fuera de rango.
func charges_of(index: int) -> int:
	if index < 0 or index >= CONSUMABLE_SLOTS:
		return 0
	return (consumable_charges >> (4 * index)) & MAX_CHARGES


## true si el arma activa es la de la ranura 2.
func is_second_slot() -> bool:
	return (combat_flags2 & FLAG2_SECOND_SLOT) != 0


## true si el personaje está agotado.
func is_exhausted() -> bool:
	return (combat_flags & FLAG_EXHAUSTED) != 0


func _to_string() -> String:
	var text: String = "CombatState(action=%d, id=%d, tick=%d, combo=%d, held=%d, charge=%d, "
	text += "buffered=%d, stamina=%d, regen_tick=%d, flags=%d, dir=%d, cc_until=%d, kb=%s, "
	text += "parry_ready=%d, weapon=%d, alt_weapon=%d, flags2=%d, ability_ready=%s, "
	text += "consumable_ready=%d, charges=%d, move_effects=%s/%s)"
	return text % [
		action, action_id, action_tick, combo_step, primary_held, charge_ticks, buffered, stamina,
		stamina_regen_tick, combat_flags, action_dir, cc_until_tick, knockback, parry_ready_tick,
		weapon_id, alt_weapon_id, combat_flags2, ability_ready, consumable_ready_tick,
		consumable_charges, move_effect_ids, move_effect_until,
	]


static func _knockback_q(value: float) -> int:
	if not is_finite(value):
		return 0
	return clampi(roundi(value * KNOCKBACK_SCALE), -32768, 32767)
