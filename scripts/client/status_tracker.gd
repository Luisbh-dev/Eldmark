class_name StatusTracker
extends RefCounted
## Efectos de estado activos de una entidad tal como los cuenta el servidor (UI-45, docs/habilidades.md,
## sección 6.4): uno por entidad, lo alimenta [NetClient] con los ENTITY_EVENT ya temporizados (los del
## jugador local al llegar; los de un remoto en su tick de dibujo).
## [br][br]
## Un STATUS 1 (aplicado o renovado) guarda o actualiza el efecto con sus acumulaciones y su
## [code]until_tick[/code]; un STATUS 2 lo quita. DEATH, DOWNED y RESPAWN de la entidad los quitan todos
## (el servidor los borra sin mandar STATUS sueltos, sección 4.3); el ENTITY_DESPAWN lo atiende quien
## guarda los trackers ([NetClient]), que tira el de esa entidad.
## [br][br]
## La caducidad no necesita evento: [method get_active] solo da los que siguen vivos en el tick que se
## le pase (el del servidor estimado para el jugador local, el de dibujo para un remoto) y
## [method prune] olvida los que ya acabaron. Solo cliente.

## Un efecto activo.
class Entry:
	## Id del efecto en el catálogo de combate ([method CombatCatalog.status]).
	var status_id: int = 0
	## Acumulaciones (al menos 1).
	var stacks: int = 1
	## Tick del servidor en que acaba (exclusivo).
	var until_tick: int = 0
	## Tick del servidor del último STATUS 1 (aplicado o renovado).
	var applied_tick: int = 0
	## Quién lo puso (net_id; 0 = sin autor).
	var source_entity: int = 0

	## true si el efecto perjudica a quien lo lleva ([method StatusTicks.is_harmful]; uno desconocido
	## cuenta como perjudicial).
	func is_harmful() -> bool:
		var status: StatusTicks = CombatCatalog.status(status_id)
		return status == null or status.is_harmful()

	## Ticks que le quedan en [param tick] (0 si ya acabó).
	func ticks_left(tick: int) -> int:
		return maxi(until_tick - tick, 0)


var _entries: Array[Entry] = []
var _events: int = 0


## Atiende un ENTITY_EVENT de esta entidad: STATUS (aplicar, renovar o quitar) y DEATH, DOWNED y
## RESPAWN (quitan todos). Los demás no cambian nada. Devuelve true si algo cambió.
func handle_event(event: NetMessages.EntityEvent) -> bool:
	if event == null:
		return false
	match event.event:
		NetMessages.EntityEvent.Kind.STATUS:
			_events += 1
			if event.op == NetMessages.EntityEvent.StatusOp.APPLIED:
				apply(event.status_id, event.stacks, event.until_tick, event.tick, event.source_entity)
				return true
			if event.op == NetMessages.EntityEvent.StatusOp.REMOVED:
				return remove(event.status_id)
		NetMessages.EntityEvent.Kind.DEATH, NetMessages.EntityEvent.Kind.DOWNED, \
				NetMessages.EntityEvent.Kind.RESPAWN:
			if _entries.is_empty():
				return false
			clear()
			return true
	return false


## Guarda (o actualiza, si ya estaba) el efecto [param status_id] con [param stacks] acumulaciones hasta
## [param until_tick] (exclusivo). Conserva el orden en que llegó cada efecto la primera vez.
func apply(status_id: int, stacks: int, until_tick: int, applied_tick: int = 0,
		source_entity: int = 0) -> void:
	var entry: Entry = _find(status_id)
	if entry == null:
		entry = Entry.new()
		entry.status_id = status_id
		_entries.append(entry)
	entry.stacks = maxi(stacks, 1)
	entry.until_tick = until_tick
	entry.applied_tick = applied_tick
	entry.source_entity = source_entity


## Quita el efecto [param status_id]. Devuelve true si estaba.
func remove(status_id: int) -> bool:
	for index: int in _entries.size():
		if _entries[index].status_id == status_id:
			_entries.remove_at(index)
			return true
	return false


## Quita todos.
func clear() -> void:
	_entries.clear()


## Olvida los efectos que ya han acabado en [param tick]. Devuelve cuántos quitó.
func prune(tick: int) -> int:
	var kept: Array[Entry] = []
	for entry: Entry in _entries:
		if entry.until_tick > tick:
			kept.append(entry)
	var removed: int = _entries.size() - kept.size()
	_entries = kept
	return removed


## Los efectos vivos en [param tick] ([code]until_tick > tick[/code]), en el orden en que llegaron o,
## con [param harmful_first], primero los perjudiciales (y dentro de cada grupo, el que acaba antes).
func get_active(tick: int, harmful_first: bool = false) -> Array[Entry]:
	var active: Array[Entry] = []
	for entry: Entry in _entries:
		if entry.until_tick > tick:
			active.append(entry)
	if harmful_first:
		active.sort_custom(func(a: Entry, b: Entry) -> bool:
			var a_harmful: bool = a.is_harmful()
			if a_harmful != b.is_harmful():
				return a_harmful
			return a.until_tick < b.until_tick)
	return active


## El efecto [param status_id] si se conoce (aunque ya haya caducado), o null.
func get_entry(status_id: int) -> Entry:
	return _find(status_id)


## Efectos guardados (también los ya caducados que no se han podado).
func size() -> int:
	return _entries.size()


## STATUS recibidos desde que existe.
func get_event_count() -> int:
	return _events


func _find(status_id: int) -> Entry:
	for entry: Entry in _entries:
		if entry.status_id == status_id:
			return entry
	return null
