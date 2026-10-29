class_name ChatInputHistory
extends RefCounted
## Historial de lo que ha escrito el jugador en la línea del chat (SOC-05): flecha arriba recorre las
## líneas enviadas de la más nueva a la más vieja y flecha abajo vuelve hacia la que se estaba escribiendo
## (el borrador). Es solo datos.

## Líneas como mucho que recuerda.
const MAX_ENTRIES: int = 50

var _entries: PackedStringArray = PackedStringArray()
## Posición en [member _entries] (-1 = el borrador).
var _cursor: int = -1
var _draft: String = ""


## Recuerda la línea enviada [param line] (se ignora si está vacía o es igual a la última) y vuelve al
## borrador.
func remember(line: String) -> void:
	_cursor = -1
	_draft = ""
	var trimmed: String = line.strip_edges()
	if trimmed.is_empty():
		return
	if not _entries.is_empty() and _entries[_entries.size() - 1] == trimmed:
		return
	_entries.append(trimmed)
	if _entries.size() > MAX_ENTRIES:
		_entries.remove_at(0)


## Vuelve al borrador sin recordar nada (al abrir o cerrar la línea).
func reset() -> void:
	_cursor = -1
	_draft = ""


## La línea anterior a la mostrada. Si se estaba escribiendo ([param current_text]), eso queda de
## borrador. Devuelve [param current_text] si no hay historial.
func previous(current_text: String) -> String:
	if _entries.is_empty():
		return current_text
	if _cursor < 0:
		_draft = current_text
		_cursor = _entries.size() - 1
	else:
		_cursor = maxi(_cursor - 1, 0)
	return _entries[_cursor]


## La línea siguiente a la mostrada; tras la más nueva, el borrador. Sin haber subido antes, no cambia
## nada ([param current_text]).
func next(current_text: String) -> String:
	if _cursor < 0:
		return current_text
	_cursor += 1
	if _cursor >= _entries.size():
		_cursor = -1
		return _draft
	return _entries[_cursor]


func get_entries() -> PackedStringArray:
	return _entries.duplicate()
