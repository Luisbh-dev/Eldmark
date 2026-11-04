extends TestCase
## Tests of NetSim (tick-based network simulator) and of NetTransport over real ENet on 127.0.0.1.
##
## NetSim: same seed, same sequence; loss does not touch the reliable channels; reliable packets
## come out in FIFO order per (peer, channel); the delay falls within rtt/2 ± jitter.
## [br][br]
## NetTransport: a server and a client in the same process (two nodes, each with its
## [SceneMultiplayer] registered by path), the handshake with send_auth/complete_auth on both
## sides, one packet per channel after peer_connected, rejection with an orderly disconnect, the
## connection failure and the simulator applied on one side. The runner fails on any engine error, so
## each of these tests also checks that nothing is sent before peer_connected.

const TICK_MS: float = 1000.0 / 60.0
## First port tried for the test servers (shifted per process so as not to collide with other
## simultaneous runs).
const FIRST_PORT: int = 24700
const MAX_HANDSHAKE_TICKS: int = 400

const HELLO: PackedByteArray = [0x45, 0x4C, 0x44, 0x4D, 0x01]
const WELCOME: PackedByteArray = [0x45, 0x4C, 0x44, 0x4D, 0x00, 0x77]
const REJECT: PackedByteArray = [0x45, 0x4C, 0x44, 0x4D, 0x03, 0x78]

## Test message types, one per channel and direction.
const TYPE_UP_UNRELIABLE: int = NetProtocol.MSG_INPUT_BATCH
const TYPE_UP_RELIABLE: int = NetProtocol.MSG_CLIENT_READY
const TYPE_DOWN_UNRELIABLE: int = NetProtocol.MSG_SNAPSHOT
const TYPE_DOWN_RELIABLE: int = NetProtocol.MSG_ENTITY_SPAWN

## Keys of the latencies returned by _measure_latencies().
const LATENCY_KEYS: Array[String] = [
	"up_unreliable", "up_reliable", "down_unreliable", "down_reliable",
]

var _tick: int = 0
var _port: int = 0
var _nodes: Array[NetTransport] = []


## One end of the test: a NetTransport plus the log of everything that arrives at it.
class Endpoint:
	extends RefCounted

	var transport: NetTransport
	var tick: int = 0
	## On the server: replies REJECT and disconnects, instead of WELCOME.
	var reject: bool = false
	## On the server: false = only records the authentication messages, without replying.
	var respond_to_auth: bool = true
	var authenticating: Array[int] = []
	## get_remote_address() of each peer at the moment of peer_authenticating.
	var authenticating_addresses: Array[String] = []
	var auth_messages: Array[PackedByteArray] = []
	var connected: Array[int] = []
	var disconnected: Array[int] = []
	var failed_count: int = 0
	## Packets the transport has discarded for not belonging to the protocol (packets_discarded).
	var discarded: int = 0
	## Each packet received: [arrival tick, peer_id, bytes].
	var packets: Array[Array] = []
	## Results of send() made before peer_connected (all must be ERR_UNAVAILABLE).
	var early_sends: Array[int] = []
	## Order in which the signals arrive: "authenticating", "auth", "connected", "packet",
	## "disconnected", "failed".
	var event_log: Array[String] = []

	func _init(p_transport: NetTransport) -> void:
		transport = p_transport
		transport.peer_authenticating.connect(_on_authenticating)
		transport.auth_received.connect(_on_auth_received)
		transport.peer_connected.connect(_on_connected)
		transport.peer_disconnected.connect(_on_disconnected)
		transport.packet_received.connect(_on_packet)
		transport.connection_failed.connect(_on_connection_failed)
		transport.packets_discarded.connect(_on_discarded)

	func _on_discarded(_peer_id: int, count: int) -> void:
		event_log.append("discarded")
		discarded += count

	func _on_authenticating(peer_id: int) -> void:
		event_log.append("authenticating")
		authenticating.append(peer_id)
		authenticating_addresses.append(transport.get_remote_address(peer_id))
		early_sends.append(transport.send(peer_id, NetProtocol.CH_RELIABLE, PackedByteArray([1])))
		if not transport.is_server():
			transport.send_auth(peer_id, HELLO)

	func _on_auth_received(peer_id: int, bytes: PackedByteArray) -> void:
		event_log.append("auth")
		auth_messages.append(bytes)
		if not respond_to_auth:
			return
		if transport.is_server():
			if reject:
				transport.send_auth(peer_id, REJECT)
				transport.flush()
				transport.disconnect_after_flush(peer_id)
				return
			transport.send_auth(peer_id, WELCOME)
			transport.complete_auth(peer_id)
		elif bytes == WELCOME:
			transport.complete_auth(peer_id)
		# Right after complete_auth() the peer is not yet connected on this side.
		early_sends.append(transport.send(peer_id, NetProtocol.CH_RELIABLE, PackedByteArray([1])))

	func _on_connected(peer_id: int) -> void:
		event_log.append("connected")
		connected.append(peer_id)

	func _on_disconnected(peer_id: int) -> void:
		event_log.append("disconnected")
		disconnected.append(peer_id)

	func _on_packet(peer_id: int, bytes: PackedByteArray) -> void:
		event_log.append("packet")
		packets.append([tick, peer_id, bytes])

	func _on_connection_failed() -> void:
		event_log.append("failed")
		failed_count += 1

	func packets_of_type(msg_type: int) -> Array[Array]:
		var result: Array[Array] = []
		for entry: Array in packets:
			var bytes: PackedByteArray = entry[2]
			if bytes[0] == msg_type:
				result.append(entry)
		return result

	func all_early_sends_unavailable() -> bool:
		for result: int in early_sends:
			if result != ERR_UNAVAILABLE:
				return false
		return true


func after_each() -> void:
	for node: NetTransport in _nodes:
		if is_instance_valid(node):
			if node.get_parent() != null:
				node.get_parent().remove_child(node)
			node.free()
	_nodes.clear()
	await wait_process_frames(1)


# --- NetSim -----------------------------------------------------------------------------------

func test_from_arg_parses_the_spec() -> void:
	assert_null(NetSim.from_arg(""), "an empty text does not create a simulator")
	assert_null(NetSim.from_arg("   "), "neither does only whitespace")

	var sim: NetSim = NetSim.from_arg("rtt=120,jitter=20,loss=5,dup=1.5,seed=7")
	if not assert_not_null(sim, "the --net-sim text is parsed"):
		return
	assert_true(sim.is_enabled())
	var text: String = sim.describe()
	assert_true(text.contains("rtt=120"), "describe() includes the rtt: %s" % text)
	assert_true(text.contains("jitter=20"), "describe() includes the jitter: %s" % text)
	assert_true(text.contains("pérdida=5%"), "describe() includes the loss: %s" % text)
	assert_true(text.contains("duplicados=1.5%"), "describe() includes the duplicates: %s" % text)
	assert_true(text.contains("semilla=7"), "describe() includes the seed: %s" % text)

	assert_true(NetSim.from_arg("rtt=120,seed=7", 1).describe().contains("semilla=8"),
			"the seed offset is added")
	assert_true(NetSim.from_arg("rtt=120").describe().contains("semilla=1"),
			"without a seed it is 1")

	var tolerant: NetSim = NetSim.from_arg(" rtt = 100 , bogus=3, jitter=abc, loss ,dup=2 ")
	if assert_not_null(tolerant, "unknown keys and invalid values are ignored"):
		var tolerant_text: String = tolerant.describe()
		assert_true(tolerant_text.contains("rtt=100"), tolerant_text)
		assert_true(tolerant_text.contains("jitter=0"), tolerant_text)
		assert_true(tolerant_text.contains("duplicados=2%"), tolerant_text)

	var idle: NetSim = NetSim.from_arg("seed=3")
	if assert_not_null(idle, "a text without useful parameters still creates the object"):
		assert_false(idle.is_enabled(), "but does nothing")

	var clamped := NetSim.new()
	clamped.configure(-10, -5, 250.0, -3.0, 1)
	assert_true(clamped.is_enabled(), "with loss capped at 100 % quota it stays active")
	assert_true(clamped.describe().contains("pérdida=100%"), clamped.describe())
	assert_true(clamped.describe().contains("rtt=0"), clamped.describe())


func test_same_seed_gives_same_sequence() -> void:
	var spec: String = "rtt=100,jitter=40,loss=20,dup=15,seed=42"
	var first: Array[Array] = _run_sequence(NetSim.from_arg(spec), 600)
	var second: Array[Array] = _run_sequence(NetSim.from_arg(spec), 600)
	assert_false(first.is_empty(), "the sequence is not empty")
	assert_true(first == second, "same seed, same sequence")

	var other_seed: Array[Array] = _run_sequence(
			NetSim.from_arg("rtt=100,jitter=40,loss=20,dup=15,seed=43"), 600)
	assert_false(first == other_seed, "another seed, another sequence")

	# The output and the input of a transport use seed and seed + 1: they must not be the same.
	var output_side: Array[Array] = _run_sequence(NetSim.from_arg(spec, 0), 600)
	var input_side: Array[Array] = _run_sequence(NetSim.from_arg(spec, 1), 600)
	assert_true(output_side == first, "offset 0 is the seed as is")
	assert_false(output_side == input_side, "offset 1 changes the sequence")

	# configure() resets the generator: repeating the configuration repeats the sequence.
	var reused := NetSim.new()
	reused.configure(100, 40, 20.0, 15.0, 42)
	var before: Array[Array] = _run_sequence(reused, 300)
	reused.configure(100, 40, 20.0, 15.0, 42)
	var after: Array[Array] = _run_sequence(reused, 300)
	assert_true(before == after, "configure() with the same seed repeats the sequence")


func test_loss_does_not_touch_reliable_channels() -> void:
	var sim: NetSim = NetSim.from_arg("rtt=60,jitter=20,loss=100,dup=100,seed=5")
	var count: int = 200
	for i: int in count:
		sim.enqueue(_packet(1, NetProtocol.CH_INPUT, i), i)
		sim.enqueue(_packet(1, NetProtocol.CH_SNAPSHOT, i), i)
		sim.enqueue(_packet(1, NetProtocol.CH_RELIABLE, i), i)
		sim.enqueue(_packet(1, NetSim.AUTH_CHANNEL, i, true), i)
	var delivered: Array[NetSim.Packet] = sim.pop_due(count + 100)
	var per_channel: Dictionary = {}
	for packet: NetSim.Packet in delivered:
		var key: String = "auth" if packet.is_auth else str(packet.channel)
		per_channel[key] = int(per_channel.get(key, 0)) + 1
	assert_false(per_channel.has("1"), "with loss=100 no packet arrives on channel 1")
	assert_false(per_channel.has("2"), "with loss=100 no packet arrives on channel 2")
	assert_eq(per_channel.get("3", 0), count, "the reliable channel arrives whole, without duplicates")
	assert_eq(per_channel.get("auth", 0), count, "the authentication arrives whole, without duplicates")
	assert_eq(sim.get_pending_count(), 0, "nothing is left in the queue")

	# With partial loss, the reliable ones stay intact and the others lose roughly that much.
	var partial: NetSim = NetSim.from_arg("rtt=60,jitter=20,loss=50,seed=9")
	var total: int = 2000
	for i: int in total:
		partial.enqueue(_packet(1, NetProtocol.CH_INPUT, i), i)
		partial.enqueue(_packet(1, NetProtocol.CH_RELIABLE, i), i)
	var got_unreliable: int = 0
	var got_reliable: int = 0
	for packet: NetSim.Packet in partial.pop_due(total + 100):
		if packet.channel == NetProtocol.CH_RELIABLE:
			got_reliable += 1
		else:
			got_unreliable += 1
	assert_eq(got_reliable, total, "at 50 % drop rate the reliable channel arrives whole")
	assert_true(got_unreliable > total * 0.4 and got_unreliable < total * 0.6,
			"at 50 %% loss roughly half of the unreliable ones arrive (%d of %d)" % [
				got_unreliable, total,
			])


func test_duplicates_only_on_unreliable_channels() -> void:
	var sim: NetSim = NetSim.from_arg("rtt=30,jitter=10,dup=100,seed=3")
	for i: int in 50:
		sim.enqueue(_packet(1, NetProtocol.CH_INPUT, i), 0)
		sim.enqueue(_packet(1, NetProtocol.CH_RELIABLE, i), 0)
		sim.enqueue(_packet(1, NetSim.AUTH_CHANNEL, i, true), 0)
	var counts: Dictionary = {}
	for packet: NetSim.Packet in sim.pop_due(100):
		var key: String = "auth" if packet.is_auth else str(packet.channel)
		counts[key] = int(counts.get(key, 0)) + 1
	assert_eq(counts.get("1", 0), 100, "with dup=100 each unreliable packet arrives twice")
	assert_eq(counts.get("3", 0), 50, "reliable ones are not duplicated")
	assert_eq(counts.get("auth", 0), 50, "the authentication is not duplicated")


func test_reliable_channels_keep_fifo_order() -> void:
	# With that much jitter the unreliable ones get reordered; the reliable ones do not.
	var sim: NetSim = NetSim.from_arg("rtt=100,jitter=60,seed=11")
	var ticks: int = 300
	var delivered: Array[NetSim.Packet] = []
	for tick: int in ticks + 20:
		if tick < ticks:
			for peer_id: int in [1, 2]:
				sim.enqueue(_packet(peer_id, NetProtocol.CH_RELIABLE, tick), tick)
				sim.enqueue(_packet(peer_id, NetProtocol.CH_INPUT, tick), tick)
				sim.enqueue(_packet(peer_id, NetProtocol.CH_SNAPSHOT, tick), tick)
				sim.enqueue(_packet(peer_id, NetSim.AUTH_CHANNEL, tick, true), tick)
		delivered.append_array(sim.pop_due(tick))
	assert_eq(sim.get_pending_count(), 0, "everything has been delivered")

	var last_seen: Dictionary = {}
	var reordered_unreliable: int = 0
	var reliable_count: int = 0
	for packet: NetSim.Packet in delivered:
		var seq: int = packet.bytes.decode_u32(0)
		var channel_text: String = "auth" if packet.is_auth else str(packet.channel)
		var key: String = "%d/%s" % [packet.peer_id, channel_text]
		var is_fifo: bool = packet.is_auth or not NetProtocol.is_unreliable_channel(packet.channel)
		var previous: int = int(last_seen.get(key, -1))
		if is_fifo:
			reliable_count += 1
			if seq <= previous:
				fail("%s: %d arrived after %d (reliable ones keep the order)" % [
					key, seq, previous,
				])
				return
		elif seq < previous:
			reordered_unreliable += 1
		last_seen[key] = maxi(previous, seq)
	assert_eq(reliable_count, ticks * 2 * 2, "all the reliable ones and the authentication arrive")
	assert_true(reordered_unreliable > 0,
			"the jitter does reorder the unreliable ones (otherwise the test would prove nothing)")


func test_delay_is_within_half_rtt_plus_minus_jitter() -> void:
	# rtt=120, jitter=20: 60 ± 20 ms = 40 to 80 ms = 2.4 to 4.8 ticks = 2 to 5 ticks.
	var low: int = roundi((60.0 - 20.0) / TICK_MS)
	var high: int = roundi((60.0 + 20.0) / TICK_MS)
	assert_eq(low, 2)
	assert_eq(high, 5)
	for channel: int in [NetProtocol.CH_INPUT, NetProtocol.CH_SNAPSHOT, NetProtocol.CH_RELIABLE,
			NetSim.AUTH_CHANNEL]:
		var sim: NetSim = NetSim.from_arg("rtt=120,jitter=20,seed=21")
		var seen: Dictionary = {}
		for i: int in 3000:
			var packet: NetSim.Packet = _packet(1, channel, i, channel == NetSim.AUTH_CHANNEL)
			# One packet at a time and a different send tick: no effect from the FIFO order.
			var now: int = i * 100
			sim.enqueue(packet, now)
			var delay: int = packet.due_tick - now
			seen[delay] = true
			if delay < low or delay > high:
				fail("channel %d: delay %d outside [%d, %d]" % [channel, delay, low, high])
				return
			sim.pop_due(now + 100)
		assert_true(seen.has(low) and seen.has(high),
				"channel %d: the delay covers the whole interval (%s)" % [channel, seen.keys()])

	# Without jitter the delay is fixed: 100 ms of RTT = 50 ms per direction = 3 ticks.
	var fixed: NetSim = NetSim.from_arg("rtt=100,seed=1")
	for i: int in 100:
		var packet: NetSim.Packet = _packet(1, NetProtocol.CH_INPUT, i)
		fixed.enqueue(packet, 10)
		assert_eq(packet.due_tick, 13, "fixed delay of 3 ticks")
		fixed.pop_due(100)

	# A delay that would come out negative stays at 0.
	var clamped: NetSim = NetSim.from_arg("rtt=10,jitter=50,seed=2")
	var longest: int = 0
	for i: int in 500:
		var packet: NetSim.Packet = _packet(1, NetProtocol.CH_SNAPSHOT, i)
		clamped.enqueue(packet, 0)
		longest = maxi(longest, packet.due_tick)
		if packet.due_tick < 0:
			fail("negative delay: %d" % packet.due_tick)
			return
		clamped.pop_due(100)
	assert_eq(longest, roundi(55.0 / TICK_MS), "with rtt=10, jitter=50 the maximum is 55 ms")

	# A simulator at zero delivers on the same tick.
	var idle := NetSim.new()
	idle.configure(0, 0, 0.0, 0.0, 1)
	assert_false(idle.is_enabled())
	var instant: NetSim.Packet = _packet(1, NetProtocol.CH_RELIABLE, 0)
	idle.enqueue(instant, 7)
	assert_eq(instant.due_tick, 7)
	assert_eq(idle.pop_due(7).size(), 1)


func test_max_delay_ticks_matches_the_worst_case_of_one_direction() -> void:
	assert_eq(NetSim.from_arg("rtt=100,jitter=10").get_max_delay_ticks(), 4,
			"rtt/2 + jitter = 60 ms = 3.6 ticks, rounded to 4")
	assert_eq(NetSim.from_arg("rtt=0,jitter=0,loss=5").get_max_delay_ticks(), 0, "no delay")
	assert_eq(NetSim.from_arg("rtt=200").get_max_delay_ticks(), 6, "100 ms = 6 ticks")
	# No sampled delay exceeds the maximum.
	var sim: NetSim = NetSim.from_arg("rtt=120,jitter=40,seed=9")
	for i: int in 200:
		sim.enqueue(NetSim.Packet.new(1, NetProtocol.CH_RELIABLE, PackedByteArray([1]), false), 0)
	for packet: NetSim.Packet in sim.pop_due(1000):
		assert_true(packet.due_tick <= sim.get_max_delay_ticks(), "the delay fits within the maximum")


func test_transport_reports_the_round_trip_its_simulators_add() -> void:
	var transport: NetTransport = _make_transport("NetTransportSimRtt")
	assert_eq(transport.get_sim_round_trip_ticks(), 0, "without a simulator it adds nothing")
	transport.set_net_sim_spec("rtt=100,jitter=10")
	assert_eq(transport.get_sim_round_trip_ticks(), 8, "output + input: 2 × 4 ticks")
	transport.set_net_sim_spec("")
	assert_eq(transport.get_sim_round_trip_ticks(), 0, "it is removed with the empty text")


func test_pop_due_returns_only_due_packets_in_order() -> void:
	var sim: NetSim = NetSim.from_arg("rtt=100,seed=1")  # 3 ticks per direction, without jitter
	var late: NetSim.Packet = _packet(1, NetProtocol.CH_INPUT, 1)
	var early: NetSim.Packet = _packet(1, NetProtocol.CH_INPUT, 2)
	var tie: NetSim.Packet = _packet(2, NetProtocol.CH_INPUT, 3)
	sim.enqueue(late, 10)    # due at 13
	sim.enqueue(early, 4)    # due at 7
	sim.enqueue(tie, 10)     # due at 13, arrived after late
	assert_eq(sim.get_pending_count(), 3)
	assert_eq(sim.pop_due(6).size(), 0, "nothing is due yet")
	var first: Array[NetSim.Packet] = sim.pop_due(7)
	assert_eq(first.size(), 1)
	assert_true(first[0] == early, "the one that is due earliest comes out first")
	assert_true(sim.has_pending(1) and sim.has_pending(2))
	var rest: Array[NetSim.Packet] = sim.pop_due(50)
	assert_eq(rest.size(), 2)
	assert_true(rest[0] == late and rest[1] == tie, "on equal ticks, in arrival order")
	assert_eq(sim.get_pending_count(), 0)

	# drain_peer() takes out everything of a peer, due or not, and leaves the rest.
	sim.enqueue(_packet(1, NetProtocol.CH_RELIABLE, 4), 0)
	sim.enqueue(_packet(2, NetProtocol.CH_RELIABLE, 5), 0)
	sim.enqueue(_packet(1, NetProtocol.CH_INPUT, 6), 1)
	var drained: Array[NetSim.Packet] = sim.drain_peer(1)
	assert_eq(drained.size(), 2)
	assert_eq(drained[0].bytes.decode_u32(0), 4, "in delivery order")
	assert_false(sim.has_pending(1))
	assert_true(sim.has_pending(2))
	assert_eq(sim.get_pending_count(), 1)


# --- NetTransport: real ENet on 127.0.0.1 -----------------------------------------------------

func test_transport_registers_its_own_multiplayer() -> void:
	var transport: NetTransport = _make_transport("NetTransportRegistered")
	var custom: MultiplayerAPI = tree.get_multiplayer(transport.get_path())
	assert_not_null(custom, "the transport registers its SceneMultiplayer")
	assert_true(custom is SceneMultiplayer, "it is a SceneMultiplayer")
	assert_true(custom != tree.get_multiplayer(), "different from the tree's default multiplayer")
	assert_false(tree.multiplayer_poll, "the tree does not poll: NetTransport.poll() does")
	var other: NetTransport = _make_transport("NetTransportOther")
	assert_true(tree.get_multiplayer(other.get_path()) != custom, "each instance has its own")

	var path: NodePath = transport.get_path()
	_nodes.erase(transport)
	transport.get_parent().remove_child(transport)
	assert_true(tree.get_multiplayer(path) == tree.get_multiplayer(),
			"the registration is removed when leaving the tree")
	transport.free()


func test_send_validates_before_touching_enet() -> void:
	var server: Endpoint = Endpoint.new(_make_transport("NetTransportValidate"))
	assert_eq(server.transport.send(5, NetProtocol.CH_RELIABLE, PackedByteArray([1])),
			ERR_UNCONFIGURED, "without host() or connect_to() nothing is configured")
	assert_eq(server.transport.send_auth(5, HELLO), ERR_UNCONFIGURED)
	assert_eq(server.transport.complete_auth(5), ERR_UNCONFIGURED)
	assert_eq(server.transport.get_rtt_ms(5), 0.0)
	assert_eq(server.transport.get_remote_address(5), "")
	var port: int = _find_free_port()
	if not assert_true(port > 0, "there is a free port"):
		return
	assert_eq(server.transport.host(port, 4), OK)
	assert_true(server.transport.is_server())
	assert_eq(server.transport.host(port + 1, 4), ERR_ALREADY_IN_USE, "it cannot be opened twice")
	assert_eq(server.transport.connect_to("127.0.0.1", port), ERR_ALREADY_IN_USE)
	assert_eq(server.transport.send(123456, NetProtocol.CH_RELIABLE, PackedByteArray([1])),
			ERR_UNAVAILABLE, "nothing is sent to an unknown peer")
	assert_eq(server.transport.send_auth(123456, HELLO), ERR_UNAVAILABLE)
	assert_eq(server.transport.complete_auth(123456), ERR_UNAVAILABLE)
	assert_eq(server.transport.get_remote_address(123456), "")
	server.transport.disconnect_after_flush(123456)  # an unknown peer does nothing
	server.transport.close()
	assert_false(server.transport.is_server(), "after close() it is no longer a server")
	assert_eq(server.transport.send(5, NetProtocol.CH_RELIABLE, PackedByteArray([1])),
			ERR_UNCONFIGURED)


func test_handshake_and_one_packet_per_channel() -> void:
	var pair: Array[Endpoint] = _make_pair()
	var server: Endpoint = pair[0]
	var client: Endpoint = pair[1]
	var connected: bool = await _run_until(pair, func() -> bool:
		return not server.connected.is_empty() and not client.connected.is_empty(),
			MAX_HANDSHAKE_TICKS)
	if not assert_true(connected, "the handshake finishes"):
		return
	var client_id: int = server.connected[0]
	assert_eq(server.authenticating, [client_id], "peer_authenticating of the client on the server")
	assert_eq(client.authenticating, [1], "peer_authenticating of the server (peer 1) on the client")
	assert_eq(client.connected, [1], "the client sees peer 1 as connected")
	assert_eq(server.auth_messages, [HELLO], "the server receives the HELLO")
	assert_eq(client.auth_messages, [WELCOME], "the client receives the WELCOME")
	assert_true(server.all_early_sends_unavailable(),
			"before peer_connected send() returns ERR_UNAVAILABLE (without an engine error)")
	assert_true(client.all_early_sends_unavailable(),
			"even right after complete_auth() send() returns ERR_UNAVAILABLE")
	assert_false(server.early_sends.is_empty() or client.early_sends.is_empty(),
			"the checks above were indeed performed")

	# One packet per channel and direction, with the exact content.
	var up_unreliable: PackedByteArray = _message(TYPE_UP_UNRELIABLE, 1, 0)
	var up_reliable: PackedByteArray = _message(TYPE_UP_RELIABLE, 2, 0)
	var down_unreliable: PackedByteArray = _message(TYPE_DOWN_UNRELIABLE, 3, 0)
	var down_reliable: PackedByteArray = _message(TYPE_DOWN_RELIABLE, 4, 0)
	assert_eq(client.transport.send(1, NetProtocol.channel_for_type(TYPE_UP_UNRELIABLE),
			up_unreliable), OK)
	assert_eq(client.transport.send(1, NetProtocol.channel_for_type(TYPE_UP_RELIABLE),
			up_reliable), OK)
	assert_eq(server.transport.send(client_id, NetProtocol.channel_for_type(TYPE_DOWN_UNRELIABLE),
			down_unreliable), OK)
	assert_eq(server.transport.send(client_id, NetProtocol.channel_for_type(TYPE_DOWN_RELIABLE),
			down_reliable), OK)
	var arrived: bool = await _run_until(pair, func() -> bool:
		return server.packets.size() >= 2 and client.packets.size() >= 2, 60)
	if not assert_true(arrived, "the four packets arrive"):
		return
	assert_eq(server.packets.size(), 2)
	assert_eq(client.packets.size(), 2)
	var server_got: Array[Array] = server.packets_of_type(TYPE_UP_UNRELIABLE)
	assert_eq(server_got.size(), 1, "the server receives the packet on the inputs channel")
	assert_eq(server_got[0][1], client_id, "with the client's id")
	assert_eq(server_got[0][2], up_unreliable, "with the content intact")
	assert_eq(server.packets_of_type(TYPE_UP_RELIABLE)[0][2], up_reliable,
			"the server receives the reliable packet")
	assert_eq(client.packets_of_type(TYPE_DOWN_UNRELIABLE)[0][2], down_unreliable,
			"the client receives the snapshot")
	assert_eq(client.packets_of_type(TYPE_DOWN_RELIABLE)[0][1], 1, "from peer 1")
	assert_eq(client.packets_of_type(TYPE_DOWN_RELIABLE)[0][2], down_reliable,
			"the client receives the reliable packet")

	# Peer data and counters.
	assert_eq(server.transport.get_remote_address(client_id), "127.0.0.1")
	assert_eq(client.transport.get_remote_address(1), "127.0.0.1")
	assert_true(server.transport.get_rtt_ms(client_id) >= 0.0)
	assert_true(server.transport.get_packet_loss(client_id) >= 0.0
			and server.transport.get_packet_loss(client_id) <= 1.0)
	var server_counters: Dictionary = server.transport.get_byte_counters()
	var client_counters: Dictionary = client.transport.get_byte_counters()
	var client_sent: int = HELLO.size() + up_unreliable.size() + up_reliable.size()
	var server_sent: int = WELCOME.size() + down_unreliable.size() + down_reliable.size()
	assert_eq(client_counters["app_out"], client_sent, "application bytes of the client")
	assert_eq(server_counters["app_in"], client_sent, "and received by the server")
	assert_eq(server_counters["app_out"], server_sent, "bytes sent by the server")
	assert_eq(client_counters["app_in"], server_sent, "and received by the client")
	for counters: Dictionary in [server_counters, client_counters]:
		assert_true(int(counters["wire_in"]) > 0 and int(counters["wire_out"]) > 0,
				"ENet counts bytes on the wire: %s" % [counters])
		assert_true(int(counters["wire_out"]) >= int(counters["app_out"]),
				"on the wire there is at least what the application sent: %s" % [counters])

	# The client says goodbye: the server notices and stops sending to it.
	client.transport.close()
	var left: bool = await _run_until(pair, func() -> bool:
		return not server.disconnected.is_empty(), 120)
	assert_true(left, "the server notices that the client has left")
	assert_eq(server.disconnected, [client_id])
	assert_eq(server.transport.send(client_id, NetProtocol.CH_RELIABLE, PackedByteArray([1])),
			ERR_UNAVAILABLE, "nothing is sent to a disconnected peer")
	assert_eq(client.disconnected.size(), 0, "close() emits no signals in whoever closes")
	assert_eq(client.failed_count, 0)


func test_send_rejects_invalid_packets() -> void:
	var pair: Array[Endpoint] = _make_pair()
	var server: Endpoint = pair[0]
	var client: Endpoint = pair[1]
	var connected: bool = await _run_until(pair, func() -> bool:
		return not client.connected.is_empty(), MAX_HANDSHAKE_TICKS)
	if not assert_true(connected, "the handshake finishes"):
		return
	var transport: NetTransport = client.transport
	assert_eq(transport.send(1, 0, PackedByteArray([1])), ERR_INVALID_PARAMETER,
			"channel 0 does not exist")
	assert_eq(transport.send(1, NetProtocol.CUSTOM_CHANNELS + 1, PackedByteArray([1])),
			ERR_INVALID_PARAMETER, "neither does channel 4")
	assert_eq(transport.send(1, NetProtocol.CH_RELIABLE, PackedByteArray()), ERR_INVALID_PARAMETER,
			"an empty packet is not sent")
	var too_big := PackedByteArray()
	too_big.resize(NetProtocol.MAX_PACKET_BYTES + 1)
	too_big[0] = TYPE_UP_UNRELIABLE
	assert_eq(transport.send(1, NetProtocol.CH_INPUT, too_big), ERR_PARAMETER_RANGE_ERROR,
			"an unreliable packet of more than 1200 B is rejected")
	too_big.resize(NetProtocol.MAX_PACKET_BYTES)
	assert_eq(transport.send(1, NetProtocol.CH_INPUT, too_big), OK, "one of exactly 1200 B is not")
	assert_eq(transport.send_auth(1, HELLO), ERR_UNAVAILABLE,
			"once connected, authentication is no longer sent")
	assert_eq(server.packets.size(), 0)


func test_reject_flushes_before_disconnect() -> void:
	await _check_reject("", "")


func test_reject_flushes_before_disconnect_with_net_sim() -> void:
	# With delay, the REJECT is in the simulator queue when the disconnect is requested: it has to go out.
	await _check_reject("rtt=200,jitter=30,seed=3", "")


func test_connection_failed_waits_for_the_delayed_reject() -> void:
	# With the simulator on the client, the REJECT arrives late, but the disconnect is already done: the
	# connection_failed signal waits for the REJECT to be delivered.
	await _check_reject("", "rtt=300,jitter=40,seed=6")


func test_disconnect_after_flush_delivers_pending_packets() -> void:
	var pair: Array[Endpoint] = _make_pair("", "rtt=120,jitter=20,seed=4")
	var server: Endpoint = pair[0]
	var client: Endpoint = pair[1]
	var connected: bool = await _run_until(pair, func() -> bool:
		return not server.connected.is_empty() and not client.connected.is_empty(),
			MAX_HANDSHAKE_TICKS)
	if not assert_true(connected, "the handshake finishes"):
		return
	var client_id: int = server.connected[0]
	var notice: PackedByteArray = PackedByteArray([
		NetProtocol.MSG_NOTICE, NetProtocol.NoticeCode.KICK, 9,
	])
	assert_eq(server.transport.send(client_id, NetProtocol.CH_RELIABLE, notice), OK)
	# The simulator (on the server) holds it for a few ticks; the disconnect requested now must not lose it.
	server.transport.disconnect_after_flush(client_id)
	assert_eq(server.transport.send(client_id, NetProtocol.CH_RELIABLE, notice), ERR_UNAVAILABLE,
			"after requesting the disconnect nothing is sent to that peer")
	var done: bool = await _run_until(pair, func() -> bool:
		return not client.disconnected.is_empty() and not server.disconnected.is_empty(), 300)
	if not assert_true(done, "both sides notice the disconnect"):
		return
	assert_eq(client.packets_of_type(NetProtocol.MSG_NOTICE).size(), 1,
			"the NOTICE arrives before the disconnect")
	assert_eq(client.packets_of_type(NetProtocol.MSG_NOTICE)[0][2], notice)
	assert_eq(client.disconnected, [1])
	assert_eq(server.disconnected, [client_id])
	assert_eq(client.failed_count, 0, "it had connected: it is not a connection failure")


func test_disconnect_waits_for_delayed_packets() -> void:
	# The server's input simulator delays the goodbye packet; the client requests the orderly disconnect
	# right after sending it. The server has to receive the packet before learning about the
	# disconnect.
	var pair: Array[Endpoint] = _make_pair("", "rtt=200,jitter=20,seed=2")
	var server: Endpoint = pair[0]
	var client: Endpoint = pair[1]
	var connected: bool = await _run_until(pair, func() -> bool:
		return not server.connected.is_empty() and not client.connected.is_empty(),
			MAX_HANDSHAKE_TICKS)
	if not assert_true(connected, "the handshake finishes"):
		return
	var client_id: int = server.connected[0]
	var leave: PackedByteArray = PackedByteArray([NetProtocol.MSG_CLIENT_LEAVE, 0])
	assert_eq(client.transport.send(1, NetProtocol.CH_RELIABLE, leave), OK)
	client.transport.disconnect_after_flush(1)
	var done: bool = await _run_until(pair, func() -> bool:
		return not server.disconnected.is_empty(), 300)
	if not assert_true(done, "the server ends up learning about the disconnect"):
		return
	assert_eq(server.packets_of_type(NetProtocol.MSG_CLIENT_LEAVE).size(), 1,
			"it receives the goodbye packet")
	assert_eq(server.disconnected, [client_id])
	var log: Array[String] = server.event_log
	assert_eq(log.slice(log.size() - 2), ["packet", "disconnected"],
			"first the packet, then the disconnect: %s" % [log])


func test_connect_to_closed_port_fails() -> void:
	var port: int = _find_free_port()
	if not assert_true(port > 0, "there is a free port"):
		return
	var client: Endpoint = Endpoint.new(_make_transport("NetTransportLonely"))
	assert_eq(client.transport.connect_to("127.0.0.1", port, 250), OK)
	var one: Array[Endpoint] = [client]
	var failed: bool = await _run_until(one, func() -> bool:
		return client.failed_count > 0, 300)
	assert_true(failed, "without a server, the connection fails")
	await _run_ticks(one, 20)
	assert_eq(client.failed_count, 1, "connection_failed is emitted only once")
	assert_true(client.authenticating.is_empty())
	assert_eq(client.connected.size(), 0)
	# After the failure you can try again without calling close() first.
	assert_eq(client.transport.connect_to("127.0.0.1", port, 250), OK, "it can be retried")
	client.transport.close()


## connect_to promises to report that there is no server "at most at double" connect_timeout_ms.
## ENet only checks the deadline when a CONNECT retransmission expires (at 0.5, 1.5, 3.5 and 7.5 s)
## and with a maximum of double it took 3.5 s for 1000 ms and 7.5 s for 3000 ms (finding S7).
func test_connect_timeout_is_at_most_double_the_requested_one() -> void:
	var port: int = _find_free_port()
	if not assert_true(port > 0, "there is a free port"):
		return
	for timeout_ms: int in [1000, 3000]:
		var client: Endpoint = Endpoint.new(_make_transport("NetTransportTimeout%d" % timeout_ms))
		assert_eq(client.transport.connect_to("127.0.0.1", port, timeout_ms), OK)
		var one: Array[Endpoint] = [client]
		var limit_ticks: int = 2 * timeout_ms * 60 / 1000 + 10
		var failed: bool = await _run_until(one, func() -> bool:
			return client.failed_count > 0, limit_ticks)
		assert_true(failed, "with %d ms, connection_failed arrives in fewer than %d ticks (%d ms)"
				% [timeout_ms, limit_ticks, limit_ticks * 1000 / 60])
		client.transport.close()


# --- Packets foreign to the protocol (finding S1) ---------------------------------------------

## A raw ENet server and client, without [SceneMultiplayer], connected at the ENet level.
func _make_attacker(server: Endpoint) -> RawEnetAttacker:
	var attacker := RawEnetAttacker.new()
	assert_eq(attacker.connect_to(_port), OK, "the attacker connects")
	var both: Array[Endpoint] = [server]
	var connected: bool = await _run_until(both, func() -> bool:
		attacker.poll()
		return attacker.is_connected_to_server() and not server.authenticating.is_empty(), 300)
	assert_true(connected, "the server sees the attacker authenticating")
	return attacker


## Authenticates the attacker against the [Endpoint] server (which replies WELCOME and confirms):
## HELLO, WELCOME and the two confirmations.
func _authenticate(server: Endpoint, attacker: RawEnetAttacker) -> bool:
	attacker.send_auth(HELLO)
	attacker.flush()
	var both: Array[Endpoint] = [server]
	var welcomed: bool = await _run_until(both, func() -> bool:
		attacker.poll()
		return attacker.server_confirmed and not attacker.auth_messages.is_empty(), 300)
	if not assert_true(welcomed, "the WELCOME and the server's confirmation arrive"):
		return false
	attacker.send_confirmation()
	attacker.flush()
	var admitted: bool = await _run_until(both, func() -> bool:
		attacker.poll()
		return not server.connected.is_empty(), 300)
	assert_true(admitted, "the server admits the attacker")
	return admitted


## Before the HELLO, SceneMultiplayer only admits authentication messages: anything else logged an
## engine error per packet (the runner fails on any engine error, so this test already checks it)
## and did not go through any limiter. Now the transport discards it and counts it.
func test_foreign_packets_before_the_hello_are_discarded_and_counted() -> void:
	var server: Endpoint = _make_server()
	var attacker: RawEnetAttacker = await _make_attacker(server)
	for i: int in 200:
		attacker.send(PackedByteArray([3, 1]), 1)
	for i: int in 20:
		# RPC, SIMPLIFY_PATH, SPAWN and system commands that are not authentication.
		attacker.send(PackedByteArray([0, 1, 2, 3, 4, 5]), 0)
		attacker.send(PackedByteArray([1, 9, 9, 9, 9, 9, 9, 9, 9, 9]), 0)
		attacker.send(PackedByteArray([4, 1, 2, 3, 4, 5, 6, 7]), 0)
		attacker.send(PackedByteArray([7, 1, 2, 0, 0, 0]), 0)
	attacker.send(PackedByteArray([]), 0)
	attacker.flush()
	var both: Array[Endpoint] = [server]
	var all_seen: bool = await _run_until(both, func() -> bool:
		attacker.poll()
		return server.discarded >= 280, 300)
	assert_true(all_seen, "all 280 packets are discarded (%d)" % server.discarded)
	assert_eq(server.discarded, 280, "and counted exactly")
	assert_true(server.packets.is_empty(), "none reaches the application")
	assert_true(server.auth_messages.is_empty(), "nor counts as authentication")
	assert_eq(server.authenticating.size(), 1, "the peer is still authenticating")
	assert_true(server.connected.is_empty(), "not admitted")
	attacker.close()


## Once authenticated, only application packets (RAW) are admitted: the rest is discarded and counted,
## and the real RAW ones keep reaching the application.
func test_foreign_packets_after_the_handshake_are_discarded_but_app_packets_pass() -> void:
	var server: Endpoint = _make_server()
	var attacker: RawEnetAttacker = await _make_attacker(server)
	if not await _authenticate(server, attacker):
		return
	assert_eq(server.discarded, 0, "up to here, nothing discarded")
	for i: int in 50:
		attacker.send(PackedByteArray([1, 0, 0, 0, 0, 0, 0, 0, 0, 0]), 0)  # SIMPLIFY_PATH
		attacker.send(PackedByteArray([0, 1, 2, 3, 4, 5, 6]), 0)  # RPC
		attacker.send(PackedByteArray([4, 1, 2, 3, 4, 5, 6, 7, 8]), 0)  # SPAWN
		attacker.send(PackedByteArray([7, 1, 2, 0, 0, 0]), 0)  # SYS ADD_PEER
		attacker.send(PackedByteArray([7, 0, 9, 9]), 0)  # another authentication
		attacker.send(PackedByteArray([7, 0]), 0)  # and another confirmation
	for i: int in 3:
		attacker.send_app(PackedByteArray([TYPE_UP_RELIABLE, i]), NetProtocol.CH_RELIABLE)
	attacker.flush()
	var both: Array[Endpoint] = [server]
	var done: bool = await _run_until(both, func() -> bool:
		attacker.poll()
		return server.discarded >= 300 and server.packets_of_type(TYPE_UP_RELIABLE).size() >= 3, 300)
	assert_true(done, "300 are discarded and the 3 application ones arrive (%d, %d)"
			% [server.discarded, server.packets_of_type(TYPE_UP_RELIABLE).size()])
	assert_eq(server.discarded, 300, "they are counted exactly")
	assert_eq(server.packets.size(), 3, "and only the RAW ones reach the application")
	assert_eq(server.disconnected.size(), 0, "the transport does not disconnect on its own")
	attacker.close()


## The confirmation and an application packet may arrive in the same poll if the server lags: the
## packet is not foreign and must not be lost or discarded (SceneMultiplayer processes them in
## order and admits the peer with the confirmation).
func test_a_packet_that_arrives_with_the_confirmation_is_delivered() -> void:
	var server: Endpoint = _make_server()
	var attacker: RawEnetAttacker = await _make_attacker(server)
	attacker.send_auth(HELLO)
	attacker.flush()
	var both: Array[Endpoint] = [server]
	var welcomed: bool = await _run_until(both, func() -> bool:
		attacker.poll()
		return attacker.server_confirmed and not attacker.auth_messages.is_empty(), 300)
	if not assert_true(welcomed, "the WELCOME and the server's confirmation arrive"):
		return
	# Confirmation and application packet in the same datagram.
	attacker.send_confirmation()
	attacker.send_app(PackedByteArray([TYPE_UP_RELIABLE, 77]), NetProtocol.CH_RELIABLE)
	attacker.flush()
	var delivered: bool = await _run_until(both, func() -> bool:
		attacker.poll()
		return not server.packets_of_type(TYPE_UP_RELIABLE).is_empty(), 300)
	assert_true(delivered, "the packet reaches the application")
	assert_eq(server.discarded, 0, "and is not counted as foreign")
	assert_eq(server.connected.size(), 1, "with the peer admitted")
	attacker.close()


## The authentication messages of a peer that is not yet admitted are bounded: a HELLO (and the
## confirmation) and little else.
func test_auth_messages_from_a_pending_peer_are_bounded() -> void:
	var server: Endpoint = _make_server()
	server.respond_to_auth = false
	var attacker: RawEnetAttacker = await _make_attacker(server)
	for i: int in 30:
		attacker.send_auth(HELLO)
	var huge := PackedByteArray()
	huge.resize(GuardedEnetPeer.MAX_AUTH_BYTES + 1)
	attacker.send_auth(huge)
	for i: int in 10:
		attacker.send_confirmation()
	attacker.flush()
	var both: Array[Endpoint] = [server]
	var done: bool = await _run_until(both, func() -> bool:
		attacker.poll()
		return server.discarded >= 27 + 1 + 9, 300)
	assert_true(done, "the extra HELLOs, the huge one and the repeated confirmations are discarded (%d)"
			% server.discarded)
	assert_eq(server.auth_messages.size(), GuardedEnetPeer.MAX_AUTH_PAYLOADS,
			"MAX_AUTH_PAYLOADS authentication messages arrive")
	attacker.close()


## A peer the server is already disconnecting (disconnect_after_flush) is discarded without counting
## it: no more warnings should be added to it nor should what it keeps sending be processed.
func test_packets_from_a_peer_being_cut_are_dropped_without_counting() -> void:
	var server: Endpoint = _make_server()
	var attacker: RawEnetAttacker = await _make_attacker(server)
	for i: int in 10:
		attacker.send(PackedByteArray([3, 1]), 1)
	attacker.flush()
	var both: Array[Endpoint] = [server]
	var counted: bool = await _run_until(both, func() -> bool:
		attacker.poll()
		return server.discarded >= 10, 300)
	assert_true(counted, "the first 10 are counted")
	server.transport.disconnect_after_flush(server.authenticating[0])
	for i: int in 100:
		attacker.send(PackedByteArray([3, 1]), 1)
	attacker.flush()
	await _run_ticks(both, 10, func(_t: int) -> void: attacker.poll())
	assert_eq(server.discarded, 10, "what it sends after the disconnect starts is not counted")
	attacker.close()


func test_net_sim_delays_packets_by_the_expected_ticks() -> void:
	# Baseline without a simulator: how long a packet takes through the test loop itself.
	var base: Dictionary = await _measure_latencies("", 60)
	var base_max: int = 0
	for key: String in LATENCY_KEYS:
		if not assert_eq(base[key].size(), 60, "without a simulator, %s: all 60 packets arrive" % key):
			return
		for latency: int in base[key]:
			if latency < 1 or latency > 2:
				fail("without a simulator, %s takes %d ticks (1 or 2 expected)" % [key, latency])
				return
			base_max = maxi(base_max, latency)

	# rtt=100 without jitter only on the client: 50 ms per direction = exactly 3 ticks, in both
	# directions and on both channel types.
	var fixed: Dictionary = await _measure_latencies("rtt=100,seed=1", 60)
	for key: String in LATENCY_KEYS:
		var latencies: Array = fixed[key]
		if not assert_eq(latencies.size(), 60, "%s: all 60 packets arrive" % key):
			return
		for latency: int in latencies:
			if latency < 3 + 1 or latency > 3 + base_max:
				fail("%s: %d ticks, 3 plus the loop's were expected (%d to %d)" % [
					key, latency, 3 + 1, 3 + base_max,
				])
				return

	# rtt=100 jitter=20: 30 to 70 ms = 1.8 to 4.2 ticks = 2 to 4 ticks per direction.
	var jittery: Dictionary = await _measure_latencies("rtt=100,jitter=20,seed=8", 120)
	var observed: Dictionary = {}
	for key: String in LATENCY_KEYS:
		var latencies: Array = jittery[key]
		if not assert_eq(latencies.size(), 120, "%s: all 120 packets arrive" % key):
			return
		for latency: int in latencies:
			observed[latency] = true
			if latency < 2 + 1 or latency > 4 + base_max:
				fail("%s: %d ticks, %d to %d were expected" % [key, latency, 2 + 1, 4 + base_max])
				return
	assert_true(observed.size() >= 3, "the jitter shows: observed latencies %s" % [observed.keys()])

	# Reliable ones arrive in the order they were sent even though the jitter delays each one differently.
	assert_true(_is_sorted(jittery["up_reliable_seq"]), "reliable ones toward the server, in order")
	assert_true(_is_sorted(jittery["down_reliable_seq"]), "reliable ones toward the client, in order")


func test_net_sim_loss_drops_unreliable_but_not_reliable_packets() -> void:
	# With loss=100 on the client, neither its inputs reach the server nor do snapshots reach it; what
	# is reliable (and the handshake itself, which uses authentication) goes through whole.
	var results: Dictionary = await _measure_latencies("rtt=60,jitter=10,loss=100,seed=2", 40)
	assert_eq(results["up_unreliable"].size(), 0, "the client's inputs are lost")
	assert_eq(results["down_unreliable"].size(), 0, "the snapshots toward the client are lost")
	assert_eq(results["up_reliable"].size(), 40, "the reliable ones toward the server all arrive")
	assert_eq(results["down_reliable"].size(), 40, "the reliable ones toward the client all arrive")
	assert_true(_is_sorted(results["up_reliable_seq"]))
	assert_true(_is_sorted(results["down_reliable_seq"]))


func test_net_sim_on_both_sides_adds_up() -> void:
	# With the simulator on both sides each direction pays twice: the output of one (3 ticks) and
	# the input of the other (3 ticks).
	var both: Dictionary = await _measure_latencies("rtt=100,seed=1", 30, "rtt=100,seed=5")
	for key: String in LATENCY_KEYS:
		var latencies: Array = both[key]
		if not assert_eq(latencies.size(), 30, "%s: all 30 packets arrive" % key):
			return
		for latency: int in latencies:
			if latency < 6 + 1 or latency > 6 + 2:
				fail("%s: %d ticks, 7 to 8 were expected (6 simulated plus the loop)" % [
					key, latency,
				])
				return


func test_disconnect_after_flush_forces_the_cut_after_60_ticks() -> void:
	var pair: Array[Endpoint] = _make_pair()
	var server: Endpoint = pair[0]
	var client: Endpoint = pair[1]
	var connected: bool = await _run_until(pair, func() -> bool:
		return not server.connected.is_empty() and not client.connected.is_empty(),
			MAX_HANDSHAKE_TICKS)
	if not assert_true(connected, "the handshake finishes"):
		return
	var client_id: int = server.connected[0]
	# The client stops servicing the network, so it cannot confirm the orderly disconnect.
	var only_server: Array[Endpoint] = [server]
	var requested_at: int = _tick
	server.transport.disconnect_after_flush(client_id)
	await _run_ticks(only_server, NetTransport.FORCE_DISCONNECT_TICKS - 5)
	assert_true(server.disconnected.is_empty(), "before 60 ticks the disconnect is not yet forced")
	var cut: bool = await _run_until(only_server, func() -> bool:
		return not server.disconnected.is_empty(), 20)
	if not assert_true(cut, "at 60 ticks the server forcibly disconnects"):
		return
	var waited: int = _tick - requested_at
	assert_true(waited >= NetTransport.FORCE_DISCONNECT_TICKS
			and waited <= NetTransport.FORCE_DISCONNECT_TICKS + 2,
			"waited %d ticks (60 were expected)" % waited)
	assert_eq(server.disconnected, [client_id], "and notifies only once")
	await _run_ticks(only_server, 10)
	assert_eq(server.disconnected, [client_id], "even if the engine notifies later, it is not repeated")
	# The client starts servicing the network again and learns of the disconnect.
	var noticed: bool = await _run_until(pair, func() -> bool:
		return not client.disconnected.is_empty(), 120)
	assert_true(noticed, "the client ends up learning")
	assert_eq(client.disconnected, [1])


func test_server_serves_several_clients() -> void:
	var server: Endpoint = _make_server()
	var clients: Array[Endpoint] = []
	for index: int in 3:
		clients.append(_make_client(index))
	var everyone: Array[Endpoint] = [server]
	everyone.append_array(clients)
	var connected: bool = await _run_until(everyone, func() -> bool:
		if server.connected.size() < 3:
			return false
		for client: Endpoint in clients:
			if client.connected.is_empty():
				return false
		return true, MAX_HANDSHAKE_TICKS)
	if not assert_true(connected, "the three clients finish the handshake"):
		return
	assert_eq(server.authenticating.size(), 3)
	var ids: Dictionary = {}
	for peer_id: int in server.connected:
		ids[peer_id] = true
	assert_eq(ids.size(), 3, "each client has a different id")
	assert_eq(server.authenticating_addresses, ["127.0.0.1", "127.0.0.1", "127.0.0.1"],
			"the address is already known during peer_authenticating")

	# The server sends each client a different packet; each client sends its own.
	for index: int in 3:
		var peer_id: int = server.connected[index]
		assert_eq(server.transport.send(peer_id, NetProtocol.CH_RELIABLE,
				_message(TYPE_DOWN_RELIABLE, peer_id, index)), OK)
		assert_eq(server.transport.send(peer_id, NetProtocol.CH_SNAPSHOT,
				_message(TYPE_DOWN_UNRELIABLE, peer_id, index)), OK)
		assert_eq(clients[index].transport.send(1, NetProtocol.CH_INPUT,
				_message(TYPE_UP_UNRELIABLE, index, index)), OK)
	var arrived: bool = await _run_until(everyone, func() -> bool:
		if server.packets.size() < 3:
			return false
		for client: Endpoint in clients:
			if client.packets.size() < 2:
				return false
		return true, 60)
	if not assert_true(arrived, "all the packets arrive"):
		return
	var from_clients: Dictionary = {}
	for entry: Array in server.packets:
		var bytes: PackedByteArray = entry[2]
		from_clients[int(entry[1])] = bytes.decode_u32(1)
	assert_eq(from_clients.size(), 3, "the server hears all three, each with its id")
	for index: int in 3:
		var received: Array[Array] = clients[index].packets
		assert_eq(received.size(), 2, "each client receives its two packets and none belonging to another")
		var expected_id: int = (received[0][2] as PackedByteArray).decode_u32(1)
		assert_true(server.connected.has(expected_id), "with the id of its peer: %d" % expected_id)
		for entry: Array in received:
			assert_eq((entry[2] as PackedByteArray).decode_u32(1), expected_id)

	# Kicking one does not affect the others.
	var kicked_id: int = server.connected[0]
	server.transport.disconnect_after_flush(kicked_id)
	var done: bool = await _run_until(everyone, func() -> bool:
		return not server.disconnected.is_empty() and not clients[0].disconnected.is_empty(), 200)
	assert_true(done, "the kicked client finds out and so does the server")
	assert_eq(server.disconnected, [kicked_id])
	assert_true(clients[1].disconnected.is_empty() and clients[2].disconnected.is_empty(),
			"the others stay connected")
	assert_eq(server.transport.send(server.connected[1], NetProtocol.CH_RELIABLE,
			PackedByteArray([1])), OK, "and they can still be sent to")


# --- Support ----------------------------------------------------------------------------------

func _packet(peer_id: int, channel: int, seq: int, is_auth: bool = false) -> NetSim.Packet:
	var bytes := PackedByteArray()
	bytes.resize(4)
	bytes.encode_u32(0, seq)
	return NetSim.Packet.new(peer_id, channel, bytes, is_auth)


# Feeds in 'count' packets (one per tick, spread across two peers and all channels) and returns
# what comes out: [tick, peer, channel, is_auth, sequence] per delivery.
func _run_sequence(sim: NetSim, count: int) -> Array[Array]:
	var out: Array[Array] = []
	var channels: Array[int] = [
		NetProtocol.CH_INPUT, NetProtocol.CH_SNAPSHOT, NetProtocol.CH_RELIABLE,
		NetSim.AUTH_CHANNEL,
	]
	for tick: int in count + 60:
		if tick < count:
			var channel: int = channels[tick % channels.size()]
			sim.enqueue(_packet(1 + tick % 2, channel, tick, channel == NetSim.AUTH_CHANNEL), tick)
		for packet: NetSim.Packet in sim.pop_due(tick):
			out.append([tick, packet.peer_id, packet.channel, packet.is_auth,
					packet.bytes.decode_u32(0)])
	return out


func _make_transport(node_name: String) -> NetTransport:
	var transport := NetTransport.new()
	transport.name = node_name
	tree.root.add_child(transport)
	_nodes.append(transport)
	return transport


# Server already open on a free port (the port is left in _port).
func _make_server(sim: String = "") -> Endpoint:
	var server := Endpoint.new(_make_transport("NetTransportServer"))
	server.transport.set_net_sim_spec(sim)
	_port = _find_free_port()
	assert_true(_port > 0, "there is a free port")
	assert_eq(server.transport.host(_port, 8), OK, "the server opens port %d" % _port)
	return server


# Client that starts connecting to the server from _make_server().
func _make_client(index: int = 0, sim: String = "") -> Endpoint:
	var client := Endpoint.new(_make_transport("NetTransportClient%d" % index))
	client.transport.set_net_sim_spec(sim)
	assert_eq(client.transport.connect_to("127.0.0.1", _port, 2000), OK)
	return client


# Server and client in the same process, already launched, with an optional simulator on each.
func _make_pair(client_sim: String = "", server_sim: String = "") -> Array[Endpoint]:
	var server: Endpoint = _make_server(server_sim)
	var client: Endpoint = _make_client(0, client_sim)
	var pair: Array[Endpoint] = [server, client]
	return pair


# First free UDP port starting from FIRST_PORT (shifted per process).
func _find_free_port() -> int:
	var start: int = FIRST_PORT + OS.get_process_id() % 40
	for port: int in range(start, start + 200):
		var probe := PacketPeerUDP.new()
		var err: Error = probe.bind(port, "*")
		probe.close()
		if err == OK:
			return port
	return -1


# One tick of the owner's loop: poll everyone, 'hook' (the simulation: here, sending) and flush
# everyone.
func _step(endpoints: Array[Endpoint], hook: Callable = Callable()) -> void:
	await tree.physics_frame
	_tick += 1
	for endpoint: Endpoint in endpoints:
		endpoint.tick = _tick
		endpoint.transport.poll(_tick)
	if hook.is_valid():
		hook.call(_tick)
	for endpoint: Endpoint in endpoints:
		endpoint.transport.flush()


func _run_ticks(endpoints: Array[Endpoint], ticks: int, hook: Callable = Callable()) -> void:
	for _i: int in ticks:
		await _step(endpoints, hook)


# Advances ticks until 'done' is true. Returns false if it does not happen within 'max_ticks'.
func _run_until(endpoints: Array[Endpoint], done: Callable, max_ticks: int,
		hook: Callable = Callable()) -> bool:
	for _i: int in max_ticks:
		await _step(endpoints, hook)
		if done.call():
			return true
	return false


# 9-byte test message: type, sequence (u32) and send tick (u32).
func _message(msg_type: int, seq: int, send_tick: int) -> PackedByteArray:
	var bytes := PackedByteArray()
	bytes.resize(9)
	bytes[0] = msg_type
	bytes.encode_u32(1, seq)
	bytes.encode_u32(5, send_tick)
	return bytes


func _is_sorted(values: Array) -> bool:
	for i: int in range(1, values.size()):
		if int(values[i]) <= int(values[i - 1]):
			return false
	return true


# Establishes a session (with the simulator only on the client), sends 'count' packets per channel
# and direction, one per tick, and returns the latencies (in ticks) and the arrival sequences.
func _measure_latencies(client_sim: String, count: int, server_sim: String = "") -> Dictionary:
	var pair: Array[Endpoint] = _make_pair(client_sim, server_sim)
	var server: Endpoint = pair[0]
	var client: Endpoint = pair[1]
	var connected: bool = await _run_until(pair, func() -> bool:
		return not server.connected.is_empty() and not client.connected.is_empty(),
			MAX_HANDSHAKE_TICKS)
	assert_true(connected, "the handshake finishes (simulators: '%s' and '%s')" % [
		client_sim, server_sim,
	])
	var results: Dictionary = {
		"up_unreliable": [], "up_reliable": [], "down_unreliable": [], "down_reliable": [],
		"up_reliable_seq": [], "down_reliable_seq": [],
	}
	if not connected:
		return results
	var client_id: int = server.connected[0]
	var sent: Array[int] = [0]
	var hook: Callable = func(tick: int) -> void:
		if sent[0] >= count:
			return
		var seq: int = sent[0]
		client.transport.send(1, NetProtocol.channel_for_type(TYPE_UP_UNRELIABLE),
				_message(TYPE_UP_UNRELIABLE, seq, tick))
		client.transport.send(1, NetProtocol.channel_for_type(TYPE_UP_RELIABLE),
				_message(TYPE_UP_RELIABLE, seq, tick))
		server.transport.send(client_id, NetProtocol.channel_for_type(TYPE_DOWN_UNRELIABLE),
				_message(TYPE_DOWN_UNRELIABLE, seq, tick))
		server.transport.send(client_id, NetProtocol.channel_for_type(TYPE_DOWN_RELIABLE),
				_message(TYPE_DOWN_RELIABLE, seq, tick))
		sent[0] += 1
	await _run_ticks(pair, count + 40, hook)
	_collect(results, "up_unreliable", server, TYPE_UP_UNRELIABLE)
	_collect(results, "up_reliable", server, TYPE_UP_RELIABLE)
	_collect(results, "down_unreliable", client, TYPE_DOWN_UNRELIABLE)
	_collect(results, "down_reliable", client, TYPE_DOWN_RELIABLE)
	_dispose(pair)
	return results


# Closes and frees the transports of a pair (to start another in the same test).
func _dispose(endpoints: Array[Endpoint]) -> void:
	for endpoint: Endpoint in endpoints:
		var node: NetTransport = endpoint.transport
		_nodes.erase(node)
		if is_instance_valid(node):
			if node.get_parent() != null:
				node.get_parent().remove_child(node)
			node.free()


func _collect(results: Dictionary, key: String, receiver: Endpoint, msg_type: int) -> void:
	for entry: Array in receiver.packets_of_type(msg_type):
		var bytes: PackedByteArray = entry[2]
		results[key].append(int(entry[0]) - bytes.decode_u32(5))
		if key.ends_with("_reliable"):
			results[key + "_seq"].append(bytes.decode_u32(1))


# Rejection: the server replies REJECT and requests the orderly disconnect; the client has to
# receive the REJECT before the connection closes, and both sides learn of the disconnect.
func _check_reject(server_sim: String, client_sim: String) -> void:
	var pair: Array[Endpoint] = _make_pair(client_sim, server_sim)
	var server: Endpoint = pair[0]
	var client: Endpoint = pair[1]
	server.reject = true
	var done: bool = await _run_until(pair, func() -> bool:
		return client.failed_count > 0 and not server.disconnected.is_empty(), 400)
	if not assert_true(done, "the rejection ends in a disconnect on both sides"):
		return
	await _run_ticks(pair, 20)
	assert_eq(client.auth_messages, [REJECT], "the client receives the REJECT before the disconnect")
	assert_eq(client.failed_count, 1, "and then connection_failed, only once")
	assert_eq(client.event_log, ["authenticating", "auth", "failed"],
			"the REJECT is delivered before connection_failed")
	assert_eq(client.connected.size(), 0, "it never gets to connect")
	assert_eq(server.connected.size(), 0)
	assert_eq(server.authenticating.size(), 1)
	assert_eq(server.disconnected, server.authenticating,
			"the server receives peer_disconnected from the peer that was authenticating")
	assert_true(client.all_early_sends_unavailable())
	assert_true(server.all_early_sends_unavailable())
