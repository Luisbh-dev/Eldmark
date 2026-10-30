extends TestCase
## Equilibrio de reinos (GUE-42 y GUE-43; docs/fuerte.md, sección 7): las reglas puras de [RealmBalance] (el
## rechazo por diferencia de personas, cuándo se retira o se añade un falso de relleno y cuál cede su plaza con el
## servidor lleno) y [FillerKeeper], que las aplica a los jugadores falsos de reino automático. Con red real lo
## prueban [code]test_zone_server_net[/code] (REJECT 9, recuento del WELCOME y la plaza que cede el relleno) y
## [code]test_server_main[/code] (los falsos que se retiran, con el servidor lleno de relleno).

const V: int = NetProtocol.Realm.VARDHEIM
const S: int = NetProtocol.Realm.SOLMARCH
const A: int = NetProtocol.Realm.ASKARRA
## La zona del Vado Gris solo admite a Vardheim y Solmarch.
const BORDER: PackedInt32Array = [NetProtocol.Realm.VARDHEIM, NetProtocol.Realm.SOLMARCH]


func _counts(vardheim: int, solmarch: int, askarra: int = 0) -> PackedInt32Array:
	return PackedInt32Array([vardheim, solmarch, askarra])


# --- Reinos que compiten y rechazo ---------------------------------------------------------------

func test_the_realms_that_compete_are_the_ones_the_zone_admits() -> void:
	assert_eq(RealmBalance.competing_realms(BORDER), BORDER, "el Vado Gris: Vardheim y Solmarch")
	assert_eq(RealmBalance.competing_realms(PackedInt32Array()), PackedInt32Array([V, S, A]),
			"una zona sin restricción: los tres")


func test_without_a_limit_nobody_is_rejected() -> void:
	assert_false(RealmBalance.exceeds(_counts(40, 0), BORDER, V, 0), "0 = sin límite")
	assert_false(RealmBalance.exceeds(_counts(40, 0), BORDER, V, -3), "y un negativo tampoco limita")


func test_entering_the_short_side_is_never_rejected() -> void:
	for limit: int in [1, 2, 5]:
		assert_false(RealmBalance.exceeds(_counts(0, 0), BORDER, V, limit), "el primero de la zona entra (N=%d)" % limit)
		assert_false(RealmBalance.exceeds(_counts(7, 3), BORDER, S, limit), "el reino corto siempre entra (N=%d)" % limit)
		assert_false(RealmBalance.exceeds(_counts(3, 3), BORDER, S, limit), "con empate, entra (N=%d)" % limit)


func test_entering_the_long_side_is_rejected_when_it_leaves_more_than_n_ahead() -> void:
	# N = 1: 1 contra 0 vale; 2 contra 0 no.
	assert_false(RealmBalance.exceeds(_counts(0, 0), BORDER, V, 1), "1 contra 0 vale")
	assert_true(RealmBalance.exceeds(_counts(1, 0), BORDER, V, 1), "2 contra 0 deja 2 de ventaja")
	assert_false(RealmBalance.exceeds(_counts(1, 1), BORDER, V, 1), "2 contra 1 vale")
	# N = 3: con 3 de ventaja vale y con 4 no.
	assert_false(RealmBalance.exceeds(_counts(2, 0), BORDER, V, 3), "3 contra 0 vale")
	assert_true(RealmBalance.exceeds(_counts(3, 0), BORDER, V, 3), "4 contra 0 no vale")
	assert_false(RealmBalance.exceeds(_counts(7, 4), BORDER, V, 4), "8 contra 4 vale")
	assert_true(RealmBalance.exceeds(_counts(8, 4), BORDER, V, 4), "9 contra 4 no vale")
	# Es simétrico para el otro reino.
	assert_true(RealmBalance.exceeds(_counts(0, 3), BORDER, S, 3), "Solmarch también se rechaza")


func test_the_comparison_is_with_the_realm_with_fewest_people_among_those_the_zone_admits() -> void:
	# En una zona de tres reinos, Askarra vacío cuenta como el reino con menos.
	assert_true(RealmBalance.exceeds(_counts(1, 1, 0), PackedInt32Array(), V, 1),
			"2 contra 1 y 0: la diferencia con Askarra es 2")
	assert_false(RealmBalance.exceeds(_counts(1, 1, 1), PackedInt32Array(), V, 1), "2 contra 1 y 1: vale")
	# En el Vado Gris Askarra no existe: sus 0 no cuentan.
	assert_false(RealmBalance.exceeds(_counts(1, 1, 0), BORDER, V, 1), "Askarra no está admitido")


func test_a_zone_with_a_single_realm_has_nobody_to_compare_with() -> void:
	assert_false(RealmBalance.exceeds(_counts(9, 0), PackedInt32Array([V]), V, 1))
	assert_false(RealmBalance.exceeds(_counts(0, 0), BORDER, 0, 1), "un reino que no existe no se rechaza aquí")
	assert_false(RealmBalance.exceeds(_counts(0, 0), BORDER, A, 1), "ni uno que la zona no admite")


# --- Relleno ---------------------------------------------------------------------------------------

func test_totals_add_people_and_fillers() -> void:
	assert_eq(RealmBalance.totals(_counts(2, 1, 0), _counts(3, 4, 0)), _counts(5, 5, 0))
	assert_eq(RealmBalance.totals(PackedInt32Array([1]), PackedInt32Array()), _counts(1, 0, 0), "los recuentos cortos se rellenan")


func test_a_new_filler_goes_to_the_realm_with_the_lowest_total() -> void:
	assert_eq(RealmBalance.realm_for_new_filler(_counts(0, 0), _counts(0, 0), BORDER), V, "a igualdad, el de código más bajo")
	assert_eq(RealmBalance.realm_for_new_filler(_counts(0, 0), _counts(1, 0), BORDER), S)
	assert_eq(RealmBalance.realm_for_new_filler(_counts(0, 3), _counts(2, 0), BORDER), V,
			"las personas cuentan: 2 contra 3")
	assert_eq(RealmBalance.realm_for_new_filler(_counts(5, 0), _counts(0, 0), BORDER), S)
	assert_eq(RealmBalance.realm_for_new_filler(_counts(0, 0), _counts(1, 1), PackedInt32Array()), A,
			"con tres reinos también se rellena Askarra")


func test_a_person_entering_the_long_side_retires_one_filler_of_it() -> void:
	# 4 falsos por bando; entra una persona en Vardheim: 5 contra 4, se va uno de Vardheim.
	assert_true(RealmBalance.should_retire_on_join(_counts(1, 0), _counts(4, 4), BORDER, V))
	# Con 3 contra 4 falsos, una persona en Solmarch deja 4 contra 5: sobra un falso de Solmarch.
	assert_true(RealmBalance.should_retire_on_join(_counts(1, 1), _counts(3, 4), BORDER, S))
	# Una persona que entra en el bando corto ocupa un hueco: no se retira a nadie.
	assert_false(RealmBalance.should_retire_on_join(_counts(1, 0), _counts(2, 5), BORDER, V),
			"3 contra 5: Vardheim es el corto")
	assert_false(RealmBalance.should_retire_on_join(_counts(1, 0), _counts(4, 5), BORDER, V),
			"5 contra 5: empate, la persona no sobra")
	# Sin falsos en su reino no hay a quién retirar.
	assert_false(RealmBalance.should_retire_on_join(_counts(6, 0), _counts(0, 4), BORDER, V))
	assert_false(RealmBalance.should_retire_on_join(_counts(1, 0), _counts(4, 4), BORDER, A),
			"un reino que la zona no admite")


func test_a_person_leaving_asks_for_a_filler_if_the_budget_allows() -> void:
	# Vardheim 3 contra Solmarch 4 tras salir una persona, y quedan 5 de 6 falsos permitidos.
	assert_true(RealmBalance.should_add_on_leave(_counts(1, 0), _counts(2, 4), BORDER, V, 6, 7))
	assert_false(RealmBalance.should_add_on_leave(_counts(1, 0), _counts(2, 4), BORDER, V, 7, 7),
			"el cupo de relleno está agotado")
	assert_false(RealmBalance.should_add_on_leave(_counts(1, 4), _counts(2, 0), BORDER, S, 2, 7),
			"Solmarch 4 contra Vardheim 3: no es el corto")
	assert_false(RealmBalance.should_add_on_leave(_counts(0, 0), _counts(3, 3), BORDER, V, 6, 7),
			"3 contra 3: nada que rellenar")


# --- FillerKeeper ------------------------------------------------------------------------------------

## Un guardián con jugadores falsos de mentira: [member created] guarda (reino) de los que crea y
## [member removed] los que retira; las personas las pone la prueba.
class Rig:
	extends RefCounted

	var persons: PackedInt32Array = PackedInt32Array([0, 0, 0])
	var created: Array[int] = []
	var removed: Array[int] = []
	var next_id: int = 100
	var keeper: FillerKeeper = null


	# Con métodos y no lambdas: una lambda guarda una referencia fuerte al Rig y el ciclo Rig → guardián → lambda
	# no se liberaba nunca (avisos de objetos perdidos al salir).
	func _init(budget: int, allowed: PackedInt32Array) -> void:
		keeper = FillerKeeper.new(allowed, budget, _get_persons)
		keeper.creator = _create
		keeper.remover = _remove


	func _get_persons() -> PackedInt32Array:
		return persons


	func _create(realm: int) -> int:
		next_id += 1
		created.append(realm)
		return next_id


	func _remove(net_id: int) -> void:
		removed.append(net_id)


	## Crea el cupo entero como hace ServerMain al arrancar.
	func fill(count: int) -> void:
		for _i: int in count:
			var realm: int = keeper.next_realm()
			next_id += 1
			keeper.track(next_id, realm)


	func person_joins(realm: int, peer_id: int = 0) -> bool:
		persons[realm - 1] += 1
		return keeper.on_person_joined(realm, peer_id)


	## Llega el HELLO de [param peer_id] con el servidor lleno: el relleno le aparta una plaza (GUE-43). La persona
	## aún no cuenta: entra en el mundo con [method person_joins], y entonces se va el falso que la cede.
	func hello_when_full(peer_id: int, realm: int) -> bool:
		return keeper.reserve_seat(peer_id, realm)


	## [param peer_id] se va sin haber entrado en el mundo (corta o no termina de cargar).
	func leaves_while_loading(peer_id: int) -> bool:
		return keeper.release_seat(peer_id)


	func person_leaves(realm: int) -> bool:
		persons[realm - 1] -= 1
		return keeper.on_person_left(realm)


func test_the_initial_fillers_alternate_between_the_realms() -> void:
	var rig := Rig.new(8, BORDER)
	rig.fill(8)
	assert_eq(rig.keeper.filler_counts(), _counts(4, 4, 0), "4 contra 4")
	assert_eq(rig.keeper.filler_count(), 8)
	var three := Rig.new(6, PackedInt32Array())
	three.fill(6)
	assert_eq(three.keeper.filler_counts(), _counts(2, 2, 2), "en una zona de tres reinos, 2 por reino")


func test_people_replace_fillers_one_for_one_while_the_sides_stay_even() -> void:
	var rig := Rig.new(8, BORDER)
	rig.fill(8)
	assert_true(rig.person_joins(V), "entra una persona en Vardheim: se va un falso suyo")
	assert_eq(rig.keeper.filler_counts(), _counts(3, 4, 0))
	assert_true(rig.person_joins(S), "entra otra en Solmarch: 4 contra 5, se va uno de Solmarch")
	assert_eq(rig.keeper.filler_counts(), _counts(3, 3, 0))
	assert_eq(RealmBalance.totals(rig.persons, rig.keeper.filler_counts()), _counts(4, 4, 0), "los totales siguen igualados")
	assert_eq(rig.removed.size(), 2, "se retiraron dos falsos")
	# Los retira por antigüedad dentro de su reino: el primer falso de Vardheim es el 101 y el de Solmarch, el 102.
	assert_eq(rig.removed, [101, 102] as Array[int], "el más antiguo de cada reino")


func test_the_filler_that_leaves_is_the_oldest_calm_one_of_its_realm() -> void:
	# Revisión de la integración de las habilidades: el más antiguo podía estar derribado, y su baja era una muerte con KILL
	# para quien lo derribó; o levantando o rematando a alguien. Se va el más antiguo tranquilo (calm_check) y, si ninguno
	# lo está, el más antiguo (su baja ya no es una muerte: ZoneServer.retire_filler).
	var rig := Rig.new(8, BORDER)
	rig.fill(8)
	var busy: Dictionary[int, bool] = {101: true, 103: true}
	rig.keeper.calm_check = func(net_id: int) -> bool: return not busy.has(net_id)
	assert_true(rig.person_joins(V), "entra una persona en Vardheim")
	assert_eq(rig.removed, [105] as Array[int], "el 101 y el 103 no están tranquilos: se va el 105")
	assert_true(rig.keeper.is_filler(101) and rig.keeper.is_filler(103), "y ellos siguen")
	# La lambda guarda el mismo diccionario: se cambia por dentro.
	busy.clear()
	for net_id: int in [102, 104, 106, 108]:
		busy[net_id] = true
	assert_true(rig.person_joins(S), "otra en Solmarch")
	assert_eq(rig.removed, [105, 102] as Array[int], "ninguno de Solmarch está tranquilo: el más antiguo")
	rig.keeper.calm_check = Callable()
	assert_true(rig.person_joins(V), "sin calm_check, todos lo están")
	assert_eq(rig.removed, [105, 102, 101] as Array[int])


func test_a_person_entering_the_short_side_does_not_retire_anyone() -> void:
	var rig := Rig.new(8, BORDER)
	# Dos falsos de Vardheim y seis de Solmarch: Vardheim es el bando corto.
	rig.keeper.track(1, V)
	rig.keeper.track(2, V)
	for id: int in range(3, 9):
		rig.keeper.track(id, S)
	assert_false(rig.person_joins(V), "la persona ocupa un hueco de Vardheim (3 contra 6)")
	assert_eq(rig.keeper.filler_counts(), _counts(2, 6, 0), "nadie se retira")
	assert_true(rig.removed.is_empty())


func test_when_the_fillers_of_a_realm_run_out_people_keep_coming_without_retiring_the_other_side() -> void:
	var rig := Rig.new(4, BORDER)
	rig.fill(4)
	assert_true(rig.person_joins(V))
	assert_true(rig.person_joins(V))
	assert_eq(rig.keeper.filler_counts(), _counts(0, 2, 0))
	assert_false(rig.person_joins(V), "ya no quedan falsos de Vardheim: nadie se retira")
	assert_eq(rig.keeper.filler_counts(), _counts(0, 2, 0), "los de Solmarch se quedan: son el relleno de su bando corto")
	assert_eq(rig.persons, _counts(3, 0, 0))


func test_a_person_leaving_brings_a_filler_back_up_to_the_budget() -> void:
	var rig := Rig.new(8, BORDER)
	rig.fill(8)
	rig.person_joins(V)
	rig.person_joins(V)
	assert_eq(rig.keeper.filler_counts(), _counts(2, 4, 0))
	assert_true(rig.person_leaves(V), "sale una: Vardheim 3 contra 4, entra un falso")
	assert_eq(rig.created, [V] as Array[int], "en el reino que se ha quedado corto")
	assert_eq(rig.keeper.filler_counts(), _counts(3, 4, 0))
	assert_true(rig.person_leaves(V))
	assert_eq(rig.keeper.filler_counts(), _counts(4, 4, 0))
	assert_eq(rig.keeper.filler_count(), 8, "sin personas vuelve el cupo entero")
	assert_eq(rig.persons, _counts(0, 0, 0))


func test_a_filler_is_only_added_to_the_realm_that_has_fallen_behind() -> void:
	var rig := Rig.new(4, BORDER)
	rig.fill(4)
	rig.person_joins(V)
	rig.person_joins(S)
	assert_eq(rig.keeper.filler_counts(), _counts(1, 1, 0), "cada persona ha sustituido a un falso")
	# Sale la de Vardheim: Vardheim 1 contra Solmarch 2, entra un falso en Vardheim.
	assert_true(rig.person_leaves(V))
	assert_eq(rig.keeper.filler_counts(), _counts(2, 1, 0))
	# Sale la de Solmarch: Vardheim 2 contra Solmarch 1, entra un falso en Solmarch.
	assert_true(rig.person_leaves(S))
	assert_eq(rig.keeper.filler_counts(), _counts(2, 2, 0))
	assert_eq(rig.created, [V, S] as Array[int], "cada reponedor, en su reino")


func test_a_leaving_person_of_the_long_side_needs_no_filler() -> void:
	var rig := Rig.new(4, BORDER)
	rig.keeper.track(1, V)
	rig.keeper.track(2, V)
	# Vardheim: 3 personas y 2 falsos (5); Solmarch: 1 persona y 1 falso (2). Sale una de Vardheim: 4 contra 2.
	rig.keeper.track(3, S)
	rig.persons = _counts(4, 1, 0)
	assert_false(rig.person_leaves(V), "Vardheim sigue siendo el bando largo")
	assert_true(rig.created.is_empty())


func test_the_keeper_tracks_and_forgets_fillers() -> void:
	var rig := Rig.new(4, BORDER)
	rig.keeper.track(7, V)
	rig.keeper.track(7, S)
	rig.keeper.track(0, V)
	assert_eq(rig.keeper.filler_count(), 1, "un id repetido o 0 no se anotan")
	assert_true(rig.keeper.is_filler(7))
	assert_eq(rig.keeper.filler_counts(), _counts(1, 0, 0), "el reino es el del primer alta")
	rig.keeper.forget(7)
	assert_false(rig.keeper.is_filler(7))
	assert_eq(rig.keeper.filler_count(), 0)


# --- Plazas que cede el relleno (GUE-43) ---------------------------------------------------------------------

func test_with_the_server_full_the_filler_that_yields_is_one_of_the_joiners_realm_when_the_sides_are_even() -> void:
	assert_eq(RealmBalance.realm_to_yield_seat(_counts(0, 0), _counts(4, 4), V), V, "4 contra 4: cede uno de Vardheim")
	assert_eq(RealmBalance.realm_to_yield_seat(_counts(0, 0), _counts(4, 4), S), S, "y para Solmarch, uno de Solmarch")
	assert_eq(RealmBalance.realm_to_yield_seat(_counts(2, 1), _counts(1, 2), S), S,
			"3 contra 3 con personas: el de su reino")
	assert_eq(RealmBalance.realm_to_yield_seat(_counts(0, 0), _counts(2, 2, 2), A), A, "con tres reinos, también")


func test_with_the_server_full_a_realm_without_fillers_takes_the_seat_of_the_side_with_the_highest_total() -> void:
	# Vardheim ya son todo personas: el falso que cede es de Solmarch (el único que tiene relleno).
	assert_eq(RealmBalance.realm_to_yield_seat(_counts(2, 0), _counts(0, 2), V), S)
	# Con tres reinos, de los que tienen relleno, el de más total; a igualdad, el de código más alto.
	assert_eq(RealmBalance.realm_to_yield_seat(_counts(2, 0, 0), _counts(0, 1, 2), V), A, "Askarra 2 contra Solmarch 1")
	assert_eq(RealmBalance.realm_to_yield_seat(_counts(2, 0, 0), _counts(0, 2, 1), V), S, "Solmarch 2 contra Askarra 1")
	assert_eq(RealmBalance.realm_to_yield_seat(_counts(2, 0, 0), _counts(0, 2, 2), V), A, "empate: el de código más alto")


func test_with_the_server_full_the_seat_comes_from_the_side_that_would_otherwise_lead() -> void:
	# Vardheim 1 contra Solmarch 3 (todo relleno): entra una persona de Vardheim (2 contra 3). Si cediera uno de
	# Vardheim quedaría 1 contra 3; cede uno de Solmarch y quedan 2 contra 2.
	assert_eq(RealmBalance.realm_to_yield_seat(_counts(0, 0), _counts(1, 3), V), S)
	# Con su reino empatado con el más alto (con ella contada), cede el suyo.
	assert_eq(RealmBalance.realm_to_yield_seat(_counts(0, 0), _counts(2, 3), V), V, "3 contra 3: el suyo")
	assert_eq(RealmBalance.realm_to_yield_seat(_counts(0, 0), _counts(0, 0), V), 0, "sin relleno no cede nadie")


func test_a_person_arriving_at_a_full_server_takes_the_seat_of_the_oldest_filler_of_their_realm() -> void:
	var rig := Rig.new(4, BORDER)
	rig.fill(4)
	assert_true(rig.hello_when_full(11, V), "con el servidor lleno de relleno, un falso le aparta su plaza")
	assert_true(rig.removed.is_empty(), "pero no se va hasta que ella entra en el mundo")
	assert_true(rig.keeper.has_reserved_seat(11), "la plaza queda a nombre de esa persona")
	assert_eq(rig.keeper.reserved_count(), 1)
	assert_true(rig.person_joins(V, 11), "al entrar en el mundo se va el falso que se la cede")
	assert_eq(rig.removed, [101] as Array[int], "el más antiguo de Vardheim")
	assert_false(rig.keeper.has_reserved_seat(11), "y la plaza deja de estar pendiente")
	assert_eq(RealmBalance.totals(rig.persons, rig.keeper.filler_counts()), _counts(2, 2, 0), "2 contra 2")
	assert_eq(rig.removed.size(), 1, "uno solo por persona")


func test_after_a_yielded_seat_the_usual_rules_keep_working() -> void:
	var rig := Rig.new(4, BORDER)
	rig.fill(4)
	rig.hello_when_full(11, V)
	rig.person_joins(V, 11)
	# Otra persona de Vardheim sin el servidor lleno (alguien subió el cupo): la regla de siempre.
	assert_true(rig.person_joins(V), "Vardheim 3 contra 2: se retira su último falso")
	assert_eq(rig.keeper.filler_counts(), _counts(0, 2, 0))
	# Se va la que entró en la plaza cedida: Vardheim 1 contra 2, vuelve un falso a Vardheim.
	assert_true(rig.person_leaves(V))
	assert_eq(rig.created, [V] as Array[int])
	assert_eq(rig.keeper.filler_counts(), _counts(1, 2, 0))


func test_two_people_of_the_same_realm_arriving_together_at_a_full_server_both_get_a_seat() -> void:
	var rig := Rig.new(4, BORDER)
	rig.fill(4)
	# Los dos HELLO llegan antes de que ninguno entre en el mundo.
	assert_true(rig.hello_when_full(11, V))
	assert_true(rig.hello_when_full(12, V))
	assert_eq(rig.keeper.reserved_count(), 2, "dos plazas apartadas")
	assert_true(rig.removed.is_empty())
	assert_true(rig.person_joins(V, 11))
	assert_true(rig.person_joins(V, 12), "Vardheim 2 (1 falso y la segunda persona) contra 2: el suyo")
	assert_eq(rig.removed, [101, 103] as Array[int], "los dos falsos de Vardheim")
	assert_eq(rig.keeper.filler_counts(), _counts(0, 2, 0))
	assert_eq(RealmBalance.totals(rig.persons, rig.keeper.filler_counts()), _counts(2, 2, 0))
	# La tercera ya no encuentra relleno de Vardheim: cede uno de Solmarch (lo que diga el cupo lo decide el servidor).
	assert_true(rig.hello_when_full(13, V))
	assert_true(rig.person_joins(V, 13))
	assert_eq(rig.removed.back(), 102, "el más antiguo de Solmarch")


func test_the_fillers_only_reserve_as_many_seats_as_there_are_fillers() -> void:
	var rig := Rig.new(2, BORDER)
	rig.fill(2)
	assert_true(rig.hello_when_full(11, V))
	assert_true(rig.hello_when_full(12, S))
	assert_false(rig.hello_when_full(13, V), "los dos falsos ya han apartado su plaza")
	assert_false(rig.hello_when_full(11, V), "ni se apartan dos a la misma persona")
	assert_eq(rig.keeper.reserved_count(), 2)
	assert_true(rig.leaves_while_loading(12))
	assert_true(rig.hello_when_full(13, V), "la que se va sin entrar deja libre la suya")


func test_a_person_who_leaves_before_entering_the_world_frees_the_seat_without_moving_any_filler() -> void:
	var rig := Rig.new(4, BORDER)
	rig.fill(4)
	rig.hello_when_full(11, V)
	assert_eq(rig.keeper.filler_count(), 4, "el falso sigue en el mundo mientras ella carga")
	assert_true(rig.leaves_while_loading(11), "se va sin entrar: la plaza se libera")
	assert_true(rig.removed.is_empty(), "no se ha retirado a nadie")
	assert_true(rig.created.is_empty(), "ni hay que reponer a nadie")
	assert_eq(rig.keeper.filler_counts(), _counts(2, 2, 0), "el cupo entero, los mismos falsos")
	assert_false(rig.keeper.has_reserved_seat(11))
	assert_false(rig.leaves_while_loading(11), "solo una vez")
	assert_false(rig.leaves_while_loading(77), "quien no tenía plaza apartada no libera nada")


func test_a_hello_and_a_disconnect_in_a_loop_never_touch_the_fillers() -> void:
	# Revisión de F6b (GUE-43): con la retirada al llegar el HELLO, cada HELLO seguido de una desconexión antes de entrar
	# retiraba al falso más antiguo (DESPAWN a todos; en algunos estados, uno del bando contrario) y creaba otro nuevo en su
	# campamento (SPAWN a todos), sin límite. Ahora la plaza solo se aparta: el relleno no se mueve.
	# Vardheim 2 personas contra Solmarch 1 persona y 1 falso: una tercera de Vardheim llega con el servidor lleno.
	var rig := Rig.new(2, BORDER)
	rig.persons = _counts(2, 1, 0)
	rig.keeper.track(50, S)
	for peer_id: int in range(11, 16):
		assert_true(rig.hello_when_full(peer_id, V), "HELLO %d: plaza apartada" % peer_id)
		assert_true(rig.leaves_while_loading(peer_id), "y se va sin entrar")
	assert_true(rig.removed.is_empty(), "no se retira ningún falso (%s)" % [rig.removed])
	assert_true(rig.created.is_empty(), "ni se crea ninguno (%s)" % [rig.created])
	assert_true(rig.keeper.is_filler(50), "el de Solmarch sigue donde estaba")


func test_a_seat_abandoned_while_another_person_loads_leaves_the_sides_even() -> void:
	# Revisión de F6b (GUE-43): con la retirada al llegar el HELLO, Ana (Vardheim) y Sam (Solmarch) cogían la plaza de un
	# falso de su reino; Sam se iba cargando y su falso volvía al reino con menos total sin contar a Ana, que aún cargaba
	# (Vardheim, por empate): al entrar Ana quedaban 3 contra 1. Ahora el falso se retira cuando ella entra: 2 contra 2.
	var rig := Rig.new(4, BORDER)
	rig.fill(4)
	assert_true(rig.hello_when_full(11, V), "Ana")
	assert_true(rig.hello_when_full(12, S), "Sam")
	assert_true(rig.leaves_while_loading(12), "Sam se va cargando")
	assert_true(rig.person_joins(V, 11), "Ana entra: se va un falso")
	assert_eq(RealmBalance.totals(rig.persons, rig.keeper.filler_counts()), _counts(2, 2, 0), "2 contra 2")
	assert_eq(rig.keeper.filler_counts(), _counts(1, 2, 0))
	assert_true(rig.created.is_empty())


func test_without_fillers_nothing_yields_a_seat() -> void:
	var rig := Rig.new(2, BORDER)
	assert_false(rig.hello_when_full(11, V), "no hay relleno")
	assert_false(rig.keeper.has_reserved_seat(11))
	assert_true(rig.removed.is_empty())
