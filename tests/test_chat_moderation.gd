extends TestCase
## Pruebas de la moderación en el chat sin red (docs/plataforma.md §9.2 a §9.5, P7b): [SocialService] con peers
## falsos que traen su reclamación. Un ignorado no llega a nadie que lo ignore por ningún canal (y en un susurro el
## emisor no lo nota), su invitación de grupo se descarta en silencio; el silenciado no habla y sabe cuánto le queda; el
## canal GM va al [member ChatRouter.command_sink]; cada receptor apunta lo recibido en su anillo y cada mensaje va al
## lote de chat; el estado del chat es por personaje y se conserva 5 min tras la baja. Las de la zona entera (con
## [FakeZonePlatform]) están en test_zone_moderation.gd.

const VARDHEIM: int = NetProtocol.Realm.VARDHEIM
const SOLMARCH: int = NetProtocol.Realm.SOLMARCH
const NOW: int = 1_800_000_000

var _social: SocialService
var _peers: Array[ServerPeer] = []
var _nodes: Array[Node3D] = []
# peer_id -> los CHAT_MESSAGE (decodificados) y los PARTY_INVITATION (bytes) que se le enviarían.
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


# --- Ayudantes --------------------------------------------------------------------------------

func _on_send(peer_id: int, bytes: PackedByteArray) -> void:
	if not _inbox.has(peer_id):
		_inbox[peer_id] = []
		_invitations[peer_id] = []
	var message: NetMessages.ChatMessage = NetMessages.ChatMessage.decode(bytes)
	if message != null:
		_inbox[peer_id].append(message)
	elif NetMessages.peek_type(bytes) == NetProtocol.MSG_PARTY_INVITATION:
		_invitations[peer_id].append(bytes)


## Un peer en el mundo con la reclamación del personaje [param character_id] de la cuenta [param account_id] (que
## ignora [param ignored] y está silenciada hasta [param muted_until]), y entra con [method SocialService.on_peer_joined].
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


# --- Ignorados (§9.3) ---------------------------------------------------------------------------

func test_an_ignored_account_reaches_nobody_who_ignores_it_on_any_channel() -> void:
	var ana: ServerPeer = _join("Ana", VARDHEIM, 101, 1001, [1002])
	var bruno: ServerPeer = _join("Bruno", VARDHEIM, 102, 1002)
	var cai: ServerPeer = _join("Cai", VARDHEIM, 103, 1003)
	assert_eq(_send(bruno, ChatChannel.Id.SAY, "hola cerca", "", 100), ChatRouter.Result.DELIVERED)
	assert_eq(_send(bruno, ChatChannel.Id.ZONE, "hola zona", "", 200), ChatRouter.Result.DELIVERED)
	assert_eq(_chat_texts(ana), PackedStringArray(), "a Ana no le llega nada de Bruno")
	assert_eq(_chat_texts(cai), PackedStringArray(["Bruno: hola cerca", "Bruno: hola zona"]), "a Cai sí")
	assert_eq(_chat_texts(bruno), PackedStringArray(["Bruno: hola cerca", "Bruno: hola zona"]),
			"Bruno ve su propia copia, como siempre")
	# El susurro: Bruno ve su copia (no sabe que lo ignoran) y a Ana no le llega.
	assert_eq(_send(bruno, ChatChannel.Id.WHISPER, "psst", "Ana", 300), ChatRouter.Result.DELIVERED)
	assert_eq(_chat_texts(ana), PackedStringArray(), "ni el susurro")
	assert_eq(_chat_texts(bruno).size(), 3, "Bruno recibe la copia de su susurro")
	assert_eq(_system_texts(bruno), PackedStringArray(), "y ningún aviso que delate que lo ignoran")
	# Lo que Ana escribe sí le llega a Bruno: ignorar es en un sentido.
	_send(ana, ChatChannel.Id.ZONE, "hola", "", 400)
	assert_eq(_last(_chat_texts(bruno)), "Ana: hola")
	assert_eq(_social.get_chat().get_stats()["ignored_copies"], 3, "tres copias que no salieron")


func test_an_ignored_invitation_is_dropped_silently() -> void:
	var ana: ServerPeer = _join("Ana", VARDHEIM, 101, 1001, [1002])
	var bruno: ServerPeer = _join("Bruno", VARDHEIM, 102, 1002)
	var party: PartyManager = _social.get_party()
	party.invite(bruno, "Ana", 100)
	assert_eq(_system_texts(bruno), PackedStringArray([PartyManager.TEXT_INVITED % "Ana"]),
			"Bruno ve lo de siempre")
	assert_eq(_invitations.get(ana.peer_id, []).size(), 0, "a Ana no le llega la invitación")
	assert_eq(_system_texts(ana), PackedStringArray(), "ni el aviso")
	party.respond(ana, "Bruno", true, 120)
	assert_eq(party.get_party_count(), 0, "y no la puede aceptar")
	assert_eq(_system_texts(ana), PackedStringArray([PartyManager.TEXT_NO_INVITATION % "Bruno"]))
	party.step(100 + PartyRules.INVITE_TTL_TICKS)
	assert_eq(_last(_system_texts(bruno)), PartyManager.TEXT_EXPIRED % "Ana", "a Bruno le caduca como siempre")
	assert_eq(_invitations.get(ana.peer_id, []).size(), 0, "y a Ana tampoco le llega la caducidad")
	assert_eq(party.get_stats()["ignored"], 1)
	# Al revés sí funciona.
	party.invite(ana, "Bruno", 4000)
	assert_eq(_invitations.get(bruno.peer_id, []).size(), 1, "Ana invita a Bruno con normalidad")


# --- Silencio (§9.5) -----------------------------------------------------------------------------

func test_a_muted_player_cannot_talk_and_learns_how_long_is_left() -> void:
	var ana: ServerPeer = _join("Ana", VARDHEIM, 101, 1001, [], NOW + 599)
	var cai: ServerPeer = _join("Cai", VARDHEIM, 103, 1003)
	for channel: int in [ChatChannel.Id.SAY, ChatChannel.Id.ZONE]:
		assert_eq(_send(ana, channel, "hola %d" % channel, "", 100 + channel * 60), ChatRouter.Result.MUTED)
	assert_eq(_send(ana, ChatChannel.Id.WHISPER, "hola", "Cai", 400), ChatRouter.Result.MUTED, "ni susurra")
	assert_eq(_chat_texts(cai), PackedStringArray(), "no sale nada")
	assert_eq(_system_texts(ana)[0], "Estás silenciado 10 min más.", "los minutos que quedan, hacia arriba")
	assert_eq(ana.chat.discarded_muted, 3)
	# Los comandos del servidor no son chat: siguen saliendo.
	assert_eq(_send(ana, ChatChannel.Id.GM, "reportar Cai otro", "", 500), ChatRouter.Result.COMMAND)
	# Cuando vence, vuelve a hablar.
	ana.chat.muted_until_unix = NOW
	assert_eq(_send(ana, ChatChannel.Id.ZONE, "ya puedo", "", 700), ChatRouter.Result.DELIVERED)
	ana.chat.muted_until_unix = ChatPeerState.MUTE_NO_END_UNIX
	_send(ana, ChatChannel.Id.ZONE, "otra", "", 800)
	assert_eq(_last(_system_texts(ana)), ChatRouter.TEXT_MUTED_NO_END, "un silencio sin fin")
	ana.chat.muted_until_unix = NOW + 61
	_send(ana, ChatChannel.Id.ZONE, "otra más", "", 900)
	assert_eq(_last(_system_texts(ana)), "Estás silenciado 2 min más.")


# --- Canal GM, anillo y lote de chat ----------------------------------------------------------------

func test_the_gm_channel_goes_to_the_command_sink_without_the_repeat_check() -> void:
	var ana: ServerPeer = _join("Ana", VARDHEIM, 101, 1001)
	assert_eq(_send(ana, ChatChannel.Id.GM, "gm  teleport Ana 1 2 3", "", 100), ChatRouter.Result.COMMAND)
	assert_eq(_send(ana, ChatChannel.Id.GM, "gm  teleport Ana 1 2 3", "", 160), ChatRouter.Result.COMMAND,
			"el mismo comando dos veces no es una repetición")
	assert_eq(_commands.size(), 2)
	assert_eq(_commands[0], [ana.peer_id, "gm teleport Ana 1 2 3", 100], "la línea saneada, con su tick")
	assert_eq(_logged, [] as Array[Dictionary], "un comando no va al lote de chat")
	# Gasta su ficha como cualquier mensaje: de 6 en ráfaga salen las 4 que quedan en el cubo de hablar.
	for i: int in 6:
		_send(ana, ChatChannel.Id.GM, "gm ayuda %d" % i, "", 200)
	assert_eq(_commands.size(), 6, "la ráfaga es la de hablar")


func test_receivers_remember_what_they_got_and_each_message_is_logged() -> void:
	var ana: ServerPeer = _join("Ana", VARDHEIM, 101, 1001)
	var bruno: ServerPeer = _join("Bruno", VARDHEIM, 102, 1002)
	var sol: ServerPeer = _join("Sol", SOLMARCH, 201, 2001)
	_send(bruno, ChatChannel.Id.ZONE, "uno", "", 100)
	_send(bruno, ChatChannel.Id.WHISPER, "dos", "Ana", 200)
	_send(ana, ChatChannel.Id.SAY, "tres", "", 300)
	var from_bruno: Array[ChatPeerState.Received] = ana.chat.received_from("bruno", 0, 20)
	assert_eq(from_bruno.size(), 2, "Ana guarda lo que le mandó Bruno")
	assert_eq([from_bruno[0].text, from_bruno[0].channel, from_bruno[0].sender_name, from_bruno[0].sent_at_unix],
			["uno", ChatChannel.Id.ZONE, "Bruno", NOW])
	assert_eq([from_bruno[1].text, from_bruno[1].channel], ["dos", ChatChannel.Id.WHISPER])
	assert_eq(bruno.chat.received_from("bruno", 0, 20).size(), 0, "lo propio no se apunta")
	assert_eq(sol.chat.received.size(), 0, "el enemigo no recibe nada")
	assert_eq(ana.chat.received_from("bruno", 150, 20).size(), 1, "solo desde un tick")
	assert_eq(ana.chat.received_from("bruno", 0, 1)[0].text, "dos", "los últimos")
	assert_eq(_logged.size(), 3, "una entrada por mensaje, no por copia")
	assert_eq(_logged[0], {"channel": ChatChannel.Id.ZONE, "sender_character_id": "102",
			"target_character_id": null, "text": "uno", "sent_at_unix": NOW})
	assert_eq(_logged[1]["target_character_id"], "101", "el susurro lleva el destinatario por id")
	# El anillo guarda los últimos RECEIVED_RING_SIZE.
	for i: int in ChatPeerState.RECEIVED_RING_SIZE + 5:
		_send(bruno, ChatChannel.Id.ZONE, "m%d" % i, "", 1000 + i * 60)
	assert_eq(ana.chat.received.size(), ChatPeerState.RECEIVED_RING_SIZE)
	var last: Array[ChatPeerState.Received] = ana.chat.received_from("bruno", 0, 200)
	assert_eq(last.size(), ChatPeerState.RECEIVED_RING_SIZE, "los cien últimos, todos de Bruno")
	assert_eq(last[0].text, "m5", "los más viejos se han perdido")
	assert_eq(last.back().text, "m%d" % (ChatPeerState.RECEIVED_RING_SIZE + 4), "en orden, el más nuevo al final")


# --- Estado por personaje (§9.2) -----------------------------------------------------------------

func test_the_chat_state_follows_the_character_for_five_minutes() -> void:
	var ana: ServerPeer = _join("Ana", VARDHEIM, 101, 1001)
	_join("Cai", VARDHEIM, 103, 1003)
	for i: int in ChatPeerState.PUBLIC_BURST:
		assert_eq(_send(ana, ChatChannel.Id.ZONE, "hola %d" % i, "", 100), ChatRouter.Result.DELIVERED)
	assert_eq(_send(ana, ChatChannel.Id.ZONE, "una más", "", 100), ChatRouter.Result.RATE_LIMITED)
	var state: ChatPeerState = ana.chat
	_leave(ana, 101)
	assert_eq(_social.get_retained_count(), 1, "se conserva por su personaje")
	# Vuelve a entrar enseguida (otra conexión, otro peer): las ráfagas siguen gastadas.
	var again: ServerPeer = _join("Ana", VARDHEIM, 101, 1001, [], 0, 102)
	assert_true(again.chat == state, "recupera el mismo estado")
	assert_eq(_send(again, ChatChannel.Id.ZONE, "otra", "", 102), ChatRouter.Result.RATE_LIMITED,
			"salir y volver no rellena la ráfaga")
	assert_eq(_social.get_retained_count(), 0)
	# Sale otra vez y vuelve pasados 5 min: estado nuevo.
	_leave(again, 200)
	var later: ServerPeer = _join("Ana", VARDHEIM, 101, 1001, [], 0, 200 + ChatRouter.KNOWN_RECIPIENT_TICKS)
	assert_false(later.chat == state, "pasados 5 min, uno nuevo")
	# Y la purga del paso social olvida los vencidos aunque no vuelvan.
	_leave(later, 20000)
	_social.step(20000 + SocialService.RETAINED_PURGE_TICKS)
	assert_eq(_social.get_retained_count(), 1, "aún no ha vencido")
	_social.step(int(ceil(float(20000 + ChatRouter.KNOWN_RECIPIENT_TICKS) / SocialService.RETAINED_PURGE_TICKS))
			* SocialService.RETAINED_PURGE_TICKS)
	assert_eq(_social.get_retained_count(), 0, "vencido, se olvida")


func test_rejoining_takes_mute_and_ignores_from_the_new_claim() -> void:
	var ana: ServerPeer = _join("Ana", VARDHEIM, 101, 1001, [1002], NOW + 600)
	ana.chat.ignored_by_name["bruno"] = 1002
	_leave(ana, 100)
	var again: ServerPeer = _join("Ana", VARDHEIM, 101, 1001, [1003], 0, 150)
	assert_eq(again.chat.ignored_accounts, {1003: true} as Dictionary[int, bool], "las de la reclamación nueva")
	assert_eq(again.chat.muted_until_unix, 0, "y su silencio")
	assert_eq(again.chat.account_id, 1001)
	# Sin plataforma (sin reclamación) no se conserva nada.
	var dev := ServerPeer.new(99)
	dev.entity = NetEntity.new()
	_social.on_peer_left(dev, 200)
	assert_eq(_social.get_retained_count(), 0)
