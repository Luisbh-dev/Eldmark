extends TestCase
## Pruebas de PlayerInput: formato de red (12 bytes little-endian) y cuantización.
##
## En la fase 2 el cliente predice con [method PlayerInput.quantized] y el servidor simula con
## [method PlayerInput.decode]; si no coinciden bit a bit, la predicción diverge del servidor.

const ENCODED_SIZE: int = 12
const MOVE_STEP: float = 1.0 / 127.0
## Error máximo admitido al cuantizar un movimiento de longitud >= 1: redondear puede dejar la
## longitud un pelo por encima de 1 y la implementación puede truncar un paso para evitarlo.
const CLAMPED_MOVE_TOLERANCE: float = MOVE_STEP * 1.5
## Longitud máxima admitida tras cuantizar (1 más un paso de cuantización).
const MAX_QUANTIZED_MOVE_LENGTH: float = 1.0 + MOVE_STEP
const YAW_STEP: float = TAU / 65536.0
const PITCH_STEP: float = (PI / 2.0) / 32767.0
## Semilla fija: las entradas "aleatorias" son siempre las mismas.
const RANDOM_SEED: int = 20261027


func test_button_constants_match_wire_format() -> void:
	# El orden de bits es parte del protocolo: cambiarlo rompe la compatibilidad cliente/servidor.
	assert_eq(PlayerInput.JUMP, 1 << 0, "JUMP")
	assert_eq(PlayerInput.SPRINT, 1 << 1, "SPRINT")
	assert_eq(PlayerInput.DODGE, 1 << 2, "DODGE")
	assert_eq(PlayerInput.PRIMARY, 1 << 3, "PRIMARY")
	assert_eq(PlayerInput.BLOCK, 1 << 4, "BLOCK")
	assert_eq(PlayerInput.ABILITY_1, 1 << 5, "ABILITY_1")
	assert_eq(PlayerInput.ABILITY_2, 1 << 6, "ABILITY_2")
	assert_eq(PlayerInput.ABILITY_3, 1 << 7, "ABILITY_3")
	assert_eq(PlayerInput.INTERACT, 1 << 8, "INTERACT")
	# Fase 4 (docs/habilidades.md, sección 3.2); 13-14 reservados y 15 es SUBSTITUTED.
	assert_eq(PlayerInput.SWAP_WEAPON, 1 << 9, "SWAP_WEAPON")
	assert_eq(PlayerInput.AIM_LEFT, 1 << 10, "AIM_LEFT")
	assert_eq(PlayerInput.CONSUMABLE_1, 1 << 11, "CONSUMABLE_1")
	assert_eq(PlayerInput.CONSUMABLE_2, 1 << 12, "CONSUMABLE_2")
	assert_eq(PlayerInput.SUBSTITUTED, 1 << 15, "SUBSTITUTED")


func test_encode_has_documented_layout() -> void:
	var input: PlayerInput = _make(0x01020304, Vector2(0.0, -1.0), PI, PI / 2.0,
			PlayerInput.JUMP | PlayerInput.INTERACT)
	var bytes: PackedByteArray = input.encode()
	if not assert_eq(bytes.size(), ENCODED_SIZE, "tamaño de la entrada codificada"):
		return
	# u32 tick little-endian.
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
	assert_eq(other_bytes.decode_u16(6), 49152, "u16 yaw (-PI/2 envuelto a 3PI/2 -> 49152)")
	assert_eq(other_bytes.decode_s16(8), -32767, "s16 pitch (-PI/2 -> -32767)")
	assert_eq(other_bytes.decode_u16(10), 0, "u16 buttons vacío")


func test_roundtrip_preserves_values_within_quantization() -> void:
	var input: PlayerInput = _make(123456, Vector2(0.25, -0.5), 1.2345, -0.4,
			PlayerInput.SPRINT | PlayerInput.BLOCK | PlayerInput.ABILITY_3)
	var decoded: PlayerInput = PlayerInput.decode(input.encode())
	if not assert_not_null(decoded, "decode() de 12 bytes válidos"):
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
	assert_false(is_same(quantized, input), "quantized() debe devolver un objeto nuevo")
	assert_true(_inputs_identical(quantized, decoded),
			"quantized() debe ser igual a decode(encode()): %s frente a %s" % [quantized, decoded])
	assert_eq(input.move, original_move, "quantized() no debe modificar el original (move)")
	assert_eq(input.look_yaw, original_yaw, "quantized() no debe modificar el original (look_yaw)")


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
	# El caso delicado: redondear un vector de longitud 1 puede dejarlo un poco por encima de 1.
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
		if not assert_not_null(decoded, "decode() con yaw %s" % yaw):
			continue
		assert_true(is_finite(decoded.look_yaw), "yaw %s decodificado debe ser finito" % yaw)
		assert_near(absf(angle_difference(decoded.look_yaw, yaw)), 0.0, YAW_STEP * 0.5 + 1e-6,
				"yaw %s debe representar el mismo ángulo" % yaw)
	# Justo por debajo de TAU redondea a 65536, que debe volver a 0 (no desbordar ni saturar).
	var near_tau: PackedByteArray = _make(1, Vector2.ZERO, TAU - 1e-7, 0.0, 0).encode()
	assert_eq(near_tau.decode_u16(6), 0, "yaw TAU - 1e-7 -> 65536 debe envolverse a 0")
	var tiny_negative: PackedByteArray = _make(1, Vector2.ZERO, -1e-9, 0.0, 0).encode()
	assert_eq(tiny_negative.decode_u16(6), 0, "yaw -1e-9 debe envolverse a 0")


func test_pitch_is_clamped_to_half_pi() -> void:
	var up: PlayerInput = _make(1, Vector2.ZERO, 0.0, 3.0, 0).quantized()
	var down: PlayerInput = _make(1, Vector2.ZERO, 0.0, -3.0, 0).quantized()
	if not assert_not_null(up, "quantized()") or not assert_not_null(down, "quantized()"):
		return
	assert_near(up.look_pitch, PI / 2.0, PITCH_STEP, "pitch 3.0 se limita a PI/2")
	assert_near(down.look_pitch, -PI / 2.0, PITCH_STEP, "pitch -3.0 se limita a -PI/2")
	assert_eq(_make(1, Vector2.ZERO, 0.0, 3.0, 0).encode().decode_s16(8), 32767,
			"s16 pitch máximo")


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
	assert_eq(everything.buttons, mask, "todos los botones sobreviven (INTERACT necesita u16)")
	for button: int in all_buttons:
		assert_true(everything.has(button), "has(%d) con todos pulsados" % button)

	for button: int in all_buttons:
		var single: PlayerInput = _make(1, Vector2.ZERO, 0.0, 0.0, button).quantized()
		assert_eq(single.buttons, button, "solo el botón %d" % button)
		for other: int in all_buttons:
			assert_eq(single.has(other), other == button,
					"has(%d) con solo %d pulsado" % [other, button])

	var none: PlayerInput = _make(1, Vector2.ZERO, 0.0, 0.0, 0)
	for button: int in all_buttons:
		assert_false(none.has(button), "has(%d) sin botones" % button)


func test_move_longer_than_one_is_clamped() -> void:
	var cases: Array[Array] = [
		[Vector2(3.0, 4.0), Vector2(0.6, 0.8)],
		[Vector2(2.0, 0.0), Vector2(1.0, 0.0)],
		[Vector2(0.0, -9.0), Vector2(0.0, -1.0)],
		[Vector2(-5.0, -5.0), Vector2(-sqrt(0.5), -sqrt(0.5))],
		[Vector2(1.0, 1.0), Vector2(sqrt(0.5), sqrt(0.5))],
		# Por debajo de 1 no se reescala.
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
				"move %s cuantizado debe tener longitud <= 1 (tiene %s)" % [
					raw, quantized.move.length(),
				])


func test_tick_uses_full_u32() -> void:
	for tick: int in [0, 1, 65537, 0x7FFFFFFF, 0x80000000, 4000000000, 0xFFFFFFFF]:
		var bytes: PackedByteArray = _make(tick, Vector2.ZERO, 0.0, 0.0, 0).encode()
		var decoded: PlayerInput = PlayerInput.decode(bytes)
		if assert_not_null(decoded, "decode() con tick %d" % tick):
			assert_eq(decoded.tick, tick, "tick %d (u32 sin signo)" % tick)


func test_wrong_size_decode_returns_null() -> void:
	for size: int in [0, 1, 11, 13, 24]:
		var bytes := PackedByteArray()
		bytes.resize(size)
		assert_null(PlayerInput.decode(bytes), "decode() de %d bytes debe devolver null" % size)


func test_duplicate_input_is_independent_copy() -> void:
	var input: PlayerInput = _make(9, Vector2(0.1234567, -0.7654321), 1.0000001, -0.3333333,
			PlayerInput.BLOCK)
	var copy: PlayerInput = input.duplicate_input()
	if not assert_not_null(copy, "duplicate_input()"):
		return
	assert_false(is_same(copy, input), "duplicate_input() debe devolver un objeto nuevo")
	assert_true(_inputs_identical(copy, input),
			"la copia debe ser exacta, sin cuantizar: %s frente a %s" % [copy, input])
	copy.tick = 10
	copy.move = Vector2.ZERO
	copy.look_yaw = 2.0
	copy.look_pitch = 0.0
	copy.buttons = 0
	var unchanged: String = "modificar la copia no cambia el original"
	assert_eq(input.tick, 9, "%s (tick)" % unchanged)
	assert_eq(input.move, Vector2(0.1234567, -0.7654321), "%s (move)" % unchanged)
	assert_eq(input.buttons, PlayerInput.BLOCK, "%s (buttons)" % unchanged)


# --- Utilidades -------------------------------------------------------------------------------

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


## Comprueba que quantized().quantized() es exactamente igual a quantized(), campo a campo y byte
## a byte, y que coincide con decode(encode()). Devuelve false (con un solo fallo) si no.
func _check_idempotent(input: PlayerInput, label: String) -> bool:
	var once: PlayerInput = input.quantized()
	if not assert_not_null(once, "%s: quantized()" % label):
		return false
	var twice: PlayerInput = once.quantized()
	var decoded: PlayerInput = PlayerInput.decode(input.encode())
	if not assert_true(_inputs_identical(once, twice),
			"%s: la cuantización no es idempotente\n      original: %s\n      una vez:  %s"
			% [label, input, once] + "\n      dos veces: %s" % twice):
		return false
	if not assert_eq(once.encode(), twice.encode(), "%s: bytes distintos al recuantizar" % label):
		return false
	if not assert_true(_inputs_identical(once, decoded),
			"%s: quantized() distinto de decode(encode()): %s frente a %s" % [
				label, once, decoded,
			]):
		return false
	return assert_true(once.move.length() <= MAX_QUANTIZED_MOVE_LENGTH,
			"%s: move cuantizado con longitud %s > 1" % [label, once.move.length()])
