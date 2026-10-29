class_name RealmBalance
extends RefCounted
## Equilibrio de reinos de una zona (GUE-42; docs/fuerte.md, sección 7): reglas puras sobre recuentos por
## reino, sin nodos ni red. Las usan [ServerAuth] (el REJECT 9 IMBALANCE), [ZoneServer] (el recuento del
## WELCOME) y [ServerMain] (los jugadores falsos de relleno).
## [br][br]
## [b]Recuentos.[/b] Un [PackedInt32Array] de tres posiciones, en el orden del WELCOME: Vardheim, Solmarch y
## Askarra (el índice es el código de reino menos uno). [b]Personas[/b] son los clientes aceptados (cargando la
## zona o ya dentro): los jugadores falsos y los cuerpos que quedan tras una baja en combate no cuentan. Los
## [b]relleno[/b] son los jugadores falsos de reino automático que el servidor ha puesto para igualar los
## bandos ([method totals] suma personas y relleno).
## [br][br]
## [b]Reinos que compiten.[/b] Los que la zona admite ([method NetZones.allowed_realms]); si la zona no
## restringe ninguno, los tres.
## [br][br]
## [b]Rechazo.[/b] Con [code]--max-realm-diff=N[/code] (N > 0), entrar en el reino [i]r[/i] se rechaza si
## [code]personas[r] + 1 − min(personas[s])[/code] es mayor que N, con [i]s[/i] cada uno de los otros reinos
## que compiten ([method exceeds]). Con N = 0, o si la zona solo admite un reino, nunca se rechaza.
## [br][br]
## [b]Relleno[/b] (solo con N > 0; ver [ServerMain]). El servidor crea los falsos de reino automático
## repartidos por turnos, en el reino con menos total ([method realm_for_new_filler]); después:
## [br]- Entra una persona en el reino [i]r[/i]: si el total de [i]r[/i] pasa a ser mayor que el menor de los
## otros y [i]r[/i] tiene algún falso de relleno, se retira uno (el más antiguo) ([method should_retire_on_join]).
## Se retira como mucho uno por persona.
## [br]- Sale una persona de [i]r[/i]: si el total de [i]r[/i] queda por debajo del mayor de los otros y no se
## ha agotado el cupo de [code]--fake-players[/code], entra un falso de relleno en [i]r[/i]
## ([method should_add_on_leave]).
## [br]Un falso nunca se retira por otra razón, y el relleno no cuenta para el rechazo: una persona no se
## queda fuera porque el bando contrario esté lleno de falsos.
## [br][br]
## Solo servidor.

## Número de posiciones de un recuento (Vardheim, Solmarch, Askarra).
const REALM_COUNT: int = 3


## Un recuento a cero.
static func empty_counts() -> PackedInt32Array:
	var counts := PackedInt32Array()
	counts.resize(REALM_COUNT)
	return counts


## Códigos de los reinos que compiten en una zona que admite [param allowed] (vacío = los tres).
static func competing_realms(allowed: PackedInt32Array) -> PackedInt32Array:
	var realms := PackedInt32Array()
	for code: int in range(1, REALM_COUNT + 1):
		if allowed.is_empty() or allowed.has(code):
			realms.append(code)
	return realms


## true si dejar entrar a una persona en [param realm] dejaría más de [param max_diff] personas de ventaja
## sobre el reino con menos de los otros que compiten. [param persons] cuenta las personas que ya hay (sin
## la que entra). Falso con [param max_diff] ≤ 0, con un reino que no compite o sin otro reino con el que
## comparar.
static func exceeds(persons: PackedInt32Array, allowed: PackedInt32Array, realm: int,
		max_diff: int) -> bool:
	if max_diff <= 0:
		return false
	var competing: PackedInt32Array = competing_realms(allowed)
	if not competing.has(realm):
		return false
	var lowest: int = _lowest_of_others(persons, competing, realm)
	if lowest < 0:
		return false
	return _count_of(persons, realm) + 1 - lowest > max_diff


## Total (personas más relleno) de cada reino.
static func totals(persons: PackedInt32Array, fillers: PackedInt32Array) -> PackedInt32Array:
	var result: PackedInt32Array = empty_counts()
	for i: int in REALM_COUNT:
		result[i] = (persons[i] if i < persons.size() else 0) + (fillers[i] if i < fillers.size() else 0)
	return result


## El reino en el que tiene que entrar el siguiente falso de relleno: el de menos total de los que compiten
## (a igualdad, el de código más bajo). 0 si no compite ninguno.
static func realm_for_new_filler(persons: PackedInt32Array, fillers: PackedInt32Array,
		allowed: PackedInt32Array) -> int:
	var all_totals: PackedInt32Array = totals(persons, fillers)
	var best: int = 0
	var best_total: int = 0x7FFFFFFF
	for code: int in competing_realms(allowed):
		var total: int = all_totals[code - 1]
		if total < best_total:
			best_total = total
			best = code
	return best


## true si, tras entrar una persona en [param realm] ([param persons] ya la cuenta), hay que retirar un falso
## de relleno de ese reino: su total supera al menor de los otros que compiten y le queda algún falso.
static func should_retire_on_join(persons: PackedInt32Array, fillers: PackedInt32Array,
		allowed: PackedInt32Array, realm: int) -> bool:
	var competing: PackedInt32Array = competing_realms(allowed)
	if not competing.has(realm) or _count_of(fillers, realm) <= 0:
		return false
	var all_totals: PackedInt32Array = totals(persons, fillers)
	var lowest: int = _lowest_of_others(all_totals, competing, realm)
	return lowest >= 0 and all_totals[realm - 1] > lowest


## true si, tras salir una persona de [param realm] ([param persons] ya no la cuenta), hay que añadir un falso de
## relleno en ese reino: su total queda por debajo del mayor de los otros que compiten y no se ha agotado el
## cupo ([param fillers_alive] relleno vivo en total frente a [param budget]).
static func should_add_on_leave(persons: PackedInt32Array, fillers: PackedInt32Array,
		allowed: PackedInt32Array, realm: int, fillers_alive: int, budget: int) -> bool:
	if fillers_alive >= budget:
		return false
	var competing: PackedInt32Array = competing_realms(allowed)
	if not competing.has(realm):
		return false
	var all_totals: PackedInt32Array = totals(persons, fillers)
	var highest: int = -1
	for code: int in competing:
		if code != realm:
			highest = maxi(highest, all_totals[code - 1])
	return highest >= 0 and all_totals[realm - 1] < highest


static func _count_of(counts: PackedInt32Array, realm: int) -> int:
	var index: int = realm - 1
	return counts[index] if index >= 0 and index < counts.size() else 0


# El menor recuento de los reinos que compiten distintos de [param realm]; -1 si no hay ninguno.
static func _lowest_of_others(counts: PackedInt32Array, competing: PackedInt32Array,
		realm: int) -> int:
	var lowest: int = -1
	for code: int in competing:
		if code == realm:
			continue
		var count: int = _count_of(counts, code)
		if lowest < 0 or count < lowest:
			lowest = count
	return lowest
