extends TestCase
## Tests for [ProjectileWorld] (docs/abilities.md, sections 6.2 and 7.3, H4) without a server: the arrows' SPAWN and
## DESPAWN are synthetic messages, as in test_net_client.gd.
## [br]- The predicted arrow is replaced by the server's (same source and index, tick within the buffer)
## without jumps: the visual offset decays over 6 ticks.
## [br]- Two prediction steps in the same physics tick with the commitment in the first: the arrow is released
## (with [signal ClientPrediction.stepped]; looking at the state once per physics tick would miss it).
## [br]- A SPAWN of an own arrow with the player already in the world goes through [NetClient] to the [ProjectileWorld]
## without touching the local character; without a counterpart, the server's is drawn.
## [br]- The remote one appears at its [code]render_tick[/code] and is removed at [code]despawn_tick + f[/code] (on the
## wall) or at [code]despawn_tick[/code] if it expires.
## [br]- The own one sticks into the world, is hidden inside an enemy's drawn capsule and, without a SPAWN, is
## removed at [code]rtt + 30[/code] ticks if no snapshot has arrived yet.
## [br]- H5 review: the remote one with DESPAWN 4 on its own tick from inside a view body (the doorway of
## the closed door) stays at its mouth ([code]hit_from_inside[/code] on the first segment, like the
## server); the remote one's fraction checks hostility against the SPAWN's realm, also without the shooter's
## view (the shooter's allies do not stop it); and the predicted one is considered rejected using the last
## snapshot's tick, not the input's RTT.

const OWN_ID: int = 5
const ENEMY_ID: int = 77
const ZONE: StringName = &"test_world"
const RTT_TICKS: int = 10
const SHOT_TICK: int = 200
## Wall (plane z = WALL_Z, 1 m thick) in front of the shooter, who looks toward −Z.
const WALL_Z: float = -20.0

var _nodes: Array[Node] = []
var _pair: PredictionPair = null


func after_each() -> void:
	if _pair != null:
		_pair.free_worlds()
		_pair = null
	for node: Node in _nodes:
		if is_instance_valid(node):
			if node.get_parent() != null:
				node.get_parent().remove_child(node)
			node.free()
	_nodes.clear()
	await wait_process_frames()


# --- Setup --------------------------------------------------------------------------------------

## Own physics world (floor and, if requested, the wall) with a [ProjectileWorld] inside and a [RemoteWorld]
## outside the tree. A couple of physics frames must pass before casting rays.
func _make_world(with_wall: bool) -> ProjectileWorld:
	var viewport := SubViewport.new()
	viewport.own_world_3d = true
	viewport.size = Vector2i(64, 64)
	tree.root.add_child(viewport)
	_nodes.append(viewport)
	_add_box(viewport, Vector3(0.0, -0.5, 0.0), Vector3(400.0, 1.0, 400.0))
	if with_wall:
		_add_box(viewport, Vector3(0.0, 5.0, WALL_Z), Vector3(40.0, 10.0, 1.0))
	var remote := RemoteWorld.new()
	remote.install_visuals = false
	remote.setup(InterpolationClock.new())
	_nodes.append(remote)
	var world := ProjectileWorld.new()
	world.install_visuals = false
	world.setup(InterpolationClock.new(), remote)
	viewport.add_child(world)
	world.set_local(OWN_ID, NetProtocol.Realm.VARDHEIM, ZONE, null, null, RTT_TICKS)
	return world


func _add_box(parent: Node, center: Vector3, box_size: Vector3) -> void:
	var body := StaticBody3D.new()
	body.collision_layer = PlayerCharacter.WORLD_COLLISION_LAYER
	body.collision_mask = 0
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = box_size
	shape.shape = box
	body.add_child(shape)
	body.position = center
	parent.add_child(body)


## State at the commitment of the bow's quick shot at [param tick] with feet at [param feet].
func _quick_shot_state(tick: int, feet: Vector3) -> PlayerState:
	var quick: AttackTicks = CombatCatalog.attack(CombatCatalog.attack_id(&"bow_quick"))
	var state := PlayerState.new()
	state.position = feet
	state.grounded = true
	state.combat = CombatState.initial(CombatCatalog.rules(), CombatCatalog.weapon_id(&"bow"))
	state.combat.action = CombatState.Action.LIGHT
	state.combat.action_id = quick.id
	state.combat.action_tick = tick - quick.windup_ticks
	return state


func _look_input(tick: int, yaw: float = 0.0, pitch: float = 0.0) -> PlayerInput:
	var input := PlayerInput.new()
	input.tick = tick
	input.look_yaw = yaw
	input.look_pitch = pitch
	return input


func _arrow_spawn(net_id: int, tick: int, owner: int, realm: int, source: int, p0: Vector3,
		v0: Vector3, index: int = 0) -> NetMessages.EntitySpawn:
	var quantized: Array = Ballistics.quantize(p0, v0)
	return NetMessages.EntitySpawn.for_projectile(net_id, tick, realm, owner,
			CombatCatalog.projectile_id(&"arrow"), source, index, false, quantized[0], quantized[1])


func _quick_source() -> int:
	return CombatSource.make(CombatSource.Kind.ATTACK, CombatCatalog.attack_id(&"bow_quick"))


# --- Tests --------------------------------------------------------------------------------------

func test_the_predicted_arrow_is_replaced_by_the_servers_without_a_jump() -> void:
	var world: ProjectileWorld = _make_world(false)
	await wait_physics_frames(2)
	var state: PlayerState = _quick_shot_state(SHOT_TICK, Vector3.ZERO)
	world.on_stepped(SHOT_TICK, _look_input(SHOT_TICK), state)
	assert_eq(world.get_stats()["predicted"], 1, "the quick shot's commitment creates the predicted arrow")
	var predicted: ProjectileWorld.Arrow = world.get_arrows()[0]
	assert_eq(predicted.spawn_tick, SHOT_TICK)
	assert_eq(predicted.source, _quick_source(), "with the attack's source")
	assert_false(predicted.confirmed)
	# The same ballistics that ProjectileLaunch computes, already quantized as it travels.
	var launch: ProjectileLaunch = ProjectileLaunch.from_state(state.combat, SHOT_TICK)
	var shots: Array[PackedVector3Array] = launch.launch(Vector3.ZERO, 0.0, 0.0, false, null,
			PackedVector3Array())
	assert_vec_near(predicted.p0, shots[0][0], 0.0001, "leaves from the chest")
	assert_vec_near(predicted.v0, shots[0][1], 0.0001, "toward the crosshair at 45 m/s")
	assert_near(predicted.v0.length(), 45.0, 0.02)
	world.draw(SHOT_TICK + 3.0, 0.0)
	var before: Vector3 = predicted.drawn_position
	assert_vec_near(before, predicted.position_at(3.0), 0.0001, "drawn at the predicted time")
	# The server fires it two ticks later (its input arrived later) and slightly offset.
	var server_p0: Vector3 = predicted.p0 + Vector3(0.06, 0.0, 0.0)
	world.on_spawn(_arrow_spawn(700, SHOT_TICK + 2, OWN_ID, NetProtocol.Realm.VARDHEIM, _quick_source(),
			server_p0, predicted.v0))
	assert_eq(world.get_stats()["substituted"], 1, "it is paired with the predicted one")
	assert_eq(world.get_live_count(), 1, "and there are not two arrows")
	var arrow: ProjectileWorld.Arrow = world.find_arrow(700)
	if not assert_not_null(arrow, "the predicted one adopts the server's id"):
		return
	assert_true(arrow.confirmed)
	assert_eq(arrow.spawn_tick, SHOT_TICK + 2, "and its tick")
	world.draw(SHOT_TICK + 3.0, 0.0)
	assert_vec_near(arrow.drawn_position, before, 0.001, "at the moment of replacement it does not jump")
	world.draw(SHOT_TICK + 6.0, 0.0)
	assert_true(arrow.offset_at(SHOT_TICK + 6.0).length() > 0.0, "the offset still decays")
	world.draw(SHOT_TICK + 9.5, 0.0)
	assert_vec_near(arrow.drawn_position, arrow.position_at(9.5 - 2.0), 0.0001,
			"6 ticks later it follows the server's trajectory")
	# DESPAWN 5 (expired): removed on its tick.
	world.on_despawn(700, SHOT_TICK + 40, NetProtocol.DespawnReason.EXPIRED)
	world.draw(SHOT_TICK + 39.9, 0.0)
	assert_eq(world.get_live_count(), 1)
	world.draw(SHOT_TICK + 40.0, 0.0)
	assert_eq(world.get_live_count(), 0, "expired, removed at despawn_tick")


func test_two_prediction_steps_in_one_physics_tick_still_fire_the_arrow() -> void:
	var quick: AttackTicks = CombatCatalog.attack(CombatCatalog.attack_id(&"bow_quick"))
	const PRESS_TICK: int = 40
	var commit: int = PRESS_TICK + quick.windup_ticks
	_pair = PredictionPair.new()
	var route := func(tick: int) -> PlayerInput:
		var input: PlayerInput = _look_input(tick)
		if tick == PRESS_TICK:
			input.buttons = PlayerInput.PRIMARY
		return input
	var combat: CombatState = CombatState.initial(CombatCatalog.rules(), CombatCatalog.weapon_id(&"bow"),
			CombatCatalog.weapon_id(&"sword_shield"), CombatState.pack_charges(2, 3))
	await _pair.build(tree, route, combat)
	var world := ProjectileWorld.new()
	world.install_visuals = false
	_nodes.append(world)
	world.setup(InterpolationClock.new(), null)
	world.set_local(OWN_ID, NetProtocol.Realm.VARDHEIM, ZONE, _pair.client, _pair.prediction, RTT_TICKS)
	while _pair.prediction.get_predicted_tick() < commit - 1:
		await tree.physics_frame
		_pair.frame()
	assert_eq(_pair.predicted(PRESS_TICK).combat.action, CombatState.Action.LIGHT,
			"the tap starts the quick shot")
	assert_eq(world.get_stats()["predicted"], 0, "nothing has left yet")
	# One physics tick with two steps (TickSync recovers lead time): the commitment falls on the first.
	await tree.physics_frame
	_pair.frame()
	_pair.prediction.step()
	var last: PlayerState = _pair.predicted(_pair.prediction.get_predicted_tick())
	assert_eq(_pair.prediction.get_predicted_tick(), commit + 1)
	assert_false(ActionMachine.is_commit_tick(last.combat, commit + 1),
			"the state at the end of the physics tick is no longer the commitment (looking at it that way would miss it)")
	assert_eq(world.get_stats()["predicted"], 1, "but the arrow is released, from the middle step")
	var arrow: ProjectileWorld.Arrow = world.get_arrows()[0]
	assert_eq(arrow.spawn_tick, commit, "on the commitment tick")
	assert_eq(arrow.source, _quick_source())
	assert_vec_near(arrow.p0, AimRay.muzzle(_pair.predicted(commit).position), 0.011,
			"from the character's chest on that tick")
	world.set_local(OWN_ID, NetProtocol.Realm.VARDHEIM, ZONE, null, null, RTT_TICKS)


func test_an_own_arrow_spawn_with_the_player_in_the_world_reaches_the_projectile_world() -> void:
	var client := NetClient.new()
	tree.root.add_child(client)
	_nodes.append(client)
	# Player already in the world (as after its own SPAWN).
	client._net_id = OWN_ID
	client._state = NetClient.State.IN_WORLD
	var world: ProjectileWorld = client.get_projectile_world()
	world.install_visuals = false
	world.set_local(OWN_ID, NetProtocol.Realm.VARDHEIM, ZONE, null, null, RTT_TICKS)
	var spawned: Array[NetMessages.EntitySpawn] = []
	client.projectile_spawned.connect(func(spawn: NetMessages.EntitySpawn) -> void: spawned.append(spawn))
	var state: PlayerState = _quick_shot_state(SHOT_TICK, Vector3.ZERO)
	world.on_stepped(SHOT_TICK, _look_input(SHOT_TICK), state)
	var predicted: ProjectileWorld.Arrow = world.get_arrows()[0]
	# The own arrow's SPAWN arrives over the network: is_yours goes to 0 and "own" is the owner.
	var spawn: NetMessages.EntitySpawn = _arrow_spawn(901, SHOT_TICK + 1, OWN_ID,
			NetProtocol.Realm.VARDHEIM, _quick_source(), predicted.p0, predicted.v0)
	client._on_packet_received(NetClient.SERVER_PEER_ID, spawn.encode())
	assert_eq(spawned.size(), 1, "it comes out through its signal")
	assert_null(client.get_character(), "it creates no local character")
	assert_eq(client.get_state(), NetClient.State.IN_WORLD)
	assert_eq(world.get_stats()["substituted"], 1, "replaces the predicted one")
	assert_eq(world.find_arrow(901), predicted)
	# Another own arrow with no predicted one (the client never got to predict it): the server's is drawn, at the
	# predicted time.
	var orphan: NetMessages.EntitySpawn = _arrow_spawn(902, SHOT_TICK + 30, OWN_ID,
			NetProtocol.Realm.VARDHEIM, _quick_source(), Vector3(0.0, 1.4, 0.0), Vector3(0.0, 0.0, -45.0))
	client._on_packet_received(NetClient.SERVER_PEER_ID, orphan.encode())
	assert_eq(world.get_stats()["own_from_server"], 1)
	var own: ProjectileWorld.Arrow = world.find_arrow(902)
	assert_true(own.predicted and own.confirmed, "drawn as own")
	world.draw(SHOT_TICK + 32.0, 50.0)
	assert_vec_near(own.drawn_position, own.position_at(2.0), 0.0001, "at the predicted time, not the render time")
	# Its DESPAWN also reaches the arrow world.
	client._on_packet_received(NetClient.SERVER_PEER_ID,
			_despawn(902, SHOT_TICK + 31, NetProtocol.DespawnReason.EXPIRED).encode())
	world.draw(SHOT_TICK + 32.0, 50.0)
	assert_null(world.find_arrow(902), "and it is removed")
	assert_eq(client.get_stats()["malformed_packets"], 0)


func test_a_remote_arrow_appears_at_its_render_tick_and_leaves_at_despawn_plus_fraction() -> void:
	var world: ProjectileWorld = _make_world(true)
	await wait_physics_frames(3)
	# At 40 m/s it travels 2/3 m per tick: segment 29 ([−19.33; −20.0]) crosses the wall face (z = −19.5)
	# at a quarter.
	var p0 := Vector3(0.0, 1.4, 0.0)
	var v0 := Vector3(0.0, 0.0, -40.0)
	world.on_spawn(_arrow_spawn(801, 100, ENEMY_ID, NetProtocol.Realm.SOLMARCH, _quick_source(), p0, v0))
	assert_eq(world.get_stats()["remote"], 1)
	var arrow: ProjectileWorld.Arrow = world.find_arrow(801)
	assert_false(arrow.predicted, "someone else's arrow runs on render time")
	world.draw(500.0, 99.5)
	assert_false(arrow.visible, "before its spawn_tick it is not seen")
	world.draw(500.0, 100.25)
	assert_true(arrow.visible, "on its tick, it is")
	assert_vec_near(arrow.drawn_position, Ballistics.position(arrow.p0, arrow.v0, arrow.gravity, 0.25),
			0.0001, "at pos(render_tick + fraction − spawn_tick)")
	world.draw(500.0, 120.0)
	assert_true(arrow.drawn_position.z > WALL_Z, "flies toward the wall")
	# The server says it hit the wall on tick 129 (segment 29).
	world.on_despawn(801, 129, NetProtocol.DespawnReason.IMPACT)
	assert_near(arrow.end_n, 29.25, 0.01, "the fraction of its own ray on the last segment")
	world.draw(500.0, 129.2)
	assert_eq(world.get_live_count(), 1, "it has not reached the wall yet")
	assert_near(arrow.drawn_position.z, -19.47, 0.02, "almost at the wall face")
	world.draw(500.0, 129.3)
	assert_eq(world.get_live_count(), 0, "removed on arrival: despawn_tick + f")
	# With nothing on the last segment, f = 1; and an expired one is removed at its despawn_tick.
	world.on_spawn(_arrow_spawn(802, 200, ENEMY_ID, NetProtocol.Realm.SOLMARCH, _quick_source(),
			Vector3(0.0, 1.4, 0.0), Vector3(0.0, 5.0, 40.0)))
	world.on_despawn(802, 210, NetProtocol.DespawnReason.IMPACT)
	assert_near(world.find_arrow(802).end_n, 11.0, 0.0001, "with nothing to hit, at the end of the segment")
	world.on_spawn(_arrow_spawn(803, 200, ENEMY_ID, NetProtocol.Realm.SOLMARCH, _quick_source(),
			Vector3(0.0, 1.4, 0.0), Vector3(0.0, 5.0, 40.0)))
	world.on_despawn(803, 260, NetProtocol.DespawnReason.EXPIRED)
	world.draw(500.0, 259.9)
	assert_not_null(world.find_arrow(803))
	world.draw(500.0, 260.0)
	assert_null(world.find_arrow(803), "expired: at despawn_tick")


func test_an_own_arrow_sticks_in_the_wall_hides_in_an_enemy_and_is_retired_without_a_spawn() -> void:
	var world: ProjectileWorld = _make_world(true)
	await wait_physics_frames(3)
	# Toward the wall: looking at −Z, the crosshair hits the wall and the arrow sticks into it.
	world.on_stepped(SHOT_TICK, _look_input(SHOT_TICK), _quick_shot_state(SHOT_TICK, Vector3.ZERO))
	var arrow: ProjectileWorld.Arrow = world.get_arrows()[0]
	world.draw(SHOT_TICK + 35.0, 0.0)
	assert_true(arrow.stuck_n > 0.0, "sticks into the wall with its own ray (n = %.2f)" % arrow.stuck_n)
	assert_near(arrow.drawn_position.z, WALL_Z + 0.5, 0.05, "at the wall face")
	world.draw(SHOT_TICK + 38.0, 0.0)
	assert_near(arrow.drawn_position.z, WALL_Z + 0.5, 0.05, "and stays there")
	assert_eq(world.get_stats()["stuck"], 1)
	# Without a SPAWN within rtt + 30 ticks: the server rejected it.
	world.draw(float(SHOT_TICK + RTT_TICKS + ProjectileWorld.REJECT_EXTRA_TICKS) + 0.5, 0.0)
	assert_eq(world.get_live_count(), 0, "a predicted arrow without a SPAWN is removed")
	assert_eq(world.get_stats()["rejected"], 1)
	# At a drawn enemy 10 m away: the arrow is hidden when it touches its capsule (no number: the HIT provides it).
	var remote: RemoteWorld = world._remote_world
	remote.on_spawn(_enemy_spawn(ENEMY_ID, Vector3(0.0, 0.0, -10.0)))
	remote.draw(50.0, 0.0)
	assert_true(remote.get_view(ENEMY_ID).is_drawn())
	# The crosshair, over its center (the camera sits 0.6 m to the right: looking straight ahead would pass beside it).
	var look: Vector2 = AimRay.look_for(Vector3.ZERO, Vector3(0.0, 0.9, -10.0), false)
	world.on_stepped(SHOT_TICK + 100, _look_input(SHOT_TICK + 100, look.x, look.y),
			_quick_shot_state(SHOT_TICK + 100, Vector3.ZERO))
	var hidden: ProjectileWorld.Arrow = world.get_arrows()[0]
	world.draw(SHOT_TICK + 100.0 + 8.0, 0.0)
	assert_true(hidden.visible, "it is visible before arriving")
	world.draw(SHOT_TICK + 100.0 + 16.0, 0.0)
	assert_false(hidden.visible, "it is hidden on touching the enemy's capsule")
	assert_true(hidden.hidden_n > 11.0 and hidden.hidden_n < 14.0,
			"at about 9.6 m (n = %.2f)" % hidden.hidden_n)
	assert_eq(world.get_stats()["hidden"], 1)


# --- H5 review --------------------------------------------------------------------------------

func test_a_remote_arrow_that_sticks_at_its_origin_inside_a_closed_gate_never_crosses_it() -> void:
	var world: ProjectileWorld = _make_world(false)
	# A 2×3×2 m view body at the origin (like the closed door's doorway): the arrow comes out from inside.
	_add_box(world.get_parent(), Vector3(0.0, 1.5, 0.0), Vector3(2.0, 3.0, 2.0))
	await wait_physics_frames(3)
	world.on_spawn(_arrow_spawn(811, 400, ENEMY_ID, NetProtocol.Realm.SOLMARCH, _quick_source(),
			Vector3(0.0, 1.4, 0.0), Vector3(0.0, 0.0, -45.0)))
	var arrow: ProjectileWorld.Arrow = world.find_arrow(811)
	# The server tests the first segment with hit_from_inside: DESPAWN 4 on the shot's tick, fraction 0.
	world.on_despawn(811, 400, NetProtocol.DespawnReason.IMPACT)
	assert_near(arrow.end_n, 0.0, 0.0001, "sticks at its origin, as on the server (before, 1: a whole tick)")
	world.draw(500.0, 399.5)
	assert_eq(world.get_live_count(), 1, "before its tick it has not left yet")
	assert_false(arrow.visible)
	world.draw(500.0, 400.5)
	assert_eq(world.get_live_count(), 0, "and it is never seen on the other side of the closed door")


func test_a_remote_arrow_fraction_ignores_the_shooters_allies_even_without_the_shooters_view() -> void:
	var world: ProjectileWorld = _make_world(false)
	await wait_physics_frames(2)
	var remote: RemoteWorld = world._remote_world
	# An ally of the shooter (Solmarch) 10 m away on the trajectory; the shooter (77, Solmarch) has no view: it already left
	# this client's interest with its arrow in the air.
	remote.on_spawn(_enemy_spawn(78, Vector3(0.0, 0.0, -10.0), NetProtocol.Realm.SOLMARCH))
	remote.draw(50.0, 0.0)
	assert_true(remote.get_view(78).is_drawn())
	assert_null(remote.get_view(ENEMY_ID), "without the shooter's view")
	world.on_spawn(_arrow_spawn(821, 100, ENEMY_ID, NetProtocol.Realm.SOLMARCH, _quick_source(),
			Vector3(0.0, 1.4, 0.0), Vector3(0.0, 0.0, -45.0)))
	assert_eq(world.find_arrow(821).realm, NetProtocol.Realm.SOLMARCH, "the arrow keeps the SPAWN's realm")
	# The server says it hit something on tick 113 (beyond the ally): segment 13 does not stop it.
	world.on_despawn(821, 113, NetProtocol.DespawnReason.IMPACT)
	assert_near(world.find_arrow(821).end_n, 14.0, 0.0001,
			"the shooter's ally does not count (before, with the Hollow's realm 0, 13)")
	# Control: an enemy of the shooter (Vardheim) in the same spot does stop it.
	remote.on_spawn(_enemy_spawn(79, Vector3(0.0, 0.0, -10.0), NetProtocol.Realm.VARDHEIM))
	remote.draw(50.0, 0.0)
	world.on_spawn(_arrow_spawn(822, 100, ENEMY_ID, NetProtocol.Realm.SOLMARCH, _quick_source(),
			Vector3(0.0, 1.4, 0.0), Vector3(0.0, 0.0, -45.0)))
	world.on_despawn(822, 113, NetProtocol.DespawnReason.IMPACT)
	assert_true(world.find_arrow(822).end_n < 14.0,
			"an enemy of the shooter on the last segment stops it (n = %.2f)" % world.find_arrow(822).end_n)


func test_a_predicted_arrow_is_judged_against_the_servers_tick_not_the_rtt_at_entry() -> void:
	var world: ProjectileWorld = _make_world(false)
	await wait_physics_frames(2)
	# RTT of 3 ticks on entering; afterwards latency rises and prediction runs 45 ticks ahead of the server.
	world.set_local(OWN_ID, NetProtocol.Realm.VARDHEIM, ZONE, null, null, 3)
	world.on_stepped(SHOT_TICK, _look_input(SHOT_TICK), _quick_shot_state(SHOT_TICK, Vector3.ZERO))
	var predicted: ProjectileWorld.Arrow = world.get_arrows()[0]
	world.on_server_tick(SHOT_TICK + 34 - 45)
	world.draw(SHOT_TICK + 34.0, 0.0)
	assert_eq(world.get_stats()["rejected"], 0,
			"with the server 11 ticks behind its tick it is not rejected (before: 34 > 3 + 30)")
	assert_eq(world.get_live_count(), 1)
	world.on_server_tick(SHOT_TICK)
	world.draw(SHOT_TICK + 45.0, 0.0)
	world.on_spawn(_arrow_spawn(831, SHOT_TICK, OWN_ID, NetProtocol.Realm.VARDHEIM, _quick_source(),
			predicted.p0, predicted.v0))
	assert_eq(world.get_stats()["substituted"], 1, "the SPAWN arrives 45 ticks later and replaces it")
	assert_eq(world.get_stats()["own_from_server"], 0, "without disappearing and being released again")
	# Another one without a SPAWN: removed when the server passes its tick plus the input buffer and the margin.
	var later: int = SHOT_TICK + 300
	world.on_stepped(later, _look_input(later), _quick_shot_state(later, Vector3.ZERO))
	var limit: int = later + CombatCatalog.rules().input_buffer_ticks + ProjectileWorld.REJECT_EXTRA_TICKS
	world.on_server_tick(limit)
	world.draw(float(limit + 45), 0.0)
	assert_eq(world.get_stats()["rejected"], 0, "with the server right at the limit, not yet")
	world.on_server_tick(limit + 1)
	world.draw(float(limit + 46), 0.0)
	assert_eq(world.get_stats()["rejected"], 1, "one more tick and the server would have sent it already: rejected")
	world.clear()


func _enemy_spawn(net_id: int, feet: Vector3, realm: int = NetProtocol.Realm.SOLMARCH) -> NetMessages.EntitySpawn:
	var spawn := NetMessages.EntitySpawn.new()
	spawn.net_id = net_id
	spawn.kind = NetProtocol.EntityKind.PLAYER
	spawn.spawn_tick = 10
	spawn.realm = realm
	spawn.display_name = "Bruno"
	var state := PlayerState.new()
	state.position = feet
	state.grounded = true
	spawn.state = state
	return spawn


func _despawn(net_id: int, tick: int, reason: int) -> NetMessages.EntityDespawn:
	var despawn := NetMessages.EntityDespawn.new()
	despawn.net_id = net_id
	despawn.despawn_tick = tick
	despawn.reason = reason
	return despawn
