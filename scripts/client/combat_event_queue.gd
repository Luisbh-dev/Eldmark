class_name CombatEventQueue
extends RefCounted
## Cola de eventos de combate ajenos, ordenada por tick del servidor (docs/combate.md, sección 6).
## [br][br]
## Un ENTITY_EVENT sobre otros jugadores no se muestra al llegar, sino cuando el tick de dibujo
## ([method InterpolationClock.get_render_tick]) alcanza su [code]tick[/code]: así el destello, la
## sacudida o la animación de un remoto coinciden con lo que se ve de él en pantalla (va unos 100
## ms por detrás del servidor). [NetClient] mete aquí los eventos que no son propios y, en cada tick
## de física, saca los que ya tocan con [method pop_due].
## [br][br]
## Los eventos con el mismo tick salen en el orden en que llegaron. La cola tiene un tope
## ([constant MAX_PENDING]) para que un reloj de dibujo que no arranca no la deje crecer sin límite;
## al llenarse se descarta el más antiguo y se cuenta en [member dropped].

## Eventos que se guardan como máximo.
const MAX_PENDING: int = 512

## Eventos descartados por llenarse la cola.
var dropped: int = 0

# Eventos pendientes ordenados por (tick, orden de llegada).
var _events: Array[NetMessages.EntityEvent] = []


## Guarda [param event] en su sitio según su tick (detrás de los que tienen el mismo tick o menos).
func push(event: NetMessages.EntityEvent) -> void:
	if event == null:
		return
	var index: int = _events.size()
	while index > 0 and _events[index - 1].tick > event.tick:
		index -= 1
	_events.insert(index, event)
	if _events.size() > MAX_PENDING:
		_events.remove_at(0)
		dropped += 1


## Saca, en orden, los eventos cuyo tick es menor o igual que [param render_tick]. Con un tick de
## dibujo que no ha arrancado (0 o menos) no sale ninguno.
func pop_due(render_tick: float) -> Array[NetMessages.EntityEvent]:
	var due: Array[NetMessages.EntityEvent] = []
	if render_tick <= 0.0:
		return due
	var count: int = 0
	while count < _events.size() and float(_events[count].tick) <= render_tick:
		count += 1
	if count == 0:
		return due
	due.assign(_events.slice(0, count))
	_events = _events.slice(count)
	return due


## Eventos pendientes.
func size() -> int:
	return _events.size()


## Tick del próximo evento, o -1 si no hay ninguno.
func peek_next_tick() -> int:
	return _events[0].tick if not _events.is_empty() else -1


## Descarta todos los eventos pendientes.
func clear() -> void:
	_events.clear()
