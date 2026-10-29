extends TestCase
## Pruebas de los grupos del servidor ([PartyManager] dentro de [SocialService], SOC-06, docs/social.md
## secciones 3 y 12.4) sin red: peers falsos y un [Callable] que apunta lo que se enviaría a cada uno.
## Se comprueban todos los flujos (invitar, aceptar, rechazar, caducar, salir, expulsar, ceder el mando,
## desconexión), los topes (5 miembros, 5 invitaciones pendientes, el ritmo de invitar), que un enemigo no
## puede ser invitado ni se entera, el líder heredado, el canal de grupo del chat y el estado de los
## miembros a 2 Hz aunque estén lejos. La prueba con clientes de ENet es test_party_loopback.gd.

const VARDHEIM: int = NetProtocol.Realm.VARDHEIM
const SOLMARCH: int = NetProtocol.Realm.SOLMARCH
const PLAYER_SCENE: PackedScene = preload("res://scenes/characters/player_character.tscn")

var _service: SocialService
var _party: PartyManager
var _peers: Array[ServerPeer] = []
var _nodes: Array[Node3D] = []
# peer_id -> los bytes que se le enviarían, en orden.
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


# --- Ayudantes --------------------------------------------------------------------------------

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


# Un Array[ServerPeer] con [param list] (para comparar con los miembros de un grupo).
func _ps(list: Array) -> Array[ServerPeer]:
	var result: Array[ServerPeer] = []
	for peer: ServerPeer in list:
		result.append(peer)
	return result


# Primer tick desde [param from_tick] (incluido) en el que el grupo [param party_id] manda su estado.
func _status_tick_from(party_id: int, from_tick: int) -> int:
	var tick: int = from_tick
	while not PartyManager.is_status_tick(party_id, tick):
		tick += 1
	return tick


# Une a [param joiners] al grupo de [param leader] (invitaciones y aceptaciones espaciadas para no pasar los
# ritmos).
func _form_party(leader: ServerPeer, joiners: Array[ServerPeer], start_tick: int = 100) -> int:
	var tick: int = start_tick
	for joiner: ServerPeer in joiners:
		_party.invite(leader, joiner.display_name, tick)
		_party.respond(joiner, leader.display_name, true, tick)
		tick += 130
	return tick


# --- Invitar y aceptar ------------------------------------------------------------------------

func test_invite_and_accept_form_a_party() -> void:
	var ana: ServerPeer = _add_peer("Ana")
	var bruno: ServerPeer = _add_peer("Bruno")
	_party.invite(ana, "bruno", 100)
	assert_eq(_last_system(ana), "Has invitado a Bruno al grupo.", "el invitador lo sabe")
	var offers: Array[NetMessages.PartyInvitation] = _invitations(bruno)
	if not assert_eq(offers.size(), 1, "Bruno recibe la invitación"):
		return
	assert_eq(offers[0].state, NetMessages.PartyInvitation.State.OFFERED, "nueva")
	assert_eq(offers[0].inviter, "Ana", "de Ana")
	assert_eq(offers[0].tick, 100 + PartyRules.INVITE_TTL_TICKS, "caduca a los 60 s")
	assert_eq(_last_system(bruno), "Ana te ha invitado a su grupo.", "y la ve en el chat")
	assert_eq(_party.get_pending_count(), 1, "una pendiente")
	assert_eq(_party.get_party_count(), 0, "aún no hay grupo")

	_party.respond(bruno, "ANA", true, 200)
	assert_eq(_party.get_party_count(), 1, "se crea el grupo")
	assert_eq(_party.get_pending_count(), 0, "y la invitación se consume")
	assert_eq(_party.members_of(ana), _ps([ana, bruno]), "Ana lidera y Bruno es el segundo")
	assert_eq(_party.leader_of(bruno), ana, "el líder es Ana")
	for peer: ServerPeer in [ana, bruno]:
		var roster: NetMessages.PartyRoster = _last_roster(peer)
		if not assert_not_null(roster, "%s recibe la lista" % peer.display_name):
			continue
		assert_eq(roster.leader_index, 0, "el líder es el primero")
		assert_eq(roster.members.size(), 2, "dos miembros")
		assert_eq(roster.members[0].display_name, "Ana", "primero Ana")
		assert_eq(roster.members[0].net_id, ana.entity.net_id, "con su net_id")
		assert_eq(roster.members[1].display_name, "Bruno", "después Bruno")
		assert_eq(_last_system(peer), "Bruno se ha unido al grupo.", "y los dos lo leen")
	# La invitación se quita del aviso de Bruno.
	var offers_after: Array[NetMessages.PartyInvitation] = _invitations(bruno)
	assert_eq(offers_after[offers_after.size() - 1].state, NetMessages.PartyInvitation.State.CANCELLED,
			"el aviso de Bruno se retira")


func test_decline_tells_the_inviter_and_clears_the_prompt() -> void:
	var ana: ServerPeer = _add_peer("Ana")
	var bruno: ServerPeer = _add_peer("Bruno")
	_party.invite(ana, "Bruno", 100)
	_party.respond(bruno, "Ana", false, 150)
	assert_eq(_last_system(ana), "Bruno ha rechazado tu invitación.", "Ana lo sabe")
	assert_eq(_party.get_party_count(), 0, "sin grupo")
	assert_eq(_party.get_pending_count(), 0, "sin pendientes")
	var offers: Array[NetMessages.PartyInvitation] = _invitations(bruno)
	assert_eq(offers[offers.size() - 1].state, NetMessages.PartyInvitation.State.CANCELLED, "aviso retirado")
	assert_eq(_party.get_stats()["declined"], 1, "se cuenta")


func test_an_invitation_expires_after_sixty_seconds() -> void:
	var ana: ServerPeer = _add_peer("Ana")
	var bruno: ServerPeer = _add_peer("Bruno")
	_party.invite(ana, "Bruno", 100)
	_party.step(100 + PartyRules.INVITE_TTL_TICKS - 1)
	assert_eq(_party.get_pending_count(), 1, "un tick antes sigue valiendo")
	_party.step(100 + PartyRules.INVITE_TTL_TICKS)
	assert_eq(_party.get_pending_count(), 0, "a los 3600 ticks caduca")
	var offers: Array[NetMessages.PartyInvitation] = _invitations(bruno)
	assert_eq(offers[offers.size() - 1].state, NetMessages.PartyInvitation.State.EXPIRED, "Bruno lo sabe")
	assert_eq(_last_system(ana), "La invitación a Bruno ha caducado.", "y Ana")
	_party.respond(bruno, "Ana", true, 100 + PartyRules.INVITE_TTL_TICKS + 5)
	assert_eq(_last_system(bruno), "No tienes ninguna invitación de «Ana».", "aceptar tarde no vale")
	assert_eq(_party.get_party_count(), 0, "sin grupo")


func test_inviting_an_enemy_or_nobody_gets_the_same_answer_and_tells_nobody() -> void:
	var ana: ServerPeer = _add_peer("Ana")
	var cora: ServerPeer = _add_peer("Cora", SOLMARCH)
	_party.invite(ana, "Cora", 100)
	_party.invite(ana, "Nadie", 300)
	assert_eq(_system_texts(ana), PackedStringArray(["«Cora» no está conectado.",
			"«Nadie» no está conectado."]), "la misma respuesta, con lo que escribió el jugador")
	assert_false(_raw_inbox.has(cora.peer_id), "el enemigo no recibe ningún paquete")
	assert_eq(_party.get_pending_count(), 0, "no queda ninguna invitación")
	# Una respuesta del enemigo a una invitación que no existe no hace nada.
	_party.respond(cora, "Ana", true, 400)
	assert_eq(_party.get_party_count(), 0, "no hay grupo entre reinos")
	assert_eq(_last_system(cora), "No tienes ninguna invitación de «Ana».", "y se le dice que no hay invitación")
	assert_true(_system_texts(ana).size() == 2, "Ana no se entera de nada más")


func test_invalid_invitations_are_refused_with_a_reason() -> void:
	var ana: ServerPeer = _add_peer("Ana")
	var bruno: ServerPeer = _add_peer("Bruno")
	var cora: ServerPeer = _add_peer("Cora")
	_party.invite(ana, "ana", 100)
	assert_eq(_last_system(ana), PartyManager.TEXT_SELF_INVITE, "a sí mismo")
	_party.invite(ana, "Bruno", 300)
	_party.invite(ana, "Bruno", 500)
	assert_eq(_last_system(ana), "Ya has invitado a Bruno.", "dos veces a la misma persona")
	assert_eq(_party.get_pending_count(), 1, "solo una invitación")
	# Cora ya está en un grupo (con Bruno): no se la puede invitar.
	_party.respond(bruno, "Ana", true, 600)
	_party.invite(bruno, "Cora", 800)
	_party.respond(cora, "Bruno", true, 900)
	_party.invite(ana, "Cora", 1100)
	assert_eq(_last_system(ana), "Cora ya está en tu grupo.", "a alguien de tu grupo")
	var dani: ServerPeer = _add_peer("Dani")
	var eva: ServerPeer = _add_peer("Eva")
	_party.invite(dani, "Eva", 100)
	_party.respond(eva, "Dani", true, 150)
	_party.invite(dani, "Ana", 400)
	_party.invite(ana, "Dani", 700)
	assert_eq(_last_system(ana), "Dani ya está en un grupo.", "a alguien de otro grupo")


func test_a_party_has_at_most_five_members() -> void:
	var leader: ServerPeer = _add_peer("Lider")
	var joiners: Array[ServerPeer] = []
	for i: int in 4:
		joiners.append(_add_peer("Miembro%s" % char(97 + i)))
	var tick: int = _form_party(leader, joiners)
	assert_eq(_party.members_of(leader).size(), NetProtocol.PARTY_MAX_SIZE, "cinco miembros")
	assert_eq(NetProtocol.PARTY_MAX_SIZE, 5, "el tope compartido es 5")
	var sixth: ServerPeer = _add_peer("Sexto")
	_party.invite(leader, "Sexto", tick)
	assert_eq(_last_system(leader), "Tu grupo está completo (máximo 5).", "no se puede invitar a un sexto")
	assert_false(_raw_inbox.has(sixth.peer_id), "y el sexto no recibe nada")
	# Una invitación que se hizo antes de llenarse falla al aceptarla.
	var late: ServerPeer = _add_peer("Tarde")
	var second_leader: ServerPeer = joiners[0]
	_party.invite(second_leader, "Tarde", tick + 300)
	assert_eq(_last_system(second_leader), "Tu grupo está completo (máximo 5).", "tampoco otro miembro")
	assert_eq(_party.get_pending_count(), 0, "sin invitaciones")
	assert_false(_raw_inbox.has(late.peer_id), "y Tarde no recibe nada")


func test_an_invitation_sent_before_the_party_filled_up_fails_when_accepted() -> void:
	var leader: ServerPeer = _add_peer("Lider")
	var late: ServerPeer = _add_peer("Tarde")
	# Se invita a Tarde cuando el grupo aún tiene sitio...
	_party.invite(leader, "Tarde", 100)
	# ...y se llena antes de que responda.
	var joiners: Array[ServerPeer] = []
	for i: int in 4:
		joiners.append(_add_peer("Miembro%s" % char(97 + i)))
	_form_party(leader, joiners, 300)
	assert_eq(_party.members_of(leader).size(), 5, "cinco miembros")
	_party.respond(late, "Lider", true, 2000)
	assert_eq(_last_system(late), PartyManager.TEXT_PARTY_FULL, "el grupo está completo")
	assert_eq(_party.members_of(leader).size(), 5, "no entra")


func test_each_player_has_at_most_five_pending_invitations() -> void:
	var ana: ServerPeer = _add_peer("Ana")
	var targets: Array[ServerPeer] = []
	for i: int in 6:
		targets.append(_add_peer("Objetivo%s" % char(97 + i)))
	var tick: int = 100
	for i: int in 5:
		_party.invite(ana, targets[i].display_name, tick)
		tick += 130
	assert_eq(_party.get_pending_from(ana), PartyRules.MAX_PENDING_PER_INVITER, "cinco pendientes")
	_party.invite(ana, targets[5].display_name, tick)
	assert_eq(_last_system(ana), "Tienes demasiadas invitaciones pendientes.", "la sexta no")
	assert_false(_raw_inbox.has(targets[5].peer_id), "y la sexta persona no recibe nada")
	# Al caducar una vuelve a haber sitio.
	_party.step(100 + PartyRules.INVITE_TTL_TICKS)
	assert_eq(_party.get_pending_from(ana), 4, "una caducó")
	_party.invite(ana, targets[5].display_name, tick + PartyRules.INVITE_TTL_TICKS)
	assert_eq(_party.get_pending_from(ana), 5, "y se puede invitar a otro")


func test_inviting_has_its_own_rate_limit_and_flooding_adds_strikes() -> void:
	var ana: ServerPeer = _add_peer("Ana")
	for i: int in 4:
		_add_peer("Blanco%s" % char(97 + i))
	for i: int in 3:
		_party.invite(ana, "Blanco%s" % char(97 + i), 100)
	assert_eq(_party.get_pending_count(), 3, "la ráfaga admite tres")
	_party.invite(ana, "Blancod", 100)
	assert_eq(_last_system(ana), "Invitas demasiado rápido.", "la cuarta se descarta")
	assert_eq(_party.get_pending_count(), 3, "y no se crea")
	assert_true(_strikes.is_empty(), "un descarte no suma avisos")
	# Veinte descartes en el mismo tick: un solo aviso al jugador y, pasados los diez gratis, uno del peer
	# por descarte.
	for i: int in 19:
		_party.invite(ana, "Blancod", 100)
	assert_eq(_system_texts(ana).count("Invitas demasiado rápido."), 1,
			"un solo «Invitas demasiado rápido.» por segundo, no uno por descarte")
	assert_eq(_strikes.size(), 20 - ChatPeerState.FLOOD_FREE_DISCARDS, "diez avisos del peer")
	assert_eq(_strikes[0], [ana.peer_id, PartyManager.STRIKE_REASON_FLOOD], "por inundar")
	# Un segundo después, si sigue sin caber, otro aviso al jugador.
	_party.invite(ana, "Blancod", 100 + ChatRouter.WARNING_INTERVAL_TICKS)
	assert_eq(_system_texts(ana).count("Invitas demasiado rápido."), 2, "un segundo después, otro")
	# Pasados 2 s vuelve a caber una.
	_party.invite(ana, "Blancod", 100 + 120)
	assert_eq(_party.get_pending_count(), 4, "2 s después, otra")


func test_accepting_one_invitation_cancels_the_others() -> void:
	var ana: ServerPeer = _add_peer("Ana")
	var bruno: ServerPeer = _add_peer("Bruno")
	var cora: ServerPeer = _add_peer("Cora")
	_party.invite(ana, "Cora", 100)
	_party.invite(bruno, "Cora", 100)
	assert_eq(_party.get_pending_count(), 2, "dos invitaciones a Cora")
	_party.respond(cora, "Ana", true, 200)
	assert_eq(_party.get_pending_count(), 0, "al aceptar una, la otra se cancela")
	var offers: Array[NetMessages.PartyInvitation] = _invitations(cora)
	var cancelled: int = 0
	for offer: NetMessages.PartyInvitation in offers:
		if offer.state == NetMessages.PartyInvitation.State.CANCELLED:
			cancelled += 1
	assert_eq(cancelled, 2, "los dos avisos de Cora se retiran")
	assert_eq(_party.members_of(cora), _ps([ana, cora]), "Cora está con Ana")


func test_forming_a_party_cancels_the_inviters_received_invitations() -> void:
	var ana: ServerPeer = _add_peer("Ana")
	var bea: ServerPeer = _add_peer("Bea")
	var eva: ServerPeer = _add_peer("Eva")
	_party.invite(eva, "Ana", 100)
	_party.invite(ana, "Bea", 230)
	_party.respond(bea, "Ana", true, 360)
	assert_eq(_party.members_of(ana), _ps([ana, bea]), "Ana y Bea forman grupo")
	assert_eq(_party.get_pending_count(), 0, "la invitación de Eva a Ana deja de valer")
	assert_eq(_party.get_pending_from(eva), 0, "y Eva recupera su hueco de pendientes")
	var offers: Array[NetMessages.PartyInvitation] = _invitations(ana)
	var last: NetMessages.PartyInvitation = offers[offers.size() - 1]
	assert_eq(last.state, NetMessages.PartyInvitation.State.CANCELLED, "el aviso de Ana se retira")
	assert_eq(last.inviter, "Eva", "el de Eva")
	_party.respond(ana, "Eva", true, 400)
	assert_eq(_last_system(ana), "No tienes ninguna invitación de «Eva».", "ya no se puede aceptar")
	assert_eq(_party.members_of(ana).size(), 2, "y Ana sigue en su grupo")


# --- Salir, expulsar y el mando ---------------------------------------------------------------

func test_the_next_oldest_inherits_the_lead_when_the_leader_leaves() -> void:
	var ana: ServerPeer = _add_peer("Ana")
	var bruno: ServerPeer = _add_peer("Bruno")
	var cora: ServerPeer = _add_peer("Cora")
	_form_party(ana, [bruno, cora])
	_party.leave(ana, 1000)
	assert_eq(_party.leader_of(bruno), bruno, "Bruno, el siguiente más antiguo, manda")
	assert_eq(_party.members_of(bruno), _ps([bruno, cora]), "quedan Bruno y Cora")
	assert_eq(_party.members_of(ana).size(), 0, "Ana ya no tiene grupo")
	assert_eq(_roster_names(bruno), PackedStringArray(["Bruno", "Cora"]), "lista nueva")
	assert_eq(_last_roster(bruno).leader_index, 0, "el líder es el primero")
	assert_true(_last_roster(ana).is_empty(), "Ana recibe la lista vacía")
	assert_true(_system_texts(bruno).has("Ana ha salido del grupo."), "se cuenta")
	assert_eq(_last_system(bruno), "Bruno es ahora el líder del grupo.", "y quién manda")
	assert_eq(_system_texts(ana)[_system_texts(ana).size() - 1], "Has salido del grupo.", "Ana lo sabe")


func test_a_party_of_one_is_disbanded() -> void:
	var ana: ServerPeer = _add_peer("Ana")
	var bruno: ServerPeer = _add_peer("Bruno")
	_form_party(ana, [bruno])
	_party.leave(bruno, 1000)
	assert_eq(_party.get_party_count(), 0, "se disuelve")
	assert_eq(_party.members_of(ana).size(), 0, "Ana ya no tiene grupo")
	assert_true(_last_roster(ana).is_empty(), "Ana recibe la lista vacía")
	assert_true(_last_roster(bruno).is_empty(), "y Bruno")
	assert_eq(_last_system(ana), "El grupo se ha disuelto.", "aviso")
	assert_true(_system_texts(ana).has("Bruno ha salido del grupo."), "y quién salió")
	# Se puede formar otro.
	_party.invite(ana, "Bruno", 2000)
	_party.respond(bruno, "Ana", true, 2010)
	assert_eq(_party.get_party_count(), 1, "otro grupo")
	_party.leave(ana, 3000)
	_party.leave(ana, 3001)
	assert_eq(_last_system(ana), "No estás en un grupo.", "salir sin grupo")


func test_only_the_leader_can_kick_and_the_kicked_is_told() -> void:
	var ana: ServerPeer = _add_peer("Ana")
	var bruno: ServerPeer = _add_peer("Bruno")
	var cora: ServerPeer = _add_peer("Cora")
	_form_party(ana, [bruno, cora])
	_party.kick(bruno, "Cora", 1000)
	assert_eq(_last_system(bruno), "Solo el líder puede hacer eso.", "un miembro no expulsa")
	assert_eq(_party.members_of(ana).size(), 3, "nadie sale")
	_party.kick(ana, "ana", 1010)
	assert_eq(_last_system(ana), "Para salir del grupo usa /salir.", "no se expulsa a uno mismo")
	_party.kick(ana, "Nadie", 1020)
	assert_eq(_last_system(ana), "«Nadie» no está en tu grupo.", "ni a quien no está")
	_party.kick(ana, "cora", 1030)
	assert_eq(_party.members_of(ana), _ps([ana, bruno]), "el líder expulsa a Cora")
	assert_true(_last_roster(cora).is_empty(), "Cora recibe la lista vacía")
	assert_eq(_system_texts(cora)[_system_texts(cora).size() - 1], "Has sido expulsado del grupo.", "y lo sabe")
	assert_true(_system_texts(ana).has("Cora ha sido expulsado del grupo."), "los demás también")
	assert_eq(_party.get_stats()["kicks"], 1, "se cuenta")
	var dani: ServerPeer = _add_peer("Dani")
	_party.kick(dani, "Ana", 1040)
	assert_eq(_last_system(dani), "No estás en un grupo.", "sin grupo")


func test_the_leader_can_hand_over_the_lead() -> void:
	var ana: ServerPeer = _add_peer("Ana")
	var bruno: ServerPeer = _add_peer("Bruno")
	var cora: ServerPeer = _add_peer("Cora")
	_form_party(ana, [bruno, cora])
	_party.set_leader(bruno, "Cora", 1000)
	assert_eq(_last_system(bruno), "Solo el líder puede hacer eso.", "un miembro no cede el mando")
	_party.set_leader(ana, "ana", 1010)
	assert_eq(_last_system(ana), "Ya eres el líder.", "a sí mismo")
	_party.set_leader(ana, "Nadie", 1020)
	assert_eq(_last_system(ana), "«Nadie» no está en tu grupo.", "a quien no está")
	_party.set_leader(ana, "Cora", 1030)
	assert_eq(_party.leader_of(ana), cora, "Cora manda")
	var roster: NetMessages.PartyRoster = _last_roster(bruno)
	assert_eq(roster.leader_index, 2, "en la lista, el líder es el tercero")
	assert_eq(roster.get_leader_id(), cora.entity.net_id, "con su net_id")
	assert_eq(roster.members[0].display_name, "Ana", "el orden no cambia")
	assert_eq(_last_system(bruno), "Cora es ahora el líder del grupo.", "aviso")
	# El nuevo líder expulsa; el antiguo ya no.
	_party.kick(ana, "Bruno", 1040)
	assert_eq(_last_system(ana), "Solo el líder puede hacer eso.", "Ana ya no puede")
	_party.kick(cora, "Bruno", 1050)
	assert_eq(_party.members_of(cora), _ps([ana, cora]), "Cora sí")


func test_leaving_the_zone_removes_the_player_and_cancels_invitations() -> void:
	var ana: ServerPeer = _add_peer("Ana")
	var bruno: ServerPeer = _add_peer("Bruno")
	var cora: ServerPeer = _add_peer("Cora")
	var dani: ServerPeer = _add_peer("Dani")
	_form_party(ana, [bruno, cora])
	_party.invite(ana, "Dani", 2000)
	# Bruno se desconecta.
	bruno.state = ServerPeer.State.LEAVING
	_party.on_peer_left(bruno, 2100)
	assert_eq(_party.members_of(ana), _ps([ana, cora]), "Bruno sale del grupo")
	assert_true(_system_texts(ana).has("Bruno ha salido del grupo."), "se cuenta")
	# Ana, la líder, se desconecta: las invitaciones que enviaba se cancelan y Cora hereda.
	ana.state = ServerPeer.State.LEAVING
	_party.on_peer_left(ana, 2200)
	assert_eq(_party.get_pending_count(), 0, "sin invitaciones pendientes")
	var offers: Array[NetMessages.PartyInvitation] = _invitations(dani)
	assert_eq(offers[offers.size() - 1].state, NetMessages.PartyInvitation.State.CANCELLED, "Dani no tiene aviso")
	assert_eq(_party.get_party_count(), 0, "Cora se queda sola: el grupo se disuelve")
	assert_true(_last_roster(cora).is_empty(), "lista vacía")
	_party.respond(dani, "Ana", true, 2300)
	assert_eq(_last_system(dani), "No tienes ninguna invitación de «Ana».", "ya no se puede aceptar")


# --- Estado compacto --------------------------------------------------------------------------

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
	assert_eq(_packets(ana, NetProtocol.MSG_PARTY_STATUS).size(), before, "no se manda fuera de su tick")
	_party.step(first)
	assert_eq(_packets(ana, NetProtocol.MSG_PARTY_STATUS).size(), before + 1, "en su tick, uno")
	assert_eq(_packets(bruno, NetProtocol.MSG_PARTY_STATUS).size(), before + 1, "a cada miembro")
	assert_false(_raw_inbox.has(outsider.peer_id), "y a nadie más")
	_party.step(first + 1)
	_party.step(first + PartyRules.STATUS_INTERVAL_TICKS - 1)
	assert_eq(_packets(ana, NetProtocol.MSG_PARTY_STATUS).size(), before + 1, "entre medias, nada")
	_party.step(first + PartyRules.STATUS_INTERVAL_TICKS)
	assert_eq(_packets(ana, NetProtocol.MSG_PARTY_STATUS).size(), before + 2, "a 2 Hz")

	var bytes: PackedByteArray = _packets(ana, NetProtocol.MSG_PARTY_STATUS)[0]
	assert_true(bytes.size() <= NetProtocol.MAX_PACKET_BYTES, "cabe en un paquete")
	var status: NetMessages.PartyStatus = NetMessages.PartyStatus.decode(bytes)
	if not assert_not_null(status, "se decodifica"):
		return
	assert_eq(status.members.size(), 2, "los dos miembros")
	var far: NetMessages.PartyStatus.MemberStatus = status.members[1]
	assert_eq(far.net_id, bruno.entity.net_id, "el segundo es Bruno")
	assert_vec_near(far.position, Vector3(250.0, 3.0, -40.0), 1e-3, "con su posición, a 250 m")
	assert_eq(far.health_q, EntityRecord.quantize_health(500, 1000), "su vida")
	assert_eq(far.stamina_q, PartyRules.STAMINA_Q_MAX, "su resistencia (llena)")
	assert_eq(far.status & NetMessages.STATUS_IN_COMBAT, NetMessages.STATUS_IN_COMBAT, "en combate")
	assert_vec_near(status.members[0].position, Vector3.ZERO, 1e-3, "y la de Ana")
	assert_eq(status.members[0].health_q, 255, "Ana, con la vida llena")


func test_dead_members_are_marked_in_the_status() -> void:
	var ana: ServerPeer = _add_peer("Ana")
	var bruno: ServerPeer = _add_peer("Bruno")
	_form_party(ana, [bruno])
	bruno.entity.set_health_view(0, 1000, NetMessages.STATUS_DEAD, 500)
	_party.step(_status_tick_from(_party.party_id_of(ana), 1000))
	var status: NetMessages.PartyStatus = NetMessages.PartyStatus.decode(
			_packets(ana, NetProtocol.MSG_PARTY_STATUS)[0])
	assert_true(status.members[1].is_dead(), "Bruno está muerto")
	assert_eq(status.members[1].health_q, 0, "sin vida")


func test_status_ticks_are_staggered_between_parties() -> void:
	# Tres grupos de dos: en una ventana de 30 ticks cada miembro recibe un estado, y nunca salen dos grupos
	# en el mismo tick (el coste se reparte, como los snapshots por la paridad del net_id).
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
	assert_eq(start % PartyRules.STATUS_INTERVAL_TICKS, 0, "la ventana empieza en un múltiplo de 30")
	for t: int in range(start, start + PartyRules.STATUS_INTERVAL_TICKS):
		_party.step(t)
		var parties_this_tick: Dictionary = {}
		for peer: ServerPeer in members:
			var count: int = _packets(peer, NetProtocol.MSG_PARTY_STATUS).size()
			if count > received[peer.peer_id]:
				parties_this_tick[_party.party_id_of(peer)] = true
			received[peer.peer_id] = count
		assert_true(parties_this_tick.size() <= 1, "el tick %d manda estado a %d grupos" % [t,
				parties_this_tick.size()])
	for peer: ServerPeer in members:
		assert_eq(received[peer.peer_id] - initial[peer.peer_id], 1,
				"%s recibe un estado en 30 ticks" % peer.display_name)


# --- Canal de grupo ---------------------------------------------------------------------------

func test_party_chat_reaches_the_members_only_and_never_another_realm() -> void:
	var ana: ServerPeer = _add_peer("Ana", VARDHEIM, Vector3.ZERO)
	var bruno: ServerPeer = _add_peer("Bruno", VARDHEIM, Vector3(800.0, 0.0, 0.0))
	var cerca: ServerPeer = _add_peer("Cerca", VARDHEIM, Vector3(1.0, 0.0, 0.0))
	var enemigo: ServerPeer = _add_peer("Enemigo", SOLMARCH, Vector3(1.0, 0.0, 0.0))
	_form_party(ana, [bruno])
	var message := NetMessages.ChatSend.new()
	message.channel = ChatChannel.Id.PARTY
	message.text = "Atacamos por la puerta"
	assert_true(_service.handle_packet(ana, NetProtocol.MSG_CHAT_SEND, message.encode(), 5000), "lo atiende")
	for peer: ServerPeer in [ana, bruno]:
		var lines: Array[NetMessages.ChatMessage] = []
		for bytes: PackedByteArray in _packets(peer, NetProtocol.MSG_CHAT_MESSAGE):
			var line: NetMessages.ChatMessage = NetMessages.ChatMessage.decode(bytes)
			if line.channel == ChatChannel.Id.PARTY:
				lines.append(line)
		assert_eq(lines.size(), 1, "%s lo recibe, esté donde esté" % peer.display_name)
		assert_eq(lines[0].text, "Atacamos por la puerta", "texto")
	for peer: ServerPeer in [cerca, enemigo]:
		for bytes: PackedByteArray in _packets(peer, NetProtocol.MSG_CHAT_MESSAGE):
			var line: NetMessages.ChatMessage = NetMessages.ChatMessage.decode(bytes)
			assert_true(line.channel != ChatChannel.Id.PARTY, "%s no recibe el canal de grupo" % peer.display_name)
	_party.leave(bruno, 6000)
	message.text = "Sigo hablando"
	_service.handle_packet(ana, NetProtocol.MSG_CHAT_SEND, message.encode(), 7000)
	assert_eq(_last_system(ana), "No estás en un grupo.", "sin grupo, el canal contesta")


# --- Mensajes inválidos -----------------------------------------------------------------------

func test_malformed_and_out_of_place_party_messages_add_a_strike() -> void:
	var ana: ServerPeer = _add_peer("Ana")
	# Mal formados.
	assert_true(_service.handle_packet(ana, NetProtocol.MSG_PARTY_INVITE, PackedByteArray([0x48, 0]), 100),
			"un PARTY_INVITE sin nombre se atiende")
	assert_true(_service.handle_packet(ana, NetProtocol.MSG_PARTY_RESPONSE, PackedByteArray([0x49, 2, 1, 65]), 100),
			"un PARTY_RESPONSE con accept 2")
	assert_true(_service.handle_packet(ana, NetProtocol.MSG_PARTY_LEAVE, PackedByteArray([0x4A, 0]), 100),
			"un PARTY_LEAVE de 2 B")
	assert_eq(_strikes.size(), 3, "tres avisos")
	assert_eq(_strikes[0][1], PartyManager.STRIKE_REASON_MALFORMED, "por mal formado")
	# Los tipos que solo manda el servidor no se atienden: quien llama suma el aviso.
	for message_type: int in [NetProtocol.MSG_PARTY_INVITATION, NetProtocol.MSG_PARTY_ROSTER,
			NetProtocol.MSG_PARTY_STATUS]:
		assert_false(_service.handle_packet(ana, message_type, PackedByteArray([message_type, 0]), 100),
				"0x%02X no es de un cliente" % message_type)
	assert_false(_service.handle_packet(ana, 0x40 + 7, PackedByteArray([0x47]), 100), "0x47 no existe")
	# Antes de entrar en el mundo.
	var cargando: ServerPeer = _add_peer("Cargando")
	cargando.state = ServerPeer.State.LOADING
	var request := NetMessages.PartyTargetRequest.make(NetProtocol.MSG_PARTY_INVITE, "Ana")
	assert_true(_service.handle_packet(cargando, NetProtocol.MSG_PARTY_INVITE, request.encode(), 100), "se atiende")
	assert_eq(_strikes[3], [cargando.peer_id, PartyManager.STRIKE_REASON_NOT_IN_WORLD], "con su aviso")
	assert_eq(_party.get_pending_count(), 0, "y no se invita a nadie")


func test_party_messages_from_clients_work_through_the_service() -> void:
	var ana: ServerPeer = _add_peer("Ana")
	var bruno: ServerPeer = _add_peer("Bruno")
	var cora: ServerPeer = _add_peer("Cora")
	var invite := NetMessages.PartyTargetRequest.make(NetProtocol.MSG_PARTY_INVITE, "bruno")
	assert_true(_service.handle_packet(ana, NetProtocol.MSG_PARTY_INVITE, invite.encode(), 100), "invitar")
	var response := NetMessages.PartyResponse.new()
	response.accept = true
	response.inviter = "ANA"
	assert_true(_service.handle_packet(bruno, NetProtocol.MSG_PARTY_RESPONSE, response.encode(), 200), "aceptar")
	assert_eq(_party.members_of(ana).size(), 2, "hay grupo")
	var second := NetMessages.PartyTargetRequest.make(NetProtocol.MSG_PARTY_INVITE, "Cora")
	_service.handle_packet(bruno, NetProtocol.MSG_PARTY_INVITE, second.encode(), 400)
	response.inviter = "Bruno"
	_service.handle_packet(cora, NetProtocol.MSG_PARTY_RESPONSE, response.encode(), 500)
	assert_eq(_party.members_of(ana).size(), 3, "cualquier miembro invita")
	var lead := NetMessages.PartyTargetRequest.make(NetProtocol.MSG_PARTY_LEADER, "Cora")
	_service.handle_packet(ana, NetProtocol.MSG_PARTY_LEADER, lead.encode(), 600)
	assert_eq(_party.leader_of(ana), cora, "ceder el mando")
	var kick := NetMessages.PartyTargetRequest.make(NetProtocol.MSG_PARTY_KICK, "Ana")
	_service.handle_packet(cora, NetProtocol.MSG_PARTY_KICK, kick.encode(), 700)
	assert_eq(_party.members_of(cora), _ps([bruno, cora]), "expulsar")
	_service.handle_packet(bruno, NetProtocol.MSG_PARTY_LEAVE, NetMessages.PartyLeave.new().encode(), 800)
	assert_eq(_party.get_party_count(), 0, "salir")
	assert_true(_strikes.is_empty(), "sin avisos")
