class_name NetEntityRegistry
extends RefCounted
## Registro de las entidades de red de la zona (docs/red.md, sección 9.1).
## [br][br]
## Asigna ids de 1 a 65535 (el 0 significa «ninguno») recorriendo el rango en círculo, así que un
## id tarda en volver a salir aunque no hubiera cuarentena. Un id liberado queda además en
## cuarentena [constant ID_QUARANTINE_TICKS] ticks (10 s): los canales de snapshots y de mensajes
## fiables no están ordenados entre sí, y un registro rezagado de la entidad vieja no puede
## atribuirse a la nueva.
## [br][br]
## [method get_sorted] da las entidades por [code]net_id[/code] ascendente: ese es el orden fijo
## de simulación del servidor.
## [br][br]
## [b]Ids pasajeros[/b] (docs/habilidades.md, sección 4.4): los proyectiles toman su id del mismo espacio
## con [method allocate_transient_id], sin entrar en la lista de entidades (no tienen [NetEntity] ni van
## en el snapshot), y lo devuelven con [method release_transient_id] a la misma cuarentena: un DESPAWN
## rezagado de una flecha nunca se atribuye a la entidad que reciba después su id, ni al revés.

## Ticks que un id liberado no puede reutilizarse (10 s a 60 Hz).
const ID_QUARANTINE_TICKS: int = 600
## Primer y último id que se asignan.
const FIRST_ID: int = 1
const LAST_ID: int = 65535

var _entities: Dictionary[int, NetEntity] = {}
# Ids pasajeros en uso (los proyectiles).
var _transient: Dictionary[int, bool] = {}
# net_id -> tick en el que se liberó.
var _quarantine: Dictionary[int, int] = {}
# Orden de liberación (los ticks no decrecen), para ir sacando los ids que ya cumplieron.
var _quarantine_order: PackedInt32Array = PackedInt32Array()
var _quarantine_head: int = 0
var _next_id: int = FIRST_ID
var _sorted: Array[NetEntity] = []
var _sorted_dirty: bool = false


## Crea una entidad de tipo [param kind] (un [enum NetProtocol.EntityKind]) dada de alta en el
## tick [param now_tick] y le asigna un id libre. null si no queda ninguno (los 65535 están en
## uso o en cuarentena).
func allocate(kind: int, now_tick: int) -> NetEntity:
	_release_expired(now_tick)
	var span: int = LAST_ID - FIRST_ID + 1
	var candidate: int = _next_id
	for _i: int in span:
		if _is_free(candidate):
			var entity := NetEntity.new()
			entity.net_id = candidate
			entity.kind = kind
			entity.spawn_tick = now_tick
			_entities[candidate] = entity
			_next_id = candidate + 1 if candidate < LAST_ID else FIRST_ID
			_sorted_dirty = true
			return entity
		candidate = candidate + 1 if candidate < LAST_ID else FIRST_ID
	return null


## Reserva un id del espacio de las entidades en el tick [param now_tick] sin crear ninguna entidad (el de
## un proyectil), con la misma búsqueda en círculo y la misma cuarentena que [method allocate]. 0 si no
## queda ninguno.
func allocate_transient_id(now_tick: int) -> int:
	_release_expired(now_tick)
	var span: int = LAST_ID - FIRST_ID + 1
	var candidate: int = _next_id
	for _i: int in span:
		if _is_free(candidate):
			_transient[candidate] = true
			_next_id = candidate + 1 if candidate < LAST_ID else FIRST_ID
			return candidate
		candidate = candidate + 1 if candidate < LAST_ID else FIRST_ID
	return 0


## Devuelve en el tick [param now_tick] el id pasajero [param net_id] y lo deja en cuarentena. No hace
## nada si no es un id pasajero en uso.
func release_transient_id(net_id: int, now_tick: int) -> void:
	if not _transient.erase(net_id):
		return
	_quarantine[net_id] = now_tick
	_quarantine_order.append(net_id)


## true si [param net_id] es un id pasajero en uso.
func is_transient(net_id: int) -> bool:
	return _transient.has(net_id)


## Ids pasajeros en uso.
func transient_count() -> int:
	return _transient.size()


## Quita la entidad [param net_id] del registro en el tick [param now_tick] y deja su id en
## cuarentena. No hace nada si el id no está en uso.
func release(net_id: int, now_tick: int) -> void:
	if not _entities.erase(net_id):
		return
	_quarantine[net_id] = now_tick
	_quarantine_order.append(net_id)
	_sorted_dirty = true


## La entidad con ese id, o null.
func get_entity(net_id: int) -> NetEntity:
	return _entities.get(net_id)


## Todas las entidades por [code]net_id[/code] ascendente. El array es una caché que se
## reconstruye tras cada alta y cada baja: quien llama no debe modificarlo, y debe saber que se
## sustituye por otro array (no se cambia en el sitio) cuando el registro cambia.
func get_sorted() -> Array[NetEntity]:
	if _sorted_dirty:
		var ids: Array[int] = []
		ids.assign(_entities.keys())
		ids.sort()
		var rebuilt: Array[NetEntity] = []
		rebuilt.resize(ids.size())
		for i: int in ids.size():
			rebuilt[i] = _entities[ids[i]]
		_sorted = rebuilt
		_sorted_dirty = false
	return _sorted


## Número de entidades en el registro.
func size() -> int:
	return _entities.size()


## true si [param net_id] está en cuarentena (liberado hace menos de
## [constant ID_QUARANTINE_TICKS] ticks) en el tick [param now_tick].
func is_quarantined(net_id: int, now_tick: int) -> bool:
	return _quarantine.has(net_id) and now_tick - _quarantine[net_id] < ID_QUARANTINE_TICKS


# true si nadie usa [param net_id]: ni una entidad, ni un proyectil, ni la cuarentena.
func _is_free(net_id: int) -> bool:
	return not _entities.has(net_id) and not _transient.has(net_id) and not _quarantine.has(net_id)


# Saca de la cuarentena los ids que llevan ID_QUARANTINE_TICKS ticks o más liberados.
func _release_expired(now_tick: int) -> void:
	while _quarantine_head < _quarantine_order.size():
		var net_id: int = _quarantine_order[_quarantine_head]
		if now_tick - _quarantine[net_id] < ID_QUARANTINE_TICKS:
			break
		_quarantine.erase(net_id)
		_quarantine_head += 1
	# Compacta la cola cuando ya se ha gastado la mayor parte.
	if _quarantine_head > 1024 and _quarantine_head * 2 > _quarantine_order.size():
		_quarantine_order = _quarantine_order.slice(_quarantine_head)
		_quarantine_head = 0
