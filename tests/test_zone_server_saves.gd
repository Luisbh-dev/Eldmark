extends TestCase
## Tests for saves in [ZoneServer] with [FakeZonePlatform], a [FakeSaveSection] and real clients over
## ENet on 127.0.0.1 (docs/platform.md §7.2, §6.1 and §15 P5): the critical save right after track and the
## checkpoint in its phase, the combat exit that saves when the body leaves, removal without a save (an
## invalid_save in combat and a revoked lease_lost in combat), a revoked that kicks with a final save, the
## §6.1 shutdown (instance_lost in the heartbeat, instance_replaced in a save) with the final saves before the
## NOTICE, the orderly shutdown that waits for the platform and releases those in LOADING and VERIFYING, the
## heartbeat's maintenance, the reconnection that brings the latest applied state and the same character coming
## back while its final save is being retried.

const VARDHEIM: int = NetProtocol.Realm.VARDHEIM
const SOLMARCH: int = NetProtocol.Realm.SOLMARCH
const PLAYER_SCENE: PackedScene = preload("res://scenes/characters/player_character.tscn")
const ZONE_ID: String = "test_world"
const FIRST_TICKET_ID: int = 9007199254740993

var _viewport: SubViewport
var _world: Node3D
var _server: ZoneServer
var _server_transport: NetTransport
var _platform: FakeZonePlatform
var _provider: TicketAuthProvider
var _section: FakeSaveSection
var _keys: Dictionary[int, PackedByteArray] = {}
var _port: int = 0
var _clients: Array[RawTicketClient] = []
var _client_tick: int = 0
var _next_client_index: int = 0
var _next_ticket_id: int = FIRST_TICKET_ID
var _sim_hash: int = -1


func before_each() -> void:
	_keys = {2: "02b7825be38fdd5396a4a058286884eaf93a9df85b874f78b4010a76103fb858".hex_decode()}


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
	_section = null
	_world = null
	_viewport = null
	_client_tick = 0
	_sim_hash = -1
	await wait_process_frames()


# --- Helpers ----------------------------------------------------------------------------------

## The test zone with the fake platform already started, the server listening with a checkpoint every 2 s
## (120 ticks) and the fake section registered. [param configure] receives the [ServerConfig] and [param setup]
## the platform before startup.
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
	config.save_interval_s = 2
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
	if not assert_not_null(_server.get_saver(), "with the platform there is a CharacterSaver"):
		return false
	assert_eq(_server.get_saver().interval_ticks(), 120, "--save-interval=2: 120 ticks")
	_section = FakeSaveSection.new()
	_section.tick_source = _server.get_tick
	_section.attach(_server.get_saver())
	_platform.go_live()
	return true


func _ticket(character_id: int) -> PackedByteArray:
	var ticket := HandoffTicket.new()
	ticket.key_id = 2
	ticket.world_id = 1
	ticket.ticket_id = _next_ticket_id
	_next_ticket_id += 1
	ticket.character_id = character_id
	ticket.zone_key = HandoffTicket.zone_key_of(ZONE_ID)
	ticket.realm = VARDHEIM
	ticket.flags = HandoffTicket.FLAG_FROM_MENU
	ticket.issued_at = _platform.now_unix()
	ticket.expires_at = ticket.issued_at + 10
	return ticket.sign(_keys[2])


func _hello(character_id: int) -> PackedByteArray:
	var hello := NetMessages.Hello.new()
	hello.sim_hash = _client_sim_hash()
	hello.realm = VARDHEIM
	hello.display_name = "Cualquiera"
	hello.character_id = character_id
	hello.ticket = _ticket(character_id)
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


func _connect(character_id: int, auto_ready: bool = true) -> RawTicketClient:
	var transport := NetTransport.new()
	transport.name = "ClientTransport%d" % _next_client_index
	_next_client_index += 1
	_viewport.add_child(transport)
	var client := RawTicketClient.new(transport, _hello(character_id))
	client.auto_ready = auto_ready
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


## Character [param character_id] joins with a ticket and waits to be signed up.
func _join(character_id: int) -> RawTicketClient:
	var client: RawTicketClient = _connect(character_id)
	var joined: bool = await _run_until(func() -> bool: return client.own_spawn != null or client.reject != null)
	if not assert_true(joined and client.own_spawn != null, "character %d enters the world" % character_id):
		return null
	return client


func _saves() -> Array[Dictionary]:
	return _platform.sent(PlatformEvent.KIND_SAVE)


func _releases() -> Array[Dictionary]:
	return _platform.sent(ZonePlatform.KIND_RELEASE)


## The final saves (with release_lease) of [param character_id].
func _finals_of(character_id: int) -> Array[Dictionary]:
	var finals: Array[Dictionary] = []
	for body: Dictionary in _saves():
		if String(body.get("character_id", "")) == str(character_id) and bool(body.get("release_lease", false)):
			finals.append(body)
	return finals


func _has_body(net_id: int) -> bool:
	return _server.get_registry().get_entity(net_id) != null


func _put_in_combat(net_id: int) -> void:
	_server.get_combat().get_combatant(net_id).mark_combat(_server.get_tick())


func _script_heartbeat(revoked: Array, maintenance: Variant = null) -> void:
	_platform.script_next(PlatformEvent.KIND_HEARTBEAT, 200, {"now_unix": _platform.now_unix(), "revoked": revoked,
			"mutes": [], "maintenance": maintenance})
	_platform.send_heartbeat_now()


# --- Tests ------------------------------------------------------------------------------------

## A critical flagged right after track (on sign-up) goes out on that same tick; afterwards, each character's
## checkpoint goes out in its phase (tick % 120 == character_id % 120) when its section is dirty.
func test_a_critical_right_after_track_and_checkpoints_in_their_phase() -> void:
	var joined_tick: Dictionary[int, int] = {}
	if not await _start(Callable(), func(platform: FakeZonePlatform) -> void:
			platform.add_character(10, 1, &"player", VARDHEIM, {})
			platform.add_character(70, 2, &"player", VARDHEIM, {})):
		return
	_server.player_joined.connect(func(_peer_id: int, net_id: int) -> void:
		joined_tick[net_id] = _server.get_tick()
		_server.get_saver().mark_critical(net_id, &"starter_kit"))
	var first: RawTicketClient = await _join(10)
	var second: RawTicketClient = await _join(70)
	if first == null or second == null:
		return
	var net_10: int = first.own_spawn.net_id
	var net_70: int = second.own_spawn.net_id
	await _run_until(func() -> bool: return _section.acknowledged.size() == 2)
	assert_eq(_section.build_ticks(net_10), [joined_tick[net_10]], "the sign-up critical goes out on the sign-up tick")
	assert_eq(_section.build_ticks(net_70), [joined_tick[net_70]], "also the second one's")
	_section.set_kills(net_10, 1)
	_section.set_kills(net_70, 2)
	await _run_until(func() -> bool:
		return _section.build_ticks(net_10).size() == 2 and _section.build_ticks(net_70).size() == 2, 4500)
	var tick_10: int = _section.build_ticks(net_10)[-1] if _section.build_ticks(net_10).size() == 2 else -1
	var tick_70: int = _section.build_ticks(net_70)[-1] if _section.build_ticks(net_70).size() == 2 else -1
	assert_eq(tick_10 % 120, 10, "the checkpoint of 10 in its phase (tick %d)" % tick_10)
	assert_eq(tick_70 % 120, 70, "that of 70 in its own (tick %d)" % tick_70)
	var reasons: Array = _saves().map(func(b: Dictionary) -> int: return int(b["reason"]))
	assert_eq(reasons, [2, 2, 1, 1], "two criticals and two checkpoints")


## Combat exit (GUE-41): the body stays and its final save goes out when it leaves, with reason 3.
func test_leaving_in_combat_saves_when_the_body_goes() -> void:
	if not await _start(Callable(), func(platform: FakeZonePlatform) -> void:
			platform.add_character(42, 7, &"player", VARDHEIM, {})):
		return
	_server.linger_ticks = 60
	var client: RawTicketClient = await _join(42)
	if client == null:
		return
	var net_id: int = client.own_spawn.net_id
	_section.set_kills(net_id, 3)
	_put_in_combat(net_id)
	client.transport.close()
	var lingering: bool = await _run_until(func() -> bool: return _server.is_lingering(net_id))
	if not assert_true(lingering, "the body stays"):
		return
	assert_eq(_finals_of(42).size(), 0, "no final save while the body remains")
	var gone: bool = await _run_until(func() -> bool: return not _has_body(net_id), 3000)
	assert_true(gone, "the body leaves")
	await _run_until(func() -> bool: return not _finals_of(42).is_empty(), 1000)
	var finals: Array[Dictionary] = _finals_of(42)
	if assert_eq(finals.size(), 1, "one final save when the body leaves"):
		assert_eq(int(finals[0]["reason"]), CharacterSaver.Reason.LOGOUT, "reason 3")
		assert_eq(int(finals[0]["pvp"]["kills"]), 3, "with its section")
	assert_eq(_releases().size(), 0, "the final save releases: no separate release")


## Removal without a save: an invalid_save with the player in combat takes the body out immediately (no
## combat exit), releases once, the "Salida" section sends nothing and the section receives nothing more; a revoked lease_lost in
## combat, the same but without releasing.
func test_a_rejected_save_and_a_lease_lost_drop_the_body_at_once() -> void:
	if not await _start(Callable(), func(platform: FakeZonePlatform) -> void:
			platform.add_character(42, 7, &"player", VARDHEIM, {})
			platform.add_character(43, 8, &"player", VARDHEIM, {})):
		return
	_server.linger_ticks = 600
	var first: RawTicketClient = await _join(42)
	var second: RawTicketClient = await _join(43)
	if first == null or second == null:
		return
	var net_42: int = first.own_spawn.net_id
	var net_43: int = second.own_spawn.net_id
	# The kit from each one's first entry has already gone out as a critical (progression.md P5a): counting starts from here.
	await _run_until(func() -> bool: return _server.get_saver().pending_count() == 0)
	var saves_before: int = _saves().size()
	_put_in_combat(net_42)
	_put_in_combat(net_43)
	_platform.script_next(PlatformEvent.KIND_SAVE, 400, FakeZonePlatform.error_body("invalid_save", "",
			{"fields": {"check": "S5", "detail": "uid fuera de los bloques"}}))
	_section.set_kills(net_42, 1)
	_server.get_saver().mark_critical(net_42, &"gm")
	var kicked: bool = await _run_until(func() -> bool: return first.kick_notice() != null)
	if not assert_true(kicked, "kick"):
		return
	assert_eq(first.kick_notice().text, ZoneServer.SAVE_REJECTED_TEXT, "\"No se ha podido guardar tu personaje…\" (your character could not be saved)")
	await _run_until(func() -> bool: return not _has_body(net_42), 1000)
	assert_false(_has_body(net_42), "the body leaves immediately")
	assert_false(_server.is_lingering(net_42), "no combat exit")
	var calls: int = _section.calls_for(net_42)
	await _run_ms(300)
	assert_eq(_saves().size(), saves_before + 1, "the \"Salida\" section sends nothing")
	assert_eq(_releases().map(func(b: Dictionary) -> String: return String(b["lease_id"])),
			[_platform.claimed(42).lease_id], "it is released once")
	assert_eq(_section.calls_for(net_42), calls, "the section receives nothing more from the body that left")
	assert_false(_server.get_saver().is_tracked(net_42), "no entry")
	_script_heartbeat([{"character_id": "43", "lease_id": _platform.claimed(43).lease_id, "reason": "lease_lost",
			"text": "Tu personaje ha entrado en otro servidor"}])
	kicked = await _run_until(func() -> bool: return second.kick_notice() != null)
	if assert_true(kicked, "lease_lost kicks"):
		assert_eq(second.kick_notice().text, ZoneServer.LEASE_LOST_TEXT, "with its text")
	await _run_until(func() -> bool: return not _has_body(net_43), 1000)
	assert_false(_has_body(net_43), "the body leaves immediately")
	await _run_ms(300)
	assert_eq(_saves().size(), saves_before + 1, "no save")
	assert_eq(_releases().size(), 1, "nor release")


## A revoked that is not lease_lost (session_revoked) kicks with its text and the final save, with reason 5.
func test_a_revoked_session_kicks_with_a_final_save() -> void:
	if not await _start(Callable(), func(platform: FakeZonePlatform) -> void:
			platform.add_character(42, 7, &"player", VARDHEIM, {})):
		return
	var client: RawTicketClient = await _join(42)
	if client == null:
		return
	_section.set_kills(client.own_spawn.net_id, 5)
	_script_heartbeat([{"character_id": "42", "lease_id": _platform.claimed(42).lease_id,
			"reason": "session_revoked", "text": "Has iniciado sesión desde otro lugar"}])
	await _run_until(func() -> bool: return not _finals_of(42).is_empty())
	if assert_not_null(client.kick_notice(), "kick"):
		assert_eq(client.kick_notice().text, "Has iniciado sesión desde otro lugar", "with the platform's text")
	var finals: Array[Dictionary] = _finals_of(42)
	if assert_eq(finals.size(), 1, "with a final save"):
		assert_eq(int(finals[0]["reason"]), CharacterSaver.Reason.KICK, "reason 5")
		assert_eq(int(finals[0]["pvp"]["kills"]), 5, "with its section")


## The §6.1 shutdown from an instance_lost in the heartbeat: everyone's final saves go out and are answered before the kick
## NOTICE; those in LOADING are released; and whoever re-enters right away loads their final save.
func test_instance_lost_saves_everyone_before_the_kick_notice() -> void:
	await _check_instance_closing(func() -> void:
		_platform.script_next(PlatformEvent.KIND_HEARTBEAT, 409, FakeZonePlatform.error_body("instance_lost"))
		_platform.send_heartbeat_now(), "instance_lost")


## The same with an instance_replaced arriving in the instance_status of a save.
func test_instance_replaced_in_a_save_status_closes_the_same_way() -> void:
	await _check_instance_closing(func() -> void:
		_platform.script_next(PlatformEvent.KIND_SAVE, 200, {"applied": true, "duplicate": false, "save_version": 1,
				"instance_status": "replaced"})
		_server.get_saver().mark_critical(_server.get_saver().tracked_net_ids()[0], &"gm"), "instance_replaced")


func _check_instance_closing(trigger: Callable, expected_code: String) -> void:
	if not await _start(Callable(), func(platform: FakeZonePlatform) -> void:
			platform.add_character(42, 7, &"player", VARDHEIM, {})
			platform.add_character(43, 8, &"player", VARDHEIM, {})):
		return
	var codes: Array[String] = []
	_server.instance_closed.connect(func(code: String) -> void:
		codes.append(code)
		_server.close_instance(code))
	var client: RawTicketClient = await _join(42)
	var loading: RawTicketClient = _connect(43, false)
	if client == null:
		return
	await _run_until(func() -> bool: return loading.connected)
	var net_id: int = client.own_spawn.net_id
	_section.set_kills(net_id, 11)
	trigger.call()
	# The final save takes 0.6 s to be answered: the NOTICE has to wait for it.
	_platform.script_next(PlatformEvent.KIND_SAVE, 200, FakeZonePlatform.DEFAULT, 0.6)
	var closed: bool = await _run_until(func() -> bool: return not codes.is_empty(), 3000)
	if not assert_true(closed, "the zone receives instance_closed"):
		return
	var closed_at: int = Time.get_ticks_msec()
	assert_eq(codes, [expected_code], "once, with its code")
	var released: bool = await _run_until(func() -> bool: return _releases().size() == 1, 1000)
	if assert_true(released, "the one in LOADING is released right away"):
		assert_eq(String(_releases()[0]["lease_id"]), _platform.claimed(43).lease_id, "with its lease")
	assert_null(client.kick_notice(), "nobody is kicked before the final saves")
	var kicked: bool = await _run_until(func() -> bool: return client.kick_notice() != null, 4000)
	if not assert_true(kicked, "kick NOTICE"):
		return
	assert_eq(client.kick_notice().text, ZoneServer.INSTANCE_CLOSED_TEXT, "\"El servidor de la zona se ha reiniciado…\" (the zone server has restarted)")
	assert_true(client.notice_time(NetProtocol.NoticeCode.KICK) - closed_at >= 500,
			"after the final save's response (%d ms)" % (client.notice_time(NetProtocol.NoticeCode.KICK) - closed_at))
	assert_not_null(loading.kick_notice(), "also to the one in LOADING")
	var finals: Array[Dictionary] = _finals_of(42)
	if assert_eq(finals.size(), 1, "one final save"):
		assert_eq(int(finals[0]["reason"]), CharacterSaver.Reason.SHUTDOWN, "reason 4")
	var stopped: bool = await _run_until(func() -> bool: return _server.is_stopped(), 2000)
	assert_true(stopped, "the zone finishes")
	assert_eq(_server.get_saver().pending_count(), 0, "with no pending saves")
	# Whoever re-enters right away loads their final save.
	_platform.take_events()
	var ticket := HandoffTicket.new()
	ticket.ticket_id = _next_ticket_id
	ticket.character_id = 42
	_platform.claim(99, ticket)
	var claim: Array[PlatformEvent] = []
	for _i: int in 60:
		for event: PlatformEvent in _platform.take_events():
			if event.kind == PlatformEvent.KIND_CLAIM:
				claim.append(event)
		if not claim.is_empty():
			break
		await wait_process_frames()
	if assert_eq(claim.size(), 1, "the next claim"):
		var claimed: ClaimedCharacter = ClaimedCharacter.from_claim(claim[0].body_dict())
		if assert_not_null(claimed, "is understood"):
			assert_eq(int(claimed.pvp["kills"]), 11, "brings the final save")


## The orderly shutdown waits for the platform to answer the final saves (after 2 s) and releases those in LOADING and
## VERIFYING (the claim that arrives late) before finishing.
func test_the_ordered_stop_waits_for_the_platform_and_releases_loading_and_verifying() -> void:
	if not await _start(Callable(), func(platform: FakeZonePlatform) -> void:
			platform.add_character(42, 7, &"player", VARDHEIM, {})
			platform.add_character(43, 8, &"player", VARDHEIM, {})
			platform.add_character(44, 9, &"player", VARDHEIM, {})):
		return
	var client: RawTicketClient = await _join(42)
	if client == null:
		return
	_section.set_kills(client.own_spawn.net_id, 4)
	var loading: RawTicketClient = _connect(43, false)
	await _run_until(func() -> bool: return loading.connected)
	_platform.script_next(PlatformEvent.KIND_CLAIM, 200, FakeZonePlatform.DEFAULT, 1.5)
	var verifying: RawTicketClient = _connect(44)
	await _run_until(func() -> bool:
		for peer_id: int in _server.get_peer_ids():
			if _server.get_peer(peer_id).state == ServerPeer.State.VERIFYING:
				return true
		return false)
	_platform.script_next(PlatformEvent.KIND_SAVE, 200, FakeZonePlatform.DEFAULT, 2.0)
	var started: int = Time.get_ticks_msec()
	_server.stop()
	assert_false(_server.is_stopped(), "it does not finish while the final save has no response")
	var stopped: bool = await _run_until(func() -> bool: return _server.is_stopped(), 5000)
	var elapsed: int = Time.get_ticks_msec() - started
	if not assert_true(stopped, "it finishes"):
		return
	assert_true(elapsed >= 1900 and elapsed < 3500, "after the final save's response (%d ms)" % elapsed)
	var finals: Array[Dictionary] = _finals_of(42)
	if assert_eq(finals.size(), 1, "the final save of the one who was in the world"):
		assert_eq(int(finals[0]["reason"]), CharacterSaver.Reason.SHUTDOWN, "reason 4")
	var leases: Array = _releases().map(func(b: Dictionary) -> String: return String(b["lease_id"]))
	assert_eq(leases, [_platform.claimed(43).lease_id, _platform.claimed(44).lease_id],
			"the one in LOADING is released and, when its claim arrives, so is the one in VERIFYING")
	assert_true(_platform.is_flushed(), "nothing queued or in flight")
	assert_true(client.notice_time(NetProtocol.NoticeCode.SHUTDOWN) >= 0, "shutdown NOTICE")
	assert_null(verifying.welcome, "the one in VERIFYING never gets in")


## The heartbeat's maintenance warns at 10, 5 and 1 min, at 30 s and at 10 s (using the platform's time) and,
## when the time comes, requests the orderly shutdown.
func test_maintenance_announces_and_asks_for_the_shutdown() -> void:
	var now: int = 1_800_000_000
	if not await _start(Callable(), func(platform: FakeZonePlatform) -> void:
			platform.fake_now_unix = now
			platform.add_character(42, 7, &"player", VARDHEIM, {})):
		return
	var requested: Array[String] = []
	_server.shutdown_requested.connect(func(reason: String) -> void: requested.append(reason))
	var client: RawTicketClient = await _join(42)
	if client == null:
		return
	_platform.fake_maintenance = {"at_unix": now + 600, "message": "versión nueva"}
	_platform.send_heartbeat_now()
	await _run_until(func() -> bool: return client.notice_texts(NetProtocol.NoticeCode.INFO).size() == 1)
	assert_eq(_server.get_maintenance_at_unix(), now + 600, "announced")
	for left: int in [300, 61, 60, 30, 11, 10, 1]:
		_platform.fake_now_unix = now + 600 - left
		await _run_ms(80)
	assert_eq(requested.size(), 0, "no shutdown yet")
	_platform.fake_now_unix = now + 600
	await _run_until(func() -> bool: return not requested.is_empty(), 1000)
	assert_eq(client.notice_texts(NetProtocol.NoticeCode.INFO), PackedStringArray([
			"El servidor se cerrará por mantenimiento en 10 min: versión nueva",
			"El servidor se cerrará por mantenimiento en 5 min: versión nueva",
			"El servidor se cerrará por mantenimiento en 1 min: versión nueva",
			"El servidor se cerrará por mantenimiento en 30 s: versión nueva",
			"El servidor se cerrará por mantenimiento en 10 s: versión nueva",
	]), "the five warnings")
	assert_eq(requested, ["mantenimiento de la plataforma"], "and when the time comes, the shutdown")
	# One that was announced and the platform withdraws: a cancellation warning and nothing more.
	_platform.fake_maintenance = {"at_unix": now + 1200, "message": ""}
	_platform.send_heartbeat_now()
	await _run_until(func() -> bool: return client.notice_texts(NetProtocol.NoticeCode.INFO).size() == 6)
	_platform.fake_maintenance = null
	_platform.send_heartbeat_now()
	await _run_until(func() -> bool: return client.notice_texts(NetProtocol.NoticeCode.INFO).size() == 7)
	var texts: PackedStringArray = client.notice_texts(NetProtocol.NoticeCode.INFO)
	assert_eq(texts.slice(5), PackedStringArray(["El servidor se cerrará por mantenimiento en 10 min",
			"Mantenimiento cancelado: el servidor sigue abierto"]), "announced and cancelled")
	assert_eq(_server.get_maintenance_at_unix(), 0, "no maintenance")


## Reconnecting returns the section's latest applied state.
func test_reconnecting_brings_back_the_last_applied_section() -> void:
	if not await _start(Callable(), func(platform: FakeZonePlatform) -> void:
			platform.add_character(42, 7, &"player", VARDHEIM, {})):
		return
	var client: RawTicketClient = await _join(42)
	if client == null:
		return
	var first_lease: String = _platform.claimed(42).lease_id
	_section.set_kills(client.own_spawn.net_id, 7)
	client.leave()
	await _run_until(func() -> bool: return _server.get_saver().entry_count() == 0)
	assert_eq(_finals_of(42).size(), 1, "the final save on exit")
	var again: RawTicketClient = await _join(42)
	if again == null:
		return
	var claimed: ClaimedCharacter = _platform.claimed(42)
	assert_false(claimed.lease_id == first_lease, "another claim, another lease_id")
	assert_eq(int(claimed.pvp["kills"]), 7, "the claim brings the latest applied state")
	assert_eq(_server.get_saver().lease_of(42), claimed.lease_id, "and the new body saves with the new lease")


## The same character returns to this instance while its final save, already applied, is being retried: the old entry receives
## lease_lost and is only logged (without releasing), and the new body is not kicked.
func test_the_same_character_back_while_its_final_is_retried() -> void:
	if not await _start(Callable(), func(platform: FakeZonePlatform) -> void:
			platform.add_character(42, 7, &"player", VARDHEIM, {})):
		return
	var client: RawTicketClient = await _join(42)
	if client == null:
		return
	_section.set_kills(client.own_spawn.net_id, 2)
	_platform.script_next(PlatformEvent.KIND_SAVE, 0, null, 0.3)
	_platform.script_next(PlatformEvent.KIND_SAVE, 0, null, 0.3)
	_platform.script_next(PlatformEvent.KIND_SAVE, 409, FakeZonePlatform.error_body("lease_lost"), 0.5)
	client.leave()
	await _run_until(func() -> bool: return not _finals_of(42).is_empty())
	var again: RawTicketClient = await _join(42)
	if again == null:
		return
	await _run_until(func() -> bool: return _saves().size() >= 3 and _server.get_saver().entry_count() == 1, 4000)
	await _run_ms(300)
	assert_null(again.kick_notice(), "the new body is not kicked")
	assert_false(again.disconnected, "and stays connected")
	assert_eq(_server.get_saver().entry_count(), 1, "the old entry is closed")
	assert_true(_server.get_saver().is_tracked(again.own_spawn.net_id), "the new one continues")
	assert_eq(_releases().size(), 0, "lease_lost does not release")
