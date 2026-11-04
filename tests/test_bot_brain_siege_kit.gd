extends TestCase
## The phase-4 kit (H5; docs/abilities.md, section 7.1) in F6b's siege pattern ([constant
## BotBrain.Pattern.SIEGE]; docs/fortress.md, sections 7 and 8.3), without network or physics: a point that moves where
## the inputs say, with an action machine that advances with them ([KitWalker]), the real Vado Gris fort and its
## routes. It checks what the integration of the two branches demands: the siege bot fights with the kit in step 1 of
## its plan, also against the defending NPC (who is still targeted before a closer player, and whom the bow aims at with its
## velocity); with the bow in hand it does not stop firing because of the chase rule (the sword does follow it); on
## the walkway the archer takes no steps sideways; it does not revive anyone (it follows its plan), and it is deterministic.
## [br]And what the integration review adds (docs/fortress.md 8.3): on the walkway it faces the enemy (the sword
## reaches it even if it is sideways) and moves along the axis; the bow only fires within range (not through a closed gate, nor its
## own, nor through the palisade; with the gate broken, through the doorway; and whatever the line of fire says), up to
## [constant BotBrain.SIEGE_BOW_FIGHT_RANGE], it draws the bow when holding the sword, it fires at another level (the level
## filter is for melee), going to finish someone off carries the chase rule and the gate is hit with the sword.
## The real physics is in [code]test_siege_archers[/code].

const V: int = NetProtocol.Realm.VARDHEIM
const S: int = NetProtocol.Realm.SOLMARCH
const ROUTES_PATH: String = "res://data/routes/vado_gris.tres"
## Gate and circle of Vado Gris (the fort is at the origin; north = -Z), as in test_bot_brain_siege.
const GATE: Vector3 = Vector3(-20.0, 0.0, 0.0)
const CIRCLE: Vector3 = Vector3(-8.5, 0.0, 0.0)
const CIRCLE_RADIUS: float = 5.0
const WALK_SPEED: float = 5.0
const SPRINT_SPEED: float = 7.5
const TICKS_PER_SECOND: float = 60.0
const START_TICK: int = 1000

var _routes: ApproachRoutes = null
var _view: SiegeView = null


## A point that obeys the inputs (no collisions; with [member blocked] it does not move) and carries the combat state
## the kit reads: an action machine that advances with those same inputs.
class KitWalker:
	extends RefCounted

	var c: CombatState
	var position: Vector3 = Vector3.ZERO
	var yaw: float = 0.0
	var blocked: bool = false
	var tick: int = START_TICK
	var inputs: Array[PlayerInput] = []
	## Each press (edge) of an ability or a consumable: (tick, slot, slot state on that tick).
	var presses: Array[Vector3i] = []


	func _init(state: CombatState, start: Vector3) -> void:
		c = state
		position = start


	func step(brain: BotBrain) -> PlayerInput:
		var t: int = tick + 1
		var input: PlayerInput = brain.next_input(t, position, yaw).quantized()
		input.tick = t
		var previous: int = inputs[inputs.size() - 1].buttons if not inputs.is_empty() else 0
		for slot: int in 5:
			var button: int = [PlayerInput.ABILITY_1, PlayerInput.ABILITY_2, PlayerInput.ABILITY_3,
					PlayerInput.CONSUMABLE_1, PlayerInput.CONSUMABLE_2][slot]
			if (input.buttons & button) != 0 and (previous & button) == 0:
				presses.append(Vector3i(t, slot, ActionMachine.ability_status(c, slot, t)))
		ActionMachine.step(c, input, true)
		yaw = input.look_yaw
		if not blocked and input.move.length() > 0.0:
			var forward := Vector3(-sin(yaw), 0.0, -cos(yaw))
			var right := Vector3(cos(yaw), 0.0, -sin(yaw))
			var speed: float = SPRINT_SPEED if input.has(PlayerInput.SPRINT) else WALK_SPEED
			position += (forward * input.move.y + right * input.move.x) * speed / TICKS_PER_SECOND
		tick = t
		inputs.append(input)
		return input


func before_each() -> void:
	_routes = load(ROUTES_PATH) as ApproachRoutes
	_view = SiegeView.new()
	_view.fortress_id = &"vado_gris_fort"
	_view.set_places(GATE, CIRCLE, CIRCLE_RADIUS)
	# A neutral fort with the captain alive (the circle is not active: the defenders go first) and the gate broken.
	_view.known = true
	_view.owner = 0
	_view.phase = FortressState.Phase.GARRISONED
	_view.gate_health = 0
	_view.gate_max = 9000


func _squire_state() -> CombatState:
	return CombatState.initial(CombatCatalog.rules(), CombatCatalog.weapon_id(&"sword_shield"), 0,
			CombatState.pack_charges(3, 2))


func _marksman_state() -> CombatState:
	return CombatState.initial(CombatCatalog.rules(), CombatCatalog.weapon_id(&"bow"),
			CombatCatalog.weapon_id(&"sword_shield"), CombatState.pack_charges(2, 3))


## A Vardheim siege brain without the walkway role that reads the state of [param walker].
func _brain(walker: KitWalker, rng_seed: int) -> BotBrain:
	var brain := BotBrain.new(rng_seed, BotBrain.Pattern.SIEGE)
	brain.set_siege(_view, _routes, V)
	brain.set_walkway_role(false)
	# The closure holds the state, not the KitWalker: no reference cycles.
	var state: CombatState = walker.c
	brain.set_combat_source(func() -> CombatState: return state)
	return brain


# The yaw (PlayerInput convention: 0 looks toward -Z) that looks from [param from] to [param to].
func _yaw_to(from: Vector3, to: Vector3) -> float:
	return fposmod(atan2(-(to.x - from.x), -(to.z - from.z)), TAU)


func _angle_gap(a: float, b: float) -> float:
	return absf(angle_difference(a, b))


# Where [param input] moves in the world (the simulation moves relative to its look_yaw).
func _world_move(input: PlayerInput) -> Vector3:
	var forward := Vector3(-sin(input.look_yaw), 0.0, -cos(input.look_yaw))
	var right := Vector3(cos(input.look_yaw), 0.0, -sin(input.look_yaw))
	return forward * input.move.y + right * input.move.x


# Bow shots the kit has decided on (quick, drawn and shooting abilities).
func _shots(brain: BotBrain) -> int:
	var counts: Dictionary[StringName, int] = brain.get_kit_counts()
	return counts.get(&"quick", 0) + counts.get(&"drawn", 0)


# The archer template with the sword in hand (as after a weapon swap) and the bow on the back.
func _marksman_sword_state() -> CombatState:
	return CombatState.initial(CombatCatalog.rules(), CombatCatalog.weapon_id(&"sword_shield"),
			CombatCatalog.weapon_id(&"bow"), CombatState.pack_charges(2, 3))


# --- Tests ----------------------------------------------------------------------------------

func test_against_the_defender_npc_the_squire_fights_with_its_kit() -> void:
	var walker := KitWalker.new(_squire_state(), CIRCLE + Vector3(-3.0, 0.0, 0.0))
	var brain: BotBrain = _brain(walker, 41)
	var npc: Vector3 = walker.position + Vector3(1.6, 0.0, 0.0)
	var player: Vector3 = walker.position + Vector3(0.0, 0.0, 1.2)
	brain.set_enemy_finder(func(_position: Vector3) -> Variant: return BotTarget.new(player))
	brain.set_defender_finder(func(_position: Vector3) -> Variant: return BotTarget.new(npc))
	var fighting: int = 0
	for _i: int in 3000:
		walker.step(brain)
		fighting += 1 if brain.get_siege_task() == BotBrain.SiegeTask.FIGHT else 0
	var counts: Dictionary[StringName, int] = brain.get_kit_counts()
	print("[asedio con kit] escudero contra el PNJ defensor, 3000 ticks: %s" % [counts])
	assert_eq(fighting, 3000, "fights the whole time (step 1 of its plan)")
	assert_true(_angle_gap(walker.yaw, _yaw_to(walker.position, npc)) < 0.3,
			"with the defending NPC even though the player is closer (yaw %.2f)" % walker.yaw)
	assert_true(counts.get(&"ability_0", 0) + counts.get(&"ability_2", 0) >= 2,
			"with the shield-bearer's abilities (%s)" % [counts])
	for press: Vector3i in walker.presses:
		assert_eq(press.z, ActionMachine.AbilityStatus.READY,
				"only presses a ready slot (tick %d, slot %d)" % [press.x, press.y])


func test_the_bow_aims_at_the_defender_npc_leading_it_by_its_velocity() -> void:
	# The defender, 10 m to the east and running south; a player 6 m to the west. The bow aims at the defender (the fight's
	# target) and ahead of it: with its velocity, farther south than without it.
	var yaws: Array[float] = []
	var direct: float = 0.0
	for velocity: Vector3 in [Vector3.ZERO, Vector3(0.0, 0.0, 4.0)]:
		var walker := KitWalker.new(_marksman_state(), CIRCLE + Vector3(-3.0, 0.0, 0.0))
		walker.blocked = true
		var brain: BotBrain = _brain(walker, 42)
		var npc: Vector3 = walker.position + Vector3(10.0, 0.0, 0.0)
		var player: Vector3 = walker.position + Vector3(-6.0, 0.0, 0.0)
		brain.set_enemy_finder(func(_position: Vector3) -> Variant: return BotTarget.new(player))
		brain.set_defender_finder(func(_position: Vector3) -> Variant: return BotTarget.new(npc, velocity))
		# A tick on which it has just looked at where it is (every COMBAT_RETARGET_TICKS): without extrapolating the position.
		for _i: int in 1 + BotBrain.COMBAT_RETARGET_TICKS * 3:
			walker.step(brain)
		assert_eq(brain.get_siege_task(), BotBrain.SiegeTask.FIGHT)
		yaws.append(walker.yaw)
		direct = _yaw_to(walker.position, npc)
		assert_true(_angle_gap(walker.yaw, direct) < 0.4,
				"at the defender (yaw %.3f, direct %.3f) and not at the player" % [walker.yaw, direct])
	# Toward +Z the yaw goes down (east is 3π/2 and south, π): leading to the south is a smaller yaw.
	assert_true(yaws[1] < yaws[0] - 0.02,
			"with the defender's velocity it aims ahead of it (%.3f versus %.3f)" % [yaws[1], yaws[0]])


func test_with_the_bow_in_hand_it_keeps_shooting_instead_of_giving_up_the_chase() -> void:
	# F6b gives up a chase that does not bring it closer within SIEGE_STUCK_TICKS; the archer does not chase (the whole SIEGE_FIGHT_RANGE is
	# firing distance), so it keeps shooting. With the sword, the rule applies the same as without the kit.
	var archer := KitWalker.new(_marksman_state(), CIRCLE + Vector3(-1.0, 0.0, 0.0))
	archer.blocked = true
	var archer_brain: BotBrain = _brain(archer, 35)
	var foe: Vector3 = archer.position + Vector3(0.0, 0.0, -10.0)
	archer_brain.set_enemy_finder(func(_position: Vector3) -> Variant: return BotTarget.new(foe))
	var fighting: int = 0
	for _i: int in 900:
		archer.step(archer_brain)
		fighting += 1 if archer_brain.get_siege_task() == BotBrain.SiegeTask.FIGHT else 0
	var counts: Dictionary[StringName, int] = archer_brain.get_kit_counts()
	assert_eq(fighting, 900, "does not stop fighting the one at 10 m")
	assert_true(counts.get(&"quick", 0) + counts.get(&"drawn", 0) >= 5, "and shoots at it (%s)" % [counts])

	var squire := KitWalker.new(_squire_state(), CIRCLE + Vector3(-1.0, 0.0, 0.0))
	squire.blocked = true
	var squire_brain: BotBrain = _brain(squire, 35)
	squire_brain.set_enemy_finder(func(_position: Vector3) -> Variant: return BotTarget.new(foe))
	var gave_up: int = -1
	for i: int in 600:
		squire.step(squire_brain)
		if squire_brain.get_siege_task() != BotBrain.SiegeTask.FIGHT:
			gave_up = i + 1
			break
	assert_true(gave_up >= BotBrain.SIEGE_STUCK_TICKS
			and gave_up <= BotBrain.SIEGE_STUCK_TICKS + 2 * BotBrain.COMBAT_RETARGET_TICKS,
			"with the sword it gives up the chase after %d ticks without getting closer (%d)" % [BotBrain.SIEGE_STUCK_TICKS, gave_up])


func test_an_archer_on_the_walkway_never_steps_sideways() -> void:
	# A walkway guard (the fort is theirs) with the bow and an enemy coming along it at 10 m: it keeps its distance
	# without the archer's sidesteps (with no inner railing, it would fall into the courtyard).
	_view.owner = V
	_view.gate_health = 9000
	_view.enclosure_size = Vector2(40.0, 40.0)
	var walker := KitWalker.new(_marksman_state(), Vector3(-18.77, _routes.walkway_height, 0.0))
	walker.blocked = true
	var brain := BotBrain.new(43, BotBrain.Pattern.SIEGE)
	brain.set_siege(_view, _routes, V)
	brain.set_walkway_role(true)
	var state: CombatState = walker.c
	brain.set_combat_source(func() -> CombatState: return state)
	var foe := Vector3(-18.77, _routes.walkway_height, 10.0)
	brain.set_enemy_finder(func(_position: Vector3) -> Variant: return BotTarget.new(foe))
	assert_true(brain.is_on_walkway(walker.position), "is on the walkway")
	var sideways: int = 0
	for _i: int in 900:
		var input: PlayerInput = walker.step(brain)
		assert_eq(brain.get_siege_task(), BotBrain.SiegeTask.FIGHT)
		sideways += 1 if absf(input.move.x) > 0.01 else 0
	var counts: Dictionary[StringName, int] = brain.get_kit_counts()
	assert_eq(sideways, 0, "no sidesteps on the walkway")
	assert_true(counts.get(&"quick", 0) + counts.get(&"drawn", 0) >= 5, "and shoots (%s)" % [counts])
	# In the courtyard (not on the walkway), the same archer does move sideways between shots.
	var below := KitWalker.new(_marksman_state(), CIRCLE)
	below.blocked = true
	var other: BotBrain = _brain(below, 43)
	var near := CIRCLE + Vector3(0.0, 0.0, 10.0)
	other.set_enemy_finder(func(_position: Vector3) -> Variant: return BotTarget.new(near))
	var strafes: int = 0
	for _i: int in 900:
		strafes += 1 if absf(below.step(other).move.x) > 0.01 else 0
	assert_true(strafes > 0, "in the courtyard, sideways (%d ticks)" % strafes)


func test_fighting_on_the_walkway_it_faces_the_foe_moves_along_the_axis_and_never_dashes() -> void:
	# With the enemy almost alongside (0.37 m toward the courtyard and 0.1 along), a "backward" dodge away from it threw it off
	# the walkway. The integration made it look along the axis, and then the one alongside was untouchable for it (integration
	# review, docs/fortress.md 8.3): it faces the enemy, but what it moves (approaching, the dodge) goes along the axis, and it does not use
	# the charge (advances 6 m and pushes), with the kit and without it.
	_view.owner = V
	_view.gate_health = 9000
	_view.enclosure_size = Vector2(40.0, 40.0)
	for with_kit: bool in [true, false]:
		var walker := KitWalker.new(_squire_state(), Vector3(-18.77, _routes.walkway_height, 0.0))
		walker.blocked = true
		var brain := BotBrain.new(46, BotBrain.Pattern.SIEGE)
		brain.set_siege(_view, _routes, V)
		brain.set_walkway_role(true)
		if with_kit:
			var state: CombatState = walker.c
			brain.set_combat_source(func() -> CombatState: return state)
		var foe := Vector3(-18.4, _routes.walkway_height, 0.1)
		brain.set_enemy_finder(func(_position: Vector3) -> Variant: return BotTarget.new(foe))
		var away: int = 0
		var across: int = 0
		var dodges: int = 0
		var side_dodges: int = 0
		for _i: int in 1800:
			var input: PlayerInput = walker.step(brain)
			assert_eq(brain.get_siege_task(), BotBrain.SiegeTask.FIGHT)
			away += 1 if _angle_gap(input.look_yaw, _yaw_to(walker.position, foe)) > 0.1 else 0
			# The axis is the gate's wall (x = -18.77): along the axis is toward ±Z in the world.
			var world: Vector3 = _world_move(input)
			across += 1 if world.length() > 0.01 and absf(world.x) > 0.1 * world.length() else 0
			if input.has(PlayerInput.DODGE):
				dodges += 1
				var dodge_yaw: float = input.look_yaw + atan2(-input.move.x, input.move.y)
				side_dodges += 1 if absf(sin(dodge_yaw)) > 0.1 else 0
		var counts: Dictionary[StringName, int] = brain.get_kit_counts()
		assert_eq(away, 0, "kit %s: always faces the enemy" % with_kit)
		assert_eq(across, 0, "kit %s: what it moves goes along the axis" % with_kit)
		assert_true(dodges > 0, "kit %s: there was some dodge (%d)" % [with_kit, dodges])
		assert_eq(side_dodges, 0, "kit %s: and along the axis, not toward the courtyard" % with_kit)
		assert_false(counts.has(&"ability_1"), "kit %s: without the charge on the walkway (%s)" % [with_kit, counts])
		if with_kit:
			assert_true(counts.get(&"ability_0", 0) + counts.get(&"ability_2", 0) > 0,
					"with the shield bash and the wall, which do not move (%s)" % [counts])
	# At 5 m along the axis, the charge distance: in the courtyard it uses it; on the walkway, no.
	for up: bool in [true, false]:
		var height: float = _routes.walkway_height if up else 0.0
		var walker := KitWalker.new(_squire_state(), Vector3(-18.77 if up else -14.0, height, 0.0))
		walker.blocked = true
		var brain := BotBrain.new(47, BotBrain.Pattern.SIEGE)
		brain.set_siege(_view, _routes, V)
		brain.set_walkway_role(up)
		var state: CombatState = walker.c
		brain.set_combat_source(func() -> CombatState: return state)
		var foe := walker.position + Vector3(0.0, 0.0, 5.0)
		brain.set_enemy_finder(func(_position: Vector3) -> Variant: return BotTarget.new(foe))
		for _i: int in 1800:
			walker.step(brain)
		var rushes: int = brain.get_kit_counts().get(&"ability_1", 0)
		if up:
			assert_eq(rushes, 0, "on the walkway, no charge")
		else:
			assert_true(rushes > 0, "in the courtyard, the charge (%d)" % rushes)


func test_a_siege_bot_follows_its_plan_and_does_not_revive_allies() -> void:
	# H5: the siege ones use the kit when fighting but revive no one (they follow their plan). A knocked-down ally at 2 m and no
	# enemy: it continues toward the circle without pressing INTERACT.
	var walker := KitWalker.new(_squire_state(), CIRCLE + Vector3(-4.0, 0.0, 0.0))
	var brain: BotBrain = _brain(walker, 44)
	var ally: Vector3 = walker.position + Vector3(0.0, 0.0, 2.0)
	brain.set_ally_finder(func(_position: Vector3) -> Variant: return ally)
	for _i: int in 300:
		var input: PlayerInput = walker.step(brain)
		assert_false(input.has(PlayerInput.INTERACT), "does not revive the ally")
		assert_true(brain.get_siege_task() != BotBrain.SiegeTask.FIGHT, "there is no one to fight")
	assert_eq(brain.get_siege_task(), BotBrain.SiegeTask.HOLD, "is in the circle")
	assert_false(brain.get_kit_counts().has(&"revive"))


func test_the_kit_in_the_siege_is_deterministic() -> void:
	var traces: Array[PackedByteArray] = []
	for _run: int in 2:
		var walker := KitWalker.new(_marksman_state(), CIRCLE + Vector3(-3.0, 0.0, 0.0))
		var brain: BotBrain = _brain(walker, 45)
		var npc: Vector3 = walker.position + Vector3(4.0, 0.0, 0.0)
		var player: Vector3 = walker.position + Vector3(0.0, 0.0, 8.0)
		brain.set_enemy_finder(func(_position: Vector3) -> Variant: return BotTarget.new(player))
		brain.set_defender_finder(func(position: Vector3) -> Variant:
			return BotTarget.new(npc, Vector3(0.0, 0.0, 2.0)) if position.x < CIRCLE.x + 2.0 else null)
		var trace := PackedByteArray()
		for _i: int in 1500:
			trace.append_array(walker.step(brain).encode())
		traces.append(trace)
	assert_eq(traces[0], traces[1], "same inputs with the same seed and the same world")


func test_on_the_walkway_its_sword_reaches_a_foe_right_beside_it() -> void:
	# The integration review's probe: facing along the axis, the enemy stuck alongside (0.9 or 1.2 m to the side and
	# almost nothing along) fell outside the sword's sector (100°). Facing it, it reaches, with the kit and without it.
	_view.owner = V
	_view.gate_health = 9000
	_view.enclosure_size = Vector2(40.0, 40.0)
	var sword: AttackTicks = CombatCatalog.attack(
			CombatCatalog.weapon(CombatCatalog.weapon_id(&"sword_shield")).light_ids[0])
	for with_kit: bool in [false, true]:
		for lateral: float in [0.6, 0.9, 1.2]:
			for along: float in [0.0, 0.2, 0.5]:
				var brain := BotBrain.new(43, BotBrain.Pattern.SIEGE)
				brain.set_siege(_view, _routes, V)
				brain.set_walkway_role(true)
				var me: Vector3 = brain.get_walkway_post() as Vector3
				var offset: float = _routes.walkway_offset(Vector2(me.x, me.z))
				var a: Vector2 = _routes.walkway_point(offset - 0.25)
				var b: Vector2 = _routes.walkway_point(offset + 0.25)
				var tangent := Vector3(b.x - a.x, 0.0, b.y - a.y).normalized()
				var normal := Vector3(-tangent.z, 0.0, tangent.x)
				var foe: Vector3 = me + tangent * along + normal * lateral
				var state: CombatState = _squire_state()
				if with_kit:
					brain.set_combat_source(func() -> CombatState: return state)
				brain.set_enemy_finder(func(_position: Vector3) -> Variant: return BotTarget.new(foe))
				var yaw: float = atan2(-tangent.x, -tangent.z)
				for t: int in 40:
					yaw = brain.next_input(START_TICK + t, me, yaw).look_yaw
				assert_eq(brain.get_siege_task(), BotBrain.SiegeTask.FIGHT)
				assert_true(HitShapes.sector_hits_capsule(me, yaw, sword.shape, foe, HitShapes.CAPSULE_RADIUS,
						HitShapes.CAPSULE_HEIGHT), "kit %s, %.1f m to the side and %.1f along: the sword reaches it" % [
						with_kit, lateral, along])


func test_the_archer_never_shoots_through_a_closed_gate_not_even_its_own() -> void:
	# Integration review (docs/fortress.md 8.3): the owner saw those outside as "reachable" (its gate does not block
	# its way), but its body blocked the view for arrows in both directions: 70 of 70 arrows into its own gate. With the
	# gate intact nobody shoots from inside out or from outside in; broken, only through the doorway.
	_view.owner = V
	_view.gate_health = 9000
	_view.enclosure_size = Vector2(40.0, 40.0)
	var owner := KitWalker.new(_marksman_state(), CIRCLE + Vector3(-3.0, 0.0, 0.0))
	owner.blocked = true
	var owner_brain: BotBrain = _brain(owner, 50)
	var at_gate := GATE + Vector3(-2.3, 0.0, 0.0)
	owner_brain.set_enemy_finder(func(_position: Vector3) -> Variant: return BotTarget.new(at_gate))
	var outside := KitWalker.new(_marksman_state(), GATE + Vector3(-8.0, 0.0, 0.0))
	outside.blocked = true
	var outside_brain := BotBrain.new(51, BotBrain.Pattern.SIEGE)
	outside_brain.set_siege(_view, _routes, S)
	outside_brain.set_walkway_role(false)
	var outside_state: CombatState = outside.c
	outside_brain.set_combat_source(func() -> CombatState: return outside_state)
	var in_yard := CIRCLE + Vector3(-3.0, 0.0, 0.0)
	outside_brain.set_enemy_finder(func(_position: Vector3) -> Variant: return BotTarget.new(in_yard))
	for _i: int in 600:
		owner.step(owner_brain)
		outside.step(outside_brain)
		assert_true(owner_brain.get_siege_task() != BotBrain.SiegeTask.FIGHT, "the owner does not shoot at its gate")
		assert_true(outside_brain.get_siege_task() != BotBrain.SiegeTask.FIGHT, "nor the one outside at the closed gate")
	assert_eq(_shots(owner_brain) + _shots(outside_brain), 0)
	# Broken: both on the gate's axis, through the doorway, shoot each other.
	_view.gate_health = 0
	var dueling: int = 0
	for _i: int in 600:
		owner.step(owner_brain)
		dueling += 1 if owner_brain.get_siege_task() == BotBrain.SiegeTask.FIGHT else 0
	assert_eq(dueling, 600, "with the gate broken, the owner shoots through the doorway at the one at the gate")
	assert_true(_shots(owner_brain) >= 5, "and shoots at it (%s)" % [owner_brain.get_kit_counts()])


func test_with_the_gate_broken_it_only_shoots_through_the_opening() -> void:
	# Integration review: with the gate broken, a target less than 12 m away behind the palisade seemed reachable
	# and the archer kept shooting at the wood (52 of 80 arrows into the world; two of four did not get in within 30 s). If the
	# line does not pass through the doorway, it follows its plan: it enters the fort.
	_view.enclosure_size = Vector2(40.0, 40.0)
	var walker := KitWalker.new(_marksman_state(), GATE + Vector3(-4.0, 0.0, 7.0))
	var brain: BotBrain = _brain(walker, 52)
	var npc := GATE + Vector3(6.0, 0.0, 8.0)
	brain.set_defender_finder(func(_position: Vector3) -> Variant: return BotTarget.new(npc))
	var first_inside: int = -1
	for i: int in 900:
		walker.step(brain)
		if first_inside < 0 and _view.is_inside_enclosure(walker.position, 0.5) == 1:
			first_inside = i
		if i < 60:
			assert_true(brain.get_siege_task() != BotBrain.SiegeTask.FIGHT,
					"in front of the palisade, with no shot at the NPC inside (tick %d, %s)" % [i, walker.position])
	assert_true(first_inside >= 0, "enters the fort through the gate (%s)" % walker.position)
	assert_eq(brain.get_siege_task(), BotBrain.SiegeTask.FIGHT, "and inside it shoots at it")
	assert_true(_shots(brain) > 0, "(%s)" % [brain.get_kit_counts()])
	# On the gate's axis, from outside in through the doorway, it does shoot at it.
	var aligned := KitWalker.new(_marksman_state(), GATE + Vector3(-8.0, 0.0, 0.5))
	aligned.blocked = true
	var aligned_brain: BotBrain = _brain(aligned, 53)
	var through := GATE + Vector3(6.0, 0.0, 0.0)
	aligned_brain.set_defender_finder(func(_position: Vector3) -> Variant: return BotTarget.new(through))
	for _i: int in 300:
		aligned.step(aligned_brain)
		assert_eq(aligned_brain.get_siege_task(), BotBrain.SiegeTask.FIGHT, "through the doorway it has a shot")
	assert_true(_shots(aligned_brain) > 0)


func test_the_line_of_sight_decides_the_shot_and_is_asked_once_per_search() -> void:
	# In the courtyard and at 10 m, whatever the line of fire says (the server and --bot: the ray of its world).
	var clear: Array[bool] = [false]
	var asked: Array[int] = [0]
	var walker := KitWalker.new(_marksman_state(), CIRCLE + Vector3(-1.0, 0.0, 0.0))
	walker.blocked = true
	var brain: BotBrain = _brain(walker, 54)
	brain.set_line_of_sight(func(_from: Vector3, _to: Vector3, _left: bool) -> bool:
		asked[0] += 1
		return clear[0])
	assert_true(brain.has_line_of_sight())
	var foe: Vector3 = walker.position + Vector3(0.0, 0.0, -10.0)
	brain.set_enemy_finder(func(_position: Vector3) -> Variant: return BotTarget.new(foe))
	for _i: int in 300:
		walker.step(brain)
		assert_true(brain.get_siege_task() != BotBrain.SiegeTask.FIGHT, "without a line of fire it does not shoot at it")
	assert_eq(_shots(brain), 0)
	assert_true(asked[0] <= 300 / BotBrain.COMBAT_RETARGET_TICKS + 1,
			"one query per target search (%d in 300 ticks)" % asked[0])
	clear[0] = true
	var fighting: int = 0
	for _i: int in 300:
		walker.step(brain)
		fighting += 1 if brain.get_siege_task() == BotBrain.SiegeTask.FIGHT else 0
	assert_true(fighting >= 300 - BotBrain.COMBAT_RETARGET_TICKS, "with it, yes (%d)" % fighting)
	assert_true(_shots(brain) > 0)


func test_the_bow_fights_further_than_the_sword() -> void:
	# At 16 m: the archer shoots at it (SIEGE_BOW_FIGHT_RANGE); the shield-bearer follows its plan (SIEGE_FIGHT_RANGE).
	var archer := KitWalker.new(_marksman_state(), CIRCLE)
	archer.blocked = true
	var archer_brain: BotBrain = _brain(archer, 55)
	var foe := CIRCLE + Vector3(0.0, 0.0, 16.0)
	archer_brain.set_enemy_finder(func(_position: Vector3) -> Variant: return BotTarget.new(foe))
	var squire := KitWalker.new(_squire_state(), CIRCLE)
	squire.blocked = true
	var squire_brain: BotBrain = _brain(squire, 55)
	squire_brain.set_enemy_finder(func(_position: Vector3) -> Variant: return BotTarget.new(foe))
	var archer_fights: int = 0
	var squire_fights: int = 0
	for _i: int in 600:
		archer.step(archer_brain)
		squire.step(squire_brain)
		archer_fights += 1 if archer_brain.get_siege_task() == BotBrain.SiegeTask.FIGHT else 0
		squire_fights += 1 if squire_brain.get_siege_task() == BotBrain.SiegeTask.FIGHT else 0
	assert_eq(archer_fights, 600, "the archer shoots at 16 m")
	assert_true(_shots(archer_brain) >= 5, "(%s)" % [archer_brain.get_kit_counts()])
	assert_eq(squire_fights, 0, "the shield-bearer does not fight at 16 m")


func test_with_the_sword_in_hand_it_draws_the_bow_for_a_far_target_without_closing_in() -> void:
	# The shooter that drew the sword (up close, or for the gate) goes back to the bow with a target in range and far: at 15 m.
	var walker := KitWalker.new(_marksman_sword_state(), CIRCLE)
	var brain: BotBrain = _brain(walker, 56)
	var foe := CIRCLE + Vector3(0.0, 0.0, 15.0)
	brain.set_enemy_finder(func(_position: Vector3) -> Variant: return BotTarget.new(foe))
	var bow: int = CombatCatalog.weapon_id(&"bow")
	var swapped_at: int = -1
	for i: int in 600:
		walker.step(brain)
		assert_eq(brain.get_siege_task(), BotBrain.SiegeTask.FIGHT)
		if swapped_at < 0:
			assert_true(walker.position.distance_to(CIRCLE) < 0.01, "while drawing the bow it does not approach with the sword")
			if walker.c.weapon_id == bow:
				swapped_at = i
	assert_true(swapped_at >= 0 and swapped_at < 120, "draws the bow (tick %d)" % swapped_at)
	assert_true(_shots(brain) > 0, "and shoots (%s)" % [brain.get_kit_counts()])


func test_the_level_filter_is_for_the_sword_the_bow_shoots_across_levels() -> void:
	# GUE-45: inside the enclosure, whoever is at another level cannot be reached with the sword. With the bow they can, if there is a shot: a
	# walkway guard shoots at the courtyard, and one in the courtyard with the sword in hand draws the bow for the one on the walkway.
	_view.owner = V
	_view.gate_health = 9000
	_view.enclosure_size = Vector2(40.0, 40.0)
	var guard := KitWalker.new(_marksman_state(), Vector3(-18.77, _routes.walkway_height, 0.0))
	guard.blocked = true
	var guard_brain := BotBrain.new(57, BotBrain.Pattern.SIEGE)
	guard_brain.set_siege(_view, _routes, V)
	guard_brain.set_walkway_role(true)
	var guard_state: CombatState = guard.c
	guard_brain.set_combat_source(func() -> CombatState: return guard_state)
	var below := Vector3(-12.0, 0.0, 3.0)
	guard_brain.set_enemy_finder(func(_position: Vector3) -> Variant: return BotTarget.new(below))
	var moved: int = 0
	for _i: int in 600:
		var input: PlayerInput = guard.step(guard_brain)
		assert_eq(guard_brain.get_siege_task(), BotBrain.SiegeTask.FIGHT, "the guard shoots at the one in the courtyard")
		moved += 1 if input.move.length() > 0.01 else 0
	assert_true(_shots(guard_brain) >= 5, "(%s)" % [guard_brain.get_kit_counts()])
	assert_eq(moved, 0, "without moving on the walkway")
	_view.owner = S
	var yard := KitWalker.new(_marksman_sword_state(), Vector3(-12.0, 0.0, 3.0))
	yard.blocked = true
	var yard_brain: BotBrain = _brain(yard, 58)
	var up := Vector3(-18.77, _routes.walkway_height, 1.0)
	yard_brain.set_enemy_finder(func(_position: Vector3) -> Variant: return BotTarget.new(up))
	for _i: int in 600:
		yard.step(yard_brain)
		assert_eq(yard_brain.get_siege_task(), BotBrain.SiegeTask.FIGHT, "the one in the courtyard shoots at the one on the walkway")
	assert_eq(yard.c.weapon_id, CombatCatalog.weapon_id(&"bow"), "with the bow: the sword does not reach it")
	assert_true(_shots(yard_brain) > 0, "(%s)" % [yard_brain.get_kit_counts()])
	# Without the kit, the same one on the walkway is not a target from the courtyard (GUE-45, as always).
	var plain := KitWalker.new(_squire_state(), Vector3(-12.0, 0.0, 3.0))
	var plain_brain := BotBrain.new(58, BotBrain.Pattern.SIEGE)
	plain_brain.set_siege(_view, _routes, V)
	plain_brain.set_walkway_role(false)
	plain_brain.set_enemy_finder(func(_position: Vector3) -> Variant: return BotTarget.new(up))
	plain.step(plain_brain)
	assert_true(plain_brain.get_siege_task() != BotBrain.SiegeTask.FIGHT, "without the bow it is not a target")


func test_going_to_finish_a_downed_foe_it_gives_up_a_chase_that_does_not_close_in() -> void:
	# Integration review: going to finish someone off with the bow in hand had no rule for giving up, and it kept
	# pushing against the palisade until the knocked-down character bled out. Approaching is chasing: the F6b rule.
	_view.enclosure_size = Vector2(40.0, 40.0)
	var walker := KitWalker.new(_marksman_state(), Vector3(-10.0, 0.0, 23.0))
	walker.blocked = true
	var brain: BotBrain = _brain(walker, 59)
	var downed := Vector3(-10.0, 0.0, 17.0)
	brain.set_enemy_finder(func(_position: Vector3) -> Variant: return BotTarget.new(downed, Vector3.ZERO, true))
	var gave_up: int = -1
	for i: int in 600:
		walker.step(brain)
		if brain.get_siege_task() != BotBrain.SiegeTask.FIGHT:
			gave_up = i + 1
			break
	assert_true(gave_up >= BotBrain.SIEGE_STUCK_TICKS
			and gave_up <= BotBrain.SIEGE_STUCK_TICKS + 2 * BotBrain.COMBAT_RETARGET_TICKS,
			"stops going to finish it off after %d ticks without getting closer (%d)" % [BotBrain.SIEGE_STUCK_TICKS, gave_up])


func test_a_marksman_swaps_to_the_sword_to_hit_the_gate() -> void:
	# Integration review: with arrows, 4 shooters took off the gate about 2.6 times less than 4 shield-bearers.
	# The shooter draws the sword to hit it; the pure archer of the load tests (kit_ranged_only) does not.
	_view.gate_health = 9000
	_view.enclosure_size = Vector2(40.0, 40.0)
	var sword: int = CombatCatalog.weapon_id(&"sword_shield")
	for ranged_only: bool in [false, true]:
		var walker := KitWalker.new(_marksman_state(), GATE + Vector3(-6.0, 0.0, 0.0))
		var brain: BotBrain = _brain(walker, 60)
		brain.kit_ranged_only = ranged_only
		var presses: int = 0
		var assaulting: int = 0
		for _i: int in 900:
			var input: PlayerInput = walker.step(brain)
			if brain.get_siege_task() == BotBrain.SiegeTask.ASSAULT:
				assaulting += 1
				presses += 1 if input.has(PlayerInput.PRIMARY) else 0
		assert_true(assaulting > 600, "reaches the gate and assaults it (%d ticks)" % assaulting)
		assert_true(presses > 0, "hits the gate")
		if ranged_only:
			assert_true(walker.c.weapon_id != sword, "the pure archer does not swap weapons")
		else:
			assert_eq(walker.c.weapon_id, sword, "with the sword")
			assert_eq(brain.get_kit_counts().get(&"swap", 0), 1, "one weapon swap")
