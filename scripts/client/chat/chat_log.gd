class_name ChatLog
extends RefCounted
## Log of what is shown in chat (SOC-05): the last [constant MAX_LINES] lines, from all channels,
## with what is needed to draw and filter them per tab. It is data only: it does not touch the UI
## ([ChatBox] draws it) or the network.
## [br][br]
## A line is either a server message ([method add_message]) or a local text ([method add_text]):
## help, a command error or a server NOTICE, all shown in the system channel.

## A line was added.
signal line_added(line: Line)
## The oldest line was dropped because the limit was reached.
signal line_dropped
## The log was cleared.
signal cleared

## Maximum number of lines it keeps.
const MAX_LINES: int = 200


## A chat line.
class Line:
	extends RefCounted

	## [enum ChatChannel.Id].
	var channel: int = ChatChannel.Id.SYSTEM
	## Sender name (empty for the system).
	var sender: String = ""
	## Sender's realm ([enum NetProtocol.Realm]).
	var sender_realm: int = NetProtocol.Realm.NONE
	## Recipient (whispers only).
	var recipient: String = ""
	## Text exactly as the server sent it. Never interpreted as BBCode when drawn.
	var text: String = ""
	## Server tick of the message (0 for a local text).
	var tick: int = 0
	## true if the sender is the local player.
	var own: bool = false

	## The other party of a whisper as seen by the local player: who they are writing to if it is theirs,
	## and who is writing to them if not. Empty if it is not a whisper.
	func whisper_partner() -> String:
		if channel != ChatChannel.Id.WHISPER:
			return ""
		return recipient if own else sender


var _lines: Array[Line] = []


## Adds the server message [param message]. [param own_name] is the local player's name (used to
## mark their own messages, which are compared by the [NameRules] key). Returns the line.
func add_message(message: NetMessages.ChatMessage, own_name: String) -> Line:
	var line := Line.new()
	line.channel = message.channel
	line.sender = message.sender
	line.sender_realm = message.sender_realm
	line.recipient = message.recipient
	line.text = message.text
	line.tick = message.tick
	line.own = not own_name.is_empty() \
			and NameRules.normalize_key(message.sender) == NameRules.normalize_key(own_name)
	return _append(line)


## Adds a local text in channel [param channel] (the system channel by default). Returns the line.
func add_text(text: String, channel: int = ChatChannel.Id.SYSTEM) -> Line:
	var line := Line.new()
	line.channel = channel
	line.text = text
	return _append(line)


## All lines, from oldest to newest (a copy).
func get_lines() -> Array[Line]:
	return _lines.duplicate()


## The lines whose channel is in [param channels]; with an empty list, all of them.
func get_filtered(channels: Array[int]) -> Array[Line]:
	if channels.is_empty():
		return get_lines()
	var result: Array[Line] = []
	for line: Line in _lines:
		if channels.has(line.channel):
			result.append(line)
	return result


func get_count() -> int:
	return _lines.size()


## Clears the log.
func clear() -> void:
	_lines.clear()
	cleared.emit()


func _append(line: Line) -> Line:
	_lines.append(line)
	if _lines.size() > MAX_LINES:
		_lines.pop_front()
		line_dropped.emit()
	line_added.emit(line)
	return line
