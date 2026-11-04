class_name RawTicketClient
extends RefCounted
## A test client that speaks the protocol by hand over a [NetTransport] (like the one in
## [code]test_zone_server_net.gd[/code]) to enter a platform-backed zone with a ticket (docs/plataforma.md
## §5.2): it sends the HELLO it is given (delayable), completes authentication with the WELCOME, sends CLIENT_READY if
## [member auto_ready] is set and records the SPAWNs, the NOTICEs (with their time) and the REJECT. It is used by
## [code]test_zone_server_platform.gd[/code], [code]test_zone_server_saves.gd[/code] and
## [code]test_zone_process_shutdown.gd[/code].

var transport: NetTransport
var hello: PackedByteArray
var auto_ready: bool = true
## Milliseconds after connecting before sending the HELLO.
var hello_delay_ms: int = 0
var connected_at_msec: int = -1
var welcome_at_msec: int = -1
var reject_at_msec: int = -1
var welcome: NetMessages.Welcome = null
var reject: NetMessages.Reject = null
var connected: bool = false
var disconnected: bool = false
var failed: bool = false
var own_spawn: NetMessages.EntitySpawn = null
var spawns: Array[NetMessages.EntitySpawn] = []
var notices: Array[NetMessages.Notice] = []
## Time (ms of [method Time.get_ticks_msec]) of each NOTICE, in the same order as [member notices].
var notice_at_msec: Array[int] = []
var _auth_peer: int = -1
var _hello_sent: bool = false


func _init(p_transport: NetTransport, p_hello: PackedByteArray) -> void:
	transport = p_transport
	hello = p_hello
	transport.peer_authenticating.connect(_on_authenticating)
	transport.auth_received.connect(_on_auth_received)
	transport.peer_connected.connect(_on_connected)
	transport.peer_disconnected.connect(func(_peer_id: int) -> void: disconnected = true)
	transport.packet_received.connect(_on_packet)
	transport.connection_failed.connect(func() -> void: failed = true)


func _on_authenticating(peer_id: int) -> void:
	_auth_peer = peer_id
	connected_at_msec = Time.get_ticks_msec()
	step()


## Sends the HELLO when due.
func step() -> void:
	if _hello_sent or _auth_peer < 0 or Time.get_ticks_msec() - connected_at_msec < hello_delay_ms:
		return
	_hello_sent = true
	transport.send_auth(_auth_peer, hello)


## Sends CLIENT_LEAVE (the client's orderly exit).
func leave() -> void:
	transport.send(1, NetProtocol.CH_RELIABLE, NetMessages.ClientLeave.new().encode())


func _on_auth_received(peer_id: int, bytes: PackedByteArray) -> void:
	var result: int = NetMessages.peek_auth_result(bytes)
	if result == NetProtocol.Result.OK:
		welcome = NetMessages.Welcome.decode(bytes)
		welcome_at_msec = Time.get_ticks_msec()
		transport.complete_auth(peer_id)
	elif result > 0:
		reject = NetMessages.Reject.decode(bytes)
		reject_at_msec = Time.get_ticks_msec()


func _on_connected(_peer_id: int) -> void:
	connected = true
	if auto_ready:
		transport.send(1, NetProtocol.CH_RELIABLE, NetMessages.ClientReady.new().encode())


func _on_packet(_peer_id: int, bytes: PackedByteArray) -> void:
	match NetMessages.peek_type(bytes):
		NetProtocol.MSG_ENTITY_SPAWN:
			var spawn: NetMessages.EntitySpawn = NetMessages.EntitySpawn.decode(bytes)
			if spawn != null:
				spawns.append(spawn)
				if spawn.is_yours:
					own_spawn = spawn
		NetProtocol.MSG_NOTICE:
			var notice: NetMessages.Notice = NetMessages.Notice.decode(bytes)
			if notice != null:
				notices.append(notice)
				notice_at_msec.append(Time.get_ticks_msec())


## The first kick NOTICE, or null.
func kick_notice() -> NetMessages.Notice:
	for notice: NetMessages.Notice in notices:
		if notice.code == NetProtocol.NoticeCode.KICK:
			return notice
	return null


## The time of the first NOTICE with [param code], or -1.
func notice_time(code: int) -> int:
	for i: int in notices.size():
		if notices[i].code == code:
			return notice_at_msec[i]
	return -1


## The texts of the NOTICEs with [param code], in order.
func notice_texts(code: int) -> PackedStringArray:
	var texts := PackedStringArray()
	for notice: NetMessages.Notice in notices:
		if notice.code == code:
			texts.append(notice.text)
	return texts


func spawn_named(display_name: String) -> NetMessages.EntitySpawn:
	for spawn: NetMessages.EntitySpawn in spawns:
		if spawn.display_name == display_name:
			return spawn
	return null
