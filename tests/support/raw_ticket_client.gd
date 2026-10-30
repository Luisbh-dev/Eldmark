class_name RawTicketClient
extends RefCounted
## Un cliente de pruebas que habla el protocolo a mano sobre un [NetTransport] (como el de
## [code]test_zone_server_net.gd[/code]) para entrar con billete en una zona con plataforma (docs/plataforma.md
## §5.2): manda el HELLO que se le da (retrasable), completa la autenticación con el WELCOME, manda CLIENT_READY si
## [member auto_ready] y apunta los SPAWN, los NOTICE (con su instante) y el REJECT. Lo usan
## [code]test_zone_server_platform.gd[/code], [code]test_zone_server_saves.gd[/code] y
## [code]test_zone_process_shutdown.gd[/code].

var transport: NetTransport
var hello: PackedByteArray
var auto_ready: bool = true
## Milisegundos tras la conexión antes de mandar el HELLO.
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
## Instante (ms de [method Time.get_ticks_msec]) de cada NOTICE, en el mismo orden que [member notices].
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


## Manda el HELLO cuando toca.
func step() -> void:
	if _hello_sent or _auth_peer < 0 or Time.get_ticks_msec() - connected_at_msec < hello_delay_ms:
		return
	_hello_sent = true
	transport.send_auth(_auth_peer, hello)


## Manda CLIENT_LEAVE (la salida ordenada del cliente).
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


## El primer NOTICE de expulsión, o null.
func kick_notice() -> NetMessages.Notice:
	for notice: NetMessages.Notice in notices:
		if notice.code == NetProtocol.NoticeCode.KICK:
			return notice
	return null


## El instante del primer NOTICE con [param code], o -1.
func notice_time(code: int) -> int:
	for i: int in notices.size():
		if notices[i].code == code:
			return notice_at_msec[i]
	return -1


## Los textos de los NOTICE con [param code], en orden.
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
