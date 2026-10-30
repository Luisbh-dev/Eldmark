class_name FakeHttpServer
extends Node
## Un servidor HTTP/1.1 mínimo en el mismo proceso de las pruebas ([TCPServer] en 127.0.0.1), con respuestas y
## retrasos guionizados: así [PlatformClient] y [ZonePlatform] se prueban con [HTTPRequest] de verdad
## (docs/plataforma.md §15 P4, [code]test_platform_client.gd[/code]).
## [br][br]
## Cada petición se guarda ([member received]) y se contesta con la primera respuesta guionizada que casa
## ([method script]: método y principio de la ruta, una vez o [code]times[/code] veces) o, si ninguna casa, con
## [member handler] ([code](request: Received) -> Array[/code]: [code][status, body, delay_s][/code]); sin él, 404.
## El cuerpo puede ser un diccionario o una lista (se manda como JSON), un texto o unos bytes (tal cual) o null
## (vacío). Un retraso mayor que el plazo del cliente hace que este corte la conexión: la respuesta se descarta
## sin escribir en un socket cerrado. Contesta con [code]Connection: close[/code] y cierra.

## Una petición recibida.
class Received:
	extends RefCounted
	var method: String = ""
	## Ruta sin la consulta.
	var path: String = ""
	## Consulta (sin el «?»), tal cual.
	var query: String = ""
	## Cabeceras, con el nombre en minúsculas.
	var headers: Dictionary = {}
	var body: PackedByteArray = PackedByteArray()
	## Instante de llegada (ms de Time.get_ticks_msec()).
	var at_msec: int = 0

	## El cuerpo leído como JSON (null si está vacío o no es JSON).
	func json() -> Variant:
		if body.is_empty():
			return null
		var parser := JSON.new()
		if parser.parse(body.get_string_from_utf8()) != OK:
			return null
		return parser.data


## Una respuesta guionizada.
class Scripted:
	extends RefCounted
	var method: String = ""
	var path_prefix: String = ""
	var status: int = 200
	var body: Variant = null
	var delay_s: float = 0.0
	## Veces que queda (-1 = siempre).
	var times: int = 1


# Una conexión abierta: lo leído y, cuando ya hay petición, la respuesta y cuándo sale.
class _Connection:
	extends RefCounted
	var peer: StreamPeerTCP
	var buffer: PackedByteArray = PackedByteArray()
	var response: PackedByteArray = PackedByteArray()
	var due_msec: int = -1
	var done: bool = false


## Peticiones recibidas, en orden de llegada.
var received: Array[Received] = []
## Respuesta de lo que no está guionizado: [code](Received) -> [status, body, delay_s][/code].
var handler: Callable = Callable()

var _server: TCPServer = null
var _connections: Array[_Connection] = []
var _scripts: Array[Scripted] = []


## Escucha en 127.0.0.1, en un puerto libre que da el sistema. Devuelve el puerto, o -1.
func listen() -> int:
	_server = TCPServer.new()
	if _server.listen(0, "127.0.0.1") != OK:
		_server = null
		return -1
	return _server.get_local_port()


## La URL base ([code]http://127.0.0.1:<puerto>[/code]).
func base_url() -> String:
	return "http://127.0.0.1:%d" % (_server.get_local_port() if _server != null else 0)


## Guioniza la respuesta de las próximas [param times] peticiones con [param method] cuya ruta empieza por
## [param path_prefix] (-1 = todas).
func script(method: String, path_prefix: String, status: int, body: Variant = null, delay_s: float = 0.0,
		times: int = 1) -> void:
	var scripted := Scripted.new()
	scripted.method = method
	scripted.path_prefix = path_prefix
	scripted.status = status
	scripted.body = body
	scripted.delay_s = delay_s
	scripted.times = times
	_scripts.append(scripted)


## Las peticiones recibidas con [param method] (vacío = cualquiera) cuya ruta empieza por [param path_prefix].
func requests_to(method: String, path_prefix: String) -> Array[Received]:
	var found: Array[Received] = []
	for request: Received in received:
		if (method.is_empty() or request.method == method) and request.path.begins_with(path_prefix):
			found.append(request)
	return found


## Cierra todo.
func stop() -> void:
	for connection: _Connection in _connections:
		connection.peer.disconnect_from_host()
	_connections.clear()
	if _server != null:
		_server.stop()
		_server = null


func _exit_tree() -> void:
	stop()


func _process(_delta: float) -> void:
	if _server == null:
		return
	while _server.is_connection_available():
		var connection := _Connection.new()
		connection.peer = _server.take_connection()
		_connections.append(connection)
	var now: int = Time.get_ticks_msec()
	for connection: _Connection in _connections:
		connection.peer.poll()
		var status: int = connection.peer.get_status()
		if status != StreamPeerTCP.STATUS_CONNECTED:
			connection.done = true
			continue
		var available: int = connection.peer.get_available_bytes()
		if available > 0:
			var chunk: Array = connection.peer.get_partial_data(available)
			if int(chunk[0]) == OK:
				connection.buffer.append_array(chunk[1])
		if connection.due_msec < 0:
			_try_parse(connection, now)
		if connection.due_msec >= 0 and now >= connection.due_msec and not connection.done:
			connection.peer.put_data(connection.response)
			connection.peer.disconnect_from_host()
			connection.done = true
	_connections = _connections.filter(func(c: _Connection) -> bool: return not c.done)


# Si el búfer ya tiene una petición entera, la guarda y prepara su respuesta.
func _try_parse(connection: _Connection, now: int) -> void:
	var text_end: int = _find(connection.buffer, "\r\n\r\n".to_ascii_buffer())
	if text_end < 0:
		return
	var head: String = connection.buffer.slice(0, text_end).get_string_from_ascii()
	var lines: PackedStringArray = head.split("\r\n")
	var request_line: PackedStringArray = lines[0].split(" ")
	if request_line.size() < 2:
		connection.done = true
		return
	var request := Received.new()
	request.method = request_line[0]
	var target: String = request_line[1]
	var question: int = target.find("?")
	request.path = target if question < 0 else target.substr(0, question)
	request.query = "" if question < 0 else target.substr(question + 1)
	for i: int in range(1, lines.size()):
		var colon: int = lines[i].find(":")
		if colon > 0:
			var header: String = lines[i].substr(0, colon).strip_edges().to_lower()
			request.headers[header] = lines[i].substr(colon + 1).strip_edges()
	var length: int = int(String(request.headers.get("content-length", "0")))
	var body_start: int = text_end + 4
	if connection.buffer.size() < body_start + length:
		return
	request.body = connection.buffer.slice(body_start, body_start + length)
	request.at_msec = now
	received.append(request)
	var answer: Array = _answer(request)
	connection.response = _response_bytes(int(answer[0]), answer[1])
	connection.due_msec = now + int(float(answer[2]) * 1000.0)


func _answer(request: Received) -> Array:
	for i: int in _scripts.size():
		var scripted: Scripted = _scripts[i]
		if scripted.method == request.method and request.path.begins_with(scripted.path_prefix):
			if scripted.times > 0:
				scripted.times -= 1
				if scripted.times == 0:
					_scripts.remove_at(i)
			return [scripted.status, scripted.body, scripted.delay_s]
	if handler.is_valid():
		var answer: Array = handler.call(request)
		if answer.size() == 3:
			return answer
	return [404, {"error": {"code": "not_found", "message": "No existe"}}, 0.0]


static func _response_bytes(status: int, body: Variant) -> PackedByteArray:
	var payload := PackedByteArray()
	if body is PackedByteArray:
		payload = body
	elif body is String:
		payload = (body as String).to_utf8_buffer()
	elif body != null:
		payload = JSON.stringify(body).to_utf8_buffer()
	if status == 204:
		payload = PackedByteArray()
	var head: String = "HTTP/1.1 %d %s\r\nContent-Type: application/json\r\nContent-Length: %d\r\n" \
			% [status, _reason(status), payload.size()] + "Connection: close\r\n\r\n"
	var bytes: PackedByteArray = head.to_ascii_buffer()
	bytes.append_array(payload)
	return bytes


static func _reason(status: int) -> String:
	match status:
		200:
			return "OK"
		204:
			return "No Content"
		400:
			return "Bad Request"
		401:
			return "Unauthorized"
		403:
			return "Forbidden"
		404:
			return "Not Found"
		409:
			return "Conflict"
		503:
			return "Service Unavailable"
	return "Status"


static func _find(haystack: PackedByteArray, needle: PackedByteArray) -> int:
	var limit: int = haystack.size() - needle.size()
	for i: int in range(0, limit + 1):
		var found: bool = true
		for j: int in needle.size():
			if haystack[i + j] != needle[j]:
				found = false
				break
		if found:
			return i
	return -1
