extends TestCase
## Chat integration with real ENet over 127.0.0.1 in a single process (SOC-04, docs/social.md sections
## 1, 5 and 12): a [ZoneServer] and several [NetClient] bots, two from Vardheim and one from Solmarch in the same
## zone. The acceptance test of the realm filter looks at the [b]bytes received[/b] by the other realm's
## client (all the packets that reach it), not at what it draws: none may contain the text of a
## message that was not for it, or be a CHAT_MESSAGE.
## [br][br]
## It also tests the sanitizing of what arrives over the network, the reach of "say", the rate limits with their warnings
## (to the player and to the peer), whispering to an enemy (the same response as to someone who does not exist), malformed
## messages and the report. The logic on its own, without network, is in test_chat_router.gd.

const VARDHEIM: int = NetProtocol.Realm.VARDHEIM
const SOLMARCH: int = NetProtocol.Realm.SOLMARCH
const ZONE_ID: String = "test_world"
## Physics frames at most that a condition is waited for (10 s).
const WAIT_FRAMES: int = 600

var _root: Node
var _server_viewport: SubViewport
var _server: ZoneServer
var _port: int = 0
var _clients: Array[NetClient] = []
var _client_viewports: Array[SubViewport] = []
# Per client (key: the NetClient): the chat that has reached it and all its raw packets.
var _inboxes: Dictionary = {}
var _raw_packets: Dictionary = {}


func before_each() -> void:
	_root = Node.new()
	_root.name = "ChatLoopback"
	tree.root.add_child(_root)


func after_each() -> void:
	for viewport: SubViewport in _client_viewports:
		if is_instance_valid(viewport):
			viewport.free()
	_client_viewports.clear()
	_clients.clear()
	_inboxes.clear()
	_raw_packets.clear()
	if is_instance_valid(_server_viewport):
		_server_viewport.free()
	_server_viewport = null
	_server = null
	if is_instance_valid(_root):
		tree.root.remove_child(_root)
		_root.free()
	_root = null
	await wait_process_frames()


# --- Helpers --------------------------------------------------------------------------------

func _start_server() -> void:
	_port = NetHarness.free_udp_port()
	_server_viewport = NetHarness.make_world_viewport(_root, "")
	var config := ServerConfig.new()
	config.port = _port
	config.zone_id = ZONE_ID
	config.max_players = 8
	_server = NetHarness.start_server(_server_viewport, config)
	await wait_physics_frames(3)


# A bot that also records the chat it receives and all the packets that reach it.
func _add_bot(realm: int, bot_seed: int) -> NetClient:
	var viewport: SubViewport = NetHarness.make_world_viewport(_root, "")
	_client_viewports.append(viewport)
	var client: NetClient = NetHarness.start_bot(viewport, _port, realm, bot_seed)
	_clients.append(client)
	var inbox: Array[NetMessages.ChatMessage] = []
	var raw: Array[PackedByteArray] = []
	_inboxes[client] = inbox
	_raw_packets[client] = raw
	client.chat_received.connect(func(message: NetMessages.ChatMessage) -> void:
		inbox.append(message))
	client.get_transport().packet_received.connect(func(_peer_id: int, bytes: PackedByteArray) -> void:
		raw.append(bytes))
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


# They all get in and stay still at their spawn point.
func _join_all_and_freeze() -> bool:
	if not await _wait_until(_all_in_world):
		return false
	for client: NetClient in _clients:
		var brain: BotBrain = client.get_meta(&"bot_brain") as BotBrain
		brain.set_idle_from(client.get_prediction().get_predicted_tick() + 1)
	await wait_physics_frames(10)
	return true


func _inbox(client: NetClient) -> Array[NetMessages.ChatMessage]:
	return _inboxes[client]


func _raw(client: NetClient) -> Array[PackedByteArray]:
	return _raw_packets[client]


# The inbox messages that are not from the system.
func _chat_lines(client: NetClient) -> Array[NetMessages.ChatMessage]:
	var lines: Array[NetMessages.ChatMessage] = []
	for message: NetMessages.ChatMessage in _inbox(client):
		if message.channel != ChatChannel.Id.SYSTEM:
			lines.append(message)
	return lines


func _system_texts(client: NetClient) -> PackedStringArray:
	var texts := PackedStringArray()
	for message: NetMessages.ChatMessage in _inbox(client):
		if message.channel == ChatChannel.Id.SYSTEM:
			texts.append(message.text)
	return texts


func _name_of(client: NetClient) -> String:
	return client.get_config().display_name


func _peer_of(client: NetClient) -> ServerPeer:
	for peer_id: int in _server.get_peer_ids():
		var peer: ServerPeer = _server.get_peer(peer_id)
		if peer.display_name == _name_of(client):
			return peer
	return null


# true if any raw packet of [param client] carries the UTF-8 bytes of [param token].
func _any_packet_contains(client: NetClient, token: String) -> bool:
	var needle: PackedByteArray = token.to_utf8_buffer()
	for packet: PackedByteArray in _raw(client):
		for start: int in range(0, packet.size() - needle.size() + 1):
			if packet.slice(start, start + needle.size()) == needle:
				return true
	return false


func _chat_packet_count(client: NetClient) -> int:
	var count: int = 0
	for packet: PackedByteArray in _raw(client):
		if NetMessages.peek_type(packet) == NetProtocol.MSG_CHAT_MESSAGE:
			count += 1
	return count


# --- Tests ----------------------------------------------------------------------------------

## The heart of SOC-04: the other realm's client receives NO packet with the text, in any of the
## channels, even if it is 3 m from the sender and in the same zone.
func test_the_enemy_realm_never_receives_a_packet_with_the_text() -> void:
	await _start_server()
	var ana: NetClient = _add_bot(VARDHEIM, 1)
	var bruno: NetClient = _add_bot(VARDHEIM, 2)
	var cora: NetClient = _add_bot(SOLMARCH, 3)
	if not assert_true(await _join_all_and_freeze(), "all three get in"):
		return
	# The enemy, next to Ana: "say" would reach it if the server did not filter by realm.
	_server.teleport(cora.get_net_id(), Vector3(-19.0, 0.0, 2.0))
	await wait_physics_frames(10)
	var secrets: PackedStringArray = ["secretoDecir", "secretoZona", "secretoSusurro", "secretoEnemigo"]

	assert_true(ana.send_chat(ChatChannel.Id.SAY, "", secrets[0]), "Ana says")
	assert_true(ana.send_chat(ChatChannel.Id.ZONE, "", secrets[1]), "Ana speaks in the zone channel")
	assert_true(ana.send_chat(ChatChannel.Id.WHISPER, _name_of(bruno), secrets[2]), "Ana whispers to Bruno")
	assert_true(ana.send_chat(ChatChannel.Id.WHISPER, _name_of(cora), secrets[3]), "Ana whispers to Cora")
	var arrived: bool = await _wait_until(func() -> bool:
		return (_chat_lines(ana).size() >= 3 and _chat_lines(bruno).size() >= 3
				and not _system_texts(ana).is_empty()))
	assert_true(arrived, "the messages reach Ana and Bruno")
	# Margin for any leak to arrive.
	await wait_physics_frames(60)

	# The legitimate recipients.
	assert_eq(_chat_lines(bruno).size(), 3, "Bruno receives the say message, the zone one and the whisper")
	var channels: Array[int] = []
	for line: NetMessages.ChatMessage in _chat_lines(bruno):
		channels.append(line.channel)
		assert_eq(line.sender, _name_of(ana), "sender")
		assert_eq(line.sender_realm, VARDHEIM, "sender's realm")
	assert_eq(channels, [ChatChannel.Id.SAY, ChatChannel.Id.ZONE, ChatChannel.Id.WHISPER], "in order")
	assert_eq(_chat_lines(ana).size(), 3, "Ana receives the copy of her three messages")
	# Ana is told that Cora is "no está conectada" (not online): the same as if she did not exist.
	assert_eq(_system_texts(ana), PackedStringArray(["«%s» no está conectado." % _name_of(cora)]),
			"response to a whisper to an enemy")

	# The enemy: not a single chat packet, and none with the texts, raw.
	assert_eq(_chat_packet_count(cora), 0, "Cora receives no CHAT_MESSAGE")
	assert_true(_inbox(cora).is_empty(), "not even a system one")
	for secret: String in secrets:
		assert_false(_any_packet_contains(cora, secret), "no packet of Cora's carries \"%s\"" % secret)
	# And the failed whisper did not reach Bruno either.
	assert_false(_any_packet_contains(bruno, secrets[3]), "Bruno does not receive the whisper addressed to Cora")
	assert_true(_any_packet_contains(bruno, secrets[0]), "control: the byte analysis finds Bruno's text")


func test_say_reaches_thirty_meters_and_zone_does_not_care_about_distance() -> void:
	await _start_server()
	var ana: NetClient = _add_bot(VARDHEIM, 1)
	var bruno: NetClient = _add_bot(VARDHEIM, 2)
	if not assert_true(await _join_all_and_freeze(), "both get in"):
		return
	_server.teleport(bruno.get_net_id(), Vector3(15.0, 0.0, 0.0))
	await wait_physics_frames(10)
	var distance: float = _server.get_registry().get_entity(ana.get_net_id()).get_position().distance_to(
			_server.get_registry().get_entity(bruno.get_net_id()).get_position())
	assert_true(distance > 30.0, "Bruno is more than 30 m from Ana (%.1f)" % distance)
	ana.send_chat(ChatChannel.Id.SAY, "", "no te llego")
	ana.send_chat(ChatChannel.Id.ZONE, "", "esto sí te llega")
	assert_true(await _wait_until(func() -> bool: return not _chat_lines(bruno).is_empty()),
			"something reaches Bruno")
	await wait_physics_frames(30)
	var lines: Array[NetMessages.ChatMessage] = _chat_lines(bruno)
	assert_eq(lines.size(), 1, "only the zone one")
	assert_eq(lines[0].channel, ChatChannel.Id.ZONE, "zone channel")
	assert_false(_any_packet_contains(bruno, "no te llego"), "the distant \"say\" did not arrive raw")
	# Ana sees her two copies.
	assert_eq(_chat_lines(ana).size(), 2, "Ana receives her two messages")


func test_text_is_sanitized_by_the_server_even_if_the_client_does_not() -> void:
	await _start_server()
	var ana: NetClient = _add_bot(VARDHEIM, 1)
	var bruno: NetClient = _add_bot(VARDHEIM, 2)
	if not assert_true(await _join_all_and_freeze(), "both get in"):
		return
	# A cheating client sends the CHAT_SEND by hand, unsanitized.
	var message := NetMessages.ChatSend.new()
	message.channel = ChatChannel.Id.SAY
	message.text = "  [b]Hola[/b]\t\n  [color=red]mundo[/color]\u0007  "
	ana.get_transport().send(NetClient.SERVER_PEER_ID, NetProtocol.CH_RELIABLE, message.encode())
	assert_true(await _wait_until(func() -> bool: return not _chat_lines(bruno).is_empty()), "it arrives")
	assert_eq(_chat_lines(bruno)[0].text, "Hola mundo", "sanitized on the server")
	assert_false(_any_packet_contains(bruno, "[b]"), "and the brackets do not cross the network")


func test_rate_limit_warns_the_player_and_counts_strikes_after_ten_discards() -> void:
	await _start_server()
	var ana: NetClient = _add_bot(VARDHEIM, 1)
	var bruno: NetClient = _add_bot(VARDHEIM, 2)
	if not assert_true(await _join_all_and_freeze(), "both get in"):
		return
	var peer: ServerPeer = _peer_of(ana)
	if not assert_not_null(peer, "the server knows Ana"):
		return
	var strikes_before: int = peer.strikes_total
	# Sixteen distinct messages in an instant (they fit in the transport's burst): five go through, eleven are
	# dropped; the first ten drops are free and the eleventh adds a peer warning.
	for i: int in 16:
		assert_true(ana.send_chat(ChatChannel.Id.ZONE, "", "mensaje %d" % i), "number %d is sent" % i)
	assert_true(await _wait_until(func() -> bool:
		return _chat_lines(bruno).size() >= 5 and not _system_texts(ana).is_empty()),
			"five arrive and the warning")
	await wait_physics_frames(30)
	assert_eq(_chat_lines(bruno).size(), 5, "Bruno receives only the burst of five")
	assert_eq(_system_texts(ana).size(), 1, "a single warning to the player, even though eleven were dropped")
	assert_eq(_system_texts(ana)[0], ChatRouter.TEXT_TOO_FAST, "\"Hablas demasiado rápido.\" (You speak too fast.)")
	assert_eq(peer.strikes_total - strikes_before, 1, "eleven drops add a peer warning")
	assert_eq(peer.chat.discards, 11, "eleven drops")
	assert_eq(peer.state, ServerPeer.State.IN_WORLD, "and Ana stays in")


func test_whispering_an_enemy_and_a_nobody_get_the_same_answer() -> void:
	await _start_server()
	var ana: NetClient = _add_bot(VARDHEIM, 1)
	var cora: NetClient = _add_bot(SOLMARCH, 3)
	if not assert_true(await _join_all_and_freeze(), "both get in"):
		return
	# With other capitals and without accents, which is how a player types it.
	ana.send_chat(ChatChannel.Id.WHISPER, _name_of(cora).to_upper(), "hola enemigo")
	ana.send_chat(ChatChannel.Id.WHISPER, "Nadie", "hola nadie")
	assert_true(await _wait_until(func() -> bool: return _system_texts(ana).size() >= 2),
			"two responses")
	await wait_physics_frames(20)
	var texts: PackedStringArray = _system_texts(ana)
	assert_eq(texts[0], "«%s» no está conectado." % _name_of(cora).to_upper(), "to the enemy")
	assert_eq(texts[1], "«Nadie» no está conectado.", "to no one")
	assert_eq(texts[0].replace(_name_of(cora).to_upper(), "X"), texts[1].replace("Nadie", "X"),
			"same phrase")
	assert_true(_inbox(cora).is_empty(), "the enemy notices nothing")
	assert_false(_any_packet_contains(cora, "hola enemigo"), "not even raw")


func test_malformed_chat_adds_strikes() -> void:
	await _start_server()
	var ana: NetClient = _add_bot(VARDHEIM, 1)
	if not assert_true(await _join_all_and_freeze(), "gets in"):
		return
	var peer: ServerPeer = _peer_of(ana)
	var before: int = peer.strikes_total
	var transport: NetTransport = ana.get_transport()
	# Truncated, system channel, whisper with no recipient and invalid UTF-8.
	transport.send(NetClient.SERVER_PEER_ID, NetProtocol.CH_RELIABLE, PackedByteArray([0x40, 0, 0]))
	transport.send(NetClient.SERVER_PEER_ID, NetProtocol.CH_RELIABLE,
			PackedByteArray([0x40, ChatChannel.Id.SYSTEM, 0, 2, 0, 0x68, 0x69]))
	transport.send(NetClient.SERVER_PEER_ID, NetProtocol.CH_RELIABLE,
			PackedByteArray([0x40, ChatChannel.Id.WHISPER, 0, 2, 0, 0x68, 0x69]))
	transport.send(NetClient.SERVER_PEER_ID, NetProtocol.CH_RELIABLE,
			PackedByteArray([0x40, ChatChannel.Id.SAY, 0, 2, 0, 0xFF, 0xFE]))
	assert_true(await _wait_until(func() -> bool: return peer.strikes_total - before >= 4),
			"four warnings")
	assert_eq(peer.strikes_total - before, 4, "exactly four")
	assert_true(_inbox(ana).is_empty(), "and nothing is distributed")
	assert_eq(peer.state, ServerPeer.State.IN_WORLD, "it is not kicked for four")


func test_the_client_api_refuses_what_the_server_would_drop() -> void:
	await _start_server()
	var ana: NetClient = _add_bot(VARDHEIM, 1)
	assert_false(ana.send_chat(ChatChannel.Id.SAY, "", "demasiado pronto"), "before being in the world")
	if not assert_true(await _join_all_and_freeze(), "gets in"):
		return
	assert_false(ana.send_chat(ChatChannel.Id.SAY, "", "   "), "empty text")
	assert_false(ana.send_chat(ChatChannel.Id.SAY, "", "[b][/b]"), "BBCode only")
	assert_false(ana.send_chat(ChatChannel.Id.SYSTEM, "", "hola"), "the system channel")
	assert_false(ana.send_chat(99, "", "hola"), "a channel that does not exist")
	assert_false(ana.send_chat(ChatChannel.Id.WHISPER, "  ", "hola"), "a whisper with no recipient")
	assert_true(ana.send_chat(ChatChannel.Id.SAY, "Pepe", "hola"), "the recipient is ignored outside whispers")
	assert_eq(ana.get_stats()["chat_sent"], 1, "only one was sent")


func test_the_report_counts_the_chat_of_the_session() -> void:
	await _start_server()
	var ana: NetClient = _add_bot(VARDHEIM, 1)
	var bruno: NetClient = _add_bot(VARDHEIM, 2)
	if not assert_true(await _join_all_and_freeze(), "both get in"):
		return
	ana.send_chat(ChatChannel.Id.ZONE, "", "para el informe")
	assert_true(await _wait_until(func() -> bool: return not _chat_lines(bruno).is_empty()), "it arrives")
	assert_eq(bruno.get_stats()["chat_received"], 1, "Bruno counts one received")
	var path: String = NetHarness.build_path("test_chat_loopback_report.json")
	assert_eq(_server.write_report(path), OK, "the report is written")
	var report: Dictionary = NetHarness.read_report(path)
	var chat: Dictionary = report.get("social", {}).get("chat", {})
	assert_eq(chat.get("routed", 0), 1, "one routed message")
	assert_eq(chat.get("delivered_copies", 0), 2, "two copies")
