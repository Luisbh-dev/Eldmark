class_name ChatCommandParser
extends RefCounted
## Analizador de la línea del chat (SOC-05, docs/social.md, sección 4): decide si lo que escribe el
## jugador es texto para el canal activo o un comando en español, y cuál.
## [br][br]
## Los comandos empiezan por [code]/[/code] y se reconocen sin distinguir mayúsculas ni tildes
## ([code]/Susurrar[/code], [code]/susurrar[/code] y [code]/SUSURRAR[/code] valen igual; la clave es la de
## [method NameRules.normalize_key]). El nombre de un jugador, como argumento, no lleva comillas ni
## espacios y tampoco distingue mayúsculas ni tildes (lo busca el servidor). Es puro: no toca la red ni
## la interfaz, así que se prueba con texto. No depende del servidor.
## [br][br]
## [b]Comandos de la fase 4[/b] (la tabla [constant COMMANDS] es la única lista; [code]/ayuda[/code] se
## genera de ella):
## [br]- Canales: [code]/d[/code] [code]/decir[/code], [code]/z[/code] [code]/zona[/code], [code]/g[/code]
## [code]/grupo[/code]: con texto lo envían por ese canal ([constant Kind.SEND]) y sin texto lo dejan como
## canal activo ([constant Kind.SET_CHANNEL]).
## [br]- [code]/s nombre texto[/code] [code]/susurrar[/code]: susurro; sin texto deja el susurro a ese
## nombre como canal activo; sin nombre, uso incorrecto ([constant Kind.INVALID]).
## [br]- [code]/r texto[/code] [code]/responder[/code]: susurro al último interlocutor
## ([constant Kind.REPLY]; lo resuelve quien tiene el historial: [ChatBox]).
## [br]- [code]/ayuda [comando][/code]: la lista de comandos o el detalle de uno ([constant Kind.HELP]).
## [br]- [code]/invitar nombre[/code], [code]/salir[/code], [code]/expulsar nombre[/code],
## [code]/lider nombre[/code]: los grupos (SOC-06 y SOC-08).
## [br]- Desde la fase 5 (docs/plataforma.md §9, P7b), los que atiende el servidor ([constant Kind.SERVER]):
## [code]/ignorar nombre[/code], [code]/designorar nombre[/code] y [code]/reportar nombre categoría
## [comentario][/code], y [code]/gm …[/code], que no sale en la ayuda (solo lo usa quien tiene rol; a los demás el
## servidor les contesta «Comando desconocido», sin revelar que existe). Se mandan tal cual por el canal GM.
## [br][br]
## Cualquier otro comando, aunque exista en docs/social.md para una fase futura ([code]/b[/code],
## [code]/gr[/code], [code]/reino[/code]...), es [constant Kind.UNKNOWN] y se contesta con
## [constant TEXT_UNKNOWN]: tampoco se avisa de que existe.

enum Kind {
	## Línea vacía: no hay nada que hacer.
	EMPTY,
	## Texto sin comando: va al canal activo.
	TEXT,
	## Texto con un comando de canal: se envía por ese canal.
	SEND,
	## Un comando de canal sin texto: el canal (y el destinatario) pasan a ser el activo.
	SET_CHANNEL,
	## [code]/r[/code]: susurro al último interlocutor (el texto puede estar vacío).
	REPLY,
	## [code]/ayuda[/code]: [member Command.topic] dice de qué comando (vacío = la lista).
	HELP,
	## [code]/invitar nombre[/code].
	INVITE,
	## [code]/salir[/code].
	LEAVE,
	## [code]/expulsar nombre[/code].
	KICK,
	## [code]/lider nombre[/code].
	LEADER,
	## Un comando que no existe.
	UNKNOWN,
	## Un comando que existe pero está mal usado: [member Command.error] explica cómo.
	INVALID,
	## Un comando que atiende el servidor ([code]/gm[/code], [code]/ignorar[/code], [code]/designorar[/code],
	## [code]/reportar[/code]): [member Command.text] es la línea sin la barra, que va por el canal GM.
	SERVER,
}

## Respuesta a un comando desconocido.
const TEXT_UNKNOWN: String = "Comando desconocido. Escribe /ayuda."
const TEXT_NAME_TOO_LONG: String = "Ese nombre es demasiado largo."
const TEXT_HELP_TITLE: String = "Comandos disponibles (escribe /ayuda comando para más detalle):"
const TEXT_NO_HELP: String = "No hay ayuda para «%s». Escribe /ayuda."

## Los comandos: [code]id[/code] (el [enum Kind] o canal que producen), [code]names[/code] (todas las
## formas, ya sin tildes ni mayúsculas), [code]usage[/code] y [code]help[/code].
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
## El comando de la moderación: no está en [constant COMMANDS] (no sale en la ayuda).
const GM_COMMAND: String = "gm"

## Canal de los comandos de canal.
const _CHANNEL_OF: Dictionary[StringName, int] = {
	&"say": ChatChannel.Id.SAY,
	&"zone": ChatChannel.Id.ZONE,
	&"party": ChatChannel.Id.PARTY,
	&"whisper": ChatChannel.Id.WHISPER,
}


## Lo que significa una línea.
class Command:
	extends RefCounted

	var kind: int = Kind.EMPTY
	## [enum ChatChannel.Id] del canal (en [constant Kind.SEND] y [constant Kind.SET_CHANNEL]); -1 si no
	## hay.
	var channel: int = -1
	## Nombre de jugador que se escribió (susurro, invitar, expulsar, líder); vacío si no hay.
	var target: String = ""
	## Texto a enviar (puede ir vacío en [constant Kind.REPLY]).
	var text: String = ""
	## En [constant Kind.HELP], el comando del que se pide ayuda (sin barra, sin tildes); vacío = lista.
	var topic: String = ""
	## En [constant Kind.INVALID], cómo se usa el comando.
	var error: String = ""
	## El comando tal como se escribió, sin barra (para los avisos).
	var name: String = ""


## Analiza [param line], la línea que escribió el jugador.
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


## La ficha de [COMMANDS] cuyo nombre es [param raw_name] (con o sin barra, sin distinguir mayúsculas ni
## tildes), o un diccionario vacío si no existe.
static func find_command(raw_name: String) -> Dictionary:
	var key: String = _topic_key(raw_name)
	if key.is_empty():
		return {}
	for spec: Dictionary in COMMANDS:
		if (spec["names"] as Array).has(key):
			return spec
	return {}


## Las líneas de ayuda de [param topic] (el nombre de un comando; vacío = la lista de todos). Para un
## comando que no existe, el aviso de que no hay ayuda.
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


# Clave de un nombre de comando: sin barra inicial, sin mayúsculas ni tildes.
static func _topic_key(text: String) -> String:
	var cleaned: String = text.strip_edges()
	var first: int = _first_space(cleaned)
	if first >= 0:
		cleaned = cleaned.substr(0, first)
	if cleaned.begins_with("/"):
		cleaned = cleaned.substr(1)
	return NameRules.normalize_key(cleaned)


# Posición del primer espacio o tabulador de [param text] (-1 si no hay).
static func _first_space(text: String) -> int:
	for i: int in text.length():
		if ChatText.is_space(text.unicode_at(i)):
			return i
	return -1


# /s nombre [texto].
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


# Comandos que piden un nombre (invitar, expulsar, líder).
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
