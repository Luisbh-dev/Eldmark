extends TestCase
## The server's projectiles (docs/habilidades.md, section 4.4; package H3b, CMB-22): no arrow
## goes through a wall (40 shots at different angles at a target behind it), a shot hugging a
## corner hits the corner even if the camera sees the target, from the closed door's doorway the arrow
## sticks at the origin, a frontal shield blocks it (never parries it), a dodge lets it pass, the shield-wall
## box stops arrows coming head-on at whoever is behind it (from far away and with the
## archer inside it) and not those from an archer behind the one holding it (nor those reaching the one
## holding it in their realm's safe zone), a segment that starts
## inside a capsule hits at point-blank range, the caps (8 per shooter, 64 per zone) remove the oldest and the
## new shot exists, a shooter who leaves takes their arrows with them (DESPAWN 5) and an arrow hits the
## door with its piercing part. Also: flight against rewound positions (and the control without
## rewinding, in the same run), a rejected rewind and the safe zone give harmless arrows, the
## fan, the draw charge, the weighted arrow, the interruption, ballistics equal to the SPAWN's,
## expiry, the server's arrow equal to the one the client predicts ([ProjectileLaunch]), a fake
## archer in a [ZoneServer] and the SPAWN and DESPAWN that reach the client that sees the shooter over the network.
## [br][br]
## The short ones set up the fighters by hand and advance the [CombatDirector] tick by tick (like
## test_ability_server); the server ones advance a network-less [ZoneServer] with [code]_physics_process[/code];
## the network one uses ENet on 127.0.0.1 ([NetHarness]).

const VARDHEIM: int = NetProtocol.Realm.VARDHEIM
const SOLMARCH: int = NetProtocol.Realm.SOLMARCH
const ZONE_ID: StringName = &"test_world"
const S: int = 400
const HIT: int = NetMessages.EntityEvent.Kind.HIT
const IMPACT: int = NetProtocol.DespawnReason.IMPACT
const EXPIRED: int = NetProtocol.DespawnReason.EXPIRED
const GATE_SCENE: String = "res://scenes/world/props/fort/fort_gate.tscn"
const TICK_DELTA: float = 1.0 / 60.0
## Center of a target's body (above the feet), which is what is aimed at.
const CENTER: Vector3 = Vector3(0.0, 0.9, 0.0)
const WAIT_FRAMES: int = 900

var _viewport: SubViewport
var _world: Node3D
var _history: StateHistory
var _safe_areas: SafeAreas
var _director: CombatDirector
var _events: Array[NetMessages.EntityEvent] = []
var _spawns: Array[NetMessages.EntitySpawn] = []
## Kills: [code]{id, tick, reason}[/code].
var _despawns: Array[Dictionary] = []
# The tests' server with ZoneServer (null in the others) and what the network test uses.
var _server: ZoneServer = null
var _server_viewport: SubViewport = null
var _client_viewport: SubViewport = null
var _client: NetClient = null
# The network test's server has a transport: it is freed with its viewport, without stop().
var _server_has_transport: bool = false


func before_each() -> void:
	_viewport = CombatFixture.make_world(tree.root)
	_world = NetHarness.get_world(_viewport)
	_history = StateHistory.new()
	_safe_areas = SafeAreas.new()
	_director = CombatDirector.new(_history, ZONE_ID, _world, _safe_areas, CombatFixture.place,
			func(realm: int) -> Transform3D:
				return Transform3D(Basis.IDENTITY, Vector3(100.0 + float(realm), 0.0, 100.0)))
	_events.clear()
	_spawns.clear()
	_despawns.clear()
	_director.event_emitted.connect(func(event: NetMessages.EntityEvent,
			_involved: PackedInt32Array) -> void: _events.append(event))
	_watch(_director.projectiles)
	await wait_physics_frames(3)


func after_each() -> void:
	_director = null
	if is_instance_valid(_client_viewport):
		_client_viewport.free()
	_client_viewport = null
	_client = null
	if is_instance_valid(_server) and not _server_has_transport:
		_server.stop()
		_server.free()
	_server = null
	_server_has_transport = false
	for viewport: SubViewport in [_viewport, _server_viewport]:
		if is_instance_valid(viewport):
			viewport.get_parent().remove_child(viewport)
			viewport.free()
	_viewport = null
	_server_viewport = null
	_world = null
	await wait_process_frames()


# --- Helpers ----------------------------------------------------------------------------------

func _watch(system: ProjectileSystem) -> void:
	system.spawned.connect(func(spawn: NetMessages.EntitySpawn, _recipients: PackedInt32Array) -> void:
		_spawns.append(spawn))
	system.despawned.connect(func(projectile_id: int, tick: int, reason: int,
			_recipients: PackedInt32Array) -> void:
		_despawns.append({"id": projectile_id, "tick": tick, "reason": reason}))


func _space() -> PhysicsDirectSpaceState3D:
	return _world.get_world_3d().direct_space_state


func _body(net_id: int, realm: int, position: Vector3, yaw: float, peer: ServerPeer = null) -> Combatant:
	var entity: NetEntity = CombatFixture.make_entity(_world, net_id, realm, position, yaw)
	_history.add_entity(net_id)
	return _director.add(entity, CombatFixture.make_queue(yaw), peer)


func _tick(s: int) -> void:
	_director.process_tick(s, _space())


func _run(from: int, to: int) -> void:
	for tick: int in range(from, to):
		_tick(tick)


## A static world box (layer 1) centered at [param center] with size [param size].
func _add_box(center: Vector3, size: Vector3) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.collision_layer = PlayerCharacter.WORLD_COLLISION_LAYER
	body.collision_mask = 0
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = size
	shape.shape = box
	body.add_child(shape)
	_world.add_child(body)
	body.global_position = center
	return body


## Leaves in [param fighter]'s queue the input simulated at [param s] with the camera toward [param point]
## (the canonical ray passes through it) and [param view_offset] ticks of view behind.
func _aim(fighter: Combatant, s: int, point: Vector3, left: bool = false, view_offset: int = 0) -> void:
	var look: Vector2 = AimRay.look_for(fighter.entity.get_position(), point, left)
	var input := PlayerInput.new()
	input.tick = s
	input.look_yaw = look.x
	input.look_pitch = look.y
	if left:
		input.buttons = PlayerInput.AIM_LEFT
	fighter.queue.reset(s - 1, NetProtocol.neutral_input(s - 1, look.x))
	fighter.queue.push(input.quantized(), view_offset * CombatResolver.VIEW_OFFSET_Q_SCALE, s)
	fighter.queue.take(s)


## Puts [param shooter] with the bow at the commitment (the first active tick) of attack
## [param attack_name] on tick [param s], aiming at [param point], with [param charge_ticks] of charge if
## it is the draw.
func _shoot(shooter: Combatant, attack_name: StringName, s: int, point: Vector3, charge_ticks: int = 0,
		view_offset: int = 0, left: bool = false) -> void:
	var attack: AttackTicks = CombatCatalog.attack(CombatCatalog.attack_id(attack_name))
	assert_not_null(attack, "attack %s exists" % attack_name)
	var combat: CombatState = shooter.get_character().combat
	combat.weapon_id = CombatCatalog.weapon_id(&"bow")
	combat.action = CombatState.Action.HEAVY if attack.heavy else CombatState.Action.LIGHT
	combat.action_id = attack.id
	combat.action_tick = s - attack.windup_ticks
	combat.charge_ticks = charge_ticks
	_aim(shooter, s, point, left, view_offset)


## The same with ability [param ability_name] (its commitment is the first active tick).
func _cast(shooter: Combatant, ability_name: StringName, s: int, point: Vector3) -> AbilityTicks:
	var ability: AbilityTicks = CombatCatalog.ability(CombatCatalog.ability_id(ability_name))
	assert_not_null(ability, "ability %s exists" % ability_name)
	var combat: CombatState = shooter.get_character().combat
	combat.weapon_id = CombatCatalog.weapon_id(&"bow")
	combat.action = CombatState.Action.ABILITY
	combat.action_id = ability.id
	combat.action_tick = s - ability.cast_ticks
	_aim(shooter, s, point)
	return ability


## The point a bot aims at so that the arrow leaving the chest of whoever has their feet at
## [param feet] at [param speed] m/s reaches [param target] despite the drop ([method Ballistics.solve_lead]).
func _over_drop(feet: Vector3, target: Vector3, speed: float) -> Vector3:
	var muzzle: Vector3 = AimRay.muzzle(feet)
	var arrow: ProjectileTicks = CombatCatalog.projectile(CombatCatalog.projectile_id(&"arrow"))
	return muzzle + Ballistics.solve_lead(muzzle, target, Vector3.ZERO, speed, arrow.gravity) \
			* muzzle.distance_to(target)


func _center_of(fighter: Combatant) -> Vector3:
	return fighter.entity.get_position() + CENTER


func _hits_on(net_id: int, events: Array[NetMessages.EntityEvent] = _events) -> Array[NetMessages.EntityEvent]:
	var found: Array[NetMessages.EntityEvent] = []
	for event: NetMessages.EntityEvent in events:
		if event.event == HIT and event.net_id == net_id:
			found.append(event)
	return found


func _spawns_of(owner_id: int) -> Array[NetMessages.EntitySpawn]:
	var found: Array[NetMessages.EntitySpawn] = []
	for spawn: NetMessages.EntitySpawn in _spawns:
		if spawn.owner_id == owner_id:
			found.append(spawn)
	return found


func _despawn_of(projectile_id: int) -> Dictionary:
	for despawn: Dictionary in _despawns:
		if despawn["id"] == projectile_id:
			return despawn
	return {}


## Position of the arrow of SPAWN [param spawn] after [param ticks] ticks of flight.
func _arrow_at(spawn: NetMessages.EntitySpawn, ticks: float) -> Vector3:
	var definition: ProjectileTicks = CombatCatalog.projectile(spawn.projectile_def_id)
	return Ballistics.position(spawn.origin, spawn.velocity, definition.gravity, ticks)


## The segment in which arrow [param spawn] ended: [code][pos(n), pos(n + 1)][/code] with
## [code]n = despawn_tick − spawn_tick[/code].
func _last_segment(spawn: NetMessages.EntitySpawn) -> Array[Vector3]:
	var despawn: Dictionary = _despawn_of(spawn.net_id)
	var flown: int = int(despawn.get("tick", spawn.spawn_tick)) - spawn.spawn_tick
	return [_arrow_at(spawn, float(flown)), _arrow_at(spawn, float(flown + 1))]


# --- Walls and corners ------------------------------------------------------------------------

func test_no_arrow_goes_through_a_wall() -> void:
	# A wall 40 x 8 m and 0.5 thick at 10 m (front face at z = -9.75) and the target 15 m behind it.
	var wall: StaticBody3D = _add_box(Vector3(0.0, 4.0, -10.0), Vector3(40.0, 8.0, 0.5))
	await wait_physics_frames(2)
	var archer: Combatant = _body(1, VARDHEIM, Vector3.ZERO, 0.0)
	var target: Combatant = _body(2, SOLMARCH, Vector3(0.0, 0.0, -15.0), PI)
	assert_false(HitShapes.has_line_of_sight(_space(), Vector3.ZERO, target.entity.get_position()),
			"the wall covers the target")
	for shot: int in 40:
		# 8 lateral offsets by 5 heights around the target: different angles, all against the wall.
		@warning_ignore("integer_division")
		var offset := Vector3((float(shot % 8) - 3.5) * 0.8, float(shot / 8) * 0.7 - 0.8, 0.0)
		var s: int = S + shot * 20
		_shoot(archer, &"bow_quick", s, _center_of(target) + offset)
		_run(s, s + 20)
	assert_eq(_spawns.size(), 40, "40 arrows")
	assert_eq(_hits_on(2).size(), 0, "none goes through the wall")
	assert_eq(target.health, 1000)
	var at_the_wall: int = 0
	for spawn: NetMessages.EntitySpawn in _spawns:
		var despawn: Dictionary = _despawn_of(spawn.net_id)
		if despawn.get("reason", -1) != IMPACT:
			continue
		var segment: Array[Vector3] = _last_segment(spawn)
		if segment[0].z >= -9.75 - 0.001 and segment[1].z <= -9.75 + 0.001:
			at_the_wall += 1
	assert_eq(at_the_wall, 40, "all end with DESPAWN 4 on the segment that crosses the wall face")
	assert_eq(_director.projectiles.live_count(), 0)
	# Control in the same run: without the wall, the same shot at the target's center hits.
	wall.collision_layer = 0
	await wait_physics_frames(2)
	_shoot(archer, &"bow_quick", S + 1000, _center_of(target))
	_run(S + 1000, S + 1030)
	assert_eq(_hits_on(2).size(), 1, "without the wall, the arrow hits the target")


func test_a_shot_pressed_against_a_corner_hits_the_corner() -> void:
	# A wall on the left up ahead (x from -10 to 0.3; z from -3 to -2): the chest (x = 0) sits behind its
	# corner and the camera (right shoulder, x = 0.6) sees beyond.
	_add_box(Vector3(-4.85, 2.0, -2.5), Vector3(10.3, 4.0, 1.0))
	await wait_physics_frames(2)
	var archer: Combatant = _body(1, VARDHEIM, Vector3.ZERO, 0.0)
	var target: Combatant = _body(2, SOLMARCH, Vector3(0.6, 0.0, -15.0), PI)
	var look: Vector2 = AimRay.look_for(Vector3.ZERO, _center_of(target), false)
	var camera: Vector3 = AimRay.canonical(Vector3.ZERO, look.x, look.y, false)[0]
	assert_true(HitShapes.is_ray_clear(_space(), camera, _center_of(target)), "the camera sees the target")
	assert_false(HitShapes.is_ray_clear(_space(), AimRay.muzzle(Vector3.ZERO), _center_of(target)),
			"the chest does not")
	_shoot(archer, &"bow_quick", S, _center_of(target))
	_run(S, S + 40)
	assert_eq(_hits_on(2).size(), 0, "the arrow does not leave on the camera's side")
	if not assert_eq(_spawns.size(), 1):
		return
	var despawn: Dictionary = _despawn_of(_spawns[0].net_id)
	assert_eq(despawn.get("reason", -1), IMPACT, "it sticks")
	var segment: Array[Vector3] = _last_segment(_spawns[0])
	assert_true(segment[0].z >= -2.0 - 0.001 and segment[1].z <= -2.0 + 0.001,
			"in the corner's face (z = -2): %s" % [segment])
	assert_true(segment[0].x < 0.3, "on the chest's side")


func test_from_inside_a_closed_gate_the_arrow_sticks_at_its_origin() -> void:
	var gate: FortGate = (load(GATE_SCENE) as PackedScene).instantiate() as FortGate
	_world.add_child(gate)
	gate.set_state(VARDHEIM, false)
	await wait_physics_frames(2)
	# The owner with feet in the doorway (chest inside the 0.5 m view box) shoots west.
	var owner: Combatant = _body(1, VARDHEIM, Vector3(0.0, 0.0, 0.5), PI * 0.5)
	var enemy: Combatant = _body(2, SOLMARCH, Vector3(-6.0, 0.0, 0.5), -PI * 0.5)
	_shoot(owner, &"bow_quick", S, _center_of(enemy))
	_run(S, S + 20)
	assert_eq(_hits_on(2).size(), 0, "from the closed doorway one does not shoot outward")
	if not assert_eq(_spawns.size(), 1):
		return
	assert_eq(_despawn_of(_spawns[0].net_id), {"id": _spawns[0].net_id, "tick": S, "reason": IMPACT},
			"DESPAWN 4 on the shot's tick: it sticks at the origin")
	assert_vec_near(_spawns[0].origin, Vector3(0.0, 1.4, 0.5), 0.011, "leaves from the chest, inside the box")
	# With the door broken there is no box: the arrow leaves.
	gate.set_state(VARDHEIM, true)
	await wait_physics_frames(2)
	_shoot(owner, &"bow_quick", S + 100, _center_of(enemy))
	_run(S + 100, S + 120)
	assert_eq(_hits_on(2).size(), 1, "broken, the arrow hits the enemy")


# --- Defenses ---------------------------------------------------------------------------------

func test_a_shield_in_front_blocks_an_arrow_and_never_parries_it() -> void:
	# Blocking facing the archer, with the parry window open when the arrow arrives.
	var archer: Combatant = _body(1, VARDHEIM, Vector3.ZERO, 0.0)
	var front: Combatant = _body(2, SOLMARCH, Vector3(0.0, 0.0, -2.0), PI)
	CombatFixture.start_block(front, S - 1, true)
	var stamina: int = front.get_character().combat.stamina
	_shoot(archer, &"bow_quick", S, _center_of(front))
	_run(S, S + 10)
	var hits: Array[NetMessages.EntityEvent] = _hits_on(2)
	if assert_eq(hits.size(), 1, "a HIT"):
		assert_true(hits[0].has_hit_flag(NetMessages.EntityEvent.HIT_FLAG_BLOCKED), "blocked")
		assert_false(hits[0].has_hit_flag(NetMessages.EntityEvent.HIT_FLAG_PARRIED), "never parried")
		assert_eq(hits[0].amount, 0, "the sword's shield mitigates everything")
		assert_eq(hits[0].get_source(), CombatCatalog.attack_id(&"bow_quick"), "with the shot's source")
		assert_true(hits[0].tick <= S + 3, "at 2 m it arrives right away")
	assert_eq(front.health, 1000)
	assert_eq(front.get_character().combat.stamina, stamina - 60, "1 stamina per point (the weapon's)")
	assert_eq(archer.get_character().combat.action, CombatState.Action.LIGHT, "the archer does not stagger")
	assert_eq(_director.stats[&"arrow_blocked"], 1, "log: arrow_blocked")
	# With its back to the archer, the same block does not stop it.
	var archer_2: Combatant = _body(3, VARDHEIM, Vector3(20.0, 0.0, 0.0), 0.0)
	var back: Combatant = _body(4, SOLMARCH, Vector3(20.0, 0.0, -6.0), 0.0)
	CombatFixture.start_block(back, S + 50)
	_shoot(archer_2, &"bow_quick", S + 100, _center_of(back))
	_run(S + 100, S + 120)
	var behind: Array[NetMessages.EntityEvent] = _hits_on(4)
	if assert_eq(behind.size(), 1, "from behind"):
		assert_false(behind[0].has_hit_flag(NetMessages.EntityEvent.HIT_FLAG_BLOCKED), "does not block")
		assert_eq(behind[0].amount, 60, "60 piercing, no crit")
		assert_eq(behind[0].damage_type, DamageFormula.DamageType.PIERCE)
	assert_eq(_director.stats[&"arrow_hits"], 1, "log: arrow_hit")


func test_a_dodge_lets_the_arrow_through_to_whoever_is_behind() -> void:
	var archer: Combatant = _body(1, VARDHEIM, Vector3.ZERO, 0.0)
	var dodger: Combatant = _body(2, SOLMARCH, Vector3(0.0, 0.0, -6.0), PI)
	# The one behind, far away: the camera's ray (0.6 m to the side) does not graze the one dodging and the crosshair converges on
	# the one behind; the line from the chest to it does cross the one dodging.
	var behind: Combatant = _body(3, SOLMARCH, Vector3(0.0, 0.0, -30.0), PI)
	# At 45 m/s the arrow travels 0.75 m per tick: it reaches the dodger around S + 7. Invulnerable from S + 3 to S + 18.
	CombatFixture.start_dodge(dodger, S)
	dodger.get_character().combat.weapon_id = CombatCatalog.weapon_id(&"sword_shield")
	# At 30 m the arrow drops 1.3 m: it is aimed above, like a bot (Ballistics.solve_lead).
	_shoot(archer, &"bow_quick", S, _over_drop(Vector3.ZERO, _center_of(behind), 45.0))
	_run(S, S + 50)
	assert_eq(_hits_on(2).size(), 0, "the dodge lets it pass")
	assert_eq(dodger.health, 1000)
	assert_eq(_director.stats[&"invulnerable"], 1, "once: it does not test it again")
	var hits: Array[NetMessages.EntityEvent] = _hits_on(3)
	if assert_eq(hits.size(), 1, "and it keeps flying to the one behind"):
		assert_eq(hits[0].amount, 60)


func test_the_shield_wall_box_stops_arrows_from_the_front_only() -> void:
	var wall: AbilityTicks = CombatCatalog.ability(CombatCatalog.ability_id(&"shield_wall"))
	var rules: CombatRules = CombatCatalog.rules()
	# The one holding the wall (Solmarch) looks at -Z; their ally is behind (at +Z).
	var holder: Combatant = _body(10, SOLMARCH, Vector3.ZERO, 0.0)
	var ally: Combatant = _body(11, SOLMARCH, Vector3(0.0, 0.0, 3.0), 0.0)
	holder.get_character().combat.action = CombatState.Action.ABILITY
	holder.get_character().combat.action_id = wall.id
	holder.get_character().combat.action_tick = S - wall.cast_ticks - 30
	var stamina: int = holder.get_character().combat.stamina
	# 1) From far away, head-on: the box stops the arrow aimed at the ally behind.
	var far: Combatant = _body(1, VARDHEIM, Vector3(0.0, 0.0, -20.0), PI)
	_shoot(far, &"bow_quick", S, _center_of(ally))
	_run(S, S + 40)
	assert_eq(_hits_on(11).size(), 0, "the ally behind does not receive the arrow")
	var blocked: Array[NetMessages.EntityEvent] = _hits_on(10)
	if assert_eq(blocked.size(), 1, "the one holding the wall blocks it"):
		assert_true(blocked[0].has_hit_flag(NetMessages.EntityEvent.HIT_FLAG_BLOCKED))
		assert_eq(blocked[0].amount, 0, "no damage")
	assert_eq(holder.health, 1000)
	assert_eq(holder.get_character().combat.stamina, stamina - roundi(60.0 * rules.ability_block_stamina_per_damage),
			"spends the wall's: 0.6 per point")
	assert_eq(holder.get_character().combat.action, CombatState.Action.ABILITY, "and stays on the wall")
	assert_eq(_director.stats[&"wall_blocked"], 1, "log: wall_blocked")
	if assert_eq(_spawns.size(), 1):
		# The box's front face (0.7 m ahead, 0.15 of half thickness, plus the arrow's radius).
		var face: float = -wall.wall_forward_m - wall.wall_half_extents.z - 0.05
		var segment: Array[Vector3] = _last_segment(_spawns[0])
		assert_true(segment[0].z <= face + 0.001 and segment[1].z >= face - 0.001,
				"ends at the box's face, in front of the one holding it: %s" % [segment])
	# 2) With the archer inside the box (0.7 m ahead, to one side), shooting toward the ally: it stops at
	# the origin.
	var inside: Combatant = _body(2, VARDHEIM, Vector3(0.8, 0.0, -0.7), PI)
	_spawns.clear()
	_shoot(inside, &"bow_quick", S + 100, _center_of(ally) + Vector3(0.8, 0.0, 0.0))
	_run(S + 100, S + 110)
	assert_eq(_hits_on(11).size(), 0, "not from inside the box either")
	assert_eq(_hits_on(10).size(), 2, "the one holding the wall blocks it")
	if assert_eq(_spawns.size(), 1):
		assert_eq(_despawn_of(_spawns[0].net_id).get("tick", -1), S + 100, "on the first segment")
	# 3) An archer behind the one holding it (to one side of their capsule) shoots freely at an ally in
	# front: the wall covers the front.
	var front_ally: Combatant = _body(12, SOLMARCH, Vector3(1.0, 0.0, -8.0), PI)
	var sneaky: Combatant = _body(3, VARDHEIM, Vector3(1.0, 0.0, 2.0), 0.0)
	_shoot(sneaky, &"bow_quick", S + 200, _center_of(front_ally))
	_run(S + 200, S + 220)
	assert_eq(_hits_on(12).size(), 1, "the arrow from behind goes through the box and hits the one in front")
	assert_eq(_hits_on(10).size(), 2, "no other wall block")
	# Control: without the wall (and with whoever held it off the line), the arrow from far away reaches the ally.
	holder.get_character().combat.action = CombatState.Action.NONE
	holder.entity.node.global_position = Vector3(6.0, 0.0, 0.0)
	_shoot(far, &"bow_quick", S + 300, _center_of(ally))
	_run(S + 300, S + 340)
	assert_eq(_hits_on(11).size(), 1, "control: without the wall the ally receives the arrow")


## Phase 4 review ("abilities" lens): the wall of someone in their realm's safe zone does not stop
## enemy arrows (they pass as through their capsule, which is not a candidate): with no stamina and with low health there is
## no blocked hit, no guard break, no damage, no knockdown, and no "in combat" for them or for the
## archer. Control: the same wall outside the safe zone does block it, with a guard break.
func test_the_shield_wall_inside_its_own_safe_area_lets_arrows_through() -> void:
	var wall: AbilityTicks = CombatCatalog.ability(CombatCatalog.ability_id(&"shield_wall"))
	_safe_areas.add(Vector3.ZERO, 5.0, SOLMARCH)
	var holder: Combatant = _body(10, SOLMARCH, Vector3.ZERO, 0.0)
	var outside: Combatant = _body(20, SOLMARCH, Vector3(30.0, 0.0, 0.0), 0.0)
	for fighter: Combatant in [holder, outside]:
		var combat: CombatState = fighter.get_character().combat
		combat.action = CombatState.Action.ABILITY
		combat.action_id = wall.id
		combat.action_tick = S - wall.cast_ticks - 30
		combat.stamina = 10
		fighter.health = 30
	var archer: Combatant = _body(1, VARDHEIM, Vector3(0.0, 0.0, -20.0), PI)
	_shoot(archer, &"bow_quick", S, _center_of(holder))
	_run(S, S + 40)
	assert_eq(_hits_on(10).size(), 0, "the arrow goes through the wall of someone in their safe zone")
	assert_true(holder.health >= 30, "no damage (in their safe zone they regenerate): %d" % holder.health)
	assert_true(holder.get_character().combat.stamina >= 10, "no stamina spent")
	assert_eq(holder.get_character().combat.action, CombatState.Action.ABILITY,
			"no guard break: still on the wall")
	assert_false(holder.is_in_combat(S + 40), "the one holding the wall does not end up in combat")
	assert_false(archer.is_in_combat(S + 40), "nor does the archer")
	assert_eq(_director.stats[&"wall_blocked"], 0, "log: no wall_blocked")
	if assert_eq(_spawns.size(), 1):
		assert_true(_despawn_of(_spawns[0].net_id).has("tick"), "the arrow keeps flying and sticks")
		var segment: Array[Vector3] = _last_segment(_spawns[0])
		assert_true(segment[1].z > 0.0, "beyond the one holding the wall: %s" % [segment])
	# Control: the same wall outside the safe zone blocks and, without stamina, the guard breaks.
	var far: Combatant = _body(2, VARDHEIM, Vector3(30.0, 0.0, -20.0), PI)
	_shoot(far, &"bow_quick", S + 100, _center_of(outside))
	_run(S + 100, S + 140)
	var blocked: Array[NetMessages.EntityEvent] = _hits_on(20)
	if assert_eq(blocked.size(), 1, "control: outside the safe zone the wall stops it"):
		assert_true(blocked[0].has_hit_flag(NetMessages.EntityEvent.HIT_FLAG_BLOCKED))
		assert_true(blocked[0].has_hit_flag(NetMessages.EntityEvent.HIT_FLAG_GUARD_BREAK),
				"control: without stamina, guard break")
	assert_true(outside.is_in_combat(S + 140), "control: ends up in combat")


func test_a_segment_that_starts_inside_a_capsule_hits_point_blank() -> void:
	# The enemy has moved on top of the archer (characters do not collide): its capsule contains the chest.
	var archer: Combatant = _body(1, VARDHEIM, Vector3.ZERO, 0.0)
	var hugger: Combatant = _body(2, SOLMARCH, Vector3(0.2, 0.0, 0.2), PI)
	# Even if it aims elsewhere (toward -Z, away).
	_shoot(archer, &"bow_quick", S, Vector3(0.0, 1.4, -30.0))
	_run(S, S + 5)
	var hits: Array[NetMessages.EntityEvent] = _hits_on(2)
	if assert_eq(hits.size(), 1, "at point-blank range"):
		assert_eq(hits[0].tick, S, "on the shot's tick")
		assert_eq(hits[0].amount, 60)
	if assert_eq(_spawns.size(), 1):
		assert_eq(_despawn_of(_spawns[0].net_id).get("tick", -1), S, "DESPAWN 4 on the first segment")


# --- Caps and kills ---------------------------------------------------------------------------

func test_with_eight_per_shooter_or_sixty_four_per_zone_the_oldest_leaves() -> void:
	var rules: CombatRules = CombatCatalog.rules()
	assert_eq([rules.max_projectiles_per_shooter, rules.max_projectiles_per_zone], [8, 64])
	var sky := Vector3(0.0, 300.0, -100.0)
	# Shooter cap: 9 consecutive shots at the sky; the ninth removes the first on that same tick.
	var archer: Combatant = _body(1, VARDHEIM, Vector3.ZERO, 0.0)
	for shot: int in 9:
		_shoot(archer, &"bow_quick", S + shot, sky)
		_tick(S + shot)
	assert_eq(_spawns.size(), 9, "nine shots, none rejected")
	assert_eq(_director.projectiles.live_count(), 8, "eight alive")
	assert_eq(_despawns, [{"id": _spawns[0].net_id, "tick": S + 8, "reason": EXPIRED}],
			"the oldest goes out with DESPAWN 5 on the ninth's tick")
	assert_not_null(_director.projectiles.get_projectile(_spawns[8].net_id), "the new shot exists")
	# Zone cap: seven more shooters with eight each (64 alive) and another one who shoots: the zone's oldest goes out (the
	# first shooter's second, from tick S + 1).
	var shooters: Array[Combatant] = []
	for index: int in 8:
		shooters.append(_body(20 + index, VARDHEIM, Vector3(float(index) * 3.0 + 5.0, 0.0, 0.0), 0.0))
	for round_index: int in 8:
		var s: int = S + 20 + round_index
		for index: int in 7:
			_shoot(shooters[index], &"bow_quick", s, sky)
		_tick(s)
	assert_eq(_director.projectiles.live_count(), 64, "64 in the zone")
	var oldest: int = _spawns[1].net_id
	assert_not_null(_director.projectiles.get_projectile(oldest))
	_despawns.clear()
	_shoot(shooters[7], &"bow_quick", S + 40, sky)
	_tick(S + 40)
	assert_eq(_director.projectiles.live_count(), 64, "it stays at the cap")
	assert_eq(_despawns, [{"id": oldest, "tick": S + 40, "reason": EXPIRED}],
			"the zone's oldest goes out with DESPAWN 5")
	assert_not_null(_director.projectiles.get_projectile(_spawns[_spawns.size() - 1].net_id),
			"and the new shot exists")
	assert_eq(_director.projectiles.stats[&"projectiles_evicted"], 2)
	assert_eq(_director.projectiles.registry.transient_count(), 64, "one id per live projectile")


func test_a_shooter_who_leaves_takes_his_arrows_with_despawn_5() -> void:
	var archer: Combatant = _body(1, VARDHEIM, Vector3.ZERO, 0.0)
	var other: Combatant = _body(2, VARDHEIM, Vector3(10.0, 0.0, 0.0), 0.0)
	for shot: int in 3:
		_shoot(archer, &"bow_quick", S + shot, Vector3(0.0, 200.0, -100.0))
		_tick(S + shot)
	_shoot(other, &"bow_quick", S + 3, Vector3(10.0, 200.0, -100.0))
	_tick(S + 3)
	assert_eq(_director.projectiles.live_count(), 4)
	_director.remove(1, S + 4)
	assert_eq(_director.projectiles.live_count(), 1, "only the other one's is left")
	assert_eq(_despawns.size(), 3, "their three arrows go out")
	for index: int in 3:
		assert_eq(_despawns[index], {"id": _spawns[index].net_id, "tick": S + 4, "reason": EXPIRED},
				"with DESPAWN 5 on the kill's tick")
	assert_false(_director.projectiles.registry.is_transient(_spawns[0].net_id), "their id goes back to quarantine")
	assert_true(_director.projectiles.registry.is_quarantined(_spawns[0].net_id, S + 4))


func test_the_sweep_never_drops_a_capsule_that_the_full_scan_would_touch() -> void:
	# 40 enemies spread over 60 x 60 m with 32 ticks of random history (one teleported: its swept
	# box is wide and goes apart), and 3000 random segments with 10 ticks of rewind: the culling (swept
	# boxes and x sweep) touches exactly the same ones as testing everyone's capsule.
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	var homes: Array[Vector3] = []
	for index: int in 40:
		var net_id: int = 10 + index
		var home := Vector3(rng.randf_range(-30.0, 30.0), 0.0, rng.randf_range(-30.0, 30.0))
		homes.append(home)
		var fighter: Combatant = _body(net_id, SOLMARCH, home, 0.0)
		for tick: int in range(S - 32, S):
			var position: Vector3 = home + Vector3(rng.randf_range(-3.0, 3.0), rng.randf_range(0.0, 1.0),
					rng.randf_range(-3.0, 3.0))
			if index == 0 and tick < S - 20:
				position += Vector3(40.0, 0.0, 0.0)
			_history.record(tick, net_id, position, 0.0, EntityRecord.FLAG_GROUNDED)
		fighter.freeze(S)
	var system: ProjectileSystem = _director.projectiles
	system.begin_tick(S, _director.get_sorted())
	var projectile := ProjectileSystem.Projectile.new()
	projectile.realm = VARDHEIM
	projectile.owner_id = 1
	projectile.rewind = 10
	projectile.definition = CombatCatalog.projectile(CombatCatalog.projectile_id(&"arrow"))
	var touched: int = 0
	var mismatches: int = 0
	for trial: int in 3000:
		# Two out of three near someone (from where they were 10 ticks ago); the rest, anywhere.
		var from := Vector3(rng.randf_range(-35.0, 75.0), rng.randf_range(-0.5, 3.0), rng.randf_range(-35.0, 35.0))
		if trial % 3 != 0:
			var seen: Vector3 = _history.position_at(10 + rng.randi_range(0, homes.size() - 1), S - 10)
			from = seen + Vector3(rng.randf_range(-1.2, 1.2), rng.randf_range(-0.5, 2.5), rng.randf_range(-1.2, 1.2))
		var to: Vector3 = from + Vector3(rng.randf_range(-1.2, 1.2), rng.randf_range(-0.3, 0.3),
				rng.randf_range(-1.2, 1.2))
		var swept: PackedInt32Array = system.touched_ids(projectile, from, to, S)
		var full: PackedInt32Array = system.touched_ids(projectile, from, to, S, true)
		if swept != full:
			mismatches += 1
		touched += full.size()
	assert_eq(mismatches, 0, "the culling changes nothing")
	assert_true(touched > 200, "and the test really hits someone (%d)" % touched)


# --- Door -------------------------------------------------------------------------------------

func test_an_arrow_hits_the_gate_with_its_piercing_share() -> void:
	FortressFixture.add_fortress(_world, FortressFixture.make_definition())
	var registry := NetEntityRegistry.new()
	var controller := FortressController.new()
	controller.setup(_world, registry, 0)
	_director.set_structure_targets(controller.get_structure_targets())
	_director.structure_hit.connect(controller.on_structure_hit)
	await wait_physics_frames(3)
	var state: FortressState = controller.get_fortress_state(FortressFixture.FORTRESS_ID)
	var gate_id: int = controller.get_net_id(FortressFixture.FORTRESS_ID)
	var target: StructureTarget = controller.get_structure_targets()[0]
	# A Vardheim archer 8 m from the door's west face (neutral and closed), looking east.
	var archer: Combatant = _body(11, VARDHEIM, target.box.origin + Vector3(-8.0, -target.box.origin.y, 0.0),
			-PI * 0.5)
	_shoot(archer, &"bow_quick", S, target.box.origin + Vector3(-1.0, 0.0, 0.0))
	_run(S, S + 20)
	var expected: int = roundi(60.0 * CombatCatalog.rules().structure_multiplier(DamageFormula.DamageType.PIERCE))
	assert_eq(expected, 12, "60 piercing × 0.2")
	var gate_hits: Array[NetMessages.EntityEvent] = _hits_on(gate_id)
	if assert_eq(gate_hits.size(), 1, "a HIT on the door"):
		assert_eq(gate_hits[0].amount, expected)
		assert_eq(gate_hits[0].attacker, 11)
		assert_eq(gate_hits[0].damage_type, DamageFormula.DamageType.PIERCE)
	assert_eq(state.gate_health, 900 - expected, "the door loses its health")
	assert_eq(_despawn_of(_spawns[0].net_id).get("reason", -1), IMPACT, "and the arrow sticks")
	# From its owner, the arrow sticks without doing anything to it.
	controller.set_owner(FortressFixture.FORTRESS_ID, VARDHEIM, S + 50)
	_shoot(archer, &"bow_quick", S + 100, target.box.origin + Vector3(-1.0, 0.0, 0.0))
	_run(S + 100, S + 120)
	assert_eq(_hits_on(gate_id).size(), 1, "the owner does not damage their door")
	assert_eq(_despawn_of(_spawns[1].net_id).get("reason", -1), IMPACT, "its arrow sticks into it")


# --- Rewind and harmless arrows ---------------------------------------------------------------

func test_the_arrow_flies_against_rewound_positions() -> void:
	# Two identical pairs 50 m apart: the target runs sideways at 6 m/s (0.1 m per tick) 15 m from the archer. Archer
	# A (with a peer) sees 10 ticks back; B does not rewind. Both aim where A sees the target when
	# the arrow arrives (~20 ticks): x(S + 20 − 10) = 1 m.
	var peer := ServerPeer.new(7)
	peer.rtt_ticks = 4
	peer.interp_delay_q = 48
	var archer_a: Combatant = _body(1, VARDHEIM, Vector3.ZERO, 0.0, peer)
	var runner_a: Combatant = _body(2, SOLMARCH, Vector3(0.0, 0.0, -15.0), PI)
	var archer_b: Combatant = _body(3, VARDHEIM, Vector3(50.0, 0.0, 0.0), 0.0)
	var runner_b: Combatant = _body(4, SOLMARCH, Vector3(50.0, 0.0, -15.0), PI)
	var place: Callable = func(tick: int) -> void:
		var x: float = 0.1 * float(tick - S)
		runner_a.entity.node.global_position = Vector3(x, 0.0, -15.0)
		runner_b.entity.node.global_position = Vector3(50.0 + x, 0.0, -15.0)
	for tick: int in range(S - 30, S):
		place.call(tick)
		for fighter: Combatant in _director.get_sorted():
			CombatFixture.record(_history, fighter, tick)
	place.call(S)
	_shoot(archer_a, &"bow_quick", S, Vector3(1.0, 0.9, -15.0), 0, 10)
	_shoot(archer_b, &"bow_quick", S, Vector3(51.0, 0.9, -15.0))
	for tick: int in range(S, S + 40):
		place.call(tick)
		_tick(tick)
		for fighter: Combatant in _director.get_sorted():
			CombatFixture.record(_history, fighter, tick)
	assert_eq(_spawns.size(), 2)
	var hits: Array[NetMessages.EntityEvent] = _hits_on(2)
	if assert_eq(hits.size(), 1, "with the 10-tick rewind the arrow hits where the archer saw the target"):
		assert_true(hits[0].tick >= S + 18 and hits[0].tick <= S + 21, "on arrival (%d)" % (hits[0].tick - S))
	assert_eq(_hits_on(4).size(), 0, "control without rewinding: against the present position it misses")
	assert_eq(peer.suspicion_score, 0, "a rewind within the cap is not suspicious")


func test_a_rejected_rewind_or_the_safe_area_make_a_harmless_arrow() -> void:
	var peer := ServerPeer.new(7)
	peer.rtt_ticks = 4
	peer.interp_delay_q = 48
	var cheat: Combatant = _body(1, VARDHEIM, Vector3.ZERO, 0.0, peer)
	var target: Combatant = _body(2, SOLMARCH, Vector3(0.0, 0.0, -8.0), PI)
	# 40 ticks of view behind, above the cap (12): harmless arrow.
	_shoot(cheat, &"bow_quick", S, _center_of(target), 0, 40)
	_run(S, S + 60)
	if assert_eq(_spawns.size(), 1):
		assert_true(_spawns[0].is_harmless(), "SPAWN with the harmless bit")
		assert_eq(_despawn_of(_spawns[0].net_id).get("reason", -1), IMPACT, "flies and hits the ground")
	assert_eq(_hits_on(2).size(), 0, "tests nobody")
	assert_eq(peer.suspicion_score, 1, "suspicion + 1")
	assert_eq(peer.rewind_rejects, 1)
	assert_eq(_director.stats[&"rewind_rejected"], 1, "and a log line")
	# From the safe zone of its realm, neither.
	_safe_areas.add(Vector3(30.0, 0.0, 0.0), 5.0, VARDHEIM)
	var camper: Combatant = _body(3, VARDHEIM, Vector3(30.0, 0.0, 0.0), 0.0)
	var outside: Combatant = _body(4, SOLMARCH, Vector3(30.0, 0.0, -8.0), PI)
	_shoot(camper, &"bow_quick", S + 100, _center_of(outside))
	_run(S + 100, S + 120)
	if assert_eq(_spawns.size(), 2):
		assert_true(_spawns[1].is_harmless(), "from the safe zone, harmless")
	assert_eq(_hits_on(4).size(), 0)
	assert_eq(_director.projectiles.stats[&"projectiles_harmless"], 2)


## Phase 4 review ("cheats" lens): the arrow of an honest player who shoots on a delayed frame (seven extra
## physics steps over the cap + 1 from before) is trimmed to the cap and is neither harmless nor adds suspicion.
func test_an_arrow_shot_in_a_late_frame_is_clamped_to_the_cap_not_made_harmless() -> void:
	var peer := ServerPeer.new(7)
	peer.rtt_ticks = 4
	peer.interp_delay_q = 48
	var archer: Combatant = _body(1, VARDHEIM, Vector3.ZERO, 0.0, peer)
	var target: Combatant = _body(2, SOLMARCH, Vector3(0.0, 0.0, -8.0), PI)
	for tick: int in range(S - 30, S):
		for fighter: Combatant in _director.get_sorted():
			CombatFixture.record(_history, fighter, tick)
	var allowed: int = CombatResolver.allowed_rewind(peer.rtt_ticks, 0, peer.interp_delay_q)
	assert_eq(allowed, 12)
	_shoot(archer, &"bow_quick", S, _center_of(target), 0, allowed + 1 + 7)
	for tick: int in range(S, S + 30):
		_tick(tick)
		for fighter: Combatant in _director.get_sorted():
			CombatFixture.record(_history, fighter, tick)
	if assert_eq(_spawns.size(), 1):
		assert_false(_spawns[0].is_harmless(), "it is not harmless")
	assert_eq(_hits_on(2).size(), 1, "and it hits")
	assert_eq(peer.suspicion_score, 0, "no suspicion")
	assert_eq(peer.rewind_rejects, 0)
	assert_eq(_director.projectiles.stats[&"projectiles_harmless"], 0)


# --- Fan, charge, effects ---------------------------------------------------------------------

func test_the_volley_the_drawn_shot_and_the_slowing_shot() -> void:
	# Fan: three arrows at -7°, 0° and +7°, 55 damage each; one hit per shot.
	var peer := ServerPeer.new(9)
	var archer: Combatant = _body(1, VARDHEIM, Vector3.ZERO, 0.0, peer)
	var target: Combatant = _body(2, SOLMARCH, Vector3(0.0, 0.0, -10.0), PI)
	_cast(archer, &"bow_volley", S, _center_of(target))
	_run(S, S + 30)
	if assert_eq(_spawns.size(), 3, "three arrows"):
		var middle: Vector3 = _spawns[1].velocity
		for index: int in 3:
			assert_eq(_spawns[index].volley_index, index)
			assert_eq(_spawns[index].source, CombatSource.make(CombatSource.Kind.ABILITY,
					CombatCatalog.ability_id(&"bow_volley")), "with the ability's source")
			assert_near(_spawns[index].velocity.length(), 45.0, 0.02, "45 m/s")
		var left := Vector2(_spawns[0].velocity.x, _spawns[0].velocity.z)
		var right := Vector2(_spawns[2].velocity.x, _spawns[2].velocity.z)
		var center := Vector2(middle.x, middle.z)
		assert_near(rad_to_deg(absf(center.angle_to(left))), 7.0, 0.05, "at 7° to one side")
		assert_near(rad_to_deg(absf(center.angle_to(right))), 7.0, 0.05, "and to the other")
	var volley_hits: Array[NetMessages.EntityEvent] = _hits_on(2)
	if assert_eq(volley_hits.size(), 1, "at 10 m only the center one hits the capsule"):
		assert_eq(volley_hits[0].amount, 55)
	assert_eq(peer.swings_landed, 1, "one hit per shot")
	# Draw: minimum charge (21 ticks) 40 m/s and 90; maximum (60) 70 m/s and 180.
	_spawns.clear()
	_shoot(archer, &"bow_drawn", S + 100, _center_of(target), 21)
	_run(S + 100, S + 130)
	_shoot(archer, &"bow_drawn", S + 200, _center_of(target), 60)
	_run(S + 200, S + 230)
	if assert_eq(_spawns.size(), 2):
		assert_near(_spawns[0].velocity.length(), 40.0, 0.02, "minimum charge: 40 m/s")
		assert_near(_spawns[1].velocity.length(), 70.0, 0.02, "maximum charge: 70 m/s")
	var drawn: Array[NetMessages.EntityEvent] = _hits_on(2)
	if assert_eq(drawn.size(), 3):
		assert_eq([drawn[1].amount, drawn[2].amount], [90, 180], "90 → 180")
	# Weighted arrow: 60 and `slowed` on hit (the target's movement slot); interrupts whoever is drinking.
	var potion: AbilityTicks = CombatCatalog.ability(CombatCatalog.ability_id(&"potion_health"))
	var combat: CombatState = target.get_character().combat
	combat.consumable_charges = CombatState.pack_charges(3, 2)
	combat.action = CombatState.Action.ABILITY
	combat.action_id = potion.id
	combat.action_tick = S + 300
	_cast(archer, &"bow_slowing_shot", S + 300, _center_of(target))
	_run(S + 300, S + 330)
	var slowing: Array[NetMessages.EntityEvent] = _hits_on(2)
	if assert_eq(slowing.size(), 4):
		assert_eq(slowing[3].amount, 60)
		assert_true(slowing[3].has_hit_flag(NetMessages.EntityEvent.HIT_FLAG_INTERRUPTED), "interrupts drinking")
	assert_eq(combat.action, CombatState.Action.NONE, "stops drinking")
	assert_eq(combat.charges_of(0), 3, "without spending the charge")
	var slowed_id: int = CombatCatalog.status_id(&"slowed")
	assert_not_null(_director.status.find(target, slowed_id), "slowed")
	assert_true(combat.move_effect_ids.has(slowed_id), "with its movement slot")
	# Backflip with a shot: an arrow at 50 m/s at its commitment, with the ability's source.
	_spawns.clear()
	var evasive: AbilityTicks = _cast(archer, &"bow_evasive_shot", S + 400, _center_of(target))
	_run(S + 400, S + 430)
	if assert_eq(_spawns.size(), 1, "the backflip shoots"):
		assert_eq(_spawns[0].spawn_tick, S + 400, "at its commitment")
		assert_eq(_spawns[0].source, CombatSource.make(CombatSource.Kind.ABILITY, evasive.id))
		assert_near(_spawns[0].velocity.length(), 50.0, 0.02, "50 m/s")
	assert_eq(_hits_on(2).size(), 5, "y da")


func test_the_flight_is_the_ballistics_of_the_spawn_and_ends_when_it_expires() -> void:
	var archer: Combatant = _body(1, VARDHEIM, Vector3.ZERO, 0.0)
	var arrow: ProjectileTicks = CombatCatalog.projectile(CombatCatalog.projectile_id(&"arrow"))
	assert_eq(arrow.lifetime_ticks, 120, "2 s")
	# Toward the sky: nothing to hit in 2 s.
	_shoot(archer, &"bow_quick", S, Vector3(3.0, 400.0, -100.0))
	_tick(S)
	if not assert_eq(_spawns.size(), 1):
		return
	var spawn: NetMessages.EntitySpawn = _spawns[0]
	var projectile: ProjectileSystem.Projectile = _director.projectiles.get_projectile(spawn.net_id)
	assert_eq(spawn.kind, NetProtocol.EntityKind.PROJECTILE)
	assert_eq(spawn.spawn_tick, S)
	assert_eq(spawn.realm, VARDHEIM)
	assert_eq(spawn.owner_id, 1)
	assert_false(spawn.is_yours, "never is_yours")
	assert_eq(spawn.projectile_def_id, arrow.id)
	# What the server flies is the SPAWN's quantized values, and the same after encoding it.
	var decoded: NetMessages.EntitySpawn = NetMessages.EntitySpawn.decode(spawn.encode())
	assert_eq(decoded.origin, projectile.origin, "origin as it travels")
	assert_eq(decoded.velocity, projectile.velocity, "velocity as it travels")
	var quantized: Array = Ballistics.quantize(projectile.origin, projectile.velocity)
	assert_eq(quantized, [projectile.origin, projectile.velocity], "already quantized")
	assert_vec_near(projectile.origin, AimRay.muzzle(Vector3.ZERO), 0.01, "leaves from the chest")
	assert_eq(projectile.position_after(37.0), Ballistics.position(decoded.origin, decoded.velocity,
			arrow.gravity, 37.0), "the same Ballistics.position as the client")
	_run(S + 1, S + 125)
	assert_eq(_despawns, [{"id": spawn.net_id, "tick": S + arrow.lifetime_ticks - 1, "reason": EXPIRED}],
			"expires at n + 1 = lifetime_ticks, with DESPAWN 5")
	assert_eq(_director.projectiles.live_count(), 0)
	assert_eq(_director.projectiles.registry.transient_count(), 0)


func test_the_server_arrow_is_the_shared_launch_the_client_predicts() -> void:
	# The client's predicted arrow (ProjectileWorld) and the server's both come out of ProjectileLaunch: with the
	# same input, the same state and the same target for convergence, the SPAWN carries exactly what the
	# client predicts (source, fan index, quantized origin and velocity), also with the
	# left shoulder, the draw charge and the fan (merge of H3b and H4).
	var archer: Combatant = _body(1, VARDHEIM, Vector3.ZERO, 0.0)
	var target: Combatant = _body(2, SOLMARCH, Vector3(1.5, 0.0, -20.0), PI)
	var cases: Array[Dictionary] = [
		{"attack": &"bow_quick", "charge": 0, "left": false},
		{"attack": &"bow_drawn", "charge": 40, "left": true},
		{"ability": &"bow_volley"},
	]
	var tick: int = S
	for case: Dictionary in cases:
		_spawns.clear()
		var aim: Vector3 = _center_of(target) + Vector3(0.0, 0.4, 0.0)
		if case.has("ability"):
			_cast(archer, case["ability"], tick, aim)
		else:
			_shoot(archer, case["attack"], tick, aim, case["charge"], 0, case["left"])
		# What the client does in its commitment step (without rewinding: the target where it is).
		var launch: ProjectileLaunch = ProjectileLaunch.from_state(archer.get_character().combat, tick)
		var input: PlayerInput = archer.queue.get_applied(tick)
		if not assert_not_null(launch, "the commitment shoots") or not assert_not_null(input):
			return
		var predicted: Array[PackedVector3Array] = launch.launch(archer.entity.get_position(),
				input.look_yaw, input.look_pitch, input.has(PlayerInput.AIM_LEFT), _space(),
				PackedVector3Array([target.entity.get_position()]))
		_tick(tick)
		var label: String = str(case)
		if assert_eq(_spawns.size(), predicted.size(), "%s: as many arrows as predicted" % label):
			for index: int in predicted.size():
				var spawn: NetMessages.EntitySpawn = _spawns[index]
				assert_eq(spawn.source, launch.source, "%s: the same source" % label)
				assert_eq(spawn.volley_index, index, "%s: the same index" % label)
				assert_eq(spawn.origin, predicted[index][0], "%s: the same origin" % label)
				assert_eq(spawn.velocity, predicted[index][1], "%s: the same velocity" % label)
		_run(tick + 1, tick + 60)
		tick += 100


# --- Server -----------------------------------------------------------------------------------

## A network-less [ZoneServer] on a flat zone, advanced by hand.
func _start_server() -> void:
	_server_viewport = NetHarness.make_world_viewport(tree.root, "")
	_server = ZoneServer.new()
	_server.name = "ZoneServer"
	_server.log_enabled = false
	_server_viewport.add_child(_server)
	await wait_physics_frames(3)
	var config := ServerConfig.new()
	config.zone_id = String(ZONE_ID)
	config.no_dummies = true
	assert_eq(_server.start(config, NetHarness.get_world(_server_viewport), null, DevAuthProvider.new()), OK,
			"the server starts")
	_server.set_physics_process(false)


## A fake player of [param realm] at [param position] with the bow, whose inputs come from
## [param script] ([code](tick) -> PlayerInput[/code]).
func _fake_archer(realm: int, position: Vector3, yaw: float, script: Callable) -> int:
	var brain := CombatFixture.ScriptBrain.new(1)
	brain.script_fn = func(tick: int, _position: Vector3, _yaw: float) -> PlayerInput:
		return script.call(tick)
	var net_id: int = _server.add_fake_player(brain, realm)
	_server.teleport(net_id, position)
	var character: PlayerCharacter = _server.get_registry().get_entity(net_id).get_character()
	character.yaw = yaw
	character.combat.weapon_id = CombatCatalog.weapon_id(&"bow")
	CombatDirector.commit_state(character)
	return net_id


func _step(count: int) -> void:
	await tree.physics_frame
	for _i: int in count:
		_server._physics_process(TICK_DELTA)


func test_a_fake_archer_on_the_server_shoots_and_hits() -> void:
	await _start_server()
	var server_events: Array[NetMessages.EntityEvent] = []
	_server.get_combat().event_emitted.connect(func(event: NetMessages.EntityEvent,
			_involved: PackedInt32Array) -> void: server_events.append(event))
	_watch(_server.get_combat().projectiles)
	var target_id: int = _fake_archer(SOLMARCH, Vector3(0.0, 0.05, -12.0), PI, func(tick: int) -> PlayerInput:
		var input := PlayerInput.new()
		input.tick = tick
		input.look_yaw = PI
		return input)
	var press: int = _server.get_tick() + 10
	# A tap of PRIMARY with the camera toward the target's center: quick shot.
	var look: Vector2 = AimRay.look_for(Vector3(0.0, 0.0, 0.0), Vector3(0.0, 0.9, -12.0), false)
	var archer_id: int = _fake_archer(VARDHEIM, Vector3(0.0, 0.05, 0.0), 0.0, func(tick: int) -> PlayerInput:
		var input := PlayerInput.new()
		input.tick = tick
		input.look_yaw = look.x
		input.look_pitch = look.y
		if tick >= press and tick < press + 2:
			input.buttons = PlayerInput.PRIMARY
		return input)
	var spawned_alive: Array[bool] = []
	_server.get_combat().projectiles.spawned.connect(func(spawn: NetMessages.EntitySpawn,
			_recipients: PackedInt32Array) -> void:
		spawned_alive.append(_server.get_registry().is_transient(spawn.net_id)
				and _server.get_registry().get_entity(spawn.net_id) == null))
	await _step(70)
	if not assert_eq(_spawns.size(), 1, "one shot"):
		return
	assert_eq(spawned_alive, [true], "with a temporary id from the zone's registry, no entity")
	assert_eq(_spawns[0].owner_id, archer_id)
	assert_eq(_spawns[0].source, CombatCatalog.attack_id(&"bow_quick"))
	var hits: Array[NetMessages.EntityEvent] = _hits_on(target_id, server_events)
	if assert_eq(hits.size(), 1, "hits the target"):
		assert_eq(hits[0].amount, 60)
		assert_eq(hits[0].attacker, archer_id)
	assert_eq(_despawn_of(_spawns[0].net_id).get("reason", -1), IMPACT)
	assert_false(_server.get_registry().is_transient(_spawns[0].net_id), "its id goes back to quarantine")
	var report: Dictionary = _server._combat_report()
	assert_eq(int(report.get("projectiles_fired", -1)), 1, "the report counts the shots")
	assert_eq(int(report.get("arrow_hits", -1)), 1, "and the hits")
	# With arrows in the air, the fake player who leaves takes them with them (DESPAWN 5).
	_despawns.clear()
	var sky_press: int = _server.get_tick() + 5
	var sky_archer: int = _fake_archer(VARDHEIM, Vector3(20.0, 0.05, 0.0), 0.0, func(tick: int) -> PlayerInput:
		var input := PlayerInput.new()
		input.tick = tick
		input.look_pitch = 1.2
		if tick >= sky_press and tick < sky_press + 2:
			input.buttons = PlayerInput.PRIMARY
		return input)
	await _step(30)
	assert_eq(_server.get_combat().projectiles.live_count(), 1, "one arrow into the sky")
	assert_true(_server.remove_fake_player(sky_archer))
	await _step(1)
	assert_eq(_despawns.size(), 1, "leaves with its shooter")
	if not _despawns.is_empty():
		assert_eq(_despawns[0]["reason"], EXPIRED)
	assert_eq(_server.get_combat().projectiles.live_count(), 0)


# --- Network ----------------------------------------------------------------------------------

func test_the_client_that_sees_the_shooter_receives_the_spawn_and_the_despawn() -> void:
	var port: int = NetHarness.free_udp_port()
	_server_viewport = NetHarness.make_world_viewport(tree.root, "")
	var config := ServerConfig.new()
	config.port = port
	config.zone_id = String(ZONE_ID)
	config.max_players = 4
	config.no_dummies = true
	_server = NetHarness.start_server(_server_viewport, config)
	if not assert_not_null(_server, "the server listens"):
		return
	_server_has_transport = true
	await wait_physics_frames(3)
	_client_viewport = NetHarness.make_world_viewport(tree.root, "")
	_client = NetHarness.start_bot(_client_viewport, port, SOLMARCH, 3)
	var spawned: Array[NetMessages.EntitySpawn] = []
	var despawned: Array[Dictionary] = []
	_client.projectile_spawned.connect(func(spawn: NetMessages.EntitySpawn) -> void: spawned.append(spawn))
	_client.projectile_despawned.connect(func(projectile_id: int, tick: int, reason: int) -> void:
		despawned.append({"id": projectile_id, "tick": tick, "reason": reason}))
	var joined: bool = false
	for _i: int in WAIT_FRAMES:
		await tree.physics_frame
		if _client.get_net_id() > 0:
			joined = true
			break
	if not assert_true(joined, "the bot enters the world"):
		return
	# A fake archer of another realm shoots at the sky: the bot has it as relevant (the base policy sees everything).
	var press: Array[int] = [0]
	var brain := CombatFixture.ScriptBrain.new(2)
	brain.script_fn = func(tick: int, _position: Vector3, _yaw: float) -> PlayerInput:
		var input := PlayerInput.new()
		input.tick = tick
		input.look_pitch = 1.0
		if press[0] > 0 and tick >= press[0] and tick < press[0] + 2:
			input.buttons = PlayerInput.PRIMARY
		return input
	var archer: int = _server.add_fake_player(brain, VARDHEIM)
	var character: PlayerCharacter = _server.get_registry().get_entity(archer).get_character()
	character.combat.weapon_id = CombatCatalog.weapon_id(&"bow")
	CombatDirector.commit_state(character)
	var server_spawns: Array[int] = []
	_server.get_combat().projectiles.spawned.connect(func(spawn: NetMessages.EntitySpawn,
			_recipients: PackedInt32Array) -> void: server_spawns.append(spawn.net_id))
	press[0] = _server.get_tick() + 30
	var done: bool = false
	for _i: int in WAIT_FRAMES:
		await tree.physics_frame
		if not despawned.is_empty():
			done = true
			break
	if not assert_true(done, "the arrow's SPAWN and DESPAWN arrive"):
		return
	if assert_eq(spawned.size(), 1, "one SPAWN") and assert_eq(server_spawns.size(), 1):
		assert_eq(spawned[0].net_id, server_spawns[0], "the server arrow's")
		assert_eq(spawned[0].owner_id, archer, "with its shooter")
		assert_eq(spawned[0].kind, NetProtocol.EntityKind.PROJECTILE)
		assert_eq(despawned[0]["id"], server_spawns[0], "and its DESPAWN")
	assert_eq(despawned[0]["reason"], EXPIRED, "expires after 2 s in the air")
	assert_eq(int(_server._combat_report().get("projectile_messages_sent", -1)), 2, "two messages: spawn and despawn")
