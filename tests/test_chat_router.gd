extends TestCase
## Tests for [ChatRouter] (SOC-04, docs/social.md sections 1, 2 and 5) without a network: fake peers, a
## [Callable] that records what would be sent to each one and another that records the notices. It checks
## the reach of each channel, the realm filter (the enemy receives nothing), sanitizing, the rates and
## whispering to an enemy. The test with real ENet clients is test_chat_loopback.gd.

const VARDHEIM: int = NetProtocol.Realm.VARDHEIM
const SOLMARCH: int = NetProtocol.Realm.SOLMARCH

var _router: ChatRouter
var _peers: Array[ServerPeer] = []
var _nodes: Array[Node3D] = []
# peer_id -> the CHAT_MESSAGEs that would be sent to it, already decoded.
var _inbox: Dictionary = {}
# peer_id -> bytes of everything that would be sent to it (to check that it receives nothing).
var _raw_inbox: Dictionary = {}
# [peer_id, reason] of each notice added.
var _strikes: Array = []
var _next_id: int = 1


func before_each() -> void:
	_peers.clear()
	_nodes.clear()
	_inbox.clear()
	_raw_inbox.clear()
	_strikes.clear()
	_next_id = 1
	_router = ChatRouter.new(func() -> Array[ServerPeer]: return _peers,
			func(peer_id: int, bytes: PackedByteArray) -> void: _on_send(peer_id, bytes),
			func(peer: ServerPeer, reason: String) -> void: _strikes.append([peer.peer_id, reason]))


func after_each() -> void:
	# The router holds lambdas that point at this test: releasing it breaks the cycle.
	_router = null
	for node: Node3D in _nodes:
		node.free()
	_nodes.clear()
	_peers.clear()


# --- Helpers ----------------------------------------------------------------------------------

func _on_send(peer_id: int, bytes: PackedByteArray) -> void:
	if not _raw_inbox.has(peer_id):
		_raw_inbox[peer_id] = []
		_inbox[peer_id] = []
	_raw_inbox[peer_id].append(bytes)
	var message: NetMessages.ChatMessage = NetMessages.ChatMessage.decode(bytes)
	if message != null:
		_inbox[peer_id].append(message)


func _add_peer(player_name: String, realm: int, position: Vector3 = Vector3.ZERO) -> ServerPeer:
	var peer := ServerPeer.new(_next_id)
	_next_id += 1
	peer.state = ServerPeer.State.IN_WORLD
	peer.display_name = player_name
	peer.realm = realm
	var node := Node3D.new()
	node.position = position
	_nodes.append(node)
	var entity := NetEntity.new()
	entity.net_id = peer.peer_id
	entity.kind = NetProtocol.EntityKind.PLAYER
	entity.realm = realm
	entity.display_name = player_name
	entity.node = node
	peer.entity = entity
	_peers.append(peer)
	return peer


func _send(peer: ServerPeer, channel: int, text: String, recipient: String = "",
		tick: int = 100) -> int:
	var message := NetMessages.ChatSend.new()
	message.channel = channel
	message.recipient = recipient
	message.text = text
	return _router.handle_send(peer, message.encode(), tick)


func _messages(peer: ServerPeer) -> Array:
	return _inbox.get(peer.peer_id, [])


# The non-system messages that [param peer] has received.
func _chat_lines(peer: ServerPeer) -> Array[NetMessages.ChatMessage]:
	var lines: Array[NetMessages.ChatMessage] = []
	for message: NetMessages.ChatMessage in _messages(peer):
		if message.channel != ChatChannel.Id.SYSTEM:
			lines.append(message)
	return lines


# The system texts that [param peer] has received.
func _system_texts(peer: ServerPeer) -> PackedStringArray:
	var texts := PackedStringArray()
	for message: NetMessages.ChatMessage in _messages(peer):
		if message.channel == ChatChannel.Id.SYSTEM:
			texts.append(message.text)
	return texts


func _received_nothing(peer: ServerPeer) -> bool:
	return not _raw_inbox.has(peer.peer_id)


# --- Say and zone -----------------------------------------------------------------------------

func test_say_reaches_the_same_realm_within_range_and_nobody_else() -> void:
	var ana: ServerPeer = _add_peer("Ana", VARDHEIM, Vector3(0.0, 0.0, 0.0))
	var bruno: ServerPeer = _add_peer("Bruno", VARDHEIM, Vector3(29.0, 0.0, 0.0))
	var lejos: ServerPeer = _add_peer("Lejos", VARDHEIM, Vector3(31.0, 0.0, 0.0))
	var enemigo: ServerPeer = _add_peer("Enemigo", SOLMARCH, Vector3(1.0, 0.0, 0.0))
	assert_eq(_send(ana, ChatChannel.Id.SAY, "Hola a todos"), ChatRouter.Result.DELIVERED, "it is delivered")
	for receiver: ServerPeer in [ana, bruno]:
		var lines: Array[NetMessages.ChatMessage] = _chat_lines(receiver)
		if not assert_eq(lines.size(), 1, "%s receives the message" % receiver.display_name):
			continue
		assert_eq(lines[0].channel, ChatChannel.Id.SAY, "say channel")
		assert_eq(lines[0].sender, "Ana", "sender")
		assert_eq(lines[0].sender_realm, VARDHEIM, "sender realm")
		assert_eq(lines[0].text, "Hola a todos", "text")
		assert_eq(lines[0].tick, 100, "server tick")
	assert_true(_received_nothing(lejos), "nothing reaches at 31 m")
	assert_true(_received_nothing(enemigo), "the enemy, even at 1 m, receives no packet")


func test_say_range_is_three_dimensional_and_exactly_thirty_meters() -> void:
	var ana: ServerPeer = _add_peer("Ana", VARDHEIM, Vector3.ZERO)
	var justo: ServerPeer = _add_peer("Justo", VARDHEIM, Vector3(30.0, 0.0, 0.0))
	var alto: ServerPeer = _add_peer("Alto", VARDHEIM, Vector3(0.0, 31.0, 0.0))
	_send(ana, ChatChannel.Id.SAY, "x")
	assert_eq(_chat_lines(justo).size(), 1, "at exactly 30 m it does")
	assert_true(_received_nothing(alto), "at 31 m of height it does not")


func test_zone_reaches_the_whole_realm_but_not_the_enemy() -> void:
	var ana: ServerPeer = _add_peer("Ana", VARDHEIM, Vector3.ZERO)
	var lejos: ServerPeer = _add_peer("Lejos", VARDHEIM, Vector3(300.0, 0.0, 0.0))
	var enemigo: ServerPeer = _add_peer("Enemigo", SOLMARCH, Vector3(1.0, 0.0, 0.0))
	assert_eq(_send(ana, ChatChannel.Id.ZONE, "Todos al fuerte"), ChatRouter.Result.DELIVERED, "it is delivered")
	assert_eq(_chat_lines(ana).size(), 1, "the sender receives their copy")
	var lines: Array[NetMessages.ChatMessage] = _chat_lines(lejos)
	if assert_eq(lines.size(), 1, "at 300 m it also arrives"):
		assert_eq(lines[0].channel, ChatChannel.Id.ZONE, "zone channel")
	assert_true(_received_nothing(enemigo), "the enemy receives nothing")


func test_peers_not_in_the_world_are_ignored() -> void:
	var ana: ServerPeer = _add_peer("Ana", VARDHEIM)
	var cargando: ServerPeer = _add_peer("Cargando", VARDHEIM)
	cargando.state = ServerPeer.State.LOADING
	var saliendo: ServerPeer = _add_peer("Saliendo", VARDHEIM)
	saliendo.state = ServerPeer.State.LEAVING
	_send(ana, ChatChannel.Id.ZONE, "Hola")
	assert_true(_received_nothing(cargando), "whoever is loading the zone does not receive")
	assert_true(_received_nothing(saliendo), "nor whoever is leaving")
	assert_eq(_chat_lines(ana).size(), 1, "the sender does")


# --- Sanitizing -------------------------------------------------------------------------------

func test_text_is_sanitized_before_it_is_sent() -> void:
	var ana: ServerPeer = _add_peer("Ana", VARDHEIM)
	var bruno: ServerPeer = _add_peer("Bruno", VARDHEIM)
	_send(ana, ChatChannel.Id.SAY, "  [b]Hola[/b]\t\tmundo\n  ", "", 100)
	var lines: Array[NetMessages.ChatMessage] = _chat_lines(bruno)
	if assert_eq(lines.size(), 1, "it arrives"):
		assert_eq(lines[0].text, "Hola mundo", "without BBCode, with the spaces fixed")


func test_empty_text_after_sanitizing_is_dropped_without_a_strike() -> void:
	var ana: ServerPeer = _add_peer("Ana", VARDHEIM)
	for text: String in ["", "   ", "[b][/b]", "\t\n"]:
		assert_eq(_send(ana, ChatChannel.Id.SAY, text), ChatRouter.Result.EMPTY, "empty: \"%s\"" % text)
	assert_true(_received_nothing(ana), "nothing is delivered")
	assert_true(_strikes.is_empty(), "and it adds no notices either")
	assert_eq(ana.chat.discarded_empty, 4, "it is counted")


func test_an_empty_text_still_spends_its_token() -> void:
	# The rate comes before sanitizing: a cheating client cannot make the server work for free with texts
	# that end up empty (nor with channels without a service).
	var ana: ServerPeer = _add_peer("Ana", VARDHEIM)
	var bruno: ServerPeer = _add_peer("Bruno", VARDHEIM)
	assert_eq(_send(ana, ChatChannel.Id.ZONE, "[[x]]", "", 100), ChatRouter.Result.EMPTY, "the first one, empty")
	assert_true(ana.chat.limiter_public.get_tokens(100) < ChatPeerState.PUBLIC_BURST,
			"and it has already spent a token")
	for i: int in 3:
		assert_eq(_send(ana, ChatChannel.Id.ZONE, "[[x]]", "", 100), ChatRouter.Result.EMPTY, "empty %d" % i)
	assert_eq(_send(ana, ChatChannel.Id.RAID, "Hola", "", 100), ChatRouter.Result.UNAVAILABLE,
			"a channel without a service also spends its own")
	assert_eq(_send(ana, ChatChannel.Id.ZONE, "hola", "", 100), ChatRouter.Result.RATE_LIMITED,
			"five spent: normal text no longer fits")
	assert_eq(_send(ana, ChatChannel.Id.RAID, "Hola", "", 100), ChatRouter.Result.RATE_LIMITED,
			"nor another system reply")
	assert_eq(_chat_lines(bruno).size(), 0, "Bruno has received nothing")


func test_flooding_texts_that_sanitize_to_nothing_adds_strikes() -> void:
	var ana: ServerPeer = _add_peer("Ana", VARDHEIM)
	# The worst case of the earlier sanitizing: 127 levels of brackets, which end up as nothing.
	var nested: String = "[".repeat(127) + "]".repeat(127)
	var results: Dictionary = {}
	for i: int in 30:
		var result: int = _send(ana, ChatChannel.Id.ZONE, nested, "", 100)
		results[result] = results.get(result, 0) + 1
	assert_eq(results.get(ChatRouter.Result.EMPTY, 0), 5, "the burst of five is spent on empties")
	assert_eq(results.get(ChatRouter.Result.RATE_LIMITED, 0), 25, "and the rest is dropped by rate")
	assert_eq(ana.chat.discards, 25, "twenty-five drops")
	assert_eq(_strikes.size(), 25 - ChatPeerState.FLOOD_FREE_DISCARDS, "after the ten free ones, one notice each")


# --- Whispers ---------------------------------------------------------------------------------

func test_whisper_reaches_the_target_and_the_sender_only() -> void:
	var ana: ServerPeer = _add_peer("Ana", VARDHEIM, Vector3.ZERO)
	var bruno: ServerPeer = _add_peer("Bruno", VARDHEIM, Vector3(500.0, 0.0, 0.0))
	var tercero: ServerPeer = _add_peer("Tercero", VARDHEIM, Vector3(1.0, 0.0, 0.0))
	assert_eq(_send(ana, ChatChannel.Id.WHISPER, "Psst", "Bruno"), ChatRouter.Result.DELIVERED, "it is delivered")
	for receiver: ServerPeer in [ana, bruno]:
		var lines: Array[NetMessages.ChatMessage] = _chat_lines(receiver)
		if not assert_eq(lines.size(), 1, "%s receives the whisper" % receiver.display_name):
			continue
		assert_eq(lines[0].channel, ChatChannel.Id.WHISPER, "whisper channel")
		assert_eq(lines[0].sender, "Ana", "sender")
		assert_eq(lines[0].recipient, "Bruno", "recipient with their canonical name")
		assert_eq(lines[0].text, "Psst", "text")
	assert_true(_received_nothing(tercero), "a third party, even if next to them, does not hear the whisper")
	# The server does not keep \"the last correspondent\" (/r is resolved by the client, docs/social.md 12.2).
	for property: Dictionary in ana.chat.get_property_list():
		assert_false(String(property["name"]).contains("partner"), "ChatPeerState does not keep the correspondent")


func test_whisper_name_ignores_case_and_accents() -> void:
	var ana: ServerPeer = _add_peer("Ana", VARDHEIM)
	var pena: ServerPeer = _add_peer("Peña", VARDHEIM)
	assert_eq(_send(ana, ChatChannel.Id.WHISPER, "Hola", "peña"), ChatRouter.Result.DELIVERED, "peña")
	assert_eq(_chat_lines(pena).size(), 1, "it reaches Peña")
	var lines: Array[NetMessages.ChatMessage] = _chat_lines(pena)
	assert_eq(lines[0].recipient, "Peña", "with the canonical name, not the typed one")
	assert_eq(_send(ana, ChatChannel.Id.WHISPER, "Otra", "PENA", 200), ChatRouter.Result.DELIVERED,
			"PENA (no tilde or ñ, in uppercase)")
	assert_eq(_chat_lines(pena).size(), 2, "it also arrives")


func test_whisper_to_an_enemy_looks_exactly_like_whispering_to_nobody() -> void:
	var ana: ServerPeer = _add_peer("Ana", VARDHEIM)
	var cora: ServerPeer = _add_peer("Cora", SOLMARCH)
	assert_eq(_send(ana, ChatChannel.Id.WHISPER, "Hola", "Cora", 100), ChatRouter.Result.NO_TARGET,
			"to an enemy")
	assert_eq(_send(ana, ChatChannel.Id.WHISPER, "Hola", "Nadie", 200), ChatRouter.Result.NO_TARGET,
			"to someone who does not exist")
	var texts: PackedStringArray = _system_texts(ana)
	assert_eq(texts, PackedStringArray(["«Cora» no está conectado.", "«Nadie» no está conectado."]),
			"the same reply, with what the player typed")
	assert_true(_received_nothing(cora), "the enemy receives no packet")
	# What was typed is repeated, not the canonical name: no uppercase or accents from the other side of the border.
	var cora_accents: ServerPeer = _add_peer("Álvaro", SOLMARCH)
	_send(ana, ChatChannel.Id.WHISPER, "Hola", "alvaro", 300)
	assert_eq(_system_texts(ana)[2], "«alvaro» no está conectado.", "what was typed is repeated")
	assert_true(_received_nothing(cora_accents), "and Álvaro receives nothing")
	assert_eq(ana.chat.whisper_misses, 3, "failures are counted")


func test_whisper_to_yourself_is_refused() -> void:
	var ana: ServerPeer = _add_peer("Ana", VARDHEIM)
	assert_eq(_send(ana, ChatChannel.Id.WHISPER, "Hola", "ana"), ChatRouter.Result.NO_TARGET, "to oneself")
	assert_eq(_system_texts(ana), PackedStringArray([ChatRouter.TEXT_SELF_WHISPER]), "with its notice")


func test_whisper_recipient_in_the_message_is_cleaned_in_the_reply() -> void:
	var ana: ServerPeer = _add_peer("Ana", VARDHEIM)
	_send(ana, ChatChannel.Id.WHISPER, "Hola", "[b]Nadie[/b]")
	assert_eq(_system_texts(ana), PackedStringArray(["«Nadie» no está conectado."]),
			"the name in the reply is also sanitized")


# --- Party and channels without a service -----------------------------------------------------

func test_party_channel_without_a_party_says_so() -> void:
	var ana: ServerPeer = _add_peer("Ana", VARDHEIM)
	assert_eq(_send(ana, ChatChannel.Id.PARTY, "Hola"), ChatRouter.Result.NO_TARGET, "without a party")
	assert_eq(_system_texts(ana), PackedStringArray([ChatRouter.TEXT_NO_PARTY]), "notice")


func test_party_channel_reaches_the_members_and_never_another_realm() -> void:
	var ana: ServerPeer = _add_peer("Ana", VARDHEIM, Vector3.ZERO)
	var bruno: ServerPeer = _add_peer("Bruno", VARDHEIM, Vector3(900.0, 0.0, 0.0))
	var aparte: ServerPeer = _add_peer("Aparte", VARDHEIM, Vector3(1.0, 0.0, 0.0))
	var enemigo: ServerPeer = _add_peer("Enemigo", SOLMARCH, Vector3.ZERO)
	# A malformed party that includes an enemy: the router sends it nothing.
	_router.party_members = func(_peer: ServerPeer) -> Array[ServerPeer]:
		return [ana, bruno, enemigo]
	assert_eq(_send(ana, ChatChannel.Id.PARTY, "Atacamos"), ChatRouter.Result.DELIVERED, "it is delivered")
	assert_eq(_chat_lines(ana).size(), 1, "the sender")
	assert_eq(_chat_lines(bruno).size(), 1, "a distant member")
	assert_true(_received_nothing(aparte), "whoever is not in the party does not receive, even if next to them")
	assert_true(_received_nothing(enemigo), "an enemy never receives, not even by mistake")
	assert_eq(_chat_lines(bruno)[0].channel, ChatChannel.Id.PARTY, "party channel")


func test_unavailable_channels_answer_without_a_strike() -> void:
	var ana: ServerPeer = _add_peer("Ana", VARDHEIM)
	for channel: int in [ChatChannel.Id.RAID, ChatChannel.Id.GUILD, ChatChannel.Id.REALM]:
		assert_eq(_send(ana, channel, "Hola"), ChatRouter.Result.UNAVAILABLE,
				"the %s channel is not available" % ChatChannel.display_name(channel))
	assert_eq(_system_texts(ana), PackedStringArray([ChatRouter.TEXT_UNAVAILABLE,
			ChatRouter.TEXT_UNAVAILABLE, ChatRouter.TEXT_UNAVAILABLE]), "a notice is sent")
	assert_eq(_send(ana, ChatChannel.Id.GM, "Hola"), ChatRouter.Result.UNAVAILABLE, "GM")
	assert_eq(_system_texts(ana)[3], ChatRouter.TEXT_UNKNOWN_COMMAND,
			"GM answers like an unknown command: its existence is not revealed")
	assert_true(_strikes.is_empty(), "no notices")


# --- Invalid messages -------------------------------------------------------------------------

func test_malformed_and_out_of_place_messages_add_a_strike() -> void:
	var ana: ServerPeer = _add_peer("Ana", VARDHEIM)
	assert_eq(_router.handle_send(ana, PackedByteArray([0x40, 0, 0]), 100), ChatRouter.Result.MALFORMED,
			"truncated")
	assert_eq(_strikes, [[ana.peer_id, ChatRouter.STRIKE_REASON_MALFORMED]], "adds a notice")
	# The system channel is not sent by a client.
	var spoof := PackedByteArray([0x40, ChatChannel.Id.SYSTEM, 0, 4, 0, 0x68, 0x6F, 0x6C, 0x61])
	assert_eq(_router.handle_send(ana, spoof, 100), ChatRouter.Result.MALFORMED, "system channel")
	assert_eq(_strikes.size(), 2, "another notice")
	assert_true(_received_nothing(ana), "and nothing is delivered")
	# Someone who is not in the world yet.
	var cargando: ServerPeer = _add_peer("Cargando", VARDHEIM)
	cargando.state = ServerPeer.State.LOADING
	var valid := NetMessages.ChatSend.new()
	valid.text = "Hola"
	assert_eq(_router.handle_send(cargando, valid.encode(), 100), ChatRouter.Result.MALFORMED,
			"before entering the world")
	assert_eq(_strikes[2], [cargando.peer_id, ChatRouter.STRIKE_REASON_NOT_IN_WORLD], "with its reason")


# --- Rates ------------------------------------------------------------------------------------

func test_public_rate_allows_a_burst_of_five_then_one_per_second() -> void:
	var ana: ServerPeer = _add_peer("Ana", VARDHEIM)
	var bruno: ServerPeer = _add_peer("Bruno", VARDHEIM)
	for i: int in 5:
		assert_eq(_send(ana, ChatChannel.Id.SAY, "mensaje %d" % i, "", 100), ChatRouter.Result.DELIVERED,
				"the burst accepts message %d" % i)
	assert_eq(_send(ana, ChatChannel.Id.SAY, "mensaje 5", "", 100), ChatRouter.Result.RATE_LIMITED,
			"the sixth is dropped")
	assert_eq(_chat_lines(bruno).size(), 5, "Bruno has received five")
	assert_eq(_system_texts(ana), PackedStringArray([ChatRouter.TEXT_TOO_FAST]), "and Ana, the notice")
	# One second later (60 ticks) one fits again.
	assert_eq(_send(ana, ChatChannel.Id.SAY, "mensaje 6", "", 160), ChatRouter.Result.DELIVERED,
			"one second later another fits")
	assert_eq(_send(ana, ChatChannel.Id.SAY, "mensaje 7", "", 160), ChatRouter.Result.RATE_LIMITED,
			"but not two")


func test_say_zone_and_party_share_the_same_bucket() -> void:
	var ana: ServerPeer = _add_peer("Ana", VARDHEIM)
	_router.party_members = func(_peer: ServerPeer) -> Array[ServerPeer]: return [ana]
	assert_eq(_send(ana, ChatChannel.Id.SAY, "uno"), ChatRouter.Result.DELIVERED, "say")
	assert_eq(_send(ana, ChatChannel.Id.ZONE, "dos"), ChatRouter.Result.DELIVERED, "zone")
	assert_eq(_send(ana, ChatChannel.Id.PARTY, "tres"), ChatRouter.Result.DELIVERED, "party")
	assert_eq(_send(ana, ChatChannel.Id.SAY, "cuatro"), ChatRouter.Result.DELIVERED, "say")
	assert_eq(_send(ana, ChatChannel.Id.ZONE, "cinco"), ChatRouter.Result.DELIVERED, "zone")
	assert_eq(_send(ana, ChatChannel.Id.PARTY, "seis"), ChatRouter.Result.RATE_LIMITED,
			"the sixth, whatever the channel")


func test_the_warning_is_sent_at_most_once_per_second() -> void:
	var ana: ServerPeer = _add_peer("Ana", VARDHEIM)
	for i: int in 5:
		_send(ana, ChatChannel.Id.SAY, "m%d" % i, "", 100)
	for i: int in 4:
		_send(ana, ChatChannel.Id.SAY, "d%d" % i, "", 100 + i)
	assert_eq(_system_texts(ana).size(), 1, "four dropped in four ticks, a single notice")
	_send(ana, ChatChannel.Id.SAY, "tarde", "", 100 + ChatRouter.WARNING_INTERVAL_TICKS - 1)
	assert_eq(_system_texts(ana).size(), 1, "still within the second")


func test_the_first_ten_discards_in_ten_seconds_are_free_and_then_each_adds_a_strike() -> void:
	var ana: ServerPeer = _add_peer("Ana", VARDHEIM)
	assert_eq(ChatPeerState.FLOOD_FREE_DISCARDS, 10, "ten free")
	assert_eq(ChatPeerState.FLOOD_WINDOW_TICKS, ServerPeer.STRIKE_WINDOW_TICKS, "in the notice window")
	for i: int in 5:
		_send(ana, ChatChannel.Id.SAY, "m%d" % i, "", 100)
	for i: int in 10:
		_send(ana, ChatChannel.Id.SAY, "d%d" % i, "", 100 + i)
	assert_true(_strikes.is_empty(), "ten drops add nothing: pressing Enter once too often costs nothing")
	_send(ana, ChatChannel.Id.SAY, "d10", "", 110)
	assert_eq(_strikes, [[ana.peer_id, ChatRouter.STRIKE_REASON_FLOOD]], "the eleventh adds a notice")
	_send(ana, ChatChannel.Id.SAY, "d11", "", 111)
	assert_eq(_strikes.size(), 2, "and each of the following, another")
	assert_eq(ana.chat.discards, 12, "twelve drops")
	# Once 10 s have passed since the first ones, the window has emptied and they are free again.
	var later: int = 112 + ChatPeerState.FLOOD_WINDOW_TICKS
	for i: int in 5:
		_send(ana, ChatChannel.Id.SAY, "n%d" % i, "", later)
	for i: int in 10:
		_send(ana, ChatChannel.Id.SAY, "x%d" % i, "", later)
	assert_eq(_strikes.size(), 2, "ten more drops, ten seconds later, add nothing")


func test_an_honest_burst_never_adds_a_strike() -> void:
	var ana: ServerPeer = _add_peer("Ana", VARDHEIM)
	# Ten Enters in a row and five more 2 s later: eight are dropped, no notice.
	for i: int in 10:
		_send(ana, ChatChannel.Id.SAY, "prisa %d" % i, "", 100)
	for i: int in 5:
		_send(ana, ChatChannel.Id.SAY, "más prisa %d" % i, "", 220)
	assert_eq(ana.chat.discards, 8, "eight drops")
	assert_true(_strikes.is_empty(), "and no notice for the peer")


func test_a_sustained_flood_through_the_transport_gets_the_player_kicked() -> void:
	# As in ZoneServer: each CHAT_SEND first goes through the transport's reliable bucket (10/s, burst of 20) and
	# the notices go to the real ServerPeer, which kicks at 50 in 600 ticks. A client that sends
	# exactly 10 distinct messages per second receives no transport notice.
	var ana: ServerPeer = _add_peer("Ana", VARDHEIM)
	var clock: Dictionary = {"tick": 0, "kicked_at": -1, "transport_drops": 0}
	var router := ChatRouter.new(func() -> Array[ServerPeer]: return _peers,
			func(_peer_id: int, _bytes: PackedByteArray) -> void: pass,
			func(peer: ServerPeer, reason: String) -> void:
				if peer.add_strike(clock["tick"], reason) and clock["kicked_at"] < 0:
					clock["kicked_at"] = clock["tick"])
	var message := NetMessages.ChatSend.new()
	message.channel = ChatChannel.Id.ZONE
	for tick: int in range(0, 1200, 6):
		clock["tick"] = tick
		message.text = "oro barato %d" % tick
		if not ana.limiter_reliable.try_consume(tick):
			clock["transport_drops"] += 1
			continue
		router.handle_send(ana, message.encode(), tick)
		if clock["kicked_at"] >= 0:
			break
	assert_eq(clock["transport_drops"], 0, "the transport drops nothing at 10/s")
	assert_true(clock["kicked_at"] >= 0, "a sustained flood kicks (tick %d)" % clock["kicked_at"])
	assert_true(clock["kicked_at"] < 600, "in under 10 s")
	router = null


func test_a_repeated_text_is_dropped_for_ten_seconds() -> void:
	var ana: ServerPeer = _add_peer("Ana", VARDHEIM)
	var bruno: ServerPeer = _add_peer("Bruno", VARDHEIM)
	assert_eq(_send(ana, ChatChannel.Id.SAY, "¡Al fuerte!", "", 100), ChatRouter.Result.DELIVERED, "the first one")
	assert_eq(_send(ana, ChatChannel.Id.SAY, "¡Al fuerte!", "", 160), ChatRouter.Result.REPEATED,
			"same as the previous one at 1 s")
	assert_eq(_send(ana, ChatChannel.Id.ZONE, "¡Al  fuerte!", "", 200), ChatRouter.Result.REPEATED,
			"same after sanitizing and on another channel")
	assert_eq(_send(ana, ChatChannel.Id.SAY, "¡Al fuerte ya!", "", 220), ChatRouter.Result.DELIVERED,
			"a different text goes through")
	assert_eq(_send(ana, ChatChannel.Id.SAY, "¡Al fuerte ya!", "", 220 + ChatRouter.REPEAT_WINDOW_TICKS),
			ChatRouter.Result.DELIVERED, "after 10 s it is accepted again")
	assert_eq(_chat_lines(bruno).size(), 3, "Bruno sees three, not the repeats")
	assert_eq(ana.chat.discarded_repeat, 2, "two repeats")
	assert_eq(_system_texts(ana), PackedStringArray([ChatRouter.TEXT_REPEATED]),
			"with its own notice (one per second at most), not \"Hablas demasiado rápido\" (\"You talk too fast\")")


func test_the_same_whisper_to_another_recipient_is_delivered() -> void:
	var ana: ServerPeer = _add_peer("Ana", VARDHEIM)
	var bea: ServerPeer = _add_peer("Bea", VARDHEIM)
	var eva: ServerPeer = _add_peer("Eva", VARDHEIM)
	assert_eq(_send(ana, ChatChannel.Id.WHISPER, "ok", "Bea", 100), ChatRouter.Result.DELIVERED, "\"ok\" to Bea")
	assert_eq(_send(ana, ChatChannel.Id.WHISPER, "ok", "Eva", 200), ChatRouter.Result.DELIVERED,
			"and the same \"ok\" to Eva also arrives")
	assert_eq(_chat_lines(eva).size(), 1, "Eva receives it")
	assert_true(_system_texts(ana).is_empty(), "no notices")
	assert_eq(_send(ana, ChatChannel.Id.WHISPER, "ok", "EVA", 260), ChatRouter.Result.REPEATED,
			"to the same recipient (written however) it is a repeat")
	assert_eq(_system_texts(ana), PackedStringArray([ChatRouter.TEXT_REPEATED]), "with its notice")
	assert_eq(_send(ana, ChatChannel.Id.SAY, "ok", "", 400), ChatRouter.Result.DELIVERED,
			"from a whisper to a public channel does not cross over")
	assert_eq(_send(ana, ChatChannel.Id.WHISPER, "ok", "Bea", 460), ChatRouter.Result.DELIVERED,
			"nor from a public channel to a whisper")
	assert_eq(_chat_lines(bea).size(), 3, "Bea: two whispers and the \"say\"")


func test_whisper_has_its_own_burst_of_three() -> void:
	var ana: ServerPeer = _add_peer("Ana", VARDHEIM)
	var bruno: ServerPeer = _add_peer("Bruno", VARDHEIM)
	for i: int in 3:
		assert_eq(_send(ana, ChatChannel.Id.WHISPER, "susurro %d" % i, "Bruno", 100),
				ChatRouter.Result.DELIVERED, "whisper %d" % i)
	assert_eq(_send(ana, ChatChannel.Id.WHISPER, "susurro 3", "Bruno", 100), ChatRouter.Result.RATE_LIMITED,
			"the fourth is dropped")
	# The talk bucket has not been touched.
	assert_eq(_send(ana, ChatChannel.Id.SAY, "sigo hablando", "", 100), ChatRouter.Result.DELIVERED,
			"say is still free")
	assert_eq(_chat_lines(bruno).size(), 4, "Bruno received three whispers and the \"say\"")


func test_whisper_allows_five_new_recipients_per_minute() -> void:
	var ana: ServerPeer = _add_peer("Ana", VARDHEIM)
	var others: Array[ServerPeer] = []
	for i: int in 7:
		others.append(_add_peer("Otro%s" % char(97 + i), VARDHEIM))
	var tick: int = 100
	for i: int in 5:
		assert_eq(_send(ana, ChatChannel.Id.WHISPER, "hola %d" % i, others[i].display_name, tick),
				ChatRouter.Result.DELIVERED, "the new recipient %d" % i)
		tick += 60
	assert_eq(_send(ana, ChatChannel.Id.WHISPER, "hola sexto", others[5].display_name, tick),
			ChatRouter.Result.RATE_LIMITED, "the sixth new recipient in under a minute")
	# You can still keep whispering to one already known.
	assert_eq(_send(ana, ChatChannel.Id.WHISPER, "otra cosa", others[0].display_name, tick + 60),
			ChatRouter.Result.DELIVERED, "to someone already known, yes")
	# After some time, the bucket refills at 5 per minute.
	assert_eq(_send(ana, ChatChannel.Id.WHISPER, "ahora sí", others[5].display_name, tick + 900),
			ChatRouter.Result.DELIVERED, "a while later another new one fits")


func test_a_player_who_only_receives_whispers_keeps_only_recent_partners() -> void:
	var diana: ServerPeer = _add_peer("Diana", VARDHEIM)
	var gap: int = ChatRouter.KNOWN_RECIPIENT_TICKS * 5
	for i: int in 200:
		var sender: ServerPeer = _add_peer("Emisor%s%s" % [char(97 + i / 26), char(97 + i % 26)], VARDHEIM)
		var tick: int = 100 + i * gap
		assert_eq(_send(sender, ChatChannel.Id.WHISPER, "hola", "Diana", tick), ChatRouter.Result.DELIVERED,
				"%s whispers to Diana" % sender.display_name)
		assert_true(diana.chat.knows_recipient(SocialPeers.name_key_of(sender), tick,
				ChatRouter.KNOWN_RECIPIENT_TICKS), "right after, Diana counts him as a correspondent")
		# The sender leaves the zone.
		_peers.erase(sender)
	assert_true(diana.chat.known_recipients.size() <= 1,
			"Diana only keeps those from the last 5 min (%d)" % diana.chat.known_recipients.size())


func test_replying_to_someone_who_whispered_you_is_not_a_new_recipient() -> void:
	var ana: ServerPeer = _add_peer("Ana", VARDHEIM)
	var strangers: Array[ServerPeer] = []
	for i: int in 6:
		strangers.append(_add_peer("Intruso%s" % char(97 + i), VARDHEIM))
	# Six strangers whisper to Ana.
	var tick: int = 100
	for stranger: ServerPeer in strangers:
		assert_eq(_send(stranger, ChatChannel.Id.WHISPER, "hola Ana", "Ana", tick),
				ChatRouter.Result.DELIVERED, "%s whispers to Ana" % stranger.display_name)
		tick += 10
	# Ana replies to all six: none counts as new.
	for stranger: ServerPeer in strangers:
		tick += 60
		assert_eq(_send(ana, ChatChannel.Id.WHISPER, "hola " + stranger.display_name,
				stranger.display_name, tick), ChatRouter.Result.DELIVERED,
				"replies to %s" % stranger.display_name)


func test_stats_count_the_results() -> void:
	var ana: ServerPeer = _add_peer("Ana", VARDHEIM)
	var bruno: ServerPeer = _add_peer("Bruno", VARDHEIM)
	_send(ana, ChatChannel.Id.SAY, "uno")
	_send(ana, ChatChannel.Id.SAY, "")
	var stats: Dictionary = _router.get_stats()
	assert_eq(stats["routed"], 2, "two processed")
	assert_eq(stats["delivered_copies"], 2, "two copies delivered (Ana and Bruno)")
	assert_eq(stats["results"]["delivered"], 1, "one delivered")
	assert_eq(stats["results"]["empty"], 1, "one empty")
	assert_eq(ana.chat.accepted, 1, "accepted by Ana")
	assert_eq(bruno.chat.accepted, 0, "and by Bruno none")
