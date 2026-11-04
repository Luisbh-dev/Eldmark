extends TestCase
## Tests for chat moderation without a network (docs/platform.md §9.2 to §9.5, P7b): [SocialService]
## with fake peers that carry their claim. An ignored player reaches nobody who ignores them on any
## channel (and in a whisper the sender does not notice), their party invitation is silently discarded;
## a muted player cannot talk and knows how much time is left; the GM channel goes to
## [member ChatRouter.command_sink]; each receiver records what it receives in its ring and each
## message goes to the chat batch; chat state is per character and is kept for 5 min after logout.
## The zone-wide ones (with [FakeZonePlatform]) are in test_zone_moderation.gd.

const VARDHEIM: int = NetProtocol.Realm.VARDHEIM
const SOLMARCH: int = NetProtocol.Realm.SOLMARCH
const NOW: int = 1_800_000_000

var _social: SocialService
var _peers: Array[ServerPeer] = []
var _nodes: Array[Node3D] = []
# peer_id -> the CHAT_MESSAGEs (decoded) and the PARTY_INVITATIONs (bytes) that would be sent to it.
var _inbox: Dictionary = {}
var _invitations: Dictionary = {}
var _strikes: Array = []
var _commands: Array = []
var _logged: Array[Dictionary] = []
var _next_id: int = 1


func before_each() -> void:
	_peers.clear()
	_nodes.clear()
	_inbox.clear()
	_invitations.clear()
	_strikes.clear()
	_commands.clear()
	_logged.clear()
	_next_id = 1
	_social = SocialService.new(func() -> Array[ServerPeer]: return _peers,
			func(peer_id: int, bytes: PackedByteArray) -> void: _on_send(peer_id, bytes),
			func(peer: ServerPeer, reason: String) -> void: _strikes.append([peer.peer_id, reason]))
	var chat: ChatRouter = _social.get_chat()
	chat.clock_unix = func() -> int: return NOW
	chat.keep_received = true
	chat.log_sink = func(entry: Dictionary) -> void: _logged.append(entry)
	chat.command_sink = func(peer: ServerPeer, line: String, tick: int) -> void:
		_commands.append([peer.peer_id, line, tick])


func after_each() -> void:
	_social = null
	for node: Node3D in _nodes:
		node.free()
	_nodes.clear()
	_peers.clear()


# --- Helpers ----------------------------------------------------------------------------------

func _on_send(peer_id: int, bytes: PackedByteArray) -> void:
	if not _inbox.has(peer_id):
		_inbox[peer_id] = []
		_invitations[peer_id] = []
	var message: NetMessages.ChatMessage = NetMessages.ChatMessage.decode(bytes)
	if message != null:
		_inbox[peer_id].append(message)
	elif NetMessages.peek_type(bytes) == NetProtocol.MSG_PARTY_INVITATION:
		_invitations[peer_id].append(bytes)


## A peer in the world with the claim of character [param character_id] of account [param account_id] (who
## ignores [param ignored] and is muted until [param muted_until]), joining with [method SocialService.on_peer_joined].
func _join(player_name: String, realm: int, character_id: int, account_id: int, ignored: Array[int] = [],
		muted_until: int = 0, tick: int = 10) -> ServerPeer:
	var peer := ServerPeer.new(_next_id)
	_next_id += 1
	peer.state = ServerPeer.State.IN_WORLD
	peer.display_name = player_name
	peer.realm = realm
	var node := Node3D.new()
	_nodes.append(node)
	var entity := NetEntity.new()
	entity.net_id = peer.peer_id
	entity.kind = NetProtocol.EntityKind.PLAYER
	entity.realm = realm
	entity.display_name = player_name
	entity.node = node
	peer.entity = entity
	var claimed := ClaimedCharacter.new()
	claimed.character_id = character_id
	claimed.account_id = account_id
	claimed.realm = realm
	claimed.display_name = player_name
	claimed.lease_id = "lease-%d" % character_id
	claimed.muted_until_unix = muted_until
	for id: int in ignored:
		claimed.ignored_accounts.append(id)
	peer.claimed = claimed
	_peers.append(peer)
	_social.on_peer_joined(peer, tick)
	return peer


func _leave(peer: ServerPeer, tick: int) -> void:
	_peers.erase(peer)
	_social.on_peer_left(peer, tick)


func _send(peer: ServerPeer, channel: int, text: String, recipient: String = "", tick: int = 100) -> int:
	var message := NetMessages.ChatSend.new()
	message.channel = channel
	message.recipient = recipient
	message.text = text
	return _social.get_chat().handle_send(peer, message.encode(), tick)


func _chat_texts(peer: ServerPeer) -> PackedStringArray:
	var texts := PackedStringArray()
	for message: NetMessages.ChatMessage in _inbox.get(peer.peer_id, []):
		if message.channel != ChatChannel.Id.SYSTEM:
			texts.append("%s: %s" % [message.sender, message.text])
	return texts


func _last(texts: PackedStringArray) -> String:
	return texts[texts.size() - 1] if not texts.is_empty() else ""


func _system_texts(peer: ServerPeer) -> PackedStringArray:
	var texts := PackedStringArray()
	for message: NetMessages.ChatMessage in _inbox.get(peer.peer_id, []):
		if message.channel == ChatChannel.Id.SYSTEM:
			texts.append(message.text)
	return texts


# --- Ignored (§9.3) -----------------------------------------------------------------------------

func test_an_ignored_account_reaches_nobody_who_ignores_it_on_any_channel() -> void:
	var ana: ServerPeer = _join("Ana", VARDHEIM, 101, 1001, [1002])
	var bruno: ServerPeer = _join("Bruno", VARDHEIM, 102, 1002)
	var cai: ServerPeer = _join("Cai", VARDHEIM, 103, 1003)
	assert_eq(_send(bruno, ChatChannel.Id.SAY, "hola cerca", "", 100), ChatRouter.Result.DELIVERED)
	assert_eq(_send(bruno, ChatChannel.Id.ZONE, "hola zona", "", 200), ChatRouter.Result.DELIVERED)
	assert_eq(_chat_texts(ana), PackedStringArray(), "nothing from Bruno reaches Ana")
	assert_eq(_chat_texts(cai), PackedStringArray(["Bruno: hola cerca", "Bruno: hola zona"]), "Cai does get it")
	assert_eq(_chat_texts(bruno), PackedStringArray(["Bruno: hola cerca", "Bruno: hola zona"]),
			"Bruno sees his own copy, as always")
	# The whisper: Bruno sees his copy (he does not know he is ignored) and it does not reach Ana.
	assert_eq(_send(bruno, ChatChannel.Id.WHISPER, "psst", "Ana", 300), ChatRouter.Result.DELIVERED)
	assert_eq(_chat_texts(ana), PackedStringArray(), "not even the whisper")
	assert_eq(_chat_texts(bruno).size(), 3, "Bruno receives the copy of his whisper")
	assert_eq(_system_texts(bruno), PackedStringArray(), "and no notice that gives away that he is ignored")
	# What Ana writes does reach Bruno: ignoring works one way.
	_send(ana, ChatChannel.Id.ZONE, "hola", "", 400)
	assert_eq(_last(_chat_texts(bruno)), "Ana: hola")
	assert_eq(_social.get_chat().get_stats()["ignored_copies"], 3, "three copies that were not sent")


func test_an_ignored_invitation_is_dropped_silently() -> void:
	var ana: ServerPeer = _join("Ana", VARDHEIM, 101, 1001, [1002])
	var bruno: ServerPeer = _join("Bruno", VARDHEIM, 102, 1002)
	var party: PartyManager = _social.get_party()
	party.invite(bruno, "Ana", 100)
	assert_eq(_system_texts(bruno), PackedStringArray([PartyManager.TEXT_INVITED % "Ana"]),
			"Bruno sees the usual")
	assert_eq(_invitations.get(ana.peer_id, []).size(), 0, "the invitation does not reach Ana")
	assert_eq(_system_texts(ana), PackedStringArray(), "nor the notice")
	party.respond(ana, "Bruno", true, 120)
	assert_eq(party.get_party_count(), 0, "and she cannot accept it")
	assert_eq(_system_texts(ana), PackedStringArray([PartyManager.TEXT_NO_INVITATION % "Bruno"]))
	party.step(100 + PartyRules.INVITE_TTL_TICKS)
	assert_eq(_last(_system_texts(bruno)), PartyManager.TEXT_EXPIRED % "Ana", "it expires for Bruno as usual")
	assert_eq(_invitations.get(ana.peer_id, []).size(), 0, "and the expiry does not reach Ana either")
	assert_eq(party.get_stats()["ignored"], 1)
	# The other way around does work.
	party.invite(ana, "Bruno", 4000)
	assert_eq(_invitations.get(bruno.peer_id, []).size(), 1, "Ana invites Bruno as normal")


# --- Mute (§9.5) --------------------------------------------------------------------------------

func test_a_muted_player_cannot_talk_and_learns_how_long_is_left() -> void:
	var ana: ServerPeer = _join("Ana", VARDHEIM, 101, 1001, [], NOW + 599)
	var cai: ServerPeer = _join("Cai", VARDHEIM, 103, 1003)
	for channel: int in [ChatChannel.Id.SAY, ChatChannel.Id.ZONE]:
		assert_eq(_send(ana, channel, "hola %d" % channel, "", 100 + channel * 60), ChatRouter.Result.MUTED)
	assert_eq(_send(ana, ChatChannel.Id.WHISPER, "hola", "Cai", 400), ChatRouter.Result.MUTED, "nor whispers")
	assert_eq(_chat_texts(cai), PackedStringArray(), "nothing goes out")
	assert_eq(_system_texts(ana)[0], "Estás silenciado 10 min más.", "the minutes left, rounded up")
	assert_eq(ana.chat.discarded_muted, 3)
	# Server commands are not chat: they still go out.
	assert_eq(_send(ana, ChatChannel.Id.GM, "reportar Cai otro", "", 500), ChatRouter.Result.COMMAND)
	# When it expires, they can talk again.
	ana.chat.muted_until_unix = NOW
	assert_eq(_send(ana, ChatChannel.Id.ZONE, "ya puedo", "", 700), ChatRouter.Result.DELIVERED)
	ana.chat.muted_until_unix = ChatPeerState.MUTE_NO_END_UNIX
	_send(ana, ChatChannel.Id.ZONE, "otra", "", 800)
	assert_eq(_last(_system_texts(ana)), ChatRouter.TEXT_MUTED_NO_END, "an endless mute")
	ana.chat.muted_until_unix = NOW + 61
	_send(ana, ChatChannel.Id.ZONE, "otra más", "", 900)
	assert_eq(_last(_system_texts(ana)), "Estás silenciado 2 min más.")


# --- GM channel, ring and chat batch ----------------------------------------------------------

func test_the_gm_channel_goes_to_the_command_sink_without_the_repeat_check() -> void:
	var ana: ServerPeer = _join("Ana", VARDHEIM, 101, 1001)
	assert_eq(_send(ana, ChatChannel.Id.GM, "gm  teleport Ana 1 2 3", "", 100), ChatRouter.Result.COMMAND)
	assert_eq(_send(ana, ChatChannel.Id.GM, "gm  teleport Ana 1 2 3", "", 160), ChatRouter.Result.COMMAND,
			"the same command twice is not a repeat")
	assert_eq(_commands.size(), 2)
	assert_eq(_commands[0], [ana.peer_id, "gm teleport Ana 1 2 3", 100], "the sanitized line, with its tick")
	assert_eq(_logged, [] as Array[Dictionary], "a command does not go to the chat batch")
	# It spends its token like any message: out of a burst of 6, the 4 left in the talk bucket go out.
	for i: int in 6:
		_send(ana, ChatChannel.Id.GM, "gm ayuda %d" % i, "", 200)
	assert_eq(_commands.size(), 6, "the burst is the talk one")


func test_receivers_remember_what_they_got_and_each_message_is_logged() -> void:
	var ana: ServerPeer = _join("Ana", VARDHEIM, 101, 1001)
	var bruno: ServerPeer = _join("Bruno", VARDHEIM, 102, 1002)
	var sol: ServerPeer = _join("Sol", SOLMARCH, 201, 2001)
	_send(bruno, ChatChannel.Id.ZONE, "uno", "", 100)
	_send(bruno, ChatChannel.Id.WHISPER, "dos", "Ana", 200)
	_send(ana, ChatChannel.Id.SAY, "tres", "", 300)
	var from_bruno: Array[ChatPeerState.Received] = ana.chat.received_from("bruno", 0, 20)
	assert_eq(from_bruno.size(), 2, "Ana keeps what Bruno sent her")
	assert_eq([from_bruno[0].text, from_bruno[0].channel, from_bruno[0].sender_name, from_bruno[0].sent_at_unix],
			["uno", ChatChannel.Id.ZONE, "Bruno", NOW])
	assert_eq([from_bruno[1].text, from_bruno[1].channel], ["dos", ChatChannel.Id.WHISPER])
	assert_eq(bruno.chat.received_from("bruno", 0, 20).size(), 0, "one's own is not recorded")
	assert_eq(sol.chat.received.size(), 0, "the enemy receives nothing")
	assert_eq(ana.chat.received_from("bruno", 150, 20).size(), 1, "only since a tick")
	assert_eq(ana.chat.received_from("bruno", 0, 1)[0].text, "dos", "the latest ones")
	assert_eq(_logged.size(), 3, "one entry per message, not per copy")
	assert_eq(_logged[0], {"channel": ChatChannel.Id.ZONE, "sender_character_id": "102",
			"target_character_id": null, "text": "uno", "sent_at_unix": NOW})
	assert_eq(_logged[1]["target_character_id"], "101", "the whisper carries the recipient by id")
	# The ring keeps the latest RECEIVED_RING_SIZE.
	for i: int in ChatPeerState.RECEIVED_RING_SIZE + 5:
		_send(bruno, ChatChannel.Id.ZONE, "m%d" % i, "", 1000 + i * 60)
	assert_eq(ana.chat.received.size(), ChatPeerState.RECEIVED_RING_SIZE)
	var last: Array[ChatPeerState.Received] = ana.chat.received_from("bruno", 0, 200)
	assert_eq(last.size(), ChatPeerState.RECEIVED_RING_SIZE, "the last hundred, all from Bruno")
	assert_eq(last[0].text, "m5", "the oldest ones are lost")
	assert_eq(last.back().text, "m%d" % (ChatPeerState.RECEIVED_RING_SIZE + 4), "in order, the newest at the end")


# --- Per-character state (§9.2) -----------------------------------------------------------------

func test_the_chat_state_follows_the_character_for_five_minutes() -> void:
	var ana: ServerPeer = _join("Ana", VARDHEIM, 101, 1001)
	_join("Cai", VARDHEIM, 103, 1003)
	for i: int in ChatPeerState.PUBLIC_BURST:
		assert_eq(_send(ana, ChatChannel.Id.ZONE, "hola %d" % i, "", 100), ChatRouter.Result.DELIVERED)
	assert_eq(_send(ana, ChatChannel.Id.ZONE, "una más", "", 100), ChatRouter.Result.RATE_LIMITED)
	var state: ChatPeerState = ana.chat
	_leave(ana, 101)
	assert_eq(_social.get_retained_count(), 1, "it is kept for their character")
	# They come back in right away (another connection, another peer): the bursts are still spent.
	var again: ServerPeer = _join("Ana", VARDHEIM, 101, 1001, [], 0, 102)
	assert_true(again.chat == state, "recovers the same state")
	assert_eq(_send(again, ChatChannel.Id.ZONE, "otra", "", 102), ChatRouter.Result.RATE_LIMITED,
			"leaving and returning does not refill the burst")
	assert_eq(_social.get_retained_count(), 0)
	# They leave again and come back after 5 min: fresh state.
	_leave(again, 200)
	var later: ServerPeer = _join("Ana", VARDHEIM, 101, 1001, [], 0, 200 + ChatRouter.KNOWN_RECIPIENT_TICKS)
	assert_false(later.chat == state, "after 5 min, a new one")
	# And the purge in the social step forgets the expired ones even if they do not come back.
	_leave(later, 20000)
	_social.step(20000 + SocialService.RETAINED_PURGE_TICKS)
	assert_eq(_social.get_retained_count(), 1, "has not expired yet")
	_social.step(int(ceil(float(20000 + ChatRouter.KNOWN_RECIPIENT_TICKS) / SocialService.RETAINED_PURGE_TICKS))
			* SocialService.RETAINED_PURGE_TICKS)
	assert_eq(_social.get_retained_count(), 0, "expired, it is forgotten")


func test_rejoining_takes_mute_and_ignores_from_the_new_claim() -> void:
	var ana: ServerPeer = _join("Ana", VARDHEIM, 101, 1001, [1002], NOW + 600)
	ana.chat.ignored_by_name["bruno"] = 1002
	_leave(ana, 100)
	var again: ServerPeer = _join("Ana", VARDHEIM, 101, 1001, [1003], 0, 150)
	assert_eq(again.chat.ignored_accounts, {1003: true} as Dictionary[int, bool], "the ones from the new claim")
	assert_eq(again.chat.muted_until_unix, 0, "and their mute")
	assert_eq(again.chat.account_id, 1001)
	# Without a platform (no claim) nothing is kept.
	var dev := ServerPeer.new(99)
	dev.entity = NetEntity.new()
	_social.on_peer_left(dev, 200)
	assert_eq(_social.get_retained_count(), 0)
