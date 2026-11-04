extends TestCase
## [method ActionMachine.set_weapons] (docs/progression.md §4.1 and §8): sets the weapons of the two equipment
## slots without resetting anything else. It keeps charges, [member CombatState.consumable_ready_tick], movement
## slots and buttons; distributes [member CombatState.ability_ready] per weapon (the active one's three first);
## with an action in progress it does nothing. With the real machine: unequipping and re-equipping a weapon with
## its cooldowns stored does not reset them, and the next SWAP works from what it leaves.

const Action = CombatState.Action
const SWAP: int = PlayerInput.SWAP_WEAPON
const ABILITY_1: int = PlayerInput.ABILITY_1
## Stored cooldowns of each weapon (absolute ticks).
var _ready_1: PackedInt64Array = PackedInt64Array([1100, 1200, 1300])
var _ready_2: PackedInt64Array = PackedInt64Array([2100, 2200, 2300])


## The two slots with slot 1 active: weapons, per-weapon cooldowns and bit0 at 0; nothing else changes.
func test_sets_both_slots_without_touching_the_rest() -> void:
	var c: CombatState = _busy_state()
	c.combat_flags2 |= CombatState.FLAG2_SECOND_SLOT
	var expected: CombatState = c.duplicate_state()
	expected.weapon_id = _bow()
	expected.alt_weapon_id = _sword()
	expected.ability_ready = PackedInt64Array([1100, 1200, 1300, 2100, 2200, 2300])
	expected.combat_flags2 &= ~CombatState.FLAG2_SECOND_SLOT
	ActionMachine.set_weapons(c, _bow(), _sword(), false, _ready_1, _ready_2)
	assert_true(c.equals(expected), "only the weapons, the cooldowns and bit0 change: %s" % c)
	assert_eq(c.consumable_charges, CombatState.pack_charges(4, 1), "the charges, untouched")
	assert_eq(c.consumable_ready_tick, 5555, "the consumables' shared cooldown, untouched")
	assert_eq(Array(c.move_effect_ids), [3, 0], "the movement slots, untouched")
	assert_eq(Array(c.move_effect_until), [4321, 0], "with its end")
	assert_eq(c.combat_flags & CombatState.FLAG_BLOCK_HELD, CombatState.FLAG_BLOCK_HELD, "the previous tick's buttons")
	assert_eq(c.combat_flags2 & CombatState.FLAG2_HELD_MASK, CombatState.FLAG2_SWAP_HELD | CombatState.FLAG2_ABILITY_2_HELD,
			"also those of combat_flags2")
	assert_false(c.is_second_slot(), "slot 1 active")


## With slot 2 active, slot 2's weapon goes to weapon_id and its cooldowns first.
func test_second_slot_active_puts_its_weapon_and_cooldowns_first() -> void:
	var c: CombatState = _busy_state()
	var expected: CombatState = c.duplicate_state()
	expected.weapon_id = _bow()
	expected.alt_weapon_id = _sword()
	expected.ability_ready = PackedInt64Array([2100, 2200, 2300, 1100, 1200, 1300])
	expected.combat_flags2 |= CombatState.FLAG2_SECOND_SLOT
	ActionMachine.set_weapons(c, _sword(), _bow(), true, _ready_1, _ready_2)
	assert_true(c.equals(expected), "slot 2 active: %s" % c)
	assert_true(c.is_second_slot(), "bit0 of combat_flags2")
	assert_eq(c.consumable_ready_tick, 5555, "without touching the consumables")


## With slot 1 empty and slot 2 active, slot 2 in hand and nothing in the other (there is no SWAP).
func test_empty_first_slot_with_the_second_active() -> void:
	var c: CombatState = _busy_state()
	ActionMachine.set_weapons(c, 0, _bow(), true, PackedInt64Array(), _ready_2)
	assert_eq([c.weapon_id, c.alt_weapon_id], [_bow(), 0], "the bow in hand, nothing in the other")
	assert_eq(c.ability_ready, PackedInt64Array([2100, 2200, 2300, 0, 0, 0]), "the other half, at 0")
	assert_true(c.is_second_slot(), "slot 2 active")
	var d := MachineDriver.new(_sword())
	d.c.copy_from(c)
	d.c.action = Action.NONE
	d.step(SWAP)
	assert_eq(d.c.action, Action.NONE, "with no weapon in the other slot, the SWAP is discarded")
	assert_eq(d.c.weapon_id, _bow(), "and the bow remains")


## Empty or short ready lists are 0; surplus ones are not looked at.
func test_missing_ready_values_are_zero() -> void:
	var c: CombatState = _busy_state()
	ActionMachine.set_weapons(c, _sword(), _bow(), false, PackedInt64Array([7]), PackedInt64Array())
	assert_eq(c.ability_ready, PackedInt64Array([7, 0, 0, 0, 0, 0]), "empty = 0")
	ActionMachine.set_weapons(c, _sword(), _bow(), false, PackedInt64Array([1, 2, 3, 4]),
			PackedInt64Array([5, 6, 7, 8]))
	assert_eq(c.ability_ready, PackedInt64Array([1, 2, 3, 5, 6, 7]), "three per weapon")
	ActionMachine.set_weapons(c, _sword(), 0, false, _ready_1, PackedInt64Array())
	assert_eq([c.weapon_id, c.alt_weapon_id], [_sword(), 0], "a single weapon")
	assert_eq(c.ability_ready, PackedInt64Array([1100, 1200, 1300, 0, 0, 0]), "and its half")


## With an action in progress (drinking, swapping, blocking, hitting, dead) nothing changes and it is logged.
func test_does_nothing_during_an_action() -> void:
	allow_logged_errors()
	for action: int in [Action.ABILITY, Action.SWAP, Action.BLOCK, Action.LIGHT, Action.DEAD, Action.DOWNED]:
		var c: CombatState = _busy_state()
		c.action = action
		c.action_tick = 4000
		var before: CombatState = c.duplicate_state()
		ActionMachine.set_weapons(c, _bow(), 0, false, _ready_2, _ready_1)
		assert_true(c.equals(before), "with action %d nothing changes" % action)


## Unequipping the sword (not active) and putting it back with its cooldowns stored does not reset them: on
## returning to it with SWAP, the shield bash is still on cooldown with the same tick.
func test_unequip_and_equip_keep_each_weapons_cooldowns() -> void:
	var d := MachineDriver.new(_sword(), _bow(), CombatState.pack_charges(3, 2))
	d.step(ABILITY_1)
	d.hold(0, 60)
	var bash_ready: int = d.c.ability_ready[0]
	assert_true(bash_ready > d.tick, "shield bash on cooldown")
	d.step(SWAP)
	d.hold(0, 30)
	assert_eq(d.c.action, Action.NONE, "with the bow and no action")
	assert_eq(d.c.ability_ready[3], bash_ready, "the shield's, in the other half")
	# What PlayerProgress.stash_ready would do when removing the sword from WEAPON_1.
	var stashed_sword: PackedInt64Array = d.c.ability_ready.slice(3, 6)
	var bow_ready: PackedInt64Array = d.c.ability_ready.slice(0, 3)
	ActionMachine.set_weapons(d.c, 0, _bow(), true, PackedInt64Array(), bow_ready)
	assert_eq([d.c.weapon_id, d.c.alt_weapon_id], [_bow(), 0], "without the sword")
	assert_eq(d.c.ability_ready.slice(3, 6), PackedInt64Array([0, 0, 0]), "its half, empty")
	d.hold(0, 5)
	ActionMachine.set_weapons(d.c, _sword(), _bow(), true, stashed_sword, bow_ready)
	assert_eq(d.c.ability_ready[3], bash_ready, "comes back with the stored cooldown")
	d.step(SWAP)
	assert_eq([d.c.weapon_id, d.c.alt_weapon_id], [_sword(), _bow()], "the SWAP goes back to the sword")
	assert_false(d.c.is_second_slot(), "slot 1")
	assert_eq(d.c.ability_ready[0], bash_ready, "with its cooldown intact")
	d.hold(0, 30)
	assert_eq(ActionMachine.ability_status(d.c, 0, d.tick + 1), ActionMachine.AbilityStatus.COOLDOWN,
			"the shield bash is still on cooldown")
	d.step(ABILITY_1)
	assert_ne_action(d, Action.ABILITY, "and cannot be used before its tick")


## A state with everything set_weapons must not touch: charges, shared cooldown, movement
## slots, previous tick's buttons, stamina and combo.
func _busy_state() -> CombatState:
	var c := CombatState.initial(CombatCatalog.rules(), _sword(), _bow(), CombatState.pack_charges(4, 1))
	c.consumable_ready_tick = 5555
	c.move_effect_ids[0] = 3
	c.move_effect_until[0] = 4321
	c.combat_flags = CombatState.FLAG_BLOCK_HELD
	c.combat_flags2 = CombatState.FLAG2_SWAP_HELD | CombatState.FLAG2_ABILITY_2_HELD
	c.stamina = 321
	c.stamina_regen_tick = 999
	c.parry_ready_tick = 777
	c.ability_ready = PackedInt64Array([9, 8, 7, 6, 5, 4])
	return c


func assert_ne_action(d: MachineDriver, action: int, message: String) -> void:
	assert_true(d.c.action != action, message)


func _sword() -> int:
	return CombatCatalog.weapon_id(&"sword_shield")


func _bow() -> int:
	return CombatCatalog.weapon_id(&"bow")
