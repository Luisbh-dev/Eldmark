extends TestCase
## Pruebas de [CombatState] (docs/combate.md sección 3.1) y de su sitio dentro de [PlayerState]:
## offsets, ida y vuelta, copia y comparación de los campos de la fase 3 (los bytes 35-68). Los
## campos de la versión 5 (76 B dentro de un PlayerState de 111 B, docs/habilidades.md sección 3.1)
## se prueban en test_combat_state_v5.gd.

const COMBAT_SIZE: int = 76
const PLAYER_STATE_SIZE: int = 111
## Offset del combate dentro del estado de jugador codificado.
const COMBAT_AT: int = 35


func _full_state() -> CombatState:
	var c := CombatState.new()
	c.action = CombatState.Action.DODGE
	c.action_id = 0x1234
	c.action_tick = 0xDEADBEEF
	c.combo_step = 2
	c.primary_held = 200
	c.charge_ticks = 72
	c.buffered = CombatState.pack_buffer(CombatState.BUFFER_DODGE, 5)
	c.stamina = 987
	c.stamina_regen_tick = 0x01020304
	c.combat_flags = CombatState.FLAG_EXHAUSTED | CombatState.FLAG_BLOCK_HELD
	c.action_dir = 0xABCD
	c.cc_until_tick = 4000000000
	c.knockback = Vector2(-3.25, 12.5)
	c.parry_ready_tick = 77777
	c.weapon_id = 0x0102
	return c


func test_sizes() -> void:
	assert_eq(CombatState.ENCODED_SIZE, COMBAT_SIZE, "el estado de combate ocupa 76 bytes")
	assert_eq(PlayerState.ENCODED_SIZE, PLAYER_STATE_SIZE, "el estado de jugador ocupa 111 bytes")
	assert_eq(PlayerState.COMBAT_OFFSET, COMBAT_AT, "el combate empieza en el byte 35")
	assert_eq(PlayerState.ENCODED_SIZE, 35 + CombatState.ENCODED_SIZE, "35 + 76")


func test_offsets_match_the_table() -> void:
	# Cada campo en el offset de la tabla de la sección 3.1 (relativo a PlayerState).
	var state := PlayerState.new()
	state.combat = _full_state()
	var bytes: PackedByteArray = state.encode()
	if not assert_eq(bytes.size(), PLAYER_STATE_SIZE, "tamaño"):
		return
	assert_eq(bytes.decode_u8(35), CombatState.Action.DODGE, "u8 action en 35")
	assert_eq(bytes.decode_u16(36), 0x1234, "u16 action_id en 36")
	assert_eq(bytes.decode_u32(38), 0xDEADBEEF, "u32 action_tick en 38")
	assert_eq(bytes.decode_u8(42), 2, "u8 combo_step en 42")
	assert_eq(bytes.decode_u8(43), 200, "u8 primary_held en 43")
	assert_eq(bytes.decode_u8(44), 72, "u8 charge_ticks en 44")
	assert_eq(bytes.decode_u8(45), CombatState.BUFFER_DODGE | (5 << 4), "u8 buffered en 45")
	assert_eq(bytes.decode_u16(46), 987, "u16 stamina en 46")
	assert_eq(bytes.decode_u32(48), 0x01020304, "u32 stamina_regen_tick en 48")
	assert_eq(bytes.decode_u8(52), CombatState.FLAG_EXHAUSTED | CombatState.FLAG_BLOCK_HELD,
			"u8 combat_flags en 52")
	assert_eq(bytes.decode_u16(53), 0xABCD, "u16 action_dir en 53")
	assert_eq(bytes.decode_u32(55), 4000000000, "u32 cc_until_tick en 55")
	assert_eq(bytes.decode_s16(59), -325, "s16 knockback.x en 59 (cm/s)")
	assert_eq(bytes.decode_s16(61), 1250, "s16 knockback.z en 61 (cm/s)")
	assert_eq(bytes.decode_u32(63), 77777, "u32 parry_ready_tick en 63")
	assert_eq(bytes.decode_u16(67), 0x0102, "u16 weapon_id en 67")


func test_combat_roundtrip() -> void:
	var original: CombatState = _full_state()
	var bytes := PackedByteArray()
	bytes.resize(COMBAT_SIZE)
	original.encode_into(bytes, 0)
	var decoded: CombatState = CombatState.decode_from(bytes, 0)
	if not assert_not_null(decoded, "decode_from de 76 bytes"):
		return
	assert_eq(decoded.action, original.action, "action")
	assert_eq(decoded.action_id, original.action_id, "action_id")
	assert_eq(decoded.action_tick, original.action_tick, "action_tick (u32 sin signo)")
	assert_eq(decoded.combo_step, original.combo_step, "combo_step")
	assert_eq(decoded.primary_held, original.primary_held, "primary_held")
	assert_eq(decoded.charge_ticks, original.charge_ticks, "charge_ticks")
	assert_eq(decoded.buffered, original.buffered, "buffered")
	assert_eq(decoded.stamina, original.stamina, "stamina")
	assert_eq(decoded.stamina_regen_tick, original.stamina_regen_tick, "stamina_regen_tick")
	assert_eq(decoded.combat_flags, original.combat_flags, "combat_flags")
	assert_eq(decoded.action_dir, original.action_dir, "action_dir")
	assert_eq(decoded.cc_until_tick, original.cc_until_tick, "cc_until_tick (u32 sin signo)")
	assert_eq(decoded.knockback, original.knockback, "knockback (exacto a cm/s)")
	assert_eq(decoded.parry_ready_tick, original.parry_ready_tick, "parry_ready_tick")
	assert_eq(decoded.weapon_id, original.weapon_id, "weapon_id")
	assert_true(decoded.equals(original), "equals() tras la ida y vuelta")


func test_encode_into_respects_the_offset() -> void:
	var bytes := PackedByteArray()
	bytes.resize(10 + COMBAT_SIZE + 3)
	bytes.fill(0xEE)
	_full_state().encode_into(bytes, 10)
	for i: int in 10:
		if bytes[i] != 0xEE:
			fail("encode_into no debe tocar el byte %d anterior al offset" % i)
			return
	for i: int in 3:
		if bytes[10 + COMBAT_SIZE + i] != 0xEE:
			fail("encode_into no debe tocar el byte %d posterior" % i)
			return
	var decoded: CombatState = CombatState.decode_from(bytes, 10)
	assert_true(decoded != null and decoded.equals(_full_state()), "decode_from con offset")


func test_decode_from_rejects_short_buffers() -> void:
	var bytes := PackedByteArray()
	bytes.resize(COMBAT_SIZE - 1)
	assert_null(CombatState.decode_from(bytes, 0), "75 bytes no bastan")
	bytes.resize(COMBAT_SIZE + 5)
	assert_not_null(CombatState.decode_from(bytes, 5), "justo caben 76 bytes desde el offset 5")
	assert_null(CombatState.decode_from(bytes, 6), "desde el offset 6 ya no caben")
	assert_null(CombatState.decode_from(bytes, -1), "offset negativo")


func test_knockback_is_rounded_to_centimeters_per_second() -> void:
	var c := CombatState.new()
	c.knockback = Vector2(1.2349, -0.0051)
	var bytes := PackedByteArray()
	bytes.resize(COMBAT_SIZE)
	c.encode_into(bytes, 0)
	var decoded: CombatState = CombatState.decode_from(bytes, 0)
	assert_eq(decoded.knockback, Vector2(1.23, -0.01), "se redondea a cm/s")
	assert_eq(CombatState.quantize_knockback(c.knockback), decoded.knockback,
			"quantize_knockback da lo mismo que pasar por la red")
	# Fuera de rango satura en lugar de dar la vuelta.
	c.knockback = Vector2(1000.0, -1000.0)
	c.encode_into(bytes, 0)
	decoded = CombatState.decode_from(bytes, 0)
	assert_eq(decoded.knockback, Vector2(327.67, -327.68), "satura a s16")
	c.knockback = Vector2(NAN, INF)
	c.encode_into(bytes, 0)
	assert_eq(CombatState.decode_from(bytes, 0).knockback, Vector2.ZERO, "NaN e infinito son 0")


func test_yaw_quantization_matches_look_yaw() -> void:
	assert_eq(CombatState.quantize_yaw(0.0), 0, "0")
	assert_eq(CombatState.quantize_yaw(PI), 32768, "PI es la mitad")
	assert_eq(CombatState.quantize_yaw(-PI / 2.0), 49152, "-PI/2 se envuelve a 3/4")
	assert_eq(CombatState.quantize_yaw(TAU), 0, "una vuelta completa vuelve a 0")
	assert_eq(CombatState.quantize_yaw(NAN), 0, "NaN es 0")
	for step: int in [0, 1, 12345, 32768, 65535]:
		assert_eq(CombatState.quantize_yaw(CombatState.dequantize_yaw(step)), step,
				"cuantizar(descuantizar(%d))" % step)
	# Es el mismo que usa PlayerInput para look_yaw.
	var input := PlayerInput.new()
	input.look_yaw = 2.5
	assert_near(CombatState.dequantize_yaw(CombatState.quantize_yaw(2.5)), input.quantized().look_yaw,
			1e-9, "misma cuantización que look_yaw")


func test_initial_state() -> void:
	var rules: CombatRules = CombatCatalog.rules()
	var weapon: int = CombatCatalog.default_weapon_id()
	var c: CombatState = CombatState.initial(rules, weapon)
	assert_eq(c.action, CombatState.Action.NONE, "sin acción")
	assert_eq(c.stamina, rules.stamina_max, "resistencia llena")
	assert_eq(c.weapon_id, weapon, "arma equipada")
	assert_true(weapon > 0, "el arma por defecto existe en el catálogo")
	assert_eq(c.combat_flags, 0, "sin banderas")
	assert_eq(c.buffered, 0, "búfer vacío")
	assert_false(c.is_exhausted(), "no está agotado")
	# Un PlayerState nuevo y un PlayerCharacter nuevo empiezan igual.
	assert_true(PlayerState.new().combat.equals(c), "PlayerState.new() lleva el combate inicial")


func test_duplicate_state_and_copy_from_are_independent() -> void:
	var original: CombatState = _full_state()
	var copy: CombatState = original.duplicate_state()
	assert_false(is_same(copy, original), "duplicate_state() devuelve otro objeto")
	assert_true(copy.equals(original), "con los mismos valores")
	copy.stamina = 1
	copy.knockback = Vector2.ZERO
	copy.action = CombatState.Action.NONE
	assert_eq(original.stamina, 987, "cambiar la copia no cambia el original")
	assert_eq(original.knockback, Vector2(-3.25, 12.5), "ni su empuje")
	var target := CombatState.new()
	target.copy_from(original)
	assert_true(target.equals(original), "copy_from copia todo")
	assert_false(original.equals(null), "null nunca es igual")


func test_equals_detects_every_field() -> void:
	var base: CombatState = _full_state()
	var changes: Dictionary[String, Callable] = {
		"action": func(c: CombatState) -> void: c.action = CombatState.Action.BLOCK,
		"action_id": func(c: CombatState) -> void: c.action_id += 1,
		"action_tick": func(c: CombatState) -> void: c.action_tick += 1,
		"combo_step": func(c: CombatState) -> void: c.combo_step = 1,
		"primary_held": func(c: CombatState) -> void: c.primary_held += 1,
		"charge_ticks": func(c: CombatState) -> void: c.charge_ticks += 1,
		"buffered": func(c: CombatState) -> void: c.buffered += 16,
		"stamina": func(c: CombatState) -> void: c.stamina += 1,
		"stamina_regen_tick": func(c: CombatState) -> void: c.stamina_regen_tick += 1,
		"combat_flags": func(c: CombatState) -> void: c.combat_flags ^= 1,
		"action_dir": func(c: CombatState) -> void: c.action_dir += 1,
		"cc_until_tick": func(c: CombatState) -> void: c.cc_until_tick -= 1,
		"knockback": func(c: CombatState) -> void: c.knockback.x += 0.01,
		"parry_ready_tick": func(c: CombatState) -> void: c.parry_ready_tick += 1,
		"weapon_id": func(c: CombatState) -> void: c.weapon_id += 1,
	}
	for field: String in changes:
		var other: CombatState = base.duplicate_state()
		changes[field].call(other)
		assert_false(base.equals(other), "equals() debe notar un cambio en %s" % field)
		var as_player_a := PlayerState.new()
		as_player_a.combat = base
		var as_player_b := PlayerState.new()
		as_player_b.combat = other
		assert_false(as_player_a.equals_exact(as_player_b),
				"PlayerState.equals_exact() debe notar un cambio en %s" % field)
		assert_false(as_player_a.is_close_to(as_player_b),
				"PlayerState.is_close_to() debe notar un cambio en %s" % field)


func test_player_state_roundtrip_keeps_the_combat() -> void:
	var state := PlayerState.new()
	state.position = Vector3(1.5, 2.0, -3.0)
	state.yaw = 1.25
	state.grounded = true
	state.prev_buttons = PlayerInput.PRIMARY | PlayerInput.BLOCK
	state.last_input_tick = 12345
	state.combat = _full_state()
	var decoded: PlayerState = PlayerState.decode(state.encode())
	if not assert_not_null(decoded, "decode() de 111 bytes"):
		return
	assert_true(decoded.combat.equals(state.combat), "el combate sobrevive")
	assert_true(decoded.equals_exact(state), "y el estado entero es igual byte a byte")
	assert_eq(decoded.last_input_tick, 12345, "last_input_tick sigue en su sitio")
	# duplicate_state copia el combate, no lo comparte.
	var copy: PlayerState = state.duplicate_state()
	assert_false(is_same(copy.combat, state.combat), "duplicate_state() copia el combate")
	copy.combat.stamina = 5
	assert_eq(state.combat.stamina, 987, "y modificarla no toca el original")
	assert_true(str(state).contains("CombatState"), "_to_string() incluye el combate")


func test_player_state_decode_rejects_old_size() -> void:
	var old := PackedByteArray()
	old.resize(35)
	assert_null(PlayerState.decode(old), "35 bytes (la versión 1) ya no son un estado")
	old.resize(69)
	assert_null(PlayerState.decode(old), "69 bytes (la fase 3) tampoco")
	old.resize(111)
	assert_not_null(PlayerState.decode(old), "111 bytes sí")
