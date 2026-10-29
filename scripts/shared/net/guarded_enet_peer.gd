class_name GuardedEnetPeer
extends MultiplayerPeerExtension
## Envoltorio del [ENetMultiplayerPeer] del servidor que filtra los paquetes antes de que los vea
## [SceneMultiplayer] (docs/red.md, secciones 2 y 12).
## [br][br]
## [b]Por qué.[/b] [SceneMultiplayer] procesa dentro de [code]poll()[/code] todo lo que llega, y solo
## entrega a la aplicación los paquetes RAW de los peers ya admitidos. Un cliente ENet sin
## [SceneMultiplayer] (un atacante) que mande otra cosa antes del HELLO o después de él (RPC, rutas
## simplificadas, SPAWN, órdenes de sistema...) hacía que el motor registrase un error por paquete
## (cada uno con su traza de GDScript: 2000 paquetes eran 742 KB de registro y un tick de 28 ms), que
## esos paquetes no pasaran por los limitadores ni sumaran avisos, y que antes del HELLO solo los
## cortase el [code]auth_timeout[/code] de 5 s (hallazgo S1 de la revisión de la fase 2).
## [br][br]
## [b]Qué deja pasar.[/b] Con el formato interno de [SceneMultiplayer] (el byte 0 &amp; 7 es el
## comando; RAW = 3, SYS = 7; el byte 1 de un SYS es el subcomando; AUTH = 0):
## [br]- A un peer que aún no está admitido (le falta su confirmación o la nuestra): solo mensajes
## de autenticación, es decir, SYS + AUTH, de como mucho [constant MAX_AUTH_BYTES] bytes y como mucho
## [constant MAX_AUTH_PAYLOADS] con contenido (el HELLO) más una confirmación de 2 bytes.
## [br]- A un peer admitido (los dos lados han confirmado): solo RAW.
## [br]Todo lo demás se descarta aquí, sin error del motor, y se cuenta: al final de cada
## [method poll] se emite [signal packets_discarded] con el número por peer, para que el servidor
## sume avisos. Un peer silenciado con [method mute_peer] (el servidor ya lo está cortando) se
## descarta sin contar.
## [br][br]
## [b]Estado.[/b] El envoltorio sabe que un peer está admitido porque ve pasar, en un sentido,
## la confirmación de 2 bytes [code][SYS, AUTH][/code] del otro lado y, en el otro, la nuestra
## ([method _put_packet_script]): [SceneMultiplayer] admite al peer exactamente cuando se han
## cruzado las dos. Si una versión futura del motor cambiara ese formato, el apretón de manos
## dejaría de completarse y las pruebas de [code]test_net_sim.gd[/code] lo detectarían.
## [br][br]
## [b]Atajo.[/b] Para los peers que [SceneMultiplayer] ya ha admitido de verdad ([member admitted],
## que rellena el dueño con sus señales), los paquetes RAW no pasan por la cola de
## [SceneMultiplayer]: se entregan directamente a [member raw_sink]. Es el camino caliente (las
## entradas de todos los jugadores, cada tick) y así el filtro apenas cuesta algo por paquete.
## Medido con 64 clientes mandando 48 000 paquetes en total (cinco repeticiones alternadas): 9,4 µs
## por paquete sin filtro, 9,9 µs con filtro y atajo (+0,6 µs, +6 %, el nivel del ruido de la
## medida: 0,05 ms por tick con 64 jugadores) y 11,3 µs con filtro y sin atajo (+25 %). Un paquete de
## un peer que se admite en esta misma llamada a [method poll] va por la cola, detrás de su
## confirmación, para que el orden se conserve.
## [br][br]
## Compartido: no lee el reloj ni depende de cliente ni de servidor.

## Se emite al final de [method poll], una vez por peer del que se han descartado paquetes en esa
## llamada.
signal packets_discarded(peer_id: int, count: int)

## Comandos de [SceneMultiplayer] (los 3 bits bajos del byte 0).
const COMMAND_MASK: int = 7
const COMMAND_RAW: int = 3
const COMMAND_SYS: int = 7
## Subcomando de autenticación dentro de SYS (byte 1).
const SYS_AUTH: int = 0
## Mensajes de autenticación con contenido que se admiten de un peer sin admitir: el HELLO.
const MAX_AUTH_PAYLOADS: int = 3
## Tamaño máximo de un mensaje de autenticación (el HELLO más grande cabe de sobra).
const MAX_AUTH_BYTES: int = 1200
## Tamaño máximo de paquete que declara a [SceneMultiplayer] (el mismo que ENetMultiplayerPeer).
const MAX_PACKET_SIZE: int = 1 << 24
## Paquetes como mucho que se procesan en cada [method poll]; el resto se queda en la cola de ENet
## para la siguiente. Acota lo que cuesta una inundación en un solo tick.
const MAX_PACKETS_PER_POLL: int = 4096

## Peers que [SceneMultiplayer] ya ha admitido (la clave es el id). Lo rellena el dueño.
var admitted: Dictionary = {}
## [code](peer_id: int, payload: PackedByteArray) -> void[/code]: recibe los paquetes RAW de los
## peers de [member admitted], sin la cabecera de un byte.
var raw_sink: Callable = Callable()

var _inner: ENetMultiplayerPeer = null
var _target_peer: int = 0
var _transfer_channel: int = 0
var _transfer_mode: int = MultiplayerPeer.TRANSFER_MODE_RELIABLE

# Cola de lo que pasa el filtro y recogerá SceneMultiplayer, en columnas. _head es el siguiente.
var _queue_peers: PackedInt32Array = PackedInt32Array()
var _queue_packets: Array[PackedByteArray] = []
var _head: int = 0

# Por peer (id -> true / contador): confirmación recibida, confirmación enviada, mensajes de
# autenticación con contenido admitidos, silenciado.
var _remote_confirmed: Dictionary = {}
var _local_confirmed: Dictionary = {}
var _auth_payloads: Dictionary = {}
var _muted: Dictionary = {}
# Descartes de la llamada a poll() en curso: id -> cuántos.
var _discarded: Dictionary = {}
# Total de paquetes descartados desde que se creó (sin contar los de peers silenciados).
var _discarded_total: int = 0


## Envuelve a [param inner], que ya debe estar creado (como servidor o como cliente) y no usarse
## desde otro sitio como peer de multijugador. Después hay que dárselo a [SceneMultiplayer] a este
## objeto en vez de a [param inner].
func attach(inner: ENetMultiplayerPeer) -> void:
	_inner = inner
	_inner.peer_connected.connect(_on_inner_peer_connected)
	_inner.peer_disconnected.connect(_on_inner_peer_disconnected)


## Deja de vigilar los paquetes de [param peer_id]: todo lo que mande se descarta sin contar. Lo usa
## el transporte cuando el servidor ya está cortando a ese peer.
func mute_peer(peer_id: int) -> void:
	_muted[peer_id] = true


## Paquetes descartados en total por no ser del protocolo (sin contar los de peers silenciados).
func get_discarded_total() -> int:
	return _discarded_total


# --- MultiplayerPeerExtension -----------------------------------------------------------------

func _poll() -> void:
	if _inner == null:
		return
	_inner.poll()
	_drain_inner()


func _drain_inner() -> void:
	# Lo recogido en la llamada anterior ya se ha consumido: se reinicia la cola.
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
			# Atajo: un peer que SceneMultiplayer ya ha admitido solo puede mandar RAW, y esos
			# paquetes se entregan al dueño directamente (sin pasar por la cola de SceneMultiplayer).
			if bytes.size() > 0 and (bytes[0] & COMMAND_MASK) == COMMAND_RAW:
				raw_sink.call(sender, bytes.slice(1))
			else:
				_discarded[sender] = int(_discarded.get(sender, 0)) + 1
			continue
		# Un paquete vacío es el que devuelve get_packet() ante un error.
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


# true si el paquete de [param sender] es de los que SceneMultiplayer espera en su estado.
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
		# La confirmación del otro lado, una sola vez.
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


# SceneMultiplayer solo usa el modo y el canal de un paquete en las órdenes de sistema que se
# retransmiten (SYS RELAY), que aquí no pasan, así que no se guardan.
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
	# Nuestra confirmación de autenticación: a partir de aquí, y con la del otro lado, el peer
	# queda admitido.
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


# --- Internos ---------------------------------------------------------------------------------

func _reset_queue() -> void:
	_queue_peers.clear()
	_queue_packets.clear()
	_head = 0


# Un id de peer nuevo empieza sin estado: el motor reutiliza ids.
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
