extends TestCase
## Pruebas del [NpcSpawnerSystem] (MUN-09 a MUN-12, GUE-11; docs/fuerte.md 4.3): los generadores de la zona crean a los
## Huecos, al Capitán del Vado, a la guarnición del dueño y a los Guardianes de la Puerta; los PNJ reaparecen en el tick
## exacto, se retiran al desactivarse el generador, el controlador de la fortaleza se entera de su capitán y de sus
## defensores y los Huecos vuelven enteros si nadie se acerca en dos minutos. Unas pruebas usan el Vado Gris de verdad
## (su malla, sus marcadores y su fuerte) y otras la zona plana con una fortaleza de tiempos cortos.

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

## Fortaleza de pruebas con dos Huecos, el Capitán y, si [param guardian_respawn_s] es mayor que 0, un Guardián
## de Vardheim con esa reaparición.
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
	assert_true(await _rig.advance_until_populated(), "los PNJ aparecen")


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


# --- La zona de verdad ------------------------------------------------------------------------

func test_the_vado_gris_spawns_the_hollows_the_captain_and_the_gate_guardians() -> void:
	await _rig.start(tree)
	var npcs: NpcSpawnerSystem = _rig.npcs()
	if not assert_not_null(npcs, "el servidor crea el sistema de PNJ"):
		return
	assert_eq(npcs.get_slot_count(), 4 + 1 + 4 + 5, "4 Huecos, el Capitán, 4 Guardianes y 5 puestos de la guarnición")
	assert_true(await _rig.advance_until_populated(), "los PNJ aparecen cuando la navegación está lista")
	assert_true(npcs.is_ready() and npcs.get_navigation() != null, "con la malla de navegación montada")
	assert_eq(_rig.alive_of(&"hollow").size(), 4, "cuatro Huecos")
	assert_eq(_rig.alive_of(&"ford_captain").size(), 1, "el Capitán del Vado")
	assert_eq(_rig.alive_of(&"gate_guardian").size(), 4, "dos Guardianes por campamento")
	assert_eq(npcs.get_alive_count(), 9)
	assert_eq(_rig.alive_of(&"realm_guard").size() + _rig.alive_of(&"realm_captain").size(), 0,
			"la guarnición del dueño no existe con el fuerte neutral")
	var captain_id: int = _rig.alive_of(&"ford_captain")[0]
	assert_eq(_rig.server.get_fortresses().get_captain_net_id(_rig.FORTRESS), captain_id,
			"la fortaleza conoce a su capitán")
	assert_eq(_rig.entity(captain_id).display_name, "Capitán del Vado")
	assert_eq(_rig.combatant(captain_id).max_health, NpcCatalog.get_definition(&"ford_captain").max_health,
			"con la vida de su definición")
	assert_eq(_rig.entity(captain_id).realm, 0, "neutral")
	var camps: Dictionary = {VARDHEIM: 0, SOLMARCH: 0}
	for guardian_id: int in _rig.alive_of(&"gate_guardian"):
		assert_true(_rig.combatant(guardian_id).ignores_safe_area, "los Guardianes ignoran la zona segura")
		camps[_rig.entity(guardian_id).realm] += 1
	assert_eq(camps, {VARDHEIM: 2, SOLMARCH: 2}, "dos de cada reino")
	for hollow_id: int in _rig.alive_of(&"hollow"):
		assert_eq(_rig.combatant(hollow_id).max_health, NpcCatalog.get_definition(&"hollow").max_health)
		assert_eq(_rig.character(hollow_id).combat.weapon_id, CombatCatalog.weapon_id(&"npc_hollow"), "con su arma")
		assert_eq(_rig.entity(hollow_id).kind, NetProtocol.EntityKind.NPC)
		assert_eq(_rig.fort_node().global_position.distance_to(_rig.entity(hollow_id).get_position()) < 25.0, true,
				"dentro del fuerte")


func test_a_spawned_npc_announces_its_catalog_number_in_its_spawn_message() -> void:
	await _rig.start(tree)
	assert_true(await _rig.advance_until_populated())
	var hollow: NetEntity = _rig.entity(_rig.alive_of(&"hollow")[0])
	var bytes: PackedByteArray = hollow.encode_spawn(_rig.server.get_tick(), false)
	var spawn: NetMessages.EntitySpawn = NetMessages.EntitySpawn.decode(bytes)
	if not assert_not_null(spawn, "el SPAWN del PNJ se decodifica"):
		return
	assert_eq(spawn.kind, NetProtocol.EntityKind.NPC)
	assert_eq(spawn.npc_def_id, NpcCatalog.number_of(&"hollow"), "lleva el número de su definición")
	assert_eq(spawn.display_name, "Hueco")
	assert_true(BossInfo.is_boss(NpcCatalog.number_of(&"ford_captain")), "y el cliente sabe que el Capitán es un jefe")
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
		assert_true(dead, "el intruso en %s muere en menos de 10 s" % offset)
		print("[guardianes] intruso en %s muerto a los %.1f s" % [offset, float(_rig.server.get_tick() - started) / 60.0])
		_rig.server.remove_fake_player(intruder)
		await _rig.advance(120)
	assert_eq(_rig.combatant(friend).health, 1000, "un jugador de Vardheim en su campamento no recibe daño")
	assert_eq(_rig.combatant(outsider).health, 1000, "ni un enemigo que está fuera de la zona segura: allí no atacan")
	assert_eq(_rig.alive_of(&"gate_guardian").size(), 4, "los Guardianes siguen vivos")


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
	assert_eq(patrollers.size(), 2, "dos de los cuatro patrullan")
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
		assert_true(highest[net_id] - floor_y > 3.0, "sube a la pasarela (%.1f m sobre el patio)" % (highest[net_id] - floor_y))
	assert_true(walked["states"].has(HfsmBrain.State.PATROL) and walked["states"].has(HfsmBrain.State.REST),
			"alterna patrulla y reposo")
	assert_eq(_rig.alive_of(&"hollow").size(), 4, "sin pelear no muere nadie")


func test_two_or_three_bots_clear_the_hollows_in_a_reasonable_time() -> void:
	# El Capitán, que se une a la pelea por el grito, se mide aparte: aquí caído, como si ya lo hubieran derrotado.
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
	assert_true(cleared, "los Huecos caen")
	assert_true(seconds < 90.0, "en menos de 90 s (%.1f s)" % seconds)
	assert_true(seconds > 15.0, "y no en un suspiro (%.1f s)" % seconds)


func test_four_bots_that_do_not_die_beat_the_ford_captain_in_a_reasonable_time() -> void:
	# Los bots no esquivan ni bloquean con criterio: un grupo de cuatro cae antes de bajarle la mitad de la vida
	# (y el Capitán, sin nadie, regresa regenerado). Para medir cuánto dura el combate por el daño que hay que
	# hacerle, se les cura la vida en cada tick, como a un grupo que sabe defenderse.
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
	assert_true(cleared, "el Capitán cae")
	assert_true(seconds > 40.0 and seconds < 150.0, "entre 40 y 150 s (%.1f s)" % seconds)
	assert_eq(_rig.state().phase, FortressState.Phase.VULNERABLE, "su muerte abre el círculo de captura")
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
	assert_true(engaged, "el Capitán entra en combate")
	_rig.server.get_combat().kill(_rig.combatant(victim), _rig.server.get_tick() + 1)
	var back: bool = await _rig.advance_until(func() -> bool:
		return _rig.npcs().get_brain(captain).state == HfsmBrain.State.REST, 1800)
	assert_true(back, "sin nadie a quien pegar, vuelve a su puesto")
	assert_eq(_rig.combatant(captain).health, 30000, "regenerado del todo")
	assert_eq(_rig.alive_of(&"ford_captain"), [captain] as Array[int], "es el mismo")


# --- Reaparición, retirada y registro (zona plana) ---------------------------------------------------

func test_a_dead_guardian_comes_back_at_the_exact_tick_and_its_corpse_goes_away() -> void:
	await _start_fort_zone(2.0)
	var spawned: Array[Vector2i] = []
	var died: Array[Array] = []
	_rig.npcs().npc_spawned.connect(func(net_id: int, _spawner: Node) -> void:
		spawned.append(Vector2i(net_id, _rig.server.get_tick())))
	_rig.npcs().npc_died.connect(func(net_id: int, spawner: Node, killer: int) -> void:
		died.append([net_id, spawner, killer]))
	var guardians: Array[int] = _rig.alive_of(&"gate_guardian")
	assert_eq(guardians.size(), 1, "un Guardián")
	var first: int = guardians[0]
	var kill_tick: int = _rig.server.get_tick() + 1
	_rig.server.get_combat().kill(_rig.combatant(first), kill_tick)
	assert_eq(died.size(), 1, "la muerte avisa con npc_died")
	assert_eq(died[0][0], first)
	assert_eq(died[0][1], _spawner("Guardian"), "con el generador del que salió")
	assert_eq(died[0][2], 0, "y sin asesino: murió por una orden")
	await _rig.advance(119)
	assert_true(_rig.alive_of(&"gate_guardian").is_empty(), "119 ticks después aún no ha vuelto")
	assert_true(spawned.is_empty())
	await _rig.advance(kill_tick + 120 - _rig.server.get_tick())
	assert_eq(spawned.size(), 1, "vuelve")
	assert_eq(spawned[0].y, kill_tick + 120, "en el tick exacto: muerte + 2 s")
	var second: int = _rig.alive_of(&"gate_guardian")[0]
	assert_true(second != first, "es un PNJ nuevo")
	assert_true(_entity_exists(first), "el cadáver sigue ahí unos segundos")
	await _rig.advance(NpcSpawnerSystem.CORPSE_TICKS)
	assert_false(_entity_exists(first), "y se retira tras %d ticks" % NpcSpawnerSystem.CORPSE_TICKS)
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
	assert_eq(pair.size(), 2, "dos a la vez")
	var first_death: int = _rig.server.get_tick() + 1
	_rig.server.get_combat().kill(_rig.combatant(pair[0]), first_death)
	await _rig.advance(40)
	var second_death: int = _rig.server.get_tick() + 1
	_rig.server.get_combat().kill(_rig.combatant(pair[1]), second_death)
	await _rig.advance(400)
	assert_eq(spawned, [first_death + 180, second_death + 180] as Array[int], "cada uno vuelve 3 s después de morir")
	assert_eq(_rig.alive_of(&"hollow").size(), 2)


func test_npcs_do_not_come_back_on_their_own_through_the_combat_director() -> void:
	await _start_fort_zone()
	var hollow: int = _rig.alive_of(&"hollow")[0]
	_kill(hollow)
	await _rig.advance(60)
	assert_true(_rig.combatant(hollow).is_dead())
	await _rig.advance(NpcSpawnerSystem.CORPSE_TICKS + 30)
	assert_false(_entity_exists(hollow), "el cadáver se retira")
	await _rig.advance(2100)
	assert_eq(_rig.alive_of(&"hollow").size(), 1, "los Huecos no reaparecen solos (los repone la fortaleza)")
	for event: NetMessages.EntityEvent in _rig.events_of(NetMessages.EntityEvent.Kind.RESPAWN):
		assert_true(_rig.entity(event.net_id) == null or _rig.entity(event.net_id).kind != NetProtocol.EntityKind.NPC,
				"ningún PNJ recibe un RESPAWN del combate")


func test_deactivating_a_spawner_removes_the_living_npcs_and_the_owners_garrison_takes_over() -> void:
	await _start_fort_zone(2.0)
	var guardian: int = _rig.alive_of(&"gate_guardian")[0]
	var hollows: Array[int] = _rig.alive_of(&"hollow")
	var captain: int = _rig.alive_of(&"ford_captain")[0]
	assert_eq(hollows.size(), 2)
	assert_eq(_state().guards_alive, 0, "neutral: no hay guarnición")
	assert_eq(_rig.server.get_fortresses().get_captain_net_id(FORTRESS), captain)
	_rig.server.console_command("fort_owner vardheim")
	await _rig.advance(3)
	for net_id: int in hollows + [captain]:
		assert_false(_entity_exists(net_id), "los PNJ de los Huecos se retiran al tener dueño el fuerte")
	assert_true(_entity_exists(guardian), "el Guardián, que no depende del fuerte, sigue")
	var guards: Array[int] = _alive_realm(&"realm_guard", VARDHEIM)
	assert_eq(guards.size(), 2, "los dos puestos de los Huecos dan dos guardias del reino dueño")
	var new_captain: Array[int] = _alive_realm(&"realm_captain", VARDHEIM)
	assert_eq(new_captain.size(), 1, "y el puesto del Capitán, el capitán del reino")
	assert_eq(_state().guards_alive, 2, "la fortaleza sabe cuántos guardias hay")
	assert_eq(_rig.server.get_fortresses().get_captain_net_id(FORTRESS), new_captain[0],
			"y quién es su capitán")
	for net_id: int in guards + new_captain:
		assert_eq(_rig.entity(net_id).realm, VARDHEIM)
	# Cambia de manos: se retira la guarnición de Vardheim y llega la de Solmarch.
	_rig.server.console_command("fort_owner solmarch")
	await _rig.advance(3)
	for net_id: int in guards + new_captain:
		assert_false(_entity_exists(net_id), "la guarnición del dueño anterior se retira")
	assert_eq(_alive_realm(&"realm_guard", SOLMARCH).size(), 2)
	assert_eq(_alive_realm(&"realm_captain", SOLMARCH).size(), 1)
	# Un reinicio devuelve a los Huecos y al Capitán del Vado.
	_rig.server.console_command("fort_reset")
	await _rig.advance(3)
	assert_eq(_rig.alive_of(&"hollow").size(), 2, "vuelven los Huecos")
	assert_eq(_rig.alive_of(&"ford_captain").size(), 1, "y el Capitán del Vado")
	assert_eq(_rig.alive_of(&"realm_guard").size(), 0, "sin guarnición del reino")
	assert_true(_entity_exists(guardian))


func test_the_fortress_learns_about_its_captain_and_its_defenders() -> void:
	await _start_fort_zone()
	var captain: int = _rig.alive_of(&"ford_captain")[0]
	var attacker: int = _rig.add_player(VARDHEIM, Vector3(60.0, 0.1, 0.0))
	var hollow: int = _rig.alive_of(&"hollow")[0]
	assert_eq(_state().phase, FortressState.Phase.GARRISONED)
	# Un golpe a un defensor marca el fuerte como atacado.
	var before: int = _state().under_attack_until_tick
	_rig.events.clear()
	var hit: NetMessages.EntityEvent = NetMessages.EntityEvent.hit(hollow, _rig.server.get_tick() + 1, attacker, 10, 0, 0, 0)
	_rig.server.get_combat().event_emitted.emit(hit, PackedInt32Array([hollow, attacker]))
	assert_true(_state().under_attack_until_tick > before, "golpear a un Hueco marca el fuerte como atacado")
	# La muerte del capitán abre el círculo.
	var died: Array[Array] = []
	_rig.npcs().npc_died.connect(func(net_id: int, spawner: Node, killer: int) -> void:
		died.append([net_id, spawner, killer]))
	_kill(captain)
	await _rig.advance(3)
	assert_eq(_state().phase, FortressState.Phase.VULNERABLE, "muerto el capitán, el círculo se activa")
	assert_false(_state().captain_alive)
	assert_eq(died.size(), 1)
	assert_eq(died[0][0], captain)
	assert_eq(_rig.server.get_fortresses().get_captain_net_id(FORTRESS), 0, "ya no tiene capitán registrado")


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
	assert_true(captured, "el reino que ocupa el círculo captura el fuerte")
	assert_eq(_state().phase, FortressState.Phase.CONSOLIDATING)
	assert_eq(_rig.alive_of(&"realm_guard").size(), 0, "durante la consolidación no hay guarnición")
	assert_eq(_rig.alive_of(&"realm_captain").size(), 0)
	var garrisoned: bool = await _rig.advance_until(func() -> bool:
		return _state().phase == FortressState.Phase.GARRISONED, 600, 6)
	assert_true(garrisoned, "a los 2 s de consolidación llega la guarnición")
	await _rig.advance(6)
	var guards: Array[int] = _alive_realm(&"realm_guard", VARDHEIM)
	assert_eq(guards.size(), 2, "los guardias del reino dueño")
	assert_eq(_alive_realm(&"realm_captain", VARDHEIM).size(), 1, "y su capitán")
	assert_eq(_state().guards_alive, 2)
	assert_true(_state().captain_alive)
	assert_eq(_rig.combatant(capturer).health, 1000, "los suyos no le atacan")
	# Un guardia muerto se repone a los guard_respawn_s de la fortaleza (10 s en la de pruebas).
	_kill(guards[0])
	await _rig.advance(3)
	assert_eq(_state().guards_alive, 1, "la fortaleza lo nota")
	await _rig.advance(60 * 9)
	assert_eq(_alive_realm(&"realm_guard", VARDHEIM).size(), 1, "a los 9 s todavía no")
	await _rig.advance(60 * 2 + 20)
	assert_eq(_alive_realm(&"realm_guard", VARDHEIM).size(), 2, "tras 10 s vuelve")
	assert_eq(_state().guards_alive, 2)
	var guards_before: Array[int] = _alive_realm(&"realm_guard", VARDHEIM)
	# Si cae el capitán del reino, vuelve solo él a los captain_respawn_s (30 s).
	var owners_captain: int = _alive_realm(&"realm_captain", VARDHEIM)[0]
	_kill(owners_captain)
	await _rig.advance(3)
	assert_eq(_state().phase, FortressState.Phase.VULNERABLE, "su muerte vuelve a abrir el círculo")
	await _rig.advance(60 * 30)
	assert_eq(_state().phase, FortressState.Phase.GARRISONED, "sin captura, el capitán regresa")
	var back: Array[int] = _alive_realm(&"realm_captain", VARDHEIM)
	assert_eq(back.size(), 1, "el capitán del reino reaparece")
	assert_true(back[0] != owners_captain)
	assert_eq(_alive_realm(&"realm_guard", VARDHEIM), guards_before, "los guardias no se tocan")


func test_the_hollows_and_the_captain_come_back_whole_after_two_minutes_with_nobody_near() -> void:
	# El capitán no vuelve solo (su plazo es larguísimo): lo trae la reaparición completa.
	await _start_fort_zone(0.0, 100000.0)
	var hollows: Array[int] = _rig.alive_of(&"hollow")
	_kill(hollows[0])
	_rig.server.console_command("fort_kill_captain")
	await _rig.advance(10)
	assert_eq(_state().phase, FortressState.Phase.VULNERABLE)
	assert_eq(_rig.alive_of(&"hollow").size(), 1)
	# Un jugador a 30 m del fuerte impide la reaparición completa mientras esté cerca.
	var near: int = _rig.add_player(VARDHEIM, FortressFixture.circle_center() + Vector3(-30.0, 0.1, 0.0))
	await _rig.advance(NpcSpawnerSystem.FULL_RESPAWN_EMPTY_TICKS + 600)
	assert_eq(_rig.alive_of(&"hollow").size(), 1, "con alguien a 30 m no vuelven")
	assert_eq(_state().phase, FortressState.Phase.VULNERABLE)
	# Se aleja a más de 40 m: la cuenta empieza.
	_rig.server.teleport(near, FortressFixture.circle_center() + Vector3(-60.0, 0.1, 0.0))
	await _rig.advance(NpcSpawnerSystem.FULL_RESPAWN_EMPTY_TICKS - 600)
	assert_eq(_rig.alive_of(&"hollow").size(), 1, "antes de los 2 min no")
	await _rig.advance(1200)
	assert_eq(_rig.alive_of(&"hollow").size(), 2, "pasados los 2 min vuelven los Huecos")
	assert_eq(_rig.alive_of(&"ford_captain").size(), 1, "y el Capitán del Vado")
	assert_eq(_state().phase, FortressState.Phase.GARRISONED, "con el fuerte guardado otra vez")
	assert_true(_state().captain_alive)
	assert_eq(_rig.server.get_fortresses().get_captain_net_id(FORTRESS), _rig.alive_of(&"ford_captain")[0])
	assert_eq(_rig.npcs().get_report()["full_respawns"], 1)


func test_without_the_npc_system_the_zone_has_no_npcs() -> void:
	await _rig.start_flat(tree, func(world: Node3D) -> void:
		NpcRig.add_spawner(world, "Solo", &"hollow", Vector3(0.0, 0.05, 0.0)),
		func(config: ServerConfig) -> void: config.no_npcs = true)
	assert_null(_rig.server.get_npc_system(), "--no-npcs apaga el sistema")
	await _rig.advance(60)
	assert_eq(_rig.server.get_registry().size(), 0, "y no aparece ningún PNJ")
	assert_eq(_rig.server.get_dummy_count(), 0)


func test_the_report_counts_the_npcs() -> void:
	await _start_fort_zone()
	_kill(_rig.alive_of(&"hollow")[0])
	await _rig.advance(60)
	var path: String = "res://build/test_npc_report.json"
	assert_eq(_rig.server.write_report(path), OK)
	var report: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(path))
	var npcs: Dictionary = report.get("npcs", {})
	assert_eq(int(npcs.get("slots", 0)), 6, "los puestos del fuerte: 3 de los Huecos y 3 de la guarnición")
	assert_eq(int(npcs.get("spawned", 0)), 3)
	assert_eq(int(npcs.get("died", 0)), 1)
	assert_eq(int(npcs.get("alive", 0)), 2)
