class_name ChatChannel
extends RefCounted
## Chat channels (docs/social.md, section 2): their network ids, the ones a client can send, and
## which send rate they share.
## [br][br]
## The id travels in the [code]channel[/code] byte of CHAT_SEND and CHAT_MESSAGE and is never
## reordered or reused. In phase 4 only [constant Id.SAY], [constant Id.ZONE],
## [constant Id.WHISPER], [constant Id.PARTY] and [constant Id.SYSTEM] are delivered; raid, guild,
## realm and GM have their id reserved and the server answers that they are not available yet.
## Shared: depends on neither the client nor the server.

enum Id {
	## Say: same realm, within 30 m of the sender.
	SAY = 0,
	## Zone: the whole realm present in the zone (and its copy).
	ZONE = 1,
	## Whisper: a character of the same realm, by name.
	WHISPER = 2,
	## Party: the party members.
	PARTY = 3,
	## War raid (phase 7).
	RAID = 4,
	## Guild (phase 6).
	GUILD = 5,
	## Whole realm (phase 6).
	REALM = 6,
	## Server and game notices: S→C only.
	SYSTEM = 7,
	## Moderation (phase 5): only with a role.
	GM = 8,
}

## Highest channel id that exists.
const MAX_ID: int = Id.GM
## Spanish name of each channel, by id.
const DISPLAY_NAMES: Array[String] = [
	"Decir", "Zona", "Susurro", "Grupo", "Banda", "Gremio", "Reino", "Sistema", "GM",
]
## Channels the server delivers in phase 4.
const IMPLEMENTED: Array[int] = [Id.SAY, Id.ZONE, Id.WHISPER, Id.PARTY, Id.SYSTEM]
## Channels that share the "talk" rate (docs/social.md, section 5): 1 message per second with a
## burst of 5. Whisper has its own and system is not sent.
const PUBLIC_RATE: Array[int] = [Id.SAY, Id.ZONE, Id.PARTY, Id.RAID, Id.GUILD]


## true if [param channel] is a known channel id.
static func is_valid(channel: int) -> bool:
	return channel >= 0 and channel <= MAX_ID


## true if a client can send on [param channel] (all except system).
static func is_client_sendable(channel: int) -> bool:
	return is_valid(channel) and channel != Id.SYSTEM


## true if the phase 4 server delivers [param channel].
static func is_implemented(channel: int) -> bool:
	return IMPLEMENTED.has(channel)


## true if [param channel] draws on the common talk rate (see [constant PUBLIC_RATE]).
static func uses_public_rate(channel: int) -> bool:
	return PUBLIC_RATE.has(channel)


## Spanish name of the channel ("Canal" if it does not exist).
static func display_name(channel: int) -> String:
	if not is_valid(channel):
		return "Canal"
	return DISPLAY_NAMES[channel]
