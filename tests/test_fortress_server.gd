extends TestCase
## Package F3 inside the [ZoneServer] (docs/fortress.md, sections 1 to 5), without networking: the test
## fortress from [FortressFixture] (circle, captain, real gate and respawn points) with fake players.
## It checks the full neutral -> Vardheim -> Solmarch capture with the captain double and the debug
## commands, real hits on the gate (damage, enemies only, a broken gate lets people through), the
## deferred repair with someone in the doorway, respawning at the own fort and in waves, the
## scoreboard, the battle log and the report.
## [br][br]
## Almost everything is advanced quickly with a [FortressFixture.Stepper] (several ticks per physics
## tick); whatever depends on real movement (crossing the gate) is run by the server at its own pace.

const VARDHEIM: int = NetProtocol.Realm.VARDHEIM
const SOLMARCH: int = NetProtocol.Realm.SOLMARCH
const FORTRESS: StringName = FortressFixture.FORTRESS_ID
const YAW_EAST: float = -PI * 0.5
const BATTLE_LOG_FILE: String = "res://build/test_fortress_battle_log.jsonl"
const REPORT_FILE: String = "res://build/test_fortress_report.json"

var _viewport: SubViewport
var _world: Node3D
var _server: ZoneServer
var _stepper: FortressFixture.Stepper
var _events: Array[NetMessages.EntityEvent] = []
var _war: Array[NetMessages.EntityEvent] = []
var _object_states: Array[NetMessages.ObjectState] = []


func after_each() -> void:
	if is_instance_valid(_server):
		_server.free()
	if is_instance_valid(_viewport):
		_viewport.get_parent().remove_child(_viewport)
		_viewport.free()
	_server = null
	_world = null
	_viewport = null
	_stepper = null
	_events.clear()
	_war.clear()
	_object_states.clear()
	await wait_process_frames()


# --- Helpers ----------------------------------------------------------------------------------

## Server on the flat zone with the test fortress. With [param manual] it advances with the
## [FortressFixture.Stepper]; otherwise, at its own pace.
func _start_server(manual: bool = true, definition: FortressDefinition = null,
		configure: Callable = Callable()) -> void:
	_viewport = SubViewport.new()
	_viewport.own_world_3d = true
	_viewport.size = Vector2i(64, 64)
	tree.root.add_child(_viewport)
	_world = ZoneFixture.build_flat_zone(_viewport)
	FortressFixture.add_fortress(_world, definition if definition != null
			else FortressFixture.make_definition())
	FortressFixture.add_respawn_points(_world)
	_server = ZoneServer.new()
	_server.name = "ZoneServer"
	_server.log_enabled = false
	_viewport.add_child(_server)
	await wait_physics_frames(3)
	var config := ServerConfig.new()
	config.zone_id = "test_world"
	config.max_players = 32
	config.no_dummies = true
	if configure.is_valid():
		configure.call(config)
	assert_eq(_server.start(config, _world, null, DevAuthProvider.new()), OK, "the server starts")
	_server.get_combat().event_emitted.connect(func(event: NetMessages.EntityEvent,
			_involved: PackedInt32Array) -> void: _events.append(event))
	_server.get_fortresses().war_event_emitted.connect(func(event: NetMessages.EntityEvent) -> void:
		_war.append(event))
	_server.get_fortresses().object_state_emitted.connect(func(object_state: NetMessages.ObjectState) -> void:
		_object_states.append(object_state))
	if manual:
		_server.set_physics_process(false)
		_stepper = FortressFixture.Stepper.new()
		_stepper.server = _server
		_viewport.add_child(_stepper)


## Advances the server by [param ticks] ticks (quickly with the Stepper, at its own pace otherwise).
func _advance(ticks: int) -> void:
	if _stepper != null:
		_stepper.remaining += ticks
		while _stepper.remaining > 0:
			await tree.physics_frame
	else:
		await wait_physics_frames(ticks)


func _brain(script: Callable = Callable()) -> CombatFixture.ScriptBrain:
	var brain := CombatFixture.ScriptBrain.new(1)
	brain.script_fn = script
	return brain


func _character(net_id: int) -> PlayerCharacter:
	return _server.get_registry().get_entity(net_id).get_character()


func _combatant(net_id: int) -> Combatant:
	return _server.get_combat().get_combatant(net_id)


func _put(net_id: int, position: Vector3, yaw: float = 0.0) -> void:
	_server.teleport(net_id, position)
	_character(net_id).yaw = yaw


func _state() -> FortressState:
	return _server.get_fortresses().get_fortress_state(FORTRESS)


func _gate() -> FortGate:
	return _server.get_fortresses().get_gate(FORTRESS)


func _war_ids() -> Array[int]:
	var ids: Array[int] = []
	for event: NetMessages.EntityEvent in _war:
		ids.append(event.war_event)
	return ids


func _events_of(kind: int) -> Array[NetMessages.EntityEvent]:
	var found: Array[NetMessages.EntityEvent] = []
	for event: NetMessages.EntityEvent in _events:
		if event.event == kind:
			found.append(event)
	return found


## An idle fake player of [param realm] at [param position].
func _idle_player(realm: int, position: Vector3) -> int:
	var net_id: int = _server.add_fake_player(_brain(), realm)
	_put(net_id, position)
	return net_id


## A fake player of [param realm] that presses PRIMARY at [param tick] facing the gate.
func _gate_attacker(realm: int, press_tick: int, position: Vector3) -> int:
	var net_id: int = _server.add_fake_player(_brain(func(tick: int, _position: Vector3,
			_yaw: float) -> PlayerInput:
		var input := PlayerInput.new()
		input.tick = tick
		input.look_yaw = YAW_EAST
		if tick >= press_tick and tick < press_tick + 2:
			input.buttons = PlayerInput.PRIMARY
		return input), realm)
	_put(net_id, position, YAW_EAST)
	return net_id


func _slash(base: int) -> int:
	return roundi(float(base) * CombatCatalog.rules().structure_multiplier(DamageFormula.DamageType.SLASH))


# --- The server with a fortress ----------------------------------------------------------------

func test_the_server_creates_the_fortress_entity_and_turns_on_the_respawn_waves() -> void:
	await _start_server()
	var fortresses: FortressController = _server.get_fortresses()
	assert_true(fortresses.has_fortresses())
	var entity: NetEntity = fortresses.get_entity(FORTRESS)
	if not assert_not_null(entity):
		return
	assert_eq(_server.get_registry().get_entity(entity.net_id), entity, "it is in the zone registry")
	assert_eq(entity.kind, NetProtocol.EntityKind.STRUCTURE)
	assert_eq(_server.get_player_count(), 0, "it does not count as a player")
	assert_eq(_server.get_combat_timing().respawn_wave_ticks, CombatTiming.WAVE_TICKS,
			"zones with a fortress respawn in waves")
	assert_eq(_server.console_command("players"), "0 entidades: ", "the fortress does not show up in the player list")
	assert_true(_server.console_command("help").contains("fort_reset"))
	await _advance(30)
	assert_eq(_server.get_tick(), 30)
	assert_true(_war.is_empty(), "a fortress on its own does not announce anything")


func test_the_default_times_are_the_designed_ones() -> void:
	assert_eq(ZoneServer.LINGER_TICKS, 15 * 60, "the body of someone who leaves in combat stays for 15 s")
	assert_eq(ZoneServer.SCOREBOARD_INTERVAL_TICKS, 2 * 60, "the scoreboard goes out every 2 s")
	assert_eq(CombatTiming.WAVE_TICKS, 10 * 60, "respawn waves, every 10 s")
	assert_eq(UnstuckTracker.CHANNEL_TICKS, 10 * 60, "/stuck channels for 10 s")
	assert_eq(UnstuckTracker.COOLDOWN_TICKS, 5 * 60 * 60, "and is reusable after 5 min")
	assert_eq(ScoreKeeper.MERITS_PER_KILL, 10)
	assert_eq(ScoreKeeper.MERITS_PER_ASSIST, 5)
	assert_eq(FortressController.OBJECT_STATE_INTERVAL_TICKS, 6, "one OBJECT_STATE every 6 ticks at most")


func test_a_zone_without_fortresses_keeps_the_plain_respawn_timing() -> void:
	_viewport = SubViewport.new()
	_viewport.own_world_3d = true
	_viewport.size = Vector2i(64, 64)
	tree.root.add_child(_viewport)
	_world = ZoneFixture.build_flat_zone(_viewport)
	_server = ZoneServer.new()
	_server.log_enabled = false
	_viewport.add_child(_server)
	await wait_physics_frames(3)
	var config := ServerConfig.new()
	config.zone_id = "test_world"
	assert_eq(_server.start(config, _world, null, DevAuthProvider.new()), OK)
	assert_false(_server.get_fortresses().has_fortresses())
	assert_eq(_server.get_combat_timing().respawn_wave_ticks, 0, "no waves")
	assert_true(_server.console_command("fort_reset").begins_with("No hay ninguna fortaleza"))
	await wait_physics_frames(5)
	assert_eq(_server.get_registry().size(), 0)


# --- Capture end to end ------------------------------------------------------------------------

func test_a_full_capture_neutral_to_vardheim_to_solmarch_through_the_server() -> void:
	await _start_server()
	var captain: int = _server.spawn_captain_double(FORTRESS)
	if not assert_true(captain > 0, "the captain double appears"):
		return
	assert_eq(_server.get_fortresses().get_captain_net_id(FORTRESS), captain)
	var vardheim: int = _idle_player(VARDHEIM, FortressFixture.circle_center())
	await _advance(120)
	assert_eq(_state().phase, FortressState.Phase.GARRISONED, "with the captain alive it cannot be captured")
	assert_eq(_state().presence[VARDHEIM], 1, "the captain, being an NPC, is in the circle and does not count")
	# The captain of the Hollow falls (here, via the debug command).
	assert_eq(_server.console_command("fort_kill_captain"), "El capitán de %s ha muerto" % FORTRESS)
	await _advance(10)
	assert_true(_combatant(captain).is_dead(), "the real double has died")
	assert_eq(_events_of(NetMessages.EntityEvent.Kind.DEATH).size(), 1)
	await _advance(200)
	assert_eq(_state().owner, VARDHEIM, "captured by Vardheim")
	assert_eq(_state().phase, FortressState.Phase.CONSOLIDATING)
	assert_eq(_gate().get_owner_realm(), VARDHEIM)
	assert_true(_server.get_scores().get_entry(vardheim).circle_seconds() >= 2,
			"the seconds in the circle count towards the scoreboard")
	# The consolidation passes and Vardheim's captain appears (here, by hand): the second captain.
	await _advance(130)
	assert_eq(_state().phase, FortressState.Phase.GARRISONED)
	var second: int = _server.spawn_captain_double(FORTRESS)
	assert_eq(_server.get_registry().get_entity(second).realm, VARDHEIM, "it belongs to the owner")
	var solmarch: int = _idle_player(SOLMARCH, FortressFixture.circle_center() + Vector3(1.0, 0.0, 0.0))
	_server.teleport(vardheim, Vector3(-20.0, 0.05, 0.0))
	assert_true(_server.console_command("fort_kill_captain").contains("ha muerto"))
	await _advance(220)
	assert_eq(_state().owner, SOLMARCH, "and captured by Solmarch")
	assert_eq(_gate().get_owner_realm(), SOLMARCH)
	assert_eq(_war_ids(), [WarEvents.CAPTAIN_DOWN, WarEvents.CAPTURE_STARTED, WarEvents.FORT_CAPTURED,
			WarEvents.CAPTAIN_DOWN, WarEvents.CAPTURE_STARTED, WarEvents.FORT_CAPTURED] as Array[int])
	assert_true(_server.get_scores().get_entry(solmarch).circle_seconds() >= 1)
	assert_true(_object_states.size() >= 4, "the state is replicated on every change")


func test_the_debug_commands_set_the_owner_reset_the_fort_and_speed_up_the_capture() -> void:
	await _start_server()
	assert_eq(_server.console_command("fort_owner solmarch"), "%s es ahora de Solmarch" % FORTRESS)
	await _advance(2)
	assert_eq(_state().owner, SOLMARCH)
	assert_eq(_gate().collision_layer, FortGate.layers_for(SOLMARCH, false))
	assert_eq(_server.console_command("fort_capture_speed 20"), "Captura de %s a x20" % FORTRESS)
	var player: int = _idle_player(VARDHEIM, FortressFixture.circle_center())
	_server.console_command("fort_kill_captain")
	await _advance(40)
	assert_eq(_state().owner, VARDHEIM, "at x20 the 120-tick capture takes about 6")
	assert_true(player > 0)
	assert_eq(_server.console_command("fort_reset"), "%s vuelve a ser neutral" % FORTRESS)
	await _advance(2)
	assert_eq(_state().owner, 0)
	assert_eq(_state().phase, FortressState.Phase.GARRISONED)
	assert_eq(_gate().collision_layer, FortGate.layers_for(0, false))
	assert_true(_server.get_commands().audit_total >= 4, "it ends up audited")


# --- The gate, for real ------------------------------------------------------------------------

func test_a_real_swing_takes_health_off_the_gate_and_announces_the_attack() -> void:
	await _start_server()
	var attacker: int = _gate_attacker(VARDHEIM, 12, Vector3(77.5, 0.05, 0.0))
	await _advance(60)
	assert_eq(_state().gate_health, 900 - _slash(90), "the light attack removes what the data says")
	var gate_id: int = _server.get_fortresses().get_net_id(FORTRESS)
	var hits: Array[NetMessages.EntityEvent] = _events_of(NetMessages.EntityEvent.Kind.HIT)
	if assert_eq(hits.size(), 1, "a HIT"):
		assert_eq(hits[0].net_id, gate_id, "with the fortress's net_id")
		assert_eq(hits[0].attacker, attacker)
	assert_true(_combatant(attacker).is_in_combat(_server.get_tick()), "the attacker ends up in combat")
	assert_eq(_war_ids(), [WarEvents.UNDER_ATTACK] as Array[int])
	assert_eq(_server.get_scores().get_entry(attacker).gate_damage, _slash(90))
	assert_eq(_server.get_combat().stats[&"gate_hits"], 1)
	# The OBJECT_STATE carries the new health.
	var last: NetMessages.ObjectState = null
	for object_state: NetMessages.ObjectState in _object_states:
		if object_state.has_field(FortressFields.GATE_HEALTH):
			last = object_state
	if assert_not_null(last, "the gate's health is replicated"):
		assert_eq(last.get_value(FortressFields.GATE_HEALTH), 900 - _slash(90))


func test_three_attackers_with_the_sword_combo_break_the_gate_in_about_55_seconds() -> void:
	var definition: FortressDefinition = FortressFixture.make_definition()
	definition.gate_health = 9000
	await _start_server(true, definition)
	# The chained sword combo: the second and third presses, 4 ticks before the previous light attack ends.
	var weapon: WeaponTicks = CombatCatalog.weapon(CombatCatalog.weapon_id(CombatCatalog.DEFAULT_WEAPON))
	var presses: Array[int] = [0]
	var cycle: int = 0
	for index: int in weapon.light_ids.size():
		cycle += CombatCatalog.attack(weapon.light_ids[index]).total_ticks
		if index < weapon.light_ids.size() - 1:
			presses.append(cycle - 4)
	var start: int = 40
	for offset: float in [-1.2, 0.0, 1.2]:
		var net_id: int = _server.add_fake_player(_brain(func(tick: int, _position: Vector3,
				_yaw: float) -> PlayerInput:
			var input := PlayerInput.new()
			input.tick = tick
			input.look_yaw = YAW_EAST
			var phase: int = (tick - start) % cycle if tick >= start else -1
			for press: int in presses:
				if phase >= press and phase < press + 2:
					input.buttons = PlayerInput.PRIMARY
			return input), VARDHEIM)
		_put(net_id, Vector3(77.5, 0.05, offset), YAW_EAST)
	await _advance(75 * 60)
	assert_true(_state().is_gate_broken(), "broken in under 75 s")
	var first_hit: int = -1
	var broken_tick: int = -1
	for event: NetMessages.EntityEvent in _events_of(NetMessages.EntityEvent.Kind.HIT):
		if event.net_id == _server.get_fortresses().get_net_id(FORTRESS):
			if first_hit < 0:
				first_hit = event.tick
			if event.has_hit_flag(NetMessages.EntityEvent.HIT_FLAG_LETHAL):
				broken_tick = event.tick
	assert_true(first_hit > 0 and broken_tick > first_hit)
	var seconds: float = float(broken_tick - first_hit) / 60.0
	assert_true(seconds > 50.0 and seconds < 60.0,
			"three attackers break it in about 55 s (it took %.1f s)" % seconds)
	assert_eq(_war_ids(), [WarEvents.UNDER_ATTACK, WarEvents.GATE_BROKEN] as Array[int],
			"a single attack alert and the break one")


func test_the_owner_does_not_damage_its_own_gate_but_its_enemies_do() -> void:
	await _start_server()
	_server.console_command("fort_owner vardheim")
	var friend: int = _gate_attacker(VARDHEIM, 12, Vector3(77.5, 0.05, -1.0))
	var enemy: int = _gate_attacker(SOLMARCH, 100, Vector3(77.5, 0.05, 1.0))
	await _advance(60)
	assert_eq(_state().gate_health, 900, "the owner does not damage it")
	await _advance(80)
	assert_eq(_state().gate_health, 900 - _slash(90), "its enemy does")
	assert_true(friend != enemy)


func test_a_closed_gate_stops_the_enemies_of_the_owner_and_a_broken_one_stops_nobody() -> void:
	await _start_server(false)
	_server.console_command("fort_owner vardheim")
	var walkers: Array[int] = []
	for realm: int in [VARDHEIM, SOLMARCH]:
		var net_id: int = _server.add_fake_player(_brain(func(tick: int, _position: Vector3,
				_yaw: float) -> PlayerInput:
			var input := PlayerInput.new()
			input.tick = tick
			input.look_yaw = YAW_EAST
			input.move = Vector2(0.0, 1.0)
			return input), realm)
		walkers.append(net_id)
	_put(walkers[0], Vector3(74.0, 0.05, -1.0), YAW_EAST)
	_put(walkers[1], Vector3(74.0, 0.05, 1.0), YAW_EAST)
	await wait_physics_frames(150)
	var gate_x: float = FortressFixture.gate_position().x
	assert_true(_server.get_registry().get_entity(walkers[0]).get_position().x > gate_x + 1.0,
			"the owner crosses their closed gate")
	assert_true(_server.get_registry().get_entity(walkers[1]).get_position().x < gate_x,
			"their enemy stays on the other side")
	# Once broken, it stops no one: the enemy keeps walking and crosses.
	var target: StructureTarget = _server.get_fortresses().get_structure_targets()[0]
	_server.get_fortresses().on_structure_hit(target, _combatant(walkers[1]), 900, _server.get_tick() + 1)
	await wait_physics_frames(150)
	assert_true(_gate().is_broken())
	assert_true(_server.get_registry().get_entity(walkers[1]).get_position().x > gate_x + 1.0,
			"with the gate broken the enemy crosses too")


func test_the_gate_repair_waits_for_the_doorway_to_be_free() -> void:
	await _start_server()
	var blocker: int = _idle_player(VARDHEIM, FortressFixture.gate_position() + Vector3(0.0, 0.05, 1.0))
	var target: StructureTarget = _server.get_fortresses().get_structure_targets()[0]
	_server.get_fortresses().on_structure_hit(target, _combatant(blocker), 900, 1)
	await _advance(21 * 60 + 30)
	assert_true(_gate().is_broken(), "20 s without damage, but someone occupies the doorway")
	assert_true(_server.get_fortresses().is_repair_pending(FORTRESS))
	_server.teleport(blocker, Vector3(60.0, 0.05, 0.0))
	await _advance(3)
	assert_false(_gate().is_broken(), "with the doorway free, the gate is repaired")
	assert_eq(_state().gate_health, 900)


# --- Respawning at the fort --------------------------------------------------------------------

## Kills [param net_id], waits for the wave, asks to respawn at [param point_index] and waits for it to
## happen. With [param attacked] it marks the fort as attacked right before asking.
func _die_and_respawn_at(net_id: int, point_index: int, attacked: bool = false) -> void:
	_server.console_command("kill %d" % net_id)
	await _advance(2)
	var combatant: Combatant = _combatant(net_id)
	var wait_ticks: int = combatant.respawn_tick - _server.get_tick() - 6
	await _advance(maxi(wait_ticks, 0))
	if attacked:
		_state().on_defender_damaged(_server.get_tick(), SOLMARCH)
	assert_eq(_server.get_combat().request_respawn(net_id, point_index, _server.get_tick() + 1),
			CombatDirector.RespawnRequestResult.ACCEPTED)
	await _advance(10)


func _respawn_events(net_id: int) -> Array[NetMessages.EntityEvent]:
	var found: Array[NetMessages.EntityEvent] = []
	for event: NetMessages.EntityEvent in _events_of(NetMessages.EntityEvent.Kind.RESPAWN):
		if event.net_id == net_id:
			found.append(event)
	return found


func test_a_player_respawns_in_the_fort_of_its_realm_and_not_in_an_enemy_one() -> void:
	await _start_server()
	_server.console_command("fort_owner vardheim")
	var ally: int = _idle_player(VARDHEIM, Vector3(-20.0, 0.05, 6.0))
	var enemy: int = _idle_player(SOLMARCH, Vector3(20.0, 0.05, 6.0))
	await _advance(5)
	await _die_and_respawn_at(ally, 2)
	var inner: Vector3 = FortressFixture.ORIGIN + FortressFixture.INNER_POINTS_LOCAL[0]
	assert_vec_near(_server.get_registry().get_entity(ally).get_position(), inner, 1.0,
			"Vardheim respawns inside its fort")
	assert_eq(_respawn_events(ally)[0].point, 2, "with the index from the static list")
	await _die_and_respawn_at(enemy, 2)
	assert_vec_near(_server.get_registry().get_entity(enemy).get_position(), FortressFixture.SOLMARCH_CAMP,
			1.0, "Solmarch cannot choose Vardheim's fort and respawns at its camp")
	assert_eq(_respawn_events(enemy)[0].point, 1, "no alert: the event carries the camp")


func test_a_neutral_or_attacked_fort_is_not_a_respawn_point() -> void:
	await _start_server()
	var player: int = _idle_player(VARDHEIM, Vector3(-20.0, 0.05, 6.0))
	await _advance(5)
	await _die_and_respawn_at(player, 2)
	assert_vec_near(_server.get_registry().get_entity(player).get_position(), FortressFixture.VARDHEIM_CAMP,
			1.0, "a neutral fort is not valid")
	# Its own but under attack: not valid either.
	_server.console_command("fort_owner vardheim")
	await _advance(3)
	await _die_and_respawn_at(player, 3, true)
	assert_eq(_respawn_events(player).back().point, 0, "attacked: the camp")
	# After 5 s without attacks, it is valid again.
	await _die_and_respawn_at(player, 3)
	assert_eq(_respawn_events(player).back().point, 3, "calm again: the fort")


func test_respawns_come_in_waves_every_ten_seconds() -> void:
	await _start_server()
	var player: int = _idle_player(VARDHEIM, Vector3(-20.0, 0.05, 6.0))
	await _advance(100)
	_server.console_command("kill %d" % player)
	await _advance(2)
	var combatant: Combatant = _combatant(player)
	assert_eq(combatant.respawn_tick % 600, 0, "it happens in a wave")
	assert_true(combatant.respawn_tick >= combatant.death_tick + 600, "at least 10 s after dying")
	assert_true(combatant.respawn_tick < combatant.death_tick + 1200, "and no more than 20 s")
	# A request made shortly before the wave stays pending and is fulfilled in that wave, not earlier.
	await _advance(combatant.respawn_tick - _server.get_tick() - 8)
	assert_eq(_server.get_combat().request_respawn(player, 0, _server.get_tick() + 1),
			CombatDirector.RespawnRequestResult.ACCEPTED)
	await _advance(4)
	assert_true(combatant.is_dead(), "the wave has not come out yet")
	await _advance(8)
	assert_true(combatant.is_alive(), "has already respawned")
	assert_eq(_events_of(NetMessages.EntityEvent.Kind.RESPAWN).size(), 1)


# Phase 4 review (war): the automatic respawn of someone who does not ask for it also happens in a wave (before, exactly
# 30 s after death: tick 1901 with the death at 101).
func test_the_automatic_respawn_of_someone_who_does_not_ask_also_comes_in_a_wave() -> void:
	await _start_server()
	var player: int = _idle_player(VARDHEIM, Vector3(-20.0, 0.05, 6.0))
	# Like a person who does not press the button: without the fake players' request.
	_combatant(player).requests_respawn_on_death = false
	await _advance(100)
	_server.console_command("kill %d" % player)
	await _advance(2)
	var death_tick: int = _combatant(player).death_tick
	assert_eq(_combatant(player).pending_respawn_point, -1, "does not ask for it")
	await _advance(2500)
	var respawns: Array[NetMessages.EntityEvent] = _respawn_events(player)
	if not assert_eq(respawns.size(), 1, "respawns by itself"):
		return
	assert_eq(respawns[0].tick % CombatTiming.WAVE_TICKS, 0, "in a wave (tick %d)" % respawns[0].tick)
	assert_true(respawns[0].tick >= death_tick + 1800, "30 s or more after death")
	assert_true(respawns[0].tick < death_tick + 1800 + CombatTiming.WAVE_TICKS, "in the first wave from then")
	assert_eq(respawns[0].point, 0, "at its camp")


func test_a_fake_player_asks_for_its_respawn_and_comes_back_in_its_first_wave() -> void:
	await _start_server()
	var player: int = _idle_player(VARDHEIM, Vector3(-20.0, 0.05, 6.0))
	await _advance(100)
	_server.console_command("kill %d" % player)
	await _advance(2)
	var respawn_tick: int = _combatant(player).respawn_tick
	assert_eq(respawn_tick % CombatTiming.WAVE_TICKS, 0)
	await _advance(2500)
	var respawns: Array[NetMessages.EntityEvent] = _respawn_events(player)
	if not assert_eq(respawns.size(), 1, "respawns once"):
		return
	assert_eq(respawns[0].tick, respawn_tick, "in its first wave, like someone who presses the button as soon as they can")
	assert_eq(respawns[0].point, 0, "at its camp")


# --- Scoreboard and battle log ----------------------------------------------------------------

func test_kills_deaths_assists_and_the_scoreboard_rows() -> void:
	await _start_server()
	var killer: int = _idle_player(VARDHEIM, Vector3(-20.0, 0.05, 4.0))
	var helper: int = _idle_player(VARDHEIM, Vector3(-20.0, 0.05, 8.0))
	var victim: int = _idle_player(SOLMARCH, Vector3(20.0, 0.05, 4.0))
	var combat: CombatDirector = _server.get_combat()
	combat.event_emitted.emit(NetMessages.EntityEvent.death(victim, 50, killer, 1), PackedInt32Array())
	combat.event_emitted.emit(NetMessages.EntityEvent.kill(victim, 50, killer, 1,
			PackedInt32Array([helper])), PackedInt32Array())
	var scores: ScoreKeeper = _server.get_scores()
	assert_eq(scores.get_entry(killer).kills, 1)
	assert_eq(scores.get_entry(helper).assists, 1)
	assert_eq(scores.get_entry(victim).deaths, 1)
	var rows: Array[NetMessages.ScoreRow] = scores.build_rows([killer, helper, victim] as Array[int])
	assert_eq(rows[0].merits, 10, "a kill is worth 10 merit points")
	assert_eq(rows[1].merits, 5, "an assist, 5")
	assert_eq(rows[2].merits, 0)
	# An NPC that kills or dies does not enter the scoreboard.
	var npc: int = _server.add_npc(_brain(), "Hueco", 0, Vector3(0.0, 0.05, 20.0), 0.0)
	combat.event_emitted.emit(NetMessages.EntityEvent.death(npc, 60, killer, 1), PackedInt32Array())
	assert_null(scores.get_entry(npc))
	# Leaving the world forgets the scoreboard entry of whoever leaves.
	assert_true(_server.remove_npc(npc))


func test_the_battle_log_records_the_war_events_and_the_deaths() -> void:
	await _start_server(true, null, func(config: ServerConfig) -> void:
		config.battle_log_path = BATTLE_LOG_FILE)
	var captain: int = _server.spawn_captain_double(FORTRESS)
	var attacker: int = _idle_player(VARDHEIM, FortressFixture.circle_center())
	var victim: int = _idle_player(SOLMARCH, Vector3(20.0, 0.05, 4.0))
	assert_true(captain > 0)
	_server.console_command("fort_kill_captain")
	await _advance(240)
	_server.console_command("kill %d" % victim)
	await _advance(30)
	assert_true(attacker > 0)
	_server.stop()
	var text: String = FileAccess.get_file_as_string(BATTLE_LOG_FILE)
	var lines: PackedStringArray = text.strip_edges().split("\n")
	assert_true(lines.size() >= 5, "the log has lines (%d)" % lines.size())
	var first: Dictionary = JSON.parse_string(lines[0])
	assert_eq(first["event"], "battle_start")
	assert_eq(first["zone"], "test_world")
	assert_eq((first["fortresses"] as Array)[0]["id"], String(FORTRESS))
	var war_keys: Array[String] = []
	var deaths: Array[Dictionary] = []
	for line: String in lines:
		var entry: Dictionary = JSON.parse_string(line)
		if entry["event"] == "war":
			war_keys.append(entry["war"])
		elif entry["event"] == "death":
			deaths.append(entry)
	assert_eq(war_keys, ["captain_down", "capture_started", "fort_captured"] as Array[String])
	assert_true(deaths.size() >= 2, "the captain's death and the player's")
	var player_deaths: int = 0
	for death: Dictionary in deaths:
		if death["victim_kind"] == "player":
			player_deaths += 1
			assert_eq(death["victim_realm"], SOLMARCH)
			assert_eq((death["position"] as Array).size(), 3)
	assert_eq(player_deaths, 1)
	var summary: Dictionary = BattleSummary.summarize(text)
	assert_eq((summary["captures"] as Array).size(), 1)


func test_the_report_lists_the_fortress_and_the_war_counters() -> void:
	await _start_server()
	_server.console_command("fort_owner vardheim")
	await _advance(10)
	assert_eq(_server.write_report(REPORT_FILE), OK)
	var report: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(REPORT_FILE))
	var war: Dictionary = report["war"]
	var fortresses: Array = war["fortresses"]
	if assert_eq(fortresses.size(), 1):
		assert_eq(fortresses[0]["id"], String(FORTRESS))
		assert_eq(int(fortresses[0]["owner"]), VARDHEIM)
		assert_eq(int(fortresses[0]["gate_health"]), 900)
	assert_true(war.has("unstuck") and war.has("lingering_total") and war.has("scoreboards_sent"))
	# The server writes the final report after stop(): the fortress is still in it.
	_server.stop()
	assert_eq(_server.write_report(REPORT_FILE), OK)
	var final_report: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(REPORT_FILE))
	var final_fortresses: Array = (final_report["war"] as Dictionary)["fortresses"]
	if assert_eq(final_fortresses.size(), 1, "after shutdown, the report still lists the fortress"):
		assert_eq(int(final_fortresses[0]["owner"]), VARDHEIM)
