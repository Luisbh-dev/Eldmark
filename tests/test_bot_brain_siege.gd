extends TestCase
## El patrón de asedio de [BotBrain] ([constant BotBrain.Pattern.SIEGE], GUE-15; docs/fuerte.md, sección 7)
## sin física: un punto que se mueve donde dicen las entradas ([Walker]), el fuerte del Vado Gris de verdad
## ([SiegeView] con las posiciones de la puerta y el círculo) y las rutas de [code]data/routes/vado_gris.tres[/code].
## Se comprueba que sigue la ruta de su reino (las dos, según su semilla), que golpea la puerta cerrada, entra en
## el círculo si está rota, que el dueño no la golpea, que pelea con el enemigo que tiene a tiro (y no con el que
## está tras la puerta), que se desatasca con un salto y un desvío, que se reinicia al reaparecer y que es
## determinista.

const V: int = NetProtocol.Realm.VARDHEIM
const S: int = NetProtocol.Realm.SOLMARCH
const ROUTES_PATH: String = "res://data/routes/vado_gris.tres"
## Puerta y círculo del Vado Gris (el fuerte está en el origen; norte = -Z).
const GATE: Vector3 = Vector3(-20.0, 0.0, 0.0)
const CIRCLE: Vector3 = Vector3(-8.5, 0.0, 0.0)
const CIRCLE_RADIUS: float = 5.0
const WALK_SPEED: float = 5.0
const SPRINT_SPEED: float = 7.5
const TICKS_PER_SECOND: float = 60.0

var _routes: ApproachRoutes = null
var _view: SiegeView = null


## Un punto que obedece a las entradas: avanza hacia donde mira (y de lado) a la velocidad de caminar o de
## esprint, sin colisiones. Con [member blocked] no se mueve (un obstáculo imaginario).
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
	# Un fuerte neutral, con la puerta entera y el capitán vivo.
	_view.known = true
	_view.owner = 0
	_view.phase = FortressState.Phase.GARRISONED
	_view.gate_health = 9000
	_view.gate_max = 9000


func _brain(realm: int, rng_seed: int = 1) -> BotBrain:
	var brain := BotBrain.new(rng_seed, BotBrain.Pattern.SIEGE)
	brain.set_siege(_view, _routes, realm)
	return brain


func _camp(realm: int) -> Vector3:
	return Vector3(-2.5, 0.0, -132.0 if realm == V else 132.0)


## Avanza hasta que se cumpla [param done] o pasen [param max_ticks]; devuelve los ticks que hicieron falta
## (-1 si no se cumplió).
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
	assert_eq(BotBrain.Pattern.SIEGE, 5, "el patrón nuevo no mueve los valores de los demás")


func test_without_a_fortress_a_siege_brain_just_wanders() -> void:
	var brain := BotBrain.new(3, BotBrain.Pattern.SIEGE, Vector3.ZERO, 20.0)
	assert_false(brain.has_siege())
	var walker := Walker.new(Vector3.ZERO)
	var moved: bool = false
	for _i: int in 300:
		walker.step(brain)
		moved = moved or walker.position.length() > 1.0
	assert_true(moved, "sin fuerte pasea como un WANDER")
	assert_eq(brain.get_siege_task(), BotBrain.SiegeTask.NONE)


func test_it_follows_the_route_of_its_realm_to_the_front_of_the_gate() -> void:
	for realm: int in [V, S]:
		var side: float = -1.0 if realm == V else 1.0
		var brain: BotBrain = _brain(realm, 5)
		var walker := Walker.new(_camp(realm))
		var arrived: int = _run(walker, brain, 6000, func() -> bool:
			return brain.get_siege_task() == BotBrain.SiegeTask.ASSAULT)
		if not assert_true(arrived > 0, "%s llega a la puerta" % NetProtocol.realm_display_name(realm)):
			continue
		assert_true(brain.get_siege_route() == ApproachRoutes.BRIDGE or brain.get_siege_route() == ApproachRoutes.FORD,
				"ha elegido una ruta")
		var seconds: float = float(arrived) / TICKS_PER_SECOND
		assert_true(seconds < 70.0, "en un tiempo razonable (%.1f s)" % seconds)
		assert_true(walker.position.distance_to(Vector3(-25.0, 0.0, 0.0)) < 8.0,
				"acaba delante de la puerta (%s)" % walker.position)
		assert_true(walker.position.z * side <= 4.0, "sin cruzar al otro lado")


func test_the_seed_picks_the_bridge_or_the_ford() -> void:
	var chosen: Dictionary = {}
	for rng_seed: int in range(1, 17):
		var brain: BotBrain = _brain(V, rng_seed)
		var walker := Walker.new(_camp(V))
		walker.step(brain)
		chosen[brain.get_siege_route()] = true
	assert_true(chosen.has(ApproachRoutes.BRIDGE), "con alguna semilla va por el puente")
	assert_true(chosen.has(ApproachRoutes.FORD), "y con otra por el vado")
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
		assert_true(worst < 4.0, "semilla %d: nunca a más de 4 m de la ruta (%.1f m)" % [rng_seed, worst])


func test_it_hits_a_closed_gate_from_in_front_and_keeps_still() -> void:
	var brain: BotBrain = _brain(V, 7)
	var walker := Walker.new(Vector3(-25.0, 0.0, -2.0))
	var settled: int = _run(walker, brain, 600, func() -> bool:
		return walker.position.distance_to(Vector3(GATE.x, 0.0, GATE.z)) <= BotBrain.SIEGE_GATE_ATTACK_DISTANCE + 0.1)
	assert_true(settled > 0, "se acerca a la puerta")
	var stand: Vector3 = walker.position
	for _i: int in 900:
		walker.step(brain)
	assert_eq(brain.get_siege_task(), BotBrain.SiegeTask.ASSAULT)
	assert_vec_near(walker.position, stand, 0.3, "no se mueve mientras golpea")
	assert_true(walker.presses > 20, "golpea la puerta una y otra vez (%d ticks pulsando)" % walker.presses)
	var to_gate: Vector3 = Vector3(GATE.x, 0.0, GATE.z) - walker.position
	assert_near(walker.yaw, fposmod(atan2(-to_gate.x, -to_gate.z), TAU), 0.05, "mirando a la puerta")


func test_a_broken_gate_lets_it_into_the_circle_and_it_stays_there() -> void:
	var brain: BotBrain = _brain(S, 8)
	var walker := Walker.new(Vector3(-25.0, 0.0, 2.0))
	for _i: int in 200:
		walker.step(brain)
	assert_eq(brain.get_siege_task(), BotBrain.SiegeTask.ASSAULT, "con la puerta entera la golpea")
	_view.gate_health = 0
	_view.gate_max = 9000
	var inside: int = _run(walker, brain, 900, func() -> bool:
		return walker.position.distance_to(CIRCLE) <= CIRCLE_RADIUS * BotBrain.SIEGE_CIRCLE_HOLD_FRACTION)
	assert_true(inside > 0, "entra en el círculo (%s)" % walker.position)
	var stand: Vector3 = walker.position
	var presses_before: int = walker.presses
	for _i: int in 300:
		walker.step(brain)
	assert_eq(brain.get_siege_task(), BotBrain.SiegeTask.HOLD)
	assert_vec_near(walker.position, stand, 0.2, "se queda dentro")
	assert_eq(walker.presses, presses_before, "y no ataca a nadie")
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
	assert_true(inside > 0, "el dueño marcha hasta el círculo (%s)" % walker.position)
	for _i: int in 300:
		walker.step(brain)
	assert_eq(walker.presses, 0, "y no golpea su propia puerta")
	# Un atacante del otro reino sí la golpea con la misma vista.
	var attacker: BotBrain = _brain(S, 9)
	var attacker_walker := Walker.new(Vector3(-22.4, 0.0, 0.0))
	for _i: int in 300:
		attacker_walker.step(attacker)
	assert_true(attacker_walker.presses > 5, "el atacante sí (%d)" % attacker_walker.presses)


func test_it_fights_an_enemy_in_range_and_ignores_a_far_one() -> void:
	var enemy: Array[Variant] = [null]
	var brain: BotBrain = _brain(V, 11)
	brain.set_enemy_finder(func(_position: Vector3) -> Variant: return enemy[0])
	var walker := Walker.new(_camp(V))
	for _i: int in 120:
		walker.step(brain)
	var route_task: BotBrain.SiegeTask = brain.get_siege_task()
	assert_eq(route_task, BotBrain.SiegeTask.MARCH, "sin enemigos marcha")
	# Un enemigo a 40 m no cambia nada.
	enemy[0] = walker.position + Vector3(30.0, 0.0, 0.0)
	for _i: int in 30:
		walker.step(brain)
	assert_eq(brain.get_siege_task(), BotBrain.SiegeTask.MARCH, "lejos no le hace desviarse")
	# Uno a 5 m: se vuelve hacia él, se acerca y le pega.
	var fixed: Vector3 = walker.position + Vector3(4.0, 0.0, 0.0)
	enemy[0] = fixed
	var presses_before: int = walker.presses
	for _i: int in 240:
		walker.step(brain)
	assert_eq(brain.get_siege_task(), BotBrain.SiegeTask.FIGHT)
	assert_true(walker.position.distance_to(fixed) < BotBrain.COMBAT_ENGAGE_DISTANCE, "se ha acercado")
	assert_true(walker.presses > presses_before, "y ataca")
	# Muerto el enemigo, retoma la marcha.
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
	assert_eq(brain.get_siege_task(), BotBrain.SiegeTask.ASSAULT, "sigue con la puerta")
	assert_true(walker.position.x < GATE.x, "no intenta cruzar")
	# Con la puerta rota el mismo enemigo sí es un blanco.
	_view.gate_health = 0
	_view.gate_max = 9000
	for _i: int in 200:
		walker.step(brain)
	assert_eq(brain.get_siege_task(), BotBrain.SiegeTask.FIGHT, "rota la puerta, va a por él")


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
			# El desvío mira de lado respecto del rumbo normal: el yaw cambia más de 1 rad.
			var points: PackedVector2Array = _routes.get_points(brain.get_siege_route(), RealmCatalog.VARDHEIM)
			var target: Vector2 = points[brain.get_siege_route_index()]
			var wanted := Vector3(target.x - walker.position.x, 0.0, target.y - walker.position.z)
			var straight: float = fposmod(atan2(-wanted.x, -wanted.z), TAU)
			if absf(angle_difference(walker.last_input.look_yaw, straight)) > 1.0:
				detour = tick
	assert_true(first_jump >= BotBrain.SIEGE_STUCK_TICKS and first_jump <= BotBrain.SIEGE_STUCK_TICKS + 3,
			"a los %d ticks sin avanzar prueba un salto (tick %d)" % [BotBrain.SIEGE_STUCK_TICKS, first_jump])
	assert_true(detour > first_jump, "después prueba un desvío lateral (tick %d)" % detour)
	assert_true(detour - first_jump >= BotBrain.SIEGE_STUCK_TICKS, "tras otros %d ticks sin avanzar" % BotBrain.SIEGE_STUCK_TICKS)
	# Y una vez libre, vuelve a la ruta: el contador de atasco se pone a cero.
	walker.blocked = false
	var before: Vector3 = walker.position
	for _i: int in 400:
		walker.step(brain)
	assert_true(walker.position.distance_to(before) > 15.0, "libre, vuelve a avanzar")


func test_a_bot_that_waits_on_purpose_is_not_stuck() -> void:
	var brain: BotBrain = _brain(V, 14)
	var walker := Walker.new(Vector3(-25.0, 0.0, -2.0))
	var settled: int = _run(walker, brain, 600, func() -> bool:
		return brain.get_siege_task() == BotBrain.SiegeTask.ASSAULT \
				and walker.position.distance_to(Vector3(GATE.x, 0.0, GATE.z)) <= BotBrain.SIEGE_GATE_ATTACK_DISTANCE)
	assert_true(settled > 0, "llega a la puerta")
	# Quieto golpeando la puerta: no avanza, y no es un atasco.
	walker.jumps = 0
	walker.blocked = true
	for _i: int in 1200:
		walker.step(brain)
	assert_eq(walker.jumps, 0, "golpear la puerta quieto no es estar atascado")
	# Lo mismo esperando dentro del círculo.
	_view.gate_health = 0
	var inner := Walker.new(CIRCLE)
	var waiting: BotBrain = _brain(S, 17)
	for _i: int in 1200:
		inner.step(waiting)
	assert_eq(inner.jumps, 0, "esperar en el círculo tampoco")


func test_a_teleport_to_the_camp_restarts_the_route() -> void:
	var brain: BotBrain = _brain(V, 15)
	var walker := Walker.new(_camp(V))
	for _i: int in 1500:
		walker.step(brain)
	var index_before: int = brain.get_siege_route_index()
	assert_true(index_before >= 2, "va por la ruta (punto %d)" % index_before)
	walker.position = _camp(V)
	walker.step(brain)
	assert_true(brain.get_siege_route_index() <= 1, "tras reaparecer vuelve a empezar por el principio (%d)" % brain.get_siege_route_index())
	assert_eq(brain.get_siege_task(), BotBrain.SiegeTask.MARCH)


func test_a_bot_inside_the_fort_skips_the_route() -> void:
	_view.owner = V
	var brain: BotBrain = _brain(V, 16)
	var walker := Walker.new(Vector3(10.0, 0.0, 14.0))
	for _i: int in 20:
		walker.step(brain)
	assert_eq(brain.get_siege_task(), BotBrain.SiegeTask.HOLD, "ya dentro del recinto: al círculo")
	assert_true(walker.position.x < 10.0, "camina hacia el círculo, no hacia fuera")


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
	assert_true(runs[0] == runs[1], "mismas entradas en las dos ejecuciones")
	assert_true(runs[0].size() > 0)
	# Y otra semilla da otras (la ruta o los golpes cambian).
	var other: BotBrain = _brain(S, 22)
	var other_walker := Walker.new(_camp(S))
	var other_bytes := PackedByteArray()
	for _tick: int in 4000:
		other_bytes.append_array(other_walker.step(other).encode())
	assert_false(other_bytes == runs[0], "otra semilla, otras entradas")


func test_a_threat_covers_the_front_half_plane_up_to_its_reach_plus_the_margin() -> void:
	# Un golpe que mira hacia -Z (yaw 0) con 3,5 m de alcance desde el origen.
	var threat := BotBrain.Threat.new(Vector3.ZERO, 0.0, 3.5)
	var margin: float = BotBrain.SIEGE_THREAT_MARGIN
	assert_true(threat.covers(Vector3(0.0, 0.0, -2.0), margin), "delante, dentro del alcance")
	assert_true(threat.covers(Vector3(0.0, 0.0, -3.5 - margin + 0.05), margin), "y hasta el alcance más el margen")
	assert_false(threat.covers(Vector3(0.0, 0.0, -3.5 - margin - 0.05), margin), "más allá, no")
	assert_true(threat.covers(Vector3(3.0, 0.0, 0.0), margin), "de lado (el semiplano de delante, con el margen)")
	assert_true(threat.covers(Vector3(1.0, 0.0, margin - 0.05), margin), "un poco por detrás, dentro del margen")
	assert_false(threat.covers(Vector3(0.0, 0.0, margin + 0.5), margin), "detrás de quien golpea, a salvo")
	assert_true(threat.covers(Vector3(0.0, 5.0, -1.0), margin), "la altura no cuenta")


func test_it_dodges_out_of_a_telegraphed_hit_without_blocking() -> void:
	var threats: Array[BotBrain.Threat] = []
	var brain: BotBrain = _brain(V, 31)
	brain.set_threat_finder(func(_position: Vector3) -> Array[BotBrain.Threat]: return threats)
	# Pegando a la puerta.
	var walker := Walker.new(Vector3(GATE.x - BotBrain.SIEGE_GATE_ATTACK_DISTANCE, 0.0, 0.3))
	for _i: int in 60:
		walker.step(brain)
	assert_eq(brain.get_siege_task(), BotBrain.SiegeTask.ASSAULT, "golpea la puerta")
	# Un PNJ a 2 m al norte que le mira (hacia +Z: yaw PI) avisa su golpe (3,5 m): sale de la zona.
	var origin: Vector3 = walker.position + Vector3(0.0, 0.0, -2.0)
	threats.append(BotBrain.Threat.new(origin, PI, 3.5))
	assert_true(threats[0].covers(walker.position, BotBrain.SIEGE_THREAT_MARGIN), "está dentro")
	var first: PlayerInput = walker.step(brain)
	assert_eq(brain.get_siege_task(), BotBrain.SiegeTask.EVADE)
	assert_true(first.has(PlayerInput.DODGE), "esquiva nada más verlo")
	assert_true(first.has(PlayerInput.SPRINT), "y esprinta")
	assert_false(first.has(PlayerInput.BLOCK), "sin bloquear")
	assert_false(first.has(PlayerInput.PRIMARY), "ni seguir golpeando")
	var blocked: bool = false
	var dodges: int = 1
	var ticks: int = 1
	while threats[0].covers(walker.position, BotBrain.SIEGE_THREAT_MARGIN) and ticks < 120:
		var input: PlayerInput = walker.step(brain)
		blocked = blocked or input.has(PlayerInput.BLOCK)
		dodges += 1 if input.has(PlayerInput.DODGE) else 0
		ticks += 1
	assert_false(blocked, "nunca bloquea dentro de la zona")
	assert_true(ticks < 60, "sale antes del impacto (1 s): %d ticks" % ticks)
	assert_true(walker.position.distance_to(origin) > 3.5 + BotBrain.SIEGE_THREAT_MARGIN - 0.2,
			"lejos del golpe (%.2f m)" % walker.position.distance_to(origin))
	# Fuera de la zona vuelve a lo suyo, aunque el aviso siga.
	walker.step(brain)
	assert_true(brain.get_siege_task() != BotBrain.SiegeTask.EVADE, "fuera, vuelve a su plan")
	# Un golpe que mira hacia el otro lado (hacia -Z: yaw 0) no le aparta.
	threats.clear()
	threats.append(BotBrain.Threat.new(walker.position + Vector3(0.0, 0.0, -2.0), 0.0, 3.5))
	assert_false(threats[0].covers(walker.position, BotBrain.SIEGE_THREAT_MARGIN))
	walker.step(brain)
	assert_true(brain.get_siege_task() != BotBrain.SiegeTask.EVADE, "un golpe que no le alcanza no cuenta")


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
			"va a por el PNJ aunque el jugador esté más cerca (%.2f m)" % walker.position.distance_to(npc))
	# Muerto el PNJ, el jugador.
	defender[0] = null
	player[0] = walker.position + Vector3(0.0, 0.0, 4.0)
	var target: Vector3 = player[0]
	for _i: int in 120:
		walker.step(brain)
	assert_true(walker.position.distance_to(target) < BotBrain.COMBAT_ENGAGE_DISTANCE, "luego, el jugador")
	# Un PNJ tras la puerta cerrada no le distrae de la puerta.
	_view.gate_health = 9000
	var outside := Walker.new(Vector3(GATE.x - 6.0, 0.0, 0.0))
	var other: BotBrain = _brain(V, 33)
	other.set_defender_finder(func(_position: Vector3) -> Variant: return Vector3(GATE.x + 3.0, 0.0, 0.0))
	for _i: int in 200:
		outside.step(other)
	assert_eq(other.get_siege_task(), BotBrain.SiegeTask.ASSAULT, "el PNJ de dentro no se alcanza: golpea la puerta")


func test_it_gives_up_a_chase_that_does_not_get_closer() -> void:
	# Un guardia tras un muro (o en la pasarela): el bot no se acerca por mucho que camine. Antes se quedaba pegado al
	# muro para siempre (pelear no es estar atascado).
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
			"deja la persecución a los %d ticks sin acercarse (%d)" % [BotBrain.SIEGE_STUCK_TICKS, gave_up])
	assert_eq(brain.get_siege_task(), BotBrain.SiegeTask.HOLD, "y vuelve a su plan: el círculo")
	walker.blocked = false
	for _i: int in BotBrain.SIEGE_CHASE_GIVE_UP_TICKS - 60:
		walker.step(brain)
		if brain.get_siege_task() == BotBrain.SiegeTask.FIGHT:
			break
	assert_eq(brain.get_siege_task(), BotBrain.SiegeTask.HOLD, "un rato sin perseguir al de lejos")
	# Uno que se le pone a menos de la distancia de pelea sí cuenta.
	enemy[0] = walker.position + Vector3(0.0, 0.0, -2.0)
	for _i: int in 6:
		walker.step(brain)
	assert_eq(brain.get_siege_task(), BotBrain.SiegeTask.FIGHT, "a 2 m pelea aunque haya dejado la persecución")
	# Pasado el plazo vuelve a perseguir.
	enemy[0] = walker.position + Vector3(0.0, 0.0, -8.0)
	for _i: int in BotBrain.SIEGE_CHASE_GIVE_UP_TICKS:
		walker.step(brain)
		if brain.get_siege_task() == BotBrain.SiegeTask.FIGHT:
			break
	assert_eq(brain.get_siege_task(), BotBrain.SiegeTask.FIGHT, "pasado el plazo, persigue otra vez")


func test_outside_by_a_side_wall_it_walks_around_the_enclosure_instead_of_into_it() -> void:
	# El recinto de 40 x 40 m (la empalizada va de x = -20 a 20 y de z = -20 a 20). Antes, un bot que una persecución
	# dejaba pegado a la pared sur por fuera se creía dentro (a menos de 30 m del círculo) y caminaba contra ella.
	_view.enclosure_size = Vector2(40.0, 40.0)
	_view.gate_health = 0
	assert_eq(_view.is_inside_enclosure(Vector3(-7.0, 0.0, 22.0), BotBrain.SIEGE_ENCLOSURE_MARGIN), 0, "fuera, junto a la pared sur")
	assert_eq(_view.is_inside_enclosure(Vector3(-7.0, 0.0, 18.0), BotBrain.SIEGE_ENCLOSURE_MARGIN), 1, "dentro")
	assert_eq(SiegeView.new().is_inside_enclosure(Vector3.ZERO), -1, "sin recinto no se sabe")
	var brain: BotBrain = _brain(S, 36)
	var walker := Walker.new(Vector3(GATE.x - 5.0, 0.0, 1.0))
	for _i: int in 30:
		walker.step(brain)
	assert_eq(brain.get_siege_route_index(), _routes.get_points(brain.get_siege_route(), RealmCatalog.SOLMARCH).size(),
			"en la explanada ya ha recorrido la ruta")
	# Le lleva una persecución por fuera hasta la pared sur (pasos de 1 m: no es una reaparición).
	for corner: Vector3 in [Vector3(-24.0, 0.0, 22.0), Vector3(-8.0, 0.0, 22.0)]:
		while walker.position.distance_to(corner) > 1.0:
			walker.position = walker.position.move_toward(corner, 1.0)
			walker.step(brain)
	assert_eq(brain.get_siege_route_index(), _routes.get_points(brain.get_siege_route(), RealmCatalog.SOLMARCH).size(),
			"sigue con la ruta hecha")
	# (Las lambdas copian las variables: la marca va en un Array.)
	var crossed_wall: Array[bool] = [false]
	var entered: int = _run(walker, brain, 1800, func() -> bool:
		var p: Vector3 = walker.position
		if p.x > GATE.x + 0.5 and absf(p.z) < 20.0 and absf(p.z) > 3.0:
			crossed_wall[0] = true
		return Vector2(p.x - CIRCLE.x, p.z - CIRCLE.z).length() <= CIRCLE_RADIUS * BotBrain.SIEGE_CIRCLE_HOLD_FRACTION)
	assert_true(entered > 0, "llega al círculo")
	assert_false(crossed_wall[0], "sin atravesar la empalizada: rodea la esquina y entra por la puerta")


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
	assert_true(runs[0] == runs[1], "mismas entradas en las dos ejecuciones")


func test_combat_and_the_other_patterns_are_unchanged() -> void:
	# La secuencia de un COMBAT con un enemigo fijo (semilla y posiciones fijas) no ha cambiado al añadir el asedio:
	# su huella es la del código anterior.
	var brain := BotBrain.new(77, BotBrain.Pattern.COMBAT, Vector3.ZERO, 30.0)
	brain.set_enemy_finder(func(_position: Vector3) -> Variant: return Vector3(2.0, 0.0, 0.0))
	var bytes := PackedByteArray()
	for tick: int in range(1, 601):
		bytes.append_array(brain.next_input(tick, Vector3.ZERO, 0.0).quantized().encode())
	assert_eq(bytes.size(), 600 * PlayerInput.ENCODED_SIZE)
	assert_eq(hash(bytes), COMBAT_FINGERPRINT, "huella de 600 ticks de combate")
	var wander := BotBrain.new(78, BotBrain.Pattern.WANDER, Vector3.ZERO, 30.0)
	var wander_bytes := PackedByteArray()
	for tick: int in range(1, 601):
		wander_bytes.append_array(wander.next_input(tick, Vector3.ZERO, 0.0).quantized().encode())
	assert_eq(hash(wander_bytes), WANDER_FINGERPRINT, "huella de 600 ticks de paseo")


## Huellas de 600 ticks de COMBAT y WANDER calculadas con el código anterior al asedio.
const COMBAT_FINGERPRINT: int = 2334970325
const WANDER_FINGERPRINT: int = 2761780144
