extends TestCase
## Tests of the [NpcSpawnerSystem] (MUN-09 to MUN-12, GUE-11; docs/fortress.md 4.3): the zone's spawners create the
## Hollow, the Ford Captain, the owner's garrison and the Gate Guardians; NPCs respawn on the exact
## tick, are withdrawn when the spawner is deactivated, the fortress controller learns of its captain and its
## defenders, and the Hollow return at full health if nobody approaches within two minutes. Some tests use the real Vado Gris
## (its mesh, its markers and its fort) and others the flat zone with a short-timed fortress.

const VARDHEIM: int = NetProtocol.Realm.VARDHEIM
const SOLMARCH: int = NetProtocol.Realm.SOLMARCH
const FORTRESS: StringName = FortressFixture.FORTRESS_ID

var _rig: NpcRig = null


func before_each() -> void:
	_rig = NpcRig.new()


func after_each() -> void:
	if _rig != null:
		await _rig.stop()
	_rig = null


# --- Ayudantes (zona plana con una fortaleza de pruebas) ---------------------------------------

## Test fortress with two Hollow, the Captain and, if [param guardian_respawn_s] is greater than 0, a Guardian
## of Vardheim with that respawn.
func _start_fort_zone(guardian_respawn_s: float = 0.0, captain_respawn_s: float = 30.0) -> void:
	await _rig.start_flat(tree, func(world: Node3D) -> void:
		var definition: FortressDefinition = FortressFixture.make_definition()
		definition.captain_respawn_s = captain_respawn_s
		var fort: Node3D = FortressFixture.add_fortress(world, definition)
		FortressFixture.add_respawn_points(world)
		var neutral: Dictionary = {&"condition": NpcSpawner.Condition.FORT_NEUTRAL, &"alert_group": &"fortaleza"}
		NpcRig.add_spawner(fort, "Hueco1", &"hollow", Vector3(-14.0, 0.05, -10.0), PI * 0.5, neutral)
		NpcRig.add_spawner(fort, "Hueco2", &"hollow", Vector3(-14.0, 0.05, 10.0), PI * 0.5, neutral)
		NpcRig.add_spawner(fort, "Capitan", &"ford_captain", FortressFixture.CAPTAIN_LOCAL, PI * 0.5, neutral)
		if guardian_respawn_s > 0.0:
			NpcRig.add_spawner(world, "Guardian", &"gate_guardian", Vector3(-100.0, 0.05, 0.0), 0.0,
					{&"respawn_s": guardian_respawn_s, &"realm": &"vardheim"}))
	assert_true(await _rig.advance_until_populated(), "the NPCs appear")


func _kill(net_id: int) -> void:
	_rig.server.get_combat().kill(_rig.combatant(net_id), _rig.server.get_tick() + 1)


func _spawner(node_name: String) -> NpcSpawner:
	for node: Node3D in _rig.npcs().get_spawners():
		if node.name == node_name:
			return node as NpcSpawner
	return null


func _state() -> FortressState:
	return _rig.server.get_fortresses().get_fortress_state(FORTRESS)


func _alive_realm(definition_id: StringName, realm: int) -> Array[int]:
	var found: Array[int] = []
	for net_id: int in _rig.alive_of(definition_id):
		if _rig.entity(net_id).realm == realm:
			found.append(net_id)
	return found


func _entity_exists(net_id: int) -> bool:
	return _rig.server.get_registry().get_entity(net_id) != null


# --- The real zone ----------------------------------------------------------------------------

func test_the_vado_gris_spawns_the_hollows_the_captain_and_the_gate_guardians() -> void:
	await _rig.start(tree)
	var npcs: NpcSpawnerSystem = _rig.npcs()
	if not assert_not_null(npcs, "the server creates the NPC system"):
		return
	assert_eq(npcs.get_slot_count(), 4 + 1 + 4 + 5, "4 Hollow, the Captain, 4 Guardians and 5 garrison posts")
	assert_true(await _rig.advance_until_populated(), "the NPCs appear when navigation is ready")
	assert_true(npcs.is_ready() and npcs.get_navigation() != null, "with the navigation mesh mounted")
	assert_eq(_rig.alive_of(&"hollow").size(), 4, "cuatro Huecos")
	assert_eq(_rig.alive_of(&"ford_captain").size(), 1, "the Ford Captain")
	assert_eq(_rig.alive_of(&"gate_guardian").size(), 4, "two Guardians per camp")
	assert_eq(npcs.get_alive_count(), 9)
	assert_eq(_rig.alive_of(&"realm_guard").size() + _rig.alive_of(&"realm_captain").size(), 0,
			"the owner's garrison does not exist with the fort neutral")
	var captain_id: int = _rig.alive_of(&"ford_captain")[0]
	assert_eq(_rig.server.get_fortresses().get_captain_net_id(_rig.FORTRESS), captain_id,
			"the fortress knows its captain")
	assert_eq(_rig.entity(captain_id).display_name, "Capitán del Vado")
	assert_eq(_rig.combatant(captain_id).max_health, NpcCatalog.get_definition(&"ford_captain").max_health,
			"with the health from its definition")
	assert_eq(_rig.entity(captain_id).realm, 0, "neutral")
	var camps: Dictionary = {VARDHEIM: 0, SOLMARCH: 0}
	for guardian_id: int in _rig.alive_of(&"gate_guardian"):
		assert_true(_rig.combatant(guardian_id).ignores_safe_area, "the Guardians ignore the safe zone")
		camps[_rig.entity(guardian_id).realm] += 1
	assert_eq(camps, {VARDHEIM: 2, SOLMARCH: 2}, "dos de cada reino")
	for hollow_id: int in _rig.alive_of(&"hollow"):
		assert_eq(_rig.combatant(hollow_id).max_health, NpcCatalog.get_definition(&"hollow").max_health)
		assert_eq(_rig.character(hollow_id).combat.weapon_id, CombatCatalog.weapon_id(&"npc_hollow"), "with its weapon")
		assert_eq(_rig.entity(hollow_id).kind, NetProtocol.EntityKind.NPC)
		assert_eq(_rig.fort_node().global_position.distance_to(_rig.entity(hollow_id).get_position()) < 25.0, true,
				"inside the fort")


func test_a_spawned_npc_announces_its_catalog_number_in_its_spawn_message() -> void:
	await _rig.start(tree)
	assert_true(await _rig.advance_until_populated())
	var hollow: NetEntity = _rig.entity(_rig.alive_of(&"hollow")[0])
	var bytes: PackedByteArray = hollow.encode_spawn(_rig.server.get_tick(), false)
	var spawn: NetMessages.EntitySpawn = NetMessages.EntitySpawn.decode(bytes)
	if not assert_not_null(spawn, "the NPC's SPAWN is decoded"):
		return
	assert_eq(spawn.kind, NetProtocol.EntityKind.NPC)
	assert_eq(spawn.npc_def_id, NpcCatalog.number_of(&"hollow"), "it carries the number of its definition")
	assert_eq(spawn.display_name, "Hueco")
	assert_true(BossInfo.is_boss(NpcCatalog.number_of(&"ford_captain")), "and the client knows the Captain is a boss")
	assert_false(BossInfo.is_boss(spawn.npc_def_id))


func test_the_gate_guardians_kill_an_intruder_in_the_safe_area_in_under_ten_seconds() -> void:
	await _rig.start(tree)
	assert_true(await _rig.advance_until_populated())
	var camp: Vector3 = _camp_position(&"vardheim")
	var friend: int = _rig.add_player(VARDHEIM, camp + Vector3(0.0, 0.1, 5.0))
	var outsider: int = _rig.add_player(SOLMARCH, camp + Vector3(0.0, 0.1, 28.0))
	for offset: Vector3 in [Vector3(0.0, 0.1, 8.0), Vector3(10.0, 0.1, 10.0), Vector3(0.0, 0.1, 22.0)]:
		var intruder: int = _rig.add_player(SOLMARCH, camp + offset)
		var started: int = _rig.server.get_tick()
		var dead: bool = await _rig.advance_until(func() -> bool: return _rig.combatant(intruder).is_dead(), 600, 3)
		assert_true(dead, "the intruder in %s dies in under 10 s" % offset)
		print("[guardianes] intruso en %s muerto a los %.1f s" % [offset, float(_rig.server.get_tick() - started) / 60.0])
		_rig.server.remove_fake_player(intruder)
		await _rig.advance(120)
	assert_eq(_rig.combatant(friend).health, 1000, "a Vardheim player in their camp takes no damage")
	assert_eq(_rig.combatant(outsider).health, 1000, "nor an enemy outside the safe zone: they do not attack there")
	assert_eq(_rig.alive_of(&"gate_guardian").size(), 4, "the Guardians are still alive")


func _camp_position(realm_name: StringName) -> Vector3:
	for marker: Node3D in NetZones.get_safe_areas(_rig.world):
		if NetZones.node_realm_code(marker) == NetZones.realm_from_name(String(realm_name)):
			return marker.global_position
	return Vector3.ZERO


func test_the_hollows_that_patrol_walk_the_walkway_and_come_back() -> void:
	await _rig.start(tree)
	assert_true(await _rig.advance_until_populated())
	var patrollers: Array[int] = []
	for net_id: int in _rig.alive_of(&"hollow"):
		if _rig.npcs().get_brain(net_id).get_route_size() >= 2:
			patrollers.append(net_id)
	assert_eq(patrollers.size(), 2, "two of the four patrol")
	var floor_y: float = _rig.fort_node().global_position.y
	var highest: Dictionary = {}
	for net_id: int in patrollers:
		highest[net_id] = -INF
	var walked: Dictionary = {"states": {}}
	_rig.server.tick_finished.connect(func(_tick: int) -> void:
		for net_id: int in patrollers:
			highest[net_id] = maxf(highest[net_id], _rig.entity(net_id).get_position().y)
			walked["states"][_rig.npcs().get_brain(net_id).state] = true)
	await _rig.advance(60 * 40)
	for net_id: int in patrollers:
		assert_true(highest[net_id] - floor_y > 3.0, "climbs to the walkway (%.1f m above the courtyard)" % (highest[net_id] - floor_y))
	assert_true(walked["states"].has(HfsmBrain.State.PATROL) and walked["states"].has(HfsmBrain.State.REST),
			"alterna patrulla y reposo")
	assert_eq(_rig.alive_of(&"hollow").size(), 4, "without fighting, nobody dies")


func test_the_leash_keeps_the_hollows_on_the_hill_when_a_runner_drags_them_toward_the_ford() -> void:
	await _rig.start(tree)
	assert_true(await _rig.advance_until_populated())
	var fort: Node3D = _rig.fort_node()
	# A runner leaves ahead of the gate toward the ford (to the west) and the fort's NPCs, alerted to it,
	# chase it through the gate link; the leash sends them back to their post before they get off the hill.
	var runner_brain := CombatFixture.ScriptBrain.new(1)
	runner_brain.script_fn = func(tick: int, _position: Vector3, _yaw: float) -> PlayerInput:
		var input := PlayerInput.new()
		input.tick = tick
		input.look_yaw = PI * 0.5
		input.move = Vector2(0.0, 1.0)
		return input
	var start: Vector3 = _surface_at(Vector2(fort.global_position.x - 30.0, 0.0))
	var runner: int = _rig.add_player(VARDHEIM, start + Vector3(0.0, 0.1, 0.0), runner_brain, PI * 0.5)
	_rig.combatant(runner).protected_until = 0
	var chasers: Array[int] = _rig.alive_of(&"hollow") + _rig.alive_of(&"ford_captain")
	for net_id: int in chasers:
		assert_true(_rig.npcs().get_brain(net_id).receive_alert(runner, _rig.server.get_tick()), "alertado")
	var farthest: Dictionary = {"from_post": 0.0, "west": INF, "returning": false}
	_rig.server.tick_finished.connect(func(_tick: int) -> void:
		for net_id: int in chasers:
			var brain: HfsmBrain = _rig.npcs().get_brain(net_id)
			var position: Vector3 = _rig.entity(net_id).get_position()
			farthest["from_post"] = maxf(farthest["from_post"], position.distance_to(brain.get_home()))
			farthest["west"] = minf(farthest["west"], position.x)
			if brain.state == HfsmBrain.State.RETURN:
				farthest["returning"] = true)
	await _rig.advance(60 * 40)
	var leash: float = NpcCatalog.get_definition(&"ford_captain").leash_radius
	assert_true(farthest["from_post"] > 18.0, "they left the fort after it (up to %.1f m from their post)" % farthest["from_post"])
	assert_true(farthest["from_post"] <= leash + 5.0, "but no farther than their leash (%.1f m of %.1f)" % [farthest["from_post"], leash])
	assert_true(farthest["west"] > fort.global_position.x - 56.0, "and none reached the ford (x = %.1f)" % farthest["west"])
	assert_true(farthest["returning"], "volvieron, regenerados e inmunes")
	for net_id: int in chasers:
		assert_true(_rig.npcs().get_brain(net_id).state != HfsmBrain.State.COMBAT or _rig.entity(net_id).get_position().distance_to(
				_rig.npcs().get_brain(net_id).get_home()) <= leash, "none keeps fighting outside its leash")


## First ground (world layer) that is hit going down from above at ([param point].x, .y).
func _surface_at(point: Vector2) -> Vector3:
	var space: PhysicsDirectSpaceState3D = _rig.world.get_world_3d().direct_space_state
	var from: Vector3 = Vector3(point.x, 60.0, point.y)
	var query := PhysicsRayQueryParameters3D.create(from, from + Vector3(0.001, -120.0, 0.0),
			PlayerCharacter.WORLD_COLLISION_LAYER)
	var hit: Dictionary = space.intersect_ray(query)
	return hit["position"] if not hit.is_empty() else Vector3(point.x, 0.0, point.y)


func test_two_or_three_bots_clear_the_hollows_in_a_reasonable_time() -> void:
	# The Captain, who joins the fight through the shout, is measured separately: here fallen, as if he had already been defeated.
	await _rig.start(tree)
	assert_true(await _rig.advance_until_populated())
	_rig.server.console_command("fort_kill_captain")
	await _rig.advance(30)
	var fort: Node3D = _rig.fort_node()
	for index: int in 3:
		_rig.add_player(VARDHEIM, fort.global_position + Vector3(6.0, 0.1, -4.0 + 4.0 * index),
				BotBrain.new(11 + index, BotBrain.Pattern.COMBAT))
	var started: int = _rig.server.get_tick()
	var cleared: bool = await _rig.advance_until(func() -> bool: return _rig.alive_of(&"hollow").is_empty(), 60 * 120, 30)
	var seconds: float = float(_rig.server.get_tick() - started) / 60.0
	print("[huecos] 3 bots limpian los 4 Huecos en %.1f s de juego" % seconds)
	assert_true(cleared, "the Hollow fall")
	assert_true(seconds < 90.0, "en menos de 90 s (%.1f s)" % seconds)
	assert_true(seconds > 15.0, "y no en un suspiro (%.1f s)" % seconds)


func test_four_bots_that_do_not_die_beat_the_ford_captain_in_a_reasonable_time() -> void:
	# The bots neither dodge nor block with judgment: a group of four falls before taking half its health off
	# (and the Captain, with nobody, returns regenerated). To measure how long the fight lasts for the damage that has to be
	# dealt to him, their health is healed every tick, like a group that knows how to defend itself.
	await _rig.start(tree)
	assert_true(await _rig.advance_until_populated())
	for hollow_id: int in _rig.alive_of(&"hollow"):
		_kill(hollow_id)
	await _rig.advance(30)
	var fort: Node3D = _rig.fort_node()
	var bots: Array[Combatant] = []
	for index: int in 4:
		var bot: int = _rig.add_player(VARDHEIM, fort.global_position + Vector3(6.0, 0.1, -6.0 + 4.0 * index),
				BotBrain.new(31 + index, BotBrain.Pattern.COMBAT))
		bots.append(_rig.combatant(bot))
	_rig.server.tick_finished.connect(func(_tick: int) -> void:
		for bot: Combatant in bots:
			if bot.is_alive():
				bot.health = bot.max_health)
	var started: int = _rig.server.get_tick()
	var cleared: bool = await _rig.advance_until(func() -> bool: return _rig.alive_of(&"ford_captain").is_empty(), 60 * 180, 30)
	var seconds: float = float(_rig.server.get_tick() - started) / 60.0
	print("[capitán] 4 bots que no mueren derrotan al Capitán del Vado en %.1f s de juego" % seconds)
	assert_true(cleared, "the Captain falls")
	assert_true(seconds > 40.0 and seconds < 150.0, "between 40 and 150 s (%.1f s)" % seconds)
	# With the new keep (ART-57, 9.9 m footprint) the bots fight the Captain on the west face, inside
	# the circle: as soon as he dies, the circle is open and it already captures (before, with the 6 m tower, they
	# attacked from outside and the phase was VULNERABLE on that tick).
	var phase: int = _rig.state().phase
	assert_true(phase == FortressState.Phase.VULNERABLE or phase == FortressState.Phase.CAPTURING,
			"his death opens the capture circle (phase %d)" % phase)
	assert_false(_rig.state().captain_alive)


func test_the_captain_returns_regenerated_when_the_party_dies() -> void:
	await _rig.start(tree)
	assert_true(await _rig.advance_until_populated())
	var captain: int = _rig.alive_of(&"ford_captain")[0]
	var fort: Node3D = _rig.fort_node()
	var victim: int = _rig.add_player(VARDHEIM, fort.global_position + Vector3(-6.0, 0.1, 6.0))
	_rig.combatant(captain).health = 15000
	var engaged: bool = await _rig.advance_until(func() -> bool:
		return _rig.npcs().get_brain(captain).state == HfsmBrain.State.COMBAT, 600)
	assert_true(engaged, "the Captain enters combat")
	_rig.server.get_combat().kill(_rig.combatant(victim), _rig.server.get_tick() + 1)
	var back: bool = await _rig.advance_until(func() -> bool:
		return _rig.npcs().get_brain(captain).state == HfsmBrain.State.REST, 1800)
	assert_true(back, "with nobody to hit, he returns to his post")
	assert_eq(_rig.combatant(captain).health, 30000, "fully regenerated")
	assert_eq(_rig.alive_of(&"ford_captain"), [captain] as Array[int], "it is the same one")


# --- Respawn, withdrawal and registry (flat zone) ----------------------------------------------------

func test_a_dead_guardian_comes_back_at_the_exact_tick_and_its_corpse_goes_away() -> void:
	await _start_fort_zone(2.0)
	var spawned: Array[Vector2i] = []
	var died: Array[Array] = []
	_rig.npcs().npc_spawned.connect(func(net_id: int, _spawner: Node) -> void:
		spawned.append(Vector2i(net_id, _rig.server.get_tick())))
	_rig.npcs().npc_died.connect(func(net_id: int, spawner: Node, killer: int) -> void:
		died.append([net_id, spawner, killer]))
	var guardians: Array[int] = _rig.alive_of(&"gate_guardian")
	assert_eq(guardians.size(), 1, "a Guardian")
	var first: int = guardians[0]
	var kill_tick: int = _rig.server.get_tick() + 1
	_rig.server.get_combat().kill(_rig.combatant(first), kill_tick)
	assert_eq(died.size(), 1, "the death is announced with npc_died")
	assert_eq(died[0][0], first)
	assert_eq(died[0][1], _spawner("Guardian"), "with the spawner it came from")
	assert_eq(died[0][2], 0, "and without a killer: it died by an order")
	await _rig.advance(119)
	assert_true(_rig.alive_of(&"gate_guardian").is_empty(), "119 ticks later it has not returned yet")
	assert_true(spawned.is_empty())
	await _rig.advance(kill_tick + 120 - _rig.server.get_tick())
	assert_eq(spawned.size(), 1, "vuelve")
	assert_eq(spawned[0].y, kill_tick + 120, "on the exact tick: death + 2 s")
	var second: int = _rig.alive_of(&"gate_guardian")[0]
	assert_true(second != first, "it is a new NPC")
	assert_true(_entity_exists(first), "the corpse stays there for a few seconds")
	await _rig.advance(NpcSpawnerSystem.CORPSE_TICKS)
	assert_false(_entity_exists(first), "and is withdrawn after %d ticks" % NpcSpawnerSystem.CORPSE_TICKS)
	assert_true(_entity_exists(second))


func test_a_spawner_with_two_slots_replaces_each_dead_npc_at_its_own_tick() -> void:
	await _rig.start_flat(tree, func(world: Node3D) -> void:
		NpcRig.add_spawner(world, "Pareja", &"hollow", Vector3(0.0, 0.05, 0.0), 0.0,
				{&"respawn_s": 3.0, &"max_alive": 2}))
	assert_true(await _rig.advance_until_populated())
	var spawned: Array[int] = []
	_rig.npcs().npc_spawned.connect(func(_net_id: int, _spawner: Node) -> void:
		spawned.append(_rig.server.get_tick()))
	var pair: Array[int] = _rig.alive_of(&"hollow")
	assert_eq(pair.size(), 2, "two at once")
	var first_death: int = _rig.server.get_tick() + 1
	_rig.server.get_combat().kill(_rig.combatant(pair[0]), first_death)
	await _rig.advance(40)
	var second_death: int = _rig.server.get_tick() + 1
	_rig.server.get_combat().kill(_rig.combatant(pair[1]), second_death)
	await _rig.advance(400)
	assert_eq(spawned, [first_death + 180, second_death + 180] as Array[int], "each one returns 3 s after dying")
	assert_eq(_rig.alive_of(&"hollow").size(), 2)


func test_npcs_do_not_come_back_on_their_own_through_the_combat_director() -> void:
	await _start_fort_zone()
	var hollow: int = _rig.alive_of(&"hollow")[0]
	_kill(hollow)
	await _rig.advance(60)
	assert_true(_rig.combatant(hollow).is_dead())
	await _rig.advance(NpcSpawnerSystem.CORPSE_TICKS + 30)
	assert_false(_entity_exists(hollow), "the corpse is withdrawn")
	await _rig.advance(2100)
	assert_eq(_rig.alive_of(&"hollow").size(), 1, "the Hollow do not respawn on their own (the fortress replenishes them)")
	for event: NetMessages.EntityEvent in _rig.events_of(NetMessages.EntityEvent.Kind.RESPAWN):
		assert_true(_rig.entity(event.net_id) == null or _rig.entity(event.net_id).kind != NetProtocol.EntityKind.NPC,
				"no NPC receives a combat RESPAWN")


func test_deactivating_a_spawner_removes_the_living_npcs_and_the_owners_garrison_takes_over() -> void:
	await _start_fort_zone(2.0)
	var guardian: int = _rig.alive_of(&"gate_guardian")[0]
	var hollows: Array[int] = _rig.alive_of(&"hollow")
	var captain: int = _rig.alive_of(&"ford_captain")[0]
	assert_eq(hollows.size(), 2)
	assert_eq(_state().guards_alive, 0, "neutral: there is no garrison")
	assert_eq(_rig.server.get_fortresses().get_captain_net_id(FORTRESS), captain)
	_rig.server.console_command("fort_owner vardheim")
	await _rig.advance(3)
	for net_id: int in hollows + [captain]:
		assert_false(_entity_exists(net_id), "the Hollow NPCs are withdrawn once the fort has an owner")
	assert_true(_entity_exists(guardian), "the Guardian, which does not depend on the fort, remains")
	var guards: Array[int] = _alive_realm(&"realm_guard", VARDHEIM)
	assert_eq(guards.size(), 2, "the two Hollow posts give two guards of the owning realm")
	var new_captain: Array[int] = _alive_realm(&"realm_captain", VARDHEIM)
	assert_eq(new_captain.size(), 1, "and the Captain's post, the realm's captain")
	assert_eq(_state().guards_alive, 2, "the fortress knows how many guards there are")
	assert_eq(_rig.server.get_fortresses().get_captain_net_id(FORTRESS), new_captain[0],
			"and who its captain is")
	for net_id: int in guards + new_captain:
		assert_eq(_rig.entity(net_id).realm, VARDHEIM)
	# It changes hands: Vardheim's garrison is withdrawn and Solmarch's arrives.
	_rig.server.console_command("fort_owner solmarch")
	await _rig.advance(3)
	for net_id: int in guards + new_captain:
		assert_false(_entity_exists(net_id), "the previous owner's garrison is withdrawn")
	assert_eq(_alive_realm(&"realm_guard", SOLMARCH).size(), 2)
	assert_eq(_alive_realm(&"realm_captain", SOLMARCH).size(), 1)
	# A reset brings back the Hollow and the Ford Captain.
	_rig.server.console_command("fort_reset")
	await _rig.advance(3)
	assert_eq(_rig.alive_of(&"hollow").size(), 2, "the Hollow return")
	assert_eq(_rig.alive_of(&"ford_captain").size(), 1, "and the Ford Captain")
	assert_eq(_rig.alive_of(&"realm_guard").size(), 0, "without a realm garrison")
	assert_true(_entity_exists(guardian))


func test_the_fortress_learns_about_its_captain_and_its_defenders() -> void:
	await _start_fort_zone()
	var captain: int = _rig.alive_of(&"ford_captain")[0]
	var attacker: int = _rig.add_player(VARDHEIM, Vector3(60.0, 0.1, 0.0))
	var hollow: int = _rig.alive_of(&"hollow")[0]
	assert_eq(_state().phase, FortressState.Phase.GARRISONED)
	# A blow to a defender marks the fort as attacked.
	var before: int = _state().under_attack_until_tick
	_rig.events.clear()
	var hit: NetMessages.EntityEvent = NetMessages.EntityEvent.hit(hollow, _rig.server.get_tick() + 1, attacker, 10, 0, 0, 0)
	_rig.server.get_combat().event_emitted.emit(hit, PackedInt32Array([hollow, attacker]))
	assert_true(_state().under_attack_until_tick > before, "hitting a Hollow marks the fort as attacked")
	# The captain's death opens the circle.
	var died: Array[Array] = []
	_rig.npcs().npc_died.connect(func(net_id: int, spawner: Node, killer: int) -> void:
		died.append([net_id, spawner, killer]))
	_kill(captain)
	await _rig.advance(3)
	assert_eq(_state().phase, FortressState.Phase.VULNERABLE, "with the captain dead, the circle activates")
	assert_false(_state().captain_alive)
	assert_eq(died.size(), 1)
	assert_eq(died[0][0], captain)
	assert_eq(_rig.server.get_fortresses().get_captain_net_id(FORTRESS), 0, "it no longer has a registered captain")


func test_a_real_capture_replaces_the_hollows_with_the_owners_garrison_after_consolidation() -> void:
	await _start_fort_zone()
	for hollow_id: int in _rig.alive_of(&"hollow"):
		_kill(hollow_id)
	_rig.server.console_command("fort_kill_captain")
	await _rig.advance(10)
	assert_eq(_state().phase, FortressState.Phase.VULNERABLE)
	var circle: Vector3 = FortressFixture.circle_center()
	var capturer: int = _rig.add_player(VARDHEIM, circle + Vector3(0.0, 0.1, 0.0))
	var captured: bool = await _rig.advance_until(func() -> bool: return _state().owner == VARDHEIM, 600, 6)
	assert_true(captured, "the realm that occupies the circle captures the fort")
	assert_eq(_state().phase, FortressState.Phase.CONSOLIDATING)
	assert_eq(_rig.alive_of(&"realm_guard").size(), 0, "during consolidation there is no garrison")
	assert_eq(_rig.alive_of(&"realm_captain").size(), 0)
	var garrisoned: bool = await _rig.advance_until(func() -> bool:
		return _state().phase == FortressState.Phase.GARRISONED, 600, 6)
	assert_true(garrisoned, "after 2 s of consolidation the garrison arrives")
	await _rig.advance(6)
	var guards: Array[int] = _alive_realm(&"realm_guard", VARDHEIM)
	assert_eq(guards.size(), 2, "the owning realm's guards")
	assert_eq(_alive_realm(&"realm_captain", VARDHEIM).size(), 1, "and its captain")
	assert_eq(_state().guards_alive, 2)
	assert_true(_state().captain_alive)
	assert_eq(_rig.combatant(capturer).health, 1000, "its own side does not attack it")
	# A dead guard is replenished after the fortress's guard_respawn_s (10 s in the test one).
	_kill(guards[0])
	await _rig.advance(3)
	assert_eq(_state().guards_alive, 1, "the fortress notices it")
	await _rig.advance(60 * 9)
	assert_eq(_alive_realm(&"realm_guard", VARDHEIM).size(), 1, "at 9 s not yet")
	await _rig.advance(60 * 2 + 20)
	assert_eq(_alive_realm(&"realm_guard", VARDHEIM).size(), 2, "tras 10 s vuelve")
	assert_eq(_state().guards_alive, 2)
	var guards_before: Array[int] = _alive_realm(&"realm_guard", VARDHEIM)
	# If the realm's captain falls, only he returns after captain_respawn_s (30 s).
	var owners_captain: int = _alive_realm(&"realm_captain", VARDHEIM)[0]
	_kill(owners_captain)
	await _rig.advance(3)
	assert_eq(_state().phase, FortressState.Phase.VULNERABLE, "his death opens the circle again")
	await _rig.advance(60 * 30)
	assert_eq(_state().phase, FortressState.Phase.GARRISONED, "without a capture, the captain returns")
	var back: Array[int] = _alive_realm(&"realm_captain", VARDHEIM)
	assert_eq(back.size(), 1, "the realm's captain respawns")
	assert_true(back[0] != owners_captain)
	assert_eq(_alive_realm(&"realm_guard", VARDHEIM), guards_before, "the guards are untouched")


func test_the_hollows_and_the_captain_come_back_whole_after_two_minutes_with_nobody_near() -> void:
	# The captain does not return on his own (his delay is very long): the full respawn brings him back.
	await _start_fort_zone(0.0, 100000.0)
	var hollows: Array[int] = _rig.alive_of(&"hollow")
	_kill(hollows[0])
	_rig.server.console_command("fort_kill_captain")
	await _rig.advance(10)
	assert_eq(_state().phase, FortressState.Phase.VULNERABLE)
	assert_eq(_rig.alive_of(&"hollow").size(), 1)
	# A player 30 m from the fort prevents the full respawn while they stay close.
	var near: int = _rig.add_player(VARDHEIM, FortressFixture.circle_center() + Vector3(-30.0, 0.1, 0.0))
	await _rig.advance(NpcSpawnerSystem.FULL_RESPAWN_EMPTY_TICKS + 600)
	assert_eq(_rig.alive_of(&"hollow").size(), 1, "with someone at 30 m they do not return")
	assert_eq(_state().phase, FortressState.Phase.VULNERABLE)
	# They move farther than 40 m away: the count starts.
	_rig.server.teleport(near, FortressFixture.circle_center() + Vector3(-60.0, 0.1, 0.0))
	await _rig.advance(NpcSpawnerSystem.FULL_RESPAWN_EMPTY_TICKS - 600)
	assert_eq(_rig.alive_of(&"hollow").size(), 1, "before 2 min, no")
	await _rig.advance(1200)
	assert_eq(_rig.alive_of(&"hollow").size(), 2, "after 2 min the Hollow return")
	assert_eq(_rig.alive_of(&"ford_captain").size(), 1, "and the Ford Captain")
	assert_eq(_state().phase, FortressState.Phase.GARRISONED, "with the fort guarded again")
	assert_true(_state().captain_alive)
	assert_eq(_rig.server.get_fortresses().get_captain_net_id(FORTRESS), _rig.alive_of(&"ford_captain")[0])
	assert_eq(_rig.npcs().get_report()["full_respawns"], 1)


# Phase 4 review (war): the Captain calls his reinforcements once per life (returning regenerated to his post does not
# rearm the call) and the full respawn withdraws any that remain and gives him the call back.
func test_the_captain_calls_his_reinforcements_once_per_life_and_the_full_respawn_takes_them_away() -> void:
	await _start_fort_zone()
	var captain: int = _rig.alive_of(&"ford_captain")[0]
	assert_eq(_rig.alive_of(&"hollow").size(), 2)
	for cycle: int in 3:
		await _failed_assault(captain)
		assert_eq(_rig.alive_of(&"hollow").size(), 4,
				"assault %d: the two Hollow and the two reinforcements of the single call" % (cycle + 1))
	assert_eq(_rig.npcs().get_report()["reinforcements"], 2, "a single call in three assaults")
	assert_true(_rig.npcs().get_brain(captain).has_called_reinforcements())
	assert_true(_rig.npcs().force_full_respawn(FORTRESS, _rig.server.get_tick()))
	await _rig.advance(30)
	assert_eq(_rig.alive_of(&"hollow").size(), 2, "the full respawn leaves them at full health, without reinforcements")
	assert_eq(_rig.alive_of(&"ford_captain"), [captain] as Array[int], "with the same Captain")
	assert_false(_rig.npcs().get_brain(captain).has_called_reinforcements(), "who can call them again")
	await _failed_assault(captain)
	assert_eq(_rig.alive_of(&"hollow").size(), 4, "and calls them in the next assault")
	assert_eq(_rig.npcs().get_report()["reinforcements"], 4)


func test_a_new_captain_does_not_add_reinforcements_while_the_previous_ones_live() -> void:
	await _start_fort_zone(0.0, 2.0)
	var first: int = _rig.alive_of(&"ford_captain")[0]
	await _failed_assault(first)
	assert_eq(_rig.alive_of(&"hollow").size(), 4, "the first Captain calls two")
	_kill(first)
	var replaced: bool = await _rig.advance_until(func() -> bool:
		var captains: Array[int] = _rig.alive_of(&"ford_captain")
		return captains.size() == 1 and captains[0] != first, 1200)
	if not assert_true(replaced, "another Captain returns"):
		return
	var second: int = _rig.alive_of(&"ford_captain")[0]
	await _failed_assault(second)
	assert_true(_rig.npcs().get_brain(second).has_called_reinforcements(), "the new one calls too")
	assert_eq(_rig.alive_of(&"hollow").size(), 4, "but with the previous two alive it adds no more")
	assert_eq(_rig.npcs().get_report()["reinforcements"], 2)


# A failed assault: a Vardheim player fights the Captain, who is below half health, and dies;
# the Captain returns to his post regenerated. The player appears 3 m from the post (within what the Captain hears: after a
# return he rests facing where he came from and would not see anyone behind his back).
func _failed_assault(captain: int) -> void:
	var post: Vector3 = _rig.npcs().get_brain(captain).get_home()
	var player: int = _rig.add_player(VARDHEIM, post + Vector3(-3.0, 0.1, 0.0))
	_rig.combatant(captain).health = 14000
	var engaged: bool = await _rig.advance_until(func() -> bool:
		return _rig.npcs().get_brain(captain).state == HfsmBrain.State.COMBAT, 600)
	assert_true(engaged, "the Captain enters combat")
	await _rig.advance(60)
	_kill(player)
	await _rig.advance(2)
	_rig.server.remove_fake_player(player)
	var back: bool = await _rig.advance_until(func() -> bool:
		return _rig.npcs().get_brain(captain).state == HfsmBrain.State.REST \
				and _rig.combatant(captain).health == _rig.combatant(captain).max_health, 3600)
	assert_true(back, "the Captain returns regenerated")


func test_without_the_npc_system_the_zone_has_no_npcs() -> void:
	await _rig.start_flat(tree, func(world: Node3D) -> void:
		NpcRig.add_spawner(world, "Solo", &"hollow", Vector3(0.0, 0.05, 0.0)),
		func(config: ServerConfig) -> void: config.no_npcs = true)
	assert_null(_rig.server.get_npc_system(), "--no-npcs turns the system off")
	await _rig.advance(60)
	assert_eq(_rig.server.get_registry().size(), 0, "and no NPC appears")
	assert_eq(_rig.server.get_dummy_count(), 0)


func test_a_definition_override_only_changes_the_npcs_of_this_server() -> void:
	# F6b: the short siege tests need weaker NPCs without touching data/npcs/ or the process catalog.
	await _rig.start_flat(tree, func(world: Node3D) -> void:
		NpcRig.add_spawner(world, "Solo", &"hollow", Vector3(0.0, 0.05, 0.0), 0.0, {&"respawn_s": 1.0}))
	var weak: NpcDefinition = NpcCatalog.get_definition(&"hollow").duplicate() as NpcDefinition
	weak.max_health = 700
	_rig.npcs().set_definition_override(&"hollow", weak)
	assert_eq(_rig.npcs().get_definition(&"hollow"), weak, "the system gives the substitute")
	assert_true(await _rig.advance_until_populated(), "the Hollow appears")
	var hollow: int = _rig.alive_of(&"hollow")[0]
	assert_eq(_rig.combatant(hollow).max_health, 700, "with the substitute's health")
	assert_eq(_rig.entity(hollow).npc_def_id, NpcCatalog.number_of(&"hollow"), "and the catalog number")
	assert_eq(NpcCatalog.get_definition(&"hollow").max_health, 2500, "the catalog does not change")
	# Without the substitution, the next one is the one from the data again.
	_rig.npcs().set_definition_override(&"hollow", null)
	_kill(hollow)
	await _rig.advance(120)
	var again: Array[int] = _rig.alive_of(&"hollow")
	if assert_eq(again.size(), 1, "reaparece"):
		assert_eq(_rig.combatant(again[0]).max_health, 2500, "with the health from data/npcs/")


func test_the_report_counts_the_npcs() -> void:
	await _start_fort_zone()
	_kill(_rig.alive_of(&"hollow")[0])
	await _rig.advance(60)
	var path: String = "res://build/test_npc_report.json"
	assert_eq(_rig.server.write_report(path), OK)
	var report: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(path))
	var npcs: Dictionary = report.get("npcs", {})
	assert_eq(int(npcs.get("slots", 0)), 6, "the fort's posts: 3 Hollow and 3 garrison")
	assert_eq(int(npcs.get("spawned", 0)), 3)
	assert_eq(int(npcs.get("died", 0)), 1)
	assert_eq(int(npcs.get("alive", 0)), 2)
