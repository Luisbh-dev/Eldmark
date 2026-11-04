extends TestCase
## Tests for combat inside the [ZoneServer] (docs/combate.md, sections 4 to 7), without a network: fake
## players with input scripts in a [SubViewport] with its own physics world.
## [br][br]
## The whole pipe is checked (input -> simulation -> hit -> event -> published health), defense
## with the flag history, the fall (the 3 m walkway when jumping does no damage and 12
## m does), a lethal volume, death below y = -100 with automatic respawn, safe zones,
## the dummy (hitting it, it healing, and the combo's DPS matching the data), the NPCs in the
## loop, the combat log, the report, the console commands and the combat brain of
## the fake players.

const VARDHEIM: int = NetProtocol.Realm.VARDHEIM
const SOLMARCH: int = NetProtocol.Realm.SOLMARCH
const COMBAT_LOG_FILE: String = "res://build/test_combat_server_log.txt"
const REPORT_FILE: String = "res://build/test_combat_server_report.json"
## Maximum wait (ticks) for a combat event.
const MAX_WAIT: int = 300

var _viewport: SubViewport
var _world: Node3D
var _server: ZoneServer
var _events: Array[NetMessages.EntityEvent] = []


func after_each() -> void:
	if is_instance_valid(_server):
		_server.free()
	if is_instance_valid(_viewport):
		_viewport.get_parent().remove_child(_viewport)
		_viewport.free()
	_server = null
	_world = null
	_viewport = null
	_events.clear()
	await wait_process_frames()


# --- Helpers ----------------------------------------------------------------------------------

## Server in a flat zone. [param prepare_world] receives the zone before starting (to add safe
## zones to it, for example) and [param configure] the [ServerConfig].
func _start_server(prepare_world: Callable = Callable(), configure: Callable = Callable()) -> void:
	_viewport = SubViewport.new()
	_viewport.own_world_3d = true
	_viewport.size = Vector2i(64, 64)
	tree.root.add_child(_viewport)
	_world = ZoneFixture.build_flat_zone(_viewport)
	if prepare_world.is_valid():
		prepare_world.call(_world)
	_server = ZoneServer.new()
	_server.name = "ZoneServer"
	_server.log_enabled = false
	_viewport.add_child(_server)
	await wait_physics_frames(3)
	var config := ServerConfig.new()
	config.zone_id = "test_world"
	if configure.is_valid():
		configure.call(config)
	assert_eq(_server.start(config, _world, null, DevAuthProvider.new()), OK, "the server starts")
	_server.get_combat().event_emitted.connect(func(event: NetMessages.EntityEvent,
			_involved: PackedInt32Array) -> void: _events.append(event))


func _brain(script: Callable = Callable()) -> CombatFixture.ScriptBrain:
	var brain := CombatFixture.ScriptBrain.new(1)
	brain.script_fn = script
	return brain


func _character(net_id: int) -> PlayerCharacter:
	return _server.get_registry().get_entity(net_id).get_character()


func _combatant(net_id: int) -> Combatant:
	return _server.get_combat().get_combatant(net_id)


## Places [param net_id] at [param position] facing [param yaw].
func _put(net_id: int, position: Vector3, yaw: float) -> void:
	_server.teleport(net_id, position)
	_character(net_id).yaw = yaw


## Attacker from Vardheim at the origin facing -Z and a victim from Solmarch 1.5 m in front, facing it. The
## attacker presses PRIMARY (two ticks) on each tick of [param presses]; the victim runs
## [param victim_script] (null = still).
func _duel(presses: Array[int], victim_script: Callable = Callable()) -> Array[int]:
	var attacker: int = _server.add_fake_player(_brain(func(tick: int, _position: Vector3,
			_yaw: float) -> PlayerInput:
		var input := PlayerInput.new()
		input.tick = tick
		input.look_yaw = 0.0
		for press: int in presses:
			if tick >= press and tick < press + 2:
				input.buttons = PlayerInput.PRIMARY
		return input), VARDHEIM)
	var victim: int = _server.add_fake_player(_brain(victim_script), SOLMARCH)
	_put(attacker, Vector3(0.0, 0.05, 0.0), 0.0)
	_put(victim, Vector3(0.0, 0.05, -1.5), PI)
	return [attacker, victim]


func _events_of(kind: int) -> Array[NetMessages.EntityEvent]:
	var found: Array[NetMessages.EntityEvent] = []
	for event: NetMessages.EntityEvent in _events:
		if event.event == kind:
			found.append(event)
	return found


## Waits, physics step by physics step, until [param condition] is met.
func _wait_until(condition: Callable, max_frames: int = MAX_WAIT) -> bool:
	for _i: int in max_frames:
		if condition.call():
			return true
		await tree.physics_frame
	return condition.call()


# --- Hits end to end ---------------------------------------------------------------------------

func test_a_light_attack_travels_from_the_input_to_the_published_health() -> void:
	await _start_server()
	var press: int = _server.get_tick() + 6
	var duel: Array[int] = _duel([press])
	var landed: bool = await _wait_until(func() -> bool:
		return not _events_of(NetMessages.EntityEvent.Kind.HIT).is_empty())
	if not assert_true(landed, "the hit lands"):
		return
	var hit: NetMessages.EntityEvent = _events_of(NetMessages.EntityEvent.Kind.HIT)[0]
	assert_eq(hit.attacker, duel[0])
	assert_eq(hit.net_id, duel[1])
	assert_eq(hit.amount, 90)
	var light_1: int = CombatCatalog.attack_id(&"sword_light_1")
	assert_eq(hit.attack_id, light_1)
	# The active hit starts after the windup (12 ticks) of the light attack that began at `press`.
	assert_eq(hit.tick, press + CombatCatalog.attack(light_1).windup_ticks, "on the first active tick")
	await wait_physics_frames(2)
	var victim: NetEntity = _server.get_registry().get_entity(duel[1])
	assert_eq(victim.health, 910, "the health published for the snapshots drops")
	assert_eq(victim.health_q, EntityRecord.quantize_health(910, 1000))
	assert_true((victim.status & NetMessages.STATUS_IN_COMBAT) != 0, "and it is in combat")
	assert_eq(_events_of(NetMessages.EntityEvent.Kind.HIT).size(), 1, "a single hit per attack")
	# The attacker's action travels in the log's action byte.
	assert_true(_server.get_registry().get_entity(duel[0]).action != 0)


func test_a_block_in_front_stops_the_hit_and_the_history_keeps_the_defense_flags() -> void:
	await _start_server()
	var press: int = _server.get_tick() + 30
	var duel: Array[int] = _duel([press], func(tick: int, _position: Vector3,
			_yaw: float) -> PlayerInput:
		var input := PlayerInput.new()
		input.tick = tick
		input.look_yaw = PI
		input.buttons = PlayerInput.BLOCK
		return input)
	var landed: bool = await _wait_until(func() -> bool:
		return not _events_of(NetMessages.EntityEvent.Kind.HIT).is_empty())
	if not assert_true(landed, "the hit reaches the shield"):
		return
	var hit: NetMessages.EntityEvent = _events_of(NetMessages.EntityEvent.Kind.HIT)[0]
	assert_true(hit.has_hit_flag(NetMessages.EntityEvent.HIT_FLAG_BLOCKED), "blocked")
	assert_eq(hit.amount, 0)
	assert_eq(_combatant(duel[1]).health, 1000, "the shield stops all the damage")
	var flags: int = _server.get_history().get_flags(duel[1], _server.get_tick() - 1)
	assert_true(flags >= 0 and (flags & ActionMachine.DEFENSE_BLOCKING) != 0,
			"the history records that it was blocking")
	assert_eq(_server.get_history().get_flags(duel[0], _server.get_tick() - 1) \
			& ActionMachine.DEFENSE_BLOCKING, 0, "and that the attacker was not")


# --- Fall, lethal volumes, below the world -----------------------------------------------------

func test_a_twelve_meter_fall_hurts_and_a_three_meter_jump_does_not() -> void:
	await _start_server()
	var jumper: int = _server.add_fake_player(_brain(), VARDHEIM)
	var faller: int = _server.add_fake_player(_brain(), SOLMARCH)
	_server.teleport(jumper, Vector3(-20.0, 3.0, 0.0))
	_character(jumper).velocity = Vector3(0.0, _character(jumper).jump_velocity, 0.0)
	_server.teleport(faller, Vector3(20.0, 12.0, 0.0))
	var landed: bool = await _wait_until(func() -> bool:
		return _character(faller).grounded and _character(jumper).grounded, 200)
	if not assert_true(landed, "both land"):
		return
	await wait_physics_frames(3)
	assert_eq(_combatant(jumper).health, 1000, "jumping from 3 m (14 m/s) does no damage")
	var health: int = _combatant(faller).health
	assert_true(health >= 1000 - 640 and health <= 1000 - 480,
			"falling 12 m (23 m/s) takes off about 560 (%d)" % (1000 - health))
	var hits: Array[NetMessages.EntityEvent] = _events_of(NetMessages.EntityEvent.Kind.HIT)
	if assert_eq(hits.size(), 1, "an environment HIT"):
		assert_eq(hits[0].attacker, 0)
		assert_eq(hits[0].net_id, faller)


func test_running_and_jumping_down_a_ramp_does_no_fall_damage() -> void:
	await _start_server(func(world: Node3D) -> void:
		# A 20-degree ramp 20 m long: it rises towards -Z.
		var ramp := StaticBody3D.new()
		ramp.name = "Rampa"
		ramp.collision_layer = PlayerCharacter.WORLD_COLLISION_LAYER
		ramp.collision_mask = 0
		var shape := CollisionShape3D.new()
		var box := BoxShape3D.new()
		box.size = Vector3(8.0, 1.0, 20.0)
		shape.shape = box
		ramp.add_child(shape)
		world.add_child(ramp)
		ramp.position = Vector3(40.0, 3.0, -40.0)
		ramp.rotation_degrees = Vector3(20.0, 0.0, 0.0))
	var runner: int = _server.add_fake_player(_brain(func(tick: int, _position: Vector3,
			_yaw: float) -> PlayerInput:
		var input := PlayerInput.new()
		input.tick = tick
		input.look_yaw = PI
		input.move = Vector2(0.0, 1.0)
		# It jumps every 25 ticks.
		if tick % 25 < 3:
			input.buttons = PlayerInput.JUMP
		return input), VARDHEIM)
	await wait_physics_frames(3)
	# It is placed at the top of the ramp (the -Z end, the highest) on its surface.
	var space: PhysicsDirectSpaceState3D = _world.get_world_3d().direct_space_state
	var from := Vector3(40.0, 20.0, -47.0)
	var query := PhysicsRayQueryParameters3D.create(from, from + Vector3(0.001, -30.0, 0.0),
			PlayerCharacter.WORLD_COLLISION_LAYER)
	var hit: Dictionary = space.intersect_ray(query)
	if not assert_false(hit.is_empty(), "there is a ramp under the starting point"):
		return
	var top: Vector3 = hit["position"]
	assert_true(top.y > 4.0, "and it is at the top (%.1f m)" % top.y)
	_server.teleport(runner, top + Vector3(0.0, 0.1, 0.0))
	_character(runner).yaw = PI
	var start_z: float = _character(runner).global_position.z
	await wait_physics_frames(150)
	assert_true(_character(runner).global_position.z > start_z + 8.0,
			"it runs and jumps down the ramp (%.1f m)" % (_character(runner).global_position.z - start_z))
	assert_eq(_combatant(runner).health, 1000, "no fall damage")
	assert_eq(_events_of(NetMessages.EntityEvent.Kind.HIT).size(), 0)


func test_falling_below_the_world_kills_and_the_body_waits_dead_at_the_spawn_until_it_respawns() -> void:
	await _start_server()
	var id: int = _server.add_fake_player(_brain(), SOLMARCH)
	# Without the fakes' request on death: the automatic respawn is measured.
	_combatant(id).requests_respawn_on_death = false
	var timing: CombatTiming = _server.get_combat_timing()
	timing.respawn = 20
	timing.auto_respawn = 60
	timing.protection = 40
	await wait_physics_frames(3)
	_server.teleport(id, Vector3(0.0, -150.0, 0.0))
	var died: bool = await _wait_until(func() -> bool: return _combatant(id).is_dead(), 10)
	if not assert_true(died, "dies when falling out of the world"):
		return
	await wait_physics_frames(2)
	var entity: NetEntity = _server.get_registry().get_entity(id)
	assert_vec_near(Vector3(entity.get_position().x, 0.0, entity.get_position().z),
			ZoneFixture.SOLMARCH_SPAWN, 0.1, "the body is at its realm's spawn point")
	assert_eq(_character(id).combat.action, CombatState.Action.DEAD, "and stays dead")
	assert_eq(entity.status, NetMessages.STATUS_DEAD)
	assert_eq(entity.teleport_counter, 2, "teleport from the command and from death")
	assert_eq(_events_of(NetMessages.EntityEvent.Kind.DEATH).size(), 1, "a DEATH without an author")
	assert_eq(_events_of(NetMessages.EntityEvent.Kind.DEATH)[0].killer, 0)
	var respawned: bool = await _wait_until(func() -> bool: return _combatant(id).is_alive(), 120)
	if not assert_true(respawned, "it respawns on its own after the automatic deadline"):
		return
	assert_eq(_events_of(NetMessages.EntityEvent.Kind.RESPAWN).size(), 1)
	assert_true(_combatant(id).is_protected(_server.get_tick()), "with protection")
	assert_eq(_character(id).combat.action, CombatState.Action.NONE)
	assert_eq(_combatant(id).health, 1000)
	assert_eq(_events_of(NetMessages.EntityEvent.Kind.DEATH).size(), 1, "and no more deaths")


func test_a_lethal_volume_kills_inside_the_zone() -> void:
	await _start_server()
	var inside: int = _server.add_fake_player(_brain(), VARDHEIM)
	var outside: int = _server.add_fake_player(_brain(), SOLMARCH)
	var area := Area3D.new()
	area.name = "Veneno"
	area.collision_layer = 0
	area.collision_mask = PlayerCharacter.CHARACTER_COLLISION_LAYER
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(6.0, 4.0, 6.0)
	shape.shape = box
	area.add_child(shape)
	area.position = Vector3(60.0, 1.0, 60.0)
	area.add_to_group(Zones.LETHAL_GROUP)
	_world.add_child(area)
	await wait_physics_frames(2)
	_server.teleport(inside, Vector3(60.0, 0.1, 60.0))
	var died: bool = await _wait_until(func() -> bool: return _combatant(inside).is_dead(), 60)
	assert_true(died, "inside the lethal volume it dies")
	assert_true(_combatant(outside).is_alive(), "outside it does not")
	assert_eq(_events_of(NetMessages.EntityEvent.Kind.DEATH).size(), 1)


# --- Safe zones -------------------------------------------------------------------------------

func test_a_hit_inside_the_safe_area_of_the_victims_realm_does_no_damage() -> void:
	await _start_server(func(world: Node3D) -> void:
		var camp := Marker3D.new()
		camp.name = "Campamento"
		world.add_child(camp)
		camp.position = Vector3(0.0, 0.0, 0.0)
		camp.add_to_group(Zones.SAFE_AREA_GROUP)
		camp.set_meta(Zones.REALM_META, &"solmarch")
		camp.set_meta(Zones.SAFE_AREA_RADIUS_META, 10.0))
	assert_eq(_server.get_safe_areas().size(), 1, "the server reads the safe zone")
	var press: int = _server.get_tick() + 6
	var duel: Array[int] = _duel([press])
	await wait_physics_frames(60)
	assert_eq(_combatant(duel[1]).health, 1000, "the Solmarch victim inside its camp takes no damage")
	assert_eq(_events_of(NetMessages.EntityEvent.Kind.HIT).size(), 0)
	# Outside the safe zone (30 m from the center) the same hit does damage.
	var second_press: int = _server.get_tick() + 6
	var attacker: int = _server.add_fake_player(_brain(func(tick: int, _position: Vector3,
			_yaw: float) -> PlayerInput:
		var input := PlayerInput.new()
		input.tick = tick
		input.look_yaw = 0.0
		if tick >= second_press and tick < second_press + 2:
			input.buttons = PlayerInput.PRIMARY
		return input), VARDHEIM)
	var victim: int = _server.add_fake_player(_brain(), SOLMARCH)
	_put(attacker, Vector3(30.0, 0.05, 0.0), 0.0)
	_put(victim, Vector3(30.0, 0.05, -1.5), PI)
	var landed: bool = await _wait_until(func() -> bool:
		return not _events_of(NetMessages.EntityEvent.Kind.HIT).is_empty())
	assert_true(landed, "outside the camp the hit lands")
	assert_eq(_combatant(victim).health, 910)


# --- Dummy and NPCs ---------------------------------------------------------------------------

func test_a_dummy_is_an_immortal_npc_simulated_with_the_players() -> void:
	await _start_server()
	var player: int = _server.add_fake_player(_brain(), VARDHEIM)
	var dummy: int = _server.spawn_dummy(Vector3(0.0, 0.0, -10.0), 0.0)
	if not assert_true(dummy > 0, "the dummy is created"):
		return
	var entity: NetEntity = _server.get_registry().get_entity(dummy)
	assert_eq(entity.kind, NetProtocol.EntityKind.NPC)
	assert_eq(entity.realm, RealmCatalog.NEUTRAL_CODE, "neutral faction: hostile to everyone")
	assert_eq(entity.display_name, ZoneServer.DUMMY_NAME)
	assert_true(_combatant(dummy).immortal)
	assert_eq(_server.get_player_count(), 1, "an NPC does not count as a player")
	assert_eq(_server.get_dummy_count(), 1)
	await wait_physics_frames(5)
	assert_true(_server.get_history().has_tick(dummy, _server.get_tick()), "it is recorded in the history")
	assert_true(entity.get_position().y > -0.2 and entity.get_position().y < 0.3,
			"it is on the ground (%s)" % entity.get_position())
	assert_true(_character(dummy).grounded)
	# A player truly dies but the dummy does not.
	_server.get_combat().kill(_combatant(player), _server.get_tick() + 1)
	_server.get_combat().kill(_combatant(dummy), _server.get_tick() + 1)
	await wait_physics_frames(3)
	assert_true(_combatant(player).is_dead())
	assert_true(_combatant(dummy).is_alive(), "the dummy does not die")
	# NPC removal.
	assert_true(_server.remove_npc(dummy), "it is removed")
	assert_null(_server.get_registry().get_entity(dummy))
	assert_false(_server.remove_npc(player), "a player is not an NPC")
	assert_eq(_server.get_dummy_count(), 0)


func test_the_dummy_modes_block_and_spin() -> void:
	await _start_server()
	var blocker: int = _server.spawn_dummy(Vector3(0.0, 0.0, -10.0), 0.0, NpcBrain.Mode.BLOCK)
	var spinner: int = _server.spawn_dummy(Vector3(10.0, 0.0, -10.0), 0.0, NpcBrain.Mode.SPIN)
	var still: int = _server.spawn_dummy(Vector3(-10.0, 0.0, -10.0), 0.0, NpcBrain.Mode.STILL)
	await wait_physics_frames(30)
	assert_eq(_character(blocker).combat.action, CombatState.Action.BLOCK, "blocking")
	assert_eq(_character(still).combat.action, CombatState.Action.NONE, "still")
	var yaw_before: float = _character(spinner).yaw
	var start: Vector3 = _character(spinner).global_position
	await wait_physics_frames(60)
	assert_true(absf(angle_difference(_character(spinner).yaw, yaw_before)) > 0.5, "turns")
	assert_true(_character(spinner).global_position.distance_to(start) < 1.5, "without moving away")
	assert_near(_character(still).yaw, 0.0, 1e-6, "the still one does not turn")


## Result of [method _run_sword_combo].
class ComboRun:
	## Tick of each hit from the attacker to the dummy, and the one due according to the .tres data.
	var hit_ticks: Array[int] = []
	var expected_hit_ticks: Array[int] = []
	var damage: int = 0
	var cycle_damage: int = 0
	var dummy_alive: bool = false


## A fake attacker throws [param cycles] combos of three light attacks at a dummy, with the presses fixed
## by the data (the first opens light attack 1 and each link falls 4 ticks before the current light
## attack ends, within its combo window). Returns the tick of each hit and the one the data says:
## start of the cycle, plus the duration of the earlier light attacks, plus its own windup.
## With [param extra_first_light_ticks] the server lengthens light attack 1 by that number of ticks [b]after[/b]
## computing the schedule with the good data: it simulates a machine that does not comply with what the
## .tres say and serves as a control that the test detects it.
func _run_sword_combo(cycles: int, extra_first_light_ticks: int = 0) -> ComboRun:
	await _start_server()
	var run := ComboRun.new()
	var weapon: WeaponTicks = CombatCatalog.weapon(
			CombatCatalog.weapon_id(CombatCatalog.DEFAULT_WEAPON))
	var cycle_presses: Array[int] = [0]
	var cycle_hits: Array[int] = []
	var cycle_ticks: int = 0
	for index: int in weapon.light_ids.size():
		var attack: AttackTicks = CombatCatalog.attack(weapon.light_ids[index])
		run.cycle_damage += attack.base_damage
		cycle_hits.append(cycle_ticks + attack.windup_ticks)
		cycle_ticks += attack.total_ticks
		if index < weapon.light_ids.size() - 1:
			cycle_presses.append(cycle_ticks - 4)
	var start_tick: int = _server.get_tick() + 8
	var all_presses: Array[int] = []
	for cycle_index: int in cycles:
		for press: int in cycle_presses:
			all_presses.append(start_tick + cycle_index * cycle_ticks + press)
		for hit: int in cycle_hits:
			run.expected_hit_ticks.append(start_tick + cycle_index * cycle_ticks + hit)
	var first_light: AttackTicks = CombatCatalog.attack(weapon.light_ids[0])
	first_light.total_ticks += extra_first_light_ticks
	var attacker: int = _server.add_fake_player(_brain(func(tick: int, _position: Vector3,
			_yaw: float) -> PlayerInput:
		var input := PlayerInput.new()
		input.tick = tick
		input.look_yaw = 0.0
		for press: int in all_presses:
			if tick >= press and tick < press + 2:
				input.buttons = PlayerInput.PRIMARY
		return input), VARDHEIM)
	var dummy: int = _server.spawn_dummy(Vector3(0.0, 0.0, -2.2), PI)
	_put(attacker, Vector3(0.0, 0.05, 0.0), 0.0)
	# Each cycle moves the attacker forward (the advance of the light attacks): it is returned to its place at the start.
	for _step: int in cycles * cycle_ticks + 30:
		var next_tick: int = _server.get_tick() + 1
		for cycle_index: int in cycles:
			if next_tick == start_tick + cycle_index * cycle_ticks - 1:
				_server.teleport(attacker, Vector3(0.0, 0.05, 0.0))
		await tree.physics_frame
	first_light.total_ticks -= extra_first_light_ticks
	for event: NetMessages.EntityEvent in _events_of(NetMessages.EntityEvent.Kind.HIT):
		if event.net_id == dummy and event.attacker == attacker:
			run.damage += event.amount
			run.hit_ticks.append(event.tick)
	run.dummy_alive = _combatant(dummy).is_alive()
	return run


func test_the_sword_combo_dps_against_the_dummy_matches_the_data() -> void:
	var cycles: int = 3
	var run: ComboRun = await _run_sword_combo(cycles)
	# The measured DPS is the one calculated from the .tres only if each hit lands on the tick the data says
	# (counting hits and damage is not enough: dividing one by the other always gives the calculated DPS, and the
	# input buffer absorbs a tick of delay on each link without changing the count).
	assert_eq(run.hit_ticks, run.expected_hit_ticks,
			"each hit lands on the data's tick (cycle start + earlier durations + windup)")
	assert_eq(run.damage, run.cycle_damage * cycles,
			"the damage of the %d combos matches the .tres" % cycles)
	assert_true(run.dummy_alive, "the dummy is still there")


func test_a_light_attack_one_tick_longer_than_the_data_is_detected_by_the_dps_test() -> void:
	# Control for the previous test: with the first light attack one tick longer than the data says
	# (a -2.5 % DPS), count and damage still give the same, but the ticks of the hits do not.
	var run: ComboRun = await _run_sword_combo(1, 1)
	assert_eq(run.hit_ticks.size(), run.expected_hit_ticks.size(), "there is still one hit per light attack")
	assert_eq(run.damage, run.cycle_damage, "and the same total damage")
	assert_true(run.hit_ticks != run.expected_hit_ticks,
			"but the hits land late: %s versus %s" % [run.hit_ticks, run.expected_hit_ticks])
	assert_true(run.hit_ticks[1] == run.expected_hit_ticks[1] + 1, "the second, one tick later")


# --- Anti-cheat: the server decides the rhythm and the reach ---------------------------------

func test_a_client_pressing_primary_every_other_tick_cannot_hit_faster_than_the_combo() -> void:
	await _start_server()
	var spammer: int = _server.add_fake_player(_brain(func(tick: int, _position: Vector3,
			_yaw: float) -> PlayerInput:
		var input := PlayerInput.new()
		input.tick = tick
		input.look_yaw = 0.0
		if tick % 2 == 0:
			input.buttons = PlayerInput.PRIMARY
		return input), VARDHEIM)
	var dummy: int = _server.spawn_dummy(Vector3(0.0, 0.0, -2.2), PI)
	_put(spammer, Vector3(0.0, 0.05, 0.0), 0.0)
	var ticks: int = 360
	for step: int in ticks:
		if step % 30 == 0:
			# The light attacks advance: it is returned to its place so it does not overshoot the dummy.
			_server.teleport(spammer, Vector3(0.0, 0.05, 0.0))
		await tree.physics_frame
	var hits: int = 0
	for event: NetMessages.EntityEvent in _events_of(NetMessages.EntityEvent.Kind.HIT):
		if event.net_id == dummy:
			hits += 1
	# The fastest combo the data allows: three light attacks chained every 119 ticks.
	var weapon: WeaponTicks = CombatCatalog.weapon(CombatCatalog.weapon_id(CombatCatalog.DEFAULT_WEAPON))
	var combo_ticks: int = 0
	for light_id: int in weapon.light_ids:
		combo_ticks += CombatCatalog.attack(light_id).total_ticks
	var most_hits: int = ceili(float(ticks) * float(weapon.light_ids.size()) / float(combo_ticks)) + 1
	assert_true(hits >= 3, "something lands (%d)" % hits)
	assert_true(hits <= most_hits, "but no more than the combo rhythm: %d <= %d" % [hits, most_hits])


## Input queue that loses the ones of certain ticks (as if they arrived late): the server
## replaces them by repeating the previous one.
class LossyQueue:
	extends InputQueue

	var lost_ticks: Array[int] = []


	func push(input: PlayerInput, view_offset_q: int, next_tick: int) -> PushResult:
		if lost_ticks.has(input.tick):
			return PushResult.TOO_EARLY
		return super.push(input, view_offset_q, next_tick)


## An attacker that holds PRIMARY for [param hold] ticks on a dummy at 2.2 m, with a queue that
## loses the inputs of [param lost] (ticks relative to the press). Returns the attacker, the
## dummy and the queue.
func _hold_primary_duel(lost: Array[int], hold: int = 30) -> Dictionary:
	await _start_server()
	var press: int = _server.get_tick() + 6
	var attacker: int = _server.add_fake_player(_brain(func(tick: int, _position: Vector3,
			_yaw: float) -> PlayerInput:
		var input := PlayerInput.new()
		input.tick = tick
		input.look_yaw = 0.0
		if tick >= press and tick < press + hold:
			input.buttons = PlayerInput.PRIMARY
		return input), VARDHEIM)
	var dummy: int = _server.spawn_dummy(Vector3(0.0, 0.0, -2.2), PI)
	_put(attacker, Vector3(0.0, 0.05, 0.0), 0.0)
	var queue := LossyQueue.new()
	queue.reset(_server.get_tick(), NetProtocol.neutral_input(_server.get_tick(), 0.0))
	for offset: int in lost:
		queue.lost_ticks.append(press + offset)
	_server._queues[attacker] = queue
	_combatant(attacker).queue = queue
	return {"attacker": attacker, "dummy": dummy, "queue": queue}


func _heavy_hits_on(dummy: int) -> int:
	var heavy: int = CombatCatalog.attack_id(&"sword_heavy")
	var count: int = 0
	for event: NetMessages.EntityEvent in _events_of(NetMessages.EntityEvent.Kind.HIT):
		if event.net_id == dummy and event.attack_id == heavy:
			count += 1
	return count


func test_holding_primary_launches_a_heavy_attack_on_the_server() -> void:
	var duel: Dictionary = await _hold_primary_duel([])
	await wait_physics_frames(110)
	assert_eq(duel["queue"].substitutions_total, 0, "without losses")
	assert_eq(_heavy_hits_on(duel["dummy"]), 1, "the charged heavy attack lands")


func test_a_lost_input_during_the_press_still_launches_the_heavy_attack() -> void:
	# C1: the input of tick p+3 arrives late and the server replaces it; the heavy attack still goes out (the
	# client, with all its inputs, predicted the charge).
	for lost: int in [1, 3, 7]:
		var duel: Dictionary = await _hold_primary_duel([lost])
		await wait_physics_frames(110)
		assert_eq(duel["queue"].substitutions_total, 1, "(p+%d) a replaced input" % lost)
		assert_eq(_heavy_hits_on(duel["dummy"]), 1, "(p+%d) the server launches the heavy attack" % lost)
		await after_each()


func test_a_client_that_goes_silent_while_charging_cannot_bank_a_heavy_attack() -> void:
	# R2: the client charges the heavy attack, stops sending inputs (the server replaces) and releases 190 ticks
	# later. Before, the heavy attack went out at once with maximum charge; now the charge expired on its own.
	var silent: Array[int] = []
	for offset: int in range(10, 200):
		silent.append(offset)
	var duel: Dictionary = await _hold_primary_duel(silent, 200)
	await wait_physics_frames(300)
	assert_eq(duel["queue"].substitutions_total, silent.size(), "190 replaced inputs")
	assert_eq(_heavy_hits_on(duel["dummy"]), 0, "no heavy attack stored")
	assert_eq(_combatant(duel["attacker"]).get_character().combat.stamina, 1000,
			"and no stamina spent")


func test_an_attack_from_five_meters_hits_nothing() -> void:
	await _start_server()
	var press: int = _server.get_tick() + 6
	var duel: Array[int] = _duel([press])
	_put(duel[1], Vector3(0.0, 0.05, -5.0), PI)
	await wait_physics_frames(60)
	assert_eq(_combatant(duel[1]).health, 1000, "out of reach there is no damage")
	assert_eq(_events_of(NetMessages.EntityEvent.Kind.HIT).size(), 0)
	assert_true(_character(duel[0]).combat.action_tick == press or _character(duel[0]).combat.action_tick > 0,
			"the attacker did throw its hit")


# --- Log, report and console -------------------------------------------------------------------

func test_combat_log_and_report() -> void:
	var log_path: String = ProjectSettings.globalize_path(COMBAT_LOG_FILE)
	await _start_server(Callable(), func(config: ServerConfig) -> void:
		config.combat_log_path = log_path)
	var press: int = _server.get_tick() + 6
	var duel: Array[int] = _duel([press])
	var landed: bool = await _wait_until(func() -> bool:
		return not _events_of(NetMessages.EntityEvent.Kind.HIT).is_empty())
	if not assert_true(landed):
		return
	await wait_physics_frames(2)
	assert_eq(_server.write_report(ProjectSettings.globalize_path(REPORT_FILE)), OK)
	_server.stop()
	var lines: PackedStringArray = FileAccess.get_file_as_string(log_path).strip_edges().split("\n")
	assert_eq(lines[0], ZoneServer.COMBAT_LOG_HEADER, "CSV header")
	if assert_eq(lines.size(), 2, "one line per hit"):
		var columns: PackedStringArray = lines[1].split(",")
		assert_eq(columns.size(), 8)
		assert_eq(columns[1], str(duel[0]), "attacker")
		assert_eq(columns[2], str(duel[1]), "target")
		assert_eq(columns[3], "sword_light_1", "attack")
		assert_near(columns[4].to_float(), float(columns[0].to_int()), 0.01, "view_tick = tick without rewind")
		assert_near(columns[5].to_float(), 0.0, 0.01, "rewind 0")
		assert_eq(columns[6], "hit", "result")
		assert_eq(columns[7], "90", "damage")
	var json := JSON.new()
	assert_eq(json.parse(FileAccess.get_file_as_string(ProjectSettings.globalize_path(REPORT_FILE))), OK)
	var report: Dictionary = json.data
	var combat: Dictionary = report.get("combat", {})
	assert_eq(int(combat.get("hits", -1)), 1, "the report counts the hit")
	assert_eq(int(combat.get("damage", -1)), 90)
	assert_true(combat.has("events_sent") and combat.has("suspicious") and combat.has("rewind_rejected"))
	assert_true(int(combat.get("hit_tests", 0)) >= 1, "the report counts the hit checks")
	assert_true(combat.has("event_bytes_sent"))
	var sections: Dictionary = (report.get("metrics", {}) as Dictionary).get("sections", {})
	assert_true(sections.has("combat_resolve"), "and measures hit resolution separately (%s)" % [sections.keys()])
	assert_true(sections.has("combat"))


func test_console_commands() -> void:
	await _start_server()
	var ana: int = _server.add_fake_player(_brain(), VARDHEIM)
	var commands: CommandRegistry = _server.get_commands()
	# Ids 7 to 12 (protocol 4) are fixed and all already have their handler: /stuck and the four fort
	# commands were registered by F3 and npc_debug by F4. Of those of protocol 6 (13 to 16, docs/abilities.md §5.1),
	# cooldowns_off and apply_status arrived with H3a and down and refill with H3c. The four progression
	# ones of protocol 7 (40 to 43, docs/progression.md §10), with progression.md P5d.
	assert_eq(commands.missing_network_commands(), PackedStringArray(),
			"all network commands have a handler")
	assert_true(_server.console_command("help").contains("teleport"))
	assert_true(_server.console_command("noexiste").begins_with("Comando desconocido"))
	# Damage, heal and kill.
	_combatant(ana).take_damage(300, 1)
	assert_eq(_server.console_command("heal Bot-01"), "Bot-01 curado")
	assert_eq(_combatant(ana).health, 1000)
	assert_eq(_server.console_command("kill %d" % ana), "Bot-01 muerto")
	await wait_physics_frames(3)
	assert_true(_combatant(ana).is_dead())
	assert_eq(_server.console_command("heal Bot-01"), "Bot-01 está muerto")
	# Teleport.
	var respawn_id: int = _server.add_fake_player(_brain(), SOLMARCH)
	assert_true(_server.console_command("teleport Bot-02 10 0.5 -4").contains("teletransportado"))
	assert_vec_near(_server.get_registry().get_entity(respawn_id).get_position(),
			Vector3(10.0, 0.5, -4.0), 1e-4)
	assert_eq(_server.console_command("teleport Bot-02 1 2"),
			"Uso: teleport <jugador> <x> <y> <z> | teleport <jugador> <otro jugador>")
	assert_eq(_server.console_command("teleport Bot-02 1e9 0 0"), "Destino fuera de rango")
	assert_eq(_server.console_command("teleport Nadie 1 2 3"), "No hay ningún jugador «Nadie»")
	# Infinite stamina and weapon.
	assert_true(_server.console_command("stamina_inf Bot-02 on").contains("activada"))
	assert_true((_character(respawn_id).combat.combat_flags & CombatState.FLAG_INFINITE_STAMINA) != 0)
	assert_true(_server.console_command("stamina_inf Bot-02 off").contains("desactivada"))
	assert_eq(_character(respawn_id).combat.combat_flags & CombatState.FLAG_INFINITE_STAMINA, 0)
	assert_true(_server.console_command("set_weapon Bot-02 sword_shield").contains("lleva ahora"))
	assert_true(_server.console_command("set_weapon Bot-02 hacha").contains("No existe"))
	# Dummies.
	assert_true(_server.console_command("spawn_dummy 5 0 5 bloqueando").contains("bloqueando"))
	assert_eq(_server.get_dummy_count(), 1)
	assert_true(_server.console_command("spawn_dummy 5 0 5 volando").contains("Modo desconocido"))
	# Announcement, kick and listing.
	assert_eq(_server.console_command("announce Hola a todos"), "Anuncio enviado a 0 jugadores")
	assert_true(_server.console_command("kick Bot-02").contains("dado de baja"))
	assert_true(_server.console_command("players").contains("Maniquí"))
	# Shutdown with countdown.
	var requests: Array[String] = []
	_server.shutdown_requested.connect(func(reason: String) -> void: requests.append(reason))
	assert_eq(_server.console_command("shutdown 1"), "Cierre dentro de 1 s")
	await wait_physics_frames(30)
	assert_eq(requests.size(), 0, "the second has not passed yet")
	assert_true(await _wait_until(func() -> bool: return requests.size() == 1, 90), "the shutdown is requested")
	assert_eq(_server.console_command("shutdown cancel"), "No hay ningún cierre pendiente")
	assert_eq(_server.console_command("shutdown 100"), "Cierre dentro de 100 s")
	assert_eq(_server.console_command("shutdown cancel"), "Cierre cancelado")
	# Everything is audited.
	assert_true(commands.audit_total >= 20, "each use is recorded in the audit (%d)" % commands.audit_total)
	assert_true(commands.audit[commands.audit.size() - 1].begins_with("[auditoría] consola: shutdown cancel"))


## H3a (docs/abilities.md, 5.1): commands 13 cooldowns_off (bit 7 of combat_flags2) and 14 apply_status
## (an effect with no author, with its duration or the data's), over the network and through the console.
func test_cooldowns_off_and_apply_status_commands() -> void:
	await _start_server()
	var ana: int = _server.add_fake_player(_brain(), VARDHEIM)
	var commands: CommandRegistry = _server.get_commands()
	var peer := ServerPeer.new(3)
	peer.entity = _server.get_registry().get_entity(ana)
	var no_cooldowns: Callable = func() -> bool:
		return (_character(ana).combat.combat_flags2 & CombatState.FLAG2_NO_COOLDOWNS) != 0
	assert_eq(commands.execute_network(peer, NetProtocol.DEBUG_COOLDOWNS_OFF, PackedByteArray([1])),
			CommandRegistry.Result.OK, "13 with 1")
	assert_true(no_cooldowns.call(), "no cooldowns")
	assert_eq(commands.execute_network(peer, NetProtocol.DEBUG_COOLDOWNS_OFF, PackedByteArray([0])),
			CommandRegistry.Result.OK, "13 with 0")
	assert_false(no_cooldowns.call(), "with cooldowns again")
	assert_eq(commands.execute_network(peer, NetProtocol.DEBUG_COOLDOWNS_OFF, PackedByteArray([2])),
			CommandRegistry.Result.BAD_ARGUMENTS, "ni 0 ni 1")
	assert_eq(commands.execute_network(peer, NetProtocol.DEBUG_COOLDOWNS_OFF, PackedByteArray()),
			CommandRegistry.Result.BAD_ARGUMENTS, "no data")
	assert_eq(_server.console_command("cooldowns_off Bot-01 on"), "Sin reutilizaciones para Bot-01")
	assert_true(no_cooldowns.call())
	assert_eq(_server.console_command("cooldowns_off Bot-01"), "Con reutilizaciones para Bot-01", "without on/off, it toggles")
	# 14: bleeding with 120 ticks, no author, from the tick the server is about to simulate.
	var bleed: int = CombatCatalog.status_id(&"bleed")
	var next_tick: int = _server.get_tick() + 1
	assert_eq(commands.execute_network(peer, NetProtocol.DEBUG_APPLY_STATUS,
			NetMessages.DebugCommand.apply_status(bleed, 120).payload), CommandRegistry.Result.OK, "14")
	var effect: StatusSystem.ActiveEffect = _server.get_combat().status.find(_combatant(ana), bleed)
	if assert_not_null(effect, "it carries it"):
		assert_eq(effect.until_tick, next_tick + 120, "with the requested duration")
		assert_eq(effect.source_id, 0, "no author")
	var statuses: Array[NetMessages.EntityEvent] = _events_of(NetMessages.EntityEvent.Kind.STATUS)
	if assert_eq(statuses.size(), 1, "STATUS 1"):
		assert_eq(statuses[0].until_tick, next_tick + 120)
		assert_eq(statuses[0].source_entity, 0)
	assert_eq(commands.execute_network(peer, NetProtocol.DEBUG_APPLY_STATUS,
			NetMessages.DebugCommand.apply_status(250, 0).payload), CommandRegistry.Result.BAD_ARGUMENTS,
			"an effect that does not exist")
	assert_eq(commands.execute_network(peer, NetProtocol.DEBUG_APPLY_STATUS, PackedByteArray([bleed])),
			CommandRegistry.Result.BAD_ARGUMENTS, "short data")
	# Through the console, with the data's duration: the slow takes up its movement slot.
	var slowed: int = CombatCatalog.status_id(&"slowed")
	assert_eq(_server.console_command("apply_status Bot-01 slowed"), "slowed aplicado a Bot-01")
	assert_eq(_character(ana).combat.move_effect_ids[0], slowed, "the movement slot")
	assert_eq(_server.console_command("apply_status Bot-01 nada"), "No existe el efecto «nada»")
	# Bleeding ticks with no author (an \"environment\" HIT with the effect's source).
	var pulsed: bool = await _wait_until(func() -> bool:
		return not _events_of(NetMessages.EntityEvent.Kind.HIT).is_empty(), 90)
	if assert_true(pulsed, "it ticks"):
		var pulse: NetMessages.EntityEvent = _events_of(NetMessages.EntityEvent.Kind.HIT)[0]
		assert_eq(pulse.attacker, 0)
		assert_eq(pulse.tick, next_tick + 60, "at anchor + 60")
		assert_eq(pulse.get_source(), CombatSource.make(CombatSource.Kind.STATUS, bleed))


func test_console_lines_run_at_the_start_of_the_next_tick() -> void:
	await _start_server()
	var ana: int = _server.add_fake_player(_brain(), VARDHEIM)
	_combatant(ana).take_damage(500, 1)
	_server.push_console_line("heal Bot-01")
	assert_eq(_combatant(ana).health, 500, "the line has not run yet")
	await wait_physics_frames(2)
	assert_eq(_combatant(ana).health, 1000, "it runs at the start of the tick, without blocking it")


# --- Combat brain ------------------------------------------------------------------------------

func test_combat_fakes_find_each_other_and_fight() -> void:
	await _start_server()
	var first: int = _server.add_fake_player(BotBrain.new(11, BotBrain.Pattern.COMBAT,
			Vector3(-3.0, 0.0, 0.0), 25.0), VARDHEIM)
	var second: int = _server.add_fake_player(BotBrain.new(12, BotBrain.Pattern.COMBAT,
			Vector3(3.0, 0.0, 0.0), 25.0), SOLMARCH)
	_put(first, Vector3(-4.0, 0.05, 0.0), -PI / 2.0)
	_put(second, Vector3(4.0, 0.05, 0.0), PI / 2.0)
	var fought: bool = await _wait_until(func() -> bool:
		return _server.get_combat().stats[&"hits"] >= 3, 400)
	assert_true(fought, "the two bots meet and hit each other (%d hits)"
			% _server.get_combat().stats[&"hits"])
	var distance: float = _server.get_registry().get_entity(first).get_position().distance_to(
			_server.get_registry().get_entity(second).get_position())
	assert_true(distance < 4.0, "they are close to each other (%.1f m)" % distance)
	assert_true(_combatant(first).health < 1000 or _combatant(second).health < 1000)
