extends TestCase
## Tests of abilities in the action machine ([ActionMachine] and [AbilityRules];
## docs/abilities.md, sections 3.3 to 3.6) without physics, with [MachineDriver]: the edge, the
## commit and the reuse, the channelings (release, moving, the cap and the examples in
## section 3.3), the priorities, the buffer, replaced inputs, queries and what the
## server imposes (knocked down, getting up, finishing off, interruption).
## [br][br]
## Sword and shield data (ticks): shield bash 18 + 6 + 24 (cooldown 720),
## charge 9 + 24 + 21 with a 6 m advance in [9, 33) (960), wall 12 + up to 360 channeled (1080,
## dodge from 12). The ids are looked up by name.

const Action = CombatState.Action
const PRIMARY: int = PlayerInput.PRIMARY
const DODGE: int = PlayerInput.DODGE
const BLOCK: int = PlayerInput.BLOCK
const ABILITY_1: int = PlayerInput.ABILITY_1
const ABILITY_2: int = PlayerInput.ABILITY_2
const ABILITY_3: int = PlayerInput.ABILITY_3
const SWAP: int = PlayerInput.SWAP_WEAPON
const CONSUMABLE_1: int = PlayerInput.CONSUMABLE_1
const INTERACT: int = PlayerInput.INTERACT

## Resources changed by a test: [resource, property, original value].
var _mutations: Array[Array] = []


func after_each() -> void:
	if _mutations.is_empty():
		return
	for i: int in range(_mutations.size() - 1, -1, -1):
		var entry: Array = _mutations[i]
		(entry[0] as Resource).set(entry[1], entry[2])
	_mutations.clear()
	CombatCatalog.reload()


# --- Edge, commit and cooldown ------------------------------------------------------

func test_the_edge_starts_the_ability_and_the_commit_sets_its_cooldown() -> void:
	var bash: AbilityTicks = _ability(&"shield_bash")
	assert_eq([bash.cast_ticks, bash.active_ticks, bash.recovery_ticks, bash.cooldown_ticks],
			[18, 6, 24, 720], "shield bash: 18 + 6 + 24, 12 s")
	var d := _sword_driver()
	d.hold(0, 3)
	d.c.combo_step = 2
	var p: int = d.tick + 1
	var first: ActionMachine.Output = d.step(ABILITY_1)
	assert_eq(d.c.action, Action.ABILITY, "the ABILITY_1 edge starts the ability")
	assert_eq(d.c.action_id, bash.id, "the one in slot 1")
	assert_eq(d.c.action_tick, p, "on the edge tick")
	assert_eq(d.c.combo_step, 0, "the combo starts over")
	assert_true(first.snap_yaw, "on the first tick the yaw snaps to the camera")
	assert_true(first.scaled_movement, "scaled movement")
	assert_near(first.move_scale, 0.2, 1e-6, "×0,2")
	assert_near(first.lunge_speed, 1.0, 1e-6, "1 m/s advance")
	assert_near(first.turn_rate, 6.0, 1e-6, "turn 6")
	assert_false(first.allow_jump or first.allow_sprint, "no jump or sprint")
	assert_eq(d.c.ability_ready[0], 0, "the cooldown is set at the commit, not at the start")
	var expected_ready: int = p + 18 + 720
	for rel: int in range(1, 48):
		var out: ActionMachine.Output = d.step(ABILITY_1)
		var tick: int = p + rel
		assert_eq(d.c.action, Action.ABILITY, "rel %d: holding the button neither repeats nor cuts it" % rel)
		var phase: int = ActionMachine.phase(d.c, tick)
		if rel < 18:
			assert_eq(phase, ActionMachine.PHASE_WINDUP, "rel %d: cast" % rel)
			assert_eq(d.c.ability_ready[0], 0, "rel %d: no cooldown yet" % rel)
			assert_near(out.lunge_speed, 1.0, 1e-6, "rel %d: advances during the cast" % rel)
		elif rel < 24:
			assert_eq(phase, ActionMachine.PHASE_ACTIVE, "rel %d: active" % rel)
			assert_eq(d.c.ability_ready[0], expected_ready, "rel %d: set at the commit" % rel)
		else:
			assert_eq(phase, ActionMachine.PHASE_RECOVERY, "rel %d: recovery" % rel)
			assert_eq(out.turn_rate, 0.0, "rel %d: no turning during recovery" % rel)
			assert_eq(out.lunge_speed, 0.0, "rel %d: nor advance" % rel)
		assert_eq(ActionMachine.is_commit_tick(d.c, tick), rel == 18, "rel %d: commit at 18" % rel)
	d.step(ABILITY_1)
	assert_eq(d.c.action, Action.NONE, "ends at 48 ticks")
	assert_eq(d.c.ability_ready[0], expected_ready, "the cooldown continues")
	assert_eq(d.c.ability_ready.slice(1), PackedInt64Array([0, 0, 0, 0, 0]), "the other slots do not change")
	assert_eq(d.c.stamina, 1000, "costs no stamina")


func test_cast_zero_commits_on_the_tick_it_starts() -> void:
	_mutate("res://data/combat/shield_bash.tres", &"cast_s", 0.0)
	var bash: AbilityTicks = _ability(&"shield_bash")
	assert_eq(bash.cast_ticks, 0, "cast 0")
	var d := _sword_driver()
	d.step(ABILITY_1)
	var p: int = d.tick
	assert_eq(d.c.action, Action.ABILITY, "starts")
	assert_eq(d.c.ability_ready[0], p + bash.cooldown_ticks, "and commits on the same tick")
	assert_true(ActionMachine.is_commit_tick(d.c, p), "its first tick is the commit")
	assert_eq(ActionMachine.phase(d.c, p), ActionMachine.PHASE_ACTIVE, "no cast")


func test_the_ability_is_ready_again_exactly_at_ability_ready_and_not_before() -> void:
	var d := _sword_driver()
	d.step(ABILITY_1)
	d.hold(0, 60)
	var ready: int = d.c.ability_ready[0]
	assert_true(ready > d.tick, "on cooldown")
	assert_eq(ActionMachine.ability_status(d.c, 0, d.tick), ActionMachine.AbilityStatus.COOLDOWN,
			"the bar sees it on cooldown")
	# Pressed one tick early: goes to the buffer and fires right at ready.
	var early := MachineDriver.new(d.c.weapon_id)
	early.c.copy_from(d.c)
	early.tick = d.tick
	early.idle_until_before(ready - 1)
	early.step(ABILITY_1)
	assert_eq(early.c.action, Action.NONE, "at ready - 1 it does not start")
	assert_eq(early.c.buffered_type(), CombatState.BUFFER_ABILITY_1, "goes to the buffer")
	early.step()
	assert_eq(early.c.action, Action.ABILITY, "comes out of the buffer at ready")
	assert_eq(early.c.action_tick, ready, "exactly at ready")
	# Pressed 9 ticks early: the buffer expires at ready - 1 and nothing starts.
	var late := MachineDriver.new(d.c.weapon_id)
	late.c.copy_from(d.c)
	late.tick = d.tick
	late.idle_until_before(ready - 9)
	late.step(ABILITY_1)
	late.idle_until_before(ready + 1)
	assert_eq(late.c.buffered, 0, "the buffer expired")
	assert_eq(late.c.action, Action.NONE, "not started at ready")
	# And a press at ready starts immediately.
	var exact := MachineDriver.new(d.c.weapon_id)
	exact.c.copy_from(d.c)
	exact.tick = d.tick
	exact.idle_until_before(ready)
	assert_eq(ActionMachine.ability_status(exact.c, 0, ready), ActionMachine.AbilityStatus.READY,
			"ready at ready")
	exact.step(ABILITY_1)
	assert_eq(exact.c.action, Action.ABILITY, "pressed at ready starts")


func test_a_stagger_in_the_cast_leaves_no_cooldown() -> void:
	var d := _sword_driver()
	d.step(ABILITY_1)
	d.hold(0, 10)
	ActionMachine.impose_stagger(d.c, d.tick, d.tick + 20, Vector2.ZERO)
	assert_eq(d.c.action, Action.STAGGER, "staggered during the cast")
	d.hold(0, 25)
	assert_eq(d.c.action, Action.NONE, "the stagger ends")
	assert_eq(d.c.ability_ready[0], 0, "a crowd control before the commit does not spend the cooldown")
	d.step(ABILITY_1)
	assert_eq(d.c.action, Action.ABILITY, "and it can be used again")


# --- Channeling ------------------------------------------------------------------------------

func test_a_stagger_cuts_a_channel_and_sets_its_cooldown_on_that_tick() -> void:
	var wall: AbilityTicks = _ability(&"shield_wall")
	assert_eq([wall.cast_ticks, wall.active_ticks, wall.recovery_ticks, wall.cooldown_ticks],
			[12, 360, 0, 1080], "wall: 12 + up to 360, 18 s")
	assert_true(wall.channel and wall.channel_hold and wall.blocks, "channeled, held, blocks")
	var d := _sword_driver()
	d.step(ABILITY_3)
	var p: int = d.tick
	d.hold(ABILITY_3, 39)
	assert_eq(d.c.ability_ready[2], 0, "a channeling sets nothing at the commit")
	var s: int = d.tick
	ActionMachine.impose_stagger(d.c, s, s + 30, Vector2(1.0, 0.0))
	assert_eq(d.c.action, Action.STAGGER, "the stagger cuts the wall")
	assert_eq(d.c.ability_ready[2], s + 1080, "and sets its cooldown on that tick")
	assert_eq(p + 39, s, "halfway through the channeling")
	# On the very tick of the commit (already simulated) it also counts; one tick earlier, it does not.
	var at_commit := _sword_driver()
	at_commit.step(ABILITY_3)
	at_commit.hold(ABILITY_3, 12)
	ActionMachine.impose_stun(at_commit.c, at_commit.tick, at_commit.tick + 30)
	assert_eq(at_commit.c.ability_ready[2], at_commit.tick + 1080,
			"stunned on the commit tick: it is already committed")
	var before := _sword_driver()
	before.step(ABILITY_3)
	before.hold(ABILITY_3, 11)
	ActionMachine.impose_stun(before.c, before.tick, before.tick + 30)
	assert_eq(before.c.ability_ready[2], 0, "during the cast: no cooldown")
	var killed := _sword_driver()
	killed.step(ABILITY_3)
	killed.hold(ABILITY_3, 30)
	ActionMachine.impose_death(killed.c, killed.tick)
	assert_eq(killed.c.ability_ready[2], killed.tick + 1080, "death sets it too")


func test_releasing_moving_and_the_cap_end_the_channel() -> void:
	# Release.
	var d := _sword_driver()
	d.step(ABILITY_3)
	var p: int = d.tick
	d.hold(ABILITY_3, 99)
	assert_eq(d.c.action, Action.ABILITY, "held, it continues")
	d.step()
	assert_eq(d.c.action, Action.NONE, "releasing 3 ends it")
	assert_eq(d.c.action_tick, p, "keeping the action_tick of what ends")
	assert_eq(d.c.ability_ready[2], p + 100 + 1080, "with the cooldown from that tick")
	# Replaced inputs do not release it.
	var held := _sword_driver()
	held.step(ABILITY_3)
	held.hold(ABILITY_3, 40)
	held.hold(0, 5, true)
	assert_eq(held.c.action, Action.ABILITY, "a replaced one without the button does not release it")
	held.step()
	assert_eq(held.c.action, Action.NONE, "the first real one without the button does")
	# The cap: 12 + 360.
	var capped := _sword_driver()
	capped.step(ABILITY_3)
	var q: int = capped.tick
	capped.idle_until_before(q + 372, ABILITY_3)
	assert_eq(capped.c.action, Action.ABILITY, "continues up to the cap")
	assert_true(ActionMachine.defense_flags(capped.c, capped.tick) & ActionMachine.DEFENSE_WIDE_BLOCK != 0,
			"blocking until the last tick")
	capped.step(ABILITY_3)
	assert_eq(capped.c.action, Action.NONE, "at 372 ticks it ends on its own")
	assert_eq(capped.c.ability_ready[2], q + 372 + 1080, "with its cooldown")
	# Moving, if the data says so.
	_mutate("res://data/combat/shield_wall.tres", &"channel_breaks_on_move", true)
	var mover := _sword_driver()
	mover.step(ABILITY_3)
	var m: int = mover.tick
	mover.move = Vector2(0.0, 1.0)
	mover.hold(ABILITY_3, 5)
	assert_eq(mover.c.action, Action.ABILITY, "moving during the cast does not break it")
	mover.move = Vector2.ZERO
	mover.idle_until_before(m + 30, ABILITY_3)
	mover.move = Vector2(0.0, 1.0)
	mover.step(ABILITY_3, true)
	assert_eq(mover.c.action, Action.ABILITY, "neither does a replaced one with movement")
	mover.step(ABILITY_3)
	assert_eq(mover.c.action, Action.NONE, "a real one with |move| >= 0.1 ends it")
	assert_eq(mover.c.ability_ready[2], m + 31 + 1080, "with its cooldown")


func test_release_and_press_primary_in_the_same_tick() -> void:
	# docs/abilities.md, section 3.3: releasing 3 and pressing PRIMARY on the same tick ends the wall in 4a
	# and the light attack comes out in 4c, on that tick.
	var d := _sword_driver()
	d.step(ABILITY_3)
	d.hold(ABILITY_3, 50)
	d.step(PRIMARY)
	assert_eq(d.c.action, Action.LIGHT, "the light attack comes out on the same tick")
	assert_eq(d.c.action_tick, d.tick, "on that tick")
	assert_eq(d.c.ability_ready[2], d.tick + 1080, "and the wall set its cooldown")


## No cooldown, but with the REARM_TICKS margin on the slot (phase 4 review: without it, another
## press at p + 13 came out with the same action byte after a single tick of NONE; see test_action_wire).
func test_a_tap_shorter_than_the_cast_gives_twelve_ticks_and_only_the_rearm_margin() -> void:
	var d := _sword_driver()
	d.step(ABILITY_3)
	var p: int = d.tick
	d.step(ABILITY_3)
	for rel: int in range(2, 12):
		d.step()
		assert_eq(d.c.action, Action.ABILITY, "rel %d: the cast continues even if released" % rel)
		assert_eq(ActionMachine.defense_flags(d.c, d.tick), 0, "rel %d: not blocking yet" % rel)
	d.step()
	assert_eq(d.tick, p + 12, "at the end of the cast")
	assert_eq(d.c.action, Action.NONE, "ends without a wall")
	assert_eq(d.c.ability_ready[2], p + 12 + AbilityTicks.REARM_TICKS,
			"and without cooldown: only the margin")


func test_release_on_the_commit_tick_and_one_tick_after() -> void:
	var on_commit := _sword_driver()
	on_commit.step(ABILITY_3)
	var p: int = on_commit.tick
	on_commit.hold(ABILITY_3, 11)
	on_commit.step()
	assert_eq(on_commit.tick, p + 12, "released at the commit")
	assert_eq(on_commit.c.action, Action.NONE, "it is cancelled")
	assert_eq(on_commit.c.ability_ready[2], p + 12 + AbilityTicks.REARM_TICKS,
			"no cooldown: only the margin")
	var after := _sword_driver()
	after.step(ABILITY_3)
	var q: int = after.tick
	after.hold(ABILITY_3, 12)
	assert_eq(ActionMachine.defense_flags(after.c, q + 12),
			ActionMachine.DEFENSE_BLOCKING | ActionMachine.DEFENSE_WIDE_BLOCK, "one tick of wall")
	after.step()
	assert_eq(after.c.action, Action.NONE, "released one tick later")
	assert_eq(after.c.ability_ready[2], q + 13 + 1080, "and it is 18 s")
	# Dodging on the commit tick does not spend it either.
	var dodged := _sword_driver()
	dodged.step(ABILITY_3)
	var r: int = dodged.tick
	dodged.hold(ABILITY_3, 11)
	dodged.step(ABILITY_3 | DODGE)
	assert_eq(dodged.c.action, Action.DODGE, "the dodge cuts the wall from the end of the cast")
	assert_eq(dodged.c.action_tick, r + 12, "at the commit")
	assert_eq(dodged.c.ability_ready[2], 0, "no cooldown")
	var dodged_later := _sword_driver()
	dodged_later.step(ABILITY_3)
	var u: int = dodged_later.tick
	dodged_later.hold(ABILITY_3, 19)
	dodged_later.step(ABILITY_3 | DODGE)
	assert_eq(dodged_later.c.action, Action.DODGE, "dodge in the middle of the channeling")
	assert_eq(dodged_later.c.ability_ready[2], u + 20 + 1080, "with the cooldown of that tick")


func test_a_buffered_wall_needs_its_button_down() -> void:
	# Pressed during the active hit of a light attack (it comes out of the buffer in the recovery, rel 18).
	var up := _sword_driver()
	up.step(PRIMARY)
	var p: int = up.tick
	up.idle_until_before(p + 12)
	up.step(ABILITY_3)
	assert_eq(up.c.buffered_type(), CombatState.BUFFER_ABILITY_3, "to the buffer")
	up.step()
	assert_eq(up.c.buffered, 0, "with the button released it is discarded")
	up.idle_until_before(p + 20)
	assert_eq(up.c.action, Action.LIGHT, "and there is no wall")
	var down := _sword_driver()
	down.step(PRIMARY)
	var q: int = down.tick
	down.idle_until_before(q + 12)
	down.idle_until_before(q + 19, ABILITY_3)
	assert_eq(down.c.action, Action.ABILITY, "held, it comes out in the light attack's recovery")
	assert_eq(down.c.action_tick, q + 18, "on the first tick of the recovery")


# --- Priorities, buffer and replaced inputs ---------------------------------------------------

func test_simultaneous_edges_follow_the_priority() -> void:
	var bash: int = _ability(&"shield_bash").id
	var rush: int = _ability(&"shield_rush").id
	var health: int = CombatCatalog.consumable_ids()[0]
	# [buttons, action, action_id (-1 = does not matter), what remains in the buffer, message]
	var cases: Array = [
		[DODGE | ABILITY_1, Action.DODGE, -1, CombatState.BUFFER_ABILITY_1, "DODGE > ABILITY_1"],
		[ABILITY_1 | ABILITY_2, Action.ABILITY, bash, CombatState.BUFFER_ABILITY_2,
				"ABILITY_1 > ABILITY_2"],
		[ABILITY_2 | ABILITY_3, Action.ABILITY, rush, CombatState.BUFFER_ABILITY_3,
				"ABILITY_2 > ABILITY_3"],
		[ABILITY_3 | CONSUMABLE_1, Action.ABILITY, _ability(&"shield_wall").id,
				CombatState.BUFFER_CONSUMABLE_1, "ABILITY_3 > CONSUMABLE_1"],
		[CONSUMABLE_1 | PlayerInput.CONSUMABLE_2, Action.ABILITY, health,
				CombatState.BUFFER_CONSUMABLE_2, "CONSUMABLE_1 > CONSUMABLE_2"],
		[PlayerInput.CONSUMABLE_2 | PRIMARY, Action.ABILITY, CombatCatalog.consumable_ids()[1],
				CombatState.BUFFER_PRIMARY, "CONSUMABLE_2 > PRIMARY"],
		[PRIMARY | SWAP, Action.LIGHT, -1, CombatState.BUFFER_SWAP, "PRIMARY > SWAP"],
		[SWAP | BLOCK, Action.SWAP, -1, CombatState.BUFFER_NONE, "SWAP > BLOCK"],
	]
	for case: Array in cases:
		var d := MachineDriver.new(_sword(), _bow(), CombatState.pack_charges(3, 2))
		d.step(case[0])
		assert_eq(d.c.action, case[1], case[4])
		if case[2] >= 0:
			assert_eq(d.c.action_id, case[2], "%s: the one that wins" % case[4])
		assert_eq(d.c.buffered_type(), case[3], "%s: the other stays in the buffer" % case[4])


func test_an_ability_pressed_in_a_light_is_buffered_until_its_recovery() -> void:
	var d := _sword_driver()
	d.step(PRIMARY)
	var p: int = d.tick
	d.idle_until_before(p + 13)
	d.step(ABILITY_1)
	assert_eq(d.c.action, Action.LIGHT, "it does not start during the active hit")
	assert_eq(d.c.buffered_type(), CombatState.BUFFER_ABILITY_1, "goes to the buffer")
	d.idle_until_before(p + 18)
	assert_eq(d.c.action, Action.LIGHT, "waits")
	d.step()
	assert_eq(d.c.action, Action.ABILITY, "comes out in the light attack's recovery")
	assert_eq(d.c.action_tick, p + 18, "on its first tick")
	assert_eq(d.c.combo_step, 0, "with the combo at 0")
	# From the recovery of an ability the light attack comes out.
	d.idle_until_before(p + 18 + 23)
	d.step(PRIMARY)
	assert_eq(d.c.action, Action.ABILITY, "not during the ability's active phase")
	assert_eq(d.c.buffered_type(), CombatState.BUFFER_PRIMARY, "to the buffer")
	d.idle_until_before(p + 18 + 24 + 1)
	assert_eq(d.c.action, Action.LIGHT, "during its recovery, yes")


func test_an_ability_press_that_expires_after_the_light_restarts_the_combo() -> void:
	var d := _sword_driver()
	d.step(PRIMARY)
	var p: int = d.tick
	d.idle_until_before(p + 30)
	d.step(PRIMARY)
	assert_eq(d.c.buffered_type(), CombatState.BUFFER_LINK, "second light attack link")
	# The light attack ends in the air: the link does not come out and becomes a stored press.
	d.grounded = false
	d.idle_until_before(p + 37)
	assert_eq(d.c.action, Action.NONE, "the light attack ended")
	assert_eq(d.c.combo_step, 1, "the combo stays half done")
	# An ability (which cannot come out in the air) replaces the press and expires.
	d.step(ABILITY_1)
	assert_eq(d.c.buffered_type(), CombatState.BUFFER_ABILITY_1, "the ability takes up the buffer")
	d.hold(0, 8)
	assert_eq(d.c.buffered, 0, "and expires")
	assert_eq(d.c.combo_step, 0, "leaving the combo at 0")
	assert_eq(d.c.action, Action.NONE, "without starting anything")


func test_substituted_inputs_start_nothing() -> void:
	# The substitute repeats the buttons of the last applied input (docs/combate.md, section 3.2): a
	# lost single-tick tap does not invent anything.
	var d := MachineDriver.new(_sword(), _bow(), CombatState.pack_charges(3, 2))
	d.hold(0, 3)
	d.step(0, true)
	d.step(0)
	assert_eq(d.c.action, Action.NONE, "the lost tap starts nothing")
	assert_eq(d.c.buffered, 0, "nor leaves anything stored")
	# Holding the button with substitutes does not create new edges: a single weapon swap.
	d.step(SWAP)
	assert_eq(d.c.action, Action.SWAP, "the real edge swaps weapon")
	d.hold(SWAP, 40, true)
	assert_eq(d.c.action, Action.NONE, "the swap ended")
	assert_eq(d.c.weapon_id, _bow(), "and was not repeated with the substitutes")
	d.step(SWAP)
	assert_eq(d.c.weapon_id, _bow(), "nor with the real one that is still held")
	# Same with a potion: a single charge.
	d.hold(0, 2)
	d.step(CONSUMABLE_1)
	d.hold(CONSUMABLE_1, 60, true)
	assert_eq(d.c.charges_of(0), 2, "a single charge spent")
	assert_eq(d.c.action, Action.NONE, "and no drinking again")


# --- Cancellations, ground and actions that allow it -------------------------------------------

func test_dodge_cancels_an_ability_only_from_its_cancel_point() -> void:
	var bash: AbilityTicks = _ability(&"shield_bash")
	assert_eq(bash.cancel_to_dodge_from_ticks, 24, "to dodge from recovery")
	var d := _sword_driver()
	d.step(ABILITY_1)
	var p: int = d.tick
	d.idle_until_before(p + 20)
	d.step(DODGE)
	assert_eq(d.c.action, Action.ABILITY, "no dodging during the active phase")
	assert_eq(d.c.buffered_type(), CombatState.BUFFER_DODGE, "goes to the buffer")
	d.idle_until_before(p + 25)
	assert_eq(d.c.action, Action.DODGE, "comes out in the recovery")
	assert_eq(d.c.action_tick, p + 24, "on its first tick")
	assert_eq(d.c.ability_ready[0], p + 18 + 720, "the cooldown was already set")


func test_abilities_need_the_ground_and_an_action_that_allows_them() -> void:
	# In the air, to the buffer; on touching the ground, it comes out.
	var air := _sword_driver()
	air.grounded = false
	air.step(ABILITY_1)
	assert_eq(air.c.action, Action.NONE, "it does not start in the air")
	assert_eq(air.c.buffered_type(), CombatState.BUFFER_ABILITY_1, "goes to the buffer")
	air.grounded = true
	air.step()
	assert_eq(air.c.action, Action.ABILITY, "on landing it comes out")
	# From the charge: it cancels it without spending.
	var charge := _sword_driver()
	charge.hold(PRIMARY, 8)
	assert_eq(charge.c.action, Action.CHARGE, "charging")
	charge.step(PRIMARY | ABILITY_2)
	assert_eq(charge.c.action, Action.ABILITY, "the ability cancels the charge")
	assert_eq(charge.c.stamina, 1000, "without spending the heavy attack")
	# From the block, and when it ends it blocks again if held.
	var block := _sword_driver()
	block.hold(BLOCK, 3)
	block.step(BLOCK | ABILITY_1)
	assert_eq(block.c.action, Action.ABILITY, "from the block")
	block.hold(BLOCK, 48)
	assert_eq(block.c.action, Action.BLOCK, "when it ends, the block as a level")
	# During the windup of a light attack, to the buffer.
	var light := _sword_driver()
	light.step(PRIMARY)
	light.step(ABILITY_1)
	assert_eq(light.c.action, Action.LIGHT, "it does not cut the windup")
	# From a stun, nothing (and the buffer expires).
	var stunned := _sword_driver()
	stunned.step()
	ActionMachine.impose_stun(stunned.c, stunned.tick, stunned.tick + 30)
	stunned.step(ABILITY_1)
	stunned.hold(0, 9)
	assert_eq(stunned.c.action, Action.STUN, "stunned")
	assert_eq(stunned.c.buffered, 0, "the press expired")


func test_an_empty_slot_drops_the_press() -> void:
	var npc_weapon: int = CombatCatalog.weapon_id(&"npc_guard")
	assert_true(npc_weapon != 0, "NPC weapon without abilities")
	var d := MachineDriver.new(npc_weapon)
	d.step(ABILITY_1)
	assert_eq(d.c.action, Action.NONE, "with no ability in the slot nothing happens")
	assert_eq(d.c.buffered, 0, "and nothing is stored")
	assert_eq(ActionMachine.ability_status(d.c, 0, d.tick), ActionMachine.AbilityStatus.EMPTY,
			"the slot is empty")


func test_exhaustion_blocks_the_wall_but_not_the_other_abilities() -> void:
	var d := _sword_driver()
	ActionMachine.drain_stamina(d.c, 5000, d.tick)
	assert_true(d.c.is_exhausted(), "exhausted")
	assert_eq(ActionMachine.ability_status(d.c, 2, d.tick), ActionMachine.AbilityStatus.BLOCKED,
			"the wall slot goes dark")
	d.step(ABILITY_3)
	assert_eq(d.c.action, Action.NONE, "exhausted, the wall is not raised")
	assert_true((d.c.combat_flags & CombatState.FLAG_NO_STAMINA) != 0, "and it notifies the interface")
	assert_eq(d.c.buffered, 0, "without storing the press")
	d.step(ABILITY_1)
	assert_eq(d.c.action, Action.ABILITY, "the shield bash does come out")


func test_no_cooldowns_flag_spends_nothing() -> void:
	var d := _sword_driver()
	d.c.combat_flags2 |= CombatState.FLAG2_NO_COOLDOWNS
	d.step(ABILITY_1)
	d.hold(0, 48)
	assert_eq(d.c.ability_ready[0], 0, "with bit 7 the cooldown is not set")
	d.step(ABILITY_1)
	assert_eq(d.c.action, Action.ABILITY, "and it can be repeated when it ends")
	d.hold(0, 60)
	d.step(ABILITY_3)
	d.hold(ABILITY_3, 30)
	d.step()
	assert_eq(d.c.ability_ready[2], 0, "nor when a channeling ends")


# --- Queries ----------------------------------------------------------------------------------

func test_queries_active_hit_status_and_defense() -> void:
	var bash: AbilityTicks = _ability(&"shield_bash")
	var d := MachineDriver.new(_sword(), _bow(), CombatState.pack_charges(3, 0))
	for slot: int in 3:
		assert_eq(ActionMachine.ability_status(d.c, slot, d.tick), ActionMachine.AbilityStatus.READY,
				"slot %d ready" % slot)
	assert_eq(ActionMachine.ability_status(d.c, ActionMachine.STATUS_SLOT_CONSUMABLE_1, d.tick),
			ActionMachine.AbilityStatus.READY, "potion 1 has charges")
	assert_eq(ActionMachine.ability_status(d.c, ActionMachine.STATUS_SLOT_CONSUMABLE_2, d.tick),
			ActionMachine.AbilityStatus.NO_CHARGES, "la 2, no")
	d.step(ABILITY_1)
	var p: int = d.tick
	assert_eq(ActionMachine.ability_status(d.c, 1, p), ActionMachine.AbilityStatus.BLOCKED,
			"during the cast the others go dark")
	for rel: int in range(0, 48):
		var hit: AttackTicks = ActionMachine.active_hit(d.c, p + rel)
		if rel >= 18 and rel < 24:
			assert_true(hit == bash.hit, "rel %d: the synthesized hit during the active phase" % rel)
		else:
			assert_null(hit, "rel %d: no hit" % rel)
	assert_eq(bash.hit.id, CombatSource.make(CombatSource.Kind.ABILITY, bash.id),
			"its id is the ability's source")
	assert_eq(ActionMachine.defense_flags(d.c, p + 20), 0, "the shield bash does not defend")
	assert_false(ActionMachine.is_attack_active(d.c, p + 20), "is_attack_active is still about attacks")
	# A light attack also has its active hit.
	var light := _sword_driver()
	light.step(PRIMARY)
	var attack: AttackTicks = CombatCatalog.attack(light.c.action_id)
	assert_true(ActionMachine.active_hit(light.c, light.tick + 12) == attack, "the attack in its active phase")
	assert_null(ActionMachine.active_hit(light.c, light.tick + 11), "not during the windup")
	assert_true(ActionMachine.is_commit_tick(light.c, light.tick + 12), "its commit")
	# The wall blocks wide during the channeling.
	var wall := _sword_driver()
	wall.step(ABILITY_3)
	var w: int = wall.tick
	wall.hold(ABILITY_3, 20)
	assert_eq(ActionMachine.defense_flags(wall.c, wall.tick),
			ActionMachine.DEFENSE_BLOCKING | ActionMachine.DEFENSE_WIDE_BLOCK, "wide block")
	assert_true(ActionMachine.is_blocking(wall.c, wall.tick), "is_blocking counts it")
	assert_false(ActionMachine.is_blocking(wall.c, w + 5), "not during the cast")
	assert_null(ActionMachine.active_hit(wall.c, wall.tick).shape, "the wall does not hit (no shape)")


func test_stamina_does_not_regenerate_in_a_blocking_channel() -> void:
	var d := _sword_driver()
	ActionMachine.drain_stamina(d.c, 500, d.tick)
	d.hold(0, 40)
	var regenerating: int = d.c.stamina
	assert_true(regenerating > 500, "regenerates after the delay (%d)" % regenerating)
	d.step(ABILITY_3)
	d.hold(ABILITY_3, 11)
	assert_eq(d.c.stamina, regenerating + 12 * 3, "during the cast it keeps regenerating")
	var channel_start: int = d.c.stamina
	d.hold(ABILITY_3, 60)
	assert_eq(d.c.stamina, channel_start, "during the blocking channeling, it does not")
	d.step()
	assert_eq(d.c.action, Action.NONE, "released")
	assert_eq(d.c.stamina, channel_start, "regeneration runs before the inputs: not yet")
	d.step()
	assert_eq(d.c.stamina, channel_start + 3, "on the next tick it regenerates again")


func test_the_rush_dash_follows_its_baked_window_and_direction() -> void:
	var rush: AbilityTicks = _ability(&"shield_rush")
	assert_eq([rush.cast_ticks, rush.active_ticks, rush.recovery_ticks], [9, 24, 21], "charge")
	assert_eq([rush.dash_from_ticks, rush.dash_to_ticks], [9, 33], "advance during the active phase")
	var total: float = 0.0
	for speed: float in rush.dash_speeds:
		total += speed / 60.0
	assert_near(total, 6.0, 1e-4, "6 m baked in")
	var d := _sword_driver()
	d.look_yaw = 0.7
	d.step(ABILITY_2)
	var p: int = d.tick
	assert_eq(d.c.action_dir, CombatState.quantize_yaw(0.7), "direction toward the camera at the start")
	d.look_yaw = -1.0
	for rel: int in range(1, 54):
		var out: ActionMachine.Output = d.step()
		if rel < 9:
			assert_false(out.forced_velocity, "rel %d: free cast" % rel)
			assert_near(out.turn_rate, 6.0, 1e-6, "rel %d: turns toward the camera" % rel)
		elif rel < 33:
			assert_true(out.forced_velocity, "rel %d: imposed advance" % rel)
			assert_eq(out.turn_rate, 0.0, "rel %d: no turning" % rel)
			var expected := Vector3(-sin(CombatState.dequantize_yaw(d.c.action_dir)), 0.0,
					-cos(CombatState.dequantize_yaw(d.c.action_dir))) * rush.dash_speed_at(rel)
			assert_vec_near(out.velocity, expected, 1e-5, "rel %d: toward the starting yaw" % rel)
		else:
			assert_false(out.forced_velocity, "rel %d: recovery without advance" % rel)
	assert_eq(d.tick, p + 53, "whole distance covered")
	# The bow's backflip goes backward from the first tick.
	var bow := MachineDriver.new(_bow())
	bow.look_yaw = 0.25
	var first: ActionMachine.Output = bow.step(ABILITY_3)
	var leap: AbilityTicks = _ability(&"bow_evasive_shot")
	assert_eq(bow.c.action_id, leap.id, "backflip with a shot")
	assert_eq(bow.c.action_dir, CombatState.quantize_yaw(0.25 + PI), "backward")
	assert_true(first.forced_velocity and first.snap_yaw, "already advances on the first tick, facing the camera")
	assert_true(first.velocity.dot(Vector3(-sin(0.25), 0.0, -cos(0.25))) < 0.0, "moving away")


# --- What the server imposes ------------------------------------------------------------------

func test_downed_only_crawls_and_does_not_end_alone() -> void:
	var slowed: int = CombatCatalog.status_id(&"slowed")
	var d := _sword_driver()
	d.step(PRIMARY)
	ActionMachine.impose_move_effect(d.c, slowed, d.tick + 500)
	d.c.buffered = CombatState.pack_buffer(CombatState.BUFFER_DODGE, 5)
	ActionMachine.impose_downed(d.c, d.tick)
	var s: int = d.tick
	assert_eq(d.c.action, Action.DOWNED, "knocked down")
	assert_eq(d.c.action_tick, s, "from that tick")
	assert_eq([d.c.buffered, d.c.primary_held, d.c.combo_step], [0, 0, 0], "no buffer, press or combo")
	assert_eq(d.c.move_effect_ids, PackedInt32Array([0, 0]), "no movement effects")
	assert_eq(ActionMachine.defense_flags(d.c, s), 0, "a knocked-down character does not defend")
	ActionMachine.impose_stagger(d.c, s, s + 30, Vector2(2.0, 0.0))
	ActionMachine.impose_stun(d.c, s, s + 30)
	assert_eq(d.c.action, Action.DOWNED, "no stagger or stun on a knocked-down character")
	var out: ActionMachine.Output = d.step(PRIMARY | DODGE | ABILITY_1 | SWAP)
	assert_eq(d.c.action, Action.DOWNED, "does not act")
	assert_eq(d.c.buffered, 0, "nor store")
	assert_true(out.scaled_movement, "crawls")
	assert_near(out.move_scale, 0.15, 1e-6, "×0,15")
	assert_near(out.turn_rate, 3.0, 1e-6, "turns at 3")
	assert_false(out.allow_jump or out.allow_sprint, "no jump or sprint")
	d.hold(0, 1500)
	assert_eq(d.c.action, Action.DOWNED, "does not end on its own")
	ActionMachine.impose_revived(d.c, d.tick)
	assert_eq(d.c.action, Action.NONE, "got up")
	assert_eq(d.c.action_tick, d.tick, "from that tick")
	var dead := _sword_driver()
	dead.step()
	ActionMachine.impose_death(dead.c, dead.tick)
	ActionMachine.impose_stun(dead.c, dead.tick, dead.tick + 30)
	assert_eq(dead.c.action, Action.DEAD, "nor on a dead character")


func test_revive_and_execute_end_by_time_by_release_or_by_dodge() -> void:
	var data: CombatTables = CombatCatalog.tables()
	assert_eq([data.revive_ticks, data.execute_ticks], [180, 60], "3 s y 1 s")
	var d := _sword_driver()
	d.step(INTERACT)
	ActionMachine.impose_interact(d.c, d.tick, Action.REVIVE)
	var s: int = d.tick
	assert_eq(d.c.action, Action.REVIVE, "getting up")
	var out: ActionMachine.Output = d.step(INTERACT)
	assert_eq(out.move_scale, 0.0, "brakes")
	assert_eq(out.turn_rate, 0.0, "no turning")
	assert_false(out.allow_jump, "nor jump")
	d.idle_until_before(s + 180, INTERACT)
	assert_eq(d.c.action, Action.REVIVE, "continues to the end")
	d.step(INTERACT)
	assert_eq(d.c.action, Action.NONE, "ends at 180 ticks")
	# Releasing INTERACT with a real input ends it; with a replaced one, it does not.
	var released := _sword_driver()
	released.step(INTERACT)
	ActionMachine.impose_interact(released.c, released.tick, Action.EXECUTE)
	var e: int = released.tick
	released.hold(0, 3, true)
	assert_eq(released.c.action, Action.EXECUTE, "finishing off even though the substitute does not carry INTERACT")
	released.step()
	assert_eq(released.c.action, Action.NONE, "the first real one without INTERACT cuts it")
	assert_eq(released.c.action_tick, e, "keeping the action_tick")
	# Finishing off lasts 60.
	var execute := _sword_driver()
	execute.step(INTERACT)
	ActionMachine.impose_interact(execute.c, execute.tick, Action.EXECUTE)
	var x: int = execute.tick
	execute.idle_until_before(x + 60, INTERACT)
	assert_eq(execute.c.action, Action.EXECUTE, "finishing off")
	execute.step(INTERACT)
	assert_eq(execute.c.action, Action.NONE, "at 60 ticks")
	# The dodge cuts it.
	var dodge := _sword_driver()
	dodge.step(INTERACT)
	ActionMachine.impose_interact(dodge.c, dodge.tick, Action.REVIVE)
	dodge.step(INTERACT | DODGE)
	assert_eq(dodge.c.action, Action.DODGE, "dodging cuts getting up")
	# Another action is not imposed this way; the interruption cuts while keeping the action_tick.
	var other := _sword_driver()
	ActionMachine.impose_interact(other.c, other.tick, Action.STUN)
	assert_eq(other.c.action, Action.NONE, "only REVIVE or EXECUTE")
	other.step(INTERACT)
	ActionMachine.impose_interact(other.c, other.tick, Action.REVIVE)
	var r: int = other.tick
	other.hold(INTERACT, 30)
	ActionMachine.impose_interrupt(other.c, other.tick)
	assert_eq(other.c.action, Action.NONE, "interrupted")
	assert_eq(other.c.action_tick, r, "keeps the action_tick of what it cuts")


# --- Utilities ---------------------------------------------------------------------------------

func _sword() -> int:
	return CombatCatalog.weapon_id(&"sword_shield")


func _bow() -> int:
	return CombatCatalog.weapon_id(&"bow")


func _ability(ability_name: StringName) -> AbilityTicks:
	return CombatCatalog.ability(CombatCatalog.ability_id(ability_name))


func _sword_driver() -> MachineDriver:
	return MachineDriver.new(_sword(), 0, CombatState.pack_charges(3, 2))


## Changes [param property] of a data resource and reloads the catalog (undone in after_each).
func _mutate(path: String, property: StringName, value: Variant) -> void:
	var resource: Resource = load(path)
	_mutations.append([resource, property, resource.get(property)])
	resource.set(property, value)
	CombatCatalog.reload()
	assert_true(CombatCatalog.tables().is_valid(), "the changed catalog is still valid: %s"
			% ", ".join(CombatCatalog.tables().errors))
