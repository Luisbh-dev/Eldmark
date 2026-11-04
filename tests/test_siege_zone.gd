extends TestCase
## A real siege on Vado Gris (GUE-15; docs/fortress.md, section 7): fake players with the siege
## brain ([constant BotBrain.Pattern.SIEGE]) leave their camp, reach the door by both routes,
## break it, kill the captain (the test double from [method ZoneServer.spawn_captain_double] or the
## [code]fort_kill_captain[/code] command), capture the neutral fort and then those of another realm recapture it. It is the
## [SiegeRunner] from [code]tools/war/siege_runner.gd[/code] with few bots and accelerated capture (command 11);
## the long battle, with many, is the [code]tools/war/siege_battle.gd[/code] tool. Since GUE-44 the attackers
## wait for their own at the camp exit and leave as a group along the same route (the two-route test
## removes it to measure them, and another one checks the rally with the server's ally counter). Since GUE-45 some of
## the bots climb the walkway: the owner's guard it (it is checked that they really climb, with the zone's physics) and
## the attackers walk it and fight there with them.

const VARDHEIM: int = NetProtocol.Realm.VARDHEIM
const SOLMARCH: int = NetProtocol.Realm.SOLMARCH
const ROUTES_PATH: String = "res://data/routes/vado_gris.tres"

var _runner: SiegeRunner = null


func before_each() -> void:
	_runner = SiegeRunner.new()
	tree.root.add_child(_runner)
	assert_true(await _runner.start(tree.root), "the server starts on Vado Gris")


func after_each() -> void:
	if is_instance_valid(_runner):
		_runner.finish()
		_runner.get_parent().remove_child(_runner)
		_runner.free()
	_runner = null
	await wait_process_frames()


## Seeds whose brain chooses [param route] (the route comes out of the first draw of the bot's generator).
func _seeds_for(route: StringName, count: int) -> Array[int]:
	var routes: ApproachRoutes = load(ROUTES_PATH) as ApproachRoutes
	var view := SiegeView.new()
	view.set_places(Vector3(-20.0, 0.0, 0.0), Vector3(-8.5, 0.0, 0.0), 5.0)
	view.known = true
	view.gate_health = 9000
	view.gate_max = 9000
	var seeds: Array[int] = []
	var candidate: int = 1
	while seeds.size() < count and candidate < 200:
		var brain := BotBrain.new(candidate, BotBrain.Pattern.SIEGE)
		brain.set_siege(view, routes, VARDHEIM)
		brain.next_input(1, Vector3(-2.5, 0.0, -132.0), 0.0)
		if brain.get_siege_route() == route:
			seeds.append(candidate)
		candidate += 1
	return seeds


func test_the_places_in_the_routes_are_the_ones_of_the_scene() -> void:
	var routes: ApproachRoutes = load(ROUTES_PATH) as ApproachRoutes
	assert_true(routes.has_places(), "the routes know where the fort is")
	var fortresses: FortressController = _runner.server.get_fortresses()
	var id: StringName = _runner.fortress_id()
	var gate: FortGate = fortresses.get_gate(id)
	var circle: Dictionary = fortresses.get_circle(id)
	assert_near(gate.global_position.x, routes.gate_point.x, 0.01, "door x")
	assert_near(gate.global_position.z, routes.gate_point.y, 0.01, "door z")
	assert_near((circle["center"] as Vector3).x, routes.circle_point.x, 0.01, "circle x")
	assert_near((circle["center"] as Vector3).z, routes.circle_point.y, 0.01, "circle z")
	assert_near(float(circle["radius"]), routes.circle_radius, 0.01, "circle radius")
	var view: SiegeView = _runner.server.get_siege_view()
	assert_not_null(view, "the server gives the fortress's siege view")
	assert_vec_near(view.gate_position, gate.global_position, 0.01, "with the scene's door")
	assert_eq(view.enclosure_size, routes.enclosure_size, "and the data's enclosure (F6b)")
	assert_eq(view.is_inside_enclosure(Vector3(circle["center"])), 1, "the circle is inside the enclosure")
	assert_eq(view.is_inside_enclosure(gate.global_position - Vector3(3.0, 0.0, 0.0)), 0, "the esplanade, outside")
	var from_routes := SiegeView.new()
	assert_true(from_routes.set_places_from_routes(routes, 10.2))
	assert_near(from_routes.circle_center.x, view.circle_center.x, 0.01, "and the same circle as the data")
	assert_false(SiegeView.new().set_places_from_routes(ApproachRoutes.new()), "routes without a fort say nothing")
	# The data's walkway (GUE-45) is where the scene has it: its floor, above the door, at the data's height.
	var post: Vector2 = routes.walkway_post()
	var space: PhysicsDirectSpaceState3D = _runner.world.get_world_3d().direct_space_state
	var ray := PhysicsRayQueryParameters3D.create(Vector3(post.x, 30.0, post.y), Vector3(post.x, 0.0, post.y),
			PlayerCharacter.WORLD_COLLISION_LAYER)
	var hit: Dictionary = space.intersect_ray(ray)
	if assert_false(hit.is_empty(), "there is floor above the door"):
		assert_near((hit["position"] as Vector3).y, routes.walkway_height, 0.05, "the walkway's")


func test_bots_from_the_camp_reach_the_gate_by_both_routes_and_break_it() -> void:
	var bridge_seeds: Array[int] = _seeds_for(ApproachRoutes.BRIDGE, 3)
	var ford_seeds: Array[int] = _seeds_for(ApproachRoutes.FORD, 3)
	assert_eq(bridge_seeds.size(), 3, "there are seeds that take the bridge")
	assert_eq(ford_seeds.size(), 3, "and others the ford")
	# Without the rally (GUE-44), which would send all six along the same route: each one takes the one from its seed.
	_runner.set_rally(0)
	var ids: Array[int] = []
	for rng_seed: int in bridge_seeds + ford_seeds:
		ids.append_array(_runner.add_siege_bots(VARDHEIM, 1, rng_seed))
	assert_eq(ids.size(), 6)
	var arrived: int = await _runner.advance_until(func() -> bool: return _runner.arrivals.size() == 6, 5400)
	if not assert_true(arrived >= 0, "all six reach the door in under 90 s (%d)" % _runner.arrivals.size()):
		return
	var by_route: Dictionary = {}
	for net_id: int in _runner.arrivals:
		var arrival: Dictionary = _runner.arrivals[net_id]
		var route: StringName = arrival["route"]
		by_route[route] = maxi(int(by_route.get(route, 0)), int(arrival["tick"]))
	assert_true(by_route.has(ApproachRoutes.BRIDGE) and by_route.has(ApproachRoutes.FORD), "by both routes")
	var bridge_seconds: float = SiegeRunner.seconds(int(by_route[ApproachRoutes.BRIDGE]))
	var ford_seconds: float = SiegeRunner.seconds(int(by_route[ApproachRoutes.FORD]))
	print("[siege] llegada a la puerta: puente %.1f s, vado %.1f s" % [bridge_seconds, ford_seconds])
	assert_true(bridge_seconds < 40.0, "the bridge, direct (%.1f s)" % bridge_seconds)
	assert_true(ford_seconds < 60.0, "the ford, longer (%.1f s)" % ford_seconds)
	assert_true(ford_seconds > bridge_seconds, "and it takes longer")
	# They break the door (with ~6 bots in a little over 30 s) and the war announces it.
	var broken: int = await _runner.advance_until(func() -> bool: return _runner.state().is_gate_broken(), 4800)
	var break_seconds: float = SiegeRunner.seconds(_runner.tick_of_war(WarEvents.GATE_BROKEN) \
			- _runner.tick_of_war(WarEvents.UNDER_ATTACK))
	print("[siege] la puerta se rompe %.1f s después del primer golpe" % break_seconds)
	if assert_true(broken >= 0, "the door breaks"):
		assert_true(_runner.war_ids().has(WarEvents.UNDER_ATTACK), "it warned that the fort was under attack")
		assert_true(_runner.war_ids().has(WarEvents.GATE_BROKEN), "and that the door is falling")
		assert_true(break_seconds < 60.0, "in under a minute (%.1f s)" % break_seconds)


func test_bots_capture_the_neutral_fort_killing_the_captain_themselves() -> void:
	var captain: int = _runner.spawn_captain_double()
	assert_true(captain > 0, "the captain double")
	_runner.add_siege_bots(VARDHEIM, 6, 40)
	_runner.set_capture_speed(30)
	var state: FortressState = _runner.state()
	var captured: int = await _runner.advance_until(func() -> bool:
		return state.owner == VARDHEIM, 12000)
	print("[siege] captura del fuerte neutral: %.1f s (capitán caído en %.1f s)" % [
		SiegeRunner.seconds(_runner.tick_of_war(WarEvents.FORT_CAPTURED)),
		SiegeRunner.seconds(_runner.tick_of_war(WarEvents.CAPTAIN_DOWN))])
	if not assert_true(captured >= 0, "Vardheim captures the fort (phase %d, owner %d)" % [state.phase, state.owner]):
		return
	assert_eq(state.owner, VARDHEIM)
	assert_eq(state.phase, FortressState.Phase.CONSOLIDATING, "and starts consolidating it")
	var ids: Array[int] = _runner.war_ids()
	assert_true(ids.find(WarEvents.CAPTAIN_DOWN) >= 0 and ids.find(WarEvents.CAPTAIN_DOWN) < ids.find(WarEvents.CAPTURE_STARTED),
			"the captain fell before the capture started: %s" % [ids])
	assert_true(ids.find(WarEvents.GATE_BROKEN) < ids.find(WarEvents.CAPTAIN_DOWN), "and the door broke before that")
	assert_true(ids.has(WarEvents.FORT_CAPTURED))
	assert_eq(_runner.server.get_combat().get_combatant(captain).is_dead(), true, "the bots killed it")
	# The attackers now defend the circle: they stay inside and do not touch their door.
	var holding: int = 0
	for net_id: int in _runner.bots:
		var position: Vector3 = _runner.server.get_registry().get_entity(net_id).get_position()
		if Vector2(position.x - (-8.5), position.z).length() <= 6.0:
			holding += 1
	assert_true(holding >= 3, "at least half are still in the circle (%d)" % holding)


func test_other_bots_recapture_a_fort_given_to_vardheim() -> void:
	_runner.server.console_command("fort_owner vardheim")
	await _runner.advance(10)
	var state: FortressState = _runner.state()
	assert_eq(state.owner, VARDHEIM, "the fort belongs to Vardheim")
	assert_eq(state.phase, FortressState.Phase.GARRISONED)
	_runner.add_siege_bots(SOLMARCH, 6, 90)
	_runner.set_capture_speed(30)
	var broken: int = await _runner.advance_until(func() -> bool: return state.is_gate_broken(), 9000)
	if not assert_true(broken >= 0, "Solmarch breaks Vardheim's door"):
		return
	assert_true(_runner.kill_captain(), "the captain falls")
	var captured: int = await _runner.advance_until(func() -> bool: return state.owner == SOLMARCH, 6000)
	print("[siege] recaptura por Solmarch: puerta rota en %.1f s, capturado en %.1f s" % [
		SiegeRunner.seconds(_runner.tick_of_war(WarEvents.GATE_BROKEN)),
		SiegeRunner.seconds(_runner.tick())])
	assert_true(captured >= 0, "Solmarch captures the fort (phase %d, owner %d)" % [state.phase, state.owner])
	assert_eq(state.owner, SOLMARCH)
	assert_eq(_runner.server.get_fortresses().get_gate(_runner.fortress_id()).get_owner_realm(), SOLMARCH,
			"the door is now Solmarch's")


func test_vardheim_captures_the_neutral_fort_with_the_command_and_solmarch_recaptures_it() -> void:
	var state: FortressState = _runner.state()
	assert_eq(state.owner, 0, "neutral")
	assert_eq(state.phase, FortressState.Phase.GARRISONED)
	var vardheim: Array[int] = _runner.add_siege_bots(VARDHEIM, 6, 40)
	_runner.set_capture_speed(30)
	var broken: int = await _runner.advance_until(func() -> bool: return state.is_gate_broken(), 9000)
	if not assert_true(broken >= 0, "Vardheim breaks the door"):
		return
	assert_true(_runner.kill_captain(), "fort_kill_captain: the captain falls")
	assert_eq(state.phase, FortressState.Phase.VULNERABLE, "the circle opens")
	var captured: int = await _runner.advance_until(func() -> bool: return state.owner == VARDHEIM, 3000)
	if not assert_true(captured >= 0, "Vardheim captures the fort (phase %d)" % state.phase):
		return
	assert_eq(state.phase, FortressState.Phase.CONSOLIDATING)
	var first_capture_tick: int = _runner.tick()
	# The Vardheim ones leave and the Solmarch ones come out: they break the door (restored on capture) with the consolidation
	# underway, and when the fort is guarded again the captain falls once more.
	for net_id: int in vardheim:
		_runner.server.remove_fake_player(net_id)
	_runner.add_siege_bots(SOLMARCH, 6, 90)
	var solmarch_broke: int = await _runner.advance_until(func() -> bool: return state.is_gate_broken(), 9000)
	if not assert_true(solmarch_broke >= 0, "Solmarch breaks Vardheim's door"):
		return
	var guarded: int = await _runner.advance_until(func() -> bool:
		return state.phase == FortressState.Phase.GARRISONED, 9000)
	if not assert_true(guarded >= 0, "Vardheim's consolidation ends (phase %d)" % state.phase):
		return
	assert_true(_runner.kill_captain(), "the new owner's captain falls")
	var recaptured: int = await _runner.advance_until(func() -> bool: return state.owner == SOLMARCH, 6000)
	print("[siege] neutral -> Vardheim en %.1f s y -> Solmarch en %.1f s más" % [
		SiegeRunner.seconds(first_capture_tick), SiegeRunner.seconds(_runner.tick() - first_capture_tick)])
	assert_true(recaptured >= 0, "Solmarch recaptures the fort (phase %d, owner %d)" % [state.phase, state.owner])
	assert_eq(state.owner, SOLMARCH)
	assert_eq(state.phase, FortressState.Phase.CONSOLIDATING)
	var ids: Array[int] = _runner.war_ids()
	assert_eq(ids.count(WarEvents.FORT_CAPTURED), 2, "two captures")
	assert_eq(ids.count(WarEvents.CAPTAIN_DOWN), 2, "and two fallen captains")
	assert_eq(ids.count(WarEvents.GATE_BROKEN), 2, "and two broken doors")


func test_the_bots_of_the_owner_walk_into_their_own_fort_and_hold_the_circle_or_the_walkway() -> void:
	_runner.server.console_command("fort_owner vardheim")
	await _runner.advance(10)
	# Seeds 10 to 13: 10 and 13 have the walkway role (GUE-45), 11 and 12 do not.
	var defenders: Array[int] = _runner.add_siege_bots(VARDHEIM, 4, 10)
	assert_eq(defenders.size(), 4)
	var guards: Array[int] = []
	for net_id: int in defenders:
		if _runner.get_brain(net_id).has_walkway_role():
			guards.append(net_id)
	assert_eq(guards.size(), 2, "two of the four guard the walkway")
	# The defenders go through their own fort's door (it opens for their realm): two to the circle and two, by the ramps,
	# to their walkway post above the door.
	var state: FortressState = _runner.state()
	var up: int = await _runner.advance_until(func() -> bool:
		return state.presence[VARDHEIM] == 2 and _on_their_posts(guards) == 2, 4800)
	print("[siege] el dueño en su fuerte: %d en el círculo y %d en la pasarela a los %.1f s" % [
		state.presence[VARDHEIM], _on_their_posts(guards), SiegeRunner.seconds(_runner.tick())])
	assert_true(up >= 0, "two in the circle (%d) and two at their walkway post (%d)" % [state.presence[VARDHEIM],
			_on_their_posts(guards)])
	for net_id: int in guards:
		var position: Vector3 = _runner.server.get_registry().get_entity(net_id).get_position()
		var routes: ApproachRoutes = _runner.server.get_approach_routes()
		assert_true(position.y > routes.walkway_height - 0.3, "really climbed: at %.2f m (the walkway, at %.2f)" % [
				position.y, routes.walkway_height])
		assert_eq(_runner.place_of(position), BattleSummary.WALKWAY, "and the summary counts it as walkway")
		assert_eq(_runner.get_brain(net_id).get_siege_task(), BotBrain.SiegeTask.WALKWAY)
	assert_eq(state.gate_health, state.gate_max, "without touching their fort's door")


func test_an_attacker_of_the_walkway_climbs_and_fights_a_guard_up_there() -> void:
	# GUE-45 with the zone's physics: a Vardheim guard at its post and a Solmarch attacker with the walkway role
	# who enters through the broken door, climbs a ramp and fights it up there; the death happens on the walkway.
	_runner.server.console_command("fort_owner vardheim")
	await _runner.advance(10)
	var state: FortressState = _runner.state()
	var ground: float = _runner.server.get_fortresses().get_gate(_runner.fortress_id()).global_position.y
	var guard: Array[int] = _runner.add_siege_bots(VARDHEIM, 1, 10)
	_runner.server.teleport(guard[0], Vector3(-12.0, ground + 0.4, 0.0))
	var posted: int = await _runner.advance_until(func() -> bool: return _on_their_posts(guard) == 1, 2400)
	if not assert_true(posted >= 0, "the guard climbs to its post"):
		return
	# The door falls and a Solmarch one with the role enters (seed 5).
	state.on_gate_damaged(_runner.tick(), state.gate_health, SOLMARCH)
	var climber: Array[int] = _runner.add_siege_bots(SOLMARCH, 1, 5)
	assert_true(_runner.get_brain(climber[0]).is_walkway_sweeper(), "seed 5 walks it attacking")
	_runner.server.teleport(climber[0], Vector3(-15.0, ground + 0.4, 1.0))
	var guard_brain: BotBrain = _runner.get_brain(guard[0])
	var climbed: int = await _runner.advance_until(func() -> bool:
		var at: Vector3 = _runner.server.get_registry().get_entity(climber[0]).get_position()
		return guard_brain.is_on_walkway(at), 1800)
	if not assert_true(climbed >= 0, "the Solmarch one climbs to the walkway"):
		return
	var up_tick: int = _runner.tick()
	var died: int = await _runner.advance_until(func() -> bool: return not _runner.deaths.is_empty(), 3600)
	if not assert_true(died >= 0, "they fight on the walkway until one falls"):
		return
	var death: Dictionary = _runner.deaths[0]
	print("[siege] muerte en la pasarela a los %.1f s (el de Solmarch subió a los %.1f s): cae %s en %s" % [
			SiegeRunner.seconds(int(death["tick"])), SiegeRunner.seconds(up_tick),
			WarEvents.realm_label(int(death["realm"])), death["position"]])
	assert_eq(_runner.place_of(death["position"]), BattleSummary.WALKWAY, "the death is on the walkway")
	assert_eq(_runner.deaths.size(), 1, "a single death")


func test_attackers_wait_for_each_other_at_the_camp_and_leave_together() -> void:
	# GUE-44: with Vardheim's fort, the Solmarch ones wait for their own at their camp exit; the server
	# counts them (_count_allies) and they leave as soon as there are three, all on the same tick and along the same route.
	_runner.server.console_command("fort_owner vardheim")
	await _runner.advance(10)
	_runner.set_rally(3)
	var first: Array[int] = _runner.add_siege_bots(SOLMARCH, 2, 600)
	await _runner.advance(120)
	var rally: Vector3 = _runner.get_brain(first[0]).get_siege_rally_point()
	var deadline: int = _runner.get_brain(first[0]).get_rally_deadline()
	assert_true(deadline > _runner.tick(), "the clock has not left yet (tick %d, departure %d)" % [_runner.tick(), deadline])
	for net_id: int in first:
		var brain: BotBrain = _runner.get_brain(net_id)
		assert_true(brain.is_rallying(), "two of three: they wait")
		assert_eq(brain.get_siege_task(), BotBrain.SiegeTask.RALLY)
		var position: Vector3 = _runner.server.get_registry().get_entity(net_id).get_position()
		assert_true(Vector2(position.x - rally.x, position.z - rally.z).length() < BotBrain.SIEGE_RALLY_RADIUS,
				"at the rally point (%s)" % position)
	# A Vardheim bot (the owner) neither waits nor counts for the Solmarch ones.
	var owner: Array[int] = _runner.add_siege_bots(VARDHEIM, 1, 650)
	await _runner.advance(30)
	assert_false(_runner.get_brain(owner[0]).is_rallying(), "the owner does not wait")
	assert_true(_runner.get_brain(first[0]).is_rallying(), "and does not count as a Solmarch one")
	var third: Array[int] = _runner.add_siege_bots(SOLMARCH, 1, 602)
	await _runner.advance(30)
	var departures: Dictionary = {}
	var routes: Dictionary = {}
	for net_id: int in first + third:
		var brain: BotBrain = _runner.get_brain(net_id)
		assert_false(brain.is_rallying(), "with the third they leave")
		departures[brain.get_last_rally_departure()] = true
		routes[brain.get_siege_route()] = true
	assert_eq(departures.size(), 1, "all three on the same tick: %s" % [departures.keys()])
	assert_true(int(departures.keys()[0]) < deadline, "before the clock")
	assert_eq(routes.size(), 1, "along the same route: %s" % [routes.keys()])
	assert_eq(_runner.rally_departures.size(), 3, "and the SiegeRunner records the three departures")


## How many of [param ids] are at their walkway post: at its height and less than 1 m from it.
func _on_their_posts(ids: Array[int]) -> int:
	var count: int = 0
	for net_id: int in ids:
		var brain: BotBrain = _runner.get_brain(net_id)
		var post: Variant = brain.get_walkway_post()
		var entity: NetEntity = _runner.server.get_registry().get_entity(net_id)
		if post is Vector3 and entity != null and entity.get_position().distance_to(post as Vector3) < 1.0:
			count += 1
	return count


func test_the_long_battle_tool_loads() -> void:
	var tool: GDScript = load("res://tools/war/siege_battle.gd") as GDScript
	if assert_not_null(tool, "the tool loads"):
		assert_true(tool.can_instantiate(), "and can be instantiated")
