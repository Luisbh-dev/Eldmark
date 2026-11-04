class_name PlayerDirectory
extends RefCounted
## Who each network id is, for the scoreboard and the kill log (UI-41).
## [br][br]
## The SCOREBOARD and the KILL messages that reach the whole zone carry only [code]net_id[/code], not name
## or realm, and the [RemoteWorld] only knows those within the interest radius. That is why the client
## remembers the name and realm of every ENTITY_SPAWN it sees (also its own) and keeps them even if the
## entity leaves interest. Anyone never seen appears as "Jugador N" (Player N) and without a realm. It has
## a cap ([constant MAX_ENTRIES]): when full, the oldest is forgotten.

## Entries remembered at most.
const MAX_ENTRIES: int = 1024

var _names: Dictionary[int, String] = {}
var _realms: Dictionary[int, int] = {}
var _kinds: Dictionary[int, int] = {}
var _npc_defs: Dictionary[int, int] = {}
var _order: Array[int] = []


## Records (or updates) entity [param net_id].
func remember(net_id: int, display_name: String, realm: int, kind: int = NetProtocol.EntityKind.PLAYER,
		npc_def_id: int = 0) -> void:
	if net_id == 0:
		return
	if not _names.has(net_id):
		_order.append(net_id)
		if _order.size() > MAX_ENTRIES:
			var oldest: int = _order.pop_front()
			_names.erase(oldest)
			_realms.erase(oldest)
			_kinds.erase(oldest)
			_npc_defs.erase(oldest)
	_names[net_id] = display_name
	_realms[net_id] = realm
	_kinds[net_id] = kind
	_npc_defs[net_id] = npc_def_id


## Records the sender of an ENTITY_SPAWN.
func remember_spawn(spawn: NetMessages.EntitySpawn) -> void:
	if spawn != null:
		remember(spawn.net_id, spawn.display_name, spawn.realm, spawn.kind, spawn.npc_def_id)


## true if [param net_id] is known.
func knows(net_id: int) -> bool:
	return _names.has(net_id)


## Name of [param net_id], or "Jugador N" (Player N) if never seen.
func name_of(net_id: int) -> String:
	var known: String = _names.get(net_id, "")
	return known if not known.is_empty() else "Jugador %d" % net_id


## Realm (network code) of [param net_id], or [constant NetProtocol.Realm.NONE] if unknown.
func realm_of(net_id: int) -> int:
	return _realms.get(net_id, NetProtocol.Realm.NONE)


## Entity kind ([enum NetProtocol.EntityKind]); player if unknown.
func kind_of(net_id: int) -> int:
	return _kinds.get(net_id, NetProtocol.EntityKind.PLAYER)


## Id of the NPC definition ([code]npc_def_id[/code] of the SPAWN) of [param net_id]; 0 if it is a player
## or unknown.
func npc_def_of(net_id: int) -> int:
	return _npc_defs.get(net_id, 0)


func size() -> int:
	return _names.size()


func clear() -> void:
	_names.clear()
	_realms.clear()
	_kinds.clear()
	_npc_defs.clear()
	_order.clear()
