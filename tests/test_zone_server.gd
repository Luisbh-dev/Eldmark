extends TestCase
## Tests for [ZoneServer] without a network: a zone's server with fake players
## ([method ZoneServer.add_fake_player]) in a [SubViewport] with its own physics world.
## [br][br]
## The test zone is a flat floor with three spawn points (two for Vardheim and one for Solmarch). The
## tests check that the tick advances, that players are in the registry by [code]net_id[/code], that
## the history is recorded, that snapshots fit in 1200 B, teleporting, respawning after falling out of
## the world, the player cap, the [code]--state-log[/code] CSV, the report and the shutdown. The
## protocol with real clients is in [code]test_zone_server_net.gd[/code].

const VARDHEIM: int = NetProtocol.Realm.VARDHEIM
const SOLMARCH: int = NetProtocol.Realm.SOLMARCH
## Output files, in build/ (the temporary folder).
const REPORT_FILE: String = "res://build/test_zone_server_report.json"
const STATE_LOG_FILE: String = "res://build/test_zone_server_states.csv"
## Spawn points of the test zone ([ZoneFixture]).
const VARDHEIM_SPAWNS: Array[Vector3] = ZoneFixture.VARDHEIM_SPAWNS
const SOLMARCH_SPAWN: Vector3 = ZoneFixture.SOLMARCH_SPAWN

var _viewport: SubViewport
var _server: ZoneServer
var _world: Node3D


## A brain that only jumps, once, on tick 5.
class JumpOnceBrain:
	extends BotBrain

	func next_input(tick: int, _position: Vector3, yaw: float) -> PlayerInput:
		var input := PlayerInput.new()
		input.tick = tick
		input.look_yaw = yaw
		if tick == 5:
			input.buttons = PlayerInput.JUMP
		return input


func after_each() -> void:
	if is_instance_valid(_server):
		_server.free()
	if is_instance_valid(_viewport):
		_viewport.get_parent().remove_child(_viewport)
		_viewport.free()
	_server = null
	_world = null
	_viewport = null
	await wait_process_frames()


# --- Helpers ----------------------------------------------------------------------------------

## Test world (floor and spawn points) and a running server, with no transport.
func _start_server(config: ServerConfig = null) -> ZoneServer:
	_viewport = SubViewport.new()
	_viewport.own_world_3d = true
	_viewport.size = Vector2i(64, 64)
	tree.root.add_child(_viewport)
	_world = ZoneFixture.build_flat_zone(_viewport)

	_server = ZoneServer.new()
	_server.name = "ZoneServer"
	_server.log_enabled = false
	_viewport.add_child(_server)
	# Collision bodies enter the physics space in the first steps.
	await wait_physics_frames(3)
	var used: ServerConfig = config if config != null else _make_config()
	var error: Error = _server.start(used, _world, null, DevAuthProvider.new())
	assert_eq(error, OK, "the server starts")
	return _server


func _make_config() -> ServerConfig:
	var config := ServerConfig.new()
	config.zone_id = "test_world"
	return config


func _character_of(net_id: int) -> PlayerCharacter:
	return _server.get_registry().get_entity(net_id).get_character()


# --- Tests ------------------------------------------------------------------------------------

func test_fake_players_run_for_300_ticks() -> void:
	await _start_server()
	var ticks_seen: Array[int] = []
	_server.tick_finished.connect(func(tick: int) -> void: ticks_seen.append(tick))
	var circler: int = _server.add_fake_player(BotBrain.new(1, BotBrain.Pattern.CIRCLE,
			VARDHEIM_SPAWNS[0], 20.0), VARDHEIM)
	var walker: int = _server.add_fake_player(BotBrain.new(2, BotBrain.Pattern.WANDER,
			VARDHEIM_SPAWNS[0], 20.0), VARDHEIM)
	var jumper: int = _server.add_fake_player(BotBrain.new(3, BotBrain.Pattern.JUMPY,
			SOLMARCH_SPAWN, 20.0), SOLMARCH)
	assert_eq([circler, walker, jumper], [1, 2, 3], "net_id 1, 2 and 3 in join order")
	assert_eq(_server.get_player_count(), 3, "three players")
	assert_eq(_server.get_registry().size(), 3, "three entities in the registry")
	var start_tick: int = _server.get_tick()
	await wait_physics_frames(300)

	var elapsed: int = _server.get_tick() - start_tick
	assert_true(elapsed >= 299 and elapsed <= 301, "the tick advances 1 per physics step (%d)" % elapsed)
	assert_eq(ticks_seen.size(), elapsed, "tick_finished once per tick")
	for i: int in ticks_seen.size():
		if ticks_seen[i] != start_tick + 1 + i:
			fail("the ticks are consecutive (index %d: %d)" % [i, ticks_seen[i]])
			break

	var sorted: Array[NetEntity] = _server.get_registry().get_sorted()
	assert_eq(sorted.size(), 3, "three entities")
	var last_id: int = 0
	for entity: NetEntity in sorted:
		assert_true(entity.net_id > last_id, "the registry goes by ascending net_id")
		last_id = entity.net_id
		assert_eq(entity.kind, NetProtocol.EntityKind.PLAYER)
		var character: PlayerCharacter = entity.get_character()
		assert_not_null(character, "player %d has a character" % entity.net_id)
		assert_null(character.get_node_or_null(^"Visual"), "the server does not carry the Visual node")
		assert_true(character.position.y > -1.0 and character.position.y < 5.0,
				"%s is still on the ground" % entity.display_name)
		assert_true(absf(character.position.x) < 200.0 and absf(character.position.z) < 200.0,
				"%s does not leave the ground" % entity.display_name)
		assert_eq(character.last_input_tick, _server.get_tick(),
				"%s applied the last tick's input" % entity.display_name)

	var moved: float = _character_of(circler).global_position.distance_to(VARDHEIM_SPAWNS[0])
	assert_true(moved > 3.0, "the one going in circles has moved (%.1f m)" % moved)
	assert_eq(_server.get_metrics().get_counter(ServerMetrics.COUNTER_PLAYERS), 3,
			"the metrics' player counter")


func test_the_social_step_has_its_own_metrics_section() -> void:
	# The social step (invitation expiry and PARTY_STATUS at 2 Hz) runs after joins and before the
	# history, and is measured in its own section (docs/social.md 12.2; ZoneServer header).
	assert_eq(ZoneServer.SECTION_SOCIAL, &"social", "the section is called \"social\"")
	var social_index: int = ZoneServer.LOGGED_SECTIONS.find(&"social")
	assert_true(social_index >= 0, "the metrics line includes it")
	assert_true(social_index > ZoneServer.LOGGED_SECTIONS.find(&"npc")
			and social_index < ZoneServer.LOGGED_SECTIONS.find(&"history"), "between \"npc\" and \"history\"")
	await _start_server()
	_server.add_fake_player(BotBrain.new(1, BotBrain.Pattern.IDLE), VARDHEIM)
	await wait_physics_frames(40)
	var sections: Dictionary = _server.get_metrics().summary()["sections"]
	assert_true(sections.has("social"), "the server measures the social step")
	if sections.has("social"):
		assert_true(int(sections["social"]["samples"]) > 0, "one sample per tick")


func test_history_records_every_tick_of_every_player() -> void:
	await _start_server()
	var ids: Array[int] = []
	for i: int in 3:
		ids.append(_server.add_fake_player(BotBrain.new(10 + i, BotBrain.Pattern.CIRCLE,
				VARDHEIM_SPAWNS[0], 15.0), VARDHEIM))
	await wait_physics_frames(90)
	var history: StateHistory = _server.get_history()
	var tick: int = _server.get_tick()
	for net_id: int in ids:
		assert_true(history.has_tick(net_id, tick), "the last tick is recorded")
		assert_true(history.has_tick(net_id, tick - StateHistory.LENGTH_TICKS + 1),
				"the ring holds %d ticks" % StateHistory.LENGTH_TICKS)
		assert_false(history.has_tick(net_id, tick - StateHistory.LENGTH_TICKS),
				"the oldest has already been overwritten")
		var sample: StateHistory.Sample = history.sample(net_id, float(tick))
		if assert_not_null(sample, "sample of the last tick"):
			assert_vec_near(sample.position, _character_of(net_id).global_position, 1e-4,
					"the last tick's sample is the current position")
			assert_near(sample.yaw, _character_of(net_id).yaw, 1e-5, "and the yaw")
		var half: StateHistory.Sample = history.sample(net_id, float(tick) - 0.5)
		assert_not_null(half, "it can also be sampled between two ticks")
	assert_null(history.sample(9999, float(tick)), "an unknown id has no track")


func test_snapshots_fit_in_the_packet_limit() -> void:
	var config: ServerConfig = _make_config()
	config.max_players = 64
	await _start_server(config)
	for i: int in 60:
		var realm: int = VARDHEIM if i % 2 == 0 else SOLMARCH
		var home: Vector3 = VARDHEIM_SPAWNS[0] if realm == VARDHEIM else SOLMARCH_SPAWN
		assert_true(_server.add_fake_player(BotBrain.new(100 + i, BotBrain.Pattern.WANDER, home,
				10.0), realm) > 0, "join %d" % i)
	await wait_physics_frames(60)

	var builder := SnapshotBuilder.new(_server.interest_policy)
	var tick: int = _server.get_tick()
	builder.begin(tick, _server.get_registry().get_sorted())
	# Observer: player 1, who sees the other 59.
	var observer: NetEntity = _server.get_registry().get_entity(1)
	var peer := ServerPeer.new(777)
	peer.entity = observer
	peer.input_queue = InputQueue.new()
	peer.input_queue.reset(tick, NetProtocol.neutral_input(tick, observer.get_character().yaw))
	for entity: NetEntity in _server.get_registry().get_sorted():
		if entity != observer:
			peer.relevant[entity.net_id] = true
	var seen: Dictionary[int, bool] = {}
	for build_index: int in 4:
		var packet: PackedByteArray = builder.build_for(peer)
		assert_true(packet.size() <= NetProtocol.MAX_PACKET_BYTES,
				"the snapshot takes %d B, at most 1200" % packet.size())
		var decoded: NetMessages.Snapshot = NetMessages.Snapshot.decode(packet)
		if not assert_not_null(decoded, "the snapshot decodes"):
			return
		assert_eq(decoded.server_tick, tick, "it carries the server tick")
		assert_not_null(decoded.own_state, "it carries the player's own state")
		var capacity: int = floori((NetProtocol.MAX_PACKET_BYTES
				- NetMessages.SNAPSHOT_HEADER_SIZE_WITH_STATE - 2) / float(EntityRecord.SIZE))
		assert_true(decoded.records.size() <= capacity,
				"at most %d records (%d)" % [capacity, decoded.records.size()])
		for record: EntityRecord in decoded.records:
			assert_true(record.net_id != observer.net_id, "the player themself is not among the records")
			seen[record.net_id] = true
	assert_eq(seen.size(), 59, "with priority, all the visible ones go out within a few snapshots")


func test_teleport_changes_state_and_bumps_the_counter() -> void:
	await _start_server()
	var id: int = _server.add_fake_player(BotBrain.new(1, BotBrain.Pattern.IDLE), VARDHEIM)
	await wait_physics_frames(5)
	var entity: NetEntity = _server.get_registry().get_entity(id)
	var character: PlayerCharacter = entity.get_character()
	var yaw_before: float = character.yaw
	assert_eq(entity.teleport_counter, 0, "no teleports")

	_server.teleport(id, Vector3(10.0, 0.5, -3.0))
	assert_eq(entity.teleport_counter, 1, "the counter goes up")
	assert_vec_near(character.global_position, Vector3(10.0, 0.5, -3.0), 1e-5, "new position")
	assert_vec_near(character.velocity, Vector3.ZERO, 1e-6, "velocity 0")
	assert_near(character.yaw, yaw_before, 1e-6, "keeps the yaw")
	var state: PlayerState = character.get_state()
	assert_true(state.equals_exact(PlayerState.decode(state.encode())),
			"the imposed state goes through encode/decode")

	await wait_physics_frames(2)
	var history: StateHistory = _server.get_history()
	var tick: int = _server.get_tick()
	var sample: StateHistory.Sample = history.sample(id, float(tick))
	if assert_not_null(sample, "sample after the teleport"):
		assert_eq((sample.flags >> EntityRecord.TELEPORT_SHIFT) & EntityRecord.TELEPORT_MASK, 1,
				"the history carries the teleport counter")

	for _i: int in 3:
		_server.teleport(id, Vector3(1.0, 0.5, 1.0))
	assert_eq(entity.teleport_counter, 0, "the counter wraps modulo 4")
	_server.teleport(12345, Vector3.ZERO)
	_server.teleport(id, Vector3(NAN, 0.0, 0.0))
	assert_eq(entity.teleport_counter, 0, "an unknown id or a non-finite position do nothing")
	assert_vec_near(character.global_position, Vector3(1.0, 0.5, 1.0), 1e-5, "the position does not change")


func test_falling_out_of_the_world_respawns_at_the_spawn_point() -> void:
	await _start_server()
	var id: int = _server.add_fake_player(BotBrain.new(1, BotBrain.Pattern.IDLE), SOLMARCH)
	await wait_physics_frames(3)
	var entity: NetEntity = _server.get_registry().get_entity(id)
	assert_eq(entity.teleport_counter, 0)
	# Below FALL_LIMIT_Y and with no ground: the server returns it to its spawn point.
	_server.teleport(id, Vector3(0.0, -150.0, 0.0))
	assert_eq(entity.teleport_counter, 1)
	await wait_physics_frames(3)
	var position: Vector3 = entity.get_position()
	assert_true(position.y > -1.0, "has respawned (y = %.2f)" % position.y)
	assert_vec_near(Vector3(position.x, 0.0, position.z), SOLMARCH_SPAWN, 0.1,
			"at Solmarch's spawn point")
	assert_eq(entity.teleport_counter, 2, "respawning also raises the counter")
	assert_true(entity.get_character().grounded, "respawns on the ground")
	assert_eq(_server.write_report(_report_path()), OK)
	var report: Dictionary = _read_json(_report_path())
	assert_eq(int(report.get("respawns", -1)), 1, "the report counts the respawn")
	assert_eq(int(report.get("teleports", -1)), 1, "and the teleport")


func test_large_step_is_counted_as_a_physics_error() -> void:
	await _start_server()
	var id: int = _server.add_fake_player(JumpOnceBrain.new(1), VARDHEIM)
	var character: PlayerCharacter = _character_of(id)
	# The jump emits jumped inside simulate(): there the character is moved 3 m in a single tick.
	character.jumped.connect(func() -> void:
		character.global_position += Vector3(0.0, 3.0, 0.0))
	await wait_physics_frames(12)
	assert_eq(_server.write_report(_report_path()), OK)
	var report: Dictionary = _read_json(_report_path())
	assert_eq(int(report.get("physics_errors", -1)), 1, "the 3 m jump is counted as a physics error")
	assert_eq(int(report.get("respawns", -1)), 0, "but it is not sent back to the spawn point")


func test_player_limit_counts_fake_players() -> void:
	var config: ServerConfig = _make_config()
	config.max_players = 2
	await _start_server(config)
	assert_true(_server.add_fake_player(BotBrain.new(1), VARDHEIM) > 0)
	assert_true(_server.add_fake_player(BotBrain.new(2), VARDHEIM) > 0)
	assert_eq(_server.add_fake_player(BotBrain.new(3), VARDHEIM), -1, "with the cap full no one else enters")
	assert_eq(_server.add_fake_player(null, VARDHEIM), -1, "without a brain neither")
	assert_eq(_server.get_player_count(), 2)


func test_fake_player_names_never_pass_the_name_rules() -> void:
	# The client's social menu (SocialTarget.is_social_target) does not offer to invite or whisper to a name that
	# does not meet NameRules: that is how it knows a body is a fake player, with no connection that could answer.
	var config: ServerConfig = _make_config()
	config.max_players = 120
	await _start_server(config)
	for i: int in 110:
		assert_true(_server.add_fake_player(BotBrain.new(i + 1, BotBrain.Pattern.IDLE), VARDHEIM) > 0,
				"fake %d enters" % (i + 1))
	var names: PackedStringArray = _server.get_connected_names()
	assert_eq(names.size(), 110, "110 fakes")
	assert_true(names.has("Bot-01") and names.has("Bot-110"), "\"Bot-01\" to \"Bot-110\"")
	for fake_name: String in names:
		assert_false(NameRules.is_valid(fake_name), "\"%s\" is not a person's name" % fake_name)


func test_players_spawn_at_their_realm_and_on_the_ground() -> void:
	await _start_server()
	var first: int = _server.add_fake_player(BotBrain.new(1, BotBrain.Pattern.IDLE), VARDHEIM)
	var second: int = _server.add_fake_player(BotBrain.new(2, BotBrain.Pattern.IDLE), VARDHEIM)
	var third: int = _server.add_fake_player(BotBrain.new(3, BotBrain.Pattern.IDLE), SOLMARCH)
	var expected: Dictionary[int, Vector3] = {
		first: VARDHEIM_SPAWNS[0], second: VARDHEIM_SPAWNS[1], third: SOLMARCH_SPAWN,
	}
	for net_id: int in expected:
		var state: PlayerState = _character_of(net_id).get_state()
		assert_vec_near(state.position, expected[net_id], 1e-5, "spawn point of %d" % net_id)
		assert_true(state.grounded, "the spawn point is on the ground")
		assert_true(state.equals_exact(PlayerState.decode(state.encode())),
				"the join state goes through encode/decode")
		assert_eq(state.last_input_tick, 0, "last_input_tick = join tick")
	await wait_physics_frames(30)
	for net_id: int in expected:
		var character: PlayerCharacter = _character_of(net_id)
		assert_vec_near(character.global_position, expected[net_id], 0.05,
				"still at its spawn point")
		assert_true(character.grounded)


## Each server body carries its realm's layer in its mask (the closed fort gates stop the others); the
## Hollow and neutral NPCs, none.
func test_bodies_collide_with_the_layer_of_their_realm() -> void:
	await _start_server()
	var base: int = PlayerCharacter.WORLD_COLLISION_LAYER | PlayerCharacter.PLAYER_BLOCKER_LAYER
	var vardheim: int = _server.add_fake_player(BotBrain.new(1, BotBrain.Pattern.IDLE), VARDHEIM)
	var solmarch: int = _server.add_fake_player(BotBrain.new(2, BotBrain.Pattern.IDLE), SOLMARCH)
	assert_eq(_character_of(vardheim).collision_mask, base | (1 << 4), "Vardheim: layer 5")
	assert_eq(_character_of(solmarch).collision_mask, base | (1 << 5), "Solmarch: layer 6")
	var npc_id: int = _server.spawn_dummy(Vector3(0.0, 0.0, 10.0), 0.0)
	if assert_true(npc_id > 0, "a neutral dummy is created"):
		assert_eq(_character_of(npc_id).collision_mask, base, "the Hollow have no realm layer")


func test_state_log_and_report() -> void:
	var config: ServerConfig = _make_config()
	config.state_log_path = _state_log_path()
	config.port = 24999
	await _start_server(config)
	var ids: Array[int] = []
	for i: int in 2:
		ids.append(_server.add_fake_player(BotBrain.new(5 + i, BotBrain.Pattern.CIRCLE,
				VARDHEIM_SPAWNS[0], 15.0), VARDHEIM))
	var start_tick: int = _server.get_tick()
	await wait_physics_frames(60)
	var ticks: int = _server.get_tick() - start_tick
	assert_eq(_server.write_report(_report_path()), OK, "the report is written")
	_server.stop()
	assert_true(_server.is_stopped(), "with no peers, shutdown is immediate")

	# --state-log: tick,net_id,substituted,hex(PlayerState) per tick and player.
	var lines: PackedStringArray = FileAccess.get_file_as_string(_state_log_path()).strip_edges() \
			.split("\n")
	assert_eq(lines.size(), ticks * 2, "one line per tick and player")
	var previous_tick: int = 0
	for line: String in lines:
		var fields: PackedStringArray = line.split(",")
		if not assert_eq(fields.size(), 4, "four fields: %s" % line):
			return
		var line_tick: int = fields[0].to_int()
		assert_true(line_tick >= previous_tick, "the ticks do not go backward")
		previous_tick = line_tick
		assert_true(ids.has(fields[1].to_int()), "known net_id")
		assert_eq(fields[2], "0", "fake players are never substituted")
		var state: PlayerState = PlayerState.decode(fields[3].hex_decode())
		if assert_not_null(state, "the state decodes from its hexadecimal"):
			assert_eq(state.last_input_tick, line_tick, "the state is the \"after the tick\" one")

	var report: Dictionary = _read_json(_report_path())
	assert_eq(int(report.get("version", 0)), 1)
	assert_eq(report.get("build"), BuildInfo.build_id(), "the report carries the build id")
	assert_eq(report.get("zone"), "test_world")
	assert_eq(int(report.get("port", 0)), 24999)
	assert_eq(int(report.get("ticks", 0)), _server.get_tick(), "ticks")
	assert_eq(int(report.get("tick_rate", 0)), 60)
	var players: Dictionary = report.get("players", {})
	assert_eq(int(players.get("fake", 0)), 2, "two fake players")
	assert_eq(int(players.get("peak", 0)), 2, "peak of two players")
	assert_eq(int(players.get("joined_total", 0)), 2)
	var player_list: Array = report.get("player_list", [])
	assert_eq(player_list.size(), 2, "one record per player")
	var metrics: Dictionary = report.get("metrics", {})
	var sections: Dictionary = metrics.get("sections", {})
	for section: String in ["tick", "net", "sim", "history", "snapshot", "flush"]:
		assert_true(sections.has(section), "the report carries the %s section" % section)
	var tick_section: Dictionary = sections.get("tick", {})
	assert_true(int(tick_section.get("samples", 0)) >= ticks - 1, "tick samples")
	assert_true(int(tick_section.get("p99", 0)) > 0, "p99 of the measured tick")
	assert_true(report.has("strikes") and report.has("kicks") and report.has("bytes")
			and report.has("inputs"), "warnings, kicks, bytes and inputs")


func test_remove_fake_player_frees_the_slot_and_counts_the_departure() -> void:
	await _start_server()
	var first: int = _server.add_fake_player(BotBrain.new(1, BotBrain.Pattern.IDLE), VARDHEIM)
	var second: int = _server.add_fake_player(BotBrain.new(2, BotBrain.Pattern.IDLE), SOLMARCH)
	await wait_physics_frames(5)
	assert_eq(_server.get_player_count(), 2)
	assert_false(_server.remove_fake_player(9999), "an unknown id is not a fake player")
	assert_true(_server.remove_fake_player(first), "the first one's removal is requested")
	assert_false(_server.remove_fake_player(first), "and it cannot be requested twice")
	await wait_physics_frames(2)
	assert_eq(_server.get_player_count(), 1, "one remains")
	assert_null(_server.get_registry().get_entity(first), "the first one's character disappeared")
	assert_not_null(_server.get_registry().get_entity(second), "the other one remains")
	assert_false(_server.remove_fake_player(first), "the first one no longer exists")
	var third: int = _server.add_fake_player(BotBrain.new(3, BotBrain.Pattern.IDLE), VARDHEIM)
	assert_true(third > 0 and third != first, "the freed id is quarantined (%d)" % third)
	assert_eq(_server.write_report(_report_path()), OK)
	var report: Dictionary = _read_json(_report_path())
	var players: Dictionary = report.get("players", {})
	assert_eq(int(players.get("joined_total", 0)), 3, "three joins")
	assert_eq(int(players.get("left_total", 0)), 1, "one removal")
	assert_eq(int(players.get("peak", 0)), 2, "peak of two")
	var simulate: Dictionary = report.get("simulate", {})
	assert_true(int(simulate.get("calls", 0)) >= 10, "simulate() was measured (%s calls)" % simulate.get("calls"))
	assert_true(float(simulate.get("avg_us", 0.0)) > 0.0, "with an average in µs")
	assert_true(report.has("snapshots"), "and the report carries the snapshot measurements")


## Continuous joins and removals (a client that joins and leaves in a loop, --fake-churn) must not
## make memory grow without bound (finding S3): each report record retained its InputQueue, its
## ServerPeer and its NetEntity forever (about 70 objects and 80 KB per cycle). When the player leaves,
## the record drops those references, and the report keeps only the latest records with the totals kept separately.
func test_player_churn_does_not_grow_memory_without_limit() -> void:
	var config: ServerConfig = _make_config()
	config.max_players = 40
	await _start_server(config)
	_server.max_logged_players = 100
	var cycles: int = 0
	var objects_after_warmup: int = 0
	for round_index: int in 16:
		var ids: Array[int] = []
		for i: int in 40:
			ids.append(_server.add_fake_player(BotBrain.new(cycles + i, BotBrain.Pattern.WANDER,
					Vector3.ZERO, 5.0), VARDHEIM))
		await wait_physics_frames(2)
		for net_id: int in ids:
			assert_true(_server.remove_fake_player(net_id), "removal is requested")
		await wait_physics_frames(2)
		cycles += 40
		if round_index == 5:
			# There are already more than 100 joins: the report ring is full.
			objects_after_warmup = int(Performance.get_monitor(Performance.OBJECT_COUNT))
	var objects_now: int = int(Performance.get_monitor(Performance.OBJECT_COUNT))
	assert_eq(_server.get_player_count(), 0, "in the end nobody is left")
	assert_true(objects_now - objects_after_warmup < 50,
			"400 more cycles do not make the object count grow (from %d to %d)"
			% [objects_after_warmup, objects_now])
	assert_eq(_server.write_report(_report_path()), OK)
	var report: Dictionary = _read_json(_report_path())
	var players: Dictionary = report.get("players", {})
	assert_eq((report.get("player_list", []) as Array).size(), 100,
			"the report keeps only the latest 100 records")
	assert_eq(int(players.get("joined_total", 0)), cycles, "but counts all the joins")
	assert_eq(int(players.get("left_total", 0)), cycles, "and all the removals")
	assert_eq(int(players.get("fake", 0)), cycles, "and all the fake players")
	assert_eq(int(players.get("archived", 0)), cycles - 100, "the records that drop out are summarized")


## The records that drop out of the ring cannot be those of players who are still inside.
func test_the_report_ring_never_drops_a_player_who_is_still_in_the_world() -> void:
	await _start_server()
	_server.max_logged_players = 3
	var stayer: int = _server.add_fake_player(BotBrain.new(1, BotBrain.Pattern.IDLE), VARDHEIM)
	for i: int in 6:
		var id: int = _server.add_fake_player(BotBrain.new(i + 2, BotBrain.Pattern.IDLE), SOLMARCH)
		await wait_physics_frames(1)
		_server.remove_fake_player(id)
		await wait_physics_frames(2)
	assert_eq(_server.write_report(_report_path()), OK)
	var report: Dictionary = _read_json(_report_path())
	var list: Array = report.get("player_list", [])
	assert_eq(list.size(), 3, "the ring has its cap")
	var found: bool = false
	for entry: Dictionary in list:
		if int(entry.get("net_id", 0)) == stayer:
			found = true
			assert_eq(int(entry.get("left_tick", 0)), -1, "and is still marked as present")
	assert_true(found, "the player who is still inside keeps their record")
	assert_eq(int((report.get("players", {}) as Dictionary).get("joined_total", 0)), 7)


func test_stop_releases_the_players_but_keeps_the_report() -> void:
	await _start_server()
	for i: int in 3:
		_server.add_fake_player(BotBrain.new(i), VARDHEIM)
	await wait_physics_frames(10)
	_server.stop("prueba")
	assert_true(_server.is_stopped())
	assert_eq(_server.get_player_count(), 0, "no players after shutdown")
	assert_eq(_server.get_registry().size(), 0, "nor entities")
	var ticks: int = _server.get_tick()
	await wait_physics_frames(5)
	assert_eq(_server.get_tick(), ticks, "the tick no longer advances")
	assert_eq(_server.add_fake_player(BotBrain.new(9), VARDHEIM), -1, "no players are added")
	assert_eq(_server.write_report(_report_path()), OK, "the report can be written after shutdown")
	var report: Dictionary = _read_json(_report_path())
	assert_eq((report.get("player_list", []) as Array).size(), 3, "with the records of the 3 players")
	_server.stop()  # closing twice does nothing


func test_start_validates_its_arguments() -> void:
	_viewport = SubViewport.new()
	_viewport.own_world_3d = true
	tree.root.add_child(_viewport)
	_world = Node3D.new()
	_viewport.add_child(_world)
	_server = ZoneServer.new()
	assert_eq(_server.start(_make_config(), _world, null, null), ERR_UNCONFIGURED,
			"the server must be in the tree")
	_viewport.add_child(_server)
	assert_eq(_server.start(null, _world, null, null), ERR_UNCONFIGURED, "without configuration")
	assert_eq(_server.start(_make_config(), null, null, null), ERR_UNCONFIGURED, "without a world")
	assert_eq(_server.start(_make_config(), _world, null, null), OK, "with everything")
	assert_eq(_server.start(_make_config(), _world, null, null), ERR_ALREADY_IN_USE,
			"it is not started twice")
	assert_eq(_server.add_fake_player(BotBrain.new(1), VARDHEIM), 1,
			"with no spawn points, the player appears at the origin")
	assert_vec_near(_character_of(1).global_position, Vector3.ZERO, 1e-5)


func _report_path() -> String:
	return ProjectSettings.globalize_path(REPORT_FILE)


func _state_log_path() -> String:
	return ProjectSettings.globalize_path(STATE_LOG_FILE)


func _read_json(path: String) -> Dictionary:
	var json := JSON.new()
	if json.parse(FileAccess.get_file_as_string(path)) != OK or not json.data is Dictionary:
		fail("could not read the JSON %s" % path)
		return {}
	return json.data
