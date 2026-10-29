extends TestCase
## Equilibrio de reinos (GUE-42; docs/fuerte.md, sección 7): las reglas puras de [RealmBalance] (el rechazo por
## diferencia de personas y cuándo se retira o se añade un falso de relleno) y [FillerKeeper], que las aplica a
## los jugadores falsos de reino automático. Con red real lo prueban [code]test_zone_server_net[/code]
## (REJECT 9 y recuento del WELCOME) y [code]test_server_main[/code] (los falsos que se retiran).

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


	func _init(budget: int, allowed: PackedInt32Array) -> void:
		keeper = FillerKeeper.new(allowed, budget, func() -> PackedInt32Array: return persons)
		keeper.creator = func(realm: int) -> int:
			next_id += 1
			created.append(realm)
			return next_id
		keeper.remover = func(net_id: int) -> void: removed.append(net_id)


	## Crea el cupo entero como hace ServerMain al arrancar.
	func fill(count: int) -> void:
		for _i: int in count:
			var realm: int = keeper.next_realm()
			next_id += 1
			keeper.track(next_id, realm)


	func person_joins(realm: int) -> bool:
		persons[realm - 1] += 1
		return keeper.on_person_joined(realm)


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
