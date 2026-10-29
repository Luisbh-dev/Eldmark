class_name RawEnetAttacker
extends RefCounted
## Cliente ENet en bruto para las pruebas de seguridad: habla con el servidor por un
## [ENetMultiplayerPeer] sin [SceneMultiplayer] ni [NetTransport], así que puede mandar cualquier
## cosa, antes y después de autenticarse (docs/red.md, secciones 5.7 y 12).
## [br][br]
## Conoce el formato interno de [SceneMultiplayer] que usa [GuardedEnetPeer]: el byte 0 &amp; 7 es el
## comando (RAW = 3, SYS = 7, RPC = 0, SIMPLIFY_PATH = 1, SPAWN = 4) y, en un SYS, el byte 1 es el
## subcomando (AUTH = 0). Un mensaje de autenticación es [code][7, 0] + contenido[/code], y la
## confirmación de que cada lado ha terminado es [code][7, 0][/code] a secas, por el canal 0.

const COMMAND_RAW: int = 3
const COMMAND_SYS: int = 7
const SYS_AUTH: int = 0

var peer: ENetMultiplayerPeer = ENetMultiplayerPeer.new()
## Contenido (sin la cabecera) de cada mensaje de autenticación recibido: WELCOME o REJECT.
var auth_messages: Array[PackedByteArray] = []
## true cuando el servidor ha mandado su confirmación de 2 bytes.
var server_confirmed: bool = false
## Paquetes de aplicación recibidos (RAW), sin la cabecera de un byte.
var app_packets: Array[PackedByteArray] = []
## Todo lo demás que llegó, tal cual.
var other_packets: Array[PackedByteArray] = []


## Empieza a conectar con 127.0.0.1:[param port].
func connect_to(port: int) -> Error:
	return peer.create_client("127.0.0.1", port, NetProtocol.CUSTOM_CHANNELS)


## true si ENet ha completado la conexión.
func is_connected_to_server() -> bool:
	return peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED


## true si la conexión se ha cortado (o nunca llegó a abrirse).
func is_closed() -> bool:
	return peer.get_connection_status() == MultiplayerPeer.CONNECTION_DISCONNECTED


## Procesa lo que haya llegado y lo clasifica. No hace nada si la conexión está cerrada (un peer
## inactivo registraría un error del motor).
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


## Manda [param bytes] tal cual por [param channel] (0 es el de sistema).
func send(bytes: PackedByteArray, channel: int = 0, reliable: bool = true) -> void:
	if is_closed():
		return
	peer.set_target_peer(1)
	peer.set_transfer_channel(channel)
	peer.set_transfer_mode(MultiplayerPeer.TRANSFER_MODE_RELIABLE if reliable
			else MultiplayerPeer.TRANSFER_MODE_UNRELIABLE)
	peer.put_packet(bytes)


## Mensaje de autenticación (el HELLO).
func send_auth(payload: PackedByteArray) -> void:
	var bytes := PackedByteArray([COMMAND_SYS, SYS_AUTH])
	bytes.append_array(payload)
	send(bytes, 0, true)


## La confirmación de que este lado ha terminado de autenticarse.
func send_confirmation() -> void:
	send(PackedByteArray([COMMAND_SYS, SYS_AUTH]), 0, true)


## Paquete de aplicación (RAW) por [param channel].
func send_app(payload: PackedByteArray, channel: int, reliable: bool = true) -> void:
	var bytes := PackedByteArray([COMMAND_RAW])
	bytes.append_array(payload)
	send(bytes, channel, reliable)


## Vuelca a ENet lo encolado (varios paquetes seguidos salen en el mismo datagrama).
func flush() -> void:
	if not is_closed():
		peer.host.flush()


## Cierra la conexión sin avisar.
func close() -> void:
	if not is_closed():
		peer.close()
