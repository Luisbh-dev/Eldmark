extends TestCase
## The [FortressController] alone, with no server or network (docs/fuerte.md, sections 1 to 3; GUE-08, GUE-10,
## GUE-12 and GUE-13): advanced by hand, tick by tick, with fake players placed inside or outside the
## circle. It checks presence (every 6 ticks, alive, connected and active), a full neutral -> Vardheim -> Solmarch
## capture with the Hollows' captain and the owner's, the dispute and the
## decays, consolidation, the OBJECT_STATE rate, the gate layers from the next
## tick, the repair deferred while someone occupies the doorway, the war notices in order, the
## interface with the NPCs, the periodic reset and the debug commands.

const VARDHEIM: int = NetProtocol.Realm.VARDHEIM
const SOLMARCH: int = NetProtocol.Realm.SOLMARCH
const ASKARRA: int = NetProtocol.Realm.ASKARRA
const FORTRESS: StringName = FortressFixture.FORTRESS_ID

var _viewport: SubViewport
var _world: Node3D
var _registry: NetEntityRegistry
var _controller: FortressController
var _definition: FortressDefinition
var _war: Array[NetMessages.EntityEvent] = []
var _object_states: Array[NetMessages.ObjectState] = []
# Signals for the NPCs: [signal, tick, data...].
var _npc_signals: Array[Array] = []
# Fake players: net_id -> {realm, position, alive, connected, idle}.
var _players: Dictionary = {}
var _bodies: PackedVector3Array = PackedVector3Array()
var _tick: int = 0
var _scores: ScoreKeeper


func before_each() -> void:
	await _build(FortressFixture.make_definition())


func after_each() -> void:
	if is_instance_valid(_viewport):
		_viewport.get_parent().remove_child(_viewport)
		_viewport.free()
	_viewport = null
	_world = null
	_controller = null
	_war.clear()
	_object_states.clear()
	_npc_signals.clear()
	_players.clear()
	_bodies = PackedVector3Array()
	_tick = 0
	await wait_process_frames()


# --- Helpers ----------------------------------------------------------------------------------

func _build(definition: FortressDefinition) -> void:
	if is_instance_valid(_viewport):
		_viewport.get_parent().remove_child(_viewport)
		_viewport.free()
	_war.clear()
	_object_states.clear()
	_npc_signals.clear()
	_players.clear()
	_tick = 0
	_viewport = SubViewport.new()
	_viewport.own_world_3d = true
	_viewport.size = Vector2i(64, 64)
	tree.root.add_child(_viewport)
	_world = ZoneFixture.build_flat_zone(_viewport)
	_definition = definition
	FortressFixture.add_fortress(_world, definition)
	await wait_physics_frames(2)
	_registry = NetEntityRegistry.new()
	_scores = ScoreKeeper.new()
	_controller = FortressController.new()
	_controller.score_keeper = _scores
	_controller.setup(_world, _registry, 0)
	_controller.candidates_source = _make_candidates
	_controller.bodies_source = func() -> PackedVector3Array: return _bodies
	_controller.war_event_emitted.connect(func(event: NetMessages.EntityEvent) -> void:
		_war.append(event))
	_controller.object_state_emitted.connect(func(object_state: NetMessages.ObjectState) -> void:
		_object_states.append(object_state))
	_controller.defenders_retired.connect(func(id: StringName, tick: int) -> void:
		_npc_signals.append([&"retired", tick, id]))
	_controller.garrison_due.connect(func(id: StringName, owner_realm: int, tick: int, full: bool) -> void:
		_npc_signals.append([&"garrison", tick, id, owner_realm, full]))
	_controller.guards_respawn_due.connect(func(id: StringName, tick: int) -> void:
		_npc_signals.append([&"guards", tick, id]))


## Presence candidates: one [FortressController.PlayerCandidate] per fake player, with the last
## input on the current tick (except the \"idle\" ones).
func _make_candidates(tick: int) -> Array:
	var list: Array = []
	for net_id: int in _players:
		var data: Dictionary = _players[net_id]
		var candidate: FortressController.PlayerCandidate = FortressController.PlayerCandidate \
				.make_player(net_id, data["realm"], data["position"],
				0 if data.get("idle", false) else tick)
		candidate.alive = data.get("alive", true)
		candidate.connected = data.get("connected", true)
		list.append(candidate)
	return list


func _put(net_id: int, realm: int, position: Vector3, extra: Dictionary = {}) -> void:
	var data: Dictionary = {"realm": realm, "position": position}
	data.merge(extra)
	_players[net_id] = data


func _inside(offset: Vector3 = Vector3.ZERO) -> Vector3:
	return FortressFixture.circle_center() + offset


func _run(ticks: int) -> void:
	for _i: int in ticks:
		_tick += 1
		_controller.step(_tick)


func _state() -> FortressState:
	return _controller.get_fortress_state(FORTRESS)


func _gate() -> FortGate:
	return _controller.get_gate(FORTRESS)


func _war_ids() -> Array[int]:
	var ids: Array[int] = []
	for event: NetMessages.EntityEvent in _war:
		ids.append(event.war_event)
	return ids


func _war_realms() -> Array[int]:
	var realms: Array[int] = []
	for event: NetMessages.EntityEvent in _war:
		realms.append(event.war_realm)
	return realms


func _signal_names() -> Array[StringName]:
	var names: Array[StringName] = []
	for entry: Array in _npc_signals:
		names.append(entry[0])
	return names


## A fighter of [param realm] to hit the gate.
func _fighter(net_id: int, realm: int) -> Combatant:
	return CombatFixture.make_fighter(_world, net_id, realm, Vector3.ZERO, 0.0,
			CombatTiming.from_rules(CombatCatalog.rules()))


func _hit_gate(attacker: Combatant, amount: int, tick: int) -> void:
	_controller.on_structure_hit(_controller.get_structure_targets()[0], attacker, amount, tick)


# --- Registration ------------------------------------------------------------------------------

func test_setup_creates_the_structure_entity_and_the_gate_target() -> void:
	assert_true(_controller.has_fortresses())
	assert_eq(_controller.get_fortress_ids(), [FORTRESS] as Array[StringName])
	var entity: NetEntity = _controller.get_entity(FORTRESS)
	if not assert_not_null(entity, "the fortress has its entity"):
		return
	assert_eq(entity.kind, NetProtocol.EntityKind.STRUCTURE)
	assert_true((entity.flags & NetEntity.FLAG_ALWAYS_RELEVANT) != 0, "all the players see it")
	assert_eq(_registry.get_entity(entity.net_id), entity, "it is in the zone registry")
	var circle: Dictionary = _controller.get_circle(FORTRESS)
	assert_vec_near(circle["center"], FortressFixture.circle_center(), 1e-4, "center of the marker")
	assert_eq(circle["radius"], 5.0, "the radius comes from the marker")
	var state: FortressState = _state()
	assert_eq(state.owner, 0, "neutral")
	assert_eq(state.phase, FortressState.Phase.GARRISONED)
	assert_eq(state.gate_health, 900)
	var targets: Array[StructureTarget] = _controller.get_structure_targets()
	if assert_eq(targets.size(), 1, "the gate is a target"):
		assert_eq(targets[0].net_id, entity.net_id)
		assert_vec_near(targets[0].box.origin, FortressFixture.gate_position() + Vector3(0.0, 2.15, 0.0),
				1e-4, "the gate's box, in place")
		assert_vec_near(targets[0].half_extents, Vector3(0.25, 2.15, 2.0), 1e-4)
		assert_eq(targets[0].exclude.size(), 2, "the gate's two bodies")
		assert_true(targets[0].can_be_hit_by(VARDHEIM), "a neutral fort can be damaged by any realm")
		assert_false(targets[0].can_be_hit_by(0), "but not by the Hollows")


func test_the_spawn_message_carries_the_whole_state_of_the_fortress() -> void:
	var entity: NetEntity = _controller.get_entity(FORTRESS)
	var spawn: NetMessages.EntitySpawn = NetMessages.EntitySpawn.decode(entity.encode_spawn(7, false))
	if not assert_not_null(spawn, "the structure's SPAWN decodes"):
		return
	assert_eq(spawn.kind, NetProtocol.EntityKind.STRUCTURE)
	assert_eq(spawn.net_id, entity.net_id)
	assert_eq(spawn.definition_id, String(FORTRESS))
	assert_eq(spawn.spawn_tick, 7)
	assert_eq(spawn.fields.size(), FortressFields.all_ids().size(), "the 17 fields")
	var client_state: FortressState = FortressState.initial(_definition, 0)
	spawn.to_object_state().apply_to_fortress(client_state)
	assert_eq(client_state.gate_health, 900)
	assert_eq(client_state.owner, 0)


func test_a_definition_with_a_bad_id_or_a_repeated_one_is_skipped() -> void:
	var repeated: FortressDefinition = FortressFixture.make_definition()
	var node := Node3D.new()
	_world.add_child(node)
	assert_eq(_controller.add_fortress(node, repeated, 0), 0, "the same id is not registered twice")
	var other: FortressDefinition = FortressFixture.make_definition()
	other.id = &"camión"
	assert_eq(_controller.add_fortress(node, other, 0), 0, "an id that is not ASCII does not fit in the protocol")
	assert_eq(_controller.get_fortress_ids().size(), 1)


# --- Presence ----------------------------------------------------------------------------------

func test_presence_is_counted_every_six_ticks_and_only_for_live_connected_active_players() -> void:
	# Near tick 3600 (60 s): whoever has never sent a real input has already been quiet too long.
	_tick = 3594
	_put(1, VARDHEIM, _inside())
	_put(2, VARDHEIM, _inside(Vector3(1.0, 0.0, 1.0)))
	_put(3, SOLMARCH, _inside(Vector3(40.0, 0.0, 0.0)))
	_put(4, SOLMARCH, _inside(), {"alive": false})
	_put(5, SOLMARCH, _inside(), {"connected": false})
	_put(6, ASKARRA, _inside(), {"idle": true})
	_run(5)
	assert_eq(_state().presence, PackedInt32Array([0, 0, 0, 0]), "it is not yet time to recount (tick 6)")
	_run(1)
	assert_eq(_state().presence, PackedInt32Array([0, 2, 0, 0]),
			"two from Vardheim; the one outside, the dead one, the disconnected one and the one that sends no inputs do not count")
	# One player enters and another leaves: it is not noticed until the next count.
	_put(7, SOLMARCH, _inside())
	_players.erase(2)
	_run(5)
	assert_eq(_state().presence, PackedInt32Array([0, 2, 0, 0]), "it is held between counts")
	_run(1)
	assert_eq(_state().presence, PackedInt32Array([0, 1, 1, 0]), "and updated at tick 12")
	assert_eq(_controller.get_presence(FORTRESS), PackedInt32Array([0, 1, 1, 0]))


func test_presence_has_the_cylinder_shape_and_the_activity_timeout() -> void:
	_tick = 3594
	_put(1, VARDHEIM, _inside(Vector3(4.9, 0.0, 0.0)))
	_put(2, VARDHEIM, _inside(Vector3(5.1, 0.0, 0.0)))
	_put(3, VARDHEIM, _inside(Vector3(0.0, 4.5, 0.0)))
	_put(4, VARDHEIM, _inside(Vector3(0.0, -0.9, 0.0)))
	_put(5, VARDHEIM, _inside(Vector3(0.0, -1.5, 0.0)))
	_run(6)
	assert_eq(_state().presence[VARDHEIM], 2, "the edge of the radius and 0.9 m below; not 5.1 m, 4.5 m high or 1.5 below")
	# Whoever stops sending inputs for 60 s stops counting.
	_players.clear()
	_put(8, VARDHEIM, _inside())
	_run(6)
	assert_eq(_state().presence[VARDHEIM], 1)
	_players[8]["idle"] = true
	_run(6)
	assert_eq(_state().presence[VARDHEIM], 0, "without real inputs it does not count")


# --- The capture machine: neutral -> Vardheim -> Solmarch ---------------------------------------

func test_a_full_capture_neutral_to_vardheim_to_solmarch_with_both_captains() -> void:
	var mirror: FortressState = FortressState.initial(_definition, 0)
	# Neutral fort, guarded by the Hollows: with the circle inactive, being inside does not capture.
	_put(1, VARDHEIM, _inside())
	_run(30)
	assert_eq(_state().phase, FortressState.Phase.GARRISONED, "with the captain alive the circle does not count")
	assert_true(_war.is_empty(), "and there are no notices")
	# The Hollows' captain falls at the hands of Vardheim.
	assert_true(_controller.on_captain_died(FORTRESS, _tick + 1, VARDHEIM))
	_run(1)
	_run(6)
	assert_eq(_state().phase, FortressState.Phase.CAPTURING, "with a single realm inside the capture starts")
	assert_eq(_state().capture_realm, VARDHEIM)
	assert_eq(_state().capture_rate, 12, "one attacker: 12 per tick")
	# 120 ticks (2 s) with one attacker.
	_run(130)
	assert_eq(_state().owner, VARDHEIM, "captured")
	assert_eq(_state().phase, FortressState.Phase.CONSOLIDATING)
	assert_eq(_gate().get_owner_realm(), VARDHEIM, "the gate is now Vardheim's")
	assert_eq(_gate().collision_layer, FortGate.layers_for(VARDHEIM, false), "and its layers, those of its enemies")
	# The circle does not count during consolidation: a Solmarch inside does nothing.
	_put(2, SOLMARCH, _inside(Vector3(1.0, 0.0, 0.0)))
	_players.erase(1)
	_run(60)
	assert_eq(_state().phase, FortressState.Phase.CONSOLIDATING)
	assert_eq(_state().capture_realm, 0)
	# Consolidation passes (120 ticks) and Vardheim's garrison and captain arrive.
	_run(80)
	assert_eq(_state().phase, FortressState.Phase.GARRISONED, "Vardheim's garrison and captain")
	assert_true(_state().captain_alive)
	# Vardheim's captain (the second captain) falls and Solmarch, who was already inside, captures.
	assert_true(_controller.on_captain_died(FORTRESS, _tick + 1, SOLMARCH))
	_run(1)
	_run(6)
	assert_eq(_state().phase, FortressState.Phase.CAPTURING)
	assert_eq(_state().capture_realm, SOLMARCH)
	_run(130)
	assert_eq(_state().owner, SOLMARCH, "captured by Solmarch")
	assert_eq(_gate().get_owner_realm(), SOLMARCH)
	_run(125)
	assert_eq(_state().phase, FortressState.Phase.GARRISONED, "and Solmarch's garrison arrives")
	_run(6)
	assert_eq(_war_ids(), [WarEvents.CAPTAIN_DOWN, WarEvents.CAPTURE_STARTED, WarEvents.FORT_CAPTURED,
			WarEvents.CAPTAIN_DOWN, WarEvents.CAPTURE_STARTED, WarEvents.FORT_CAPTURED] as Array[int],
			"the notices, in the order they happen")
	assert_eq(_war_realms(), [VARDHEIM, VARDHEIM, VARDHEIM, SOLMARCH, SOLMARCH, SOLMARCH] as Array[int],
			"with the realm that accompanies each one")
	for event: NetMessages.EntityEvent in _war:
		assert_eq(event.net_id, _controller.get_net_id(FORTRESS), "tied to the fortress")
	assert_eq(_signal_names(), [&"retired", &"garrison", &"retired", &"garrison"] as Array[StringName],
			"the NPCs: the previous owner's are removed and the new one's garrison appears")
	# The client rebuilds the same with the OBJECT_STATEs.
	for object_state: NetMessages.ObjectState in _object_states:
		object_state.apply_to_fortress(mirror)
	assert_eq(mirror.owner, SOLMARCH)
	assert_eq(mirror.phase, _state().phase)
	assert_eq(mirror.capture_progress_at_start, _state().capture_progress_at_start)
	assert_eq(mirror.gate_health, 900)


func test_the_garrison_signals_say_who_and_how_much_to_spawn() -> void:
	_put(1, VARDHEIM, _inside())
	_controller.on_captain_died(FORTRESS, 1, VARDHEIM)
	_run(150)
	_run(140)
	var garrison: Array = _npc_signals[_signal_names().find(&"garrison")]
	assert_eq(garrison[2], FORTRESS)
	assert_eq(garrison[3], VARDHEIM, "the garrison belongs to the new owner")
	assert_true(garrison[4], "whole: guards and captain")
	# If the captain just respawns (nobody captured), the garrison stays standing.
	_npc_signals.clear()
	_controller.on_captain_died(FORTRESS, _tick + 1, SOLMARCH)
	_players.clear()
	_run(31 * 60)
	assert_eq(_state().phase, FortressState.Phase.GARRISONED)
	assert_eq(_signal_names(), [&"garrison"] as Array[StringName])
	assert_false(_npc_signals[0][4], "only the captain returns")


func test_two_attackers_capture_faster_and_a_contested_circle_freezes() -> void:
	_controller.on_captain_died(FORTRESS, 1, VARDHEIM)
	_put(1, VARDHEIM, _inside())
	_put(2, VARDHEIM, _inside(Vector3(1.0, 0.0, 0.0)))
	_run(12)
	assert_eq(_state().capture_rate, 16, "two attackers: 16 per tick")
	# A Solmarch enters: the capture freezes and the dispute notice goes out.
	_put(3, SOLMARCH, _inside(Vector3(-1.0, 0.0, 0.0)))
	_run(12)
	assert_true(_state().contested, "disputed")
	assert_eq(_state().capture_rate, 0, "frozen")
	assert_true(_war_ids().has(WarEvents.CAPTURE_CONTESTED))
	var progress: int = _state().progress_at(float(_tick))
	_run(30)
	assert_eq(_state().progress_at(float(_tick)), progress, "without advancing while it lasts")
	assert_eq(_war_ids().count(WarEvents.CAPTURE_CONTESTED), 1, "the notice goes out on entering the dispute, not every time")
	# The capturers leave: with only the enemy inside, progress rolls back fast.
	_players.erase(1)
	_players.erase(2)
	_run(12)
	assert_eq(_state().capture_rate, -24, "only those who do not capture are there: -24")
	assert_true(_state().progress_at(float(_tick)) < progress, "it rolls back fast")


func test_an_empty_circle_decays_slowly_after_the_delay() -> void:
	_controller.on_captain_died(FORTRESS, 1, VARDHEIM)
	_put(1, VARDHEIM, _inside())
	_run(60)
	var progress: int = _state().progress_at(float(_tick))
	assert_true(progress > 0)
	_players.clear()
	_run(18)
	assert_eq(_state().capture_rate, 0, "first it freezes (until decay_after_empty_s = 1 s)")
	var frozen: int = _state().progress_at(float(_tick))
	assert_true(frozen >= progress, "progress does not roll back while frozen")
	_run(60)
	assert_eq(_state().capture_rate, -4, "then it decays at a third of the base speed")
	assert_true(_state().progress_at(float(_tick)) < frozen, "and rolls back")


func test_the_captain_comes_back_if_nobody_captures() -> void:
	_controller.on_captain_died(FORTRESS, 1, VARDHEIM)
	_run(1)
	assert_eq(_state().phase, FortressState.Phase.VULNERABLE)
	assert_false(_state().captain_alive)
	_run(30 * 60)
	assert_eq(_state().phase, FortressState.Phase.GARRISONED, "at captain_respawn_s it respawns")
	assert_true(_state().captain_alive)


func test_capture_speed_multiplies_the_capture_rate() -> void:
	assert_true(_controller.set_capture_speed(FORTRESS, 10))
	assert_false(_controller.set_capture_speed(FORTRESS, 0), "the factor goes from 1 to 255")
	assert_false(_controller.set_capture_speed(FORTRESS, 256))
	assert_false(_controller.set_capture_speed(&"nadie", 2))
	_controller.on_captain_died(FORTRESS, 1, VARDHEIM)
	_put(1, VARDHEIM, _inside())
	_run(12)
	assert_eq(_state().capture_rate, 120, "12 x 10")
	_run(30)
	assert_eq(_state().owner, VARDHEIM, "the 120-tick capture ends in about 12")


# --- Notices and OBJECT_STATE -----------------------------------------------------------------

func test_object_state_is_sent_at_most_every_six_ticks_with_only_the_changes() -> void:
	_put(1, VARDHEIM, _inside())
	_put(2, SOLMARCH, _inside(Vector3(40.0, 0.0, 0.0)))
	_run(5)
	assert_true(_object_states.is_empty(), "nothing has changed")
	_run(1)
	assert_eq(_object_states.size(), 1, "presence changes at tick 6")
	var first: NetMessages.ObjectState = _object_states[0]
	assert_eq(first.tick, 6)
	assert_eq(first.net_id, _controller.get_net_id(FORTRESS))
	assert_eq(first.fields.size(), 1, "only Vardheim's presence field")
	assert_eq(first.get_value(FortressFields.PRESENCE_BASE + VARDHEIM), 1)
	# More changes, closer together than every 6 ticks, are merged.
	_put(3, VARDHEIM, _inside(Vector3(0.5, 0.0, 0.0)))
	_put(4, VARDHEIM, _inside(Vector3(0.0, 0.0, 0.5)))
	_players.erase(1)
	_run(6)
	assert_eq(_object_states.size(), 2)
	var gaps: Array[int] = []
	for i: int in range(1, _object_states.size()):
		gaps.append(_object_states[i].tick - _object_states[i - 1].tick)
	for gap: int in gaps:
		assert_true(gap >= FortressController.OBJECT_STATE_INTERVAL_TICKS, "at most one every 6 ticks")


func test_the_under_attack_field_is_only_sent_when_it_advances_a_minute() -> void:
	_controller.register_defender(FORTRESS, 99)
	var attacker: NetEntity = _registry.allocate(NetProtocol.EntityKind.PLAYER, 0)
	attacker.realm = VARDHEIM
	var hit := func(tick: int) -> void:
		_controller.on_combat_event(NetMessages.EntityEvent.hit(99, tick, attacker.net_id, 10, 0, 0, 1),
				PackedInt32Array([99, attacker.net_id]))
	_run(99)
	hit.call(100)
	_run(1)
	_run(6)
	var sent: Array[int] = []
	for object_state: NetMessages.ObjectState in _object_states:
		if object_state.has_field(FortressFields.UNDER_ATTACK_UNTIL_TICK):
			sent.append(object_state.get_value(FortressFields.UNDER_ATTACK_UNTIL_TICK))
	assert_eq(sent, [100 + 300] as Array[int], "the first hit marks the fort as attacked for 5 s more")
	# Another hit 10 ticks later: it advances 10 ticks, less than 60. It is not sent.
	hit.call(_tick + 10)
	_run(30)
	var count: int = 0
	for object_state: NetMessages.ObjectState in _object_states:
		if object_state.has_field(FortressFields.UNDER_ATTACK_UNTIL_TICK):
			count += 1
	assert_eq(count, 1, "an advance of less than 60 ticks does not deserve another message")
	# Much later, another hit advances more than 60 ticks: it goes out.
	_run(600)
	hit.call(_tick + 1)
	_run(8)
	count = 0
	for object_state: NetMessages.ObjectState in _object_states:
		if object_state.has_field(FortressFields.UNDER_ATTACK_UNTIL_TICK):
			count += 1
	assert_eq(count, 2)


func test_a_hit_on_a_defender_gives_one_under_attack_notice_per_minute() -> void:
	_controller.register_defender(FORTRESS, 99)
	var attacker: NetEntity = _registry.allocate(NetProtocol.EntityKind.PLAYER, 0)
	attacker.realm = SOLMARCH
	for tick: int in [10, 20, 30]:
		_controller.on_combat_event(NetMessages.EntityEvent.hit(99, tick, attacker.net_id, 10, 0, 0, 1),
				PackedInt32Array())
	assert_eq(_war_ids(), [WarEvents.UNDER_ATTACK] as Array[int], "just one")
	assert_eq(_war_realms(), [SOLMARCH] as Array[int], "with the attacker's realm")
	_controller.on_combat_event(NetMessages.EntityEvent.hit(99, 3700, attacker.net_id, 10, 0, 0, 1),
			PackedInt32Array())
	assert_eq(_war_ids().size(), 2, "after the minute, another")
	# A hit on someone who is not a defender does not count.
	_controller.on_combat_event(NetMessages.EntityEvent.hit(55, 3800, attacker.net_id, 10, 0, 0, 1),
			PackedInt32Array())
	assert_eq(_war_ids().size(), 2)
	assert_true(_state().under_attack_until_tick >= 3700 + 300, "the fort counts as attacked")


# --- The gate ----------------------------------------------------------------------------------

func test_gate_hits_lower_the_health_warn_and_break_the_gate() -> void:
	var attacker: Combatant = _fighter(10, VARDHEIM)
	_run(10)
	_hit_gate(attacker, 300, 11)
	_hit_gate(attacker, 300, 12)
	assert_eq(_state().gate_health, 300)
	assert_eq(_war_ids(), [WarEvents.UNDER_ATTACK] as Array[int], "the first hit warns; the following ones do not")
	assert_eq(_scores.get_entry(10).gate_damage, 600, "damage to the gate counts on the scoreboard")
	_hit_gate(attacker, 300, 13)
	assert_eq(_state().gate_health, 0)
	assert_eq(_war_ids(), [WarEvents.UNDER_ATTACK, WarEvents.GATE_BROKEN] as Array[int])
	assert_eq(_war_realms(), [VARDHEIM, VARDHEIM] as Array[int], "whoever broke it")
	assert_false(_gate().is_broken(), "the layers change at the end of the step, not on the hit")
	_tick = 13
	_run(1)
	assert_true(_gate().is_broken(), "broken from the next tick")
	assert_eq(_gate().collision_layer, 0, "without layers")
	var target: StructureTarget = _controller.get_structure_targets()[0]
	assert_false(target.can_be_hit_by(VARDHEIM), "a broken gate cannot be damaged")


func test_the_first_gate_damage_is_announced_once() -> void:
	var started: Array[int] = []
	_controller.gate_damage_started.connect(func(_id: StringName, tick: int) -> void: started.append(tick))
	var attacker: Combatant = _fighter(10, VARDHEIM)
	_hit_gate(attacker, 10, 5)
	_hit_gate(attacker, 10, 6)
	assert_eq(started, [5] as Array[int])


func test_a_gate_collision_change_goes_out_in_the_same_tick() -> void:
	var attacker: Combatant = _fighter(10, VARDHEIM)
	_run(7)
	_object_states.clear()
	_hit_gate(attacker, 900, 8)
	_run(1)
	if not assert_eq(_object_states.size(), 1, "the breakage goes out right away, without waiting for the 6-tick interval"):
		return
	assert_eq(_object_states[0].tick, 8)
	assert_eq(_object_states[0].get_value(FortressFields.GATE_HEALTH, -1), 0)
	# Repairing it (here with fort_reset) also changes the collision: it goes out on the same tick.
	_controller.reset_fortress(FORTRESS, 9)
	_object_states.clear()
	_run(1)
	assert_eq(_object_states.size(), 1, "repairing the gate goes out on the same tick")
	assert_eq(_object_states[0].tick, 9)
	# A hit that does not break it waits its turn.
	_hit_gate(attacker, 100, 10)
	_run(2)
	assert_eq(_object_states.size(), 1, "a hit that does not break the gate does not go out ahead of time")
	_run(4)
	assert_eq(_object_states.size(), 2, "after the 6-tick interval, it does")
	assert_eq(_object_states[1].get_value(FortressFields.GATE_HEALTH, -1), 800)


func test_a_broken_gate_is_repaired_after_the_delay_without_damage() -> void:
	var attacker: Combatant = _fighter(10, VARDHEIM)
	_hit_gate(attacker, 900, 5)
	_tick = 5
	_run(1)
	assert_true(_gate().is_broken())
	_run(19 * 60)
	assert_true(_gate().is_broken(), "20 s without damage have not passed yet")
	_run(2 * 60)
	assert_false(_gate().is_broken(), "repaired")
	assert_eq(_state().gate_health, 900)
	assert_eq(_gate().collision_layer, FortGate.layers_for(0, false), "closed again for the three realms")


func test_the_repair_waits_while_a_character_overlaps_the_doorway() -> void:
	var attacker: Combatant = _fighter(10, VARDHEIM)
	_hit_gate(attacker, 900, 5)
	_tick = 5
	_run(1)
	var doorway: Vector3 = FortressFixture.gate_position()
	_bodies = PackedVector3Array([doorway + Vector3(0.0, 0.0, 1.0)])
	_run(21 * 60)
	assert_true(_gate().is_broken(), "someone occupies the doorway: the gate stays open")
	assert_true(_controller.is_repair_pending(FORTRESS), "and the repair waits")
	assert_eq(_state().gate_health, 0, "the replicated health stays at 0, like the collision")
	# Someone above, on the walkway, does not hold it back; as soon as the doorway is free, it is repaired.
	_bodies = PackedVector3Array([doorway + Vector3(0.0, 4.4, 0.0), doorway + Vector3(3.0, 0.0, 0.0)])
	_run(1)
	assert_false(_gate().is_broken(), "doorway free, it is repaired on the next tick")
	assert_false(_controller.is_repair_pending(FORTRESS))
	assert_eq(_state().gate_health, 900)


func test_the_repair_after_a_capture_also_waits_for_a_free_doorway() -> void:
	var attacker: Combatant = _fighter(10, VARDHEIM)
	_hit_gate(attacker, 900, 5)
	_tick = 5
	_run(1)
	_bodies = PackedVector3Array([FortressFixture.gate_position()])
	_controller.on_captain_died(FORTRESS, _tick + 1, VARDHEIM)
	_put(1, VARDHEIM, _inside())
	_run(150)
	assert_eq(_state().owner, VARDHEIM, "it is captured even though the gate cannot close")
	assert_true(_gate().is_broken(), "but with someone in the doorway the new gate waits")
	assert_eq(_state().gate_health, 0)
	assert_eq(_gate().get_owner_realm(), VARDHEIM, "it already belongs to its new owner")
	_bodies = PackedVector3Array()
	_run(1)
	assert_false(_gate().is_broken())
	assert_eq(_state().gate_health, 900, "repaired when it becomes free")


# Phase 4 revision (war): only the repair of a broken gate is deferred. That of an intact one does not change the
# collision and, deferred, erased the damage that arrived in the meantime (the owner stayed in the doorway of its gate).
func test_a_whole_gate_is_repaired_at_once_with_someone_in_the_doorway_and_later_damage_stays() -> void:
	var attacker: Combatant = _fighter(10, SOLMARCH)
	assert_true(_controller.set_owner(FORTRESS, VARDHEIM, 1))
	_tick = 1
	_run(1)
	_hit_gate(attacker, 300, 2)
	assert_eq(_state().gate_health, 600)
	# A defender of the owner (crosses its own closed gate) stands still in the doorway.
	_bodies = PackedVector3Array([FortressFixture.gate_position() + Vector3(0.0, 0.05, 1.0)])
	_run(20 * 60 + 30)
	assert_eq(_state().gate_health, 900, "intact, it is repaired on schedule even if someone is in the doorway")
	assert_false(_controller.is_repair_pending(FORTRESS), "with nothing pending")
	_hit_gate(attacker, 500, _tick)
	assert_eq(_state().gate_health, 400)
	_run(5)
	_bodies = PackedVector3Array()
	_run(5)
	assert_eq(_state().gate_health, 400, "the later damage is not erased when the doorway becomes free")
	assert_false(_controller.is_repair_pending(FORTRESS))


func test_a_gate_broken_after_its_repair_came_due_waits_the_whole_delay_from_the_break() -> void:
	var attacker: Combatant = _fighter(10, SOLMARCH)
	assert_true(_controller.set_owner(FORTRESS, VARDHEIM, 1))
	_tick = 1
	_run(1)
	_hit_gate(attacker, 300, 2)
	_bodies = PackedVector3Array([FortressFixture.gate_position() + Vector3(0.0, 0.05, 1.0)])
	_run(20 * 60 + 30)
	_hit_gate(attacker, 900, _tick)
	var broken_at: int = _tick
	assert_true(_state().is_gate_broken(), "broken")
	_run(1)
	assert_true(_gate().is_broken())
	_bodies = PackedVector3Array()
	_run(30)
	assert_true(_gate().is_broken(), "doorway free, it stays broken: no old repair closes it")
	assert_eq(_state().gate_health, 0)
	_run(broken_at + 20 * 60 - _tick - 1)
	assert_true(_gate().is_broken(), "20 s have not passed since the breakage yet")
	_run(2)
	assert_false(_gate().is_broken(), "repaired 20 s after the breakage")
	assert_eq(_state().gate_health, 900)


func test_an_owner_change_with_a_whole_damaged_gate_repairs_it_at_once_with_someone_in_the_doorway() -> void:
	var attacker: Combatant = _fighter(10, VARDHEIM)
	_hit_gate(attacker, 300, 5)
	_tick = 5
	_run(1)
	_bodies = PackedVector3Array([FortressFixture.gate_position() + Vector3(0.0, 0.05, 1.0)])
	assert_true(_controller.set_owner(FORTRESS, SOLMARCH, _tick + 1))
	_run(1)
	assert_eq(_state().gate_health, 900, "intact: the change of owner leaves it repaired")
	assert_false(_controller.is_repair_pending(FORTRESS), "with nothing pending")
	assert_eq(_gate().collision_layer, FortGate.layers_for(SOLMARCH, false), "with the new owner's layers")
	_hit_gate(attacker, 500, _tick)
	_bodies = PackedVector3Array()
	_run(5)
	assert_eq(_state().gate_health, 400, "and the later damage is not erased when the doorway becomes free")


func test_the_owner_change_swaps_which_realms_the_gate_stops() -> void:
	_gate().set_state(0, false)
	assert_eq(_gate().collision_layer, PlayerCharacter.realm_layer(VARDHEIM) | PlayerCharacter.realm_layer(SOLMARCH)
			| PlayerCharacter.realm_layer(ASKARRA), "neutral: all three")
	assert_true(_controller.set_owner(FORTRESS, SOLMARCH, 3))
	_tick = 3
	_run(1)
	assert_eq(_gate().collision_layer, PlayerCharacter.realm_layer(VARDHEIM) | PlayerCharacter.realm_layer(ASKARRA),
			"Solmarch's: stops Vardheim and Askarra")
	var target: StructureTarget = _controller.get_structure_targets()[0]
	assert_false(target.can_be_hit_by(SOLMARCH), "the owner does not damage it")
	assert_true(target.can_be_hit_by(VARDHEIM))
	assert_true(target.can_be_hit_by(ASKARRA))


# --- Interface with the NPCs ------------------------------------------------------------------

func test_guards_that_are_missing_are_due_after_their_respawn_time() -> void:
	_controller.set_guards_alive(FORTRESS, 4)
	_run(10)
	_controller.set_guards_alive(FORTRESS, 3)
	_run(9 * 60)
	assert_false(_signal_names().has(&"guards"), "the 10 s of guard_respawn_s have not passed yet")
	_run(70)
	assert_eq(_signal_names(), [&"guards"] as Array[StringName], "it is time to replenish, and a notice goes out once")
	_run(120)
	assert_eq(_signal_names().size(), 1, "it is not repeated while nobody answers")
	_controller.set_guards_alive(FORTRESS, 4)
	_run(60)
	assert_eq(_signal_names().size(), 1, "with the garrison whole it is no longer needed")


func test_the_registered_captain_opens_the_circle_when_it_dies() -> void:
	var killer: NetEntity = _registry.allocate(NetProtocol.EntityKind.PLAYER, 0)
	killer.realm = SOLMARCH
	_controller.register_captain(FORTRESS, 77)
	assert_eq(_controller.get_captain_net_id(FORTRESS), 77)
	_controller.on_combat_event(NetMessages.EntityEvent.death(77, 20, killer.net_id, 1), PackedInt32Array())
	assert_eq(_state().phase, FortressState.Phase.VULNERABLE)
	assert_eq(_war_ids(), [WarEvents.CAPTAIN_DOWN] as Array[int])
	assert_eq(_war_realms(), [SOLMARCH] as Array[int], "the realm of whoever killed it")
	assert_eq(_controller.get_captain_net_id(FORTRESS), 0, "there is no registered captain anymore")
	# Any other DEATH does nothing.
	_controller.on_combat_event(NetMessages.EntityEvent.death(78, 21, killer.net_id, 1), PackedInt32Array())
	assert_eq(_war_ids().size(), 1)


# --- Reset --------------------------------------------------------------------------------------

func test_the_fortress_goes_back_to_neutral_on_its_own_when_the_definition_says_so() -> void:
	await _build(FortressFixture.make_definition(2.0, 2.0, 3.0))
	_controller.set_owner(FORTRESS, VARDHEIM, 1)
	_tick = 1
	_run(1)
	assert_eq(_state().owner, VARDHEIM)
	_npc_signals.clear()
	_war.clear()
	_run(3 * 60 - 2)
	assert_eq(_state().owner, VARDHEIM, "3 s have not passed since the last reset yet")
	_run(3)
	assert_eq(_state().owner, 0, "goes back to neutral")
	assert_eq(_state().phase, FortressState.Phase.GARRISONED)
	assert_true(_state().captain_alive, "with the Hollows and their Captain")
	assert_eq(_war_ids(), [WarEvents.FORT_RESET] as Array[int])
	assert_eq(_war_realms(), [0] as Array[int])
	assert_eq(_signal_names(), [&"retired", &"garrison"] as Array[StringName])
	assert_eq(_npc_signals[1][3], 0, "the garrison is the neutral one")
	assert_eq(_gate().get_owner_realm(), 0)


func test_a_definition_without_periodic_reset_never_resets() -> void:
	_controller.set_owner(FORTRESS, SOLMARCH, 1)
	_run(60 * 60)
	assert_eq(_state().owner, SOLMARCH)


func test_reset_leaves_the_players_inside_where_they_are() -> void:
	_put(1, VARDHEIM, _inside())
	_controller.on_captain_died(FORTRESS, 1, VARDHEIM)
	_run(30)
	assert_eq(_state().phase, FortressState.Phase.CAPTURING)
	assert_true(_controller.reset_fortress(FORTRESS, _tick + 1))
	_run(1)
	assert_eq(_state().phase, FortressState.Phase.GARRISONED)
	assert_eq(_state().capture_progress_at_start, 0)
	assert_eq(_players[1]["position"], _inside(), "the server moves nobody")
	assert_false(_controller.reset_fortress(&"nadie", 1))


# --- Debug commands ----------------------------------------------------------------------------

func _register_commands() -> CommandRegistry:
	var commands := CommandRegistry.new()
	_controller.register_commands(commands, func() -> int: return _tick + 1)
	return commands


func _peer_at(position: Vector3, realm: int) -> ServerPeer:
	var peer := ServerPeer.new(3)
	peer.display_name = "Ana"
	peer.realm = realm
	var entity: NetEntity = _registry.allocate(NetProtocol.EntityKind.PLAYER, 0)
	entity.realm = realm
	var holder := Node3D.new()
	_world.add_child(holder)
	holder.global_position = position
	entity.node = holder
	peer.entity = entity
	return peer


func test_the_four_commands_are_registered_with_their_fixed_network_ids() -> void:
	var commands: CommandRegistry = _register_commands()
	for command_name: StringName in [&"fort_reset", &"fort_owner", &"fort_kill_captain", &"fort_capture_speed"]:
		assert_true(commands.has_command(command_name), String(command_name))
	var missing: PackedStringArray = commands.missing_network_commands()
	for command_name: String in ["fort_reset", "fort_owner", "fort_kill_captain", "fort_capture_speed"]:
		assert_false(missing.has(command_name), "%s has a network handler" % command_name)
	assert_eq(NetProtocol.DEBUG_COMMAND_IDS[&"fort_reset"], 8)
	assert_eq(NetProtocol.DEBUG_COMMAND_IDS[&"fort_capture_speed"], 11)


func test_network_commands_act_on_the_nearest_fortress_and_validate_their_data() -> void:
	var commands: CommandRegistry = _register_commands()
	var peer: ServerPeer = _peer_at(_inside(), VARDHEIM)
	assert_eq(commands.execute_network(peer, NetProtocol.DEBUG_FORT_OWNER, PackedByteArray([SOLMARCH])),
			CommandRegistry.Result.OK)
	assert_eq(_state().owner, SOLMARCH, "fort_owner solmarch")
	assert_eq(_war_ids(), [WarEvents.FORT_CAPTURED] as Array[int], "warns of the capture")
	assert_eq(commands.execute_network(peer, NetProtocol.DEBUG_FORT_OWNER, PackedByteArray([9])),
			CommandRegistry.Result.BAD_ARGUMENTS, "the realm goes from 0 to 3")
	assert_eq(commands.execute_network(peer, NetProtocol.DEBUG_FORT_OWNER, PackedByteArray()),
			CommandRegistry.Result.BAD_ARGUMENTS, "and carries one byte")
	assert_eq(commands.execute_network(peer, NetProtocol.DEBUG_FORT_CAPTURE_SPEED, PackedByteArray([0])),
			CommandRegistry.Result.BAD_ARGUMENTS, "the factor goes from 1 to 255")
	assert_eq(commands.execute_network(peer, NetProtocol.DEBUG_FORT_CAPTURE_SPEED, PackedByteArray([20])),
			CommandRegistry.Result.OK)
	assert_eq(_state().capture_rate_multiplier, 20)
	assert_eq(commands.execute_network(peer, NetProtocol.DEBUG_FORT_KILL_CAPTAIN, PackedByteArray()),
			CommandRegistry.Result.OK)
	assert_eq(_state().phase, FortressState.Phase.VULNERABLE, "the captain has died")
	assert_eq(_war_realms().back(), VARDHEIM, "at the hands of the realm of whoever ordered it")
	assert_eq(commands.execute_network(peer, NetProtocol.DEBUG_FORT_KILL_CAPTAIN, PackedByteArray()),
			CommandRegistry.Result.REFUSED, "it no longer guarded the fort: rejected without notice")
	assert_eq(commands.execute_network(peer, NetProtocol.DEBUG_FORT_RESET, PackedByteArray()),
			CommandRegistry.Result.OK)
	assert_eq(_state().owner, 0, "fort_reset")
	assert_eq(_state().phase, FortressState.Phase.GARRISONED)
	assert_eq(commands.execute_network(peer, NetProtocol.DEBUG_FORT_RESET, PackedByteArray([1])),
			CommandRegistry.Result.BAD_ARGUMENTS, "carries no data")
	assert_true(commands.audit_total >= 8, "everything is audited")


func test_console_commands_name_the_realm_and_the_fortress() -> void:
	var commands: CommandRegistry = _register_commands()
	assert_eq(commands.execute_console("fort_owner vardheim"), "%s es ahora de Vardheim" % FORTRESS)
	assert_eq(_state().owner, VARDHEIM)
	assert_eq(commands.execute_console("fort_owner Solmarch %s" % FORTRESS), "%s es ahora de Solmarch" % FORTRESS)
	assert_eq(_state().owner, SOLMARCH)
	assert_eq(commands.execute_console("fort_owner neutral"), "%s es ahora de los Huecos" % FORTRESS)
	assert_eq(_state().owner, 0)
	assert_true(commands.execute_console("fort_owner marte").begins_with("Reino desconocido"))
	assert_true(commands.execute_console("fort_owner vardheim nadie").begins_with("No hay ninguna fortaleza"))
	assert_true(commands.execute_console("fort_owner").begins_with("Uso:"))
	assert_eq(commands.execute_console("fort_kill_captain"), "El capitán de %s ha muerto" % FORTRESS)
	assert_eq(_state().phase, FortressState.Phase.VULNERABLE)
	assert_true(commands.execute_console("fort_kill_captain").contains("no está guardando"))
	assert_eq(commands.execute_console("fort_capture_speed 7"), "Captura de %s a x7" % FORTRESS)
	assert_eq(_state().capture_rate_multiplier, 7)
	assert_true(commands.execute_console("fort_capture_speed 300").contains("entre 1 y 255"))
	assert_true(commands.execute_console("fort_capture_speed x").begins_with("Uso:"))
	assert_eq(commands.execute_console("fort_reset"), "%s vuelve a ser neutral" % FORTRESS)
	assert_eq(_state().phase, FortressState.Phase.GARRISONED)


func test_kill_captain_goes_through_the_registered_captain_npc() -> void:
	var killed: Array[int] = []
	_controller.captain_killer = func(net_id: int) -> bool:
		killed.append(net_id)
		return true
	_controller.register_captain(FORTRESS, 77)
	assert_true(_controller.kill_captain(FORTRESS, 5, SOLMARCH))
	assert_eq(killed, [77] as Array[int], "the NPC is killed, the captain is not considered dead")
	assert_eq(_state().phase, FortressState.Phase.GARRISONED, "until its DEATH arrives")
	# Its death with no author arrives: the realm of whoever ordered it killed.
	_controller.on_combat_event(NetMessages.EntityEvent.death(77, 6, 0, 0), PackedInt32Array())
	assert_eq(_state().phase, FortressState.Phase.VULNERABLE)
	assert_eq(_war_realms(), [SOLMARCH] as Array[int])
