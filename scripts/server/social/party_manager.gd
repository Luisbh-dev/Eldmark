class_name PartyManager
extends RefCounted
## Zone server parties (SOC-06, docs/social.md, sections 3 and 12.4): invite, accept, decline, leave, kick and hand over
## leadership, and the compact state of the members.
## [br][br]
## [b]Rules.[/b] A party has at most [constant NetProtocol.PARTY_MAX_SIZE] players and belongs to [b]a single realm[/b]:
## inviting a player of another realm, or someone who does not exist, answers the same as a whisper ("no está
## conectado" (not connected)), does not warn the invitee nor reveal that they exist. The first is the leader and can
## kick and hand over leadership; any member can invite. If the leader leaves, the next oldest inherits leadership; a
## party of one disbands. An invitation to someone who ignores the inviter's account (docs/platform.md §9.3) is
## silently discarded: the inviter sees the usual and it expires, and nothing reaches the invitee nor can they accept it.
## An invitation expires after [constant PartyRules.INVITE_TTL_TICKS] ticks (60 s), each player can have at most
## [constant PartyRules.MAX_PENDING_PER_INVITER] sent and, when the party forms or grows, the other invitations held by
## whoever accepts and, if the party is new, by whoever invited, are cancelled. Inviting has its own bucket (1 every 2 s,
## burst of 3); what is discarded warns the player (at most once per second) and, after the first
## [constant ChatPeerState.FLOOD_FREE_DISCARDS] in each 10 s, each discard adds a strike to the peer.
## [br][br]
## [b]What is sent.[/b] Each result reaches the player as a system channel message ([code]notify[/code]); the interface
## also receives PARTY_INVITATION (the invitation, and when it stops being valid), PARTY_ROSTER (the member list and the
## leader, every time it changes; empty on leaving) and PARTY_STATUS (health, stamina and position of each member) at
## 2 Hz ([constant PartyRules.STATUS_INTERVAL_TICKS]) to all members, wherever they are: it does not go through the
## snapshots' interest. Each party sends it on its tick of the interval ([method is_status_tick], staggered by the party
## id), like snapshots by net_id parity: so the cost is spread over the 30 ticks and does not fall entirely on one.
## [br][br]
## It touches neither the network nor the clock: it receives from [SocialService] four [Callable]s
## ([code]peers_source() -> Array[ServerPeer][/code], [code]send_sink(peer_id: int, bytes: PackedByteArray)[/code],
## [code]strike_sink(peer: ServerPeer, reason: String)[/code] and [code]notify(peer: ServerPeer, text: String, now_tick:
## int)[/code]) and the tick on each call.

const STRIKE_REASON_MALFORMED: String = "mensaje de grupo mal formado"
const STRIKE_REASON_NOT_IN_WORLD: String = "grupo antes de entrar en el mundo"
const STRIKE_REASON_FLOOD: String = "exceso de invitaciones de grupo"

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


## A party: its members in order of arrival and who leads.
class Party:
	extends RefCounted

	var id: int = 0
	var members: Array[ServerPeer] = []
	var leader: ServerPeer = null


## A pending invitation.
class Invitation:
	extends RefCounted

	var inviter: ServerPeer = null
	var target: ServerPeer = null
	var expire_tick: int = 0
	## The invitee ignores the inviter's account: nothing is sent to them and they cannot accept it.
	var hidden: bool = false


var _peers_source: Callable
var _send_sink: Callable
var _strike_sink: Callable
var _notify: Callable
var _parties: Array[Party] = []
# peer_id -> its party.
var _party_of: Dictionary[int, Party] = {}
var _invitations: Array[Invitation] = []
var _next_party_id: int = 1
var _stats: Dictionary = {"parties_created": 0, "invitations": 0, "accepted": 0, "declined": 0,
		"expired": 0, "kicks": 0, "status_sent": 0, "rate_limited": 0, "ignored": 0}


func _init(peers_source: Callable, send_sink: Callable, strike_sink: Callable, notify: Callable) -> void:
	_peers_source = peers_source
	_send_sink = send_sink
	_strike_sink = strike_sink
	_notify = notify


# --- Input ----------------------------------------------------------------------------------

## Handles the message [param bytes] of type [param msg_type] from [param peer] at tick [param now_tick]. Returns false
## if the type is not one a client sends (PARTY_INVITE to PARTY_LEADER): the caller decides what to do with an
## unexpected type. A malformed message, or one from someone not yet in the world, adds a strike.
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


# --- Actions ---------------------------------------------------------------------------------

## [param peer] invites [param target_name] (a player of its realm) to its party.
func invite(peer: ServerPeer, target_name: String, now_tick: int) -> void:
	var state: ChatPeerState = peer.chat
	if not state.limiter_invites.try_consume(now_tick):
		state.invite_discards += 1
		_stats["rate_limited"] += 1
		if state.last_invite_warning_tick < 0 \
				or now_tick - state.last_invite_warning_tick >= ChatRouter.WARNING_INTERVAL_TICKS:
			state.last_invite_warning_tick = now_tick
			_notify.call(peer, TEXT_TOO_FAST, now_tick)
		if state.invite_flood.note(now_tick):
			_strike_sink.call(peer, STRIKE_REASON_FLOOD)
		return
	var target: ServerPeer = SocialPeers.find_by_name(_world_peers(), target_name, peer.realm)
	if target == null:
		# Same for whoever does not exist and for an enemy: nothing reveals which of the two it is, and nothing reaches the
		# enemy.
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
	# Whoever ignores the inviter's account receives nothing, and the inviter does not know it (§9.3).
	invitation.hidden = SocialPeers.ignores(target, peer)
	_invitations.append(invitation)
	_stats["invitations"] += 1
	_notify.call(peer, TEXT_INVITED % target.display_name, now_tick)
	if invitation.hidden:
		_stats["ignored"] += 1
		return
	_send_invitation(target, NetMessages.PartyInvitation.State.OFFERED, invitation.expire_tick, peer)
	_notify.call(target, TEXT_INVITED_YOU % peer.display_name, now_tick)


## [param peer] responds to the invitation from [param inviter_name]: accepts or declines it.
func respond(peer: ServerPeer, inviter_name: String, accept: bool, now_tick: int) -> void:
	var key: String = NameRules.normalize_key(inviter_name)
	var invitation: Invitation = null
	for candidate: Invitation in _invitations:
		if candidate.target == peer and not candidate.hidden and SocialPeers.name_key_of(candidate.inviter) == key:
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
		# Whoever invited has just entered a party: their received invitations stop being valid, like those of whoever accepts
		# (nobody has invitations while in a party; invite() does not create them).
		_cancel_invitations_to(inviter, now_tick)
	party.members.append(peer)
	_party_of[peer.peer_id] = party
	_stats["accepted"] += 1
	_cancel_invitations_to(peer, now_tick)
	_notify_members(party, TEXT_JOINED % peer.display_name, now_tick)
	_send_roster(party)


## [param peer] leaves its party.
func leave(peer: ServerPeer, now_tick: int) -> void:
	var party: Party = _party_of.get(peer.peer_id)
	if party == null:
		_notify.call(peer, TEXT_NOT_IN_PARTY, now_tick)
		return
	_notify.call(peer, TEXT_YOU_LEFT, now_tick)
	_remove_member(party, peer, now_tick, TEXT_LEFT, true)


## The leader [param peer] kicks [param target_name] from their party.
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


## The leader [param peer] hands leadership over to [param target_name].
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


## [param peer] leaves the zone (disconnection, server kick): it leaves its party and the invitations it sent or
## received are cancelled. Nothing is sent to it: it is gone.
func on_peer_left(peer: ServerPeer, now_tick: int) -> void:
	for invitation: Invitation in _invitations.duplicate():
		if invitation.inviter == peer:
			_invitations.erase(invitation)
			if not invitation.hidden:
				_send_invitation(invitation.target, NetMessages.PartyInvitation.State.CANCELLED, now_tick, peer)
		elif invitation.target == peer:
			_invitations.erase(invitation)
	var party: Party = _party_of.get(peer.peer_id)
	if party != null:
		_remove_member(party, peer, now_tick, TEXT_LEFT, false)


## One server tick: expires overdue invitations and, at 2 Hz, sends each party's members' state on its tick
## ([method is_status_tick]).
func step(now_tick: int) -> void:
	for invitation: Invitation in _invitations.duplicate():
		if invitation.expire_tick <= now_tick:
			_invitations.erase(invitation)
			_stats["expired"] += 1
			if not invitation.hidden:
				_send_invitation(invitation.target, NetMessages.PartyInvitation.State.EXPIRED, now_tick,
						invitation.inviter)
			_notify.call(invitation.inviter, TEXT_EXPIRED % invitation.target.display_name, now_tick)
	for party: Party in _parties:
		if is_status_tick(party.id, now_tick):
			_send_status(party)


## true if party [param party_id] sends its PARTY_STATUS at tick [param now_tick]: one out of every
## [constant PartyRules.STATUS_INTERVAL_TICKS], staggered by id so they do not all go out together.
static func is_status_tick(party_id: int, now_tick: int) -> bool:
	return posmod(now_tick + party_id, PartyRules.STATUS_INTERVAL_TICKS) == 0


# --- Queries --------------------------------------------------------------------------------

## The members of the party of [param peer], in order of arrival (empty if it has none).
func members_of(peer: ServerPeer) -> Array[ServerPeer]:
	var party: Party = _party_of.get(peer.peer_id)
	if party == null:
		return []
	return party.members.duplicate()


## The leader of the party of [param peer] (null if it has no party).
func leader_of(peer: ServerPeer) -> ServerPeer:
	var party: Party = _party_of.get(peer.peer_id)
	return party.leader if party != null else null


## Id of the party of [param peer] (0 if it has no party); with it, [method is_status_tick] says when its PARTY_STATUS is
## due.
func party_id_of(peer: ServerPeer) -> int:
	var party: Party = _party_of.get(peer.peer_id)
	return party.id if party != null else 0


func get_party_count() -> int:
	return _parties.size()


## Pending invitations across the whole server.
func get_pending_count() -> int:
	return _invitations.size()


## Pending invitations that [param peer] has sent.
func get_pending_from(peer: ServerPeer) -> int:
	return _pending_from(peer)


## Statistics for the report: parties created, invitations sent, accepted, declined, expired, discarded by rate and
## silently discarded because the invitee ignores the inviter, kicks and states sent.
func get_stats() -> Dictionary:
	var stats: Dictionary = _stats.duplicate()
	stats["parties"] = _parties.size()
	stats["pending"] = _invitations.size()
	return stats


# --- Internal pieces --------------------------------------------------------------------------

func _world_peers() -> Array[ServerPeer]:
	var peers: Array[ServerPeer] = _peers_source.call()
	return SocialPeers.in_world(peers)


# The party of [param peer] if it is its leader; otherwise, warns and returns null.
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


# Removes all invitations that [param target] had (it is already in a party) and removes their warnings.
func _cancel_invitations_to(target: ServerPeer, now_tick: int) -> void:
	for invitation: Invitation in _invitations.duplicate():
		if invitation.target == target:
			_invitations.erase(invitation)
			if not invitation.hidden:
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


# Removes [param peer] from the party. [param left_text] is what is told to the others ("X ha salido del grupo." (X has
# left the party)). With [param tell_peer], the one leaving receives its empty list. If fewer than two remain, the party
# disbands; if the leader was leaving, the next oldest inherits.
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


# The party list to [param peer]; with [param party] null, the empty list ("ya no estás en un grupo" (you are no longer
# in a party)).
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


# The members' compact state to all of them.
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
