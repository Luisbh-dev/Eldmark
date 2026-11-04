extends TestCase
## Tests of the server's parties ([PartyManager] inside [SocialService], SOC-06, docs/social.md
## sections 3 and 12.4) without a network: fake peers and a [Callable] that records what would be
## sent to each one. All the flows are checked (invite, accept, decline, expire, leave, kick, hand
## over leadership, disconnection), the caps (5 members, 5 pending invitations, the invite rate),
## that an enemy cannot be invited nor finds out, the inherited leader, the chat party channel and
## the members' state at 2 Hz even when they are far away. The test with ENet clients is
## test_party_loopback.gd.

const VARDHEIM: int = NetProtocol.Realm.VARDHEIM
const SOLMARCH: int = NetProtocol.Realm.SOLMARCH
const PLAYER_SCENE: PackedScene = preload("res://scenes/characters/player_character.tscn")

var _service: SocialService
var _party: PartyManager
var _peers: Array[ServerPeer] = []
var _nodes: Array[Node3D] = []
# peer_id -> the bytes that would be sent to it, in order.
var _raw_inbox: Dictionary = {}
var _strikes: Array = []
var _next_id: int = 1


func before_each() -> void:
	_peers.clear()
	_nodes.clear()
	_raw_inbox.clear()
	_strikes.clear()
	_next_id = 1
	_service = SocialService.new(func() -> Array[ServerPeer]: return _peers,
			func(peer_id: int, bytes: PackedByteArray) -> void: _on_send(peer_id, bytes),
			func(peer: ServerPeer, reason: String) -> void: _strikes.append([peer.peer_id, reason]))
	_party = _service.get_party()


func after_each() -> void:
	_party = null
	_service = null
	for node: Node3D in _nodes:
		node.free()
	_nodes.clear()
	_peers.clear()


# --- Helpers ----------------------------------------------------------------------------------

func _on_send(peer_id: int, bytes: PackedByteArray) -> void:
	if not _raw_inbox.has(peer_id):
		_raw_inbox[peer_id] = []
	_raw_inbox[peer_id].append(bytes)


func _add_peer(player_name: String, realm: int = VARDHEIM, position: Vector3 = Vector3.ZERO,
		with_character: bool = false) -> ServerPeer:
	var peer := ServerPeer.new(_next_id)
	_next_id += 1
	peer.state = ServerPeer.State.IN_WORLD
	peer.display_name = player_name
	peer.realm = realm
	var node: Node3D = PLAYER_SCENE.instantiate() as Node3D if with_character else Node3D.new()
	node.position = position
	_nodes.append(node)
	var entity := NetEntity.new()
	entity.net_id = 100 + peer.peer_id
	entity.kind = NetProtocol.EntityKind.PLAYER
	entity.realm = realm
	entity.display_name = player_name
	entity.node = node
	peer.entity = entity
	_peers.append(peer)
	return peer


func _packets(peer: ServerPeer, msg_type: int) -> Array[PackedByteArray]:
	var found: Array[PackedByteArray] = []
	for bytes: PackedByteArray in _raw_inbox.get(peer.peer_id, []):
		if NetMessages.peek_type(bytes) == msg_type:
			found.append(bytes)
	return found


func _system_texts(peer: ServerPeer) -> PackedStringArray:
	var texts := PackedStringArray()
	for bytes: PackedByteArray in _packets(peer, NetProtocol.MSG_CHAT_MESSAGE):
		var message: NetMessages.ChatMessage = NetMessages.ChatMessage.decode(bytes)
		if message != null and message.channel == ChatChannel.Id.SYSTEM:
			texts.append(message.text)
	return texts


func _last_system(peer: ServerPeer) -> String:
	var texts: PackedStringArray = _system_texts(peer)
	return texts[texts.size() - 1] if not texts.is_empty() else ""


func _rosters(peer: ServerPeer) -> Array[NetMessages.PartyRoster]:
	var rosters: Array[NetMessages.PartyRoster] = []
	for bytes: PackedByteArray in _packets(peer, NetProtocol.MSG_PARTY_ROSTER):
		rosters.append(NetMessages.PartyRoster.decode(bytes))
	return rosters


func _last_roster(peer: ServerPeer) -> NetMessages.PartyRoster:
	var rosters: Array[NetMessages.PartyRoster] = _rosters(peer)
	return rosters[rosters.size() - 1] if not rosters.is_empty() else null


func _invitations(peer: ServerPeer) -> Array[NetMessages.PartyInvitation]:
	var found: Array[NetMessages.PartyInvitation] = []
	for bytes: PackedByteArray in _packets(peer, NetProtocol.MSG_PARTY_INVITATION):
		found.append(NetMessages.PartyInvitation.decode(bytes))
	return found


func _roster_names(peer: ServerPeer) -> PackedStringArray:
	var names := PackedStringArray()
	var roster: NetMessages.PartyRoster = _last_roster(peer)
	if roster != null:
		for member: NetMessages.PartyRoster.Member in roster.members:
			names.append(member.display_name)
	return names


# An Array[ServerPeer] with [param list] (to compare with the members of a party).
func _ps(list: Array) -> Array[ServerPeer]:
	var result: Array[ServerPeer] = []
	for peer: ServerPeer in list:
		result.append(peer)
	return result


# First tick from [param from_tick] (included) at which party [param party_id] sends its state.
func _status_tick_from(party_id: int, from_tick: int) -> int:
	var tick: int = from_tick
	while not PartyManager.is_status_tick(party_id, tick):
		tick += 1
	return tick


# Joins [param joiners] to [param leader]'s party (invitations and acceptances spaced out so as not
# to exceed the rates).
func _form_party(leader: ServerPeer, joiners: Array[ServerPeer], start_tick: int = 100) -> int:
	var tick: int = start_tick
	for joiner: ServerPeer in joiners:
		_party.invite(leader, joiner.display_name, tick)
		_party.respond(joiner, leader.display_name, true, tick)
		tick += 130
	return tick


# --- Inviting and accepting -------------------------------------------------------------------

func test_invite_and_accept_form_a_party() -> void:
	var ana: ServerPeer = _add_peer("Ana")
	var bruno: ServerPeer = _add_peer("Bruno")
	_party.invite(ana, "bruno", 100)
	assert_eq(_last_system(ana), "Has invitado a Bruno al grupo.", "the inviter knows it")
	var offers: Array[NetMessages.PartyInvitation] = _invitations(bruno)
	if not assert_eq(offers.size(), 1, "Bruno receives the invitation"):
		return
	assert_eq(offers[0].state, NetMessages.PartyInvitation.State.OFFERED, "new")
	assert_eq(offers[0].inviter, "Ana", "from Ana")
	assert_eq(offers[0].tick, 100 + PartyRules.INVITE_TTL_TICKS, "expires after 60 s")
	assert_eq(_last_system(bruno), "Ana te ha invitado a su grupo.", "and sees it in the chat")
	assert_eq(_party.get_pending_count(), 1, "one pending")
	assert_eq(_party.get_party_count(), 0, "there is no party yet")

	_party.respond(bruno, "ANA", true, 200)
	assert_eq(_party.get_party_count(), 1, "the party is created")
	assert_eq(_party.get_pending_count(), 0, "and the invitation is consumed")
	assert_eq(_party.members_of(ana), _ps([ana, bruno]), "Ana leads and Bruno is second")
	assert_eq(_party.leader_of(bruno), ana, "the leader is Ana")
	for peer: ServerPeer in [ana, bruno]:
		var roster: NetMessages.PartyRoster = _last_roster(peer)
		if not assert_not_null(roster, "%s receives the list" % peer.display_name):
			continue
		assert_eq(roster.leader_index, 0, "the leader is the first")
		assert_eq(roster.members.size(), 2, "two members")
		assert_eq(roster.members[0].display_name, "Ana", "Ana first")
		assert_eq(roster.members[0].net_id, ana.entity.net_id, "with her net_id")
		assert_eq(roster.members[1].display_name, "Bruno", "then Bruno")
		assert_eq(_last_system(peer), "Bruno se ha unido al grupo.", "and both read it")
	# The invitation is removed from Bruno's prompt.
	var offers_after: Array[NetMessages.PartyInvitation] = _invitations(bruno)
	assert_eq(offers_after[offers_after.size() - 1].state, NetMessages.PartyInvitation.State.CANCELLED,
			"Bruno's prompt is withdrawn")


func test_decline_tells_the_inviter_and_clears_the_prompt() -> void:
	var ana: ServerPeer = _add_peer("Ana")
	var bruno: ServerPeer = _add_peer("Bruno")
	_party.invite(ana, "Bruno", 100)
	_party.respond(bruno, "Ana", false, 150)
	assert_eq(_last_system(ana), "Bruno ha rechazado tu invitación.", "Ana knows it")
	assert_eq(_party.get_party_count(), 0, "without a party")
	assert_eq(_party.get_pending_count(), 0, "without pending ones")
	var offers: Array[NetMessages.PartyInvitation] = _invitations(bruno)
	assert_eq(offers[offers.size() - 1].state, NetMessages.PartyInvitation.State.CANCELLED, "prompt withdrawn")
	assert_eq(_party.get_stats()["declined"], 1, "it is counted")


func test_an_invitation_expires_after_sixty_seconds() -> void:
	var ana: ServerPeer = _add_peer("Ana")
	var bruno: ServerPeer = _add_peer("Bruno")
	_party.invite(ana, "Bruno", 100)
	_party.step(100 + PartyRules.INVITE_TTL_TICKS - 1)
	assert_eq(_party.get_pending_count(), 1, "one tick earlier it is still valid")
	_party.step(100 + PartyRules.INVITE_TTL_TICKS)
	assert_eq(_party.get_pending_count(), 0, "at 3600 ticks it expires")
	var offers: Array[NetMessages.PartyInvitation] = _invitations(bruno)
	assert_eq(offers[offers.size() - 1].state, NetMessages.PartyInvitation.State.EXPIRED, "Bruno knows it")
	assert_eq(_last_system(ana), "La invitación a Bruno ha caducado.", "and Ana")
	_party.respond(bruno, "Ana", true, 100 + PartyRules.INVITE_TTL_TICKS + 5)
	assert_eq(_last_system(bruno), "No tienes ninguna invitación de «Ana».", "accepting late is not valid")
	assert_eq(_party.get_party_count(), 0, "without a party")


func test_inviting_an_enemy_or_nobody_gets_the_same_answer_and_tells_nobody() -> void:
	var ana: ServerPeer = _add_peer("Ana")
	var cora: ServerPeer = _add_peer("Cora", SOLMARCH)
	_party.invite(ana, "Cora", 100)
	_party.invite(ana, "Nadie", 300)
	assert_eq(_system_texts(ana), PackedStringArray(["«Cora» no está conectado.",
			"«Nadie» no está conectado."]), "the same reply, with what the player typed")
	assert_false(_raw_inbox.has(cora.peer_id), "the enemy receives no packet")
	assert_eq(_party.get_pending_count(), 0, "no invitation is left")
	# A reply from the enemy to an invitation that does not exist does nothing.
	_party.respond(cora, "Ana", true, 400)
	assert_eq(_party.get_party_count(), 0, "there is no party across realms")
	assert_eq(_last_system(cora), "No tienes ninguna invitación de «Ana».", "and it is told there is no invitation")
	assert_true(_system_texts(ana).size() == 2, "Ana learns nothing more")


func test_invalid_invitations_are_refused_with_a_reason() -> void:
	var ana: ServerPeer = _add_peer("Ana")
	var bruno: ServerPeer = _add_peer("Bruno")
	var cora: ServerPeer = _add_peer("Cora")
	_party.invite(ana, "ana", 100)
	assert_eq(_last_system(ana), PartyManager.TEXT_SELF_INVITE, "to oneself")
	_party.invite(ana, "Bruno", 300)
	_party.invite(ana, "Bruno", 500)
	assert_eq(_last_system(ana), "Ya has invitado a Bruno.", "twice to the same person")
	assert_eq(_party.get_pending_count(), 1, "only one invitation")
	# Cora is already in a party (with Bruno): she cannot be invited.
	_party.respond(bruno, "Ana", true, 600)
	_party.invite(bruno, "Cora", 800)
	_party.respond(cora, "Bruno", true, 900)
	_party.invite(ana, "Cora", 1100)
	assert_eq(_last_system(ana), "Cora ya está en tu grupo.", "to someone in your party")
	var dani: ServerPeer = _add_peer("Dani")
	var eva: ServerPeer = _add_peer("Eva")
	_party.invite(dani, "Eva", 100)
	_party.respond(eva, "Dani", true, 150)
	_party.invite(dani, "Ana", 400)
	_party.invite(ana, "Dani", 700)
	assert_eq(_last_system(ana), "Dani ya está en un grupo.", "to someone in another party")


func test_a_party_has_at_most_five_members() -> void:
	var leader: ServerPeer = _add_peer("Lider")
	var joiners: Array[ServerPeer] = []
	for i: int in 4:
		joiners.append(_add_peer("Miembro%s" % char(97 + i)))
	var tick: int = _form_party(leader, joiners)
	assert_eq(_party.members_of(leader).size(), NetProtocol.PARTY_MAX_SIZE, "five members")
	assert_eq(NetProtocol.PARTY_MAX_SIZE, 5, "the shared cap is 5")
	var sixth: ServerPeer = _add_peer("Sexto")
	_party.invite(leader, "Sexto", tick)
	assert_eq(_last_system(leader), "Tu grupo está completo (máximo 5).", "a sixth cannot be invited")
	assert_false(_raw_inbox.has(sixth.peer_id), "and the sixth receives nothing")
	# An invitation made before the party filled up fails when accepted.
	var late: ServerPeer = _add_peer("Tarde")
	var second_leader: ServerPeer = joiners[0]
	_party.invite(second_leader, "Tarde", tick + 300)
	assert_eq(_last_system(second_leader), "Tu grupo está completo (máximo 5).", "nor does another member")
	assert_eq(_party.get_pending_count(), 0, "without invitations")
	assert_false(_raw_inbox.has(late.peer_id), "and Tarde receives nothing")


func test_an_invitation_sent_before_the_party_filled_up_fails_when_accepted() -> void:
	var leader: ServerPeer = _add_peer("Lider")
	var late: ServerPeer = _add_peer("Tarde")
	# Tarde is invited when the party still has room...
	_party.invite(leader, "Tarde", 100)
	# ...and it fills up before they reply.
	var joiners: Array[ServerPeer] = []
	for i: int in 4:
		joiners.append(_add_peer("Miembro%s" % char(97 + i)))
	_form_party(leader, joiners, 300)
	assert_eq(_party.members_of(leader).size(), 5, "five members")
	_party.respond(late, "Lider", true, 2000)
	assert_eq(_last_system(late), PartyManager.TEXT_PARTY_FULL, "the party is full")
	assert_eq(_party.members_of(leader).size(), 5, "does not get in")


func test_each_player_has_at_most_five_pending_invitations() -> void:
	var ana: ServerPeer = _add_peer("Ana")
	var targets: Array[ServerPeer] = []
	for i: int in 6:
		targets.append(_add_peer("Objetivo%s" % char(97 + i)))
	var tick: int = 100
	for i: int in 5:
		_party.invite(ana, targets[i].display_name, tick)
		tick += 130
	assert_eq(_party.get_pending_from(ana), PartyRules.MAX_PENDING_PER_INVITER, "five pending")
	_party.invite(ana, targets[5].display_name, tick)
	assert_eq(_last_system(ana), "Tienes demasiadas invitaciones pendientes.", "the sixth does not")
	assert_false(_raw_inbox.has(targets[5].peer_id), "and the sixth person receives nothing")
	# When one expires there is room again.
	_party.step(100 + PartyRules.INVITE_TTL_TICKS)
	assert_eq(_party.get_pending_from(ana), 4, "one expired")
	_party.invite(ana, targets[5].display_name, tick + PartyRules.INVITE_TTL_TICKS)
	assert_eq(_party.get_pending_from(ana), 5, "and another can be invited")


func test_inviting_has_its_own_rate_limit_and_flooding_adds_strikes() -> void:
	var ana: ServerPeer = _add_peer("Ana")
	for i: int in 4:
		_add_peer("Blanco%s" % char(97 + i))
	for i: int in 3:
		_party.invite(ana, "Blanco%s" % char(97 + i), 100)
	assert_eq(_party.get_pending_count(), 3, "the burst admits three")
	_party.invite(ana, "Blancod", 100)
	assert_eq(_last_system(ana), "Invitas demasiado rápido.", "the fourth is dropped")
	assert_eq(_party.get_pending_count(), 3, "and it is not created")
	assert_true(_strikes.is_empty(), "a drop adds no warnings")
	# Twenty drops on the same tick: a single warning to the player and, past the ten free ones, one
	# for the peer per drop.
	for i: int in 19:
		_party.invite(ana, "Blancod", 100)
	assert_eq(_system_texts(ana).count("Invitas demasiado rápido."), 1,
			"a single \"Invitas demasiado rápido.\" (inviting too fast) per second, not one per drop")
	assert_eq(_strikes.size(), 20 - ChatPeerState.FLOOD_FREE_DISCARDS, "ten warnings for the peer")
	assert_eq(_strikes[0], [ana.peer_id, PartyManager.STRIKE_REASON_FLOOD], "for flooding")
	# One second later, if it still does not fit, another warning to the player.
	_party.invite(ana, "Blancod", 100 + ChatRouter.WARNING_INTERVAL_TICKS)
	assert_eq(_system_texts(ana).count("Invitas demasiado rápido."), 2, "one second later, another")
	# After 2 s one fits again.
	_party.invite(ana, "Blancod", 100 + 120)
	assert_eq(_party.get_pending_count(), 4, "2 s later, another")


func test_accepting_one_invitation_cancels_the_others() -> void:
	var ana: ServerPeer = _add_peer("Ana")
	var bruno: ServerPeer = _add_peer("Bruno")
	var cora: ServerPeer = _add_peer("Cora")
	_party.invite(ana, "Cora", 100)
	_party.invite(bruno, "Cora", 100)
	assert_eq(_party.get_pending_count(), 2, "two invitations to Cora")
	_party.respond(cora, "Ana", true, 200)
	assert_eq(_party.get_pending_count(), 0, "on accepting one, the other is cancelled")
	var offers: Array[NetMessages.PartyInvitation] = _invitations(cora)
	var cancelled: int = 0
	for offer: NetMessages.PartyInvitation in offers:
		if offer.state == NetMessages.PartyInvitation.State.CANCELLED:
			cancelled += 1
	assert_eq(cancelled, 2, "Cora's two prompts are withdrawn")
	assert_eq(_party.members_of(cora), _ps([ana, cora]), "Cora is with Ana")


func test_forming_a_party_cancels_the_inviters_received_invitations() -> void:
	var ana: ServerPeer = _add_peer("Ana")
	var bea: ServerPeer = _add_peer("Bea")
	var eva: ServerPeer = _add_peer("Eva")
	_party.invite(eva, "Ana", 100)
	_party.invite(ana, "Bea", 230)
	_party.respond(bea, "Ana", true, 360)
	assert_eq(_party.members_of(ana), _ps([ana, bea]), "Ana and Bea form a party")
	assert_eq(_party.get_pending_count(), 0, "Eva's invitation to Ana stops being valid")
	assert_eq(_party.get_pending_from(eva), 0, "and Eva gets her pending slot back")
	var offers: Array[NetMessages.PartyInvitation] = _invitations(ana)
	var last: NetMessages.PartyInvitation = offers[offers.size() - 1]
	assert_eq(last.state, NetMessages.PartyInvitation.State.CANCELLED, "Ana's prompt is withdrawn")
	assert_eq(last.inviter, "Eva", "Eva's")
	_party.respond(ana, "Eva", true, 400)
	assert_eq(_last_system(ana), "No tienes ninguna invitación de «Eva».", "it can no longer be accepted")
	assert_eq(_party.members_of(ana).size(), 2, "and Ana stays in her party")


# --- Leaving, kicking and leadership ---------------------------------------------------------

func test_the_next_oldest_inherits_the_lead_when_the_leader_leaves() -> void:
	var ana: ServerPeer = _add_peer("Ana")
	var bruno: ServerPeer = _add_peer("Bruno")
	var cora: ServerPeer = _add_peer("Cora")
	_form_party(ana, [bruno, cora])
	_party.leave(ana, 1000)
	assert_eq(_party.leader_of(bruno), bruno, "Bruno, the next oldest, is in charge")
	assert_eq(_party.members_of(bruno), _ps([bruno, cora]), "Bruno and Cora remain")
	assert_eq(_party.members_of(ana).size(), 0, "Ana no longer has a party")
	assert_eq(_roster_names(bruno), PackedStringArray(["Bruno", "Cora"]), "new list")
	assert_eq(_last_roster(bruno).leader_index, 0, "the leader is the first")
	assert_true(_last_roster(ana).is_empty(), "Ana receives the empty list")
	assert_true(_system_texts(bruno).has("Ana ha salido del grupo."), "it is counted")
	assert_eq(_last_system(bruno), "Bruno es ahora el líder del grupo.", "and who is in charge")
	assert_eq(_system_texts(ana)[_system_texts(ana).size() - 1], "Has salido del grupo.", "Ana knows it")


func test_a_party_of_one_is_disbanded() -> void:
	var ana: ServerPeer = _add_peer("Ana")
	var bruno: ServerPeer = _add_peer("Bruno")
	_form_party(ana, [bruno])
	_party.leave(bruno, 1000)
	assert_eq(_party.get_party_count(), 0, "it dissolves")
	assert_eq(_party.members_of(ana).size(), 0, "Ana no longer has a party")
	assert_true(_last_roster(ana).is_empty(), "Ana receives the empty list")
	assert_true(_last_roster(bruno).is_empty(), "and Bruno")
	assert_eq(_last_system(ana), "El grupo se ha disuelto.", "prompt")
	assert_true(_system_texts(ana).has("Bruno ha salido del grupo."), "and who left")
	# Another one can be formed.
	_party.invite(ana, "Bruno", 2000)
	_party.respond(bruno, "Ana", true, 2010)
	assert_eq(_party.get_party_count(), 1, "another party")
	_party.leave(ana, 3000)
	_party.leave(ana, 3001)
	assert_eq(_last_system(ana), "No estás en un grupo.", "leaving without a party")


func test_only_the_leader_can_kick_and_the_kicked_is_told() -> void:
	var ana: ServerPeer = _add_peer("Ana")
	var bruno: ServerPeer = _add_peer("Bruno")
	var cora: ServerPeer = _add_peer("Cora")
	_form_party(ana, [bruno, cora])
	_party.kick(bruno, "Cora", 1000)
	assert_eq(_last_system(bruno), "Solo el líder puede hacer eso.", "a member does not kick")
	assert_eq(_party.members_of(ana).size(), 3, "nobody leaves")
	_party.kick(ana, "ana", 1010)
	assert_eq(_last_system(ana), "Para salir del grupo usa /salir.", "one does not kick oneself")
	_party.kick(ana, "Nadie", 1020)
	assert_eq(_last_system(ana), "«Nadie» no está en tu grupo.", "nor someone who is not there")
	_party.kick(ana, "cora", 1030)
	assert_eq(_party.members_of(ana), _ps([ana, bruno]), "the leader kicks Cora")
	assert_true(_last_roster(cora).is_empty(), "Cora receives the empty list")
	assert_eq(_system_texts(cora)[_system_texts(cora).size() - 1], "Has sido expulsado del grupo.", "and knows it")
	assert_true(_system_texts(ana).has("Cora ha sido expulsado del grupo."), "the others too")
	assert_eq(_party.get_stats()["kicks"], 1, "it is counted")
	var dani: ServerPeer = _add_peer("Dani")
	_party.kick(dani, "Ana", 1040)
	assert_eq(_last_system(dani), "No estás en un grupo.", "without a party")


func test_the_leader_can_hand_over_the_lead() -> void:
	var ana: ServerPeer = _add_peer("Ana")
	var bruno: ServerPeer = _add_peer("Bruno")
	var cora: ServerPeer = _add_peer("Cora")
	_form_party(ana, [bruno, cora])
	_party.set_leader(bruno, "Cora", 1000)
	assert_eq(_last_system(bruno), "Solo el líder puede hacer eso.", "a member does not hand over leadership")
	_party.set_leader(ana, "ana", 1010)
	assert_eq(_last_system(ana), "Ya eres el líder.", "to oneself")
	_party.set_leader(ana, "Nadie", 1020)
	assert_eq(_last_system(ana), "«Nadie» no está en tu grupo.", "to someone who is not there")
	_party.set_leader(ana, "Cora", 1030)
	assert_eq(_party.leader_of(ana), cora, "Cora is in charge")
	var roster: NetMessages.PartyRoster = _last_roster(bruno)
	assert_eq(roster.leader_index, 2, "in the list, the leader is the third")
	assert_eq(roster.get_leader_id(), cora.entity.net_id, "with her net_id")
	assert_eq(roster.members[0].display_name, "Ana", "the order does not change")
	assert_eq(_last_system(bruno), "Cora es ahora el líder del grupo.", "prompt")
	# The new leader kicks; the old one no longer can.
	_party.kick(ana, "Bruno", 1040)
	assert_eq(_last_system(ana), "Solo el líder puede hacer eso.", "Ana can no longer")
	_party.kick(cora, "Bruno", 1050)
	assert_eq(_party.members_of(cora), _ps([ana, cora]), "Cora can")


func test_leaving_the_zone_removes_the_player_and_cancels_invitations() -> void:
	var ana: ServerPeer = _add_peer("Ana")
	var bruno: ServerPeer = _add_peer("Bruno")
	var cora: ServerPeer = _add_peer("Cora")
	var dani: ServerPeer = _add_peer("Dani")
	_form_party(ana, [bruno, cora])
	_party.invite(ana, "Dani", 2000)
	# Bruno disconnects.
	bruno.state = ServerPeer.State.LEAVING
	_party.on_peer_left(bruno, 2100)
	assert_eq(_party.members_of(ana), _ps([ana, cora]), "Bruno leaves the party")
	assert_true(_system_texts(ana).has("Bruno ha salido del grupo."), "it is counted")
	# Ana, the leader, disconnects: the invitations she sent are cancelled and Cora inherits.
	ana.state = ServerPeer.State.LEAVING
	_party.on_peer_left(ana, 2200)
	assert_eq(_party.get_pending_count(), 0, "without pending invitations")
	var offers: Array[NetMessages.PartyInvitation] = _invitations(dani)
	assert_eq(offers[offers.size() - 1].state, NetMessages.PartyInvitation.State.CANCELLED, "Dani has no prompt")
	assert_eq(_party.get_party_count(), 0, "Cora is left alone: the party dissolves")
	assert_true(_last_roster(cora).is_empty(), "empty list")
	_party.respond(dani, "Ana", true, 2300)
	assert_eq(_last_system(dani), "No tienes ninguna invitación de «Ana».", "it can no longer be accepted")


# --- Compact state ----------------------------------------------------------------------------

func test_member_status_is_sent_at_2_hz_even_to_far_members() -> void:
	var ana: ServerPeer = _add_peer("Ana", VARDHEIM, Vector3(0.0, 0.0, 0.0), true)
	var bruno: ServerPeer = _add_peer("Bruno", VARDHEIM, Vector3(250.0, 3.0, -40.0), true)
	var outsider: ServerPeer = _add_peer("Fuera")
	_form_party(ana, [bruno])
	bruno.entity.set_health_view(500, 1000, NetMessages.STATUS_IN_COMBAT, 0)
	ana.entity.set_health_view(1000, 1000, 0, 0)
	var before: int = _packets(ana, NetProtocol.MSG_PARTY_STATUS).size()
	var first: int = _status_tick_from(_party.party_id_of(ana), 1000)
	_party.step(first - 1)
	assert_eq(_packets(ana, NetProtocol.MSG_PARTY_STATUS).size(), before, "it is not sent outside its tick")
	_party.step(first)
	assert_eq(_packets(ana, NetProtocol.MSG_PARTY_STATUS).size(), before + 1, "on its tick, one")
	assert_eq(_packets(bruno, NetProtocol.MSG_PARTY_STATUS).size(), before + 1, "to each member")
	assert_false(_raw_inbox.has(outsider.peer_id), "and to nobody else")
	_party.step(first + 1)
	_party.step(first + PartyRules.STATUS_INTERVAL_TICKS - 1)
	assert_eq(_packets(ana, NetProtocol.MSG_PARTY_STATUS).size(), before + 1, "in between, nothing")
	_party.step(first + PartyRules.STATUS_INTERVAL_TICKS)
	assert_eq(_packets(ana, NetProtocol.MSG_PARTY_STATUS).size(), before + 2, "a 2 Hz")

	var bytes: PackedByteArray = _packets(ana, NetProtocol.MSG_PARTY_STATUS)[0]
	assert_true(bytes.size() <= NetProtocol.MAX_PACKET_BYTES, "fits in a packet")
	var status: NetMessages.PartyStatus = NetMessages.PartyStatus.decode(bytes)
	if not assert_not_null(status, "it is decoded"):
		return
	assert_eq(status.members.size(), 2, "the two members")
	var far: NetMessages.PartyStatus.MemberStatus = status.members[1]
	assert_eq(far.net_id, bruno.entity.net_id, "the second is Bruno")
	assert_vec_near(far.position, Vector3(250.0, 3.0, -40.0), 1e-3, "with his position, at 250 m")
	assert_eq(far.health_q, EntityRecord.quantize_health(500, 1000), "his health")
	assert_eq(far.stamina_q, PartyRules.STAMINA_Q_MAX, "his stamina (full)")
	assert_eq(far.status & NetMessages.STATUS_IN_COMBAT, NetMessages.STATUS_IN_COMBAT, "in combat")
	assert_vec_near(status.members[0].position, Vector3.ZERO, 1e-3, "and Ana's")
	assert_eq(status.members[0].health_q, 255, "Ana, with full health")


func test_dead_members_are_marked_in_the_status() -> void:
	var ana: ServerPeer = _add_peer("Ana")
	var bruno: ServerPeer = _add_peer("Bruno")
	_form_party(ana, [bruno])
	bruno.entity.set_health_view(0, 1000, NetMessages.STATUS_DEAD, 500)
	_party.step(_status_tick_from(_party.party_id_of(ana), 1000))
	var status: NetMessages.PartyStatus = NetMessages.PartyStatus.decode(
			_packets(ana, NetProtocol.MSG_PARTY_STATUS)[0])
	assert_true(status.members[1].is_dead(), "Bruno is dead")
	assert_eq(status.members[1].health_q, 0, "without health")


func test_status_ticks_are_staggered_between_parties() -> void:
	# Three parties of two: in a window of 30 ticks each member receives a state, and two parties never
	# go out on the same tick (the cost is spread out, like snapshots by the parity of the net_id).
	var members: Array[ServerPeer] = []
	var tick: int = 100
	for i: int in 3:
		var leader: ServerPeer = _add_peer("Lider%s" % char(97 + i))
		var joiner: ServerPeer = _add_peer("Miembro%s" % char(97 + i))
		tick = _form_party(leader, [joiner], tick)
		members.append_array([leader, joiner])
	var initial: Dictionary = {}
	var received: Dictionary = {}
	for peer: ServerPeer in members:
		initial[peer.peer_id] = _packets(peer, NetProtocol.MSG_PARTY_STATUS).size()
		received[peer.peer_id] = initial[peer.peer_id]
	var start: int = 1020
	assert_eq(start % PartyRules.STATUS_INTERVAL_TICKS, 0, "the window starts at a multiple of 30")
	for t: int in range(start, start + PartyRules.STATUS_INTERVAL_TICKS):
		_party.step(t)
		var parties_this_tick: Dictionary = {}
		for peer: ServerPeer in members:
			var count: int = _packets(peer, NetProtocol.MSG_PARTY_STATUS).size()
			if count > received[peer.peer_id]:
				parties_this_tick[_party.party_id_of(peer)] = true
			received[peer.peer_id] = count
		assert_true(parties_this_tick.size() <= 1, "tick %d sends state to %d parties" % [t,
				parties_this_tick.size()])
	for peer: ServerPeer in members:
		assert_eq(received[peer.peer_id] - initial[peer.peer_id], 1,
				"%s receives a state in 30 ticks" % peer.display_name)


# --- Party channel ----------------------------------------------------------------------------

func test_party_chat_reaches_the_members_only_and_never_another_realm() -> void:
	var ana: ServerPeer = _add_peer("Ana", VARDHEIM, Vector3.ZERO)
	var bruno: ServerPeer = _add_peer("Bruno", VARDHEIM, Vector3(800.0, 0.0, 0.0))
	var cerca: ServerPeer = _add_peer("Cerca", VARDHEIM, Vector3(1.0, 0.0, 0.0))
	var enemigo: ServerPeer = _add_peer("Enemigo", SOLMARCH, Vector3(1.0, 0.0, 0.0))
	_form_party(ana, [bruno])
	var message := NetMessages.ChatSend.new()
	message.channel = ChatChannel.Id.PARTY
	message.text = "Atacamos por la puerta"
	assert_true(_service.handle_packet(ana, NetProtocol.MSG_CHAT_SEND, message.encode(), 5000), "it handles it")
	for peer: ServerPeer in [ana, bruno]:
		var lines: Array[NetMessages.ChatMessage] = []
		for bytes: PackedByteArray in _packets(peer, NetProtocol.MSG_CHAT_MESSAGE):
			var line: NetMessages.ChatMessage = NetMessages.ChatMessage.decode(bytes)
			if line.channel == ChatChannel.Id.PARTY:
				lines.append(line)
		assert_eq(lines.size(), 1, "%s receives it, wherever they are" % peer.display_name)
		assert_eq(lines[0].text, "Atacamos por la puerta", "text")
	for peer: ServerPeer in [cerca, enemigo]:
		for bytes: PackedByteArray in _packets(peer, NetProtocol.MSG_CHAT_MESSAGE):
			var line: NetMessages.ChatMessage = NetMessages.ChatMessage.decode(bytes)
			assert_true(line.channel != ChatChannel.Id.PARTY, "%s does not receive the party channel" % peer.display_name)
	_party.leave(bruno, 6000)
	message.text = "Sigo hablando"
	_service.handle_packet(ana, NetProtocol.MSG_CHAT_SEND, message.encode(), 7000)
	assert_eq(_last_system(ana), "No estás en un grupo.", "without a party, the channel replies")


# --- Invalid messages -------------------------------------------------------------------------

func test_malformed_and_out_of_place_party_messages_add_a_strike() -> void:
	var ana: ServerPeer = _add_peer("Ana")
	# Malformed.
	assert_true(_service.handle_packet(ana, NetProtocol.MSG_PARTY_INVITE, PackedByteArray([0x48, 0]), 100),
			"a PARTY_INVITE without a name is handled")
	assert_true(_service.handle_packet(ana, NetProtocol.MSG_PARTY_RESPONSE, PackedByteArray([0x49, 2, 1, 65]), 100),
			"a PARTY_RESPONSE with accept 2")
	assert_true(_service.handle_packet(ana, NetProtocol.MSG_PARTY_LEAVE, PackedByteArray([0x4A, 0]), 100),
			"a 2 B PARTY_LEAVE")
	assert_eq(_strikes.size(), 3, "three warnings")
	assert_eq(_strikes[0][1], PartyManager.STRIKE_REASON_MALFORMED, "for malformed")
	# The types that only the server sends are not handled: the caller adds the warning.
	for message_type: int in [NetProtocol.MSG_PARTY_INVITATION, NetProtocol.MSG_PARTY_ROSTER,
			NetProtocol.MSG_PARTY_STATUS]:
		assert_false(_service.handle_packet(ana, message_type, PackedByteArray([message_type, 0]), 100),
				"0x%02X is not from a client" % message_type)
	assert_false(_service.handle_packet(ana, 0x40 + 7, PackedByteArray([0x47]), 100), "0x47 does not exist")
	# Before entering the world.
	var cargando: ServerPeer = _add_peer("Cargando")
	cargando.state = ServerPeer.State.LOADING
	var request := NetMessages.PartyTargetRequest.make(NetProtocol.MSG_PARTY_INVITE, "Ana")
	assert_true(_service.handle_packet(cargando, NetProtocol.MSG_PARTY_INVITE, request.encode(), 100), "it is handled")
	assert_eq(_strikes[3], [cargando.peer_id, PartyManager.STRIKE_REASON_NOT_IN_WORLD], "with its warning")
	assert_eq(_party.get_pending_count(), 0, "and nobody is invited")


func test_party_messages_from_clients_work_through_the_service() -> void:
	var ana: ServerPeer = _add_peer("Ana")
	var bruno: ServerPeer = _add_peer("Bruno")
	var cora: ServerPeer = _add_peer("Cora")
	var invite := NetMessages.PartyTargetRequest.make(NetProtocol.MSG_PARTY_INVITE, "bruno")
	assert_true(_service.handle_packet(ana, NetProtocol.MSG_PARTY_INVITE, invite.encode(), 100), "invite")
	var response := NetMessages.PartyResponse.new()
	response.accept = true
	response.inviter = "ANA"
	assert_true(_service.handle_packet(bruno, NetProtocol.MSG_PARTY_RESPONSE, response.encode(), 200), "accept")
	assert_eq(_party.members_of(ana).size(), 2, "there is a party")
	var second := NetMessages.PartyTargetRequest.make(NetProtocol.MSG_PARTY_INVITE, "Cora")
	_service.handle_packet(bruno, NetProtocol.MSG_PARTY_INVITE, second.encode(), 400)
	response.inviter = "Bruno"
	_service.handle_packet(cora, NetProtocol.MSG_PARTY_RESPONSE, response.encode(), 500)
	assert_eq(_party.members_of(ana).size(), 3, "any member invites")
	var lead := NetMessages.PartyTargetRequest.make(NetProtocol.MSG_PARTY_LEADER, "Cora")
	_service.handle_packet(ana, NetProtocol.MSG_PARTY_LEADER, lead.encode(), 600)
	assert_eq(_party.leader_of(ana), cora, "hand over leadership")
	var kick := NetMessages.PartyTargetRequest.make(NetProtocol.MSG_PARTY_KICK, "Ana")
	_service.handle_packet(cora, NetProtocol.MSG_PARTY_KICK, kick.encode(), 700)
	assert_eq(_party.members_of(cora), _ps([bruno, cora]), "kick")
	_service.handle_packet(bruno, NetProtocol.MSG_PARTY_LEAVE, NetMessages.PartyLeave.new().encode(), 800)
	assert_eq(_party.get_party_count(), 0, "leave")
	assert_true(_strikes.is_empty(), "without warnings")
