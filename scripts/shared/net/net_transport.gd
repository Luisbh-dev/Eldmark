class_name NetTransport
extends Node
## Thin layer over [ENetMultiplayerPeer] and [SceneMultiplayer] (see docs/networking.md, sections 2, 3
## and 13).
##
## It does only three things: connect, authenticate ([method send_auth], [method complete_auth] and
## the [signal peer_authenticating] signal) and move binary packets ([method send] and the
## [signal packet_received] signal). It uses no RPC, [MultiplayerSynchronizer] or
## [MultiplayerSpawner]: prediction, interpolation and rewind need an explicit tick on every piece
## of data.
## [br][br]
## Each instance has its own [SceneMultiplayer], registered in the tree with
## [method SceneTree.set_multiplayer] under the node's path, so several can live in the same
## process (tests and the bot swarm). It must be added to the tree before [method host] or
## [method connect_to]. Since [member SceneTree.multiplayer_poll] is disabled, the owner calls
## [method poll] at the start of its physics tick and [method flush] at the end: receive,
## simulate, send.
## [br][br]
## Rules:
## [br]- All signals are emitted from [method poll], never from inside the engine, so listeners
## can freely call [method send], [method close] or [method host].
## [br]- Nothing is sent to a peer until [signal peer_connected] has been delivered for it (on the
## client, peer 1): before that, [method send] returns [constant ERR_UNAVAILABLE]. Sending right
## after [method complete_auth] would cause an engine error on the server, because the other
## side's "authentication completed" notice arrives in a later packet.
## [br]- Channels: [constant NetProtocol.CH_INPUT] unreliable, [constant NetProtocol.CH_SNAPSHOT]
## unreliable and sequenced, [constant NetProtocol.CH_RELIABLE] reliable.
## [br]- With [method set_net_sim_spec], the [NetSim] delays (and drops or duplicates, if
## unreliable) both outgoing and incoming traffic. Authentication only gets added delay.
## [br]- After [signal connection_failed] or loss of the server, the client can call
## [method connect_to] again (or [method close]).
## [br]- With DTLS ([method host] and [method connect_to] with [TLSOptions], docs/platform.md
## §10.2) the disconnect is always started by the server: see [method disconnect_after_flush].
## [br][br]
## Shared: it does not read the clock. Time is the tick passed to [method poll].

## A peer has connected and is starting authentication: this is the moment to send HELLO (client)
## or wait for it (server). [signal peer_connected] will follow or, on failure,
## [signal peer_disconnected] (server) or [signal connection_failed] (client).
signal peer_authenticating(peer_id: int)
## Authentication message from the other side (after the simulator's delay, if any).
signal auth_received(peer_id: int, bytes: PackedByteArray)
## Authentication completed on both sides: [method send] can now be used.
signal peer_connected(peer_id: int)
## The peer is gone. On the server it is also emitted for a peer that was authenticating and is
## lost (timeout, disconnect, rejection), so that whatever was created in
## [signal peer_authenticating] can be cleaned up. On the client it is emitted when an already
## connected server (peer 1) is lost; if it fails before fully connecting,
## [signal connection_failed] is emitted instead.
signal peer_disconnected(peer_id: int)
## Application packet from the peer, with the full message, untouched.
signal packet_received(peer_id: int, bytes: PackedByteArray)
## The client could not connect or authenticate. If a REJECT arrived earlier through
## [signal auth_received], that is the reason.
signal connection_failed()

## Maximum [SceneMultiplayer] authentication time (seconds), on both sides and counted from the
## connection, not from the HELLO. 10 s since protocol 7 (docs/platform.md §5.2): it leaves room
## for the ticket claim, which the zone cuts off at 7 s with a REJECT that always arrives in time.
const AUTH_TIMEOUT_SECONDS: float = 10.0
## Ticks given to [method disconnect_after_flush] before forcing the disconnect.
const FORCE_DISCONNECT_TICKS: int = 60
## ENet timeouts after connecting: a disconnection is detected in 3-8 s.
const TIMEOUT_LIMIT: int = 32
const TIMEOUT_MIN_MS: int = 3000
const TIMEOUT_MAX_MS: int = 8000
## ENet throttling disabled (deceleration 0). ENet drops unreliable packets when the RTT rises, and
## inputs and snapshots must not be lost because of that: bandwidth is already limited by the
## server (snapshot budget) and loss is simulated by [NetSim].
const THROTTLE_INTERVAL_MS: int = 5000
const THROTTLE_ACCELERATION: int = 32
const THROTTLE_DECELERATION: int = 0
## Ticks between two reads of the ENet statistics (the ENet counter is 32-bit).
const WIRE_SAMPLE_TICKS: int = 60
## Id of the server as seen from the client.
const SERVER_PEER_ID: int = 1
## Environment variable that makes a client start the disconnect (CI canary of the engine crash, see disconnect_after_flush).
const ENV_CLIENT_STARTS_DISCONNECT: String = "ELDMARK_CLIENT_STARTS_DISCONNECT"
## Scale of [constant ENetPacketPeer.PEER_PACKET_LOSS] (ENET_PEER_PACKET_LOSS_SCALE).
const PACKET_LOSS_SCALE: float = 65536.0

## Packets from a peer that were discarded without being delivered because they do not belong to
## the protocol (see [GuardedEnetPeer]): before the HELLO, anything that is not authentication;
## afterwards, anything that is not an application packet. Server only. Normally the owner adds a
## warning for each one.
signal packets_discarded(peer_id: int, count: int)

# Event types pending delivery to listeners.
const _EVENT_AUTHENTICATING: int = 0
const _EVENT_AUTH: int = 1
const _EVENT_CONNECTED: int = 2
const _EVENT_DISCONNECTED: int = 3
const _EVENT_PACKET: int = 4
const _EVENT_CONNECTION_FAILED: int = 5
const _EVENT_DISCARDED: int = 6


# Event the engine produced inside poll() and that is delivered when it finishes.
class _Event:
	var kind: int = 0
	var peer_id: int = 0
	var bytes: PackedByteArray = PackedByteArray()
	## Only in _EVENT_DISCARDED: how many packets.
	var count: int = 0

	func _init(p_kind: int, p_peer_id: int = 0,
			p_bytes: PackedByteArray = PackedByteArray()) -> void:
		kind = p_kind
		peer_id = p_peer_id
		bytes = p_bytes


var _mp: SceneMultiplayer = null
var _enet: ENetMultiplayerPeer = null
# Packet filter between ENet and SceneMultiplayer (server only; null on the client).
var _guard: GuardedEnetPeer = null
var _is_server: bool = false
# The connection goes over DTLS (host or connect_to with TLSOptions).
var _dtls: bool = false
# Test hook (ENV_CLIENT_STARTS_DISCONNECT): the client starts the disconnect, as it did before.
var _client_starts_disconnect: bool = false
var _now_tick: int = 0
# Increases on every close(): stops event delivery if a listener closes the transport.
var _epoch: int = 0
var _sim_spec: String = ""
var _out_sim: NetSim = null
var _in_sim: NetSim = null
# Peers by id. _authenticating: authenticating. _mp_connected: SceneMultiplayer considers them
# connected. _connected: additionally peer_connected has been delivered (only these are sent to).
# _closing: with a pending disconnect (peer_id -> deadline tick).
var _authenticating: Dictionary = {}
var _mp_connected: Dictionary = {}
var _connected: Dictionary = {}
var _closing: Dictionary = {}
# Peers for which complete_auth() has already been called (afterwards they no longer accept
# send_auth()).
var _local_auth_done: Dictionary = {}
var _events: Array[_Event] = []
# Disconnections waiting for the peer's delayed packets to go out.
var _parked: Array[_Event] = []
var _client_connected: bool = false
var _client_failed: bool = false
var _app_in: int = 0
var _app_out: int = 0
var _wire_in: int = 0
var _wire_out: int = 0
var _last_wire_sample_tick: int = 0


func _enter_tree() -> void:
	_client_starts_disconnect = OS.get_environment(ENV_CLIENT_STARTS_DISCONNECT) == "1"
	_mp = SceneMultiplayer.new()
	_mp.server_relay = false
	_mp.allow_object_decoding = false
	_mp.auth_timeout = AUTH_TIMEOUT_SECONDS
	_mp.auth_callback = _on_auth_callback
	_mp.peer_authenticating.connect(_on_peer_authenticating)
	_mp.peer_authentication_failed.connect(_on_peer_authentication_failed)
	_mp.peer_connected.connect(_on_mp_peer_connected)
	_mp.peer_disconnected.connect(_on_mp_peer_disconnected)
	_mp.peer_packet.connect(_on_peer_packet)
	_mp.connection_failed.connect(_on_mp_connection_failed)
	_mp.server_disconnected.connect(_on_mp_server_disconnected)
	var tree: SceneTree = get_tree()
	# poll() calls SceneMultiplayer.poll() by hand: the tree must not do it as well.
	tree.multiplayer_poll = false
	tree.set_multiplayer(_mp, get_path())


func _exit_tree() -> void:
	close()
	var tree: SceneTree = get_tree()
	if tree != null:
		tree.set_multiplayer(null, get_path())
	_mp = null


## Configures the network simulator from the [code]--net-sim[/code] text (see
## [method NetSim.from_arg]). Empty = no simulator. It is applied to outgoing traffic (seed
## [code]seed[/code]) and incoming traffic ([code]seed + 1[/code]). It must be called before
## [method host] or [method connect_to]; if called afterwards, whatever the simulator had queued is
## discarded.
func set_net_sim_spec(spec: String) -> void:
	_sim_spec = spec
	_create_sims()


## Opens an ENet server on [param port] for [param max_peers] peers. The transport must be in the
## tree. If the port is busy it returns an error (and the engine logs it).
## [br][br]With [param dtls] ([method TLSOptions.server] with the zone's key and certificate) all
## traffic goes over DTLS (docs/platform.md §10.2): [method ENetConnection.dtls_server_setup] is
## called right after [method ENetMultiplayerPeer.create_server] and before wrapping it in
## [GuardedEnetPeer], which filters the already decrypted traffic the same way. Without it,
## plaintext, as always.
func host(port: int, max_peers: int, dtls: TLSOptions = null) -> Error:
	if _mp == null:
		return ERR_UNCONFIGURED
	if _is_active():
		return ERR_ALREADY_IN_USE
	var peer := ENetMultiplayerPeer.new()
	var err: Error = peer.create_server(port, max_peers, NetProtocol.CUSTOM_CHANNELS)
	if err != OK:
		return err
	if dtls != null:
		err = peer.host.dtls_server_setup(dtls)
		if err != OK:
			peer.close()
			return err
	_attach(peer, true)
	_dtls = dtls != null
	return OK


## Starts connecting to the server at [param address]:[param port]. The result arrives through
## [signal peer_authenticating] (peer 1) and [signal peer_connected], or through
## [signal connection_failed] after at most twice [param connect_timeout_ms] (in practice, between
## 1 and 1.5 times: ENet only checks the deadline when retransmitting the CONNECT). The transport
## must be in the tree.
## [br][br]With [param dtls] (the zone's certificate pinned with [method TLSOptions.client]) the
## connection goes over DTLS and [param dtls_name] is the name (CN) expected from the certificate
## (docs/platform.md §10.2). Without it, as always. The DTLS handshake delays the connection
## (about 0.6 s instead of 0.2–0.3): ENet sends the CONNECT once DTLS is ready, on its first
## retransmission.
func connect_to(address: String, port: int, connect_timeout_ms: int = 3000, dtls_name: String = "",
		dtls: TLSOptions = null) -> Error:
	if _mp == null:
		return ERR_UNCONFIGURED
	if _is_active():
		return ERR_ALREADY_IN_USE
	var peer := ENetMultiplayerPeer.new()
	var err: Error = peer.create_client(address, port, NetProtocol.CUSTOM_CHANNELS)
	if err != OK:
		return err
	if dtls != null:
		err = peer.host.dtls_client_setup(dtls_name, dtls)
		if err != OK:
			peer.close()
			return err
	# A short timeout is used while connecting; once connected it switches to the normal one (see
	# _on_peer_authenticating). The minimum and the maximum are the same: ENet only looks at the
	# deadline when a CONNECT retransmission expires (at 0.5, 1.5, 3.5 and 7.5 s), and with a maximum
	# of twice the minimum it took 3.5 s to give up with 1000 ms and 7.5 s with 3000 ms.
	for packet_peer: ENetPacketPeer in peer.host.get_peers():
		packet_peer.set_timeout(TIMEOUT_LIMIT, connect_timeout_ms, connect_timeout_ms)
	_attach(peer, false)
	_dtls = dtls != null
	return OK


## true if this transport is a server.
func is_server() -> bool:
	return _is_server


## true if the connection (or the server) goes over DTLS.
func is_dtls() -> bool:
	return _dtls


## Sends [param bytes] to the peer on [param channel] ([constant NetProtocol.CH_INPUT],
## [constant NetProtocol.CH_SNAPSHOT] or [constant NetProtocol.CH_RELIABLE]); the transfer mode
## comes from the channel ([method NetProtocol.transfer_mode]). Returns
## [constant ERR_UNAVAILABLE] if the peer is not connected yet (or is already closing). With the
## simulator, the packet goes out in some later [method flush]; without it, in the next one.
## Unreliable packets larger than [constant NetProtocol.MAX_PACKET_BYTES] are rejected (ENet would
## fragment them and losing one fragment would drop the whole packet).
func send(peer_id: int, channel: int, bytes: PackedByteArray) -> Error:
	if _mp == null or _enet == null:
		return ERR_UNCONFIGURED
	if not _connected.has(peer_id) or _closing.has(peer_id):
		return ERR_UNAVAILABLE
	if channel < NetProtocol.CH_INPUT or channel > NetProtocol.CUSTOM_CHANNELS or bytes.is_empty():
		return ERR_INVALID_PARAMETER
	if bytes.size() > NetProtocol.MAX_PACKET_BYTES and NetProtocol.is_unreliable_channel(channel):
		return ERR_PARAMETER_RANGE_ERROR
	if _out_sim != null:
		_out_sim.enqueue(NetSim.Packet.new(peer_id, channel, bytes), _now_tick)
		_app_out += bytes.size()
		return OK
	var err: Error = _send_now(peer_id, channel, bytes)
	if err == OK:
		_app_out += bytes.size()
	return err


## Sends an authentication message (HELLO, WELCOME, REJECT) to a peer that is authenticating.
## Returns [constant ERR_UNAVAILABLE] if the peer is not in that state or [method complete_auth]
## has already been called for it. With the simulator it is only delayed.
func send_auth(peer_id: int, bytes: PackedByteArray) -> Error:
	if _mp == null or _enet == null:
		return ERR_UNCONFIGURED
	if not _authenticating.has(peer_id) or _local_auth_done.has(peer_id) \
			or _closing.has(peer_id):
		return ERR_UNAVAILABLE
	if bytes.is_empty():
		return ERR_INVALID_PARAMETER
	if _out_sim != null:
		_out_sim.enqueue(NetSim.Packet.new(peer_id, NetSim.AUTH_CHANNEL, bytes, true), _now_tick)
		_app_out += bytes.size()
		return OK
	var err: Error = _send_auth_now(peer_id, bytes)
	if err == OK:
		_app_out += bytes.size()
	return err


## Accepts the peer's authentication on this side. When both sides have completed it,
## [signal peer_connected] arrives. With the simulator it is delayed just like authentication
## messages, and always after those already queued.
func complete_auth(peer_id: int) -> Error:
	if _mp == null or _enet == null:
		return ERR_UNCONFIGURED
	if not _authenticating.has(peer_id) or _local_auth_done.has(peer_id) \
			or _closing.has(peer_id):
		return ERR_UNAVAILABLE
	_local_auth_done[peer_id] = true
	if _out_sim != null:
		# An empty authentication packet is the "complete" marker (it is never sent empty).
		_out_sim.enqueue(NetSim.Packet.new(peer_id, NetSim.AUTH_CHANNEL, PackedByteArray(), true),
				_now_tick)
		return OK
	return _complete_auth_now(peer_id)


## Flushes whatever the simulator holds for the peer (without waiting for its delay), hands it to
## ENet and requests the disconnect with [method ENetPacketPeer.peer_disconnect_later], which lets
## queued data go out first (for example a REJECT or a kick NOTICE). As a safety net, if the peer
## is still there after [constant FORCE_DISCONNECT_TICKS] ticks, it is forcibly disconnected. From
## that moment on [method send] and [method send_auth] return [constant ERR_UNAVAILABLE] for that
## peer.
## [br][br]
## [b]The client never starts the disconnect[/b] (docs/platform.md §19.18, P9c; docs/networking.md section 3), over DTLS or not: it
## flushes its own data and waits for the server to cut it, which is how the server answers the
## CLIENT_LEAVE. Godot's DTLS server forgets a peer's session as soon as ENet considers it
## disconnected; if the client starts the disconnect, its DTLS close notice arrives one round trip
## later, the server takes it for a new handshake and the engine logs an error
## ([code]TLS handshake error: -30464[/code], measured in 6 of 6 disconnects started that way and
## in 0 of 6 started by the server). If the server does not cut within
## [constant FORCE_DISCONNECT_TICKS] ticks, the client closes the whole connection: the DISCONNECT
## and the DTLS close go out in the same send and arrive together (also 0 of 6).
## [br][br]
## Over plain UDP the same rule avoids a crash of the engine: the exported [i]release[/i] Linux server (4.7.2) dies
## with SIGBUS when it handles a DISCONNECT that the client started (it does not with a disconnect it started
## itself). [constant ENV_CLIENT_STARTS_DISCONNECT] brings the old behavior back for the canary of CI
## (tools/ci/smoke_server.sh --canary), which tells when an engine update fixes it.
func disconnect_after_flush(peer_id: int) -> void:
	if _enet == null or not _is_known(peer_id) or _closing.has(peer_id):
		return
	if _out_sim != null:
		for packet: NetSim.Packet in _out_sim.drain_peer(peer_id):
			_send_packet_now(packet)
	_flush_host()
	var packet_peer: ENetPacketPeer = _enet.get_peer(peer_id)
	if packet_peer != null and (_is_server or _client_starts_disconnect):
		packet_peer.peer_disconnect_later()
	if _guard != null:
		# It is already being disconnected: anything it keeps sending is dropped without being counted.
		_guard.mute_peer(peer_id)
	_closing[peer_id] = _now_tick + FORCE_DISCONNECT_TICKS


## Receives what has arrived, delivers signals and advances the simulator. Called once at the
## start of the owner's physics tick [param now_tick].
func poll(now_tick: int) -> void:
	_now_tick = now_tick
	if _mp == null or _enet == null:
		return
	_mp.poll()
	_force_pending_disconnects()
	if _in_sim != null:
		for packet: NetSim.Packet in _in_sim.pop_due(now_tick):
			_events.append(_event_from_packet(packet))
	_dispatch_events()
	if _enet != null and now_tick - _last_wire_sample_tick >= WIRE_SAMPLE_TICKS:
		_sample_wire_stats()
		_last_wire_sample_tick = now_tick


## Sends the simulator packets that are due this tick and flushes everything queued to ENet.
## Called once at the end of the owner's physics tick.
func flush() -> void:
	if _enet == null:
		return
	if _out_sim != null:
		for packet: NetSim.Packet in _out_sim.pop_due(_now_tick):
			_send_packet_now(packet)
	_flush_host()


## Closes the transport: sends whatever the simulator was holding, notifies the peers and frees
## the port. Emits no signals. Afterwards [method host] or [method connect_to] can be called
## again. It is called automatically when leaving the tree.
## [br][br]
## The disconnect is immediate and ENet discards on the receiver whatever it has not yet
## delivered. For a last message (CLIENT_LEAVE, a closing NOTICE) to arrive reliably, use
## [method disconnect_after_flush] first and close when [signal peer_disconnected] arrives.
func close() -> void:
	if _enet != null:
		if _out_sim != null:
			for packet: NetSim.Packet in _out_sim.pop_due(9223372036854775807):
				if not packet.is_auth:
					_send_packet_now(packet)
		_flush_host()
		_teardown()
	else:
		_reset_state()


## ENet RTT to the peer in milliseconds (it does not include the simulator's delay), or 0 if
## unknown.
func get_rtt_ms(peer_id: int) -> float:
	var packet_peer: ENetPacketPeer = _get_packet_peer(peer_id)
	if packet_peer == null:
		return 0.0
	return packet_peer.get_statistic(ENetPacketPeer.PEER_ROUND_TRIP_TIME)


## Maximum delay (ticks) that this transport's simulators add to a round trip with the peer: the
## outgoing one plus the incoming one. 0 without a simulator. Used to separate the real RTT from
## the simulated one (see [method get_rtt_ms], which does not include the simulator).
func get_sim_round_trip_ticks() -> int:
	var ticks: int = 0
	if _out_sim != null:
		ticks += _out_sim.get_max_delay_ticks()
	if _in_sim != null:
		ticks += _in_sim.get_max_delay_ticks()
	return ticks


## Reliable packet loss with the peer according to ENet, as a fraction from 0 to 1 (it does not
## include the simulator's), or 0 if unknown.
func get_packet_loss(peer_id: int) -> float:
	var packet_peer: ENetPacketPeer = _get_packet_peer(peer_id)
	if packet_peer == null:
		return 0.0
	return packet_peer.get_statistic(ENetPacketPeer.PEER_PACKET_LOSS) / PACKET_LOSS_SCALE


## The peer's IP address (empty if unknown). Already works during authentication.
func get_remote_address(peer_id: int) -> String:
	var packet_peer: ENetPacketPeer = _get_packet_peer(peer_id)
	if packet_peer == null:
		return ""
	return packet_peer.get_remote_address()


## Bytes accumulated since the transport was created:
## [code]{"app_in": int, "app_out": int, "wire_in": int, "wire_out": int}[/code].
## [br]- [code]app_*[/code]: application bytes, as seen by [method send],
## [method send_auth] and the [signal packet_received] and [signal auth_received] signals (what
## the simulator drops does not arrive, and does not count).
## [br]- [code]wire_*[/code]: bytes ENet has received and sent over the socket (with its headers,
## without the UDP/IP ones).
func get_byte_counters() -> Dictionary:
	_sample_wire_stats()
	return {
		"app_in": _app_in,
		"app_out": _app_out,
		"wire_in": _wire_in,
		"wire_out": _wire_out,
	}


# --- Internals --------------------------------------------------------------------------------

func _create_sims() -> void:
	_out_sim = NetSim.from_arg(_sim_spec, 0)
	_in_sim = NetSim.from_arg(_sim_spec, 1)
	if _out_sim != null and not _out_sim.is_enabled():
		_out_sim = null
	if _in_sim != null and not _in_sim.is_enabled():
		_in_sim = null


func _attach(peer: ENetMultiplayerPeer, as_server: bool) -> void:
	# Measured in Godot 4.7.2: without this call ENet intermittently lowers the peers' throttle limit
	# to 1/32 and drops between 20% and 65% of unreliable packets even on loopback. With 0, 0 (no
	# bandwidth limit) they all arrive.
	peer.host.bandwidth_limit(0, 0)
	_enet = peer
	_is_server = as_server
	_client_connected = false
	_client_failed = false
	if as_server:
		# The server does not let SceneMultiplayer see anything that is not part of its protocol: every
		# foreign packet would log an engine error and bypass the rate limiters (finding S1).
		_guard = GuardedEnetPeer.new()
		_guard.attach(peer)
		_guard.packets_discarded.connect(_on_packets_discarded)
		_guard.admitted = _mp_connected
		_guard.raw_sink = _on_peer_packet
		_mp.multiplayer_peer = _guard
	else:
		_mp.multiplayer_peer = peer


# Closes the ENet peer without notifying listeners and leaves the transport ready for reuse.
func _teardown() -> void:
	if _enet != null:
		_sample_wire_stats()
		if _mp != null:
			_mp.multiplayer_peer = null
		if _guard != null:
			# Also closes the ENet peer and releases its signals (otherwise they would stay referenced).
			_guard.close()
		else:
			_enet.close()
	_reset_state()


func _reset_state() -> void:
	_enet = null
	_guard = null
	_is_server = false
	_dtls = false
	_client_connected = false
	_client_failed = false
	_authenticating.clear()
	_mp_connected.clear()
	_connected.clear()
	_closing.clear()
	_local_auth_done.clear()
	_events.clear()
	_parked.clear()
	_epoch += 1
	_create_sims()


# true if an ENet peer is running. If the client lost or failed to establish the connection, the
# peer is left dead: it is cleaned up here so that host() or connect_to() can be called again.
func _is_active() -> bool:
	if _enet == null:
		return false
	if _enet.get_connection_status() == MultiplayerPeer.CONNECTION_DISCONNECTED:
		_teardown()
		return false
	return true


func _is_known(peer_id: int) -> bool:
	return _authenticating.has(peer_id) or _mp_connected.has(peer_id)


func _get_packet_peer(peer_id: int) -> ENetPacketPeer:
	if _enet == null or not _is_known(peer_id):
		return null
	return _enet.get_peer(peer_id)


# The ENet connection, or null if the peer is not active (accessing [code]host[/code] then logs
# an engine error).
func _get_host() -> ENetConnection:
	if _enet == null or _enet.get_connection_status() == MultiplayerPeer.CONNECTION_DISCONNECTED:
		return null
	return _enet.host


func _flush_host() -> void:
	var connection: ENetConnection = _get_host()
	if connection != null:
		connection.flush()


# The ENet counter is reset to 0 when read and is 32-bit: it is accumulated here.
func _sample_wire_stats() -> void:
	var connection: ENetConnection = _get_host()
	if connection == null:
		return
	_wire_in += int(connection.pop_statistic(ENetConnection.HOST_TOTAL_RECEIVED_DATA))
	_wire_out += int(connection.pop_statistic(ENetConnection.HOST_TOTAL_SENT_DATA))


# --- Real output (after the simulator) --------------------------------------------------------

# Hands ENet a packet from the outgoing simulator when it is due.
func _send_packet_now(packet: NetSim.Packet) -> void:
	if not packet.is_auth:
		_send_now(packet.peer_id, packet.channel, packet.bytes)
	elif packet.bytes.is_empty():
		_complete_auth_now(packet.peer_id)
	else:
		_send_auth_now(packet.peer_id, packet.bytes)


# Errors are deliberately ignored on the delayed path: if the peer left along the way, the packet
# is dropped, as a real network would do.
func _send_now(peer_id: int, channel: int, bytes: PackedByteArray) -> Error:
	if _mp == null or not _connected.has(peer_id) or _closing.has(peer_id):
		return ERR_UNAVAILABLE
	return _mp.send_bytes(bytes, peer_id, NetProtocol.transfer_mode(channel), channel)


func _send_auth_now(peer_id: int, bytes: PackedByteArray) -> Error:
	if _mp == null or not _authenticating.has(peer_id) or _closing.has(peer_id):
		return ERR_UNAVAILABLE
	return _mp.send_auth(peer_id, bytes)


func _complete_auth_now(peer_id: int) -> Error:
	if _mp == null or not _authenticating.has(peer_id) or _closing.has(peer_id):
		return ERR_UNAVAILABLE
	return _mp.complete_auth(peer_id)


# --- Disconnections ---------------------------------------------------------------------------

# Forcibly disconnects peers whose disconnect_after_flush() did not finish in time.
func _force_pending_disconnects() -> void:
	if _closing.is_empty():
		return
	for peer_id: int in _closing.keys():
		if _now_tick < int(_closing[peer_id]):
			continue
		if _enet == null:
			_closing.erase(peer_id)
			continue
		if not _is_server and not _client_starts_disconnect and _is_known(peer_id):
			# With DTLS, the client closes the whole connection (see disconnect_after_flush).
			var was_mp_connected: bool = _mp_connected.has(peer_id)
			_forget_peer(peer_id)
			_queue_disconnect(peer_id, was_mp_connected)
			_close_enet_keeping_events()
			continue
		var packet_peer: ENetPacketPeer = _enet.get_peer(peer_id) if _is_known(peer_id) else null
		if packet_peer != null:
			packet_peer.peer_disconnect_now()
		if _is_known(peer_id):
			var was_connected: bool = _mp_connected.has(peer_id)
			_forget_peer(peer_id)
			_queue_disconnect(peer_id, was_connected)
		else:
			_closing.erase(peer_id)


# Closes the ENet peer (ENetMultiplayerPeer.close: DISCONNECT and, with DTLS, the close notice in
# the same send) without losing the events pending delivery, which go out in this same poll().
# Afterwards the transport is left as after losing the connection: close() makes it ready for
# reuse.
func _close_enet_keeping_events() -> void:
	_sample_wire_stats()
	if _mp != null:
		_mp.multiplayer_peer = null
	_enet.close()
	_enet = null


func _forget_peer(peer_id: int) -> void:
	_authenticating.erase(peer_id)
	_mp_connected.erase(peer_id)
	_connected.erase(peer_id)
	_closing.erase(peer_id)
	_local_auth_done.erase(peer_id)
	if _out_sim != null:
		_out_sim.drain_peer(peer_id)


# Records the loss of a peer. With the incoming simulator, the signal waits for the packets that
# peer had in transit to be delivered, so as not to announce the disconnect before what it sent.
func _queue_disconnect(peer_id: int, was_connected: bool) -> void:
	if _is_server or was_connected:
		var event := _Event.new(_EVENT_DISCONNECTED, peer_id)
		if _in_sim != null:
			_parked.append(event)
		else:
			_events.append(event)
	else:
		_fail_client()


# The client never managed to connect: it is reported only once. Like disconnections, it waits
# for whatever the server had in transit (for example a delayed REJECT) to be delivered.
func _fail_client() -> void:
	if _client_failed:
		return
	_client_failed = true
	var event := _Event.new(_EVENT_CONNECTION_FAILED, SERVER_PEER_ID)
	if _in_sim != null:
		_parked.append(event)
	else:
		_events.append(event)


# --- SceneMultiplayer handlers (inside mp.poll(): they only record, they do not notify) --------

func _on_peer_authenticating(peer_id: int) -> void:
	_authenticating[peer_id] = true
	# An ENet connection now exists: switches from the connection timeout to the normal steady-state one.
	var packet_peer: ENetPacketPeer = _enet.get_peer(peer_id)
	if packet_peer != null:
		packet_peer.set_timeout(TIMEOUT_LIMIT, TIMEOUT_MIN_MS, TIMEOUT_MAX_MS)
		packet_peer.throttle_configure(THROTTLE_INTERVAL_MS, THROTTLE_ACCELERATION,
				THROTTLE_DECELERATION)
	_events.append(_Event.new(_EVENT_AUTHENTICATING, peer_id))


func _on_peer_authentication_failed(peer_id: int) -> void:
	if not _authenticating.has(peer_id):
		return
	_forget_peer(peer_id)
	_queue_disconnect(peer_id, false)


func _on_mp_peer_connected(peer_id: int) -> void:
	_authenticating.erase(peer_id)
	_local_auth_done.erase(peer_id)
	_mp_connected[peer_id] = true
	if not _is_server:
		_client_connected = true
	_events.append(_Event.new(_EVENT_CONNECTED, peer_id))


func _on_mp_peer_disconnected(peer_id: int) -> void:
	if not _mp_connected.has(peer_id):
		return
	_forget_peer(peer_id)
	_queue_disconnect(peer_id, true)


func _on_mp_connection_failed() -> void:
	if not _is_server:
		_fail_client()


func _on_mp_server_disconnected() -> void:
	# Already reported with peer_disconnected (if it was connected) or with the failed authentication.
	if not _is_server and not _client_connected:
		_fail_client()


func _on_packets_discarded(peer_id: int, count: int) -> void:
	var event := _Event.new(_EVENT_DISCARDED, peer_id)
	event.count = count
	_events.append(event)


func _on_auth_callback(peer_id: int, bytes: PackedByteArray) -> void:
	if _in_sim != null:
		_in_sim.enqueue(NetSim.Packet.new(peer_id, NetSim.AUTH_CHANNEL, bytes, true), _now_tick)
	else:
		_events.append(_Event.new(_EVENT_AUTH, peer_id, bytes))


func _on_peer_packet(peer_id: int, bytes: PackedByteArray) -> void:
	if bytes.is_empty() or not _mp_connected.has(peer_id):
		return
	if _in_sim != null:
		var channel: int = NetProtocol.channel_for_type(bytes[0])
		_in_sim.enqueue(NetSim.Packet.new(peer_id, channel, bytes), _now_tick)
	else:
		_events.append(_Event.new(_EVENT_PACKET, peer_id, bytes))


# --- Event delivery ---------------------------------------------------------------------------

func _event_from_packet(packet: NetSim.Packet) -> _Event:
	var kind: int = _EVENT_AUTH if packet.is_auth else _EVENT_PACKET
	return _Event.new(kind, packet.peer_id, packet.bytes)


func _dispatch_events() -> void:
	var epoch: int = _epoch
	var batch: Array[_Event] = _events
	_events = []
	for event: _Event in batch:
		_emit_event(event)
		if epoch != _epoch:
			return
	if _parked.is_empty():
		return
	var still_parked: Array[_Event] = []
	var released: Array[_Event] = []
	for event: _Event in _parked:
		if _in_sim != null and _in_sim.has_pending(event.peer_id):
			still_parked.append(event)
		else:
			released.append(event)
	_parked = still_parked
	for event: _Event in released:
		_emit_event(event)
		if epoch != _epoch:
			return


func _emit_event(event: _Event) -> void:
	match event.kind:
		_EVENT_AUTHENTICATING:
			peer_authenticating.emit(event.peer_id)
		_EVENT_AUTH:
			_app_in += event.bytes.size()
			auth_received.emit(event.peer_id, event.bytes)
		_EVENT_CONNECTED:
			# From now on this peer can be sent to (if it has not been lost in the meantime).
			if _mp_connected.has(event.peer_id):
				_connected[event.peer_id] = true
			peer_connected.emit(event.peer_id)
		_EVENT_DISCONNECTED:
			peer_disconnected.emit(event.peer_id)
		_EVENT_PACKET:
			_app_in += event.bytes.size()
			packet_received.emit(event.peer_id, event.bytes)
		_EVENT_CONNECTION_FAILED:
			connection_failed.emit()
		_EVENT_DISCARDED:
			packets_discarded.emit(event.peer_id, event.count)
