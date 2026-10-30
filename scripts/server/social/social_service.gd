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
## [b]Estado del chat por personaje[/b] (docs/plataforma.md §9.2, P7b). Con plataforma, el [ChatPeerState] de quien
## sale se conserva por su [code]character_id[/code] [constant ChatRouter.KNOWN_RECIPIENT_TICKS] ticks (5 min) y, si
## vuelve a entrar en esta instancia, [method on_peer_joined] se lo devuelve: salir y volver no rellena las ráfagas.
## Al entrar se ponen además su cuenta, las que ignora y su silencio, de la reclamación. Sin plataforma, por conexión,
## como en la fase 4.
## [br][br]
## No toca la red ni el reloj. Recibe del [ZoneServer] tres [Callable]s ([code]peers_source() ->
## Array[ServerPeer][/code], [code]send_sink(peer_id: int, bytes: PackedByteArray)[/code] por el canal
## fiable y [code]strike_sink(peer: ServerPeer, reason: String)[/code]) y el tick en cada llamada.

## Primer y último tipo de mensaje que atiende este servicio (el rango social del protocolo 5: chat desde el
## 0x40 y grupos desde el 0x48).
const FIRST_TYPE: int = 0x40
const LAST_TYPE: int = 0x4F
## Cada cuántos ticks se olvidan los estados conservados que ya han vencido.
const RETAINED_PURGE_TICKS: int = 600


# El estado del chat de un personaje que se ha ido, y cuándo.
class _Kept:
	extends RefCounted

	var state: ChatPeerState = null
	var left_tick: int = 0


var _chat: ChatRouter
var _party: PartyManager
# character_id -> el estado de quien se fue hace menos de KNOWN_RECIPIENT_TICKS.
var _retained: Dictionary[int, _Kept] = {}
var _reattached: int = 0


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


## [param peer] entra en el mundo en el tick [param now_tick]. Con plataforma (su reclamación), recupera el estado
## del chat de su personaje si salió hace menos de [constant ChatRouter.KNOWN_RECIPIENT_TICKS] ticks y toma de la
## reclamación su cuenta, las cuentas que ignora y su silencio.
func on_peer_joined(peer: ServerPeer, now_tick: int) -> void:
	var claimed: ClaimedCharacter = peer.claimed
	if claimed == null:
		return
	var kept: _Kept = _retained.get(claimed.character_id)
	if kept != null:
		_retained.erase(claimed.character_id)
		if now_tick - kept.left_tick < ChatRouter.KNOWN_RECIPIENT_TICKS:
			peer.chat = kept.state
			_reattached += 1
	var state: ChatPeerState = peer.chat
	state.name_key = ""
	state.account_id = claimed.account_id
	state.ignored_accounts.clear()
	for account_id: int in claimed.ignored_accounts:
		state.ignored_accounts[account_id] = true
	state.muted_until_unix = claimed.muted_until_unix
	state.mute_changed_msec = -1


## [param peer] ha salido de la zona (ya no está en el mundo): sale de su grupo y se cancelan sus
## invitaciones. Con plataforma, si llegó a estar en el mundo, se conserva su estado del chat por su personaje.
func on_peer_left(peer: ServerPeer, now_tick: int) -> void:
	_party.on_peer_left(peer, now_tick)
	if peer.claimed != null and peer.entity != null:
		var kept := _Kept.new()
		kept.state = peer.chat
		kept.left_tick = now_tick
		_retained[peer.claimed.character_id] = kept


## Un tick del servidor: caducan las invitaciones y, a 2 Hz, sale el estado de los grupos. Cada
## [constant RETAINED_PURGE_TICKS] ticks se olvidan los estados del chat conservados que ya han vencido.
func step(now_tick: int) -> void:
	_party.step(now_tick)
	if now_tick % RETAINED_PURGE_TICKS == 0 and not _retained.is_empty():
		for character_id: int in _retained.keys():
			if now_tick - _retained[character_id].left_tick >= ChatRouter.KNOWN_RECIPIENT_TICKS:
				_retained.erase(character_id)


## Estados del chat conservados de personajes que se han ido.
func get_retained_count() -> int:
	return _retained.size()


## Estadísticas para el informe.
func get_stats() -> Dictionary:
	return {"chat": _chat.get_stats(), "party": _party.get_stats(), "retained": _retained.size(),
			"reattached": _reattached}
