extends TestCase
## Pruebas de NetSim (simulador de red en ticks) y de NetTransport sobre ENet real en 127.0.0.1.
##
## NetSim: misma semilla, misma secuencia; la pérdida no toca los canales fiables; los fiables
## salen en orden FIFO por (peer, canal); el retardo cae dentro de rtt/2 ± jitter.
## [br][br]
## NetTransport: un servidor y un cliente en el mismo proceso (dos nodos, cada uno con su
## [SceneMultiplayer] registrado por ruta), el handshake con send_auth/complete_auth en los dos
## lados, un paquete por canal después de peer_connected, el rechazo con corte ordenado, el fallo de
## conexión y el simulador aplicado a un lado. El ejecutor falla ante cualquier error del motor, así
## que cada una de estas pruebas también comprueba que no se envía nada antes de peer_connected.

const TICK_MS: float = 1000.0 / 60.0
## Primer puerto que se prueba para los servidores de las pruebas (se desplaza por proceso para no
## chocar con otras ejecuciones a la vez).
const FIRST_PORT: int = 24700
const MAX_HANDSHAKE_TICKS: int = 400

const HELLO: PackedByteArray = [0x45, 0x4C, 0x44, 0x4D, 0x01]
const WELCOME: PackedByteArray = [0x45, 0x4C, 0x44, 0x4D, 0x00, 0x77]
const REJECT: PackedByteArray = [0x45, 0x4C, 0x44, 0x4D, 0x03, 0x78]

## Tipos de mensaje de prueba, uno por canal y sentido.
const TYPE_UP_UNRELIABLE: int = NetProtocol.MSG_INPUT_BATCH
const TYPE_UP_RELIABLE: int = NetProtocol.MSG_CLIENT_READY
const TYPE_DOWN_UNRELIABLE: int = NetProtocol.MSG_SNAPSHOT
const TYPE_DOWN_RELIABLE: int = NetProtocol.MSG_ENTITY_SPAWN

## Claves de las latencias que devuelve _measure_latencies().
const LATENCY_KEYS: Array[String] = [
	"up_unreliable", "up_reliable", "down_unreliable", "down_reliable",
]

var _tick: int = 0
var _port: int = 0
var _nodes: Array[NetTransport] = []


## Un extremo de la prueba: un NetTransport más el registro de todo lo que le llega.
class Endpoint:
	extends RefCounted

	var transport: NetTransport
	var tick: int = 0
	## En el servidor: contesta REJECT y corta, en lugar de WELCOME.
	var reject: bool = false
	var authenticating: Array[int] = []
	## get_remote_address() de cada peer en el momento de peer_authenticating.
	var authenticating_addresses: Array[String] = []
	var auth_messages: Array[PackedByteArray] = []
	var connected: Array[int] = []
	var disconnected: Array[int] = []
	var failed_count: int = 0
	## Cada paquete recibido: [tick de llegada, peer_id, bytes].
	var packets: Array[Array] = []
	## Resultados de send() hechos antes de peer_connected (todos deben ser ERR_UNAVAILABLE).
	var early_sends: Array[int] = []
	## Orden en que llegan las señales: "authenticating", "auth", "connected", "packet",
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
		# Justo después de complete_auth() el peer aún no está conectado en este lado.
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
	assert_null(NetSim.from_arg(""), "un texto vacío no crea simulador")
	assert_null(NetSim.from_arg("   "), "solo espacios tampoco")

	var sim: NetSim = NetSim.from_arg("rtt=120,jitter=20,loss=5,dup=1.5,seed=7")
	if not assert_not_null(sim, "el texto de --net-sim se interpreta"):
		return
	assert_true(sim.is_enabled())
	var text: String = sim.describe()
	assert_true(text.contains("rtt=120"), "describe() incluye el rtt: %s" % text)
	assert_true(text.contains("jitter=20"), "describe() incluye el jitter: %s" % text)
	assert_true(text.contains("pérdida=5%"), "describe() incluye la pérdida: %s" % text)
	assert_true(text.contains("duplicados=1.5%"), "describe() incluye los duplicados: %s" % text)
	assert_true(text.contains("semilla=7"), "describe() incluye la semilla: %s" % text)

	assert_true(NetSim.from_arg("rtt=120,seed=7", 1).describe().contains("semilla=8"),
			"el desplazamiento de semilla se suma")
	assert_true(NetSim.from_arg("rtt=120").describe().contains("semilla=1"),
			"sin semilla vale 1")

	var tolerant: NetSim = NetSim.from_arg(" rtt = 100 , bogus=3, jitter=abc, loss ,dup=2 ")
	if assert_not_null(tolerant, "las claves desconocidas y los valores inválidos se ignoran"):
		var tolerant_text: String = tolerant.describe()
		assert_true(tolerant_text.contains("rtt=100"), tolerant_text)
		assert_true(tolerant_text.contains("jitter=0"), tolerant_text)
		assert_true(tolerant_text.contains("duplicados=2%"), tolerant_text)

	var idle: NetSim = NetSim.from_arg("seed=3")
	if assert_not_null(idle, "un texto sin parámetros útiles sigue creando el objeto"):
		assert_false(idle.is_enabled(), "pero no hace nada")

	var clamped := NetSim.new()
	clamped.configure(-10, -5, 250.0, -3.0, 1)
	assert_true(clamped.is_enabled(), "con la pérdida limitada a 100 % queda activo")
	assert_true(clamped.describe().contains("pérdida=100%"), clamped.describe())
	assert_true(clamped.describe().contains("rtt=0"), clamped.describe())


func test_same_seed_gives_same_sequence() -> void:
	var spec: String = "rtt=100,jitter=40,loss=20,dup=15,seed=42"
	var first: Array[Array] = _run_sequence(NetSim.from_arg(spec), 600)
	var second: Array[Array] = _run_sequence(NetSim.from_arg(spec), 600)
	assert_false(first.is_empty(), "la secuencia no está vacía")
	assert_true(first == second, "misma semilla, misma secuencia")

	var other_seed: Array[Array] = _run_sequence(
			NetSim.from_arg("rtt=100,jitter=40,loss=20,dup=15,seed=43"), 600)
	assert_false(first == other_seed, "otra semilla, otra secuencia")

	# La salida y la entrada de un transporte usan seed y seed + 1: no deben ser la misma.
	var output_side: Array[Array] = _run_sequence(NetSim.from_arg(spec, 0), 600)
	var input_side: Array[Array] = _run_sequence(NetSim.from_arg(spec, 1), 600)
	assert_true(output_side == first, "el desplazamiento 0 es la semilla tal cual")
	assert_false(output_side == input_side, "el desplazamiento 1 cambia la secuencia")

	# configure() reinicia el generador: repetir la configuración repite la secuencia.
	var reused := NetSim.new()
	reused.configure(100, 40, 20.0, 15.0, 42)
	var before: Array[Array] = _run_sequence(reused, 300)
	reused.configure(100, 40, 20.0, 15.0, 42)
	var after: Array[Array] = _run_sequence(reused, 300)
	assert_true(before == after, "configure() con la misma semilla repite la secuencia")


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
	assert_false(per_channel.has("1"), "con loss=100 no llega ningún paquete del canal 1")
	assert_false(per_channel.has("2"), "con loss=100 no llega ningún paquete del canal 2")
	assert_eq(per_channel.get("3", 0), count, "el canal fiable llega entero, sin duplicados")
	assert_eq(per_channel.get("auth", 0), count, "la autenticación llega entera, sin duplicados")
	assert_eq(sim.get_pending_count(), 0, "no queda nada en cola")

	# Con una pérdida parcial, los fiables siguen intactos y los demás pierden aproximadamente eso.
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
	assert_eq(got_reliable, total, "al 50 % de pérdida el canal fiable llega entero")
	assert_true(got_unreliable > total * 0.4 and got_unreliable < total * 0.6,
			"al 50 %% de pérdida llega más o menos la mitad de los no fiables (%d de %d)" % [
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
	assert_eq(counts.get("1", 0), 100, "con dup=100 cada paquete no fiable llega dos veces")
	assert_eq(counts.get("3", 0), 50, "los fiables no se duplican")
	assert_eq(counts.get("auth", 0), 50, "la autenticación no se duplica")


func test_reliable_channels_keep_fifo_order() -> void:
	# Con tanto jitter los no fiables se desordenan; los fiables, no.
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
	assert_eq(sim.get_pending_count(), 0, "se ha entregado todo")

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
				fail("%s: llegó %d después de %d (los fiables mantienen el orden)" % [
					key, seq, previous,
				])
				return
		elif seq < previous:
			reordered_unreliable += 1
		last_seen[key] = maxi(previous, seq)
	assert_eq(reliable_count, ticks * 2 * 2, "llegan todos los fiables y la autenticación")
	assert_true(reordered_unreliable > 0,
			"el jitter sí desordena los no fiables (si no, la prueba no probaría nada)")


func test_delay_is_within_half_rtt_plus_minus_jitter() -> void:
	# rtt=120, jitter=20: 60 ± 20 ms = de 40 a 80 ms = de 2,4 a 4,8 ticks = de 2 a 5 ticks.
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
			# Un solo paquete cada vez y un tick de salida distinto: sin efecto del orden FIFO.
			var now: int = i * 100
			sim.enqueue(packet, now)
			var delay: int = packet.due_tick - now
			seen[delay] = true
			if delay < low or delay > high:
				fail("canal %d: retardo %d fuera de [%d, %d]" % [channel, delay, low, high])
				return
			sim.pop_due(now + 100)
		assert_true(seen.has(low) and seen.has(high),
				"canal %d: el retardo recorre todo el intervalo (%s)" % [channel, seen.keys()])

	# Sin jitter el retardo es fijo: 100 ms de RTT = 50 ms por sentido = 3 ticks.
	var fixed: NetSim = NetSim.from_arg("rtt=100,seed=1")
	for i: int in 100:
		var packet: NetSim.Packet = _packet(1, NetProtocol.CH_INPUT, i)
		fixed.enqueue(packet, 10)
		assert_eq(packet.due_tick, 13, "retardo fijo de 3 ticks")
		fixed.pop_due(100)

	# Un retardo que saldría negativo se queda en 0.
	var clamped: NetSim = NetSim.from_arg("rtt=10,jitter=50,seed=2")
	var longest: int = 0
	for i: int in 500:
		var packet: NetSim.Packet = _packet(1, NetProtocol.CH_SNAPSHOT, i)
		clamped.enqueue(packet, 0)
		longest = maxi(longest, packet.due_tick)
		if packet.due_tick < 0:
			fail("retardo negativo: %d" % packet.due_tick)
			return
		clamped.pop_due(100)
	assert_eq(longest, roundi(55.0 / TICK_MS), "con rtt=10, jitter=50 el máximo es 55 ms")

	# Un simulador a cero entrega en el mismo tick.
	var idle := NetSim.new()
	idle.configure(0, 0, 0.0, 0.0, 1)
	assert_false(idle.is_enabled())
	var instant: NetSim.Packet = _packet(1, NetProtocol.CH_RELIABLE, 0)
	idle.enqueue(instant, 7)
	assert_eq(instant.due_tick, 7)
	assert_eq(idle.pop_due(7).size(), 1)


func test_pop_due_returns_only_due_packets_in_order() -> void:
	var sim: NetSim = NetSim.from_arg("rtt=100,seed=1")  # 3 ticks por sentido, sin jitter
	var late: NetSim.Packet = _packet(1, NetProtocol.CH_INPUT, 1)
	var early: NetSim.Packet = _packet(1, NetProtocol.CH_INPUT, 2)
	var tie: NetSim.Packet = _packet(2, NetProtocol.CH_INPUT, 3)
	sim.enqueue(late, 10)    # vence en el 13
	sim.enqueue(early, 4)    # vence en el 7
	sim.enqueue(tie, 10)     # vence en el 13, llegó después que late
	assert_eq(sim.get_pending_count(), 3)
	assert_eq(sim.pop_due(6).size(), 0, "todavía no vence nada")
	var first: Array[NetSim.Packet] = sim.pop_due(7)
	assert_eq(first.size(), 1)
	assert_true(first[0] == early, "sale primero el que vence antes")
	assert_true(sim.has_pending(1) and sim.has_pending(2))
	var rest: Array[NetSim.Packet] = sim.pop_due(50)
	assert_eq(rest.size(), 2)
	assert_true(rest[0] == late and rest[1] == tie, "a igualdad de tick, por orden de llegada")
	assert_eq(sim.get_pending_count(), 0)

	# drain_peer() saca todo lo de un peer, venza o no, y deja el resto.
	sim.enqueue(_packet(1, NetProtocol.CH_RELIABLE, 4), 0)
	sim.enqueue(_packet(2, NetProtocol.CH_RELIABLE, 5), 0)
	sim.enqueue(_packet(1, NetProtocol.CH_INPUT, 6), 1)
	var drained: Array[NetSim.Packet] = sim.drain_peer(1)
	assert_eq(drained.size(), 2)
	assert_eq(drained[0].bytes.decode_u32(0), 4, "en orden de entrega")
	assert_false(sim.has_pending(1))
	assert_true(sim.has_pending(2))
	assert_eq(sim.get_pending_count(), 1)


# --- NetTransport: ENet real en 127.0.0.1 -----------------------------------------------------

func test_transport_registers_its_own_multiplayer() -> void:
	var transport: NetTransport = _make_transport("NetTransportRegistered")
	var custom: MultiplayerAPI = tree.get_multiplayer(transport.get_path())
	assert_not_null(custom, "el transporte registra su SceneMultiplayer")
	assert_true(custom is SceneMultiplayer, "es un SceneMultiplayer")
	assert_true(custom != tree.get_multiplayer(), "distinto del multijugador por defecto del árbol")
	assert_false(tree.multiplayer_poll, "el árbol no sondea: lo hace NetTransport.poll()")
	var other: NetTransport = _make_transport("NetTransportOther")
	assert_true(tree.get_multiplayer(other.get_path()) != custom, "cada instancia tiene el suyo")

	var path: NodePath = transport.get_path()
	_nodes.erase(transport)
	transport.get_parent().remove_child(transport)
	assert_true(tree.get_multiplayer(path) == tree.get_multiplayer(),
			"al salir del árbol se quita el registro")
	transport.free()


func test_send_validates_before_touching_enet() -> void:
	var server: Endpoint = Endpoint.new(_make_transport("NetTransportValidate"))
	assert_eq(server.transport.send(5, NetProtocol.CH_RELIABLE, PackedByteArray([1])),
			ERR_UNCONFIGURED, "sin host() ni connect_to() no hay nada configurado")
	assert_eq(server.transport.send_auth(5, HELLO), ERR_UNCONFIGURED)
	assert_eq(server.transport.complete_auth(5), ERR_UNCONFIGURED)
	assert_eq(server.transport.get_rtt_ms(5), 0.0)
	assert_eq(server.transport.get_remote_address(5), "")
	var port: int = _find_free_port()
	if not assert_true(port > 0, "hay un puerto libre"):
		return
	assert_eq(server.transport.host(port, 4), OK)
	assert_true(server.transport.is_server())
	assert_eq(server.transport.host(port + 1, 4), ERR_ALREADY_IN_USE, "no se puede abrir dos veces")
	assert_eq(server.transport.connect_to("127.0.0.1", port), ERR_ALREADY_IN_USE)
	assert_eq(server.transport.send(123456, NetProtocol.CH_RELIABLE, PackedByteArray([1])),
			ERR_UNAVAILABLE, "a un peer desconocido no se envía")
	assert_eq(server.transport.send_auth(123456, HELLO), ERR_UNAVAILABLE)
	assert_eq(server.transport.complete_auth(123456), ERR_UNAVAILABLE)
	assert_eq(server.transport.get_remote_address(123456), "")
	server.transport.disconnect_after_flush(123456)  # un peer desconocido no hace nada
	server.transport.close()
	assert_false(server.transport.is_server(), "tras close() ya no es servidor")
	assert_eq(server.transport.send(5, NetProtocol.CH_RELIABLE, PackedByteArray([1])),
			ERR_UNCONFIGURED)


func test_handshake_and_one_packet_per_channel() -> void:
	var pair: Array[Endpoint] = _make_pair()
	var server: Endpoint = pair[0]
	var client: Endpoint = pair[1]
	var connected: bool = await _run_until(pair, func() -> bool:
		return not server.connected.is_empty() and not client.connected.is_empty(),
			MAX_HANDSHAKE_TICKS)
	if not assert_true(connected, "el handshake termina"):
		return
	var client_id: int = server.connected[0]
	assert_eq(server.authenticating, [client_id], "peer_authenticating del cliente en el servidor")
	assert_eq(client.authenticating, [1], "peer_authenticating del servidor (peer 1) en el cliente")
	assert_eq(client.connected, [1], "el cliente ve conectado al peer 1")
	assert_eq(server.auth_messages, [HELLO], "el servidor recibe el HELLO")
	assert_eq(client.auth_messages, [WELCOME], "el cliente recibe el WELCOME")
	assert_true(server.all_early_sends_unavailable(),
			"antes de peer_connected send() devuelve ERR_UNAVAILABLE (sin error del motor)")
	assert_true(client.all_early_sends_unavailable(),
			"incluso justo después de complete_auth() send() devuelve ERR_UNAVAILABLE")
	assert_false(server.early_sends.is_empty() or client.early_sends.is_empty(),
			"las comprobaciones de arriba sí se han hecho")

	# Un paquete por canal y sentido, con el contenido exacto.
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
	if not assert_true(arrived, "llegan los cuatro paquetes"):
		return
	assert_eq(server.packets.size(), 2)
	assert_eq(client.packets.size(), 2)
	var server_got: Array[Array] = server.packets_of_type(TYPE_UP_UNRELIABLE)
	assert_eq(server_got.size(), 1, "el servidor recibe el paquete del canal de entradas")
	assert_eq(server_got[0][1], client_id, "con el id del cliente")
	assert_eq(server_got[0][2], up_unreliable, "con el contenido intacto")
	assert_eq(server.packets_of_type(TYPE_UP_RELIABLE)[0][2], up_reliable,
			"el servidor recibe el paquete fiable")
	assert_eq(client.packets_of_type(TYPE_DOWN_UNRELIABLE)[0][2], down_unreliable,
			"el cliente recibe el snapshot")
	assert_eq(client.packets_of_type(TYPE_DOWN_RELIABLE)[0][1], 1, "del peer 1")
	assert_eq(client.packets_of_type(TYPE_DOWN_RELIABLE)[0][2], down_reliable,
			"el cliente recibe el paquete fiable")

	# Datos del peer y contadores.
	assert_eq(server.transport.get_remote_address(client_id), "127.0.0.1")
	assert_eq(client.transport.get_remote_address(1), "127.0.0.1")
	assert_true(server.transport.get_rtt_ms(client_id) >= 0.0)
	assert_true(server.transport.get_packet_loss(client_id) >= 0.0
			and server.transport.get_packet_loss(client_id) <= 1.0)
	var server_counters: Dictionary = server.transport.get_byte_counters()
	var client_counters: Dictionary = client.transport.get_byte_counters()
	var client_sent: int = HELLO.size() + up_unreliable.size() + up_reliable.size()
	var server_sent: int = WELCOME.size() + down_unreliable.size() + down_reliable.size()
	assert_eq(client_counters["app_out"], client_sent, "bytes de aplicación del cliente")
	assert_eq(server_counters["app_in"], client_sent, "y recibidos por el servidor")
	assert_eq(server_counters["app_out"], server_sent, "bytes enviados por el servidor")
	assert_eq(client_counters["app_in"], server_sent, "y recibidos por el cliente")
	for counters: Dictionary in [server_counters, client_counters]:
		assert_true(int(counters["wire_in"]) > 0 and int(counters["wire_out"]) > 0,
				"ENet cuenta bytes en el cable: %s" % [counters])
		assert_true(int(counters["wire_out"]) >= int(counters["app_out"]),
				"en el cable hay al menos lo que envió la aplicación: %s" % [counters])

	# El cliente se despide: el servidor lo nota y deja de enviarle.
	client.transport.close()
	var left: bool = await _run_until(pair, func() -> bool:
		return not server.disconnected.is_empty(), 120)
	assert_true(left, "el servidor nota que el cliente se ha ido")
	assert_eq(server.disconnected, [client_id])
	assert_eq(server.transport.send(client_id, NetProtocol.CH_RELIABLE, PackedByteArray([1])),
			ERR_UNAVAILABLE, "a un peer desconectado no se envía")
	assert_eq(client.disconnected.size(), 0, "close() no emite señales en quien cierra")
	assert_eq(client.failed_count, 0)


func test_send_rejects_invalid_packets() -> void:
	var pair: Array[Endpoint] = _make_pair()
	var server: Endpoint = pair[0]
	var client: Endpoint = pair[1]
	var connected: bool = await _run_until(pair, func() -> bool:
		return not client.connected.is_empty(), MAX_HANDSHAKE_TICKS)
	if not assert_true(connected, "el handshake termina"):
		return
	var transport: NetTransport = client.transport
	assert_eq(transport.send(1, 0, PackedByteArray([1])), ERR_INVALID_PARAMETER,
			"el canal 0 no existe")
	assert_eq(transport.send(1, NetProtocol.CUSTOM_CHANNELS + 1, PackedByteArray([1])),
			ERR_INVALID_PARAMETER, "tampoco el canal 4")
	assert_eq(transport.send(1, NetProtocol.CH_RELIABLE, PackedByteArray()), ERR_INVALID_PARAMETER,
			"un paquete vacío no se envía")
	var too_big := PackedByteArray()
	too_big.resize(NetProtocol.MAX_PACKET_BYTES + 1)
	too_big[0] = TYPE_UP_UNRELIABLE
	assert_eq(transport.send(1, NetProtocol.CH_INPUT, too_big), ERR_PARAMETER_RANGE_ERROR,
			"un paquete no fiable de más de 1200 B se rechaza")
	too_big.resize(NetProtocol.MAX_PACKET_BYTES)
	assert_eq(transport.send(1, NetProtocol.CH_INPUT, too_big), OK, "de 1200 B justos sí")
	assert_eq(transport.send_auth(1, HELLO), ERR_UNAVAILABLE,
			"una vez conectado ya no se envía autenticación")
	assert_eq(server.packets.size(), 0)


func test_reject_flushes_before_disconnect() -> void:
	await _check_reject("", "")


func test_reject_flushes_before_disconnect_with_net_sim() -> void:
	# Con retardo, el REJECT está en la cola del simulador cuando se pide el corte: tiene que salir.
	await _check_reject("rtt=200,jitter=30,seed=3", "")


func test_connection_failed_waits_for_the_delayed_reject() -> void:
	# Con el simulador en el cliente, el REJECT llega retrasado, pero el corte ya está hecho: la
	# señal connection_failed espera a que se entregue el REJECT.
	await _check_reject("", "rtt=300,jitter=40,seed=6")


func test_disconnect_after_flush_delivers_pending_packets() -> void:
	var pair: Array[Endpoint] = _make_pair("", "rtt=120,jitter=20,seed=4")
	var server: Endpoint = pair[0]
	var client: Endpoint = pair[1]
	var connected: bool = await _run_until(pair, func() -> bool:
		return not server.connected.is_empty() and not client.connected.is_empty(),
			MAX_HANDSHAKE_TICKS)
	if not assert_true(connected, "el handshake termina"):
		return
	var client_id: int = server.connected[0]
	var notice: PackedByteArray = PackedByteArray([
		NetProtocol.MSG_NOTICE, NetProtocol.NoticeCode.KICK, 9,
	])
	assert_eq(server.transport.send(client_id, NetProtocol.CH_RELIABLE, notice), OK)
	# El simulador (en el servidor) lo retiene unos ticks; el corte pedido ahora no debe perderlo.
	server.transport.disconnect_after_flush(client_id)
	assert_eq(server.transport.send(client_id, NetProtocol.CH_RELIABLE, notice), ERR_UNAVAILABLE,
			"tras pedir el corte ya no se envía a ese peer")
	var done: bool = await _run_until(pair, func() -> bool:
		return not client.disconnected.is_empty() and not server.disconnected.is_empty(), 300)
	if not assert_true(done, "ambos lados notan el corte"):
		return
	assert_eq(client.packets_of_type(NetProtocol.MSG_NOTICE).size(), 1,
			"el NOTICE llega antes del corte")
	assert_eq(client.packets_of_type(NetProtocol.MSG_NOTICE)[0][2], notice)
	assert_eq(client.disconnected, [1])
	assert_eq(server.disconnected, [client_id])
	assert_eq(client.failed_count, 0, "se había conectado: no es un fallo de conexión")


func test_disconnect_waits_for_delayed_packets() -> void:
	# El simulador de entrada del servidor retrasa el paquete de despedida; el cliente pide el corte
	# ordenado justo después de enviarlo. El servidor tiene que recibir el paquete antes de enterarse
	# del corte.
	var pair: Array[Endpoint] = _make_pair("", "rtt=200,jitter=20,seed=2")
	var server: Endpoint = pair[0]
	var client: Endpoint = pair[1]
	var connected: bool = await _run_until(pair, func() -> bool:
		return not server.connected.is_empty() and not client.connected.is_empty(),
			MAX_HANDSHAKE_TICKS)
	if not assert_true(connected, "el handshake termina"):
		return
	var client_id: int = server.connected[0]
	var leave: PackedByteArray = PackedByteArray([NetProtocol.MSG_CLIENT_LEAVE, 0])
	assert_eq(client.transport.send(1, NetProtocol.CH_RELIABLE, leave), OK)
	client.transport.disconnect_after_flush(1)
	var done: bool = await _run_until(pair, func() -> bool:
		return not server.disconnected.is_empty(), 300)
	if not assert_true(done, "el servidor acaba enterándose del corte"):
		return
	assert_eq(server.packets_of_type(NetProtocol.MSG_CLIENT_LEAVE).size(), 1,
			"recibe el paquete de despedida")
	assert_eq(server.disconnected, [client_id])
	var log: Array[String] = server.event_log
	assert_eq(log.slice(log.size() - 2), ["packet", "disconnected"],
			"primero el paquete, después el corte: %s" % [log])


func test_connect_to_closed_port_fails() -> void:
	var port: int = _find_free_port()
	if not assert_true(port > 0, "hay un puerto libre"):
		return
	var client: Endpoint = Endpoint.new(_make_transport("NetTransportLonely"))
	assert_eq(client.transport.connect_to("127.0.0.1", port, 250), OK)
	var one: Array[Endpoint] = [client]
	var failed: bool = await _run_until(one, func() -> bool:
		return client.failed_count > 0, 300)
	assert_true(failed, "sin servidor, la conexión falla")
	await _run_ticks(one, 20)
	assert_eq(client.failed_count, 1, "connection_failed se emite una sola vez")
	assert_true(client.authenticating.is_empty())
	assert_eq(client.connected.size(), 0)
	# Tras el fallo se puede volver a intentar sin llamar antes a close().
	assert_eq(client.transport.connect_to("127.0.0.1", port, 250), OK, "se puede reintentar")
	client.transport.close()


func test_net_sim_delays_packets_by_the_expected_ticks() -> void:
	# Referencia sin simulador: lo que tarda un paquete por el propio bucle de la prueba.
	var base: Dictionary = await _measure_latencies("", 60)
	var base_max: int = 0
	for key: String in LATENCY_KEYS:
		if not assert_eq(base[key].size(), 60, "sin simulador, %s: llegan los 60 paquetes" % key):
			return
		for latency: int in base[key]:
			if latency < 1 or latency > 2:
				fail("sin simulador, %s tarda %d ticks (se esperaba 1 o 2)" % [key, latency])
				return
			base_max = maxi(base_max, latency)

	# rtt=100 sin jitter solo en el cliente: 50 ms por sentido = 3 ticks exactos, en las dos
	# direcciones y en los dos tipos de canal.
	var fixed: Dictionary = await _measure_latencies("rtt=100,seed=1", 60)
	for key: String in LATENCY_KEYS:
		var latencies: Array = fixed[key]
		if not assert_eq(latencies.size(), 60, "%s: llegan los 60 paquetes" % key):
			return
		for latency: int in latencies:
			if latency < 3 + 1 or latency > 3 + base_max:
				fail("%s: %d ticks, se esperaban 3 más los del bucle (%d a %d)" % [
					key, latency, 3 + 1, 3 + base_max,
				])
				return

	# rtt=100 jitter=20: de 30 a 70 ms = de 1,8 a 4,2 ticks = de 2 a 4 ticks por sentido.
	var jittery: Dictionary = await _measure_latencies("rtt=100,jitter=20,seed=8", 120)
	var observed: Dictionary = {}
	for key: String in LATENCY_KEYS:
		var latencies: Array = jittery[key]
		if not assert_eq(latencies.size(), 120, "%s: llegan los 120 paquetes" % key):
			return
		for latency: int in latencies:
			observed[latency] = true
			if latency < 2 + 1 or latency > 4 + base_max:
				fail("%s: %d ticks, se esperaban de %d a %d" % [key, latency, 2 + 1, 4 + base_max])
				return
	assert_true(observed.size() >= 3, "el jitter se nota: latencias vistas %s" % [observed.keys()])

	# Los fiables llegan en el orden en que se enviaron aunque el jitter retrase cada uno distinto.
	assert_true(_is_sorted(jittery["up_reliable_seq"]), "fiables hacia el servidor, en orden")
	assert_true(_is_sorted(jittery["down_reliable_seq"]), "fiables hacia el cliente, en orden")


func test_net_sim_loss_drops_unreliable_but_not_reliable_packets() -> void:
	# Con loss=100 en el cliente, ni sus entradas llegan al servidor ni los snapshots le llegan a
	# él; lo fiable (y el propio handshake, que usa autenticación) pasa entero.
	var results: Dictionary = await _measure_latencies("rtt=60,jitter=10,loss=100,seed=2", 40)
	assert_eq(results["up_unreliable"].size(), 0, "las entradas del cliente se pierden")
	assert_eq(results["down_unreliable"].size(), 0, "los snapshots hacia el cliente se pierden")
	assert_eq(results["up_reliable"].size(), 40, "los fiables hacia el servidor llegan todos")
	assert_eq(results["down_reliable"].size(), 40, "los fiables hacia el cliente llegan todos")
	assert_true(_is_sorted(results["up_reliable_seq"]))
	assert_true(_is_sorted(results["down_reliable_seq"]))


func test_net_sim_on_both_sides_adds_up() -> void:
	# Con el simulador en los dos lados cada sentido lo paga dos veces: la salida de uno (3 ticks) y
	# la entrada del otro (3 ticks).
	var both: Dictionary = await _measure_latencies("rtt=100,seed=1", 30, "rtt=100,seed=5")
	for key: String in LATENCY_KEYS:
		var latencies: Array = both[key]
		if not assert_eq(latencies.size(), 30, "%s: llegan los 30 paquetes" % key):
			return
		for latency: int in latencies:
			if latency < 6 + 1 or latency > 6 + 2:
				fail("%s: %d ticks, se esperaban de 7 a 8 (6 simulados más el bucle)" % [
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
	if not assert_true(connected, "el handshake termina"):
		return
	var client_id: int = server.connected[0]
	# El cliente deja de atender la red, así que no puede confirmar el corte ordenado.
	var only_server: Array[Endpoint] = [server]
	var requested_at: int = _tick
	server.transport.disconnect_after_flush(client_id)
	await _run_ticks(only_server, NetTransport.FORCE_DISCONNECT_TICKS - 5)
	assert_true(server.disconnected.is_empty(), "antes de los 60 ticks el corte aún no es forzoso")
	var cut: bool = await _run_until(only_server, func() -> bool:
		return not server.disconnected.is_empty(), 20)
	if not assert_true(cut, "a los 60 ticks el servidor corta a la fuerza"):
		return
	var waited: int = _tick - requested_at
	assert_true(waited >= NetTransport.FORCE_DISCONNECT_TICKS
			and waited <= NetTransport.FORCE_DISCONNECT_TICKS + 2,
			"esperó %d ticks (se esperaban 60)" % waited)
	assert_eq(server.disconnected, [client_id], "y avisa una sola vez")
	await _run_ticks(only_server, 10)
	assert_eq(server.disconnected, [client_id], "aunque el motor avise después, no se repite")
	# El cliente vuelve a atender la red y se entera del corte.
	var noticed: bool = await _run_until(pair, func() -> bool:
		return not client.disconnected.is_empty(), 120)
	assert_true(noticed, "el cliente acaba enterándose")
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
	if not assert_true(connected, "los tres clientes terminan el handshake"):
		return
	assert_eq(server.authenticating.size(), 3)
	var ids: Dictionary = {}
	for peer_id: int in server.connected:
		ids[peer_id] = true
	assert_eq(ids.size(), 3, "cada cliente tiene un id distinto")
	assert_eq(server.authenticating_addresses, ["127.0.0.1", "127.0.0.1", "127.0.0.1"],
			"la dirección ya se conoce durante peer_authenticating")

	# El servidor manda a cada cliente un paquete distinto; cada cliente manda el suyo.
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
	if not assert_true(arrived, "llegan todos los paquetes"):
		return
	var from_clients: Dictionary = {}
	for entry: Array in server.packets:
		var bytes: PackedByteArray = entry[2]
		from_clients[int(entry[1])] = bytes.decode_u32(1)
	assert_eq(from_clients.size(), 3, "el servidor oye a los tres, cada uno con su id")
	for index: int in 3:
		var received: Array[Array] = clients[index].packets
		assert_eq(received.size(), 2, "cada cliente recibe sus dos paquetes y ninguno ajeno")
		var expected_id: int = (received[0][2] as PackedByteArray).decode_u32(1)
		assert_true(server.connected.has(expected_id), "con el id de su peer: %d" % expected_id)
		for entry: Array in received:
			assert_eq((entry[2] as PackedByteArray).decode_u32(1), expected_id)

	# Echar a uno no afecta a los demás.
	var kicked_id: int = server.connected[0]
	server.transport.disconnect_after_flush(kicked_id)
	var done: bool = await _run_until(everyone, func() -> bool:
		return not server.disconnected.is_empty() and not clients[0].disconnected.is_empty(), 200)
	assert_true(done, "el cliente echado se entera y el servidor también")
	assert_eq(server.disconnected, [kicked_id])
	assert_true(clients[1].disconnected.is_empty() and clients[2].disconnected.is_empty(),
			"los demás siguen conectados")
	assert_eq(server.transport.send(server.connected[1], NetProtocol.CH_RELIABLE,
			PackedByteArray([1])), OK, "y se les puede seguir enviando")


# --- Apoyo ------------------------------------------------------------------------------------

func _packet(peer_id: int, channel: int, seq: int, is_auth: bool = false) -> NetSim.Packet:
	var bytes := PackedByteArray()
	bytes.resize(4)
	bytes.encode_u32(0, seq)
	return NetSim.Packet.new(peer_id, channel, bytes, is_auth)


# Mete 'count' paquetes (uno por tick, repartidos entre dos peers y todos los canales) y devuelve
# lo que sale: [tick, peer, canal, es_auth, secuencia] por entrega.
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


# Servidor ya abierto en un puerto libre (el puerto queda en _port).
func _make_server(sim: String = "") -> Endpoint:
	var server := Endpoint.new(_make_transport("NetTransportServer"))
	server.transport.set_net_sim_spec(sim)
	_port = _find_free_port()
	assert_true(_port > 0, "hay un puerto libre")
	assert_eq(server.transport.host(_port, 8), OK, "el servidor abre el puerto %d" % _port)
	return server


# Cliente que empieza a conectar con el servidor de _make_server().
func _make_client(index: int = 0, sim: String = "") -> Endpoint:
	var client := Endpoint.new(_make_transport("NetTransportClient%d" % index))
	client.transport.set_net_sim_spec(sim)
	assert_eq(client.transport.connect_to("127.0.0.1", _port, 2000), OK)
	return client


# Servidor y cliente en el mismo proceso, ya lanzados, con un simulador opcional en cada uno.
func _make_pair(client_sim: String = "", server_sim: String = "") -> Array[Endpoint]:
	var server: Endpoint = _make_server(server_sim)
	var client: Endpoint = _make_client(0, client_sim)
	var pair: Array[Endpoint] = [server, client]
	return pair


# Primer puerto UDP libre a partir de FIRST_PORT (desplazado por proceso).
func _find_free_port() -> int:
	var start: int = FIRST_PORT + OS.get_process_id() % 40
	for port: int in range(start, start + 200):
		var probe := PacketPeerUDP.new()
		var err: Error = probe.bind(port, "*")
		probe.close()
		if err == OK:
			return port
	return -1


# Un tick del bucle del dueño: poll de todos, 'hook' (la simulación: aquí se envía) y flush de
# todos.
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


# Avanza ticks hasta que 'done' sea verdadero. Devuelve false si no ocurre en 'max_ticks'.
func _run_until(endpoints: Array[Endpoint], done: Callable, max_ticks: int,
		hook: Callable = Callable()) -> bool:
	for _i: int in max_ticks:
		await _step(endpoints, hook)
		if done.call():
			return true
	return false


# Mensaje de prueba de 9 bytes: tipo, secuencia (u32) y tick de envío (u32).
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


# Establece una sesión (con el simulador solo en el cliente), envía 'count' paquetes por canal y
# sentido, uno por tick, y devuelve las latencias (en ticks) y las secuencias de llegada.
func _measure_latencies(client_sim: String, count: int, server_sim: String = "") -> Dictionary:
	var pair: Array[Endpoint] = _make_pair(client_sim, server_sim)
	var server: Endpoint = pair[0]
	var client: Endpoint = pair[1]
	var connected: bool = await _run_until(pair, func() -> bool:
		return not server.connected.is_empty() and not client.connected.is_empty(),
			MAX_HANDSHAKE_TICKS)
	assert_true(connected, "el handshake termina (simuladores: '%s' y '%s')" % [
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


# Cierra y libera los transportes de una pareja (para empezar otra en la misma prueba).
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


# Rechazo: el servidor contesta REJECT y pide el corte ordenado; el cliente tiene que recibir el
# REJECT antes de que se cierre la conexión, y los dos lados se enteran del corte.
func _check_reject(server_sim: String, client_sim: String) -> void:
	var pair: Array[Endpoint] = _make_pair(client_sim, server_sim)
	var server: Endpoint = pair[0]
	var client: Endpoint = pair[1]
	server.reject = true
	var done: bool = await _run_until(pair, func() -> bool:
		return client.failed_count > 0 and not server.disconnected.is_empty(), 400)
	if not assert_true(done, "el rechazo termina en un corte en los dos lados"):
		return
	await _run_ticks(pair, 20)
	assert_eq(client.auth_messages, [REJECT], "el cliente recibe el REJECT antes del corte")
	assert_eq(client.failed_count, 1, "y luego connection_failed, una sola vez")
	assert_eq(client.event_log, ["authenticating", "auth", "failed"],
			"el REJECT se entrega antes de connection_failed")
	assert_eq(client.connected.size(), 0, "nunca llega a conectar")
	assert_eq(server.connected.size(), 0)
	assert_eq(server.authenticating.size(), 1)
	assert_eq(server.disconnected, server.authenticating,
			"el servidor recibe peer_disconnected del peer que estaba autenticando")
	assert_true(client.all_early_sends_unavailable())
	assert_true(server.all_early_sends_unavailable())
