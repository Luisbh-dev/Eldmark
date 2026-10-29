class_name DamageLedger
extends RefCounted
## Registro del daño que ha recibido una víctima (docs/combate.md, sección 5; GUE-05): quién le
## hizo cuánto y cuándo, durante los últimos [constant WINDOW_TICKS] ticks (15 s).
## [br][br]
## Con él, al morir, el servidor reparte el crédito: el golpe de gracia es para quien dio el golpe
## mortal (o, si murió por el entorno, para el último enemigo que la golpeó) y las asistencias son
## para quienes hicieron al menos el [constant ASSIST_PERCENT] % del daño de la ventana.
## [br][br]
## Solo se apunta el daño que llega a la vida y de un atacante concreto: el entorno (id 0) y las
## autolesiones no cuentan. Los aliados nunca aparecen porque no hay fuego amigo
## ([FactionRules]).

## Ventana del registro (15 s a 60 Hz).
const WINDOW_TICKS: int = 900
## Porcentaje mínimo del daño de la ventana para contar como asistencia.
const ASSIST_PERCENT: int = 10
## Máximo de asistentes que se devuelven (con un 10 % mínimo nunca son más de 10).
const MAX_ASSISTANTS: int = 10

# Una entrada por golpe, en orden cronológico. Los ticks van en 64 bits (son u32 en el servidor).
var _ticks: PackedInt64Array = PackedInt64Array()
var _attackers: PackedInt32Array = PackedInt32Array()
var _amounts: PackedInt32Array = PackedInt32Array()
# Primera entrada vigente; lo anterior se descarta al compactar.
var _head: int = 0
# net_id de la víctima: sus propios golpes no cuentan.
var _victim_id: int = 0


func _init(victim_id: int = 0) -> void:
	_victim_id = victim_id


## Apunta [param amount] de daño de [param attacker_id] en el tick [param tick]. No hace nada con
## una cantidad no positiva, con el entorno (id 0) ni con las autolesiones.
func record(tick: int, attacker_id: int, amount: int) -> void:
	if amount <= 0 or attacker_id <= 0 or attacker_id == _victim_id:
		return
	_ticks.append(tick)
	_attackers.append(attacker_id)
	_amounts.append(amount)
	_prune(tick)


## Daño total de la ventana que termina en [param tick].
func total_damage(tick: int) -> int:
	var total: int = 0
	for i: int in range(_first_valid(tick), _ticks.size()):
		total += _amounts[i]
	return total


## Daño que [param attacker_id] hizo en la ventana que termina en [param tick].
func damage_by(attacker_id: int, tick: int) -> int:
	var total: int = 0
	for i: int in range(_first_valid(tick), _ticks.size()):
		if _attackers[i] == attacker_id:
			total += _amounts[i]
	return total


## Asistentes de la muerte en [param tick]: quienes (salvo [param killer_id]) hicieron al menos el
## [constant ASSIST_PERCENT] % del daño total de la ventana, ordenados por daño descendente y, a
## igual daño, por id.
func get_assistants(killer_id: int, tick: int) -> PackedInt32Array:
	var by_attacker: Dictionary[int, int] = {}
	var total: int = 0
	for i: int in range(_first_valid(tick), _ticks.size()):
		by_attacker[_attackers[i]] = by_attacker.get(_attackers[i], 0) + _amounts[i]
		total += _amounts[i]
	var assistants: Array[Dictionary] = []
	for attacker_id: int in by_attacker:
		var damage: int = by_attacker[attacker_id]
		if attacker_id != killer_id and damage * 100 >= total * ASSIST_PERCENT:
			assistants.append({"id": attacker_id, "damage": damage})
	assistants.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if a["damage"] != b["damage"]:
			return a["damage"] > b["damage"]
		return a["id"] < b["id"])
	var result := PackedInt32Array()
	for entry: Dictionary in assistants:
		if result.size() >= MAX_ASSISTANTS:
			break
		result.append(entry["id"])
	return result


## Último atacante que le hizo daño (id), o 0 si no hay ninguno en la ventana.
func last_attacker(tick: int) -> int:
	if _ticks.size() > _first_valid(tick):
		return _attackers[_ticks.size() - 1]
	return 0


## Número de golpes apuntados en la ventana que termina en [param tick].
func entry_count(tick: int) -> int:
	return _ticks.size() - _first_valid(tick)


## Borra todo lo apuntado de [param attacker_id] (se ha ido del servidor: su id puede reutilizarse).
func forget_attacker(attacker_id: int) -> void:
	var kept_ticks := PackedInt64Array()
	var kept_attackers := PackedInt32Array()
	var kept_amounts := PackedInt32Array()
	for i: int in range(_head, _ticks.size()):
		if _attackers[i] != attacker_id:
			kept_ticks.append(_ticks[i])
			kept_attackers.append(_attackers[i])
			kept_amounts.append(_amounts[i])
	_ticks = kept_ticks
	_attackers = kept_attackers
	_amounts = kept_amounts
	_head = 0


## Vacía el registro (al reaparecer).
func clear() -> void:
	_ticks.clear()
	_attackers.clear()
	_amounts.clear()
	_head = 0


# Índice de la primera entrada dentro de la ventana que termina en [param tick].
func _first_valid(tick: int) -> int:
	var index: int = _head
	while index < _ticks.size() and tick - _ticks[index] >= WINDOW_TICKS:
		index += 1
	return index


# Descarta lo que ya salió de la ventana y compacta los arrays cuando lo descartado es la mitad.
func _prune(tick: int) -> void:
	_head = _first_valid(tick)
	if _head > 32 and _head * 2 > _ticks.size():
		_ticks = _ticks.slice(_head)
		_attackers = _attackers.slice(_head)
		_amounts = _amounts.slice(_head)
		_head = 0
