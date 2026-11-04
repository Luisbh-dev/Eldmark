extends TestCase
## The rally and formation of [BotBrain]'s siege pattern (GUE-44; docs/fuerte.md, sections 7 and 8.3) without physics:
## points that move where the inputs say ([Walker]), the Vado Gris fort ([SiegeView] with the gate and the
## circle) and its routes. An attacker that starts or respawns at its camp waits for its side at the rally point and
## leaves with them when there are enough, when its side is already fighting in the fort or on the next tick of the shared clock,
## all by the same route; the owner does not wait; and, in a group, each one takes its own slot so they do not pile up.

const V: int = NetProtocol.Realm.VARDHEIM
const S: int = NetProtocol.Realm.SOLMARCH
const ROUTES_PATH: String = "res://data/routes/vado_gris.tres"
const GATE: Vector3 = Vector3(-20.0, 0.0, 0.0)
const CIRCLE: Vector3 = Vector3(-8.5, 0.0, 0.0)
const CIRCLE_RADIUS: float = 5.0
const WALK_SPEED: float = 5.0
const SPRINT_SPEED: float = 7.5
const TICKS_PER_SECOND: float = 60.0
## Respawn points of Vardheim's camp (z = -138) and the camp exit (the first point of its routes).
const CAMP_SPAWN: Vector3 = Vector3(-7.5, 0.0, -138.0)
const RALLY_V: Vector3 = Vector3(-2.5, 0.0, -132.0)
const RALLY_S: Vector3 = Vector3(-2.5, 0.0, 132.0)

var _routes: ApproachRoutes = null
var _view: SiegeView = null


## A point that obeys the inputs (like the one in test_bot_brain_siege), with its brain. While it is not
## [member present] (has not appeared yet) it neither thinks nor counts for the others.
class Walker:
	extends RefCounted

	var brain: BotBrain = null
	var position: Vector3 = Vector3.ZERO
	var yaw: float = 0.0
	var present: bool = true
	var last_input: PlayerInput = null


	func _init(new_brain: BotBrain, start: Vector3) -> void:
		brain = new_brain
		position = start


	func step(tick: int) -> PlayerInput:
		if not present:
			return null
		var input: PlayerInput = brain.next_input(tick, position, yaw).quantized()
		last_input = input
		yaw = input.look_yaw
		if input.move.length() > 0.0:
			var forward := Vector3(-sin(yaw), 0.0, -cos(yaw))
			var right := Vector3(cos(yaw), 0.0, -sin(yaw))
			var speed: float = SPRINT_SPEED if input.has(PlayerInput.SPRINT) else WALK_SPEED
			position += (forward * input.move.y + right * input.move.x) * speed / TICKS_PER_SECOND
		return input


## Several bots in the same world: each one's ally counter counts the others of its realm that are present.
class Squad:
	extends RefCounted

	var walkers: Array[Walker] = []
	var realms: PackedInt32Array = PackedInt32Array()


	func add(walker: Walker, realm: int) -> Walker:
		var index: int = walkers.size()
		walkers.append(walker)
		realms.append(realm)
		# A bound method and not a lambda: the lambda would hold the Squad and the Squad -> brain -> lambda cycle
		# would not be freed at the end.
		walker.brain.set_ally_counter(count.bind(index))
		return walker


	func count(center: Vector3, radius: float, index: int) -> int:
		var found: int = 0
		for other: int in walkers.size():
			if other == index or realms[other] != realms[index] or not walkers[other].present:
				continue
			var offset := Vector2(walkers[other].position.x - center.x, walkers[other].position.z - center.z)
			if offset.length() <= radius:
				found += 1
		return found


	# One tick for all: they all think with the earlier positions (like the server's fake ones, which count with the
	# tick's list) and then move.
	func step(tick: int) -> void:
		var before: Array[Vector3] = []
		for walker: Walker in walkers:
			before.append(walker.position)
		var after: Array[Vector3] = []
		for index: int in walkers.size():
			walkers[index].step(tick)
			after.append(walkers[index].position)
			walkers[index].position = before[index]
		for index: int in walkers.size():
			walkers[index].position = after[index]


func before_each() -> void:
	_routes = load(ROUTES_PATH) as ApproachRoutes
	_view = SiegeView.new()
	_view.fortress_id = &"vado_gris_fort"
	_view.set_places(GATE, CIRCLE, CIRCLE_RADIUS)
	_view.enclosure_size = Vector2(40.0, 40.0)
	_view.known = true
	_view.owner = 0
	_view.phase = FortressState.Phase.GARRISONED
	_view.gate_health = 9000
	_view.gate_max = 9000


## A siege brain without the walkway role (GUE-45): these points have no height and cannot climb to it;
## the walkway is tested in test_bot_brain_walkway.
func _brain(realm: int, rng_seed: int) -> BotBrain:
	var brain := BotBrain.new(rng_seed, BotBrain.Pattern.SIEGE)
	brain.set_siege(_view, _routes, realm)
	brain.set_walkway_role(false)
	return brain


func _alone(brain: BotBrain) -> void:
	brain.set_ally_counter(func(_center: Vector3, _radius: float) -> int: return 0)


func test_the_rally_point_is_the_way_out_of_the_camp() -> void:
	assert_vec_near(_brain(V, 1).get_siege_rally_point(), RALLY_V, 0.01, "Vardheim: the first point of its routes")
	assert_vec_near(_brain(S, 1).get_siege_rally_point(), RALLY_S, 0.01, "Solmarch: its own")
	var routes_point: Vector2 = _routes.get_points(ApproachRoutes.FORD, RealmCatalog.VARDHEIM)[0]
	assert_eq(Vector2(RALLY_V.x, RALLY_V.z), routes_point, "both routes start in the same place")
	var lost := BotBrain.new(1, BotBrain.Pattern.SIEGE)
	lost.set_siege(_view, null, V)
	assert_null(lost.get_siege_rally_point(), "without routes there is no rally point")
	assert_true(CAMP_SPAWN.distance_to(RALLY_V) < BotBrain.SIEGE_RALLY_RADIUS,
			"the camp's respawn points fall within the rally radius")


func test_the_departure_clock_is_shared_and_the_group_route_alternates() -> void:
	var period: int = BotBrain.SIEGE_RALLY_PERIOD_TICKS
	var offset: int = BotBrain.SIEGE_RALLY_OFFSET_TICKS
	assert_eq(BotBrain.next_rally_departure(0), offset, "the first departure, 5 s after the start")
	assert_eq(BotBrain.next_rally_departure(offset - 1), offset)
	assert_eq(BotBrain.next_rally_departure(offset), offset + period, "always after the given tick")
	assert_eq(BotBrain.next_rally_departure(offset + 1), offset + period)
	assert_eq(BotBrain.next_rally_departure(4000, 600), 4500, "with another turn of the clock")
	# Two bots that start waiting on different ticks of the same turn leave on the same one.
	assert_eq(BotBrain.next_rally_departure(700), BotBrain.next_rally_departure(2000))
	# The group's route alternates from one turn to the next and does not change for a few ticks around a departure.
	assert_eq(BotBrain.rally_route_index(offset, 2), 0)
	assert_eq(BotBrain.rally_route_index(offset + period, 2), 1)
	assert_eq(BotBrain.rally_route_index(offset + 2 * period, 2), 0)
	assert_eq(BotBrain.rally_route_index(offset + period - 5, 2), BotBrain.rally_route_index(offset + period + 5, 2),
			"a few ticks before or after a departure, the same route")
	assert_eq(BotBrain.rally_route_index(100, 0), -1, "without routes, none")


func test_without_an_ally_counter_it_marches_at_once() -> void:
	var brain: BotBrain = _brain(V, 3)
	var walker := Walker.new(brain, CAMP_SPAWN)
	walker.step(1)
	assert_false(brain.is_rallying(), "with no ally counter it does not wait (as before GUE-44)")
	assert_eq(brain.get_siege_task(), BotBrain.SiegeTask.MARCH)
	assert_true(brain.get_siege_route() != &"", "and has chosen its route")


func test_alone_at_the_camp_it_waits_for_the_clock_and_then_marches() -> void:
	var brain: BotBrain = _brain(V, 4)
	_alone(brain)
	var walker := Walker.new(brain, CAMP_SPAWN)
	var departure: int = BotBrain.next_rally_departure(1)
	for tick: int in range(1, departure):
		walker.step(tick)
		if not assert_eq(brain.get_siege_task(), BotBrain.SiegeTask.RALLY, "tick %d: waits" % tick):
			return
	assert_true(brain.is_rallying())
	assert_eq(brain.get_rally_deadline(), departure, "at most until the next departure of the clock")
	assert_eq(brain.get_siege_route(), &"", "still without a route")
	var spot: Vector3 = RALLY_V + Vector3(brain.get_siege_slot().x, 0.0, brain.get_siege_slot().y) \
			* BotBrain.SIEGE_SLOT_RALLY_SPREAD
	assert_true(walker.position.distance_to(spot) <= BotBrain.SIEGE_SLOT_REACHED + 0.2,
			"standing still at its place at the rally point (%.2f m)" % walker.position.distance_to(spot))
	assert_false(walker.last_input.has(PlayerInput.PRIMARY), "without attacking anyone")
	walker.step(departure)
	assert_false(brain.is_rallying(), "leaves with the clock")
	assert_eq(brain.get_last_rally_departure(), departure)
	assert_eq(brain.get_siege_task(), BotBrain.SiegeTask.MARCH)
	var candidates: Array[StringName] = _routes.get_route_ids()
	assert_eq(brain.get_siege_route(), candidates[BotBrain.rally_route_index(departure, candidates.size())],
			"by the route of that turn of the clock")


func test_a_group_leaves_together_by_the_same_route_once_enough_have_gathered() -> void:
	var squad := Squad.new()
	var size: int = 4
	for index: int in size:
		var walker: Walker = squad.add(Walker.new(_brain(V, 100 + index), CAMP_SPAWN), V)
		walker.brain.set_rally(size)
		# They arrive one at a time (as if respawning): one every 40 ticks.
		walker.present = index == 0
	var arrival_of_last: int = 1 + 40 * (size - 1)
	for tick: int in range(1, arrival_of_last + 3):
		for index: int in size:
			if tick == 1 + 40 * index:
				squad.walkers[index].present = true
		squad.step(tick)
		if tick < arrival_of_last:
			for index: int in size:
				if squad.walkers[index].present and not squad.walkers[index].brain.is_rallying():
					assert_true(false, "tick %d: number %d should not have left yet" % [tick, index])
					return
	var departures: Dictionary = {}
	var routes: Dictionary = {}
	for walker: Walker in squad.walkers:
		assert_false(walker.brain.is_rallying(), "no longer waits")
		departures[walker.brain.get_last_rally_departure()] = true
		routes[walker.brain.get_siege_route()] = true
	assert_eq(departures.keys(), [arrival_of_last], "they all leave on the tick the fourth arrives, without waiting for the clock")
	assert_true(arrival_of_last < BotBrain.next_rally_departure(1))
	assert_eq(routes.size(), 1, "and by the same route: %s" % [routes.keys()])


func test_bots_that_arrive_at_different_times_leave_together_on_the_clock() -> void:
	var squad := Squad.new()
	var arrivals: Array[int] = [5, 120, 250]
	for index: int in arrivals.size():
		var walker: Walker = squad.add(Walker.new(_brain(S, 200 + index * 7), Vector3(-7.5, 0.0, 138.0)), S)
		walker.present = false
	var departure: int = BotBrain.next_rally_departure(arrivals[0])
	assert_eq(departure, BotBrain.next_rally_departure(arrivals[2]), "all three fall in the same turn of the clock")
	for tick: int in range(1, departure + 2):
		for index: int in arrivals.size():
			if tick == arrivals[index]:
				squad.walkers[index].present = true
		squad.step(tick)
	var routes: Dictionary = {}
	for walker: Walker in squad.walkers:
		assert_eq(walker.brain.get_last_rally_departure(), departure, "they leave together with the clock (group of 3 of 8)")
		routes[walker.brain.get_siege_route()] = true
	assert_eq(routes.size(), 1, "by the same route")


func test_after_a_respawn_at_the_camp_it_waits_again() -> void:
	var brain: BotBrain = _brain(V, 5)
	_alone(brain)
	brain.set_rally(BotBrain.SIEGE_RALLY_GROUP_SIZE, 600)
	var walker := Walker.new(brain, CAMP_SPAWN)
	var tick: int = 1
	while brain.is_rallying() or tick == 1:
		walker.step(tick)
		tick += 1
	for _i: int in 900:
		walker.step(tick)
		tick += 1
	assert_eq(brain.get_siege_task(), BotBrain.SiegeTask.MARCH, "march")
	assert_true(walker.position.distance_to(RALLY_V) > 30.0, "far from the camp")
	# Dies and respawns at the camp (a jump of more than 5 m).
	walker.position = CAMP_SPAWN
	walker.step(tick)
	assert_true(brain.is_rallying(), "waits for its side again")
	assert_eq(brain.get_siege_task(), BotBrain.SiegeTask.RALLY)
	assert_eq(brain.get_rally_deadline(), BotBrain.next_rally_departure(tick, 600))


func test_a_respawn_far_from_the_camp_or_the_owner_never_waits() -> void:
	# A jump that does not end at the camp (it is placed in front of the gate) is not a respawn there.
	var brain: BotBrain = _brain(V, 6)
	_alone(brain)
	brain.set_rally(BotBrain.SIEGE_RALLY_GROUP_SIZE, 600)
	var walker := Walker.new(brain, CAMP_SPAWN)
	walker.step(1)
	assert_true(brain.is_rallying())
	walker.position = Vector3(-27.0, 0.0, 0.0)
	walker.step(2)
	assert_false(brain.is_rallying(), "in front of the gate it waits for no one")
	for tick: int in range(3, 120):
		walker.step(tick)
	assert_eq(brain.get_siege_task(), BotBrain.SiegeTask.ASSAULT, "hits the gate")
	# The owner defends as soon as it can.
	_view.owner = V
	var owner: BotBrain = _brain(V, 7)
	_alone(owner)
	var owner_walker := Walker.new(owner, CAMP_SPAWN)
	owner_walker.step(1)
	assert_false(owner.is_rallying(), "the owner does not wait")
	assert_eq(owner.get_siege_task(), BotBrain.SiegeTask.MARCH)


func test_it_does_not_wait_if_its_people_are_already_fighting_at_the_fort() -> void:
	# Three of its side in the courtyard: the assault is ongoing and it goes to help them without waiting for the group or the clock.
	var at_fort: Array[int] = [BotBrain.SIEGE_RALLY_JOIN_COUNT - 1]
	var brain: BotBrain = _brain(V, 12)
	brain.set_ally_counter(func(center: Vector3, _radius: float) -> int:
		return at_fort[0] if center.distance_to(CIRCLE) < 0.01 else 0)
	var walker := Walker.new(brain, CAMP_SPAWN)
	for tick: int in range(1, 30):
		walker.step(tick)
	assert_true(brain.is_rallying(), "with %d in the fort, it waits" % at_fort[0])
	at_fort[0] = BotBrain.SIEGE_RALLY_JOIN_COUNT
	walker.step(30)
	assert_false(brain.is_rallying(), "with %d, it leaves" % at_fort[0])
	assert_eq(brain.get_last_rally_departure(), 30)
	assert_eq(brain.get_siege_task(), BotBrain.SiegeTask.MARCH)


func test_it_stops_waiting_when_its_realm_takes_the_fort() -> void:
	var brain: BotBrain = _brain(S, 8)
	_alone(brain)
	var walker := Walker.new(brain, Vector3(-7.5, 0.0, 138.0))
	for tick: int in range(1, 60):
		walker.step(tick)
	assert_true(brain.is_rallying())
	_view.owner = S
	walker.step(60)
	assert_false(brain.is_rallying(), "now it is the owner: to defend")
	assert_eq(brain.get_siege_task(), BotBrain.SiegeTask.MARCH)


func test_a_group_of_one_or_less_never_waits() -> void:
	var brain: BotBrain = _brain(V, 9)
	_alone(brain)
	brain.set_rally(1)
	var walker := Walker.new(brain, CAMP_SPAWN)
	walker.step(1)
	assert_false(brain.is_rallying(), "with the group at 1 it leaves alone")
	var other: BotBrain = _brain(V, 10)
	_alone(other)
	var other_walker := Walker.new(other, CAMP_SPAWN)
	other_walker.step(1)
	assert_true(other.is_rallying())
	other.set_rally(0)
	assert_false(other.is_rallying(), "removing the rally while it waits ends the wait")
	other_walker.step(2)
	assert_eq(other.get_siege_task(), BotBrain.SiegeTask.MARCH)


func test_it_fights_an_enemy_that_comes_to_the_rally_and_then_waits_again() -> void:
	var enemy: Array[Variant] = [null]
	var brain: BotBrain = _brain(V, 11)
	_alone(brain)
	brain.set_enemy_finder(func(_position: Vector3) -> Variant: return enemy[0])
	var walker := Walker.new(brain, CAMP_SPAWN)
	for tick: int in range(1, 40):
		walker.step(tick)
	assert_eq(brain.get_siege_task(), BotBrain.SiegeTask.RALLY)
	enemy[0] = walker.position + Vector3(3.0, 0.0, 0.0)
	for tick: int in range(40, 80):
		walker.step(tick)
	assert_eq(brain.get_siege_task(), BotBrain.SiegeTask.FIGHT, "fights whoever arrives")
	assert_true(brain.is_rallying(), "without ceasing to be one of those waiting")
	enemy[0] = null
	for tick: int in range(80, 100):
		walker.step(tick)
	assert_eq(brain.get_siege_task(), BotBrain.SiegeTask.RALLY, "and waits again")


func test_the_rally_is_deterministic() -> void:
	var runs: Array[PackedByteArray] = []
	for _run_index: int in 2:
		var squad := Squad.new()
		for index: int in 3:
			squad.add(Walker.new(_brain(V, 300 + index), CAMP_SPAWN + Vector3(float(index) * 5.0, 0.0, 0.0)), V)
		for walker: Walker in squad.walkers:
			walker.brain.set_rally(3)
		squad.walkers[2].present = false
		var bytes := PackedByteArray()
		for tick: int in range(1, 1500):
			if tick == 200:
				squad.walkers[2].present = true
			if tick == 1000:
				squad.walkers[0].position = CAMP_SPAWN
			squad.step(tick)
			for walker: Walker in squad.walkers:
				if walker.last_input != null:
					bytes.append_array(walker.last_input.encode())
		runs.append(bytes)
	assert_true(runs[0].size() > 0)
	assert_true(runs[0] == runs[1], "same inputs in both runs")


func test_slots_of_consecutive_seeds_are_spread_over_the_unit_disk() -> void:
	var slots: Array[Vector2] = []
	for rng_seed: int in range(2000, 2020):
		var slot: Vector2 = BotBrain.slot_for_seed(rng_seed)
		assert_true(slot.length() <= 1.0001, "within the unit disc (%s)" % slot)
		slots.append(slot)
	assert_eq(BotBrain.slot_for_seed(2000), BotBrain.slot_for_seed(2000), "always the same for the same seed")
	assert_eq(_brain(V, 2005).get_siege_slot(), BotBrain.slot_for_seed(2005), "the brain's one")
	var closest: float = INF
	for i: int in slots.size():
		for j: int in range(i + 1, slots.size()):
			closest = minf(closest, slots[i].distance_to(slots[j]))
	assert_true(closest > 0.1, "twenty consecutive seeds, twenty different slots (the closest pair at %.2f)" % closest)
	var left: int = 0
	for slot: Vector2 in slots:
		left += 1 if slot.x < 0.0 else 0
	assert_true(left >= 6 and left <= 14, "spread to both sides (%d of 20 on the left)" % left)
	# What slot_for_seed and docs/fuerte.md say (F6b review): with any base from 0 to 6000, the closest pair of
	# twenty consecutive seeds is 0.1 or more apart (under 0.18 in one of every ten bases).
	var worst: float = INF
	var below: int = 0
	for base: int in range(0, 6001):
		var group: Array[Vector2] = []
		for index: int in 20:
			group.append(BotBrain.slot_for_seed(base + index))
		var nearest: float = INF
		for i: int in group.size():
			for j: int in range(i + 1, group.size()):
				nearest = minf(nearest, group[i].distance_squared_to(group[j]))
		nearest = sqrt(nearest)
		worst = minf(worst, nearest)
		below += 1 if nearest < 0.18 else 0
	assert_true(worst >= 0.1, "with any base, 0.1 or more (the worst, %.3f)" % worst)
	assert_true(below > 0 and below < 900, "under 0.18 in one of every ten bases, not in none (%d of 6001)" % below)


func test_in_a_group_they_hit_the_gate_and_hold_the_circle_each_from_its_own_spot() -> void:
	# Without a slot, those who arrive by the same place end up on top of one another (characters do not collide with each other).
	var squad := Squad.new()
	for index: int in 6:
		var walker: Walker = squad.add(Walker.new(_brain(V, 400 + index), Vector3(-26.0, 0.0, -1.0)), V)
		walker.brain.set_rally(2)
	for tick: int in range(1, 400):
		squad.step(tick)
	var across := Vector3(0.0, 0.0, 1.0)
	var laterals: Array[float] = []
	for walker: Walker in squad.walkers:
		assert_eq(walker.brain.get_siege_task(), BotBrain.SiegeTask.ASSAULT, "hit the gate")
		assert_true(walker.position.distance_to(GATE) <= BotBrain.SIEGE_GATE_ATTACK_DISTANCE + 2.0,
				"within reach of the gate (%.2f m)" % walker.position.distance_to(GATE))
		var lateral: float = (walker.position - GATE).dot(across)
		assert_true(absf(lateral) <= BotBrain.SIEGE_SLOT_GATE_SPREAD + 0.6, "within the width of the gate (%.2f)" % lateral)
		assert_near(walker.yaw, fposmod(atan2(-1.0, 0.0), TAU), 0.05, "facing it head-on")
		laterals.append(lateral)
	laterals.sort()
	assert_true(laterals[laterals.size() - 1] - laterals[0] > 1.5, "spread along the gate: %s" % [laterals])
	# With the gate broken, each to their place in the circle.
	_view.gate_health = 0
	for tick: int in range(400, 1000):
		squad.step(tick)
	var spots: Array[Vector3] = []
	for walker: Walker in squad.walkers:
		assert_eq(walker.brain.get_siege_task(), BotBrain.SiegeTask.HOLD)
		assert_true(_view.is_in_circle(walker.position), "inside the circle (%s)" % walker.position)
		spots.append(walker.position)
	var closest: float = INF
	for i: int in spots.size():
		for j: int in range(i + 1, spots.size()):
			closest = minf(closest, spots[i].distance_to(spots[j]))
	assert_true(closest > 0.3, "without piling up (the two closest at %.2f m)" % closest)
