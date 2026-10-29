extends TestCase
## Pruebas de [ChatRouter] (SOC-04, docs/social.md secciones 1, 2 y 5) sin red: peers falsos, un
## [Callable] que apunta lo que se enviaría a cada uno y otro que apunta los avisos. Se comprueba el
## alcance de cada canal, el filtro por reino (el enemigo no recibe nada), el saneado, los ritmos y el
## susurro a un enemigo. La prueba con clientes de ENet de verdad es test_chat_loopback.gd.

const VARDHEIM: int = NetProtocol.Realm.VARDHEIM
const SOLMARCH: int = NetProtocol.Realm.SOLMARCH

var _router: ChatRouter
var _peers: Array[ServerPeer] = []
var _nodes: Array[Node3D] = []
# peer_id -> los CHAT_MESSAGE que se le enviarían, ya decodificados.
var _inbox: Dictionary = {}
# peer_id -> bytes de todo lo que se le enviaría (para comprobar que no recibe nada).
var _raw_inbox: Dictionary = {}
# [peer_id, motivo] de cada aviso sumado.
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
	# El enrutador guarda lambdas que apuntan a esta prueba: soltarlo rompe el ciclo.
	_router = null
	for node: Node3D in _nodes:
		node.free()
	_nodes.clear()
	_peers.clear()


# --- Ayudantes --------------------------------------------------------------------------------

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


# Los mensajes que no son del sistema que ha recibido [param peer].
func _chat_lines(peer: ServerPeer) -> Array[NetMessages.ChatMessage]:
	var lines: Array[NetMessages.ChatMessage] = []
	for message: NetMessages.ChatMessage in _messages(peer):
		if message.channel != ChatChannel.Id.SYSTEM:
			lines.append(message)
	return lines


# Los textos del sistema que ha recibido [param peer].
func _system_texts(peer: ServerPeer) -> PackedStringArray:
	var texts := PackedStringArray()
	for message: NetMessages.ChatMessage in _messages(peer):
		if message.channel == ChatChannel.Id.SYSTEM:
			texts.append(message.text)
	return texts


func _received_nothing(peer: ServerPeer) -> bool:
	return not _raw_inbox.has(peer.peer_id)


# --- Decir y zona -----------------------------------------------------------------------------

func test_say_reaches_the_same_realm_within_range_and_nobody_else() -> void:
	var ana: ServerPeer = _add_peer("Ana", VARDHEIM, Vector3(0.0, 0.0, 0.0))
	var bruno: ServerPeer = _add_peer("Bruno", VARDHEIM, Vector3(29.0, 0.0, 0.0))
	var lejos: ServerPeer = _add_peer("Lejos", VARDHEIM, Vector3(31.0, 0.0, 0.0))
	var enemigo: ServerPeer = _add_peer("Enemigo", SOLMARCH, Vector3(1.0, 0.0, 0.0))
	assert_eq(_send(ana, ChatChannel.Id.SAY, "Hola a todos"), ChatRouter.Result.DELIVERED, "se reparte")
	for receiver: ServerPeer in [ana, bruno]:
		var lines: Array[NetMessages.ChatMessage] = _chat_lines(receiver)
		if not assert_eq(lines.size(), 1, "%s recibe el mensaje" % receiver.display_name):
			continue
		assert_eq(lines[0].channel, ChatChannel.Id.SAY, "canal decir")
		assert_eq(lines[0].sender, "Ana", "emisor")
		assert_eq(lines[0].sender_realm, VARDHEIM, "reino del emisor")
		assert_eq(lines[0].text, "Hola a todos", "texto")
		assert_eq(lines[0].tick, 100, "tick del servidor")
	assert_true(_received_nothing(lejos), "a 31 m no llega nada")
	assert_true(_received_nothing(enemigo), "el enemigo, aunque esté a 1 m, no recibe ningún paquete")


func test_say_range_is_three_dimensional_and_exactly_thirty_meters() -> void:
	var ana: ServerPeer = _add_peer("Ana", VARDHEIM, Vector3.ZERO)
	var justo: ServerPeer = _add_peer("Justo", VARDHEIM, Vector3(30.0, 0.0, 0.0))
	var alto: ServerPeer = _add_peer("Alto", VARDHEIM, Vector3(0.0, 31.0, 0.0))
	_send(ana, ChatChannel.Id.SAY, "x")
	assert_eq(_chat_lines(justo).size(), 1, "a 30 m justos sí")
	assert_true(_received_nothing(alto), "a 31 m de altura no")


func test_zone_reaches_the_whole_realm_but_not_the_enemy() -> void:
	var ana: ServerPeer = _add_peer("Ana", VARDHEIM, Vector3.ZERO)
	var lejos: ServerPeer = _add_peer("Lejos", VARDHEIM, Vector3(300.0, 0.0, 0.0))
	var enemigo: ServerPeer = _add_peer("Enemigo", SOLMARCH, Vector3(1.0, 0.0, 0.0))
	assert_eq(_send(ana, ChatChannel.Id.ZONE, "Todos al fuerte"), ChatRouter.Result.DELIVERED, "se reparte")
	assert_eq(_chat_lines(ana).size(), 1, "el emisor recibe su copia")
	var lines: Array[NetMessages.ChatMessage] = _chat_lines(lejos)
	if assert_eq(lines.size(), 1, "a 300 m también llega"):
		assert_eq(lines[0].channel, ChatChannel.Id.ZONE, "canal zona")
	assert_true(_received_nothing(enemigo), "el enemigo no recibe nada")


func test_peers_not_in_the_world_are_ignored() -> void:
	var ana: ServerPeer = _add_peer("Ana", VARDHEIM)
	var cargando: ServerPeer = _add_peer("Cargando", VARDHEIM)
	cargando.state = ServerPeer.State.LOADING
	var saliendo: ServerPeer = _add_peer("Saliendo", VARDHEIM)
	saliendo.state = ServerPeer.State.LEAVING
	_send(ana, ChatChannel.Id.ZONE, "Hola")
	assert_true(_received_nothing(cargando), "quien carga la zona no recibe")
	assert_true(_received_nothing(saliendo), "ni quien se va")
	assert_eq(_chat_lines(ana).size(), 1, "el emisor sí")


# --- Saneado ----------------------------------------------------------------------------------

func test_text_is_sanitized_before_it_is_sent() -> void:
	var ana: ServerPeer = _add_peer("Ana", VARDHEIM)
	var bruno: ServerPeer = _add_peer("Bruno", VARDHEIM)
	_send(ana, ChatChannel.Id.SAY, "  [b]Hola[/b]\t\tmundo\n  ", "", 100)
	var lines: Array[NetMessages.ChatMessage] = _chat_lines(bruno)
	if assert_eq(lines.size(), 1, "llega"):
		assert_eq(lines[0].text, "Hola mundo", "sin BBCode, con los espacios arreglados")


func test_empty_text_after_sanitizing_is_dropped_without_a_strike() -> void:
	var ana: ServerPeer = _add_peer("Ana", VARDHEIM)
	for text: String in ["", "   ", "[b][/b]", "\t\n"]:
		assert_eq(_send(ana, ChatChannel.Id.SAY, text), ChatRouter.Result.EMPTY, "vacío: «%s»" % text)
	assert_true(_received_nothing(ana), "no se reparte nada")
	assert_true(_strikes.is_empty(), "y tampoco suma avisos")
	assert_eq(ana.chat.discarded_empty, 4, "se cuenta")


func test_an_empty_text_still_spends_its_token() -> void:
	# El ritmo va antes que el saneado: un cliente tramposo no puede hacer trabajar al servidor gratis con
	# textos que quedan vacíos (ni con canales sin servicio).
	var ana: ServerPeer = _add_peer("Ana", VARDHEIM)
	var bruno: ServerPeer = _add_peer("Bruno", VARDHEIM)
	assert_eq(_send(ana, ChatChannel.Id.ZONE, "[[x]]", "", 100), ChatRouter.Result.EMPTY, "el primero, vacío")
	assert_true(ana.chat.limiter_public.get_tokens(100) < ChatPeerState.PUBLIC_BURST,
			"y ya ha gastado una ficha")
	for i: int in 3:
		assert_eq(_send(ana, ChatChannel.Id.ZONE, "[[x]]", "", 100), ChatRouter.Result.EMPTY, "vacío %d" % i)
	assert_eq(_send(ana, ChatChannel.Id.RAID, "Hola", "", 100), ChatRouter.Result.UNAVAILABLE,
			"un canal sin servicio también gasta la suya")
	assert_eq(_send(ana, ChatChannel.Id.ZONE, "hola", "", 100), ChatRouter.Result.RATE_LIMITED,
			"cinco gastadas: el texto normal ya no cabe")
	assert_eq(_send(ana, ChatChannel.Id.RAID, "Hola", "", 100), ChatRouter.Result.RATE_LIMITED,
			"ni otra respuesta del sistema")
	assert_eq(_chat_lines(bruno).size(), 0, "Bruno no ha recibido nada")


func test_flooding_texts_that_sanitize_to_nothing_adds_strikes() -> void:
	var ana: ServerPeer = _add_peer("Ana", VARDHEIM)
	# El peor caso del saneado de antes: 127 niveles de corchetes, que quedan en nada.
	var nested: String = "[".repeat(127) + "]".repeat(127)
	var results: Dictionary = {}
	for i: int in 30:
		var result: int = _send(ana, ChatChannel.Id.ZONE, nested, "", 100)
		results[result] = results.get(result, 0) + 1
	assert_eq(results.get(ChatRouter.Result.EMPTY, 0), 5, "la ráfaga de cinco se gasta en vacíos")
	assert_eq(results.get(ChatRouter.Result.RATE_LIMITED, 0), 25, "y el resto se descarta por ritmo")
	assert_eq(ana.chat.discards, 25, "veinticinco descartes")
	assert_eq(_strikes.size(), 25 - ChatPeerState.FLOOD_FREE_DISCARDS, "pasados los diez gratis, un aviso cada uno")


# --- Susurros ---------------------------------------------------------------------------------

func test_whisper_reaches_the_target_and_the_sender_only() -> void:
	var ana: ServerPeer = _add_peer("Ana", VARDHEIM, Vector3.ZERO)
	var bruno: ServerPeer = _add_peer("Bruno", VARDHEIM, Vector3(500.0, 0.0, 0.0))
	var tercero: ServerPeer = _add_peer("Tercero", VARDHEIM, Vector3(1.0, 0.0, 0.0))
	assert_eq(_send(ana, ChatChannel.Id.WHISPER, "Psst", "Bruno"), ChatRouter.Result.DELIVERED, "se reparte")
	for receiver: ServerPeer in [ana, bruno]:
		var lines: Array[NetMessages.ChatMessage] = _chat_lines(receiver)
		if not assert_eq(lines.size(), 1, "%s recibe el susurro" % receiver.display_name):
			continue
		assert_eq(lines[0].channel, ChatChannel.Id.WHISPER, "canal susurro")
		assert_eq(lines[0].sender, "Ana", "emisor")
		assert_eq(lines[0].recipient, "Bruno", "destinatario con su nombre canónico")
		assert_eq(lines[0].text, "Psst", "texto")
	assert_true(_received_nothing(tercero), "un tercero, aunque esté al lado, no oye el susurro")
	# El servidor no guarda «el último interlocutor» (/r lo resuelve el cliente, docs/social.md 12.2).
	for property: Dictionary in ana.chat.get_property_list():
		assert_false(String(property["name"]).contains("partner"), "ChatPeerState no guarda el interlocutor")


func test_whisper_name_ignores_case_and_accents() -> void:
	var ana: ServerPeer = _add_peer("Ana", VARDHEIM)
	var pena: ServerPeer = _add_peer("Peña", VARDHEIM)
	assert_eq(_send(ana, ChatChannel.Id.WHISPER, "Hola", "peña"), ChatRouter.Result.DELIVERED, "peña")
	assert_eq(_chat_lines(pena).size(), 1, "llega a Peña")
	var lines: Array[NetMessages.ChatMessage] = _chat_lines(pena)
	assert_eq(lines[0].recipient, "Peña", "con el nombre canónico, no con el tecleado")
	assert_eq(_send(ana, ChatChannel.Id.WHISPER, "Otra", "PENA", 200), ChatRouter.Result.DELIVERED,
			"PENA (sin tilde ni eñe, en mayúsculas)")
	assert_eq(_chat_lines(pena).size(), 2, "también llega")


func test_whisper_to_an_enemy_looks_exactly_like_whispering_to_nobody() -> void:
	var ana: ServerPeer = _add_peer("Ana", VARDHEIM)
	var cora: ServerPeer = _add_peer("Cora", SOLMARCH)
	assert_eq(_send(ana, ChatChannel.Id.WHISPER, "Hola", "Cora", 100), ChatRouter.Result.NO_TARGET,
			"a un enemigo")
	assert_eq(_send(ana, ChatChannel.Id.WHISPER, "Hola", "Nadie", 200), ChatRouter.Result.NO_TARGET,
			"a alguien que no existe")
	var texts: PackedStringArray = _system_texts(ana)
	assert_eq(texts, PackedStringArray(["«Cora» no está conectado.", "«Nadie» no está conectado."]),
			"la misma respuesta, con lo que escribió el jugador")
	assert_true(_received_nothing(cora), "el enemigo no recibe ningún paquete")
	# Se repite lo escrito, no el nombre canónico: ni mayúsculas ni tildes del otro lado de la frontera.
	var cora_accents: ServerPeer = _add_peer("Álvaro", SOLMARCH)
	_send(ana, ChatChannel.Id.WHISPER, "Hola", "alvaro", 300)
	assert_eq(_system_texts(ana)[2], "«alvaro» no está conectado.", "se repite lo tecleado")
	assert_true(_received_nothing(cora_accents), "y Álvaro no recibe nada")
	assert_eq(ana.chat.whisper_misses, 3, "se cuentan los fallos")


func test_whisper_to_yourself_is_refused() -> void:
	var ana: ServerPeer = _add_peer("Ana", VARDHEIM)
	assert_eq(_send(ana, ChatChannel.Id.WHISPER, "Hola", "ana"), ChatRouter.Result.NO_TARGET, "a sí mismo")
	assert_eq(_system_texts(ana), PackedStringArray([ChatRouter.TEXT_SELF_WHISPER]), "con su aviso")


func test_whisper_recipient_in_the_message_is_cleaned_in_the_reply() -> void:
	var ana: ServerPeer = _add_peer("Ana", VARDHEIM)
	_send(ana, ChatChannel.Id.WHISPER, "Hola", "[b]Nadie[/b]")
	assert_eq(_system_texts(ana), PackedStringArray(["«Nadie» no está conectado."]),
			"el nombre de la respuesta también se sanea")


# --- Grupo y canales sin servicio -------------------------------------------------------------

func test_party_channel_without_a_party_says_so() -> void:
	var ana: ServerPeer = _add_peer("Ana", VARDHEIM)
	assert_eq(_send(ana, ChatChannel.Id.PARTY, "Hola"), ChatRouter.Result.NO_TARGET, "sin grupo")
	assert_eq(_system_texts(ana), PackedStringArray([ChatRouter.TEXT_NO_PARTY]), "aviso")


func test_party_channel_reaches_the_members_and_never_another_realm() -> void:
	var ana: ServerPeer = _add_peer("Ana", VARDHEIM, Vector3.ZERO)
	var bruno: ServerPeer = _add_peer("Bruno", VARDHEIM, Vector3(900.0, 0.0, 0.0))
	var aparte: ServerPeer = _add_peer("Aparte", VARDHEIM, Vector3(1.0, 0.0, 0.0))
	var enemigo: ServerPeer = _add_peer("Enemigo", SOLMARCH, Vector3.ZERO)
	# Un grupo mal formado que incluye a un enemigo: el enrutador no le manda nada.
	_router.party_members = func(_peer: ServerPeer) -> Array[ServerPeer]:
		return [ana, bruno, enemigo]
	assert_eq(_send(ana, ChatChannel.Id.PARTY, "Atacamos"), ChatRouter.Result.DELIVERED, "se reparte")
	assert_eq(_chat_lines(ana).size(), 1, "el emisor")
	assert_eq(_chat_lines(bruno).size(), 1, "un miembro lejano")
	assert_true(_received_nothing(aparte), "quien no está en el grupo no recibe, aunque esté al lado")
	assert_true(_received_nothing(enemigo), "un enemigo nunca recibe, ni por error")
	assert_eq(_chat_lines(bruno)[0].channel, ChatChannel.Id.PARTY, "canal grupo")


func test_unavailable_channels_answer_without_a_strike() -> void:
	var ana: ServerPeer = _add_peer("Ana", VARDHEIM)
	for channel: int in [ChatChannel.Id.RAID, ChatChannel.Id.GUILD, ChatChannel.Id.REALM]:
		assert_eq(_send(ana, channel, "Hola"), ChatRouter.Result.UNAVAILABLE,
				"el canal %s no está disponible" % ChatChannel.display_name(channel))
	assert_eq(_system_texts(ana), PackedStringArray([ChatRouter.TEXT_UNAVAILABLE,
			ChatRouter.TEXT_UNAVAILABLE, ChatRouter.TEXT_UNAVAILABLE]), "se avisa")
	assert_eq(_send(ana, ChatChannel.Id.GM, "Hola"), ChatRouter.Result.UNAVAILABLE, "GM")
	assert_eq(_system_texts(ana)[3], ChatRouter.TEXT_UNKNOWN_COMMAND,
			"GM contesta como un comando desconocido: no se revela que existe")
	assert_true(_strikes.is_empty(), "sin avisos")


# --- Mensajes inválidos -----------------------------------------------------------------------

func test_malformed_and_out_of_place_messages_add_a_strike() -> void:
	var ana: ServerPeer = _add_peer("Ana", VARDHEIM)
	assert_eq(_router.handle_send(ana, PackedByteArray([0x40, 0, 0]), 100), ChatRouter.Result.MALFORMED,
			"truncado")
	assert_eq(_strikes, [[ana.peer_id, ChatRouter.STRIKE_REASON_MALFORMED]], "suma un aviso")
	# El canal del sistema no lo envía un cliente.
	var spoof := PackedByteArray([0x40, ChatChannel.Id.SYSTEM, 0, 4, 0, 0x68, 0x6F, 0x6C, 0x61])
	assert_eq(_router.handle_send(ana, spoof, 100), ChatRouter.Result.MALFORMED, "canal del sistema")
	assert_eq(_strikes.size(), 2, "otro aviso")
	assert_true(_received_nothing(ana), "y no se reparte nada")
	# Quien aún no está en el mundo.
	var cargando: ServerPeer = _add_peer("Cargando", VARDHEIM)
	cargando.state = ServerPeer.State.LOADING
	var valid := NetMessages.ChatSend.new()
	valid.text = "Hola"
	assert_eq(_router.handle_send(cargando, valid.encode(), 100), ChatRouter.Result.MALFORMED,
			"antes de entrar en el mundo")
	assert_eq(_strikes[2], [cargando.peer_id, ChatRouter.STRIKE_REASON_NOT_IN_WORLD], "con su motivo")


# --- Ritmos -----------------------------------------------------------------------------------

func test_public_rate_allows_a_burst_of_five_then_one_per_second() -> void:
	var ana: ServerPeer = _add_peer("Ana", VARDHEIM)
	var bruno: ServerPeer = _add_peer("Bruno", VARDHEIM)
	for i: int in 5:
		assert_eq(_send(ana, ChatChannel.Id.SAY, "mensaje %d" % i, "", 100), ChatRouter.Result.DELIVERED,
				"la ráfaga admite el mensaje %d" % i)
	assert_eq(_send(ana, ChatChannel.Id.SAY, "mensaje 5", "", 100), ChatRouter.Result.RATE_LIMITED,
			"el sexto se descarta")
	assert_eq(_chat_lines(bruno).size(), 5, "Bruno ha recibido cinco")
	assert_eq(_system_texts(ana), PackedStringArray([ChatRouter.TEXT_TOO_FAST]), "y Ana, el aviso")
	# Un segundo después (60 ticks) vuelve a caber uno.
	assert_eq(_send(ana, ChatChannel.Id.SAY, "mensaje 6", "", 160), ChatRouter.Result.DELIVERED,
			"un segundo después cabe otro")
	assert_eq(_send(ana, ChatChannel.Id.SAY, "mensaje 7", "", 160), ChatRouter.Result.RATE_LIMITED,
			"pero no dos")


func test_say_zone_and_party_share_the_same_bucket() -> void:
	var ana: ServerPeer = _add_peer("Ana", VARDHEIM)
	_router.party_members = func(_peer: ServerPeer) -> Array[ServerPeer]: return [ana]
	assert_eq(_send(ana, ChatChannel.Id.SAY, "uno"), ChatRouter.Result.DELIVERED, "decir")
	assert_eq(_send(ana, ChatChannel.Id.ZONE, "dos"), ChatRouter.Result.DELIVERED, "zona")
	assert_eq(_send(ana, ChatChannel.Id.PARTY, "tres"), ChatRouter.Result.DELIVERED, "grupo")
	assert_eq(_send(ana, ChatChannel.Id.SAY, "cuatro"), ChatRouter.Result.DELIVERED, "decir")
	assert_eq(_send(ana, ChatChannel.Id.ZONE, "cinco"), ChatRouter.Result.DELIVERED, "zona")
	assert_eq(_send(ana, ChatChannel.Id.PARTY, "seis"), ChatRouter.Result.RATE_LIMITED,
			"el sexto, sea del canal que sea")


func test_the_warning_is_sent_at_most_once_per_second() -> void:
	var ana: ServerPeer = _add_peer("Ana", VARDHEIM)
	for i: int in 5:
		_send(ana, ChatChannel.Id.SAY, "m%d" % i, "", 100)
	for i: int in 4:
		_send(ana, ChatChannel.Id.SAY, "d%d" % i, "", 100 + i)
	assert_eq(_system_texts(ana).size(), 1, "cuatro descartados en cuatro ticks, un solo aviso")
	_send(ana, ChatChannel.Id.SAY, "tarde", "", 100 + ChatRouter.WARNING_INTERVAL_TICKS - 1)
	assert_eq(_system_texts(ana).size(), 1, "aún dentro del segundo")


func test_the_first_ten_discards_in_ten_seconds_are_free_and_then_each_adds_a_strike() -> void:
	var ana: ServerPeer = _add_peer("Ana", VARDHEIM)
	assert_eq(ChatPeerState.FLOOD_FREE_DISCARDS, 10, "diez gratis")
	assert_eq(ChatPeerState.FLOOD_WINDOW_TICKS, ServerPeer.STRIKE_WINDOW_TICKS, "en la ventana de los avisos")
	for i: int in 5:
		_send(ana, ChatChannel.Id.SAY, "m%d" % i, "", 100)
	for i: int in 10:
		_send(ana, ChatChannel.Id.SAY, "d%d" % i, "", 100 + i)
	assert_true(_strikes.is_empty(), "diez descartes no suman nada: pulsar Intro de más no cuesta")
	_send(ana, ChatChannel.Id.SAY, "d10", "", 110)
	assert_eq(_strikes, [[ana.peer_id, ChatRouter.STRIKE_REASON_FLOOD]], "el undécimo suma un aviso")
	_send(ana, ChatChannel.Id.SAY, "d11", "", 111)
	assert_eq(_strikes.size(), 2, "y cada uno de los siguientes, otro")
	assert_eq(ana.chat.discards, 12, "doce descartes")
	# Pasados 10 s desde los primeros, la ventana se ha vaciado y vuelven a ser gratis.
	var later: int = 112 + ChatPeerState.FLOOD_WINDOW_TICKS
	for i: int in 5:
		_send(ana, ChatChannel.Id.SAY, "n%d" % i, "", later)
	for i: int in 10:
		_send(ana, ChatChannel.Id.SAY, "x%d" % i, "", later)
	assert_eq(_strikes.size(), 2, "diez descartes más, diez segundos después, no suman nada")


func test_an_honest_burst_never_adds_a_strike() -> void:
	var ana: ServerPeer = _add_peer("Ana", VARDHEIM)
	# Diez Intro seguidos y otros cinco a los 2 s: se descartan ocho, ningún aviso.
	for i: int in 10:
		_send(ana, ChatChannel.Id.SAY, "prisa %d" % i, "", 100)
	for i: int in 5:
		_send(ana, ChatChannel.Id.SAY, "más prisa %d" % i, "", 220)
	assert_eq(ana.chat.discards, 8, "ocho descartes")
	assert_true(_strikes.is_empty(), "y ningún aviso del peer")


func test_a_sustained_flood_through_the_transport_gets_the_player_kicked() -> void:
	# Como en ZoneServer: cada CHAT_SEND pasa antes por el cubo fiable del transporte (10/s, ráfaga de 20) y
	# los avisos van al ServerPeer de verdad, que expulsa con 50 en 600 ticks. Un cliente que manda
	# justo 10 mensajes distintos por segundo no recibe ningún aviso del transporte.
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
	assert_eq(clock["transport_drops"], 0, "el transporte no descarta nada a 10/s")
	assert_true(clock["kicked_at"] >= 0, "la inundación sostenida expulsa (tick %d)" % clock["kicked_at"])
	assert_true(clock["kicked_at"] < 600, "en menos de 10 s")
	router = null


func test_a_repeated_text_is_dropped_for_ten_seconds() -> void:
	var ana: ServerPeer = _add_peer("Ana", VARDHEIM)
	var bruno: ServerPeer = _add_peer("Bruno", VARDHEIM)
	assert_eq(_send(ana, ChatChannel.Id.SAY, "¡Al fuerte!", "", 100), ChatRouter.Result.DELIVERED, "el primero")
	assert_eq(_send(ana, ChatChannel.Id.SAY, "¡Al fuerte!", "", 160), ChatRouter.Result.REPEATED,
			"igual al anterior a los 1 s")
	assert_eq(_send(ana, ChatChannel.Id.ZONE, "¡Al  fuerte!", "", 200), ChatRouter.Result.REPEATED,
			"igual tras sanear y en otro canal")
	assert_eq(_send(ana, ChatChannel.Id.SAY, "¡Al fuerte ya!", "", 220), ChatRouter.Result.DELIVERED,
			"un texto distinto pasa")
	assert_eq(_send(ana, ChatChannel.Id.SAY, "¡Al fuerte ya!", "", 220 + ChatRouter.REPEAT_WINDOW_TICKS),
			ChatRouter.Result.DELIVERED, "pasados 10 s se admite de nuevo")
	assert_eq(_chat_lines(bruno).size(), 3, "Bruno ve tres, no las repeticiones")
	assert_eq(ana.chat.discarded_repeat, 2, "dos repeticiones")
	assert_eq(_system_texts(ana), PackedStringArray([ChatRouter.TEXT_REPEATED]),
			"con su propio aviso (uno por segundo como mucho), no «Hablas demasiado rápido»")


func test_the_same_whisper_to_another_recipient_is_delivered() -> void:
	var ana: ServerPeer = _add_peer("Ana", VARDHEIM)
	var bea: ServerPeer = _add_peer("Bea", VARDHEIM)
	var eva: ServerPeer = _add_peer("Eva", VARDHEIM)
	assert_eq(_send(ana, ChatChannel.Id.WHISPER, "ok", "Bea", 100), ChatRouter.Result.DELIVERED, "«ok» a Bea")
	assert_eq(_send(ana, ChatChannel.Id.WHISPER, "ok", "Eva", 200), ChatRouter.Result.DELIVERED,
			"y el mismo «ok» a Eva también llega")
	assert_eq(_chat_lines(eva).size(), 1, "Eva lo recibe")
	assert_true(_system_texts(ana).is_empty(), "sin avisos")
	assert_eq(_send(ana, ChatChannel.Id.WHISPER, "ok", "EVA", 260), ChatRouter.Result.REPEATED,
			"al mismo destinatario (escrito como sea) sí es repetición")
	assert_eq(_system_texts(ana), PackedStringArray([ChatRouter.TEXT_REPEATED]), "con su aviso")
	assert_eq(_send(ana, ChatChannel.Id.SAY, "ok", "", 400), ChatRouter.Result.DELIVERED,
			"de un susurro a un canal público no cruza")
	assert_eq(_send(ana, ChatChannel.Id.WHISPER, "ok", "Bea", 460), ChatRouter.Result.DELIVERED,
			"ni de un canal público a un susurro")
	assert_eq(_chat_lines(bea).size(), 3, "Bea: dos susurros y el «decir»")


func test_whisper_has_its_own_burst_of_three() -> void:
	var ana: ServerPeer = _add_peer("Ana", VARDHEIM)
	var bruno: ServerPeer = _add_peer("Bruno", VARDHEIM)
	for i: int in 3:
		assert_eq(_send(ana, ChatChannel.Id.WHISPER, "susurro %d" % i, "Bruno", 100),
				ChatRouter.Result.DELIVERED, "el susurro %d" % i)
	assert_eq(_send(ana, ChatChannel.Id.WHISPER, "susurro 3", "Bruno", 100), ChatRouter.Result.RATE_LIMITED,
			"el cuarto se descarta")
	# El cubo de hablar no se ha tocado.
	assert_eq(_send(ana, ChatChannel.Id.SAY, "sigo hablando", "", 100), ChatRouter.Result.DELIVERED,
			"decir sigue libre")
	assert_eq(_chat_lines(bruno).size(), 4, "Bruno recibió tres susurros y el «decir»")


func test_whisper_allows_five_new_recipients_per_minute() -> void:
	var ana: ServerPeer = _add_peer("Ana", VARDHEIM)
	var others: Array[ServerPeer] = []
	for i: int in 7:
		others.append(_add_peer("Otro%s" % char(97 + i), VARDHEIM))
	var tick: int = 100
	for i: int in 5:
		assert_eq(_send(ana, ChatChannel.Id.WHISPER, "hola %d" % i, others[i].display_name, tick),
				ChatRouter.Result.DELIVERED, "el destinatario nuevo %d" % i)
		tick += 60
	assert_eq(_send(ana, ChatChannel.Id.WHISPER, "hola sexto", others[5].display_name, tick),
			ChatRouter.Result.RATE_LIMITED, "el sexto destinatario nuevo en menos de un minuto")
	# A uno ya conocido sí se puede seguir susurrando.
	assert_eq(_send(ana, ChatChannel.Id.WHISPER, "otra cosa", others[0].display_name, tick + 60),
			ChatRouter.Result.DELIVERED, "a quien ya conoce, sí")
	# Pasado el tiempo, el cubo se recarga a razón de 5 por minuto.
	assert_eq(_send(ana, ChatChannel.Id.WHISPER, "ahora sí", others[5].display_name, tick + 900),
			ChatRouter.Result.DELIVERED, "un rato después cabe otro nuevo")


func test_a_player_who_only_receives_whispers_keeps_only_recent_partners() -> void:
	var diana: ServerPeer = _add_peer("Diana", VARDHEIM)
	var gap: int = ChatRouter.KNOWN_RECIPIENT_TICKS * 5
	for i: int in 200:
		var sender: ServerPeer = _add_peer("Emisor%s%s" % [char(97 + i / 26), char(97 + i % 26)], VARDHEIM)
		var tick: int = 100 + i * gap
		assert_eq(_send(sender, ChatChannel.Id.WHISPER, "hola", "Diana", tick), ChatRouter.Result.DELIVERED,
				"%s susurra a Diana" % sender.display_name)
		assert_true(diana.chat.knows_recipient(SocialPeers.name_key_of(sender), tick,
				ChatRouter.KNOWN_RECIPIENT_TICKS), "justo después, Diana lo cuenta como interlocutor")
		# El emisor se va de la zona.
		_peers.erase(sender)
	assert_true(diana.chat.known_recipients.size() <= 1,
			"Diana solo guarda a los de los últimos 5 min (%d)" % diana.chat.known_recipients.size())


func test_replying_to_someone_who_whispered_you_is_not_a_new_recipient() -> void:
	var ana: ServerPeer = _add_peer("Ana", VARDHEIM)
	var strangers: Array[ServerPeer] = []
	for i: int in 6:
		strangers.append(_add_peer("Intruso%s" % char(97 + i), VARDHEIM))
	# Seis desconocidos le susurran a Ana.
	var tick: int = 100
	for stranger: ServerPeer in strangers:
		assert_eq(_send(stranger, ChatChannel.Id.WHISPER, "hola Ana", "Ana", tick),
				ChatRouter.Result.DELIVERED, "%s susurra a Ana" % stranger.display_name)
		tick += 10
	# Ana les responde a los seis: ninguno cuenta como nuevo.
	for stranger: ServerPeer in strangers:
		tick += 60
		assert_eq(_send(ana, ChatChannel.Id.WHISPER, "hola " + stranger.display_name,
				stranger.display_name, tick), ChatRouter.Result.DELIVERED,
				"responde a %s" % stranger.display_name)


func test_stats_count_the_results() -> void:
	var ana: ServerPeer = _add_peer("Ana", VARDHEIM)
	var bruno: ServerPeer = _add_peer("Bruno", VARDHEIM)
	_send(ana, ChatChannel.Id.SAY, "uno")
	_send(ana, ChatChannel.Id.SAY, "")
	var stats: Dictionary = _router.get_stats()
	assert_eq(stats["routed"], 2, "dos procesados")
	assert_eq(stats["delivered_copies"], 2, "dos copias repartidas (Ana y Bruno)")
	assert_eq(stats["results"]["delivered"], 1, "uno repartido")
	assert_eq(stats["results"]["empty"], 1, "uno vacío")
	assert_eq(ana.chat.accepted, 1, "aceptados por Ana")
	assert_eq(bruno.chat.accepted, 0, "y por Bruno ninguno")
