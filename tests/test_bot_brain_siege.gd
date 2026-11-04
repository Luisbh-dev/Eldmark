extends TestCase
## The siege pattern of [BotBrain] ([constant BotBrain.Pattern.SIEGE], GUE-15; docs/fuerte.md, section 7)
## without physics: a point that moves where the inputs say ([Walker]), the real Vado Gris fort
## ([SiegeView] with the gate and circle positions) and the routes in [code]data/routes/vado_gris.tres[/code].
## It checks that it follows its realm's route (either of the two, depending on its seed), that it hits the closed gate, enters
## the circle if it is broken, that the owner does not hit it, that it fights the enemy within range (and not the one
## behind the gate), that it gets unstuck with a jump and a detour, that it resets on respawn and that it is
## deterministic.

const V: int = NetProtocol.Realm.VARDHEIM
const S: int = NetProtocol.Realm.SOLMARCH
const ROUTES_PATH: String = "res://data/routes/vado_gris.tres"
## Gate and circle of Vado Gris (the fort is at the origin; north = -Z).
const GATE: Vector3 = Vector3(-20.0, 0.0, 0.0)
const CIRCLE: Vector3 = Vector3(-8.5, 0.0, 0.0)
const CIRCLE_RADIUS: float = 5.0
const WALK_SPEED: float = 5.0
const SPRINT_SPEED: float = 7.5
const TICKS_PER_SECOND: float = 60.0

var _routes: ApproachRoutes = null
var _view: SiegeView = null


## A point that obeys the inputs: it moves toward where it looks (and sideways) at walking or
## sprinting speed, without collisions. With [member blocked] it does not move (an imaginary obstacle).
class Walker:
	extends RefCounted

	var position: Vector3 = Vector3.ZERO
	var yaw: float = 0.0
	var blocked: bool = false
	var last_input: PlayerInput = null
	var presses: int = 0
	var jumps: int = 0
	var tick: int = 0


	func _init(start: Vector3) -> void:
		position = start


	func step(brain: BotBrain) -> PlayerInput:
		tick += 1
		var input: PlayerInput = brain.next_input(tick, position, yaw).quantized()
		last_input = input
		yaw = input.look_yaw
		if input.has(PlayerInput.PRIMARY):
			presses += 1
		if input.has(PlayerInput.JUMP):
			jumps += 1
		if not blocked and input.move.length() > 0.0:
			var forward := Vector3(-sin(yaw), 0.0, -cos(yaw))
			var right := Vector3(cos(yaw), 0.0, -sin(yaw))
			var speed: float = SPRINT_SPEED if input.has(PlayerInput.SPRINT) else WALK_SPEED
			position += (forward * input.move.y + right * input.move.x) * speed / TICKS_PER_SECOND
		return input


func before_each() -> void:
	_routes = load(ROUTES_PATH) as ApproachRoutes
	_view = SiegeView.new()
	_view.fortress_id = &"vado_gris_fort"
	_view.set_places(GATE, CIRCLE, CIRCLE_RADIUS)
	# A neutral fort, with the gate intact and the captain alive.
	_view.known = true
	_view.owner = 0
	_view.phase = FortressState.Phase.GARRISONED
	_view.gate_health = 9000
	_view.gate_max = 9000


## A siege brain without the walkway role (GUE-45): the [Walker] has no height and cannot climb to it; the
## walkway is tested in test_bot_brain_walkway.
func _brain(realm: int, rng_seed: int = 1) -> BotBrain:
	var brain := BotBrain.new(rng_seed, BotBrain.Pattern.SIEGE)
	brain.set_siege(_view, _routes, realm)
	brain.set_walkway_role(false)
	return brain


func _camp(realm: int) -> Vector3:
	return Vector3(-2.5, 0.0, -132.0 if realm == V else 132.0)


## Advances until [param done] is met or [param max_ticks] pass; returns the ticks it took
## (-1 if it was not met).
func _run(walker: Walker, brain: BotBrain, max_ticks: int, done: Callable) -> int:
	for i: int in max_ticks:
		walker.step(brain)
		if bool(done.call()):
			return i + 1
	return -1


func test_the_siege_pattern_goes_at_the_end_of_the_enum() -> void:
	assert_eq(BotBrain.Pattern.WANDER, 0)
	assert_eq(BotBrain.Pattern.CIRCLE, 1)
	assert_eq(BotBrain.Pattern.IDLE, 2)
	assert_eq(BotBrain.Pattern.JUMPY, 3)
	assert_eq(BotBrain.Pattern.COMBAT, 4)
	assert_eq(BotBrain.Pattern.SIEGE, 5, "the new pattern does not move the others' values")


func test_without_a_fortress_a_siege_brain_just_wanders() -> void:
	var brain := BotBrain.new(3, BotBrain.Pattern.SIEGE, Vector3.ZERO, 20.0)
	assert_false(brain.has_siege())
	var walker := Walker.new(Vector3.ZERO)
	var moved: bool = false
	for _i: int in 300:
		walker.step(brain)
		moved = moved or walker.position.length() > 1.0
	assert_true(moved, "without a fort it strolls like a WANDER")
	assert_eq(brain.get_siege_task(), BotBrain.SiegeTask.NONE)


func test_it_follows_the_route_of_its_realm_to_the_front_of_the_gate() -> void:
	for realm: int in [V, S]:
		var side: float = -1.0 if realm == V else 1.0
		var brain: BotBrain = _brain(realm, 5)
		var walker := Walker.new(_camp(realm))
		var arrived: int = _run(walker, brain, 6000, func() -> bool:
			return brain.get_siege_task() == BotBrain.SiegeTask.ASSAULT)
		if not assert_true(arrived > 0, "%s reaches the gate" % NetProtocol.realm_display_name(realm)):
			continue
		assert_true(brain.get_siege_route() == ApproachRoutes.BRIDGE or brain.get_siege_route() == ApproachRoutes.FORD,
				"has chosen a route")
		var seconds: float = float(arrived) / TICKS_PER_SECOND
		assert_true(seconds < 70.0, "in a reasonable time (%.1f s)" % seconds)
		assert_true(walker.position.distance_to(Vector3(-25.0, 0.0, 0.0)) < 8.0,
				"ends in front of the gate (%s)" % walker.position)
		assert_true(walker.position.z * side <= 4.0, "without crossing to the other side")


func test_the_seed_picks_the_bridge_or_the_ford() -> void:
	var chosen: Dictionary = {}
	for rng_seed: int in range(1, 17):
		var brain: BotBrain = _brain(V, rng_seed)
		var walker := Walker.new(_camp(V))
		walker.step(brain)
		chosen[brain.get_siege_route()] = true
	assert_true(chosen.has(ApproachRoutes.BRIDGE), "with some seed it takes the bridge")
	assert_true(chosen.has(ApproachRoutes.FORD), "and with another the ford")
	assert_eq(chosen.size(), 2)


func test_it_sticks_to_the_route() -> void:
	for rng_seed: int in [2, 3, 4, 6]:
		var brain: BotBrain = _brain(V, rng_seed)
		var walker := Walker.new(_camp(V))
		var worst: float = 0.0
		for _i: int in 4200:
			walker.step(brain)
			if brain.get_siege_route() != &"":
				var points: PackedVector2Array = _routes.get_points(brain.get_siege_route(), RealmCatalog.VARDHEIM)
				var closest: float = INF
				for i: int in range(1, points.size()):
					var near: Vector2 = Geometry2D.get_closest_point_to_segment(
							Vector2(walker.position.x, walker.position.z), points[i - 1], points[i])
					closest = minf(closest, near.distance_to(Vector2(walker.position.x, walker.position.z)))
				worst = maxf(worst, closest)
			if brain.get_siege_task() == BotBrain.SiegeTask.ASSAULT:
				break
		assert_true(worst < 4.0, "seed %d: never more than 4 m from the route (%.1f m)" % [rng_seed, worst])


func test_it_hits_a_closed_gate_from_in_front_and_keeps_still() -> void:
	var brain: BotBrain = _brain(V, 7)
	var walker := Walker.new(Vector3(-25.0, 0.0, -2.0))
	var settled: int = _run(walker, brain, 600, func() -> bool:
		return walker.position.distance_to(Vector3(GATE.x, 0.0, GATE.z)) <= BotBrain.SIEGE_GATE_ATTACK_DISTANCE + 0.1)
	assert_true(settled > 0, "approaches the gate")
	var stand: Vector3 = walker.position
	for _i: int in 900:
		walker.step(brain)
	assert_eq(brain.get_siege_task(), BotBrain.SiegeTask.ASSAULT)
	assert_vec_near(walker.position, stand, 0.3, "does not move while hitting")
	assert_true(walker.presses > 20, "hits the gate over and over (%d ticks pressing)" % walker.presses)
	var to_gate: Vector3 = Vector3(GATE.x, 0.0, GATE.z) - walker.position
	assert_near(walker.yaw, fposmod(atan2(-to_gate.x, -to_gate.z), TAU), 0.05, "facing the gate")


func test_a_broken_gate_lets_it_into_the_circle_and_it_stays_there() -> void:
	var brain: BotBrain = _brain(S, 8)
	var walker := Walker.new(Vector3(-25.0, 0.0, 2.0))
	for _i: int in 200:
		walker.step(brain)
	assert_eq(brain.get_siege_task(), BotBrain.SiegeTask.ASSAULT, "with the gate intact it hits it")
	_view.gate_health = 0
	_view.gate_max = 9000
	var inside: int = _run(walker, brain, 900, func() -> bool:
		return walker.position.distance_to(CIRCLE) <= CIRCLE_RADIUS * BotBrain.SIEGE_CIRCLE_HOLD_FRACTION)
	assert_true(inside > 0, "enters the circle (%s)" % walker.position)
	var stand: Vector3 = walker.position
	var presses_before: int = walker.presses
	for _i: int in 300:
		walker.step(brain)
	assert_eq(brain.get_siege_task(), BotBrain.SiegeTask.HOLD)
	assert_vec_near(walker.position, stand, 0.2, "stays inside")
	assert_eq(walker.presses, presses_before, "and attacks no one")
	assert_true(_view.is_in_circle(walker.position))


func test_the_owner_defends_the_circle_and_never_hits_its_own_gate() -> void:
	_view.owner = V
	_view.phase = FortressState.Phase.GARRISONED
	_view.gate_health = 9000
	_view.gate_max = 9000
	var brain: BotBrain = _brain(V, 9)
	var walker := Walker.new(_camp(V))
	var inside: int = _run(walker, brain, 7000, func() -> bool:
		return brain.get_siege_task() == BotBrain.SiegeTask.HOLD \
				and walker.position.distance_to(CIRCLE) <= CIRCLE_RADIUS * BotBrain.SIEGE_CIRCLE_HOLD_FRACTION)
	assert_true(inside > 0, "the owner marches to the circle (%s)" % walker.position)
	for _i: int in 300:
		walker.step(brain)
	assert_eq(walker.presses, 0, "and does not hit its own gate")
	# An attacker from the other realm does hit it with the same view.
	var attacker: BotBrain = _brain(S, 9)
	var attacker_walker := Walker.new(Vector3(-22.4, 0.0, 0.0))
	for _i: int in 300:
		attacker_walker.step(attacker)
	assert_true(attacker_walker.presses > 5, "the attacker does (%d)" % attacker_walker.presses)


func test_it_fights_an_enemy_in_range_and_ignores_a_far_one() -> void:
	var enemy: Array[Variant] = [null]
	var brain: BotBrain = _brain(V, 11)
	brain.set_enemy_finder(func(_position: Vector3) -> Variant: return enemy[0])
	var walker := Walker.new(_camp(V))
	for _i: int in 120:
		walker.step(brain)
	var route_task: BotBrain.SiegeTask = brain.get_siege_task()
	assert_eq(route_task, BotBrain.SiegeTask.MARCH, "with no enemies it marches")
	# An enemy at 40 m changes nothing.
	enemy[0] = walker.position + Vector3(30.0, 0.0, 0.0)
	for _i: int in 30:
		walker.step(brain)
	assert_eq(brain.get_siege_task(), BotBrain.SiegeTask.MARCH, "far away it does not make it veer")
	# One at 5 m: it turns toward it, approaches and hits it.
	var fixed: Vector3 = walker.position + Vector3(4.0, 0.0, 0.0)
	enemy[0] = fixed
	var presses_before: int = walker.presses
	for _i: int in 240:
		walker.step(brain)
	assert_eq(brain.get_siege_task(), BotBrain.SiegeTask.FIGHT)
	assert_true(walker.position.distance_to(fixed) < BotBrain.COMBAT_ENGAGE_DISTANCE, "has approached")
	assert_true(walker.presses > presses_before, "and attacks")
	# With the enemy dead, it resumes the march.
	enemy[0] = null
	for _i: int in 30:
		walker.step(brain)
	assert_eq(brain.get_siege_task(), BotBrain.SiegeTask.MARCH)


func test_an_enemy_behind_a_closed_gate_is_not_a_target() -> void:
	var inside: Vector3 = Vector3(-14.0, 0.0, 0.0)
	var brain: BotBrain = _brain(V, 12)
	brain.set_enemy_finder(func(_position: Vector3) -> Variant: return inside)
	var walker := Walker.new(Vector3(-22.3, 0.0, 0.0))
	for _i: int in 200:
		walker.step(brain)
	assert_eq(brain.get_siege_task(), BotBrain.SiegeTask.ASSAULT, "continues with the gate")
	assert_true(walker.position.x < GATE.x, "does not try to cross")
	# With the gate broken the same enemy is a target.
	_view.gate_health = 0
	_view.gate_max = 9000
	for _i: int in 200:
		walker.step(brain)
	assert_eq(brain.get_siege_task(), BotBrain.SiegeTask.FIGHT, "with the gate broken, it goes after it")


func test_when_it_cannot_move_it_jumps_and_then_detours() -> void:
	var brain: BotBrain = _brain(V, 13)
	var walker := Walker.new(_camp(V))
	walker.blocked = true
	var first_jump: int = -1
	var detour: int = -1
	for tick: int in range(1, 900):
		walker.step(brain)
		if first_jump < 0 and walker.jumps > 0:
			first_jump = tick
		if first_jump > 0 and detour < 0:
			# The detour looks sideways relative to the normal heading: the yaw changes by more than 1 rad.
			var points: PackedVector2Array = _routes.get_points(brain.get_siege_route(), RealmCatalog.VARDHEIM)
			var target: Vector2 = points[brain.get_siege_route_index()]
			var wanted := Vector3(target.x - walker.position.x, 0.0, target.y - walker.position.z)
			var straight: float = fposmod(atan2(-wanted.x, -wanted.z), TAU)
			if absf(angle_difference(walker.last_input.look_yaw, straight)) > 1.0:
				detour = tick
	assert_true(first_jump >= BotBrain.SIEGE_STUCK_TICKS and first_jump <= BotBrain.SIEGE_STUCK_TICKS + 3,
			"after %d ticks without advancing it tries a jump (tick %d)" % [BotBrain.SIEGE_STUCK_TICKS, first_jump])
	assert_true(detour > first_jump, "then it tries a lateral detour (tick %d)" % detour)
	assert_true(detour - first_jump >= BotBrain.SIEGE_STUCK_TICKS, "after another %d ticks without advancing" % BotBrain.SIEGE_STUCK_TICKS)
	# And once free, it returns to the route: the stuck counter is reset to zero.
	walker.blocked = false
	var before: Vector3 = walker.position
	for _i: int in 400:
		walker.step(brain)
	assert_true(walker.position.distance_to(before) > 15.0, "free, it advances again")


func test_a_bot_that_waits_on_purpose_is_not_stuck() -> void:
	var brain: BotBrain = _brain(V, 14)
	var walker := Walker.new(Vector3(-25.0, 0.0, -2.0))
	var settled: int = _run(walker, brain, 600, func() -> bool:
		return brain.get_siege_task() == BotBrain.SiegeTask.ASSAULT \
				and walker.position.distance_to(Vector3(GATE.x, 0.0, GATE.z)) <= BotBrain.SIEGE_GATE_ATTACK_DISTANCE)
	assert_true(settled > 0, "reaches the gate")
	# Standing still hitting the gate: it does not advance, and it is not a stall.
	walker.jumps = 0
	walker.blocked = true
	for _i: int in 1200:
		walker.step(brain)
	assert_eq(walker.jumps, 0, "hitting the gate while standing still is not being stuck")
	# The same while waiting inside the circle.
	_view.gate_health = 0
	var inner := Walker.new(CIRCLE)
	var waiting: BotBrain = _brain(S, 17)
	for _i: int in 1200:
		inner.step(waiting)
	assert_eq(inner.jumps, 0, "waiting in the circle neither")


func test_a_teleport_to_the_camp_restarts_the_route() -> void:
	var brain: BotBrain = _brain(V, 15)
	var walker := Walker.new(_camp(V))
	for _i: int in 1500:
		walker.step(brain)
	var index_before: int = brain.get_siege_route_index()
	assert_true(index_before >= 2, "follows the route (point %d)" % index_before)
	walker.position = _camp(V)
	walker.step(brain)
	assert_true(brain.get_siege_route_index() <= 1, "after respawning it starts over from the beginning (%d)" % brain.get_siege_route_index())
	assert_eq(brain.get_siege_task(), BotBrain.SiegeTask.MARCH)


func test_a_bot_inside_the_fort_skips_the_route() -> void:
	_view.owner = V
	var brain: BotBrain = _brain(V, 16)
	var walker := Walker.new(Vector3(10.0, 0.0, 14.0))
	for _i: int in 20:
		walker.step(brain)
	assert_eq(brain.get_siege_task(), BotBrain.SiegeTask.HOLD, "already inside the enclosure: to the circle")
	assert_true(walker.position.x < 10.0, "walks toward the circle, not outward")


func test_the_same_seed_and_the_same_world_give_the_same_inputs() -> void:
	var enemy: Array[Variant] = [null]
	var runs: Array[PackedByteArray] = []
	for _run_index: int in 2:
		_view.owner = 0
		_view.gate_health = 9000
		var brain: BotBrain = _brain(S, 21)
		brain.set_enemy_finder(func(_position: Vector3) -> Variant: return enemy[0])
		var walker := Walker.new(_camp(S))
		var bytes := PackedByteArray()
		for tick: int in 4000:
			if tick == 2500:
				enemy[0] = walker.position + Vector3(2.0, 0.0, 1.0)
			if tick == 2800:
				enemy[0] = null
			if tick == 3200:
				_view.gate_health = 0
				_view.gate_max = 9000
			bytes.append_array(walker.step(brain).encode())
		runs.append(bytes)
	assert_eq(runs[0].size(), runs[1].size())
	assert_true(runs[0] == runs[1], "same inputs in both runs")
	assert_true(runs[0].size() > 0)
	# And another seed gives different ones (the route or the hits change).
	var other: BotBrain = _brain(S, 22)
	var other_walker := Walker.new(_camp(S))
	var other_bytes := PackedByteArray()
	for _tick: int in 4000:
		other_bytes.append_array(other_walker.step(other).encode())
	assert_false(other_bytes == runs[0], "another seed, other inputs")


func test_a_threat_covers_the_front_half_plane_up_to_its_reach_plus_the_margin() -> void:
	# A hit that looks toward -Z (yaw 0) with 3.5 m of reach from the origin.
	var threat := BotBrain.Threat.new(Vector3.ZERO, 0.0, 3.5)
	var margin: float = BotBrain.SIEGE_THREAT_MARGIN
	assert_true(threat.covers(Vector3(0.0, 0.0, -2.0), margin), "in front, within reach")
	assert_true(threat.covers(Vector3(0.0, 0.0, -3.5 - margin + 0.05), margin), "and up to the reach plus the margin")
	assert_false(threat.covers(Vector3(0.0, 0.0, -3.5 - margin - 0.05), margin), "beyond, no")
	assert_true(threat.covers(Vector3(3.0, 0.0, 0.0), margin), "to the side (the front half-plane, with the margin)")
	assert_true(threat.covers(Vector3(1.0, 0.0, margin - 0.05), margin), "slightly behind, within the margin")
	assert_false(threat.covers(Vector3(0.0, 0.0, margin + 0.5), margin), "behind the one hitting, safe")
	assert_true(threat.covers(Vector3(0.0, 5.0, -1.0), margin), "height does not count")


func test_it_dodges_out_of_a_telegraphed_hit_without_blocking() -> void:
	var threats: Array[BotBrain.Threat] = []
	var brain: BotBrain = _brain(V, 31)
	brain.set_threat_finder(func(_position: Vector3) -> Array[BotBrain.Threat]: return threats)
	# Hitting the gate.
	var walker := Walker.new(Vector3(GATE.x - BotBrain.SIEGE_GATE_ATTACK_DISTANCE, 0.0, 0.3))
	for _i: int in 60:
		walker.step(brain)
	assert_eq(brain.get_siege_task(), BotBrain.SiegeTask.ASSAULT, "hits the gate")
	# An NPC 2 m to the north facing it (toward +Z: yaw PI) telegraphs its hit (3.5 m): it leaves the zone.
	var origin: Vector3 = walker.position + Vector3(0.0, 0.0, -2.0)
	threats.append(BotBrain.Threat.new(origin, PI, 3.5))
	assert_true(threats[0].covers(walker.position, BotBrain.SIEGE_THREAT_MARGIN), "is inside")
	var first: PlayerInput = walker.step(brain)
	assert_eq(brain.get_siege_task(), BotBrain.SiegeTask.EVADE)
	assert_true(first.has(PlayerInput.DODGE), "dodges as soon as it sees it")
	assert_true(first.has(PlayerInput.SPRINT), "and sprints")
	assert_false(first.has(PlayerInput.BLOCK), "without blocking")
	assert_false(first.has(PlayerInput.PRIMARY), "or continuing to hit")
	var blocked: bool = false
	var dodges: int = 1
	var ticks: int = 1
	while threats[0].covers(walker.position, BotBrain.SIEGE_THREAT_MARGIN) and ticks < 120:
		var input: PlayerInput = walker.step(brain)
		blocked = blocked or input.has(PlayerInput.BLOCK)
		dodges += 1 if input.has(PlayerInput.DODGE) else 0
		ticks += 1
	assert_false(blocked, "never blocks inside the zone")
	assert_true(ticks < 60, "leaves before the impact (1 s): %d ticks" % ticks)
	assert_true(walker.position.distance_to(origin) > 3.5 + BotBrain.SIEGE_THREAT_MARGIN - 0.2,
			"far from the hit (%.2f m)" % walker.position.distance_to(origin))
	# Outside the zone it goes back to its business, even if the telegraph continues.
	walker.step(brain)
	assert_true(brain.get_siege_task() != BotBrain.SiegeTask.EVADE, "outside, it goes back to its plan")
	# A hit facing the other way (toward -Z: yaw 0) does not push it away.
	threats.clear()
	threats.append(BotBrain.Threat.new(walker.position + Vector3(0.0, 0.0, -2.0), 0.0, 3.5))
	assert_false(threats[0].covers(walker.position, BotBrain.SIEGE_THREAT_MARGIN))
	walker.step(brain)
	assert_true(brain.get_siege_task() != BotBrain.SiegeTask.EVADE, "a hit that does not reach it does not count")


func test_a_defender_npc_in_range_comes_before_a_closer_player() -> void:
	_view.gate_health = 0
	var player: Array[Variant] = [null]
	var defender: Array[Variant] = [null]
	var brain: BotBrain = _brain(V, 32)
	brain.set_enemy_finder(func(_position: Vector3) -> Variant: return player[0])
	brain.set_defender_finder(func(_position: Vector3) -> Variant: return defender[0])
	var walker := Walker.new(CIRCLE + Vector3(-3.0, 0.0, 0.0))
	player[0] = walker.position + Vector3(0.0, 0.0, 1.5)
	defender[0] = walker.position + Vector3(6.0, 0.0, 0.0)
	var npc: Vector3 = defender[0]
	for _i: int in 120:
		walker.step(brain)
	assert_eq(brain.get_siege_task(), BotBrain.SiegeTask.FIGHT)
	assert_true(walker.position.distance_to(npc) < BotBrain.COMBAT_ENGAGE_DISTANCE,
			"goes after the NPC even though the player is closer (%.2f m)" % walker.position.distance_to(npc))
	# With the NPC dead, the player.
	defender[0] = null
	player[0] = walker.position + Vector3(0.0, 0.0, 4.0)
	var target: Vector3 = player[0]
	for _i: int in 120:
		walker.step(brain)
	assert_true(walker.position.distance_to(target) < BotBrain.COMBAT_ENGAGE_DISTANCE, "then, the player")
	# An NPC behind the closed gate does not distract it from the gate.
	_view.gate_health = 9000
	var outside := Walker.new(Vector3(GATE.x - 6.0, 0.0, 0.0))
	var other: BotBrain = _brain(V, 33)
	other.set_defender_finder(func(_position: Vector3) -> Variant: return Vector3(GATE.x + 3.0, 0.0, 0.0))
	for _i: int in 200:
		outside.step(other)
	assert_eq(other.get_siege_task(), BotBrain.SiegeTask.ASSAULT, "the NPC inside cannot be reached: it hits the gate")


func test_it_gives_up_a_chase_that_does_not_get_closer() -> void:
	# A guard behind a wall (or on the walkway): the bot does not get closer no matter how much it walks. It used to stay stuck to
	# the wall forever (fighting is not being stuck).
	_view.gate_health = 0
	var enemy: Array[Variant] = [null]
	var brain: BotBrain = _brain(V, 35)
	brain.set_enemy_finder(func(_position: Vector3) -> Variant: return enemy[0])
	var walker := Walker.new(CIRCLE + Vector3(-1.0, 0.0, 0.0))
	walker.blocked = true
	enemy[0] = walker.position + Vector3(0.0, 0.0, -8.0)
	var gave_up: int = _run(walker, brain, 600, func() -> bool:
		return brain.get_siege_task() != BotBrain.SiegeTask.FIGHT)
	assert_true(gave_up >= BotBrain.SIEGE_STUCK_TICKS and gave_up <= BotBrain.SIEGE_STUCK_TICKS + 2 * BotBrain.COMBAT_RETARGET_TICKS,
			"gives up the chase after %d ticks without getting closer (%d)" % [BotBrain.SIEGE_STUCK_TICKS, gave_up])
	assert_eq(brain.get_siege_task(), BotBrain.SiegeTask.HOLD, "and goes back to its plan: the circle")
	walker.blocked = false
	for _i: int in BotBrain.SIEGE_CHASE_GIVE_UP_TICKS - 60:
		walker.step(brain)
		if brain.get_siege_task() == BotBrain.SiegeTask.FIGHT:
			break
	assert_eq(brain.get_siege_task(), BotBrain.SiegeTask.HOLD, "for a while it does not chase the distant one")
	# One that comes within fighting distance does count.
	enemy[0] = walker.position + Vector3(0.0, 0.0, -2.0)
	for _i: int in 6:
		walker.step(brain)
	assert_eq(brain.get_siege_task(), BotBrain.SiegeTask.FIGHT, "at 2 m it fights even though it gave up the chase")
	# After the deadline it chases again.
	enemy[0] = walker.position + Vector3(0.0, 0.0, -8.0)
	for _i: int in BotBrain.SIEGE_CHASE_GIVE_UP_TICKS:
		walker.step(brain)
		if brain.get_siege_task() == BotBrain.SiegeTask.FIGHT:
			break
	assert_eq(brain.get_siege_task(), BotBrain.SiegeTask.FIGHT, "after the deadline, it chases again")


func test_reaching_the_enemy_ends_the_chase_so_a_dodge_back_is_a_new_one() -> void:
	# F6b review: the chase reference was not renewed while it fought at 3 m or less, so if the enemy
	# moved away exactly when the 180 ticks since it started were up (a 4.5 m backward dodge) it was compared with
	# the starting distance and stopped chasing for 600 ticks someone it had been stuck to the whole time.
	_view.gate_health = 0
	var enemy: Array[Variant] = [null]
	var brain: BotBrain = _brain(V, 35)
	brain.set_enemy_finder(func(_position: Vector3) -> Variant: return enemy[0])
	var walker := Walker.new(CIRCLE + Vector3(-1.0, 0.0, 0.0))
	var start: Vector3 = walker.position + Vector3(0.0, 0.0, -3.4)
	enemy[0] = start
	for _i: int in 149:
		walker.step(brain)
	assert_eq(brain.get_siege_task(), BotBrain.SiegeTask.FIGHT, "fights in melee")
	assert_true(walker.position.distance_to(start) <= BotBrain.COMBAT_ENGAGE_DISTANCE,
			"stuck to the enemy (%.2f m)" % walker.position.distance_to(start))
	# On tick 150 it dodges 4.5 m backward (in 27 ticks) and stays there.
	var fighting: int = 0
	for tick: int in range(150, 750):
		var dodge: float = clampf(float(tick - 150) / 27.0, 0.0, 1.0) * 4.5
		enemy[0] = start + Vector3(0.0, 0.0, -dodge)
		walker.step(brain)
		if brain.get_siege_task() == BotBrain.SiegeTask.FIGHT:
			fighting += 1
	assert_true(fighting >= 590, "keeps fighting it: %d of 600 ticks" % fighting)
	assert_true(walker.position.distance_to(enemy[0] as Vector3) <= BotBrain.COMBAT_ENGAGE_DISTANCE,
			"and is stuck to it again (%.2f m)" % walker.position.distance_to(enemy[0] as Vector3))


func test_a_new_target_is_a_new_chase() -> void:
	# F6b review: the two finders (the defenders' and the enemies') shared the chase, and one that does not
	# get closer (flees at its own pace) left the reference for the next target, farther away: at 180 ticks from the start
	# distances of different targets were compared and it stopped chasing the new one.
	for change: String in ["defender_to_player", "player_to_player"]:
		_view.gate_health = 0
		var near: Array[Variant] = [null]
		var other: Array[Variant] = [null]
		var brain: BotBrain = _brain(V, 37)
		if change == "defender_to_player":
			brain.set_defender_finder(func(_position: Vector3) -> Variant: return near[0])
			brain.set_enemy_finder(func(_position: Vector3) -> Variant: return other[0])
		else:
			brain.set_enemy_finder(func(_position: Vector3) -> Variant: return near[0] if near[0] != null else other[0])
		var walker := Walker.new(CIRCLE + Vector3(-1.0, 0.0, 0.0))
		# For the first 150 ticks it chases one that moves away at its own pace, at 5 m.
		for _i: int in 150:
			near[0] = walker.position + Vector3(5.0, 0.0, 0.0)
			walker.step(brain)
		assert_eq(brain.get_siege_task(), BotBrain.SiegeTask.FIGHT, "%s: chases it" % change)
		# It disappears (dies) and there is another at 9 m, standing still.
		near[0] = null
		other[0] = walker.position + Vector3(0.0, 0.0, -9.0)
		var reached: int = _run(walker, brain, 300, func() -> bool:
			return walker.position.distance_to(other[0] as Vector3) <= BotBrain.COMBAT_ENGAGE_DISTANCE)
		assert_true(reached > 0, "%s: chases the other until it reaches it (at %.2f m)" % [change,
				walker.position.distance_to(other[0] as Vector3)])
		assert_eq(brain.get_siege_task(), BotBrain.SiegeTask.FIGHT, "%s: and fights it" % change)


func test_an_attacker_inside_the_fort_keeps_the_circle_when_the_gate_is_repaired() -> void:
	# F6b review: with the gate repaired (after gate_repair_after_s without hits, or on capture) an attacker that was
	# already in the circle went back to "assaulting" the gate from inside; in formation it went to the slot outside and hit with its
	# back to it, toward the courtyard. Capture does not need the gate: it stays in the circle.
	_view.owner = V
	_view.gate_health = 0
	for formation: bool in [true, false]:
		_view.gate_health = 0
		var brain: BotBrain = _brain(S, 7)
		if formation:
			brain.set_ally_counter(func(_center: Vector3, _radius: float) -> int: return 0)
		var walker := Walker.new(CIRCLE + Vector3(0.0, 0.0, 0.5))
		for _i: int in 120:
			walker.step(brain)
		assert_eq(brain.get_siege_task(), BotBrain.SiegeTask.HOLD, "formation %s: in the circle" % formation)
		_view.gate_health = 9000
		var left: Array[bool] = [false]
		_run(walker, brain, 900, func() -> bool:
			left[0] = left[0] or brain.get_siege_task() != BotBrain.SiegeTask.HOLD or not _view.is_in_circle(walker.position)
			return false)
		assert_false(left[0], "formation %s: with the gate repaired it does not leave the circle (%s, task %d)" % [formation,
				walker.position, brain.get_siege_task()])
		assert_eq(walker.presses, 0, "formation %s: nor hits anything" % formation)


func test_outside_by_a_side_wall_it_walks_around_the_enclosure_instead_of_into_it() -> void:
	# The 40 x 40 m enclosure (the palisade runs from x = -20 to 20 and from z = -20 to 20). Before, a bot that a chase
	# left stuck to the south wall from outside believed itself inside (within 30 m of the circle) and walked against it.
	_view.enclosure_size = Vector2(40.0, 40.0)
	_view.gate_health = 0
	assert_eq(_view.is_inside_enclosure(Vector3(-7.0, 0.0, 22.0), BotBrain.SIEGE_ENCLOSURE_MARGIN), 0, "outside, next to the south wall")
	assert_eq(_view.is_inside_enclosure(Vector3(-7.0, 0.0, 18.0), BotBrain.SIEGE_ENCLOSURE_MARGIN), 1, "inside")
	assert_eq(SiegeView.new().is_inside_enclosure(Vector3.ZERO), -1, "without an enclosure it cannot be known")
	var brain: BotBrain = _brain(S, 36)
	var walker := Walker.new(Vector3(GATE.x - 5.0, 0.0, 1.0))
	for _i: int in 30:
		walker.step(brain)
	assert_eq(brain.get_siege_route_index(), _routes.get_points(brain.get_siege_route(), RealmCatalog.SOLMARCH).size(),
			"on the esplanade it has already walked the route")
	# A chase takes it outside to the south wall (1 m steps: it is not a respawn).
	for corner: Vector3 in [Vector3(-24.0, 0.0, 22.0), Vector3(-8.0, 0.0, 22.0)]:
		while walker.position.distance_to(corner) > 1.0:
			walker.position = walker.position.move_toward(corner, 1.0)
			walker.step(brain)
	assert_eq(brain.get_siege_route_index(), _routes.get_points(brain.get_siege_route(), RealmCatalog.SOLMARCH).size(),
			"continues with the route done")
	# (Lambdas copy variables: the mark goes in an Array.)
	var crossed_wall: Array[bool] = [false]
	var entered: int = _run(walker, brain, 1800, func() -> bool:
		var p: Vector3 = walker.position
		if p.x > GATE.x + 0.5 and absf(p.z) < 20.0 and absf(p.z) > 3.0:
			crossed_wall[0] = true
		return Vector2(p.x - CIRCLE.x, p.z - CIRCLE.z).length() <= CIRCLE_RADIUS * BotBrain.SIEGE_CIRCLE_HOLD_FRACTION)
	assert_true(entered > 0, "reaches the circle")
	assert_false(crossed_wall[0], "without going through the palisade: it goes around the corner and enters through the gate")


func test_the_threat_and_defender_finders_keep_it_deterministic() -> void:
	var runs: Array[PackedByteArray] = []
	for _run_index: int in 2:
		_view.owner = 0
		_view.gate_health = 9000
		var threats: Array[BotBrain.Threat] = []
		var defender: Array[Variant] = [null]
		var brain: BotBrain = _brain(S, 34)
		brain.set_defender_finder(func(_position: Vector3) -> Variant: return defender[0])
		brain.set_threat_finder(func(_position: Vector3) -> Array[BotBrain.Threat]: return threats)
		var walker := Walker.new(_camp(S))
		var bytes := PackedByteArray()
		for tick: int in 3000:
			if tick == 2000:
				defender[0] = walker.position + Vector3(2.0, 0.0, 1.0)
			if tick == 2100:
				threats.append(BotBrain.Threat.new(walker.position + Vector3(0.0, 0.0, 1.5), PI, 3.5))
			if tick == 2160:
				threats.clear()
			if tick == 2400:
				defender[0] = null
			bytes.append_array(walker.step(brain).encode())
		runs.append(bytes)
	assert_true(runs[0] == runs[1], "same inputs in both runs")


func test_combat_and_the_other_patterns_are_unchanged() -> void:
	# The sequence of a COMBAT with a fixed enemy (fixed seed and positions) has not changed by adding the siege:
	# its fingerprint is that of the previous code.
	var brain := BotBrain.new(77, BotBrain.Pattern.COMBAT, Vector3.ZERO, 30.0)
	brain.set_enemy_finder(func(_position: Vector3) -> Variant: return Vector3(2.0, 0.0, 0.0))
	var bytes := PackedByteArray()
	for tick: int in range(1, 601):
		bytes.append_array(brain.next_input(tick, Vector3.ZERO, 0.0).quantized().encode())
	assert_eq(bytes.size(), 600 * PlayerInput.ENCODED_SIZE)
	assert_eq(hash(bytes), COMBAT_FINGERPRINT, "fingerprint of 600 ticks of combat")
	var wander := BotBrain.new(78, BotBrain.Pattern.WANDER, Vector3.ZERO, 30.0)
	var wander_bytes := PackedByteArray()
	for tick: int in range(1, 601):
		wander_bytes.append_array(wander.next_input(tick, Vector3.ZERO, 0.0).quantized().encode())
	assert_eq(hash(wander_bytes), WANDER_FINGERPRINT, "fingerprint of 600 ticks of strolling")


## Fingerprints of 600 ticks of COMBAT and WANDER computed with the code prior to the siege.
const COMBAT_FINGERPRINT: int = 2334970325
const WANDER_FINGERPRINT: int = 2761780144
