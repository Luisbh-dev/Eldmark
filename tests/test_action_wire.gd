extends TestCase
## Tests of the action byte of the network record ([ActionWire]): it is that of
## [method ActionMachine.action_byte] except for the dodge, stagger, stun and weapon
## swap, which carry a rearm counter in bits 6-7 so a remote can tell two identical consecutive
## actions apart. An ability carries its slot there (3 = a consumable) and its phase in bits 4-5
## (docs/abilities.md, section 5.5): two uses with the same byte always leave
## [constant AbilityTicks.REARM_TICKS] ticks of NONE in between, also after an interruption or after a
## wall released before the commit.

const START_TICK: int = 1000

var _rules: CombatRules


func before_each() -> void:
	_rules = CombatCatalog.rules()


func _state() -> CombatState:
	return CombatState.initial(_rules, CombatCatalog.default_weapon_id())


func test_without_an_action_the_byte_is_the_plain_one() -> void:
	var wire := ActionWire.new()
	var state: CombatState = _state()
	assert_eq(wire.encode(state, START_TICK), 0x30, "with no action it is 0x30, as always")
	assert_eq(ActionWire.step_of(0x30), 0)


func test_actions_other_than_dodge_and_controls_keep_the_plain_byte() -> void:
	var wire := ActionWire.new()
	var state: CombatState = _state()
	var weapon: WeaponTicks = CombatCatalog.weapon(state.weapon_id)
	for light_index: int in 3:
		state.action = CombatState.Action.LIGHT
		state.action_id = weapon.light_ids[light_index]
		state.action_tick = START_TICK + light_index * 7
		var byte: int = wire.encode(state, START_TICK + light_index * 7 + 3)
		assert_eq(byte, ActionMachine.action_byte(state, START_TICK + light_index * 7 + 3),
				"light attack %d carries its combo step" % light_index)
		assert_eq(ActionWire.step_of(byte), light_index)
	for action: int in [CombatState.Action.HEAVY, CombatState.Action.CHARGE, CombatState.Action.BLOCK,
			CombatState.Action.DEAD]:
		state.action = action
		state.action_id = weapon.heavy_id if action == CombatState.Action.HEAVY else 0
		state.action_tick += 11
		var plain: int = ActionMachine.action_byte(state, state.action_tick + 2)
		assert_eq(wire.encode(state, state.action_tick + 2), plain, "action %d unchanged" % action)
		assert_eq(ActionWire.step_of(plain), 0)


func test_each_new_dodge_or_control_bumps_the_counter_and_staying_in_it_does_not() -> void:
	var wire := ActionWire.new()
	var state: CombatState = _state()
	state.action = CombatState.Action.DODGE
	state.action_tick = START_TICK
	var first: int = wire.encode(state, START_TICK)
	assert_eq(first & 0x3F, ActionMachine.action_byte(state, START_TICK) & 0x3F,
			"the action and the phase do not change")
	for rel: int in range(1, 27):
		assert_eq(ActionWire.step_of(wire.encode(state, START_TICK + rel)), ActionWire.step_of(first),
				"while the dodge lasts (+%d) the counter is the same" % rel)
	# Another chained dodge, on the tick the first one ends.
	state.action_tick = START_TICK + 27
	var second: int = wire.encode(state, START_TICK + 27)
	assert_true(ActionWire.step_of(second) != ActionWire.step_of(first), "another dodge, another counter")
	assert_eq(second & 0x3F, first & 0x3F, "with the same action and phase byte")
	# A stagger, and another whose start is a multiple of 4 ticks apart (the start tick modulo 4 would
	# not be enough to tell them apart).
	var seen: Array[int] = []
	for i: int in 6:
		ActionMachine.impose_stagger(state, START_TICK + 100 + i * 4, START_TICK + 140, Vector2.ZERO)
		seen.append(ActionWire.step_of(wire.encode(state, START_TICK + 100 + i * 4)))
		if i > 0:
			assert_true(seen[i] != seen[i - 1], "stagger %d: counter different from the previous one" % i)
	ActionMachine.impose_stun(state, START_TICK + 130, START_TICK + 170)
	var stun: int = wire.encode(state, START_TICK + 130)
	assert_eq(stun & 15, CombatState.Action.STUN)
	assert_true(ActionWire.step_of(stun) != seen[5], "and the stun after them")
	assert_true(wire.encode(state, START_TICK + 131) == stun, "but it stays the same while it lasts")


func test_the_counter_wraps_and_fits_in_two_bits() -> void:
	var wire := ActionWire.new()
	var state: CombatState = _state()
	for i: int in 9:
		state.action = CombatState.Action.DODGE
		state.action_tick = START_TICK + i * 30
		var byte: int = wire.encode(state, state.action_tick)
		assert_true(byte >= 0 and byte <= 255, "fits in a byte")
		assert_eq(ActionWire.step_of(byte), (i + 1) & 3, "goes up one at a time modulo 4")


func test_an_ability_carries_its_slot_and_phase() -> void:
	var wire := ActionWire.new()
	var sword: int = CombatCatalog.weapon_id(&"sword_shield")
	for slot: int in 3:
		var d := MachineDriver.new(sword)
		d.step(PlayerInput.ABILITY_1 << slot)
		var ability: AbilityTicks = CombatCatalog.ability(d.c.action_id)
		assert_eq(ability.slot, slot, "the ability of slot %d" % (slot + 1))
		var start: int = d.tick
		var phases: Dictionary[int, bool] = {}
		for rel: int in ability.total_ticks if not ability.channel else ability.cast_ticks + 20:
			var tick: int = start + rel
			var byte: int = wire.encode(d.c, tick)
			assert_eq(byte & 15, CombatState.Action.ABILITY, "slot %d: ABILITY" % slot)
			assert_eq(ActionWire.step_of(byte), slot, "slot %d in bits 6-7" % slot)
			var phase: int = (byte >> 4) & 3
			assert_eq(phase, AbilityRules.phase_of(ability, rel), "slot %d, rel %d: phase" % [slot, rel])
			phases[phase] = true
			d.step(PlayerInput.ABILITY_1 << slot)
		assert_true(phases.has(0) and phases.has(1), "slot %d: cast and active" % slot)
		assert_eq(phases.has(2), not ability.channel, "slot %d: recovery if not channeled" % slot)
	# A consumable: slot 3.
	var potion := MachineDriver.new(sword, 0, CombatState.pack_charges(1, 1))
	potion.step(PlayerInput.CONSUMABLE_2)
	var drink: int = wire.encode(potion.c, potion.tick)
	assert_eq(drink & 15, CombatState.Action.ABILITY, "drinking is ABILITY")
	assert_eq(ActionWire.step_of(drink), 3, "with slot 3")
	assert_eq((drink >> 4) & 3, 0, "in its phase 0")
	assert_false(ActionWire.has_counter(CombatState.Action.ABILITY), "no counter")


func test_swap_carries_a_counter_and_downed_revive_execute_do_not() -> void:
	assert_true(ActionWire.has_counter(CombatState.Action.SWAP), "the weapon swap carries a counter")
	var wire := ActionWire.new()
	var state: CombatState = _state()
	state.action = CombatState.Action.SWAP
	state.action_tick = START_TICK
	var first: int = wire.encode(state, START_TICK)
	assert_eq(first & 0x3F, CombatState.Action.SWAP | (3 << 4), "SWAP without phases")
	assert_eq(wire.encode(state, START_TICK + 10), first, "same while it lasts")
	state.action_tick = START_TICK + 24
	var second: int = wire.encode(state, START_TICK + 24)
	assert_true(ActionWire.step_of(second) != ActionWire.step_of(first),
			"another chained swap from the buffer: another counter")
	for action: int in [CombatState.Action.DOWNED, CombatState.Action.REVIVE, CombatState.Action.EXECUTE]:
		assert_false(ActionWire.has_counter(action), "%d without a counter" % action)
		state.action = action
		state.action_tick = START_TICK + 100 + action
		assert_eq(wire.encode(state, START_TICK + 200), action | (3 << 4), "%d: phase 3 and bits 6-7 at 0" % action)
	# CHARGE with the bow: phase 0 and nothing else.
	var bow := MachineDriver.new(CombatCatalog.weapon_id(&"bow"))
	bow.hold(PlayerInput.PRIMARY, 10)
	assert_eq(bow.c.action, CombatState.Action.CHARGE, "drawing")
	assert_eq(wire.encode(bow.c, bow.tick), CombatState.Action.CHARGE, "CHARGE, phase 0, bits 6-7 at 0")


## H5 review: with the health potion cut at its cast (NONE at s), an edge of the stamina one at
## s + 1 started another ABILITY with the same byte (phase 0, slot 3) as at s - 1. A remote sees the record every
## SNAPSHOT_INTERVAL_TICKS ticks: one that did not sample s saw the same byte and the drinking clip still did not
## restart. Now the interruption leaves REARM_TICKS ticks of margin and the NONE is seen with any sampling.
func test_after_an_interrupted_drink_the_next_one_waits_until_a_remote_can_see_none() -> void:
	var sword: int = CombatCatalog.weapon_id(&"sword_shield")
	var d := MachineDriver.new(sword, 0, CombatState.pack_charges(3, 2))
	var wire := ActionWire.new()
	d.step(PlayerInput.CONSUMABLE_1)
	d.hold(PlayerInput.CONSUMABLE_1, 10)
	var before: int = wire.encode(d.c, d.tick)
	assert_eq([before & 15, (before >> 4) & 3, ActionWire.step_of(before)], [CombatState.Action.ABILITY, 0, 3],
			"at s - 1 the health one is drunk: ABILITY, phase 0, slot 3")
	d.step(PlayerInput.CONSUMABLE_1)
	var s: int = d.tick
	ActionMachine.impose_interrupt(d.c, s)
	assert_eq(wire.encode(d.c, s), 0x30, "at s, NONE")
	assert_eq(d.c.charges_of(0), 3, "without spending the charge")
	var bytes: Array[int] = [0x30]
	var started: int = -1
	for rel: int in range(1, AbilityTicks.REARM_TICKS + 4):
		# An edge of the other potion at s + 1 (another button, releasing nothing), and it is held.
		d.step(PlayerInput.CONSUMABLE_2)
		var byte: int = wire.encode(d.c, d.tick)
		if started < 0 and d.c.action == CombatState.Action.ABILITY:
			started = d.tick
		if started < 0:
			bytes.append(byte)
	assert_true(bytes.size() > 1 and bytes[1] != before,
			"at s + 1 the byte from s - 1 no longer comes out (before: the same, and has_counter(ABILITY) is false)")
	assert_eq(started, s + AbilityTicks.REARM_TICKS, "the stamina one starts when the margin ends (from the buffer)")
	assert_eq(d.c.action_id, CombatCatalog.ability_id(&"potion_stamina"))
	assert_eq(bytes.size(), AbilityTicks.REARM_TICKS, "NONE from s to s + REARM_TICKS - 1")
	for byte: int in bytes:
		assert_eq(byte, 0x30, "all NONE")
	assert_true(AbilityTicks.REARM_TICKS >= 3 * NetProtocol.SNAPSHOT_INTERVAL_TICKS,
			"more than a snapshot interval: any sampling sees the NONE")
	# An ability cut during its cast leaves the same margin in its slot.
	var bash := MachineDriver.new(sword)
	bash.step(PlayerInput.ABILITY_1)
	var ability: AbilityTicks = CombatCatalog.ability(bash.c.action_id)
	bash.step()
	ActionMachine.impose_interrupt(bash.c, bash.tick)
	assert_eq(bash.c.ability_ready[ability.slot], bash.tick + AbilityTicks.REARM_TICKS,
			"the slot of %s, with the margin" % ability.name)
	# After the commit the cooldown is already greater and does not change.
	var late := MachineDriver.new(sword, 0, CombatState.pack_charges(3, 2))
	late.step(PlayerInput.CONSUMABLE_1)
	late.hold(0, CombatCatalog.ability(late.c.action_id).cast_ticks + 2)
	var committed: int = late.c.consumable_ready_tick
	assert_true(committed > late.tick + AbilityTicks.REARM_TICKS, "committed, it already has its cooldown")
	ActionMachine.impose_interrupt(late.c, late.tick)
	assert_eq(late.c.consumable_ready_tick, committed, "and the interruption does not touch it")


## Phase 4 review ("abilities" lens): a tap of 3 shorter than the wall's cast ends
## without a commit at the end of the cast (p + cast, 4a with the button released). Before, it left no
## margin: another press at p + cast + 1 came out with the same byte (ABILITY, phase 0, slot 2) after a single
## tick of NONE, and a remote that did not sample it kept following the first one's clip. Now it leaves REARM_TICKS,
## like the interruption: NONE from p + cast to p + cast + REARM_TICKS - 1 and the wall comes out again when it ends,
## from the buffer with the button down.
func test_after_a_wall_tap_shorter_than_the_cast_the_next_one_waits_until_a_remote_can_see_none() -> void:
	var d := MachineDriver.new(CombatCatalog.weapon_id(&"sword_shield"))
	var wire := ActionWire.new()
	var wall: AbilityTicks = CombatCatalog.ability(CombatCatalog.ability_id(&"shield_wall"))
	d.step(PlayerInput.ABILITY_3)
	var p: int = d.tick
	assert_eq(d.c.action_id, wall.id, "the wall starts")
	var first: int = wire.encode(d.c, p)
	d.idle_until_before(p + wall.cast_ticks)
	d.step()
	var end: int = d.tick
	assert_eq(end, p + wall.cast_ticks, "at the end of the cast")
	assert_eq(d.c.action, CombatState.Action.NONE, "ends without a wall")
	assert_eq(d.c.ability_ready[wall.slot], end + AbilityTicks.REARM_TICKS,
			"no cooldown, but with the REARM_TICKS margin")
	var bytes: Array[int] = [wire.encode(d.c, end)]
	var started: int = -1
	var second: int = -1
	for _rel: int in range(1, AbilityTicks.REARM_TICKS + 4):
		# Another press of 3 at p + cast + 1, and it is held.
		d.step(PlayerInput.ABILITY_3)
		var byte: int = wire.encode(d.c, d.tick)
		if started < 0 and d.c.action == CombatState.Action.ABILITY:
			started = d.tick
			second = byte
		if started < 0:
			bytes.append(byte)
	assert_eq(second, first,
			"the second wall comes out with the same byte as the first (hence the margin is needed)")
	assert_eq(started, end + AbilityTicks.REARM_TICKS,
			"the wall comes out again when the margin ends (from the buffer)")
	assert_eq(bytes.size(), AbilityTicks.REARM_TICKS, "NONE from p + cast to p + cast + REARM_TICKS - 1")
	for byte: int in bytes:
		assert_eq(byte, 0x30, "all NONE")
	# Control: releasing when already committed sets the whole cooldown.
	var held := MachineDriver.new(CombatCatalog.weapon_id(&"sword_shield"))
	held.step(PlayerInput.ABILITY_3)
	held.hold(PlayerInput.ABILITY_3, wall.cast_ticks + 1)
	held.step()
	assert_eq(held.c.action, CombatState.Action.NONE, "control: released after the commit, it ends")
	assert_eq(held.c.ability_ready[wall.slot], held.tick + wall.cooldown_ticks,
			"control: with its cooldown")
