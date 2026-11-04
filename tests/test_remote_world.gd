extends TestCase
## Tests for [RemoteWorld] and [RemotePlayerView] (docs/red.md, sections 7 and 9.4) with synthetic
## messages: ENTITY_SPAWN, SNAPSHOT and ENTITY_DESPAWN by hand, and a fake interpolation clock
## whose render tick is set at will. It checks that the remote appears and disappears according to the
## render tick, that it is interpolated between samples, that records with unknown or out-of-range
## ids are ignored, that the view emits the [signal PlayerCharacter.jumped] and
## [signal PlayerCharacter.landed] edges, that the body does not collide and that the animator works with a
## body that does not simulate.


## Clock whose render tick is set from the test.
class FakeClock extends InterpolationClock:
	var render: float = 0.0

	func get_render_tick() -> float:
		return render


var _world: RemoteWorld
var _clock: FakeClock


func before_each() -> void:
	_clock = FakeClock.new()
	_world = RemoteWorld.new()
	_world.install_visuals = false
	_world.setup(_clock)
	tree.root.add_child(_world)


func after_each() -> void:
	if is_instance_valid(_world):
		tree.root.remove_child(_world)
		_world.free()
	_world = null
	await wait_process_frames()


# --- Helpers ----------------------------------------------------------------------------------

func _spawn(net_id: int, tick: int, position: Vector3, grounded: bool = true,
		teleport_counter: int = 0) -> NetMessages.EntitySpawn:
	var spawn := NetMessages.EntitySpawn.new()
	spawn.net_id = net_id
	spawn.kind = NetProtocol.EntityKind.PLAYER
	spawn.spawn_tick = tick
	spawn.realm = NetProtocol.Realm.SOLMARCH
	spawn.teleport_counter = teleport_counter
	spawn.display_name = "Remoto%d" % net_id
	var state := PlayerState.new()
	state.position = position
	state.grounded = grounded
	spawn.state = state
	return spawn


func _record(net_id: int, position: Vector3, velocity: Vector3 = Vector3.ZERO,
		grounded: bool = true, teleport_counter: int = 0, yaw: float = 0.0) -> EntityRecord:
	var record := EntityRecord.new()
	record.net_id = net_id
	record.position = position
	record.velocity = velocity
	record.yaw = yaw
	record.flags = (teleport_counter & EntityRecord.TELEPORT_MASK) << EntityRecord.TELEPORT_SHIFT
	if grounded:
		record.flags |= EntityRecord.FLAG_GROUNDED
	return record


func _snapshot(tick: int, records: Array[EntityRecord]) -> NetMessages.Snapshot:
	var snapshot := NetMessages.Snapshot.new()
	snapshot.server_tick = tick
	snapshot.records = records
	return snapshot


func _push(tick: int, record: EntityRecord) -> void:
	_world.on_snapshot(_snapshot(tick, [record] as Array[EntityRecord]))


func _despawn(net_id: int, tick: int) -> NetMessages.EntityDespawn:
	var despawn := NetMessages.EntityDespawn.new()
	despawn.net_id = net_id
	despawn.despawn_tick = tick
	despawn.reason = NetProtocol.DespawnReason.DISCONNECTED
	return despawn


# --- Appearing and disappearing ---------------------------------------------------------------

func test_spawn_creates_a_hidden_non_colliding_body() -> void:
	_world.on_spawn(_spawn(7, 100, Vector3(3.0, 0.0, -4.0)))
	var view: RemotePlayerView = _world.get_view(7)
	if not assert_not_null(view, "the SPAWN creates the view"):
		return
	assert_eq(_world.get_view_count(), 1)
	var body: PlayerCharacter = view.get_body()
	assert_not_null(body)
	assert_eq(body.collision_layer, 0, "the remote is in no layer")
	assert_eq(body.collision_mask, 0, "nor does it look at any layer")
	assert_eq(body.physics_interpolation_mode, Node.PHYSICS_INTERPOLATION_MODE_OFF)
	assert_false(body.is_physics_processing(), "never simulates")
	assert_false(body.visible, "hidden until the render reaches its spawn")
	assert_eq(view.get_net_id(), 7)
	assert_eq(view.get_display_name(), "Remoto7")
	assert_eq(view.get_realm(), NetProtocol.Realm.SOLMARCH)
	assert_true(body.get_parent() == _world, "the body hangs from the RemoteWorld")


func test_body_configuration_survives_ready_when_set_up_before_entering_the_tree() -> void:
	# PlayerCharacter's _ready() enables its collisions: the view disables them when it is ready.
	var scene: PackedScene = load(RemoteWorld.PLAYER_SCENE_PATH) as PackedScene
	var body: PlayerCharacter = scene.instantiate() as PlayerCharacter
	var view := RemotePlayerView.new()
	view.setup(body, _spawn(3, 10, Vector3.ZERO))
	_world.add_child(body)
	_world.add_child(view)
	assert_eq(body.collision_layer, 0)
	assert_eq(body.collision_mask, 0)
	assert_false(body.is_physics_processing())


func test_own_spawn_is_ignored() -> void:
	var own: NetMessages.EntitySpawn = _spawn(1, 50, Vector3.ZERO)
	own.is_yours = true
	_world.on_spawn(own)
	assert_eq(_world.get_view_count(), 0, "the own SPAWN does not create a remote")


func test_duplicate_spawn_is_ignored() -> void:
	_world.on_spawn(_spawn(7, 100, Vector3.ZERO))
	_world.on_spawn(_spawn(7, 100, Vector3(50.0, 0.0, 0.0)))
	assert_eq(_world.get_view_count(), 1)
	assert_eq(_world.get_stats()["spawned"], 1)
	_world.draw(101.0, 0.016)
	assert_vec_near(_world.get_view(7).get_drawn_position(), Vector3.ZERO, 0.001,
			"the first one wins")


func test_visibility_follows_the_render_tick() -> void:
	_world.on_spawn(_spawn(7, 100, Vector3(1.0, 0.0, 2.0)))
	var view: RemotePlayerView = _world.get_view(7)
	_world.draw(99.0, 0.016)
	assert_false(view.get_body().visible, "before its spawn it is not seen")
	assert_false(view.is_drawn())
	_world.draw(100.0, 0.016)
	assert_true(view.get_body().visible, "at its spawn it appears")
	assert_true(view.is_drawn())
	assert_vec_near(view.get_body().global_position, Vector3(1.0, 0.0, 2.0), 0.001)
	assert_vec_near(view.get_drawn_position(), Vector3(1.0, 0.0, 2.0), 0.001)


func test_despawn_removes_the_view_when_the_render_tick_arrives() -> void:
	_world.on_spawn(_spawn(7, 100, Vector3.ZERO))
	var view: RemotePlayerView = _world.get_view(7)
	var body: PlayerCharacter = view.get_body()
	_push(102, _record(7, Vector3(2.0, 0.0, 0.0)))
	_world.on_despawn(_despawn(7, 110))
	assert_true(view.is_despawn_scheduled())
	assert_eq(view.get_despawn_tick(), 110)
	_world.draw(105.0, 0.016)
	assert_not_null(_world.get_view(7), "it stays on screen until its despawn tick")
	assert_true(body.visible)
	_world.draw(109.9, 0.016)
	assert_not_null(_world.get_view(7))
	_world.draw(110.0, 0.016)
	assert_null(_world.get_view(7), "at its despawn tick it disappears")
	assert_eq(_world.get_view_count(), 0)
	await wait_process_frames()
	assert_false(is_instance_valid(body), "the body is freed")


func test_records_outside_the_life_of_the_view_are_ignored() -> void:
	_world.on_spawn(_spawn(7, 100, Vector3.ZERO))
	var view: RemotePlayerView = _world.get_view(7)
	_push(98, _record(7, Vector3(99.0, 0.0, 0.0)))
	assert_eq(view.get_interpolator().get_sample_count(), 1, "a record before the spawn is not valid")
	_push(104, _record(7, Vector3(4.0, 0.0, 0.0)))
	assert_eq(view.get_interpolator().get_sample_count(), 2)
	_world.on_despawn(_despawn(7, 108))
	_push(108, _record(7, Vector3(8.0, 0.0, 0.0)))
	_push(110, _record(7, Vector3(10.0, 0.0, 0.0)))
	assert_eq(view.get_interpolator().get_sample_count(), 2,
			"records from the despawn tick on are not valid")


func test_records_of_unknown_ids_are_ignored() -> void:
	_world.on_spawn(_spawn(7, 100, Vector3.ZERO))
	var records: Array[EntityRecord] = [_record(99, Vector3(1.0, 0.0, 0.0)),
			_record(7, Vector3(2.0, 0.0, 0.0))]
	_world.on_snapshot(_snapshot(102, records))
	assert_null(_world.get_view(99), "an unknown id creates nothing")
	assert_eq(_world.get_view_count(), 1)
	assert_eq(_world.get_stats()["ignored_records"], 1)
	assert_eq(_world.get_view(7).get_interpolator().get_sample_count(), 2)


func test_despawn_of_an_unknown_id_is_harmless() -> void:
	_world.on_despawn(_despawn(55, 100))
	assert_eq(_world.get_view_count(), 0)


func test_respawn_with_the_same_id_keeps_the_old_view_until_its_despawn_tick() -> void:
	_world.on_spawn(_spawn(7, 100, Vector3.ZERO))
	_push(104, _record(7, Vector3(4.0, 0.0, 0.0)))
	_world.on_despawn(_despawn(7, 110))
	_world.on_spawn(_spawn(7, 120, Vector3(50.0, 0.0, 0.0)))
	var fresh: RemotePlayerView = _world.get_view(7)
	assert_eq(fresh.get_spawn_tick(), 120, "the current one is the new one")
	assert_eq(_world.get_views().size(), 2, "the old one remains until its despawn")
	_push(108, _record(7, Vector3(8.0, 0.0, 0.0)))
	_push(122, _record(7, Vector3(52.0, 0.0, 0.0)))
	assert_eq(fresh.get_interpolator().get_sample_count(), 2,
			"the record of tick 122 belongs to the new view, not the one of 108")
	_world.draw(105.0, 0.016)
	var old_body: PlayerCharacter = null
	for view: RemotePlayerView in _world.get_views():
		if view != fresh:
			old_body = view.get_body()
	assert_true(old_body.visible, "the old one is seen until its despawn")
	assert_false(fresh.get_body().visible, "the new one has not appeared yet")
	_world.draw(111.0, 0.016)
	assert_eq(_world.get_views().size(), 1, "the old one was removed on its despawn tick")
	_world.draw(121.0, 0.016)
	assert_true(fresh.get_body().visible)
	assert_vec_near(fresh.get_drawn_position(), Vector3(51.0, 0.0, 0.0), 0.001)


# --- Interpolation ----------------------------------------------------------------------------

func test_draws_between_snapshots_with_interpolation() -> void:
	_world.on_spawn(_spawn(7, 100, Vector3.ZERO))
	_push(102, _record(7, Vector3(2.0, 0.0, 0.0), Vector3.ZERO, true, 0, 0.0))
	_push(104, _record(7, Vector3(4.0, 0.0, 0.0), Vector3.ZERO, true, 0, 1.0))
	var view: RemotePlayerView = _world.get_view(7)
	_world.draw(101.0, 0.016)
	assert_vec_near(view.get_drawn_position(), Vector3(1.0, 0.0, 0.0), 0.001)
	_world.draw(103.5, 0.016)
	assert_vec_near(view.get_drawn_position(), Vector3(3.5, 0.0, 0.0), 0.001)
	assert_near(view.get_body().yaw, 0.75, 0.001, "the yaw is also interpolated")
	assert_near(_world.get_last_drawn_render_tick(), 103.5, 0.0001)


func test_writes_velocity_and_grounded_into_the_body() -> void:
	_world.on_spawn(_spawn(7, 100, Vector3.ZERO))
	_push(102, _record(7, Vector3(0.0, 1.0, 0.0), Vector3(0.0, 6.0, -5.0), false))
	_push(104, _record(7, Vector3(0.0, 2.0, 0.0), Vector3(0.0, 6.0, -5.0), false))
	_world.draw(103.0, 0.016)
	var body: PlayerCharacter = _world.get_view(7).get_body()
	assert_vec_near(body.velocity, Vector3(0.0, 6.0, -5.0), 0.001)
	assert_false(body.grounded)


func test_extrapolates_up_to_six_ticks_and_then_stops() -> void:
	_world.on_spawn(_spawn(7, 100, Vector3.ZERO))
	_push(102, _record(7, Vector3(0.0, 0.0, 0.0), Vector3(6.0, 0.0, 0.0)))
	var view: RemotePlayerView = _world.get_view(7)
	_world.draw(105.0, 0.016)
	assert_vec_near(view.get_drawn_position(), Vector3(0.3, 0.0, 0.0), 0.001, "3 ticks at 6 m/s")
	_world.draw(120.0, 0.016)
	assert_vec_near(view.get_drawn_position(), Vector3(0.6, 0.0, 0.0), 0.001, "cap of 6 ticks")


func test_teleport_counter_holds_the_position_until_the_next_sample() -> void:
	_world.on_spawn(_spawn(7, 100, Vector3.ZERO))
	_push(102, _record(7, Vector3(100.0, 0.0, 0.0), Vector3.ZERO, true, 1))
	var view: RemotePlayerView = _world.get_view(7)
	_world.draw(101.0, 0.016)
	assert_vec_near(view.get_drawn_position(), Vector3.ZERO, 0.001, "a jump is not interpolated")
	_world.draw(102.0, 0.016)
	assert_vec_near(view.get_drawn_position(), Vector3(100.0, 0.0, 0.0), 0.001)
	assert_eq(view.get_blend_offset(), Vector3.ZERO)


func test_return_after_extrapolation_becomes_a_decaying_offset() -> void:
	_world.on_spawn(_spawn(7, 100, Vector3.ZERO))
	_push(102, _record(7, Vector3(0.2, 0.0, 0.0), Vector3(6.0, 0.0, 0.0)))
	var view: RemotePlayerView = _world.get_view(7)
	_world.draw(106.0, 0.0)
	assert_vec_near(view.get_drawn_position(), Vector3(0.6, 0.0, 0.0), 0.001,
			"extrapolated 4 ticks")
	# The data arrives that contradicts the extrapolation: a 10 cm jump.
	_push(104, _record(7, Vector3(0.3, 0.0, 0.0), Vector3(6.0, 0.0, 0.0)))
	assert_vec_near(view.get_blend_offset(), Vector3(0.1, 0.0, 0.0), 0.001,
			"the jump becomes an offset")
	_world.draw(106.0, 0.0)
	assert_vec_near(view.get_drawn_position(), Vector3(0.6, 0.0, 0.0), 0.001,
			"what is drawn does not jump")
	_world.draw(106.0, RemotePlayerView.OFFSET_HALF_LIFE)
	assert_vec_near(view.get_blend_offset(), Vector3(0.05, 0.0, 0.0), 0.001,
			"decays to half in one half-life")
	for _i: int in 200:
		_world.draw(106.0, 0.1)
	assert_eq(view.get_blend_offset(), Vector3.ZERO, "and ends up vanishing")


func test_small_return_jumps_are_ignored_and_big_ones_snap() -> void:
	_world.on_spawn(_spawn(7, 100, Vector3.ZERO))
	_push(102, _record(7, Vector3.ZERO, Vector3(6.0, 0.0, 0.0)))
	var view: RemotePlayerView = _world.get_view(7)
	_world.draw(105.0, 0.0)
	# Extrapolated to 0.3 m; the new data says that at that instant it was at 0.28 m (a 2 cm jump):
	# it does not merit an offset.
	_push(104, _record(7, Vector3(0.18, 0.0, 0.0), Vector3(6.0, 0.0, 0.0)))
	assert_eq(view.get_blend_offset(), Vector3.ZERO, "less than 5 cm is ignored")
	# Now the jump is 3 m: it is applied all at once.
	_world.draw(112.0, 0.0)
	_push(111, _record(7, Vector3(3.0, 0.0, 0.0), Vector3.ZERO))
	assert_eq(view.get_blend_offset(), Vector3.ZERO, "more than 1.5 m jumps directly")
	_world.draw(112.0, 0.0)
	assert_vec_near(view.get_drawn_position(), Vector3(3.0, 0.0, 0.0), 0.001)


# --- Jump and landing edges -------------------------------------------------------------------

func test_view_emits_jumped_and_landed_on_flanks() -> void:
	_world.on_spawn(_spawn(7, 100, Vector3.ZERO))
	_push(102, _record(7, Vector3.ZERO))
	_push(104, _record(7, Vector3(0.0, 0.5, 0.0), Vector3(0.0, 8.0, 0.0), false))
	_push(106, _record(7, Vector3(0.0, 0.6, 0.0), Vector3(0.0, 2.0, 0.0), false))
	_push(108, _record(7, Vector3.ZERO))
	var view: RemotePlayerView = _world.get_view(7)
	var counts: Dictionary = {"jumped": 0, "landed": 0}
	view.get_body().jumped.connect(func() -> void: counts["jumped"] += 1)
	view.get_body().landed.connect(func() -> void: counts["landed"] += 1)
	_world.draw(100.0, 0.016)
	_world.draw(101.0, 0.016)
	assert_eq(counts["jumped"], 0, "on the ground there are no edges")
	_world.draw(103.0, 0.016)
	assert_eq(counts["jumped"], 1, "taking off upward is a jump")
	assert_eq(counts["landed"], 0)
	_world.draw(105.0, 0.016)
	assert_eq(counts["jumped"], 1, "in the air it does not repeat")
	_world.draw(107.0, 0.016)
	assert_eq(counts["landed"], 1, "returning to the ground is a landing")
	assert_eq(counts["jumped"], 1)
	assert_eq(view.get_jumped_count(), 1)
	assert_eq(view.get_landed_count(), 1)
	_world.draw(108.0, 0.016)
	assert_eq(counts["landed"], 1, "nor the landing")


func test_falling_off_a_ledge_is_not_a_jump() -> void:
	_world.on_spawn(_spawn(7, 100, Vector3.ZERO))
	_push(102, _record(7, Vector3(0.0, -0.1, 0.0), Vector3(2.0, -1.0, 0.0), false))
	_push(104, _record(7, Vector3(0.0, -0.4, 0.0), Vector3(2.0, -3.0, 0.0), false))
	_push(106, _record(7, Vector3(0.0, -2.0, 0.0)))
	var view: RemotePlayerView = _world.get_view(7)
	var counts: Dictionary = {"jumped": 0, "landed": 0}
	view.get_body().jumped.connect(func() -> void: counts["jumped"] += 1)
	view.get_body().landed.connect(func() -> void: counts["landed"] += 1)
	_world.draw(100.0, 0.016)
	_world.draw(103.0, 0.016)
	_world.draw(105.0, 0.016)
	_world.draw(106.0, 0.016)
	assert_eq(counts["jumped"], 0, "falling off an edge does not emit jumped")
	assert_eq(counts["landed"], 1, "but the landing does")


func test_first_drawn_frame_emits_nothing() -> void:
	_world.on_spawn(_spawn(7, 100, Vector3.ZERO, false))
	var view: RemotePlayerView = _world.get_view(7)
	var counts: Dictionary = {"landed": 0}
	view.get_body().landed.connect(func() -> void: counts["landed"] += 1)
	_world.draw(100.0, 0.016)
	_push(102, _record(7, Vector3.ZERO))
	assert_eq(counts["landed"], 0, "the first frame has nothing to compare against")


# --- Collision --------------------------------------------------------------------------------

func test_remote_does_not_collide_with_anything() -> void:
	var scene: PackedScene = load(RemoteWorld.PLAYER_SCENE_PATH) as PackedScene
	# Control: a normal character (layer 2) does appear in queries.
	var control: PlayerCharacter = scene.instantiate() as PlayerCharacter
	_world.add_child(control)
	control.global_position = Vector3(10.0, 0.0, 0.0)
	_world.on_spawn(_spawn(7, 100, Vector3.ZERO))
	_world.draw(100.0, 0.016)
	await wait_physics_frames(2)
	var space: PhysicsDirectSpaceState3D = _world.get_world_3d().direct_space_state
	var all_layers: int = 0xFFFFF
	var ray_remote := PhysicsRayQueryParameters3D.create(Vector3(0.0, 1.0, 3.0),
			Vector3(0.0, 1.0, -3.0), all_layers)
	assert_true(space.intersect_ray(ray_remote).is_empty(),
			"a ray against all layers does not touch the remote")
	var ray_control := PhysicsRayQueryParameters3D.create(Vector3(10.0, 1.0, 3.0),
			Vector3(10.0, 1.0, -3.0), all_layers)
	assert_false(space.intersect_ray(ray_control).is_empty(),
			"and the query does see a normal character")
	control.free()


# --- Animation --------------------------------------------------------------------------------

func test_animator_works_on_a_body_that_never_simulates() -> void:
	_world.install_visuals = true
	_world.on_spawn(_spawn(7, 100, Vector3.ZERO))
	var view: RemotePlayerView = _world.get_view(7)
	var visual: HumanoidVisual = view.get_body().get_node_or_null(^"Visual/HumanoidVisual") \
			as HumanoidVisual
	if not assert_not_null(visual, "the remote carries the animated humanoid"):
		return
	var placeholders: int = 0
	for child: Node in view.get_body().get_node(^"Visual").get_children():
		if child is MeshInstance3D:
			placeholders += 1
	assert_eq(placeholders, 0, "and without the placeholder meshes")
	# Running toward -Z at 5 m/s for a good while.
	for i: int in range(1, 31):
		_push(100 + i * 2, _record(7, Vector3(0.0, 0.0, -float(i) / 6.0), Vector3(0.0, 0.0, -5.0)))
	_clock.render = 110.0
	await wait_process_frames(40)
	var animator: CharacterAnimator = visual.get_animator()
	assert_true(animator.get_character() == view.get_body(), "the animator reads the remote")
	var running: Dictionary = animator.get_debug_state()
	assert_true(float(running["speed"]) > 3.0, "the velocity reaches the animator: %s" % running)
	assert_eq(running["air_state"], "GROUNDED")
	# Now in the air (jumping).
	for i: int in range(31, 41):
		_push(100 + i * 2, _record(7, Vector3(0.0, 0.5, -5.0), Vector3(0.0, 6.0, -5.0), false))
	_clock.render = 165.0
	await wait_process_frames(6)
	var airborne: Dictionary = animator.get_debug_state()
	assert_true(str(airborne["air_state"]) != "GROUNDED",
			"the animator sees there is no ground: %s" % airborne)


# --- Miscellaneous ----------------------------------------------------------------------------

func test_process_draws_with_the_clock_and_keeps_the_last_render_tick() -> void:
	_world.on_spawn(_spawn(7, 100, Vector3.ZERO))
	_clock.render = 130.0
	await wait_process_frames(2)
	var drawn: float = _world.get_last_drawn_render_tick()
	assert_true(drawn >= 130.0 and drawn < 131.0,
			"render_tick + interpolation fraction (%s)" % drawn)


func test_stats_count_spawns_and_despawns() -> void:
	_world.on_spawn(_spawn(7, 100, Vector3.ZERO))
	_world.on_spawn(_spawn(8, 100, Vector3(2.0, 0.0, 0.0)))
	_world.on_despawn(_despawn(8, 120))
	var stats: Dictionary = _world.get_stats()
	assert_eq(stats["spawned"], 2)
	assert_eq(stats["despawns"], 1)
	assert_eq(stats["views"], 2)


# --- Drawn action and health (combat) ---------------------------------------------------------

func test_view_exposes_the_drawn_action_and_health() -> void:
	_world.on_spawn(_spawn(7, 100, Vector3.ZERO))
	var view: RemotePlayerView = _world.get_view(7)
	assert_eq(view.get_drawn_action(), 0, "on appearing, no action")
	assert_eq(view.get_drawn_health_q(), EntityRecord.HEALTH_Q_FULL, "and with full health")
	var attacking: EntityRecord = _record(7, Vector3(0.0, 0.0, -1.0))
	attacking.action = ActionMachine.PHASE_ACTIVE << 4 | CombatState.Action.LIGHT
	attacking.health_q = 100
	_push(104, attacking)
	_push(108, attacking)
	_clock.render = 104.0
	_world.draw(104.0, 0.016)
	assert_eq(view.get_drawn_action() & 15, CombatState.Action.LIGHT, "the record's action")
	assert_eq((view.get_drawn_action() >> 4) & 3, ActionMachine.PHASE_ACTIVE, "and its phase")
	assert_eq(view.get_drawn_health_q(), 100, "and the quantized health")


# --- Weapons (phase 4) --------------------------------------------------------------------------

func test_the_weapon_pair_comes_from_the_spawn_and_the_loadout_and_the_slot_bit_picks_one() -> void:
	var sword: int = CombatCatalog.weapon_id(&"sword_shield")
	var bow: int = CombatCatalog.weapon_id(&"bow")
	var spawn: NetMessages.EntitySpawn = _spawn(7, 10, Vector3.ZERO)
	# Another player's SPAWN carries the other weapon and the active slot (docs/habilidades.md, section 5.2): here, the
	# bow in slot 2 and active.
	spawn.state.combat = CombatState.initial(CombatCatalog.rules(), bow, sword)
	spawn.state.combat.combat_flags2 |= CombatState.FLAG2_SECOND_SLOT
	_world.on_spawn(spawn)
	var view: RemotePlayerView = _world.get_view(7)
	assert_eq(view.get_weapons(), Vector2i(sword, bow), "in slot order")
	assert_true(view.is_drawn_second_slot(), "slot 2 active, from the SPAWN")
	assert_eq(view.get_active_weapon_id(), bow)
	# The drawn record rules: bit 3 of flags at 0 is slot 1.
	_push(12, _record(7, Vector3.ZERO))
	_clock.render = 12.0
	_world.draw(12.0, 0.0)
	assert_false(view.is_drawn_second_slot())
	assert_eq(view.get_active_weapon_id(), sword, "switched to the sword")
	var second: EntityRecord = _record(7, Vector3.ZERO)
	second.flags |= EntityRecord.FLAG_SECOND_SLOT
	_push(14, second)
	_world.draw(14.0, 0.0)
	assert_eq(view.get_active_weapon_id(), bow, "and goes back to the bow")
	# A LOADOUT (on respawning with another template) gives it another pair.
	_world.on_loadout(NetMessages.EntityEvent.loadout(7, 20, CombatCatalog.template_id(&"squire"), sword, 0, 0))
	assert_eq(view.get_weapons(), Vector2i(sword, 0))
	assert_eq(view.get_active_weapon_id(), sword, "without a second weapon, slot 1's even if the bit arrives")
	_world.on_loadout(NetMessages.EntityEvent.loadout(99, 20, 1, bow, 0, 0))
	assert_eq(view.get_weapons(), Vector2i(sword, 0), "the LOADOUT of another id does not touch it")
