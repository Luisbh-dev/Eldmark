extends TestCase
## The phase-4 kit in [BotBrain] (H5; docs/habilidades.md, section 7.1), without network or physics: the bot's
## combat state is that of an action machine that advances with its own inputs ([ActionMachine]), and the
## enemies and allies are given by hand-written finders. It checks that the bot uses abilities only when they are valid and holds
## the wall button, that it drinks and swaps weapons when due, that the bow aims with the lead shot (the
## arrows computed by [ProjectileLaunch] hit a running target), that it finishes off and gets allies up while holding INTERACT,
## and that without combat state (or with [member BotBrain.use_kit] off) the bot is the phase-3 one.

const START_TICK: int = 1000


## A bot with its action machine: [member c] is its combat state (the one the kit reads), which advances with the
## inputs the bot generates.
class Rig:
	extends RefCounted

	var c: CombatState
	var brain: BotBrain
	var tick: int = START_TICK
	var position: Vector3 = Vector3.ZERO
	var inputs: Array[PlayerInput] = []
	## Tick of each press (edge) of an ability or a consumable -> state of its slot on that tick.
	var presses: Array[Vector3i] = []

	## One tick: the bot's input (quantized, as it travels) and the machine's step.
	func step() -> PlayerInput:
		var t: int = tick + 1
		var input: PlayerInput = brain.next_input(t, position, 0.0).quantized()
		input.tick = t
		var previous: int = inputs[inputs.size() - 1].buttons if not inputs.is_empty() else 0
		for slot: int in 5:
			var button: int = [PlayerInput.ABILITY_1, PlayerInput.ABILITY_2, PlayerInput.ABILITY_3,
					PlayerInput.CONSUMABLE_1, PlayerInput.CONSUMABLE_2][slot]
			if (input.buttons & button) != 0 and (previous & button) == 0:
				presses.append(Vector3i(t, slot, ActionMachine.ability_status(c, slot, t)))
		ActionMachine.step(c, input, true)
		tick = t
		inputs.append(input)
		return input

	func run(count: int) -> void:
		for _i: int in count:
			step()


func _rig(weapon_1: StringName, weapon_2: StringName, charges: int, rng_seed: int = 7,
		enemy: Variant = null) -> Rig:
	var rig := Rig.new()
	rig.c = CombatState.initial(CombatCatalog.rules(), CombatCatalog.weapon_id(weapon_1),
			CombatCatalog.weapon_id(weapon_2) if weapon_2 != &"" else 0, charges)
	rig.brain = BotBrain.new(rng_seed, BotBrain.Pattern.COMBAT, Vector3.ZERO, 30.0)
	# The closure holds the state, not the Rig (which holds the brain): no reference cycles.
	var state: CombatState = rig.c
	rig.brain.set_combat_source(func() -> CombatState: return state)
	if enemy != null:
		rig.brain.set_enemy_finder(func(_position: Vector3) -> Variant: return enemy)
	return rig


func _squire(enemy: Variant, rng_seed: int = 7) -> Rig:
	return _rig(&"sword_shield", &"", CombatState.pack_charges(3, 2), rng_seed, enemy)


# Presses of slot [param slot] (0-2 abilities, 3-4 consumables).
func _presses_of(rig: Rig, slot: int) -> Array[Vector3i]:
	var found: Array[Vector3i] = []
	for press: Vector3i in rig.presses:
		if press.y == slot:
			found.append(press)
	return found


# The longest run of consecutive ticks with [param button] pressed.
func _longest_hold(rig: Rig, button: int) -> int:
	var longest: int = 0
	var run_length: int = 0
	for input: PlayerInput in rig.inputs:
		run_length = run_length + 1 if (input.buttons & button) != 0 else 0
		longest = maxi(longest, run_length)
	return longest


# --- Data ------------------------------------------------------------------------------------

func test_the_role_of_each_ability_comes_from_its_data() -> void:
	var roles: Dictionary[StringName, BotBrain.KitRole] = {
		&"shield_bash": BotBrain.KitRole.CLOSE, &"shield_rush": BotBrain.KitRole.GAP_CLOSER,
		&"shield_wall": BotBrain.KitRole.GUARD, &"bow_volley": BotBrain.KitRole.SHOT,
		&"bow_slowing_shot": BotBrain.KitRole.SHOT, &"bow_evasive_shot": BotBrain.KitRole.ESCAPE,
	}
	for ability_name: StringName in roles:
		assert_eq(BotBrain.kit_role(CombatCatalog.ability(CombatCatalog.ability_id(ability_name))),
				roles[ability_name], "role of %s" % ability_name)
	assert_eq(BotBrain.kit_role(null), BotBrain.KitRole.NONE)
	assert_true(BotBrain.is_ranged_weapon(CombatCatalog.weapon_id(&"bow")), "the bow fires with the light attack")
	assert_false(BotBrain.is_ranged_weapon(CombatCatalog.weapon_id(&"sword_shield")))
	assert_false(BotBrain.is_ranged_weapon(0))


func test_without_a_combat_source_or_with_the_kit_off_it_fights_like_in_phase_3() -> void:
	var enemy := Vector3(2.0, 0.0, 0.0)
	var plain := BotBrain.new(77, BotBrain.Pattern.COMBAT, Vector3.ZERO, 30.0)
	plain.set_enemy_finder(func(_position: Vector3) -> Variant: return enemy)
	var off := BotBrain.new(77, BotBrain.Pattern.COMBAT, Vector3.ZERO, 30.0)
	off.set_enemy_finder(func(_position: Vector3) -> Variant: return BotTarget.new(enemy))
	var state: CombatState = CombatState.initial(CombatCatalog.rules(), CombatCatalog.weapon_id(&"sword_shield"))
	off.set_combat_source(func() -> CombatState: return state)
	off.use_kit = false
	for tick: int in range(1, 601):
		var a: PlayerInput = plain.next_input(tick, Vector3.ZERO, 0.0).quantized()
		var b: PlayerInput = off.next_input(tick, Vector3.ZERO, 0.0).quantized()
		assert_eq(b.encode(), a.encode(), "same inputs, also with a BotTarget (tick %d)" % tick)
	assert_true(off.get_kit_counts().is_empty(), "the kit has done nothing")


# --- Sword and shield --------------------------------------------------------------------------

func test_the_squire_uses_its_abilities_only_when_they_are_ready_and_holds_the_wall() -> void:
	var rig: Rig = _squire(Vector3(0.0, 0.0, -1.6))
	var wall_id: int = CombatCatalog.ability_id(&"shield_wall")
	var wall_ticks: int = 0
	var longest_wall: int = 0
	for _i: int in 4000:
		rig.step()
		if rig.c.action == CombatState.Action.ABILITY and rig.c.action_id == wall_id:
			wall_ticks += 1
			longest_wall = maxi(longest_wall, rig.tick - rig.c.action_tick + 1)
	var counts: Dictionary[StringName, int] = rig.brain.get_kit_counts()
	print("[kit] escudero contra un enemigo a 1,6 m, 4000 ticks: %s" % [counts])
	for press: Vector3i in rig.presses:
		assert_eq(press.z, ActionMachine.AbilityStatus.READY,
				"only presses a ready slot (tick %d, slot %d)" % [press.x, press.y])
	assert_true(_presses_of(rig, 0).size() >= 2, "shield bash (%d)" % _presses_of(rig, 0).size())
	assert_true(_presses_of(rig, 2).size() >= 1, "wall (%d)" % _presses_of(rig, 2).size())
	assert_true(_longest_hold(rig, PlayerInput.ABILITY_3) >= BotBrain.KIT_GUARD_HOLD_TICKS.x,
			"holds the wall button (%d ticks)" % _longest_hold(rig, PlayerInput.ABILITY_3))
	assert_true(longest_wall >= BotBrain.KIT_GUARD_HOLD_TICKS.x,
			"and the channeling lasts as long as it is held (%d ticks)" % longest_wall)
	var bash: AbilityTicks = CombatCatalog.ability(CombatCatalog.ability_id(&"shield_bash"))
	var bash_presses: Array[Vector3i] = _presses_of(rig, 0)
	for index: int in range(1, bash_presses.size()):
		assert_true(bash_presses[index].x - bash_presses[index - 1].x >= bash.cooldown_ticks,
				"two shield bashes, separated by at least their cooldown")
	assert_true(int(counts.get(&"ability_0", 0)) == bash_presses.size(), "the counter keeps the tally")
	assert_true((_count_button(rig, PlayerInput.PRIMARY)) > 0, "and keeps attacking with the sword")


func test_the_squire_closes_the_gap_with_the_rush() -> void:
	var rig: Rig = _squire(Vector3(0.0, 0.0, -5.0))
	rig.run(300)
	var rushes: Array[Vector3i] = _presses_of(rig, 1)
	if not assert_false(rushes.is_empty(), "at 5 m it opens with the charge"):
		return
	assert_eq(rushes[0].z, ActionMachine.AbilityStatus.READY)
	assert_true(_presses_of(rig, 0).is_empty(), "at 5 m it does not use the shield bash, which does not reach")


func test_it_drinks_when_hurt_or_tired_and_only_with_charges_and_off_cooldown() -> void:
	var rig: Rig = _squire(Vector3(0.0, 0.0, -20.0))
	var health: Array[float] = [0.3]
	rig.brain.set_health_source(func() -> float: return health[0])
	rig.run(4000)
	var drinks: Array[Vector3i] = _presses_of(rig, 3)
	assert_eq(drinks.size(), 3, "the shield-bearer's three health charges, not one more (%s)" % [drinks])
	for index: int in range(1, drinks.size()):
		assert_true(drinks[index].x - drinks[index - 1].x >= CombatCatalog.tables().consumable_cooldown_ticks,
				"separated by the shared cooldown")
	assert_eq(rig.c.charges_of(0), 0, "without health charges")
	# Tired and with full health: the stamina one.
	var tired: Rig = _squire(Vector3(0.0, 0.0, -20.0))
	tired.brain.set_health_source(func() -> float: return 1.0)
	tired.c.stamina = 100
	tired.c.stamina_regen_tick = START_TICK + 100000
	tired.run(60)
	assert_eq(_presses_of(tired, 4).size(), 1, "drinks the stamina one")
	assert_true(_presses_of(tired, 3).is_empty(), "and not the health one")
	assert_true(tired.c.stamina >= 400, "+400 stamina (%d)" % tired.c.stamina)


# --- Weapon swap and bow ------------------------------------------------------------------------

func test_the_marksman_swaps_to_the_sword_up_close_and_back_to_the_bow_at_range() -> void:
	var enemy: Array[Vector3] = [Vector3(0.0, 0.0, -3.0)]
	var rig: Rig = _rig(&"bow", &"sword_shield", CombatState.pack_charges(2, 3), 8)
	rig.brain.set_enemy_finder(func(_position: Vector3) -> Variant: return enemy[0])
	rig.run(60)
	assert_eq(rig.c.weapon_id, CombatCatalog.weapon_id(&"sword_shield"), "up close, the sword")
	assert_eq(int(rig.brain.get_kit_counts().get(&"swap", 0)), 1, "one swap")
	enemy[0] = Vector3(0.0, 0.0, -20.0)
	rig.run(60)
	assert_eq(rig.c.weapon_id, CombatCatalog.weapon_id(&"bow"), "from afar, the bow")
	assert_eq(int(rig.brain.get_kit_counts().get(&"swap", 0)), 2, "and another")
	assert_eq(rig.c.ability_ready.size(), 6, "the cooldowns of both weapons are still there")


func test_the_archer_leads_a_running_target_and_its_arrows_hit() -> void:
	# A target at 22 m running sideways at 6 m/s: each arrow that goes out (the one ProjectileLaunch computes with the
	# input of the commit tick, the same calculation as the server) flies against its moving capsule.
	var velocity := Vector3(6.0, 0.0, 0.0)
	var start := Vector3(-30.0, 0.0, -22.0)
	var rig: Rig = _rig(&"bow", &"", CombatState.pack_charges(2, 3), 9)
	var now: Array[int] = [START_TICK]
	rig.brain.set_enemy_finder(func(_position: Vector3) -> Variant:
		return BotTarget.new(start + velocity * (float(now[0] + 1 - START_TICK) / 60.0), velocity))
	var shots: int = 0
	var hits: int = 0
	var drawn: int = 0
	for _i: int in 600:
		var input: PlayerInput = rig.step()
		now[0] = rig.tick
		var launch: ProjectileLaunch = ProjectileLaunch.from_state(rig.c, rig.tick)
		if launch == null:
			continue
		var target_at_commit: Vector3 = start + velocity * (float(rig.tick - START_TICK) / 60.0)
		var arrows: Array[PackedVector3Array] = launch.launch(rig.position, input.look_yaw, input.look_pitch,
				input.has(PlayerInput.AIM_LEFT), null, PackedVector3Array([target_at_commit]))
		var middle: PackedVector3Array = arrows[arrows.size() / 2]
		shots += 1
		if launch.charge_fraction > 0.0:
			drawn += 1
		if _flies_into(middle[0], middle[1], target_at_commit, velocity):
			hits += 1
	print("[kit] arquero contra un blanco que corre a 22 m: %d disparos (%d tensados), %d aciertos; %s" % [
			shots, drawn, hits, rig.brain.get_kit_counts()])
	assert_true(shots >= 8, "fires (%d)" % shots)
	assert_true(drawn >= 1, "also draws (%d)" % drawn)
	assert_true(hits >= shots - 1, "and almost all hit the running target: %d of %d" % [hits, shots])
	assert_true(_longest_hold(rig, PlayerInput.PRIMARY) >= 21, "holds PRIMARY to draw")
	assert_true(rig.inputs.any(func(input: PlayerInput) -> bool: return input.look_pitch > 0.0),
			"aims above the target (the drop)")
	assert_true(rig.inputs.all(func(input: PlayerInput) -> bool: return input.has(PlayerInput.AIM_LEFT)),
			"odd seed: left shoulder on all its inputs")


# true if the arrow leaving [param p0] with [param v0] touches the capsule of a target that starts at
# [param feet] and moves at [param velocity] (each tick's segment against the capsule on that tick).
func _flies_into(p0: Vector3, v0: Vector3, feet: Vector3, velocity: Vector3) -> bool:
	var arrow: ProjectileTicks = CombatCatalog.projectile(CombatCatalog.projectile_id(&"arrow"))
	for n: int in arrow.lifetime_ticks:
		var a: Vector3 = Ballistics.position(p0, v0, arrow.gravity, float(n))
		var b: Vector3 = Ballistics.position(p0, v0, arrow.gravity, float(n + 1))
		var capsule: Vector3 = feet + velocity * (float(n) / 60.0)
		if HitShapes.segment_capsule_fraction(a, b, capsule, HitShapes.CAPSULE_RADIUS + arrow.radius_m,
				HitShapes.CAPSULE_HEIGHT) >= 0.0:
			return true
	return false


func _count_button(rig: Rig, button: int) -> int:
	var count: int = 0
	for input: PlayerInput in rig.inputs:
		if (input.buttons & button) != 0:
			count += 1
	return count


# --- Knocked down ---------------------------------------------------------------------------------

func test_it_executes_a_downed_enemy_holding_interact() -> void:
	var rig: Rig = _squire(BotTarget.new(Vector3(0.0, 0.0, -1.0), Vector3.ZERO, true, 42))
	rig.run(100)
	var held: int = _longest_hold(rig, PlayerInput.INTERACT)
	assert_true(held >= CombatCatalog.tables().execute_ticks,
			"holds INTERACT for the length of the finishing blow (%d ticks)" % held)
	assert_eq(_count_button(rig, PlayerInput.PRIMARY), 0, "does not hit it: finishes it off")
	assert_true(int(rig.brain.get_kit_counts().get(&"execute", 0)) >= 1, "counts the finishing blow")
	# From afar, it goes toward it.
	var far: Rig = _squire(BotTarget.new(Vector3(0.0, 0.0, -6.0), Vector3.ZERO, true, 42))
	var input: PlayerInput = far.step()
	assert_eq(input.move, Vector2(0.0, 1.0), "approaches the knocked-down character")
	assert_false(input.has(PlayerInput.INTERACT), "without pressing yet")


func test_it_revives_a_downed_ally_when_no_enemy_is_close() -> void:
	var rig: Rig = _squire(null)
	var ally: Array[Vector3] = [Vector3(0.0, 0.0, -5.0)]
	rig.brain.set_ally_finder(func(_position: Vector3) -> Variant: return ally[0])
	var input: PlayerInput = rig.step()
	assert_eq(input.move, Vector2(0.0, 1.0), "goes toward the knocked-down ally")
	assert_near(angle_difference(input.look_yaw, 0.0), 0.0, 1e-3, "facing it (toward -Z)")
	ally[0] = Vector3(0.0, 0.0, -1.0)
	rig.run(200)
	var held: int = _longest_hold(rig, PlayerInput.INTERACT)
	assert_true(held >= CombatCatalog.tables().revive_ticks, "holds INTERACT for as long as getting it up takes (%d)" % held)
	assert_true(int(rig.brain.get_kit_counts().get(&"revive", 0)) >= 1, "counts the revive")
	# With a standing enemy on top, it fights.
	var busy: Rig = _squire(Vector3(0.0, 0.0, -2.0))
	busy.brain.set_ally_finder(func(_position: Vector3) -> Variant: return Vector3(1.0, 0.0, 0.0))
	busy.run(200)
	assert_eq(int(busy.brain.get_kit_counts().get(&"revive", 0)), 0, "with the enemy at 2 m it does not start reviving")


func test_the_kit_is_deterministic_with_the_seed() -> void:
	var first: Rig = _rig(&"bow", &"sword_shield", CombatState.pack_charges(2, 3), 21, Vector3(0.0, 0.0, -14.0))
	var second: Rig = _rig(&"bow", &"sword_shield", CombatState.pack_charges(2, 3), 21, Vector3(0.0, 0.0, -14.0))
	first.run(1500)
	second.run(1500)
	for index: int in first.inputs.size():
		assert_eq(first.inputs[index].encode(), second.inputs[index].encode(), "tick %d" % first.inputs[index].tick)
	assert_eq(first.c.ability_ready, second.c.ability_ready, "and the same state")


func test_load_test_archers_never_swap_to_the_sword_and_can_aim_at_the_sky() -> void:
	var rig: Rig = _rig(&"bow", &"sword_shield", CombatState.pack_charges(2, 3), 8, Vector3(0.0, 0.0, -3.0))
	rig.brain.kit_ranged_only = true
	rig.run(120)
	assert_eq(rig.c.weapon_id, CombatCatalog.weapon_id(&"bow"), "a pure archer does not draw the sword up close")
	assert_eq(int(rig.brain.get_kit_counts().get(&"swap", 0)), 0)
	assert_true(_count_button(rig, PlayerInput.PRIMARY) > 0, "and keeps firing")
	# With the sword in hand it goes back to the bow even if the enemy is near.
	var melee: Rig = _rig(&"sword_shield", &"bow", CombatState.pack_charges(2, 3), 8, Vector3(0.0, 0.0, -3.0))
	melee.brain.kit_ranged_only = true
	melee.run(60)
	assert_eq(melee.c.weapon_id, CombatCatalog.weapon_id(&"bow"), "goes back to the bow")
	# Skyward: the same aim, higher.
	var plain: Rig = _rig(&"bow", &"", CombatState.pack_charges(2, 3), 8, Vector3(0.0, 0.0, -20.0))
	var sky: Rig = _rig(&"bow", &"", CombatState.pack_charges(2, 3), 8, Vector3(0.0, 0.0, -20.0))
	sky.brain.kit_aim_raise = 0.8
	var a: PlayerInput = plain.step()
	var b: PlayerInput = sky.step()
	assert_near(b.look_pitch - a.look_pitch, 0.8, 0.01, "raises the aim by what is asked")
