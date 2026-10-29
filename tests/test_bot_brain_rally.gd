extends TestCase
## La reunión y la formación del patrón de asedio de [BotBrain] (GUE-44; docs/fuerte.md, secciones 7 y 8.3) sin física:
## puntos que se mueven donde dicen las entradas ([Walker]), el fuerte del Vado Gris ([SiegeView] con la puerta y el
## círculo) y sus rutas. Un atacante que empieza o reaparece en su campamento espera a los suyos en el punto de reunión y
## sale con ellos cuando son bastantes, cuando los suyos ya pelean en el fuerte o en la siguiente salida del reloj común,
## todos por la misma ruta; el dueño no espera; y, en grupo, cada uno lleva su hueco para no apilarse.

const V: int = NetProtocol.Realm.VARDHEIM
const S: int = NetProtocol.Realm.SOLMARCH
const ROUTES_PATH: String = "res://data/routes/vado_gris.tres"
const GATE: Vector3 = Vector3(-20.0, 0.0, 0.0)
const CIRCLE: Vector3 = Vector3(-8.5, 0.0, 0.0)
const CIRCLE_RADIUS: float = 5.0
const WALK_SPEED: float = 5.0
const SPRINT_SPEED: float = 7.5
const TICKS_PER_SECOND: float = 60.0
## Puntos de reaparición del campamento de Vardheim (z = -138) y la salida del campamento (el primer punto de sus rutas).
const CAMP_SPAWN: Vector3 = Vector3(-7.5, 0.0, -138.0)
const RALLY_V: Vector3 = Vector3(-2.5, 0.0, -132.0)
const RALLY_S: Vector3 = Vector3(-2.5, 0.0, 132.0)

var _routes: ApproachRoutes = null
var _view: SiegeView = null


## Un punto que obedece a las entradas (como el de test_bot_brain_siege), con su cerebro. Mientras no está
## [member present] (no ha aparecido aún) no piensa ni cuenta para los demás.
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


## Varios bots en el mismo mundo: el contador de aliados de cada uno cuenta a los demás de su reino que están presentes.
class Squad:
	extends RefCounted

	var walkers: Array[Walker] = []
	var realms: PackedInt32Array = PackedInt32Array()


	func add(walker: Walker, realm: int) -> Walker:
		var index: int = walkers.size()
		walkers.append(walker)
		realms.append(realm)
		# Un método enlazado y no una lambda: la lambda guardaría al Squad y el ciclo Squad -> cerebro -> lambda no se
		# liberaría al acabar.
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


	# Un tick para todos: piensan todos con las posiciones de antes (como los falsos del servidor, que cuentan con la
	# lista del tick) y luego se mueven.
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


## Un cerebro de asedio sin el papel de la pasarela (GUE-45): estos puntos no tienen altura y no pueden subir a ella;
## la pasarela se prueba en test_bot_brain_walkway.
func _brain(realm: int, rng_seed: int) -> BotBrain:
	var brain := BotBrain.new(rng_seed, BotBrain.Pattern.SIEGE)
	brain.set_siege(_view, _routes, realm)
	brain.set_walkway_role(false)
	return brain


func _alone(brain: BotBrain) -> void:
	brain.set_ally_counter(func(_center: Vector3, _radius: float) -> int: return 0)


func test_the_rally_point_is_the_way_out_of_the_camp() -> void:
	assert_vec_near(_brain(V, 1).get_siege_rally_point(), RALLY_V, 0.01, "Vardheim: el primer punto de sus rutas")
	assert_vec_near(_brain(S, 1).get_siege_rally_point(), RALLY_S, 0.01, "Solmarch: el suyo")
	var routes_point: Vector2 = _routes.get_points(ApproachRoutes.FORD, RealmCatalog.VARDHEIM)[0]
	assert_eq(Vector2(RALLY_V.x, RALLY_V.z), routes_point, "las dos rutas empiezan en el mismo sitio")
	var lost := BotBrain.new(1, BotBrain.Pattern.SIEGE)
	lost.set_siege(_view, null, V)
	assert_null(lost.get_siege_rally_point(), "sin rutas no hay punto de reunión")
	assert_true(CAMP_SPAWN.distance_to(RALLY_V) < BotBrain.SIEGE_RALLY_RADIUS,
			"los puntos de reaparición del campamento quedan dentro del radio de la reunión")


func test_the_departure_clock_is_shared_and_the_group_route_alternates() -> void:
	var period: int = BotBrain.SIEGE_RALLY_PERIOD_TICKS
	var offset: int = BotBrain.SIEGE_RALLY_OFFSET_TICKS
	assert_eq(BotBrain.next_rally_departure(0), offset, "la primera salida, 5 s después del principio")
	assert_eq(BotBrain.next_rally_departure(offset - 1), offset)
	assert_eq(BotBrain.next_rally_departure(offset), offset + period, "siempre después del tick dado")
	assert_eq(BotBrain.next_rally_departure(offset + 1), offset + period)
	assert_eq(BotBrain.next_rally_departure(4000, 600), 4500, "con otra vuelta del reloj")
	# Dos bots que empiezan a esperar en ticks distintos de la misma vuelta salen en el mismo.
	assert_eq(BotBrain.next_rally_departure(700), BotBrain.next_rally_departure(2000))
	# La ruta del grupo alterna de una vuelta a la siguiente y no cambia por unos ticks alrededor de una salida.
	assert_eq(BotBrain.rally_route_index(offset, 2), 0)
	assert_eq(BotBrain.rally_route_index(offset + period, 2), 1)
	assert_eq(BotBrain.rally_route_index(offset + 2 * period, 2), 0)
	assert_eq(BotBrain.rally_route_index(offset + period - 5, 2), BotBrain.rally_route_index(offset + period + 5, 2),
			"unos ticks antes o después de una salida, la misma ruta")
	assert_eq(BotBrain.rally_route_index(100, 0), -1, "sin rutas, ninguna")


func test_without_an_ally_counter_it_marches_at_once() -> void:
	var brain: BotBrain = _brain(V, 3)
	var walker := Walker.new(brain, CAMP_SPAWN)
	walker.step(1)
	assert_false(brain.is_rallying(), "sin contador de aliados no espera (como antes de GUE-44)")
	assert_eq(brain.get_siege_task(), BotBrain.SiegeTask.MARCH)
	assert_true(brain.get_siege_route() != &"", "y ha elegido su ruta")


func test_alone_at_the_camp_it_waits_for_the_clock_and_then_marches() -> void:
	var brain: BotBrain = _brain(V, 4)
	_alone(brain)
	var walker := Walker.new(brain, CAMP_SPAWN)
	var departure: int = BotBrain.next_rally_departure(1)
	for tick: int in range(1, departure):
		walker.step(tick)
		if not assert_eq(brain.get_siege_task(), BotBrain.SiegeTask.RALLY, "tick %d: espera" % tick):
			return
	assert_true(brain.is_rallying())
	assert_eq(brain.get_rally_deadline(), departure, "como mucho hasta la siguiente salida del reloj")
	assert_eq(brain.get_siege_route(), &"", "aún sin ruta")
	var spot: Vector3 = RALLY_V + Vector3(brain.get_siege_slot().x, 0.0, brain.get_siege_slot().y) \
			* BotBrain.SIEGE_SLOT_RALLY_SPREAD
	assert_true(walker.position.distance_to(spot) <= BotBrain.SIEGE_SLOT_REACHED + 0.2,
			"quieto en su sitio del punto de reunión (%.2f m)" % walker.position.distance_to(spot))
	assert_false(walker.last_input.has(PlayerInput.PRIMARY), "sin atacar a nadie")
	walker.step(departure)
	assert_false(brain.is_rallying(), "sale con el reloj")
	assert_eq(brain.get_last_rally_departure(), departure)
	assert_eq(brain.get_siege_task(), BotBrain.SiegeTask.MARCH)
	var candidates: Array[StringName] = _routes.get_route_ids()
	assert_eq(brain.get_siege_route(), candidates[BotBrain.rally_route_index(departure, candidates.size())],
			"por la ruta de esa vuelta del reloj")


func test_a_group_leaves_together_by_the_same_route_once_enough_have_gathered() -> void:
	var squad := Squad.new()
	var size: int = 4
	for index: int in size:
		var walker: Walker = squad.add(Walker.new(_brain(V, 100 + index), CAMP_SPAWN), V)
		walker.brain.set_rally(size)
		# Llegan de uno en uno (como si reaparecieran): uno cada 40 ticks.
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
					assert_true(false, "tick %d: el %d no debería haber salido aún" % [tick, index])
					return
	var departures: Dictionary = {}
	var routes: Dictionary = {}
	for walker: Walker in squad.walkers:
		assert_false(walker.brain.is_rallying(), "ya no espera")
		departures[walker.brain.get_last_rally_departure()] = true
		routes[walker.brain.get_siege_route()] = true
	assert_eq(departures.keys(), [arrival_of_last], "salen todos en el tick en que llega el cuarto, sin esperar al reloj")
	assert_true(arrival_of_last < BotBrain.next_rally_departure(1))
	assert_eq(routes.size(), 1, "y por la misma ruta: %s" % [routes.keys()])


func test_bots_that_arrive_at_different_times_leave_together_on_the_clock() -> void:
	var squad := Squad.new()
	var arrivals: Array[int] = [5, 120, 250]
	for index: int in arrivals.size():
		var walker: Walker = squad.add(Walker.new(_brain(S, 200 + index * 7), Vector3(-7.5, 0.0, 138.0)), S)
		walker.present = false
	var departure: int = BotBrain.next_rally_departure(arrivals[0])
	assert_eq(departure, BotBrain.next_rally_departure(arrivals[2]), "los tres caen en la misma vuelta del reloj")
	for tick: int in range(1, departure + 2):
		for index: int in arrivals.size():
			if tick == arrivals[index]:
				squad.walkers[index].present = true
		squad.step(tick)
	var routes: Dictionary = {}
	for walker: Walker in squad.walkers:
		assert_eq(walker.brain.get_last_rally_departure(), departure, "salen juntos con el reloj (grupo de 3 de 8)")
		routes[walker.brain.get_siege_route()] = true
	assert_eq(routes.size(), 1, "por la misma ruta")


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
	assert_eq(brain.get_siege_task(), BotBrain.SiegeTask.MARCH, "marcha")
	assert_true(walker.position.distance_to(RALLY_V) > 30.0, "lejos del campamento")
	# Muere y reaparece en el campamento (un salto de más de 5 m).
	walker.position = CAMP_SPAWN
	walker.step(tick)
	assert_true(brain.is_rallying(), "vuelve a esperar a los suyos")
	assert_eq(brain.get_siege_task(), BotBrain.SiegeTask.RALLY)
	assert_eq(brain.get_rally_deadline(), BotBrain.next_rally_departure(tick, 600))


func test_a_respawn_far_from_the_camp_or_the_owner_never_waits() -> void:
	# Un salto que no acaba en el campamento (lo colocan delante de la puerta) no es una reaparición en él.
	var brain: BotBrain = _brain(V, 6)
	_alone(brain)
	brain.set_rally(BotBrain.SIEGE_RALLY_GROUP_SIZE, 600)
	var walker := Walker.new(brain, CAMP_SPAWN)
	walker.step(1)
	assert_true(brain.is_rallying())
	walker.position = Vector3(-27.0, 0.0, 0.0)
	walker.step(2)
	assert_false(brain.is_rallying(), "delante de la puerta no espera a nadie")
	for tick: int in range(3, 120):
		walker.step(tick)
	assert_eq(brain.get_siege_task(), BotBrain.SiegeTask.ASSAULT, "golpea la puerta")
	# El dueño defiende en cuanto puede.
	_view.owner = V
	var owner: BotBrain = _brain(V, 7)
	_alone(owner)
	var owner_walker := Walker.new(owner, CAMP_SPAWN)
	owner_walker.step(1)
	assert_false(owner.is_rallying(), "el dueño no espera")
	assert_eq(owner.get_siege_task(), BotBrain.SiegeTask.MARCH)


func test_it_does_not_wait_if_its_people_are_already_fighting_at_the_fort() -> void:
	# Tres de los suyos en el patio: el asalto sigue y va a ayudarlos sin esperar al grupo ni al reloj.
	var at_fort: Array[int] = [BotBrain.SIEGE_RALLY_JOIN_COUNT - 1]
	var brain: BotBrain = _brain(V, 12)
	brain.set_ally_counter(func(center: Vector3, _radius: float) -> int:
		return at_fort[0] if center.distance_to(CIRCLE) < 0.01 else 0)
	var walker := Walker.new(brain, CAMP_SPAWN)
	for tick: int in range(1, 30):
		walker.step(tick)
	assert_true(brain.is_rallying(), "con %d en el fuerte, espera" % at_fort[0])
	at_fort[0] = BotBrain.SIEGE_RALLY_JOIN_COUNT
	walker.step(30)
	assert_false(brain.is_rallying(), "con %d, sale" % at_fort[0])
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
	assert_false(brain.is_rallying(), "ahora es el dueño: a defender")
	assert_eq(brain.get_siege_task(), BotBrain.SiegeTask.MARCH)


func test_a_group_of_one_or_less_never_waits() -> void:
	var brain: BotBrain = _brain(V, 9)
	_alone(brain)
	brain.set_rally(1)
	var walker := Walker.new(brain, CAMP_SPAWN)
	walker.step(1)
	assert_false(brain.is_rallying(), "con el grupo a 1 sale solo")
	var other: BotBrain = _brain(V, 10)
	_alone(other)
	var other_walker := Walker.new(other, CAMP_SPAWN)
	other_walker.step(1)
	assert_true(other.is_rallying())
	other.set_rally(0)
	assert_false(other.is_rallying(), "quitar la reunión mientras espera la acaba")
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
	assert_eq(brain.get_siege_task(), BotBrain.SiegeTask.FIGHT, "pelea con quien llega")
	assert_true(brain.is_rallying(), "sin dejar de ser de los que esperan")
	enemy[0] = null
	for tick: int in range(80, 100):
		walker.step(tick)
	assert_eq(brain.get_siege_task(), BotBrain.SiegeTask.RALLY, "y vuelve a esperar")


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
	assert_true(runs[0] == runs[1], "mismas entradas en las dos ejecuciones")


func test_slots_of_consecutive_seeds_are_spread_over_the_unit_disk() -> void:
	var slots: Array[Vector2] = []
	for rng_seed: int in range(2000, 2020):
		var slot: Vector2 = BotBrain.slot_for_seed(rng_seed)
		assert_true(slot.length() <= 1.0001, "dentro del disco unidad (%s)" % slot)
		slots.append(slot)
	assert_eq(BotBrain.slot_for_seed(2000), BotBrain.slot_for_seed(2000), "siempre el mismo para la misma semilla")
	assert_eq(_brain(V, 2005).get_siege_slot(), BotBrain.slot_for_seed(2005), "el del cerebro")
	var closest: float = INF
	for i: int in slots.size():
		for j: int in range(i + 1, slots.size()):
			closest = minf(closest, slots[i].distance_to(slots[j]))
	assert_true(closest > 0.1, "veinte semillas seguidas, veinte huecos distintos (el par más cercano a %.2f)" % closest)
	var left: int = 0
	for slot: Vector2 in slots:
		left += 1 if slot.x < 0.0 else 0
	assert_true(left >= 6 and left <= 14, "repartidos a los dos lados (%d de 20 a la izquierda)" % left)


func test_in_a_group_they_hit_the_gate_and_hold_the_circle_each_from_its_own_spot() -> void:
	# Sin hueco, los que llegan por el mismo sitio acaban uno encima de otro (los personajes no chocan entre sí).
	var squad := Squad.new()
	for index: int in 6:
		var walker: Walker = squad.add(Walker.new(_brain(V, 400 + index), Vector3(-26.0, 0.0, -1.0)), V)
		walker.brain.set_rally(2)
	for tick: int in range(1, 400):
		squad.step(tick)
	var across := Vector3(0.0, 0.0, 1.0)
	var laterals: Array[float] = []
	for walker: Walker in squad.walkers:
		assert_eq(walker.brain.get_siege_task(), BotBrain.SiegeTask.ASSAULT, "golpean la puerta")
		assert_true(walker.position.distance_to(GATE) <= BotBrain.SIEGE_GATE_ATTACK_DISTANCE + 2.0,
				"al alcance de la puerta (%.2f m)" % walker.position.distance_to(GATE))
		var lateral: float = (walker.position - GATE).dot(across)
		assert_true(absf(lateral) <= BotBrain.SIEGE_SLOT_GATE_SPREAD + 0.6, "dentro del ancho de la puerta (%.2f)" % lateral)
		assert_near(walker.yaw, fposmod(atan2(-1.0, 0.0), TAU), 0.05, "mirándola de frente")
		laterals.append(lateral)
	laterals.sort()
	assert_true(laterals[laterals.size() - 1] - laterals[0] > 1.5, "repartidos a lo largo de la puerta: %s" % [laterals])
	# Con la puerta rota, cada uno a su sitio del círculo.
	_view.gate_health = 0
	for tick: int in range(400, 1000):
		squad.step(tick)
	var spots: Array[Vector3] = []
	for walker: Walker in squad.walkers:
		assert_eq(walker.brain.get_siege_task(), BotBrain.SiegeTask.HOLD)
		assert_true(_view.is_in_circle(walker.position), "dentro del círculo (%s)" % walker.position)
		spots.append(walker.position)
	var closest: float = INF
	for i: int in spots.size():
		for j: int in range(i + 1, spots.size()):
			closest = minf(closest, spots[i].distance_to(spots[j]))
	assert_true(closest > 0.3, "sin apilarse (los dos más cercanos a %.2f m)" % closest)
