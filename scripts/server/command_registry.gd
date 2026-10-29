class_name CommandRegistry
extends RefCounted
## Registro único de los comandos de administración del servidor (docs/combate.md, sección 6;
## TEC-19): los que llegan por la red en un DEBUG_COMMAND y los de la consola de la entrada
## estándar. CMB-11, GUE-08, PRG-16 y SOC-14 registran aquí los suyos.
## [br][br]
## [b]Comandos de red.[/b] Solo funcionan con [code]--debug-commands[/code] (lo comprueba quien llama)
## y actúan sobre el jugador que los envía. Cada uno tiene un id fijo en
## [constant NetProtocol.DEBUG_COMMAND_IDS]: [method register] se niega a registrar un comando de
## red cuyo nombre no esté en esa tabla, y [method missing_network_commands] lista los de la tabla
## que nadie ha registrado.
## [br][br]
## [b]Comandos de consola.[/b] Se escriben por la entrada estándar del servidor
## ([code]--console[/code]) con sus argumentos ([code]kick Ana[/code]). Los de red también existen en
## la consola, con el jugador como primer argumento. [code]announce[/code], [code]kick[/code] y
## [code]shutdown <s>[/code] son solo de consola hasta los roles de GM (TEC-23).
## [br][br]
## [b]Auditoría.[/b] Cada uso, aceptado o no, queda en [member audit] y se manda a
## [member audit_sink] (el registro del servidor): origen, comando, argumentos y resultado.

## Resultado de un comando de red.
enum Result {
	OK,
	## El id no corresponde a ningún comando registrado.
	UNKNOWN,
	## Los datos del comando no son válidos (el servidor suma un aviso al peer).
	BAD_ARGUMENTS,
	## El comando es válido pero no se puede cumplir ahora (sin aviso).
	REFUSED,
}

## Entradas del registro de auditoría que se conservan.
const MAX_AUDIT_ENTRIES: int = 200

## Último uso de cada comando, de más antiguo a más reciente (las últimas [constant MAX_AUDIT_ENTRIES]).
var audit: PackedStringArray = PackedStringArray()
## Usos totales auditados.
var audit_total: int = 0
## Se llama con cada línea de auditoría, [code](line: String) -> void[/code].
var audit_sink: Callable = Callable()

# nombre -> Command.
var _commands: Dictionary[StringName, Command] = {}


## Un comando registrado.
class Command:
	var name: StringName = &""
	var usage: String = ""
	## [code](ctx: CommandRegistry.Context) -> String]: la consola; devuelve el texto de respuesta.
	var console_handler: Callable = Callable()
	## [code](ctx: CommandRegistry.Context) -> int]: la red; devuelve un [enum Result].
	var network_handler: Callable = Callable()


## Lo que recibe un manejador.
class Context:
	## Quién lo envía en el registro de auditoría ([code]peer 3 (Ana, net_id 2)[/code] o
	## [code]consola[/code]).
	var source: String = ""
	## El peer que lo envía (null en la consola).
	var peer: ServerPeer = null
	## Datos del comando de red (después del id).
	var payload: PackedByteArray = PackedByteArray()
	## Argumentos de la consola (sin el nombre).
	var args: PackedStringArray = PackedStringArray()
	## Texto que el manejador añade a la auditoría (el resultado).
	var note: String = ""


## Registra el comando [param command_name]. [param console_handler] atiende la consola y
## [param network_handler] (opcional) la red; este último exige que el nombre tenga su id fijo en
## [constant NetProtocol.DEBUG_COMMAND_IDS]. Devuelve false (y registra un error) si el nombre ya
## existe, no tiene ningún manejador o es de red sin id fijo.
func register(command_name: StringName, usage: String, console_handler: Callable,
		network_handler: Callable = Callable()) -> bool:
	if _commands.has(command_name):
		push_error("[Eldmark] Comando duplicado: '%s'" % command_name)
		return false
	if not console_handler.is_valid() and not network_handler.is_valid():
		push_error("[Eldmark] Comando sin manejador: '%s'" % command_name)
		return false
	if network_handler.is_valid() and not NetProtocol.DEBUG_COMMAND_IDS.has(command_name):
		push_error("[Eldmark] El comando de red '%s' no tiene un id fijo en NetProtocol" % command_name)
		return false
	var command := Command.new()
	command.name = command_name
	command.usage = usage
	command.console_handler = console_handler
	command.network_handler = network_handler
	_commands[command_name] = command
	return true


## true si hay un comando con ese nombre.
func has_command(command_name: StringName) -> bool:
	return _commands.has(command_name)


## Nombres de todos los comandos registrados, ordenados.
func get_names() -> PackedStringArray:
	var names := PackedStringArray()
	for command_name: StringName in _commands:
		names.append(String(command_name))
	names.sort()
	return names


## Nombres de los comandos de [constant NetProtocol.DEBUG_COMMAND_IDS] que no tienen manejador de
## red.
func missing_network_commands() -> PackedStringArray:
	var missing := PackedStringArray()
	for command_name: StringName in NetProtocol.DEBUG_COMMAND_IDS:
		var command: Command = _commands.get(command_name)
		if command == null or not command.network_handler.is_valid():
			missing.append(String(command_name))
	missing.sort()
	return missing


## Ejecuta el comando de red con id [param command_id] enviado por [param peer] con los datos
## [param payload]. Devuelve un [enum Result]. Queda auditado.
func execute_network(peer: ServerPeer, command_id: int, payload: PackedByteArray) -> int:
	var command: Command = _find_by_network_id(command_id)
	var source: String = "peer %d (%s)" % [peer.peer_id, peer.display_name]
	if peer.entity != null:
		source = "peer %d (%s, net_id %d)" % [peer.peer_id, peer.display_name, peer.entity.net_id]
	if command == null or not command.network_handler.is_valid():
		_audit(source, "id %d" % command_id, "desconocido")
		return Result.UNKNOWN
	var context := Context.new()
	context.source = source
	context.peer = peer
	context.payload = payload
	var result: int = command.network_handler.call(context)
	_audit(source, String(command.name) if payload.is_empty() else "%s [%d B]" % [command.name,
			payload.size()], _result_text(result, context.note))
	return result


## Ejecuta una línea de la consola ([code]comando argumento argumento...[/code], con una barra
## inicial opcional) y devuelve el texto de respuesta. Queda auditada.
func execute_console(line: String) -> String:
	var text: String = line.strip_edges()
	if text.begins_with("/"):
		text = text.substr(1)
	if text.is_empty():
		return ""
	var parts: PackedStringArray = text.split(" ", false, 1)
	var command_name := StringName(parts[0].to_lower())
	var arguments := PackedStringArray()
	if parts.size() > 1:
		arguments = parts[1].strip_edges().split(" ", false)
	if command_name == &"help":
		var listing: String = "Comandos: " + ", ".join(get_names())
		_audit("consola", "help", "")
		return listing
	var command: Command = _commands.get(command_name)
	if command == null or not command.console_handler.is_valid():
		var unknown: String = "Comando desconocido: %s (escribe help)" % parts[0]
		_audit("consola", text, "desconocido")
		return unknown
	var context := Context.new()
	context.source = "consola"
	context.args = arguments
	var response: String = command.console_handler.call(context)
	_audit("consola", text, response if context.note.is_empty() else context.note)
	return response


## Uso de un comando ([code]usage[/code] al registrarlo), o una cadena vacía si no existe.
func get_usage(command_name: StringName) -> String:
	var command: Command = _commands.get(command_name)
	return command.usage if command != null else ""


func _find_by_network_id(command_id: int) -> Command:
	for command_name: StringName in NetProtocol.DEBUG_COMMAND_IDS:
		if NetProtocol.DEBUG_COMMAND_IDS[command_name] == command_id:
			return _commands.get(command_name)
	return null


static func _result_text(result: int, note: String) -> String:
	var text: String = "ok"
	match result:
		Result.UNKNOWN:
			text = "desconocido"
		Result.BAD_ARGUMENTS:
			text = "argumentos no válidos"
		Result.REFUSED:
			text = "rechazado"
	return text if note.is_empty() else "%s (%s)" % [text, note]


func _audit(source: String, what: String, result: String) -> void:
	var line: String = "[auditoría] %s: %s" % [source, what]
	if not result.is_empty():
		line += " -> %s" % result
	audit.append(line)
	audit_total += 1
	while audit.size() > MAX_AUDIT_ENTRIES:
		audit.remove_at(0)
	if audit_sink.is_valid():
		audit_sink.call(line)
