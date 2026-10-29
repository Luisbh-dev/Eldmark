class_name ChatChannel
extends RefCounted
## Canales del chat (docs/social.md, sección 2): sus ids de red, los que puede enviar un cliente y
## qué ritmo de envío comparten.
## [br][br]
## El id viaja en el byte [code]channel[/code] de CHAT_SEND y CHAT_MESSAGE y no se reordena ni se
## reutiliza. En la fase 4 solo se reparten [constant Id.SAY], [constant Id.ZONE], [constant Id.WHISPER],
## [constant Id.PARTY] y [constant Id.SYSTEM]; banda, gremio, reino y GM tienen su id reservado y el
## servidor contesta que aún no están disponibles. Compartido: no depende del cliente ni del servidor.

enum Id {
	## Decir: mismo reino, a 30 m del emisor.
	SAY = 0,
	## Zona: todo el reino presente en la zona (y su copia).
	ZONE = 1,
	## Susurro: un personaje del mismo reino, por su nombre.
	WHISPER = 2,
	## Grupo: los miembros del grupo.
	PARTY = 3,
	## Banda de guerra (fase 7).
	RAID = 4,
	## Gremio (fase 6).
	GUILD = 5,
	## Reino entero (fase 6).
	REALM = 6,
	## Avisos del servidor y del juego: solo S→C.
	SYSTEM = 7,
	## Moderación (fase 5): solo con rol.
	GM = 8,
}

## Mayor id de canal que existe.
const MAX_ID: int = Id.GM
## Nombre en español de cada canal, por id.
const DISPLAY_NAMES: Array[String] = [
	"Decir", "Zona", "Susurro", "Grupo", "Banda", "Gremio", "Reino", "Sistema", "GM",
]
## Canales que reparte el servidor en la fase 4.
const IMPLEMENTED: Array[int] = [Id.SAY, Id.ZONE, Id.WHISPER, Id.PARTY, Id.SYSTEM]
## Canales que comparten el ritmo de «hablar» (docs/social.md, sección 5): 1 mensaje por segundo con
## ráfaga de 5. El susurro tiene el suyo y el sistema no se envía.
const PUBLIC_RATE: Array[int] = [Id.SAY, Id.ZONE, Id.PARTY, Id.RAID, Id.GUILD]


## true si [param channel] es un id de canal conocido.
static func is_valid(channel: int) -> bool:
	return channel >= 0 and channel <= MAX_ID


## true si un cliente puede enviar por [param channel] (todos menos el del sistema).
static func is_client_sendable(channel: int) -> bool:
	return is_valid(channel) and channel != Id.SYSTEM


## true si el servidor de la fase 4 reparte [param channel].
static func is_implemented(channel: int) -> bool:
	return IMPLEMENTED.has(channel)


## true si [param channel] gasta del ritmo común de hablar (ver [constant PUBLIC_RATE]).
static func uses_public_rate(channel: int) -> bool:
	return PUBLIC_RATE.has(channel)


## Nombre en español del canal («Canal» si no existe).
static func display_name(channel: int) -> String:
	if not is_valid(channel):
		return "Canal"
	return DISPLAY_NAMES[channel]
