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
## [code]shutdown <s>[/code] son de consola y, con la plataforma, de [code]/gm[/code] con su rol.
## [br][br]
## [b]Comandos de chat[/b] ([code]/gm …[/code], docs/plataforma.md §9.1, P7b). Con la plataforma, un jugador con
## rol escribe [code]/gm comando argumentos[/code] y llega aquí por [method execute_chat] con el rol de su
## reclamación: se ejecuta el manejador de consola, con el peer que lo manda en el [Context]. Sin permiso, o un
## comando que no existe, contesta [constant TEXT_UNKNOWN], lo mismo que a quien no tiene rol: no se revela qué
## existe.
## [br][br]
## [b]Rol mínimo.[/b] Cada comando declara su [code]min_role[/code] al registrarse ([constant ROLE_GM] por defecto):
## lo exigen [method execute_chat] y, con la plataforma, [method execute_network] (DEBUG_COMMAND con el rol de la
## reclamación; sin él, [constant Result.FORBIDDEN], que la zona cuenta como un aviso). La consola no lo mira: es
## el operador del servidor. Sin plataforma (rol vacío) los DEBUG_COMMAND siguen como en la fase 4.
## [br][br]
## [b]Auditoría.[/b] Cada uso, aceptado o no, queda en [member audit] y se manda a
## [member audit_sink] (el registro del servidor): origen, comando, argumentos y resultado. Con la plataforma,
## cada uso que llega a ejecutarse (no los desconocidos ni los que no tienen permiso) sale además por
## [member audit_entry_sink], que arma la entrada del lote de auditoría (docs/plataforma.md §9.1).

## Resultado de un comando de red.
enum Result {
	OK,
	## El id no corresponde a ningún comando registrado.
	UNKNOWN,
	## Los datos del comando no son válidos (el servidor suma un aviso al peer).
	BAD_ARGUMENTS,
	## El comando es válido pero no se puede cumplir ahora (sin aviso).
	REFUSED,
	## Con la plataforma, el rol de quien lo manda no llega al [code]min_role[/code] del comando: no se ejecuta
	## (la zona suma un aviso, como sin [code]--debug-commands[/code]).
	FORBIDDEN,
}

## Por dónde llega un comando.
enum Origin {
	## La consola del servidor (el operador: no se mira el rol).
	CONSOLE,
	## [code]/gm …[/code] por el chat, con el rol de la reclamación.
	CHAT,
	## Un DEBUG_COMMAND.
	NETWORK,
}

## Roles de las cuentas (docs/plataforma.md §9.1), de menor a mayor; los mismos que
## [constant ClaimedCharacter.ROLES].
const ROLE_PLAYER: StringName = &"player"
const ROLE_MODERATOR: StringName = &"moderator"
const ROLE_GM: StringName = &"gm"
const ROLE_ADMIN: StringName = &"admin"
const ROLES: Array[StringName] = [ROLE_PLAYER, ROLE_MODERATOR, ROLE_GM, ROLE_ADMIN]
## Rol mínimo de un comando que no declara otro.
const DEFAULT_MIN_ROLE: StringName = ROLE_GM
## Respuesta a un comando de chat desconocido o sin permiso (docs/social.md, sección 4).
const TEXT_UNKNOWN: String = "Comando desconocido. Escribe /ayuda."
const TEXT_CHAT_HELP: String = "Comandos de /gm: %s. Escribe /gm ayuda <comando> para ver cómo se usa."

## Entradas del registro de auditoría que se conservan.
const MAX_AUDIT_ENTRIES: int = 200

## Último uso de cada comando, de más antiguo a más reciente (las últimas [constant MAX_AUDIT_ENTRIES]).
var audit: PackedStringArray = PackedStringArray()
## Usos totales auditados.
var audit_total: int = 0
## Se llama con cada línea de auditoría, [code](line: String) -> void[/code].
var audit_sink: Callable = Callable()
## Con la plataforma: se llama con cada uso que llega a ejecutarse,
## [code](ctx: CommandRegistry.Context, command_name: StringName, result: String) -> void[/code]; la zona arma
## con él la entrada del lote de auditoría.
var audit_entry_sink: Callable = Callable()

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
	## Rol mínimo para usarlo por el chat ([code]/gm[/code]) o, con la plataforma, por DEBUG_COMMAND.
	var min_role: StringName = DEFAULT_MIN_ROLE
	## Rol mínimo por DEBUG_COMMAND con la plataforma si es otro (vacío: [member min_role]). Los que crean o conservan
	## valor del propio personaje piden [code]admin[/code] por la red aunque por [code]/gm[/code] baste
	## [code]gm[/code] (progresion.md §10).
	var network_min_role: StringName = &""


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
	## Por dónde llega ([enum Origin]).
	var origin: int = Origin.CONSOLE
	## El rol de quien lo manda (vacío en la consola, y en la red sin plataforma).
	var role: StringName = &""
	## El personaje sobre el que actúa, si el manejador lo ha resuelto (para la auditoría: el objetivo va por id,
	## nunca por nombre).
	var target: NetEntity = null
	## Argumentos para la entrada del lote de auditoría, sin nombres ni correos (docs/plataforma.md §9.1).
	var audit_args: Dictionary = {}
	## La [code]key[/code] de esa entrada si el comando la fija: [code]op:<op_id>[/code] en uno que crea una operación
	## (§9.1, «Dos vías, una fila»; progresion.md P5d). Vacía: la pone [ZonePlatform].
	var audit_key: String = ""
	## La hora Unix de esa entrada si el comando la fija: el [code]detail.at_unix[/code] de la operación que crea, para
	## que la entrada y la fila del guardado (S8) lleven la misma (progresion.md P5d). 0: la de ahora.
	var audit_at_unix: int = 0
	## true si la entrada del lote la arma el comando más tarde (el [code]op_revert[/code] con plataforma: su
	## REVERSAL, con su [code]op:<op_id>[/code], se crea al llegar la respuesta de la plataforma; progresion.md P5d).
	var audit_deferred: bool = false


## Registra el comando [param command_name]. [param console_handler] atiende la consola (y [code]/gm[/code]) y
## [param network_handler] (opcional) la red; este último exige que el nombre tenga su id fijo en
## [constant NetProtocol.DEBUG_COMMAND_IDS]. [param min_role] es el rol mínimo para el chat y, con la plataforma,
## para la red; [param network_min_role], si no está vacío, el de la red (progresion.md P5d: los 40–43 y el 16 piden
## [code]admin[/code] por DEBUG_COMMAND y [code]gm[/code] por [code]/gm[/code]). Devuelve false (y registra un
## error) si el nombre ya existe, no tiene ningún manejador, es de red sin id fijo o el rol no existe.
func register(command_name: StringName, usage: String, console_handler: Callable,
		network_handler: Callable = Callable(), min_role: StringName = DEFAULT_MIN_ROLE,
		network_min_role: StringName = &"") -> bool:
	if _commands.has(command_name):
		push_error("[Eldmark] Comando duplicado: '%s'" % command_name)
		return false
	if not console_handler.is_valid() and not network_handler.is_valid():
		push_error("[Eldmark] Comando sin manejador: '%s'" % command_name)
		return false
	if network_handler.is_valid() and not NetProtocol.DEBUG_COMMAND_IDS.has(command_name):
		push_error("[Eldmark] El comando de red '%s' no tiene un id fijo en NetProtocol" % command_name)
		return false
	if role_rank(min_role) < 0 or (not network_min_role.is_empty() and role_rank(network_min_role) < 0):
		push_error("[Eldmark] Rol desconocido para '%s': %s" % [command_name, min_role])
		return false
	var command := Command.new()
	command.name = command_name
	command.usage = usage
	command.console_handler = console_handler
	command.network_handler = network_handler
	command.min_role = min_role
	command.network_min_role = network_min_role
	_commands[command_name] = command
	return true


## El rango de [param role] en [constant ROLES] (player 0 … admin 3); uno desconocido, -1.
static func role_rank(role: StringName) -> int:
	return ROLES.find(role)


## true si [param role] llega a [param min_role].
static func role_allows(role: StringName, min_role: StringName) -> bool:
	var needed: int = role_rank(min_role)
	return needed >= 0 and role_rank(role) >= needed


## El rol mínimo del comando (vacío si no existe).
func get_min_role(command_name: StringName) -> StringName:
	var command: Command = _commands.get(command_name)
	return command.min_role if command != null else &""


## El rol mínimo del comando por DEBUG_COMMAND con la plataforma (vacío si no existe).
func get_network_min_role(command_name: StringName) -> StringName:
	var command: Command = _commands.get(command_name)
	if command == null:
		return &""
	return command.network_min_role if not command.network_min_role.is_empty() else command.min_role


## true si quien tiene [param role] puede usar [param command_name] por el chat ([code]/gm[/code]).
func can_use(command_name: StringName, role: StringName) -> bool:
	var command: Command = _commands.get(command_name)
	return command != null and command.console_handler.is_valid() and role_allows(role, command.min_role)


## Los comandos que [param role] puede usar por el chat, ordenados.
func get_names_for(role: StringName) -> PackedStringArray:
	var names := PackedStringArray()
	for command_name: StringName in _commands:
		if can_use(command_name, role):
			names.append(String(command_name))
	names.sort()
	return names


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
## [param payload]. Con [param role] (la plataforma: el de la reclamación), el comando exige su
## [code]min_role[/code]; sin él se devuelve [constant Result.FORBIDDEN] y no se ejecuta. Vacío, como sin
## plataforma: no se mira. Devuelve un [enum Result]. Queda auditado.
func execute_network(peer: ServerPeer, command_id: int, payload: PackedByteArray,
		role: StringName = &"") -> int:
	var command: Command = _find_by_network_id(command_id)
	var source: String = _peer_source(peer)
	if command == null or not command.network_handler.is_valid():
		_audit(source, "id %d" % command_id, "desconocido")
		return Result.UNKNOWN
	var what: String = String(command.name) if payload.is_empty() else "%s [%d B]" % [command.name, payload.size()]
	var needed: StringName = get_network_min_role(command.name)
	if not role.is_empty() and not role_allows(role, needed):
		_audit(source, what, "sin permiso (%s; hace falta %s)" % [role, needed])
		return Result.FORBIDDEN
	var context := Context.new()
	context.source = source
	context.peer = peer
	context.payload = payload
	context.origin = Origin.NETWORK
	context.role = role
	var result: int = command.network_handler.call(context)
	var result_text: String = _result_text(result, context.note)
	_audit(source, what, result_text)
	_audit_entry(context, command.name, result_text)
	return result


## Ejecuta [param line] ([code]comando argumentos…[/code], lo que sigue a [code]/gm[/code]) que manda
## [param peer] con el rol [param role] (el de su reclamación) y devuelve la respuesta para su chat. Un comando
## que no existe, que no tiene manejador de consola o al que no llega su rol contesta [constant TEXT_UNKNOWN];
## [code]ayuda[/code] lista los que puede usar (o explica uno), y a quien no puede usar ninguno le contesta lo mismo
## que a un desconocido. Queda auditado (los desconocidos y los que no tienen permiso, solo en el registro).
func execute_chat(peer: ServerPeer, line: String, role: StringName) -> String:
	var source: String = "/gm " + _peer_source(peer)
	var text: String = line.strip_edges()
	var parts: PackedStringArray = text.split(" ", false, 1)
	# Sin distinguir mayúsculas ni tildes (docs/social.md, sección 4).
	var command_name := StringName(NameRules.normalize_key(parts[0])) if not parts.is_empty() else &""
	var arguments := PackedStringArray()
	if parts.size() > 1:
		arguments = parts[1].strip_edges().split(" ", false)
	var allowed: PackedStringArray = get_names_for(role)
	if command_name.is_empty() or command_name == &"ayuda" or command_name == &"help":
		if allowed.is_empty():
			_audit(source, text, "desconocido")
			return TEXT_UNKNOWN
		var topic := StringName(NameRules.normalize_key(arguments[0])) if not arguments.is_empty() else &""
		if can_use(topic, role):
			return "Uso: /gm %s" % get_usage(topic)
		return TEXT_CHAT_HELP % ", ".join(allowed)
	if not can_use(command_name, role):
		_audit(source, text, "desconocido" if not _commands.has(command_name) else "sin permiso (%s)" % role)
		return TEXT_UNKNOWN
	var command: Command = _commands[command_name]
	var context := Context.new()
	context.source = source
	context.peer = peer
	context.args = arguments
	context.origin = Origin.CHAT
	context.role = role
	var response: String = command.console_handler.call(context)
	var result_text: String = response if context.note.is_empty() else context.note
	_audit(source, text, result_text)
	_audit_entry(context, command.name, result_text)
	return response


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
	context.origin = Origin.CONSOLE
	var response: String = command.console_handler.call(context)
	var result_text: String = response if context.note.is_empty() else context.note
	_audit("consola", text, result_text)
	_audit_entry(context, command.name, result_text)
	return response


## Uso de un comando ([code]usage[/code] al registrarlo), o una cadena vacía si no existe.
func get_usage(command_name: StringName) -> String:
	var command: Command = _commands.get(command_name)
	return command.usage if command != null else ""


# Quién manda un comando, para la auditoría: [code]peer 3 (Ana, net_id 2)[/code].
static func _peer_source(peer: ServerPeer) -> String:
	if peer.entity != null:
		return "peer %d (%s, net_id %d)" % [peer.peer_id, peer.display_name, peer.entity.net_id]
	return "peer %d (%s)" % [peer.peer_id, peer.display_name]


func _audit_entry(context: Context, command_name: StringName, result_text: String) -> void:
	if audit_entry_sink.is_valid():
		audit_entry_sink.call(context, command_name, result_text)


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
		Result.FORBIDDEN:
			text = "sin permiso"
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
