extends TestCase
## Pruebas de PlayerState: formato de red (69 bytes little-endian: 35 de movimiento y 34 de combate)
## y comparación con tolerancia. El formato del combate se prueba en test_combat_state.gd.
##
## En la fase 2 el servidor envía este estado y el cliente lo compara con su predicción
## ([method PlayerState.is_close_to]) para decidir si tiene que reconciliar.

const ENCODED_SIZE: int = 69
## Error admitido al pasar por f32 (los valores de prueba son exactos en f32 salvo el yaw).
const F32_EPSILON: float = 1e-5


func test_encode_size_and_layout() -> void:
	var state: PlayerState = _make(Vector3(1.5, -2.25, 1000.125), Vector3(-3.5, 8.0, 0.0625),
			-2.75, true, 0x1FF, 4000000000)
	var bytes: PackedByteArray = state.encode()
	if not assert_eq(bytes.size(), ENCODED_SIZE, "tamaño del estado codificado"):
		return
	assert_near(bytes.decode_float(0), 1.5, F32_EPSILON, "f32 position.x en el byte 0")
	assert_near(bytes.decode_float(4), -2.25, F32_EPSILON, "f32 position.y en el byte 4")
	assert_near(bytes.decode_float(8), 1000.125, F32_EPSILON, "f32 position.z en el byte 8")
	assert_near(bytes.decode_float(12), -3.5, F32_EPSILON, "f32 velocity.x en el byte 12")
	assert_near(bytes.decode_float(16), 8.0, F32_EPSILON, "f32 velocity.y en el byte 16")
	assert_near(bytes.decode_float(20), 0.0625, F32_EPSILON, "f32 velocity.z en el byte 20")
	assert_near(bytes.decode_float(24), -2.75, F32_EPSILON, "f32 yaw en el byte 24")
	assert_eq(bytes.decode_u8(28), 1,
			"u8 flags en el byte 28 (bit 0 = grounded, contadores a 0)")
	assert_eq(bytes.decode_u16(29), 0x1FF, "u16 prev_buttons en el byte 29")
	assert_eq(bytes.decode_u32(31), 4000000000, "u32 last_input_tick en el byte 31")
	assert_eq(bytes.slice(35), _initial_combat_bytes(), "el combate inicial va en los bytes 35-68")

	state.grounded = false
	assert_eq(state.encode().decode_u8(28), 0, "flags sin grounded")

	# Bits 1-3: coyote_ticks; bits 4-7: jump_buffer_ticks.
	state.coyote_ticks = 5
	state.jump_buffer_ticks = 9
	assert_eq(state.encode().decode_u8(28), (5 << 1) | (9 << 4), "flags con los contadores")
	state.grounded = true
	state.coyote_ticks = PlayerState.MAX_COYOTE_TICKS
	state.jump_buffer_ticks = PlayerState.MAX_JUMP_BUFFER_TICKS
	assert_eq(state.encode().decode_u8(28), 0xFF, "flags con todo al máximo")
	# Fuera de rango se limitan en lugar de pisar otros bits.
	state.grounded = false
	state.coyote_ticks = 100
	state.jump_buffer_ticks = -3
	assert_eq(state.encode().decode_u8(28), PlayerState.MAX_COYOTE_TICKS << 1,
			"contadores fuera de rango limitados")


func test_encode_decode_roundtrip() -> void:
	for grounded: bool in [true, false]:
		var state: PlayerState = _make(Vector3(12.5, 0.375, -87.25), Vector3(4.75, -19.5, -0.125),
				1.2345678, grounded, PlayerInput.JUMP | PlayerInput.INTERACT, 0xFFFFFFFF)
		state.coyote_ticks = 6 if grounded else 2
		state.jump_buffer_ticks = 0 if grounded else 11
		var decoded: PlayerState = PlayerState.decode(state.encode())
		if not assert_not_null(decoded, "decode() de 69 bytes válidos"):
			return
		assert_vec_near(decoded.position, state.position, F32_EPSILON, "position")
		assert_vec_near(decoded.velocity, state.velocity, F32_EPSILON, "velocity")
		assert_near(decoded.yaw, state.yaw, 1e-6, "yaw")
		assert_eq(decoded.grounded, grounded, "grounded")
		assert_eq(decoded.prev_buttons, state.prev_buttons, "prev_buttons")
		assert_eq(decoded.last_input_tick, 0xFFFFFFFF, "last_input_tick (u32 sin signo)")
		assert_eq(decoded.coyote_ticks, state.coyote_ticks, "coyote_ticks")
		assert_eq(decoded.jump_buffer_ticks, state.jump_buffer_ticks, "jump_buffer_ticks")
		assert_true(decoded.is_close_to(state, 1e-4),
				"el estado decodificado debe parecerse al original")


func test_decode_wrong_size_returns_null() -> void:
	for size: int in [0, 1, 34, 35, 68, 70]:
		var bytes := PackedByteArray()
		bytes.resize(size)
		assert_null(PlayerState.decode(bytes), "decode() de %d bytes debe devolver null" % size)


func test_duplicate_state_is_independent_copy() -> void:
	var state: PlayerState = _make(Vector3(1.0, 2.0, 3.0), Vector3(4.0, 5.0, 6.0), 0.123456789,
			true, PlayerInput.SPRINT, 99)
	state.coyote_ticks = 4
	state.jump_buffer_ticks = 7
	var copy: PlayerState = state.duplicate_state()
	if not assert_not_null(copy, "duplicate_state()"):
		return
	assert_false(is_same(copy, state), "duplicate_state() debe devolver un objeto nuevo")
	assert_eq(copy.position, state.position, "position")
	assert_eq(copy.velocity, state.velocity, "velocity")
	assert_eq(copy.yaw, state.yaw, "yaw exacto (sin pasar por f32)")
	assert_eq(copy.grounded, state.grounded, "grounded")
	assert_eq(copy.prev_buttons, state.prev_buttons, "prev_buttons")
	assert_eq(copy.last_input_tick, state.last_input_tick, "last_input_tick")
	assert_eq(copy.coyote_ticks, 4, "coyote_ticks")
	assert_eq(copy.jump_buffer_ticks, 7, "jump_buffer_ticks")
	assert_true(copy.combat.equals(state.combat), "combat")
	assert_false(is_same(copy.combat, state.combat), "combat es una copia, no el mismo objeto")
	copy.combat.stamina = 3
	copy.combat.action = CombatState.Action.DODGE
	copy.position = Vector3.ZERO
	copy.velocity = Vector3.ZERO
	copy.yaw = 0.0
	copy.grounded = false
	copy.prev_buttons = 0
	copy.last_input_tick = 0
	copy.coyote_ticks = 0
	copy.jump_buffer_ticks = 0
	var unchanged: String = "modificar la copia no cambia el original"
	assert_eq(state.position, Vector3(1.0, 2.0, 3.0), "%s (position)" % unchanged)
	assert_eq(state.velocity, Vector3(4.0, 5.0, 6.0), "%s (velocity)" % unchanged)
	assert_true(state.grounded, "%s (grounded)" % unchanged)
	assert_eq(state.last_input_tick, 99, "%s (last_input_tick)" % unchanged)
	assert_eq(state.coyote_ticks, 4, "%s (coyote_ticks)" % unchanged)
	assert_eq(state.jump_buffer_ticks, 7, "%s (jump_buffer_ticks)" % unchanged)
	assert_eq(state.combat.stamina, 1000, "%s (combat)" % unchanged)


func test_is_close_to_accepts_equal_and_nearby_states() -> void:
	var base: PlayerState = _make(Vector3(5.0, 1.0, -3.0), Vector3(2.0, 0.0, -1.0), 0.5, true,
			0, 10)
	assert_true(base.is_close_to(base), "un estado está cerca de sí mismo")
	assert_true(base.is_close_to(base.duplicate_state()), "un estado está cerca de su copia")

	var nearby: PlayerState = base.duplicate_state()
	nearby.position += Vector3(0.005, 0.0, 0.0)
	nearby.velocity += Vector3(0.0, 0.0, -0.005)
	nearby.yaw += 0.005
	assert_true(base.is_close_to(nearby),
			"diferencias de 0.005 con epsilon 0.01 por defecto")
	assert_true(nearby.is_close_to(base), "is_close_to debe ser simétrico")


func test_is_close_to_detects_differences() -> void:
	var base: PlayerState = _make(Vector3(5.0, 1.0, -3.0), Vector3(2.0, 0.0, -1.0), 0.5, true,
			0, 10)

	var moved: PlayerState = base.duplicate_state()
	moved.position += Vector3(0.0, 0.02, 0.0)
	assert_false(base.is_close_to(moved), "posición a 0.02 con epsilon 0.01")
	assert_false(moved.is_close_to(base), "posición a 0.02 con epsilon 0.01 (simétrico)")

	var faster: PlayerState = base.duplicate_state()
	faster.velocity += Vector3(0.02, 0.0, 0.0)
	assert_false(base.is_close_to(faster), "velocidad a 0.02 con epsilon 0.01")

	var turned: PlayerState = base.duplicate_state()
	turned.yaw += 0.5
	assert_false(base.is_close_to(turned), "yaw a 0.5 rad")

	var airborne: PlayerState = base.duplicate_state()
	airborne.grounded = false
	assert_false(base.is_close_to(airborne), "grounded distinto")

	# Los contadores de salto cambian lo que harán los ticks siguientes.
	var coyote: PlayerState = base.duplicate_state()
	coyote.coyote_ticks = 1
	assert_false(base.is_close_to(coyote), "coyote_ticks distinto")
	var buffered: PlayerState = base.duplicate_state()
	buffered.jump_buffer_ticks = 3
	assert_false(base.is_close_to(buffered), "jump_buffer_ticks distinto")

	# El combate cambia lo que harán los ticks siguientes: se compara exacto.
	var attacking: PlayerState = base.duplicate_state()
	attacking.combat.action = CombatState.Action.LIGHT
	assert_false(base.is_close_to(attacking), "acción distinta")
	var tired: PlayerState = base.duplicate_state()
	tired.combat.stamina -= 1
	assert_false(base.is_close_to(tired), "resistencia distinta")

	var broken: PlayerState = base.duplicate_state()
	broken.position = Vector3(NAN, 1.0, -3.0)
	assert_false(base.is_close_to(broken), "una posición NaN nunca está cerca")


func test_is_close_to_yaw_is_angle_wrap_aware() -> void:
	var a: PlayerState = _make(Vector3.ZERO, Vector3.ZERO, 0.3, true, 0, 0)
	var b: PlayerState = a.duplicate_state()
	b.yaw = 0.3 + TAU
	assert_true(a.is_close_to(b), "0.3 y 0.3 + TAU son el mismo ángulo")
	b.yaw = 0.3 - 3.0 * TAU
	assert_true(a.is_close_to(b), "0.3 y 0.3 - 3 TAU son el mismo ángulo")

	a.yaw = PI - 5e-5
	b.yaw = -PI + 5e-5
	assert_true(a.is_close_to(b), "PI - 5e-5 y -PI + 5e-5 están a 1e-4 rad (cruzando ±PI)")

	a.yaw = 0.0
	b.yaw = TAU
	assert_true(a.is_close_to(b), "0 y TAU son el mismo ángulo")

	a.yaw = 0.1
	b.yaw = 0.1 - TAU + 0.5
	assert_false(a.is_close_to(b), "a 0.5 rad tras dar la vuelta no están cerca")


func test_is_close_to_respects_custom_epsilon() -> void:
	var a: PlayerState = _make(Vector3(1.0, 0.0, 1.0), Vector3.ZERO, 0.0, false, 0, 0)
	var b: PlayerState = a.duplicate_state()
	b.position += Vector3(0.05, 0.0, 0.0)
	assert_false(a.is_close_to(b), "0.05 con el epsilon por defecto (0.01)")
	assert_true(a.is_close_to(b, 0.1), "0.05 con epsilon 0.1")
	assert_false(a.is_close_to(b, 0.01), "0.05 con epsilon 0.01 explícito")

	var c: PlayerState = a.duplicate_state()
	c.position += Vector3(0.0005, 0.0, 0.0)
	assert_true(a.is_close_to(c, 1e-3), "0.0005 con epsilon 1e-3")
	assert_false(a.is_close_to(c, 1e-4), "0.0005 con epsilon 1e-4")


# --- Utilidades -------------------------------------------------------------------------------

func _initial_combat_bytes() -> PackedByteArray:
	var bytes := PackedByteArray()
	bytes.resize(CombatState.ENCODED_SIZE)
	CombatState.initial(CombatCatalog.rules(), CombatCatalog.default_weapon_id()).encode_into(bytes, 0)
	return bytes


func _make(position: Vector3, velocity: Vector3, yaw: float, grounded: bool, prev_buttons: int,
		last_input_tick: int) -> PlayerState:
	var state := PlayerState.new()
	state.position = position
	state.velocity = velocity
	state.yaw = yaw
	state.grounded = grounded
	state.prev_buttons = prev_buttons
	state.last_input_tick = last_input_tick
	return state
