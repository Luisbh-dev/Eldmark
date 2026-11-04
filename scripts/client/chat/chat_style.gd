class_name ChatStyle
extends RefCounted
## Chat appearance (SOC-05): the color of each channel and how a line is composed. Everything is
## constants and static functions, with no state.
## [br][br]
## [b]Provisional colors (pending the user).[/b] Each channel has its own color, and the system and
## GMs an unmistakable one (docs/social.md, section 2); these are the first-version ones, awaiting the
## ART-12 visual guide. The sender's name takes the color of their realm. The text of other players is
## always delivered as literal text ([code]RichTextLabel.add_text[/code]), never as BBCode.

## Text color of each channel, by [enum ChatChannel.Id].
const CHANNEL_COLORS: Array[Color] = [
	Color(0.93, 0.92, 0.9, 1.0),   # say
	Color(0.98, 0.68, 0.36, 1.0),  # zone
	Color(0.95, 0.5, 0.9, 1.0),    # whisper
	Color(0.4, 0.7, 1.0, 1.0),     # party
	Color(0.92, 0.38, 0.32, 1.0),  # raid
	Color(0.4, 0.9, 0.45, 1.0),    # guild
	Color(0.78, 0.6, 1.0, 1.0),    # realm
	Color(1.0, 0.9, 0.5, 1.0),     # system
	Color(0.3, 0.95, 0.95, 1.0),   # GM
]
## Bracketed tags of the channels that have them.
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


## Color of channel [param channel]; that of "say" if it does not exist.
static func channel_color(channel: int) -> Color:
	if not ChatChannel.is_valid(channel):
		return CHANNEL_COLORS[ChatChannel.Id.SAY]
	return CHANNEL_COLORS[channel]


## The parts of a line, in order: each one is [code]{"text": String, "color": Color}[/code]. Joined
## they give the line's text. A whisper reads "Ana te susurra: texto" (Ana whispers to you) or "Susurras a Bruno:
## texto" (You whisper to Bruno); a "say", "Ana dice: texto" or "Dices: texto"; zone, party and the others,
## "[code][Zona][/code] Ana: texto".
## The sender's name goes in their realm's color and the rest in the channel's color.
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


## The plain text of a line (the parts of [method segments] joined).
static func line_text(line: ChatLog.Line) -> String:
	var text: String = ""
	for part: Dictionary in segments(line):
		text += String(part["text"])
	return text


static func _part(text: String, color: Color) -> Dictionary:
	return {"text": text, "color": color}


# Color of a sender's name: that of their realm, or the channel's if it is unknown.
static func _realm_color(realm: int, fallback: Color) -> Color:
	if realm == NetProtocol.Realm.NONE:
		return fallback
	return UIPalette.faction_color_of_code(realm).lightened(0.25)
