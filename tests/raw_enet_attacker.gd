class_name RawEnetAttacker
extends RefCounted
## Raw ENet client for the security tests: talks to the server through an
## [ENetMultiplayerPeer] without [SceneMultiplayer] or [NetTransport], so it can send anything,
## before and after authenticating (docs/red.md, sections 5.7 and 12).
## [br][br]
## It knows the internal [SceneMultiplayer] format used by [GuardedEnetPeer]: byte 0 &amp; 7 is the
## command (RAW = 3, SYS = 7, RPC = 0, SIMPLIFY_PATH = 1, SPAWN = 4) and, in a SYS, byte 1 is the
## subcommand (AUTH = 0). An authentication message is [code][7, 0] + content[/code], and the
## confirmation that each side is done is a bare [code][7, 0][/code], on channel 0.

const COMMAND_RAW: int = 3
const COMMAND_SYS: int = 7
const SYS_AUTH: int = 0

var peer: ENetMultiplayerPeer = ENetMultiplayerPeer.new()
## Content (without the header) of each authentication message received: WELCOME or REJECT.
var auth_messages: Array[PackedByteArray] = []
## true once the server has sent its 2-byte confirmation.
var server_confirmed: bool = false
## Application packets received (RAW), without the one-byte header.
var app_packets: Array[PackedByteArray] = []
## Everything else that arrived, as is.
var other_packets: Array[PackedByteArray] = []


## Starts connecting to 127.0.0.1:[param port].
func connect_to(port: int) -> Error:
	return peer.create_client("127.0.0.1", port, NetProtocol.CUSTOM_CHANNELS)


## true once ENet has completed the connection.
func is_connected_to_server() -> bool:
	return peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED


## true if the connection was dropped (or never got to open).
func is_closed() -> bool:
	return peer.get_connection_status() == MultiplayerPeer.CONNECTION_DISCONNECTED


## Processes whatever has arrived and classifies it. Does nothing if the connection is closed (an
## idle peer would log an engine error).
func poll() -> void:
	if is_closed():
		return
	peer.poll()
	while not is_closed() and peer.get_available_packet_count() > 0:
		var bytes: PackedByteArray = peer.get_packet()
		if bytes.size() == 2 and bytes[0] == COMMAND_SYS and bytes[1] == SYS_AUTH:
			server_confirmed = true
		elif bytes.size() > 2 and bytes[0] == COMMAND_SYS and bytes[1] == SYS_AUTH:
			auth_messages.append(bytes.slice(2))
		elif bytes.size() > 0 and bytes[0] == COMMAND_RAW:
			app_packets.append(bytes.slice(1))
		else:
			other_packets.append(bytes)


## Sends [param bytes] as is over [param channel] (0 is the system one).
func send(bytes: PackedByteArray, channel: int = 0, reliable: bool = true) -> void:
	if is_closed():
		return
	peer.set_target_peer(1)
	peer.set_transfer_channel(channel)
	peer.set_transfer_mode(MultiplayerPeer.TRANSFER_MODE_RELIABLE if reliable
			else MultiplayerPeer.TRANSFER_MODE_UNRELIABLE)
	peer.put_packet(bytes)


## Authentication message (the HELLO).
func send_auth(payload: PackedByteArray) -> void:
	var bytes := PackedByteArray([COMMAND_SYS, SYS_AUTH])
	bytes.append_array(payload)
	send(bytes, 0, true)


## The confirmation that this side has finished authenticating.
func send_confirmation() -> void:
	send(PackedByteArray([COMMAND_SYS, SYS_AUTH]), 0, true)


## Application packet (RAW) over [param channel].
func send_app(payload: PackedByteArray, channel: int, reliable: bool = true) -> void:
	var bytes := PackedByteArray([COMMAND_RAW])
	bytes.append_array(payload)
	send(bytes, channel, reliable)


## Flushes the queued data to ENet (several consecutive packets go out in the same datagram).
func flush() -> void:
	if not is_closed():
		peer.host.flush()


## Closes the connection without notice.
func close() -> void:
	if not is_closed():
		peer.close()
