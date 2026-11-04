extends TestCase
## Tests of the action machine ([ActionMachine], docs/combate.md section 3).
## [br][br]
## The first half uses a physics-free [Driver]: it advances the machine tick by tick with scripted
## buttons and checks the exact tick of each phase, the combo, the charge, the buffer, the
## dodge cancel, the parry, stamina, replaced inputs and what the
## server imposes. The second half (from "Con física" on) moves a real [PlayerCharacter]:
## dodge distance, walls, blocking, attack advance, landing speed and
## deterministic replay (set_state in the middle of an action and same inputs = same encode()) in
## two separate physics worlds.
## [br][br]
## Sword and shield values (ticks): light 1 = 12 + 6 + 18 (combo window [27, 36)),
## light 2 = 11 + 6 + 18, light 3 = 15 + 6 + 27, heavy = 24 + 7 + 33 with charge 21..72, dodge
## = 27 (invulnerable [3, 18), attack-cancellable from 18, costs 300).

const PRIMARY: int = PlayerInput.PRIMARY
const BLOCK: int = PlayerInput.BLOCK
const DODGE: int = PlayerInput.DODGE
const Action = CombatState.Action

const CHARACTER_SCENE_PATH: String = "res://scenes/characters/player_character.tscn"
const WORLD_LAYER: int = PlayerCharacter.WORLD_COLLISION_LAYER
## First tick of the physics-free tests (far from 0 to avoid grazing negative windows).
const START_TICK: int = 1000

var _data: CombatTables
var _viewports: Array[SubViewport] = []
var _dt: float = 1.0 / 60.0


## Physics-free machine: a [CombatState] and a clock, to script inputs tick by tick.
class Driver:
	var c: CombatState
	var tick: int = START_TICK
	var grounded: bool = true
	var move: Vector2 = Vector2.ZERO
	var look_yaw: float = 0.0
	var out: ActionMachine.Output


	func _init() -> void:
		c = CombatState.initial(CombatCatalog.rules(), CombatCatalog.default_weapon_id())


	## Advances one tick with [param buttons] (and the replaced-input mark if requested) and returns
	## the allowed movement. The advanced tick is left in [member tick].
	func step(buttons: int = 0, substituted: bool = false) -> ActionMachine.Output:
		tick += 1
		var input := PlayerInput.new()
		input.tick = tick
		input.buttons = buttons | (PlayerInput.SUBSTITUTED if substituted else 0)
		input.move = move
		input.look_yaw = look_yaw
		out = ActionMachine.step(c, input, grounded)
		return out


	## Sets stamina without regeneration (which runs before each tick's inputs)
	## changing it.
	func set_stamina(value: int) -> void:
		c.stamina = value
		c.stamina_regen_tick = tick + 100000


	## [param count] consecutive ticks with the same buttons.
	func hold(buttons: int, count: int, substituted: bool = false) -> void:
		for _i: int in count:
			step(buttons, substituted)


	## Advances until the next [method step] is the one for tick [param target] (inclusive:
	## leaves the state ready for [member tick] to be [code]target - 1[/code]).
	func idle_until_before(target: int) -> void:
		while tick < target - 1:
			step()


func before_each() -> void:
	_data = CombatCatalog.tables()
	_dt = 1.0 / float(Engine.physics_ticks_per_second)


func after_each() -> void:
	for viewport: SubViewport in _viewports:
		if is_instance_valid(viewport):
			if viewport.is_inside_tree():
				viewport.get_parent().remove_child(viewport)
			viewport.free()
	_viewports.clear()
	await wait_process_frames()


# --- Light attack: phases ---------------------------------------------------------------------

func test_idle_does_nothing() -> void:
	var d := Driver.new()
	d.hold(0, 50)
	assert_eq(d.c.action, Action.NONE, "with no input there is no action")
	assert_eq(d.c.stamina, 1000, "and stamina stays full")
	assert_eq(d.c.buffered, 0, "the buffer is still empty")
	var out: ActionMachine.Output = d.step()
	assert_eq(out.move_scale, 1.0, "normal movement")
	assert_eq(out.turn_rate, -1.0, "normal turning")
	assert_true(out.allow_jump and out.allow_sprint, "jump and sprint allowed")
	assert_false(out.scaled_movement or out.forced_velocity or out.snap_yaw, "no effects")
	assert_eq(out.lunge_speed, 0.0, "no advance")


func test_light_attack_phases_at_exact_ticks() -> void:
	var d := Driver.new()
	d.hold(0, 5)
	var p: int = d.tick + 1
	var light1: AttackTicks = _data.attack(_light_id(0))
	d.step(PRIMARY)
	assert_eq(d.c.action, Action.LIGHT, "PRIMARY on the ground starts the light attack")
	assert_eq(d.c.action_id, light1.id, "the first of the combo")
	assert_eq(d.c.action_tick, p, "action_tick is the tick of the press")
	assert_eq(d.c.combo_step, 1, "combo_step points to the next one")
	assert_eq(d.c.primary_held, 1, "primary_held counts from the edge")
	for rel: int in range(0, 38):
		if rel > 0:
			d.step()
		var tick: int = p + rel
		var phase: int = ActionMachine.phase(d.c, tick)
		if rel < 12:
			assert_eq(phase, ActionMachine.PHASE_WINDUP, "rel %d: windup" % rel)
			assert_false(ActionMachine.is_attack_active(d.c, tick), "rel %d: does not hit yet" % rel)
		elif rel < 18:
			assert_eq(phase, ActionMachine.PHASE_ACTIVE, "rel %d: active hit" % rel)
			assert_true(ActionMachine.is_attack_active(d.c, tick), "rel %d: hits" % rel)
		elif rel < 36:
			assert_eq(phase, ActionMachine.PHASE_RECOVERY, "rel %d: recovery" % rel)
			assert_false(ActionMachine.is_attack_active(d.c, tick), "rel %d: no longer hits" % rel)
		if rel < 36:
			assert_eq(d.c.action, Action.LIGHT, "rel %d: the attack continues" % rel)
		else:
			assert_eq(d.c.action, Action.NONE, "rel %d: back to NONE after 36 ticks" % rel)
			assert_eq(ActionMachine.phase(d.c, tick), ActionMachine.PHASE_NONE, "no phases")
	assert_eq(d.c.combo_step, 0, "with no link, the combo starts over")
	assert_eq(d.c.stamina, 1000, "light attacks cost no stamina")


func test_light_attack_movement_per_phase() -> void:
	var d := Driver.new()
	var first: ActionMachine.Output = d.step(PRIMARY)
	assert_true(first.snap_yaw, "on the first tick the yaw snaps to the camera")
	assert_true(first.scaled_movement, "the movement is scaled")
	assert_near(first.move_scale, 0.3, 1e-9, "×0,3")
	assert_near(first.lunge_speed, 1.5, 1e-9, "1.5 m/s advance")
	assert_near(first.turn_rate, 6.0, 1e-9, "6 rad/s turn")
	assert_false(first.allow_jump, "no jumping while attacking")
	assert_false(first.allow_sprint, "nor sprinting")
	assert_false(first.forced_velocity, "the speed is not imposed: it accelerates normally")
	var second: ActionMachine.Output = d.step()
	assert_false(second.snap_yaw, "it only jumps on the first tick")
	assert_near(second.lunge_speed, 1.5, 1e-9, "the advance continues during the windup")
	d.hold(0, 15)
	var active: ActionMachine.Output = d.step()
	assert_eq(d.tick - d.c.action_tick, 17, "last tick of the active hit")
	assert_near(active.lunge_speed, 1.5, 1e-9, "and in the active hit")
	var recovery: ActionMachine.Output = d.step()
	assert_eq(d.tick - d.c.action_tick, 18, "first tick of the recovery")
	assert_eq(recovery.lunge_speed, 0.0, "during the recovery it no longer advances")
	assert_eq(recovery.turn_rate, 0.0, "nor turns")
	assert_near(recovery.move_scale, 0.3, 1e-9, "but can move at ×0.3")
	assert_false(recovery.allow_jump, "without jumping")


# --- Combo ------------------------------------------------------------------------------------

func test_three_light_combo_with_link_window() -> void:
	var d := Driver.new()
	d.hold(0, 3)
	var p1: int = d.tick + 1
	d.step(PRIMARY)
	assert_eq(d.c.action_id, _light_id(0), "light 1")
	# Press within the first attack's combo window [27, 36).
	d.hold(0, 29)
	d.step(PRIMARY)
	assert_eq(d.tick, p1 + 30, "press 30 ticks after starting")
	assert_eq(d.c.buffered_type(), CombatState.BUFFER_LINK, "stays as a link")
	for rel: int in range(31, 36):
		d.step()
		assert_eq(d.c.action_id, _light_id(0), "rel %d: the first one continues" % rel)
	d.step()
	var p2: int = p1 + 36
	assert_eq(d.tick, p2, "the second starts right when the recovery ends")
	assert_eq(d.c.action, Action.LIGHT, "light")
	assert_eq(d.c.action_id, _light_id(1), "light 2")
	assert_eq(d.c.action_tick, p2, "action_tick of the second")
	assert_eq(d.c.combo_step, 2, "the next is the third")
	assert_eq(d.c.buffered, 0, "the link was consumed")
	assert_true(d.out.snap_yaw, "the yaw snaps to the camera on a linked light attack too")

	# The second lasts 35 ticks, with window [26, 35).
	d.hold(0, 29)
	d.step(PRIMARY)
	assert_eq(d.tick, p2 + 30, "press 30 ticks after the second starts")
	d.hold(0, 4)
	assert_eq(d.c.action_id, _light_id(1), "the second continues until rel 34")
	d.step()
	var p3: int = p2 + 35
	assert_eq(d.tick, p3, "the third starts at 35 ticks")
	assert_eq(d.c.action_id, _light_id(2), "light 3")
	assert_eq(d.c.combo_step, 0, "after the third the combo starts over")

	# The third (48 ticks) has no window, but a press in its last 8 ticks waits in
	# the buffer and starts the combo again.
	d.hold(0, 44)
	d.step(PRIMARY)
	assert_eq(d.tick, p3 + 45, "press at rel 45 of the third")
	assert_eq(d.c.buffered_type(), CombatState.BUFFER_PRIMARY, "with no window, it is a normal press")
	d.hold(0, 2)
	assert_eq(d.c.action_id, _light_id(2), "rel 47: the third continues")
	d.step()
	assert_eq(d.tick, p3 + 48, "the third ends at 48 ticks")
	assert_eq(d.c.action_id, _light_id(0), "and the combo starts again with light 1")
	assert_eq(d.c.combo_step, 1, "and the next is 2")


func test_link_press_boundaries() -> void:
	# The press links from 8 ticks before the window: the first lasts 36 and its window is
	# [27, 36), so it counts from rel 19.
	for rel: int in [10, 18, 19, 20, 26, 27, 35]:
		var d := Driver.new()
		var p: int = d.tick + 1
		d.step(PRIMARY)
		d.hold(0, rel - 1)
		d.step(PRIMARY)
		d.hold(0, 35 - rel)
		assert_eq(d.tick, p + 35, "(rel %d) last tick of the first attack" % rel)
		assert_eq(d.c.action_id, _light_id(0), "(rel %d) the first continues on its last tick" % rel)
		d.step()
		var chained: bool = rel >= 19
		if chained:
			assert_eq(d.c.action_id, _light_id(1), "(rel %d) inside the window, it links 2" % rel)
		else:
			assert_eq(d.c.action, Action.NONE, "(rel %d) outside the window there is no link" % rel)
			assert_eq(d.c.combo_step, 0, "(rel %d) and the combo starts over" % rel)


func test_a_link_that_cannot_run_in_the_air_restarts_the_combo_when_the_buffer_expires() -> void:
	# C5: the light attack ends in the air with a pending link. The link cannot be executed (no
	# attacking in the air) and, when the stored press expires, the combo starts over.
	var d := Driver.new()
	var p: int = d.tick + 1
	d.step(PRIMARY)
	d.hold(0, 29)
	d.step(PRIMARY)
	assert_eq(d.tick, p + 30, "link press in the window")
	assert_eq(d.c.buffered_type(), CombatState.BUFFER_LINK, "stays as a link")
	d.hold(0, 3)
	d.grounded = false
	d.hold(0, 2)
	assert_eq(d.tick, p + 35, "last tick of the light attack")
	d.step()
	assert_eq(d.tick, p + 36, "the light attack ends")
	assert_eq(d.c.action, Action.NONE, "no action")
	assert_eq(d.c.buffered_type(), CombatState.BUFFER_PRIMARY, "the link becomes a stored press")
	assert_eq(d.c.combo_step, 1, "while the press waits, the combo continues")
	d.hold(0, 7)
	assert_eq(d.tick, p + 43, "last tick with the stored press")
	assert_eq(d.c.buffered_type(), CombatState.BUFFER_PRIMARY, "still waiting")
	assert_eq(d.c.combo_step, 1, "(continues)")
	d.step()
	assert_eq(d.c.buffered, 0, "the press expires after 8 ticks")
	assert_eq(d.c.combo_step, 0, "and the combo starts over")
	d.hold(0, 200)
	d.grounded = true
	d.step(PRIMARY)
	assert_eq(d.c.action_id, _light_id(0), "a later press starts with light 1")
	assert_eq(d.c.combo_step, 1, "with the second as the next")


func test_a_link_that_lands_within_the_buffer_still_chains() -> void:
	# C5 control: if the character lands within the 8 ticks, the link is executed.
	var d := Driver.new()
	var p: int = d.tick + 1
	d.step(PRIMARY)
	d.hold(0, 29)
	d.step(PRIMARY)
	d.hold(0, 3)
	d.grounded = false
	d.hold(0, 4)
	assert_eq(d.tick, p + 37, "one tick after the light attack ends")
	assert_eq(d.c.action, Action.NONE, "no attacking in the air")
	d.hold(0, 2)
	d.grounded = true
	d.step()
	assert_eq(d.tick, p + 40, "lands")
	assert_eq(d.c.action, Action.LIGHT, "the link is executed")
	assert_eq(d.c.action_id, _light_id(1), "with light 2")


func test_an_early_buffered_press_during_a_light_keeps_the_combo() -> void:
	# C5 control: a stored press that expires while the light attack is still in progress does not restart the combo.
	var d := Driver.new()
	d.step(PRIMARY)
	d.hold(0, 4)
	d.step(PRIMARY)
	d.hold(0, 4)
	assert_eq(d.c.buffered_type(), CombatState.BUFFER_PRIMARY, "normal stored press")
	d.hold(0, 5)
	assert_eq(d.c.buffered, 0, "expired")
	assert_eq(d.c.action, Action.LIGHT, "with light 1 still in progress")
	assert_eq(d.c.combo_step, 1, "and the combo continues where it was")


func test_press_after_the_recovery_starts_a_new_combo() -> void:
	var d := Driver.new()
	d.step(PRIMARY)
	d.hold(0, 35)
	assert_eq(d.c.action, Action.LIGHT, "the first continues on its last recovery tick")
	d.step(PRIMARY)
	assert_eq(d.c.action, Action.LIGHT, "pressing right when it ends (outside the window)...")
	assert_eq(d.c.action_id, _light_id(0), "...starts over with light 1")
	assert_eq(d.c.combo_step, 1, "with the second as the next")
	# After a few idle ticks, the same.
	var e := Driver.new()
	e.step(PRIMARY)
	e.hold(0, 40)
	assert_eq(e.c.action, Action.NONE, "(other) the first ended")
	e.step(PRIMARY)
	assert_eq(e.c.action_id, _light_id(0), "(other) after a few idle ticks, light 1")


func test_holding_primary_after_the_combo_does_not_repeat_attacks() -> void:
	# Holding the button does not chain hits: you have to release and press again.
	var d := Driver.new()
	d.step(PRIMARY)
	d.hold(PRIMARY, 7)
	assert_eq(d.c.action, Action.CHARGE, "after 8 ticks pressed it charges")
	d.hold(PRIMARY, 70)
	assert_eq(d.c.action, Action.HEAVY, "and the heavy attack is released on reaching maximum charge")
	d.hold(PRIMARY, 100)
	assert_eq(d.c.action, Action.NONE, "with the button still pressed, no other attack starts")
	assert_eq(d.c.buffered, 0, "nor is anything left in the buffer")


# --- Heavy attack charge -------------------------------------------------------------------------

func test_holding_primary_8_ticks_starts_the_charge() -> void:
	var d := Driver.new()
	d.hold(0, 4)
	var p: int = d.tick + 1
	d.step(PRIMARY)
	for held: int in range(2, 8):
		d.step(PRIMARY)
		assert_eq(d.c.action, Action.LIGHT, "with %d ticks pressed the light attack continues" % held)
		assert_eq(d.c.primary_held, held, "primary_held = %d" % held)
	var out: ActionMachine.Output = d.step(PRIMARY)
	assert_eq(d.tick, p + 7, "the eighth tick pressed")
	assert_eq(d.c.action, Action.CHARGE, "at 8 ticks pressed the charge starts")
	assert_eq(d.c.action_id, _heavy_id(), "with the heavy attack")
	assert_eq(d.c.action_tick, p, "keeps the action_tick of the press")
	assert_eq(d.c.primary_held, 8, "primary_held = 8")
	assert_true(out.snap_yaw, "the yaw snaps to the camera when the charge starts")
	assert_near(out.move_scale, 0.4, 1e-9, "while charging it moves at ×0.4")
	assert_near(out.turn_rate, 4.0, 1e-9, "and turns at 4 rad/s")
	assert_eq(out.lunge_speed, 0.0, "no advance")
	assert_false(out.allow_jump, "without jumping")
	assert_false(out.allow_sprint, "nor sprinting")
	assert_eq(d.c.stamina, 1000, "charging costs no stamina")
	assert_eq(ActionMachine.phase(d.c, d.tick), ActionMachine.PHASE_WINDUP, "the charge is phase 0")
	var next: ActionMachine.Output = d.step(PRIMARY)
	assert_false(next.snap_yaw, "and it only jumps once")


func test_a_short_press_stays_a_light_attack() -> void:
	var d := Driver.new()
	d.hold(PRIMARY, 7)
	d.step()
	assert_eq(d.c.action, Action.LIGHT, "7 ticks pressed are not enough")
	assert_eq(d.c.action_id, _light_id(0), "it is light 1")
	assert_eq(d.c.primary_held, 0, "releasing clears the press")
	d.hold(0, 40)
	assert_eq(d.c.action, Action.NONE, "and ends like a light attack")


func test_releasing_before_the_minimum_launches_at_the_minimum() -> void:
	var d := Driver.new()
	var p: int = d.tick + 1
	d.hold(PRIMARY, 10)
	assert_eq(d.c.action, Action.CHARGE, "charging")
	# Releasing with 10 ticks of charge (minimum 21): it waits.
	for rel: int in range(10, 21):
		d.step()
		assert_eq(d.tick, p + rel, "tick %d" % rel)
		assert_eq(d.c.action, Action.CHARGE, "rel %d: waits for the minimum charge" % rel)
		assert_eq(d.c.primary_held, 0, "rel %d: the press is no longer alive" % rel)
	d.step()
	assert_eq(d.tick, p + 21, "it is released on reaching charge_min")
	assert_eq(d.c.action, Action.HEAVY, "HEAVY")
	assert_eq(d.c.action_id, _heavy_id(), "heavy")
	assert_eq(d.c.action_tick, p + 21, "the windup starts on release")
	assert_eq(d.c.charge_ticks, 21, "21-tick charge")
	assert_eq(d.c.stamina, 850, "the heavy attack costs 150")
	assert_eq(d.c.stamina_regen_tick, p + 21 + 36, "and delays regeneration 0.6 s")
	assert_true(d.out.snap_yaw, "the yaw snaps to the camera on release")
	assert_true(ActionMachine.phase(d.c, d.tick) == ActionMachine.PHASE_WINDUP, "the windup starts")


func test_releasing_after_the_minimum_launches_at_once() -> void:
	var d := Driver.new()
	var p: int = d.tick + 1
	d.hold(PRIMARY, 30)
	assert_eq(d.c.action, Action.CHARGE, "charging 30 ticks")
	d.step()
	assert_eq(d.tick, p + 30, "on release")
	assert_eq(d.c.action, Action.HEAVY, "it is released right away")
	assert_eq(d.c.charge_ticks, 30, "with 30 ticks of charge")
	assert_eq(d.c.action_tick, p + 30, "action_tick = tick of the release")


func test_heavy_attack_phases_at_exact_ticks() -> void:
	var d := Driver.new()
	d.hold(PRIMARY, 25)
	d.step()
	var launch: int = d.tick
	assert_eq(d.c.action, Action.HEAVY, "released")
	for rel: int in range(1, 66):
		var out: ActionMachine.Output = d.step()
		var tick: int = launch + rel
		if rel < 24:
			assert_eq(ActionMachine.phase(d.c, tick), ActionMachine.PHASE_WINDUP, "rel %d" % rel)
			assert_near(out.lunge_speed, 2.5, 1e-9, "rel %d: advances at 2.5 m/s" % rel)
		elif rel < 31:
			assert_eq(ActionMachine.phase(d.c, tick), ActionMachine.PHASE_ACTIVE, "rel %d" % rel)
			assert_true(ActionMachine.is_attack_active(d.c, tick), "rel %d: hits" % rel)
		elif rel < 64:
			assert_eq(ActionMachine.phase(d.c, tick), ActionMachine.PHASE_RECOVERY, "rel %d" % rel)
			assert_eq(out.lunge_speed, 0.0, "rel %d: no advance" % rel)
		if rel < 64:
			assert_eq(d.c.action, Action.HEAVY, "rel %d: the heavy attack continues" % rel)
		else:
			assert_eq(d.c.action, Action.NONE, "rel %d: ended at 64 ticks" % rel)
	assert_near(d.c.stamina, 850.0 + 3.0 * (66 - 36), 0.5, "after the delay it regenerates 3 per tick again")


func test_charge_launches_automatically_at_the_maximum() -> void:
	var d := Driver.new()
	var p: int = d.tick + 1
	d.hold(PRIMARY, 72)
	assert_eq(d.tick, p + 71, "71 ticks since the press")
	assert_eq(d.c.action, Action.CHARGE, "still charging on tick 71")
	d.step(PRIMARY)
	assert_eq(d.tick, p + 72, "tick 72")
	assert_eq(d.c.action, Action.HEAVY, "maximum charge: automatic release")
	assert_eq(d.c.charge_ticks, 72, "with the maximum charge")
	assert_eq(d.c.action_tick, p + 72, "action_tick = the release")
	assert_eq(d.c.stamina, 850, "spends 150")


func test_charge_does_not_regenerate_stamina() -> void:
	var d := Driver.new()
	ActionMachine.drain_stamina(d.c, 400, d.tick)
	assert_eq(d.c.stamina, 600, "after spending 400")
	d.hold(0, 40)
	var regenerated: int = d.c.stamina
	assert_true(regenerated > 600, "outside the charge it regenerates (%d)" % regenerated)
	d.hold(PRIMARY, 8)
	assert_eq(d.c.action, Action.CHARGE, "charging")
	var charging: int = d.c.stamina
	assert_true(charging > regenerated, "while it was a light attack it did regenerate")
	d.hold(PRIMARY, 30)
	assert_eq(d.c.action, Action.CHARGE, "still charging")
	assert_eq(d.c.stamina, charging, "charging does not regenerate")


# --- Replaced inputs ---------------------------------------------------------------------

func test_substituted_inputs_do_not_turn_a_light_attack_into_a_charge() -> void:
	var d := Driver.new()
	d.step(PRIMARY)
	d.hold(PRIMARY, 10, true)
	assert_eq(d.c.action, Action.LIGHT, "with repeated inputs, the light attack continues")
	assert_eq(d.c.primary_held, 1, "replaced inputs do not add to primary_held")
	d.hold(PRIMARY, 30, true)
	assert_eq(d.c.action, Action.NONE, "the light attack ends (36 ticks)")
	assert_eq(d.c.buffered, 0, "with nothing pending")
	# A real input afterward sees no edge (the button is still pressed) and does not count 8 at once.
	d.step(PRIMARY)
	assert_eq(d.c.action, Action.NONE, "there is no new edge")


func test_substituted_inputs_freeze_the_charge() -> void:
	var d := Driver.new()
	d.hold(PRIMARY, 8)
	assert_eq(d.c.action, Action.CHARGE, "charging")
	assert_eq(d.c.primary_held, 8, "eight real ticks")
	# Up to the maximum charge plus the input buffer (72 + 8 = 80 ticks since the press: 72 replaced
	# ticks after the 8 real ones) the charge freezes: the repeated ones do not release on reaching the maximum.
	d.hold(PRIMARY, 72, true)
	assert_eq(d.c.action, Action.CHARGE, "72 ticks of repeated inputs: does not release on reaching the maximum")
	assert_eq(d.c.primary_held, 8, "primary_held frozen")
	assert_eq(d.c.charge_ticks, 0, "and nothing has been released")
	assert_eq(d.c.stamina, 1000, "nor has any stamina been spent")
	# The first real input releases at maximum charge (no more).
	d.step(PRIMARY)
	assert_eq(d.c.action, Action.HEAVY, "with a real input, it releases")
	assert_eq(d.c.charge_ticks, 72, "with the maximum charge")


func test_a_silent_client_cannot_keep_a_charged_heavy_attack_ready() -> void:
	# R2: past the maximum charge plus the input buffer, replaced inputs cancel the charge
	# (without releasing or spending stamina); the first real input after the silence finds nothing.
	var margin: int = CombatCatalog.rules().input_buffer_ticks
	var max_charge: int = _data.attack(_heavy_id()).charge_max_ticks
	for release: bool in [false, true]:
		var d := Driver.new()
		var p: int = d.tick + 1
		d.hold(PRIMARY, 10)
		assert_eq(d.c.action, Action.CHARGE, "charging")
		while d.tick < p + max_charge + margin - 1:
			d.step(PRIMARY, true)
			assert_eq(d.c.action, Action.CHARGE, "tick p+%d: the charge freezes" % (d.tick - p))
		assert_eq(d.tick, p + max_charge + margin - 1, "last frozen tick")
		d.step(PRIMARY, true)
		assert_eq(d.c.action, Action.NONE, "(release %s) past the margin, the charge is cancelled" % release)
		assert_eq(d.c.stamina, 1000, "without spending stamina")
		assert_eq(d.c.charge_ticks, 0, "nor leaving any charge")
		d.hold(PRIMARY, 600, true)
		assert_eq(d.c.action, Action.NONE, "the silence does not charge again")
		d.step(0 if release else PRIMARY)
		assert_eq(d.c.action, Action.NONE, "(release %s) the first real input releases nothing" % release)
		assert_eq(d.c.stamina, 1000, "and stamina stays full")
		d.hold(0 if release else PRIMARY, 100)
		assert_eq(d.c.action, Action.NONE, "nor afterward")
	# With a gap shorter than the margin, the first real input does release the heavy attack at maximum charge.
	var e := Driver.new()
	e.hold(PRIMARY, 10)
	e.hold(PRIMARY, max_charge + margin - 11, true)
	assert_eq(e.c.action, Action.CHARGE, "(short gap) still frozen")
	e.step(PRIMARY)
	assert_eq(e.c.action, Action.HEAVY, "(short gap) the real input releases")
	assert_eq(e.c.charge_ticks, max_charge, "with the maximum charge")


func test_substituted_inputs_still_launch_after_a_real_release() -> void:
	# Releasing is a real decision: if the release falls on a replaced tick, it still happens.
	var d := Driver.new()
	d.hold(PRIMARY, 10)
	d.step()
	assert_eq(d.c.primary_held, 0, "released with a real input")
	d.hold(0, 20, true)
	assert_eq(d.c.action, Action.HEAVY, "the heavy attack goes out at 21 ticks even if repeated inputs arrive")


func test_substituted_inputs_do_not_open_parry_windows() -> void:
	var d := Driver.new()
	d.step(0, true)
	d.step(BLOCK, true)
	assert_eq(d.c.action, Action.BLOCK, "the block does start")
	assert_eq(d.c.parry_ready_tick, 0, "but it opens no parry window and sets no cooldown")
	assert_false(ActionMachine.is_parry_window(d.c, d.tick), "no parry window")
	# With an equivalent real input it does open.
	var e := Driver.new()
	e.step(0)
	e.step(BLOCK)
	assert_true(ActionMachine.is_parry_window(e.c, e.tick), "with a real input, parry window")


func test_a_substituted_input_during_the_press_only_delays_the_charge() -> void:
	# C1: a single replaced input between ticks p+1 and p+7 of the press delays the charge by one
	# tick (primary_held counts only real ticks), but does not cancel it forever.
	for lost: int in range(1, 8):
		var d := Driver.new()
		d.hold(0, 4)
		var p: int = d.tick + 1
		d.step(PRIMARY)
		for rel: int in range(1, 8):
			d.step(PRIMARY, rel == lost)
		assert_eq(d.tick, p + 7, "(lost at p+%d) tick p+7" % lost)
		assert_eq(d.c.action, Action.LIGHT, "(lost at p+%d) not yet 8 real ticks" % lost)
		assert_eq(d.c.primary_held, 7, "(lost at p+%d) seven real ticks" % lost)
		var out: ActionMachine.Output = d.step(PRIMARY)
		assert_eq(d.tick, p + 8, "(lost at p+%d) tick p+8" % lost)
		assert_eq(d.c.action, Action.CHARGE, "(lost at p+%d) one tick later, charge" % lost)
		assert_eq(d.c.primary_held, 8, "(lost at p+%d) eight real ticks" % lost)
		assert_eq(d.c.action_tick, p, "(lost at p+%d) keeps the action_tick" % lost)
		assert_true(out.snap_yaw, "(lost at p+%d) the yaw snaps when the charge starts" % lost)
		d.hold(PRIMARY, 22)
		d.step()
		assert_eq(d.c.action, Action.HEAVY, "(lost at p+%d) on release the heavy attack goes out" % lost)
		assert_eq(d.c.charge_ticks, 31, "(lost at p+%d) with the charge since the press" % lost)
		assert_eq(d.c.stamina, 850, "(lost at p+%d) and it spends 150" % lost)


func test_substituted_inputs_after_the_charge_started_change_nothing() -> void:
	# Losing an input once the charge has started does not undo it (C1 control).
	var d := Driver.new()
	d.hold(PRIMARY, 8)
	assert_eq(d.c.action, Action.CHARGE, "charging")
	d.step(PRIMARY, true)
	d.step(PRIMARY)
	assert_eq(d.c.action, Action.CHARGE, "the charge continues")
	assert_eq(d.c.primary_held, 9, "and only real ticks count")


func test_a_new_press_during_another_lights_windup_still_does_not_charge_it() -> void:
	# C1 must not break the §3.3 rule: a press that arrives with another light attack already underway does not
	# convert it, even with replaced inputs in between.
	for lost: int in [-1, 4, 6]:
		var d := Driver.new()
		var p: int = d.tick + 1
		d.step(PRIMARY)
		d.hold(0, 3)
		var second: int = d.tick + 1
		d.step(PRIMARY)
		assert_eq(second, p + 4, "second press at p+4, with the light attack in its windup")
		for rel: int in range(1, 10):
			d.step(PRIMARY, rel == lost)
		assert_ne_int(d.c.action, Action.CHARGE,
				"(lost %d) the new press does not convert the other's light attack" % lost)


func test_a_press_held_across_a_buffer_still_converts_the_light_it_starts() -> void:
	# A press in the air (to the buffer) held until landing: the light attack that starts on landing
	# belongs to that press and becomes a charge (C1 control).
	var d := Driver.new()
	d.grounded = false
	var p: int = d.tick + 1
	d.step(PRIMARY)
	assert_eq(d.c.action, Action.NONE, "no attacking in the air")
	assert_eq(d.c.buffered_type(), CombatState.BUFFER_PRIMARY, "stays in the buffer")
	d.hold(PRIMARY, 2)
	d.grounded = true
	d.step(PRIMARY)
	assert_eq(d.c.action, Action.LIGHT, "on landing the light attack starts")
	assert_eq(d.c.action_tick, p + 3, "on the landing tick")
	d.hold(PRIMARY, 4)
	assert_eq(d.c.primary_held, 8, "eight real ticks of press")
	assert_eq(d.c.action, Action.CHARGE, "and the press's light attack converts")


func test_substituted_bit_is_not_a_button() -> void:
	var d := Driver.new()
	d.step(PlayerInput.SUBSTITUTED, true)
	assert_eq(d.c.action, Action.NONE, "the bit alone does nothing")
	assert_eq(d.c.combat_flags & (CombatState.FLAG_DODGE_HELD | CombatState.FLAG_BLOCK_HELD
			| CombatState.FLAG_PRIMARY_HELD), 0, "nor does it count as a pressed button")
	assert_eq(PlayerInput.SUBSTITUTED & NetProtocol.VALID_BUTTONS, 0,
			"outside the valid buttons: the server discards it from what the client sends")


# --- Buffer ------------------------------------------------------------------------------------

func test_primary_buffer_holds_for_8_ticks() -> void:
	# During the dodge one can only attack from tick 18.
	for press_at: int in [9, 10, 17]:
		var d := Driver.new()
		var start: int = d.tick + 1
		d.step(DODGE)
		d.hold(0, press_at - 1)
		d.step(PRIMARY)
		assert_eq(d.tick, start + press_at, "(%d) press" % press_at)
		assert_eq(d.c.action, Action.DODGE, "(%d) cannot attack yet" % press_at)
		assert_eq(d.c.buffered_type(), CombatState.BUFFER_PRIMARY, "(%d) goes to the buffer" % press_at)
		d.idle_until_before(start + 18)
		d.step()
		if press_at >= 10:
			assert_eq(d.c.action, Action.LIGHT, "(%d) the buffer executes the attack when possible" % press_at)
			assert_eq(d.c.action_tick, start + 18, "(%d) on the first tick it is possible" % press_at)
			assert_eq(d.c.buffered, 0, "(%d) and it empties" % press_at)
		else:
			assert_eq(d.c.action, Action.DODGE, "(%d) 9 ticks of waiting are too many" % press_at)
			assert_eq(d.c.buffered, 0, "(%d) the buffer expired" % press_at)


func test_buffered_press_has_priority_over_new_inputs() -> void:
	# A stored attack comes out before a new dodge on the same tick.
	var d := Driver.new()
	var start: int = d.tick + 1
	d.step(DODGE)
	d.hold(0, 9)
	d.step(PRIMARY)
	d.idle_until_before(start + 18)
	d.step(DODGE)
	assert_eq(d.c.action, Action.LIGHT, "the stored attack executes first")
	assert_eq(d.c.buffered_type(), CombatState.BUFFER_DODGE, "and the new dodge waits in the buffer")


func test_a_newer_press_replaces_the_buffered_one() -> void:
	var d := Driver.new()
	d.step(DODGE)
	d.step(PRIMARY)
	assert_eq(d.c.buffered_type(), CombatState.BUFFER_PRIMARY, "PRIMARY in the buffer")
	d.step()
	d.step(DODGE)
	assert_eq(d.c.buffered_type(), CombatState.BUFFER_DODGE, "the latest press replaces the previous one")
	assert_eq(d.c.buffered_ticks(), 8, "with its 8 ticks")


func test_no_attack_or_dodge_in_the_air() -> void:
	var d := Driver.new()
	d.grounded = false
	d.step(PRIMARY)
	assert_eq(d.c.action, Action.NONE, "no attacking in the air")
	assert_eq(d.c.buffered_type(), CombatState.BUFFER_PRIMARY, "the press waits in the buffer")
	d.step(0)
	d.step(DODGE)
	assert_eq(d.c.action, Action.NONE, "no dodging in the air")
	assert_eq(d.c.buffered_type(), CombatState.BUFFER_DODGE, "the dodge waits in the buffer")
	d.step()
	d.step(BLOCK)
	assert_eq(d.c.action, Action.NONE, "nor blocking in the air")
	# On landing in time, what was stored is executed.
	d.grounded = true
	d.step(BLOCK)
	assert_eq(d.c.action, Action.DODGE, "on landing, the stored dodge comes out")
	assert_eq(d.c.stamina, 700, "and costs 300")
	assert_eq(d.c.parry_ready_tick, 0, "(the block that was being held opened no window)")

	# If it does not land in time, it expires.
	var e := Driver.new()
	e.grounded = false
	e.step(PRIMARY)
	e.hold(0, 9)
	e.grounded = true
	e.step()
	assert_eq(e.c.action, Action.NONE, "after 9 ticks in the air, the press expired")


func test_blocking_is_cancelled_when_leaving_the_ground() -> void:
	var d := Driver.new()
	d.step(BLOCK)
	assert_eq(d.c.action, Action.BLOCK, "blocking")
	var ready: int = d.c.parry_ready_tick
	d.grounded = false
	d.step(BLOCK)
	assert_eq(d.c.action, Action.NONE, "jumping or falling drops the block")
	d.grounded = true
	d.step(BLOCK)
	assert_eq(d.c.action, Action.BLOCK, "and on landing with the button held, it blocks again")
	assert_eq(d.c.parry_ready_tick, ready, "with no new parry, because it is not an edge")
	assert_false(ActionMachine.is_parry_window(d.c, d.tick), "nor a window")


# --- Dodge cancel --------------------------------------------------------------------

func test_dodge_cancels_an_attack_only_from_the_cancel_point() -> void:
	# The first light attack can be cancelled into a dodge from rel 24. The press lasts 8 ticks.
	for press_rel: int in [5, 15, 16, 23, 24, 30]:
		var d := Driver.new()
		var p: int = d.tick + 1
		d.step(PRIMARY)
		d.hold(0, press_rel - 1)
		d.step(DODGE)
		assert_eq(d.tick, p + press_rel, "(%d) dodge press" % press_rel)
		if press_rel >= 24:
			assert_eq(d.c.action, Action.DODGE, "(%d) from tick 24 it cancels instantly" % press_rel)
			assert_eq(d.c.action_tick, p + press_rel, "(%d) action_tick" % press_rel)
			continue
		assert_eq(d.c.action, Action.LIGHT, "(%d) before tick 24 the attack continues" % press_rel)
		d.idle_until_before(p + 24)
		d.step()
		if press_rel >= 16:
			assert_eq(d.c.action, Action.DODGE, "(%d) the stored press cancels on tick 24" % press_rel)
			assert_eq(d.c.action_tick, p + 24, "(%d) right at the cancel point" % press_rel)
			assert_eq(d.c.stamina, 700, "(%d) and it spends 300" % press_rel)
		else:
			assert_eq(d.c.action, Action.LIGHT, "(%d) the press expired earlier" % press_rel)
			assert_eq(d.c.stamina, 1000, "(%d) no cost" % press_rel)


func test_dodge_cancels_a_charge_and_a_block() -> void:
	var d := Driver.new()
	d.hold(PRIMARY, 12)
	assert_eq(d.c.action, Action.CHARGE, "charging")
	d.step(DODGE)
	assert_eq(d.c.action, Action.DODGE, "one can dodge while charging")
	assert_eq(d.c.stamina, 700, "only the dodge is paid")
	var e := Driver.new()
	e.step(BLOCK)
	e.step(BLOCK | DODGE)
	assert_eq(e.c.action, Action.DODGE, "and while blocking")


func test_attack_cancels_the_dodge_only_from_the_cancel_point() -> void:
	var d := Driver.new()
	var start: int = d.tick + 1
	d.step(DODGE)
	d.idle_until_before(start + 17)
	d.step(PRIMARY)
	assert_eq(d.tick, start + 17, "press on tick 17")
	assert_eq(d.c.action, Action.DODGE, "the dodge continues")
	d.step()
	assert_eq(d.tick, start + 18, "tick 18")
	assert_eq(d.c.action, Action.LIGHT, "it can be cancelled into an attack from tick 18")
	assert_eq(d.c.action_tick, start + 18, "the attack starts there")
	assert_eq(d.c.combo_step, 1, "it is light 1")
	# Directly on tick 18 too.
	var e := Driver.new()
	var s2: int = e.tick + 1
	e.step(DODGE)
	e.idle_until_before(s2 + 18)
	e.step(PRIMARY)
	assert_eq(e.c.action, Action.LIGHT, "pressing right on tick 18 attacks instantly")


# --- Dodge ----------------------------------------------------------------------------------

func test_dodge_phases_cost_and_invulnerability() -> void:
	var d := Driver.new()
	d.hold(0, 3)
	var start: int = d.tick + 1
	d.step(DODGE)
	assert_eq(d.c.action, Action.DODGE, "dodge")
	assert_eq(d.c.action_tick, start, "action_tick")
	assert_eq(d.c.action_id, 0, "the dodge is not an attack")
	assert_eq(d.c.stamina, 700, "costs 300")
	assert_eq(d.c.stamina_regen_tick, start + 36, "and delays regeneration 36 ticks")
	for rel: int in range(0, 29):
		if rel > 0:
			d.step()
		var tick: int = start + rel
		var invulnerable: bool = rel >= 3 and rel < 18
		if rel < 27:
			assert_eq(d.c.action, Action.DODGE, "rel %d: dodging" % rel)
			assert_eq(ActionMachine.is_invulnerable(d.c, tick), invulnerable,
					"rel %d: invulnerable = %s" % [rel, invulnerable])
			assert_eq((ActionMachine.defense_flags(d.c, tick) & ActionMachine.DEFENSE_INVULNERABLE) != 0,
					invulnerable, "rel %d: invulnerability flag" % rel)
			assert_false(d.out.allow_jump or d.out.allow_sprint, "rel %d: no jump or sprint" % rel)
		else:
			assert_eq(d.c.action, Action.NONE, "rel %d: ended at 27 ticks" % rel)
			assert_false(ActionMachine.is_invulnerable(d.c, tick), "rel %d: no longer" % rel)


func test_dodge_direction_is_relative_to_the_camera_and_saved() -> void:
	var cases: Array = [
		# [move, look_yaw, expected movement yaw, description]
		[Vector2(0.0, 1.0), 0.0, 0.0, "adelante"],
		[Vector2(1.0, 0.0), 0.0, -PI / 2.0, "a la derecha"],
		[Vector2(-1.0, 0.0), 0.0, PI / 2.0, "a la izquierda"],
		[Vector2(0.0, -1.0), 0.0, PI, "hacia atrás"],
		[Vector2.ZERO, 0.0, PI, "sin entrada: hacia atrás"],
		[Vector2(0.0, 1.0), 1.0, 1.0, "adelante con la cámara girada"],
		[Vector2(0.0, 0.0), 2.0, 2.0 + PI, "sin entrada con la cámara girada"],
		[Vector2(0.05, 0.05), 0.0, PI, "una entrada mínima cuenta como ninguna"],
		[Vector2(1.0, 1.0).normalized(), 0.5, 0.5 - PI / 4.0, "en diagonal"],
	]
	for case: Array in cases:
		var d := Driver.new()
		d.move = case[0]
		d.look_yaw = case[1]
		d.step(DODGE)
		assert_eq(d.c.action, Action.DODGE, "%s: dodge" % case[3])
		var expected_steps: int = CombatState.quantize_yaw(case[2])
		assert_eq(d.c.action_dir, expected_steps, "%s: action_dir" % case[3])
		# Changing the input afterward does not change the stored direction.
		var first_velocity: Vector3 = d.out.velocity
		assert_true(first_velocity.length() > 5.0, "%s: imposed initial velocity" % case[3])
		d.move = Vector2(-1.0, 0.0)
		d.look_yaw = 3.0
		d.step()
		assert_eq(d.c.action_dir, expected_steps, "%s: the direction does not change" % case[3])
		assert_near(d.out.velocity.normalized().dot(first_velocity.normalized()), 1.0, 1e-6,
				"%s: continues in the same direction" % case[3])
	# Specific orientation: forward is -Z and right is +X when looking toward -Z.
	var forward := Driver.new()
	forward.move = Vector2(0.0, 1.0)
	assert_vec_near(forward.step(DODGE).velocity.normalized(), Vector3(0.0, 0.0, -1.0), 1e-4,
			"forward = -Z")
	var right := Driver.new()
	right.move = Vector2(1.0, 0.0)
	assert_vec_near(right.step(DODGE).velocity.normalized(), Vector3(1.0, 0.0, 0.0), 1e-4,
			"right = +X")


func test_dodge_velocity_follows_the_baked_curve() -> void:
	var d := Driver.new()
	d.move = Vector2(0.0, 1.0)
	var curve: PackedFloat32Array = _data.weapon(_data.weapon_ids[&"sword_shield"]).dodge.speeds
	var start: int = d.tick + 1
	for rel: int in 27:
		var out: ActionMachine.Output = d.step(DODGE if rel == 0 else 0)
		assert_true(out.forced_velocity, "rel %d: imposed velocity" % rel)
		assert_near(out.velocity.length(), curve[rel], 1e-4, "rel %d: velocity along the curve" % rel)
		assert_eq(out.velocity.y, 0.0, "rel %d: horizontal" % rel)
		assert_eq(out.turn_rate, 0.0, "rel %d: the body keeps its yaw" % rel)
	assert_eq(d.tick, start + 26, "last tick")
	assert_false(d.step().forced_velocity, "after the dodge nothing is imposed anymore")


func test_dodge_needs_stamina_and_does_not_work_exhausted() -> void:
	var d := Driver.new()
	d.set_stamina(299)
	var out: ActionMachine.Output = d.step(DODGE)
	assert_eq(d.c.action, Action.NONE, "with 299 stamina there is no dodge")
	assert_true((d.c.combat_flags & CombatState.FLAG_NO_STAMINA) != 0, "the interface is notified")
	assert_eq(d.c.buffered, 0, "and the press is not stored")
	assert_eq(out.move_scale, 1.0, "no effects")
	d.step()
	assert_eq(d.c.combat_flags & CombatState.FLAG_NO_STAMINA, 0, "the notice lasts one tick")
	var e := Driver.new()
	e.set_stamina(300)
	e.step(DODGE)
	assert_eq(e.c.action, Action.DODGE, "with 300 it does")
	assert_eq(e.c.stamina, 0, "it stays at 0")
	assert_true(e.c.is_exhausted(), "reaching 0 exhausts")


# --- Block and parry -------------------------------------------------------------------------

func test_block_enters_and_leaves_with_the_button() -> void:
	var d := Driver.new()
	d.hold(0, 3)
	var out: ActionMachine.Output = d.step(BLOCK)
	assert_eq(d.c.action, Action.BLOCK, "BLOCK pressed from NONE blocks")
	assert_true(ActionMachine.is_blocking(d.c, d.tick), "is_blocking()")
	assert_near(out.move_scale, 0.5, 1e-9, "×0.5 movement")
	assert_near(out.turn_rate, 8.0, 1e-9, "8 rad/s turn")
	assert_true(out.allow_jump, "jumping is allowed")
	assert_false(out.allow_sprint, "but not sprinting")
	assert_true(out.scaled_movement, "scaled movement")
	d.hold(BLOCK, 20)
	assert_eq(d.c.action, Action.BLOCK, "while held")
	assert_true((ActionMachine.defense_flags(d.c, d.tick) & ActionMachine.DEFENSE_BLOCKING) != 0,
			"block flag")
	d.step()
	assert_eq(d.c.action, Action.NONE, "releasing BLOCK leaves the block")
	assert_eq(ActionMachine.defense_flags(d.c, d.tick), 0, "no flags")


func test_parry_window_only_on_a_real_edge_and_with_cooldown() -> void:
	var d := Driver.new()
	d.hold(0, 5)
	var p: int = d.tick + 1
	d.step(BLOCK)
	assert_eq(d.c.parry_ready_tick, p + 30, "the cooldown ends at 30 ticks")
	for rel: int in range(0, 12):
		if rel > 0:
			d.step(BLOCK)
		var in_window: bool = rel < 6
		assert_eq(ActionMachine.is_parry_window(d.c, p + rel), in_window,
				"rel %d: parry window = %s" % [rel, in_window])
		assert_eq((ActionMachine.defense_flags(d.c, p + rel) & ActionMachine.DEFENSE_PARRY) != 0,
				in_window, "rel %d: parry flag" % rel)
	# Releasing and pressing again before the cooldown ends: it blocks but without a parry.
	d.step(0)
	assert_eq(d.c.action, Action.NONE, "released")
	d.step(BLOCK)
	assert_eq(d.c.action, Action.BLOCK, "blocks again")
	assert_false(ActionMachine.is_parry_window(d.c, d.tick), "but with no parry window (cooldown)")
	assert_eq(d.c.parry_ready_tick, p + 30, "and the cooldown does not restart")
	# After the cooldown, a new edge opens another window.
	d.step(0)
	d.idle_until_before(p + 30)
	d.step(BLOCK)
	assert_eq(d.tick, p + 30, "right when the cooldown ends")
	assert_true(ActionMachine.is_parry_window(d.c, d.tick), "another window opens")
	assert_eq(d.c.parry_ready_tick, p + 60, "and a new cooldown")


func test_a_block_that_starts_when_an_action_ends_has_no_parry_window() -> void:
	# Block held during a dodge: when it ends it enters BLOCK without an edge.
	var d := Driver.new()
	var start: int = d.tick + 1
	d.step(DODGE | BLOCK)
	assert_eq(d.c.action, Action.DODGE, "dodging")
	d.idle_until_before(start + 26)
	d.hold(BLOCK, 1)
	d.step(BLOCK)
	assert_eq(d.tick, start + 27, "when the dodge ends")
	assert_eq(d.c.action, Action.BLOCK, "it enters BLOCK")
	assert_false(ActionMachine.is_parry_window(d.c, d.tick), "without a parry window")
	assert_eq(d.c.parry_ready_tick, 0, "or cooldown")
	# And an attack with BLOCK held throughout, the same.
	var e := Driver.new()
	e.step(PRIMARY | BLOCK)
	assert_eq(e.c.action, Action.LIGHT, "the attack takes priority over the block")
	e.hold(BLOCK, 40)
	assert_eq(e.c.action, Action.BLOCK, "when the attack ends, it blocks")
	assert_eq(e.c.parry_ready_tick, 0, "without a parry")


func test_blocking_can_be_cancelled_by_an_attack() -> void:
	var d := Driver.new()
	d.step(BLOCK)
	d.hold(BLOCK, 5)
	d.step(BLOCK | PRIMARY)
	assert_eq(d.c.action, Action.LIGHT, "one can attack while blocking")
	assert_eq(ActionMachine.defense_flags(d.c, d.tick), 0, "and attacking stops protecting")


func test_block_does_not_start_while_exhausted() -> void:
	var d := Driver.new()
	ActionMachine.drain_stamina(d.c, 1000, d.tick)
	assert_true(d.c.is_exhausted(), "exhausted")
	d.hold(BLOCK, 10)
	assert_eq(d.c.action, Action.NONE, "exhausted, no blocking")


# --- Stamina ------------------------------------------------------------------------------

func test_stamina_regenerates_after_the_delay() -> void:
	var d := Driver.new()
	d.hold(0, 2)
	var x: int = d.tick
	ActionMachine.drain_stamina(d.c, 400, x)
	assert_eq(d.c.stamina, 600, "spend of 400")
	assert_eq(d.c.stamina_regen_tick, x + 36, "0.6 s delay = 36 ticks")
	for rel: int in range(1, 36):
		d.step()
		assert_eq(d.c.stamina, 600, "rel %d: still in the delay" % rel)
	d.step()
	assert_eq(d.tick, x + 36, "first regeneration tick")
	assert_eq(d.c.stamina, 603, "+3 per tick (180/s)")
	d.step()
	assert_eq(d.c.stamina, 606, "+3")
	d.hold(0, 200)
	assert_eq(d.c.stamina, 1000, "without exceeding the maximum")
	# A new spend during the delay restarts it.
	ActionMachine.drain_stamina(d.c, 100, d.tick)
	d.hold(0, 20)
	ActionMachine.drain_stamina(d.c, 100, d.tick)
	assert_eq(d.c.stamina_regen_tick, d.tick + 36, "every spend restarts the delay")


func test_stamina_does_not_regenerate_while_blocking_or_dodging() -> void:
	var d := Driver.new()
	ActionMachine.drain_stamina(d.c, 500, d.tick)
	d.hold(BLOCK, 100)
	assert_eq(d.c.action, Action.BLOCK, "blocking")
	assert_eq(d.c.stamina, 500, "blocking does not regenerate")
	d.step()
	assert_eq(d.c.stamina, 500, "(releasing: the exit tick still goes through BLOCK)")
	d.step()
	assert_eq(d.c.stamina, 503, "outside the block it regenerates again")
	# Dodging: regeneration (unlocked by hand) does not advance either.
	var e := Driver.new()
	e.step(DODGE)
	e.c.stamina_regen_tick = 0
	var before: int = e.c.stamina
	e.hold(0, 10)
	assert_eq(e.c.action, Action.DODGE, "dodging")
	assert_eq(e.c.stamina, before, "dodging does not regenerate")


func test_exhaustion_and_exit_by_threshold() -> void:
	var d := Driver.new()
	d.hold(0, 2)
	var x: int = d.tick
	ActionMachine.drain_stamina(d.c, 1000, x)
	assert_eq(d.c.stamina, 0, "a 0")
	assert_true(d.c.is_exhausted(), "exhausted on reaching 0")
	# Exhausted: no dodge or block; light attacks are allowed.
	d.step(DODGE)
	assert_eq(d.c.action, Action.NONE, "no dodge")
	assert_true((d.c.combat_flags & CombatState.FLAG_NO_STAMINA) != 0, "with a notice")
	d.step(BLOCK)
	assert_eq(d.c.action, Action.NONE, "no block")
	d.step(0)
	d.step(PRIMARY)
	assert_eq(d.c.action, Action.LIGHT, "a light attack can be done while exhausted")
	d.hold(0, 40)
	# Slow regeneration (1 per tick) from tick x + 36.
	assert_true(d.tick >= x + 36, "after the delay")
	var base_tick: int = x + 35
	assert_eq(d.c.stamina, d.tick - base_tick, "1 per tick while exhausted")
	while d.tick < x + 335:
		d.step()
	assert_eq(d.c.stamina, 300, "300 on tick x + 335")
	assert_true(d.c.is_exhausted(), "300 does not exceed the threshold")
	d.step()
	assert_eq(d.tick, x + 336, "tick x + 336")
	assert_eq(d.c.stamina, 301, "301")
	assert_false(d.c.is_exhausted(), "exceeding 300 ends the exhaustion")
	d.step()
	assert_eq(d.c.stamina, 304, "and it regenerates 3 per tick again")
	d.hold(0, 2)
	d.step(DODGE)
	assert_eq(d.c.action, Action.DODGE, "dodging is possible again")


func test_heavy_charge_needs_stamina_and_no_exhaustion() -> void:
	var d := Driver.new()
	d.set_stamina(149)
	d.hold(PRIMARY, 12)
	assert_eq(d.c.action, Action.LIGHT, "with 149 stamina it does not switch to charging")
	var e := Driver.new()
	ActionMachine.drain_stamina(e.c, 1000, e.tick)
	e.set_stamina(200)
	assert_true(e.c.is_exhausted(), "exhausted with 200")
	e.hold(PRIMARY, 12)
	assert_eq(e.c.action, Action.LIGHT, "exhausted does not charge either")
	var f := Driver.new()
	f.set_stamina(150)
	f.hold(PRIMARY, 8)
	assert_eq(f.c.action, Action.CHARGE, "with exactly 150 it does")


func test_infinite_stamina_flag_spends_nothing() -> void:
	var d := Driver.new()
	d.c.combat_flags |= CombatState.FLAG_INFINITE_STAMINA
	d.set_stamina(10)
	d.step(DODGE)
	assert_eq(d.c.action, Action.DODGE, "with infinite stamina one can always dodge")
	assert_eq(d.c.stamina, 10, "and nothing is spent")
	ActionMachine.drain_stamina(d.c, 500, d.tick)
	assert_eq(d.c.stamina, 10, "nor drain_stamina")


# --- What the server imposes ----------------------------------------------------------------

func test_impose_stagger_with_linearly_decaying_knockback() -> void:
	var d := Driver.new()
	d.hold(0, 3)
	var s: int = d.tick
	ActionMachine.impose_stagger(d.c, s, s + 30, Vector2(4.0, -2.0))
	assert_eq(d.c.action, Action.STAGGER, "stagger")
	assert_eq(d.c.action_tick, s, "action_tick")
	assert_eq(d.c.cc_until_tick, s + 30, "cc_until_tick")
	assert_eq(d.c.knockback, Vector2(4.0, -2.0), "push")
	for rel: int in range(1, 30):
		var out: ActionMachine.Output = d.step()
		assert_eq(d.c.action, Action.STAGGER, "rel %d: staggering" % rel)
		assert_true(out.forced_velocity, "rel %d: the velocity is imposed" % rel)
		var factor: float = (30.0 - rel) / 30.0
		assert_near(out.velocity.x, 4.0 * factor, 1e-5, "rel %d: x decays linearly" % rel)
		assert_near(out.velocity.z, -2.0 * factor, 1e-5, "rel %d: z decays linearly" % rel)
		assert_false(out.allow_jump or out.allow_sprint, "rel %d: no jump or sprint" % rel)
		assert_eq(out.turn_rate, 0.0, "rel %d: does not turn" % rel)
	var after: ActionMachine.Output = d.step()
	assert_eq(d.tick, s + 30, "at cc_until_tick")
	assert_eq(d.c.action, Action.NONE, "ends at cc_until_tick")
	assert_false(after.forced_velocity, "and no longer imposes anything")


func test_impose_stagger_without_knockback_just_brakes() -> void:
	var d := Driver.new()
	ActionMachine.impose_stagger(d.c, d.tick, d.tick + 20, Vector2.ZERO)
	var out: ActionMachine.Output = d.step()
	assert_false(out.forced_velocity, "with no push the velocity is not forced")
	assert_eq(out.move_scale, 0.0, "the goal is to stop")
	assert_false(out.allow_jump, "without jumping")


func test_impose_stagger_quantizes_the_knockback() -> void:
	var d := Driver.new()
	ActionMachine.impose_stagger(d.c, d.tick, d.tick + 20, Vector2(1.2349, 0.0049))
	assert_eq(d.c.knockback, Vector2(1.23, 0.0), "rounded to cm/s, as when going over the network")
	var round_trip: CombatState = _round_trip(d.c)
	assert_true(round_trip.equals(d.c), "and the state survives encode()")
	assert_eq(round_trip.knockback, d.c.knockback, "with the same exact push")


func test_impose_clears_buffer_held_and_combo() -> void:
	var d := Driver.new()
	d.step(PRIMARY)
	d.hold(0, 30)
	d.step(PRIMARY)
	assert_ne_int(d.c.combo_step, 0, "there is a combo in progress")
	assert_eq(d.c.buffered_type(), CombatState.BUFFER_LINK, "and a stored link")
	ActionMachine.impose_stagger(d.c, d.tick, d.tick + 20, Vector2.ZERO)
	assert_eq(d.c.buffered, 0, "the buffer is cleared")
	assert_eq(d.c.primary_held, 0, "the press is cleared")
	assert_eq(d.c.combo_step, 0, "and the combo")
	assert_eq(d.c.action_id, 0, "and the action stops being an attack")
	# Cutting a charge: the button is still pressed but there is no attack when the crowd control ends.
	var e := Driver.new()
	e.hold(PRIMARY, 12)
	assert_eq(e.c.action, Action.CHARGE, "charging")
	ActionMachine.impose_stagger(e.c, e.tick, e.tick + 10, Vector2.ZERO)
	e.hold(PRIMARY, 30)
	assert_eq(e.c.action, Action.NONE, "after the stagger nothing resumes or is released")
	assert_eq(e.c.stamina, 1000, "and no stamina was spent")


func test_stagger_cuts_a_light_attack() -> void:
	var d := Driver.new()
	d.step(PRIMARY)
	d.hold(0, 10)
	assert_eq(d.c.action, Action.LIGHT, "attacking")
	ActionMachine.impose_stagger(d.c, d.tick, d.tick + 18, Vector2.ZERO)
	d.hold(0, 5)
	assert_eq(d.c.action, Action.STAGGER, "the stagger cuts the hit")
	assert_false(ActionMachine.is_attack_active(d.c, d.tick), "which no longer hits")
	d.hold(0, 13)
	assert_eq(d.c.action, Action.NONE, "and when it ends it goes back to NONE")


func test_impose_stun_and_inputs_during_control() -> void:
	var d := Driver.new()
	ActionMachine.impose_stun(d.c, d.tick, d.tick + 60)
	assert_eq(d.c.action, Action.STUN, "stunned")
	assert_eq(d.c.knockback, Vector2.ZERO, "no push")
	var out: ActionMachine.Output = d.step(PRIMARY | DODGE | BLOCK)
	assert_eq(d.c.action, Action.STUN, "the inputs do nothing")
	assert_eq(out.move_scale, 0.0, "it only brakes")
	assert_false(out.forced_velocity, "no imposed velocity")
	assert_false(out.allow_jump, "without jumping")
	assert_eq(d.c.stamina, 1000, "and without spending")
	# What is pressed during the crowd control waits in the buffer for a few ticks.
	assert_ne_int(d.c.buffered, 0, "what was pressed during the crowd control stays stored")
	d.hold(0, 59)
	assert_eq(d.c.action, Action.NONE, "the stun ends at cc_until_tick")
	assert_eq(d.c.buffered, 0, "and what was stored expired")


func test_impose_death_and_respawn() -> void:
	var d := Driver.new()
	d.step(PRIMARY)
	ActionMachine.drain_stamina(d.c, 300, d.tick)
	d.c.action_dir = 777
	ActionMachine.impose_death(d.c, d.tick)
	assert_eq(d.c.action, Action.DEAD, "dead")
	assert_eq(d.c.action_id, 0, "no attack")
	assert_eq(ActionMachine.defense_flags(d.c, d.tick), ActionMachine.DEFENSE_DEAD, "dead flag")
	var out: ActionMachine.Output = d.step(PRIMARY | DODGE | BLOCK)
	assert_eq(d.c.action, Action.DEAD, "the dead do not act")
	assert_eq(d.c.buffered, 0, "nor store presses")
	assert_eq(out.move_scale, 0.0, "brakes")
	assert_false(out.allow_jump, "does not jump")
	ActionMachine.reset_for_respawn(d.c, d.tick, CombatCatalog.default_weapon_id(), 0, 0)
	assert_eq(d.c.action, Action.NONE, "respawns with no action")
	assert_eq(d.c.stamina, 1000, "with full stamina")
	assert_eq(d.c.weapon_id, CombatCatalog.default_weapon_id(), "keeps the weapon")
	assert_eq(d.c.cc_until_tick, 0, "no crowd control")
	assert_eq(d.c.knockback, Vector2.ZERO, "no push")
	assert_eq(d.c.parry_ready_tick, 0, "no parry cooldown")
	assert_false(d.c.is_exhausted(), "no exhaustion")
	# Button levels are preserved: PRIMARY|DODGE|BLOCK stay pressed, with no edges.
	d.step(PRIMARY | DODGE | BLOCK)
	assert_eq(d.c.action, Action.BLOCK, "with the buttons still pressed there are no edges: only the block as a level")
	assert_false(ActionMachine.is_parry_window(d.c, d.tick), "without a parry")


func test_drain_stamina() -> void:
	var d := Driver.new()
	ActionMachine.drain_stamina(d.c, 250, d.tick)
	assert_eq(d.c.stamina, 750, "subtracts")
	assert_eq(d.c.stamina_regen_tick, d.tick + 36, "and delays regeneration")
	assert_false(d.c.is_exhausted(), "without becoming exhausted")
	ActionMachine.drain_stamina(d.c, 5000, d.tick)
	assert_eq(d.c.stamina, 0, "never drops below 0")
	assert_true(d.c.is_exhausted(), "and at 0 it exhausts")
	var before: CombatState = d.c.duplicate_state()
	ActionMachine.drain_stamina(d.c, 0, d.tick + 5)
	ActionMachine.drain_stamina(d.c, -10, d.tick + 5)
	assert_true(d.c.equals(before), "a spend of 0 or negative does nothing")


# --- Queries --------------------------------------------------------------------------------

func test_action_byte() -> void:
	var d := Driver.new()
	assert_eq(ActionMachine.action_byte(d.c, d.tick), Action.NONE | (3 << 4),
			"NONE: no phases = 3")
	var p: int = d.tick + 1
	d.step(PRIMARY)
	assert_eq(ActionMachine.action_byte(d.c, p), Action.LIGHT | (0 << 4) | (0 << 6),
			"first light attack, windup")
	d.hold(0, 12)
	assert_eq(ActionMachine.action_byte(d.c, p + 12), Action.LIGHT | (1 << 4) | (0 << 6),
			"first light attack, active hit")
	d.hold(0, 6)
	assert_eq(ActionMachine.action_byte(d.c, p + 18), Action.LIGHT | (2 << 4) | (0 << 6),
			"first light attack, recovery")
	# Second light attack.
	d.step(PRIMARY)
	d.idle_until_before(p + 36)
	d.step()
	assert_eq(d.c.action_id, _light_id(1), "second light attack")
	assert_eq(ActionMachine.action_byte(d.c, d.tick), Action.LIGHT | (0 << 4) | (1 << 6),
			"the combo step goes in bits 6-7")
	# Third.
	var e := Driver.new()
	e.step(PRIMARY)
	e.hold(0, 40)
	e.c.combo_step = 2
	e.step(PRIMARY)
	assert_eq(ActionMachine.action_byte(e.c, e.tick), Action.LIGHT | (0 << 4) | (2 << 6), "third")
	# Heavy attack, block, dodge.
	var f := Driver.new()
	f.hold(PRIMARY, 8)
	assert_eq(ActionMachine.action_byte(f.c, f.tick), Action.CHARGE | (0 << 4), "charge: phase 0")
	f.hold(PRIMARY, 14)
	f.step()
	assert_eq(f.c.action, Action.HEAVY, "released")
	assert_eq(ActionMachine.action_byte(f.c, f.tick), Action.HEAVY | (0 << 4) | (0 << 6),
			"heavy attack, windup (does not use the combo step)")
	var g := Driver.new()
	g.step(BLOCK)
	assert_eq(ActionMachine.action_byte(g.c, g.tick), Action.BLOCK | (3 << 4), "block: no phases = 3")
	var h := Driver.new()
	h.step(DODGE)
	assert_eq(ActionMachine.action_byte(h.c, h.tick), Action.DODGE | (3 << 4), "dodge: no phases = 3")
	assert_true(ActionMachine.action_byte(h.c, h.tick) <= 255, "fits in a byte")


func test_queries_use_the_catalog_of_the_weapon() -> void:
	var c := CombatState.new()
	c.weapon_id = 99
	c.action = Action.DODGE
	assert_false(ActionMachine.is_invulnerable(c, 5), "a weapon that does not exist gives no invulnerability")
	c.action = Action.LIGHT
	c.action_id = 99
	assert_eq(ActionMachine.phase(c, 5), ActionMachine.PHASE_NONE, "an attack that does not exist has no phases")
	assert_false(ActionMachine.is_attack_active(c, 5), "nor hits")
	assert_eq(ActionMachine.action_byte(c, 5), Action.LIGHT | (3 << 4), "action_byte does not fail")


func test_a_state_with_unknown_weapon_or_attack_does_not_crash() -> void:
	var d := Driver.new()
	d.c.weapon_id = 0
	d.hold(PRIMARY | DODGE | BLOCK, 5)
	assert_eq(d.c.action, Action.NONE, "without a weapon one cannot attack, dodge or block")
	var e := Driver.new()
	e.c.action = Action.LIGHT
	e.c.action_id = 200
	e.c.action_tick = e.tick
	e.step()
	assert_eq(e.c.action, Action.NONE, "an unknown attack is discarded")


# --- Determinism of the machine alone ----------------------------------------------------------

func test_machine_replay_from_any_tick_gives_the_same_state() -> void:
	var inputs: Array[int] = _combat_buttons()
	var reference := Driver.new()
	reference.move = Vector2(0.2, 1.0)
	var states: Array[PackedByteArray] = []
	for i: int in inputs.size():
		states.append(_bytes(reference.c))
		reference.step(inputs[i] & 0xFFFF, (inputs[i] & PlayerInput.SUBSTITUTED) != 0)
	states.append(_bytes(reference.c))
	var actions_seen: Dictionary[int, bool] = {}
	for i: int in range(0, inputs.size(), 2):
		var replay := Driver.new()
		replay.move = Vector2(0.2, 1.0)
		replay.c = _round_trip(_state_from(states[i]))
		replay.tick = START_TICK + i
		for j: int in range(i, inputs.size()):
			replay.step(inputs[j] & 0xFFFF, (inputs[j] & PlayerInput.SUBSTITUTED) != 0)
			actions_seen[replay.c.action] = true
			if _bytes(replay.c) != states[j + 1]:
				fail("replaying from tick %d diverges at %d:\n  expected %s\n  got %s" % [
					i, j, _state_from(states[j + 1]), replay.c,
				])
				return
	for action: int in [Action.LIGHT, Action.HEAVY, Action.CHARGE, Action.BLOCK, Action.DODGE]:
		assert_true(actions_seen.has(action), "the script goes through action %d" % action)


# --- With physics: movement -------------------------------------------------------------------

func test_dodge_travels_the_baked_distance_on_flat_ground() -> void:
	var rig: Dictionary = await _make_rig("Esquiva")
	var character: PlayerCharacter = rig["character"]
	var tick: int = await _settle(character, Vector3(0.0, 0.0, 10.0), 0.0)
	var directions: Array = [
		[Vector2(0.0, 1.0), Vector3(0.0, 0.0, -1.0), "adelante"],
		[Vector2(1.0, 0.0), Vector3(1.0, 0.0, 0.0), "derecha"],
		[Vector2(0.0, -1.0), Vector3(0.0, 0.0, 1.0), "atrás"],
		[Vector2.ZERO, Vector3(0.0, 0.0, 1.0), "sin entrada"],
	]
	for case: Array in directions:
		await _teleport(character, Vector3(0.0, 0.0, 10.0), 0.0)
		var start: Vector3 = character.global_position
		var yaw_before: float = character.yaw
		tick = await _next_tick(character, tick)
		var dodge := _input(tick, case[0], 0.0, DODGE)
		character.simulate(dodge, _dt)
		assert_eq(character.combat.action, Action.DODGE, "%s: dodge" % case[2])
		for _i: int in 26:
			tick += 1
			character.simulate(_input(tick, Vector2.ZERO, 0.0, 0), _dt)
		for _i: int in 20:
			tick += 1
			character.simulate(_input(tick, Vector2.ZERO, 0.0, 0), _dt)
		assert_eq(character.combat.action, Action.NONE, "%s: the dodge ended" % case[2])
		var travelled: Vector3 = character.global_position - start
		assert_near(travelled.length(), 4.5, 0.05, "%s: covers 4.5 m on flat ground (%s)" % [case[2], travelled])
		assert_near(travelled.normalized().dot(case[1]), 1.0, 1e-3, "%s: in the expected direction" % case[2])
		assert_near(travelled.y, 0.0, 0.01, "%s: without leaving the ground" % case[2])
		assert_eq(character.yaw, yaw_before, "%s: the body keeps its yaw" % case[2])
		assert_true(character.get_horizontal_speed() < 0.01, "%s: ends stopped" % case[2])


func test_dodge_does_not_pass_through_walls() -> void:
	var rig: Dictionary = await _make_rig("MuroEsquiva")
	var viewport: SubViewport = rig["viewport"]
	# World wall (layer 1) ahead, at 3 m, and a player block (layer 3) on the right.
	_add_box(viewport, Vector3(10.0, 4.0, 1.0), Vector3(0.0, 2.0, 7.0), WORLD_LAYER)
	_add_box(viewport, Vector3(1.0, 4.0, 10.0), Vector3(4.0, 2.0, 15.0),
			PlayerCharacter.PLAYER_BLOCKER_LAYER)
	await wait_physics_frames(2)
	var character: PlayerCharacter = rig["character"]
	var tick: int = await _settle(character, Vector3(0.0, 0.0, 10.0), 0.0)
	tick = await _next_tick(character, tick)
	character.simulate(_input(tick, Vector2(0.0, 1.0), 0.0, DODGE), _dt)
	for _i: int in 45:
		tick += 1
		character.simulate(_input(tick, Vector2.ZERO, 0.0, 0), _dt)
	# The wall occupies z from 6.5 to 7.5; the capsule has a 0.4 radius.
	assert_true(character.global_position.z >= 7.5 + 0.35, "does not go through the world wall (z = %s)"
			% character.global_position.z)
	assert_true(character.global_position.z < 9.0, "but does get close (z = %s)" % character.global_position.z)
	assert_near(character.global_position.x, 0.0, 0.05, "without veering")

	await _teleport(character, Vector3(0.0, 0.0, 12.0), 0.0)
	tick = await _next_tick(character, tick)
	character.simulate(_input(tick, Vector2(1.0, 0.0), 0.0, DODGE), _dt)
	for _i: int in 45:
		tick += 1
		character.simulate(_input(tick, Vector2.ZERO, 0.0, 0), _dt)
	assert_true(character.global_position.x <= 3.5 - 0.35 + 0.01, "does not go through the player block (x = %s)"
			% character.global_position.x)
	assert_true(character.global_position.x > 2.0, "but reaches it (x = %s)" % character.global_position.x)


func test_blocking_slows_the_character() -> void:
	var rig: Dictionary = await _make_rig("Bloqueo")
	var character: PlayerCharacter = rig["character"]
	var tick: int = await _settle(character, Vector3(0.0, 0.0, 40.0), 0.0)
	# Without blocking: running speed.
	tick = await _next_tick(character, tick)
	for _i: int in 30:
		tick += 1
		character.simulate(_input(tick, Vector2(0.0, 1.0), 0.0, 0), _dt)
	assert_near(character.get_horizontal_speed(), character.run_speed, 0.05, "running")
	# Blocking, half; and sprinting does not work.
	for _i: int in 30:
		tick += 1
		character.simulate(_input(tick, Vector2(0.0, 1.0), 0.0, BLOCK), _dt)
	assert_eq(character.combat.action, Action.BLOCK, "blocking")
	assert_near(character.get_horizontal_speed(), character.run_speed * 0.5, 0.05, "×0.5 when blocking")
	for _i: int in 30:
		tick += 1
		character.simulate(_input(tick, Vector2(0.0, 1.0), 0.0, BLOCK | PlayerInput.SPRINT), _dt)
	assert_near(character.get_horizontal_speed(), character.run_speed * 0.5, 0.05, "without sprinting")
	# Backward and sideways: also ×0.5 of running (the table adds no further multipliers).
	for _i: int in 30:
		tick += 1
		character.simulate(_input(tick, Vector2(0.0, -1.0), 0.0, BLOCK), _dt)
	assert_near(character.get_horizontal_speed(), character.run_speed * 0.5, 0.05, "backward")
	# Release: runs again.
	for _i: int in 30:
		tick += 1
		character.simulate(_input(tick, Vector2(0.0, 1.0), 0.0, 0), _dt)
	assert_near(character.get_horizontal_speed(), character.run_speed, 0.05, "without blocking again")
	assert_eq(character.combat.action, Action.NONE, "no longer blocks")


func test_attacks_turn_toward_the_camera_even_when_standing_still() -> void:
	var rig: Dictionary = await _make_rig("Giro")
	var character: PlayerCharacter = rig["character"]
	var tick: int = await _settle(character, Vector3(0.0, 0.0, 40.0), 0.0)
	tick = await _next_tick(character, tick)
	# Without attacking, standing still: the body does not turn toward the camera.
	for _i: int in 5:
		tick += 1
		character.simulate(_input(tick, Vector2.ZERO, 1.5, 0), _dt)
	assert_near(character.yaw, 0.0, 1e-6, "stopped, no attack, the yaw does not change")
	# The light attack makes the yaw snap to the camera on its first tick.
	tick += 1
	character.simulate(_input(tick, Vector2.ZERO, 1.5, PRIMARY), _dt)
	assert_near(character.yaw, 1.5, 1e-3, "the yaw snaps to look_yaw")
	assert_eq(character.yaw, PlayerState.to_f32(character.yaw), "and is rounded to f32")
	# While attacking it keeps turning toward the camera at 6 rad/s.
	for _i: int in 6:
		tick += 1
		character.simulate(_input(tick, Vector2.ZERO, -0.5, 0), _dt)
	assert_near(character.yaw, 1.5 - 6.0 * 6.0 / 60.0, 0.02, "turns at 6 rad/s toward the new camera")
	# During the recovery (from tick 18) it no longer turns.
	for _i: int in 12:
		tick += 1
		character.simulate(_input(tick, Vector2.ZERO, 3.0, 0), _dt)
	var yaw_at_recovery: float = character.yaw
	assert_eq(ActionMachine.phase(character.combat, tick), ActionMachine.PHASE_RECOVERY, "recovery")
	for _i: int in 6:
		tick += 1
		character.simulate(_input(tick, Vector2.ZERO, 3.0, 0), _dt)
	assert_eq(character.yaw, yaw_at_recovery, "does not turn during the recovery")


func test_light_attack_lunges_forward_and_stops_in_recovery() -> void:
	var rig: Dictionary = await _make_rig("Avance")
	var character: PlayerCharacter = rig["character"]
	var tick: int = await _settle(character, Vector3(0.0, 0.0, 40.0), 0.0)
	tick = await _next_tick(character, tick)
	var start: Vector3 = character.global_position
	tick += 1
	character.simulate(_input(tick, Vector2.ZERO, 0.0, PRIMARY), _dt)
	var speeds: Array[float] = []
	for _i: int in 17:
		tick += 1
		character.simulate(_input(tick, Vector2.ZERO, 0.0, 0), _dt)
		speeds.append(character.get_horizontal_speed())
	assert_near(speeds[speeds.size() - 1], 1.5, 0.01, "advances at 1.5 m/s at the end of the active hit")
	var advanced: float = start.z - character.global_position.z
	assert_true(advanced > 0.35 and advanced < 0.5, "advances about 0.4 m in 18 ticks (%s)" % advanced)
	assert_near(character.global_position.x, start.x, 1e-4, "and forward")
	for _i: int in 6:
		tick += 1
		character.simulate(_input(tick, Vector2.ZERO, 0.0, 0), _dt)
	assert_true(character.get_horizontal_speed() < 0.01, "in the recovery it brakes (%s)"
			% character.get_horizontal_speed())


func test_cannot_jump_while_attacking_or_dodging_but_can_while_blocking() -> void:
	var rig: Dictionary = await _make_rig("Salto")
	var character: PlayerCharacter = rig["character"]
	var tick: int = await _settle(character, Vector3(0.0, 0.0, 40.0), 0.0)
	tick = await _next_tick(character, tick)
	tick += 1
	character.simulate(_input(tick, Vector2.ZERO, 0.0, PRIMARY), _dt)
	for _i: int in 4:
		tick += 1
		character.simulate(_input(tick, Vector2.ZERO, 0.0, PlayerInput.JUMP), _dt)
	assert_true(character.grounded and character.velocity.y <= 0.001, "no jumping while attacking")
	# Wait for the attack to end and the stored jump press to expire.
	for _i: int in 50:
		tick += 1
		character.simulate(_input(tick, Vector2.ZERO, 0.0, 0), _dt)
	assert_eq(character.combat.action, Action.NONE, "the attack ended")
	tick += 1
	character.simulate(_input(tick, Vector2.ZERO, 0.0, DODGE), _dt)
	for _i: int in 4:
		tick += 1
		character.simulate(_input(tick, Vector2.ZERO, 0.0, PlayerInput.JUMP), _dt)
	assert_eq(character.combat.action, Action.DODGE, "dodging")
	assert_true(character.grounded and character.velocity.y <= 0.001, "no jumping while dodging")
	for _i: int in 60:
		tick += 1
		character.simulate(_input(tick, Vector2.ZERO, 0.0, 0), _dt)
	# Jumping while blocking is allowed, and jumping drops the block.
	tick += 1
	character.simulate(_input(tick, Vector2.ZERO, 0.0, BLOCK), _dt)
	tick += 1
	character.simulate(_input(tick, Vector2.ZERO, 0.0, BLOCK | PlayerInput.JUMP), _dt)
	assert_true(character.velocity.y > 5.0, "while blocking one can jump (vy = %s)" % character.velocity.y)
	tick += 1
	character.simulate(_input(tick, Vector2.ZERO, 0.0, BLOCK), _dt)
	assert_eq(character.combat.action, Action.NONE, "and being in the air drops the block")


## Horizontal velocity after [param ticks] ticks in the air (30 m up, 7.5 m/s toward -Z) with an
## imposed action ([param kind]: "none", "death", "stun" or "stagger") and the movement [param move].
## Returns the velocity and the encoded state at the end.
func _air_run(character: PlayerCharacter, kind: String, move: Vector2, ticks: int) -> Dictionary:
	await wait_physics_frames(1)
	var start := PlayerState.new()
	start.position = Vector3(0.0, 30.0, 40.0)
	start.velocity = Vector3(0.0, 0.0, -7.5)
	start.grounded = false
	character.set_state(PlayerState.decode(start.encode()))
	character.reset_physics_interpolation()
	var tick: int = START_TICK
	match kind:
		"death":
			ActionMachine.impose_death(character.combat, tick)
		"stun":
			ActionMachine.impose_stun(character.combat, tick, tick + 600)
		"stagger":
			ActionMachine.impose_stagger(character.combat, tick, tick + 600, Vector2.ZERO)
	character.set_state(PlayerState.decode(character.get_state().encode()))
	for _i: int in ticks:
		tick += 1
		character.simulate(_input(tick, move, 0.0, 0), _dt)
	return {
		"velocity": Vector2(character.velocity.x, character.velocity.z),
		"bytes": character.get_state().encode(),
		"grounded": character.grounded,
	}


func test_a_dead_stunned_or_staggered_body_in_the_air_brakes_and_cannot_be_steered() -> void:
	# C4: with move_scale 0 the target velocity is 0, but the air branch kept the momentum
	# pushing forward (or turned it diagonally). Braking is what §3.3 says (DEAD, STUN and
	# STAGGER without a push "brake").
	var rig: Dictionary = await _make_rig("AireControlado")
	var character: PlayerCharacter = rig["character"]
	await _settle(character, Vector3(0.0, 0.0, 40.0), 0.0)
	for kind: String in ["death", "stun", "stagger"]:
		var rest: Dictionary = await _air_run(character, kind, Vector2.ZERO, 30)
		assert_false(rest["grounded"], "(%s) still in the air" % kind)
		var rest_velocity: Vector2 = rest["velocity"]
		assert_true(rest_velocity.length() < 7.5 - 2.0, "(%s) with no input it brakes (%s)" % [kind,
				rest_velocity])
		for move: Vector2 in [Vector2(0.0, 1.0), Vector2(0.7, 0.7), Vector2(-1.0, 0.0)]:
			var steered: Dictionary = await _air_run(character, kind, move, 30)
			var velocity: Vector2 = steered["velocity"]
			assert_vec_near(velocity, rest_velocity, 1e-5,
					"(%s) with move=%s the velocity is the same as with no input" % [kind, move])
			assert_eq(steered["bytes"], rest["bytes"],
					"(%s) with move=%s the encoded state is the same" % [kind, move])
		# Deterministic: repeating the same input gives the same bytes.
		var again: Dictionary = await _air_run(character, kind, Vector2.ZERO, 30)
		assert_eq(again["bytes"], rest["bytes"], "(%s) repeatable byte for byte" % kind)
	# Control: with no action, pushing forward keeps the momentum in the air.
	var free_rest: Dictionary = await _air_run(character, "none", Vector2.ZERO, 30)
	var free_forward: Dictionary = await _air_run(character, "none", Vector2(0.0, 1.0), 30)
	var free_velocity: Vector2 = free_forward["velocity"]
	assert_near(free_velocity.length(), 7.5, 0.01, "with no action, W keeps the 7.5 m/s")
	var brake_velocity: Vector2 = free_rest["velocity"]
	assert_true(brake_velocity.length() < 5.0, "and with no input it brakes (%s)" % brake_velocity)


func test_last_landing_speed_is_measured_before_move_and_slide() -> void:
	var rig: Dictionary = await _make_rig("Caida")
	var character: PlayerCharacter = rig["character"]
	var tick: int = await _settle(character, Vector3(0.0, 0.0, 40.0), 0.0)
	assert_eq(character.last_landing_speed, 0.0, "at rest it is 0")
	await _teleport(character, Vector3(0.0, 3.0, 40.0), 0.0, false)
	tick = await _next_tick(character, tick)
	var landing_speeds: Array[float] = []
	var landing_ticks: int = 0
	for _i: int in 90:
		tick += 1
		character.simulate(_input(tick, Vector2.ZERO, 0.0, 0), _dt)
		if character.last_landing_speed != 0.0:
			landing_speeds.append(character.last_landing_speed)
			landing_ticks += 1
			assert_true(character.grounded, "it is only different from 0 on the tick the ground is touched")
	assert_eq(landing_ticks, 1, "a single landing tick")
	if landing_speeds.size() == 1:
		# Free fall of about 3 m at 22 m/s²: ~11.5 m/s right before touching the ground.
		assert_true(landing_speeds[0] > 10.0 and landing_speeds[0] < 12.5,
				"landing speed of about 11.5 m/s (%s)" % landing_speeds[0])
	assert_eq(character.last_landing_speed, 0.0, "and afterward it goes back to 0")
	# Running on the ground never triggers it.
	for _i: int in 30:
		tick += 1
		character.simulate(_input(tick, Vector2(0.0, 1.0), 0.0, 0), _dt)
		assert_eq(character.last_landing_speed, 0.0, "while walking it is 0")


func test_character_state_includes_the_combat() -> void:
	var rig: Dictionary = await _make_rig("Estado")
	var character: PlayerCharacter = rig["character"]
	await wait_physics_frames(1)
	assert_true(character.combat.equals(CombatState.initial(CombatCatalog.rules(),
			CombatCatalog.default_weapon_id())), "the character starts with the initial combat state")
	character.combat.stamina = 321
	character.combat.action = Action.BLOCK
	var state: PlayerState = character.get_state()
	assert_eq(state.combat.stamina, 321, "get_state() carries the combat state")
	character.combat.stamina = 5
	assert_eq(state.combat.stamina, 321, "and is a copy, not an alias")
	character.set_state(state)
	assert_eq(character.combat.stamina, 321, "set_state() restores it")
	assert_eq(character.combat.action, Action.BLOCK, "with the action")
	state.combat.stamina = 7
	assert_eq(character.combat.stamina, 321, "without sharing the object")


func test_prev_buttons_never_keeps_the_substituted_bit() -> void:
	var rig: Dictionary = await _make_rig("Sustituida")
	var character: PlayerCharacter = rig["character"]
	var tick: int = await _settle(character, Vector3(0.0, 0.0, 40.0), 0.0)
	tick = await _next_tick(character, tick)
	var input := _input(tick, Vector2.ZERO, 0.0, BLOCK | PlayerInput.SUBSTITUTED)
	character.simulate(input, _dt)
	assert_eq(character.prev_buttons, BLOCK, "prev_buttons does not store bit 15")
	assert_eq(character.get_state().prev_buttons & PlayerInput.SUBSTITUTED, 0, "nor the state")
	assert_eq(character.get_state().encode().decode_u16(29), BLOCK, "nor what travels over the network")


# --- With physics: deterministic replay ------------------------------------------------------

func test_replay_from_mid_action_gives_the_same_encoded_state() -> void:
	# The script goes through combo, dodge, block, heavy attack charge, repeated inputs and an
	# imposed stagger. It is recorded in one world and replayed from many ticks in a different one.
	var inputs: Array[PlayerInput] = _combat_script()
	var recorder: Dictionary = await _make_rig("Grabacion")
	var replayer: Dictionary = await _make_rig("Repeticion")
	var origin: Vector3 = Vector3(0.0, 0.0, 40.0)
	var first: PlayerCharacter = recorder["character"]
	var second: PlayerCharacter = replayer["character"]
	await _settle(first, origin, 0.0)
	await _settle(second, origin, 0.0)
	var start_state: PlayerState = PlayerState.decode(first.get_state().encode())
	var states: Array[PlayerState] = []
	var actions_seen: Dictionary[int, bool] = {}
	first.set_state(start_state)
	for i: int in inputs.size():
		states.append(PlayerState.decode(first.get_state().encode()))
		first.simulate(inputs[i], _dt)
		_apply_imposition(first, inputs[i].tick)
		actions_seen[first.combat.action] = true
	states.append(PlayerState.decode(first.get_state().encode()))
	for action: int in [Action.LIGHT, Action.HEAVY, Action.CHARGE, Action.BLOCK, Action.DODGE,
			Action.STAGGER]:
		assert_true(actions_seen.has(action), "the script goes through action %d" % action)
	assert_true(states[inputs.size()].position.distance_to(origin) > 3.0, "and the character moves")

	var mismatches: PackedStringArray = PackedStringArray()
	var replays: int = 0
	for from_tick: int in range(0, inputs.size(), 3):
		replays += 1
		second.set_state(states[from_tick])
		for i: int in range(from_tick, inputs.size()):
			second.simulate(inputs[i], _dt)
			_apply_imposition(second, inputs[i].tick)
			var expected: PackedByteArray = states[i + 1].encode()
			var actual: PackedByteArray = second.get_state().encode()
			if actual != expected:
				mismatches.append("desde %d diverge en %d: %s (esperado %s)" % [
					from_tick, i, second.get_state(), states[i + 1],
				])
				break
	assert_true(replays > 50, "replayed from %d ticks" % replays)
	assert_true(mismatches.is_empty(), "%d replays diverge:\n  %s" % [
		mismatches.size(), "\n  ".join(mismatches.slice(0, 3)),
	])


func test_replay_from_mid_action_in_the_same_world() -> void:
	# The same in a single world and passing the state over the network at each starting point.
	var inputs: Array[PlayerInput] = _combat_script()
	var rig: Dictionary = await _make_rig("Mismo")
	var character: PlayerCharacter = rig["character"]
	var origin: Vector3 = Vector3(0.0, 0.0, 40.0)
	await _settle(character, origin, 0.0)
	var start_state: PlayerState = PlayerState.decode(character.get_state().encode())
	var states: Array[PlayerState] = []
	character.set_state(start_state)
	for i: int in inputs.size():
		states.append(PlayerState.decode(character.get_state().encode()))
		character.simulate(inputs[i], _dt)
		_apply_imposition(character, inputs[i].tick)
	states.append(PlayerState.decode(character.get_state().encode()))
	var bad: int = 0
	for from_tick: int in range(1, inputs.size(), 7):
		character.set_state(states[from_tick])
		for i: int in range(from_tick, inputs.size()):
			character.simulate(inputs[i], _dt)
			_apply_imposition(character, inputs[i].tick)
			if character.get_state().encode() != states[i + 1].encode():
				bad += 1
				break
	assert_eq(bad, 0, "no replay diverges")


# --- Utilities -------------------------------------------------------------------------------

func _light_id(index: int) -> int:
	return _data.weapon(_data.weapon_ids[&"sword_shield"]).light_ids[index]


func _heavy_id() -> int:
	return _data.weapon(_data.weapon_ids[&"sword_shield"]).heavy_id


func assert_ne_int(actual: int, unexpected: int, message: String = "") -> bool:
	return assert_true(actual != unexpected, "%s (value %d)" % [message, actual])


func _bytes(c: CombatState) -> PackedByteArray:
	var bytes := PackedByteArray()
	bytes.resize(CombatState.ENCODED_SIZE)
	c.encode_into(bytes, 0)
	return bytes


func _state_from(bytes: PackedByteArray) -> CombatState:
	return CombatState.decode_from(bytes, 0)


func _round_trip(c: CombatState) -> CombatState:
	return _state_from(_bytes(c))


## Scripted buttons (with the replacement mark in bit 15) that go through all the
## actions: three-hit combo, dodge, block with parry, heavy attack charge and a stretch of repeated
## inputs.
func _combat_buttons() -> Array[int]:
	var buttons: Array[int] = []
	var sub: int = PlayerInput.SUBSTITUTED
	_append_ticks(buttons, 0, 10)
	# Combo: three presses within the windows.
	_append_ticks(buttons, PRIMARY, 1)
	_append_ticks(buttons, 0, 29)
	_append_ticks(buttons, PRIMARY, 1)
	_append_ticks(buttons, 0, 33)
	_append_ticks(buttons, PRIMARY, 1)
	_append_ticks(buttons, 0, 60)
	# Dodge and an attack cancelling the dodge.
	_append_ticks(buttons, DODGE, 1)
	_append_ticks(buttons, 0, 17)
	_append_ticks(buttons, PRIMARY, 1)
	_append_ticks(buttons, 0, 50)
	# Block with parry, release and press again.
	_append_ticks(buttons, BLOCK, 20)
	_append_ticks(buttons, 0, 3)
	_append_ticks(buttons, BLOCK, 20)
	_append_ticks(buttons, 0, 10)
	# Heavy attack charge, releasing before the minimum.
	_append_ticks(buttons, PRIMARY, 12)
	_append_ticks(buttons, 0, 80)
	# Charge with repeated inputs in the middle and a dodge in the middle of the charge.
	_append_ticks(buttons, PRIMARY, 10)
	_append_ticks(buttons, PRIMARY | sub, 20)
	_append_ticks(buttons, PRIMARY, 15)
	_append_ticks(buttons, PRIMARY | DODGE, 1)
	_append_ticks(buttons, 0, 60)
	# Maximum charge with automatic release.
	_append_ticks(buttons, PRIMARY, 90)
	_append_ticks(buttons, 0, 40)
	return buttons


func _append_ticks(buttons: Array[int], mask: int, count: int) -> void:
	for _i: int in count:
		buttons.append(mask)


## The same script as quantized inputs (with movement and camera) for the real character.
func _combat_script() -> Array[PlayerInput]:
	var buttons: Array[int] = _combat_buttons()
	var inputs: Array[PlayerInput] = []
	for i: int in buttons.size():
		var input := PlayerInput.new()
		input.tick = START_TICK + i
		input.buttons = buttons[i]
		input.move = Vector2(0.3, 1.0).limit_length(1.0) if i % 90 < 60 else Vector2.ZERO
		input.look_yaw = 0.35 * sin(float(i) / 40.0) + (0.5 if i > 300 else 0.0)
		inputs.append(input.quantized())
	return inputs


## Stagger imposed by the server on a tick of the script (as it would after a hit).
func _apply_imposition(character: PlayerCharacter, tick: int) -> void:
	if tick == START_TICK + 290:
		ActionMachine.impose_stagger(character.combat, tick, tick + 25, Vector2(3.0, -2.0))
		character.set_state(PlayerState.decode(character.get_state().encode()))


## A physics world of its own with a floor, and a character inside. Returns
## {viewport, character}.
func _make_rig(rig_name: String) -> Dictionary:
	var viewport := SubViewport.new()
	viewport.name = rig_name
	viewport.own_world_3d = true
	viewport.size = Vector2i(64, 64)
	tree.root.add_child(viewport)
	_viewports.append(viewport)
	_add_box(viewport, Vector3(400.0, 1.0, 400.0), Vector3(0.0, -0.5, 0.0), WORLD_LAYER)
	var scene: PackedScene = load(CHARACTER_SCENE_PATH) as PackedScene
	var character: PlayerCharacter = scene.instantiate() as PlayerCharacter
	viewport.add_child(character)
	await wait_physics_frames(2)
	return {"viewport": viewport, "character": character}


func _add_box(parent: Node, size: Vector3, center: Vector3, layer: int) -> void:
	var body := StaticBody3D.new()
	body.collision_layer = layer
	body.collision_mask = 0
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = size
	shape.shape = box
	body.add_child(shape)
	body.position = center
	parent.add_child(body)


## Places the character and leaves it settled on the ground. Returns the last simulated tick.
func _settle(character: PlayerCharacter, position: Vector3, yaw: float) -> int:
	await _teleport(character, position, yaw)
	return START_TICK - 1


## Next tick of a test with physics: waits until it is inside the physics step.
func _next_tick(_character: PlayerCharacter, tick: int) -> int:
	await wait_physics_frames(1)
	return tick + 1


func _teleport(character: PlayerCharacter, position: Vector3, yaw: float,
		grounded: bool = true) -> void:
	await wait_physics_frames(1)
	var state := PlayerState.new()
	state.position = position
	state.yaw = yaw
	state.grounded = grounded
	character.set_state(PlayerState.decode(state.encode()))
	character.reset_physics_interpolation()
	for i: int in 3:
		character.simulate(_input(START_TICK - 4 + i, Vector2.ZERO, yaw, 0), _dt)


func _input(tick: int, move: Vector2, look_yaw: float, buttons: int) -> PlayerInput:
	var input := PlayerInput.new()
	input.tick = tick
	input.move = move
	input.look_yaw = look_yaw
	input.buttons = buttons
	return input.quantized()
