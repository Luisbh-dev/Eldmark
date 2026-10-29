extends TestCase
## Un asedio de verdad sobre el Vado Gris (GUE-15; docs/fuerte.md, sección 7): jugadores falsos con el cerebro
## de asedio ([constant BotBrain.Pattern.SIEGE]) salen de su campamento, llegan a la puerta por las dos rutas,
## la rompen, matan al capitán (el doble de pruebas de [method ZoneServer.spawn_captain_double] o la orden
## [code]fort_kill_captain[/code]), capturan el fuerte neutral y luego los de otro reino lo recapturan. Es el
## [SiegeRunner] de [code]tools/war/siege_runner.gd[/code] con pocos bots y la captura acelerada (orden 11);
## la batalla larga, con muchos, es la herramienta [code]tools/war/siege_battle.gd[/code]. Desde GUE-44 los atacantes
## esperan a los suyos en la salida del campamento y salen en grupo por la misma ruta (la prueba de las dos rutas la
## quita para medirlas, y otra comprueba la reunión con el contador de aliados del servidor). Desde GUE-45 una parte de
## los bots sube a la pasarela: los del dueño la guardan (se comprueba que suben de verdad, con la física de la zona) y
## los atacantes la recorren y pelean allí con ellos.

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
	assert_eq(view.enclosure_size, routes.enclosure_size, "y el recinto de los datos (F6b)")
	assert_eq(view.is_inside_enclosure(Vector3(circle["center"])), 1, "el círculo está dentro del recinto")
	assert_eq(view.is_inside_enclosure(gate.global_position - Vector3(3.0, 0.0, 0.0)), 0, "la explanada, fuera")
	var from_routes := SiegeView.new()
	assert_true(from_routes.set_places_from_routes(routes, 10.2))
	assert_near(from_routes.circle_center.x, view.circle_center.x, 0.01, "y el mismo círculo que los datos")
	assert_false(SiegeView.new().set_places_from_routes(ApproachRoutes.new()), "unas rutas sin fuerte no dicen nada")
	# La pasarela de los datos (GUE-45) está donde la escena: su suelo, encima de la puerta, a la altura de los datos.
	var post: Vector2 = routes.walkway_post()
	var space: PhysicsDirectSpaceState3D = _runner.world.get_world_3d().direct_space_state
	var ray := PhysicsRayQueryParameters3D.create(Vector3(post.x, 30.0, post.y), Vector3(post.x, 0.0, post.y),
			PlayerCharacter.WORLD_COLLISION_LAYER)
	var hit: Dictionary = space.intersect_ray(ray)
	if assert_false(hit.is_empty(), "hay suelo encima de la puerta"):
		assert_near((hit["position"] as Vector3).y, routes.walkway_height, 0.05, "el de la pasarela")


func test_bots_from_the_camp_reach_the_gate_by_both_routes_and_break_it() -> void:
	var bridge_seeds: Array[int] = _seeds_for(ApproachRoutes.BRIDGE, 3)
	var ford_seeds: Array[int] = _seeds_for(ApproachRoutes.FORD, 3)
	assert_eq(bridge_seeds.size(), 3, "hay semillas que van por el puente")
	assert_eq(ford_seeds.size(), 3, "y otras por el vado")
	# Sin la reunión (GUE-44), que mandaría a los seis por la misma ruta: cada uno va por la de su semilla.
	_runner.set_rally(0)
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


func test_other_bots_recapture_a_fort_given_to_vardheim() -> void:
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


func test_vardheim_captures_the_neutral_fort_with_the_command_and_solmarch_recaptures_it() -> void:
	var state: FortressState = _runner.state()
	assert_eq(state.owner, 0, "neutral")
	assert_eq(state.phase, FortressState.Phase.GARRISONED)
	var vardheim: Array[int] = _runner.add_siege_bots(VARDHEIM, 6, 40)
	_runner.set_capture_speed(30)
	var broken: int = await _runner.advance_until(func() -> bool: return state.is_gate_broken(), 9000)
	if not assert_true(broken >= 0, "Vardheim rompe la puerta"):
		return
	assert_true(_runner.kill_captain(), "fort_kill_captain: cae el capitán")
	assert_eq(state.phase, FortressState.Phase.VULNERABLE, "el círculo se abre")
	var captured: int = await _runner.advance_until(func() -> bool: return state.owner == VARDHEIM, 3000)
	if not assert_true(captured >= 0, "Vardheim captura el fuerte (fase %d)" % state.phase):
		return
	assert_eq(state.phase, FortressState.Phase.CONSOLIDATING)
	var first_capture_tick: int = _runner.tick()
	# Los de Vardheim se van y salen los de Solmarch: rompen la puerta (repuesta al capturar) con la consolidación
	# en marcha, y cuando el fuerte vuelve a estar guardado cae el capitán otra vez.
	for net_id: int in vardheim:
		_runner.server.remove_fake_player(net_id)
	_runner.add_siege_bots(SOLMARCH, 6, 90)
	var solmarch_broke: int = await _runner.advance_until(func() -> bool: return state.is_gate_broken(), 9000)
	if not assert_true(solmarch_broke >= 0, "Solmarch rompe la puerta de Vardheim"):
		return
	var guarded: int = await _runner.advance_until(func() -> bool:
		return state.phase == FortressState.Phase.GARRISONED, 9000)
	if not assert_true(guarded >= 0, "acaba la consolidación de Vardheim (fase %d)" % state.phase):
		return
	assert_true(_runner.kill_captain(), "cae el capitán del nuevo dueño")
	var recaptured: int = await _runner.advance_until(func() -> bool: return state.owner == SOLMARCH, 6000)
	print("[siege] neutral -> Vardheim en %.1f s y -> Solmarch en %.1f s más" % [
		SiegeRunner.seconds(first_capture_tick), SiegeRunner.seconds(_runner.tick() - first_capture_tick)])
	assert_true(recaptured >= 0, "Solmarch recaptura el fuerte (fase %d, dueño %d)" % [state.phase, state.owner])
	assert_eq(state.owner, SOLMARCH)
	assert_eq(state.phase, FortressState.Phase.CONSOLIDATING)
	var ids: Array[int] = _runner.war_ids()
	assert_eq(ids.count(WarEvents.FORT_CAPTURED), 2, "dos capturas")
	assert_eq(ids.count(WarEvents.CAPTAIN_DOWN), 2, "y dos capitanes caídos")
	assert_eq(ids.count(WarEvents.GATE_BROKEN), 2, "y dos puertas rotas")


func test_the_bots_of_the_owner_walk_into_their_own_fort_and_hold_the_circle_or_the_walkway() -> void:
	_runner.server.console_command("fort_owner vardheim")
	await _runner.advance(10)
	# Las semillas 10 a 13: la 10 y la 13 tienen el papel de la pasarela (GUE-45), la 11 y la 12 no.
	var defenders: Array[int] = _runner.add_siege_bots(VARDHEIM, 4, 10)
	assert_eq(defenders.size(), 4)
	var guards: Array[int] = []
	for net_id: int in defenders:
		if _runner.get_brain(net_id).has_walkway_role():
			guards.append(net_id)
	assert_eq(guards.size(), 2, "dos de los cuatro guardan la pasarela")
	# Los defensores van por la puerta de su propio fuerte (se abre para su reino): dos al círculo y dos, por las rampas,
	# a su puesto de la pasarela encima de la puerta.
	var state: FortressState = _runner.state()
	var up: int = await _runner.advance_until(func() -> bool:
		return state.presence[VARDHEIM] == 2 and _on_their_posts(guards) == 2, 4800)
	print("[siege] el dueño en su fuerte: %d en el círculo y %d en la pasarela a los %.1f s" % [
		state.presence[VARDHEIM], _on_their_posts(guards), SiegeRunner.seconds(_runner.tick())])
	assert_true(up >= 0, "dos en el círculo (%d) y dos en su puesto de la pasarela (%d)" % [state.presence[VARDHEIM],
			_on_their_posts(guards)])
	for net_id: int in guards:
		var position: Vector3 = _runner.server.get_registry().get_entity(net_id).get_position()
		var routes: ApproachRoutes = _runner.server.get_approach_routes()
		assert_true(position.y > routes.walkway_height - 0.3, "subido de verdad: a %.2f m (la pasarela, a %.2f)" % [
				position.y, routes.walkway_height])
		assert_eq(_runner.place_of(position), BattleSummary.WALKWAY, "y el resumen lo cuenta como pasarela")
		assert_eq(_runner.get_brain(net_id).get_siege_task(), BotBrain.SiegeTask.WALKWAY)
	assert_eq(state.gate_health, state.gate_max, "sin tocar la puerta de su fuerte")


func test_an_attacker_of_the_walkway_climbs_and_fights_a_guard_up_there() -> void:
	# GUE-45 con la física de la zona: un guardia de Vardheim en su puesto y un atacante de Solmarch con el papel de la
	# pasarela que entra por la puerta rota, sube por una rampa y pelea con él allí arriba; la muerte sale en la pasarela.
	_runner.server.console_command("fort_owner vardheim")
	await _runner.advance(10)
	var state: FortressState = _runner.state()
	var ground: float = _runner.server.get_fortresses().get_gate(_runner.fortress_id()).global_position.y
	var guard: Array[int] = _runner.add_siege_bots(VARDHEIM, 1, 10)
	_runner.server.teleport(guard[0], Vector3(-12.0, ground + 0.4, 0.0))
	var posted: int = await _runner.advance_until(func() -> bool: return _on_their_posts(guard) == 1, 2400)
	if not assert_true(posted >= 0, "el guardia sube a su puesto"):
		return
	# La puerta cae y entra uno de Solmarch con el papel (semilla 5).
	state.on_gate_damaged(_runner.tick(), state.gate_health, SOLMARCH)
	var climber: Array[int] = _runner.add_siege_bots(SOLMARCH, 1, 5)
	assert_true(_runner.get_brain(climber[0]).is_walkway_sweeper(), "la semilla 5 la recorre atacando")
	_runner.server.teleport(climber[0], Vector3(-15.0, ground + 0.4, 1.0))
	var guard_brain: BotBrain = _runner.get_brain(guard[0])
	var climbed: int = await _runner.advance_until(func() -> bool:
		var at: Vector3 = _runner.server.get_registry().get_entity(climber[0]).get_position()
		return guard_brain.is_on_walkway(at), 1800)
	if not assert_true(climbed >= 0, "el de Solmarch sube a la pasarela"):
		return
	var up_tick: int = _runner.tick()
	var died: int = await _runner.advance_until(func() -> bool: return not _runner.deaths.is_empty(), 3600)
	if not assert_true(died >= 0, "pelean en la pasarela hasta que uno cae"):
		return
	var death: Dictionary = _runner.deaths[0]
	print("[siege] muerte en la pasarela a los %.1f s (el de Solmarch subió a los %.1f s): cae %s en %s" % [
			SiegeRunner.seconds(int(death["tick"])), SiegeRunner.seconds(up_tick),
			WarEvents.realm_label(int(death["realm"])), death["position"]])
	assert_eq(_runner.place_of(death["position"]), BattleSummary.WALKWAY, "la muerte es en la pasarela")
	assert_eq(_runner.deaths.size(), 1, "una sola muerte")


func test_attackers_wait_for_each_other_at_the_camp_and_leave_together() -> void:
	# GUE-44: con el fuerte de Vardheim, los de Solmarch esperan a los suyos en la salida de su campamento; el servidor
	# los cuenta (_count_allies) y salen en cuanto son tres, todos en el mismo tick y por la misma ruta.
	_runner.server.console_command("fort_owner vardheim")
	await _runner.advance(10)
	_runner.set_rally(3)
	var first: Array[int] = _runner.add_siege_bots(SOLMARCH, 2, 600)
	await _runner.advance(120)
	var rally: Vector3 = _runner.get_brain(first[0]).get_siege_rally_point()
	var deadline: int = _runner.get_brain(first[0]).get_rally_deadline()
	assert_true(deadline > _runner.tick(), "el reloj aún no ha salido (tick %d, salida %d)" % [_runner.tick(), deadline])
	for net_id: int in first:
		var brain: BotBrain = _runner.get_brain(net_id)
		assert_true(brain.is_rallying(), "dos de tres: esperan")
		assert_eq(brain.get_siege_task(), BotBrain.SiegeTask.RALLY)
		var position: Vector3 = _runner.server.get_registry().get_entity(net_id).get_position()
		assert_true(Vector2(position.x - rally.x, position.z - rally.z).length() < BotBrain.SIEGE_RALLY_RADIUS,
				"en el punto de reunión (%s)" % position)
	# Un bot de Vardheim (el dueño) no espera ni cuenta para los de Solmarch.
	var owner: Array[int] = _runner.add_siege_bots(VARDHEIM, 1, 650)
	await _runner.advance(30)
	assert_false(_runner.get_brain(owner[0]).is_rallying(), "el dueño no espera")
	assert_true(_runner.get_brain(first[0]).is_rallying(), "y no cuenta como de Solmarch")
	var third: Array[int] = _runner.add_siege_bots(SOLMARCH, 1, 602)
	await _runner.advance(30)
	var departures: Dictionary = {}
	var routes: Dictionary = {}
	for net_id: int in first + third:
		var brain: BotBrain = _runner.get_brain(net_id)
		assert_false(brain.is_rallying(), "con el tercero salen")
		departures[brain.get_last_rally_departure()] = true
		routes[brain.get_siege_route()] = true
	assert_eq(departures.size(), 1, "los tres en el mismo tick: %s" % [departures.keys()])
	assert_true(int(departures.keys()[0]) < deadline, "antes del reloj")
	assert_eq(routes.size(), 1, "por la misma ruta: %s" % [routes.keys()])
	assert_eq(_runner.rally_departures.size(), 3, "y el SiegeRunner apunta las tres salidas")


## Cuántos de [param ids] están en su puesto de la pasarela: a su altura y a menos de 1 m de él.
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
	if assert_not_null(tool, "la herramienta carga"):
		assert_true(tool.can_instantiate(), "y se puede instanciar")
