extends TestCase
## El paquete F3 dentro del [ZoneServer] (docs/fuerte.md, secciones 1 a 5), sin red: la fortaleza de
## pruebas de [FortressFixture] (círculo, capitán, puerta de verdad y puntos de reaparición) con jugadores
## falsos. Se comprueba la captura completa neutral -> Vardheim -> Solmarch con el doble del capitán y las
## órdenes de depuración, los golpes de verdad a la puerta (daño, solo enemigos, rota deja pasar), la
## reparación aplazada con alguien en el vano, la reaparición en el fuerte propio y por oleadas, el
## marcador, el registro de batalla y el informe.
## [br][br]
## Casi todo se avanza deprisa con un [FortressFixture.Stepper] (varios ticks por tick de física); lo que
## depende del movimiento de verdad (cruzar la puerta) lo corre el servidor a su ritmo.

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


# --- Ayudantes --------------------------------------------------------------------------------

## Servidor en la zona plana con la fortaleza de pruebas. Con [param manual] se avanza con el
## [FortressFixture.Stepper]; si no, a su ritmo.
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
	assert_eq(_server.start(config, _world, null, DevAuthProvider.new()), OK, "el servidor arranca")
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


## Avanza [param ticks] ticks del servidor (deprisa con el Stepper, a su ritmo si no).
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


## Un jugador falso quieto de [param realm] en [param position].
func _idle_player(realm: int, position: Vector3) -> int:
	var net_id: int = _server.add_fake_player(_brain(), realm)
	_put(net_id, position)
	return net_id


## Un jugador falso de [param realm] que pulsa PRIMARY en [param tick] mirando hacia la puerta.
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


# --- El servidor con una fortaleza -------------------------------------------------------------

func test_the_server_creates_the_fortress_entity_and_turns_on_the_respawn_waves() -> void:
	await _start_server()
	var fortresses: FortressController = _server.get_fortresses()
	assert_true(fortresses.has_fortresses())
	var entity: NetEntity = fortresses.get_entity(FORTRESS)
	if not assert_not_null(entity):
		return
	assert_eq(_server.get_registry().get_entity(entity.net_id), entity, "está en el registro de la zona")
	assert_eq(entity.kind, NetProtocol.EntityKind.STRUCTURE)
	assert_eq(_server.get_player_count(), 0, "no cuenta como jugador")
	assert_eq(_server.get_combat_timing().respawn_wave_ticks, CombatTiming.WAVE_TICKS,
			"las zonas con fortaleza reaparecen por oleadas")
	assert_eq(_server.console_command("players"), "0 entidades: ", "la fortaleza no sale en la lista de jugadores")
	assert_true(_server.console_command("help").contains("fort_reset"))
	await _advance(30)
	assert_eq(_server.get_tick(), 30)
	assert_true(_war.is_empty(), "una fortaleza sola no avisa de nada")


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
	assert_eq(_server.get_combat_timing().respawn_wave_ticks, 0, "sin oleadas")
	assert_true(_server.console_command("fort_reset").begins_with("No hay ninguna fortaleza"))
	await wait_physics_frames(5)
	assert_eq(_server.get_registry().size(), 0)


# --- Captura de punta a punta ------------------------------------------------------------------

func test_a_full_capture_neutral_to_vardheim_to_solmarch_through_the_server() -> void:
	await _start_server()
	var captain: int = _server.spawn_captain_double(FORTRESS)
	if not assert_true(captain > 0, "el doble del capitán aparece"):
		return
	assert_eq(_server.get_fortresses().get_captain_net_id(FORTRESS), captain)
	var vardheim: int = _idle_player(VARDHEIM, FortressFixture.circle_center())
	await _advance(120)
	assert_eq(_state().phase, FortressState.Phase.GARRISONED, "con el capitán vivo no se captura")
	assert_eq(_state().presence[VARDHEIM], 1, "el capitán, que es un PNJ, está en el círculo y no cuenta")
	# Cae el capitán de los Huecos (aquí, con el comando de depuración).
	assert_eq(_server.console_command("fort_kill_captain"), "El capitán de %s ha muerto" % FORTRESS)
	await _advance(10)
	assert_true(_combatant(captain).is_dead(), "el doble de verdad ha muerto")
	assert_eq(_events_of(NetMessages.EntityEvent.Kind.DEATH).size(), 1)
	await _advance(200)
	assert_eq(_state().owner, VARDHEIM, "capturado por Vardheim")
	assert_eq(_state().phase, FortressState.Phase.CONSOLIDATING)
	assert_eq(_gate().get_owner_realm(), VARDHEIM)
	assert_true(_server.get_scores().get_entry(vardheim).circle_seconds() >= 2,
			"los segundos en el círculo cuentan para el marcador")
	# Pasa la consolidación y aparece (aquí, a mano) el capitán de Vardheim: el segundo capitán.
	await _advance(130)
	assert_eq(_state().phase, FortressState.Phase.GARRISONED)
	var second: int = _server.spawn_captain_double(FORTRESS)
	assert_eq(_server.get_registry().get_entity(second).realm, VARDHEIM, "es del dueño")
	var solmarch: int = _idle_player(SOLMARCH, FortressFixture.circle_center() + Vector3(1.0, 0.0, 0.0))
	_server.teleport(vardheim, Vector3(-20.0, 0.05, 0.0))
	assert_true(_server.console_command("fort_kill_captain").contains("ha muerto"))
	await _advance(220)
	assert_eq(_state().owner, SOLMARCH, "y capturado por Solmarch")
	assert_eq(_gate().get_owner_realm(), SOLMARCH)
	assert_eq(_war_ids(), [WarEvents.CAPTAIN_DOWN, WarEvents.CAPTURE_STARTED, WarEvents.FORT_CAPTURED,
			WarEvents.CAPTAIN_DOWN, WarEvents.CAPTURE_STARTED, WarEvents.FORT_CAPTURED] as Array[int])
	assert_true(_server.get_scores().get_entry(solmarch).circle_seconds() >= 1)
	assert_true(_object_states.size() >= 4, "el estado se replica en cada cambio")


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
	assert_eq(_state().owner, VARDHEIM, "a x20 la captura de 120 ticks dura unos 6")
	assert_true(player > 0)
	assert_eq(_server.console_command("fort_reset"), "%s vuelve a ser neutral" % FORTRESS)
	await _advance(2)
	assert_eq(_state().owner, 0)
	assert_eq(_state().phase, FortressState.Phase.GARRISONED)
	assert_eq(_gate().collision_layer, FortGate.layers_for(0, false))
	assert_true(_server.get_commands().audit_total >= 4, "queda auditado")


# --- La puerta, de verdad ----------------------------------------------------------------------

func test_a_real_swing_takes_health_off_the_gate_and_announces_the_attack() -> void:
	await _start_server()
	var attacker: int = _gate_attacker(VARDHEIM, 12, Vector3(77.5, 0.05, 0.0))
	await _advance(60)
	assert_eq(_state().gate_health, 900 - _slash(90), "el ligero quita lo que dicen los datos")
	var gate_id: int = _server.get_fortresses().get_net_id(FORTRESS)
	var hits: Array[NetMessages.EntityEvent] = _events_of(NetMessages.EntityEvent.Kind.HIT)
	if assert_eq(hits.size(), 1, "un HIT"):
		assert_eq(hits[0].net_id, gate_id, "con el net_id de la fortaleza")
		assert_eq(hits[0].attacker, attacker)
	assert_true(_combatant(attacker).is_in_combat(_server.get_tick()), "el atacante queda en combate")
	assert_eq(_war_ids(), [WarEvents.UNDER_ATTACK] as Array[int])
	assert_eq(_server.get_scores().get_entry(attacker).gate_damage, _slash(90))
	assert_eq(_server.get_combat().stats[&"gate_hits"], 1)
	# El OBJECT_STATE lleva la vida nueva.
	var last: NetMessages.ObjectState = null
	for object_state: NetMessages.ObjectState in _object_states:
		if object_state.has_field(FortressFields.GATE_HEALTH):
			last = object_state
	if assert_not_null(last, "la vida de la puerta se replica"):
		assert_eq(last.get_value(FortressFields.GATE_HEALTH), 900 - _slash(90))


func test_three_attackers_with_the_sword_combo_break_the_gate_in_about_55_seconds() -> void:
	var definition: FortressDefinition = FortressFixture.make_definition()
	definition.gate_health = 9000
	await _start_server(true, definition)
	# El combo de espada encadenado: la segunda y la tercera pulsación, 4 ticks antes de acabar el ligero anterior.
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
	assert_true(_state().is_gate_broken(), "rota en menos de 75 s")
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
			"tres atacantes la rompen en unos 55 s (han sido %.1f s)" % seconds)
	assert_eq(_war_ids(), [WarEvents.UNDER_ATTACK, WarEvents.GATE_BROKEN] as Array[int],
			"un solo aviso de ataque y el de rotura")


func test_the_owner_does_not_damage_its_own_gate_but_its_enemies_do() -> void:
	await _start_server()
	_server.console_command("fort_owner vardheim")
	var friend: int = _gate_attacker(VARDHEIM, 12, Vector3(77.5, 0.05, -1.0))
	var enemy: int = _gate_attacker(SOLMARCH, 100, Vector3(77.5, 0.05, 1.0))
	await _advance(60)
	assert_eq(_state().gate_health, 900, "el dueño no la daña")
	await _advance(80)
	assert_eq(_state().gate_health, 900 - _slash(90), "su enemigo sí")
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
			"el dueño cruza su puerta cerrada")
	assert_true(_server.get_registry().get_entity(walkers[1]).get_position().x < gate_x,
			"su enemigo se queda al otro lado")
	# Rota, no para a nadie: el enemigo sigue andando y cruza.
	var target: StructureTarget = _server.get_fortresses().get_structure_targets()[0]
	_server.get_fortresses().on_structure_hit(target, _combatant(walkers[1]), 900, _server.get_tick() + 1)
	await wait_physics_frames(150)
	assert_true(_gate().is_broken())
	assert_true(_server.get_registry().get_entity(walkers[1]).get_position().x > gate_x + 1.0,
			"con la puerta rota también cruza el enemigo")


func test_the_gate_repair_waits_for_the_doorway_to_be_free() -> void:
	await _start_server()
	var blocker: int = _idle_player(VARDHEIM, FortressFixture.gate_position() + Vector3(0.0, 0.05, 1.0))
	var target: StructureTarget = _server.get_fortresses().get_structure_targets()[0]
	_server.get_fortresses().on_structure_hit(target, _combatant(blocker), 900, 1)
	await _advance(21 * 60 + 30)
	assert_true(_gate().is_broken(), "20 s sin daño, pero alguien ocupa el vano")
	assert_true(_server.get_fortresses().is_repair_pending(FORTRESS))
	_server.teleport(blocker, Vector3(60.0, 0.05, 0.0))
	await _advance(3)
	assert_false(_gate().is_broken(), "libre el vano, la puerta se repara")
	assert_eq(_state().gate_health, 900)


# --- Reaparición en el fuerte ------------------------------------------------------------------

## Mata a [param net_id], espera a la oleada, pide reaparecer en [param point_index] y espera a que lo haga. Con
## [param attacked] marca el fuerte como atacado justo antes de pedirlo.
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
			"Vardheim reaparece dentro de su fuerte")
	assert_eq(_respawn_events(ally)[0].point, 2, "con el índice de la lista estática")
	await _die_and_respawn_at(enemy, 2)
	assert_vec_near(_server.get_registry().get_entity(enemy).get_position(), FortressFixture.SOLMARCH_CAMP,
			1.0, "Solmarch no puede elegir el fuerte de Vardheim y reaparece en su campamento")
	assert_eq(_respawn_events(enemy)[0].point, 1, "sin aviso: el evento lleva el campamento")


func test_a_neutral_or_attacked_fort_is_not_a_respawn_point() -> void:
	await _start_server()
	var player: int = _idle_player(VARDHEIM, Vector3(-20.0, 0.05, 6.0))
	await _advance(5)
	await _die_and_respawn_at(player, 2)
	assert_vec_near(_server.get_registry().get_entity(player).get_position(), FortressFixture.VARDHEIM_CAMP,
			1.0, "un fuerte neutral no vale")
	# Suyo pero atacado: tampoco.
	_server.console_command("fort_owner vardheim")
	await _advance(3)
	await _die_and_respawn_at(player, 3, true)
	assert_eq(_respawn_events(player).back().point, 0, "atacado: el campamento")
	# Pasados los 5 s sin ataques, vuelve a valer.
	await _die_and_respawn_at(player, 3)
	assert_eq(_respawn_events(player).back().point, 3, "tranquilo otra vez: el fuerte")


func test_respawns_come_in_waves_every_ten_seconds() -> void:
	await _start_server()
	var player: int = _idle_player(VARDHEIM, Vector3(-20.0, 0.05, 6.0))
	await _advance(100)
	_server.console_command("kill %d" % player)
	await _advance(2)
	var combatant: Combatant = _combatant(player)
	assert_eq(combatant.respawn_tick % 600, 0, "cae en una oleada")
	assert_true(combatant.respawn_tick >= combatant.death_tick + 600, "al menos 10 s después de morir")
	assert_true(combatant.respawn_tick < combatant.death_tick + 1200, "y no más de 20 s")
	# Una petición hecha poco antes de la oleada queda pendiente y se cumple en ella, no antes.
	await _advance(combatant.respawn_tick - _server.get_tick() - 8)
	assert_eq(_server.get_combat().request_respawn(player, 0, _server.get_tick() + 1),
			CombatDirector.RespawnRequestResult.ACCEPTED)
	await _advance(4)
	assert_true(combatant.is_dead(), "aún no ha salido la oleada")
	await _advance(8)
	assert_true(combatant.is_alive(), "ya ha reaparecido")
	assert_eq(_events_of(NetMessages.EntityEvent.Kind.RESPAWN).size(), 1)


# --- Marcador y registro de batalla -----------------------------------------------------------

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
	assert_eq(rows[0].merits, 10, "una baja vale 10 méritos")
	assert_eq(rows[1].merits, 5, "una asistencia, 5")
	assert_eq(rows[2].merits, 0)
	# Un PNJ que mata o muere no entra en el marcador.
	var npc: int = _server.add_npc(_brain(), "Hueco", 0, Vector3(0.0, 0.05, 20.0), 0.0)
	combat.event_emitted.emit(NetMessages.EntityEvent.death(npc, 60, killer, 1), PackedInt32Array())
	assert_null(scores.get_entry(npc))
	# Salir del mundo olvida el marcador del que se va.
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
	assert_true(lines.size() >= 5, "el registro tiene líneas (%d)" % lines.size())
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
	assert_true(deaths.size() >= 2, "la muerte del capitán y la del jugador")
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
