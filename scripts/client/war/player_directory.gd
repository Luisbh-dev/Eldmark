class_name PlayerDirectory
extends RefCounted
## Quién es cada id de red, para el marcador y el registro de bajas (UI-41).
## [br][br]
## El SCOREBOARD y los KILL que llegan a toda la zona solo llevan [code]net_id[/code], no nombre ni
## reino, y el [RemoteWorld] solo conoce a quien está dentro del radio de interés. Por eso el cliente
## recuerda el nombre y el reino de cada ENTITY_SPAWN que ve (también el propio) y los conserva
## aunque la entidad salga de interés. Quien nunca se ha visto sale como «Jugador N» y sin reino.
## Tiene un tope ([constant MAX_ENTRIES]): al llenarse se olvida al más antiguo.

## Entradas que se recuerdan como máximo.
const MAX_ENTRIES: int = 1024

var _names: Dictionary[int, String] = {}
var _realms: Dictionary[int, int] = {}
var _kinds: Dictionary[int, int] = {}
var _order: Array[int] = []


## Apunta (o actualiza) a la entidad [param net_id].
func remember(net_id: int, display_name: String, realm: int, kind: int = NetProtocol.EntityKind.PLAYER) -> void:
	if net_id == 0:
		return
	if not _names.has(net_id):
		_order.append(net_id)
		if _order.size() > MAX_ENTRIES:
			var oldest: int = _order.pop_front()
			_names.erase(oldest)
			_realms.erase(oldest)
			_kinds.erase(oldest)
	_names[net_id] = display_name
	_realms[net_id] = realm
	_kinds[net_id] = kind


## Apunta al emisor de un ENTITY_SPAWN.
func remember_spawn(spawn: NetMessages.EntitySpawn) -> void:
	if spawn != null:
		remember(spawn.net_id, spawn.display_name, spawn.realm, spawn.kind)


## true si se conoce a [param net_id].
func knows(net_id: int) -> bool:
	return _names.has(net_id)


## Nombre de [param net_id], o «Jugador N» si nunca se ha visto.
func name_of(net_id: int) -> String:
	var known: String = _names.get(net_id, "")
	return known if not known.is_empty() else "Jugador %d" % net_id


## Reino (código de red) de [param net_id], o [constant NetProtocol.Realm.NONE] si no se conoce.
func realm_of(net_id: int) -> int:
	return _realms.get(net_id, NetProtocol.Realm.NONE)


## Tipo de entidad ([enum NetProtocol.EntityKind]); jugador si no se conoce.
func kind_of(net_id: int) -> int:
	return _kinds.get(net_id, NetProtocol.EntityKind.PLAYER)


func size() -> int:
	return _names.size()


func clear() -> void:
	_names.clear()
	_realms.clear()
	_kinds.clear()
	_order.clear()
