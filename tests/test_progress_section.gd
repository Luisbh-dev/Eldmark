extends TestCase
## Tests for the [code]progress[/code] section of [CharacterSaver] in [ZoneServer] with [FakeZonePlatform] and real clients
## over ENet on 127.0.0.1 (docs/progresion.md §9 and §15 P5a): the section is registered first; the kit of
## the first join as critical; the retry with the same body; [code]duplicate[/code] confirms;
## [code]lease_lost[/code] discards the state; a 400 [code]invalid_save[/code] kicks and releases, and afterwards no
## [ProgressService] hook fails with that [code]net_id[/code]; [method PlayerProgress.is_dirty] with only movement
## or losing health; [code]prepare[/code] with a broken record → REJECT UNAVAILABLE and release; leaving during LOADING →
## [code]cancel_prepared[/code] and release; the fake platform's next claim brings the last applied state; and the final save
## built with a save in flight goes out after it without repeating its operations.

const VARDHEIM: int = NetProtocol.Realm.VARDHEIM
const PLAYER_SCENE: PackedScene = preload("res://scenes/characters/player_character.tscn")
const ZONE_ID: String = "test_world"
const FIRST_TICKET_ID: int = 9007199254740993
# Characters have their checkpoint at phase character_id % 3600: with 2042 and 2043, at 34 s, after
# each test. That way only the saves that each test triggers go out.

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
	_world = null
	_viewport = null
	_client_tick = 0
	_sim_hash = -1
	await wait_process_frames()


# --- Helpers ----------------------------------------------------------------------------------

## The test zone with the fake platform already started and the server listening (checkpoints every 60 s: in
## these tests only critical and final saves go out). [param setup] receives the platform before it starts.
func _start(setup: Callable = Callable()) -> bool:
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
	config.save_interval_s = 60
	_port = NetHarness.free_udp_port()
	config.port = _port
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
	_server.get_progress().log_sink = func(_text: String) -> void: pass
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
	var hello := NetMessages.Hello.new()
	hello.sim_hash = _client_sim_hash()
	hello.realm = VARDHEIM
	hello.display_name = "Cualquiera"
	hello.character_id = character_id
	hello.ticket = _ticket(character_id)
	var transport := NetTransport.new()
	transport.name = "ClientTransport%d" % _next_client_index
	_next_client_index += 1
	_viewport.add_child(transport)
	var client := RawTicketClient.new(transport, hello.encode())
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


## Character [param character_id] joins with a ticket, waits for its registration and for its first save (the kit, if any)
## to get a response.
func _join(character_id: int) -> RawTicketClient:
	var client: RawTicketClient = _connect(character_id)
	var joined: bool = await _run_until(func() -> bool: return client.own_spawn != null or client.reject != null)
	if not assert_true(joined and client.own_spawn != null, "character %d enters the world" % character_id):
		return null
	await _run_until(func() -> bool: return _server.get_saver().pending_count() == 0)
	return client


func _progress() -> ProgressService:
	return _server.get_progress()


func _saves() -> Array[Dictionary]:
	return _platform.sent(PlatformEvent.KIND_SAVE)


func _releases() -> Array[Dictionary]:
	return _platform.sent(ZonePlatform.KIND_RELEASE)


func _has_body(net_id: int) -> bool:
	return _server.get_registry().get_entity(net_id) != null


func _op_ids(body: Dictionary) -> Array:
	return ((body["progress"] as Dictionary)["ops"] as Array).map(func(o: Dictionary) -> String: return o["op_id"])


# A GM operation of +[param gold] gold on the progress of [param net_id].
func _gm_gold(net_id: int, gold: int) -> EconomyOp:
	var player: PlayerProgress = _progress().get_player(net_id)
	var op: EconomyOp = player.begin_op(EconomyOp.Kind.GM, 7, "prueba", {"command": "currency_add",
			"source": "console", "at_unix": _platform.now_unix(), "args": [str(player.character_id), "oro",
			str(gold)]})
	player.change_currency(op, Currency.Code.GOLD, gold, EconomyReason.GM_GRANT, 0, 0)
	return op


# --- Tests ------------------------------------------------------------------------------------

## The progress section is CharacterSaver's first, and the first join goes out with the kit as critical, on the
## same tick as the join, with its STARTER_KIT and the character snapshot.
func test_the_section_is_registered_first_and_the_kit_is_critical() -> void:
	if not await _start(func(platform: FakeZonePlatform) -> void:
			platform.add_character(2042, 7, &"player", VARDHEIM, {})):
		return
	# Since plataforma.md P6, start also registers the real pvp one (ScoreKeeper), after progress.
	assert_eq(_server.get_saver().section_names(), [ProgressService.SECTION, ScoreKeeper.SECTION] as Array[StringName],
			"progress, registered first in start")
	var other := FakeSaveSection.new()
	other.attach(_server.get_saver())
	assert_eq(_server.get_saver().section_names(), [&"progress", &"pvp"] as Array[StringName],
			"the fake one replaces pvp and progress stays first")
	var client: RawTicketClient = await _join(2042)
	if client == null:
		return
	var net_id: int = client.own_spawn.net_id
	assert_true(_progress().has_inventory(net_id), "the body has its progress")
	var saves: Array[Dictionary] = _saves()
	if not assert_eq(saves.size(), 1, "one save: the kit's"):
		return
	assert_eq(int(saves[0]["reason"]), CharacterSaver.Reason.CRITICAL, "critical")
	var progress: Dictionary = saves[0]["progress"]
	assert_eq(progress["starter_granted"], true, "with starter_granted")
	var ops: Array = progress["ops"]
	if assert_eq(ops.size(), 1, "one operation"):
		assert_eq(int(ops[0]["kind"]), EconomyOp.Kind.STARTER_KIT, "STARTER_KIT")
		assert_eq((ops[0]["items"] as Array).size(), 4, "with the four items of the archer kit")
	assert_eq((progress["items"] as Array).size(), 4, "and the snapshot with them")
	assert_eq(progress["location"]["zone_id"], ZONE_ID, "the position, in this zone")
	assert_false(progress.has("race_id") or progress.has("appearance") or progress.has("starter_template_id"),
			"without the read-only fields")
	assert_true(saves[0].has("pvp"), "and the pvp section after it")
	assert_eq(_progress().get_player(net_id).unconfirmed_count(), 0, "the 200 confirms: the journal is emptied")
	assert_false(_progress().get_player(net_id).is_dirty(), "and stays clean")
	assert_eq(_progress().get_ids().available(), 1024 - 5, "the kit spends 5 ids from the first block")


## With no response (offline) the save is retried with the same body; a duplicate confirms like an applied.
func test_a_retry_resends_the_same_body_and_duplicate_confirms() -> void:
	if not await _start(func(platform: FakeZonePlatform) -> void:
			platform.add_character(2042, 7, &"player", VARDHEIM, {})
			platform.script_next(PlatformEvent.KIND_SAVE, 0, null)
			platform.script_next(PlatformEvent.KIND_SAVE, 0, null)
			platform.script_next(PlatformEvent.KIND_SAVE, 200, {"applied": false, "duplicate": true,
					"save_version": 1, "instance_status": "live"})):
		return
	var client: RawTicketClient = await _join(2042)
	if client == null:
		return
	var saves: Array[Dictionary] = _saves()
	if assert_eq(saves.size(), 3, "two attempts with no response and the third"):
		assert_eq(saves[1], saves[0], "the same body")
		assert_eq(saves[2], saves[0], "the third one too")
	var player: PlayerProgress = _progress().get_player(client.own_spawn.net_id)
	assert_eq(player.unconfirmed_count(), 0, "duplicate confirms: the kit leaves the journal")
	assert_false(player.is_dirty(), "and stays clean")


## A lease_lost (from the heartbeat or from a save) is a departure without a save: the state is discarded (on_departure).
func test_lease_lost_discards_the_state() -> void:
	if not await _start(func(platform: FakeZonePlatform) -> void:
			platform.add_character(2042, 7, &"player", VARDHEIM, {})
			platform.add_character(2043, 8, &"player", VARDHEIM, {})):
		return
	var first: RawTicketClient = await _join(2042)
	var second: RawTicketClient = await _join(2043)
	if first == null or second == null:
		return
	var net_42: int = first.own_spawn.net_id
	var net_43: int = second.own_spawn.net_id
	_platform.script_next(PlatformEvent.KIND_HEARTBEAT, 200, {"now_unix": _platform.now_unix(), "revoked": [
			{"character_id": "2042", "lease_id": _platform.claimed(2042).lease_id, "reason": "lease_lost",
			"text": "Tu personaje ha entrado en otro servidor"}], "mutes": [], "maintenance": null})
	_platform.send_heartbeat_now()
	await _run_until(func() -> bool: return not _has_body(net_42))
	assert_false(_progress().has_inventory(net_42), "the heartbeat: no progress")
	_platform.script_next(PlatformEvent.KIND_SAVE, 409, FakeZonePlatform.error_body("lease_lost"))
	_gm_gold(net_43, 5)
	_server.get_saver().mark_critical(net_43, &"gm")
	await _run_until(func() -> bool: return not _has_body(net_43))
	assert_false(_progress().has_inventory(net_43), "the save: no progress")
	await _run_ms(200)
	assert_eq(_releases().size(), 0, "lease_lost does not release")


## A 400 invalid_save kicks and releases; afterwards, no ProgressService hook fails with that net_id.
func test_an_invalid_save_kicks_releases_and_leaves_harmless_hooks() -> void:
	if not await _start(func(platform: FakeZonePlatform) -> void:
			platform.add_character(2042, 7, &"player", VARDHEIM, {})):
		return
	var client: RawTicketClient = await _join(2042)
	if client == null:
		return
	var net_id: int = client.own_spawn.net_id
	var lease_id: String = _platform.claimed(2042).lease_id
	var saves_before: int = _saves().size()
	_platform.script_next(PlatformEvent.KIND_SAVE, 400, FakeZonePlatform.error_body("invalid_save", "",
			{"fields": {"check": "S5", "detail": "uid fuera de los bloques"}}))
	_gm_gold(net_id, 5)
	_server.get_saver().mark_critical(net_id, &"gm")
	var kicked: bool = await _run_until(func() -> bool: return client.kick_notice() != null)
	if not assert_true(kicked, "kick"):
		return
	assert_eq(client.kick_notice().text, ZoneServer.SAVE_REJECTED_TEXT, "\"No se ha podido guardar tu personaje…\" (your character could not be saved)")
	await _run_until(func() -> bool: return not _has_body(net_id), 1000)
	await _run_ms(200)
	assert_eq(_saves().size(), saves_before + 1, "the \"Salida\" (departure) sends nothing")
	assert_eq(_releases().map(func(b: Dictionary) -> String: return String(b["lease_id"])), [lease_id],
			"it is released once")
	var progress: ProgressService = _progress()
	assert_false(progress.has_inventory(net_id), "no progress")
	progress.on_departure(net_id)
	progress._acknowledge(net_id, 2)
	assert_false(progress._is_dirty(net_id), "is_dirty without progress: false")
	assert_eq(progress.level_of(net_id), 0, "level_of: 0")
	assert_null(progress.get_player(net_id), "and nothing to bind")


## is_dirty with only movement or losing health (§9.2), and clean right after joining.
func test_is_dirty_with_only_moving_or_losing_health() -> void:
	if not await _start(func(platform: FakeZonePlatform) -> void:
			platform.add_character(2042, 7, &"player", VARDHEIM, {})):
		return
	var client: RawTicketClient = await _join(2042)
	if client == null:
		return
	var net_id: int = client.own_spawn.net_id
	var player: PlayerProgress = _progress().get_player(net_id)
	assert_false(player.is_dirty(), "after the confirmed kit, clean")
	await _run_ms(300)
	assert_false(player.is_dirty(), "standing still, it stays clean")
	var here: Vector3 = _server.get_registry().get_entity(net_id).get_position()
	_server.teleport(net_id, here + Vector3(2.0, 0.0, 0.0))
	assert_true(player.is_dirty(), "moving makes it dirty")
	_server.get_saver().mark_critical(net_id, &"gm")
	await _run_until(func() -> bool: return _saves().size() == 2 and _server.get_saver().pending_count() == 0)
	assert_false(player.is_dirty(), "saved and confirmed, clean")
	var moved: Dictionary = _saves()[1]["progress"]["location"]
	assert_near(float(moved["x"]), here.x + 2.0, 0.01, "with the new position")
	_server.get_combat().get_combatant(net_id).health -= 100
	assert_true(player.is_dirty(), "losing health makes it dirty")


## prepare with a record that cannot be read: REJECT UNAVAILABLE with its text, and release.
func test_a_broken_record_is_rejected_and_released() -> void:
	if not await _start(func(platform: FakeZonePlatform) -> void:
			platform.add_character(2042, 7, &"player", VARDHEIM, {"progress_format": 1, "level": 3})):
		return
	var client: RawTicketClient = _connect(2042)
	var rejected: bool = await _run_until(func() -> bool: return client.reject != null)
	if not assert_true(rejected, "REJECT"):
		return
	assert_eq(client.reject.result, NetProtocol.Result.UNAVAILABLE, "UNAVAILABLE")
	assert_eq(client.reject.text, ProgressService.PREPARE_FAILED_TEXT, "\"No se ha podido cargar el personaje\" (the character could not be loaded)")
	var released: bool = await _run_until(func() -> bool: return not _releases().is_empty(), 2000)
	if assert_true(released, "it is released"):
		assert_eq(_releases()[0]["lease_id"], _platform.claimed(2042).lease_id, "with its lease_id")
	assert_eq(_progress().get_stats()["prepare_failed"], 1, "and it is counted")
	assert_eq(_saves().size(), 0, "without saving")


## Leaving during LOADING: cancel_prepared and release, without saving.
func test_leaving_while_loading_cancels_the_prepared_progress() -> void:
	if not await _start(func(platform: FakeZonePlatform) -> void:
			platform.add_character(2042, 7, &"player", VARDHEIM, {})):
		return
	var client: RawTicketClient = _connect(2042, false)
	var peer_id: Array[int] = [-1]
	var loading: bool = await _run_until(func() -> bool:
		for id: int in _server.get_peer_ids():
			if _server.get_peer(id).state == ServerPeer.State.LOADING:
				peer_id[0] = id
				return client.connected
		return false)
	if not assert_true(loading, "WELCOME and LOADING"):
		return
	assert_not_null(_progress().get_prepared(peer_id[0]), "prepared before the WELCOME")
	client.transport.close()
	var released: bool = await _run_until(func() -> bool: return not _releases().is_empty())
	assert_true(released, "it is released")
	assert_null(_progress().get_prepared(peer_id[0]), "and what was prepared is discarded")
	assert_eq(_progress().get_stats()["cancelled"], 1, "cancel_prepared")
	assert_eq(_saves().size(), 0, "without saving")


## The fake platform's next claim brings the last applied state: the kit (same uids), the position with saved_at_unix
## and the gold; the second join does not give the kit again.
func test_the_next_claim_brings_the_last_applied_progress() -> void:
	if not await _start(func(platform: FakeZonePlatform) -> void:
			platform.add_character(2042, 7, &"player", VARDHEIM, {})):
		return
	var client: RawTicketClient = await _join(2042)
	if client == null:
		return
	var net_id: int = client.own_spawn.net_id
	var uids: Array = _progress().get_player(net_id).record.inventory.all_items().map(
			func(i: ItemInstance) -> int: return i.uid)
	_gm_gold(net_id, 25)
	client.leave()
	await _run_until(func() -> bool: return _server.get_saver().entry_count() == 0)
	var finals: Array[Dictionary] = _saves().filter(func(b: Dictionary) -> bool: return bool(b["release_lease"]))
	assert_eq(finals.size(), 1, "the final save on leaving")
	assert_eq(_progress().get_stats()["players"], 0, "the state is discarded on departure")
	var again: RawTicketClient = await _join(2042)
	if again == null:
		return
	var claimed: Dictionary = _platform.claimed(2042).progress
	assert_false(claimed.has("ops"), "the claim carries no ops")
	assert_eq([claimed["race_id"], claimed["starter_template_id"]], ["race_vardheim", "marksman"],
			"with the read-only fields of the previous one")
	assert_true((claimed["location"] as Dictionary).has("saved_at_unix"), "and location.saved_at_unix")
	var player: PlayerProgress = _progress().get_player(again.own_spawn.net_id)
	assert_eq(player.record.inventory.all_items().map(func(i: ItemInstance) -> int: return i.uid), uids,
			"the same items with the same uids")
	assert_eq(player.record.wallets[Currency.Code.GOLD], 25, "and the gold")
	assert_true(player.record.starter_granted, "with the kit already given")
	assert_eq(_saves().size(), 2, "the second join does not give another kit (nor save)")


## The final save built with a save in flight waits behind it and does not repeat its operations: applied in
## order, no op_id appears twice (S2) and the final save carries the snapshot with everything.
func test_the_final_built_with_a_save_in_flight_applies_after_it() -> void:
	if not await _start(func(platform: FakeZonePlatform) -> void:
			platform.add_character(2042, 7, &"player", VARDHEIM, {})):
		return
	var client: RawTicketClient = await _join(2042)
	if client == null:
		return
	var net_id: int = client.own_spawn.net_id
	var first: EconomyOp = _gm_gold(net_id, 10)
	_platform.script_next(PlatformEvent.KIND_SAVE, 200, FakeZonePlatform.DEFAULT, 0.6)
	_server.get_saver().mark_critical(net_id, &"gm")
	await _run_until(func() -> bool: return _saves().size() == 2)
	var second: EconomyOp = _gm_gold(net_id, 20)
	client.leave()
	await _run_until(func() -> bool: return not _has_body(net_id))
	assert_eq(_saves().size(), 2, "the final save waits behind the one in flight")
	var done: bool = await _run_until(func() -> bool: return _server.get_saver().entry_count() == 0, 3000)
	if not assert_true(done, "both have a response"):
		return
	var saves: Array[Dictionary] = _saves()
	if not assert_eq(saves.size(), 3, "the kit, the critical one and the final one"):
		return
	assert_eq(_op_ids(saves[1]), [str(first.op_id)], "the critical one carries the first")
	assert_eq(_op_ids(saves[2]), [str(second.op_id)], "the final one, only the second")
	assert_true(bool(saves[2]["release_lease"]), "with release_lease")
	assert_eq(int(saves[2]["seq"]), int(saves[1]["seq"]) + 1, "with the next seq")
	var seen: Dictionary = {}
	for body: Dictionary in saves:
		for op_id: String in _op_ids(body):
			assert_false(seen.has(op_id), "op_id %s appears only once" % op_id)
			seen[op_id] = true
	var gold: int = -1
	for wallet: Dictionary in saves[2]["progress"]["wallets"]:
		if int(wallet["currency"]) == Currency.Code.GOLD:
			gold = int(wallet["balance"])
	assert_eq(gold, 30, "the final snapshot with the 30 gold")
	assert_eq(_platform.applied(2042)["seq"], saves[2]["seq"], "the last applied is the final one")
