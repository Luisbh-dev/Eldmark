class_name AttackTokens
extends RefCounted
## Attack tokens (docs/fortress.md, section 4.2; MUN-08): at most [constant MAX_PER_TARGET] NPCs attack the
## same target at once; the rest circle it at 3 or 4 m waiting for their turn.
## [br][br]
## An NPC requests a token with [method try_claim] before starting an attack and releases it with
## [method release] when its attack ends. A token expires on its own after [constant TTL_TICKS] ticks if not
## renewed, so that an NPC that dies, despawns or loses its target does not leave anyone without a turn:
## whoever holds it renews it with [method renew] on every think while attacking.

## NPCs that can attack the same target at once.
const MAX_PER_TARGET: int = 2
## Ticks a token lasts without renewal (1 s).
const TTL_TICKS: int = 60

# target -> {NPC -> tick at which its token expires}.
var _holders: Dictionary[int, Dictionary] = {}
# Tokens granted since it was created (for measurement).
var _claims_granted: int = 0
var _claims_denied: int = 0


## Requests an attack token against [param target_id] for NPC [param npc_id] at tick [param tick]. true if
## it holds one (it already had it, or one was free).
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


## Renews the token that [param npc_id] holds against [param target_id]. Returns false if it did not hold
## one (or it had already expired).
func renew(target_id: int, npc_id: int, tick: int) -> bool:
	var holders: Dictionary = _holders.get(target_id, {})
	if not holders.has(npc_id) or int(holders[npc_id]) <= tick:
		return false
	holders[npc_id] = tick + TTL_TICKS
	return true


## true if [param npc_id] holds a valid token against [param target_id].
func holds(target_id: int, npc_id: int, tick: int) -> bool:
	var holders: Dictionary = _holders.get(target_id, {})
	return holders.has(npc_id) and int(holders[npc_id]) > tick


## Releases [param npc_id]'s token against [param target_id].
func release(target_id: int, npc_id: int) -> void:
	var holders: Dictionary = _holders.get(target_id, {})
	holders.erase(npc_id)
	if holders.is_empty():
		_holders.erase(target_id)


## Releases all of [param npc_id]'s tokens (it dies or withdraws).
func release_all(npc_id: int) -> void:
	for target_id: int in _holders.keys():
		release(target_id, npc_id)


## Valid tokens against [param target_id] at tick [param tick].
func count(target_id: int, tick: int) -> int:
	var holders: Dictionary = _holders.get(target_id, {})
	var total: int = 0
	for expires: int in holders.values():
		if expires > tick:
			total += 1
	return total


## Removes all the tokens (when the server shuts down).
func clear() -> void:
	_holders.clear()


## Tokens granted and denied since it was created.
func get_stats() -> Dictionary:
	return {"granted": _claims_granted, "denied": _claims_denied}


static func _prune(holders: Dictionary, tick: int) -> void:
	for npc_id: int in holders.keys():
		if int(holders[npc_id]) <= tick:
			holders.erase(npc_id)
