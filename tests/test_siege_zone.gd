extends TestCase
## Un asedio de verdad sobre el Vado Gris (GUE-15; docs/fuerte.md, sección 7): jugadores falsos con el cerebro
## de asedio ([constant BotBrain.Pattern.SIEGE]) salen de su campamento, llegan a la puerta por las dos rutas,
## la rompen, matan al capitán (el doble de pruebas de [method ZoneServer.spawn_captain_double] o la orden
## [code]fort_kill_captain[/code]), capturan el fuerte neutral y luego los de otro reino lo recapturan. Es el
## [SiegeRunner] de [code]tools/war/siege_runner.gd[/code] con pocos bots y la captura acelerada (orden 11);
## la batalla larga, con muchos, es la herramienta [code]tools/war/siege_battle.gd[/code].

const VARDHEIM: int = NetProtocol.Realm.VARDHEIM
const SOLMARCH: int = NetProtocol.Realm.SOLMARCH
const ROUTES_PATH: String = "res://data/routes/vado_gris.tres"

var _runner: SiegeRunner = null


func before_each() -> void:
	_runner = SiegeRunner.new()
	tree.root.add_child(_runner)
	assert_true(await _runner.start(tree.root), "el servidor arranca sobre el Vado Gris")


func after_each() -> void:
	if is_instance_valid(_runner):
		_runner.finish()
		_runner.get_parent().remove_child(_runner)
		_runner.free()
	_runner = null
	await wait_process_frames()


## Semillas cuyo cerebro elige [param route] (la ruta sale del primer sorteo del generador del bot).
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
	assert_true(routes.has_places(), "las rutas saben dónde está el fuerte")
	var fortresses: FortressController = _runner.server.get_fortresses()
	var id: StringName = _runner.fortress_id()
	var gate: FortGate = fortresses.get_gate(id)
	var circle: Dictionary = fortresses.get_circle(id)
	assert_near(gate.global_position.x, routes.gate_point.x, 0.01, "x de la puerta")
	assert_near(gate.global_position.z, routes.gate_point.y, 0.01, "z de la puerta")
	assert_near((circle["center"] as Vector3).x, routes.circle_point.x, 0.01, "x del círculo")
	assert_near((circle["center"] as Vector3).z, routes.circle_point.y, 0.01, "z del círculo")
	assert_near(float(circle["radius"]), routes.circle_radius, 0.01, "radio del círculo")
	var view: SiegeView = _runner.server.get_siege_view()
	assert_not_null(view, "el servidor da la vista de asedio de la fortaleza")
	assert_vec_near(view.gate_position, gate.global_position, 0.01, "con la puerta de la escena")
	var from_routes := SiegeView.new()
	assert_true(from_routes.set_places_from_routes(routes, 10.2))
	assert_near(from_routes.circle_center.x, view.circle_center.x, 0.01, "y el mismo círculo que los datos")
	assert_false(SiegeView.new().set_places_from_routes(ApproachRoutes.new()), "unas rutas sin fuerte no dicen nada")


func test_bots_from_the_camp_reach_the_gate_by_both_routes_and_break_it() -> void:
	var bridge_seeds: Array[int] = _seeds_for(ApproachRoutes.BRIDGE, 3)
	var ford_seeds: Array[int] = _seeds_for(ApproachRoutes.FORD, 3)
	assert_eq(bridge_seeds.size(), 3, "hay semillas que van por el puente")
	assert_eq(ford_seeds.size(), 3, "y otras por el vado")
	var ids: Array[int] = []
	for rng_seed: int in bridge_seeds + ford_seeds:
		ids.append_array(_runner.add_siege_bots(VARDHEIM, 1, rng_seed))
	assert_eq(ids.size(), 6)
	var arrived: int = await _runner.advance_until(func() -> bool: return _runner.arrivals.size() == 6, 5400)
	if not assert_true(arrived >= 0, "los seis llegan a la puerta en menos de 90 s (%d)" % _runner.arrivals.size()):
		return
	var by_route: Dictionary = {}
	for net_id: int in _runner.arrivals:
		var arrival: Dictionary = _runner.arrivals[net_id]
		var route: StringName = arrival["route"]
		by_route[route] = maxi(int(by_route.get(route, 0)), int(arrival["tick"]))
	assert_true(by_route.has(ApproachRoutes.BRIDGE) and by_route.has(ApproachRoutes.FORD), "por las dos rutas")
	var bridge_seconds: float = SiegeRunner.seconds(int(by_route[ApproachRoutes.BRIDGE]))
	var ford_seconds: float = SiegeRunner.seconds(int(by_route[ApproachRoutes.FORD]))
	print("[siege] llegada a la puerta: puente %.1f s, vado %.1f s" % [bridge_seconds, ford_seconds])
	assert_true(bridge_seconds < 40.0, "el puente, directo (%.1f s)" % bridge_seconds)
	assert_true(ford_seconds < 60.0, "el vado, más largo (%.1f s)" % ford_seconds)
	assert_true(ford_seconds > bridge_seconds, "y tarda más")
	# Rompen la puerta (con ~6 bots en poco más de 30 s) y avisa la guerra.
	var broken: int = await _runner.advance_until(func() -> bool: return _runner.state().is_gate_broken(), 4800)
	var break_seconds: float = SiegeRunner.seconds(_runner.tick_of_war(WarEvents.GATE_BROKEN) \
			- _runner.tick_of_war(WarEvents.UNDER_ATTACK))
	print("[siege] la puerta se rompe %.1f s después del primer golpe" % break_seconds)
	if assert_true(broken >= 0, "la puerta se rompe"):
		assert_true(_runner.war_ids().has(WarEvents.UNDER_ATTACK), "avisó de que atacaban el fuerte")
		assert_true(_runner.war_ids().has(WarEvents.GATE_BROKEN), "y de que la puerta cae")
		assert_true(break_seconds < 60.0, "en menos de un minuto (%.1f s)" % break_seconds)


func test_bots_capture_the_neutral_fort_killing_the_captain_themselves() -> void:
	var captain: int = _runner.spawn_captain_double()
	assert_true(captain > 0, "el doble del capitán")
	_runner.add_siege_bots(VARDHEIM, 6, 40)
	_runner.set_capture_speed(30)
	var state: FortressState = _runner.state()
	var captured: int = await _runner.advance_until(func() -> bool:
		return state.owner == VARDHEIM, 12000)
	print("[siege] captura del fuerte neutral: %.1f s (capitán caído en %.1f s)" % [
		SiegeRunner.seconds(_runner.tick_of_war(WarEvents.FORT_CAPTURED)),
		SiegeRunner.seconds(_runner.tick_of_war(WarEvents.CAPTAIN_DOWN))])
	if not assert_true(captured >= 0, "Vardheim captura el fuerte (fase %d, dueño %d)" % [state.phase, state.owner]):
		return
	assert_eq(state.owner, VARDHEIM)
	assert_eq(state.phase, FortressState.Phase.CONSOLIDATING, "y empieza a consolidarlo")
	var ids: Array[int] = _runner.war_ids()
	assert_true(ids.find(WarEvents.CAPTAIN_DOWN) >= 0 and ids.find(WarEvents.CAPTAIN_DOWN) < ids.find(WarEvents.CAPTURE_STARTED),
			"el capitán cayó antes de empezar la captura: %s" % [ids])
	assert_true(ids.find(WarEvents.GATE_BROKEN) < ids.find(WarEvents.CAPTAIN_DOWN), "y la puerta se rompió antes")
	assert_true(ids.has(WarEvents.FORT_CAPTURED))
	assert_eq(_runner.server.get_combat().get_combatant(captain).is_dead(), true, "lo mataron los bots")
	# Los atacantes defienden ahora el círculo: se quedan dentro y no tocan su puerta.
	var holding: int = 0
	for net_id: int in _runner.bots:
		var position: Vector3 = _runner.server.get_registry().get_entity(net_id).get_position()
		if Vector2(position.x - (-8.5), position.z).length() <= 6.0:
			holding += 1
	assert_true(holding >= 3, "al menos la mitad sigue en el círculo (%d)" % holding)


func test_other_bots_recapture_the_fort_from_the_new_owner() -> void:
	_runner.server.console_command("fort_owner vardheim")
	await _runner.advance(10)
	var state: FortressState = _runner.state()
	assert_eq(state.owner, VARDHEIM, "el fuerte es de Vardheim")
	assert_eq(state.phase, FortressState.Phase.GARRISONED)
	_runner.add_siege_bots(SOLMARCH, 6, 90)
	_runner.set_capture_speed(30)
	var broken: int = await _runner.advance_until(func() -> bool: return state.is_gate_broken(), 9000)
	if not assert_true(broken >= 0, "Solmarch rompe la puerta de Vardheim"):
		return
	assert_true(_runner.kill_captain(), "cae el capitán")
	var captured: int = await _runner.advance_until(func() -> bool: return state.owner == SOLMARCH, 6000)
	print("[siege] recaptura por Solmarch: puerta rota en %.1f s, capturado en %.1f s" % [
		SiegeRunner.seconds(_runner.tick_of_war(WarEvents.GATE_BROKEN)),
		SiegeRunner.seconds(_runner.tick())])
	assert_true(captured >= 0, "Solmarch captura el fuerte (fase %d, dueño %d)" % [state.phase, state.owner])
	assert_eq(state.owner, SOLMARCH)
	assert_eq(_runner.server.get_fortresses().get_gate(_runner.fortress_id()).get_owner_realm(), SOLMARCH,
			"la puerta es ya de Solmarch")


func test_the_bots_of_the_owner_walk_into_their_own_fort_and_hold_the_circle() -> void:
	_runner.server.console_command("fort_owner vardheim")
	await _runner.advance(10)
	var defenders: Array[int] = _runner.add_siege_bots(VARDHEIM, 3, 10)
	# Los defensores van por la puerta de su propio fuerte (se abre para su reino) hasta el círculo.
	var state: FortressState = _runner.state()
	var inside: int = await _runner.advance_until(func() -> bool:
		return state.presence[VARDHEIM] == 3, 4800)
	assert_true(inside >= 0, "los tres defensores entran en el círculo (%d)" % state.presence[VARDHEIM])
	assert_eq(state.gate_health, state.gate_max, "sin tocar la puerta de su fuerte")
	assert_eq(defenders.size(), 3)


func test_the_long_battle_tool_loads() -> void:
	var tool: GDScript = load("res://tools/war/siege_battle.gd") as GDScript
	if assert_not_null(tool, "la herramienta carga"):
		assert_true(tool.can_instantiate(), "y se puede instanciar")
