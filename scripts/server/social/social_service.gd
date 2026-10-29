class_name SocialService
extends RefCounted
## Servicio social de un servidor de zona (docs/social.md, sección 12): reúne el [ChatRouter] y el
## [PartyManager], y es lo único del chat y los grupos que conoce el [ZoneServer], que le pasa cada mensaje de
## los tipos [constant FIRST_TYPE] a [constant LAST_TYPE], le avisa de quién se va ([method on_peer_left]) y
## le da un paso por tick ([method step]). Así lo social vive en [code]scripts/server/social/[/code] y el
## servidor de zona se toca lo mínimo.
## [br][br]
## El canal de grupo del chat reparte a los miembros que da el [PartyManager] y los mensajes del sistema de
## los grupos salen por el [ChatRouter].
## [br][br]
## No toca la red ni el reloj. Recibe del [ZoneServer] tres [Callable]s ([code]peers_source() ->
## Array[ServerPeer][/code], [code]send_sink(peer_id: int, bytes: PackedByteArray)[/code] por el canal
## fiable y [code]strike_sink(peer: ServerPeer, reason: String)[/code]) y el tick en cada llamada.

## Primer y último tipo de mensaje que atiende este servicio (el rango social del protocolo 5: chat desde el
## 0x40 y grupos desde el 0x48).
const FIRST_TYPE: int = 0x40
const LAST_TYPE: int = 0x4F

var _chat: ChatRouter
var _party: PartyManager


func _init(peers_source: Callable, send_sink: Callable, strike_sink: Callable) -> void:
	_chat = ChatRouter.new(peers_source, send_sink, strike_sink)
	_party = PartyManager.new(peers_source, send_sink, strike_sink, Callable(_chat, "send_system"))
	_chat.party_members = Callable(_party, "members_of")


## true si [param msg_type] es un tipo de mensaje de este servicio.
static func handles_type(msg_type: int) -> bool:
	return msg_type >= FIRST_TYPE and msg_type <= LAST_TYPE


## El enrutador del chat.
func get_chat() -> ChatRouter:
	return _chat


## Los grupos.
func get_party() -> PartyManager:
	return _party


## Atiende el mensaje [param bytes] de tipo [param msg_type] llegado de [param peer] en el tick
## [param now_tick]. Devuelve false si el tipo no es de este servicio, o es uno que solo manda el servidor
## (y no se ha hecho nada): quien llama decide qué hacer (el servidor de zona suma un aviso por tipo
## inesperado).
func handle_packet(peer: ServerPeer, msg_type: int, bytes: PackedByteArray, now_tick: int) -> bool:
	if msg_type == NetProtocol.MSG_CHAT_SEND:
		_chat.handle_send(peer, bytes, now_tick)
		return true
	return _party.handle_packet(peer, msg_type, bytes, now_tick)


## [param peer] ha salido de la zona (ya no está en el mundo): sale de su grupo y se cancelan sus
## invitaciones.
func on_peer_left(peer: ServerPeer, now_tick: int) -> void:
	_party.on_peer_left(peer, now_tick)


## Un tick del servidor: caducan las invitaciones y, a 2 Hz, sale el estado de los grupos.
func step(now_tick: int) -> void:
	_party.step(now_tick)


## Estadísticas para el informe.
func get_stats() -> Dictionary:
	return {"chat": _chat.get_stats(), "party": _party.get_stats()}
