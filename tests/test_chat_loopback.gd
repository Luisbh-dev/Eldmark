extends TestCase
## Integración del chat con ENet real sobre 127.0.0.1 en un solo proceso (SOC-04, docs/social.md secciones
## 1, 5 y 12): un [ZoneServer] y varios [NetClient] bots, dos de Vardheim y uno de Solmarch en la misma
## zona. La prueba de aceptación del filtro por reino mira los [b]bytes recibidos[/b] por el cliente del
## otro reino (todos los paquetes que le llegan), no lo que pinta: ninguno puede contener el texto de un
## mensaje que no era para él, ni ser un CHAT_MESSAGE.
## [br][br]
## También se prueba el saneado de lo que llega por la red, el alcance de «decir», los ritmos con sus avisos
## (al jugador y al peer), el susurro a un enemigo (la misma respuesta que a quien no existe), los mensajes
## mal formados y el informe. La lógica por separado, sin red, está en test_chat_router.gd.

const VARDHEIM: int = NetProtocol.Realm.VARDHEIM
const SOLMARCH: int = NetProtocol.Realm.SOLMARCH
const ZONE_ID: String = "test_world"
## Fotogramas de física como mucho que se espera a una condición (10 s).
const WAIT_FRAMES: int = 600

var _root: Node
var _server_viewport: SubViewport
var _server: ZoneServer
var _port: int = 0
var _clients: Array[NetClient] = []
var _client_viewports: Array[SubViewport] = []
# Por cliente (clave: el NetClient): lo que le ha llegado de chat y todos sus paquetes en bruto.
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


# --- Ayudantes --------------------------------------------------------------------------------

func _start_server() -> void:
	_port = NetHarness.free_udp_port()
	_server_viewport = NetHarness.make_world_viewport(_root, "")
	var config := ServerConfig.new()
	config.port = _port
	config.zone_id = ZONE_ID
	config.max_players = 8
	_server = NetHarness.start_server(_server_viewport, config)
	await wait_physics_frames(3)


# Un bot que además apunta el chat que recibe y todos los paquetes que le llegan.
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


# Entran todos y se quedan quietos en su punto de aparición.
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


# Los mensajes del inbox que no son del sistema.
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


# true si algún paquete en bruto de [param client] lleva los bytes UTF-8 de [param token].
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


# --- Pruebas ----------------------------------------------------------------------------------

## El corazón de SOC-04: el cliente del otro reino no recibe NINGÚN paquete con el texto, en ninguno de los
## canales, aunque esté a 3 m del emisor y en la misma zona.
func test_the_enemy_realm_never_receives_a_packet_with_the_text() -> void:
	await _start_server()
	var ana: NetClient = _add_bot(VARDHEIM, 1)
	var bruno: NetClient = _add_bot(VARDHEIM, 2)
	var cora: NetClient = _add_bot(SOLMARCH, 3)
	if not assert_true(await _join_all_and_freeze(), "entran los tres"):
		return
	# El enemigo, junto a Ana: «decir» le alcanzaría si el servidor no filtrase por reino.
	_server.teleport(cora.get_net_id(), Vector3(-19.0, 0.0, 2.0))
	await wait_physics_frames(10)
	var secrets: PackedStringArray = ["secretoDecir", "secretoZona", "secretoSusurro", "secretoEnemigo"]

	assert_true(ana.send_chat(ChatChannel.Id.SAY, "", secrets[0]), "Ana dice")
	assert_true(ana.send_chat(ChatChannel.Id.ZONE, "", secrets[1]), "Ana habla por la zona")
	assert_true(ana.send_chat(ChatChannel.Id.WHISPER, _name_of(bruno), secrets[2]), "Ana susurra a Bruno")
	assert_true(ana.send_chat(ChatChannel.Id.WHISPER, _name_of(cora), secrets[3]), "Ana susurra a Cora")
	var arrived: bool = await _wait_until(func() -> bool:
		return (_chat_lines(ana).size() >= 3 and _chat_lines(bruno).size() >= 3
				and not _system_texts(ana).is_empty()))
	assert_true(arrived, "llegan los mensajes a Ana y a Bruno")
	# Margen para que llegara cualquier fuga.
	await wait_physics_frames(60)

	# Los destinatarios legítimos.
	assert_eq(_chat_lines(bruno).size(), 3, "Bruno recibe el «decir», la zona y el susurro")
	var channels: Array[int] = []
	for line: NetMessages.ChatMessage in _chat_lines(bruno):
		channels.append(line.channel)
		assert_eq(line.sender, _name_of(ana), "emisor")
		assert_eq(line.sender_realm, VARDHEIM, "reino del emisor")
	assert_eq(channels, [ChatChannel.Id.SAY, ChatChannel.Id.ZONE, ChatChannel.Id.WHISPER], "en orden")
	assert_eq(_chat_lines(ana).size(), 3, "Ana recibe la copia de sus tres mensajes")
	# A Ana se le contesta que Cora «no está conectada»: lo mismo que si no existiera.
	assert_eq(_system_texts(ana), PackedStringArray(["«%s» no está conectado." % _name_of(cora)]),
			"respuesta a un susurro a un enemigo")

	# El enemigo: ni un paquete de chat, y ninguno con los textos, en bruto.
	assert_eq(_chat_packet_count(cora), 0, "Cora no recibe ningún CHAT_MESSAGE")
	assert_true(_inbox(cora).is_empty(), "ni siquiera del sistema")
	for secret: String in secrets:
		assert_false(_any_packet_contains(cora, secret), "ningún paquete de Cora lleva «%s»" % secret)
	# Y el susurro fallido tampoco llegó a Bruno.
	assert_false(_any_packet_contains(bruno, secrets[3]), "Bruno no recibe el susurro dirigido a Cora")
	assert_true(_any_packet_contains(bruno, secrets[0]), "control: el análisis de bytes encuentra el texto de Bruno")


func test_say_reaches_thirty_meters_and_zone_does_not_care_about_distance() -> void:
	await _start_server()
	var ana: NetClient = _add_bot(VARDHEIM, 1)
	var bruno: NetClient = _add_bot(VARDHEIM, 2)
	if not assert_true(await _join_all_and_freeze(), "entran los dos"):
		return
	_server.teleport(bruno.get_net_id(), Vector3(15.0, 0.0, 0.0))
	await wait_physics_frames(10)
	var distance: float = _server.get_registry().get_entity(ana.get_net_id()).get_position().distance_to(
			_server.get_registry().get_entity(bruno.get_net_id()).get_position())
	assert_true(distance > 30.0, "Bruno está a más de 30 m de Ana (%.1f)" % distance)
	ana.send_chat(ChatChannel.Id.SAY, "", "no te llego")
	ana.send_chat(ChatChannel.Id.ZONE, "", "esto sí te llega")
	assert_true(await _wait_until(func() -> bool: return not _chat_lines(bruno).is_empty()),
			"llega algo a Bruno")
	await wait_physics_frames(30)
	var lines: Array[NetMessages.ChatMessage] = _chat_lines(bruno)
	assert_eq(lines.size(), 1, "solo la zona")
	assert_eq(lines[0].channel, ChatChannel.Id.ZONE, "canal zona")
	assert_false(_any_packet_contains(bruno, "no te llego"), "el «decir» lejano no llegó en bruto")
	# Ana ve sus dos copias.
	assert_eq(_chat_lines(ana).size(), 2, "Ana recibe sus dos mensajes")


func test_text_is_sanitized_by_the_server_even_if_the_client_does_not() -> void:
	await _start_server()
	var ana: NetClient = _add_bot(VARDHEIM, 1)
	var bruno: NetClient = _add_bot(VARDHEIM, 2)
	if not assert_true(await _join_all_and_freeze(), "entran los dos"):
		return
	# Un cliente tramposo manda el CHAT_SEND a mano, sin sanear.
	var message := NetMessages.ChatSend.new()
	message.channel = ChatChannel.Id.SAY
	message.text = "  [b]Hola[/b]\t\n  [color=red]mundo[/color]\u0007  "
	ana.get_transport().send(NetClient.SERVER_PEER_ID, NetProtocol.CH_RELIABLE, message.encode())
	assert_true(await _wait_until(func() -> bool: return not _chat_lines(bruno).is_empty()), "llega")
	assert_eq(_chat_lines(bruno)[0].text, "Hola mundo", "saneado en el servidor")
	assert_false(_any_packet_contains(bruno, "[b]"), "y los corchetes no cruzan la red")


func test_rate_limit_warns_the_player_and_counts_strikes_every_fifth_discard() -> void:
	await _start_server()
	var ana: NetClient = _add_bot(VARDHEIM, 1)
	var bruno: NetClient = _add_bot(VARDHEIM, 2)
	if not assert_true(await _join_all_and_freeze(), "entran los dos"):
		return
	var peer: ServerPeer = _peer_of(ana)
	if not assert_not_null(peer, "el servidor conoce a Ana"):
		return
	var strikes_before: int = peer.strikes_total
	# Doce mensajes distintos en un instante: cinco caben, siete se descartan (un aviso del peer).
	for i: int in 12:
		assert_true(ana.send_chat(ChatChannel.Id.ZONE, "", "mensaje %d" % i), "se envía el %d" % i)
	assert_true(await _wait_until(func() -> bool:
		return _chat_lines(bruno).size() >= 5 and not _system_texts(ana).is_empty()),
			"llegan cinco y el aviso")
	await wait_physics_frames(30)
	assert_eq(_chat_lines(bruno).size(), 5, "Bruno recibe solo la ráfaga de cinco")
	assert_eq(_system_texts(ana).size(), 1, "un solo aviso al jugador, aunque se descartaran siete")
	assert_eq(_system_texts(ana)[0], ChatRouter.TEXT_TOO_FAST, "«Hablas demasiado rápido.»")
	assert_eq(peer.strikes_total - strikes_before, 1, "siete descartes suman un aviso del peer")
	assert_eq(peer.chat.discards, 7, "siete descartes")
	assert_eq(peer.state, ServerPeer.State.IN_WORLD, "y Ana sigue dentro")


func test_whispering_an_enemy_and_a_nobody_get_the_same_answer() -> void:
	await _start_server()
	var ana: NetClient = _add_bot(VARDHEIM, 1)
	var cora: NetClient = _add_bot(SOLMARCH, 3)
	if not assert_true(await _join_all_and_freeze(), "entran los dos"):
		return
	# Con otras mayúsculas y sin tildes, que es como lo escribe un jugador.
	ana.send_chat(ChatChannel.Id.WHISPER, _name_of(cora).to_upper(), "hola enemigo")
	ana.send_chat(ChatChannel.Id.WHISPER, "Nadie", "hola nadie")
	assert_true(await _wait_until(func() -> bool: return _system_texts(ana).size() >= 2),
			"dos respuestas")
	await wait_physics_frames(20)
	var texts: PackedStringArray = _system_texts(ana)
	assert_eq(texts[0], "«%s» no está conectado." % _name_of(cora).to_upper(), "al enemigo")
	assert_eq(texts[1], "«Nadie» no está conectado.", "a nadie")
	assert_eq(texts[0].replace(_name_of(cora).to_upper(), "X"), texts[1].replace("Nadie", "X"),
			"misma frase")
	assert_true(_inbox(cora).is_empty(), "el enemigo no se entera de nada")
	assert_false(_any_packet_contains(cora, "hola enemigo"), "ni en bruto")


func test_malformed_chat_adds_strikes() -> void:
	await _start_server()
	var ana: NetClient = _add_bot(VARDHEIM, 1)
	if not assert_true(await _join_all_and_freeze(), "entra"):
		return
	var peer: ServerPeer = _peer_of(ana)
	var before: int = peer.strikes_total
	var transport: NetTransport = ana.get_transport()
	# Truncado, canal del sistema, susurro sin destinatario y UTF-8 inválido.
	transport.send(NetClient.SERVER_PEER_ID, NetProtocol.CH_RELIABLE, PackedByteArray([0x40, 0, 0]))
	transport.send(NetClient.SERVER_PEER_ID, NetProtocol.CH_RELIABLE,
			PackedByteArray([0x40, ChatChannel.Id.SYSTEM, 0, 2, 0, 0x68, 0x69]))
	transport.send(NetClient.SERVER_PEER_ID, NetProtocol.CH_RELIABLE,
			PackedByteArray([0x40, ChatChannel.Id.WHISPER, 0, 2, 0, 0x68, 0x69]))
	transport.send(NetClient.SERVER_PEER_ID, NetProtocol.CH_RELIABLE,
			PackedByteArray([0x40, ChatChannel.Id.SAY, 0, 2, 0, 0xFF, 0xFE]))
	assert_true(await _wait_until(func() -> bool: return peer.strikes_total - before >= 4),
			"cuatro avisos")
	assert_eq(peer.strikes_total - before, 4, "exactamente cuatro")
	assert_true(_inbox(ana).is_empty(), "y no se reparte nada")
	assert_eq(peer.state, ServerPeer.State.IN_WORLD, "no se expulsa por cuatro")


func test_the_client_api_refuses_what_the_server_would_drop() -> void:
	await _start_server()
	var ana: NetClient = _add_bot(VARDHEIM, 1)
	assert_false(ana.send_chat(ChatChannel.Id.SAY, "", "demasiado pronto"), "antes de estar en el mundo")
	if not assert_true(await _join_all_and_freeze(), "entra"):
		return
	assert_false(ana.send_chat(ChatChannel.Id.SAY, "", "   "), "texto vacío")
	assert_false(ana.send_chat(ChatChannel.Id.SAY, "", "[b][/b]"), "solo BBCode")
	assert_false(ana.send_chat(ChatChannel.Id.SYSTEM, "", "hola"), "el canal del sistema")
	assert_false(ana.send_chat(99, "", "hola"), "un canal que no existe")
	assert_false(ana.send_chat(ChatChannel.Id.WHISPER, "  ", "hola"), "un susurro sin destinatario")
	assert_true(ana.send_chat(ChatChannel.Id.SAY, "Pepe", "hola"), "el destinatario se ignora fuera del susurro")
	assert_eq(ana.get_stats()["chat_sent"], 1, "solo se envió uno")


func test_the_report_counts_the_chat_of_the_session() -> void:
	await _start_server()
	var ana: NetClient = _add_bot(VARDHEIM, 1)
	var bruno: NetClient = _add_bot(VARDHEIM, 2)
	if not assert_true(await _join_all_and_freeze(), "entran los dos"):
		return
	ana.send_chat(ChatChannel.Id.ZONE, "", "para el informe")
	assert_true(await _wait_until(func() -> bool: return not _chat_lines(bruno).is_empty()), "llega")
	assert_eq(bruno.get_stats()["chat_received"], 1, "Bruno cuenta uno recibido")
	var path: String = NetHarness.build_path("test_chat_loopback_report.json")
	assert_eq(_server.write_report(path), OK, "se escribe el informe")
	var report: Dictionary = NetHarness.read_report(path)
	var chat: Dictionary = report.get("social", {}).get("chat", {})
	assert_eq(chat.get("routed", 0), 1, "un mensaje enrutado")
	assert_eq(chat.get("delivered_copies", 0), 2, "dos copias")
