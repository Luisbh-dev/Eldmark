extends TestCase
## Tests for persistent war in the zone (docs/platform.md §8 and §15 P6, GUE-19): the round trip of
## [FortressPersistence] (ticks and Unix time with the clock fixed), starting up with CONSOLIDATING
## half done (owner and deadline), CAPTURING that comes back with its progress (and, with nobody there,
## back to VULNERABLE), the platform being silent at startup, the empty list (initial state with no
## warning) and a different schema (with a warning), [code]version_conflict[/code] with resend,
## captures and [code]defend_ticks[/code] (only the owner, without [member NetEntity.gm_forced], which
## respawning removes), captures forced by a command, the [code]pvp[/code] section (reconnect and end
## before [method ScoreKeeper.forget]) and the event batch resent without duplicates.
## [br][br]
## A network-less [ZoneServer] over the flat zone with the fortress from [FortressFixture], advanced
## quickly with its [FortressFixture.Stepper], and the fake platform ([FakeZonePlatform]) with the
## clock fixed; characters with a claim are set up by hand like the real join (LOADING, claim,
## [method ProgressService.prepare] and CLIENT_READY). The real startup ([ServerMain] with
## [code]--platform[/code] against [FakeHttpServer]) is in [code]test_war_platform_process.gd[/code].

const VARDHEIM: int = NetProtocol.Realm.VARDHEIM
const SOLMARCH: int = NetProtocol.Realm.SOLMARCH
const FORTRESS: StringName = FortressFixture.FORTRESS_ID
const ZONE_ID: String = "test_world"
## The fake platform's Unix time.
const NOW: int = 1_800_000_000
const KEY_HEX: String = "02b7825be38fdd5396a4a058286884eaf93a9df85b874f78b4010a76103fb858"
const PHASE: Dictionary = {
	&"garrisoned": FortressState.Phase.GARRISONED, &"vulnerable": FortressState.Phase.VULNERABLE,
	&"capturing": FortressState.Phase.CAPTURING, &"consolidating": FortressState.Phase.CONSOLIDATING,
}


## A transport that connects nothing and records what the server sends to each peer.
class RecordingTransport:
	extends NetTransport

	var sent: Dictionary[int, Array] = {}

	func send(peer_id: int, _channel: int, bytes: PackedByteArray) -> Error:
		if not sent.has(peer_id):
			sent[peer_id] = []
		(sent[peer_id] as Array).append(bytes)
		return OK


var _viewport: SubViewport = null
var _world: Node3D = null
var _server: ZoneServer = null
var _platform: FakeZonePlatform = null
var _stepper: FortressFixture.Stepper = null
var _recorder: RecordingTransport = null
var _captured: Array[Array] = []


func after_each() -> void:
	if is_instance_valid(_stepper):
		_stepper.get_parent().remove_child(_stepper)
		_stepper.free()
	if is_instance_valid(_server):
		_server._transport = null
		_server.get_parent().remove_child(_server)
		_server.free()
	if is_instance_valid(_recorder):
		_recorder.free()
	if is_instance_valid(_viewport):
		_viewport.get_parent().remove_child(_viewport)
		_viewport.free()
	_stepper = null
	_server = null
	_recorder = null
	_platform = null
	_viewport = null
	_world = null
	_captured.clear()
	await wait_process_frames()


# --- Setup ------------------------------------------------------------------------------------

## The flat zone with the test fortress (2 s capture, 2 s consolidation) and the network-less server.
## With [param with_platform], the fake platform with the clock at [constant NOW], already started and
## alive; [param setup] receives the platform before startup (its [member FakeZonePlatform.fake_fortresses],
## its scripts...).
func _start(with_platform: bool = true, setup: Callable = Callable()) -> bool:
	_viewport = SubViewport.new()
	_viewport.own_world_3d = true
	_viewport.size = Vector2i(64, 64)
	tree.root.add_child(_viewport)
	_world = ZoneFixture.build_flat_zone(_viewport)
	FortressFixture.add_fortress(_world, FortressFixture.make_definition())
	FortressFixture.add_respawn_points(_world)
	var config := ServerConfig.new()
	config.zone_id = ZONE_ID
	config.max_players = 16
	config.no_dummies = true
	config.no_npcs = true
	var keys: Dictionary[int, PackedByteArray] = {2: KEY_HEX.hex_decode()}
	if with_platform:
		config.platform_url = "http://fake"
		config.save_interval_s = 600
		_platform = FakeZonePlatform.new()
		_platform.name = "Platform"
		_platform.log_sink = func(_text: String) -> void: pass
		_platform.fake_now_unix = NOW
		_viewport.add_child(_platform)
		if setup.is_valid():
			setup.call(_platform)
	_server = ZoneServer.new()
	_server.name = "ZoneServer"
	_server.log_enabled = false
	_viewport.add_child(_server)
	await wait_physics_frames(3)
	var provider: AuthProvider = DevAuthProvider.new()
	if with_platform:
		var finished: Array = await _start_platform(config, keys)
		if not assert_eq(finished, [[true, ""]], "the fake platform starts"):
			return false
		var tickets := TicketAuthProvider.new(_platform, config.world_id, config.zone_id, config.channel, keys)
		tickets.log_sink = func(_text: String) -> void: pass
		provider = tickets
	if not assert_eq(_server.start(config, _world, null, provider, _platform), OK, "the server starts"):
		return false
	_server.get_progress().log_sink = func(_text: String) -> void: pass
	_server.set_physics_process(false)
	_recorder = RecordingTransport.new()
	_server._transport = _recorder
	_stepper = FortressFixture.Stepper.new()
	_stepper.server = _server
	_viewport.add_child(_stepper)
	_server.get_fortresses().fortress_captured.connect(func(fortress_id: StringName, owner_realm: int,
			in_circle: PackedInt32Array, tick: int) -> void:
		_captured.append([fortress_id, owner_realm, in_circle, tick]))
	if with_platform:
		_platform.go_live()
		var live: bool = await _pump_until(func() -> bool: return _platform.is_live())
		if not assert_true(live, "the instance is alive"):
			return false
	return true


## Starts the fake platform with [param config] and waits for [signal ZonePlatform.startup_finished].
func _start_platform(config: ServerConfig, keys: Dictionary[int, PackedByteArray]) -> Array:
	var finished: Array = []
	_platform.startup_finished.connect(func(ok: bool, error: String) -> void: finished.append([ok, error]))
	_platform.start(config, {"token": "token", "ticket_keys": keys})
	var started: int = Time.get_ticks_msec()
	while finished.is_empty() and Time.get_ticks_msec() - started < 5000:
		await wait_process_frames()
	return finished


## Frames without advancing the server (the fake platform's responses arrive during them) until
## [param condition] is met or [param max_ms] ms pass (or, with [param max_ms] 0, a few frames).
func _pump_until(condition: Callable, max_ms: int = 3000) -> bool:
	var started: int = Time.get_ticks_msec()
	var frames: int = 0
	while Time.get_ticks_msec() - started < max_ms or frames < 3:
		if condition.call():
			return true
		await wait_process_frames()
		frames += 1
	return bool(condition.call())


## Advances the server [param ticks] ticks quickly.
func _advance(ticks: int) -> void:
	_stepper.remaining += ticks
	while _stepper.remaining > 0:
		await tree.physics_frame


## Advances 2 ticks at a time (with frames in between for the platform's responses) until
## [param condition] is met or [param max_ticks] pass.
func _advance_until(condition: Callable, max_ticks: int = 600) -> bool:
	var elapsed: int = 0
	while elapsed < max_ticks:
		if condition.call():
			return true
		await _advance(2)
		await wait_process_frames()
		elapsed += 2
	return bool(condition.call())


func _state() -> FortressState:
	return _server.get_fortresses().get_fortress_state(FORTRESS)


func _definition() -> FortressDefinition:
	return _server.get_fortresses().get_definition(FORTRESS)


func _persistence() -> FortressPersistence:
	return _server.get_fortress_persistence()


## The fortress PUTs received by the fake platform.
func _puts() -> Array[Dictionary]:
	return _platform.sent(PlatformEvent.KIND_FORTRESS)


## A record of the test fortress with [param changes] applied over a whole neutral GARRISONED one.
func _record(changes: Dictionary) -> Dictionary:
	var record: Dictionary = {
		"schema": 1, "owner": 0, "phase": "garrisoned", "phase_ends_at_unix": null, "captain_alive": true,
		"captain_respawn_at_unix": null, "gate_health": 900, "capture_realm": 0, "capture_progress": 0,
		"last_reset_at_unix": NOW - 100,
	}
	record.merge(changes, true)
	return record


## A fake idle player of [param realm] at [param position].
func _idle_player(realm: int, position: Vector3) -> int:
	var brain := CombatFixture.ScriptBrain.new(1)
	var net_id: int = _server.add_fake_player(brain, realm)
	_server.teleport(net_id, position)
	return net_id


func _entity(net_id: int) -> NetEntity:
	return _server.get_registry().get_entity(net_id)


## Sets up a peer with the claim [param claimed] like the real join and waits for it to join.
func _enter(peer_id: int, claimed: ClaimedCharacter) -> ServerPeer:
	var peer := ServerPeer.new(peer_id)
	peer.state = ServerPeer.State.LOADING
	peer.realm = claimed.realm
	peer.display_name = claimed.display_name
	peer.loading_since_tick = _server.get_tick()
	_server._peers[peer_id] = peer
	peer.claimed = claimed
	assert_true(_server.get_progress().prepare(peer_id, claimed), "the record is prepared")
	_server._pending_ready.append(peer_id)
	await _advance(1)
	assert_not_null(peer.entity, "peer %d enters the world" % peer_id)
	return peer


## The next claim of [param character_id] on the fake platform, with the round trip through JSON.
func _claim(character_id: int) -> ClaimedCharacter:
	var answer: Array = _platform._claim_answer({"character_id": str(character_id), "ticket_id": "1"})
	var json := JSON.new()
	json.parse(JSON.stringify(answer[1]))
	return ClaimedCharacter.from_claim(json.data)


## [param peer] leaves (like a CLIENT_LEAVE) and waits for the platform to answer its final save.
func _leave(peer: ServerPeer) -> void:
	var saves_before: int = _platform.sent(PlatformEvent.KIND_SAVE).size()
	_server._mark_leaving(peer)
	await _advance(1)
	await _advance_until(func() -> bool:
		return _platform.sent(PlatformEvent.KIND_SAVE).size() > saves_before \
				and _server.get_saver().pending_count() == 0)
	_server._peers.erase(peer.peer_id)


## The six pvp totals of [param body] with int().
static func _pvp(body: Dictionary) -> Dictionary:
	var totals: Dictionary = {}
	var pvp: Dictionary = body.get("pvp", {}) if body.get("pvp") is Dictionary else {}
	for key: String in ClaimedCharacter.PVP_KEYS:
		totals[key] = int(pvp.get(key, -1))
	return totals


# --- FortressPersistence: the conversion -------------------------------------------------------

func test_the_record_round_trips_ticks_and_unix_time_with_a_fixed_clock() -> void:
	var def := FortressFixture.make_definition(30.0, 120.0)
	# CONSOLIDATING for Vardheim, at 50.5 s of 120: the end is written rounded up (69.5 → 70 s).
	var state := FortressState.initial(def, 0)
	state.owner = VARDHEIM
	state.phase = FortressState.Phase.CONSOLIDATING
	state.phase_tick = 1000
	state.captain_alive = false
	state.gate_health = 450
	state.last_reset_tick = 1000
	var tick: int = 1000 + 3030
	var record: Dictionary = FortressPersistence.to_record(state, def, tick, NOW)
	assert_eq(record, {"schema": 1, "owner": VARDHEIM, "phase": "consolidating", "phase_ends_at_unix": NOW + 70,
			"captain_alive": false, "captain_respawn_at_unix": null, "gate_health": 450, "capture_realm": 0,
			"capture_progress": 0, "last_reset_at_unix": NOW - 50}, "the §8 record")
	# Through JSON (numbers come back as float) and 10 s later, in another process that is at tick 500.
	var json := JSON.new()
	json.parse(JSON.stringify(record))
	var loaded: FortressPersistence.Loaded = FortressPersistence.from_record(json.data, def, 500, NOW + 10)
	assert_eq(loaded.error, "", "valid")
	assert_eq(loaded.state.owner, VARDHEIM, "keeps the owner")
	assert_eq(loaded.state.phase, FortressState.Phase.CONSOLIDATING)
	assert_eq(loaded.consolidation_ends_tick, 500 + 60 * 60, "and the deadline: 60 s remain")
	assert_eq(loaded.state.gate_health, 450, "the gate's health")
	assert_eq(loaded.state.gate_last_damage_tick, 500, "the repair counts from startup")
	assert_eq(loaded.state.last_reset_tick, 500 - 60 * 60, "the last reset, 60 s earlier")
	assert_true(loaded.state.phase_tick >= 0, "the phase start fits in OBJECT_STATE")

	# VULNERABLE: the captain returns at 299 s and one tick (→ 300 s).
	state = FortressState.initial(def, 0)
	state.owner = SOLMARCH
	state.on_captain_died(2000, VARDHEIM)
	state.captain_respawn_tick = 2000 + 299 * 60 + 1
	record = FortressPersistence.to_record(state, def, 2000, NOW)
	assert_eq(record["phase"], "vulnerable")
	assert_eq(record["captain_respawn_at_unix"], NOW + 300)
	assert_eq(record["phase_ends_at_unix"], NOW + 300, "the phase ends when the captain returns")
	loaded = FortressPersistence.from_record(record, def, 0, NOW + 100)
	assert_eq(loaded.state.phase, FortressState.Phase.VULNERABLE)
	assert_false(loaded.state.captain_alive)
	assert_eq(loaded.state.captain_respawn_tick, 200 * 60, "200 s remain")
	# A deadline that has already passed comes back on the load tick, never earlier.
	loaded = FortressPersistence.from_record(record, def, 70, NOW + 400)
	assert_eq(loaded.state.captain_respawn_tick, 70)

	# CAPTURING: the progress of the tick at which it is written.
	state = FortressState.initial(def, 0)
	state.on_captain_died(100, VARDHEIM)
	state.phase = FortressState.Phase.CAPTURING
	state.capture_realm = VARDHEIM
	state.capture_start_tick = 100
	state.capture_rate = 12
	state.capture_progress_at_start = 0
	record = FortressPersistence.to_record(state, def, 700, NOW)
	assert_eq([record["phase"], record["capture_realm"], record["capture_progress"]], ["capturing", VARDHEIM, 7200])
	loaded = FortressPersistence.from_record(record, def, 40, NOW + 3)
	assert_eq(loaded.state.phase, FortressState.Phase.CAPTURING, "with its captor and its progress")
	assert_eq(loaded.state.capture_realm, VARDHEIM)
	assert_eq(loaded.state.progress_at(40), 7200)
	assert_eq([loaded.state.capture_rate, loaded.state.empty_since_tick], [0, 40], "the circle empty, decaying")

	# Neutral GARRISONED: no deadlines.
	record = FortressPersistence.to_record(FortressState.initial(def, 0), def, 0, NOW)
	assert_eq([record["phase_ends_at_unix"], record["captain_respawn_at_unix"], record["captain_alive"]],
			[null, null, true])


func test_a_record_that_does_not_fit_gives_the_initial_state_and_why() -> void:
	var def := FortressFixture.make_definition()
	var good: Dictionary = _record({"owner": SOLMARCH})
	assert_eq(FortressPersistence.from_record(good, def, 0, NOW).error, "", "the good one is valid")
	var cases: Array[Array] = [
		[{"schema": 2}, "esquema 2"],
		[{"owner": 4}, "owner"],
		[{"phase": "asediado"}, "phase"],
		[{"gate_health": -1}, "gate_health"],
		[{"captain_alive": 1}, "captain_alive"],
		[{"last_reset_at_unix": "ayer"}, "last_reset_at_unix"],
		[{"phase": "consolidating", "owner": 0, "phase_ends_at_unix": NOW}, "consolidating sin dueño"],
		[{"phase": "capturing", "owner": SOLMARCH, "capture_realm": SOLMARCH}, "capturing sin captor"],
	]
	for entry: Array in cases:
		var record: Dictionary = good.duplicate()
		record.merge(entry[0], true)
		var loaded: FortressPersistence.Loaded = FortressPersistence.from_record(record, def, 0, NOW)
		assert_true(loaded.error.contains(entry[1]), "%s → %s (%s)" % [entry[0], entry[1], loaded.error])
		assert_eq([loaded.state.owner, loaded.state.phase], [0, FortressState.Phase.GARRISONED],
				"and the initial state")
	assert_eq(FortressPersistence.from_record("{}", def, 0, NOW).error, "no es un objeto")
	var no_schema: Dictionary = good.duplicate()
	no_schema.erase("schema")
	assert_eq(FortressPersistence.from_record(no_schema, def, 0, NOW).error, "esquema desconocido")


# --- Startup with the platform -----------------------------------------------------------------

func test_starting_with_consolidating_half_way_keeps_the_owner_and_the_deadline() -> void:
	var saved: Dictionary = _record({"owner": SOLMARCH, "phase": "consolidating", "phase_ends_at_unix": NOW + 1,
			"captain_alive": false, "gate_health": 450})
	var started: bool = await _start(true, func(platform: FakeZonePlatform) -> void:
		platform.fake_fortresses = [{"fortress_id": String(FORTRESS), "record": saved, "version": 4}])
	if not started:
		return
	var load_tick: int = 0
	assert_eq([_state().owner, _state().phase, _state().gate_health], [SOLMARCH,
			FortressState.Phase.CONSOLIDATING, 450], "keeps owner, phase and gate")
	assert_eq(_server.get_fortresses().get_consolidation_end_tick(FORTRESS), load_tick + 60, "and the deadline: 1 s")
	assert_eq(_server.get_fortresses().get_gate(FORTRESS).collision_layer, FortGate.layers_for(SOLMARCH, false),
			"the gate belongs to Solmarch")
	assert_false(_server.get_fortresses().get_entity(FORTRESS).encode_spawn(_server.get_tick(), false).is_empty(),
			"the fortress spawn is encoded (no negative ticks)")
	assert_eq(_persistence().get_stats()["loaded"], 1)
	await _advance(58 - _server.get_tick())
	await _pump_until(func() -> bool: return false, 50)
	assert_eq(_state().phase, FortressState.Phase.CONSOLIDATING, "2 ticks from the end, consolidating")
	assert_eq(_puts().size(), 0, "loading writes nothing")
	# The fake clock does not run on its own: at tick 60, 1 s has passed.
	_platform.fake_now_unix = NOW + 1
	await _advance(60 - _server.get_tick())
	assert_eq(_state().phase, FortressState.Phase.GARRISONED, "on its tick, the garrison")
	assert_eq(_state().owner, SOLMARCH)
	var written: bool = await _pump_until(func() -> bool: return _puts().size() == 1)
	if assert_true(written, "the phase change is written right away"):
		var put: Dictionary = _puts()[0]
		assert_eq(int(put["expected_version"]), 4, "with the version from the GET")
		var record: Dictionary = put["record"]
		assert_eq([int(record["owner"]), record["phase"], int(record["gate_health"])], [SOLMARCH, "garrisoned",
				450])
		assert_eq(int(record["last_reset_at_unix"]), NOW - 100, "the reset cycle does not start again")


func test_capturing_comes_back_with_its_progress_and_falls_to_vulnerable_if_nobody_returns() -> void:
	# 2 s capture: 120 ticks × 12 = 1440 progress; it comes back with 600.
	var saved: Dictionary = _record({"phase": "capturing", "captain_alive": false, "capture_realm": VARDHEIM,
			"capture_progress": 600})
	var started: bool = await _start(true, func(platform: FakeZonePlatform) -> void:
		platform.fake_fortresses = [{"fortress_id": String(FORTRESS), "record": saved, "version": 2}])
	if not started:
		return
	assert_eq([_state().phase, _state().capture_realm, _state().progress_at(_server.get_tick())],
			[FortressState.Phase.CAPTURING, VARDHEIM, 600], "with its captor and its progress")
	await _advance(30)
	assert_eq(_state().progress_at(_server.get_tick()), 600, "the empty circle waits out its delay (1 s)")
	# Then it decays at −4 per tick: 600 / 4 = 150 ticks.
	var fell: bool = await _advance_until(func() -> bool:
		return _state().phase == FortressState.Phase.VULNERABLE, 300)
	if assert_true(fell, "with nobody there, it goes back to VULNERABLE"):
		assert_true(_server.get_tick() >= 60 + 150 and _server.get_tick() <= 60 + 150 + 6,
				"on decaying to 0 (tick %d)" % _server.get_tick())
		assert_false(_state().captain_alive, "the captain is still down")
		assert_eq(_state().capture_realm, 0)
		assert_eq(_state().captain_respawn_tick, _state().phase_tick + _definition().captain_respawn_ticks(),
				"with a new deadline for the captain")


func test_the_captors_that_come_back_continue_from_the_saved_progress() -> void:
	var saved: Dictionary = _record({"phase": "capturing", "captain_alive": false, "capture_realm": VARDHEIM,
			"capture_progress": 1200})
	var started: bool = await _start(true, func(platform: FakeZonePlatform) -> void:
		platform.fake_fortresses = [{"fortress_id": String(FORTRESS), "record": saved, "version": 2}])
	if not started:
		return
	_idle_player(VARDHEIM, FortressFixture.circle_center())
	# 240 remain: with one inside, 12 per tick, 20 ticks (plus the count every 6).
	var captured: bool = await _advance_until(func() -> bool: return _state().owner == VARDHEIM, 60)
	assert_true(captured and _server.get_tick() <= 30, "Vardheim finishes what it started (tick %d)" % _server.get_tick())


func test_a_platform_that_never_answers_the_fortresses_stops_the_startup_without_writing() -> void:
	_viewport = SubViewport.new()
	tree.root.add_child(_viewport)
	_platform = FakeZonePlatform.new()
	_platform.name = "Platform"
	_platform.log_sink = func(_text: String) -> void: pass
	_platform.startup_limit_s = 1.0
	for _i: int in 40:
		_platform.script_next(&"fortresses", 0, null)
	_viewport.add_child(_platform)
	var config := ServerConfig.new()
	config.zone_id = ZONE_ID
	config.platform_url = "http://fake"
	var keys: Dictionary[int, PackedByteArray] = {2: KEY_HEX.hex_decode()}
	var finished: Array = await _start_platform(config, keys)
	assert_eq(finished, [[false, "No se han podido leer las fortalezas de la plataforma: sin respuesta de la plataforma"]],
			"no response is not \"no record\": startup fails")
	assert_true(_platform.sent(&"fortresses").size() >= 3, "after retrying (%d)" % _platform.sent(&"fortresses").size())
	assert_true(_platform.fortress_records().is_empty(), "no fortress loaded")
	assert_eq(_platform.sent(PlatformEvent.KIND_ID_BLOCK).size(), 0, "nor the first block")
	assert_eq(_platform.sent(PlatformEvent.KIND_FORTRESS).size(), 0, "and nothing written: the saved owner is not overwritten")


func test_an_empty_list_is_the_initial_state_without_a_warning_and_is_written_once_live() -> void:
	if not await _start(true):
		return
	assert_eq([_state().owner, _state().phase, _state().gate_health], [0, FortressState.Phase.GARRISONED, 900])
	var stats: Dictionary = _persistence().get_stats()
	assert_eq([stats["initial"], stats["discarded"], stats["loaded"]], [1, 0, 0], "initial state, no warning")
	await _advance(1)
	var written: bool = await _pump_until(func() -> bool: return _puts().size() == 1)
	if assert_true(written, "the first startup writes the initial state as soon as the instance is alive"):
		assert_eq(int(_puts()[0]["expected_version"]), 0, "creates the row")
		assert_eq(_puts()[0]["record"]["phase"], "garrisoned")
	await _advance(120)
	await _pump_until(func() -> bool: return false, 50)
	assert_eq(_puts().size(), 1, "with no changes it writes no more")


func test_a_record_with_another_schema_is_the_initial_state_with_a_warning() -> void:
	var started: bool = await _start(true, func(platform: FakeZonePlatform) -> void:
		platform.fake_fortresses = [{"fortress_id": String(FORTRESS), "record": _record({"schema": 2,
				"owner": SOLMARCH}), "version": 9}])
	if not started:
		return
	assert_eq(_state().owner, 0, "initial state")
	var stats: Dictionary = _persistence().get_stats()
	assert_eq([stats["discarded"], stats["initial"]], [1, 0], "with a warning")
	await _advance(30)
	await _pump_until(func() -> bool: return false, 50)
	assert_eq(_puts().size(), 0, "it does not overwrite it until something changes")
	_server.console_command("fort_owner vardheim")
	await _advance(1)
	var written: bool = await _pump_until(func() -> bool: return _puts().size() == 1)
	if assert_true(written, "the change is written"):
		assert_eq(int(_puts()[0]["expected_version"]), 9, "over the version that was there")


func test_a_version_conflict_resends_the_record_with_the_new_version() -> void:
	var started: bool = await _start(true, func(platform: FakeZonePlatform) -> void:
		platform.script_next(PlatformEvent.KIND_FORTRESS, 409, FakeZonePlatform.error_body("version_conflict",
				"El registro de la fortaleza ha cambiado", {"version": 7})))
	if not started:
		return
	await _advance(1)
	var resent: bool = await _advance_until(func() -> bool:
		return _puts().size() == 2 and int(_persistence().get_stats()["put_ok"]) == 1, 60)
	if not assert_true(resent, "after the 409 it is resent"):
		return
	assert_eq([int(_puts()[0]["expected_version"]), int(_puts()[1]["expected_version"])], [0, 7],
			"with the version from the error")
	assert_eq(_puts()[1]["record"], _puts()[0]["record"], "the same record: the live instance wins")
	assert_eq(_persistence().get_stats()["put_conflicts"], 1)
	# The next change goes with the version the 200 gave (the fake's, 1).
	_server.console_command("fort_owner solmarch")
	await _advance(1)
	await _pump_until(func() -> bool: return _puts().size() == 3)
	assert_eq(int(_puts()[2]["expected_version"]), 1, "and the next one, with the 200's")


# --- Captures, time defending and forced changes ------------------------------------------------

func test_captures_and_defend_ticks_count_only_the_owner_and_skip_gm_forced() -> void:
	if not await _start(false):
		return
	var circle: Vector3 = FortressFixture.circle_center()
	var first: int = _idle_player(VARDHEIM, circle)
	var second: int = _idle_player(VARDHEIM, circle + Vector3(1.0, 0.0, 0.0))
	var forced: int = _idle_player(VARDHEIM, circle + Vector3(0.0, 0.0, 1.0))
	var outside: int = _idle_player(VARDHEIM, circle + Vector3(20.0, 0.0, 0.0))
	var enemy: int = _idle_player(SOLMARCH, circle + Vector3(-20.0, 0.0, 0.0))
	_entity(forced).gm_forced = true
	var scores: ScoreKeeper = _server.get_scores()
	# The captain falls in combat (a real change).
	assert_true(_server.get_fortresses().on_captain_died(FORTRESS, _server.get_tick(), VARDHEIM))
	var captured: bool = await _advance_until(func() -> bool: return _state().owner == VARDHEIM, 200)
	if not assert_true(captured, "Vardheim captures"):
		return
	assert_eq([scores.get_entry(first).captures, scores.get_entry(second).captures], [1, 1],
			"the captor's players in the circle add up to one capture")
	assert_eq(scores.get_entry(forced).captures, 0, "the one flagged by a GM command, no")
	assert_true(scores.get_entry(outside) == null or scores.get_entry(outside).captures == 0, "the one outside, no")
	if assert_eq(_captured.size(), 1, "the list goes out once"):
		assert_eq(_captured[0][2], PackedInt32Array([first, second]), "the same one ScoreKeeper adds up")
		assert_eq(_captured[0][1], VARDHEIM)
	assert_eq(scores.get_entry(first).defend_ticks, 0, "capturing is not defending")
	# Consolidation (2 s) and garrison; Vardheim's captain falls: the circle opens with the owner inside.
	await _advance_until(func() -> bool: return _state().phase == FortressState.Phase.GARRISONED, 200)
	await _advance(12)
	assert_eq(scores.get_entry(first).defend_ticks, 0, "with the circle closed there is no defending")
	_server.teleport(enemy, circle + Vector3(-1.0, 0.0, 0.0))
	assert_true(_server.get_fortresses().on_captain_died(FORTRESS, _server.get_tick(), SOLMARCH))
	await _advance(120)
	assert_true(scores.get_entry(first).defend_ticks >= 108 and scores.get_entry(first).defend_ticks <= 126,
			"the owner in the active circle defends (%d ticks)" % scores.get_entry(first).defend_ticks)
	assert_eq(scores.get_entry(second).defend_ticks, scores.get_entry(first).defend_ticks)
	assert_eq(scores.get_entry(forced).defend_ticks, 0, "the flagged one, no")
	assert_eq(scores.get_entry(enemy).defend_ticks, 0, "the attacker, no")
	assert_true(scores.get_entry(enemy).circle_ticks > 0, "though it does count in the circle (merits)")
	# Respawning removes the flag.
	_server.console_command("kill %d" % forced)
	await _advance(2)
	var combatant: Combatant = _server.get_combat().get_combatant(forced)
	await _advance(maxi(combatant.respawn_tick - _server.get_tick() - 6, 0))
	assert_true(_entity(forced).gm_forced, "dead, it is still flagged")
	assert_eq(_server.get_combat().request_respawn(forced, 0, _server.get_tick() + 1),
			CombatDirector.RespawnRequestResult.ACCEPTED)
	await _advance(10)
	assert_false(_entity(forced).gm_forced, "after respawning, no longer")


func test_a_capture_forced_by_a_fort_command_does_not_count() -> void:
	if not await _start(false):
		return
	var circle: Vector3 = FortressFixture.circle_center()
	var vardheim: int = _idle_player(VARDHEIM, circle)
	var scores: ScoreKeeper = _server.get_scores()
	var fortresses: FortressController = _server.get_fortresses()
	assert_false(fortresses.is_forced(FORTRESS), "at startup nothing is forced")
	# With fort_capture_speed ≠ 1 the capture is forced, even if the captain falls in combat.
	_server.console_command("fort_capture_speed 20")
	assert_true(fortresses.on_captain_died(FORTRESS, _server.get_tick(), VARDHEIM))
	assert_true(fortresses.is_forced(FORTRESS))
	await _advance_until(func() -> bool: return _state().owner == VARDHEIM, 100)
	assert_eq(_state().owner, VARDHEIM, "captured at x20")
	assert_true(scores.get_entry(vardheim) == null or scores.get_entry(vardheim).captures == 0, "no capture")
	assert_eq(_captured.size(), 0, "nor list")
	# Back to x1; Vardheim's garrison arrives on its own: the cycle stops being forced.
	_server.console_command("fort_capture_speed 1")
	assert_true(fortresses.is_forced(FORTRESS), "x1 does not erase what was already forced")
	await _advance_until(func() -> bool: return _state().phase == FortressState.Phase.GARRISONED, 200)
	assert_false(fortresses.is_forced(FORTRESS), "the garrison that arrives on its own starts a real cycle")
	# Solmarch captures it for real and scores.
	_server.teleport(vardheim, circle + Vector3(30.0, 0.0, 0.0))
	var solmarch: int = _idle_player(SOLMARCH, circle)
	assert_true(fortresses.on_captain_died(FORTRESS, _server.get_tick(), SOLMARCH))
	await _advance_until(func() -> bool: return _state().owner == SOLMARCH, 200)
	assert_eq(scores.get_entry(solmarch).captures, 1, "a real capture counts")
	# fort_owner: the change is forced and counts for no one.
	_server.console_command("fort_owner vardheim")
	assert_true(fortresses.is_forced(FORTRESS), "fort_owner is forced")
	await _advance(12)
	assert_eq(scores.get_entry(solmarch).captures, 1)
	# fort_kill_captain opens a forced circle: the capture that follows neither counts nor is reported.
	_server.console_command("fort_kill_captain")
	assert_true(fortresses.is_forced(FORTRESS), "fort_kill_captain is forced")
	await _advance_until(func() -> bool: return _state().owner == SOLMARCH, 200)
	assert_eq(_state().owner, SOLMARCH, "Solmarch retakes the fort")
	assert_eq(scores.get_entry(solmarch).captures, 1, "without counting: a command opened it")
	assert_eq(_captured.size(), 1, "only the real capture was reported")
	# fort_reset is also forced; the captain falling in combat afterwards removes that.
	_server.console_command("fort_reset")
	assert_true(fortresses.is_forced(FORTRESS))
	await _advance(2)
	assert_true(fortresses.on_captain_died(FORTRESS, _server.get_tick(), SOLMARCH))
	assert_false(fortresses.is_forced(FORTRESS), "the captain's death in combat is real")


func test_the_captain_killed_by_a_command_is_already_forced_when_its_death_goes_out() -> void:
	if not await _start(false):
		return
	var captain: int = _server.spawn_captain_double(FORTRESS)
	if not assert_true(captain > 0, "the captain's double appears"):
		return
	var seen: Array[bool] = []
	_server.get_combat().event_emitted.connect(func(event: NetMessages.EntityEvent, _involved: PackedInt32Array) -> void:
		if event.event == NetMessages.EntityEvent.Kind.DEATH and event.net_id == captain:
			seen.append(_server.get_fortresses().is_forced(FORTRESS)))
	assert_false(_server.get_fortresses().is_forced(FORTRESS))
	assert_eq(_server.console_command("fort_kill_captain"), "El capitán de %s ha muerto" % FORTRESS)
	await _advance(2)
	assert_eq(seen, [true] as Array[bool], "its death is now reported as forced (on_npc_killed does not pay for it, progression.md P5c)")
	assert_eq(_state().phase, FortressState.Phase.VULNERABLE)


# --- pvp section ---------------------------------------------------------------------------------

func test_the_pvp_section_survives_a_reconnection_and_the_final_is_built_before_forget() -> void:
	if not await _start(true):
		return
	var ids: bool = await _advance_until(func() -> bool: return _server.get_progress().get_ids().available() > 0)
	if not assert_true(ids, "the first block of ids arrives"):
		return
	_platform.add_character(41, 410, &"player", VARDHEIM, {}, {"kills": 3, "deaths": 2, "assists": 1,
			"captures": 1, "gate_damage": 450, "defend_s": 120}, "Aneira")
	var peer: ServerPeer = await _enter(1, _claim(41))
	if peer == null or peer.entity == null:
		return
	var net_id: int = peer.entity.net_id
	var scores: ScoreKeeper = _server.get_scores()
	assert_eq(scores.pvp_totals(net_id), {"kills": 3, "deaths": 2, "assists": 1, "captures": 1, "gate_damage": 450,
			"defend_s": 120}, "the base is the claim's totals")
	assert_false(scores.is_section_dirty(net_id), "entering does not dirty the section")
	# The kit critic already carries the pvp section, after progress.
	var kit_saved: bool = await _advance_until(func() -> bool: return not _platform.applied(41).is_empty())
	if assert_true(kit_saved, "the kit critic is applied"):
		var kit: Dictionary = _platform.applied(41)
		assert_true(kit.has("progress") and kit.has("pvp"), "with both sections")
		assert_eq(_pvp(kit), scores.pvp_totals(net_id))
	# The session: two kills, one capture, 125 ticks defending (2 s) and damage to the gate.
	scores.add_kill(net_id)
	scores.add_kill(net_id)
	scores.add_capture(net_id)
	scores.add_defend_ticks(net_id, 125)
	scores.add_gate_damage(net_id, 50)
	assert_true(scores.is_section_dirty(net_id), "the session dirties the section")
	var expected: Dictionary = {"kills": 5, "deaths": 2, "assists": 1, "captures": 2, "gate_damage": 500,
			"defend_s": 122}
	assert_eq(scores.pvp_totals(net_id), expected, "loaded plus the session (defend_s = 120 + 125 / 60)")
	await _leave(peer)
	var final: Dictionary = _platform.applied(41)
	assert_eq(int(final.get("reason", 0)), CharacterSaver.Reason.LOGOUT, "the end of the exit")
	assert_eq(_pvp(final), expected, "built before ScoreKeeper.forget: it carries the session")
	assert_null(scores.get_entry(net_id), "and then it is forgotten")
	# Reconnecting brings back the latest applied and continues from there.
	var again: ClaimedCharacter = _claim(41)
	assert_eq(again.pvp, expected, "the platform returns the totals")
	var back: ServerPeer = await _enter(2, again)
	if back == null or back.entity == null:
		return
	assert_eq(scores.pvp_totals(back.entity.net_id), expected, "and the zone takes them as the base")
	scores.add_kill(back.entity.net_id)
	assert_eq(int(scores.pvp_totals(back.entity.net_id)["kills"]), 6)


func test_the_pvp_section_is_clean_after_its_body_is_acknowledged() -> void:
	var scores := ScoreKeeper.new()
	scores.load_totals(5, {"kills": 1.0, "deaths": 0, "assists": 0, "captures": 0, "gate_damage": 0, "defend_s": 0})
	assert_false(scores.is_section_dirty(5))
	scores.add_kill(5)
	assert_true(scores.is_section_dirty(5))
	var body: Dictionary = scores.build_section(5, 1)
	assert_eq(int(body["kills"]), 2)
	scores.add_death(5)
	scores.acknowledge_section(5, 1)
	assert_true(scores.is_section_dirty(5), "what happened after body 1 is still dirty")
	scores.build_section(5, 2)
	scores.acknowledge_section(5, 2)
	assert_false(scores.is_section_dirty(5), "once 2 is confirmed, clean")
	scores.add_defend_ticks(5, 59)
	assert_false(scores.is_section_dirty(5), "less than a second defending does not change defend_s")
	scores.add_defend_ticks(5, 1)
	assert_true(scores.is_section_dirty(5))
	# A total that does not fit in the column is clamped: with greatest on the platform nothing goes down.
	scores.load_totals(6, {"kills": 2147483647})
	scores.add_kill(6)
	assert_eq(int(scores.pvp_totals(6)["kills"]), 2147483647)


# --- History -----------------------------------------------------------------------------------

func test_a_resent_war_event_batch_does_not_duplicate_anything() -> void:
	var started: bool = await _start(true, func(platform: FakeZonePlatform) -> void:
		platform.script_next(&"war", 503, FakeZonePlatform.error_body("db_unavailable")))
	if not started:
		return
	_idle_player(VARDHEIM, FortressFixture.circle_center())
	assert_true(_server.get_fortresses().on_captain_died(FORTRESS, _server.get_tick(), VARDHEIM))
	await _advance_until(func() -> bool: return _state().owner == VARDHEIM, 200)
	_server.console_command("fort_reset")
	await _advance(2)
	_platform.begin_flush()
	var delivered: bool = await _pump_until(func() -> bool:
		var keys: Dictionary = {}
		for body: Dictionary in _platform.sent(&"war"):
			for entry: Dictionary in body.get("events", []):
				keys[entry["key"]] = true
		return keys.size() >= 3 and _platform.is_flushed())
	if not assert_true(delivered, "the batches arrive"):
		return
	var batches: Array[Dictionary] = _platform.sent(&"war")
	assert_true(batches.size() >= 2, "the first is resent after the 503")
	assert_eq(batches[1], batches[0], "with the same bytes: the same keys, which the platform does not duplicate")
	var seen: Dictionary = {}
	var events: Array = []
	for index: int in batches.size():
		if index == 1:
			continue
		for entry: Dictionary in batches[index].get("events", []):
			assert_false(seen.has(entry["key"]), "the key %s is not repeated between different batches" % entry["key"])
			seen[entry["key"]] = true
			events.append([int(entry["event"]), int(entry["realm"]), entry["fortress_id"], int(entry["at_unix"])])
	assert_eq(events, [[WarEvents.CAPTURE_STARTED, VARDHEIM, String(FORTRESS), NOW],
			[WarEvents.FORT_CAPTURED, VARDHEIM, String(FORTRESS), NOW],
			[WarEvents.FORT_RESET, 0, String(FORTRESS), NOW]],
			"only alerts 3, 6 and 7 (neither the fallen captain nor the attack), with their realm and time")
	for key: String in seen:
		assert_true(key.begins_with(_platform.instance_id() + ":"), "the key belongs to the instance (%s)" % key)
