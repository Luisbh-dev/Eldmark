class_name GuardedEnetPeer
extends MultiplayerPeerExtension
## Wrapper around the server's [ENetMultiplayerPeer] that filters packets before [SceneMultiplayer]
## sees them (docs/networking.md, sections 2 and 12).
## [br][br]
## [b]Why.[/b] [SceneMultiplayer] processes everything that arrives inside [code]poll()[/code], and only
## delivers to the application the RAW packets of already admitted peers. An ENet client without
## [SceneMultiplayer] (an attacker) that sent anything else before or after the HELLO (RPCs, simplified
## paths, SPAWN, system commands...) made the engine log one error per packet
## (each with its GDScript trace: 2000 packets were 742 KB of log and a 28 ms tick), those
## packets bypassed the limiters and added no warnings, and before the HELLO only the 5 s
## [code]auth_timeout[/code] cut them off (finding S1 of the phase 2 review).
## [br][br]
## [b]What it lets through.[/b] With [SceneMultiplayer]'s internal format (byte 0 &amp; 7 is the
## command; RAW = 3, SYS = 7; byte 1 of a SYS is the subcommand; AUTH = 0):
## [br]- To a peer that is not yet admitted (missing its confirmation or ours): only authentication
## messages, that is, SYS + AUTH, of at most [constant MAX_AUTH_BYTES] bytes and at most
## [constant MAX_AUTH_PAYLOADS] with content (the HELLO) plus a 2-byte confirmation.
## [br]- To an admitted peer (both sides have confirmed): only RAW.
## [br]Everything else is discarded here, with no engine error, and counted: at the end of each
## [method poll] [signal packets_discarded] is emitted with the number per peer, so that the server
## adds up warnings. A peer silenced with [method mute_peer] (the server is already cutting it off) is
## discarded without counting.
## [br][br]
## [b]State.[/b] The wrapper knows a peer is admitted because it sees pass, in one direction,
## the other side's 2-byte confirmation [code][SYS, AUTH][/code] and, in the other, ours
## ([method _put_packet_script]): [SceneMultiplayer] admits the peer exactly when both have
## crossed. If a future engine version changed that format, the handshake
## would stop completing and the [code]test_net_sim.gd[/code] tests would detect it.
## [br][br]
## [b]Shortcut.[/b] For peers that [SceneMultiplayer] has truly admitted ([member admitted],
## which the owner fills with its signals), RAW packets do not go through
## [SceneMultiplayer]'s queue: they are delivered directly to [member raw_sink]. It is the hot path (the
## inputs of all players, every tick) and this way the filter costs almost nothing per packet.
## Measured with 64 clients sending 48,000 packets in total (five alternating repetitions): 9.4 µs
## per packet without filter, 9.9 µs with filter and shortcut (+0.6 µs, +6%, the noise level of the
## measurement: 0.05 ms per tick with 64 players) and 11.3 µs with filter and no shortcut (+25%). A packet from
## a peer that is admitted during this same call to [method poll] goes through the queue, behind its
## confirmation, so that order is preserved.
## [br][br]
## Shared: it does not read the clock nor depend on client or server.

## Emitted at the end of [method poll], once per peer from which packets were discarded in that
## call.
signal packets_discarded(peer_id: int, count: int)

## [SceneMultiplayer] commands (the low 3 bits of byte 0).
const COMMAND_MASK: int = 7
const COMMAND_RAW: int = 3
const COMMAND_SYS: int = 7
## Authentication subcommand within SYS (byte 1).
const SYS_AUTH: int = 0
## Authentication messages with content that are accepted from a non-admitted peer: the HELLO.
const MAX_AUTH_PAYLOADS: int = 3
## Maximum size of an authentication message (the largest HELLO fits with room to spare).
const MAX_AUTH_BYTES: int = 1200
## Maximum packet size it declares to [SceneMultiplayer] (the same as ENetMultiplayerPeer).
const MAX_PACKET_SIZE: int = 1 << 24
## At most this many packets are processed in each [method poll]; the rest stay in ENet's queue
## for the next one. Bounds the cost of a flood in a single tick.
const MAX_PACKETS_PER_POLL: int = 4096

## Peers that [SceneMultiplayer] has already admitted (the key is the id). Filled by the owner.
var admitted: Dictionary = {}
## [code](peer_id: int, payload: PackedByteArray) -> void[/code]: receives the RAW packets of the
## peers in [member admitted], without the one-byte header.
var raw_sink: Callable = Callable()

var _inner: ENetMultiplayerPeer = null
var _target_peer: int = 0
var _transfer_channel: int = 0
var _transfer_mode: int = MultiplayerPeer.TRANSFER_MODE_RELIABLE

# Queue of what passes the filter and SceneMultiplayer will pick up, in columns. _head is the next one.
var _queue_peers: PackedInt32Array = PackedInt32Array()
var _queue_packets: Array[PackedByteArray] = []
var _head: int = 0

# Per peer (id -> true / counter): confirmation received, confirmation sent, authentication
# messages with content admitted, muted.
var _remote_confirmed: Dictionary = {}
var _local_confirmed: Dictionary = {}
var _auth_payloads: Dictionary = {}
var _muted: Dictionary = {}
# Discards of the current poll() call: id -> how many.
var _discarded: Dictionary = {}
# Total packets discarded since it was created (not counting those of muted peers).
var _discarded_total: int = 0


## Wraps [param inner], which must already be created (as server or client) and not be used
## elsewhere as a multiplayer peer. Afterwards this object must be given to [SceneMultiplayer]
## instead of [param inner].
func attach(inner: ENetMultiplayerPeer) -> void:
	_inner = inner
	_inner.peer_connected.connect(_on_inner_peer_connected)
	_inner.peer_disconnected.connect(_on_inner_peer_disconnected)


## Stops watching the packets of [param peer_id]: everything it sends is discarded without counting. Used by
## the transport when the server is already cutting that peer off.
func mute_peer(peer_id: int) -> void:
	_muted[peer_id] = true


## Total packets discarded for not belonging to the protocol (not counting those of muted peers).
func get_discarded_total() -> int:
	return _discarded_total


# --- MultiplayerPeerExtension -----------------------------------------------------------------

func _poll() -> void:
	if _inner == null:
		return
	_inner.poll()
	_drain_inner()


func _drain_inner() -> void:
	# What was picked up in the previous call has already been consumed: the queue is reset.
	if _head > 0 and _head >= _queue_packets.size():
		_reset_queue()
	var handled: int = 0
	while _inner != null and handled < MAX_PACKETS_PER_POLL \
			and _inner.get_available_packet_count() > 0:
		handled += 1
		var sender: int = _inner.get_packet_peer()
		var bytes: PackedByteArray = _inner.get_packet()
		if _muted.has(sender):
			continue
		if admitted.has(sender):
			# Shortcut: a peer that SceneMultiplayer has already admitted can only send RAW, and those
			# packets are delivered to the owner directly (without going through SceneMultiplayer's queue).
			if bytes.size() > 0 and (bytes[0] & COMMAND_MASK) == COMMAND_RAW:
				raw_sink.call(sender, bytes.slice(1))
			else:
				_discarded[sender] = int(_discarded.get(sender, 0)) + 1
			continue
		# An empty packet is what get_packet() returns on error.
		if not _accepts(sender, bytes):
			_discarded[sender] = int(_discarded.get(sender, 0)) + 1
			continue
		_queue_peers.append(sender)
		_queue_packets.append(bytes)
	if _discarded.is_empty():
		return
	var report: Dictionary = _discarded
	_discarded = {}
	for peer_id: int in report:
		var count: int = report[peer_id]
		_discarded_total += count
		packets_discarded.emit(peer_id, count)


# true if the packet from [param sender] is of the kind SceneMultiplayer expects in its state.
func _accepts(sender: int, bytes: PackedByteArray) -> bool:
	var size: int = bytes.size()
	if size == 0:
		return false
	var command: int = bytes[0] & COMMAND_MASK
	if _remote_confirmed.has(sender) and _local_confirmed.has(sender):
		return command == COMMAND_RAW
	if command != COMMAND_SYS or size < 2 or bytes[1] != SYS_AUTH:
		return false
	if size == 2:
		# The other side's confirmation, only once.
		if _remote_confirmed.has(sender):
			return false
		_remote_confirmed[sender] = true
		return true
	if size > MAX_AUTH_BYTES:
		return false
	var payloads: int = int(_auth_payloads.get(sender, 0))
	if payloads >= MAX_AUTH_PAYLOADS:
		return false
	_auth_payloads[sender] = payloads + 1
	return true


func _get_available_packet_count() -> int:
	return _queue_packets.size() - _head


func _get_packet_peer() -> int:
	return _queue_peers[_head] if _head < _queue_peers.size() else 0


# SceneMultiplayer only uses a packet's mode and channel in the system commands that are
# relayed (SYS RELAY), which do not get through here, so they are not stored.
func _get_packet_mode() -> int:
	return MultiplayerPeer.TRANSFER_MODE_RELIABLE


func _get_packet_channel() -> int:
	return 0


func _get_packet_script() -> PackedByteArray:
	if _head >= _queue_packets.size():
		return PackedByteArray()
	var bytes: PackedByteArray = _queue_packets[_head]
	_head += 1
	return bytes


func _put_packet_script(buffer: PackedByteArray) -> Error:
	if _inner == null:
		return ERR_UNCONFIGURED
	# Our authentication confirmation: from here on, and together with the other side's, the peer
	# is admitted.
	if buffer.size() == 2 and buffer[0] == COMMAND_SYS and buffer[1] == SYS_AUTH \
			and _target_peer > 0:
		_local_confirmed[_target_peer] = true
	_inner.set_target_peer(_target_peer)
	_inner.set_transfer_channel(_transfer_channel)
	_inner.set_transfer_mode(_transfer_mode as MultiplayerPeer.TransferMode)
	return _inner.put_packet(buffer)


func _get_max_packet_size() -> int:
	return MAX_PACKET_SIZE


func _set_transfer_channel(channel: int) -> void:
	_transfer_channel = channel


func _get_transfer_channel() -> int:
	return _transfer_channel


func _set_transfer_mode(mode: int) -> void:
	_transfer_mode = mode


func _get_transfer_mode() -> int:
	return _transfer_mode


func _set_target_peer(peer: int) -> void:
	_target_peer = peer


func _is_server() -> bool:
	return _inner != null and _inner.is_server()


func _is_server_relay_supported() -> bool:
	return false


func _close() -> void:
	if _inner != null:
		if _inner.peer_connected.is_connected(_on_inner_peer_connected):
			_inner.peer_connected.disconnect(_on_inner_peer_connected)
		if _inner.peer_disconnected.is_connected(_on_inner_peer_disconnected):
			_inner.peer_disconnected.disconnect(_on_inner_peer_disconnected)
		_inner.close()
		_inner = null
	_reset_queue()
	_remote_confirmed.clear()
	_local_confirmed.clear()
	_auth_payloads.clear()
	_muted.clear()
	_discarded.clear()


func _disconnect_peer(peer: int, force: bool) -> void:
	if _inner != null:
		_inner.disconnect_peer(peer, force)


func _get_unique_id() -> int:
	return _inner.get_unique_id() if _inner != null else 0


func _set_refuse_new_connections(enable: bool) -> void:
	if _inner != null:
		_inner.refuse_new_connections = enable


func _is_refusing_new_connections() -> bool:
	return _inner != null and _inner.refuse_new_connections


func _get_connection_status() -> int:
	if _inner == null:
		return MultiplayerPeer.CONNECTION_DISCONNECTED
	return _inner.get_connection_status()


# --- Internals --------------------------------------------------------------------------------

func _reset_queue() -> void:
	_queue_peers.clear()
	_queue_packets.clear()
	_head = 0


# A new peer id starts with no state: the engine reuses ids.
func _on_inner_peer_connected(peer_id: int) -> void:
	_forget_peer(peer_id)
	peer_connected.emit(peer_id)


func _on_inner_peer_disconnected(peer_id: int) -> void:
	_forget_peer(peer_id)
	peer_disconnected.emit(peer_id)


func _forget_peer(peer_id: int) -> void:
	_remote_confirmed.erase(peer_id)
	_local_confirmed.erase(peer_id)
	_auth_payloads.erase(peer_id)
	_muted.erase(peer_id)
