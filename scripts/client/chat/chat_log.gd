class_name ChatLog
extends RefCounted
## Registro de lo que se ve en el chat (SOC-05): las últimas [constant MAX_LINES] líneas, de todos los
## canales, con lo necesario para pintarlas y filtrarlas por pestaña. Es solo datos: no toca la interfaz
## ([ChatBox] la pinta) ni la red.
## [br][br]
## Una línea es un mensaje del servidor ([method add_message]) o un texto local ([method add_text]): la
## ayuda, un error de un comando o un NOTICE del servidor, que se muestran en el canal del sistema.

## Se añadió una línea.
signal line_added(line: Line)
## Se descartó la línea más antigua por llegar al tope.
signal line_dropped
## Se vació el registro.
signal cleared

## Líneas como mucho que guarda.
const MAX_LINES: int = 200


## Una línea del chat.
class Line:
	extends RefCounted

	## [enum ChatChannel.Id].
	var channel: int = ChatChannel.Id.SYSTEM
	## Nombre del emisor (vacío en el sistema).
	var sender: String = ""
	## Reino del emisor ([enum NetProtocol.Realm]).
	var sender_realm: int = NetProtocol.Realm.NONE
	## Destinatario (solo en un susurro).
	var recipient: String = ""
	## Texto tal como lo mandó el servidor. Nunca se interpreta como BBCode al pintarlo.
	var text: String = ""
	## Tick del servidor del mensaje (0 en un texto local).
	var tick: int = 0
	## true si el emisor es el jugador local.
	var own: bool = false

	## El otro interlocutor de un susurro visto por el jugador local: a quién le escribe si es suyo y quién le
	## escribe si no. Vacío si no es un susurro.
	func whisper_partner() -> String:
		if channel != ChatChannel.Id.WHISPER:
			return ""
		return recipient if own else sender


var _lines: Array[Line] = []


## Añade el mensaje [param message] del servidor. [param own_name] es el nombre del jugador local (para
## marcar los mensajes propios, que comparan por la clave de [NameRules]). Devuelve la línea.
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


## Añade un texto local en el canal [param channel] (por defecto el del sistema). Devuelve la línea.
func add_text(text: String, channel: int = ChatChannel.Id.SYSTEM) -> Line:
	var line := Line.new()
	line.channel = channel
	line.text = text
	return _append(line)


## Todas las líneas, de la más antigua a la más nueva (una copia).
func get_lines() -> Array[Line]:
	return _lines.duplicate()


## Las líneas cuyo canal está en [param channels]; con la lista vacía, todas.
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


## Vacía el registro.
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
