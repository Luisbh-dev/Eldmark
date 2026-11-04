class_name PlayerInput
extends RefCounted
## One tick of player intent: exactly what the client will send to the server in phase 2.
##
## The client never sends positions or results, only this intent. Before simulating, the client
## must use [method quantized] so that local prediction works with the same values the server will
## get with [method decode].
## [br][br]
## Network format ([constant ENCODED_SIZE] bytes, little-endian):
## [codeblock]
## offset  type  field
## 0       u32   tick
## 4       s8    move.x   round(v * 127), length <= 1
## 5       s8    move.y
## 6       u16   look_yaw   [0, TAU) -> 0..65535 (65536 wraps to 0)
## 8       s16   look_pitch pitch / (PI / 2) * 32767
## 10      u16   buttons
## [/codeblock]

const JUMP: int = 1 << 0
const SPRINT: int = 1 << 1
const DODGE: int = 1 << 2
const PRIMARY: int = 1 << 3
const BLOCK: int = 1 << 4
const ABILITY_1: int = 1 << 5
const ABILITY_2: int = 1 << 6
const ABILITY_3: int = 1 << 7
const INTERACT: int = 1 << 8
## Swap weapon (Q; docs/habilidades.md, section 3.2).
const SWAP_WEAPON: int = 1 << 9
## Camera's left shoulder: set by the client with the camera's effective shoulder. It is a level,
## not a press; only projectile aiming reads it (docs/habilidades.md, section 4.4).
const AIM_LEFT: int = 1 << 10
## Consumables: health potion (R) and stamina potion (T).
const CONSUMABLE_1: int = 1 << 11
const CONSUMABLE_2: int = 1 << 12
## Bits 13-14 reserved.
## Substituted-input marker (docs/combate.md, section 3.2): it is not a button. It is set by the
## server's input queue and the client's prediction on the input that repeats the last applied one
## when the real one has not arrived. It is outside [constant NetProtocol.VALID_BUTTONS], so the
## client cannot set it: the server discards it when decoding. The action machine neither counts
## nor triggers anything with it, and [member PlayerCharacter.prev_buttons] never stores it.
const SUBSTITUTED: int = 1 << 15

## Size in bytes of an encoded input.
const ENCODED_SIZE: int = 12

const _MOVE_SCALE: int = 127
const _YAW_STEPS: int = 65536
const _PITCH_SCALE: int = 32767
const _HALF_PI: float = PI / 2.0

## Simulation tick number this input belongs to (u32 on the network).
var tick: int = 0
## Desired movement: x = right, y = forward. Length <= 1.
var move: Vector2 = Vector2.ZERO
## Camera yaw in radians, same convention as [member Node3D.rotation].y
## (0 faces -Z). After quantization it lies in [0, TAU).
var look_yaw: float = 0.0
## Camera pitch in radians; positive looks up. Clamped to [-PI/2, PI/2].
var look_pitch: float = 0.0
## Mask of buttons pressed on this tick (constants JUMP, SPRINT...).
var buttons: int = 0


## Returns true if the button (one of this class's constants) is pressed.
func has(button: int) -> bool:
	return (buttons & button) != 0


## Serializes the input into [constant ENCODED_SIZE] little-endian bytes.
func encode() -> PackedByteArray:
	var bytes := PackedByteArray()
	bytes.resize(ENCODED_SIZE)
	var move_q: Vector2i = _quantize_move(move)
	bytes.encode_u32(0, tick & 0xFFFFFFFF)
	bytes.encode_s8(4, move_q.x)
	bytes.encode_s8(5, move_q.y)
	bytes.encode_u16(6, _quantize_yaw(look_yaw))
	bytes.encode_s16(8, _quantize_pitch(look_pitch))
	bytes.encode_u16(10, buttons & 0xFFFF)
	return bytes


## Rebuilds an input from bytes. Returns null if the size is not [constant ENCODED_SIZE].
## Out-of-range values (for example, from a malicious client) are normalized, so the result always
## satisfies the invariants. The resulting yaw is in [0, TAU).
static func decode(bytes: PackedByteArray) -> PlayerInput:
	if bytes.size() != ENCODED_SIZE:
		return null
	var input := PlayerInput.new()
	input.tick = bytes.decode_u32(0)
	var move_x: int = clampi(bytes.decode_s8(4), -_MOVE_SCALE, _MOVE_SCALE)
	var move_y: int = clampi(bytes.decode_s8(5), -_MOVE_SCALE, _MOVE_SCALE)
	if move_x * move_x + move_y * move_y > _MOVE_SCALE * _MOVE_SCALE:
		# Vector with length > 1: it is requantized so that it is a canonical value.
		var fixed: Vector2i = _quantize_move(Vector2(move_x, move_y) / float(_MOVE_SCALE))
		move_x = fixed.x
		move_y = fixed.y
	input.move = Vector2(move_x / float(_MOVE_SCALE), move_y / float(_MOVE_SCALE))
	input.look_yaw = bytes.decode_u16(6) / float(_YAW_STEPS) * TAU
	var pitch_q: int = clampi(bytes.decode_s16(8), -_PITCH_SCALE, _PITCH_SCALE)
	input.look_pitch = pitch_q / float(_PITCH_SCALE) * _HALF_PI
	input.buttons = bytes.decode_u16(10)
	return input


## Returns the input as the server will see it: equivalent to decode(encode()).
## It is idempotent: quantized().quantized() equals quantized().
func quantized() -> PlayerInput:
	return decode(encode())


## Exact copy (not quantized).
func duplicate_input() -> PlayerInput:
	var copy := PlayerInput.new()
	copy.tick = tick
	copy.move = move
	copy.look_yaw = look_yaw
	copy.look_pitch = look_pitch
	copy.buttons = buttons
	return copy


func _to_string() -> String:
	return "PlayerInput(tick=%d, move=%s, look_yaw=%.5f, look_pitch=%.5f, buttons=%d)" % [
		tick, move, look_yaw, look_pitch, buttons,
	]


## Quantizes movement to integers in [-127, 127] with length <= 127.
## Rounding can leave the length slightly above 1; in that case it is truncated toward zero, which
## guarantees length <= 1 and that requantizing the result does not change it.
static func _quantize_move(value: Vector2) -> Vector2i:
	if not value.is_finite():
		return Vector2i.ZERO
	var clamped: Vector2 = value.limit_length(1.0)
	var qx: int = roundi(clamped.x * _MOVE_SCALE)
	var qy: int = roundi(clamped.y * _MOVE_SCALE)
	if qx * qx + qy * qy > _MOVE_SCALE * _MOVE_SCALE:
		qx = int(clamped.x * _MOVE_SCALE)
		qy = int(clamped.y * _MOVE_SCALE)
	return Vector2i(clampi(qx, -_MOVE_SCALE, _MOVE_SCALE), clampi(qy, -_MOVE_SCALE, _MOVE_SCALE))


## Wraps the yaw to [0, TAU) and maps it to 0..65535 (65536 wraps to 0).
static func _quantize_yaw(value: float) -> int:
	if not is_finite(value):
		return 0
	var wrapped: float = fposmod(value, TAU)
	return roundi(wrapped / TAU * _YAW_STEPS) % _YAW_STEPS


## Clamps the pitch to [-PI/2, PI/2] and maps it to -32767..32767.
static func _quantize_pitch(value: float) -> int:
	if not is_finite(value):
		return 0
	var clamped: float = clampf(value, -_HALF_PI, _HALF_PI)
	return clampi(roundi(clamped / _HALF_PI * _PITCH_SCALE), -_PITCH_SCALE, _PITCH_SCALE)
