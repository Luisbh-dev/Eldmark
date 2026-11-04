extends TestCase
## Integration of parties with real ENet over 127.0.0.1 in a single process (SOC-06, docs/social.md
## section 12.4): a [ZoneServer] and several bot [NetClient]s, two or three from Vardheim and one from
## Solmarch in the same zone. The bots send the party messages by hand (the party client is SOC-08's)
## and the test decodes what reaches them raw. Flows: invite, accept, decline, the member list, the
## leader inherited on leaving, kick, hand over leadership, the invitation to an enemy (declined
## without the enemy finding out), the chat party channel and the compact 2 Hz state of a member
## outside the interest radius. The logic on its own, without a network, is in test_party_manager.gd.

const VARDHEIM: int = NetProtocol.Realm.VARDHEIM
const SOLMARCH: int = NetProtocol.Realm.SOLMARCH
const ZONE_ID: String = "test_world"
const WAIT_FRAMES: int = 600
## Interest radius of the test policy (m): what is farther away does not appear in the snapshots.
const INTEREST_RADIUS: float = 100.0


## Interest policy that only sees what is within [constant INTEREST_RADIUS] m.
class RangePolicy:
	extends InterestPolicy

	func is_relevant(observer: NetEntity, entity: NetEntity, _was_relevant: bool) -> bool:
		return observer.get_position().distance_to(entity.get_position()) <= INTEREST_RADIUS


var _root: Node
var _server_viewport: SubViewport
var _server: ZoneServer
var _port: int = 0
var _clients: Array[NetClient] = []
var _client_viewports: Array[SubViewport] = []
var _raw_packets: Dictionary = {}
var _chat_inboxes: Dictionary = {}


func before_each() -> void:
	_root = Node.new()
	_root.name = "PartyLoopback"
	tree.root.add_child(_root)


func after_each() -> void:
	for viewport: SubViewport in _client_viewports:
		if is_instance_valid(viewport):
			viewport.free()
	_client_viewports.clear()
	_clients.clear()
	_raw_packets.clear()
	_chat_inboxes.clear()
	if is_instance_valid(_server_viewport):
		_server_viewport.free()
	_server_viewport = null
	_server = null
	if is_instance_valid(_root):
		tree.root.remove_child(_root)
		_root.free()
	_root = null
	await wait_process_frames()


# --- Helpers ----------------------------------------------------------------------------------

func _start_server(policy: InterestPolicy = null) -> void:
	_port = NetHarness.free_udp_port()
	_server_viewport = NetHarness.make_world_viewport(_root, "")
	var config := ServerConfig.new()
	config.port = _port
	config.zone_id = ZONE_ID
	config.max_players = 8
	_server = NetHarness.start_server(_server_viewport, config)
	if policy != null:
		_server.interest_policy = policy
	await wait_physics_frames(3)


func _add_bot(realm: int, bot_seed: int) -> NetClient:
	var viewport: SubViewport = NetHarness.make_world_viewport(_root, "")
	_client_viewports.append(viewport)
	var client: NetClient = NetHarness.start_bot(viewport, _port, realm, bot_seed)
	_clients.append(client)
	var raw: Array[PackedByteArray] = []
	var chat: Array[NetMessages.ChatMessage] = []
	_raw_packets[client] = raw
	_chat_inboxes[client] = chat
	client.get_transport().packet_received.connect(func(_peer_id: int, bytes: PackedByteArray) -> void:
		raw.append(bytes))
	client.chat_received.connect(func(message: NetMessages.ChatMessage) -> void: chat.append(message))
	return client


func _wait_until(condition: Callable, max_frames: int = WAIT_FRAMES) -> bool:
	for _i: int in max_frames:
		if condition.call():
			return true
		await tree.physics_frame
	return condition.call()


func _all_in_world() -> bool:
	for client: NetClient in _clients:
		if client.get_state() != NetClient.State.IN_WORLD:
			return false
	return true


func _join_all_and_freeze() -> bool:
	if not await _wait_until(_all_in_world):
		return false
	for client: NetClient in _clients:
		var brain: BotBrain = client.get_meta(&"bot_brain") as BotBrain
		brain.set_idle_from(client.get_prediction().get_predicted_tick() + 1)
	await wait_physics_frames(10)
	return true


func _name_of(client: NetClient) -> String:
	return client.get_config().display_name


func _raw(client: NetClient) -> Array[PackedByteArray]:
	return _raw_packets[client]


func _packets(client: NetClient, msg_type: int) -> Array[PackedByteArray]:
	var found: Array[PackedByteArray] = []
	for packet: PackedByteArray in _raw(client):
		if NetMessages.peek_type(packet) == msg_type:
			found.append(packet)
	return found


# How many party packets (0x48 to 0x4F) or chat packets [param client] has received.
func _social_packet_count(client: NetClient) -> int:
	var count: int = 0
	for packet: PackedByteArray in _raw(client):
		if SocialService.handles_type(NetMessages.peek_type(packet)):
			count += 1
	return count


func _system_texts(client: NetClient) -> PackedStringArray:
	var texts := PackedStringArray()
	for message: NetMessages.ChatMessage in _chat_inboxes[client]:
		if message.channel == ChatChannel.Id.SYSTEM:
			texts.append(message.text)
	return texts


func _last_roster(client: NetClient) -> NetMessages.PartyRoster:
	var rosters: Array[PackedByteArray] = _packets(client, NetProtocol.MSG_PARTY_ROSTER)
	return NetMessages.PartyRoster.decode(rosters[rosters.size() - 1]) if not rosters.is_empty() else null


func _roster_names(client: NetClient) -> PackedStringArray:
	var names := PackedStringArray()
	var roster: NetMessages.PartyRoster = _last_roster(client)
	if roster != null:
		for member: NetMessages.PartyRoster.Member in roster.members:
			names.append(member.display_name)
	return names


func _send(client: NetClient, bytes: PackedByteArray) -> void:
	client.get_transport().send(NetClient.SERVER_PEER_ID, NetProtocol.CH_RELIABLE, bytes)


# The sends go through the real client's API ([NetClient.send_party_invite] and company).
func _invite(from: NetClient, target_name: String) -> void:
	assert_true(from.send_party_invite(target_name), "the client sends PARTY_INVITE")


func _respond(from: NetClient, inviter_name: String, accept: bool) -> void:
	assert_true(from.send_party_response(inviter_name, accept), "the client sends PARTY_RESPONSE")


func _party_manager() -> PartyManager:
	return _server.get_social().get_party()


# Ana invites [param other] and they accept; waits for both to have the list with the two of them.
func _join_party(leader: NetClient, other: NetClient) -> bool:
	_invite(leader, _name_of(other))
	if not await _wait_until(func() -> bool: return not _packets(other, NetProtocol.MSG_PARTY_INVITATION).is_empty()):
		return false
	_respond(other, _name_of(leader), true)
	# The first time, the leader's list is empty and ends up with two names (themselves and the newcomer).
	var expected: int = maxi(_roster_names(leader).size(), 1) + 1
	return await _wait_until(func() -> bool:
		return _roster_names(other).size() == expected and _roster_names(leader).size() == expected)


# --- Tests ------------------------------------------------------------------------------------

func test_invite_accept_and_party_chat_with_the_realm_filter() -> void:
	await _start_server()
	var ana: NetClient = _add_bot(VARDHEIM, 1)
	var bruno: NetClient = _add_bot(VARDHEIM, 2)
	var cora: NetClient = _add_bot(SOLMARCH, 3)
	if not assert_true(await _join_all_and_freeze(), "all three get in"):
		return
	_invite(ana, _name_of(bruno).to_upper())
	assert_true(await _wait_until(func() -> bool:
		return not _packets(bruno, NetProtocol.MSG_PARTY_INVITATION).is_empty()), "Bruno receives the invitation")
	var offer: NetMessages.PartyInvitation = NetMessages.PartyInvitation.decode(
			_packets(bruno, NetProtocol.MSG_PARTY_INVITATION)[0])
	assert_eq(offer.state, NetMessages.PartyInvitation.State.OFFERED, "new")
	assert_eq(offer.inviter, _name_of(ana), "from Ana, with her canonical name")
	assert_true(offer.tick > _server.get_tick(), "which expires in the future")
	assert_true(offer.tick <= _server.get_tick() + PartyRules.INVITE_TTL_TICKS, "in 60 s at most")

	_respond(bruno, _name_of(ana), true)
	assert_true(await _wait_until(func() -> bool:
		return _roster_names(ana).size() == 2 and _roster_names(bruno).size() == 2), "both receive the list")
	for client: NetClient in [ana, bruno]:
		var roster: NetMessages.PartyRoster = _last_roster(client)
		assert_eq(roster.members[0].display_name, _name_of(ana), "Ana first")
		assert_eq(roster.members[0].net_id, ana.get_net_id(), "with the net_id the server gave her")
		assert_eq(roster.members[1].display_name, _name_of(bruno), "then Bruno")
		assert_eq(roster.members[1].net_id, bruno.get_net_id(), "with his net_id")
		assert_eq(roster.get_leader_id(), ana.get_net_id(), "Ana is in charge")
	assert_eq(_party_manager().get_party_count(), 1, "the server has a party")
	# The client's party state (PartyState) reflects the list, and the invitation was withdrawn from Bruno.
	var state: PartyState = bruno.get_party()
	assert_eq(state.get_member_count(), 2, "Bruno sees two members")
	assert_true(state.is_leader(ana.get_net_id()), "and that Ana is in charge")
	assert_false(state.is_leader(bruno.get_net_id()), "and he is not")
	assert_null(state.get_current_invitation(), "without pending invitations")
	assert_eq(bruno.get_stats()["party_rosters"], 1, "a received list")

	# The chat party channel: only the members, and Cora, from the other realm, gets nothing.
	assert_true(ana.send_chat(ChatChannel.Id.PARTY, "", "secretoGrupo"), "Ana speaks to the party")
	assert_true(await _wait_until(func() -> bool:
		return _chat_lines(bruno, ChatChannel.Id.PARTY) == 1), "it reaches Bruno")
	await wait_physics_frames(30)
	assert_eq(_chat_lines(ana, ChatChannel.Id.PARTY), 1, "and Ana, her copy")
	assert_eq(_social_packet_count(cora), 0, "Cora receives no chat or party packet")
	assert_false(_any_packet_contains(cora, "secretoGrupo"), "nor with the raw text")


func test_inviting_an_enemy_is_refused_and_the_enemy_never_knows() -> void:
	await _start_server()
	var ana: NetClient = _add_bot(VARDHEIM, 1)
	var cora: NetClient = _add_bot(SOLMARCH, 3)
	if not assert_true(await _join_all_and_freeze(), "both get in"):
		return
	_invite(ana, _name_of(cora))
	_invite(ana, "Nadie")
	assert_true(await _wait_until(func() -> bool: return _system_texts(ana).size() >= 2), "two replies")
	await wait_physics_frames(30)
	assert_eq(_system_texts(ana)[0], "«%s» no está conectado." % _name_of(cora), "to the enemy")
	assert_eq(_system_texts(ana)[1], "«Nadie» no está conectado.", "to nobody: the same phrase")
	assert_eq(_social_packet_count(cora), 0, "Cora does not receive a single social packet")
	assert_eq(_party_manager().get_pending_count(), 0, "there is no invitation")
	# Cora tries to accept anyway, and is told she has no invitation.
	_respond(cora, _name_of(ana), true)
	assert_true(await _wait_until(func() -> bool: return not _system_texts(cora).is_empty()), "the server replies")
	assert_eq(_system_texts(cora)[0], "No tienes ninguna invitación de «%s»." % _name_of(ana), "without an invitation")
	assert_eq(_party_manager().get_party_count(), 0, "there is no party across realms")
	assert_true(_packets(cora, NetProtocol.MSG_PARTY_ROSTER).is_empty(), "and Cora has not received any list")
	assert_true(_packets(ana, NetProtocol.MSG_PARTY_ROSTER).is_empty(), "nor has Ana")


func test_declining_and_expiring_clear_the_invitation() -> void:
	await _start_server()
	var ana: NetClient = _add_bot(VARDHEIM, 1)
	var bruno: NetClient = _add_bot(VARDHEIM, 2)
	if not assert_true(await _join_all_and_freeze(), "both get in"):
		return
	_invite(ana, _name_of(bruno))
	assert_true(await _wait_until(func() -> bool:
		return not _packets(bruno, NetProtocol.MSG_PARTY_INVITATION).is_empty()), "it arrives")
	_respond(bruno, _name_of(ana), false)
	var declined_text: String = "%s ha rechazado tu invitación." % _name_of(bruno)
	assert_true(await _wait_until(func() -> bool: return _system_texts(ana).has(declined_text)), "Ana knows it")
	assert_eq(_party_manager().get_party_count(), 0, "without a party")
	assert_true(await _wait_until(func() -> bool: return _packets(bruno, NetProtocol.MSG_PARTY_INVITATION).size() == 2),
			"the notice that the invitation is no longer valid arrives")
	var offers: Array[PackedByteArray] = _packets(bruno, NetProtocol.MSG_PARTY_INVITATION)
	assert_eq(NetMessages.PartyInvitation.decode(offers[offers.size() - 1]).state,
			NetMessages.PartyInvitation.State.CANCELLED, "Bruno's prompt is withdrawn")
	# A new invitation that expires (the server step with a tick 60 s later).
	await wait_physics_frames(130)
	_invite(ana, _name_of(bruno))
	assert_true(await _wait_until(func() -> bool: return _packets(bruno, NetProtocol.MSG_PARTY_INVITATION).size() == 3),
			"the second invitation arrives")
	_party_manager().step(_server.get_tick() + PartyRules.INVITE_TTL_TICKS + 1)
	assert_true(await _wait_until(func() -> bool: return _packets(bruno, NetProtocol.MSG_PARTY_INVITATION).size() == 4),
			"the expiry notice arrives")
	offers = _packets(bruno, NetProtocol.MSG_PARTY_INVITATION)
	assert_eq(NetMessages.PartyInvitation.decode(offers[3]).state, NetMessages.PartyInvitation.State.EXPIRED, "expired")
	assert_eq(_party_manager().get_pending_count(), 0, "without pending ones")


func test_leaving_kicking_and_the_inherited_lead() -> void:
	await _start_server()
	var ana: NetClient = _add_bot(VARDHEIM, 1)
	var bruno: NetClient = _add_bot(VARDHEIM, 2)
	var cora: NetClient = _add_bot(VARDHEIM, 3)
	if not assert_true(await _join_all_and_freeze(), "all three get in"):
		return
	assert_true(await _join_party(ana, bruno), "Bruno joins")
	await wait_physics_frames(130)
	assert_true(await _join_party(ana, cora), "Cora joins")
	assert_eq(_roster_names(cora), PackedStringArray([_name_of(ana), _name_of(bruno), _name_of(cora)]),
			"order of arrival")

	# Ana hands leadership to Cora.
	assert_true(ana.send_party_leader(_name_of(cora)), "Ana hands over leadership")
	assert_true(await _wait_until(func() -> bool: return _last_roster(bruno).get_leader_id() == cora.get_net_id()),
			"Cora is in charge")
	# Bruno cannot kick anyone.
	assert_true(bruno.send_party_kick(_name_of(cora)), "Bruno tries to kick")
	assert_true(await _wait_until(func() -> bool: return _system_texts(bruno).has("Solo el líder puede hacer eso.")),
			"a member does not kick")
	assert_eq(_roster_names(bruno).size(), 3, "nobody leaves")
	# Cora, who is in charge, kicks Ana.
	assert_true(cora.send_party_kick(_name_of(ana)), "Cora kicks Ana")
	assert_true(await _wait_until(func() -> bool: return _last_roster(ana).is_empty()), "Ana receives the empty list")
	assert_true(_system_texts(ana).has("Has sido expulsado del grupo."), "and knows it")
	assert_eq(_roster_names(cora), PackedStringArray([_name_of(bruno), _name_of(cora)]), "Bruno and Cora remain")
	assert_eq(_party_manager().get_party_count(), 1, "the party continues")
	# Cora leaves: the party of one dissolves and Bruno is left without a party.
	assert_true(cora.send_party_leave(), "Cora leaves")
	assert_true(await _wait_until(func() -> bool:
		return _last_roster(bruno).is_empty() and _last_roster(cora).is_empty()), "both receive the empty list")
	assert_true(_system_texts(bruno).has("El grupo se ha disuelto."), "Bruno knows it dissolved")
	assert_eq(_party_manager().get_party_count(), 0, "the server has no parties")


func test_the_leader_leaving_the_zone_passes_the_lead_on() -> void:
	await _start_server()
	var ana: NetClient = _add_bot(VARDHEIM, 1)
	var bruno: NetClient = _add_bot(VARDHEIM, 2)
	var cora: NetClient = _add_bot(VARDHEIM, 3)
	if not assert_true(await _join_all_and_freeze(), "all three get in"):
		return
	assert_true(await _join_party(ana, bruno), "Bruno joins")
	await wait_physics_frames(130)
	assert_true(await _join_party(ana, cora), "Cora joins")
	ana.leave()
	assert_true(await _wait_until(func() -> bool:
		return _roster_names(bruno).size() == 2 and _roster_names(cora).size() == 2), "the list loses Ana")
	assert_eq(_roster_names(bruno), PackedStringArray([_name_of(bruno), _name_of(cora)]), "Bruno and Cora")
	assert_eq(_last_roster(cora).get_leader_id(), bruno.get_net_id(), "Bruno inherits, the next oldest")
	assert_true(_system_texts(bruno).has("%s ha salido del grupo." % _name_of(ana)), "it is counted")
	assert_true(_system_texts(bruno).has("%s es ahora el líder del grupo." % _name_of(bruno)), "and who is in charge")


func test_member_status_reaches_a_member_outside_the_interest_radius() -> void:
	await _start_server(RangePolicy.new())
	var ana: NetClient = _add_bot(VARDHEIM, 1)
	var bruno: NetClient = _add_bot(VARDHEIM, 2)
	if not assert_true(await _join_all_and_freeze(), "both get in"):
		return
	assert_true(await _join_party(ana, bruno), "they form a party")
	var far: Vector3 = Vector3(190.0, 0.0, 0.0)
	_server.teleport(bruno.get_net_id(), far)
	# Bruno leaves Ana's interest: his view disappears, but the party state keeps arriving.
	assert_true(await _wait_until(func() -> bool: return ana.get_remote_world().get_view_count() == 0, 300),
			"Ana no longer sees Bruno in her snapshots")
	var bruno_is_far: Callable = func() -> bool:
		var received: Array[PackedByteArray] = _packets(ana, NetProtocol.MSG_PARTY_STATUS)
		if received.is_empty():
			return false
		var newest: NetMessages.PartyStatus = NetMessages.PartyStatus.decode(received[received.size() - 1])
		for member: NetMessages.PartyStatus.MemberStatus in newest.members:
			if member.net_id == bruno.get_net_id() and member.position.distance_to(far) < 1.0:
				return true
		return false
	var reached: bool = await _wait_until(bruno_is_far, 300)
	assert_true(reached, "Bruno's state at 210 m reaches Ana with his position")
	var packets: Array[PackedByteArray] = _packets(ana, NetProtocol.MSG_PARTY_STATUS)
	var last: NetMessages.PartyStatus = NetMessages.PartyStatus.decode(packets[packets.size() - 1])
	assert_eq(last.members.size(), 2, "the two members")
	assert_eq(last.members[0].net_id, ana.get_net_id(), "Ana, the first")
	assert_eq(last.members[0].health_q, 255, "with full health")
	assert_eq(last.members[1].stamina_q, PartyRules.STAMINA_Q_MAX, "Bruno, with full stamina")
	# At 2 Hz: in one second about 2 arrive (and for the two members).
	var before: int = _packets(ana, NetProtocol.MSG_PARTY_STATUS).size()
	await wait_physics_frames(120)
	var gained: int = _packets(ana, NetProtocol.MSG_PARTY_STATUS).size() - before
	assert_true(gained >= 3 and gained <= 5, "in 2 s ~4 states arrive (%d)" % gained)
	# The server counts it in the report.
	var report_path: String = NetHarness.build_path("test_party_loopback_report.json")
	assert_eq(_server.write_report(report_path), OK, "the report is written")
	var party_stats: Dictionary = NetHarness.read_report(report_path).get("social", {}).get("party", {})
	assert_true(party_stats.get("status_sent", 0) > 0, "the report counts the states sent")
	assert_eq(party_stats.get("accepted", 0), 1, "and the accepted invitation")


func test_malformed_party_messages_add_strikes() -> void:
	await _start_server()
	var ana: NetClient = _add_bot(VARDHEIM, 1)
	if not assert_true(await _join_all_and_freeze(), "gets in"):
		return
	var peer: ServerPeer = null
	for peer_id: int in _server.get_peer_ids():
		peer = _server.get_peer(peer_id)
	var before: int = peer.strikes_total
	_send(ana, PackedByteArray([0x48, 0]))
	_send(ana, PackedByteArray([0x49, 5, 1, 65]))
	_send(ana, PackedByteArray([0x4A, 1]))
	# Types that only the server sends.
	_send(ana, PackedByteArray([0x4E, 0, 0]))
	_send(ana, PackedByteArray([0x47]))
	assert_true(await _wait_until(func() -> bool: return peer.strikes_total - before >= 5), "five warnings")
	assert_eq(peer.strikes_total - before, 5, "exactly five")
	assert_eq(peer.state, ServerPeer.State.IN_WORLD, "nobody is kicked for five")


# --- More helpers -----------------------------------------------------------------------------

func _chat_lines(client: NetClient, channel: int) -> int:
	var count: int = 0
	for message: NetMessages.ChatMessage in _chat_inboxes[client]:
		if message.channel == channel:
			count += 1
	return count


func _any_packet_contains(client: NetClient, token: String) -> bool:
	var needle: PackedByteArray = token.to_utf8_buffer()
	for packet: PackedByteArray in _raw(client):
		for start: int in range(0, packet.size() - needle.size() + 1):
			if packet.slice(start, start + needle.size()) == needle:
				return true
	return false
