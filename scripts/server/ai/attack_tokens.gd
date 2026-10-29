class_name AttackTokens
extends RefCounted
## Fichas de ataque (docs/fuerte.md, sección 4.2; MUN-08): como mucho [constant MAX_PER_TARGET] PNJ atacan a la
## vez al mismo objetivo; los demás lo rodean a 3 o 4 m esperando su turno.
## [br][br]
## Un PNJ pide una ficha con [method try_claim] antes de empezar un ataque y la suelta con [method release]
## cuando su ataque acaba. Una ficha caduca sola a los [constant TTL_TICKS] ticks si no se renueva, para que un
## PNJ que muere, desaparece o pierde el objetivo no deje a nadie sin turno: quien la tiene la renueva con
## [method renew] en cada pensamiento mientras ataca.

## PNJ que pueden atacar a la vez al mismo objetivo.
const MAX_PER_TARGET: int = 2
## Ticks que dura una ficha sin renovar (1 s).
const TTL_TICKS: int = 60

# objetivo -> {pnj -> tick en el que caduca su ficha}.
var _holders: Dictionary[int, Dictionary] = {}
# Fichas concedidas desde que existe (para medir).
var _claims_granted: int = 0
var _claims_denied: int = 0


## Pide una ficha de ataque contra [param target_id] para el PNJ [param npc_id] en el tick [param tick]. true si
## la tiene (ya la tenía, o quedaba alguna libre).
func try_claim(target_id: int, npc_id: int, tick: int) -> bool:
	var holders: Dictionary = _holders.get(target_id, {})
	if holders.has(npc_id) and int(holders[npc_id]) > tick:
		holders[npc_id] = tick + TTL_TICKS
		return true
	_prune(holders, tick)
	if holders.size() >= MAX_PER_TARGET:
		_claims_denied += 1
		return false
	holders[npc_id] = tick + TTL_TICKS
	_holders[target_id] = holders
	_claims_granted += 1
	return true


## Renueva la ficha que [param npc_id] tiene contra [param target_id]. Devuelve false si no la tenía (o ya había
## caducado).
func renew(target_id: int, npc_id: int, tick: int) -> bool:
	var holders: Dictionary = _holders.get(target_id, {})
	if not holders.has(npc_id) or int(holders[npc_id]) <= tick:
		return false
	holders[npc_id] = tick + TTL_TICKS
	return true


## true si [param npc_id] tiene una ficha vigente contra [param target_id].
func holds(target_id: int, npc_id: int, tick: int) -> bool:
	var holders: Dictionary = _holders.get(target_id, {})
	return holders.has(npc_id) and int(holders[npc_id]) > tick


## Suelta la ficha de [param npc_id] contra [param target_id].
func release(target_id: int, npc_id: int) -> void:
	var holders: Dictionary = _holders.get(target_id, {})
	holders.erase(npc_id)
	if holders.is_empty():
		_holders.erase(target_id)


## Suelta todas las fichas de [param npc_id] (muere o se retira).
func release_all(npc_id: int) -> void:
	for target_id: int in _holders.keys():
		release(target_id, npc_id)


## Fichas vigentes contra [param target_id] en el tick [param tick].
func count(target_id: int, tick: int) -> int:
	var holders: Dictionary = _holders.get(target_id, {})
	var total: int = 0
	for expires: int in holders.values():
		if expires > tick:
			total += 1
	return total


## Quita todas las fichas (al cerrar el servidor).
func clear() -> void:
	_holders.clear()


## Fichas concedidas y denegadas desde que existe.
func get_stats() -> Dictionary:
	return {"granted": _claims_granted, "denied": _claims_denied}


static func _prune(holders: Dictionary, tick: int) -> void:
	for npc_id: int in holders.keys():
		if int(holders[npc_id]) <= tick:
			holders.erase(npc_id)
