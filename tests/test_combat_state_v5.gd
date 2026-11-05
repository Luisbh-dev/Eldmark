extends TestCase
## Tests for version 5 of [CombatState] (docs/abilities.md, section 3.1): 76 B inside a 111 B
## [PlayerState], each new field at its offset, round trip, the new format of
## [member CombatState.buffered] (bits 0-3 type, 4-7 ticks), the charges, the active slot, the array
## copy and that the reconciliation comparison notices each new field.

const Action = CombatState.Action


## A state with all the version 5 fields set to distinct, easy-to-recognize values.
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
	assert_eq(CombatState.ENCODED_SIZE, 76, "the v5 combat state takes 76 B")
	assert_eq(PlayerState.ENCODED_SIZE, 111, "the player state takes 111 B")
	assert_eq(PlayerState.ENCODED_SIZE, PlayerState.COMBAT_OFFSET + CombatState.ENCODED_SIZE,
			"35 + 76")
	assert_eq(PlayerState.new().encode().size(), 111, "encode() gives 111 B")
	assert_eq(CombatState.ABILITY_SLOTS, 3, "3 ability slots")
	assert_eq(CombatState.MOVE_EFFECT_SLOTS, 2, "2 movement effect slots")


func test_new_actions_keep_the_old_numbers() -> void:
	# The phase 3 numbers do not change and the new ones fit in the 4 bits of the action byte.
	assert_eq(Action.DEAD, 8, "DEAD is still 8")
	assert_eq(Action.ABILITY, 9, "ABILITY")
	assert_eq(Action.SWAP, 10, "SWAP")
	assert_eq(Action.DOWNED, 11, "DOWNED")
	assert_eq(Action.REVIVE, 12, "REVIVE")
	assert_eq(Action.EXECUTE, 13, "EXECUTE (14 and 15 free)")


func test_every_new_field_is_at_its_offset() -> void:
	# Offsets inside PlayerState (the table in docs/abilities.md, section 3.1).
	var state := PlayerState.new()
	state.combat = _full_state()
	var bytes: PackedByteArray = state.encode()
	if not assert_eq(bytes.size(), 111, "size"):
		return
	assert_eq(bytes.decode_u8(35), Action.ABILITY, "u8 action at 35")
	assert_eq(bytes.decode_u16(36), 0x0203, "u16 action_id at 36 (the ability)")
	assert_eq(bytes.decode_u16(67), 0x0102, "u16 weapon_id is still at 67")
	assert_eq(bytes.decode_u16(69), 0x0A0B, "u16 alt_weapon_id at 69")
	assert_eq(bytes.decode_u8(71), CombatState.FLAG2_SECOND_SLOT | CombatState.FLAG2_SWAP_HELD
			| CombatState.FLAG2_NO_COOLDOWNS, "u8 combat_flags2 at 71")
	for i: int in 3:
		assert_eq(bytes.decode_u32(72 + 4 * i), 0x10000000 + i * 0x01010101,
				"u32 ability_ready[%d] at %d" % [i, 72 + 4 * i])
	for i: int in range(3, 6):
		assert_eq(bytes.decode_u32(84 + 4 * (i - 3)), 0x10000000 + i * 0x01010101,
				"u32 ability_ready[%d] at %d" % [i, 84 + 4 * (i - 3)])
	assert_eq(bytes.decode_u32(96), 4000000001, "u32 consumable_ready_tick at 96")
	assert_eq(bytes.decode_u8(100), 3 | (12 << 4), "u8 consumable_charges at 100")
	assert_eq(bytes.decode_u8(101), 7, "u8 move_effect_ids[0] at 101")
	assert_eq(bytes.decode_u32(102), 123456, "u32 move_effect_until[0] at 102")
	assert_eq(bytes.decode_u8(106), 255, "u8 move_effect_ids[1] at 106")
	assert_eq(bytes.decode_u32(107), 0xFFFFFFFF, "u32 move_effect_until[1] at 107")


func test_roundtrip_of_the_new_fields() -> void:
	var original: CombatState = _full_state()
	var decoded: PlayerState = PlayerState.decode(_with_combat(original).encode())
	if not assert_not_null(decoded, "decode() of 111 B"):
		return
	var c: CombatState = decoded.combat
	assert_eq(c.alt_weapon_id, original.alt_weapon_id, "alt_weapon_id")
	assert_eq(c.combat_flags2, original.combat_flags2, "combat_flags2")
	assert_eq(c.ability_ready, original.ability_ready, "ability_ready (6 values)")
	assert_eq(c.consumable_ready_tick, original.consumable_ready_tick, "consumable_ready_tick (u32)")
	assert_eq(c.consumable_charges, original.consumable_charges, "consumable_charges")
	assert_eq(c.move_effect_ids, original.move_effect_ids, "move_effect_ids")
	assert_eq(c.move_effect_until, original.move_effect_until, "move_effect_until (u32)")
	assert_eq(c.buffered, original.buffered, "buffered")
	assert_true(c.equals(original), "equals() after the round trip")
	assert_true(decoded.equals_exact(_with_combat(original)), "and byte for byte")


func test_ticks_are_u32_on_the_wire() -> void:
	# Like cc_until_tick: absolute ticks travel in u32 (unsigned).
	var c := CombatState.new()
	c.ability_ready[5] = 0x1_0000_0005
	c.consumable_ready_tick = -1
	c.move_effect_until[1] = 0x1_0000_0009
	var bytes := PackedByteArray()
	bytes.resize(CombatState.ENCODED_SIZE)
	c.encode_into(bytes, 0)
	var decoded: CombatState = CombatState.decode_from(bytes, 0)
	assert_eq(decoded.ability_ready[5], 5, "it keeps the low 32 bits")
	assert_eq(decoded.consumable_ready_tick, 0xFFFFFFFF, "-1 is 0xFFFFFFFF")
	assert_eq(decoded.move_effect_until[1], 9, "and the effect's end too")


func test_the_new_buffered_layout() -> void:
	var c := CombatState.new()
	assert_eq(CombatState.BUFFER_TYPE_MASK, 15, "bits 0-3 type")
	assert_eq(CombatState.BUFFER_TICKS_SHIFT, 4, "bits 4-7 ticks")
	var kinds: Array[int] = [
		CombatState.BUFFER_NONE, CombatState.BUFFER_PRIMARY, CombatState.BUFFER_DODGE,
		CombatState.BUFFER_LINK, CombatState.BUFFER_ABILITY_1, CombatState.BUFFER_ABILITY_2,
		CombatState.BUFFER_ABILITY_3, CombatState.BUFFER_SWAP, CombatState.BUFFER_CONSUMABLE_1,
		CombatState.BUFFER_CONSUMABLE_2,
	]
	for i: int in kinds.size():
		assert_eq(kinds[i], i, "the types go from 0 to 9 in the order of section 3.1")
	for kind: int in kinds:
		for ticks: int in [0, 1, 8, 15]:
			c.buffered = CombatState.pack_buffer(kind, ticks)
			assert_eq(c.buffered_type(), kind, "type %d with %d ticks" % [kind, ticks])
			assert_eq(c.buffered_ticks(), ticks, "%d ticks of type %d" % [ticks, kind])
			assert_eq(c.buffered, kind | (ticks << 4), "packing of %d/%d" % [kind, ticks])
	c.buffered = CombatState.pack_buffer(CombatState.BUFFER_SWAP, 99)
	assert_eq(c.buffered_ticks(), 15, "the ticks are limited to 15")
	c.buffered = 0xFF
	assert_eq(c.buffered_type(), 15, "0xFF: type 15")
	assert_eq(c.buffered_ticks(), 15, "and 15 ticks")


func test_the_machine_buffer_keeps_working_with_the_new_layout() -> void:
	# A dodge pressed in the air waits in the buffer for input_buffer_ticks ticks (combat.md 3.3)
	# with the new format.
	var c: CombatState = CombatState.initial(CombatCatalog.rules(), CombatCatalog.default_weapon_id())
	var input := PlayerInput.new()
	input.tick = 100
	input.buttons = PlayerInput.DODGE
	ActionMachine.step(c, input, false)
	assert_eq(c.buffered_type(), CombatState.BUFFER_DODGE, "the dodge waits in the buffer")
	assert_eq(c.buffered_ticks(), CombatCatalog.rules().input_buffer_ticks, "with its 8 ticks")
	input.tick = 101
	ActionMachine.step(c, input, false)
	assert_eq(c.buffered_ticks(), CombatCatalog.rules().input_buffer_ticks - 1, "one less")
	input.tick = 102
	ActionMachine.step(c, input, true)
	assert_eq(c.action, Action.DODGE, "on touching the ground the dodge goes out")
	assert_eq(c.buffered, 0, "and the buffer empties")


func test_initial_state_takes_both_weapons_and_the_charges() -> void:
	var rules: CombatRules = CombatCatalog.rules()
	var sword: int = CombatCatalog.weapon_id(&"sword_shield")
	var bow: int = CombatCatalog.weapon_id(&"bow")
	var c: CombatState = CombatState.initial(rules, bow, sword, CombatState.pack_charges(2, 3))
	assert_eq(c.weapon_id, bow, "active weapon")
	assert_eq(c.alt_weapon_id, sword, "weapon in the other slot")
	assert_eq([c.charges_of(0), c.charges_of(1)], [2, 3], "charges")
	assert_false(c.is_second_slot(), "it appears with slot 1 active")
	assert_eq(c.stamina, rules.stamina_max, "full stamina")
	assert_eq(c.ability_ready, PackedInt64Array([0, 0, 0, 0, 0, 0]), "no cooldowns")
	assert_eq(c.consumable_ready_tick, 0, "no shared cooldown")
	assert_eq(c.move_effect_ids, PackedInt32Array([0, 0]), "free movement slots")
	assert_eq(c.combat_flags2, 0, "no flags")
	var plain: CombatState = CombatState.initial(rules, sword)
	assert_eq([plain.alt_weapon_id, plain.consumable_charges], [0, 0], "by default, no other weapon or charges")


func test_charges_and_slot_helpers() -> void:
	var c := CombatState.new()
	c.consumable_charges = CombatState.pack_charges(15, 0)
	assert_eq([c.charges_of(0), c.charges_of(1)], [15, 0], "potion 1 in bits 0-3")
	c.consumable_charges = CombatState.pack_charges(0, 15)
	assert_eq([c.charges_of(0), c.charges_of(1)], [0, 15], "potion 2 in bits 4-7")
	assert_eq(CombatState.pack_charges(20, -3), 15, "they are limited to 0..15")
	assert_eq(c.charges_of(2), 0, "a consumable that does not exist has no charges")
	assert_eq(c.charges_of(-1), 0, "nor does a negative one")
	assert_false(c.is_second_slot(), "slot 1")
	c.combat_flags2 = CombatState.FLAG2_SECOND_SLOT
	assert_true(c.is_second_slot(), "slot 2")
	assert_eq(CombatState.FLAG2_HELD_MASK, CombatState.FLAG2_ABILITY_1_HELD
			| CombatState.FLAG2_ABILITY_2_HELD | CombatState.FLAG2_ABILITY_3_HELD
			| CombatState.FLAG2_SWAP_HELD | CombatState.FLAG2_CONSUMABLE_1_HELD
			| CombatState.FLAG2_CONSUMABLE_2_HELD, "bits 1-6: buttons of the previous tick")
	assert_eq(CombatState.FLAG2_NO_COOLDOWNS, 1 << 7, "bit 7: no cooldowns")


func test_copy_from_copies_the_arrays_not_the_references() -> void:
	var original: CombatState = _full_state()
	var copy: CombatState = original.duplicate_state()
	assert_true(copy.equals(original), "equal copy")
	copy.ability_ready[0] = 1
	copy.move_effect_ids[1] = 3
	copy.move_effect_until[0] = 4
	assert_eq(original.ability_ready[0], 0x10000000, "changing the copy does not touch the original")
	assert_eq(original.move_effect_ids[1], 255, "nor its effects")
	assert_eq(original.move_effect_until[0], 123456, "nor their ends")
	var target := CombatState.new()
	target.copy_from(original)
	assert_true(target.equals(original), "copy_from copies everything")
	original.ability_ready[2] = 99
	assert_eq(target.ability_ready[2], 0x10000000 + 2 * 0x01010101, "and does not share the arrays")
	# Two new states do not share arrays (the Packed*Arrays are passed by reference).
	var a := CombatState.new()
	var b := CombatState.new()
	a.ability_ready[0] = 7
	a.move_effect_ids[0] = 7
	assert_eq(b.ability_ready[0], 0, "independent new states")
	assert_eq(b.move_effect_ids[0], 0, "the effects too")


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
		assert_false(base.equals(other), "equals() must notice a change in %s" % field)
		assert_false(_with_combat(base).equals_exact(_with_combat(other)),
				"PlayerState.equals_exact() must notice a change in %s" % field)
		assert_false(_with_combat(base).is_close_to(_with_combat(other)),
				"PlayerState.is_close_to() must notice a change in %s" % field)


func test_reset_for_respawn_takes_the_loadout_and_clears_the_timers() -> void:
	var c: CombatState = _full_state()
	c.action = Action.DEAD
	c.combat_flags = CombatState.FLAG_EXHAUSTED | CombatState.FLAG_BLOCK_HELD
	ActionMachine.reset_for_respawn(c, 5000, 0x0A0B, 0x0102, CombatState.pack_charges(2, 3))
	assert_eq(c.action, Action.NONE, "no action")
	assert_eq(c.action_tick, 5000, "from the respawn tick")
	assert_eq([c.weapon_id, c.alt_weapon_id], [0x0A0B, 0x0102], "both weapons in slot order")
	assert_false(c.is_second_slot(), "with the one in slot 1 active")
	assert_eq(c.combat_flags2 & CombatState.FLAG2_HELD_MASK, CombatState.FLAG2_SWAP_HELD,
			"keeps the held buttons")
	assert_eq(c.combat_flags2 & CombatState.FLAG2_NO_COOLDOWNS, 0, "but not the command")
	assert_eq(c.combat_flags, CombatState.FLAG_BLOCK_HELD, "nor the exhaustion")
	assert_eq(c.consumable_charges, CombatState.pack_charges(2, 3), "the template's charges")
	assert_eq(c.ability_ready, PackedInt64Array([0, 0, 0, 0, 0, 0]), "cooldowns at 0")
	assert_eq(c.consumable_ready_tick, 0, "the shared one too")
	assert_eq(c.move_effect_ids, PackedInt32Array([0, 0]), "free movement slots")
	assert_eq(c.buffered, 0, "empty buffer")
	assert_eq(c.stamina, CombatCatalog.rules().stamina_max, "full stamina")


func _with_combat(combat: CombatState) -> PlayerState:
	var state := PlayerState.new()
	state.combat = combat.duplicate_state()
	return state
