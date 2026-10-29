class_name SocialService
extends RefCounted
## Servicio social de un servidor de zona (docs/social.md, sección 12): reúne el [ChatRouter] y, cuando
## existan, los grupos, y es lo único del chat que conoce el [ZoneServer], que le pasa cada mensaje de
## los tipos [constant FIRST_TYPE] a [constant LAST_TYPE] y poco más. Así lo social vive en
## [code]scripts/server/social/[/code] y el servidor de zona se toca lo mínimo.
## [br][br]
## No toca la red ni el reloj. Recibe del [ZoneServer] tres [Callable]s ([code]peers_source() ->
## Array[ServerPeer][/code], [code]send_sink(peer_id: int, bytes: PackedByteArray)[/code] por el canal
## fiable y [code]strike_sink(peer: ServerPeer, reason: String)[/code]) y el tick en cada llamada.

## Primer y último tipo de mensaje que atiende este servicio (el rango social del protocolo 5: chat desde el
## 0x40 y grupos desde el 0x48).
const FIRST_TYPE: int = 0x40
const LAST_TYPE: int = 0x4F

var _chat: ChatRouter


func _init(peers_source: Callable, send_sink: Callable, strike_sink: Callable) -> void:
	_chat = ChatRouter.new(peers_source, send_sink, strike_sink)


## true si [param msg_type] es un tipo de mensaje de este servicio.
static func handles_type(msg_type: int) -> bool:
	return msg_type >= FIRST_TYPE and msg_type <= LAST_TYPE


## El enrutador del chat.
func get_chat() -> ChatRouter:
	return _chat


## Atiende el mensaje [param bytes] de tipo [param msg_type] llegado de [param peer] en el tick
## [param now_tick]. Devuelve false si el tipo no es de este servicio (y no se ha hecho nada): quien
## llama decide qué hacer (el servidor de zona suma un aviso por tipo inesperado).
func handle_packet(peer: ServerPeer, msg_type: int, bytes: PackedByteArray, now_tick: int) -> bool:
	match msg_type:
		NetProtocol.MSG_CHAT_SEND:
			_chat.handle_send(peer, bytes, now_tick)
			return true
	return false


## Estadísticas para el informe.
func get_stats() -> Dictionary:
	return {"chat": _chat.get_stats()}
