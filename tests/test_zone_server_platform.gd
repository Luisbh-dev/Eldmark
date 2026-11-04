extends TestCase
## Tests for [ZoneServer] with the platform ([FakeZonePlatform] and [TicketAuthProvider]) and real
## clients over ENet on 127.0.0.1 (docs/platform.md §5.2, §5.4 and §15 P4): ticket → VERIFYING →
## WELCOME with the character's realm and name; with no ticket, TICKET; the quota counts those who are
## verifying; a late HELLO with a slow claim gets in (10 s auth_timeout); a silent platform gives
## UNAVAILABLE at 7 s; the fenced zone too; removals in VERIFYING and in LOADING release without saving;
## the heartbeat's revoked; BUSY and BANNED with their text; the game staff bit; and the HELLO no longer
## gives names away (docs/social.md, 12.7).

const VARDHEIM: int = NetProtocol.Realm.VARDHEIM
const SOLMARCH: int = NetProtocol.Realm.SOLMARCH
const PLAYER_SCENE: PackedScene = preload("res://scenes/characters/player_character.tscn")
const ZONE_ID: String = "test_world"
## The first ticket_id: above 2^53, like the real ones.
const FIRST_TICKET_ID: int = 9007199254740993

var _viewport: SubViewport
var _world: Node3D
var _server: ZoneServer
var _server_transport: NetTransport
var _platform: FakeZonePlatform
var _provider: TicketAuthProvider
var _keys: Dictionary[int, PackedByteArray] = {}
var _port: int = 0
var _clients: Array[RawTicketClient] = []
var _client_tick: int = 0
var _next_client_index: int = 0
var _next_ticket_id: int = FIRST_TICKET_ID
var _sim_hash: int = -1


func before_each() -> void:
	_keys = {1: PackedByteArray(range(32)),
			2: "02b7825be38fdd5396a4a058286884eaf93a9df85b874f78b4010a76103fb858".hex_decode()}


func after_each() -> void:
	for client: RawTicketClient in _clients:
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


# --- Helpers ----------------------------------------------------------------------------------

## The test zone with the fake platform already started and the server listening. [param configure]
## receives the [ServerConfig] and [param setup] the platform before startup.
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
	if not assert_eq(finished, [[true, ""]], "the fake platform starts"):
		return false
	_provider = TicketAuthProvider.new(_platform, config.world_id, config.zone_id, config.channel, _keys)
	_provider.log_sink = func(_text: String) -> void: pass
	if not assert_eq(_server.start(config, _world, _server_transport, _provider, _platform), OK,
			"the server opens port %d" % _port):
		return false
	_platform.go_live()
	return true


## A valid ticket for [param character_id] in this zone (or in [param zone_id]).
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


func _connect(hello: PackedByteArray, auto_ready: bool = true, hello_delay_ms: int = 0) -> RawTicketClient:
	var transport := NetTransport.new()
	transport.name = "ClientTransport%d" % _next_client_index
	_next_client_index += 1
	_viewport.add_child(transport)
	var client := RawTicketClient.new(transport, hello)
	client.auto_ready = auto_ready
	client.hello_delay_ms = hello_delay_ms
	_clients.append(client)
	assert_eq(transport.connect_to("127.0.0.1", _port, 2000), OK, "the client connects")
	return client


func _step() -> void:
	await tree.physics_frame
	_client_tick += 1
	for client: RawTicketClient in _clients:
		if not is_instance_valid(client.transport):
			continue
		client.transport.poll(_client_tick)
		client.step()
		client.transport.flush()


## Advances until [param condition] is true or [param max_ms] ms pass.
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


## The server's peer in [param state], or null.
func _server_peer_in(state: ServerPeer.State) -> ServerPeer:
	for peer_id: int in _server.get_peer_ids():
		var peer: ServerPeer = _server.get_peer(peer_id)
		if peer.state == state:
			return peer
	return null


## Character [param character_id] joins with a ticket and waits to be signed up.
func _join(character_id: int) -> RawTicketClient:
	var client: RawTicketClient = _connect(_hello(character_id, _ticket(character_id)))
	var joined: bool = await _run_until(func() -> bool: return client.own_spawn != null or client.reject != null)
	if not assert_true(joined and client.own_spawn != null, "character %d enters the world" % character_id):
		return null
	return client


# --- Tests ------------------------------------------------------------------------------------

## Ticket → VERIFYING → WELCOME: the realm and name are the character's, not the HELLO's; the claim
## carries the ids as strings (ticket_id > 2^53), the character enters the heartbeat set, VERIFYING counts
## toward the quota and game staff carry bit 3 in their SPAWN.
func test_ticket_goes_through_verifying_to_welcome() -> void:
	if not await _start(Callable(), func(platform: FakeZonePlatform) -> void:
			platform.add_character(42, 7, &"gm", VARDHEIM, {}, {}, "Aneira")
			platform.add_character(43, 8, &"player", VARDHEIM, {}, {}, "Brais")):
		return
	_platform.script_next(PlatformEvent.KIND_CLAIM, 200, FakeZonePlatform.DEFAULT, 0.5)
	var client: RawTicketClient = _connect(_hello(42, _ticket(42), SOLMARCH, "Impostor"))
	var verifying: bool = await _run_until(func() -> bool:
		return _server_peer_in(ServerPeer.State.VERIFYING) != null)
	if not assert_true(verifying, "the peer waits for the claim in VERIFYING"):
		return
	assert_eq(_server.get_player_count(), 1, "VERIFYING counts toward the quota")
	assert_null(client.welcome, "still no WELCOME")
	var joined: bool = await _run_until(func() -> bool: return client.own_spawn != null)
	if not assert_true(joined, "with the 200 the WELCOME arrives and it enters the world"):
		return
	assert_eq(client.welcome.realm, VARDHEIM, "the WELCOME carries the character's realm, not the HELLO's")
	assert_eq(client.own_spawn.display_name, "Aneira", "and the character's name")
	assert_eq(client.own_spawn.realm, VARDHEIM, "its SPAWN is of its realm")
	assert_true(client.own_spawn.is_staff, "a gm carries the game staff bit")
	var claims: Array[Dictionary] = _platform.sent(PlatformEvent.KIND_CLAIM)
	assert_eq(claims, [{"zone_instance_id": _platform.instance_id(), "ticket_id": str(FIRST_TICKET_ID),
			"character_id": "42"}], "one claim, with the ticket_id > 2^53 as a string")
	var claimed: ClaimedCharacter = _platform.claimed(42)
	assert_eq(_platform.heartbeat_set(), {42: claimed.lease_id}, "the character enters the heartbeat set")
	_platform.send_heartbeat_now()
	await _run_until(func() -> bool: return not _platform.sent(PlatformEvent.KIND_HEARTBEAT).is_empty())
	var beats: Array[Dictionary] = _platform.sent(PlatformEvent.KIND_HEARTBEAT)
	assert_eq(beats.back()["characters"], [{"character_id": "42", "lease_id": claimed.lease_id}],
			"and the heartbeat beats for it")
	var other: RawTicketClient = await _join(43)
	if other != null:
		assert_false(other.own_spawn.is_staff, "a player does not")
		var seen: NetMessages.EntitySpawn = other.spawn_named("Aneira")
		if assert_not_null(seen, "Brais sees Aneira"):
			assert_true(seen.is_staff, "with her tag")
	assert_true(_server.get_connected_names().has("Aneira") and not _server.get_connected_names().has("Impostor"),
			"the HELLO's name does not count")


func test_hello_without_ticket_gets_ticket_with_the_menu_text() -> void:
	if not await _start():
		return
	var client: RawTicketClient = _connect(_hello(42, PackedByteArray()))
	var answered: bool = await _run_until(func() -> bool: return client.reject != null or client.welcome != null)
	if assert_true(answered and client.reject != null, "REJECT"):
		assert_eq(client.reject.result, NetProtocol.Result.TICKET, "TICKET")
		assert_eq(client.reject.text, TicketAuthProvider.NO_TICKET_TEXT, "\"Entra desde el menú con tu cuenta\" (join from the menu with your account)")
	var forged: RawTicketClient = _connect(_hello(42, _ticket(42, "vado_gris")))
	await _run_until(func() -> bool: return forged.reject != null)
	if assert_not_null(forged.reject, "a ticket from another zone"):
		assert_eq(forged.reject.result, NetProtocol.Result.TICKET, "TICKET")
		assert_eq(forged.reject.text, NetProtocol.result_text(NetProtocol.Result.TICKET), "with its text")
	assert_eq(_platform.sent(PlatformEvent.KIND_CLAIM).size(), 0, "nothing reaches the platform")


## Quota of 4 with 5 at once in VERIFYING: the fifth receives FULL and is never claimed.
func test_quota_of_four_with_five_verifying_rejects_one_with_full() -> void:
	if not await _start(func(config: ServerConfig) -> void: config.max_players = 4,
			func(platform: FakeZonePlatform) -> void:
				for character_id: int in range(11, 16):
					platform.add_character(character_id, character_id, &"player", VARDHEIM, {})):
		return
	for _i: int in 4:
		_platform.script_next(PlatformEvent.KIND_CLAIM, 200, FakeZonePlatform.DEFAULT, 1.0)
	var clients: Array[RawTicketClient] = []
	for character_id: int in range(11, 16):
		clients.append(_connect(_hello(character_id, _ticket(character_id)), false))
	var one_full: bool = await _run_until(func() -> bool:
		return clients.filter(func(c: RawTicketClient) -> bool: return c.reject != null).size() == 1)
	if not assert_true(one_full, "one receives REJECT right away"):
		return
	var rejected: RawTicketClient = clients.filter(func(c: RawTicketClient) -> bool: return c.reject != null)[0]
	assert_eq(rejected.reject.result, NetProtocol.Result.FULL, "FULL: the four that are verifying take up the quota")
	assert_eq(_server.get_player_count(), 4, "four in VERIFYING")
	var welcomed: bool = await _run_until(func() -> bool:
		return clients.filter(func(c: RawTicketClient) -> bool: return c.welcome != null).size() == 4)
	assert_true(welcomed, "the four receive their WELCOME with the 200")
	assert_eq(_platform.sent(PlatformEvent.KIND_CLAIM).size(), 4, "only four claims")


## The HELLO arrives 1.4 s after connecting and the claim takes 5 s: the WELCOME goes out at ~6.4 s, before the 7 s deadline
## and the 10 s auth_timeout on both sides (with 5 s, the client would have dropped).
func test_late_hello_and_slow_claim_still_get_welcome() -> void:
	if not await _start(Callable(), func(platform: FakeZonePlatform) -> void:
			platform.add_character(42, 7, &"player", VARDHEIM, {})):
		return
	_platform.script_next(PlatformEvent.KIND_CLAIM, 200, FakeZonePlatform.DEFAULT, 5.0)
	var client: RawTicketClient = _connect(_hello(42, _ticket(42)), true, 1400)
	var joined: bool = await _run_until(func() -> bool:
		return client.own_spawn != null or client.reject != null or client.failed, 9000)
	if not assert_true(joined and client.own_spawn != null, "enters the world (rejection: %s)"
			% (client.reject.text if client.reject != null else "ninguno")):
		return
	var elapsed: int = client.welcome_at_msec - client.connected_at_msec
	assert_true(elapsed >= 6000 and elapsed < 7000, "the WELCOME arrives %d ms after connecting" % elapsed)
	assert_false(client.failed or client.disconnected, "nobody drops because of the auth_timeout")


## Silent platform: REJECT UNAVAILABLE at 7 s (real clock) and, when the claim arrives afterwards, it is released.
func test_mute_platform_rejects_with_unavailable_after_seven_seconds() -> void:
	if not await _start(Callable(), func(platform: FakeZonePlatform) -> void:
			platform.add_character(42, 7, &"player", VARDHEIM, {})):
		return
	_platform.script_next(PlatformEvent.KIND_CLAIM, 200, FakeZonePlatform.DEFAULT, 8.0)
	var client: RawTicketClient = _connect(_hello(42, _ticket(42)))
	var rejected: bool = await _run_until(func() -> bool: return client.reject != null, 9000)
	if not assert_true(rejected, "REJECT"):
		return
	assert_eq(client.reject.result, NetProtocol.Result.UNAVAILABLE, "UNAVAILABLE")
	assert_eq(client.reject.text, NetProtocol.result_text(NetProtocol.Result.UNAVAILABLE),
			"\"El servicio de cuentas no responde: inténtalo más tarde\" (the accounts service is not responding: try again later)")
	var elapsed: int = client.reject_at_msec - client.connected_at_msec
	assert_true(elapsed >= 6900 and elapsed < 8000, "7 s after connecting (%d ms)" % elapsed)
	var released: bool = await _run_until(func() -> bool:
		return not _platform.sent(ZonePlatform.KIND_RELEASE).is_empty(), 3000)
	if assert_true(released, "the claim that arrives afterwards is released"):
		assert_eq(_platform.sent(ZonePlatform.KIND_RELEASE)[0]["lease_id"], _platform.claimed(42).lease_id,
				"with its lease_id")
	assert_true(_platform.heartbeat_set().is_empty(), "and it does not stay in the heartbeat")


func test_fenced_zone_rejects_with_unavailable() -> void:
	if not await _start(Callable(), func(platform: FakeZonePlatform) -> void:
			platform.add_character(42, 7, &"player", VARDHEIM, {})):
		return
	_platform.set_fenced(true)
	var client: RawTicketClient = _connect(_hello(42, _ticket(42)))
	await _run_until(func() -> bool: return client.reject != null)
	if assert_not_null(client.reject, "REJECT"):
		assert_eq(client.reject.result, NetProtocol.Result.UNAVAILABLE, "fenced zone: UNAVAILABLE")
	assert_eq(_platform.sent(PlatformEvent.KIND_CLAIM).size(), 0, "no claim")
	_platform.set_fenced(false)
	var later: RawTicketClient = _connect(_hello(42, _ticket(42)))
	await _run_until(func() -> bool: return later.own_spawn != null)
	assert_not_null(later.own_spawn, "with the heartbeat back, it gets in")


func test_leaving_while_verifying_releases_the_late_claim() -> void:
	if not await _start(Callable(), func(platform: FakeZonePlatform) -> void:
			platform.add_character(42, 7, &"player", VARDHEIM, {})):
		return
	_platform.script_next(PlatformEvent.KIND_CLAIM, 200, FakeZonePlatform.DEFAULT, 1.0)
	var client: RawTicketClient = _connect(_hello(42, _ticket(42)))
	await _run_until(func() -> bool: return _server_peer_in(ServerPeer.State.VERIFYING) != null)
	client.transport.close()
	var gone: bool = await _run_until(func() -> bool: return _server.get_peer_ids().is_empty())
	assert_true(gone, "the server removes the peer that was verifying")
	assert_eq(_server.get_player_count(), 0, "and frees its slot")
	var released: bool = await _run_until(func() -> bool:
		return not _platform.sent(ZonePlatform.KIND_RELEASE).is_empty(), 3000)
	if assert_true(released, "the claim that arrives afterwards is released"):
		assert_eq(_platform.sent(ZonePlatform.KIND_RELEASE)[0]["lease_id"], _platform.claimed(42).lease_id,
				"with its lease_id")
	assert_eq(_provider.pending_count(), 0, "the provider is not waiting for anyone")


func test_leaving_while_loading_releases_without_saving() -> void:
	if not await _start(Callable(), func(platform: FakeZonePlatform) -> void:
			platform.add_character(42, 7, &"player", VARDHEIM, {})):
		return
	var client: RawTicketClient = _connect(_hello(42, _ticket(42)), false)
	var loading: bool = await _run_until(func() -> bool:
		return client.connected and _server_peer_in(ServerPeer.State.LOADING) != null)
	if not assert_true(loading, "WELCOME and LOADING"):
		return
	var lease_id: String = _platform.claimed(42).lease_id
	client.transport.close()
	var released: bool = await _run_until(func() -> bool:
		return not _platform.sent(ZonePlatform.KIND_RELEASE).is_empty())
	if assert_true(released, "the removal in LOADING releases"):
		assert_eq(_platform.sent(ZonePlatform.KIND_RELEASE), [{"zone_instance_id": _platform.instance_id(),
				"lease_id": lease_id}], "once, with its lease_id")
	assert_eq(_platform.sent(PlatformEvent.KIND_SAVE).size(), 0, "without saving")
	assert_true(_platform.heartbeat_set().is_empty(), "and leaves the heartbeat")


## A heartbeat revoked with a character in LOADING: kick NOTICE with the platform's text and release
## without saving.
func test_revoked_while_loading_kicks_and_releases() -> void:
	if not await _start(Callable(), func(platform: FakeZonePlatform) -> void:
			platform.add_character(42, 7, &"player", VARDHEIM, {})):
		return
	var client: RawTicketClient = _connect(_hello(42, _ticket(42)), false)
	await _run_until(func() -> bool: return client.connected and _server_peer_in(ServerPeer.State.LOADING) != null)
	await _run_ms(100)
	var lease_id: String = _platform.claimed(42).lease_id
	_platform.script_next(PlatformEvent.KIND_HEARTBEAT, 200, {"now_unix": _platform.now_unix(), "revoked": [
			{"character_id": "42", "lease_id": lease_id, "reason": "session_revoked",
			"text": "Has iniciado sesión desde otro lugar"}], "mutes": [], "maintenance": null})
	_platform.send_heartbeat_now()
	var kicked: bool = await _run_until(func() -> bool: return client.kick_notice() != null)
	if assert_true(kicked, "kick NOTICE"):
		assert_eq(client.kick_notice().text, "Has iniciado sesión desde otro lugar", "with the platform's text")
	var released: bool = await _run_until(func() -> bool:
		return not _platform.sent(ZonePlatform.KIND_RELEASE).is_empty())
	if assert_true(released, "and it is released"):
		assert_eq(_platform.sent(ZonePlatform.KIND_RELEASE)[0]["lease_id"], lease_id, "its lease")
	assert_eq(_platform.sent(PlatformEvent.KIND_SAVE).size(), 0, "without saving")


## In the world: a revoked with an old lease_id does not kick; with the current one, it does (and when the body leaves its final
## save goes out with release_lease, which releases: since progression.md P5a the progress section is always built); a lease_lost
## kicks without releasing or saving.
func test_revoked_in_the_world_only_with_the_current_lease() -> void:
	if not await _start(Callable(), func(platform: FakeZonePlatform) -> void:
			platform.add_character(42, 7, &"player", VARDHEIM, {})
			platform.add_character(43, 8, &"player", SOLMARCH, {})):
		return
	var first: RawTicketClient = await _join(42)
	var second: RawTicketClient = await _join(43)
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
	assert_null(first.kick_notice(), "an old lease_id does not kick")
	assert_false(first.disconnected, "still connected")
	revoke.call("42", lease_42, "banned", "Tu cuenta está expulsada: trampas")
	await _run_until(func() -> bool: return first.kick_notice() != null)
	if assert_not_null(first.kick_notice(), "with the current one, a kick"):
		assert_eq(first.kick_notice().text, "Tu cuenta está expulsada: trampas", "with the platform's text")
	var final_of_42: Callable = func() -> Array[Dictionary]:
		return _platform.sent(PlatformEvent.KIND_SAVE).filter(func(b: Dictionary) -> bool:
			return bool(b["release_lease"]) and String(b["lease_id"]) == lease_42)
	var finished: bool = await _run_until(func() -> bool: return not (final_of_42.call() as Array).is_empty())
	assert_true(finished, "when the body leaves its final save goes out with release_lease, which releases")
	var saves_before: int = _platform.sent(PlatformEvent.KIND_SAVE).size()
	revoke.call("43", lease_43, "lease_lost", "Tu personaje ha entrado en otro servidor")
	await _run_until(func() -> bool: return second.kick_notice() != null)
	if assert_not_null(second.kick_notice(), "lease_lost kicks"):
		assert_eq(second.kick_notice().text, "Tu personaje ha entrado en otro servidor", "with its text")
	await _run_until(func() -> bool: return _server.get_registry().get_sorted().filter(
			func(e: NetEntity) -> bool: return e.kind == NetProtocol.EntityKind.PLAYER).is_empty(), 2000)
	await _run_ms(200)
	assert_eq(_platform.sent(ZonePlatform.KIND_RELEASE).size(), 0, "lease_lost does not release (it no longer belongs to the zone)")
	assert_eq(_platform.sent(PlatformEvent.KIND_SAVE).size(), saves_before, "nor save")
	assert_false(_platform.heartbeat_set().has(43), "nor does the heartbeat keep beating for it")


## BUSY with its text and BANNED with the 403's message, for suspension, kick and pending deletion.
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
		var client: RawTicketClient = _connect(_hello(42, _ticket(42)))
		await _run_until(func() -> bool: return client.reject != null or client.welcome != null)
		if assert_not_null(client.reject, "REJECT for %s" % entry[3]):
			assert_eq([client.reject.result, client.reject.text], [entry[2], entry[3]], entry[3])
	assert_eq(_platform.sent(ZonePlatform.KIND_RELEASE).size(), 0, "with no lease, nothing to release")


## docs/social.md 12.7: with a ticket, the HELLO's name is not compared with the connected players. A HELLO with another
## character's ticket and the name of a connected enemy does not receive NAME: it enters with its character (or, with a ticket
## that is not valid, receives TICKET). Nothing gives away whether the enemy is in the zone.
func test_hello_cannot_probe_an_enemy_name() -> void:
	if not await _start(Callable(), func(platform: FakeZonePlatform) -> void:
			platform.add_character(2, 20, &"player", SOLMARCH, {}, {}, "Bruna")
			platform.add_character(3, 30, &"player", VARDHEIM, {}, {}, "Ana")):
		return
	var enemy: RawTicketClient = await _join(2)
	if enemy == null:
		return
	assert_true(_server.get_connected_names().has("Bruna"), "Bruna is in the zone")
	var probe: RawTicketClient = _connect(_hello(3, _ticket(3), SOLMARCH, "Bruna"))
	await _run_until(func() -> bool: return probe.own_spawn != null or probe.reject != null)
	assert_null(probe.reject, "neither NAME nor any other REJECT")
	if assert_not_null(probe.own_spawn, "enters with its character"):
		assert_eq(probe.own_spawn.display_name, "Ana", "with its name")
		assert_eq(probe.welcome.realm, VARDHEIM, "and its realm")
	var forged: RawTicketClient = _connect(_hello(3, _ticket(2), SOLMARCH, "Bruna"))
	await _run_until(func() -> bool: return forged.reject != null or forged.welcome != null)
	if assert_not_null(forged.reject, "another character's ticket"):
		assert_eq(forged.reject.result, NetProtocol.Result.TICKET, "TICKET, not NAME")
	var bare: RawTicketClient = _connect(_hello(0, PackedByteArray(), SOLMARCH, "Bruna"))
	await _run_until(func() -> bool: return bare.reject != null or bare.welcome != null)
	if assert_not_null(bare.reject, "no ticket"):
		assert_eq(bare.reject.result, NetProtocol.Result.TICKET, "TICKET, not NAME")
	var absent: RawTicketClient = _connect(_hello(3, PackedByteArray(), SOLMARCH, "Nadie"))
	await _run_until(func() -> bool: return absent.reject != null or absent.welcome != null)
	if assert_not_null(absent.reject, "with a name that is not there"):
		assert_eq([absent.reject.result, absent.reject.text], [bare.reject.result, bare.reject.text],
				"the same response as with the enemy's")


## With a production env, --debug-commands makes startup fail (the zone exits) and the instance
## deregisters.
func test_debug_commands_with_production_env_stop_the_startup() -> void:
	_platform = FakeZonePlatform.new()
	_platform.fake_env = &"production"
	_platform.log_sink = func(_text: String) -> void: pass
	_viewport = SubViewport.new()
	tree.root.add_child(_viewport)
	_viewport.add_child(_platform)
	var config := ServerConfig.from_args(PackedStringArray(["--server", "--zone=test_world",
			"--platform=http://fake", "--debug-commands"]))
	assert_true(config.uses_platform() and config.debug_commands, "the options are read")
	var finished: Array = []
	_platform.startup_finished.connect(func(ok: bool, error: String) -> void: finished.append([ok, error]))
	_platform.start(config, {"token": "token", "ticket_keys": {2: _keys[2]}})
	for _i: int in 60:
		if not finished.is_empty():
			break
		await wait_process_frames()
	if assert_eq(finished.size(), 1, "startup finishes"):
		assert_false(finished[0][0], "badly")
		assert_eq(finished[0][1], "Esa opción no se admite con la plataforma en staging/production: --debug-commands",
				"with the reason")
	await wait_process_frames(3)
	assert_eq(_platform.sent(ZonePlatform.KIND_STOP).size(), 1, "and the instance deregisters")
	assert_eq(_platform.sent(ZonePlatform.KIND_FORTRESSES).size(), 0, "without continuing with startup")
