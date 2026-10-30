class_name FillerKeeper
extends RefCounted
## Los jugadores falsos de relleno de una zona con [code]--max-realm-diff[/code] (GUE-42; docs/fuerte.md,
## sección 7): los falsos de reino automático que rellenan el bando corto y se retiran cuando entran
## personas. Lleva la cuenta de cuáles son y aplica las reglas de [RealmBalance]; no sabe crear ni quitar
## jugadores, eso lo hacen [member creator] y [member remover] ([ServerMain] los conecta con [ZoneServer]).
## [br][br]
## [b]La regla exacta[/b] (con [param budget] = [code]--fake-players[/code]):
## [br]1. Al arrancar, [ServerMain] crea el cupo entero repartiendo cada falso en el reino con menos total
## (personas más relleno); a igualdad, el de código más bajo. Sin personas es el reparto por turnos de siempre.
## [br]2. Entra una persona en el reino [i]r[/i]: si el total de [i]r[/i] (con ella) pasa a ser mayor que el
## menor de los otros reinos de la zona y [i]r[/i] tiene falsos de relleno, se retira el más antiguo de [i]r[/i]:
## uno por cada persona que entra en el bando largo. Si [i]r[/i] era el corto (o iba empatado), la persona
## ocupa un hueco y no se retira a nadie.
## [br]3. Sale una persona de [i]r[/i]: si el total de [i]r[/i] queda por debajo del mayor de los otros y el
## relleno vivo no llega al cupo, entra un falso nuevo en [i]r[/i].
## [br]4. Llega el HELLO de una persona de [i]r[/i] con el servidor lleno solo por el relleno (GUE-43; lo decide
## [ZoneServer], que solo cuenta como plazas ocupadas las personas y los falsos que no son de relleno): un falso le
## [b]aparta[/b] su plaza ([method reserve_seat]), pero no se va todavía: se va cuando esa persona entra en el mundo
## ([method on_person_joined]), y entonces es el más antiguo del reino que da [method RealmBalance.realm_to_yield_seat]
## con lo que hay en ese momento. Cuenta como el que retira la regla 2 (uno por persona). Si se va sin haber entrado
## (corta la conexión o no termina de cargar), la plaza apartada se libera ([method release_seat]) y el relleno no se
## ha movido: ni altas ni bajas para nadie. Mientras alguien carga en una plaza apartada, el servidor tiene un jugador
## de más (ella y el falso que se la cede; [method reserved_count] dice cuántas hay), y solo el relleno que no ha apartado
## su plaza puede cedérsela a otro HELLO.
## [br]5. Nada más retira ni añade falsos. El relleno no cuenta para rechazar a nadie ([RealmBalance.exceeds]), ni
## para llenar el servidor.
## [br][br]
## [ZoneServer] llama a [method on_person_joined], [method on_person_left], [method reserve_seat] y
## [method release_seat] ([method ZoneServer.set_filler_keeper]) y le avisa de cada falso que se da de baja
## ([method forget]).
## [br][br]
## Solo servidor.

## [code](realm: int) -> int[/code]: crea un jugador falso en el reino y devuelve su id de red (o -1).
var creator: Callable = Callable()
## [code](net_id: int) -> void[/code]: da de baja al jugador falso.
var remover: Callable = Callable()

var _allowed: PackedInt32Array = PackedInt32Array()
var _budget: int = 0
# () -> PackedInt32Array: las personas que hay en cada reino ahora mismo.
var _persons_source: Callable = Callable()
# Relleno vivo, del más antiguo al más nuevo, y el reino de cada uno.
var _ids: Array[int] = []
var _realm_of: Dictionary[int, int] = {}
# Personas (peer_id) a las que el relleno ha apartado una plaza y que aún no están en el mundo, con su reino.
var _seated: Dictionary[int, int] = {}


## [param allowed] son los reinos de la zona (vacío = los tres), [param budget] el cupo de relleno y
## [param persons_source] un [Callable] sin argumentos con el recuento de personas por reino.
func _init(allowed: PackedInt32Array, budget: int, persons_source: Callable) -> void:
	_allowed = allowed
	_budget = maxi(budget, 0)
	_persons_source = persons_source


## El reino en el que tiene que entrar el siguiente falso de relleno (0 si no compite ninguno).
func next_realm() -> int:
	return RealmBalance.realm_for_new_filler(_persons(), filler_counts(), _allowed)


## Anota que el falso [param net_id] del reino [param realm] es de relleno.
func track(net_id: int, realm: int) -> void:
	if net_id <= 0 or _realm_of.has(net_id):
		return
	_ids.append(net_id)
	_realm_of[net_id] = realm


## Deja de contar a [param net_id] como relleno (se ha dado de baja por otra razón).
func forget(net_id: int) -> void:
	_ids.erase(net_id)
	_realm_of.erase(net_id)


## true si [param net_id] es de relleno.
func is_filler(net_id: int) -> bool:
	return _realm_of.has(net_id)


## Falsos de relleno vivos.
func filler_count() -> int:
	return _ids.size()


## Falsos de relleno de cada reino (Vardheim, Solmarch, Askarra).
func filler_counts() -> PackedInt32Array:
	var counts: PackedInt32Array = RealmBalance.empty_counts()
	for realm: int in _realm_of.values():
		if realm >= 1 and realm <= RealmBalance.REALM_COUNT:
			counts[realm - 1] += 1
	return counts


## Ha entrado una persona en [param realm] (el recuento de personas ya la incluye): retira un falso de relleno si toca.
## Devuelve true si lo ha retirado. Si el relleno le había apartado una plaza al llegar su HELLO ([method reserve_seat]
## con el mismo [param peer_id]), se retira ahora el falso que la cede: el más antiguo del reino que da
## [method RealmBalance.realm_to_yield_seat] (contándola a ella), aunque no sea de su reino. Si no, la regla 2.
func on_person_joined(realm: int, peer_id: int = 0) -> bool:
	if _seated.erase(peer_id):
		# Sin contarla a ella (realm_to_yield_seat la suma), y en una copia: la fuente puede dar su propio array.
		var persons: PackedInt32Array = _persons().duplicate()
		if realm >= 1 and realm <= persons.size():
			persons[realm - 1] = maxi(persons[realm - 1] - 1, 0)
		var from_realm: int = RealmBalance.realm_to_yield_seat(persons, filler_counts(), realm)
		return from_realm > 0 and _retire_oldest_of(from_realm)
	if not RealmBalance.should_retire_on_join(_persons(), filler_counts(), _allowed, realm):
		return false
	return _retire_oldest_of(realm)


## Llega el HELLO de la persona [param peer_id] de [param realm] con el servidor lleno: el relleno le aparta una plaza
## (GUE-43). No retira a nadie todavía: el falso que la cede se va cuando ella entra en el mundo
## ([method on_person_joined]); si se va antes, [method release_seat]. Devuelve false si no queda relleno sin apartar
## o si ya tenía una.
func reserve_seat(peer_id: int, realm: int) -> bool:
	if peer_id <= 0 or _seated.has(peer_id) or _seated.size() >= _ids.size():
		return false
	_seated[peer_id] = realm
	return true


## true si el relleno ha apartado una plaza a [param peer_id] y aún no ha entrado en el mundo.
func has_reserved_seat(peer_id: int) -> bool:
	return _seated.has(peer_id)


## La persona [param peer_id] se ha ido sin entrar en el mundo: libera la plaza que el relleno le había apartado
## ([method reserve_seat]). Ningún falso se había ido, así que no vuelve ninguno. Devuelve true si tenía una.
func release_seat(peer_id: int) -> bool:
	return _seated.erase(peer_id)


## Plazas que el relleno tiene apartadas para personas que aún cargan la zona ([method reserve_seat]).
func reserved_count() -> int:
	return _seated.size()


## Ha salido una persona de [param realm] (el recuento ya no la incluye): añade un falso de relleno en ese reino
## si toca. Devuelve true si lo ha creado.
func on_person_left(realm: int) -> bool:
	if not RealmBalance.should_add_on_leave(_persons(), filler_counts(), _allowed, realm,
			_ids.size(), _budget):
		return false
	if not creator.is_valid():
		return false
	var net_id: int = int(creator.call(realm))
	if net_id <= 0:
		return false
	track(net_id, realm)
	return true


# Retira el falso de relleno más antiguo de [param realm]. false si ese reino no tiene.
func _retire_oldest_of(realm: int) -> bool:
	for net_id: int in _ids:
		if _realm_of[net_id] == realm:
			forget(net_id)
			if remover.is_valid():
				remover.call(net_id)
			return true
	return false


func _persons() -> PackedInt32Array:
	if _persons_source.is_valid():
		return _persons_source.call()
	return RealmBalance.empty_counts()
