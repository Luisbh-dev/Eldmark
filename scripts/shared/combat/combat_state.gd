class_name CombatState
extends RefCounted
## A character's combat state (docs/combate.md, section 3.1, extended to version 5 in
## docs/habilidades.md, section 3.1). It lives inside [PlayerState] and goes into
## [method PlayerState.encode], so reconciliation also compares the current action, the
## stamina, the controls imposed by the server, the cooldowns, the consumable charges
## and the movement effects.
## [br][br]
## Network format ([constant ENCODED_SIZE] bytes, little-endian). The left column is the
## offset within [PlayerState] (combat starts at byte 35):
## [codeblock]
## 35   u8       action                 Action
## 36   u16      action_id              catalog attack (LIGHT, HEAVY, CHARGE) or ability (ABILITY)
## 38   u32      action_tick            tick on which the action started
## 42   u8       combo_step             0-2: next light attack of the combo
## 43   u8       primary_held           real ticks with PRIMARY pressed since its edge (0 = none)
## 44   u8       charge_ticks           charge ticks when the heavy attack is released
## 45   u8       buffered               bits 0-3 type (BUFFER_*), bits 4-7 ticks remaining
## 46   u16      stamina                0..stamina_max
## 48   u32      stamina_regen_tick     first tick on which it regenerates again
## 52   u8       combat_flags           FLAG_* (bits 0-6)
## 53   u16      action_dir             quantized yaw of the dodge or an ability's advance
## 55   u32      cc_until_tick          end of the current control (exclusive)
## 59   s16 x2   knockback              horizontal knockback (x, z) in cm/s
## 63   u32      parry_ready_tick       first tick on which another parry window can be opened
## 67   u16      weapon_id              active weapon
## 69   u16      alt_weapon_id          weapon in the other slot (0 = none)
## 71   u8       combat_flags2          FLAG2_* (active slot, previous-tick buttons, command)
## 72   u32 x3   ability_ready[0..2]    first tick on which each of the active weapon's abilities is ready again
## 84   u32 x3   ability_ready[3..5]    same, for the other slot's weapon
## 96   u32      consumable_ready_tick  shared cooldown of the consumables
## 100  u8       consumable_charges     bits 0-3 potion 1, bits 4-7 potion 2
## 101  u8 + u32 move_effect 0          id of the movement effect (0 = free) and its end (exclusive)
## 106  u8 + u32 move_effect 1          same
## [/codeblock]
## Everything is integers except [member knockback], which is rounded to cm/s on encoding. Ticks are
## absolute (like [member cc_until_tick]): restoring a state is unambiguous and the cooldown
## time keeps running even while the weapon is stowed.

## Actions. [constant NONE] is doing nothing; [constant STAGGER], [constant STUN], [constant DEAD],
## [constant DOWNED], [constant REVIVE] and [constant EXECUTE] are imposed by the server.
## [constant ABILITY] is an ability or a consumable ([member action_id] is the ability) and
## [constant SWAP], the weapon swap (docs/habilidades.md, section 3). 14 and 15 are left free (the
## action takes 4 bits in the record's action byte).
enum Action {
	NONE, LIGHT, HEAVY, CHARGE, BLOCK, DODGE, STAGGER, STUN, DEAD,
	ABILITY, SWAP, DOWNED, REVIVE, EXECUTE,
}

## Size in bytes of an encoded combat state.
const ENCODED_SIZE: int = 76
## Ability slots of a weapon.
const ABILITY_SLOTS: int = 3
## Movement effect slots (slow, root).
const MOVE_EFFECT_SLOTS: int = 2
## Consumables (potions) of the rules.
const CONSUMABLE_SLOTS: int = 2
## Maximum charges of each consumable (4 bits).
const MAX_CHARGES: int = 15

## Bit 0 of [member combat_flags]: exhausted (no dodge or block until the threshold is exceeded).
const FLAG_EXHAUSTED: int = 1 << 0
## Bit 1: the last action attempt failed for lack of stamina (for the UI). It lasts a
## single tick: the machine clears it at the start of the next one.
const FLAG_NO_STAMINA: int = 1 << 1
## Bit 2: infinite stamina (debug command): the machine does not spend.
const FLAG_INFINITE_STAMINA: int = 1 << 2
## Bits 3-5: level that DODGE, BLOCK and PRIMARY had on the previous tick. The machine derives
## the rising edges from them, so it does not depend on [member PlayerCharacter.prev_buttons].
const FLAG_DODGE_HELD: int = 1 << 3
const FLAG_BLOCK_HELD: int = 1 << 4
const FLAG_PRIMARY_HELD: int = 1 << 5
## Bit 6: the light attack in progress started while the live PRIMARY press was down (from the edge or
## from the buffer or link it left), so holding it turns it into a charge. It is not deduced from
## [member primary_held] and the current tick because a substituted input does not add to that count and would open
## a permanent gap. It is set and cleared by the action machine (it only makes sense with a light attack
## in progress).
const FLAG_LIGHT_OF_PRESS: int = 1 << 6

## Bit 0 of [member combat_flags2]: the active weapon is the one in slot 2 ([member weapon_id] is the
## template's second weapon and [member alt_weapon_id], the first).
const FLAG2_SECOND_SLOT: int = 1 << 0
## Bits 1-6: level that ABILITY_1, ABILITY_2, ABILITY_3, SWAP_WEAPON, CONSUMABLE_1 and
## CONSUMABLE_2 had on the previous tick (to derive their edges, like bits 3-5 of
## [member combat_flags]).
const FLAG2_ABILITY_1_HELD: int = 1 << 1
const FLAG2_ABILITY_2_HELD: int = 1 << 2
const FLAG2_ABILITY_3_HELD: int = 1 << 3
const FLAG2_SWAP_HELD: int = 1 << 4
const FLAG2_CONSUMABLE_1_HELD: int = 1 << 5
const FLAG2_CONSUMABLE_2_HELD: int = 1 << 6
## Bits 1-6 together.
const FLAG2_HELD_MASK: int = 0b0111_1110
## Bit 7: no cooldowns or charge spending (debug command 13).
const FLAG2_NO_COOLDOWNS: int = 1 << 7

## Input buffer types ([member buffered], bits 0-3).
const BUFFER_NONE: int = 0
const BUFFER_PRIMARY: int = 1
const BUFFER_DODGE: int = 2
## PRIMARY press within a light attack's combo window: it starts the next one when
## its recovery ends, without expiring before.
const BUFFER_LINK: int = 3
## Abilities of slots 1-3 (4, 5 and 6).
const BUFFER_ABILITY_1: int = 4
const BUFFER_ABILITY_2: int = 5
const BUFFER_ABILITY_3: int = 6
const BUFFER_SWAP: int = 7
## Consumables 1 and 2 (8 and 9).
const BUFFER_CONSUMABLE_1: int = 8
const BUFFER_CONSUMABLE_2: int = 9
## Buffer type bits and shift of its ticks.
const BUFFER_TYPE_MASK: int = 15
const BUFFER_TICKS_SHIFT: int = 4

## Steps of the quantized yaw of [member action_dir] (like [member PlayerInput.look_yaw]).
const YAW_STEPS: int = 65536
## Knockback: centimeters per m/s.
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
## Horizontal knockback (x, z) in m/s, at cm/s precision.
var knockback: Vector2 = Vector2.ZERO
var parry_ready_tick: int = 0
## Active weapon.
var weapon_id: int = 0
## Weapon in the other slot (0 = none).
var alt_weapon_id: int = 0
## FLAG2_*: active slot, previous-tick buttons and no cooldowns.
var combat_flags2: int = 0
## First tick on which each ability is ready again: indices 0-2 are the active weapon's, 3-5 those of the
## other slot (6 values; [method copy_from] copies the contents, not the reference).
var ability_ready: PackedInt64Array
## First tick on which any consumable is ready again (shared cooldown).
var consumable_ready_tick: int = 0
## Consumable charges: bits 0-3 potion 1 and bits 4-7 potion 2 ([method charges_of]).
var consumable_charges: int = 0
## Id ([StatusTicks]) of each movement effect slot; 0 = free (2 values).
var move_effect_ids: PackedInt32Array
## End (exclusive) of each movement effect slot (2 values).
var move_effect_until: PackedInt64Array


func _init() -> void:
	# Each state's own arrays: Packed*Arrays are passed by reference and a shared default
	# value would make two states overwrite each other.
	ability_ready = PackedInt64Array()
	ability_ready.resize(ABILITY_SLOTS * 2)
	move_effect_ids = PackedInt32Array()
	move_effect_ids.resize(MOVE_EFFECT_SLOTS)
	move_effect_until = PackedInt64Array()
	move_effect_until.resize(MOVE_EFFECT_SLOTS)


## State of a newly created character: no action, full stamina, weapon
## [param weapon] active, [param alt_weapon] in the other slot and the charges [param charges]
## (packed as [member consumable_charges]).
static func initial(rules: CombatRules, weapon: int, alt_weapon: int = 0,
		charges: int = 0) -> CombatState:
	var state := CombatState.new()
	state.stamina = rules.stamina_max
	state.weapon_id = weapon
	state.alt_weapon_id = alt_weapon
	state.consumable_charges = charges & 0xFF
	return state


## Packs the charges of the two consumables as [member consumable_charges] (each is clamped
## to 0..[constant MAX_CHARGES]).
static func pack_charges(first: int, second: int) -> int:
	return clampi(first, 0, MAX_CHARGES) | (clampi(second, 0, MAX_CHARGES) << 4)


## Packs a buffer of type [param kind] (BUFFER_*) with [param ticks] ticks of life.
static func pack_buffer(kind: int, ticks: int) -> int:
	return (kind & BUFFER_TYPE_MASK) | (clampi(ticks, 0, 15) << BUFFER_TICKS_SHIFT)


## Rounds [param value] to the precision of [member knockback] (cm/s), the one that survives
## [method encode_into] and [method decode_from].
static func quantize_knockback(value: Vector2) -> Vector2:
	return Vector2(_knockback_q(value.x) / KNOCKBACK_SCALE, _knockback_q(value.y) / KNOCKBACK_SCALE)


## Yaw (rad) -> [member action_dir] steps (0..65535).
static func quantize_yaw(yaw: float) -> int:
	if not is_finite(yaw):
		return 0
	return roundi(fposmod(yaw, TAU) / TAU * YAW_STEPS) % YAW_STEPS


## [member action_dir] steps -> yaw (rad) in [0, TAU).
static func dequantize_yaw(steps: int) -> float:
	return (steps % YAW_STEPS) / float(YAW_STEPS) * TAU


## Writes the state into [param bytes] starting at [param offset]
## ([constant ENCODED_SIZE] bytes; the buffer must already have that size).
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
	# Version 5 (docs/habilidades.md, section 3.1).
	bytes.encode_u16(offset + 34, alt_weapon_id & 0xFFFF)
	bytes.encode_u8(offset + 36, combat_flags2 & 0xFF)
	for i: int in ABILITY_SLOTS * 2:
		bytes.encode_u32(offset + 37 + 4 * i, ability_ready[i] & 0xFFFFFFFF)
	bytes.encode_u32(offset + 61, consumable_ready_tick & 0xFFFFFFFF)
	bytes.encode_u8(offset + 65, consumable_charges & 0xFF)
	for i: int in MOVE_EFFECT_SLOTS:
		bytes.encode_u8(offset + 66 + 5 * i, move_effect_ids[i] & 0xFF)
		bytes.encode_u32(offset + 67 + 5 * i, move_effect_until[i] & 0xFFFFFFFF)


## Reads a state from [param bytes] starting at [param offset]. Returns null if
## [constant ENCODED_SIZE] bytes do not fit.
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


## Exact, independent copy.
func duplicate_state() -> CombatState:
	var copy := CombatState.new()
	copy.copy_from(self)
	return copy


## Copies all fields of [param other] onto this state (without creating new objects: arrays
## are copied element by element).
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


## true if all fields match as they travel over the network (that is, if
## [method encode_into] gives the same bytes). A null [param other] is never equal.
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


## Type of the input buffer ([constant BUFFER_NONE]...).
func buffered_type() -> int:
	return buffered & BUFFER_TYPE_MASK


## Ticks remaining for the buffered press.
func buffered_ticks() -> int:
	return (buffered >> BUFFER_TICKS_SHIFT) & 15


## Charges remaining for consumable [param index] (0 or 1); 0 for an out-of-range index.
func charges_of(index: int) -> int:
	if index < 0 or index >= CONSUMABLE_SLOTS:
		return 0
	return (consumable_charges >> (4 * index)) & MAX_CHARGES


## true if the active weapon is the one in slot 2.
func is_second_slot() -> bool:
	return (combat_flags2 & FLAG2_SECOND_SLOT) != 0


## true if the character is exhausted.
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
