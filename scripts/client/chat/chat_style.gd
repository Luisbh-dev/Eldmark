class_name ChatStyle
extends RefCounted
## Aspecto del chat (SOC-05): el color de cada canal y cómo se compone una línea. Todo son constantes y
## funciones estáticas, sin estado.
## [br][br]
## [b]Colores provisionales (pendiente del usuario).[/b] Cada canal tiene su color propio y el sistema y los
## GM uno inconfundible (docs/social.md, sección 2); estos son los de la primera versión, a la espera de la
## guía visual de ART-12. El nombre del emisor lleva el color de su reino. El texto de otros jugadores se
## entrega siempre como texto literal ([code]RichTextLabel.add_text[/code]), nunca como BBCode.

## Color del texto de cada canal, por id de [enum ChatChannel.Id].
const CHANNEL_COLORS: Array[Color] = [
	Color(0.93, 0.92, 0.9, 1.0),   # decir
	Color(0.98, 0.68, 0.36, 1.0),  # zona
	Color(0.95, 0.5, 0.9, 1.0),    # susurro
	Color(0.4, 0.7, 1.0, 1.0),     # grupo
	Color(0.92, 0.38, 0.32, 1.0),  # banda
	Color(0.4, 0.9, 0.45, 1.0),    # gremio
	Color(0.78, 0.6, 1.0, 1.0),    # reino
	Color(1.0, 0.9, 0.5, 1.0),     # sistema
	Color(0.3, 0.95, 0.95, 1.0),   # GM
]
## Etiquetas entre corchetes de los canales que las llevan.
const TAGS: Dictionary[int, String] = {
	ChatChannel.Id.ZONE: "[Zona] ",
	ChatChannel.Id.PARTY: "[Grupo] ",
	ChatChannel.Id.RAID: "[Banda] ",
	ChatChannel.Id.GUILD: "[Gremio] ",
	ChatChannel.Id.REALM: "[Reino] ",
	ChatChannel.Id.GM: "[GM] ",
}
const TEXT_YOU_SAY: String = "Dices: "
const TEXT_SAYS: String = " dice: "
const TEXT_WHISPERS_YOU: String = " te susurra: "
const TEXT_YOU_WHISPER: String = "Susurras a "


## Color del canal [param channel]; el de «decir» si no existe.
static func channel_color(channel: int) -> Color:
	if not ChatChannel.is_valid(channel):
		return CHANNEL_COLORS[ChatChannel.Id.SAY]
	return CHANNEL_COLORS[channel]


## Las partes de una línea, en orden: cada una es [code]{"text": String, "color": Color}[/code]. Unidas
## dan el texto de la línea. Un susurro se lee «Ana te susurra: texto» o «Susurras a Bruno: texto»; un
## «decir», «Ana dice: texto» o «Dices: texto»; zona, grupo y los demás, «[Zona] Ana: texto». El nombre del
## emisor va con el color de su reino y el resto con el del canal.
static func segments(line: ChatLog.Line) -> Array[Dictionary]:
	var color: Color = channel_color(line.channel)
	var parts: Array[Dictionary] = []
	match line.channel:
		ChatChannel.Id.SYSTEM:
			parts.append(_part(line.text, color))
		ChatChannel.Id.WHISPER:
			if line.own:
				parts.append(_part(TEXT_YOU_WHISPER, color))
				parts.append(_part(line.recipient, _realm_color(line.sender_realm, color)))
				parts.append(_part(": " + line.text, color))
			else:
				parts.append(_part(line.sender, _realm_color(line.sender_realm, color)))
				parts.append(_part(TEXT_WHISPERS_YOU + line.text, color))
		ChatChannel.Id.SAY:
			if line.own:
				parts.append(_part(TEXT_YOU_SAY + line.text, color))
			else:
				parts.append(_part(line.sender, _realm_color(line.sender_realm, color)))
				parts.append(_part(TEXT_SAYS + line.text, color))
		_:
			parts.append(_part(TAGS.get(line.channel, ""), color))
			parts.append(_part(line.sender, _realm_color(line.sender_realm, color)))
			parts.append(_part(": " + line.text, color))
	return parts


## El texto plano de una línea (las partes de [method segments] unidas).
static func line_text(line: ChatLog.Line) -> String:
	var text: String = ""
	for part: Dictionary in segments(line):
		text += String(part["text"])
	return text


static func _part(text: String, color: Color) -> Dictionary:
	return {"text": text, "color": color}


# Color del nombre de un emisor: el de su reino, o el del canal si no se conoce.
static func _realm_color(realm: int, fallback: Color) -> Color:
	if realm == NetProtocol.Realm.NONE:
		return fallback
	return UIPalette.faction_color_of_code(realm).lightened(0.25)
