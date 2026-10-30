class_name NetTransport
extends Node
## Capa fina sobre [ENetMultiplayerPeer] y [SceneMultiplayer] (ver docs/red.md, secciones 2, 3
## y 13).
##
## Solo hace tres cosas: conectar, autenticar ([method send_auth], [method complete_auth] y la
## señal [signal peer_authenticating]) y mover paquetes binarios ([method send] y la señal
## [signal packet_received]). No usa RPC, [MultiplayerSynchronizer] ni [MultiplayerSpawner]:
## predecir, interpolar y rebobinar exigen un tick explícito en cada dato.
## [br][br]
## Cada instancia tiene su propio [SceneMultiplayer], registrado en el árbol con
## [method SceneTree.set_multiplayer] bajo la ruta del nodo, así que caben varias en un mismo
## proceso (pruebas y enjambre de bots). Hay que añadirla al árbol antes de [method host] o
## [method connect_to]. Como [member SceneTree.multiplayer_poll] queda desactivado, el dueño llama
## a [method poll] al empezar su tick de física y a [method flush] al terminarlo: recibir,
## simular, enviar.
## [br][br]
## Reglas:
## [br]- Todas las señales se emiten desde [method poll], nunca desde dentro del motor, así que los
## oyentes pueden llamar a [method send], [method close] o [method host] con libertad.
## [br]- No se envía nada a un peer hasta que se le ha entregado [signal peer_connected] (en el
## cliente, el peer 1): antes, [method send] devuelve [constant ERR_UNAVAILABLE]. Enviar justo
## después de [method complete_auth] daría un error del motor en el servidor, porque el aviso de
## autenticación completada del otro lado llega en un paquete posterior.
## [br]- Canales: [constant NetProtocol.CH_INPUT] no fiable, [constant NetProtocol.CH_SNAPSHOT] no
## fiable y secuenciado, [constant NetProtocol.CH_RELIABLE] fiable.
## [br]- Con [method set_net_sim_spec], el [NetSim] retrasa (y pierde o duplica, si es no fiable)
## lo que sale y lo que entra. A la autenticación solo le añade retardo.
## [br]- Tras [signal connection_failed] o la pérdida del servidor, el cliente puede volver a llamar
## a [method connect_to] (o a [method close]).
## [br][br]
## Compartido: no lee el reloj. El tiempo es el tick que se pasa a [method poll].

## Un peer ha conectado y empieza su autenticación: es el momento de enviar HELLO (cliente) o de
## esperarlo (servidor). Después llegará [signal peer_connected] o, si falla,
## [signal peer_disconnected] (servidor) o [signal connection_failed] (cliente).
signal peer_authenticating(peer_id: int)
## Mensaje de autenticación del otro lado (tras el retardo del simulador, si lo hay).
signal auth_received(peer_id: int, bytes: PackedByteArray)
## Autenticación completada en ambos lados: ya se puede enviar con [method send].
signal peer_connected(peer_id: int)
## El peer se ha ido. También se emite, en el servidor, para un peer que estaba autenticándose y
## se pierde (tiempo agotado, corte, rechazo), para que se pueda limpiar lo creado en
## [signal peer_authenticating]. En el cliente se emite al perder el servidor ya conectado (el
## peer 1); si falla antes de conectar del todo se emite [signal connection_failed].
signal peer_disconnected(peer_id: int)
## Paquete de aplicación del peer, con el mensaje completo y sin tocar.
signal packet_received(peer_id: int, bytes: PackedByteArray)
## El cliente no ha podido conectar o autenticarse. Si antes llegó un REJECT por
## [signal auth_received], ese es el motivo.
signal connection_failed()

## Tiempo máximo de autenticación de [SceneMultiplayer] (segundos), en los dos lados y contado desde la
## conexión, no desde el HELLO. 10 s desde el protocolo 7 (docs/plataforma.md §5.2): deja sitio a la
## reclamación del billete, que la zona corta a los 7 s con un REJECT que siempre llega a tiempo.
const AUTH_TIMEOUT_SECONDS: float = 10.0
## Ticks que se deja a [method disconnect_after_flush] antes de cortar a la fuerza.
const FORCE_DISCONNECT_TICKS: int = 60
## Tiempos de espera de ENet tras conectar: una desconexión se detecta en 3-8 s.
const TIMEOUT_LIMIT: int = 32
const TIMEOUT_MIN_MS: int = 3000
const TIMEOUT_MAX_MS: int = 8000
## Estrangulamiento de ENet desactivado (deceleración 0). ENet tira paquetes no fiables cuando el
## RTT sube, y las entradas y los snapshots no deben perderse por eso: el ancho de banda ya lo
## limita el servidor (presupuesto del snapshot) y la pérdida la simula [NetSim].
const THROTTLE_INTERVAL_MS: int = 5000
const THROTTLE_ACCELERATION: int = 32
const THROTTLE_DECELERATION: int = 0
## Ticks entre dos lecturas de las estadísticas de ENet (el contador de ENet es de 32 bits).
const WIRE_SAMPLE_TICKS: int = 60
## Id del servidor visto desde el cliente.
const SERVER_PEER_ID: int = 1
## Escala de [constant ENetPacketPeer.PEER_PACKET_LOSS] (ENET_PEER_PACKET_LOSS_SCALE).
const PACKET_LOSS_SCALE: float = 65536.0

## Paquetes de un peer que se han descartado sin entregarlos porque no son del protocolo (ver
## [GuardedEnetPeer]): antes del HELLO, cualquier cosa que no sea autenticación; después, cualquier
## cosa que no sea un paquete de aplicación. Solo en el servidor. Lo normal es que el dueño sume un
## aviso por cada uno.
signal packets_discarded(peer_id: int, count: int)

# Tipos de evento pendientes de entregar a los oyentes.
const _EVENT_AUTHENTICATING: int = 0
const _EVENT_AUTH: int = 1
const _EVENT_CONNECTED: int = 2
const _EVENT_DISCONNECTED: int = 3
const _EVENT_PACKET: int = 4
const _EVENT_CONNECTION_FAILED: int = 5
const _EVENT_DISCARDED: int = 6


# Suceso que el motor ha producido dentro de poll() y que se entrega al terminar.
class _Event:
	var kind: int = 0
	var peer_id: int = 0
	var bytes: PackedByteArray = PackedByteArray()
	## Solo en _EVENT_DISCARDED: cuántos paquetes.
	var count: int = 0

	func _init(p_kind: int, p_peer_id: int = 0,
			p_bytes: PackedByteArray = PackedByteArray()) -> void:
		kind = p_kind
		peer_id = p_peer_id
		bytes = p_bytes


var _mp: SceneMultiplayer = null
var _enet: ENetMultiplayerPeer = null
# Filtro de paquetes entre ENet y SceneMultiplayer (solo en el servidor; null en el cliente).
var _guard: GuardedEnetPeer = null
var _is_server: bool = false
var _now_tick: int = 0
# Sube con cada close(): corta el reparto de eventos si un oyente cierra el transporte.
var _epoch: int = 0
var _sim_spec: String = ""
var _out_sim: NetSim = null
var _in_sim: NetSim = null
# Peers por id. _authenticating: en autenticación. _mp_connected: SceneMultiplayer los da por
# conectados. _connected: además ya se les ha entregado peer_connected (solo a estos se envía).
# _closing: con corte pendiente (peer_id -> tick límite).
var _authenticating: Dictionary = {}
var _mp_connected: Dictionary = {}
var _connected: Dictionary = {}
var _closing: Dictionary = {}
# Peers a los que ya se ha llamado a complete_auth() (después ya no admiten send_auth()).
var _local_auth_done: Dictionary = {}
var _events: Array[_Event] = []
# Desconexiones que esperan a que salgan los paquetes retrasados del peer.
var _parked: Array[_Event] = []
var _client_connected: bool = false
var _client_failed: bool = false
var _app_in: int = 0
var _app_out: int = 0
var _wire_in: int = 0
var _wire_out: int = 0
var _last_wire_sample_tick: int = 0


func _enter_tree() -> void:
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
	# poll() llama a mano a SceneMultiplayer.poll(): que el árbol no lo haga además.
	tree.multiplayer_poll = false
	tree.set_multiplayer(_mp, get_path())


func _exit_tree() -> void:
	close()
	var tree: SceneTree = get_tree()
	if tree != null:
		tree.set_multiplayer(null, get_path())
	_mp = null


## Configura el simulador de red con el texto de [code]--net-sim[/code] (ver
## [method NetSim.from_arg]). Vacío = sin simulador. Se aplica a la salida (semilla
## [code]seed[/code]) y a la entrada ([code]seed + 1[/code]). Hay que llamarlo antes de
## [method host] o [method connect_to]; si se llama después, se descarta lo que el simulador
## tuviera en cola.
func set_net_sim_spec(spec: String) -> void:
	_sim_spec = spec
	_create_sims()


## Abre un servidor ENet en [param port] para [param max_peers] peers. El transporte debe estar en
## el árbol. Si el puerto está ocupado devuelve un error (y el motor lo registra).
func host(port: int, max_peers: int) -> Error:
	if _mp == null:
		return ERR_UNCONFIGURED
	if _is_active():
		return ERR_ALREADY_IN_USE
	var peer := ENetMultiplayerPeer.new()
	var err: Error = peer.create_server(port, max_peers, NetProtocol.CUSTOM_CHANNELS)
	if err != OK:
		return err
	_attach(peer, true)
	return OK


## Empieza a conectar con el servidor en [param address]:[param port]. El resultado llega por
## [signal peer_authenticating] (peer 1) y [signal peer_connected], o por [signal connection_failed]
## pasado como mucho el doble de [param connect_timeout_ms] (en la práctica, entre 1 y 1,5 veces: ENet
## solo comprueba el plazo al retransmitir el CONNECT). El transporte debe estar en el árbol.
func connect_to(address: String, port: int, connect_timeout_ms: int = 3000) -> Error:
	if _mp == null:
		return ERR_UNCONFIGURED
	if _is_active():
		return ERR_ALREADY_IN_USE
	var peer := ENetMultiplayerPeer.new()
	var err: Error = peer.create_client(address, port, NetProtocol.CUSTOM_CHANNELS)
	if err != OK:
		return err
	# Mientras conecta se usa un tiempo corto; al conectar pasa al normal (ver
	# _on_peer_authenticating). El mínimo y el máximo son el mismo: ENet solo mira el plazo cuando
	# vence una retransmisión del CONNECT (a los 0,5, 1,5, 3,5 y 7,5 s), y con un máximo del doble
	# tardaba 3,5 s en rendirse con 1000 ms y 7,5 s con 3000 ms.
	for packet_peer: ENetPacketPeer in peer.host.get_peers():
		packet_peer.set_timeout(TIMEOUT_LIMIT, connect_timeout_ms, connect_timeout_ms)
	_attach(peer, false)
	return OK


## true si este transporte es un servidor.
func is_server() -> bool:
	return _is_server


## Envía [param bytes] al peer por [param channel] ([constant NetProtocol.CH_INPUT],
## [constant NetProtocol.CH_SNAPSHOT] o [constant NetProtocol.CH_RELIABLE]); el modo de
## transferencia sale del canal ([method NetProtocol.transfer_mode]). Devuelve
## [constant ERR_UNAVAILABLE] si el peer aún no está conectado (o ya se está cerrando). Con el
## simulador, el paquete sale en algún [method flush] posterior; sin él, en el siguiente. Los
## paquetes no fiables de más de [constant NetProtocol.MAX_PACKET_BYTES] se rechazan (ENet los
## fragmentaría y perder un fragmento tiraría el paquete entero).
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


## Envía un mensaje de autenticación (HELLO, WELCOME, REJECT) a un peer que se está
## autenticando. Devuelve [constant ERR_UNAVAILABLE] si el peer no está en ese estado o ya se ha
## llamado a [method complete_auth] para él. Con el simulador solo se retrasa.
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


## Da por buena la autenticación del peer por este lado. Cuando los dos lados la han completado
## llega [signal peer_connected]. Con el simulador se retrasa igual que los mensajes de
## autenticación, y siempre después de los que ya estaban en cola.
func complete_auth(peer_id: int) -> Error:
	if _mp == null or _enet == null:
		return ERR_UNCONFIGURED
	if not _authenticating.has(peer_id) or _local_auth_done.has(peer_id) \
			or _closing.has(peer_id):
		return ERR_UNAVAILABLE
	_local_auth_done[peer_id] = true
	if _out_sim != null:
		# Un paquete de autenticación vacío es la marca de "completar" (nunca se envía vacío).
		_out_sim.enqueue(NetSim.Packet.new(peer_id, NetSim.AUTH_CHANNEL, PackedByteArray(), true),
				_now_tick)
		return OK
	return _complete_auth_now(peer_id)


## Vacía lo que el simulador retiene para el peer (sin esperar su retardo), lo manda a ENet y pide
## el corte con [method ENetPacketPeer.peer_disconnect_later], que deja salir antes lo encolado
## (por ejemplo un REJECT o un NOTICE de expulsión). Como red de seguridad, si el peer sigue ahí
## a los [constant FORCE_DISCONNECT_TICKS] ticks, lo corta a la fuerza. Desde ese momento
## [method send] y [method send_auth] devuelven [constant ERR_UNAVAILABLE] para ese peer.
func disconnect_after_flush(peer_id: int) -> void:
	if _enet == null or not _is_known(peer_id) or _closing.has(peer_id):
		return
	if _out_sim != null:
		for packet: NetSim.Packet in _out_sim.drain_peer(peer_id):
			_send_packet_now(packet)
	_flush_host()
	var packet_peer: ENetPacketPeer = _enet.get_peer(peer_id)
	if packet_peer != null:
		packet_peer.peer_disconnect_later()
	if _guard != null:
		# Ya se le está cortando: lo que siga mandando se descarta sin contarlo.
		_guard.mute_peer(peer_id)
	_closing[peer_id] = _now_tick + FORCE_DISCONNECT_TICKS


## Recibe lo que ha llegado, entrega las señales y avanza el simulador. Se llama una vez al
## empezar el tick de física [param now_tick] del dueño.
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


## Envía los paquetes del simulador que vencen en este tick y vuelca a ENet todo lo encolado. Se
## llama una vez al terminar el tick de física del dueño.
func flush() -> void:
	if _enet == null:
		return
	if _out_sim != null:
		for packet: NetSim.Packet in _out_sim.pop_due(_now_tick):
			_send_packet_now(packet)
	_flush_host()


## Cierra el transporte: manda lo que el simulador retenía, avisa a los peers y libera el puerto.
## No emite señales. Después se puede volver a llamar a [method host] o [method connect_to]. Se
## llama sola al salir del árbol.
## [br][br]
## El corte es inmediato y ENet descarta en el receptor lo que aún no ha entregado. Para que un
## último mensaje (CLIENT_LEAVE, un NOTICE de cierre) llegue seguro, hay que usar antes
## [method disconnect_after_flush] y cerrar cuando llegue [signal peer_disconnected].
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


## RTT de ENet con el peer en milisegundos (no incluye el retardo del simulador), o 0 si no se
## conoce.
func get_rtt_ms(peer_id: int) -> float:
	var packet_peer: ENetPacketPeer = _get_packet_peer(peer_id)
	if packet_peer == null:
		return 0.0
	return packet_peer.get_statistic(ENetPacketPeer.PEER_ROUND_TRIP_TIME)


## Retardo máximo (ticks) que los simuladores de este transporte añaden a un viaje de ida y vuelta
## con el peer: el de salida más el de entrada. 0 sin simulador. Sirve para separar el RTT real del
## simulado (ver [method get_rtt_ms], que no incluye el simulador).
func get_sim_round_trip_ticks() -> int:
	var ticks: int = 0
	if _out_sim != null:
		ticks += _out_sim.get_max_delay_ticks()
	if _in_sim != null:
		ticks += _in_sim.get_max_delay_ticks()
	return ticks


## Pérdida de paquetes fiables con el peer según ENet, como fracción de 0 a 1 (no incluye la
## del simulador), o 0 si no se conoce.
func get_packet_loss(peer_id: int) -> float:
	var packet_peer: ENetPacketPeer = _get_packet_peer(peer_id)
	if packet_peer == null:
		return 0.0
	return packet_peer.get_statistic(ENetPacketPeer.PEER_PACKET_LOSS) / PACKET_LOSS_SCALE


## Dirección IP del peer (vacía si no se conoce). Ya sirve durante la autenticación.
func get_remote_address(peer_id: int) -> String:
	var packet_peer: ENetPacketPeer = _get_packet_peer(peer_id)
	if packet_peer == null:
		return ""
	return packet_peer.get_remote_address()


## Bytes acumulados desde que se creó el transporte:
## [code]{"app_in": int, "app_out": int, "wire_in": int, "wire_out": int}[/code].
## [br]- [code]app_*[/code]: bytes de aplicación, tal como los ven [method send],
## [method send_auth] y las señales [signal packet_received] y [signal auth_received] (lo que el
## simulador pierde no llega, y no cuenta).
## [br]- [code]wire_*[/code]: bytes que ENet ha recibido y enviado por el socket (con sus
## cabeceras, sin las de UDP/IP).
func get_byte_counters() -> Dictionary:
	_sample_wire_stats()
	return {
		"app_in": _app_in,
		"app_out": _app_out,
		"wire_in": _wire_in,
		"wire_out": _wire_out,
	}


# --- Internos ---------------------------------------------------------------------------------

func _create_sims() -> void:
	_out_sim = NetSim.from_arg(_sim_spec, 0)
	_in_sim = NetSim.from_arg(_sim_spec, 1)
	if _out_sim != null and not _out_sim.is_enabled():
		_out_sim = null
	if _in_sim != null and not _in_sim.is_enabled():
		_in_sim = null


func _attach(peer: ENetMultiplayerPeer, as_server: bool) -> void:
	# Medido en Godot 4.7.2: sin esta llamada ENet baja de forma intermitente el límite de
	# estrangulamiento de los peers a 1/32 y tira entre el 20 % y el 65 % de los paquetes no
	# fiables incluso en loopback. Con 0, 0 (sin límite de ancho de banda) llegan todos.
	peer.host.bandwidth_limit(0, 0)
	_enet = peer
	_is_server = as_server
	_client_connected = false
	_client_failed = false
	if as_server:
		# El servidor no deja que SceneMultiplayer vea nada que no sea de su protocolo: cada paquete
		# ajeno registraría un error del motor y se saltaría los limitadores (hallazgo S1).
		_guard = GuardedEnetPeer.new()
		_guard.attach(peer)
		_guard.packets_discarded.connect(_on_packets_discarded)
		_guard.admitted = _mp_connected
		_guard.raw_sink = _on_peer_packet
		_mp.multiplayer_peer = _guard
	else:
		_mp.multiplayer_peer = peer


# Cierra el peer de ENet sin avisar a los oyentes y deja el transporte listo para reutilizarse.
func _teardown() -> void:
	if _enet != null:
		_sample_wire_stats()
		if _mp != null:
			_mp.multiplayer_peer = null
		if _guard != null:
			# Cierra también el peer de ENet y suelta sus señales (si no, se quedarían referenciados).
			_guard.close()
		else:
			_enet.close()
	_reset_state()


func _reset_state() -> void:
	_enet = null
	_guard = null
	_is_server = false
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


# true si hay un peer de ENet en marcha. Si el cliente perdió o no logró la conexión, el peer
# ha quedado muerto: se limpia aquí para poder volver a llamar a host() o connect_to().
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


# La conexión de ENet, o null si el peer no está activo (acceder a [code]host[/code] entonces
# registra un error del motor).
func _get_host() -> ENetConnection:
	if _enet == null or _enet.get_connection_status() == MultiplayerPeer.CONNECTION_DISCONNECTED:
		return null
	return _enet.host


func _flush_host() -> void:
	var connection: ENetConnection = _get_host()
	if connection != null:
		connection.flush()


# El contador de ENet se pone a 0 al leerlo y es de 32 bits: se acumula aquí.
func _sample_wire_stats() -> void:
	var connection: ENetConnection = _get_host()
	if connection == null:
		return
	_wire_in += int(connection.pop_statistic(ENetConnection.HOST_TOTAL_RECEIVED_DATA))
	_wire_out += int(connection.pop_statistic(ENetConnection.HOST_TOTAL_SENT_DATA))


# --- Salida real (tras el simulador) ----------------------------------------------------------

# Entrega a ENet un paquete del simulador de salida cuando vence.
func _send_packet_now(packet: NetSim.Packet) -> void:
	if not packet.is_auth:
		_send_now(packet.peer_id, packet.channel, packet.bytes)
	elif packet.bytes.is_empty():
		_complete_auth_now(packet.peer_id)
	else:
		_send_auth_now(packet.peer_id, packet.bytes)


# Los errores se ignoran a propósito en el camino retrasado: si el peer se ha ido por el camino,
# el paquete se descarta, como haría una red real.
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


# --- Cortes -----------------------------------------------------------------------------------

# Corta a la fuerza los peers cuyo disconnect_after_flush() no ha terminado a tiempo.
func _force_pending_disconnects() -> void:
	if _closing.is_empty():
		return
	for peer_id: int in _closing.keys():
		if _now_tick < int(_closing[peer_id]):
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


func _forget_peer(peer_id: int) -> void:
	_authenticating.erase(peer_id)
	_mp_connected.erase(peer_id)
	_connected.erase(peer_id)
	_closing.erase(peer_id)
	_local_auth_done.erase(peer_id)
	if _out_sim != null:
		_out_sim.drain_peer(peer_id)


# Apunta la pérdida de un peer. Con el simulador de entrada, la señal espera a que se entreguen los
# paquetes que ese peer tenía en tránsito, para no avisar del corte antes de lo que mandó.
func _queue_disconnect(peer_id: int, was_connected: bool) -> void:
	if _is_server or was_connected:
		var event := _Event.new(_EVENT_DISCONNECTED, peer_id)
		if _in_sim != null:
			_parked.append(event)
		else:
			_events.append(event)
	else:
		_fail_client()


# El cliente no ha llegado a conectar: se avisa una sola vez. Como las desconexiones, espera a que
# se entregue lo que el servidor tuviera en tránsito (por ejemplo un REJECT retrasado).
func _fail_client() -> void:
	if _client_failed:
		return
	_client_failed = true
	var event := _Event.new(_EVENT_CONNECTION_FAILED, SERVER_PEER_ID)
	if _in_sim != null:
		_parked.append(event)
	else:
		_events.append(event)


# --- Manejadores de SceneMultiplayer (dentro de mp.poll(): solo apuntan, no avisan) --------------

func _on_peer_authenticating(peer_id: int) -> void:
	_authenticating[peer_id] = true
	# Ya hay conexión ENet: pasa del tiempo de conexión al de régimen normal.
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
	# Ya se ha avisado con peer_disconnected (si estaba conectado) o con la autenticación fallida.
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


# --- Reparto de eventos -----------------------------------------------------------------------

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
			# Desde ahora se puede enviar a este peer (si no se ha perdido entretanto).
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
