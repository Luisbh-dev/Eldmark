extends TestCase
## Pruebas de [ZoneServer] con la plataforma ([FakeZonePlatform] y [TicketAuthProvider]) y clientes de verdad
## sobre ENet en 127.0.0.1 (docs/plataforma.md §5.2, §5.4 y §15 P4): billete → VERIFYING → WELCOME con el reino y el
## nombre del personaje; sin billete, TICKET; el cupo cuenta a los que verifican; un HELLO tardío con una
## reclamación lenta entra (auth_timeout de 10 s); la plataforma muda da UNAVAILABLE a los 7 s; la zona cercada
## también; las bajas en VERIFYING y en LOADING liberan sin guardar; los revoked del latido; BUSY y BANNED con su
## texto; el bit del personal del juego; y el HELLO ya no delata nombres (docs/social.md, 12.7).

const VARDHEIM: int = NetProtocol.Realm.VARDHEIM
const SOLMARCH: int = NetProtocol.Realm.SOLMARCH
const PLAYER_SCENE: PackedScene = preload("res://scenes/characters/player_character.tscn")
const ZONE_ID: String = "test_world"
## El primer ticket_id: por encima de 2^53, como los de verdad.
const FIRST_TICKET_ID: int = 9007199254740993

var _viewport: SubViewport
var _world: Node3D
var _server: ZoneServer
var _server_transport: NetTransport
var _platform: FakeZonePlatform
var _provider: TicketAuthProvider
var _keys: Dictionary[int, PackedByteArray] = {}
var _port: int = 0
var _clients: Array[RawClient] = []
var _client_tick: int = 0
var _next_client_index: int = 0
var _next_ticket_id: int = FIRST_TICKET_ID
var _sim_hash: int = -1


## Un cliente que habla el protocolo a mano (como el de test_zone_server_net.gd), con el HELLO retrasable.
class RawClient:
	extends RefCounted

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

	func kick_notice() -> NetMessages.Notice:
		for notice: NetMessages.Notice in notices:
			if notice.code == NetProtocol.NoticeCode.KICK:
				return notice
		return null

	func spawn_named(display_name: String) -> NetMessages.EntitySpawn:
		for spawn: NetMessages.EntitySpawn in spawns:
			if spawn.display_name == display_name:
				return spawn
		return null


func before_each() -> void:
	_keys = {1: PackedByteArray(range(32)),
			2: "02b7825be38fdd5396a4a058286884eaf93a9df85b874f78b4010a76103fb858".hex_decode()}


func after_each() -> void:
	for client: RawClient in _clients:
		if is_instance_valid(client.transport):
			client.transport.free()
	_clients.clear()
	if is_instance_valid(_server):
		_server.free()
	if is_instance_valid(_server_transport):
		_server_transport.free()
	if is_instance_valid(_viewport):
		_viewport.get_parent().remove_child(_viewport)
		_viewport.free()
	_server = null
	_server_transport = null
	_platform = null
	_provider = null
	_world = null
	_viewport = null
	_client_tick = 0
	_sim_hash = -1
	await wait_process_frames()


# --- Ayudantes --------------------------------------------------------------------------------

## La zona de prueba con la plataforma falsa ya arrancada y el servidor escuchando. [param configure] recibe el
## [ServerConfig] y [param setup] la plataforma antes de arrancar.
func _start(configure: Callable = Callable(), setup: Callable = Callable()) -> bool:
	_viewport = SubViewport.new()
	_viewport.own_world_3d = true
	_viewport.size = Vector2i(64, 64)
	tree.root.add_child(_viewport)
	_world = ZoneFixture.build_flat_zone(_viewport)
	_server_transport = NetTransport.new()
	_server_transport.name = "ServerTransport"
	_viewport.add_child(_server_transport)
	_platform = FakeZonePlatform.new()
	_platform.name = "Platform"
	_platform.log_sink = func(_text: String) -> void: pass
	_viewport.add_child(_platform)
	_server = ZoneServer.new()
	_server.name = "ZoneServer"
	_server.log_enabled = false
	_viewport.add_child(_server)
	await wait_physics_frames(3)
	var config := ServerConfig.new()
	config.zone_id = ZONE_ID
	config.platform_url = "http://fake"
	_port = NetHarness.free_udp_port()
	config.port = _port
	if configure.is_valid():
		configure.call(config)
	if setup.is_valid():
		setup.call(_platform)
	var finished: Array = []
	_platform.startup_finished.connect(func(ok: bool, error: String) -> void: finished.append([ok, error]))
	_platform.start(config, {"token": "token", "ticket_keys": _keys})
	for _i: int in 120:
		if not finished.is_empty():
			break
		await wait_process_frames()
	if not assert_eq(finished, [[true, ""]], "la plataforma falsa arranca"):
		return false
	_provider = TicketAuthProvider.new(_platform, config.world_id, config.zone_id, config.channel, _keys)
	_provider.log_sink = func(_text: String) -> void: pass
	if not assert_eq(_server.start(config, _world, _server_transport, _provider, _platform), OK,
			"el servidor abre el puerto %d" % _port):
		return false
	_platform.go_live()
	return true


## Un billete válido para [param character_id] en esta zona (o el de [param zone_id]).
func _ticket(character_id: int, zone_id: String = ZONE_ID) -> PackedByteArray:
	var ticket := HandoffTicket.new()
	ticket.key_id = 2
	ticket.world_id = 1
	ticket.ticket_id = _next_ticket_id
	_next_ticket_id += 1
	ticket.character_id = character_id
	ticket.zone_key = HandoffTicket.zone_key_of(zone_id)
	ticket.realm = VARDHEIM
	ticket.flags = HandoffTicket.FLAG_FROM_MENU
	ticket.issued_at = _platform.now_unix()
	ticket.expires_at = ticket.issued_at + 10
	return ticket.sign(_keys[2])


func _hello(character_id: int, ticket: PackedByteArray, realm: int = VARDHEIM,
		player_name: String = "Cualquiera") -> PackedByteArray:
	var hello := NetMessages.Hello.new()
	hello.sim_hash = _client_sim_hash()
	hello.realm = realm
	hello.display_name = player_name
	hello.character_id = character_id
	hello.ticket = ticket
	return hello.encode()


func _client_sim_hash() -> int:
	if _sim_hash >= 0:
		return _sim_hash
	var character: PlayerCharacter = PLAYER_SCENE.instantiate() as PlayerCharacter
	_world.add_child(character)
	_sim_hash = NetProtocol.compute_sim_hash(character)
	_world.remove_child(character)
	character.free()
	return _sim_hash


func _connect(hello: PackedByteArray, auto_ready: bool = true, hello_delay_ms: int = 0) -> RawClient:
	var transport := NetTransport.new()
	transport.name = "ClientTransport%d" % _next_client_index
	_next_client_index += 1
	_viewport.add_child(transport)
	var client := RawClient.new(transport, hello)
	client.auto_ready = auto_ready
	client.hello_delay_ms = hello_delay_ms
	_clients.append(client)
	assert_eq(transport.connect_to("127.0.0.1", _port, 2000), OK, "el cliente conecta")
	return client


func _step() -> void:
	await tree.physics_frame
	_client_tick += 1
	for client: RawClient in _clients:
		if not is_instance_valid(client.transport):
			continue
		client.transport.poll(_client_tick)
		client.step()
		client.transport.flush()


## Avanza hasta que [param condition] sea verdadera o pasen [param max_ms] ms.
func _run_until(condition: Callable, max_ms: int = 5000) -> bool:
	var started: int = Time.get_ticks_msec()
	while Time.get_ticks_msec() - started < max_ms:
		if condition.call():
			return true
		await _step()
	return condition.call()


func _run_ms(ms: int) -> void:
	var started: int = Time.get_ticks_msec()
	while Time.get_ticks_msec() - started < ms:
		await _step()


## El peer del servidor en [param state], o null.
func _server_peer_in(state: ServerPeer.State) -> ServerPeer:
	for peer_id: int in _server.get_peer_ids():
		var peer: ServerPeer = _server.get_peer(peer_id)
		if peer.state == state:
			return peer
	return null


## Entra con billete el personaje [param character_id] y espera su alta.
func _join(character_id: int) -> RawClient:
	var client: RawClient = _connect(_hello(character_id, _ticket(character_id)))
	var joined: bool = await _run_until(func() -> bool: return client.own_spawn != null or client.reject != null)
	if not assert_true(joined and client.own_spawn != null, "el personaje %d entra en el mundo" % character_id):
		return null
	return client


# --- Pruebas ----------------------------------------------------------------------------------

## Billete → VERIFYING → WELCOME: el reino y el nombre son los del personaje, no los del HELLO; la reclamación
## lleva los ids en cadena (ticket_id > 2^53), el personaje entra en el conjunto del latido, el VERIFYING cuenta
## para el cupo y el personal del juego lleva el bit 3 en su SPAWN.
func test_ticket_goes_through_verifying_to_welcome() -> void:
	if not await _start(Callable(), func(platform: FakeZonePlatform) -> void:
			platform.add_character(42, 7, &"gm", VARDHEIM, {}, {}, "Aneira")
			platform.add_character(43, 8, &"player", VARDHEIM, {}, {}, "Brais")):
		return
	_platform.script_next(PlatformEvent.KIND_CLAIM, 200, FakeZonePlatform.DEFAULT, 0.5)
	var client: RawClient = _connect(_hello(42, _ticket(42), SOLMARCH, "Impostor"))
	var verifying: bool = await _run_until(func() -> bool:
		return _server_peer_in(ServerPeer.State.VERIFYING) != null)
	if not assert_true(verifying, "el peer espera la reclamación en VERIFYING"):
		return
	assert_eq(_server.get_player_count(), 1, "VERIFYING cuenta para el cupo")
	assert_null(client.welcome, "aún sin WELCOME")
	var joined: bool = await _run_until(func() -> bool: return client.own_spawn != null)
	if not assert_true(joined, "con el 200 llega el WELCOME y entra en el mundo"):
		return
	assert_eq(client.welcome.realm, VARDHEIM, "el WELCOME lleva el reino del personaje, no el del HELLO")
	assert_eq(client.own_spawn.display_name, "Aneira", "y el nombre del personaje")
	assert_eq(client.own_spawn.realm, VARDHEIM, "su SPAWN es de su reino")
	assert_true(client.own_spawn.is_staff, "un gm lleva el bit del personal del juego")
	var claims: Array[Dictionary] = _platform.sent(PlatformEvent.KIND_CLAIM)
	assert_eq(claims, [{"zone_instance_id": _platform.instance_id(), "ticket_id": str(FIRST_TICKET_ID),
			"character_id": "42"}], "una reclamación, con el ticket_id > 2^53 en cadena")
	var claimed: ClaimedCharacter = _platform.claimed(42)
	assert_eq(_platform.heartbeat_set(), {42: claimed.lease_id}, "el personaje entra en el conjunto del latido")
	_platform.send_heartbeat_now()
	await _run_until(func() -> bool: return not _platform.sent(PlatformEvent.KIND_HEARTBEAT).is_empty())
	var beats: Array[Dictionary] = _platform.sent(PlatformEvent.KIND_HEARTBEAT)
	assert_eq(beats.back()["characters"], [{"character_id": "42", "lease_id": claimed.lease_id}],
			"y el latido late por él")
	var other: RawClient = await _join(43)
	if other != null:
		assert_false(other.own_spawn.is_staff, "un player no")
		var seen: NetMessages.EntitySpawn = other.spawn_named("Aneira")
		if assert_not_null(seen, "Brais ve a Aneira"):
			assert_true(seen.is_staff, "con su etiqueta")
	assert_true(_server.get_connected_names().has("Aneira") and not _server.get_connected_names().has("Impostor"),
			"el nombre del HELLO no cuenta")


func test_hello_without_ticket_gets_ticket_with_the_menu_text() -> void:
	if not await _start():
		return
	var client: RawClient = _connect(_hello(42, PackedByteArray()))
	var answered: bool = await _run_until(func() -> bool: return client.reject != null or client.welcome != null)
	if assert_true(answered and client.reject != null, "REJECT"):
		assert_eq(client.reject.result, NetProtocol.Result.TICKET, "TICKET")
		assert_eq(client.reject.text, TicketAuthProvider.NO_TICKET_TEXT, "«Entra desde el menú con tu cuenta»")
	var forged: RawClient = _connect(_hello(42, _ticket(42, "vado_gris")))
	await _run_until(func() -> bool: return forged.reject != null)
	if assert_not_null(forged.reject, "un billete de otra zona"):
		assert_eq(forged.reject.result, NetProtocol.Result.TICKET, "TICKET")
		assert_eq(forged.reject.text, NetProtocol.result_text(NetProtocol.Result.TICKET), "con su texto")
	assert_eq(_platform.sent(PlatformEvent.KIND_CLAIM).size(), 0, "nada llega a la plataforma")


## Cupo de 4 con 5 a la vez en VERIFYING: el quinto recibe FULL y nunca se reclama.
func test_quota_of_four_with_five_verifying_rejects_one_with_full() -> void:
	if not await _start(func(config: ServerConfig) -> void: config.max_players = 4,
			func(platform: FakeZonePlatform) -> void:
				for character_id: int in range(11, 16):
					platform.add_character(character_id, character_id, &"player", VARDHEIM, {})):
		return
	for _i: int in 4:
		_platform.script_next(PlatformEvent.KIND_CLAIM, 200, FakeZonePlatform.DEFAULT, 1.0)
	var clients: Array[RawClient] = []
	for character_id: int in range(11, 16):
		clients.append(_connect(_hello(character_id, _ticket(character_id)), false))
	var one_full: bool = await _run_until(func() -> bool:
		return clients.filter(func(c: RawClient) -> bool: return c.reject != null).size() == 1)
	if not assert_true(one_full, "uno recibe REJECT enseguida"):
		return
	var rejected: RawClient = clients.filter(func(c: RawClient) -> bool: return c.reject != null)[0]
	assert_eq(rejected.reject.result, NetProtocol.Result.FULL, "FULL: los cuatro que verifican ocupan el cupo")
	assert_eq(_server.get_player_count(), 4, "cuatro en VERIFYING")
	var welcomed: bool = await _run_until(func() -> bool:
		return clients.filter(func(c: RawClient) -> bool: return c.welcome != null).size() == 4)
	assert_true(welcomed, "los cuatro reciben su WELCOME con el 200")
	assert_eq(_platform.sent(PlatformEvent.KIND_CLAIM).size(), 4, "solo cuatro reclamaciones")


## El HELLO llega a 1,4 s de la conexión y la reclamación tarda 5 s: el WELCOME sale a ~6,4 s, antes del plazo de 7 s
## y del auth_timeout de 10 s de los dos lados (con 5 s, el cliente habría caído).
func test_late_hello_and_slow_claim_still_get_welcome() -> void:
	if not await _start(Callable(), func(platform: FakeZonePlatform) -> void:
			platform.add_character(42, 7, &"player", VARDHEIM, {})):
		return
	_platform.script_next(PlatformEvent.KIND_CLAIM, 200, FakeZonePlatform.DEFAULT, 5.0)
	var client: RawClient = _connect(_hello(42, _ticket(42)), true, 1400)
	var joined: bool = await _run_until(func() -> bool:
		return client.own_spawn != null or client.reject != null or client.failed, 9000)
	if not assert_true(joined and client.own_spawn != null, "entra en el mundo (rechazo: %s)"
			% (client.reject.text if client.reject != null else "ninguno")):
		return
	var elapsed: int = client.welcome_at_msec - client.connected_at_msec
	assert_true(elapsed >= 6000 and elapsed < 7000, "el WELCOME llega a los %d ms de la conexión" % elapsed)
	assert_false(client.failed or client.disconnected, "nadie cae por el auth_timeout")


## Plataforma muda: REJECT UNAVAILABLE a los 7 s (reloj real) y, cuando la reclamación llega después, se libera.
func test_mute_platform_rejects_with_unavailable_after_seven_seconds() -> void:
	if not await _start(Callable(), func(platform: FakeZonePlatform) -> void:
			platform.add_character(42, 7, &"player", VARDHEIM, {})):
		return
	_platform.script_next(PlatformEvent.KIND_CLAIM, 200, FakeZonePlatform.DEFAULT, 8.0)
	var client: RawClient = _connect(_hello(42, _ticket(42)))
	var rejected: bool = await _run_until(func() -> bool: return client.reject != null, 9000)
	if not assert_true(rejected, "REJECT"):
		return
	assert_eq(client.reject.result, NetProtocol.Result.UNAVAILABLE, "UNAVAILABLE")
	assert_eq(client.reject.text, NetProtocol.result_text(NetProtocol.Result.UNAVAILABLE),
			"«El servicio de cuentas no responde: inténtalo más tarde»")
	var elapsed: int = client.reject_at_msec - client.connected_at_msec
	assert_true(elapsed >= 6900 and elapsed < 8000, "a los 7 s de la conexión (%d ms)" % elapsed)
	var released: bool = await _run_until(func() -> bool:
		return not _platform.sent(ZonePlatform.KIND_RELEASE).is_empty(), 3000)
	if assert_true(released, "la reclamación que llega después se libera"):
		assert_eq(_platform.sent(ZonePlatform.KIND_RELEASE)[0]["lease_id"], _platform.claimed(42).lease_id,
				"con su lease_id")
	assert_true(_platform.heartbeat_set().is_empty(), "y no queda en el latido")


func test_fenced_zone_rejects_with_unavailable() -> void:
	if not await _start(Callable(), func(platform: FakeZonePlatform) -> void:
			platform.add_character(42, 7, &"player", VARDHEIM, {})):
		return
	_platform.set_fenced(true)
	var client: RawClient = _connect(_hello(42, _ticket(42)))
	await _run_until(func() -> bool: return client.reject != null)
	if assert_not_null(client.reject, "REJECT"):
		assert_eq(client.reject.result, NetProtocol.Result.UNAVAILABLE, "zona cercada: UNAVAILABLE")
	assert_eq(_platform.sent(PlatformEvent.KIND_CLAIM).size(), 0, "sin reclamación")
	_platform.set_fenced(false)
	var later: RawClient = _connect(_hello(42, _ticket(42)))
	await _run_until(func() -> bool: return later.own_spawn != null)
	assert_not_null(later.own_spawn, "con el latido de vuelta, entra")


func test_leaving_while_verifying_releases_the_late_claim() -> void:
	if not await _start(Callable(), func(platform: FakeZonePlatform) -> void:
			platform.add_character(42, 7, &"player", VARDHEIM, {})):
		return
	_platform.script_next(PlatformEvent.KIND_CLAIM, 200, FakeZonePlatform.DEFAULT, 1.0)
	var client: RawClient = _connect(_hello(42, _ticket(42)))
	await _run_until(func() -> bool: return _server_peer_in(ServerPeer.State.VERIFYING) != null)
	client.transport.close()
	var gone: bool = await _run_until(func() -> bool: return _server.get_peer_ids().is_empty())
	assert_true(gone, "el servidor da de baja al peer que verificaba")
	assert_eq(_server.get_player_count(), 0, "y deja su plaza")
	var released: bool = await _run_until(func() -> bool:
		return not _platform.sent(ZonePlatform.KIND_RELEASE).is_empty(), 3000)
	if assert_true(released, "la reclamación que llega después se libera"):
		assert_eq(_platform.sent(ZonePlatform.KIND_RELEASE)[0]["lease_id"], _platform.claimed(42).lease_id,
				"con su lease_id")
	assert_eq(_provider.pending_count(), 0, "el proveedor no espera a nadie")


func test_leaving_while_loading_releases_without_saving() -> void:
	if not await _start(Callable(), func(platform: FakeZonePlatform) -> void:
			platform.add_character(42, 7, &"player", VARDHEIM, {})):
		return
	var client: RawClient = _connect(_hello(42, _ticket(42)), false)
	var loading: bool = await _run_until(func() -> bool:
		return client.connected and _server_peer_in(ServerPeer.State.LOADING) != null)
	if not assert_true(loading, "WELCOME y LOADING"):
		return
	var lease_id: String = _platform.claimed(42).lease_id
	client.transport.close()
	var released: bool = await _run_until(func() -> bool:
		return not _platform.sent(ZonePlatform.KIND_RELEASE).is_empty())
	if assert_true(released, "la baja en LOADING libera"):
		assert_eq(_platform.sent(ZonePlatform.KIND_RELEASE), [{"zone_instance_id": _platform.instance_id(),
				"lease_id": lease_id}], "una vez, con su lease_id")
	assert_eq(_platform.sent(PlatformEvent.KIND_SAVE).size(), 0, "sin guardar")
	assert_true(_platform.heartbeat_set().is_empty(), "y sale del latido")


## Un revoked del latido con un personaje en LOADING: NOTICE de expulsión con el texto de la plataforma y
## liberación sin guardar.
func test_revoked_while_loading_kicks_and_releases() -> void:
	if not await _start(Callable(), func(platform: FakeZonePlatform) -> void:
			platform.add_character(42, 7, &"player", VARDHEIM, {})):
		return
	var client: RawClient = _connect(_hello(42, _ticket(42)), false)
	await _run_until(func() -> bool: return client.connected and _server_peer_in(ServerPeer.State.LOADING) != null)
	await _run_ms(100)
	var lease_id: String = _platform.claimed(42).lease_id
	_platform.script_next(PlatformEvent.KIND_HEARTBEAT, 200, {"now_unix": _platform.now_unix(), "revoked": [
			{"character_id": "42", "lease_id": lease_id, "reason": "session_revoked",
			"text": "Has iniciado sesión desde otro lugar"}], "mutes": [], "maintenance": null})
	_platform.send_heartbeat_now()
	var kicked: bool = await _run_until(func() -> bool: return client.kick_notice() != null)
	if assert_true(kicked, "NOTICE de expulsión"):
		assert_eq(client.kick_notice().text, "Has iniciado sesión desde otro lugar", "con el texto de la plataforma")
	var released: bool = await _run_until(func() -> bool:
		return not _platform.sent(ZonePlatform.KIND_RELEASE).is_empty())
	if assert_true(released, "y se libera"):
		assert_eq(_platform.sent(ZonePlatform.KIND_RELEASE)[0]["lease_id"], lease_id, "su arrendamiento")
	assert_eq(_platform.sent(PlatformEvent.KIND_SAVE).size(), 0, "sin guardar")


## En el mundo: un revoked con un lease_id viejo no expulsa; con el de ahora, sí (y libera al irse el cuerpo); un
## lease_lost expulsa sin liberar.
func test_revoked_in_the_world_only_with_the_current_lease() -> void:
	if not await _start(Callable(), func(platform: FakeZonePlatform) -> void:
			platform.add_character(42, 7, &"player", VARDHEIM, {})
			platform.add_character(43, 8, &"player", SOLMARCH, {})):
		return
	var first: RawClient = await _join(42)
	var second: RawClient = await _join(43)
	if first == null or second == null:
		return
	var lease_42: String = _platform.claimed(42).lease_id
	var lease_43: String = _platform.claimed(43).lease_id
	var revoke: Callable = func(character_id: String, lease_id: String, reason: String, text: String) -> void:
		_platform.script_next(PlatformEvent.KIND_HEARTBEAT, 200, {"now_unix": _platform.now_unix(), "revoked": [
				{"character_id": character_id, "lease_id": lease_id, "reason": reason, "text": text}],
				"mutes": [], "maintenance": null})
		_platform.send_heartbeat_now()
	revoke.call("42", "00000000-0000-4000-8000-999999999999", "banned", "Tu cuenta está expulsada: trampas")
	await _run_ms(400)
	assert_null(first.kick_notice(), "un lease_id viejo no expulsa")
	assert_false(first.disconnected, "sigue conectado")
	revoke.call("42", lease_42, "banned", "Tu cuenta está expulsada: trampas")
	await _run_until(func() -> bool: return first.kick_notice() != null)
	if assert_not_null(first.kick_notice(), "con el de ahora, expulsión"):
		assert_eq(first.kick_notice().text, "Tu cuenta está expulsada: trampas", "con el texto de la plataforma")
	var released: bool = await _run_until(func() -> bool:
		return not _platform.sent(ZonePlatform.KIND_RELEASE).is_empty())
	if assert_true(released, "al irse el cuerpo se libera"):
		assert_eq(_platform.sent(ZonePlatform.KIND_RELEASE)[0]["lease_id"], lease_42, "su arrendamiento")
	revoke.call("43", lease_43, "lease_lost", "Tu personaje ha entrado en otro servidor")
	await _run_until(func() -> bool: return second.kick_notice() != null)
	if assert_not_null(second.kick_notice(), "lease_lost expulsa"):
		assert_eq(second.kick_notice().text, "Tu personaje ha entrado en otro servidor", "con su texto")
	await _run_until(func() -> bool: return _server.get_registry().get_sorted().filter(
			func(e: NetEntity) -> bool: return e.kind == NetProtocol.EntityKind.PLAYER).is_empty(), 2000)
	await _run_ms(200)
	assert_eq(_platform.sent(ZonePlatform.KIND_RELEASE).size(), 1, "lease_lost no libera (ya no es de la zona)")
	assert_false(_platform.heartbeat_set().has(43), "ni se sigue latiendo por él")


## BUSY con su texto y BANNED con el message del 403 en suspensión, expulsión y borrado pendiente.
func test_busy_and_banned_rejections_carry_their_text() -> void:
	if not await _start(Callable(), func(platform: FakeZonePlatform) -> void:
			platform.add_character(42, 7, &"player", VARDHEIM, {})):
		return
	var cases: Array = [
		[409, FakeZonePlatform.error_body("character_busy"), NetProtocol.Result.BUSY,
				"Tu personaje sigue en el mundo: espera unos segundos"],
		[403, FakeZonePlatform.error_body("account_blocked",
				"Tu cuenta está suspendida hasta el 3/11/2026 18:00 UTC: insultos",
				{"kind": "suspension", "until_unix": 1793728800, "reason": "insultos"}), NetProtocol.Result.BANNED,
				"Tu cuenta está suspendida hasta el 3/11/2026 18:00 UTC: insultos"],
		[403, FakeZonePlatform.error_body("account_blocked", "Tu cuenta está expulsada: trampas",
				{"kind": "ban", "until_unix": null, "reason": "trampas"}), NetProtocol.Result.BANNED,
				"Tu cuenta está expulsada: trampas"],
		[403, FakeZonePlatform.error_body("account_blocked", "Tu cuenta se borrará el 14/11/2026",
				{"kind": "pending_deletion", "until_unix": 1794700000, "reason": ""}), NetProtocol.Result.BANNED,
				"Tu cuenta se borrará el 14/11/2026"],
	]
	for entry: Array in cases:
		_platform.script_next(PlatformEvent.KIND_CLAIM, entry[0], entry[1])
		var client: RawClient = _connect(_hello(42, _ticket(42)))
		await _run_until(func() -> bool: return client.reject != null or client.welcome != null)
		if assert_not_null(client.reject, "REJECT para %s" % entry[3]):
			assert_eq([client.reject.result, client.reject.text], [entry[2], entry[3]], entry[3])
	assert_eq(_platform.sent(ZonePlatform.KIND_RELEASE).size(), 0, "sin arrendamiento, nada que liberar")


## docs/social.md 12.7: con billete, el nombre del HELLO no se compara con los conectados. Un HELLO con el billete
## de otro personaje y el nombre de un enemigo conectado no recibe NAME: entra con su personaje (o, con un billete
## que no vale, recibe TICKET). Nada delata si el enemigo está en la zona.
func test_hello_cannot_probe_an_enemy_name() -> void:
	if not await _start(Callable(), func(platform: FakeZonePlatform) -> void:
			platform.add_character(2, 20, &"player", SOLMARCH, {}, {}, "Bruna")
			platform.add_character(3, 30, &"player", VARDHEIM, {}, {}, "Ana")):
		return
	var enemy: RawClient = await _join(2)
	if enemy == null:
		return
	assert_true(_server.get_connected_names().has("Bruna"), "Bruna está en la zona")
	var probe: RawClient = _connect(_hello(3, _ticket(3), SOLMARCH, "Bruna"))
	await _run_until(func() -> bool: return probe.own_spawn != null or probe.reject != null)
	assert_null(probe.reject, "ni NAME ni ningún otro REJECT")
	if assert_not_null(probe.own_spawn, "entra con su personaje"):
		assert_eq(probe.own_spawn.display_name, "Ana", "con su nombre")
		assert_eq(probe.welcome.realm, VARDHEIM, "y su reino")
	var forged: RawClient = _connect(_hello(3, _ticket(2), SOLMARCH, "Bruna"))
	await _run_until(func() -> bool: return forged.reject != null or forged.welcome != null)
	if assert_not_null(forged.reject, "el billete de otro personaje"):
		assert_eq(forged.reject.result, NetProtocol.Result.TICKET, "TICKET, no NAME")
	var bare: RawClient = _connect(_hello(0, PackedByteArray(), SOLMARCH, "Bruna"))
	await _run_until(func() -> bool: return bare.reject != null or bare.welcome != null)
	if assert_not_null(bare.reject, "sin billete"):
		assert_eq(bare.reject.result, NetProtocol.Result.TICKET, "TICKET, no NAME")
	var absent: RawClient = _connect(_hello(3, PackedByteArray(), SOLMARCH, "Nadie"))
	await _run_until(func() -> bool: return absent.reject != null or absent.welcome != null)
	if assert_not_null(absent.reject, "con un nombre que no está"):
		assert_eq([absent.reject.result, absent.reject.text], [bare.reject.result, bare.reject.text],
				"la misma respuesta que con el del enemigo")


## Con un env de production, --debug-commands hace que el arranque falle (la zona sale) y la instancia se da de
## baja.
func test_debug_commands_with_production_env_stop_the_startup() -> void:
	_platform = FakeZonePlatform.new()
	_platform.fake_env = &"production"
	_platform.log_sink = func(_text: String) -> void: pass
	_viewport = SubViewport.new()
	tree.root.add_child(_viewport)
	_viewport.add_child(_platform)
	var config := ServerConfig.from_args(PackedStringArray(["--server", "--zone=test_world",
			"--platform=http://fake", "--debug-commands"]))
	assert_true(config.uses_platform() and config.debug_commands, "las opciones se leen")
	var finished: Array = []
	_platform.startup_finished.connect(func(ok: bool, error: String) -> void: finished.append([ok, error]))
	_platform.start(config, {"token": "token", "ticket_keys": {2: _keys[2]}})
	for _i: int in 60:
		if not finished.is_empty():
			break
		await wait_process_frames()
	if assert_eq(finished.size(), 1, "el arranque termina"):
		assert_false(finished[0][0], "mal")
		assert_eq(finished[0][1], "Esa opción no se admite con la plataforma en staging/production: --debug-commands",
				"con el motivo")
	await wait_process_frames(3)
	assert_eq(_platform.sent(ZonePlatform.KIND_STOP).size(), 1, "y la instancia se da de baja")
	assert_eq(_platform.sent(ZonePlatform.KIND_FORTRESSES).size(), 0, "sin seguir con el arranque")
