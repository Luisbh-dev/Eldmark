extends TestCase
## The bow in the action machine (docs/habilidades.md, sections 0, 2.3 and 7.3): a tap is the
## quick shot (the light attack, a combo of 1), holding 8 ticks is the draw (the heavy attack's charge), the
## minimum and maximum charges come out on their ticks, BLOCK does nothing and when exhausted it cannot be drawn.
## [br][br]
## Data: quick 15 + 1 + 21 (37), draw with a charge of 21 to 60 ticks from the press and then 3 + 1
## + 18, movement ×0.5 and turn 8.

const Action = CombatState.Action
const PRIMARY: int = PlayerInput.PRIMARY


func test_a_tap_is_the_quick_shot() -> void:
	var bow: WeaponTicks = CombatCatalog.weapon(_bow())
	var quick: AttackTicks = CombatCatalog.attack(bow.light_ids[0])
	assert_eq(quick.name, &"bow_quick", "the light attack is the quick shot")
	assert_eq(bow.light_ids.size(), 1, "combo of 1")
	var d := _driver()
	var first: ActionMachine.Output = d.step(PRIMARY)
	var p: int = d.tick
	assert_eq(d.c.action, Action.LIGHT, "a tap fires")
	assert_eq(d.c.action_id, quick.id, "the quick one")
	assert_eq(d.c.combo_step, 0, "the combo of 1 goes back to the start")
	assert_near(first.move_scale, 0.5, 1e-6, "×0,5")
	assert_near(first.turn_rate, 8.0, 1e-6, "turn 8")
	for rel: int in range(1, 37):
		d.step()
		assert_eq(ActionMachine.is_commit_tick(d.c, p + rel), rel == 15, "rel %d: the arrow goes out at 15" % rel)
	assert_eq(d.c.action, Action.LIGHT, "fires for 37 ticks")
	d.step()
	assert_eq(d.c.action, Action.NONE, "and ends")
	d.step(PRIMARY)
	assert_eq(d.c.action_id, quick.id, "the next tap is the quick one again")


func test_holding_eight_ticks_draws_the_bow() -> void:
	var d := _driver()
	d.hold(PRIMARY, 7)
	assert_eq(d.c.action, Action.LIGHT, "7 ticks: still the quick one")
	d.step(PRIMARY)
	assert_eq(d.c.action, Action.CHARGE, "at 8, drawing")
	assert_eq(d.c.action_id, CombatCatalog.weapon(_bow()).heavy_id, "the draw")
	assert_true(d.out.snap_yaw, "looks at the camera")
	d.step(PRIMARY)
	assert_near(d.out.move_scale, 0.5, 1e-6, "drawing ×0.5")
	assert_near(d.out.turn_rate, 8.0, 1e-6, "turn 8")
	assert_eq(ActionMachine.phase(d.c, d.tick), ActionMachine.PHASE_WINDUP, "phase 0")
	assert_eq(ActionMachine.action_byte(d.c, d.tick), Action.CHARGE, "byte: CHARGE, phase 0, nothing else")
	assert_eq(d.c.stamina, 1000, "drawing costs no stamina")


func test_minimum_and_maximum_draw_launch_on_their_ticks() -> void:
	var drawn: AttackTicks = CombatCatalog.attack(CombatCatalog.weapon(_bow()).heavy_id)
	assert_eq([drawn.charge_min_ticks, drawn.charge_max_ticks], [21, 60], "charge 21-60")
	assert_eq([drawn.windup_ticks, drawn.active_ticks, drawn.recovery_ticks], [3, 1, 18], "3 + 1 + 18")
	# Releasing before the minimum: it goes out at the minimum.
	var short := _driver()
	short.step(PRIMARY)
	var p: int = short.tick
	short.hold(PRIMARY, 9)
	short.idle_until_before(p + 21)
	assert_eq(short.c.action, Action.CHARGE, "waits for the minimum")
	short.step()
	assert_eq(short.c.action, Action.HEAVY, "releases at the minimum")
	assert_eq(short.c.action_tick, p + 21, "on tick 21 since the press")
	assert_eq(short.c.charge_ticks, 21, "with 21 of charge")
	assert_true(ActionMachine.is_commit_tick(short.c, p + 21 + 3), "the arrow goes out 3 ticks later")
	# Holding: it goes out on its own at the maximum.
	var full := _driver()
	full.step(PRIMARY)
	var q: int = full.tick
	full.idle_until_before(q + 60, PRIMARY)
	assert_eq(full.c.action, Action.CHARGE, "drawing up to the maximum")
	full.step(PRIMARY)
	assert_eq(full.c.action, Action.HEAVY, "at the maximum it releases on its own")
	assert_eq(full.c.action_tick, q + 60, "on tick 60")
	assert_eq(full.c.charge_ticks, 60, "with the maximum charge")


func test_block_does_nothing_with_the_bow() -> void:
	var d := _driver()
	d.hold(PlayerInput.BLOCK, 20)
	assert_eq(d.c.action, Action.NONE, "the bow does not block")
	assert_eq(d.c.parry_ready_tick, 0, "nor open parries")
	assert_eq(ActionMachine.defense_flags(d.c, d.tick), 0, "no defense")
	d.step(PlayerInput.BLOCK | PRIMARY)
	assert_eq(d.c.action, Action.LIGHT, "and the button does not get in the way of the shot")


func test_exhausted_does_not_draw_but_still_shoots() -> void:
	var d := _driver()
	ActionMachine.drain_stamina(d.c, 5000, d.tick)
	assert_true(d.c.is_exhausted(), "exhausted")
	d.hold(PRIMARY, 8)
	assert_eq(d.c.action, Action.LIGHT, "does not draw: the quick shot continues")
	assert_true((d.c.combat_flags & CombatState.FLAG_NO_STAMINA) != 0, "and notifies the interface")
	d.hold(PRIMARY, 40)
	assert_eq(d.c.action, Action.NONE, "the quick shot ended")


func _bow() -> int:
	return CombatCatalog.weapon_id(&"bow")


func _driver() -> MachineDriver:
	return MachineDriver.new(_bow(), CombatCatalog.weapon_id(&"sword_shield"),
			CombatState.pack_charges(2, 3))
