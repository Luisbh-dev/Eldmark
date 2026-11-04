extends TestCase
## The walkway of [BotBrain]'s siege pattern (GUE-45; docs/fuerte.md, sections 7 and 8.3) without physics: a point that
## moves where the inputs say ([HeightWalker]) in a fort with simple heights (the flat courtyard at 10.2 m, the two
## ramps from [code]data/routes/vado_gris.tres[/code] and the walkway at 13.55 m, with no inner railing: whoever strays from
## its axis by more than 1 m falls into the courtyard). A share of the bots, by their seed, has the walkway role: the owner climbs
## a ramp and guards its post above the gate, ignoring those below (it cannot reach them) and fighting
## whoever climbs without leaving the axis; the attacker (half of that share) walks it once on entering and jumps into the courtyard
## on the way to the circle.

const V: int = NetProtocol.Realm.VARDHEIM
const S: int = NetProtocol.Realm.SOLMARCH
const ROUTES_PATH: String = "res://data/routes/vado_gris.tres"
## Floor of the courtyard and the esplanade (the fort's plateau), gate and circle of Vado Gris.
const FLOOR: float = 10.2
const GATE: Vector3 = Vector3(-20.0, FLOOR, 0.0)
const CIRCLE: Vector3 = Vector3(-8.5, FLOOR + 0.05, 0.0)
const CIRCLE_RADIUS: float = 5.0
## The ramps (x = 7, 2 m wide): they climb 3.35 m from their foot (z = ∓10.87) to the walkway (z = ∓17.77).
const RAMP_X: float = 7.0
const RAMP_HALF_WIDTH: float = 1.0
const RAMP_FOOT_Z: float = 10.87
const RAMP_TOP_Z: float = 17.77
## Half the walkway's width (2 m): farther from its axis, one falls.
const WALKWAY_HALF_WIDTH: float = 1.0
const WALK_SPEED: float = 5.0
const SPRINT_SPEED: float = 7.5
const TICKS_PER_SECOND: float = 60.0

var _routes: ApproachRoutes = null
var _view: SiegeView = null


## A point that obeys the inputs, like the one in test_bot_brain_siege, but with height: it climbs the ramps from their
## foot, walks the walkway if it reaches it by a ramp and falls into the courtyard if it strays from it. It counts the hits, the
## sideways dodges on the walkway and the falls.
class HeightWalker:
	extends RefCounted

	var routes: ApproachRoutes = null
	var position: Vector3 = Vector3.ZERO
	var elevation: float = 0.0
	var yaw: float = 0.0
	var tick: int = 0
	var presses: int = 0
	var side_dodges_up: int = 0
	var falls: int = 0
	## The farthest (m) it has been from the walkway's axis while walking on it (off the ramps, whose top
	## is at its edge).
	var worst_on_walkway: float = 0.0


	func _init(new_routes: ApproachRoutes, start: Vector3) -> void:
		routes = new_routes
		position = start
		elevation = maxf(start.y - FLOOR, 0.0)


	func rise() -> float:
		return routes.walkway_height - FLOOR


	func is_up() -> bool:
		return elevation >= rise() - 0.01


	func step(brain: BotBrain) -> PlayerInput:
		tick += 1
		var input: PlayerInput = brain.next_input(tick, position, yaw).quantized()
		yaw = input.look_yaw
		var was_up: bool = is_up()
		if input.has(PlayerInput.PRIMARY):
			presses += 1
		if was_up and input.has(PlayerInput.DODGE) and is_side_dodge(input):
			side_dodges_up += 1
		if input.move.length() > 0.0:
			var forward := Vector3(-sin(yaw), 0.0, -cos(yaw))
			var right := Vector3(cos(yaw), 0.0, -sin(yaw))
			var speed: float = SPRINT_SPEED if input.has(PlayerInput.SPRINT) else WALK_SPEED
			position += (forward * input.move.y + right * input.move.x) * speed / TICKS_PER_SECOND
		elevation = surface(Vector2(position.x, position.z), elevation)
		if was_up and not is_up() and elevation < 0.01:
			falls += 1
		if is_up() and not on_ramp(Vector2(position.x, position.z)):
			worst_on_walkway = maxf(worst_on_walkway, routes.walkway_distance(Vector2(position.x, position.z)))
		position.y = FLOOR + elevation
		return input


	## true if the dodge of [param input] goes crosswise to the walkway (toward the courtyard or the parapet) and not along its axis: its
	## direction in the world (that of the movement relative to the camera yaw, like ActionMachine._dodge_yaw) against the
	## tangent of the axis where it is. Since the integration review the bot faces the enemy and not along the axis, so
	## a dodge along the axis may carry sideways movement in its frame: what counts is where it goes in the world.
	func is_side_dodge(input: PlayerInput) -> bool:
		var dodge_yaw: float = input.look_yaw + PI
		if input.move.length() >= 0.1:
			dodge_yaw = input.look_yaw + atan2(-input.move.x, input.move.y)
		var direction := Vector2(-sin(dodge_yaw), -cos(dodge_yaw))
		var offset: float = routes.walkway_offset(Vector2(position.x, position.z))
		var a: Vector2 = routes.walkway_point(maxf(offset - 0.25, 0.0))
		var b: Vector2 = routes.walkway_point(minf(offset + 0.25, routes.walkway_length()))
		return absf((b - a).normalized().cross(direction)) > 0.1


	## true if [param point] is on one of the two ramps or on their landing, between their top and the walkway's
	## axis (in plan view).
	func on_ramp(point: Vector2) -> bool:
		for side: float in [-1.0, 1.0]:
			var z: float = point.y * side
			if absf(point.x - RAMP_X) <= RAMP_HALF_WIDTH and z >= RAMP_FOOT_Z and z <= RAMP_TOP_Z + WALKWAY_HALF_WIDTH:
				return true
		return false


	## The height (above the courtyard) of the ground it steps on at [param point] coming from [param previous]: a ramp if it is on
	## it and at its height (one does not climb onto it from the side or from below), the walkway if it was already up, or the courtyard.
	func surface(point: Vector2, previous: float) -> float:
		for side: float in [-1.0, 1.0]:
			var along: float = (point.y * side - RAMP_FOOT_Z) / (RAMP_TOP_Z - RAMP_FOOT_Z)
			if absf(point.x - RAMP_X) <= RAMP_HALF_WIDTH and along >= 0.0 and along <= 1.0:
				var height: float = rise() * along
				if absf(height - previous) <= 0.6:
					return height
		if previous >= rise() - 0.6 and routes.walkway_distance(point) <= WALKWAY_HALF_WIDTH:
			return rise()
		return 0.0


func before_each() -> void:
	_routes = load(ROUTES_PATH) as ApproachRoutes
	_view = SiegeView.new()
	_view.fortress_id = &"vado_gris_fort"
	_view.set_places(GATE, CIRCLE, CIRCLE_RADIUS)
	_view.enclosure_size = Vector2(40.0, 40.0)
	# The fort belongs to Vardheim, with the gate intact and the captain alive.
	_view.known = true
	_view.owner = V
	_view.phase = FortressState.Phase.GARRISONED
	_view.gate_health = 9000
	_view.gate_max = 9000


func _brain(realm: int, rng_seed: int) -> BotBrain:
	var brain := BotBrain.new(rng_seed, BotBrain.Pattern.SIEGE)
	brain.set_siege(_view, _routes, realm)
	return brain


## Seeds with the walkway role ([param share]: by default that of those who guard it; with
## [constant BotBrain.SIEGE_WALKWAY_SWEEP_SHARE], the attackers who walk it) whose slot falls to one side of the post:
## [param side] -1, to the north (slot x below -0.3), 1 to the south.
func _walkway_seeds(side: float, count: int, share: float = BotBrain.SIEGE_WALKWAY_SHARE) -> Array[int]:
	var seeds: Array[int] = []
	var candidate: int = 1
	while seeds.size() < count and candidate < 500:
		if BotBrain.is_walkway_seed(candidate, share) and BotBrain.slot_for_seed(candidate).x * side > 0.3:
			seeds.append(candidate)
		candidate += 1
	return seeds


## Advances until [param done] is met or [param max_ticks] pass; returns the ticks it took (-1 if not).
func _run(walker: HeightWalker, brain: BotBrain, max_ticks: int, done: Callable) -> int:
	for i: int in max_ticks:
		walker.step(brain)
		if bool(done.call()):
			return i + 1
	return -1


## true if [param walker] is at its post on the walkway (at its height and within
## [constant BotBrain.SIEGE_WALKWAY_REACHED] of it, as the brain sees it).
func _at_post(walker: HeightWalker, brain: BotBrain) -> bool:
	var post: Variant = brain.get_walkway_post()
	return post is Vector3 and walker.is_up() \
			and walker.position.distance_to(post as Vector3) <= BotBrain.SIEGE_WALKWAY_REACHED


func test_a_quarter_of_the_seeds_have_the_walkway_role_whatever_their_spacing() -> void:
	var consecutive: int = 0
	var sweepers: int = 0
	var every_other: int = 0
	for index: int in 20:
		var rng_seed: int = 1000 + index
		consecutive += 1 if BotBrain.is_walkway_seed(rng_seed) else 0
		every_other += 1 if BotBrain.is_walkway_seed(1000 + 2 * index) else 0
		var brain: BotBrain = _brain(V, rng_seed)
		if brain.is_walkway_sweeper():
			sweepers += 1
			assert_true(brain.has_walkway_role(), "seed %d: those who walk it when attacking also guard it" % rng_seed)
	assert_eq(consecutive, 5, "with base 1000, 5 of 20 consecutive seeds (those of a realm in siege_battle) guard it")
	assert_eq(sweepers, 3, "and 3 walk it when attacking (an eighth of 20 is 2.5)")
	# With other bases, from 4 to 6 and from 1 to 4 (F6b review: base 2000, Vardheim's in seed 2000, gives 6).
	var counts: Dictionary[int, int] = {}
	var sweeping: Dictionary[int, int] = {}
	for base: int in range(0, 10001, 7):
		var guards: int = 0
		var sweeps: int = 0
		for index: int in 20:
			guards += 1 if BotBrain.is_walkway_seed(base + index) else 0
			sweeps += 1 if BotBrain.is_walkway_seed(base + index, BotBrain.SIEGE_WALKWAY_SWEEP_SHARE) else 0
		counts[guards] = counts.get(guards, 0) + 1
		sweeping[sweeps] = sweeping.get(sweeps, 0) + 1
	assert_eq(counts.keys().filter(func(guards: int) -> bool: return guards < 4 or guards > 6), [],
			"from 4 to 6 guards out of every 20 (%s)" % [counts])
	assert_true(counts.get(5, 0) * 2 > counts.values().reduce(func(a: int, b: int) -> int: return a + b, 0),
			"5 in more than half of the bases (%s)" % [counts])
	assert_eq(sweeping.keys().filter(func(sweeps: int) -> bool: return sweeps < 1 or sweeps > 4), [],
			"from 1 to 4 out of every 20 walk it (%s)" % [sweeping])
	var of_2000: int = 0
	for index: int in 20:
		of_2000 += 1 if BotBrain.is_walkway_seed(2000 + index) else 0
	assert_eq(of_2000, 6, "with base 2000, 6")
	assert_true(every_other >= 4 and every_other <= 6, "and of one in every two, also a quarter (%d)" % every_other)
	for rng_seed: int in [5, 10, 11, 12, 13]:
		var brain: BotBrain = _brain(V, rng_seed)
		assert_eq(brain.has_walkway_role(), BotBrain.is_walkway_seed(rng_seed), "seed %d" % rng_seed)
		assert_eq(brain.is_walkway_sweeper(), BotBrain.is_walkway_seed(rng_seed, BotBrain.SIEGE_WALKWAY_SWEEP_SHARE),
				"seed %d attacking" % rng_seed)
	var brain: BotBrain = _brain(V, 10)
	assert_true(brain.has_walkway_role(), "seed 10 guards it")
	assert_false(brain.is_walkway_sweeper(), "but when attacking it does not walk it")
	brain.set_walkway_share(0.0)
	assert_false(brain.has_walkway_role() or brain.is_walkway_sweeper(), "with the share at 0 nobody climbs (as before GUE-45)")
	brain.set_walkway_share(1.0)
	assert_true(brain.has_walkway_role(), "with 1, everyone guards it")
	assert_true(brain.is_walkway_sweeper(), "and with half of 1 seed 10 walks it too (%.2f)" % fposmod(
			10.0 * BotBrain.WALKWAY_SEED_STEP, 1.0))
	brain.set_walkway_role(false)
	assert_false(brain.has_walkway_role() or brain.is_walkway_sweeper())
	brain.set_walkway_role(true, false)
	assert_true(brain.has_walkway_role() and not brain.is_walkway_sweeper())
	assert_false(BotBrain.is_walkway_seed(10, 0.0))


func test_the_post_is_over_the_gate_spread_by_the_slot() -> void:
	var post: Vector2 = _routes.walkway_post()
	assert_vec_near(Vector3(post.x, 0.0, post.y), Vector3(-18.77, 0.0, 0.0), 0.01, "above the gate")
	for rng_seed: int in [10, 13, 18, 23]:
		var brain: BotBrain = _brain(V, rng_seed)
		var spot: Vector3 = brain.get_walkway_post()
		assert_near(spot.y, _routes.walkway_height, 0.001, "at the walkway's height")
		assert_near(spot.x, -18.77, 0.01, "on the axis of the walkway on the gate's face")
		assert_near(spot.z, BotBrain.slot_for_seed(rng_seed).x * BotBrain.SIEGE_WALKWAY_POST_SPREAD, 0.01,
				"along it according to its slot")
	assert_null(BotBrain.new(1, BotBrain.Pattern.SIEGE).get_walkway_post(), "without a fort there is no post")
	var flat := ApproachRoutes.new()
	flat.gate_point = Vector2(-20.0, 0.0)
	flat.circle_point = Vector2(-8.5, 0.0)
	flat.circle_radius = 5.0
	var no_walkway := BotBrain.new(10, BotBrain.Pattern.SIEGE)
	no_walkway.set_siege(_view, flat, V)
	assert_null(no_walkway.get_walkway_post(), "nor with routes that do not know the walkway")


func test_an_owner_with_the_role_climbs_a_ramp_and_holds_its_post_over_the_gate() -> void:
	for side: float in [-1.0, 1.0]:
		var rng_seed: int = _walkway_seeds(side, 1)[0]
		var brain: BotBrain = _brain(V, rng_seed)
		var walker := HeightWalker.new(_routes, CIRCLE)
		var ramp_side: Array[float] = [0.0]
		var arrived: int = _run(walker, brain, 1800, func() -> bool:
			if walker.elevation > 0.5 and walker.elevation < walker.rise() - 0.5:
				ramp_side[0] = signf(walker.position.z)
			return _at_post(walker, brain))
		if not assert_true(arrived > 0, "seed %d: reaches its post (%s, at %.2f m)" % [rng_seed, walker.position,
				walker.elevation]):
			continue
		print("[pasarela] semilla %d: del círculo a su puesto en %.1f s" % [rng_seed, float(arrived) / TICKS_PER_SECOND])
		assert_true(float(arrived) / TICKS_PER_SECOND < 25.0, "in less than 25 s")
		assert_eq(ramp_side[0], side, "by the ramp on its side (the north one if its post is to the north)")
		assert_eq(walker.falls, 0, "without falling")
		assert_true(walker.worst_on_walkway <= 0.6, "along the walkway's axis (%.2f m)" % walker.worst_on_walkway)
		assert_eq(brain.get_siege_task(), BotBrain.SiegeTask.WALKWAY)
		var stand: Vector3 = walker.position
		for _i: int in 300:
			walker.step(brain)
		assert_eq(brain.get_siege_task(), BotBrain.SiegeTask.WALKWAY, "and guards it")
		assert_vec_near(walker.position, stand, 0.05, "standing still")
		assert_near(walker.yaw, fposmod(atan2(1.0, 0.0), TAU), 0.05, "facing outward, toward the esplanade")
		assert_eq(walker.presses, 0, "without hitting anyone")


func test_from_outside_the_owner_goes_in_by_its_gate_and_then_climbs() -> void:
	var rng_seed: int = _walkway_seeds(1.0, 1)[0]
	var brain: BotBrain = _brain(V, rng_seed)
	var walker := HeightWalker.new(_routes, Vector3(-27.0, FLOOR, 3.0))
	var crossing: Array[float] = [INF]
	var arrived: int = _run(walker, brain, 2400, func() -> bool:
		if absf(walker.position.x - GATE.x) < 0.3:
			crossing[0] = walker.position.z
		return _at_post(walker, brain))
	assert_true(arrived > 0, "reaches its post (%s)" % walker.position)
	assert_true(absf(crossing[0]) <= BotBrain.SIEGE_GATE_OPENING_HALF_WIDTH, "crossing through the doorway (z = %.2f)" % crossing[0])
	assert_eq(walker.falls, 0)


func test_the_owners_without_the_role_still_hold_the_circle() -> void:
	var rng_seed: int = 11
	assert_false(BotBrain.is_walkway_seed(rng_seed))
	var brain: BotBrain = _brain(V, rng_seed)
	var walker := HeightWalker.new(_routes, Vector3(-16.0, FLOOR, 6.0))
	var inside: int = _run(walker, brain, 900, func() -> bool:
		return brain.get_siege_task() == BotBrain.SiegeTask.HOLD and _view.is_in_circle(walker.position))
	assert_true(inside > 0, "goes to the circle (%s)" % walker.position)
	assert_eq(walker.elevation, 0.0, "without climbing")


func test_on_the_walkway_it_ignores_the_enemies_below_and_fights_one_that_comes_up() -> void:
	var rng_seed: int = _walkway_seeds(-1.0, 1)[0]
	var brain: BotBrain = _brain(V, rng_seed)
	var enemy: Array[Variant] = [null]
	brain.set_enemy_finder(func(_position: Vector3) -> Variant: return enemy[0])
	var walker := HeightWalker.new(_routes, CIRCLE)
	assert_true(_run(walker, brain, 1800, func() -> bool: return _at_post(walker, brain)) > 0, "at its post")
	var stand: Vector3 = walker.position
	# One hitting the gate, below and outside, 3 m horizontally: it cannot reach it (nor it the walkway).
	enemy[0] = Vector3(-22.3, FLOOR, stand.z)
	for _i: int in 240:
		walker.step(brain)
	assert_eq(brain.get_siege_task(), BotBrain.SiegeTask.WALKWAY, "stays at its post")
	assert_vec_near(walker.position, stand, 0.05, "without moving")
	assert_eq(walker.presses, 0, "nor hitting the air")
	# And one in the courtyard, right below.
	enemy[0] = Vector3(stand.x + 1.0, FLOOR, stand.z)
	for _i: int in 120:
		walker.step(brain)
	assert_eq(brain.get_siege_task(), BotBrain.SiegeTask.WALKWAY, "neither the one in the courtyard")
	assert_eq(walker.presses, 0)
	# One that climbs and comes along the walkway: it goes for it along the axis and hits it.
	var climber := Vector3(-18.77, _routes.walkway_height, stand.z - 8.0)
	enemy[0] = climber
	var engaged: int = _run(walker, brain, 600, func() -> bool:
		return walker.position.distance_to(climber) < BotBrain.COMBAT_ENGAGE_DISTANCE and walker.presses > 0)
	assert_true(engaged > 0, "fights the one who climbs (%s)" % walker.position)
	assert_eq(brain.get_siege_task(), BotBrain.SiegeTask.FIGHT)
	assert_eq(walker.falls, 0, "without falling")
	assert_true(walker.worst_on_walkway <= 0.6, "along the axis (%.2f m)" % walker.worst_on_walkway)
	# With the one who climbed dead, it returns to its post.
	enemy[0] = null
	assert_true(_run(walker, brain, 600, func() -> bool: return _at_post(walker, brain)) > 0, "returns to its post")


func test_a_fight_on_the_walkway_goes_round_the_corner_and_never_dodges_sideways() -> void:
	var dodges_seen: int = 0
	for rng_seed: int in _walkway_seeds(-1.0, 4):
		var brain: BotBrain = _brain(V, rng_seed)
		var enemy: Array[Variant] = [null]
		brain.set_enemy_finder(func(_position: Vector3) -> Variant: return enemy[0])
		var walker := HeightWalker.new(_routes, Vector3(-18.77, _routes.walkway_height, -10.0))
		walker.step(brain)
		# On the other side of the northwest corner, 11 m in a straight line (which passes over the courtyard).
		var foe := Vector3(-12.0, _routes.walkway_height, -18.77)
		enemy[0] = foe
		var engaged: int = _run(walker, brain, 600, func() -> bool:
			return walker.position.distance_to(foe) < BotBrain.COMBAT_ENGAGE_DISTANCE)
		assert_true(engaged > 0, "seed %d: reaches it (%s)" % [rng_seed, walker.position])
		assert_eq(walker.falls, 0, "seed %d: rounds the corner without falling" % rng_seed)
		assert_true(walker.worst_on_walkway <= 0.6, "along the axis (%.2f m)" % walker.worst_on_walkway)
		# Fighting for a good while: the dodges go backward along the axis and never sideways.
		for _i: int in 1200:
			var input: PlayerInput = walker.step(brain)
			dodges_seen += 1 if input.has(PlayerInput.DODGE) else 0
		assert_eq(walker.side_dodges_up, 0, "seed %d: no sideways dodge on the walkway" % rng_seed)
		assert_true(walker.presses > 0, "and hits it")
	assert_true(dodges_seen > 0, "there was some dodge (%d)" % dodges_seen)


func test_an_attacker_with_the_role_sweeps_the_walkway_once_and_drops_into_the_circle() -> void:
	_view.gate_health = 0
	var rng_seed: int = _walkway_seeds(1.0, 1, BotBrain.SIEGE_WALKWAY_SWEEP_SHARE)[0]
	var brain: BotBrain = _brain(S, rng_seed)
	var walker := HeightWalker.new(_routes, Vector3(-16.0, FLOOR, -1.0))
	var reached: int = _run(walker, brain, 1800, func() -> bool: return brain.is_walkway_swept())
	if not assert_true(reached > 0, "walks the walkway to the post (%s)" % walker.position):
		return
	assert_true(walker.is_up(), "up there")
	assert_eq(walker.falls, 0)
	var inside: int = _run(walker, brain, 900, func() -> bool:
		return brain.get_siege_task() == BotBrain.SiegeTask.HOLD \
				and walker.position.distance_to(CIRCLE) <= CIRCLE_RADIUS * BotBrain.SIEGE_CIRCLE_HOLD_FRACTION + 0.5)
	assert_true(inside > 0, "and then goes to the circle (%s)" % walker.position)
	assert_eq(walker.falls, 1, "jumping from the walkway to the courtyard")
	assert_eq(walker.elevation, 0.0)
	# Only once per life: in the circle it stays.
	for _i: int in 300:
		walker.step(brain)
	assert_eq(brain.get_siege_task(), BotBrain.SiegeTask.HOLD)
	# On respawning (a position jump) it is its turn again.
	walker.position = Vector3(-2.5, FLOOR - 6.0, 132.0)
	walker.elevation = 0.0
	walker.step(brain)
	assert_false(brain.is_walkway_swept(), "after respawning it will walk it again")


func test_an_attacker_without_the_role_and_outside_the_fort_never_climbs() -> void:
	_view.gate_health = 0
	# Without the role (11) or with the one for guarding it but not the one for walking it when attacking (10).
	for rng_seed: int in [11, 10]:
		var brain: BotBrain = _brain(S, rng_seed)
		assert_false(brain.is_walkway_sweeper())
		var walker := HeightWalker.new(_routes, Vector3(-16.0, FLOOR, -1.0))
		var climbed: bool = false
		for _i: int in 900:
			walker.step(brain)
			climbed = climbed or brain.get_siege_task() == BotBrain.SiegeTask.WALKWAY
		assert_false(climbed, "seed %d: when attacking it does not climb" % rng_seed)
		assert_true(_view.is_in_circle(walker.position), "goes to the circle")
	# With the role but the gate intact, it hits the gate from outside: the walkway is for when it gets in.
	_view.gate_health = 9000
	var outside: BotBrain = _brain(S, _walkway_seeds(1.0, 1, BotBrain.SIEGE_WALKWAY_SWEEP_SHARE)[0])
	var out_walker := HeightWalker.new(_routes, Vector3(-25.0, FLOOR, 1.0))
	for _i: int in 300:
		out_walker.step(outside)
	assert_eq(outside.get_siege_task(), BotBrain.SiegeTask.ASSAULT)


func test_a_walkway_guard_whose_realm_loses_the_fort_drops_into_the_circle_instead_of_hitting_the_air() -> void:
	# F6b review: on capture, the gate is repaired, and the previous owner's walkway guards (alive and outside the
	# circle) became attackers inside a closed fort: they "assaulted" the gate from above, hitting the air.
	# From inside the gate is not assaulted: it goes down to the courtyard and heads to the circle (in formation, with an ally counter, and without).
	for formation: bool in [true, false]:
		_view.owner = V
		_view.gate_health = 9000
		var rng_seed: int = _walkway_seeds(1.0, 1)[0]
		var brain: BotBrain = _brain(V, rng_seed)
		brain.set_walkway_role(true, false)
		if formation:
			brain.set_ally_counter(func(_center: Vector3, _radius: float) -> int: return 0)
		var walker := HeightWalker.new(_routes, CIRCLE)
		if not assert_true(_run(walker, brain, 1800, func() -> bool: return _at_post(walker, brain)) > 0,
				"formation %s: at its post" % formation):
			continue
		# Solmarch captures: the fort is theirs and the gate, repaired, blocks Vardheim's way.
		_view.owner = S
		var assaulted: Array[bool] = [false]
		var inside: int = _run(walker, brain, 900, func() -> bool:
			assaulted[0] = assaulted[0] or brain.get_siege_task() == BotBrain.SiegeTask.ASSAULT
			return brain.get_siege_task() == BotBrain.SiegeTask.HOLD and _view.is_in_circle(walker.position))
		assert_true(inside > 0, "formation %s: comes down from the walkway and goes to the circle (%s)" % [formation, walker.position])
		assert_false(assaulted[0], "formation %s: without assaulting the gate from inside" % formation)
		assert_eq(walker.presses, 0, "formation %s: nor hitting the air" % formation)
		assert_eq(walker.elevation, 0.0)


func test_inside_the_fort_an_enemy_on_the_walkway_is_not_a_target_from_the_ground() -> void:
	_view.gate_health = 0
	var brain: BotBrain = _brain(S, 11)
	var enemy: Array[Variant] = [Vector3(-18.77, _routes.walkway_height, 1.0)]
	brain.set_enemy_finder(func(_position: Vector3) -> Variant: return enemy[0])
	var walker := HeightWalker.new(_routes, CIRCLE + Vector3(-1.0, 0.0, 1.0))
	for _i: int in 300:
		walker.step(brain)
	assert_eq(brain.get_siege_task(), BotBrain.SiegeTask.HOLD, "at 10 m but on the walkway: stays in the circle")
	assert_eq(walker.presses, 0, "without staying below hitting the air")
	# The same enemy at ground level, yes.
	enemy[0] = Vector3(-14.0, FLOOR, 1.0)
	for _i: int in 60:
		walker.step(brain)
	assert_eq(brain.get_siege_task(), BotBrain.SiegeTask.FIGHT, "in the courtyard it is a target")
	# Outside the enclosure (the slopes) height does not count: one 3 m higher on the slope is a target.
	var climber: BotBrain = _brain(S, 11)
	climber.set_enemy_finder(func(_position: Vector3) -> Variant: return Vector3(-36.0, 7.0, 28.0))
	climber.next_input(1, Vector3(-40.0, 4.0, 30.0), 0.0)
	assert_eq(climber.get_siege_task(), BotBrain.SiegeTask.FIGHT, "on the slope, outside, yes")


func test_a_telegraphed_hit_from_another_level_is_not_evaded() -> void:
	var rng_seed: int = _walkway_seeds(-1.0, 1)[0]
	var brain: BotBrain = _brain(V, rng_seed)
	var threats: Array[BotBrain.Threat] = []
	brain.set_threat_finder(func(_position: Vector3) -> Array[BotBrain.Threat]: return threats)
	var walker := HeightWalker.new(_routes, CIRCLE)
	assert_true(_run(walker, brain, 1800, func() -> bool: return _at_post(walker, brain)) > 0, "at its post")
	# An NPC in the courtyard, right below, telegraphs a hit that would cover it horizontally.
	var below := Vector3(walker.position.x + 1.5, FLOOR, walker.position.z)
	threats.append(BotBrain.Threat.new(below, PI * 0.5, 3.5))
	assert_true(threats[0].covers(walker.position, BotBrain.SIEGE_THREAT_MARGIN), "horizontally it covers it")
	walker.step(brain)
	assert_eq(brain.get_siege_task(), BotBrain.SiegeTask.WALKWAY, "but from the courtyard it does not reach: it does not leave")
	# The same hit on the walkway, yes.
	threats[0] = BotBrain.Threat.new(Vector3(below.x - 1.5, walker.position.y, below.z - 2.0), PI, 3.5)
	walker.step(brain)
	assert_eq(brain.get_siege_task(), BotBrain.SiegeTask.EVADE, "on the walkway, yes")


func test_pushed_off_the_ramp_it_goes_back_to_its_foot_and_climbs_again() -> void:
	var rng_seed: int = _walkway_seeds(-1.0, 1)[0]
	var brain: BotBrain = _brain(V, rng_seed)
	var walker := HeightWalker.new(_routes, CIRCLE)
	var on_ramp: int = _run(walker, brain, 1200, func() -> bool: return walker.elevation > 1.5)
	assert_true(on_ramp > 0, "climbing the ramp")
	# A push of 2 m to the side (not a respawn): it falls into the courtyard, next to the ramp.
	walker.position += Vector3(2.0, 0.0, 0.0)
	walker.elevation = 0.0
	walker.position.y = FLOOR
	var climbed: int = _run(walker, brain, 1800, func() -> bool: return _at_post(walker, brain))
	assert_true(climbed > 0, "returns to the foot, climbs again and reaches its post (%s)" % walker.position)


func test_the_level_weight_puts_the_enemy_at_its_own_height_first() -> void:
	var me := Vector3(-14.0, FLOOR, 0.0)
	var up := Vector3(-18.77, FLOOR + 3.35, 0.0)
	var far := Vector3(-14.0 + 11.0, FLOOR, 0.0)
	assert_true(me.distance_squared_to(up) < me.distance_squared_to(far), "in a straight line, the one on the walkway is closer")
	assert_true(BotBrain.target_distance_squared(me, far) < BotBrain.target_distance_squared(me, up),
			"but with height weighed in, the one at its level at 11 m goes first")
	assert_near(BotBrain.target_distance_squared(me, Vector3(-11.0, FLOOR, 4.0)), 25.0, 0.0001, "without height, the usual one")
	assert_true(sqrt(BotBrain.target_distance_squared(me, up)) > BotBrain.SIEGE_FIGHT_RANGE,
			"the walkway is farther than the fight reach")


func test_the_walkway_keeps_it_deterministic() -> void:
	var rng_seed: int = _walkway_seeds(1.0, 1)[0]
	var runs: Array[PackedByteArray] = []
	for _run_index: int in 2:
		var brain: BotBrain = _brain(V, rng_seed)
		var enemy: Array[Variant] = [null]
		brain.set_enemy_finder(func(_position: Vector3) -> Variant: return enemy[0])
		var walker := HeightWalker.new(_routes, CIRCLE)
		var bytes := PackedByteArray()
		for tick: int in 2400:
			if tick == 1200:
				enemy[0] = Vector3(-18.77, _routes.walkway_height, 9.0)
			if tick == 1800:
				enemy[0] = null
			bytes.append_array(walker.step(brain).encode())
		runs.append(bytes)
	assert_true(runs[0] == runs[1], "same inputs in both runs")
