class_name ScoreboardState
extends RefCounted
## Zone scoreboard as the client sees it (docs/fuerte.md, section 6; UI-41). Pure, no nodes.
## [br][br]
## The server sends the scoreboard every 2 s to the whole zone and, with more than
## [constant NetMessages.Scoreboard.MAX_ROWS] players, splits it into several pages
## ([method NetMessages.Scoreboard.split]). This object assembles them: a page 0 (or a different total page
## count) starts a new scoreboard, and when all the pages of the total are in, it is published whole and
## replaces the previous one. Meanwhile the last complete scoreboard stays visible, so the list neither
## flickers nor stays half-filled.

## How many complete scoreboards have been published.
var version: int = 0

var _rows: Array[NetMessages.ScoreRow] = []
var _pending: Dictionary[int, Array] = {}
var _pending_count: int = 0
var _pages_received: int = 0
var _updated_at_msec: int = 0


## Records a page. Returns true if with it the scoreboard is complete and published.
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


## Rows of the last complete scoreboard, in the server's order.
func get_rows() -> Array[NetMessages.ScoreRow]:
	return _rows.duplicate()


## Row of player [param net_id] (null if absent).
func get_row(net_id: int) -> NetMessages.ScoreRow:
	for row: NetMessages.ScoreRow in _rows:
		if row.net_id == net_id:
			return row
	return null


## Number of rows of the last complete scoreboard.
func get_row_count() -> int:
	return _rows.size()


## Pages received since it was created.
func get_pages_received() -> int:
	return _pages_received


## Pages missing to complete the scoreboard being assembled (0 if none is half-built).
func get_pending_pages() -> int:
	return maxi(_pending_count - _pending.size(), 0) if not _pending.is_empty() else 0


## Sorts [param rows] for display: most kills first, then fewest deaths, most assists and, lastly, the id
## so that the order is stable.
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
