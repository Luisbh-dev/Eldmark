extends TestCase
## Weapon swap (docs/habilidades.md, sections 3.3 to 3.5 and 7.3): swapping the weapons and the two
## halves of the cooldowns, never in the middle of a strike (it goes to the buffer, and expires if the
## window does not arrive), with no weapon in the other slot it does nothing,
## [method ActionMachine.set_charges] touches nothing else and [method ActionMachine.set_loadout]
## forces NONE on a living character. With physics ([PredictionPair]): the swap, predicted and reconciled with a
## substituted input around the edge, ends up the same on both sides.

const Action = CombatState.Action
const PRIMARY: int = PlayerInput.PRIMARY
const DODGE: int = PlayerInput.DODGE
const SWAP: int = PlayerInput.SWAP_WEAPON
const ABILITY_1: int = PlayerInput.ABILITY_1
const ABILITY_3: int = PlayerInput.ABILITY_3
## Tick of the SWAP edge in the test with physics.
const SWAP_TICK: int = 40

var _pair: PredictionPair


func after_each() -> void:
	if _pair != null:
		_pair.free_worlds()
		_pair = null
	await wait_process_frames()


func test_swap_exchanges_the_weapons_and_the_two_cooldown_halves() -> void:
	var data: CombatTables = CombatCatalog.tables()
	assert_eq(data.swap_ticks, 24, "0,4 s")
	var d := _driver()
	d.step(ABILITY_1)
	d.hold(0, 60)
	var bash_ready: int = d.c.ability_ready[0]
	assert_true(bash_ready > 0, "shield bash on cooldown")
	d.step(SWAP)
	var s: int = d.tick
	assert_eq(d.c.action, Action.SWAP, "swapping")
	assert_eq(d.c.action_tick, s, "from the edge")
	assert_eq([d.c.weapon_id, d.c.alt_weapon_id], [_bow(), _sword()], "the weapon changes on the first tick")
	assert_true(d.c.is_second_slot(), "slot 2 is active")
	assert_eq(d.c.ability_ready.slice(0, 3), PackedInt64Array([0, 0, 0]), "the bow's are free")
	assert_eq(d.c.ability_ready[3], bash_ready, "the shield's is stored in the other half")
	assert_true(d.out.scaled_movement, "scaled movement")
	assert_near(d.out.move_scale, 0.8, 1e-6, "×0,8")
	assert_eq(d.out.turn_rate, -1.0, "normal turning")
	assert_false(d.out.allow_jump or d.out.allow_sprint, "no jump or sprint")
	assert_eq(ActionMachine.phase(d.c, s), ActionMachine.PHASE_NONE, "no phases")
	d.idle_until_before(s + 24)
	assert_eq(d.c.action, Action.SWAP, "lasts 24 ticks")
	d.step()
	assert_eq(d.c.action, Action.NONE, "and ends")
	# Cooldowns are absolute ticks: they keep running with the weapon stowed.
	d.step(SWAP)
	assert_eq([d.c.weapon_id, d.c.alt_weapon_id], [_sword(), _bow()], "back to the sword")
	assert_false(d.c.is_second_slot(), "slot 1")
	assert_eq(d.c.ability_ready[0], bash_ready, "the cooldown comes back with its weapon, intact")
	assert_eq(d.c.ability_ready[3], 0, "and the bow's half is stored")
	# In the air too.
	var air := _driver()
	air.grounded = false
	air.step(SWAP)
	assert_eq(air.c.action, Action.SWAP, "it swaps in the air")


func test_no_swap_in_the_middle_of_a_hit() -> void:
	# Pressed during the active part of a light attack: the weapon does not change until recovery (rel 18).
	var d := _driver()
	d.step(PRIMARY)
	var p: int = d.tick
	d.idle_until_before(p + 13)
	d.step(SWAP)
	assert_eq(d.c.action, Action.LIGHT, "in the middle of a strike it does not swap")
	assert_eq(d.c.weapon_id, _sword(), "the weapon stays")
	assert_eq(d.c.buffered_type(), CombatState.BUFFER_SWAP, "it goes to the buffer")
	d.idle_until_before(p + 18)
	assert_eq(d.c.weapon_id, _sword(), "until recovery, nothing")
	d.step()
	assert_eq(d.c.action, Action.SWAP, "in recovery it swaps")
	assert_eq(d.c.action_tick, p + 18, "on its first tick")
	assert_eq(d.c.weapon_id, _bow(), "with the new weapon")
	# Pressed during windup: the buffer expires before recovery.
	var early := _driver()
	early.step(PRIMARY)
	var q: int = early.tick
	early.step(SWAP)
	early.idle_until_before(q + 40)
	assert_eq(early.c.weapon_id, _sword(), "it expired: no swap")
	assert_eq(early.c.alt_weapon_id, _bow(), "the weapons stay the same")
	# Nor during a charge, nor during the cast or channeling of an ability.
	var charge := _driver()
	charge.hold(PRIMARY, 8)
	charge.step(PRIMARY | SWAP)
	assert_eq(charge.c.action, Action.CHARGE, "while charging it does not swap")
	var wall := _driver()
	wall.step(ABILITY_3)
	wall.hold(ABILITY_3, 5)
	wall.step(ABILITY_3 | SWAP)
	assert_eq(wall.c.action, Action.ABILITY, "while casting neither")
	wall.hold(ABILITY_3, 20)
	wall.step(ABILITY_3 | SWAP)
	assert_eq(wall.c.action, Action.ABILITY, "while channeling neither")
	assert_eq(wall.c.weapon_id, _sword(), "the weapon stays")
	# From the dodge, from its cancel_to_attack_from (18).
	var dodge := _driver()
	dodge.step(DODGE)
	var r: int = dodge.tick
	dodge.idle_until_before(r + 10)
	dodge.step(SWAP)
	assert_eq(dodge.c.action, Action.DODGE, "while dodging, not yet")
	dodge.idle_until_before(r + 19)
	assert_eq(dodge.c.action, Action.SWAP, "from tick 18 of the dodge")
	assert_eq(dodge.c.action_tick, r + 18, "right there")


func test_without_a_second_weapon_the_press_is_dropped() -> void:
	var d := MachineDriver.new(_sword(), 0, CombatState.pack_charges(3, 2))
	d.step(SWAP)
	assert_eq(d.c.action, Action.NONE, "with no other weapon there is no swap")
	assert_eq(d.c.buffered, 0, "nor is it buffered")
	assert_eq(d.c.weapon_id, _sword(), "the weapon stays")


func test_a_buffered_swap_starts_when_the_other_ends() -> void:
	var d := _driver()
	d.step(SWAP)
	var s: int = d.tick
	d.idle_until_before(s + 20)
	d.step(SWAP)
	assert_eq(d.c.buffered_type(), CombatState.BUFFER_SWAP, "the second swap waits")
	d.idle_until_before(s + 25)
	assert_eq(d.c.action, Action.SWAP, "it happens on the tick the first one ends, without NONE")
	assert_eq(d.c.action_tick, s + 24, "on that tick")
	assert_eq(d.c.weapon_id, _sword(), "back to the sword")
	var wire := ActionWire.new()
	var first := MachineDriver.new(_sword(), _bow())
	first.step(SWAP)
	var byte_first: int = wire.encode(first.c, first.tick)
	first.idle_until_before(first.tick + 20)
	first.step(SWAP)
	first.idle_until_before(first.c.action_tick + 25)
	var byte_second: int = wire.encode(first.c, first.tick)
	assert_eq(byte_first & 0x3F, byte_second & 0x3F, "same action byte and phase")
	assert_true(ActionWire.step_of(byte_first) != ActionWire.step_of(byte_second),
			"but a different counter: the remote restarts the animation")


func test_set_charges_touches_nothing_else() -> void:
	var d := _driver()
	d.step(SWAP)
	d.hold(0, 30)
	d.step(ABILITY_1)
	d.hold(ABILITY_1, 30)
	assert_true(d.c.is_second_slot(), "with slot 2 active")
	d.step(ABILITY_3)
	d.hold(ABILITY_3, 5)
	assert_eq(d.c.action, Action.ABILITY, "and an ability in progress")
	assert_true(d.c.ability_ready[0] > 0, "with its cooldown set")
	var before: PackedByteArray = d.bytes()
	ActionMachine.set_charges(d.c, CombatState.pack_charges(7, 1))
	var after: PackedByteArray = d.bytes()
	assert_eq(d.c.consumable_charges, CombatState.pack_charges(7, 1), "the charges change")
	for i: int in CombatState.ENCODED_SIZE:
		if i == 65:
			continue
		if before[i] != after[i]:
			fail("set_charges changed byte %d (offset %d in PlayerState)" % [i, i + 35])
			return
	assert_eq(d.c.action, Action.ABILITY, "the ability continues")


func test_set_loadout_forces_none_on_a_living_character_and_reset_takes_the_template() -> void:
	var d := _driver()
	d.c.combat_flags2 |= CombatState.FLAG2_NO_COOLDOWNS
	d.step(PRIMARY | ABILITY_3)
	d.step(ABILITY_1 | ABILITY_3)
	ActionMachine.impose_move_effect(d.c, CombatCatalog.status_id(&"slowed"), d.tick + 100)
	ActionMachine.set_loadout(d.c, _bow(), _sword(), CombatState.pack_charges(2, 3))
	assert_eq(d.c.action, Action.NONE, "on a living character, NONE first")
	assert_eq([d.c.weapon_id, d.c.alt_weapon_id], [_bow(), _sword()], "weapons in slot order")
	assert_false(d.c.is_second_slot(), "with 1 active")
	assert_eq(d.c.ability_ready, PackedInt64Array([0, 0, 0, 0, 0, 0]), "cooldowns at 0")
	assert_eq(d.c.consumable_charges, CombatState.pack_charges(2, 3), "charges")
	assert_eq(d.c.move_effect_ids, PackedInt32Array([0, 0]), "empty slots")
	assert_eq(d.c.buffered, 0, "no buffer")
	assert_eq(d.c.combat_flags2 & CombatState.FLAG2_HELD_MASK,
			CombatState.FLAG2_ABILITY_1_HELD | CombatState.FLAG2_ABILITY_3_HELD,
			"keeps the pressed buttons")
	d.step(ABILITY_1 | ABILITY_3)
	assert_eq(d.c.action, Action.NONE, "no edges while they stay held")
	var dead := _driver()
	dead.step()
	ActionMachine.impose_death(dead.c, dead.tick)
	ActionMachine.set_loadout(dead.c, _bow(), 0, 0)
	assert_eq(dead.c.action, Action.DEAD, "on a dead character only the equipment changes")
	assert_eq(dead.c.weapon_id, _bow(), "the bow")


func test_a_predicted_swap_is_reconciled_around_a_substituted_edge() -> void:
	# The edge's input is lost: the server substitutes it (without SWAP) and swaps one tick late, with
	# the next real one. The client corrects and ends up the same, byte for byte.
	_pair = PredictionPair.new()
	_pair.lost.assign([SWAP_TICK])
	await _pair.build(tree, _swap_route, _pair_combat())
	for _frame: int in 120:
		await tree.physics_frame
		_pair.frame()
	var server_start: int = -1
	for tick: int in range(SWAP_TICK - 1, SWAP_TICK + 4):
		var state: PlayerState = _pair.server_states[tick]
		if state.combat.action == Action.SWAP and server_start < 0:
			server_start = state.combat.action_tick
	assert_eq(server_start, SWAP_TICK + 1, "the server swaps with the first real input")
	assert_true(_pair.results_not(ClientPrediction.Result.MATCH).size() >= 1, "the client corrects")
	var since: int = _pair.converged_since(SWAP_TICK)
	assert_true(since > 0 and since <= SWAP_TICK + 4, "and ends up the same as the server (from %d)" % since)
	var last: PlayerState = _pair.predicted(_pair.server_tick)
	assert_eq(last.combat.weapon_id, _bow(), "with the bow")
	# And if the input following the edge is lost, the substitute repeats the button: nothing to correct.
	_pair.free_worlds()
	_pair = PredictionPair.new()
	_pair.lost.assign([SWAP_TICK + 1])
	await _pair.build(tree, _swap_route, _pair_combat())
	for _frame: int in 120:
		await tree.physics_frame
		_pair.frame()
	assert_eq(_pair.results_not(ClientPrediction.Result.MATCH).size(), 0,
			"losing the tick after the edge changes nothing")
	assert_eq((_pair.server_states[SWAP_TICK] as PlayerState).combat.action, Action.SWAP,
			"the server swapped on the edge")


func _sword() -> int:
	return CombatCatalog.weapon_id(&"sword_shield")


func _bow() -> int:
	return CombatCatalog.weapon_id(&"bow")


func _driver() -> MachineDriver:
	return MachineDriver.new(_sword(), _bow(), CombatState.pack_charges(2, 3))


func _pair_combat() -> CombatState:
	return CombatState.initial(CombatCatalog.rules(), _sword(), _bow(), CombatState.pack_charges(2, 3))


## Walks and holds SWAP from [constant SWAP_TICK] to [constant SWAP_TICK] + 5.
func _swap_route(tick: int) -> PlayerInput:
	var input := PlayerInput.new()
	input.tick = tick
	if tick < 20:
		return input
	input.move = Vector2(0.0, 1.0)
	if tick >= SWAP_TICK and tick <= SWAP_TICK + 5:
		input.buttons |= SWAP
	return input
