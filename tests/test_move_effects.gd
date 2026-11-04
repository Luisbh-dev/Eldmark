extends TestCase
## Movement effects (docs/abilities.md, sections 3.3, 3.4, 3.5 and 7.3): the two [CombatState]
## slots imposed by the server, their expiry at the exact tick, the third that replaces the one
## ending sooner, ROOT that prevents dodging and advancing, and [member ActionMachine.Output.speed_factor]
## in movement. With physics ([PredictionPair]): the slow gives the same speed on client
## and server after reconciling.

const Action = CombatState.Action
## Server tick at which it imposes the slow (in the test with physics).
const SLOW_TICK: int = 60

var _pair: PredictionPair
var _viewport: SubViewport
var _mutations: Array[Array] = []


func after_each() -> void:
	if _pair != null:
		_pair.free_worlds()
		_pair = null
	if is_instance_valid(_viewport):
		_viewport.get_parent().remove_child(_viewport)
		_viewport.free()
	_viewport = null
	for i: int in range(_mutations.size() - 1, -1, -1):
		var entry: Array = _mutations[i]
		(entry[0] as Resource).set(entry[1], entry[2])
	if not _mutations.is_empty():
		_mutations.clear()
		CombatCatalog.reload()
	await wait_process_frames()


func test_the_slots_take_the_same_effect_and_the_third_replaces_the_one_ending_first() -> void:
	var slowed: int = CombatCatalog.status_id(&"slowed")
	var rooted: int = CombatCatalog.status_id(&"rooted")
	var bleed: int = CombatCatalog.status_id(&"bleed")
	var c := CombatState.new()
	ActionMachine.impose_move_effect(c, slowed, 500)
	ActionMachine.impose_move_effect(c, rooted, 300)
	assert_eq(c.move_effect_ids, PackedInt32Array([slowed, rooted]), "two slots")
	ActionMachine.impose_move_effect(c, slowed, 400)
	assert_eq(c.move_effect_until[0], 500, "the same effect keeps the later end")
	ActionMachine.impose_move_effect(c, slowed, 650)
	assert_eq(c.move_effect_until[0], 650, "and extends it")
	ActionMachine.impose_move_effect(c, bleed, 900)
	assert_eq(c.move_effect_ids, PackedInt32Array([slowed, bleed]), "the third replaces the one ending sooner")
	assert_eq(c.move_effect_until[1], 900, "with its end")
	ActionMachine.impose_move_effect(c, 0, 1000)
	assert_eq(c.move_effect_ids, PackedInt32Array([slowed, bleed]), "id 0 occupies nothing")
	ActionMachine.clear_move_effects(c)
	assert_eq(c.move_effect_ids, PackedInt32Array([0, 0]), "clear_move_effects empties them")
	assert_eq(c.move_effect_until, PackedInt64Array([0, 0]), "the ends too")


func test_a_slot_expires_on_its_exact_tick() -> void:
	var d := _driver()
	d.hold(0, 2)
	var until: int = d.tick + 30
	ActionMachine.impose_move_effect(d.c, CombatCatalog.status_id(&"slowed"), until)
	d.idle_until_before(until)
	assert_near(d.out.speed_factor, 0.6, 1e-6, "×0.6 until the tick before the end")
	assert_eq(d.c.move_effect_ids[0], CombatCatalog.status_id(&"slowed"), "the slot is still occupied")
	d.step()
	assert_eq(d.tick, until, "at the end tick (exclusive)")
	assert_eq(d.c.move_effect_ids[0], 0, "the slot empties")
	assert_eq(d.c.move_effect_until[0], 0, "with its end")
	assert_eq(d.out.speed_factor, 1.0, "and the speed returns")


func test_speed_factor_takes_the_slowest_and_the_fastest() -> void:
	var d := _driver()
	ActionMachine.impose_move_effect(d.c, CombatCatalog.status_id(&"slowed"), d.tick + 100)
	d.step()
	assert_near(d.out.speed_factor, 0.6, 1e-6, "slowed ×0.6")
	assert_false(d.out.rooted, "not rooted")
	assert_true(d.out.allow_jump, "can jump")
	ActionMachine.impose_move_effect(d.c, CombatCatalog.status_id(&"rooted"), d.tick + 100)
	d.step()
	assert_eq(d.out.speed_factor, 0.0, "rooted: 0")
	assert_true(d.out.rooted, "rooted")
	assert_false(d.out.allow_jump, "no jump")
	# An effect that speeds up (> 1) multiplies with the slowest one.
	_mutate("res://data/combat/slowed.tres", &"move_speed_scale", 1.5)
	var fast := _driver()
	ActionMachine.impose_move_effect(fast.c, CombatCatalog.status_id(&"slowed"), fast.tick + 100)
	fast.step()
	assert_near(fast.out.speed_factor, 1.5, 1e-6, "×1.5 if it speeds up")
	ActionMachine.impose_move_effect(fast.c, CombatCatalog.status_id(&"rooted"), fast.tick + 100)
	fast.step()
	assert_eq(fast.out.speed_factor, 0.0, "(the slowest, 0) × (the fastest, 1.5)")
	# In an action too (the block).
	var block := _driver()
	ActionMachine.impose_move_effect(block.c, CombatCatalog.status_id(&"slowed"), block.tick + 100)
	block.step(PlayerInput.BLOCK)
	assert_eq(block.c.action, Action.BLOCK, "blocking")
	assert_near(block.out.move_scale, 0.5, 1e-6, "×0.5 from the block")
	assert_near(block.out.speed_factor, 1.5, 1e-6, "and the effect separately")


func test_root_prevents_dodging_and_dashing() -> void:
	var rooted: int = CombatCatalog.status_id(&"rooted")
	var d := _driver()
	ActionMachine.impose_move_effect(d.c, rooted, d.tick + 90)
	d.step(PlayerInput.DODGE)
	assert_eq(d.c.action, Action.NONE, "rooted cannot dodge")
	assert_eq(d.c.buffered, 0, "and the press is discarded")
	assert_eq(d.c.combat_flags & CombatState.FLAG_NO_STAMINA, 0, "no stamina alert")
	assert_eq(d.c.stamina, 1000, "nor spending")
	assert_eq(ActionMachine.ability_status(d.c, 1, d.tick), ActionMachine.AbilityStatus.BLOCKED,
			"the charge is turned off")
	d.step(PlayerInput.ABILITY_2)
	assert_eq(d.c.action, Action.NONE, "the charge (advance) either")
	assert_eq(d.c.buffered, 0, "discarded")
	d.step(PlayerInput.ABILITY_1)
	assert_eq(d.c.action, Action.ABILITY, "the shield bash (no advance) does")
	assert_eq(d.out.speed_factor, 0.0, "but standing still")
	# On expiry, dodging works again.
	d.idle_until_before(d.c.move_effect_until[0] + 60)
	d.step(PlayerInput.DODGE)
	assert_eq(d.c.action, Action.DODGE, "without the root, it dodges")


func test_rooted_on_the_ground_and_in_the_air() -> void:
	_viewport = SubViewport.new()
	_viewport.own_world_3d = true
	_viewport.size = Vector2i(64, 64)
	tree.root.add_child(_viewport)
	var floor_body := StaticBody3D.new()
	floor_body.collision_layer = PlayerCharacter.WORLD_COLLISION_LAYER
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(400.0, 1.0, 400.0)
	shape.shape = box
	floor_body.add_child(shape)
	floor_body.position = Vector3(0.0, -0.5, 0.0)
	_viewport.add_child(floor_body)
	var character: PlayerCharacter = (load("res://scenes/characters/player_character.tscn")
			as PackedScene).instantiate() as PlayerCharacter
	_viewport.add_child(character)
	await wait_physics_frames(2)
	var dt: float = 1.0 / float(Engine.physics_ticks_per_second)
	var tick: int = 1000
	# Running on the ground and rooted: it brakes to 0 and does not jump.
	_place(character, Vector3(0.0, 0.0, 40.0), Vector3.ZERO, true)
	for _i: int in 30:
		tick += 1
		character.simulate(_input(tick, Vector2(0.0, 1.0), 0), dt)
	assert_near(character.get_horizontal_speed(), character.run_speed, 0.05, "runs")
	ActionMachine.impose_move_effect(character.combat, CombatCatalog.status_id(&"rooted"), tick + 60)
	PredictionPair.commit(character)
	for _i: int in 20:
		tick += 1
		character.simulate(_input(tick, Vector2(0.0, 1.0), PlayerInput.JUMP), dt)
	assert_true(character.get_horizontal_speed() < 0.01, "rooted it stops (%s)"
			% character.get_horizontal_speed())
	assert_true(character.grounded and character.velocity.y <= 0.001, "and does not jump")
	# In the air, rooted it brakes even if pushing forward.
	await wait_physics_frames(1)
	_place(character, Vector3(0.0, 30.0, 40.0), Vector3(0.0, 0.0, -7.5), false)
	ActionMachine.impose_move_effect(character.combat, CombatCatalog.status_id(&"rooted"), tick + 200)
	PredictionPair.commit(character)
	for _i: int in 30:
		tick += 1
		character.simulate(_input(tick, Vector2(0.0, 1.0), 0), dt)
	assert_true(character.get_horizontal_speed() < 7.5 - 2.0, "in the air it brakes (%s)"
			% character.get_horizontal_speed())
	# Slowed: ×0.6 of the run.
	await wait_physics_frames(1)
	ActionMachine.clear_move_effects(character.combat)
	_place(character, Vector3(0.0, 0.0, 40.0), Vector3.ZERO, true)
	ActionMachine.impose_move_effect(character.combat, CombatCatalog.status_id(&"slowed"), tick + 500)
	PredictionPair.commit(character)
	for _i: int in 40:
		tick += 1
		character.simulate(_input(tick, Vector2(0.0, 1.0), 0), dt)
	assert_near(character.get_horizontal_speed(), character.run_speed * 0.6, 0.02, "×0,6")
	for _i: int in 30:
		tick += 1
		character.simulate(_input(tick, Vector2(0.0, 1.0), PlayerInput.SPRINT), dt)
	assert_near(character.get_horizontal_speed(), character.sprint_speed * 0.6, 0.02,
			"the sprint too")


func test_a_slow_gives_the_same_speed_on_client_and_server() -> void:
	var slowed: StatusTicks = CombatCatalog.status(CombatCatalog.status_id(&"slowed"))
	_pair = PredictionPair.new()
	_pair.server_hook = func(character: PlayerCharacter, tick: int) -> void:
		if tick == SLOW_TICK:
			ActionMachine.impose_move_effect(character.combat, slowed.id, tick + slowed.duration_ticks)
			PredictionPair.commit(character)
	await _pair.build(tree, _run_route, CombatState.initial(CombatCatalog.rules(),
			CombatCatalog.weapon_id(&"sword_shield")))
	var slow_speeds: Array[float] = []
	var free_speeds: Array[float] = []
	var expiry: int = SLOW_TICK + slowed.duration_ticks
	for _frame: int in expiry - PredictionPair.SPAWN_TICK + 40:
		await tree.physics_frame
		var state: PlayerState = _pair.frame()
		var speed: float = Vector2(state.velocity.x, state.velocity.z).length()
		if _pair.server_tick > SLOW_TICK + 30 and _pair.server_tick < expiry:
			slow_speeds.append(speed)
		elif _pair.server_tick > expiry + 20:
			free_speeds.append(speed)
	assert_eq(slowed.duration_ticks, 180, "3 s")
	assert_true(slow_speeds.size() > 100, "slowed ticks (%d)" % slow_speeds.size())
	for speed: float in slow_speeds:
		if absf(speed - 5.0 * 0.6) > 0.02:
			fail("slowed it should run at run_speed · 0.6 (%s)" % speed)
			break
	for speed: float in free_speeds:
		if absf(speed - 5.0) > 0.02:
			fail("on expiry it returns to run_speed (%s)" % speed)
			break
	assert_true(_pair.results_not(ClientPrediction.Result.MATCH).size() >= 1,
			"the client does not predict it: it reconciles")
	var since: int = _pair.converged_since(SLOW_TICK)
	assert_true(since > 0 and since <= SLOW_TICK + 2,
			"and from then on it matches the server every tick, also on expiry (from %d)" % since)
	assert_eq((_pair.server_states[expiry] as PlayerState).combat.move_effect_ids[0], 0,
			"the slot empties at the exact tick")
	assert_eq((_pair.server_states[expiry - 1] as PlayerState).combat.move_effect_ids[0], slowed.id,
			"and not before")


func _driver() -> MachineDriver:
	return MachineDriver.new(CombatCatalog.weapon_id(&"sword_shield"), 0, CombatState.pack_charges(3, 2))


func _run_route(tick: int) -> PlayerInput:
	var input := PlayerInput.new()
	input.tick = tick
	if tick >= 20:
		input.move = Vector2(0.0, 1.0)
	return input


func _input(tick: int, move: Vector2, buttons: int) -> PlayerInput:
	var input := PlayerInput.new()
	input.tick = tick
	input.move = move
	input.buttons = buttons
	return input.quantized()


func _place(character: PlayerCharacter, position: Vector3, velocity: Vector3, grounded: bool) -> void:
	var state := PlayerState.new()
	state.position = position
	state.velocity = velocity
	state.grounded = grounded
	state.combat = character.combat.duplicate_state()
	character.set_state(PlayerState.decode(state.encode()))
	character.reset_physics_interpolation()


func _mutate(path: String, property: StringName, value: Variant) -> void:
	var resource: Resource = load(path)
	_mutations.append([resource, property, resource.get(property)])
	resource.set(property, value)
	CombatCatalog.reload()
