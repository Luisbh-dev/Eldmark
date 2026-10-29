class_name PartyManager
extends RefCounted
## Grupos del servidor de zona (SOC-06, docs/social.md, secciones 3 y 12.4): invitar, aceptar, rechazar,
## salir, expulsar y ceder el mando, y el estado compacto de los miembros.
## [br][br]
## [b]Reglas.[/b] Un grupo es de [constant NetProtocol.PARTY_MAX_SIZE] jugadores como mucho y [b]del mismo
## reino[/b]: invitar a un jugador de otro reino, o a quien no existe, contesta lo mismo que un susurro
## («no está conectado»), no avisa al invitado ni revela que existe. El primero es el líder y puede expulsar y
## ceder el mando; cualquier miembro puede invitar. Si el líder se va, el siguiente más antiguo hereda el
## mando; un grupo de uno se disuelve. Una invitación caduca a los [constant PartyRules.INVITE_TTL_TICKS]
## ticks (60 s), cada jugador puede tener como mucho [constant PartyRules.MAX_PENDING_PER_INVITER] enviadas
## y aceptar una invitación cancela las demás que tuviera. Invitar tiene su cubo (1 cada 2 s, ráfaga de 3); lo
## que se descarta avisa al jugador y uno de cada cinco suma un aviso del peer.
## [br][br]
## [b]Lo que se manda.[/b] Cada resultado llega al jugador como un mensaje del canal del sistema
## ([code]notify[/code]); la interfaz recibe además PARTY_INVITATION (la invitación, y cuándo deja de valer),
## PARTY_ROSTER (la lista de miembros y el líder, cada vez que cambia; vacía al salir) y PARTY_STATUS (vida,
## resistencia y posición de cada miembro) a 2 Hz ([constant PartyRules.STATUS_INTERVAL_TICKS]) a todos los
## miembros, estén donde estén: no pasa por el interés de los snapshots.
## [br][br]
## No toca la red ni el reloj: recibe de [SocialService] cuatro [Callable]s ([code]peers_source() ->
## Array[ServerPeer][/code], [code]send_sink(peer_id: int, bytes: PackedByteArray)[/code],
## [code]strike_sink(peer: ServerPeer, reason: String)[/code] y [code]notify(peer: ServerPeer, text:
## String, now_tick: int)[/code]) y el tick en cada llamada.

const STRIKE_REASON_MALFORMED: String = "mensaje de grupo mal formado"
const STRIKE_REASON_NOT_IN_WORLD: String = "grupo antes de entrar en el mundo"
const STRIKE_REASON_FLOOD: String = "exceso de invitaciones de grupo"
## De cada cuántas invitaciones descartadas por ritmo una suma un aviso del peer.
const STRIKE_EVERY_DISCARDS: int = 5

const TEXT_NOT_CONNECTED: String = "«%s» no está conectado."
const TEXT_SELF_INVITE: String = "No puedes invitarte a ti mismo."
const TEXT_TOO_FAST: String = "Invitas demasiado rápido."
const TEXT_FULL: String = "Tu grupo está completo (máximo %d)."
const TEXT_TARGET_IN_YOUR_PARTY: String = "%s ya está en tu grupo."
const TEXT_TARGET_IN_A_PARTY: String = "%s ya está en un grupo."
const TEXT_ALREADY_INVITED: String = "Ya has invitado a %s."
const TEXT_TOO_MANY_PENDING: String = "Tienes demasiadas invitaciones pendientes."
const TEXT_INVITED: String = "Has invitado a %s al grupo."
const TEXT_INVITED_YOU: String = "%s te ha invitado a su grupo."
const TEXT_NO_INVITATION: String = "No tienes ninguna invitación de «%s»."
const TEXT_DECLINED: String = "%s ha rechazado tu invitación."
const TEXT_EXPIRED: String = "La invitación a %s ha caducado."
const TEXT_ALREADY_IN_PARTY: String = "Ya estás en un grupo."
const TEXT_PARTY_FULL: String = "El grupo está completo."
const TEXT_JOINED: String = "%s se ha unido al grupo."
const TEXT_LEFT: String = "%s ha salido del grupo."
const TEXT_YOU_LEFT: String = "Has salido del grupo."
const TEXT_DISBANDED: String = "El grupo se ha disuelto."
const TEXT_NEW_LEADER: String = "%s es ahora el líder del grupo."
const TEXT_NOT_IN_PARTY: String = "No estás en un grupo."
const TEXT_NOT_LEADER: String = "Solo el líder puede hacer eso."
const TEXT_NOT_A_MEMBER: String = "«%s» no está en tu grupo."
const TEXT_KICK_SELF: String = "Para salir del grupo usa /salir."
const TEXT_KICKED: String = "%s ha sido expulsado del grupo."
const TEXT_YOU_WERE_KICKED: String = "Has sido expulsado del grupo."
const TEXT_ALREADY_LEADER: String = "Ya eres el líder."


## Un grupo: sus miembros por orden de llegada y quién manda.
class Party:
	extends RefCounted

	var id: int = 0
	var members: Array[ServerPeer] = []
	var leader: ServerPeer = null


## Una invitación pendiente.
class Invitation:
	extends RefCounted

	var inviter: ServerPeer = null
	var target: ServerPeer = null
	var expire_tick: int = 0


var _peers_source: Callable
var _send_sink: Callable
var _strike_sink: Callable
var _notify: Callable
var _parties: Array[Party] = []
# peer_id -> su grupo.
var _party_of: Dictionary[int, Party] = {}
var _invitations: Array[Invitation] = []
var _next_party_id: int = 1
var _stats: Dictionary = {"parties_created": 0, "invitations": 0, "accepted": 0, "declined": 0,
		"expired": 0, "kicks": 0, "status_sent": 0, "rate_limited": 0}


func _init(peers_source: Callable, send_sink: Callable, strike_sink: Callable, notify: Callable) -> void:
	_peers_source = peers_source
	_send_sink = send_sink
	_strike_sink = strike_sink
	_notify = notify


# --- Entrada ----------------------------------------------------------------------------------

## Atiende el mensaje [param bytes] de tipo [param msg_type] de [param peer] en el tick [param now_tick].
## Devuelve false si el tipo no es uno de los que manda un cliente (PARTY_INVITE a PARTY_LEADER): quien
## llama decide qué hacer con un tipo inesperado. Un mensaje mal formado, o de quien aún no está en el mundo,
## suma un aviso.
func handle_packet(peer: ServerPeer, msg_type: int, bytes: PackedByteArray, now_tick: int) -> bool:
	if not (NetMessages.PartyTargetRequest.is_request_type(msg_type) \
			or msg_type == NetProtocol.MSG_PARTY_RESPONSE or msg_type == NetProtocol.MSG_PARTY_LEAVE):
		return false
	if peer.state != ServerPeer.State.IN_WORLD or peer.entity == null:
		_strike_sink.call(peer, STRIKE_REASON_NOT_IN_WORLD)
		return true
	match msg_type:
		NetProtocol.MSG_PARTY_LEAVE:
			if NetMessages.PartyLeave.decode(bytes) == null:
				_strike_sink.call(peer, STRIKE_REASON_MALFORMED)
				return true
			leave(peer, now_tick)
		NetProtocol.MSG_PARTY_RESPONSE:
			var response: NetMessages.PartyResponse = NetMessages.PartyResponse.decode(bytes)
			if response == null:
				_strike_sink.call(peer, STRIKE_REASON_MALFORMED)
				return true
			respond(peer, response.inviter, response.accept, now_tick)
		_:
			var request: NetMessages.PartyTargetRequest = NetMessages.PartyTargetRequest.decode(bytes)
			if request == null:
				_strike_sink.call(peer, STRIKE_REASON_MALFORMED)
				return true
			match msg_type:
				NetProtocol.MSG_PARTY_INVITE:
					invite(peer, request.target, now_tick)
				NetProtocol.MSG_PARTY_KICK:
					kick(peer, request.target, now_tick)
				NetProtocol.MSG_PARTY_LEADER:
					set_leader(peer, request.target, now_tick)
	return true


# --- Acciones ---------------------------------------------------------------------------------

## [param peer] invita a [param target_name] (un jugador de su reino) a su grupo.
func invite(peer: ServerPeer, target_name: String, now_tick: int) -> void:
	var state: ChatPeerState = peer.chat
	if not state.limiter_invites.try_consume(now_tick):
		state.invite_discards += 1
		_stats["rate_limited"] += 1
		_notify.call(peer, TEXT_TOO_FAST, now_tick)
		if state.invite_discards % STRIKE_EVERY_DISCARDS == 0:
			_strike_sink.call(peer, STRIKE_REASON_FLOOD)
		return
	var target: ServerPeer = SocialPeers.find_by_name(_world_peers(), target_name, peer.realm)
	if target == null:
		# Igual para quien no existe y para un enemigo: nada que delate cuál de los dos es, y al enemigo no
		# le llega nada.
		var shown: String = ChatText.clean(target_name).substr(0, NetProtocol.MAX_NAME_CHARS)
		_notify.call(peer, TEXT_NOT_CONNECTED % shown, now_tick)
		return
	if target == peer:
		_notify.call(peer, TEXT_SELF_INVITE, now_tick)
		return
	var party: Party = _party_of.get(peer.peer_id)
	if party != null and party.members.size() >= NetProtocol.PARTY_MAX_SIZE:
		_notify.call(peer, TEXT_FULL % NetProtocol.PARTY_MAX_SIZE, now_tick)
		return
	var target_party: Party = _party_of.get(target.peer_id)
	if target_party != null:
		_notify.call(peer, (TEXT_TARGET_IN_YOUR_PARTY if target_party == party else TEXT_TARGET_IN_A_PARTY)
				% target.display_name, now_tick)
		return
	if _find_invitation(peer, target) != null:
		_notify.call(peer, TEXT_ALREADY_INVITED % target.display_name, now_tick)
		return
	if _pending_from(peer) >= PartyRules.MAX_PENDING_PER_INVITER:
		_notify.call(peer, TEXT_TOO_MANY_PENDING, now_tick)
		return
	var invitation := Invitation.new()
	invitation.inviter = peer
	invitation.target = target
	invitation.expire_tick = now_tick + PartyRules.INVITE_TTL_TICKS
	_invitations.append(invitation)
	_stats["invitations"] += 1
	_send_invitation(target, NetMessages.PartyInvitation.State.OFFERED, invitation.expire_tick, peer)
	_notify.call(peer, TEXT_INVITED % target.display_name, now_tick)
	_notify.call(target, TEXT_INVITED_YOU % peer.display_name, now_tick)


## [param peer] responde a la invitación de [param inviter_name]: la acepta o la rechaza.
func respond(peer: ServerPeer, inviter_name: String, accept: bool, now_tick: int) -> void:
	var key: String = NameRules.normalize_key(inviter_name)
	var invitation: Invitation = null
	for candidate: Invitation in _invitations:
		if candidate.target == peer and SocialPeers.name_key_of(candidate.inviter) == key:
			invitation = candidate
			break
	if invitation == null:
		var shown: String = ChatText.clean(inviter_name).substr(0, NetProtocol.MAX_NAME_CHARS)
		_notify.call(peer, TEXT_NO_INVITATION % shown, now_tick)
		return
	_invitations.erase(invitation)
	var inviter: ServerPeer = invitation.inviter
	_send_invitation(peer, NetMessages.PartyInvitation.State.CANCELLED, now_tick, inviter)
	if not accept:
		_stats["declined"] += 1
		_notify.call(inviter, TEXT_DECLINED % peer.display_name, now_tick)
		return
	if _party_of.has(peer.peer_id):
		_notify.call(peer, TEXT_ALREADY_IN_PARTY, now_tick)
		return
	var party: Party = _party_of.get(inviter.peer_id)
	if party != null and party.members.size() >= NetProtocol.PARTY_MAX_SIZE:
		_notify.call(peer, TEXT_PARTY_FULL, now_tick)
		return
	if party == null:
		party = _create_party(inviter)
	party.members.append(peer)
	_party_of[peer.peer_id] = party
	_stats["accepted"] += 1
	_cancel_invitations_to(peer, now_tick)
	_notify_members(party, TEXT_JOINED % peer.display_name, now_tick)
	_send_roster(party)


## [param peer] sale de su grupo.
func leave(peer: ServerPeer, now_tick: int) -> void:
	var party: Party = _party_of.get(peer.peer_id)
	if party == null:
		_notify.call(peer, TEXT_NOT_IN_PARTY, now_tick)
		return
	_notify.call(peer, TEXT_YOU_LEFT, now_tick)
	_remove_member(party, peer, now_tick, TEXT_LEFT, true)


## El líder [param peer] expulsa a [param target_name] de su grupo.
func kick(peer: ServerPeer, target_name: String, now_tick: int) -> void:
	var party: Party = _leader_party(peer, now_tick)
	if party == null:
		return
	var target: ServerPeer = _member_by_name(party, target_name)
	if target == null:
		var shown: String = ChatText.clean(target_name).substr(0, NetProtocol.MAX_NAME_CHARS)
		_notify.call(peer, TEXT_NOT_A_MEMBER % shown, now_tick)
		return
	if target == peer:
		_notify.call(peer, TEXT_KICK_SELF, now_tick)
		return
	_stats["kicks"] += 1
	_notify.call(target, TEXT_YOU_WERE_KICKED, now_tick)
	_remove_member(party, target, now_tick, TEXT_KICKED, true)


## El líder [param peer] cede el mando a [param target_name].
func set_leader(peer: ServerPeer, target_name: String, now_tick: int) -> void:
	var party: Party = _leader_party(peer, now_tick)
	if party == null:
		return
	var target: ServerPeer = _member_by_name(party, target_name)
	if target == null:
		var shown: String = ChatText.clean(target_name).substr(0, NetProtocol.MAX_NAME_CHARS)
		_notify.call(peer, TEXT_NOT_A_MEMBER % shown, now_tick)
		return
	if target == peer:
		_notify.call(peer, TEXT_ALREADY_LEADER, now_tick)
		return
	party.leader = target
	_notify_members(party, TEXT_NEW_LEADER % target.display_name, now_tick)
	_send_roster(party)


## [param peer] se va de la zona (desconexión, expulsión del servidor): sale de su grupo y se cancelan las
## invitaciones que enviaba o recibía. No se le manda nada: ya no está.
func on_peer_left(peer: ServerPeer, now_tick: int) -> void:
	for invitation: Invitation in _invitations.duplicate():
		if invitation.inviter == peer:
			_invitations.erase(invitation)
			_send_invitation(invitation.target, NetMessages.PartyInvitation.State.CANCELLED, now_tick, peer)
		elif invitation.target == peer:
			_invitations.erase(invitation)
	var party: Party = _party_of.get(peer.peer_id)
	if party != null:
		_remove_member(party, peer, now_tick, TEXT_LEFT, false)


## Un tick del servidor: caduca las invitaciones vencidas y, a 2 Hz, manda el estado de los miembros.
func step(now_tick: int) -> void:
	for invitation: Invitation in _invitations.duplicate():
		if invitation.expire_tick <= now_tick:
			_invitations.erase(invitation)
			_stats["expired"] += 1
			_send_invitation(invitation.target, NetMessages.PartyInvitation.State.EXPIRED, now_tick,
					invitation.inviter)
			_notify.call(invitation.inviter, TEXT_EXPIRED % invitation.target.display_name, now_tick)
	if now_tick % PartyRules.STATUS_INTERVAL_TICKS == 0:
		for party: Party in _parties:
			_send_status(party)


# --- Consultas --------------------------------------------------------------------------------

## Los miembros del grupo de [param peer], por orden de llegada (vacío si no tiene).
func members_of(peer: ServerPeer) -> Array[ServerPeer]:
	var party: Party = _party_of.get(peer.peer_id)
	if party == null:
		return []
	return party.members.duplicate()


## El líder del grupo de [param peer] (null si no tiene grupo).
func leader_of(peer: ServerPeer) -> ServerPeer:
	var party: Party = _party_of.get(peer.peer_id)
	return party.leader if party != null else null


func get_party_count() -> int:
	return _parties.size()


## Invitaciones pendientes en todo el servidor.
func get_pending_count() -> int:
	return _invitations.size()


## Invitaciones pendientes que [param peer] ha enviado.
func get_pending_from(peer: ServerPeer) -> int:
	return _pending_from(peer)


## Estadísticas para el informe: grupos creados, invitaciones enviadas, aceptadas, rechazadas, caducadas y
## descartadas por ritmo, expulsiones y estados enviados.
func get_stats() -> Dictionary:
	var stats: Dictionary = _stats.duplicate()
	stats["parties"] = _parties.size()
	stats["pending"] = _invitations.size()
	return stats


# --- Piezas internas --------------------------------------------------------------------------

func _world_peers() -> Array[ServerPeer]:
	var peers: Array[ServerPeer] = _peers_source.call()
	return SocialPeers.in_world(peers)


# El grupo de [param peer] si es su líder; si no, avisa y devuelve null.
func _leader_party(peer: ServerPeer, now_tick: int) -> Party:
	var party: Party = _party_of.get(peer.peer_id)
	if party == null:
		_notify.call(peer, TEXT_NOT_IN_PARTY, now_tick)
		return null
	if party.leader != peer:
		_notify.call(peer, TEXT_NOT_LEADER, now_tick)
		return null
	return party


func _member_by_name(party: Party, target_name: String) -> ServerPeer:
	var key: String = NameRules.normalize_key(target_name)
	if key.is_empty():
		return null
	for member: ServerPeer in party.members:
		if SocialPeers.name_key_of(member) == key:
			return member
	return null


func _find_invitation(inviter: ServerPeer, target: ServerPeer) -> Invitation:
	for invitation: Invitation in _invitations:
		if invitation.inviter == inviter and invitation.target == target:
			return invitation
	return null


func _pending_from(inviter: ServerPeer) -> int:
	var count: int = 0
	for invitation: Invitation in _invitations:
		if invitation.inviter == inviter:
			count += 1
	return count


# Quita todas las invitaciones que tenía [param target] (ya está en un grupo) y le quita el aviso.
func _cancel_invitations_to(target: ServerPeer, now_tick: int) -> void:
	for invitation: Invitation in _invitations.duplicate():
		if invitation.target == target:
			_invitations.erase(invitation)
			_send_invitation(target, NetMessages.PartyInvitation.State.CANCELLED, now_tick,
					invitation.inviter)


func _create_party(leader: ServerPeer) -> Party:
	var party := Party.new()
	party.id = _next_party_id
	_next_party_id += 1
	party.leader = leader
	party.members.append(leader)
	_parties.append(party)
	_party_of[leader.peer_id] = party
	_stats["parties_created"] += 1
	return party


# Saca a [param peer] del grupo. [param left_text] es lo que se cuenta a los demás («X ha salido del
# grupo.»). Con [param tell_peer], el que sale recibe su lista vacía. Si quedan menos de dos, el grupo se
# disuelve; si se iba el líder, hereda el siguiente más antiguo.
func _remove_member(party: Party, peer: ServerPeer, now_tick: int, left_text: String,
		tell_peer: bool) -> void:
	party.members.erase(peer)
	_party_of.erase(peer.peer_id)
	if tell_peer:
		_send_roster_to(peer, null)
	_notify_members(party, left_text % peer.display_name, now_tick)
	if party.members.size() < 2:
		for member: ServerPeer in party.members:
			_party_of.erase(member.peer_id)
			_notify.call(member, TEXT_DISBANDED, now_tick)
			_send_roster_to(member, null)
		party.members.clear()
		_parties.erase(party)
		return
	if party.leader == peer:
		party.leader = party.members[0]
		_notify_members(party, TEXT_NEW_LEADER % party.leader.display_name, now_tick)
	_send_roster(party)


func _notify_members(party: Party, text: String, now_tick: int) -> void:
	for member: ServerPeer in party.members:
		_notify.call(member, text, now_tick)


func _send_roster(party: Party) -> void:
	for member: ServerPeer in party.members:
		_send_roster_to(member, party)


# La lista del grupo a [param peer]; con [param party] null, la lista vacía («ya no estás en un grupo»).
func _send_roster_to(peer: ServerPeer, party: Party) -> void:
	if peer.state != ServerPeer.State.IN_WORLD:
		return
	var roster := NetMessages.PartyRoster.new()
	if party != null:
		for i: int in party.members.size():
			var member: ServerPeer = party.members[i]
			roster.members.append(NetMessages.PartyRoster.Member.make(
					member.entity.net_id if member.entity != null else 0, member.display_name))
			if member == party.leader:
				roster.leader_index = i
	_send_sink.call(peer.peer_id, roster.encode())


func _send_invitation(target: ServerPeer, state: int, tick: int, inviter: ServerPeer) -> void:
	if target.state != ServerPeer.State.IN_WORLD:
		return
	var message := NetMessages.PartyInvitation.new()
	message.state = state
	message.tick = tick
	message.inviter = inviter.display_name
	_send_sink.call(target.peer_id, message.encode())


# El estado compacto de los miembros a todos ellos.
func _send_status(party: Party) -> void:
	var status := NetMessages.PartyStatus.new()
	var stamina_max: int = CombatCatalog.rules().stamina_max
	for member: ServerPeer in party.members:
		var entity: NetEntity = member.entity
		if entity == null:
			continue
		var stamina_q: int = 0
		var character: PlayerCharacter = entity.get_character()
		if character != null:
			stamina_q = PartyRules.quantize_stamina(character.combat.stamina, stamina_max)
		status.members.append(NetMessages.PartyStatus.MemberStatus.make(entity.net_id, entity.health_q,
				stamina_q, entity.status, entity.get_position()))
	if status.members.is_empty():
		return
	var bytes: PackedByteArray = status.encode()
	for member: ServerPeer in party.members:
		if member.state == ServerPeer.State.IN_WORLD:
			_send_sink.call(member.peer_id, bytes)
			_stats["status_sent"] += 1
