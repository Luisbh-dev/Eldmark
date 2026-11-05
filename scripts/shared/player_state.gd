class_name PlayerState
extends RefCounted
## Complete simulation state of a character.
##
## Restoring it with [method PlayerCharacter.set_state] and reapplying the same inputs must
## reproduce the same result (phase 2 reconciliation).
## [br][br]
## Network format ([constant ENCODED_SIZE] bytes, little-endian):
## [codeblock]
## offset  type     field
## 0       f32 x3   position
## 12      f32 x3   velocity
## 24      f32      yaw
## 28      u8       flags: bit 0 = grounded, bits 1-3 = coyote_ticks, bits 4-7 = jump_buffer_ticks
## 29      u16      prev_buttons
## 31      u32      last_input_tick
## 35      76 B     combat (CombatState v5, see docs/combat.md section 3.1 and docs/abilities.md
##                  section 3.1)
## [/codeblock]

## Size in bytes of an encoded state (35 for movement and [constant CombatState.ENCODED_SIZE] for
## combat).
const ENCODED_SIZE: int = 111
## Offset of the combat state inside the encoded state.
const COMBAT_OFFSET: int = 35
## Maximum value of [member coyote_ticks] (takes 3 bits of the flags).
const MAX_COYOTE_TICKS: int = 7
## Maximum value of [member jump_buffer_ticks] (takes 4 bits of the flags).
const MAX_JUMP_BUFFER_TICKS: int = 15

const _FLAG_GROUNDED: int = 1 << 0
const _COYOTE_SHIFT: int = 1
const _JUMP_BUFFER_SHIFT: int = 4

# 4-byte buffer used by to_f32() to avoid allocating memory on every call.
static var _f32_scratch: PackedByteArray = PackedByteArray([0, 0, 0, 0])

## Global position of the character's feet.
var position: Vector3 = Vector3.ZERO
## Velocity in m/s.
var velocity: Vector3 = Vector3.ZERO
## Orientation in radians (same convention as [member Node3D.rotation].y).
var yaw: float = 0.0
## Whether the character was on the ground when the last tick ended.
var grounded: bool = false
## Buttons of the last applied input (to detect rising edges, such as the jump).
var prev_buttons: int = 0
## Tick of the last applied input.
var last_input_tick: int = 0
## Ticks in the air the character has left to be able to jump after leaving the ground without
## jumping ("coyote time"). Between 0 and [constant MAX_COYOTE_TICKS].
var coyote_ticks: int = 0
## Ticks remaining for a jump press stored in the buffer (0 = none pending).
## Between 0 and [constant MAX_JUMP_BUFFER_TICKS].
var jump_buffer_ticks: int = 0
## Combat state: current action, stamina, crowd controls imposed by the server... A new state
## carries the initial combat of the default weapon (full stamina, no action).
var combat: CombatState = CombatState.initial(
		CombatCatalog.rules(), CombatCatalog.default_weapon_id())


## Rounds [param value] to a 32-bit float, the precision with which [method encode] stores the yaw
## and the other real fields. [member PlayerCharacter.yaw] uses it in its setter so that the state
## survives the network round trip exactly (phase 2 reconciliation).
## A NaN remains NaN and a value that does not fit in f32 becomes infinity.
static func to_f32(value: float) -> float:
	_f32_scratch.encode_float(0, value)
	return _f32_scratch.decode_float(0)


## Serializes the state into [constant ENCODED_SIZE] little-endian bytes.
func encode() -> PackedByteArray:
	var bytes := PackedByteArray()
	bytes.resize(ENCODED_SIZE)
	bytes.encode_float(0, position.x)
	bytes.encode_float(4, position.y)
	bytes.encode_float(8, position.z)
	bytes.encode_float(12, velocity.x)
	bytes.encode_float(16, velocity.y)
	bytes.encode_float(20, velocity.z)
	bytes.encode_float(24, yaw)
	var flags: int = _FLAG_GROUNDED if grounded else 0
	flags |= clampi(coyote_ticks, 0, MAX_COYOTE_TICKS) << _COYOTE_SHIFT
	flags |= clampi(jump_buffer_ticks, 0, MAX_JUMP_BUFFER_TICKS) << _JUMP_BUFFER_SHIFT
	bytes.encode_u8(28, flags)
	bytes.encode_u16(29, prev_buttons & 0xFFFF)
	bytes.encode_u32(31, last_input_tick & 0xFFFFFFFF)
	combat.encode_into(bytes, COMBAT_OFFSET)
	return bytes


## Rebuilds a state from bytes. Returns null if the size is not
## [constant ENCODED_SIZE].
static func decode(bytes: PackedByteArray) -> PlayerState:
	if bytes.size() != ENCODED_SIZE:
		return null
	var state := PlayerState.new()
	state.position = Vector3(bytes.decode_float(0), bytes.decode_float(4), bytes.decode_float(8))
	state.velocity = Vector3(bytes.decode_float(12), bytes.decode_float(16), bytes.decode_float(20))
	state.yaw = bytes.decode_float(24)
	var flags: int = bytes.decode_u8(28)
	state.grounded = (flags & _FLAG_GROUNDED) != 0
	state.coyote_ticks = (flags >> _COYOTE_SHIFT) & MAX_COYOTE_TICKS
	state.jump_buffer_ticks = (flags >> _JUMP_BUFFER_SHIFT) & MAX_JUMP_BUFFER_TICKS
	state.prev_buttons = bytes.decode_u16(29)
	state.last_input_tick = bytes.decode_u32(31)
	state.combat = CombatState.decode_from(bytes, COMBAT_OFFSET)
	return state


## Exact copy of the state.
func duplicate_state() -> PlayerState:
	var copy := PlayerState.new()
	copy.position = position
	copy.velocity = velocity
	copy.yaw = yaw
	copy.grounded = grounded
	copy.prev_buttons = prev_buttons
	copy.last_input_tick = last_input_tick
	copy.coyote_ticks = coyote_ticks
	copy.jump_buffer_ticks = jump_buffer_ticks
	copy.combat = combat.duplicate_state()
	return copy


## Returns true if [method encode] is byte-for-byte identical in both states. This is the
## reconciliation comparison: it also detects differences in [member prev_buttons],
## [member last_input_tick], the jump counters and [member combat], which [method is_close_to]
## does not tolerate. A null [param other] is never equal.
func equals_exact(other: PlayerState) -> bool:
	if other == null:
		return false
	return encode() == other.encode()


## Returns true if both states match within tolerance: position and velocity
## (distance <= pos_epsilon), yaw (angular difference <= pos_epsilon, accounting for the full
## turn), grounded and the jump counters ([member coyote_ticks] and [member jump_buffer_ticks],
## which change what the next ticks will do) and the combat state, which is compared exactly
## (they are integers). Any NaN makes it return false.
func is_close_to(other: PlayerState, pos_epsilon: float = 0.01) -> bool:
	if other == null:
		return false
	# "not (x <= eps)" is used so that a NaN counts as a difference.
	if not (position.distance_to(other.position) <= pos_epsilon):
		return false
	if not (velocity.distance_to(other.velocity) <= pos_epsilon):
		return false
	if not (absf(angle_difference(yaw, other.yaw)) <= pos_epsilon):
		return false
	if coyote_ticks != other.coyote_ticks or jump_buffer_ticks != other.jump_buffer_ticks:
		return false
	if not combat.equals(other.combat):
		return false
	return grounded == other.grounded


func _to_string() -> String:
	var text: String = "PlayerState(pos=%s, vel=%s, yaw=%.5f, grounded=%s, prev_buttons=%d, "
	text += "last_input_tick=%d, coyote=%d, jump_buffer=%d, %s)"
	return text % [
		position, velocity, yaw, grounded, prev_buttons, last_input_tick, coyote_ticks,
		jump_buffer_ticks, combat,
	]
