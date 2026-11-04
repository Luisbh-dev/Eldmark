class_name ChatCommandParser
extends RefCounted
## Chat line parser (SOC-05, docs/social.md, section 4): decides whether what the player types is
## text for the active channel or a command in Spanish, and which one.
## [br][br]
## Commands start with [code]/[/code] and are recognized case- and accent-insensitively
## ([code]/Susurrar[/code], [code]/susurrar[/code] and [code]/SUSURRAR[/code] are equivalent; the
## key is that of [method NameRules.normalize_key]). A player's name, as an argument, has no quotes
## or spaces and is also case- and accent-insensitive (the server looks it up). It is pure: it
## touches neither the network nor the interface, so it is tested with text. It does not depend on the server.
## [br][br]
## [b]Phase 4 commands[/b] (the [constant COMMANDS] table is the only list; [code]/ayuda[/code] is
## generated from it):
## [br]- Channels: [code]/d[/code] [code]/decir[/code], [code]/z[/code] [code]/zona[/code],
## [code]/g[/code] [code]/grupo[/code]: with text they send it through that channel ([constant Kind.SEND]) and without text they leave it as the active channel ([constant Kind.SET_CHANNEL]).
## [br]- [code]/s nombre texto[/code] [code]/susurrar[/code]: whisper; without text it leaves the
## whisper to that name as the active channel; without a name, incorrect usage ([constant Kind.INVALID]).
## [br]- [code]/r texto[/code] [code]/responder[/code]: whisper to the last correspondent
## ([constant Kind.REPLY]; resolved by whoever holds the history: [ChatBox]).
## [br]- [code]/ayuda [comando][/code]: the list of commands or the detail of one ([constant Kind.HELP]).
## [br]- [code]/invitar nombre[/code], [code]/salir[/code], [code]/expulsar nombre[/code],
## [code]/lider nombre[/code]: parties (SOC-06 and SOC-08).
## [br]- Since phase 5 (docs/plataforma.md §9, P7b), those handled by the server ([constant Kind.SERVER]): [code]/ignorar nombre[/code], [code]/designorar nombre[/code] and [code]/reportar
## nombre categoría [comentario][/code], and [code]/gm …[/code], which does not appear in the help
## (only used by those with a role; to everyone else the server answers "Comando desconocido"
## (unknown command), without revealing that it exists). They are sent as is through the GM channel.
## [br][br]
## Any other command, even if it exists in docs/social.md for a future phase ([code]/b[/code],
## [code]/gr[/code], [code]/reino[/code]...), is [constant Kind.UNKNOWN] and is answered with
## [constant TEXT_UNKNOWN]: it does not reveal that it exists either.

enum Kind {
	## Empty line: there is nothing to do.
	EMPTY,
	## Text without a command: goes to the active channel.
	TEXT,
	## Text with a channel command: it is sent through that channel.
	SEND,
	## A channel command without text: the channel (and the recipient) become the active one.
	SET_CHANNEL,
	## [code]/r[/code]: whisper to the last correspondent (the text may be empty).
	REPLY,
	## [code]/ayuda[/code]: [member Command.topic] says which command (empty = the list).
	HELP,
	## [code]/invitar nombre[/code].
	INVITE,
	## [code]/salir[/code].
	LEAVE,
	## [code]/expulsar nombre[/code].
	KICK,
	## [code]/lider nombre[/code].
	LEADER,
	## A command that does not exist.
	UNKNOWN,
	## A command that exists but is misused: [member Command.error] explains how.
	INVALID,
	## A command handled by the server ([code]/gm[/code], [code]/ignorar[/code], [code]/designorar[/code],
	## [code]/reportar[/code]): [member Command.text] is the line without the slash, which goes through the GM channel.
	SERVER,
}

## Response to an unknown command.
const TEXT_UNKNOWN: String = "Comando desconocido. Escribe /ayuda."
const TEXT_NAME_TOO_LONG: String = "Ese nombre es demasiado largo."
const TEXT_HELP_TITLE: String = "Comandos disponibles (escribe /ayuda comando para más detalle):"
const TEXT_NO_HELP: String = "No hay ayuda para «%s». Escribe /ayuda."

## The commands: [code]id[/code] (the [enum Kind] or channel they produce), [code]names[/code] (all
## the forms, already without accents or uppercase), [code]usage[/code] and [code]help[/code].
const COMMANDS: Array[Dictionary] = [
	{"id": &"say", "names": ["d", "decir"], "usage": "/d [texto]",
			"help": "Habla a los de tu reino que estén cerca (30 m). Sin texto, es tu canal activo."},
	{"id": &"zone", "names": ["z", "zona"], "usage": "/z [texto]",
			"help": "Habla a todo tu reino presente en la zona. Sin texto, es tu canal activo."},
	{"id": &"whisper", "names": ["s", "susurrar"], "usage": "/s nombre [texto]",
			"help": "Susurra a un jugador de tu reino. Sin texto, sigues susurrándole."},
	{"id": &"reply", "names": ["r", "responder"], "usage": "/r [texto]",
			"help": "Responde al último jugador con el que has hablado por susurro."},
	{"id": &"party", "names": ["g", "grupo"], "usage": "/g [texto]",
			"help": "Habla a tu grupo. Sin texto, es tu canal activo."},
	{"id": &"invite", "names": ["invitar"], "usage": "/invitar nombre",
			"help": "Invita a un jugador de tu reino a tu grupo (hasta 5)."},
	{"id": &"leave", "names": ["salir"], "usage": "/salir",
			"help": "Sales de tu grupo."},
	{"id": &"kick", "names": ["expulsar"], "usage": "/expulsar nombre",
			"help": "El líder echa a un miembro del grupo."},
	{"id": &"leader", "names": ["lider"], "usage": "/lider nombre",
			"help": "El líder cede el mando del grupo a otro miembro."},
	{"id": &"ignore", "names": ["ignorar"], "usage": "/ignorar nombre",
			"help": "Dejas de recibir los mensajes y las invitaciones de ese jugador (de toda su cuenta)."},
	{"id": &"unignore", "names": ["designorar"], "usage": "/designorar nombre",
			"help": "Vuelves a recibir los mensajes de un jugador que ignorabas."},
	{"id": &"report", "names": ["reportar"], "usage": "/reportar nombre categoría [comentario]",
			"help": "Reporta a un jugador a la moderación (categorías: lenguaje, acoso, trampas, bot, nombre, otro)."},
	{"id": &"help", "names": ["ayuda"], "usage": "/ayuda [comando]",
			"help": "Lista los comandos o explica uno."},
]
## The moderation command: it is not in [constant COMMANDS] (it does not appear in the help).
const GM_COMMAND: String = "gm"

## Channel of the channel commands.
const _CHANNEL_OF: Dictionary[StringName, int] = {
	&"say": ChatChannel.Id.SAY,
	&"zone": ChatChannel.Id.ZONE,
	&"party": ChatChannel.Id.PARTY,
	&"whisper": ChatChannel.Id.WHISPER,
}


## What a line means.
class Command:
	extends RefCounted

	var kind: int = Kind.EMPTY
	## [enum ChatChannel.Id] of the channel (for [constant Kind.SEND] and [constant Kind.SET_CHANNEL]); -1 if none.
	var channel: int = -1
	## Player name that was typed (whisper, invite, kick, leader); empty if none.
	var target: String = ""
	## Text to send (may be empty for [constant Kind.REPLY]).
	var text: String = ""
	## For [constant Kind.HELP], the command that help is requested for (without slash, without accents); empty = list.
	var topic: String = ""
	## For [constant Kind.INVALID], how the command is used.
	var error: String = ""
	## The command as it was typed, without the slash (for notices).
	var name: String = ""


## Parses [param line], the line the player typed.
static func parse(line: String) -> Command:
	var command := Command.new()
	var trimmed: String = line.strip_edges()
	if trimmed.is_empty():
		return command
	if not trimmed.begins_with("/"):
		command.kind = Kind.TEXT
		command.text = trimmed
		return command

	var body: String = trimmed.substr(1)
	var split_at: int = _first_space(body)
	var raw_name: String = body if split_at < 0 else body.substr(0, split_at)
	var rest: String = "" if split_at < 0 else body.substr(split_at).strip_edges()
	command.name = raw_name
	if not raw_name.begins_with("/") and NameRules.normalize_key(raw_name) == GM_COMMAND:
		command.kind = Kind.SERVER
		command.text = GM_COMMAND if rest.is_empty() else "%s %s" % [GM_COMMAND, rest]
		return command
	var spec: Dictionary = {} if raw_name.begins_with("/") else find_command(raw_name)
	if spec.is_empty():
		command.kind = Kind.UNKNOWN
		return command
	var id: StringName = spec["id"]
	match id:
		&"say", &"zone", &"party":
			command.channel = _CHANNEL_OF[id]
			command.text = rest
			command.kind = Kind.SEND if not rest.is_empty() else Kind.SET_CHANNEL
		&"whisper":
			_parse_whisper(command, spec, rest)
		&"reply":
			command.kind = Kind.REPLY
			command.channel = ChatChannel.Id.WHISPER
			command.text = rest
		&"help":
			command.kind = Kind.HELP
			command.topic = _topic_key(rest)
		&"invite":
			_parse_with_name(command, spec, rest, Kind.INVITE)
		&"kick":
			_parse_with_name(command, spec, rest, Kind.KICK)
		&"leader":
			_parse_with_name(command, spec, rest, Kind.LEADER)
		&"leave":
			command.kind = Kind.LEAVE
		&"ignore", &"unignore", &"report":
			_parse_with_name(command, spec, rest, Kind.SERVER)
			if command.kind == Kind.SERVER:
				command.text = "%s %s" % [(spec["names"] as Array)[0], rest]
	return command


## The [COMMANDS] entry whose name is [param raw_name] (with or without slash, case- and
## accent-insensitive), or an empty dictionary if it does not exist.
static func find_command(raw_name: String) -> Dictionary:
	var key: String = _topic_key(raw_name)
	if key.is_empty():
		return {}
	for spec: Dictionary in COMMANDS:
		if (spec["names"] as Array).has(key):
			return spec
	return {}


## The help lines for [param topic] (a command's name; empty = the list of all). For a command that
## does not exist, the notice that there is no help.
static func help_lines(topic: String) -> PackedStringArray:
	var lines := PackedStringArray()
	var key: String = _topic_key(topic)
	if key.is_empty():
		lines.append(TEXT_HELP_TITLE)
		for spec: Dictionary in COMMANDS:
			lines.append("  %s — %s" % [spec["usage"], spec["help"]])
		return lines
	var spec: Dictionary = find_command(key)
	if spec.is_empty():
		lines.append(TEXT_NO_HELP % topic.strip_edges())
		return lines
	var names: PackedStringArray = PackedStringArray()
	for name: String in spec["names"]:
		names.append("/" + name)
	lines.append("%s — %s" % [spec["usage"], spec["help"]])
	if names.size() > 1:
		lines.append("También: " + ", ".join(names))
	return lines


# Key of a command name: without the leading slash, without uppercase or accents.
static func _topic_key(text: String) -> String:
	var cleaned: String = text.strip_edges()
	var first: int = _first_space(cleaned)
	if first >= 0:
		cleaned = cleaned.substr(0, first)
	if cleaned.begins_with("/"):
		cleaned = cleaned.substr(1)
	return NameRules.normalize_key(cleaned)


# Position of the first space or tab in [param text] (-1 if none).
static func _first_space(text: String) -> int:
	for i: int in text.length():
		if ChatText.is_space(text.unicode_at(i)):
			return i
	return -1


# /s name [text].
static func _parse_whisper(command: Command, spec: Dictionary, rest: String) -> void:
	command.channel = ChatChannel.Id.WHISPER
	if rest.is_empty():
		command.kind = Kind.INVALID
		command.error = "Uso: %s" % spec["usage"]
		return
	var split_at: int = _first_space(rest)
	command.target = rest if split_at < 0 else rest.substr(0, split_at)
	command.text = "" if split_at < 0 else rest.substr(split_at).strip_edges()
	if command.target.length() > NameRules.MAX_LENGTH:
		command.kind = Kind.INVALID
		command.error = TEXT_NAME_TOO_LONG
		return
	command.kind = Kind.SEND if not command.text.is_empty() else Kind.SET_CHANNEL


# Commands that ask for a name (invite, kick, leader).
static func _parse_with_name(command: Command, spec: Dictionary, rest: String, kind: int) -> void:
	if rest.is_empty():
		command.kind = Kind.INVALID
		command.error = "Uso: %s" % spec["usage"]
		return
	var split_at: int = _first_space(rest)
	command.target = rest if split_at < 0 else rest.substr(0, split_at)
	if command.target.length() > NameRules.MAX_LENGTH:
		command.kind = Kind.INVALID
		command.error = TEXT_NAME_TOO_LONG
		return
	command.kind = kind
