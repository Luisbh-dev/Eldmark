extends TestCase
## SOC-08 demo with real ENet (docs/social.md section 12.5): a server and five Vardheim bots; the
## first invites the other four, who accept, and the first one's party frames ([PartyFrames]), linked to
## the [PartyState] of its [NetClient], show what the server says: the five members in order of
## arrival, the leader's crown, health and stamina, the distance, and dimmed the one who moves away,
## as well as following the list when someone leaves. The part with synthetic states (dead, no data,
## chat commands and the invitation prompt) is in test_party_hud.gd.

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
	if not assert_true(await _wait_until(_all_in_world), "all five get in"):
		return
	for client: NetClient in _clients:
		var brain: BotBrain = client.get_meta(&"bot_brain") as BotBrain
		brain.set_idle_from(client.get_prediction().get_predicted_tick() + 1)
	var leader: NetClient = _clients[0]
	var frames: PartyFrames = PartyFrames.new()
	_root.add_child(frames)
	frames.bind(leader.get_party(), leader)

	# The leader invites the other four, one at a time (inviting has its own pace), and each accepts.
	for index: int in range(1, 5):
		var member: NetClient = _clients[index]
		assert_true(leader.send_party_invite(member.get_config().display_name), "invites bot %d" % index)
		var invited: bool = await _wait_until(func() -> bool:
			return member.get_party().get_current_invitation() != null)
		if not assert_true(invited, "bot %d receives the invitation" % index):
			return
		assert_true(member.send_party_response(leader.get_config().display_name, true), "accepts")
		var joined: bool = await _wait_until(func() -> bool:
			return leader.get_party().get_member_count() == index + 1)
		if not assert_true(joined, "the party reaches %d members" % (index + 1)):
			return
		await wait_physics_frames(60)

	# The leader's frames, with the 2 Hz state the server sends.
	var all_with_data: Callable = func() -> bool:
		if frames.get_frame_count() != 5:
			return false
		for frame: PartyFrame in frames.get_frames():
			if not frame.has_data():
				return false
		return true
	if not assert_true(await _wait_until(all_with_data), "all five frames have data"):
		return
	var names: PackedStringArray = PackedStringArray()
	for frame: PartyFrame in frames.get_frames():
		names.append(frame.get_name_text())
	var expected: PackedStringArray = PackedStringArray()
	for client: NetClient in _clients:
		expected.append(client.get_config().display_name)
	assert_eq(names, expected, "all five, in order of arrival")
	for client: NetClient in _clients:
		var frame: PartyFrame = frames.get_frame(client.get_net_id())
		if not assert_not_null(frame, "there is a frame for %s" % client.get_config().display_name):
			continue
		assert_eq(frame.is_own(), client == leader, "only the first is the player itself")
		assert_eq(frame.is_leader_shown(), client == leader, "and only it carries the crown")
		assert_eq(frame.get_health_fraction(), 1.0, "full health")
		assert_eq(frame.get_stamina_fraction(), 1.0, "full stamina")
		assert_false(frame.is_dead(), "alive")
		assert_false(frame.is_dimmed(), "near and with data: not dimmed")
	assert_eq(frames.get_frames().filter(func(frame: PartyFrame) -> bool: return frame.is_leader_shown()).size(), 1,
			"a single crown")

	# A member moves away 200 m: its frame dims; the state keeps arriving even though it is not seen.
	var far_client: NetClient = _clients[3]
	_server.teleport(far_client.get_net_id(), Vector3(190.0, 0.0, 0.0))
	var far_frame_dimmed: Callable = func() -> bool:
		var frame: PartyFrame = frames.get_frame(far_client.get_net_id())
		return frame != null and frame.is_far() and frame.is_dimmed()
	assert_true(await _wait_until(far_frame_dimmed), "the frame of the one moving away dims")
	assert_true(frames.get_frame(far_client.get_net_id()).get_distance() > PartyRules.FAR_DISTANCE,
			"at more than 100 m")
	assert_false(frames.get_frame(_clients[1].get_net_id()).is_dimmed(), "and the others do not")

	# A member leaves: the frame disappears and the crown stays where it was.
	var leaving: NetClient = _clients[4]
	leaving.send_party_leave()
	assert_true(await _wait_until(func() -> bool: return frames.get_frame_count() == 4), "one frame leaves")
	assert_null(frames.get_frame(leaving.get_net_id()), "that of whoever left")
	assert_true(frames.get_frame(leader.get_net_id()).is_leader_shown(), "Ana is still in charge")
