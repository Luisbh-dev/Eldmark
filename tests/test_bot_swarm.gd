extends TestCase
## [BotSwarm] and [SwarmBot] (docs/networking.md, sections 15 and 17.5; TEC-11) against a real [ZoneServer] in the
## same process, with ENet over 127.0.0.1: the real scene ([code]scenes/client/bot_swarm.tscn[/code])
## with [code]--bots=8[/code]. It checks that all of them get in (one every 5 ticks), that they receive snapshots,
## that their inputs arrive on time, that the report carries the bytes per client and that closing via
## [code]--quit-after-ticks[/code] (or [code]--quit-at-server-tick[/code]) and rejection because the server is full give the
## expected exit code. Also, that the chat and the protocol 5 parties that reach a bot (docs/social.md,
## 12.7) are decoded and dropped without being counted as malformed packets.
## The swarm in a separate process is tested by [code]test_net_processes[/code].

const SWARM_SCENE: String = "res://scenes/client/bot_swarm.tscn"
const REPORT_FILE: String = "test_bot_swarm_report.json"
const ZONE_ID: String = "test_world"
const WAIT_FRAMES: int = 900

var _root: Node
var _server_viewport: SubViewport
var _server: ZoneServer
var _swarm: BotSwarm
# Viewport of the [NetClient] client that talks to the bots (only in the chat test).
var _client_viewport: SubViewport
var _port: int = 0
var _exit_codes: Array[int] = []
var _saved_config: ClientConfig
var _saved_hook: Callable
var _saved_max_fps: int = 0


func before_each() -> void:
	_saved_config = BotSwarm.config
	_saved_hook = BotSwarm.quit_hook
	_saved_max_fps = Engine.max_fps
	_exit_codes.clear()
	BotSwarm.quit_hook = func(code: int) -> void: _exit_codes.append(code)
	DirAccess.remove_absolute(NetHarness.build_path(REPORT_FILE))
	_root = Node.new()
	_root.name = "BotSwarmTest"
	tree.root.add_child(_root)


func after_each() -> void:
	if is_instance_valid(_client_viewport):
		_client_viewport.free()
	_client_viewport = null
	if is_instance_valid(_swarm):
		_swarm.get_parent().remove_child(_swarm)
		_swarm.free()
	_swarm = null
	if is_instance_valid(_server_viewport):
		_server_viewport.free()
	_server_viewport = null
	_server = null
	if is_instance_valid(_root):
		tree.root.remove_child(_root)
		_root.free()
	_root = null
	BotSwarm.config = _saved_config
	BotSwarm.quit_hook = _saved_hook
	Engine.max_fps = _saved_max_fps
	await wait_process_frames(2)


# --- Helpers --------------------------------------------------------------------------------

func _start_server(max_players: int = 16) -> void:
	_port = NetHarness.free_udp_port()
	_server_viewport = NetHarness.make_world_viewport(_root, "")
	var config := ServerConfig.new()
	config.port = _port
	config.zone_id = ZONE_ID
	config.max_players = max_players
	_server = NetHarness.start_server(_server_viewport, config)
	await wait_physics_frames(3)


## The real scene's swarm, with [param count] bots toward the test server.
func _start_swarm(count: int, configure: Callable = Callable()) -> void:
	var config := ClientConfig.new()
	config.mode = ClientConfig.Mode.SWARM
	config.port = _port
	config.bot_count = count
	config.bot_seed = 40
	config.report_path = NetHarness.build_path(REPORT_FILE)
	if configure.is_valid():
		configure.call(config)
	BotSwarm.config = config
	var packed: PackedScene = load(SWARM_SCENE) as PackedScene
	_swarm = packed.instantiate() as BotSwarm
	_root.add_child(_swarm)


func _wait_until(condition: Callable, max_frames: int = WAIT_FRAMES) -> bool:
	for _i: int in max_frames:
		if condition.call():
			return true
		await tree.physics_frame
	return condition.call()


func _exited() -> bool:
	return not _exit_codes.is_empty()


# --- Tests ----------------------------------------------------------------------------------

func test_eight_bots_join_one_every_five_ticks_and_receive_snapshots() -> void:
	await _start_server()
	_start_swarm(8)
	assert_eq(_swarm.get_bots().size(), 1, "the first bot is created at the start")
	var all_in: bool = await _wait_until(func() -> bool: return _swarm.count_in_world() == 8)
	if not assert_true(all_in, "all 8 enter the world (%d)" % _swarm.count_in_world()):
		return
	assert_eq(_server.get_player_count(), 8, "the server has all 8")
	for i: int in 8:
		assert_eq(_swarm.get_created_tick(i), i * BotSwarm.SPAWN_INTERVAL_TICKS,
				"bot %d is created on tick %d" % [i, i * BotSwarm.SPAWN_INTERVAL_TICKS])
	await wait_physics_frames(240)

	var names: Dictionary = {}
	var in_sync: int = 0
	for bot: SwarmBot in _swarm.get_bots():
		var stats: Dictionary = bot.get_stats()
		var label: String = "bot %d" % bot.get_bot_index()
		assert_eq(bot.get_state(), SwarmBot.State.IN_WORLD, "%s keeps playing" % label)
		assert_eq(bot.get_display_name(), NameRules.bot_name(40 + bot.get_bot_index()),
				"%s: valid name per seed" % label)
		names[bot.get_display_name()] = true
		assert_true(int(stats["snapshots"]) > 50, "%s: receives snapshots (%d)" % [label, stats["snapshots"]])
		assert_true(int(stats["snapshots_with_state"]) > 50, "%s: with its own state" % label)
		assert_eq(int(stats["malformed_packets"]), 0, "%s: no malformed packets" % label)
		assert_true(int(stats["bytes_up"]) > 1000 and int(stats["bytes_down"]) > 1000,
				"%s: uploads and downloads bytes (%d / %d)" % [label, stats["bytes_up"], stats["bytes_down"]])
		assert_true(float(stats["avg_snapshot_bytes"]) > 49.0 + 20.0 * 6.0,
				"%s: snapshots with the other 7 (%.1f B on average)" % [label, stats["avg_snapshot_bytes"]])
		assert_eq(int(stats["max_snapshot_records"]), 7, "%s: sees the other 7" % label)
		assert_true(int(stats["batches_sent"]) > 150, "%s: sends batches every tick" % label)
		if _server_position(bot.get_net_id()).distance_to(bot.get_position()) < 3.0:
			in_sync += 1
	assert_eq(names.size(), 8, "eight different names")

	# The server treats them like real clients: their inputs arrive on time and there are no warnings.
	for peer_id: int in _server.get_peer_ids():
		var peer: ServerPeer = _server.get_peer(peer_id)
		assert_eq(peer.strikes_total, 0, "peer %d: no warnings" % peer_id)
		assert_eq(peer.state, ServerPeer.State.IN_WORLD)
		assert_true(peer.input_queue.substitutions_total <= 4,
				"peer %d: replaced inputs %d" % [peer_id, peer.input_queue.substitutions_total])
		assert_eq(peer.input_queue.late_count, 0, "peer %d: no late input" % peer_id)
	assert_eq(in_sync, 8, "the position each bot uses (that of its snapshot) is the server's, delayed")


func test_walking_bots_actually_move_on_the_server() -> void:
	await _start_server()
	_start_swarm(4, func(config: ClientConfig) -> void: config.bot_seed = 7)
	assert_true(await _wait_until(func() -> bool: return _swarm.count_in_world() == 4), "all 4 get in")
	var starts: Dictionary = {}
	for bot: SwarmBot in _swarm.get_bots():
		starts[bot.get_net_id()] = _server_position(bot.get_net_id())
	await wait_physics_frames(420)
	var travelled: int = 0
	for bot: SwarmBot in _swarm.get_bots():
		var start: Vector3 = starts[bot.get_net_id()]
		var distance: float = start.distance_to(_server_position(bot.get_net_id()))
		if distance > 2.0:
			travelled += 1
	assert_true(travelled >= 3, "at least 3 of the 4 have walked more than 2 m (%d)" % travelled)


func test_report_has_bytes_per_client_and_the_swarm_quits_on_its_own() -> void:
	await _start_server()
	_start_swarm(4, func(config: ClientConfig) -> void: config.quit_after_ticks = 240)
	assert_true(await _wait_until(_exited), "the swarm closes on its own (--quit-after-ticks)")
	assert_eq(_exit_codes[0], 0, "with code 0: all of them were playing")
	var report: Dictionary = NetHarness.read_report(NetHarness.build_path(REPORT_FILE))
	assert_eq(int(report.get("version", 0)), 1)
	assert_eq(report.get("mode"), "SWARM")
	assert_eq(int(report.get("port", 0)), _port)
	var bots: Dictionary = report.get("bots", {})
	assert_eq(int(bots.get("requested", 0)), 4)
	assert_eq(int(bots.get("created", 0)), 4)
	assert_eq(int(bots.get("played", 0)), 4, "all 4 played")
	assert_eq(int(bots.get("rejected", -1)), 0)
	var clients: Array = report.get("clients", [])
	if not assert_eq(clients.size(), 4, "one record per client"):
		return
	var snapshots: int = 0
	for entry: Dictionary in clients:
		assert_true(int(entry.get("bytes_up", 0)) > 500, "upload bytes per client (%s)" % entry.get("bytes_up"))
		assert_true(int(entry.get("bytes_down", 0)) > 500, "download bytes per client (%s)" % entry.get("bytes_down"))
		assert_true(int(entry.get("snapshots", 0)) > 20, "snapshots received (%s)" % entry.get("snapshots"))
		assert_true(float(entry.get("avg_snapshot_bytes", 0.0)) > 49.0, "average snapshot size")
		assert_true(float(entry.get("kb_down_per_s", 0.0)) > 0.1, "KB/s of download")
		snapshots += int(entry.get("snapshots", 0))
	var totals: Dictionary = report.get("totals", {})
	assert_eq(int(totals.get("snapshots", -1)), snapshots, "the total of snapshots is the sum")
	assert_true(float(totals.get("avg_snapshot_bytes", 0.0)) > 49.0)
	# After the close, the bots leave the zone with CLIENT_LEAVE.
	assert_true(await _wait_until(func() -> bool: return _server.get_player_count() == 0),
			"and the server is left with no players")


func test_the_swarm_can_quit_when_the_server_reaches_a_tick() -> void:
	# The load tests close it this way (F6b review): a loaded server runs slower than real time.
	await _start_server()
	var target: int = _server.get_tick() + 240
	_start_swarm(2, func(config: ClientConfig) -> void: config.quit_at_server_tick = target)
	assert_true(await _wait_until(_exited), "the swarm closes on its own (--quit-at-server-tick)")
	assert_eq(_exit_codes[0], 0, "with code 0: all of them were playing")
	assert_true(_swarm.newest_server_tick() >= target,
			"when its bots see the server's tick %d (%d)" % [target, _swarm.newest_server_tick()])
	assert_true(_server.get_tick() >= target, "and not before")


func test_bots_rejected_by_a_full_server_make_the_exit_code_one() -> void:
	await _start_server(2)
	_start_swarm(3, func(config: ClientConfig) -> void: config.quit_after_ticks = 200)
	assert_true(await _wait_until(_exited), "the swarm closes on its own")
	assert_eq(_exit_codes[0], 1, "with code 1: one could not get in")
	var report: Dictionary = NetHarness.read_report(NetHarness.build_path(REPORT_FILE))
	var bots: Dictionary = report.get("bots", {})
	assert_eq(int(bots.get("played", 0)), 2, "2 play")
	assert_eq(int(bots.get("rejected", 0)), 1, "and one receives REJECT")
	var rejected_entry: Dictionary = {}
	for entry: Dictionary in report.get("clients", []):
		if bool(entry.get("rejected", false)):
			rejected_entry = entry
	assert_eq(int(rejected_entry.get("reject_result", 0)), NetProtocol.Result.FULL, "because the server is full")
	assert_eq(rejected_entry.get("reject_text"), NetProtocol.result_text(NetProtocol.Result.FULL))
	assert_eq(rejected_entry.get("state"), "CLOSED")


# The server treats a swarm bot like a player: it receives its realm's "zone" chat, it can be
# whispered to and it can be invited (PARTY_INVITATION and the system notice). All of that is well-formed and
# must not count in malformed_packets, which is what the tests and the load reports look at.
func test_chat_and_party_messages_reach_a_bot_without_counting_as_malformed() -> void:
	await _start_server()
	_start_swarm(1, func(config: ClientConfig) -> void: config.realm = NetProtocol.Realm.VARDHEIM)
	_client_viewport = NetHarness.make_world_viewport(_root, "")
	var client: NetClient = NetHarness.start_bot(_client_viewport, _port, NetProtocol.Realm.VARDHEIM, 90)
	var both_in: bool = await _wait_until(func() -> bool:
		return _swarm.count_in_world() == 1 and client.get_state() == NetClient.State.IN_WORLD)
	if not assert_true(both_in, "the swarm bot and a client get in, both from Vardheim"):
		return
	var bot: SwarmBot = _swarm.get_bots()[0]
	assert_true(bot.get_display_name() != client.get_config().display_name, "different names")
	# The types of everything that reaches the bot (the test connects after it, so each packet
	# has already been handled by the bot by the time it is noted here).
	var received: Dictionary[int, int] = {}
	var transport: NetTransport = bot.get_node("NetTransport") as NetTransport
	transport.packet_received.connect(func(_peer_id: int, bytes: PackedByteArray) -> void:
		var msg_type: int = bytes[0] if not bytes.is_empty() else -1
		received[msg_type] = received.get(msg_type, 0) + 1)

	assert_true(client.send_chat(ChatChannel.Id.ZONE, "", "hola a todos"), "speaks in the zone chat")
	assert_true(client.send_chat(ChatChannel.Id.WHISPER, bot.get_display_name(), "psst"), "whispers to the bot")
	assert_true(client.send_party_invite(bot.get_display_name()), "invites it to the party")
	# Zone, whisper and the system notice of the invitation (three CHAT_MESSAGEs) and the invitation.
	var arrived: bool = await _wait_until(func() -> bool:
		return received.get(NetProtocol.MSG_CHAT_MESSAGE, 0) >= 3 \
				and received.get(NetProtocol.MSG_PARTY_INVITATION, 0) >= 1)
	assert_true(arrived, "the chat and the invitation reach it (%s)" % received)
	var stats: Dictionary = bot.get_stats()
	assert_eq(int(stats["malformed_packets"]), 0, "chat and parties do not count as malformed")
	assert_eq(int(stats.get("chat_messages_seen", -1)), received.get(NetProtocol.MSG_CHAT_MESSAGE, 0),
			"counts every CHAT_MESSAGE that reaches it")
	assert_eq(int(stats.get("party_messages_seen", -1)), received.get(NetProtocol.MSG_PARTY_INVITATION, 0),
			"and every PARTY_INVITATION")
	assert_eq(bot.get_state(), SwarmBot.State.IN_WORLD, "and keeps playing")


# PARTY_ROSTER and PARTY_STATUS only reach someone who is in a party, and a swarm bot does not accept
# invitations: they are given to it by hand, along with broken versions of all four types, which do count.
func test_party_roster_and_status_are_discarded_and_broken_ones_count_as_malformed() -> void:
	var bot := SwarmBot.new()
	var roster := NetMessages.PartyRoster.new()
	roster.members.append(NetMessages.PartyRoster.Member.make(3, "Brand"))
	roster.members.append(NetMessages.PartyRoster.Member.make(5, NameRules.bot_name(40)))
	var status := NetMessages.PartyStatus.new()
	status.members.append(NetMessages.PartyStatus.MemberStatus.make(3, 200, 255, 0, Vector3(1.0, 0.0, 2.0)))
	var system := NetMessages.ChatMessage.new()
	system.channel = ChatChannel.Id.SYSTEM
	system.text = "Ya no estás en un grupo."
	for bytes: PackedByteArray in [roster.encode(), NetMessages.PartyRoster.new().encode(), status.encode(),
			system.encode()]:
		bot._on_packet_received(SwarmBot.SERVER_PEER_ID, bytes)
	var stats: Dictionary = bot.get_stats()
	assert_eq(int(stats["malformed_packets"]), 0, "the well-formed lists, status and notice do not count")
	assert_eq(int(stats.get("party_messages_seen", -1)), 3, "two PARTY_ROSTERs and one PARTY_STATUS")
	assert_eq(int(stats.get("chat_messages_seen", -1)), 1, "and one CHAT_MESSAGE")

	# Truncated: only the type, or the good message with one byte less.
	var broken: Array[PackedByteArray] = []
	for msg_type: int in [NetProtocol.MSG_CHAT_MESSAGE, NetProtocol.MSG_PARTY_INVITATION,
			NetProtocol.MSG_PARTY_ROSTER, NetProtocol.MSG_PARTY_STATUS]:
		broken.append(PackedByteArray([msg_type]))
	for good: PackedByteArray in [roster.encode(), status.encode(), system.encode()]:
		broken.append(good.slice(0, good.size() - 1))
	for bytes: PackedByteArray in broken:
		bot._on_packet_received(SwarmBot.SERVER_PEER_ID, bytes)
	stats = bot.get_stats()
	assert_eq(int(stats["malformed_packets"]), broken.size(), "each broken one counts as malformed")
	assert_eq(int(stats.get("party_messages_seen", -1)), 3, "and not as seen")
	assert_eq(int(stats.get("chat_messages_seen", -1)), 1)
	bot.free()


## Server-side position of the player with that net_id (infinite if it does not exist).
func _server_position(net_id: int) -> Vector3:
	var entity: NetEntity = _server.get_registry().get_entity(net_id)
	if entity == null:
		return Vector3(INF, INF, INF)
	return entity.get_position()


func test_a_siege_bot_does_not_count_a_downed_ally_in_the_rally() -> void:
	# Abilities integration review: a knocked-down character publishes its knocked-down health, which is never 0
	# (Combatant.publish), and the SwarmBot only looked at health: it counted knocked-down characters in the rally (GUE-44) and went out to
	# "help them", when the server does not count them for its fake ones (is_alive). It also looks at their action, DOWNED.
	var states: Dictionary[String, Array] = {"en pie": [CombatState.Action.NONE, 200, true],
			"derribado": [CombatState.Action.DOWNED, 3, false], "muerto": [CombatState.Action.NONE, 0, false]}
	for label: String in states:
		var record := EntityRecord.from_state(7, NetProtocol.EntityKind.PLAYER, PlayerState.new(), 0)
		record.action = int(states[label][0])
		record.health_q = int(states[label][1])
		# A snapshot section with that record: (type, how many) and the record.
		var bytes := PackedByteArray([1, NetProtocol.EntityKind.PLAYER, 1])
		record.encode_into(bytes, bytes.size())
		assert_eq(SwarmBot.is_standing_record(bytes, 3), bool(states[label][2]), label)
		var bot := SwarmBot.new()
		bot._ally_positions[7] = Vector3.ZERO
		bot._ally_alive[7] = true
		# Each snapshot decodes one of every ENEMY_SCAN_STRIDE records, rotating: in that many, all of them.
		for _i: int in SwarmBot.ENEMY_SCAN_STRIDE:
			bot._scan_enemies(bytes, 0)
		assert_eq(bot._count_allies(Vector3.ZERO, 10.0), 1 if bool(states[label][2]) else 0,
				"%s: in the rally, %s" % [label, "cuenta" if bool(states[label][2]) else "no cuenta"])
		bot.free()
