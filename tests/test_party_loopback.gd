extends TestCase
## Integración de los grupos con ENet real sobre 127.0.0.1 en un solo proceso (SOC-06, docs/social.md sección
## 12.4): un [ZoneServer] y varios [NetClient] bots, dos o tres de Vardheim y uno de Solmarch en la misma zona.
## Los bots envían los mensajes de grupo a mano (el cliente de grupos es de SOC-08) y la prueba decodifica
## lo que les llega en bruto. Flujos: invitar, aceptar, rechazar, la lista de miembros, el líder heredado al
## salir, expulsar, ceder el mando, la invitación a un enemigo (rechazada sin que el enemigo se entere), el
## canal de grupo del chat y el estado compacto a 2 Hz de un miembro fuera del radio de interés. La lógica por
## separado, sin red, está en test_party_manager.gd.

const VARDHEIM: int = NetProtocol.Realm.VARDHEIM
const SOLMARCH: int = NetProtocol.Realm.SOLMARCH
const ZONE_ID: String = "test_world"
const WAIT_FRAMES: int = 600
## Radio de interés de la política de la prueba (m): lo más lejano no sale en los snapshots.
const INTEREST_RADIUS: float = 100.0


## Política de interés que solo ve lo que está a menos de [constant INTEREST_RADIUS] m.
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


# --- Ayudantes --------------------------------------------------------------------------------

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


# Cuántos paquetes de grupo (0x48 a 0x4F) o de chat ha recibido [param client].
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


# Los envíos van por la API del cliente de verdad ([NetClient.send_party_invite] y compañía).
func _invite(from: NetClient, target_name: String) -> void:
	assert_true(from.send_party_invite(target_name), "el cliente envía PARTY_INVITE")


func _respond(from: NetClient, inviter_name: String, accept: bool) -> void:
	assert_true(from.send_party_response(inviter_name, accept), "el cliente envía PARTY_RESPONSE")


func _party_manager() -> PartyManager:
	return _server.get_social().get_party()


# Ana invita a [param other] y este acepta; espera a que los dos tengan la lista con los dos.
func _join_party(leader: NetClient, other: NetClient) -> bool:
	_invite(leader, _name_of(other))
	if not await _wait_until(func() -> bool: return not _packets(other, NetProtocol.MSG_PARTY_INVITATION).is_empty()):
		return false
	_respond(other, _name_of(leader), true)
	# La primera vez, la lista del líder está vacía y pasa a tener dos nombres (él y el recién llegado).
	var expected: int = maxi(_roster_names(leader).size(), 1) + 1
	return await _wait_until(func() -> bool:
		return _roster_names(other).size() == expected and _roster_names(leader).size() == expected)


# --- Pruebas ----------------------------------------------------------------------------------

func test_invite_accept_and_party_chat_with_the_realm_filter() -> void:
	await _start_server()
	var ana: NetClient = _add_bot(VARDHEIM, 1)
	var bruno: NetClient = _add_bot(VARDHEIM, 2)
	var cora: NetClient = _add_bot(SOLMARCH, 3)
	if not assert_true(await _join_all_and_freeze(), "entran los tres"):
		return
	_invite(ana, _name_of(bruno).to_upper())
	assert_true(await _wait_until(func() -> bool:
		return not _packets(bruno, NetProtocol.MSG_PARTY_INVITATION).is_empty()), "Bruno recibe la invitación")
	var offer: NetMessages.PartyInvitation = NetMessages.PartyInvitation.decode(
			_packets(bruno, NetProtocol.MSG_PARTY_INVITATION)[0])
	assert_eq(offer.state, NetMessages.PartyInvitation.State.OFFERED, "nueva")
	assert_eq(offer.inviter, _name_of(ana), "de Ana, con su nombre canónico")
	assert_true(offer.tick > _server.get_tick(), "que caduca en el futuro")
	assert_true(offer.tick <= _server.get_tick() + PartyRules.INVITE_TTL_TICKS, "en 60 s como mucho")

	_respond(bruno, _name_of(ana), true)
	assert_true(await _wait_until(func() -> bool:
		return _roster_names(ana).size() == 2 and _roster_names(bruno).size() == 2), "los dos reciben la lista")
	for client: NetClient in [ana, bruno]:
		var roster: NetMessages.PartyRoster = _last_roster(client)
		assert_eq(roster.members[0].display_name, _name_of(ana), "primero Ana")
		assert_eq(roster.members[0].net_id, ana.get_net_id(), "con el net_id que le dio el servidor")
		assert_eq(roster.members[1].display_name, _name_of(bruno), "después Bruno")
		assert_eq(roster.members[1].net_id, bruno.get_net_id(), "con su net_id")
		assert_eq(roster.get_leader_id(), ana.get_net_id(), "manda Ana")
	assert_eq(_party_manager().get_party_count(), 1, "el servidor tiene un grupo")
	# El estado de grupo del cliente (PartyState) refleja la lista, y la invitación se retiró de Bruno.
	var state: PartyState = bruno.get_party()
	assert_eq(state.get_member_count(), 2, "Bruno ve a dos miembros")
	assert_true(state.is_leader(ana.get_net_id()), "y que Ana manda")
	assert_false(state.is_leader(bruno.get_net_id()), "y él no")
	assert_null(state.get_current_invitation(), "sin invitaciones pendientes")
	assert_eq(bruno.get_stats()["party_rosters"], 1, "una lista recibida")

	# El canal de grupo del chat: solo los miembros, y Cora, del otro reino, nada.
	assert_true(ana.send_chat(ChatChannel.Id.PARTY, "", "secretoGrupo"), "Ana habla al grupo")
	assert_true(await _wait_until(func() -> bool:
		return _chat_lines(bruno, ChatChannel.Id.PARTY) == 1), "llega a Bruno")
	await wait_physics_frames(30)
	assert_eq(_chat_lines(ana, ChatChannel.Id.PARTY), 1, "y a Ana, su copia")
	assert_eq(_social_packet_count(cora), 0, "Cora no recibe ningún paquete de chat ni de grupo")
	assert_false(_any_packet_contains(cora, "secretoGrupo"), "ni con el texto en bruto")


func test_inviting_an_enemy_is_refused_and_the_enemy_never_knows() -> void:
	await _start_server()
	var ana: NetClient = _add_bot(VARDHEIM, 1)
	var cora: NetClient = _add_bot(SOLMARCH, 3)
	if not assert_true(await _join_all_and_freeze(), "entran los dos"):
		return
	_invite(ana, _name_of(cora))
	_invite(ana, "Nadie")
	assert_true(await _wait_until(func() -> bool: return _system_texts(ana).size() >= 2), "dos respuestas")
	await wait_physics_frames(30)
	assert_eq(_system_texts(ana)[0], "«%s» no está conectado." % _name_of(cora), "al enemigo")
	assert_eq(_system_texts(ana)[1], "«Nadie» no está conectado.", "a nadie: la misma frase")
	assert_eq(_social_packet_count(cora), 0, "Cora no recibe ni un paquete social")
	assert_eq(_party_manager().get_pending_count(), 0, "no hay invitación")
	# Cora intenta aceptar de todos modos, y se le dice que no tiene invitación.
	_respond(cora, _name_of(ana), true)
	assert_true(await _wait_until(func() -> bool: return not _system_texts(cora).is_empty()), "responde el servidor")
	assert_eq(_system_texts(cora)[0], "No tienes ninguna invitación de «%s»." % _name_of(ana), "sin invitación")
	assert_eq(_party_manager().get_party_count(), 0, "no hay grupo entre reinos")
	assert_true(_packets(cora, NetProtocol.MSG_PARTY_ROSTER).is_empty(), "y Cora no ha recibido ninguna lista")
	assert_true(_packets(ana, NetProtocol.MSG_PARTY_ROSTER).is_empty(), "ni Ana")


func test_declining_and_expiring_clear_the_invitation() -> void:
	await _start_server()
	var ana: NetClient = _add_bot(VARDHEIM, 1)
	var bruno: NetClient = _add_bot(VARDHEIM, 2)
	if not assert_true(await _join_all_and_freeze(), "entran los dos"):
		return
	_invite(ana, _name_of(bruno))
	assert_true(await _wait_until(func() -> bool:
		return not _packets(bruno, NetProtocol.MSG_PARTY_INVITATION).is_empty()), "llega")
	_respond(bruno, _name_of(ana), false)
	var declined_text: String = "%s ha rechazado tu invitación." % _name_of(bruno)
	assert_true(await _wait_until(func() -> bool: return _system_texts(ana).has(declined_text)), "Ana lo sabe")
	assert_eq(_party_manager().get_party_count(), 0, "sin grupo")
	assert_true(await _wait_until(func() -> bool: return _packets(bruno, NetProtocol.MSG_PARTY_INVITATION).size() == 2),
			"llega el aviso de que la invitación ya no vale")
	var offers: Array[PackedByteArray] = _packets(bruno, NetProtocol.MSG_PARTY_INVITATION)
	assert_eq(NetMessages.PartyInvitation.decode(offers[offers.size() - 1]).state,
			NetMessages.PartyInvitation.State.CANCELLED, "el aviso de Bruno se retira")
	# Una invitación nueva que caduca (el paso del servidor con un tick 60 s más tarde).
	await wait_physics_frames(130)
	_invite(ana, _name_of(bruno))
	assert_true(await _wait_until(func() -> bool: return _packets(bruno, NetProtocol.MSG_PARTY_INVITATION).size() == 3),
			"la segunda invitación llega")
	_party_manager().step(_server.get_tick() + PartyRules.INVITE_TTL_TICKS + 1)
	assert_true(await _wait_until(func() -> bool: return _packets(bruno, NetProtocol.MSG_PARTY_INVITATION).size() == 4),
			"llega el aviso de caducidad")
	offers = _packets(bruno, NetProtocol.MSG_PARTY_INVITATION)
	assert_eq(NetMessages.PartyInvitation.decode(offers[3]).state, NetMessages.PartyInvitation.State.EXPIRED, "caducada")
	assert_eq(_party_manager().get_pending_count(), 0, "sin pendientes")


func test_leaving_kicking_and_the_inherited_lead() -> void:
	await _start_server()
	var ana: NetClient = _add_bot(VARDHEIM, 1)
	var bruno: NetClient = _add_bot(VARDHEIM, 2)
	var cora: NetClient = _add_bot(VARDHEIM, 3)
	if not assert_true(await _join_all_and_freeze(), "entran los tres"):
		return
	assert_true(await _join_party(ana, bruno), "Bruno se une")
	await wait_physics_frames(130)
	assert_true(await _join_party(ana, cora), "Cora se une")
	assert_eq(_roster_names(cora), PackedStringArray([_name_of(ana), _name_of(bruno), _name_of(cora)]),
			"orden de llegada")

	# Ana cede el mando a Cora.
	assert_true(ana.send_party_leader(_name_of(cora)), "Ana cede el mando")
	assert_true(await _wait_until(func() -> bool: return _last_roster(bruno).get_leader_id() == cora.get_net_id()),
			"manda Cora")
	# Bruno no puede expulsar a nadie.
	assert_true(bruno.send_party_kick(_name_of(cora)), "Bruno intenta expulsar")
	assert_true(await _wait_until(func() -> bool: return _system_texts(bruno).has("Solo el líder puede hacer eso.")),
			"un miembro no expulsa")
	assert_eq(_roster_names(bruno).size(), 3, "nadie se va")
	# Cora, que manda, expulsa a Ana.
	assert_true(cora.send_party_kick(_name_of(ana)), "Cora expulsa a Ana")
	assert_true(await _wait_until(func() -> bool: return _last_roster(ana).is_empty()), "Ana recibe la lista vacía")
	assert_true(_system_texts(ana).has("Has sido expulsado del grupo."), "y lo sabe")
	assert_eq(_roster_names(cora), PackedStringArray([_name_of(bruno), _name_of(cora)]), "quedan Bruno y Cora")
	assert_eq(_party_manager().get_party_count(), 1, "el grupo sigue")
	# Cora sale: el grupo de uno se disuelve y Bruno queda sin grupo.
	assert_true(cora.send_party_leave(), "Cora sale")
	assert_true(await _wait_until(func() -> bool:
		return _last_roster(bruno).is_empty() and _last_roster(cora).is_empty()), "los dos reciben la lista vacía")
	assert_true(_system_texts(bruno).has("El grupo se ha disuelto."), "Bruno sabe que se disolvió")
	assert_eq(_party_manager().get_party_count(), 0, "el servidor no tiene grupos")


func test_the_leader_leaving_the_zone_passes_the_lead_on() -> void:
	await _start_server()
	var ana: NetClient = _add_bot(VARDHEIM, 1)
	var bruno: NetClient = _add_bot(VARDHEIM, 2)
	var cora: NetClient = _add_bot(VARDHEIM, 3)
	if not assert_true(await _join_all_and_freeze(), "entran los tres"):
		return
	assert_true(await _join_party(ana, bruno), "Bruno se une")
	await wait_physics_frames(130)
	assert_true(await _join_party(ana, cora), "Cora se une")
	ana.leave()
	assert_true(await _wait_until(func() -> bool:
		return _roster_names(bruno).size() == 2 and _roster_names(cora).size() == 2), "la lista pierde a Ana")
	assert_eq(_roster_names(bruno), PackedStringArray([_name_of(bruno), _name_of(cora)]), "Bruno y Cora")
	assert_eq(_last_roster(cora).get_leader_id(), bruno.get_net_id(), "hereda Bruno, el siguiente más antiguo")
	assert_true(_system_texts(bruno).has("%s ha salido del grupo." % _name_of(ana)), "se cuenta")
	assert_true(_system_texts(bruno).has("%s es ahora el líder del grupo." % _name_of(bruno)), "y quién manda")


func test_member_status_reaches_a_member_outside_the_interest_radius() -> void:
	await _start_server(RangePolicy.new())
	var ana: NetClient = _add_bot(VARDHEIM, 1)
	var bruno: NetClient = _add_bot(VARDHEIM, 2)
	if not assert_true(await _join_all_and_freeze(), "entran los dos"):
		return
	assert_true(await _join_party(ana, bruno), "se agrupan")
	var far: Vector3 = Vector3(190.0, 0.0, 0.0)
	_server.teleport(bruno.get_net_id(), far)
	# Bruno sale del interés de Ana: su vista desaparece, pero el estado de grupo sigue llegando.
	assert_true(await _wait_until(func() -> bool: return ana.get_remote_world().get_view_count() == 0, 300),
			"Ana ya no ve a Bruno en sus snapshots")
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
	assert_true(reached, "el estado de Bruno a 210 m llega a Ana con su posición")
	var packets: Array[PackedByteArray] = _packets(ana, NetProtocol.MSG_PARTY_STATUS)
	var last: NetMessages.PartyStatus = NetMessages.PartyStatus.decode(packets[packets.size() - 1])
	assert_eq(last.members.size(), 2, "los dos miembros")
	assert_eq(last.members[0].net_id, ana.get_net_id(), "Ana, la primera")
	assert_eq(last.members[0].health_q, 255, "con la vida llena")
	assert_eq(last.members[1].stamina_q, PartyRules.STAMINA_Q_MAX, "Bruno, con la resistencia llena")
	# A 2 Hz: en un segundo llegan unos 2 (y a los dos miembros).
	var before: int = _packets(ana, NetProtocol.MSG_PARTY_STATUS).size()
	await wait_physics_frames(120)
	var gained: int = _packets(ana, NetProtocol.MSG_PARTY_STATUS).size() - before
	assert_true(gained >= 3 and gained <= 5, "en 2 s llegan ~4 estados (%d)" % gained)
	# El servidor lo cuenta en el informe.
	var report_path: String = NetHarness.build_path("test_party_loopback_report.json")
	assert_eq(_server.write_report(report_path), OK, "se escribe el informe")
	var party_stats: Dictionary = NetHarness.read_report(report_path).get("social", {}).get("party", {})
	assert_true(party_stats.get("status_sent", 0) > 0, "el informe cuenta los estados enviados")
	assert_eq(party_stats.get("accepted", 0), 1, "y la invitación aceptada")


func test_malformed_party_messages_add_strikes() -> void:
	await _start_server()
	var ana: NetClient = _add_bot(VARDHEIM, 1)
	if not assert_true(await _join_all_and_freeze(), "entra"):
		return
	var peer: ServerPeer = null
	for peer_id: int in _server.get_peer_ids():
		peer = _server.get_peer(peer_id)
	var before: int = peer.strikes_total
	_send(ana, PackedByteArray([0x48, 0]))
	_send(ana, PackedByteArray([0x49, 5, 1, 65]))
	_send(ana, PackedByteArray([0x4A, 1]))
	# Tipos que solo manda el servidor.
	_send(ana, PackedByteArray([0x4E, 0, 0]))
	_send(ana, PackedByteArray([0x47]))
	assert_true(await _wait_until(func() -> bool: return peer.strikes_total - before >= 5), "cinco avisos")
	assert_eq(peer.strikes_total - before, 5, "exactamente cinco")
	assert_eq(peer.state, ServerPeer.State.IN_WORLD, "no se expulsa por cinco")


# --- Más ayudantes ----------------------------------------------------------------------------

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
