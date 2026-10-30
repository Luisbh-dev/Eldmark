extends TestCase
## La pasarela del patrón de asedio de [BotBrain] (GUE-45; docs/fuerte.md, secciones 7 y 8.3) sin física: un punto que se
## mueve donde dicen las entradas ([HeightWalker]) en un fuerte con alturas sencillas (el patio llano a 10,2 m, las dos
## rampas de [code]data/routes/vado_gris.tres[/code] y la pasarela a 13,55 m, sin barandilla por dentro: quien se sale de
## su eje más de 1 m cae al patio). Una parte de los bots, por su semilla, tiene el papel de la pasarela: el dueño sube
## por una rampa y guarda su puesto encima de la puerta, sin hacer caso a los de abajo (no los alcanza) y peleando con
## quien sube sin salirse del eje; el atacante (la mitad de esa parte) la recorre una vez al entrar y salta al patio
## camino del círculo.

const V: int = NetProtocol.Realm.VARDHEIM
const S: int = NetProtocol.Realm.SOLMARCH
const ROUTES_PATH: String = "res://data/routes/vado_gris.tres"
## Suelo del patio y de la explanada (la meseta del fuerte), puerta y círculo del Vado Gris.
const FLOOR: float = 10.2
const GATE: Vector3 = Vector3(-20.0, FLOOR, 0.0)
const CIRCLE: Vector3 = Vector3(-8.5, FLOOR + 0.05, 0.0)
const CIRCLE_RADIUS: float = 5.0
## Las rampas (x = 7, 2 m de ancho): suben 3,35 m desde su pie (z = ∓10,87) hasta la pasarela (z = ∓17,77).
const RAMP_X: float = 7.0
const RAMP_HALF_WIDTH: float = 1.0
const RAMP_FOOT_Z: float = 10.87
const RAMP_TOP_Z: float = 17.77
## Media anchura de la pasarela (2 m): más lejos de su eje, se cae.
const WALKWAY_HALF_WIDTH: float = 1.0
const WALK_SPEED: float = 5.0
const SPRINT_SPEED: float = 7.5
const TICKS_PER_SECOND: float = 60.0

var _routes: ApproachRoutes = null
var _view: SiegeView = null


## Un punto que obedece a las entradas, como el de test_bot_brain_siege, pero con altura: sube por las rampas desde su
## pie, anda por la pasarela si llega a ella por una rampa y cae al patio si se sale de ella. Cuenta los golpes, las
## esquivas de lado en la pasarela y las caídas.
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
	## Lo más lejos (m) que ha estado del eje de la pasarela mientras andaba por ella (fuera de las rampas, cuya cima
	## queda en su borde).
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


	## true si la esquiva de [param input] va de través a la pasarela (hacia el patio o el parapeto) y no por su eje: su
	## dirección en el mundo (la del movimiento respecto del yaw de la cámara, como ActionMachine._dodge_yaw) frente a la
	## tangente del eje donde está. Desde la revisión de la integración el bot mira al enemigo y no por el eje, así que
	## una esquiva por el eje puede llevar movimiento de lado en su marco: lo que cuenta es adónde va en el mundo.
	func is_side_dodge(input: PlayerInput) -> bool:
		var dodge_yaw: float = input.look_yaw + PI
		if input.move.length() >= 0.1:
			dodge_yaw = input.look_yaw + atan2(-input.move.x, input.move.y)
		var direction := Vector2(-sin(dodge_yaw), -cos(dodge_yaw))
		var offset: float = routes.walkway_offset(Vector2(position.x, position.z))
		var a: Vector2 = routes.walkway_point(maxf(offset - 0.25, 0.0))
		var b: Vector2 = routes.walkway_point(minf(offset + 0.25, routes.walkway_length()))
		return absf((b - a).normalized().cross(direction)) > 0.1


	## true si [param point] está sobre una de las dos rampas o en su desembarco, entre su cima y el eje de la
	## pasarela (en planta).
	func on_ramp(point: Vector2) -> bool:
		for side: float in [-1.0, 1.0]:
			var z: float = point.y * side
			if absf(point.x - RAMP_X) <= RAMP_HALF_WIDTH and z >= RAMP_FOOT_Z and z <= RAMP_TOP_Z + WALKWAY_HALF_WIDTH:
				return true
		return false


	## La altura (sobre el patio) del suelo que pisa en [param point] viniendo de [param previous]: una rampa si está en
	## ella y a su altura (no se sube a ella de lado ni desde debajo), la pasarela si ya estaba arriba, o el patio.
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
	# El fuerte es de Vardheim, con la puerta entera y el capitán vivo.
	_view.known = true
	_view.owner = V
	_view.phase = FortressState.Phase.GARRISONED
	_view.gate_health = 9000
	_view.gate_max = 9000


func _brain(realm: int, rng_seed: int) -> BotBrain:
	var brain := BotBrain.new(rng_seed, BotBrain.Pattern.SIEGE)
	brain.set_siege(_view, _routes, realm)
	return brain


## Semillas con el papel de la pasarela ([param share]: por defecto el de los que la guardan; con
## [constant BotBrain.SIEGE_WALKWAY_SWEEP_SHARE], los atacantes que la recorren) cuyo hueco cae a un lado del puesto:
## [param side] -1, al norte (x del hueco por debajo de -0,3), 1 al sur.
func _walkway_seeds(side: float, count: int, share: float = BotBrain.SIEGE_WALKWAY_SHARE) -> Array[int]:
	var seeds: Array[int] = []
	var candidate: int = 1
	while seeds.size() < count and candidate < 500:
		if BotBrain.is_walkway_seed(candidate, share) and BotBrain.slot_for_seed(candidate).x * side > 0.3:
			seeds.append(candidate)
		candidate += 1
	return seeds


## Avanza hasta que se cumpla [param done] o pasen [param max_ticks]; devuelve los ticks que hicieron falta (-1 si no).
func _run(walker: HeightWalker, brain: BotBrain, max_ticks: int, done: Callable) -> int:
	for i: int in max_ticks:
		walker.step(brain)
		if bool(done.call()):
			return i + 1
	return -1


## true si [param walker] está en su puesto de la pasarela (a su altura y a menos de
## [constant BotBrain.SIEGE_WALKWAY_REACHED] de él, como lo mira el cerebro).
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
			assert_true(brain.has_walkway_role(), "semilla %d: los que la recorren atacando también la guardan" % rng_seed)
	assert_eq(consecutive, 5, "con la base 1000, 5 de 20 semillas seguidas (las de un reino en siege_battle) la guardan")
	assert_eq(sweepers, 3, "y 3 la recorren cuando atacan (una octava parte de 20 son 2,5)")
	# Con otras bases, de 4 a 6 y de 1 a 4 (revisión de F6b: la base 2000, la de Vardheim en la semilla 2000, da 6).
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
			"de 4 a 6 guardias de cada 20 (%s)" % [counts])
	assert_true(counts.get(5, 0) * 2 > counts.values().reduce(func(a: int, b: int) -> int: return a + b, 0),
			"5 en más de la mitad de las bases (%s)" % [counts])
	assert_eq(sweeping.keys().filter(func(sweeps: int) -> bool: return sweeps < 1 or sweeps > 4), [],
			"de 1 a 4 de cada 20 la recorren (%s)" % [sweeping])
	var of_2000: int = 0
	for index: int in 20:
		of_2000 += 1 if BotBrain.is_walkway_seed(2000 + index) else 0
	assert_eq(of_2000, 6, "con la base 2000, 6")
	assert_true(every_other >= 4 and every_other <= 6, "y de una de cada dos, también una cuarta parte (%d)" % every_other)
	for rng_seed: int in [5, 10, 11, 12, 13]:
		var brain: BotBrain = _brain(V, rng_seed)
		assert_eq(brain.has_walkway_role(), BotBrain.is_walkway_seed(rng_seed), "semilla %d" % rng_seed)
		assert_eq(brain.is_walkway_sweeper(), BotBrain.is_walkway_seed(rng_seed, BotBrain.SIEGE_WALKWAY_SWEEP_SHARE),
				"semilla %d atacando" % rng_seed)
	var brain: BotBrain = _brain(V, 10)
	assert_true(brain.has_walkway_role(), "la semilla 10 la guarda")
	assert_false(brain.is_walkway_sweeper(), "pero atacando no la recorre")
	brain.set_walkway_share(0.0)
	assert_false(brain.has_walkway_role() or brain.is_walkway_sweeper(), "con la parte a 0 nadie sube (como antes de GUE-45)")
	brain.set_walkway_share(1.0)
	assert_true(brain.has_walkway_role(), "con 1, todos la guardan")
	assert_true(brain.is_walkway_sweeper(), "y con la mitad de 1 la recorre también la semilla 10 (%.2f)" % fposmod(
			10.0 * BotBrain.WALKWAY_SEED_STEP, 1.0))
	brain.set_walkway_role(false)
	assert_false(brain.has_walkway_role() or brain.is_walkway_sweeper())
	brain.set_walkway_role(true, false)
	assert_true(brain.has_walkway_role() and not brain.is_walkway_sweeper())
	assert_false(BotBrain.is_walkway_seed(10, 0.0))


func test_the_post_is_over_the_gate_spread_by_the_slot() -> void:
	var post: Vector2 = _routes.walkway_post()
	assert_vec_near(Vector3(post.x, 0.0, post.y), Vector3(-18.77, 0.0, 0.0), 0.01, "encima de la puerta")
	for rng_seed: int in [10, 13, 18, 23]:
		var brain: BotBrain = _brain(V, rng_seed)
		var spot: Vector3 = brain.get_walkway_post()
		assert_near(spot.y, _routes.walkway_height, 0.001, "a la altura de la pasarela")
		assert_near(spot.x, -18.77, 0.01, "en el eje de la pasarela de la cara de la puerta")
		assert_near(spot.z, BotBrain.slot_for_seed(rng_seed).x * BotBrain.SIEGE_WALKWAY_POST_SPREAD, 0.01,
				"a lo largo de ella según su hueco")
	assert_null(BotBrain.new(1, BotBrain.Pattern.SIEGE).get_walkway_post(), "sin fuerte no hay puesto")
	var flat := ApproachRoutes.new()
	flat.gate_point = Vector2(-20.0, 0.0)
	flat.circle_point = Vector2(-8.5, 0.0)
	flat.circle_radius = 5.0
	var no_walkway := BotBrain.new(10, BotBrain.Pattern.SIEGE)
	no_walkway.set_siege(_view, flat, V)
	assert_null(no_walkway.get_walkway_post(), "ni con unas rutas que no conocen la pasarela")


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
		if not assert_true(arrived > 0, "semilla %d: llega a su puesto (%s, a %.2f m)" % [rng_seed, walker.position,
				walker.elevation]):
			continue
		print("[pasarela] semilla %d: del círculo a su puesto en %.1f s" % [rng_seed, float(arrived) / TICKS_PER_SECOND])
		assert_true(float(arrived) / TICKS_PER_SECOND < 25.0, "en menos de 25 s")
		assert_eq(ramp_side[0], side, "por la rampa de su lado (la del norte si su puesto está al norte)")
		assert_eq(walker.falls, 0, "sin caerse")
		assert_true(walker.worst_on_walkway <= 0.6, "por el eje de la pasarela (%.2f m)" % walker.worst_on_walkway)
		assert_eq(brain.get_siege_task(), BotBrain.SiegeTask.WALKWAY)
		var stand: Vector3 = walker.position
		for _i: int in 300:
			walker.step(brain)
		assert_eq(brain.get_siege_task(), BotBrain.SiegeTask.WALKWAY, "y lo guarda")
		assert_vec_near(walker.position, stand, 0.05, "quieto")
		assert_near(walker.yaw, fposmod(atan2(1.0, 0.0), TAU), 0.05, "mirando afuera, hacia la explanada")
		assert_eq(walker.presses, 0, "sin golpear a nadie")


func test_from_outside_the_owner_goes_in_by_its_gate_and_then_climbs() -> void:
	var rng_seed: int = _walkway_seeds(1.0, 1)[0]
	var brain: BotBrain = _brain(V, rng_seed)
	var walker := HeightWalker.new(_routes, Vector3(-27.0, FLOOR, 3.0))
	var crossing: Array[float] = [INF]
	var arrived: int = _run(walker, brain, 2400, func() -> bool:
		if absf(walker.position.x - GATE.x) < 0.3:
			crossing[0] = walker.position.z
		return _at_post(walker, brain))
	assert_true(arrived > 0, "llega a su puesto (%s)" % walker.position)
	assert_true(absf(crossing[0]) <= BotBrain.SIEGE_GATE_OPENING_HALF_WIDTH, "cruzando por el vano (z = %.2f)" % crossing[0])
	assert_eq(walker.falls, 0)


func test_the_owners_without_the_role_still_hold_the_circle() -> void:
	var rng_seed: int = 11
	assert_false(BotBrain.is_walkway_seed(rng_seed))
	var brain: BotBrain = _brain(V, rng_seed)
	var walker := HeightWalker.new(_routes, Vector3(-16.0, FLOOR, 6.0))
	var inside: int = _run(walker, brain, 900, func() -> bool:
		return brain.get_siege_task() == BotBrain.SiegeTask.HOLD and _view.is_in_circle(walker.position))
	assert_true(inside > 0, "va al círculo (%s)" % walker.position)
	assert_eq(walker.elevation, 0.0, "sin subir")


func test_on_the_walkway_it_ignores_the_enemies_below_and_fights_one_that_comes_up() -> void:
	var rng_seed: int = _walkway_seeds(-1.0, 1)[0]
	var brain: BotBrain = _brain(V, rng_seed)
	var enemy: Array[Variant] = [null]
	brain.set_enemy_finder(func(_position: Vector3) -> Variant: return enemy[0])
	var walker := HeightWalker.new(_routes, CIRCLE)
	assert_true(_run(walker, brain, 1800, func() -> bool: return _at_post(walker, brain)) > 0, "en su puesto")
	var stand: Vector3 = walker.position
	# Uno golpeando la puerta, abajo y fuera, a 3 m en horizontal: no lo alcanza (ni él a la pasarela).
	enemy[0] = Vector3(-22.3, FLOOR, stand.z)
	for _i: int in 240:
		walker.step(brain)
	assert_eq(brain.get_siege_task(), BotBrain.SiegeTask.WALKWAY, "sigue en su puesto")
	assert_vec_near(walker.position, stand, 0.05, "sin moverse")
	assert_eq(walker.presses, 0, "ni golpear al aire")
	# Y uno en el patio, justo debajo.
	enemy[0] = Vector3(stand.x + 1.0, FLOOR, stand.z)
	for _i: int in 120:
		walker.step(brain)
	assert_eq(brain.get_siege_task(), BotBrain.SiegeTask.WALKWAY, "tampoco el del patio")
	assert_eq(walker.presses, 0)
	# Uno que sube y viene por la pasarela: va a por él por el eje y le pega.
	var climber := Vector3(-18.77, _routes.walkway_height, stand.z - 8.0)
	enemy[0] = climber
	var engaged: int = _run(walker, brain, 600, func() -> bool:
		return walker.position.distance_to(climber) < BotBrain.COMBAT_ENGAGE_DISTANCE and walker.presses > 0)
	assert_true(engaged > 0, "pelea con el que sube (%s)" % walker.position)
	assert_eq(brain.get_siege_task(), BotBrain.SiegeTask.FIGHT)
	assert_eq(walker.falls, 0, "sin caerse")
	assert_true(walker.worst_on_walkway <= 0.6, "por el eje (%.2f m)" % walker.worst_on_walkway)
	# Muerto el que subió, vuelve a su puesto.
	enemy[0] = null
	assert_true(_run(walker, brain, 600, func() -> bool: return _at_post(walker, brain)) > 0, "vuelve a su puesto")


func test_a_fight_on_the_walkway_goes_round_the_corner_and_never_dodges_sideways() -> void:
	var dodges_seen: int = 0
	for rng_seed: int in _walkway_seeds(-1.0, 4):
		var brain: BotBrain = _brain(V, rng_seed)
		var enemy: Array[Variant] = [null]
		brain.set_enemy_finder(func(_position: Vector3) -> Variant: return enemy[0])
		var walker := HeightWalker.new(_routes, Vector3(-18.77, _routes.walkway_height, -10.0))
		walker.step(brain)
		# Al otro lado de la esquina del noroeste, a 11 m en línea recta (que pasa por encima del patio).
		var foe := Vector3(-12.0, _routes.walkway_height, -18.77)
		enemy[0] = foe
		var engaged: int = _run(walker, brain, 600, func() -> bool:
			return walker.position.distance_to(foe) < BotBrain.COMBAT_ENGAGE_DISTANCE)
		assert_true(engaged > 0, "semilla %d: llega hasta él (%s)" % [rng_seed, walker.position])
		assert_eq(walker.falls, 0, "semilla %d: dobla la esquina sin caerse" % rng_seed)
		assert_true(walker.worst_on_walkway <= 0.6, "por el eje (%.2f m)" % walker.worst_on_walkway)
		# Peleando un buen rato: las esquivas, hacia atrás por el eje y nunca de lado.
		for _i: int in 1200:
			var input: PlayerInput = walker.step(brain)
			dodges_seen += 1 if input.has(PlayerInput.DODGE) else 0
		assert_eq(walker.side_dodges_up, 0, "semilla %d: ninguna esquiva de lado en la pasarela" % rng_seed)
		assert_true(walker.presses > 0, "y le pega")
	assert_true(dodges_seen > 0, "alguna esquiva hubo (%d)" % dodges_seen)


func test_an_attacker_with_the_role_sweeps_the_walkway_once_and_drops_into_the_circle() -> void:
	_view.gate_health = 0
	var rng_seed: int = _walkway_seeds(1.0, 1, BotBrain.SIEGE_WALKWAY_SWEEP_SHARE)[0]
	var brain: BotBrain = _brain(S, rng_seed)
	var walker := HeightWalker.new(_routes, Vector3(-16.0, FLOOR, -1.0))
	var reached: int = _run(walker, brain, 1800, func() -> bool: return brain.is_walkway_swept())
	if not assert_true(reached > 0, "recorre la pasarela hasta el puesto (%s)" % walker.position):
		return
	assert_true(walker.is_up(), "arriba")
	assert_eq(walker.falls, 0)
	var inside: int = _run(walker, brain, 900, func() -> bool:
		return brain.get_siege_task() == BotBrain.SiegeTask.HOLD \
				and walker.position.distance_to(CIRCLE) <= CIRCLE_RADIUS * BotBrain.SIEGE_CIRCLE_HOLD_FRACTION + 0.5)
	assert_true(inside > 0, "y luego va al círculo (%s)" % walker.position)
	assert_eq(walker.falls, 1, "saltando de la pasarela al patio")
	assert_eq(walker.elevation, 0.0)
	# Solo una vez por vida: en el círculo se queda.
	for _i: int in 300:
		walker.step(brain)
	assert_eq(brain.get_siege_task(), BotBrain.SiegeTask.HOLD)
	# Al reaparecer (un salto de posición) vuelve a tocarle.
	walker.position = Vector3(-2.5, FLOOR - 6.0, 132.0)
	walker.elevation = 0.0
	walker.step(brain)
	assert_false(brain.is_walkway_swept(), "tras reaparecer la recorrerá otra vez")


func test_an_attacker_without_the_role_and_outside_the_fort_never_climbs() -> void:
	_view.gate_health = 0
	# Sin papel (11) o con el de guardarla pero no el de recorrerla atacando (10).
	for rng_seed: int in [11, 10]:
		var brain: BotBrain = _brain(S, rng_seed)
		assert_false(brain.is_walkway_sweeper())
		var walker := HeightWalker.new(_routes, Vector3(-16.0, FLOOR, -1.0))
		var climbed: bool = false
		for _i: int in 900:
			walker.step(brain)
			climbed = climbed or brain.get_siege_task() == BotBrain.SiegeTask.WALKWAY
		assert_false(climbed, "semilla %d: atacando no sube" % rng_seed)
		assert_true(_view.is_in_circle(walker.position), "va al círculo")
	# Con el papel pero la puerta entera, golpea la puerta desde fuera: la pasarela es para cuando entra.
	_view.gate_health = 9000
	var outside: BotBrain = _brain(S, _walkway_seeds(1.0, 1, BotBrain.SIEGE_WALKWAY_SWEEP_SHARE)[0])
	var out_walker := HeightWalker.new(_routes, Vector3(-25.0, FLOOR, 1.0))
	for _i: int in 300:
		out_walker.step(outside)
	assert_eq(outside.get_siege_task(), BotBrain.SiegeTask.ASSAULT)


func test_a_walkway_guard_whose_realm_loses_the_fort_drops_into_the_circle_instead_of_hitting_the_air() -> void:
	# Revisión de F6b: al capturar, la puerta se repara, y los guardias de la pasarela del dueño anterior (vivos y fuera del
	# círculo) pasaban a ser atacantes dentro de un fuerte cerrado: «asaltaban» la puerta desde arriba, golpeando el aire.
	# Desde dentro no se asalta la puerta: baja al patio y va al círculo (en formación, con contador de aliados, y sin ella).
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
				"formación %s: en su puesto" % formation):
			continue
		# Solmarch captura: el fuerte es suyo y la puerta, reparada, cierra el paso a Vardheim.
		_view.owner = S
		var assaulted: Array[bool] = [false]
		var inside: int = _run(walker, brain, 900, func() -> bool:
			assaulted[0] = assaulted[0] or brain.get_siege_task() == BotBrain.SiegeTask.ASSAULT
			return brain.get_siege_task() == BotBrain.SiegeTask.HOLD and _view.is_in_circle(walker.position))
		assert_true(inside > 0, "formación %s: baja de la pasarela y va al círculo (%s)" % [formation, walker.position])
		assert_false(assaulted[0], "formación %s: sin asaltar la puerta desde dentro" % formation)
		assert_eq(walker.presses, 0, "formación %s: ni golpear el aire" % formation)
		assert_eq(walker.elevation, 0.0)


func test_inside_the_fort_an_enemy_on_the_walkway_is_not_a_target_from_the_ground() -> void:
	_view.gate_health = 0
	var brain: BotBrain = _brain(S, 11)
	var enemy: Array[Variant] = [Vector3(-18.77, _routes.walkway_height, 1.0)]
	brain.set_enemy_finder(func(_position: Vector3) -> Variant: return enemy[0])
	var walker := HeightWalker.new(_routes, CIRCLE + Vector3(-1.0, 0.0, 1.0))
	for _i: int in 300:
		walker.step(brain)
	assert_eq(brain.get_siege_task(), BotBrain.SiegeTask.HOLD, "a 10 m pero en la pasarela: sigue en el círculo")
	assert_eq(walker.presses, 0, "sin quedarse debajo golpeando al aire")
	# El mismo enemigo a ras de suelo, sí.
	enemy[0] = Vector3(-14.0, FLOOR, 1.0)
	for _i: int in 60:
		walker.step(brain)
	assert_eq(brain.get_siege_task(), BotBrain.SiegeTask.FIGHT, "en el patio sí es un blanco")
	# Fuera del recinto (las laderas) la altura no cuenta: uno 3 m más arriba en la ladera sí es un blanco.
	var climber: BotBrain = _brain(S, 11)
	climber.set_enemy_finder(func(_position: Vector3) -> Variant: return Vector3(-36.0, 7.0, 28.0))
	climber.next_input(1, Vector3(-40.0, 4.0, 30.0), 0.0)
	assert_eq(climber.get_siege_task(), BotBrain.SiegeTask.FIGHT, "en la ladera, fuera, sí")


func test_a_telegraphed_hit_from_another_level_is_not_evaded() -> void:
	var rng_seed: int = _walkway_seeds(-1.0, 1)[0]
	var brain: BotBrain = _brain(V, rng_seed)
	var threats: Array[BotBrain.Threat] = []
	brain.set_threat_finder(func(_position: Vector3) -> Array[BotBrain.Threat]: return threats)
	var walker := HeightWalker.new(_routes, CIRCLE)
	assert_true(_run(walker, brain, 1800, func() -> bool: return _at_post(walker, brain)) > 0, "en su puesto")
	# Un PNJ en el patio, justo debajo, avisa un golpe que le cubriría en horizontal.
	var below := Vector3(walker.position.x + 1.5, FLOOR, walker.position.z)
	threats.append(BotBrain.Threat.new(below, PI * 0.5, 3.5))
	assert_true(threats[0].covers(walker.position, BotBrain.SIEGE_THREAT_MARGIN), "en horizontal le cubre")
	walker.step(brain)
	assert_eq(brain.get_siege_task(), BotBrain.SiegeTask.WALKWAY, "pero desde el patio no llega: no sale")
	# El mismo golpe en la pasarela, sí.
	threats[0] = BotBrain.Threat.new(Vector3(below.x - 1.5, walker.position.y, below.z - 2.0), PI, 3.5)
	walker.step(brain)
	assert_eq(brain.get_siege_task(), BotBrain.SiegeTask.EVADE, "en la pasarela sí")


func test_pushed_off_the_ramp_it_goes_back_to_its_foot_and_climbs_again() -> void:
	var rng_seed: int = _walkway_seeds(-1.0, 1)[0]
	var brain: BotBrain = _brain(V, rng_seed)
	var walker := HeightWalker.new(_routes, CIRCLE)
	var on_ramp: int = _run(walker, brain, 1200, func() -> bool: return walker.elevation > 1.5)
	assert_true(on_ramp > 0, "subiendo por la rampa")
	# Un empujón de 2 m de lado (no es una reaparición): cae al patio, junto a la rampa.
	walker.position += Vector3(2.0, 0.0, 0.0)
	walker.elevation = 0.0
	walker.position.y = FLOOR
	var climbed: int = _run(walker, brain, 1800, func() -> bool: return _at_post(walker, brain))
	assert_true(climbed > 0, "vuelve al pie, sube otra vez y llega a su puesto (%s)" % walker.position)


func test_the_level_weight_puts_the_enemy_at_its_own_height_first() -> void:
	var me := Vector3(-14.0, FLOOR, 0.0)
	var up := Vector3(-18.77, FLOOR + 3.35, 0.0)
	var far := Vector3(-14.0 + 11.0, FLOOR, 0.0)
	assert_true(me.distance_squared_to(up) < me.distance_squared_to(far), "en línea recta, el de la pasarela está más cerca")
	assert_true(BotBrain.target_distance_squared(me, far) < BotBrain.target_distance_squared(me, up),
			"pero con la altura pesada va antes el de su nivel a 11 m")
	assert_near(BotBrain.target_distance_squared(me, Vector3(-11.0, FLOOR, 4.0)), 25.0, 0.0001, "sin altura, la de siempre")
	assert_true(sqrt(BotBrain.target_distance_squared(me, up)) > BotBrain.SIEGE_FIGHT_RANGE,
			"la pasarela queda más lejos que el alcance de pelea")


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
	assert_true(runs[0] == runs[1], "mismas entradas en las dos ejecuciones")
