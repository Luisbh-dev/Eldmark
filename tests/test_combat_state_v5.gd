extends TestCase
## Pruebas de la versión 5 de [CombatState] (docs/habilidades.md, sección 3.1): 76 B dentro de un
## [PlayerState] de 111 B, cada campo nuevo en su offset, ida y vuelta, el nuevo formato de
## [member CombatState.buffered] (bits 0-3 tipo, 4-7 ticks), las cargas, la ranura activa, la copia
## de los arrays y que la comparación de la reconciliación nota cada campo nuevo.

const Action = CombatState.Action


## Un estado con todos los campos de la versión 5 a valores distintos y fáciles de reconocer.
func _full_state() -> CombatState:
	var c := CombatState.new()
	c.action = Action.ABILITY
	c.action_id = 0x0203
	c.action_tick = 0xCAFEBABE
	c.buffered = CombatState.pack_buffer(CombatState.BUFFER_CONSUMABLE_2, 7)
	c.stamina = 640
	c.weapon_id = 0x0102
	c.alt_weapon_id = 0x0A0B
	c.combat_flags2 = CombatState.FLAG2_SECOND_SLOT | CombatState.FLAG2_SWAP_HELD \
			| CombatState.FLAG2_NO_COOLDOWNS
	for i: int in CombatState.ABILITY_SLOTS * 2:
		c.ability_ready[i] = 0x10000000 + i * 0x01010101
	c.consumable_ready_tick = 4000000001
	c.consumable_charges = CombatState.pack_charges(3, 12)
	c.move_effect_ids[0] = 7
	c.move_effect_until[0] = 123456
	c.move_effect_ids[1] = 255
	c.move_effect_until[1] = 0xFFFFFFFF
	return c


func test_sizes() -> void:
	assert_eq(CombatState.ENCODED_SIZE, 76, "el estado de combate v5 ocupa 76 B")
	assert_eq(PlayerState.ENCODED_SIZE, 111, "el estado de jugador ocupa 111 B")
	assert_eq(PlayerState.ENCODED_SIZE, PlayerState.COMBAT_OFFSET + CombatState.ENCODED_SIZE,
			"35 + 76")
	assert_eq(PlayerState.new().encode().size(), 111, "encode() da 111 B")
	assert_eq(CombatState.ABILITY_SLOTS, 3, "3 ranuras de habilidad")
	assert_eq(CombatState.MOVE_EFFECT_SLOTS, 2, "2 ranuras de efectos de movimiento")


func test_new_actions_keep_the_old_numbers() -> void:
	# Los números de la fase 3 no cambian y los nuevos caben en los 4 bits del byte de acción.
	assert_eq(Action.DEAD, 8, "DEAD sigue siendo 8")
	assert_eq(Action.ABILITY, 9, "ABILITY")
	assert_eq(Action.SWAP, 10, "SWAP")
	assert_eq(Action.DOWNED, 11, "DOWNED")
	assert_eq(Action.REVIVE, 12, "REVIVE")
	assert_eq(Action.EXECUTE, 13, "EXECUTE (14 y 15 libres)")


func test_every_new_field_is_at_its_offset() -> void:
	# Offsets dentro de PlayerState (la tabla de docs/habilidades.md, sección 3.1).
	var state := PlayerState.new()
	state.combat = _full_state()
	var bytes: PackedByteArray = state.encode()
	if not assert_eq(bytes.size(), 111, "tamaño"):
		return
	assert_eq(bytes.decode_u8(35), Action.ABILITY, "u8 action en 35")
	assert_eq(bytes.decode_u16(36), 0x0203, "u16 action_id en 36 (la habilidad)")
	assert_eq(bytes.decode_u16(67), 0x0102, "u16 weapon_id sigue en 67")
	assert_eq(bytes.decode_u16(69), 0x0A0B, "u16 alt_weapon_id en 69")
	assert_eq(bytes.decode_u8(71), CombatState.FLAG2_SECOND_SLOT | CombatState.FLAG2_SWAP_HELD
			| CombatState.FLAG2_NO_COOLDOWNS, "u8 combat_flags2 en 71")
	for i: int in 3:
		assert_eq(bytes.decode_u32(72 + 4 * i), 0x10000000 + i * 0x01010101,
				"u32 ability_ready[%d] en %d" % [i, 72 + 4 * i])
	for i: int in range(3, 6):
		assert_eq(bytes.decode_u32(84 + 4 * (i - 3)), 0x10000000 + i * 0x01010101,
				"u32 ability_ready[%d] en %d" % [i, 84 + 4 * (i - 3)])
	assert_eq(bytes.decode_u32(96), 4000000001, "u32 consumable_ready_tick en 96")
	assert_eq(bytes.decode_u8(100), 3 | (12 << 4), "u8 consumable_charges en 100")
	assert_eq(bytes.decode_u8(101), 7, "u8 move_effect_ids[0] en 101")
	assert_eq(bytes.decode_u32(102), 123456, "u32 move_effect_until[0] en 102")
	assert_eq(bytes.decode_u8(106), 255, "u8 move_effect_ids[1] en 106")
	assert_eq(bytes.decode_u32(107), 0xFFFFFFFF, "u32 move_effect_until[1] en 107")


func test_roundtrip_of_the_new_fields() -> void:
	var original: CombatState = _full_state()
	var decoded: PlayerState = PlayerState.decode(_with_combat(original).encode())
	if not assert_not_null(decoded, "decode() de 111 B"):
		return
	var c: CombatState = decoded.combat
	assert_eq(c.alt_weapon_id, original.alt_weapon_id, "alt_weapon_id")
	assert_eq(c.combat_flags2, original.combat_flags2, "combat_flags2")
	assert_eq(c.ability_ready, original.ability_ready, "ability_ready (6 valores)")
	assert_eq(c.consumable_ready_tick, original.consumable_ready_tick, "consumable_ready_tick (u32)")
	assert_eq(c.consumable_charges, original.consumable_charges, "consumable_charges")
	assert_eq(c.move_effect_ids, original.move_effect_ids, "move_effect_ids")
	assert_eq(c.move_effect_until, original.move_effect_until, "move_effect_until (u32)")
	assert_eq(c.buffered, original.buffered, "buffered")
	assert_true(c.equals(original), "equals() tras la ida y vuelta")
	assert_true(decoded.equals_exact(_with_combat(original)), "y byte a byte")


func test_ticks_are_u32_on_the_wire() -> void:
	# Como cc_until_tick: los ticks absolutos viajan en u32 (sin signo).
	var c := CombatState.new()
	c.ability_ready[5] = 0x1_0000_0005
	c.consumable_ready_tick = -1
	c.move_effect_until[1] = 0x1_0000_0009
	var bytes := PackedByteArray()
	bytes.resize(CombatState.ENCODED_SIZE)
	c.encode_into(bytes, 0)
	var decoded: CombatState = CombatState.decode_from(bytes, 0)
	assert_eq(decoded.ability_ready[5], 5, "se queda con los 32 bits bajos")
	assert_eq(decoded.consumable_ready_tick, 0xFFFFFFFF, "-1 es 0xFFFFFFFF")
	assert_eq(decoded.move_effect_until[1], 9, "y el fin del efecto también")


func test_the_new_buffered_layout() -> void:
	var c := CombatState.new()
	assert_eq(CombatState.BUFFER_TYPE_MASK, 15, "bits 0-3 tipo")
	assert_eq(CombatState.BUFFER_TICKS_SHIFT, 4, "bits 4-7 ticks")
	var kinds: Array[int] = [
		CombatState.BUFFER_NONE, CombatState.BUFFER_PRIMARY, CombatState.BUFFER_DODGE,
		CombatState.BUFFER_LINK, CombatState.BUFFER_ABILITY_1, CombatState.BUFFER_ABILITY_2,
		CombatState.BUFFER_ABILITY_3, CombatState.BUFFER_SWAP, CombatState.BUFFER_CONSUMABLE_1,
		CombatState.BUFFER_CONSUMABLE_2,
	]
	for i: int in kinds.size():
		assert_eq(kinds[i], i, "los tipos van de 0 a 9 en el orden de la sección 3.1")
	for kind: int in kinds:
		for ticks: int in [0, 1, 8, 15]:
			c.buffered = CombatState.pack_buffer(kind, ticks)
			assert_eq(c.buffered_type(), kind, "tipo %d con %d ticks" % [kind, ticks])
			assert_eq(c.buffered_ticks(), ticks, "%d ticks del tipo %d" % [ticks, kind])
			assert_eq(c.buffered, kind | (ticks << 4), "empaquetado de %d/%d" % [kind, ticks])
	c.buffered = CombatState.pack_buffer(CombatState.BUFFER_SWAP, 99)
	assert_eq(c.buffered_ticks(), 15, "los ticks se limitan a 15")
	c.buffered = 0xFF
	assert_eq(c.buffered_type(), 15, "0xFF: tipo 15")
	assert_eq(c.buffered_ticks(), 15, "y 15 ticks")


func test_the_machine_buffer_keeps_working_with_the_new_layout() -> void:
	# Una esquiva pulsada en el aire espera en el búfer input_buffer_ticks ticks (combate.md 3.3)
	# con el nuevo formato.
	var c: CombatState = CombatState.initial(CombatCatalog.rules(), CombatCatalog.default_weapon_id())
	var input := PlayerInput.new()
	input.tick = 100
	input.buttons = PlayerInput.DODGE
	ActionMachine.step(c, input, false)
	assert_eq(c.buffered_type(), CombatState.BUFFER_DODGE, "la esquiva espera en el búfer")
	assert_eq(c.buffered_ticks(), CombatCatalog.rules().input_buffer_ticks, "con sus 8 ticks")
	input.tick = 101
	ActionMachine.step(c, input, false)
	assert_eq(c.buffered_ticks(), CombatCatalog.rules().input_buffer_ticks - 1, "uno menos")
	input.tick = 102
	ActionMachine.step(c, input, true)
	assert_eq(c.action, Action.DODGE, "al tocar el suelo sale la esquiva")
	assert_eq(c.buffered, 0, "y el búfer se vacía")


func test_initial_state_takes_both_weapons_and_the_charges() -> void:
	var rules: CombatRules = CombatCatalog.rules()
	var sword: int = CombatCatalog.weapon_id(&"sword_shield")
	var bow: int = CombatCatalog.weapon_id(&"bow")
	var c: CombatState = CombatState.initial(rules, bow, sword, CombatState.pack_charges(2, 3))
	assert_eq(c.weapon_id, bow, "arma activa")
	assert_eq(c.alt_weapon_id, sword, "arma de la otra ranura")
	assert_eq([c.charges_of(0), c.charges_of(1)], [2, 3], "cargas")
	assert_false(c.is_second_slot(), "aparece con la ranura 1 activa")
	assert_eq(c.stamina, rules.stamina_max, "resistencia llena")
	assert_eq(c.ability_ready, PackedInt64Array([0, 0, 0, 0, 0, 0]), "sin reutilizaciones")
	assert_eq(c.consumable_ready_tick, 0, "sin reutilización compartida")
	assert_eq(c.move_effect_ids, PackedInt32Array([0, 0]), "ranuras de movimiento libres")
	assert_eq(c.combat_flags2, 0, "sin banderas")
	var plain: CombatState = CombatState.initial(rules, sword)
	assert_eq([plain.alt_weapon_id, plain.consumable_charges], [0, 0], "por defecto, sin otra arma ni cargas")


func test_charges_and_slot_helpers() -> void:
	var c := CombatState.new()
	c.consumable_charges = CombatState.pack_charges(15, 0)
	assert_eq([c.charges_of(0), c.charges_of(1)], [15, 0], "poción 1 en los bits 0-3")
	c.consumable_charges = CombatState.pack_charges(0, 15)
	assert_eq([c.charges_of(0), c.charges_of(1)], [0, 15], "poción 2 en los bits 4-7")
	assert_eq(CombatState.pack_charges(20, -3), 15, "se limitan a 0..15")
	assert_eq(c.charges_of(2), 0, "un consumible que no existe no tiene cargas")
	assert_eq(c.charges_of(-1), 0, "ni uno negativo")
	assert_false(c.is_second_slot(), "ranura 1")
	c.combat_flags2 = CombatState.FLAG2_SECOND_SLOT
	assert_true(c.is_second_slot(), "ranura 2")
	assert_eq(CombatState.FLAG2_HELD_MASK, CombatState.FLAG2_ABILITY_1_HELD
			| CombatState.FLAG2_ABILITY_2_HELD | CombatState.FLAG2_ABILITY_3_HELD
			| CombatState.FLAG2_SWAP_HELD | CombatState.FLAG2_CONSUMABLE_1_HELD
			| CombatState.FLAG2_CONSUMABLE_2_HELD, "bits 1-6: botones del tick anterior")
	assert_eq(CombatState.FLAG2_NO_COOLDOWNS, 1 << 7, "bit 7: sin reutilizaciones")


func test_copy_from_copies_the_arrays_not_the_references() -> void:
	var original: CombatState = _full_state()
	var copy: CombatState = original.duplicate_state()
	assert_true(copy.equals(original), "copia igual")
	copy.ability_ready[0] = 1
	copy.move_effect_ids[1] = 3
	copy.move_effect_until[0] = 4
	assert_eq(original.ability_ready[0], 0x10000000, "cambiar la copia no toca el original")
	assert_eq(original.move_effect_ids[1], 255, "ni sus efectos")
	assert_eq(original.move_effect_until[0], 123456, "ni sus fines")
	var target := CombatState.new()
	target.copy_from(original)
	assert_true(target.equals(original), "copy_from copia todo")
	original.ability_ready[2] = 99
	assert_eq(target.ability_ready[2], 0x10000000 + 2 * 0x01010101, "y no comparte los arrays")
	# Dos estados nuevos no comparten arrays (los Packed*Array se pasan por referencia).
	var a := CombatState.new()
	var b := CombatState.new()
	a.ability_ready[0] = 7
	a.move_effect_ids[0] = 7
	assert_eq(b.ability_ready[0], 0, "estados nuevos independientes")
	assert_eq(b.move_effect_ids[0], 0, "también los efectos")


func test_equals_detects_every_new_field() -> void:
	var base: CombatState = _full_state()
	var changes: Dictionary[String, Callable] = {
		"alt_weapon_id": func(c: CombatState) -> void: c.alt_weapon_id += 1,
		"combat_flags2": func(c: CombatState) -> void: c.combat_flags2 ^= CombatState.FLAG2_ABILITY_1_HELD,
		"ability_ready[0]": func(c: CombatState) -> void: c.ability_ready[0] += 1,
		"ability_ready[5]": func(c: CombatState) -> void: c.ability_ready[5] += 1,
		"consumable_ready_tick": func(c: CombatState) -> void: c.consumable_ready_tick -= 1,
		"consumable_charges": func(c: CombatState) -> void: c.consumable_charges ^= 0x10,
		"move_effect_ids[0]": func(c: CombatState) -> void: c.move_effect_ids[0] = 1,
		"move_effect_until[1]": func(c: CombatState) -> void: c.move_effect_until[1] = 2,
		"buffered (ticks)": func(c: CombatState) -> void: c.buffered += 16,
	}
	for field: String in changes:
		var other: CombatState = base.duplicate_state()
		changes[field].call(other)
		assert_false(base.equals(other), "equals() debe notar un cambio en %s" % field)
		assert_false(_with_combat(base).equals_exact(_with_combat(other)),
				"PlayerState.equals_exact() debe notar un cambio en %s" % field)
		assert_false(_with_combat(base).is_close_to(_with_combat(other)),
				"PlayerState.is_close_to() debe notar un cambio en %s" % field)


func test_reset_for_respawn_takes_the_loadout_and_clears_the_timers() -> void:
	var c: CombatState = _full_state()
	c.action = Action.DEAD
	c.combat_flags = CombatState.FLAG_EXHAUSTED | CombatState.FLAG_BLOCK_HELD
	ActionMachine.reset_for_respawn(c, 5000, 0x0A0B, 0x0102, CombatState.pack_charges(2, 3))
	assert_eq(c.action, Action.NONE, "sin acción")
	assert_eq(c.action_tick, 5000, "desde el tick de la reaparición")
	assert_eq([c.weapon_id, c.alt_weapon_id], [0x0A0B, 0x0102], "las dos armas en orden de ranura")
	assert_false(c.is_second_slot(), "con la de la ranura 1 activa")
	assert_eq(c.combat_flags2 & CombatState.FLAG2_HELD_MASK, CombatState.FLAG2_SWAP_HELD,
			"conserva los botones mantenidos")
	assert_eq(c.combat_flags2 & CombatState.FLAG2_NO_COOLDOWNS, 0, "pero no el comando")
	assert_eq(c.combat_flags, CombatState.FLAG_BLOCK_HELD, "ni el agotamiento")
	assert_eq(c.consumable_charges, CombatState.pack_charges(2, 3), "las cargas de la plantilla")
	assert_eq(c.ability_ready, PackedInt64Array([0, 0, 0, 0, 0, 0]), "reutilizaciones a 0")
	assert_eq(c.consumable_ready_tick, 0, "también la compartida")
	assert_eq(c.move_effect_ids, PackedInt32Array([0, 0]), "ranuras de movimiento libres")
	assert_eq(c.buffered, 0, "búfer vacío")
	assert_eq(c.stamina, CombatCatalog.rules().stamina_max, "resistencia llena")


func _with_combat(combat: CombatState) -> PlayerState:
	var state := PlayerState.new()
	state.combat = combat.duplicate_state()
	return state
