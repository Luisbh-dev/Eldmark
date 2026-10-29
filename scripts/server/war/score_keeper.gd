class_name ScoreKeeper
extends RefCounted
## Marcador de la batalla (docs/fuerte.md, sección 6; UI-41): por jugador, bajas, muertes,
## asistencias, daño a la puerta, tiempo en el círculo y méritos. Todo en memoria (la persistencia
## llega en la fase 5). Lo alimenta el [ZoneServer] con los KILL y DEATH del combate y el
## [FortressController] con el círculo y la puerta, y [method build_rows] da las filas del
## SCOREBOARD que se manda a toda la zona cada 2 s.
## [br][br]
## [b]Méritos provisionales[/b] (la regla de verdad llega con PRG-09, con antifarmeo y reparto por
## daño): [code]bajas × 10 + asistencias × 5 + segundos en el círculo[/code]
## ([constant MERITS_PER_KILL], [constant MERITS_PER_ASSIST]). Contra el mismo rival rinden siempre
## igual: aquí no hay antifarmeo.

## Méritos por cada baja y por cada asistencia.
const MERITS_PER_KILL: int = 10
const MERITS_PER_ASSIST: int = 5


## Contadores de un jugador.
class Entry:
	extends RefCounted

	var kills: int = 0
	var deaths: int = 0
	var assists: int = 0
	var gate_damage: int = 0
	## Ticks pasados dentro de un círculo de captura activo.
	var circle_ticks: int = 0


	## Segundos enteros en el círculo.
	func circle_seconds() -> int:
		@warning_ignore("integer_division")
		return circle_ticks / CombatCatalog.TICK_RATE


	## Méritos provisionales de este jugador.
	func merits() -> int:
		return kills * MERITS_PER_KILL + assists * MERITS_PER_ASSIST + circle_seconds()


# net_id -> contadores.
var _entries: Dictionary[int, Entry] = {}


## Una baja de [param net_id].
func add_kill(net_id: int) -> void:
	_entry(net_id).kills += 1


## Una muerte de [param net_id].
func add_death(net_id: int) -> void:
	_entry(net_id).deaths += 1


## Una asistencia de [param net_id].
func add_assist(net_id: int) -> void:
	_entry(net_id).assists += 1


## [param amount] de daño a la puerta de [param net_id].
func add_gate_damage(net_id: int, amount: int) -> void:
	if amount > 0:
		_entry(net_id).gate_damage += amount


## [param ticks] pasados por [param net_id] dentro de un círculo activo.
func add_circle_ticks(net_id: int, ticks: int) -> void:
	if ticks > 0:
		_entry(net_id).circle_ticks += ticks


## Contadores de [param net_id], o null si todavía no tiene ninguno.
func get_entry(net_id: int) -> Entry:
	return _entries.get(net_id)


## Borra los contadores de [param net_id] (se va del mundo: su id puede reutilizarse).
func forget(net_id: int) -> void:
	_entries.erase(net_id)


## Borra todo.
func clear() -> void:
	_entries.clear()


## Jugadores con contadores.
func size() -> int:
	return _entries.size()


## Las filas del SCOREBOARD de [param net_ids] (en el orden dado; los que no tienen contadores salen a
## cero).
func build_rows(net_ids: Array[int]) -> Array[NetMessages.ScoreRow]:
	var rows: Array[NetMessages.ScoreRow] = []
	for net_id: int in net_ids:
		var entry: Entry = _entries.get(net_id)
		if entry == null:
			rows.append(NetMessages.ScoreRow.make(net_id, 0, 0, 0, 0, 0, 0))
		else:
			rows.append(NetMessages.ScoreRow.make(net_id, entry.kills, entry.deaths,
					entry.assists, entry.gate_damage, entry.circle_seconds(), entry.merits()))
	return rows


func _entry(net_id: int) -> Entry:
	var found: Entry = _entries.get(net_id)
	if found == null:
		found = Entry.new()
		_entries[net_id] = found
	return found
