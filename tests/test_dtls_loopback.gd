extends TestCase
## DTLS end to end in one process (docs/plataforma.md §10.2 and §15, P9c; TEC-27): server and client with real ENet
## over 127.0.0.1, the server behind [GuardedEnetPeer], and a clean shutdown with no engine errors (the
## runner fails on any).
## [br][br]
## - Bare [NetTransport]: handshake, 1200 B packets in both directions and over all three channels, the client's
## exit (which does not start the cut: the server does on receiving its CLIENT_LEAVE, or it closes everything itself
## after 60 ticks) and that no client packet is dropped by the filter.
## - A client that pins another certificate, that expects another name or that goes in the clear does not manage to connect (those
## failures are logged by the engine: they are the only tests that allow them).
## - [ZoneServer] with [member ServerConfig.dtls] and a [NetClient] (the predicting bot) and the real swarm
## ([BotSwarm] with [code]--dtls-cert --dtls-name[/code]): they enter, play, leave with CLIENT_LEAVE and the server is left
## empty. The swarm also against the real dedicated server in another process ([code]--server --dtls-cert
## --dtls-key[/code]), which loads the certificate with [ZoneDtls] and says so in its log and its report.

const DIR: String = "res://tests/fixtures/dtls/"
const ZONE_CERT: String = DIR + "zone_cert.pem"
const ZONE_KEY: String = DIR + "zone_key.pem"
const OTHER_CERT: String = DIR + "other_cert.pem"
const ZONE_NAME: String = "zona-pruebas.eldmark.test"
const SWARM_SCENE: String = "res://scenes/client/bot_swarm.tscn"
const REPORT_FILE: String = "test_dtls_loopback_swarm.json"
const ZONE_ID: String = "test_world"
const MAX_TICKS: int = 600
const WAIT_FRAMES: int = 900

const HELLO: PackedByteArray = [0x45, 0x4C, 0x44, 0x4D, 0x01]
const WELCOME: PackedByteArray = [0x45, 0x4C, 0x44, 0x4D, 0x00, 0x77]

var _root: Node
var _tick: int = 0
var _server_viewport: SubViewport
var _client_viewport: SubViewport
var _server: ZoneServer
var _swarm: BotSwarm
var _port: int = 0
var _exit_codes: Array[int] = []
var _saved_config: ClientConfig
var _saved_hook: Callable
var _saved_max_fps: int = 0
var _pids: Array[int] = []


## One end of the transport test: the [NetTransport] and what reaches it. The server answers the HELLO with
## WELCOME and, if [member answer_leave], a CLIENT_LEAVE with the ordered cut (like [ZoneServer]).
class Endpoint:
	extends RefCounted

	var transport: NetTransport
	var answer_leave: bool = true
	var authenticating: Array[int] = []
	var connected: Array[int] = []
	var disconnected: Array[int] = []
	var failed: int = 0
	var discarded: int = 0
	var packets: Array[PackedByteArray] = []

	func _init(p_transport: NetTransport) -> void:
		transport = p_transport
		transport.peer_authenticating.connect(func(peer_id: int) -> void:
			authenticating.append(peer_id)
			if not transport.is_server():
				transport.send_auth(peer_id, HELLO))
		transport.auth_received.connect(func(peer_id: int, bytes: PackedByteArray) -> void:
			if transport.is_server():
				transport.send_auth(peer_id, WELCOME)
				transport.complete_auth(peer_id)
			elif bytes == WELCOME:
				transport.complete_auth(peer_id))
		transport.peer_connected.connect(func(peer_id: int) -> void: connected.append(peer_id))
		transport.peer_disconnected.connect(func(peer_id: int) -> void: disconnected.append(peer_id))
		transport.connection_failed.connect(func() -> void: failed += 1)
		transport.packets_discarded.connect(func(_peer_id: int, count: int) -> void: discarded += count)
		transport.packet_received.connect(func(peer_id: int, bytes: PackedByteArray) -> void:
			packets.append(bytes)
			if transport.is_server() and answer_leave and bytes[0] == NetProtocol.MSG_CLIENT_LEAVE:
				transport.disconnect_after_flush(peer_id))


func before_each() -> void:
	_saved_config = BotSwarm.config
	_saved_hook = BotSwarm.quit_hook
	_saved_max_fps = Engine.max_fps
	_exit_codes.clear()
	BotSwarm.quit_hook = func(code: int) -> void: _exit_codes.append(code)
	DirAccess.remove_absolute(NetHarness.build_path(REPORT_FILE))
	_root = Node.new()
	_root.name = "DtlsLoopbackTest"
	tree.root.add_child(_root)
	_tick = 0


func after_each() -> void:
	for pid: int in _pids:
		if OS.is_process_running(pid):
			OS.kill(pid)
	_pids.clear()
	if is_instance_valid(_swarm):
		_swarm.get_parent().remove_child(_swarm)
		_swarm.free()
	_swarm = null
	if is_instance_valid(_client_viewport):
		_client_viewport.free()
	_client_viewport = null
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


# --- Helpers ----------------------------------------------------------------------------------

func _certificate(path: String = ZONE_CERT) -> X509Certificate:
	var certificate := X509Certificate.new()
	certificate.load(path)
	return certificate


func _zone_dtls() -> ZoneDtls:
	return ZoneDtls.load_files(ZONE_CERT, ZONE_KEY)


func _transport(node_name: String) -> NetTransport:
	var transport := NetTransport.new()
	transport.name = node_name
	_root.add_child(transport)
	return transport


func _step(endpoints: Array[Endpoint]) -> void:
	_tick += 1
	for endpoint: Endpoint in endpoints:
		endpoint.transport.poll(_tick)
	for endpoint: Endpoint in endpoints:
		endpoint.transport.flush()
	await tree.physics_frame


func _run_until(endpoints: Array[Endpoint], condition: Callable, max_ticks: int = MAX_TICKS) -> bool:
	for _i: int in max_ticks:
		if condition.call():
			return true
		await _step(endpoints)
	return condition.call()


func _bytes(type: int, size: int) -> PackedByteArray:
	var bytes := PackedByteArray()
	bytes.resize(size)
	for i: int in size:
		bytes[i] = (i * 31 + size) & 0xFF
	bytes[0] = type
	return bytes


# Server with DTLS and a client that pins [param certificate] and expects [param name]. Returns [server, client].
func _pair(certificate: X509Certificate, name: String) -> Array[Endpoint]:
	var server := Endpoint.new(_transport("DtlsServer"))
	var client := Endpoint.new(_transport("DtlsClient"))
	_port = NetHarness.free_udp_port()
	assert_eq(server.transport.host(_port, 4, _zone_dtls().server_options), OK, "the server opens the port with DTLS")
	var options: TLSOptions = TLSOptions.client(certificate) if certificate != null else null
	assert_eq(client.transport.connect_to("127.0.0.1", _port, 3000, name, options), OK, "the client starts to connect")
	return [server, client]


# First the client and then the server: if the server closes first, the client's DTLS close notice goes to an
# already closed port, the system answers with an ICMP and the client's next send fails with an engine error
# (bio_send).
func _close_all(endpoints: Array[Endpoint]) -> void:
	for i: int in range(endpoints.size() - 1, -1, -1):
		endpoints[i].transport.close()


# --- Bare NetTransport ------------------------------------------------------------------------

func test_a_dtls_handshake_carries_full_packets_through_the_guard_and_closes_cleanly() -> void:
	var pair: Array[Endpoint] = _pair(_certificate(), ZONE_NAME)
	var server: Endpoint = pair[0]
	var client: Endpoint = pair[1]
	assert_true(server.transport.is_dtls() and client.transport.is_dtls(), "both sides go over DTLS")
	var started: int = Time.get_ticks_msec()
	var connected: bool = await _run_until(pair, func() -> bool:
		return server.connected.size() == 1 and client.connected.size() == 1)
	if not assert_true(connected, "they connect and authenticate"):
		_close_all(pair)
		return
	print("    (conexión con DTLS en %d ms, %d ticks)" % [Time.get_ticks_msec() - started, _tick])
	var peer_id: int = server.connected[0]
	# Maximum-size packets over all three channels and in both directions.
	var up: Array[PackedByteArray] = [_bytes(NetProtocol.MSG_INPUT_BATCH, NetProtocol.MAX_PACKET_BYTES),
			_bytes(NetProtocol.MSG_CLIENT_READY, NetProtocol.MAX_PACKET_BYTES)]
	var down: Array[PackedByteArray] = [_bytes(NetProtocol.MSG_SNAPSHOT, NetProtocol.MAX_PACKET_BYTES),
			_bytes(NetProtocol.MSG_ENTITY_SPAWN, 3000)]
	assert_eq(client.transport.send(1, NetProtocol.CH_INPUT, up[0]), OK)
	assert_eq(client.transport.send(1, NetProtocol.CH_RELIABLE, up[1]), OK)
	assert_eq(server.transport.send(peer_id, NetProtocol.CH_SNAPSHOT, down[0]), OK)
	assert_eq(server.transport.send(peer_id, NetProtocol.CH_RELIABLE, down[1]), OK, "a reliable 3000 B packet is fragmented")
	assert_true(await _run_until(pair, func() -> bool:
		return server.packets.size() == 2 and client.packets.size() == 2), "all four arrive")
	assert_true(server.packets.has(up[0]) and server.packets.has(up[1]), "at the server, intact")
	assert_true(client.packets.has(down[0]) and client.packets.has(down[1]), "at the client, intact")
	assert_eq(server.discarded, 0, "the server filter drops nothing from the client")
	# The exit: CLIENT_LEAVE and ordered cut; the server makes the cut.
	var leave := NetMessages.ClientLeave.new()
	leave.reason = NetMessages.ClientLeave.REASON_QUIT
	assert_eq(client.transport.send(1, NetProtocol.CH_RELIABLE, leave.encode()), OK)
	client.transport.disconnect_after_flush(1)
	var asked_at: int = _tick
	assert_true(await _run_until(pair, func() -> bool:
		return server.disconnected.size() == 1 and client.disconnected.size() == 1, 120),
			"both see the cut")
	assert_true(_tick - asked_at < NetTransport.FORCE_DISCONNECT_TICKS,
			"without waiting for the forced cut (%d ticks)" % (_tick - asked_at))
	# A few more ticks: a DTLS close notice that arrived late would be an engine error here.
	for _i: int in 30:
		await _step(pair)
	_close_all(pair)
	assert_eq(server.failed + client.failed, 0, "no connection failures")


func test_a_dtls_client_whose_leave_gets_no_answer_closes_everything_after_sixty_ticks() -> void:
	var pair: Array[Endpoint] = _pair(_certificate(), ZONE_NAME)
	var server: Endpoint = pair[0]
	var client: Endpoint = pair[1]
	server.answer_leave = false
	if not assert_true(await _run_until(pair, func() -> bool: return client.connected.size() == 1), "they connect"):
		_close_all(pair)
		return
	client.transport.disconnect_after_flush(1)
	var asked_at: int = _tick
	for _i: int in 40:
		await _step(pair)
	assert_eq(server.disconnected.size(), 0, "the client does not start the cut on its own")
	assert_true(await _run_until(pair, func() -> bool:
		return server.disconnected.size() == 1 and client.disconnected.size() == 1, 120),
			"after 60 ticks it closes everything and both see it")
	assert_true(_tick - asked_at >= NetTransport.FORCE_DISCONNECT_TICKS, "when the deadline is met")
	assert_eq(client.transport.send(1, NetProtocol.CH_RELIABLE, PackedByteArray([1])), ERR_UNCONFIGURED,
			"the client transport no longer has a connection")
	for _i: int in 30:
		await _step(pair)
	# It can connect again with the same transport.
	client.transport.close()
	assert_eq(client.transport.connect_to("127.0.0.1", _port, 3000, ZONE_NAME, TLSOptions.client(_certificate())), OK,
			"and connects again")
	assert_true(await _run_until(pair, func() -> bool: return client.connected.size() == 2), "inside again")
	_close_all(pair)


func test_a_client_with_another_certificate_another_name_or_in_clear_does_not_connect() -> void:
	# Failed handshakes are logged by the engine (mbedtls): that is what is being tested.
	allow_logged_errors()
	var cases: Array[Array] = [[_certificate(OTHER_CERT), "otra-zona.eldmark.test", "otro certificado"],
			[_certificate(), "otro-nombre.eldmark.test", "otro nombre"], [null, "", "en claro"]]
	for entry: Array in cases:
		var pair: Array[Endpoint] = _pair(entry[0], entry[1])
		var server: Endpoint = pair[0]
		var client: Endpoint = pair[1]
		await _run_until(pair, func() -> bool: return client.failed > 0 or client.connected.size() > 0, 400)
		assert_eq(client.connected.size(), 0, "%s: does not connect" % entry[2])
		assert_eq(server.authenticating.size(), 0, "%s: the server never gets to see a peer" % entry[2])
		assert_eq(client.failed, 1, "%s: the client considers it failed" % entry[2])
		_close_all(pair)
		for endpoint: Endpoint in pair:
			endpoint.transport.queue_free()
		await wait_process_frames(2)


# --- ZoneServer, NetClient and the swarm --------------------------------------------------------

func _start_server() -> void:
	_port = NetHarness.free_udp_port()
	_server_viewport = NetHarness.make_world_viewport(_root, "")
	var config := ServerConfig.new()
	config.port = _port
	config.zone_id = ZONE_ID
	config.max_players = 8
	config.dtls = _zone_dtls()
	_server = NetHarness.start_server(_server_viewport, config)
	await wait_physics_frames(3)


func _wait_until(condition: Callable, max_frames: int = WAIT_FRAMES) -> bool:
	for _i: int in max_frames:
		if condition.call():
			return true
		await tree.physics_frame
	return condition.call()


func test_a_predicting_bot_plays_and_leaves_a_dtls_zone() -> void:
	await _start_server()
	assert_true((_server_viewport.get_node("ServerTransport") as NetTransport).is_dtls(), "the zone listens over DTLS")
	_client_viewport = NetHarness.make_world_viewport(_root, "")
	var client: NetClient = NetHarness.start_bot(_client_viewport, _port, NetProtocol.Realm.VARDHEIM, 61, "", "", "",
			"", func(config: ClientConfig) -> void:
				config.dtls_cert_path = ZONE_CERT
				config.dtls_name = ZONE_NAME)
	assert_true((client.get_meta(&"transport") as NetTransport).is_dtls(), "the bot connects over DTLS")
	if not assert_true(await _wait_until(func() -> bool: return client.get_state() == NetClient.State.IN_WORLD),
			"enters the world"):
		return
	await wait_physics_frames(120)
	var stats: Dictionary = client.get_stats()
	assert_true(int(stats.get("snapshots", 0)) > 30, "receives snapshots (%s)" % stats.get("snapshots"))
	assert_eq(int(stats.get("malformed_packets", 0)), 0, "no malformed packets")
	assert_eq(_server.get_player_count(), 1)
	client.leave()
	assert_true(await _wait_until(func() -> bool:
		return client.get_state() == NetClient.State.CLOSED and _server.get_player_count() == 0, 240),
			"leaves with CLIENT_LEAVE and the server is left empty")
	await wait_physics_frames(30)


func _start_swarm(count: int, configure: Callable = Callable()) -> void:
	var config := ClientConfig.new()
	config.mode = ClientConfig.Mode.SWARM
	config.port = _port
	config.bot_count = count
	config.bot_seed = 70
	config.report_path = NetHarness.build_path(REPORT_FILE)
	config.dtls_cert_path = ZONE_CERT
	config.dtls_name = ZONE_NAME
	if configure.is_valid():
		configure.call(config)
	BotSwarm.config = config
	var packed: PackedScene = load(SWARM_SCENE) as PackedScene
	_swarm = packed.instantiate() as BotSwarm
	_root.add_child(_swarm)


func test_a_swarm_with_the_certificate_plays_a_dtls_zone_and_leaves_cleanly() -> void:
	await _start_server()
	_start_swarm(4, func(config: ClientConfig) -> void: config.quit_after_ticks = 300)
	if not assert_true(await _wait_until(func() -> bool: return _swarm.count_in_world() == 4), "all 4 enter"):
		return
	assert_eq(_server.get_player_count(), 4)
	for bot: SwarmBot in _swarm.get_bots():
		assert_true((bot.get_node("NetTransport") as NetTransport).is_dtls(), "bot %d over DTLS" % bot.get_bot_index())
	assert_true(await _wait_until(func() -> bool: return not _exit_codes.is_empty()), "the swarm shuts down on its own")
	assert_eq(_exit_codes[0], 0, "with code 0: all of them played")
	var report: Dictionary = NetHarness.read_report(NetHarness.build_path(REPORT_FILE))
	assert_true(bool(report.get("dtls", false)), "the report says it went over DTLS")
	for entry: Dictionary in report.get("clients", []):
		assert_true(int(entry.get("snapshots", 0)) > 20, "bot %s: snapshots (%s)" % [entry.get("index"),
				entry.get("snapshots")])
		assert_eq(int(entry.get("malformed_packets", 0)), 0)
	assert_true(await _wait_until(func() -> bool: return _server.get_player_count() == 0, 240),
			"they leave with CLIENT_LEAVE and the server is left empty")
	for bot: SwarmBot in _swarm.get_bots():
		assert_eq(bot.get_state(), SwarmBot.State.CLOSED, "bot %d closed" % bot.get_bot_index())
	for peer_id: int in _server.get_peer_ids():
		fail("peer %d remains" % peer_id)
	await wait_physics_frames(30)


func test_a_swarm_without_the_name_or_with_an_unreadable_certificate_exits_with_one() -> void:
	_port = NetHarness.free_udp_port()
	_start_swarm(2, func(config: ClientConfig) -> void: config.dtls_name = "")
	assert_eq(_exit_codes, [1] as Array[int], "without --dtls-name, code 1")
	assert_eq(_swarm.get_bots().size(), 0, "and no bot connects in the clear")
	_swarm.get_parent().remove_child(_swarm)
	_swarm.free()
	_exit_codes.clear()
	_start_swarm(2, func(config: ClientConfig) -> void: config.dtls_cert_path = DIR + "no_existe.pem")
	assert_eq(_exit_codes, [1] as Array[int], "with a certificate that cannot be read, code 1")
	assert_eq(_swarm.get_bots().size(), 0)


func test_a_server_process_with_its_certificate_takes_a_swarm_by_dtls() -> void:
	_port = NetHarness.free_udp_port()
	var log_path: String = NetHarness.build_path("test_dtls_server.log")
	var report_path: String = NetHarness.build_path("test_dtls_server.json")
	var stop_path: String = NetHarness.build_path("test_dtls_server.stop")
	for path: String in [log_path, report_path, stop_path]:
		DirAccess.remove_absolute(path)
	var pid: int = NetHarness.launch_process(PackedStringArray(["--server", "--zone=%s" % ZONE_ID,
			"--port=%d" % _port, "--quit-after-ticks=3600", "--report=%s" % report_path, "--stop-file=%s" % stop_path,
			"--dtls-cert=%s" % ProjectSettings.globalize_path(ZONE_CERT),
			"--dtls-key=%s" % ProjectSettings.globalize_path(ZONE_KEY)]), "test_dtls_server")
	_pids.append(pid)
	var listening: bool = false
	for _i: int in 200:
		if FileAccess.get_file_as_string(log_path).contains("escuchando en el puerto") or not OS.is_process_running(pid):
			listening = OS.is_process_running(pid)
			break
		await tree.create_timer(0.1).timeout
	if not assert_true(listening, "the server listens"):
		return
	var text: String = FileAccess.get_file_as_string(log_path)
	assert_true(text.contains("DTLS: certificado de «%s»" % ZONE_NAME), "loads the certificate and says its CN")
	assert_true(text.contains("con DTLS"), "and listens over DTLS")
	_start_swarm(2, func(config: ClientConfig) -> void: config.quit_after_ticks = 240)
	assert_true(await _wait_until(func() -> bool: return not _exit_codes.is_empty(), 900), "the swarm finishes")
	assert_eq(_exit_codes[0] if not _exit_codes.is_empty() else -1, 0, "with code 0: both played")
	await wait_physics_frames(30)
	var stop_file: FileAccess = FileAccess.open(stop_path, FileAccess.WRITE)
	stop_file.close()
	var deadline: int = Time.get_ticks_msec() + 15000
	while OS.is_process_running(pid) and Time.get_ticks_msec() < deadline:
		await tree.create_timer(0.1).timeout
	if not assert_false(OS.is_process_running(pid), "the server shuts down with the stop file"):
		return
	assert_eq(OS.get_process_exit_code(pid), 0, "exit code 0")
	var report: Dictionary = NetHarness.read_report(report_path)
	assert_true(bool(report.get("dtls", false)), "the server report says it went over DTLS")
	assert_eq(int((report.get("players", {}) as Dictionary).get("joined_total", 0)), 2, "both entered")
	var log_text: String = FileAccess.get_file_as_string(log_path)
	for marker: String in ["ERROR", "SCRIPT ERROR", "TLS handshake error", "bio_send"]:
		assert_false(log_text.contains(marker), "the server log does not have \"%s\"" % marker)
