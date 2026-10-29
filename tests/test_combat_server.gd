extends TestCase
## Pruebas del combate dentro del [ZoneServer] (docs/combate.md, secciones 4 a 7), sin red: jugadores
## falsos con guiones de entradas en un [SubViewport] con su propio mundo de física.
## [br][br]
## Se comprueba el tubo entero (entrada -> simulación -> golpe -> evento -> vida publicada), la
## defensa con el historial de banderas, la caída (la pasarela de 3 m saltando no hace daño y los
## 12 m sí), un volumen letal, la muerte bajo y = -100 con reaparición automática, las zonas seguras,
## el maniquí (golpearlo, que se cure y que el DPS del combo coincida con los datos), los PNJ en el
## bucle, el registro de combate, el informe, los comandos de la consola y el cerebro de combate de
## los jugadores falsos.

const VARDHEIM: int = NetProtocol.Realm.VARDHEIM
const SOLMARCH: int = NetProtocol.Realm.SOLMARCH
const COMBAT_LOG_FILE: String = "res://build/test_combat_server_log.txt"
const REPORT_FILE: String = "res://build/test_combat_server_report.json"
## Espera máxima (ticks) a un suceso del combate.
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


# --- Ayudantes --------------------------------------------------------------------------------

## Servidor en una zona plana. [param prepare_world] recibe la zona antes de arrancar (para añadirle
## zonas seguras, por ejemplo) y [param configure] el [ServerConfig].
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
	assert_eq(_server.start(config, _world, null, DevAuthProvider.new()), OK, "el servidor arranca")
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


## Coloca a [param net_id] en [param position] mirando a [param yaw].
func _put(net_id: int, position: Vector3, yaw: float) -> void:
	_server.teleport(net_id, position)
	_character(net_id).yaw = yaw


## Atacante de Vardheim en el origen mirando a -Z y víctima de Solmarch 1,5 m delante, de cara. El
## atacante pulsa PRIMARY (dos ticks) en cada tick de [param presses]; la víctima ejecuta
## [param victim_script] (null = quieta).
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


## Espera, paso de física a paso de física, a que se cumpla [param condition].
func _wait_until(condition: Callable, max_frames: int = MAX_WAIT) -> bool:
	for _i: int in max_frames:
		if condition.call():
			return true
		await tree.physics_frame
	return condition.call()


# --- Golpes de punta a punta -------------------------------------------------------------------

func test_a_light_attack_travels_from_the_input_to_the_published_health() -> void:
	await _start_server()
	var press: int = _server.get_tick() + 6
	var duel: Array[int] = _duel([press])
	var landed: bool = await _wait_until(func() -> bool:
		return not _events_of(NetMessages.EntityEvent.Kind.HIT).is_empty())
	if not assert_true(landed, "el golpe llega"):
		return
	var hit: NetMessages.EntityEvent = _events_of(NetMessages.EntityEvent.Kind.HIT)[0]
	assert_eq(hit.attacker, duel[0])
	assert_eq(hit.net_id, duel[1])
	assert_eq(hit.amount, 90)
	var light_1: int = CombatCatalog.attack_id(&"sword_light_1")
	assert_eq(hit.attack_id, light_1)
	# El golpe activo empieza tras la anticipación (12 ticks) del ligero que empezó en `press`.
	assert_eq(hit.tick, press + CombatCatalog.attack(light_1).windup_ticks, "en el primer tick activo")
	await wait_physics_frames(2)
	var victim: NetEntity = _server.get_registry().get_entity(duel[1])
	assert_eq(victim.health, 910, "la vida publicada para los snapshots baja")
	assert_eq(victim.health_q, EntityRecord.quantize_health(910, 1000))
	assert_true((victim.status & NetMessages.STATUS_IN_COMBAT) != 0, "y está en combate")
	assert_eq(_events_of(NetMessages.EntityEvent.Kind.HIT).size(), 1, "un solo golpe por ataque")
	# La acción del atacante viaja en el byte de acción del registro.
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
	if not assert_true(landed, "el golpe llega al escudo"):
		return
	var hit: NetMessages.EntityEvent = _events_of(NetMessages.EntityEvent.Kind.HIT)[0]
	assert_true(hit.has_hit_flag(NetMessages.EntityEvent.HIT_FLAG_BLOCKED), "bloqueado")
	assert_eq(hit.amount, 0)
	assert_eq(_combatant(duel[1]).health, 1000, "el escudo para todo el daño")
	var flags: int = _server.get_history().get_flags(duel[1], _server.get_tick() - 1)
	assert_true(flags >= 0 and (flags & ActionMachine.DEFENSE_BLOCKING) != 0,
			"el historial guarda que bloqueaba")
	assert_eq(_server.get_history().get_flags(duel[0], _server.get_tick() - 1) \
			& ActionMachine.DEFENSE_BLOCKING, 0, "y que el atacante no")


# --- Caída, volúmenes letales, bajo el mundo ---------------------------------------------------

func test_a_twelve_meter_fall_hurts_and_a_three_meter_jump_does_not() -> void:
	await _start_server()
	var jumper: int = _server.add_fake_player(_brain(), VARDHEIM)
	var faller: int = _server.add_fake_player(_brain(), SOLMARCH)
	_server.teleport(jumper, Vector3(-20.0, 3.0, 0.0))
	_character(jumper).velocity = Vector3(0.0, _character(jumper).jump_velocity, 0.0)
	_server.teleport(faller, Vector3(20.0, 12.0, 0.0))
	var landed: bool = await _wait_until(func() -> bool:
		return _character(faller).grounded and _character(jumper).grounded, 200)
	if not assert_true(landed, "los dos aterrizan"):
		return
	await wait_physics_frames(3)
	assert_eq(_combatant(jumper).health, 1000, "saltar desde 3 m (14 m/s) no hace daño")
	var health: int = _combatant(faller).health
	assert_true(health >= 1000 - 640 and health <= 1000 - 480,
			"caer 12 m (23 m/s) quita unos 560 (%d)" % (1000 - health))
	var hits: Array[NetMessages.EntityEvent] = _events_of(NetMessages.EntityEvent.Kind.HIT)
	if assert_eq(hits.size(), 1, "un HIT del entorno"):
		assert_eq(hits[0].attacker, 0)
		assert_eq(hits[0].net_id, faller)


func test_running_and_jumping_down_a_ramp_does_no_fall_damage() -> void:
	await _start_server(func(world: Node3D) -> void:
		# Una rampa de 20 grados de 20 m de largo: sube hacia -Z.
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
		# Salta cada 25 ticks.
		if tick % 25 < 3:
			input.buttons = PlayerInput.JUMP
		return input), VARDHEIM)
	await wait_physics_frames(3)
	# Se coloca en lo alto de la rampa (el extremo -Z, el más alto) sobre su superficie.
	var space: PhysicsDirectSpaceState3D = _world.get_world_3d().direct_space_state
	var from := Vector3(40.0, 20.0, -47.0)
	var query := PhysicsRayQueryParameters3D.create(from, from + Vector3(0.001, -30.0, 0.0),
			PlayerCharacter.WORLD_COLLISION_LAYER)
	var hit: Dictionary = space.intersect_ray(query)
	if not assert_false(hit.is_empty(), "hay rampa bajo el punto de salida"):
		return
	var top: Vector3 = hit["position"]
	assert_true(top.y > 4.0, "y está en lo alto (%.1f m)" % top.y)
	_server.teleport(runner, top + Vector3(0.0, 0.1, 0.0))
	_character(runner).yaw = PI
	var start_z: float = _character(runner).global_position.z
	await wait_physics_frames(150)
	assert_true(_character(runner).global_position.z > start_z + 8.0,
			"baja corriendo y saltando por la rampa (%.1f m)" % (_character(runner).global_position.z - start_z))
	assert_eq(_combatant(runner).health, 1000, "sin daño por caída")
	assert_eq(_events_of(NetMessages.EntityEvent.Kind.HIT).size(), 0)


func test_falling_below_the_world_kills_and_the_body_waits_dead_at_the_spawn_until_it_respawns() -> void:
	await _start_server()
	var id: int = _server.add_fake_player(_brain(), SOLMARCH)
	var timing: CombatTiming = _server.get_combat_timing()
	timing.respawn = 20
	timing.auto_respawn = 60
	timing.protection = 40
	await wait_physics_frames(3)
	_server.teleport(id, Vector3(0.0, -150.0, 0.0))
	var died: bool = await _wait_until(func() -> bool: return _combatant(id).is_dead(), 10)
	if not assert_true(died, "muere al caer fuera del mundo"):
		return
	await wait_physics_frames(2)
	var entity: NetEntity = _server.get_registry().get_entity(id)
	assert_vec_near(Vector3(entity.get_position().x, 0.0, entity.get_position().z),
			ZoneFixture.SOLMARCH_SPAWN, 0.1, "el cuerpo está en el punto de aparición de su reino")
	assert_eq(_character(id).combat.action, CombatState.Action.DEAD, "y sigue muerto")
	assert_eq(entity.status, NetMessages.STATUS_DEAD)
	assert_eq(entity.teleport_counter, 2, "teletransporte del comando y de la muerte")
	assert_eq(_events_of(NetMessages.EntityEvent.Kind.DEATH).size(), 1, "una DEATH sin autor")
	assert_eq(_events_of(NetMessages.EntityEvent.Kind.DEATH)[0].killer, 0)
	var respawned: bool = await _wait_until(func() -> bool: return _combatant(id).is_alive(), 120)
	if not assert_true(respawned, "reaparece sola pasado el plazo automático"):
		return
	assert_eq(_events_of(NetMessages.EntityEvent.Kind.RESPAWN).size(), 1)
	assert_true(_combatant(id).is_protected(_server.get_tick()), "con protección")
	assert_eq(_character(id).combat.action, CombatState.Action.NONE)
	assert_eq(_combatant(id).health, 1000)
	assert_eq(_events_of(NetMessages.EntityEvent.Kind.DEATH).size(), 1, "y sin más muertes")


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
	assert_true(died, "dentro del volumen letal muere")
	assert_true(_combatant(outside).is_alive(), "fuera no")
	assert_eq(_events_of(NetMessages.EntityEvent.Kind.DEATH).size(), 1)


# --- Zonas seguras ----------------------------------------------------------------------------

func test_a_hit_inside_the_safe_area_of_the_victims_realm_does_no_damage() -> void:
	await _start_server(func(world: Node3D) -> void:
		var camp := Marker3D.new()
		camp.name = "Campamento"
		world.add_child(camp)
		camp.position = Vector3(0.0, 0.0, 0.0)
		camp.add_to_group(Zones.SAFE_AREA_GROUP)
		camp.set_meta(Zones.REALM_META, &"solmarch")
		camp.set_meta(Zones.SAFE_AREA_RADIUS_META, 10.0))
	assert_eq(_server.get_safe_areas().size(), 1, "el servidor lee la zona segura")
	var press: int = _server.get_tick() + 6
	var duel: Array[int] = _duel([press])
	await wait_physics_frames(60)
	assert_eq(_combatant(duel[1]).health, 1000, "la víctima de Solmarch dentro de su campamento no recibe daño")
	assert_eq(_events_of(NetMessages.EntityEvent.Kind.HIT).size(), 0)
	# Fuera de la zona segura (a 30 m del centro) el mismo golpe sí hace daño.
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
	assert_true(landed, "fuera del campamento el golpe llega")
	assert_eq(_combatant(victim).health, 910)


# --- Maniquí y PNJ ----------------------------------------------------------------------------

func test_a_dummy_is_an_immortal_npc_simulated_with_the_players() -> void:
	await _start_server()
	var player: int = _server.add_fake_player(_brain(), VARDHEIM)
	var dummy: int = _server.spawn_dummy(Vector3(0.0, 0.0, -10.0), 0.0)
	if not assert_true(dummy > 0, "se crea el maniquí"):
		return
	var entity: NetEntity = _server.get_registry().get_entity(dummy)
	assert_eq(entity.kind, NetProtocol.EntityKind.NPC)
	assert_eq(entity.realm, RealmCatalog.NEUTRAL_CODE, "bando neutral: hostil a todos")
	assert_eq(entity.display_name, ZoneServer.DUMMY_NAME)
	assert_true(_combatant(dummy).immortal)
	assert_eq(_server.get_player_count(), 1, "un PNJ no cuenta como jugador")
	assert_eq(_server.get_dummy_count(), 1)
	await wait_physics_frames(5)
	assert_true(_server.get_history().has_tick(dummy, _server.get_tick()), "se graba en el historial")
	assert_true(entity.get_position().y > -0.2 and entity.get_position().y < 0.3,
			"está sobre el suelo (%s)" % entity.get_position())
	assert_true(_character(dummy).grounded)
	# Se muere de verdad un jugador pero no el maniquí.
	_server.get_combat().kill(_combatant(player), _server.get_tick() + 1)
	_server.get_combat().kill(_combatant(dummy), _server.get_tick() + 1)
	await wait_physics_frames(3)
	assert_true(_combatant(player).is_dead())
	assert_true(_combatant(dummy).is_alive(), "el maniquí no muere")
	# Baja del PNJ.
	assert_true(_server.remove_npc(dummy), "se da de baja")
	assert_null(_server.get_registry().get_entity(dummy))
	assert_false(_server.remove_npc(player), "un jugador no es un PNJ")
	assert_eq(_server.get_dummy_count(), 0)


func test_the_dummy_modes_block_and_spin() -> void:
	await _start_server()
	var blocker: int = _server.spawn_dummy(Vector3(0.0, 0.0, -10.0), 0.0, NpcBrain.Mode.BLOCK)
	var spinner: int = _server.spawn_dummy(Vector3(10.0, 0.0, -10.0), 0.0, NpcBrain.Mode.SPIN)
	var still: int = _server.spawn_dummy(Vector3(-10.0, 0.0, -10.0), 0.0, NpcBrain.Mode.STILL)
	await wait_physics_frames(30)
	assert_eq(_character(blocker).combat.action, CombatState.Action.BLOCK, "bloqueando")
	assert_eq(_character(still).combat.action, CombatState.Action.NONE, "quieto")
	var yaw_before: float = _character(spinner).yaw
	var start: Vector3 = _character(spinner).global_position
	await wait_physics_frames(60)
	assert_true(absf(angle_difference(_character(spinner).yaw, yaw_before)) > 0.5, "gira")
	assert_true(_character(spinner).global_position.distance_to(start) < 1.5, "sin alejarse")
	assert_near(_character(still).yaw, 0.0, 1e-6, "el quieto no gira")


func test_the_sword_combo_dps_against_the_dummy_matches_the_data() -> void:
	await _start_server()
	var weapon: WeaponTicks = CombatCatalog.weapon(
			CombatCatalog.weapon_id(CombatCatalog.DEFAULT_WEAPON))
	# Un ciclo: la primera pulsación abre el ligero 1 y cada enlace cae 4 ticks antes de que acabe el
	# ligero en curso (dentro de su ventana de combo). Al acabar el tercero empieza otro ciclo.
	var cycle_presses: Array[int] = [0]
	var cycle_ticks: int = 0
	var cycle_damage: int = 0
	for index: int in weapon.light_ids.size():
		var attack: AttackTicks = CombatCatalog.attack(weapon.light_ids[index])
		cycle_damage += attack.base_damage
		cycle_ticks += attack.total_ticks
		if index < weapon.light_ids.size() - 1:
			cycle_presses.append(cycle_ticks - 4)
	var cycles: int = 3
	var start_tick: int = _server.get_tick() + 8
	var all_presses: Array[int] = []
	for cycle_index: int in cycles:
		for press: int in cycle_presses:
			all_presses.append(start_tick + cycle_index * cycle_ticks + press)
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
	# Cada ciclo avanza al atacante (el avance de los ligeros): se le devuelve a su sitio al empezar.
	for _step: int in cycles * cycle_ticks + 30:
		var next_tick: int = _server.get_tick() + 1
		for cycle_index: int in cycles:
			if next_tick == start_tick + cycle_index * cycle_ticks - 1:
				_server.teleport(attacker, Vector3(0.0, 0.05, 0.0))
		await tree.physics_frame
	var damage: int = 0
	var hits: int = 0
	for event: NetMessages.EntityEvent in _events_of(NetMessages.EntityEvent.Kind.HIT):
		if event.net_id == dummy and event.attacker == attacker:
			damage += event.amount
			hits += 1
	assert_eq(hits, weapon.light_ids.size() * cycles, "tres golpes por ciclo")
	assert_eq(damage, cycle_damage * cycles, "el daño de los %d combos coincide con los .tres" % cycles)
	var seconds: float = float(cycles * cycle_ticks) / 60.0
	assert_near(float(damage) / seconds, float(cycle_damage) / (float(cycle_ticks) / 60.0), 0.01,
			"el DPS medido es el calculado con los datos")
	assert_true(_combatant(dummy).is_alive(), "el maniquí sigue ahí")


# --- Antitrampas: el servidor decide el ritmo y el alcance -------------------------------------

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
			# Los ligeros avanzan: se le devuelve a su sitio para que no pase de largo al maniquí.
			_server.teleport(spammer, Vector3(0.0, 0.05, 0.0))
		await tree.physics_frame
	var hits: int = 0
	for event: NetMessages.EntityEvent in _events_of(NetMessages.EntityEvent.Kind.HIT):
		if event.net_id == dummy:
			hits += 1
	# El combo más rápido que permiten los datos: tres ligeros encadenados cada 119 ticks.
	var weapon: WeaponTicks = CombatCatalog.weapon(CombatCatalog.weapon_id(CombatCatalog.DEFAULT_WEAPON))
	var combo_ticks: int = 0
	for light_id: int in weapon.light_ids:
		combo_ticks += CombatCatalog.attack(light_id).total_ticks
	var most_hits: int = ceili(float(ticks) * float(weapon.light_ids.size()) / float(combo_ticks)) + 1
	assert_true(hits >= 3, "algo acierta (%d)" % hits)
	assert_true(hits <= most_hits, "pero no más que el ritmo del combo: %d <= %d" % [hits, most_hits])


func test_an_attack_from_five_meters_hits_nothing() -> void:
	await _start_server()
	var press: int = _server.get_tick() + 6
	var duel: Array[int] = _duel([press])
	_put(duel[1], Vector3(0.0, 0.05, -5.0), PI)
	await wait_physics_frames(60)
	assert_eq(_combatant(duel[1]).health, 1000, "fuera de alcance no hay daño")
	assert_eq(_events_of(NetMessages.EntityEvent.Kind.HIT).size(), 0)
	assert_true(_character(duel[0]).combat.action_tick == press or _character(duel[0]).combat.action_tick > 0,
			"el atacante sí lanzó su golpe")


# --- Registro, informe y consola ---------------------------------------------------------------

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
	assert_eq(lines[0], ZoneServer.COMBAT_LOG_HEADER, "cabecera del CSV")
	if assert_eq(lines.size(), 2, "una línea por golpe"):
		var columns: PackedStringArray = lines[1].split(",")
		assert_eq(columns.size(), 8)
		assert_eq(columns[1], str(duel[0]), "atacante")
		assert_eq(columns[2], str(duel[1]), "objetivo")
		assert_eq(columns[3], "sword_light_1", "ataque")
		assert_near(columns[4].to_float(), float(columns[0].to_int()), 0.01, "view_tick = tick sin rebobinado")
		assert_near(columns[5].to_float(), 0.0, 0.01, "rebobinado 0")
		assert_eq(columns[6], "hit", "resultado")
		assert_eq(columns[7], "90", "daño")
	var json := JSON.new()
	assert_eq(json.parse(FileAccess.get_file_as_string(ProjectSettings.globalize_path(REPORT_FILE))), OK)
	var report: Dictionary = json.data
	var combat: Dictionary = report.get("combat", {})
	assert_eq(int(combat.get("hits", -1)), 1, "el informe cuenta el golpe")
	assert_eq(int(combat.get("damage", -1)), 90)
	assert_true(combat.has("events_sent") and combat.has("suspicious") and combat.has("rewind_rejected"))
	assert_true(int(combat.get("hit_tests", 0)) >= 1, "el informe cuenta las comprobaciones de golpe")
	assert_true(combat.has("event_bytes_sent"))
	var sections: Dictionary = (report.get("metrics", {}) as Dictionary).get("sections", {})
	assert_true(sections.has("combat_resolve"), "y mide aparte la resolución de los golpes (%s)" % [sections.keys()])
	assert_true(sections.has("combat"))


func test_console_commands() -> void:
	await _start_server()
	var ana: int = _server.add_fake_player(_brain(), VARDHEIM)
	var commands: CommandRegistry = _server.get_commands()
	assert_eq(commands.missing_network_commands(), PackedStringArray(), "todos los comandos de red tienen manejador")
	assert_true(_server.console_command("help").contains("teleport"))
	assert_true(_server.console_command("noexiste").begins_with("Comando desconocido"))
	# Daño, curar y matar.
	_combatant(ana).take_damage(300, 1)
	assert_eq(_server.console_command("heal Bot-01"), "Bot-01 curado")
	assert_eq(_combatant(ana).health, 1000)
	assert_eq(_server.console_command("kill %d" % ana), "Bot-01 muerto")
	await wait_physics_frames(3)
	assert_true(_combatant(ana).is_dead())
	assert_eq(_server.console_command("heal Bot-01"), "Bot-01 está muerto")
	# Teletransporte.
	var respawn_id: int = _server.add_fake_player(_brain(), SOLMARCH)
	assert_true(_server.console_command("teleport Bot-02 10 0.5 -4").contains("teletransportado"))
	assert_vec_near(_server.get_registry().get_entity(respawn_id).get_position(),
			Vector3(10.0, 0.5, -4.0), 1e-4)
	assert_eq(_server.console_command("teleport Bot-02 1 2"), "Uso: teleport <jugador> <x> <y> <z>")
	assert_eq(_server.console_command("teleport Bot-02 1e9 0 0"), "Destino fuera de rango")
	assert_eq(_server.console_command("teleport Nadie 1 2 3"), "No hay ningún jugador «Nadie»")
	# Resistencia infinita y arma.
	assert_true(_server.console_command("stamina_inf Bot-02 on").contains("activada"))
	assert_true((_character(respawn_id).combat.combat_flags & CombatState.FLAG_INFINITE_STAMINA) != 0)
	assert_true(_server.console_command("stamina_inf Bot-02 off").contains("desactivada"))
	assert_eq(_character(respawn_id).combat.combat_flags & CombatState.FLAG_INFINITE_STAMINA, 0)
	assert_true(_server.console_command("set_weapon Bot-02 sword_shield").contains("lleva ahora"))
	assert_true(_server.console_command("set_weapon Bot-02 hacha").contains("No existe"))
	# Maniquíes.
	assert_true(_server.console_command("spawn_dummy 5 0 5 bloqueando").contains("bloqueando"))
	assert_eq(_server.get_dummy_count(), 1)
	assert_true(_server.console_command("spawn_dummy 5 0 5 volando").contains("Modo desconocido"))
	# Anuncio, expulsión y listado.
	assert_eq(_server.console_command("announce Hola a todos"), "Anuncio enviado a 0 jugadores")
	assert_true(_server.console_command("kick Bot-02").contains("dado de baja"))
	assert_true(_server.console_command("players").contains("Maniquí"))
	# Cierre con cuenta atrás.
	var requests: Array[String] = []
	_server.shutdown_requested.connect(func(reason: String) -> void: requests.append(reason))
	assert_eq(_server.console_command("shutdown 1"), "Cierre dentro de 1 s")
	await wait_physics_frames(30)
	assert_eq(requests.size(), 0, "aún no ha pasado el segundo")
	assert_true(await _wait_until(func() -> bool: return requests.size() == 1, 90), "se pide el cierre")
	assert_eq(_server.console_command("shutdown cancel"), "No hay ningún cierre pendiente")
	assert_eq(_server.console_command("shutdown 100"), "Cierre dentro de 100 s")
	assert_eq(_server.console_command("shutdown cancel"), "Cierre cancelado")
	# Todo queda auditado.
	assert_true(commands.audit_total >= 20, "cada uso queda en la auditoría (%d)" % commands.audit_total)
	assert_true(commands.audit[commands.audit.size() - 1].begins_with("[auditoría] consola: shutdown cancel"))


func test_console_lines_run_at_the_start_of_the_next_tick() -> void:
	await _start_server()
	var ana: int = _server.add_fake_player(_brain(), VARDHEIM)
	_combatant(ana).take_damage(500, 1)
	_server.push_console_line("heal Bot-01")
	assert_eq(_combatant(ana).health, 500, "la línea aún no se ha ejecutado")
	await wait_physics_frames(2)
	assert_eq(_combatant(ana).health, 1000, "se ejecuta al empezar el tick, sin bloquearlo")


# --- Cerebro de combate ------------------------------------------------------------------------

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
	assert_true(fought, "los dos bots se encuentran y se golpean (%d golpes)"
			% _server.get_combat().stats[&"hits"])
	var distance: float = _server.get_registry().get_entity(first).get_position().distance_to(
			_server.get_registry().get_entity(second).get_position())
	assert_true(distance < 4.0, "están cerca el uno del otro (%.1f m)" % distance)
	assert_true(_combatant(first).health < 1000 or _combatant(second).health < 1000)
