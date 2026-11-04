class_name CommandRegistry
extends RefCounted
## Single registry of the server's admin commands (docs/combate.md, section 6;
## TEC-19): those that arrive over the network in a DEBUG_COMMAND and those from the standard input
## console. CMB-11, GUE-08, PRG-16 and SOC-14 register theirs here.
## [br][br]
## [b]Network commands.[/b] They only work with [code]--debug-commands[/code] (checked by the caller)
## and act on the player who sends them. Each has a fixed id in
## [constant NetProtocol.DEBUG_COMMAND_IDS]: [method register] refuses to register a network
## command whose name is not in that table, and [method missing_network_commands] lists those in the table
## that nobody has registered.
## [br][br]
## [b]Console commands.[/b] They are typed on the server's standard input
## ([code]--console[/code]) with their arguments ([code]kick Ana[/code]). The network ones also exist in
## the console, with the player as the first argument. [code]announce[/code], [code]kick[/code] and
## [code]shutdown <s>[/code] are console commands and, with the platform, [code]/gm[/code] commands with their role.
## [br][br]
## [b]Chat commands[/b] ([code]/gm …[/code], docs/plataforma.md §9.1, P7b). With the platform, a player with a
## role types [code]/gm command arguments[/code] and it arrives here via [method execute_chat] with the role of their
## claim: the console handler runs, with the sending peer in the [Context]. Without permission, or a
## command that does not exist, it answers [constant TEXT_UNKNOWN], the same as to someone with no role: it does not reveal what
## exists.
## [br][br]
## [b]Minimum role.[/b] Each command declares its [code]min_role[/code] on registering ([constant ROLE_GM] by default):
## [method execute_chat] requires it and, with the platform, so does [method execute_network] (DEBUG_COMMAND with the role of the
## claim; without it, [constant Result.FORBIDDEN], which the zone counts as a warning). The console does not check it: it is
## the server operator. Without the platform (empty role) DEBUG_COMMANDs continue as in phase 4.
## [br][br]
## [b]Audit.[/b] Every use, accepted or not, is kept in [member audit] and sent to
## [member audit_sink] (the server's log): origin, command, arguments and result. With the platform,
## each use that actually gets executed (not unknown ones or those without permission) also goes out through
## [member audit_entry_sink], which builds the audit batch entry (docs/plataforma.md §9.1).

## Result of a network command.
enum Result {
	OK,
	## The id does not correspond to any registered command.
	UNKNOWN,
	## The command's data is not valid (the server adds a warning to the peer).
	BAD_ARGUMENTS,
	## The command is valid but cannot be fulfilled now (no warning).
	REFUSED,
	## With the platform, the role of whoever sends it does not reach the command's [code]min_role[/code]: it is not executed
	## (the zone adds a warning, as without [code]--debug-commands[/code]).
	FORBIDDEN,
}

## Where a command comes from.
enum Origin {
	## The server console (the operator: the role is not checked).
	CONSOLE,
	## [code]/gm …[/code] through chat, with the claim's role.
	CHAT,
	## A DEBUG_COMMAND.
	NETWORK,
}

## Account roles (docs/plataforma.md §9.1), lowest to highest; the same as
## [constant ClaimedCharacter.ROLES].
const ROLE_PLAYER: StringName = &"player"
const ROLE_MODERATOR: StringName = &"moderator"
const ROLE_GM: StringName = &"gm"
const ROLE_ADMIN: StringName = &"admin"
const ROLES: Array[StringName] = [ROLE_PLAYER, ROLE_MODERATOR, ROLE_GM, ROLE_ADMIN]
## Minimum role of a command that declares no other.
const DEFAULT_MIN_ROLE: StringName = ROLE_GM
## Reply to an unknown chat command or one without permission (docs/social.md, section 4).
const TEXT_UNKNOWN: String = "Comando desconocido. Escribe /ayuda."
const TEXT_CHAT_HELP: String = "Comandos de /gm: %s. Escribe /gm ayuda <comando> para ver cómo se usa."

## Audit log entries that are kept.
const MAX_AUDIT_ENTRIES: int = 200

## Latest use of each command, oldest to newest (the last [constant MAX_AUDIT_ENTRIES]).
var audit: PackedStringArray = PackedStringArray()
## Total audited uses.
var audit_total: int = 0
## Called with each audit line, [code](line: String) -> void[/code].
var audit_sink: Callable = Callable()
## With the platform: called with each use that actually gets executed,
## [code](ctx: CommandRegistry.Context, command_name: StringName, result: String) -> void[/code]; the zone uses
## it to build the audit batch entry.
var audit_entry_sink: Callable = Callable()

# name -> Command.
var _commands: Dictionary[StringName, Command] = {}


## A registered command.
class Command:
	var name: StringName = &""
	var usage: String = ""
	## [code](ctx: CommandRegistry.Context) -> String]: the console; returns the reply text.
	var console_handler: Callable = Callable()
	## [code](ctx: CommandRegistry.Context) -> int]: the network; returns a [enum Result].
	var network_handler: Callable = Callable()
	## Minimum role to use it through chat ([code]/gm[/code]) or, with the platform, through DEBUG_COMMAND.
	var min_role: StringName = DEFAULT_MIN_ROLE
	## Minimum role through DEBUG_COMMAND with the platform if different (empty: [member min_role]). Those that create or keep
	## value of the character itself ask for [code]admin[/code] over the network even though through [code]/gm[/code]
	## [code]gm[/code] is enough (progresion.md §10).
	var network_min_role: StringName = &""


## What a handler receives.
class Context:
	## Who sends it, in the audit log ([code]peer 3 (Ana, net_id 2)[/code] or
	## [code]consola[/code]).
	var source: String = ""
	## The peer that sends it (null in the console).
	var peer: ServerPeer = null
	## Network command data (after the id).
	var payload: PackedByteArray = PackedByteArray()
	## Console arguments (without the name).
	var args: PackedStringArray = PackedStringArray()
	## Text the handler adds to the audit (the result).
	var note: String = ""
	## Where it comes from ([enum Origin]).
	var origin: int = Origin.CONSOLE
	## The role of whoever sends it (empty in the console, and on the network without the platform).
	var role: StringName = &""
	## The character it acts on, if the handler has resolved it (for the audit: the target goes by id,
	## never by name).
	var target: NetEntity = null
	## Arguments for the audit batch entry, without names or emails (docs/plataforma.md §9.1).
	var audit_args: Dictionary = {}
	## The [code]key[/code] of that entry if the command sets it: [code]op:<op_id>[/code] on one that creates an operation
	## (§9.1, "Two paths, one row"; progresion.md P5d). Empty: [ZonePlatform] sets it.
	var audit_key: String = ""
	## The Unix time of that entry if the command sets it: the [code]detail.at_unix[/code] of the operation it creates, so
	## that the entry and the save row (S8) carry the same one (progresion.md P5d). 0: the current one.
	var audit_at_unix: int = 0
	## true if the batch entry is built by the command later (the [code]op_revert[/code] with the platform: its
	## REVERSAL, with its [code]op:<op_id>[/code], is created when the platform's reply arrives; progresion.md P5d).
	var audit_deferred: bool = false


## Registers the command [param command_name]. [param console_handler] serves the console (and [code]/gm[/code]) and
## [param network_handler] (optional) the network; the latter requires the name to have its fixed id in
## [constant NetProtocol.DEBUG_COMMAND_IDS]. [param min_role] is the minimum role for chat and, with the platform,
## for the network; [param network_min_role], if not empty, the network's (progresion.md P5d: 40–43 and 16 require
## [code]admin[/code] through DEBUG_COMMAND and [code]gm[/code] through [code]/gm[/code]). Returns false (and logs an
## error) if the name already exists, it has no handler, it is a network command without a fixed id or the role does not exist.
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


## The rank of [param role] in [constant ROLES] (player 0 … admin 3); an unknown one, -1.
static func role_rank(role: StringName) -> int:
	return ROLES.find(role)


## true if [param role] reaches [param min_role].
static func role_allows(role: StringName, min_role: StringName) -> bool:
	var needed: int = role_rank(min_role)
	return needed >= 0 and role_rank(role) >= needed


## The command's minimum role (empty if it does not exist).
func get_min_role(command_name: StringName) -> StringName:
	var command: Command = _commands.get(command_name)
	return command.min_role if command != null else &""


## The command's minimum role through DEBUG_COMMAND with the platform (empty if it does not exist).
func get_network_min_role(command_name: StringName) -> StringName:
	var command: Command = _commands.get(command_name)
	if command == null:
		return &""
	return command.network_min_role if not command.network_min_role.is_empty() else command.min_role


## true if whoever has [param role] can use [param command_name] through chat ([code]/gm[/code]).
func can_use(command_name: StringName, role: StringName) -> bool:
	var command: Command = _commands.get(command_name)
	return command != null and command.console_handler.is_valid() and role_allows(role, command.min_role)


## The commands [param role] can use through chat, sorted.
func get_names_for(role: StringName) -> PackedStringArray:
	var names := PackedStringArray()
	for command_name: StringName in _commands:
		if can_use(command_name, role):
			names.append(String(command_name))
	names.sort()
	return names


## true if there is a command with that name.
func has_command(command_name: StringName) -> bool:
	return _commands.has(command_name)


## Names of all registered commands, sorted.
func get_names() -> PackedStringArray:
	var names := PackedStringArray()
	for command_name: StringName in _commands:
		names.append(String(command_name))
	names.sort()
	return names


## Names of the commands in [constant NetProtocol.DEBUG_COMMAND_IDS] that have no network
## handler.
func missing_network_commands() -> PackedStringArray:
	var missing := PackedStringArray()
	for command_name: StringName in NetProtocol.DEBUG_COMMAND_IDS:
		var command: Command = _commands.get(command_name)
		if command == null or not command.network_handler.is_valid():
			missing.append(String(command_name))
	missing.sort()
	return missing


## Executes the network command with id [param command_id] sent by [param peer] with the data
## [param payload]. With [param role] (the platform: the claim's), the command requires its
## [code]min_role[/code]; without it [constant Result.FORBIDDEN] is returned and it is not executed. Empty, as without
## the platform: not checked. Returns a [enum Result]. It is audited.
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


## Executes [param line] ([code]command arguments…[/code], what follows [code]/gm[/code]) sent by
## [param peer] with role [param role] (that of its claim) and returns the reply for its chat. A command
## that does not exist, has no console handler or whose role does not reach it answers [constant TEXT_UNKNOWN];
## [code]ayuda[/code] lists those it can use (or explains one), and to someone who can use none it answers the same
## as to an unknown one. It is audited (unknown ones and those without permission, only in the log).
func execute_chat(peer: ServerPeer, line: String, role: StringName) -> String:
	var source: String = "/gm " + _peer_source(peer)
	var text: String = line.strip_edges()
	var parts: PackedStringArray = text.split(" ", false, 1)
	# Ignoring case and accents (docs/social.md, section 4).
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


## Executes a console line ([code]command argument argument...[/code], with an optional leading
## slash) and returns the reply text. It is audited.
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


## Usage of a command ([code]usage[/code] when registering it), or an empty string if it does not exist.
func get_usage(command_name: StringName) -> String:
	var command: Command = _commands.get(command_name)
	return command.usage if command != null else ""


# Who sends a command, for the audit: [code]peer 3 (Ana, net_id 2)[/code].
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
