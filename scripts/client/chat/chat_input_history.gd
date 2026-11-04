class_name ChatInputHistory
extends RefCounted
## History of what the player has typed on the chat line (SOC-05): up arrow walks through the sent
## lines from newest to oldest and down arrow goes back toward the one being typed (the draft). It is data only.

## Maximum lines it remembers.
const MAX_ENTRIES: int = 50

var _entries: PackedStringArray = PackedStringArray()
## Position in [member _entries] (-1 = the draft).
var _cursor: int = -1
var _draft: String = ""


## Remembers the sent line [param line] (ignored if empty or equal to the last one) and returns to the draft.
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


## Returns to the draft without remembering anything (when opening or closing the line).
func reset() -> void:
	_cursor = -1
	_draft = ""


## The line before the one shown. If one was being typed ([param current_text]), that is kept as
## the draft. Returns [param current_text] if there is no history.
func previous(current_text: String) -> String:
	if _entries.is_empty():
		return current_text
	if _cursor < 0:
		_draft = current_text
		_cursor = _entries.size() - 1
	else:
		_cursor = maxi(_cursor - 1, 0)
	return _entries[_cursor]


## The line after the one shown; after the newest, the draft. If one has not gone up first, it
## changes nothing ([param current_text]).
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
