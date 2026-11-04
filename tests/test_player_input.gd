extends TestCase
## Tests of PlayerInput: network format (12 little-endian bytes) and quantization.
##
## In phase 2 the client predicts with [method PlayerInput.quantized] and the server simulates with
## [method PlayerInput.decode]; if they do not match bit for bit, the prediction diverges from the server.

const ENCODED_SIZE: int = 12
const MOVE_STEP: float = 1.0 / 127.0
## Maximum error allowed when quantizing a movement of length >= 1: rounding can leave the
## length slightly above 1 and the implementation may truncate a step to avoid it.
const CLAMPED_MOVE_TOLERANCE: float = MOVE_STEP * 1.5
## Maximum length allowed after quantizing (1 plus one quantization step).
const MAX_QUANTIZED_MOVE_LENGTH: float = 1.0 + MOVE_STEP
const YAW_STEP: float = TAU / 65536.0
const PITCH_STEP: float = (PI / 2.0) / 32767.0
## Fixed seed: the "random" inputs are always the same.
const RANDOM_SEED: int = 20261027


func test_button_constants_match_wire_format() -> void:
	# The bit order is part of the protocol: changing it breaks client/server compatibility.
	assert_eq(PlayerInput.JUMP, 1 << 0, "JUMP")
	assert_eq(PlayerInput.SPRINT, 1 << 1, "SPRINT")
	assert_eq(PlayerInput.DODGE, 1 << 2, "DODGE")
	assert_eq(PlayerInput.PRIMARY, 1 << 3, "PRIMARY")
	assert_eq(PlayerInput.BLOCK, 1 << 4, "BLOCK")
	assert_eq(PlayerInput.ABILITY_1, 1 << 5, "ABILITY_1")
	assert_eq(PlayerInput.ABILITY_2, 1 << 6, "ABILITY_2")
	assert_eq(PlayerInput.ABILITY_3, 1 << 7, "ABILITY_3")
	assert_eq(PlayerInput.INTERACT, 1 << 8, "INTERACT")
	# Phase 4 (docs/habilidades.md, section 3.2); 13-14 reserved and 15 is SUBSTITUTED.
	assert_eq(PlayerInput.SWAP_WEAPON, 1 << 9, "SWAP_WEAPON")
	assert_eq(PlayerInput.AIM_LEFT, 1 << 10, "AIM_LEFT")
	assert_eq(PlayerInput.CONSUMABLE_1, 1 << 11, "CONSUMABLE_1")
	assert_eq(PlayerInput.CONSUMABLE_2, 1 << 12, "CONSUMABLE_2")
	assert_eq(PlayerInput.SUBSTITUTED, 1 << 15, "SUBSTITUTED")


func test_encode_has_documented_layout() -> void:
	var input: PlayerInput = _make(0x01020304, Vector2(0.0, -1.0), PI, PI / 2.0,
			PlayerInput.JUMP | PlayerInput.INTERACT)
	var bytes: PackedByteArray = input.encode()
	if not assert_eq(bytes.size(), ENCODED_SIZE, "size of the encoded input"):
		return
	# u32 little-endian tick.
	assert_eq(bytes[0], 0x04, "byte 0 (tick, little-endian)")
	assert_eq(bytes[1], 0x03, "byte 1 (tick)")
	assert_eq(bytes[2], 0x02, "byte 2 (tick)")
	assert_eq(bytes[3], 0x01, "byte 3 (tick)")
	assert_eq(bytes.decode_s8(4), 0, "s8 move.x")
	assert_eq(bytes.decode_s8(5), -127, "s8 move.y (-1 -> -127)")
	assert_eq(bytes.decode_u16(6), 32768, "u16 yaw (PI -> 32768)")
	assert_eq(bytes.decode_s16(8), 32767, "s16 pitch (PI/2 -> 32767)")
	assert_eq(bytes.decode_u16(10), 0x0101, "u16 buttons (JUMP | INTERACT)")

	var other: PlayerInput = _make(0, Vector2(1.0, 0.0), -PI / 2.0, -PI / 2.0, 0)
	var other_bytes: PackedByteArray = other.encode()
	assert_eq(other_bytes.decode_u32(0), 0, "tick 0")
	assert_eq(other_bytes.decode_s8(4), 127, "s8 move.x (1 -> 127)")
	assert_eq(other_bytes.decode_s8(5), 0, "s8 move.y")
	assert_eq(other_bytes.decode_u16(6), 49152, "u16 yaw (-PI/2 wrapped to 3PI/2 -> 49152)")
	assert_eq(other_bytes.decode_s16(8), -32767, "s16 pitch (-PI/2 -> -32767)")
	assert_eq(other_bytes.decode_u16(10), 0, "u16 empty buttons")


func test_roundtrip_preserves_values_within_quantization() -> void:
	var input: PlayerInput = _make(123456, Vector2(0.25, -0.5), 1.2345, -0.4,
			PlayerInput.SPRINT | PlayerInput.BLOCK | PlayerInput.ABILITY_3)
	var decoded: PlayerInput = PlayerInput.decode(input.encode())
	if not assert_not_null(decoded, "decode() of 12 valid bytes"):
		return
	assert_eq(decoded.tick, 123456, "tick")
	assert_vec_near(decoded.move, input.move, MOVE_STEP, "move")
	assert_near(absf(angle_difference(decoded.look_yaw, input.look_yaw)), 0.0,
			YAW_STEP * 0.5 + 1e-9, "look_yaw")
	assert_near(decoded.look_pitch, input.look_pitch, PITCH_STEP * 0.5 + 1e-9, "look_pitch")
	assert_eq(decoded.buttons, input.buttons, "buttons")


func test_quantized_equals_decode_of_encode_and_keeps_original() -> void:
	var input: PlayerInput = _make(77, Vector2(-0.33, 0.71), -2.5, 0.9, PlayerInput.DODGE)
	var original_move: Vector2 = input.move
	var original_yaw: float = input.look_yaw
	var quantized: PlayerInput = input.quantized()
	var decoded: PlayerInput = PlayerInput.decode(input.encode())
	if not assert_not_null(quantized, "quantized()") or not assert_not_null(decoded, "decode()"):
		return
	assert_false(is_same(quantized, input), "quantized() must return a new object")
	assert_true(_inputs_identical(quantized, decoded),
			"quantized() must equal decode(encode()): %s versus %s" % [quantized, decoded])
	assert_eq(input.move, original_move, "quantized() must not modify the original (move)")
	assert_eq(input.look_yaw, original_yaw, "quantized() must not modify the original (look_yaw)")


func test_quantization_is_idempotent_for_random_inputs() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = RANDOM_SEED
	for i: int in 2000:
		var radius: float = rng.randf_range(0.0, 1.6)
		var angle: float = rng.randf_range(-PI, PI)
		var input: PlayerInput = _make(
				rng.randi(),
				Vector2(cos(angle), sin(angle)) * radius,
				rng.randf_range(-40.0, 40.0),
				rng.randf_range(-2.0, 2.0),
				rng.randi_range(0, 0x1FF))
		if not _check_idempotent(input, "entrada aleatoria #%d" % i):
			return


func test_quantization_is_idempotent_on_unit_circle() -> void:
	# The delicate case: rounding a length-1 vector can leave it slightly above 1.
	for i: int in 3600:
		var angle: float = TAU * i / 3600.0
		for radius: float in [1.0, 1.3]:
			var direction := Vector2(cos(angle), sin(angle))
			var input: PlayerInput = _make(i, direction * radius, angle, 0.0, 0)
			if not _check_idempotent(input, "dirección %d/3600, radio %s" % [i, radius]):
				return


func test_negative_and_large_yaw_wraps() -> void:
	var cases: Array[float] = [
		-PI / 2.0, -0.001, -100.0, 7.0 * TAU + 0.3, 1000.0, TAU, -TAU, 3.0 * PI,
	]
	for yaw: float in cases:
		var bytes: PackedByteArray = _make(1, Vector2.ZERO, yaw, 0.0, 0).encode()
		var decoded: PlayerInput = PlayerInput.decode(bytes)
		if not assert_not_null(decoded, "decode() with yaw %s" % yaw):
			continue
		assert_true(is_finite(decoded.look_yaw), "decoded yaw %s must be finite" % yaw)
		assert_near(absf(angle_difference(decoded.look_yaw, yaw)), 0.0, YAW_STEP * 0.5 + 1e-6,
				"yaw %s must represent the same angle" % yaw)
	# Just below TAU rounds to 65536, which must wrap back to 0 (neither overflow nor saturate).
	var near_tau: PackedByteArray = _make(1, Vector2.ZERO, TAU - 1e-7, 0.0, 0).encode()
	assert_eq(near_tau.decode_u16(6), 0, "yaw TAU - 1e-7 -> 65536 must wrap to 0")
	var tiny_negative: PackedByteArray = _make(1, Vector2.ZERO, -1e-9, 0.0, 0).encode()
	assert_eq(tiny_negative.decode_u16(6), 0, "yaw -1e-9 must wrap to 0")


func test_pitch_is_clamped_to_half_pi() -> void:
	var up: PlayerInput = _make(1, Vector2.ZERO, 0.0, 3.0, 0).quantized()
	var down: PlayerInput = _make(1, Vector2.ZERO, 0.0, -3.0, 0).quantized()
	if not assert_not_null(up, "quantized()") or not assert_not_null(down, "quantized()"):
		return
	assert_near(up.look_pitch, PI / 2.0, PITCH_STEP, "pitch 3.0 is clamped to PI/2")
	assert_near(down.look_pitch, -PI / 2.0, PITCH_STEP, "pitch -3.0 is clamped to -PI/2")
	assert_eq(_make(1, Vector2.ZERO, 0.0, 3.0, 0).encode().decode_s16(8), 32767,
			"maximum s16 pitch")


func test_buttons_roundtrip_and_has() -> void:
	var all_buttons: Array[int] = [
		PlayerInput.JUMP, PlayerInput.SPRINT, PlayerInput.DODGE, PlayerInput.PRIMARY,
		PlayerInput.BLOCK, PlayerInput.ABILITY_1, PlayerInput.ABILITY_2, PlayerInput.ABILITY_3,
		PlayerInput.INTERACT, PlayerInput.SWAP_WEAPON, PlayerInput.AIM_LEFT, PlayerInput.CONSUMABLE_1,
		PlayerInput.CONSUMABLE_2,
	]
	var mask: int = 0
	for button: int in all_buttons:
		mask |= button
	var everything: PlayerInput = _make(1, Vector2.ZERO, 0.0, 0.0, mask).quantized()
	if not assert_not_null(everything, "quantized()"):
		return
	assert_eq(everything.buttons, mask, "all the buttons survive (INTERACT needs u16)")
	for button: int in all_buttons:
		assert_true(everything.has(button), "has(%d) with all pressed" % button)

	for button: int in all_buttons:
		var single: PlayerInput = _make(1, Vector2.ZERO, 0.0, 0.0, button).quantized()
		assert_eq(single.buttons, button, "only button %d" % button)
		for other: int in all_buttons:
			assert_eq(single.has(other), other == button,
					"has(%d) with only %d pressed" % [other, button])

	var none: PlayerInput = _make(1, Vector2.ZERO, 0.0, 0.0, 0)
	for button: int in all_buttons:
		assert_false(none.has(button), "has(%d) without buttons" % button)


func test_move_longer_than_one_is_clamped() -> void:
	var cases: Array[Array] = [
		[Vector2(3.0, 4.0), Vector2(0.6, 0.8)],
		[Vector2(2.0, 0.0), Vector2(1.0, 0.0)],
		[Vector2(0.0, -9.0), Vector2(0.0, -1.0)],
		[Vector2(-5.0, -5.0), Vector2(-sqrt(0.5), -sqrt(0.5))],
		[Vector2(1.0, 1.0), Vector2(sqrt(0.5), sqrt(0.5))],
		# Below 1 it is not rescaled.
		[Vector2(0.3, 0.4), Vector2(0.3, 0.4)],
		[Vector2(-0.05, 0.02), Vector2(-0.05, 0.02)],
	]
	for entry: Array in cases:
		var raw: Vector2 = entry[0]
		var expected: Vector2 = entry[1]
		var quantized: PlayerInput = _make(1, raw, 0.0, 0.0, 0).quantized()
		if not assert_not_null(quantized, "quantized()"):
			return
		assert_vec_near(quantized.move, expected, CLAMPED_MOVE_TOLERANCE, "move %s" % raw)
		assert_true(quantized.move.length() <= MAX_QUANTIZED_MOVE_LENGTH,
				"quantized %s move must have length <= 1 (it has %s)" % [
					raw, quantized.move.length(),
				])


func test_tick_uses_full_u32() -> void:
	for tick: int in [0, 1, 65537, 0x7FFFFFFF, 0x80000000, 4000000000, 0xFFFFFFFF]:
		var bytes: PackedByteArray = _make(tick, Vector2.ZERO, 0.0, 0.0, 0).encode()
		var decoded: PlayerInput = PlayerInput.decode(bytes)
		if assert_not_null(decoded, "decode() with tick %d" % tick):
			assert_eq(decoded.tick, tick, "tick %d (unsigned u32)" % tick)


func test_wrong_size_decode_returns_null() -> void:
	for size: int in [0, 1, 11, 13, 24]:
		var bytes := PackedByteArray()
		bytes.resize(size)
		assert_null(PlayerInput.decode(bytes), "decode() of %d bytes must return null" % size)


func test_duplicate_input_is_independent_copy() -> void:
	var input: PlayerInput = _make(9, Vector2(0.1234567, -0.7654321), 1.0000001, -0.3333333,
			PlayerInput.BLOCK)
	var copy: PlayerInput = input.duplicate_input()
	if not assert_not_null(copy, "duplicate_input()"):
		return
	assert_false(is_same(copy, input), "duplicate_input() must return a new object")
	assert_true(_inputs_identical(copy, input),
			"the copy must be exact, unquantized: %s versus %s" % [copy, input])
	copy.tick = 10
	copy.move = Vector2.ZERO
	copy.look_yaw = 2.0
	copy.look_pitch = 0.0
	copy.buttons = 0
	var unchanged: String = "modificar la copia no cambia el original"
	assert_eq(input.tick, 9, "%s (tick)" % unchanged)
	assert_eq(input.move, Vector2(0.1234567, -0.7654321), "%s (move)" % unchanged)
	assert_eq(input.buttons, PlayerInput.BLOCK, "%s (buttons)" % unchanged)


# --- Utilities --------------------------------------------------------------------------------

func _make(tick: int, move: Vector2, look_yaw: float, look_pitch: float,
		buttons: int) -> PlayerInput:
	var input := PlayerInput.new()
	input.tick = tick
	input.move = move
	input.look_yaw = look_yaw
	input.look_pitch = look_pitch
	input.buttons = buttons
	return input


func _inputs_identical(a: PlayerInput, b: PlayerInput) -> bool:
	return (a.tick == b.tick and a.move == b.move and a.look_yaw == b.look_yaw
			and a.look_pitch == b.look_pitch and a.buttons == b.buttons)


## Checks that quantized().quantized() is exactly equal to quantized(), field by field and byte
## by byte, and that it matches decode(encode()). Returns false (with a single failure) if not.
func _check_idempotent(input: PlayerInput, label: String) -> bool:
	var once: PlayerInput = input.quantized()
	if not assert_not_null(once, "%s: quantized()" % label):
		return false
	var twice: PlayerInput = once.quantized()
	var decoded: PlayerInput = PlayerInput.decode(input.encode())
	if not assert_true(_inputs_identical(once, twice),
			"%s: the quantization is not idempotent\n      original: %s\n      once:  %s"
			% [label, input, once] + "\n      twice: %s" % twice):
		return false
	if not assert_eq(once.encode(), twice.encode(), "%s: different bytes on requantizing" % label):
		return false
	if not assert_true(_inputs_identical(once, decoded),
			"%s: quantized() differs from decode(encode()): %s versus %s" % [
				label, once, decoded,
			]):
		return false
	return assert_true(once.move.length() <= MAX_QUANTIZED_MOVE_LENGTH,
			"%s: quantized move with length %s > 1" % [label, once.move.length()])
