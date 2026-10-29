extends TestCase
## Demo de SOC-08 con ENet de verdad (docs/social.md sección 12.5): un servidor y cinco bots de Vardheim; el
## primero invita a los otros cuatro, que aceptan, y los marcos de grupo ([PartyFrames]) del primero, enlazados al
## [PartyState] de su [NetClient], enseñan lo que dice el servidor: los cinco miembros por orden de llegada, la
## corona del líder, la vida y la resistencia, la distancia, y atenuado al que se aleja, además de seguir la lista
## cuando alguien sale. La parte con estados sintéticos (muertos, sin datos, comandos del chat y el aviso de
## invitación) está en test_party_hud.gd.

const VARDHEIM: int = NetProtocol.Realm.VARDHEIM
const ZONE_ID: String = "test_world"
const WAIT_FRAMES: int = 900

var _root: Node
var _server_viewport: SubViewport
var _server: ZoneServer
var _port: int = 0
var _clients: Array[NetClient] = []
var _client_viewports: Array[SubViewport] = []


func before_each() -> void:
	_root = Node.new()
	_root.name = "PartyDemo"
	tree.root.add_child(_root)


func after_each() -> void:
	for viewport: SubViewport in _client_viewports:
		if is_instance_valid(viewport):
			viewport.free()
	_client_viewports.clear()
	_clients.clear()
	if is_instance_valid(_server_viewport):
		_server_viewport.free()
	_server_viewport = null
	_server = null
	if is_instance_valid(_root):
		tree.root.remove_child(_root)
		_root.free()
	_root = null
	await wait_process_frames()


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


func test_four_bots_in_a_party_show_the_right_frames() -> void:
	_port = NetHarness.free_udp_port()
	_server_viewport = NetHarness.make_world_viewport(_root, "")
	var config := ServerConfig.new()
	config.port = _port
	config.zone_id = ZONE_ID
	config.max_players = 8
	_server = NetHarness.start_server(_server_viewport, config)
	await wait_physics_frames(3)
	for bot_seed: int in range(1, 6):
		var viewport: SubViewport = NetHarness.make_world_viewport(_root, "")
		_client_viewports.append(viewport)
		_clients.append(NetHarness.start_bot(viewport, _port, VARDHEIM, bot_seed))
	if not assert_true(await _wait_until(_all_in_world), "entran los cinco"):
		return
	for client: NetClient in _clients:
		var brain: BotBrain = client.get_meta(&"bot_brain") as BotBrain
		brain.set_idle_from(client.get_prediction().get_predicted_tick() + 1)
	var leader: NetClient = _clients[0]
	var frames: PartyFrames = PartyFrames.new()
	_root.add_child(frames)
	frames.bind(leader.get_party(), leader)

	# El líder invita a los otros cuatro, de uno en uno (invitar tiene su ritmo), y cada uno acepta.
	for index: int in range(1, 5):
		var member: NetClient = _clients[index]
		assert_true(leader.send_party_invite(member.get_config().display_name), "invita al bot %d" % index)
		var invited: bool = await _wait_until(func() -> bool:
			return member.get_party().get_current_invitation() != null)
		if not assert_true(invited, "el bot %d recibe la invitación" % index):
			return
		assert_true(member.send_party_response(leader.get_config().display_name, true), "acepta")
		var joined: bool = await _wait_until(func() -> bool:
			return leader.get_party().get_member_count() == index + 1)
		if not assert_true(joined, "el grupo llega a %d miembros" % (index + 1)):
			return
		await wait_physics_frames(60)

	# Los marcos del líder, con el estado a 2 Hz que manda el servidor.
	var all_with_data: Callable = func() -> bool:
		if frames.get_frame_count() != 5:
			return false
		for frame: PartyFrame in frames.get_frames():
			if not frame.has_data():
				return false
		return true
	if not assert_true(await _wait_until(all_with_data), "los cinco marcos tienen datos"):
		return
	var names: PackedStringArray = PackedStringArray()
	for frame: PartyFrame in frames.get_frames():
		names.append(frame.get_name_text())
	var expected: PackedStringArray = PackedStringArray()
	for client: NetClient in _clients:
		expected.append(client.get_config().display_name)
	assert_eq(names, expected, "los cinco, por orden de llegada")
	for client: NetClient in _clients:
		var frame: PartyFrame = frames.get_frame(client.get_net_id())
		if not assert_not_null(frame, "hay marco de %s" % client.get_config().display_name):
			continue
		assert_eq(frame.is_own(), client == leader, "solo el primero es el propio jugador")
		assert_eq(frame.is_leader_shown(), client == leader, "y solo él lleva la corona")
		assert_eq(frame.get_health_fraction(), 1.0, "vida llena")
		assert_eq(frame.get_stamina_fraction(), 1.0, "resistencia llena")
		assert_false(frame.is_dead(), "vivo")
		assert_false(frame.is_dimmed(), "cerca y con datos: sin atenuar")
	assert_eq(frames.get_frames().filter(func(frame: PartyFrame) -> bool: return frame.is_leader_shown()).size(), 1,
			"una sola corona")

	# Un miembro se aleja 200 m: su marco se atenúa; el estado le sigue llegando aunque no se le vea.
	var far_client: NetClient = _clients[3]
	_server.teleport(far_client.get_net_id(), Vector3(190.0, 0.0, 0.0))
	var far_frame_dimmed: Callable = func() -> bool:
		var frame: PartyFrame = frames.get_frame(far_client.get_net_id())
		return frame != null and frame.is_far() and frame.is_dimmed()
	assert_true(await _wait_until(far_frame_dimmed), "el marco del que se aleja se atenúa")
	assert_true(frames.get_frame(far_client.get_net_id()).get_distance() > PartyRules.FAR_DISTANCE,
			"a más de 100 m")
	assert_false(frames.get_frame(_clients[1].get_net_id()).is_dimmed(), "y los demás, no")

	# Un miembro sale: el marco desaparece y la corona sigue donde estaba.
	var leaving: NetClient = _clients[4]
	leaving.send_party_leave()
	assert_true(await _wait_until(func() -> bool: return frames.get_frame_count() == 4), "sale un marco")
	assert_null(frames.get_frame(leaving.get_net_id()), "el de quien salió")
	assert_true(frames.get_frame(leader.get_net_id()).is_leader_shown(), "Ana sigue mandando")
