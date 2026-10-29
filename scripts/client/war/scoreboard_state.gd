class_name ScoreboardState
extends RefCounted
## Marcador de la zona tal como lo ve el cliente (docs/fuerte.md, sección 6; UI-41). Puro, sin nodos.
## [br][br]
## El servidor manda el marcador cada 2 s a toda la zona y, con más de
## [constant NetMessages.Scoreboard.MAX_ROWS] jugadores, lo parte en varias páginas
## ([method NetMessages.Scoreboard.split]). Este objeto las junta: una página 0 (o un total de
## páginas distinto) empieza un marcador nuevo, y cuando están todas las páginas del total se publica
## entero y sustituye al anterior. Mientras tanto se sigue viendo el último marcador completo, así que
## la lista no parpadea ni se queda a medias.

## Cuántos marcadores completos se han publicado.
var version: int = 0

var _rows: Array[NetMessages.ScoreRow] = []
var _pending: Dictionary[int, Array] = {}
var _pending_count: int = 0
var _pages_received: int = 0
var _updated_at_msec: int = 0


## Anota una página. Devuelve true si con ella el marcador queda completo y se publica.
func apply(board: NetMessages.Scoreboard) -> bool:
	if board == null:
		return false
	_pages_received += 1
	if board.page_index == 0 or board.page_count != _pending_count:
		_pending.clear()
		_pending_count = board.page_count
	_pending[board.page_index] = board.rows.duplicate()
	if _pending.size() < _pending_count:
		return false
	var joined: Array[NetMessages.ScoreRow] = []
	for page: int in _pending_count:
		var page_rows: Array = _pending.get(page, [])
		for row: NetMessages.ScoreRow in page_rows:
			joined.append(row)
	_rows = joined
	_pending.clear()
	version += 1
	return true


## Filas del último marcador completo, en el orden del servidor.
func get_rows() -> Array[NetMessages.ScoreRow]:
	return _rows.duplicate()


## Fila del jugador [param net_id] (null si no figura).
func get_row(net_id: int) -> NetMessages.ScoreRow:
	for row: NetMessages.ScoreRow in _rows:
		if row.net_id == net_id:
			return row
	return null


## Número de filas del último marcador completo.
func get_row_count() -> int:
	return _rows.size()


## Páginas recibidas desde que existe.
func get_pages_received() -> int:
	return _pages_received


## Páginas que faltan para completar el marcador que se está juntando (0 si no hay ninguno a medias).
func get_pending_pages() -> int:
	return maxi(_pending_count - _pending.size(), 0) if not _pending.is_empty() else 0


## Ordena [param rows] para mostrarlas: más bajas primero, luego menos muertes, más asistencias y,
## por último, el id para que el orden sea estable.
static func sort_rows(rows: Array[NetMessages.ScoreRow]) -> Array[NetMessages.ScoreRow]:
	var sorted: Array[NetMessages.ScoreRow] = rows.duplicate()
	sorted.sort_custom(func(a: NetMessages.ScoreRow, b: NetMessages.ScoreRow) -> bool:
		if a.kills != b.kills:
			return a.kills > b.kills
		if a.deaths != b.deaths:
			return a.deaths < b.deaths
		if a.assists != b.assists:
			return a.assists > b.assists
		return a.net_id < b.net_id)
	return sorted
