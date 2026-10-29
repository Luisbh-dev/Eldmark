class_name FortressTimeline
extends RefCounted
## Historia de cambios de una fortaleza tal como la conoce el cliente (docs/fuerte.md, secciones 2 y
## 3.2). Puro, sin nodos: [FortressView] guarda una por fortaleza.
## [br][br]
## Cada OBJECT_STATE (y el ENTITY_SPAWN de la estructura, que lleva todos los campos) se anota con su
## [code]tick[/code]: el tick del servidor [b]tras[/b] el que vale el estado. De ahí salen dos
## preguntas distintas:
## [br]- [method state_at]: el estado válido tras el tick [code]t[/code] (el último cambio con
## [code]tick ≤ t[/code]). La interfaz y los estandartes lo piden con el tick de dibujo, así que se
## aplican cuando [code]render_tick[/code] alcanza el del mensaje, no al llegar.
## [br]- [method gate_layers_for_tick]: las capas de la puerta para [i]simular[/i] el tick
## [code]t[/code]. Un cambio con [code]tick = s[/code] vale desde [code]s + 1[/code] (el servidor lo
## aplica en el paso 4b del tick [code]s[/code]), así que se mira el estado tras [code]t - 1[/code].
## La predicción lo pregunta en cada tick simulado, también en las repeticiones, y así cliente y
## servidor simulan cada tick con la misma puerta.
## [br][br]
## [b]Qué se guarda.[/b] Por cambio, los campos que trajo y el estado acumulado tras aplicarlos (un
## [FortressState] reconstruido con [method FortressState.initial] y los campos de
## [FortressFields]; lo que no viaja sale de la definición). Si un mensaje llega desordenado
## (canal fiable, no debería) se inserta en su sitio y se recalculan los siguientes. La historia se
## poda por antigüedad ([constant RETAIN_TICKS] respecto al cambio más nuevo) y por número
## ([constant MAX_ENTRIES]); la entrada más antigua que queda hace de base, y un mensaje anterior a
## ella se ignora.
## [br][br]
## El estado que devuelve [method state_at] es el guardado: no se debe modificar.
## [br][br]
## Solo cliente, pero sin dependencias de nodos de interfaz.

## Cambios que se recuerdan como máximo.
const MAX_ENTRIES: int = 512
## Ticks de antigüedad (respecto al cambio más nuevo) a partir de los que se poda: 30 s, más que de
## sobra para las repeticiones de la reconciliación (anillos de 256 ticks).
const RETAIN_TICKS: int = 1800


## Un cambio: el tick, los campos que trajo y el estado acumulado tras aplicarlos.
class Entry extends RefCounted:
	var tick: int = 0
	var fields: Array[NetMessages.ObjectField] = []
	var state: FortressState = null


var _definition: FortressDefinition = null
var _initial: FortressState = null
var _entries: Array[Entry] = []
var _version: int = 0
var _applied_total: int = 0
var _pruned: bool = false


func _init(definition: FortressDefinition) -> void:
	_definition = definition
	_initial = FortressState.initial(definition, 0)


## Definición con la que se reconstruyen los estados.
func get_definition() -> FortressDefinition:
	return _definition


## true si ya ha llegado algún estado (el SPAWN de la estructura o un OBJECT_STATE).
func has_state() -> bool:
	return not _entries.is_empty()


## Cambios guardados.
func get_entry_count() -> int:
	return _entries.size()


## Contador que sube con cada cambio anotado: sirve para saber si hay algo nuevo sin comparar estados.
func get_version() -> int:
	return _version


## Campos conocidos aplicados desde que existe (los que se saltan por tipo o id desconocido no).
func get_applied_fields() -> int:
	return _applied_total


## Tick del cambio más nuevo (-1 si no hay ninguno).
func get_latest_tick() -> int:
	return _entries[_entries.size() - 1].tick if not _entries.is_empty() else -1


## Tick del cambio más antiguo que se conserva (-1 si no hay ninguno).
func get_oldest_tick() -> int:
	return _entries[0].tick if not _entries.is_empty() else -1


## Anota el OBJECT_STATE [param object_state] (o el SPAWN pasado por
## [method NetMessages.EntitySpawn.to_object_state]). Devuelve cuántos campos conocidos aplicó; 0 si
## no trae ninguno y no se anota nada.
func apply_object_state(object_state: NetMessages.ObjectState) -> int:
	if object_state == null:
		return 0
	return apply_fields(object_state.tick, object_state.fields)


## Anota los campos [param fields] como un cambio del tick [param tick]. Los ids desconocidos y los
## campos con otro tipo de valor que el suyo se saltan (compatibilidad hacia delante). Devuelve
## cuántos campos aplicó; con 0 no se anota nada.
func apply_fields(tick: int, fields: Array[NetMessages.ObjectField]) -> int:
	var index: int = _insert_index(tick)
	if _pruned and index == 0:
		# Anterior a la base que queda tras podar: ya no se puede reconstruir en su sitio.
		return 0
	var state: FortressState = _state_before(index).duplicate_state()
	var applied: int = _apply_to(state, fields)
	if applied == 0:
		return 0
	var entry := Entry.new()
	entry.tick = tick
	entry.fields = fields.duplicate()
	entry.state = state
	_entries.insert(index, entry)
	_applied_total += applied
	_version += 1
	if index < _entries.size() - 1:
		_rebuild_from(index + 1)
	_prune()
	return applied


## Estado válido tras el tick [param tick]: el del último cambio con [code]tick ≤ tick[/code]. Antes
## del primer cambio conocido devuelve ese primero (el SPAWN trae el estado completo y es lo mejor
## que se sabe); sin ningún cambio, el estado inicial de la definición (neutral, entera). No se debe
## modificar.
func state_at(tick: int) -> FortressState:
	if _entries.is_empty():
		return _initial
	return _entries[maxi(_floor_index(tick), 0)].state


## Tick del cambio que da [method state_at] para [param tick] (-1 si aún no hay ninguno).
func change_tick_at(tick: int) -> int:
	if _entries.is_empty():
		return -1
	return _entries[maxi(_floor_index(tick), 0)].tick


## Capas de colisión de movimiento de la puerta para [i]simular[/i] el tick [param tick] (ver la
## descripción de la clase): [method FortGate.layers_for] con el dueño y la rotura del estado tras
## [code]tick - 1[/code].
func gate_layers_for_tick(tick: int) -> int:
	var state: FortressState = state_at(tick - 1)
	return FortGate.layers_for(state.owner, state.is_gate_broken())


## Progreso de la captura (0 a [member FortressState.progress_max]) en el instante de dibujo
## [param render_time] (ticks con fracción): la fórmula
## [code]clamp(p0 + rate · (t − t0), 0, P)[/code] del estado vigente en ese instante.
func progress_at(render_time: float) -> int:
	return state_at(floori(render_time)).progress_at(render_time)


## Progreso de 0 a 1 en [param render_time].
func progress_fraction_at(render_time: float) -> float:
	var state: FortressState = state_at(floori(render_time))
	if state.progress_max <= 0:
		return 0.0
	return clampf(float(state.progress_at(render_time)) / float(state.progress_max), 0.0, 1.0)


# --- Interno ----------------------------------------------------------------------------------

# Primera posición cuyo tick es mayor que [param tick]: donde va un cambio nuevo (detrás de los que
# tienen su mismo tick, que se aplican antes).
func _insert_index(tick: int) -> int:
	var low: int = 0
	var high: int = _entries.size()
	while low < high:
		var middle: int = (low + high) >> 1
		if _entries[middle].tick <= tick:
			low = middle + 1
		else:
			high = middle
	return low


# Posición del último cambio con tick ≤ [param tick], o -1 si todos son posteriores.
func _floor_index(tick: int) -> int:
	return _insert_index(tick) - 1


# Estado acumulado justo antes de la posición [param index] (el inicial si es la primera).
func _state_before(index: int) -> FortressState:
	return _entries[index - 1].state if index > 0 else _initial


func _apply_to(state: FortressState, fields: Array[NetMessages.ObjectField]) -> int:
	var applied: int = 0
	for field: NetMessages.ObjectField in fields:
		if FortressFields.is_known(field.field_id) \
				and FortressFields.value_type(field.field_id) == field.value_type \
				and FortressFields.set_value(state, field.field_id, field.value):
			applied += 1
	return applied


# Recalcula los estados acumulados desde la posición [param first] (tras insertar uno en medio).
func _rebuild_from(first: int) -> void:
	for index: int in range(first, _entries.size()):
		var state: FortressState = _state_before(index).duplicate_state()
		_apply_to(state, _entries[index].fields)
		_entries[index].state = state


# Quita lo muy antiguo, dejando siempre una entrada de base.
func _prune() -> void:
	var newest: int = _entries[_entries.size() - 1].tick
	while _entries.size() > 1 and (_entries.size() > MAX_ENTRIES
			or _entries[1].tick < newest - RETAIN_TICKS):
		_entries.remove_at(0)
		_pruned = true
