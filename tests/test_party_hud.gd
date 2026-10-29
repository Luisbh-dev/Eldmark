extends TestCase
## Pruebas de la interfaz de grupo del cliente (SOC-08, docs/social.md sección 12.5) con mensajes sintéticos y un
## cliente falso: el estado de grupo ([PartyState]: lista, líder, estado a 2 Hz, invitaciones y su caducidad),
## los marcos ([PartyFrames], [PartyFrame]: una demo con cuatro bots agrupados), el aviso de invitación con
## aceptar y rechazar por teclado ([PartyInvitePrompt]) y el montaje en el [HUD] con los comandos del chat.

const VARDHEIM: int = NetProtocol.Realm.VARDHEIM
const OWN_ID: int = 101
const HUD_SCENE_PATH: String = "res://scenes/ui/hud.tscn"
const CAMERA_RIG_SCENE_PATH: String = "res://scenes/client/camera_rig.tscn"
const CHARACTER_SCENE_PATH: String = "res://scenes/characters/player_character.tscn"


## Cliente de red que no conecta con nada: da el jugador local, el tick del servidor y apunta lo que se le
## pide enviar.
class FakeClient extends NetClient:
	var fake_config: ClientConfig = ClientConfig.new()
	var fake_character: PlayerCharacter = null
	var fake_tick: int = 1000
	var fake_net_id: int = 0
	var sent: Array[Array] = []

	func get_config() -> ClientConfig:
		return fake_config

	func get_character() -> PlayerCharacter:
		return fake_character

	func get_estimated_server_tick() -> int:
		return fake_tick

	func get_net_id() -> int:
		return fake_net_id

	func send_party_invite(target_name: String) -> bool:
		sent.append(["invite", target_name])
		return true

	func send_party_kick(target_name: String) -> bool:
		sent.append(["kick", target_name])
		return true

	func send_party_leader(target_name: String) -> bool:
		sent.append(["leader", target_name])
		return true

	func send_party_leave() -> bool:
		sent.append(["leave"])
		return true

	func send_party_response(inviter: String, accept: bool) -> bool:
		sent.append(["response", inviter, accept])
		get_party().remove_invitation(inviter)
		return true


var _nodes: Array[Node] = []
var _client: FakeClient = null
var _party: PartyState = null


func before_each() -> void:
	_nodes.clear()
	_client = _track(FakeClient.new()) as FakeClient
	_client.fake_config.display_name = "Ana"
	_client.fake_config.realm = VARDHEIM
	_client.fake_net_id = OWN_ID
	_party = _client.get_party()
	InputBindings.ensure_defaults()


func after_each() -> void:
	for node: Node in _nodes:
		if is_instance_valid(node):
			if node.get_parent() != null:
				node.get_parent().remove_child(node)
			node.free()
	_nodes.clear()
	await wait_process_frames()


# --- Ayudantes --------------------------------------------------------------------------------

func _track(node: Node) -> Node:
	tree.root.add_child(node)
	_nodes.append(node)
	return node


func _roster(names: Array[String], leader_index: int = 0, first_id: int = OWN_ID) -> NetMessages.PartyRoster:
	var roster := NetMessages.PartyRoster.new()
	roster.leader_index = leader_index
	for i: int in names.size():
		roster.members.append(NetMessages.PartyRoster.Member.make(first_id + i, names[i]))
	return roster


# Una lista con ids explícitos: [[id, nombre], ...].
func _roster_of(entries: Array[Array], leader_index: int = 0) -> NetMessages.PartyRoster:
	var roster := NetMessages.PartyRoster.new()
	roster.leader_index = leader_index
	for entry: Array in entries:
		roster.members.append(NetMessages.PartyRoster.Member.make(entry[0], entry[1]))
	return roster


func _status(entries: Array[Dictionary]) -> NetMessages.PartyStatus:
	var status := NetMessages.PartyStatus.new()
	for entry: Dictionary in entries:
		status.members.append(NetMessages.PartyStatus.MemberStatus.make(entry["id"], entry.get("health", 255),
				entry.get("stamina", 255), entry.get("status", 0), entry.get("position", Vector3.ZERO)))
	return status


func _offer(inviter: String, expire_tick: int) -> NetMessages.PartyInvitation:
	var invitation := NetMessages.PartyInvitation.new()
	invitation.inviter = inviter
	invitation.tick = expire_tick
	return invitation


func _key(keycode: Key) -> InputEventKey:
	var event := InputEventKey.new()
	event.physical_keycode = keycode
	event.keycode = keycode
	event.pressed = true
	return event


# --- PartyState -------------------------------------------------------------------------------

func test_state_follows_the_roster_and_keeps_the_status_of_who_stays() -> void:
	var changes: Array[int] = [0]
	_party.roster_changed.connect(func() -> void: changes[0] += 1)
	assert_false(_party.is_in_party(), "empieza sin grupo")
	_party.apply_roster(_roster(["Ana", "Bruno", "Cora"], 1))
	assert_true(_party.is_in_party(), "con grupo")
	assert_eq(_party.get_member_count(), 3, "tres miembros")
	assert_eq(_party.get_leader_id(), OWN_ID + 1, "manda Bruno")
	assert_true(_party.is_leader(OWN_ID + 1), "is_leader")
	assert_false(_party.is_leader(OWN_ID), "Ana no")
	assert_false(_party.is_leader(0), "ni el id 0")
	assert_eq(_party.get_member(OWN_ID + 2).display_name, "Cora", "por id")
	assert_null(_party.get_member(999), "uno que no está")
	assert_false(_party.get_member(OWN_ID).has_status, "sin estado hasta el primer PARTY_STATUS")
	assert_eq(changes[0], 1, "roster_changed")

	_party.apply_status(_status([{"id": OWN_ID + 2, "health": 100, "stamina": 50, "position": Vector3(1, 2, 3),
			"status": NetMessages.STATUS_IN_COMBAT}]))
	var cora: PartyState.Member = _party.get_member(OWN_ID + 2)
	assert_true(cora.has_status, "ya tiene estado")
	assert_near(cora.get_health_fraction(), 100.0 / 255.0, 1e-6, "vida")
	assert_near(cora.get_stamina_fraction(), 50.0 / 255.0, 1e-6, "resistencia")
	assert_vec_near(cora.position, Vector3(1.0, 2.0, 3.0), 1e-6, "posición")
	assert_true(cora.is_in_combat(), "en combate")
	assert_false(cora.is_dead(), "vivo")
	# Una lista nueva (sale Bruno) conserva el estado de Cora y se queda con el orden nuevo.
	_party.apply_roster(_roster_of([[OWN_ID, "Ana"], [OWN_ID + 2, "Cora"]], 1))
	assert_eq(_party.get_member_count(), 2, "dos")
	assert_eq(_party.get_leader_id(), OWN_ID + 2, "manda Cora")
	var kept: PartyState.Member = _party.get_member(OWN_ID + 2)
	assert_true(kept.has_status, "Cora conserva su estado")
	assert_near(kept.get_health_fraction(), 100.0 / 255.0, 1e-6, "y su vida")
	assert_null(_party.get_member(OWN_ID + 1), "Bruno ya no está")
	# Un estado de alguien que no está se ignora.
	var status_changes: Array[int] = [0]
	_party.status_changed.connect(func() -> void: status_changes[0] += 1)
	_party.apply_status(_status([{"id": 777, "health": 10}]))
	assert_eq(status_changes[0], 0, "un miembro desconocido no cambia nada")
	# La lista vacía es salir del grupo.
	_party.apply_roster(NetMessages.PartyRoster.new())
	assert_false(_party.is_in_party(), "sin grupo")
	assert_eq(_party.get_leader_id(), 0, "sin líder")


func test_dead_members_and_status_bits() -> void:
	_party.apply_roster(_roster(["Ana", "Bruno"]))
	_party.apply_status(_status([{"id": OWN_ID + 1, "health": 0, "status": NetMessages.STATUS_DEAD}]))
	assert_true(_party.get_member(OWN_ID + 1).is_dead(), "muerto")
	assert_eq(_party.get_member(OWN_ID + 1).get_health_fraction(), 0.0, "sin vida")
	assert_false(_party.get_member(OWN_ID).is_dead(), "Ana, sin datos, no consta como muerta")


func test_invitations_are_replaced_removed_and_expire() -> void:
	var changes: Array[int] = [0]
	_party.invitation_changed.connect(func() -> void: changes[0] += 1)
	_party.apply_invitation(_offer("Bruno", 2000))
	_party.apply_invitation(_offer("Cora", 3000))
	assert_eq(_party.get_invitations().size(), 2, "dos pendientes")
	assert_eq(_party.get_current_invitation().inviter, "Bruno", "se enseña la más antigua")
	_party.apply_invitation(_offer("BRUNO", 2500))
	assert_eq(_party.get_invitations().size(), 2, "una nueva del mismo jugador sustituye a la anterior")
	assert_eq(_party.get_current_invitation().inviter, "Cora", "y pasa al final")
	var cancelled := NetMessages.PartyInvitation.new()
	cancelled.state = NetMessages.PartyInvitation.State.CANCELLED
	cancelled.inviter = "cora"
	_party.apply_invitation(cancelled)
	assert_eq(_party.get_invitations().size(), 1, "una cancelada se quita")
	var expired := NetMessages.PartyInvitation.new()
	expired.state = NetMessages.PartyInvitation.State.EXPIRED
	expired.inviter = "Bruno"
	_party.apply_invitation(expired)
	assert_null(_party.get_current_invitation(), "una caducada también")
	# Caducidad por tick, por si se pierde el aviso.
	_party.apply_invitation(_offer("Dani", 1500))
	assert_eq(_party.prune_expired(1499), 0, "un tick antes sigue")
	assert_eq(_party.prune_expired(1500), 1, "al llegar el tick, se quita")
	assert_false(_party.remove_invitation("Dani"), "ya no está")
	_party.apply_invitation(_offer("Eva", 9000))
	assert_true(_party.remove_invitation("eva"), "se quita al responder")
	_party.apply_invitation(_offer("Eva", 9000))
	_party.clear()
	assert_null(_party.get_current_invitation(), "clear vacía todo")
	assert_true(changes[0] >= 6, "invitation_changed avisa de cada cambio (%d)" % changes[0])


# --- Marcos -----------------------------------------------------------------------------------

func _frames() -> PartyFrames:
	var frames: PartyFrames = _track(PartyFrames.new()) as PartyFrames
	frames.bind(_party, _client)
	return frames


## La demo del backlog: cuatro bots agrupados con el jugador local (cinco marcos, el máximo). Lleva a cada uno a un sitio:
## Bruno cerca y a media vida, Cora lejos, Dani muerto y Eva sin datos todavía.
func test_a_party_of_five_shows_the_right_frames() -> void:
	var character: PlayerCharacter = (load(CHARACTER_SCENE_PATH) as PackedScene).instantiate() as PlayerCharacter
	_track(character)
	character.global_position = Vector3.ZERO
	_client.fake_character = character
	var frames: PartyFrames = _frames()
	assert_false(frames.visible, "sin grupo no hay marcos")
	assert_eq(frames.get_frame_count(), 0, "ninguno")

	_party.apply_roster(_roster(["Ana", "Bruno", "Cora", "Dani", "Eva"], 1))
	_party.apply_status(_status([
		{"id": OWN_ID, "health": 255, "stamina": 255, "position": Vector3.ZERO},
		{"id": OWN_ID + 1, "health": 128, "stamina": 200, "position": Vector3(10.0, 0.0, 0.0)},
		{"id": OWN_ID + 2, "health": 255, "stamina": 100, "position": Vector3(250.0, 0.0, 0.0)},
		{"id": OWN_ID + 3, "health": 0, "stamina": 0, "status": NetMessages.STATUS_DEAD,
				"position": Vector3(20.0, 0.0, 0.0)},
	]))
	assert_true(frames.visible, "con grupo, sí")
	assert_eq(frames.get_frame_count(), 5, "un marco por miembro")
	var names: PackedStringArray = PackedStringArray()
	for frame: PartyFrame in frames.get_frames():
		names.append(frame.get_name_text())
	assert_eq(names, PackedStringArray(["Ana", "Bruno", "Cora", "Dani", "Eva"]), "en el orden del servidor")

	var own: PartyFrame = frames.get_frame(OWN_ID)
	assert_true(own.is_own(), "el primero es el propio jugador")
	assert_false(own.is_leader_shown(), "sin corona")
	assert_false(own.is_dimmed(), "ni atenuado")
	var bruno: PartyFrame = frames.get_frame(OWN_ID + 1)
	assert_true(bruno.is_leader_shown(), "la corona es del líder, Bruno")
	assert_eq(frames.get_frames().filter(func(frame: PartyFrame) -> bool: return frame.is_leader_shown()).size(), 1,
			"y solo de uno")
	assert_near(bruno.get_health_fraction(), 128.0 / 255.0, 1e-6, "su vida")
	assert_near(bruno.get_stamina_fraction(), 200.0 / 255.0, 1e-6, "su resistencia")
	assert_near(bruno.get_distance(), 10.0, 1e-3, "a 10 m")
	assert_false(bruno.is_far(), "cerca")
	assert_near(bruno.modulate.a, 1.0, 1e-6, "opaco")
	var cora: PartyFrame = frames.get_frame(OWN_ID + 2)
	assert_true(cora.is_far(), "Cora está a 250 m")
	assert_true(cora.is_dimmed(), "atenuada")
	assert_near(cora.modulate.a, PartyFrame.DIM_ALPHA, 1e-6, "con la opacidad de los atenuados")
	var dani: PartyFrame = frames.get_frame(OWN_ID + 3)
	assert_true(dani.is_dead(), "Dani está muerto")
	assert_true(dani.is_dimmed(), "atenuado")
	assert_eq(dani.get_health_fraction(), 0.0, "sin vida")
	var eva: PartyFrame = frames.get_frame(OWN_ID + 4)
	assert_false(eva.has_data(), "Eva aún no tiene datos")
	assert_true(eva.is_dimmed(), "atenuada y sin datos")
	var colors: Dictionary = {}
	for frame: PartyFrame in frames.get_frames():
		colors[frame.get_name_color()] = true
	assert_eq(colors.size(), 1, "todos con el color del reino")
	assert_eq(bruno.get_name_color(), UIPalette.faction_color_of_code(VARDHEIM).lightened(0.25), "el de Vardheim")

	# Cora se acerca: deja de estar atenuada al repintar.
	_party.apply_status(_status([{"id": OWN_ID + 2, "health": 255, "position": Vector3(40.0, 0.0, 0.0)}]))
	assert_false(frames.get_frame(OWN_ID + 2).is_far(), "a 40 m ya no está lejos")
	assert_false(frames.get_frame(OWN_ID + 2).is_dimmed(), "ni atenuada")
	# Y el jugador local se aleja: el reloj de distancia repinta los marcos.
	character.global_position = Vector3(-200.0, 0.0, 0.0)
	frames.advance(PartyFrames.REFRESH_SECONDS + 0.01)
	assert_true(frames.get_frame(OWN_ID + 1).is_far(), "al alejarse el jugador, Bruno queda lejos (210 m)")


func test_frames_follow_the_roster() -> void:
	var frames: PartyFrames = _frames()
	_party.apply_roster(_roster(["Ana", "Bruno", "Cora"], 0))
	assert_eq(frames.get_frame_count(), 3, "tres marcos")
	_party.apply_roster(_roster(["Ana", "Cora"], 1))
	assert_eq(frames.get_frame_count(), 2, "sale uno")
	assert_true(frames.get_frame(OWN_ID + 1).is_leader_shown(), "la corona cambia con el líder")
	assert_false(frames.get_frame(OWN_ID).is_leader_shown(), "y se quita del anterior")
	_party.apply_roster(NetMessages.PartyRoster.new())
	assert_eq(frames.get_frame_count(), 0, "sin grupo, sin marcos")
	assert_false(frames.visible, "y la columna se oculta")


# --- Invitación -------------------------------------------------------------------------------

func _prompt() -> PartyInvitePrompt:
	var prompt: PartyInvitePrompt = _track(PartyInvitePrompt.new()) as PartyInvitePrompt
	prompt.bind(_party, _client)
	return prompt


func test_the_invitation_prompt_shows_who_and_how_long() -> void:
	var prompt: PartyInvitePrompt = _prompt()
	assert_false(prompt.visible, "sin invitación no se ve")
	_party.apply_invitation(_offer("Bruno", _client.fake_tick + 3600))
	assert_true(prompt.visible, "con invitación, sí")
	assert_eq(prompt.get_title_text(), "Bruno te invita a su grupo", "quién")
	assert_eq(prompt.get_seconds_left(), 60, "60 s")
	assert_eq(prompt.get_timer_text(), "60 s", "se ven")
	_client.fake_tick += 1830
	prompt.refresh()
	assert_eq(prompt.get_seconds_left(), 30, "pasados 30,5 s quedan 30")
	_party.apply_invitation(_offer("Cora", _client.fake_tick + 3000))
	assert_eq(prompt.get_title_text(), "Bruno te invita a su grupo (+1 más)", "con otra más, lo dice")
	# La caducidad por tick quita el aviso aunque no llegue el mensaje del servidor.
	_client.fake_tick += 1800
	prompt.refresh()
	assert_eq(prompt.get_title_text(), "Cora te invita a su grupo", "caducó la de Bruno: sigue la de Cora")
	_client.fake_tick += 5000
	prompt.refresh()
	assert_false(prompt.visible, "caducadas todas, se oculta")
	assert_eq(prompt.get_seconds_left(), 0, "0 s")


func test_the_prompt_shows_the_real_keys_and_responds_from_the_keyboard() -> void:
	var prompt: PartyInvitePrompt = _prompt()
	_party.apply_invitation(_offer("Bruno", _client.fake_tick + 3600))
	assert_eq(prompt.get_accept_glyph().action, &"party_accept", "el glifo de aceptar")
	assert_eq(prompt.get_decline_glyph().action, &"party_decline", "y el de rechazar")
	assert_true(InputMap.has_action(&"party_accept") and InputMap.has_action(&"party_decline"),
			"las acciones existen")
	# Aceptar con la tecla.
	prompt._unhandled_input(_key(KEY_Y))
	assert_eq(_client.sent.size(), 1, "una respuesta enviada")
	assert_eq(_client.sent[0], ["response", "Bruno", true], "se acepta a Bruno")
	assert_false(prompt.visible, "y el aviso se quita al momento")
	assert_null(_party.get_current_invitation(), "sin invitaciones")
	# Rechazar con la otra.
	_party.apply_invitation(_offer("Cora", _client.fake_tick + 3600))
	prompt._unhandled_input(_key(KEY_N))
	assert_eq(_client.sent[1], ["response", "Cora", false], "se rechaza a Cora")
	# Sin aviso a la vista, las teclas no hacen nada.
	prompt._unhandled_input(_key(KEY_Y))
	prompt._unhandled_input(_key(KEY_N))
	assert_eq(_client.sent.size(), 2, "sin invitación no se envía nada")
	assert_false(prompt.respond(true), "respond sin invitación devuelve false")


# --- Montaje en el HUD ------------------------------------------------------------------------

func test_the_hud_mounts_the_party_interface_and_the_chat_commands_reach_the_server() -> void:
	var rig: CameraRig = _track((load(CAMERA_RIG_SCENE_PATH) as PackedScene).instantiate()) as CameraRig
	var hud: HUD = _track((load(HUD_SCENE_PATH) as PackedScene).instantiate()) as HUD
	var character: PlayerCharacter = (load(CHARACTER_SCENE_PATH) as PackedScene).instantiate() as PlayerCharacter
	_track(character)
	_client.fake_character = character
	hud.bind(character, rig)
	assert_null(hud.get_party_hud(), "el sandbox no tiene grupo")
	hud.bind_net(_client, null)
	var party_hud: PartyHud = hud.get_party_hud()
	if not assert_not_null(party_hud, "en red, sí"):
		return
	assert_true(party_hud.get_index() < hud.get_death_screen().get_index(), "por debajo de la pantalla de muerte")
	assert_not_null(party_hud.get_frames(), "con marcos")
	assert_not_null(party_hud.get_prompt(), "y aviso")
	# Una invitación y una lista llegan a los marcos y al aviso.
	_party.apply_invitation(_offer("Bruno", _client.fake_tick + 3600))
	assert_true(party_hud.get_prompt().visible, "el aviso se ve")
	_party.apply_roster(_roster(["Ana", "Bruno"], 0))
	assert_eq(party_hud.get_frames().get_frame_count(), 2, "y los dos marcos")
	# Los comandos del chat van al cliente.
	var chat: ChatBox = hud.get_chat()
	chat.submit("/invitar Cora")
	chat.submit("/expulsar Bruno")
	chat.submit("/lider bruno")
	chat.submit("/salir")
	assert_eq(_client.sent.size(), 4, "cuatro peticiones")
	assert_eq(_client.sent[0], ["invite", "Cora"], "/invitar")
	assert_eq(_client.sent[1], ["kick", "Bruno"], "/expulsar")
	assert_eq(_client.sent[2], ["leader", "bruno"], "/lider")
	assert_eq(_client.sent[3], ["leave"], "/salir")
	assert_true(chat.get_log().get_count() == 0, "y el chat no se queja de comandos desconocidos")
	# Una segunda llamada rehace la interfaz sin duplicarla.
	hud.bind_net(_client, null)
	assert_eq(hud.get_children().filter(func(child: Node) -> bool: return child is PartyHud).size(), 1, "una sola")
	# Las placas de nombre conocen el grupo.
	assert_true(hud.get_nameplates().get_party() == _party, "las placas reciben el estado de grupo")
