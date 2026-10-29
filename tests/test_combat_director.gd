extends TestCase
## Pruebas del [CombatDirector] (docs/combate.md, secciones 4.2 y 5) con luchadores montados a mano:
## aplicar un golpe (daño, críticos, carga del fuerte, bloqueo, rotura de guardia, parada), los
## controles (el tambaleo corta un ligero pero no un fuerte con entereza, empuje, la cadena y su
## inmunidad), la muerte (una sola DEATH y KILL con asistentes), el entorno (caída, volumen letal,
## bajo y = -100), la reaparición pedida y automática con protección y el maniquí inmortal.
## [br][br]
## No hay red ni servidor: el director recibe los cuerpos y se le llama tick a tick con
## [method CombatDirector.process_tick].

const VARDHEIM: int = NetProtocol.Realm.VARDHEIM
const SOLMARCH: int = NetProtocol.Realm.SOLMARCH
const HUECOS: int = RealmCatalog.NEUTRAL_CODE
const ZONE_ID: StringName = &"test_world"
const S: int = 400
const HIT_CRITICAL: int = NetMessages.EntityEvent.HIT_FLAG_CRITICAL
const HIT_BLOCKED: int = NetMessages.EntityEvent.HIT_FLAG_BLOCKED
const HIT_PARRIED: int = NetMessages.EntityEvent.HIT_FLAG_PARRIED
const HIT_GUARD_BREAK: int = NetMessages.EntityEvent.HIT_FLAG_GUARD_BREAK
const HIT_LETHAL: int = NetMessages.EntityEvent.HIT_FLAG_LETHAL

var _viewport: SubViewport
var _world: Node3D
var _history: StateHistory
var _director: CombatDirector
var _events: Array[NetMessages.EntityEvent] = []
var _involved: Array[PackedInt32Array] = []


func before_each() -> void:
	_viewport = CombatFixture.make_world(tree.root)
	_world = NetHarness.get_world(_viewport)
	_history = StateHistory.new()
	_director = CombatDirector.new(_history, ZONE_ID, _world, SafeAreas.new(),
			CombatFixture.place, _pick_spawn)
	_events.clear()
	_involved.clear()
	_director.event_emitted.connect(func(event: NetMessages.EntityEvent,
			involved: PackedInt32Array) -> void:
		_events.append(event)
		_involved.append(involved))
	await wait_physics_frames(3)


func after_each() -> void:
	_director = null
	if is_instance_valid(_viewport):
		_viewport.get_parent().remove_child(_viewport)
		_viewport.free()
	_viewport = null
	_world = null
	await wait_process_frames()


# --- Ayudantes --------------------------------------------------------------------------------

func _pick_spawn(realm: int) -> Transform3D:
	return Transform3D(Basis.IDENTITY, Vector3(100.0 + float(realm), 0.0, 100.0))


func _body(net_id: int, realm: int, position: Vector3, yaw: float) -> Combatant:
	var entity: NetEntity = CombatFixture.make_entity(_world, net_id, realm, position, yaw)
	_history.add_entity(net_id)
	return _director.add(entity, CombatFixture.make_queue(yaw), null)


## Atacante de Vardheim en el origen mirando a -Z y víctima de Solmarch a 1,5 m delante, de cara.
func _duel() -> Array[Combatant]:
	var attacker: Combatant = _body(1, VARDHEIM, Vector3.ZERO, 0.0)
	var victim: Combatant = _body(2, SOLMARCH, Vector3(0.0, 0.0, -1.5), PI)
	return [attacker, victim]


func _tick(s: int = S) -> void:
	_director.process_tick(s, _world.get_world_3d().direct_space_state)


func _events_of(kind: int) -> Array[NetMessages.EntityEvent]:
	var found: Array[NetMessages.EntityEvent] = []
	for event: NetMessages.EntityEvent in _events:
		if event.event == kind:
			found.append(event)
	return found


func _light_id(index: int) -> int:
	return CombatCatalog.weapon(CombatCatalog.weapon_id(CombatCatalog.DEFAULT_WEAPON)).light_ids[index]


func _combat_of(combatant: Combatant) -> CombatState:
	return combatant.get_character().combat


# --- Daño -------------------------------------------------------------------------------------

func test_light_hit_applies_damage_events_and_combat_state() -> void:
	var duel: Array[Combatant] = _duel()
	CombatFixture.start_light_active(duel[0], S)
	_tick()
	assert_eq(duel[1].health, 1000 - 90, "el ligero quita 90")
	assert_eq(duel[0].health, 1000, "el atacante no pierde vida")
	var hits: Array[NetMessages.EntityEvent] = _events_of(NetMessages.EntityEvent.Kind.HIT)
	if not assert_eq(hits.size(), 1, "un HIT"):
		return
	assert_eq(hits[0].net_id, 2, "atado a la víctima")
	assert_eq(hits[0].attacker, 1)
	assert_eq(hits[0].amount, 90)
	assert_eq(hits[0].hit_flags, 0)
	assert_eq(hits[0].attack_id, _light_id(0))
	assert_eq(hits[0].damage_type, DamageFormula.DamageType.SLASH)
	assert_eq(hits[0].tick, S)
	assert_eq(_involved[0], PackedInt32Array([2, 1]), "víctima y atacante son los implicados")
	assert_true(duel[0].is_in_combat(S) and duel[1].is_in_combat(S), "los dos entran en combate")
	assert_eq(duel[1].ledger.damage_by(1, S), 90, "el registro de daño lo apunta")
	assert_eq(duel[1].last_enemy_id, 1)
	assert_eq(duel[1].entity.health, 910, "y lo publica para los snapshots")
	assert_true((duel[1].entity.status & NetMessages.STATUS_IN_COMBAT) != 0)
	assert_eq(duel[1].entity.health_q, EntityRecord.quantize_health(910, 1000))
	assert_eq(_combat_of(duel[1]).action, CombatState.Action.NONE, "un ligero no tambalea")


func test_back_hit_is_critical_and_charged_heavy_scales_damage() -> void:
	var attacker: Combatant = _body(1, VARDHEIM, Vector3.ZERO, 0.0)
	var victim: Combatant = _body(2, SOLMARCH, Vector3(0.0, 0.0, -1.5), 0.0)
	CombatFixture.start_light_active(attacker, S)
	_tick()
	assert_eq(victim.health, 1000 - 135, "por la espalda: 90 × 1,5")
	var hits: Array[NetMessages.EntityEvent] = _events_of(NetMessages.EntityEvent.Kind.HIT)
	assert_eq(hits[0].hit_flags, HIT_CRITICAL, "marcado como crítico")
	# Fuerte con la carga máxima: 180 × 1,7 (y por la espalda × 1,5).
	var heavy: AttackTicks = CombatCatalog.attack(CombatCatalog.weapon(
			_combat_of(attacker).weapon_id).heavy_id)
	victim.heal_full()
	CombatFixture.start_heavy_active(attacker, S + 100, heavy.charge_max_ticks)
	_director.process_tick(S + 100, _world.get_world_3d().direct_space_state)
	assert_eq(victim.health, 1000 - roundi(180.0 * 1.7 * 1.5), "carga máxima y espalda")
	# Sin carga extra: solo el daño base.
	victim.heal_full()
	CombatFixture.start_heavy_active(attacker, S + 200, heavy.charge_min_ticks)
	_director.process_tick(S + 200, _world.get_world_3d().direct_space_state)
	assert_eq(victim.health, 1000 - roundi(180.0 * 1.5), "carga mínima: base × crítico")


func test_no_friendly_fire_and_no_hit_out_of_reach() -> void:
	var attacker: Combatant = _body(1, VARDHEIM, Vector3.ZERO, 0.0)
	var ally: Combatant = _body(2, VARDHEIM, Vector3(0.0, 0.0, -1.5), PI)
	_body(3, SOLMARCH, Vector3(0.0, 0.0, -6.0), PI)
	CombatFixture.start_light_active(attacker, S)
	_tick()
	assert_eq(ally.health, 1000, "sin fuego amigo")
	assert_eq(_events_of(NetMessages.EntityEvent.Kind.HIT).size(), 0)
	assert_false(attacker.is_in_combat(S), "sin golpes no hay combate")


# --- Bloqueo, rotura de guardia y parada ------------------------------------------------------

func test_block_mitigates_all_damage_and_costs_stamina() -> void:
	var duel: Array[Combatant] = _duel()
	CombatFixture.start_light_active(duel[0], S)
	CombatFixture.start_block(duel[1], S - 30)
	var stamina_before: int = _combat_of(duel[1]).stamina
	_tick()
	assert_eq(duel[1].health, 1000, "el escudo para todo el daño físico frontal")
	assert_eq(_combat_of(duel[1]).stamina, stamina_before - 90, "1 de resistencia por punto absorbido")
	assert_eq(_combat_of(duel[1]).stamina_regen_tick, S + CombatCatalog.tables().regen_delay_ticks,
			"gastar resistencia retrasa su regeneración")
	var hits: Array[NetMessages.EntityEvent] = _events_of(NetMessages.EntityEvent.Kind.HIT)
	if assert_eq(hits.size(), 1):
		assert_eq(hits[0].hit_flags, HIT_BLOCKED)
		assert_eq(hits[0].amount, 0)
	assert_eq(_combat_of(duel[1]).action, CombatState.Action.BLOCK, "sigue bloqueando")
	assert_true(duel[1].is_in_combat(S), "un bloqueo también es combate")


func test_guard_break_with_no_stamina_stuns_and_lets_the_rest_through() -> void:
	var duel: Array[Combatant] = _duel()
	CombatFixture.start_light_active(duel[0], S)
	CombatFixture.start_block(duel[1], S - 30)
	_combat_of(duel[1]).stamina = 20
	_tick()
	assert_eq(duel[1].health, 1000 - 70, "pasa lo que el escudo no absorbe (90 - 20)")
	assert_eq(_combat_of(duel[1]).stamina, 0, "se queda sin resistencia")
	assert_true(_combat_of(duel[1]).is_exhausted(), "agotado")
	assert_eq(_combat_of(duel[1]).action, CombatState.Action.STUN, "rotura de guardia: aturdido")
	assert_eq(_combat_of(duel[1]).cc_until_tick, S + 60, "durante 1 s")
	var hits: Array[NetMessages.EntityEvent] = _events_of(NetMessages.EntityEvent.Kind.HIT)
	if assert_eq(hits.size(), 1):
		assert_eq(hits[0].hit_flags, HIT_BLOCKED | HIT_GUARD_BREAK)
		assert_eq(hits[0].amount, 70)


func test_a_guard_break_with_full_stamina_does_not_happen() -> void:
	var duel: Array[Combatant] = _duel()
	CombatFixture.start_light_active(duel[0], S)
	CombatFixture.start_block(duel[1], S - 30)
	_combat_of(duel[1]).stamina = 90
	_tick()
	assert_eq(_combat_of(duel[1]).action, CombatState.Action.BLOCK, "justo le alcanza")
	assert_eq(_combat_of(duel[1]).stamina, 0)


func test_parry_staggers_the_attacker_and_costs_nothing() -> void:
	var duel: Array[Combatant] = _duel()
	CombatFixture.start_light_active(duel[0], S)
	CombatFixture.start_block(duel[1], S - 2, true)
	var stamina_before: int = _combat_of(duel[1]).stamina
	_tick()
	assert_eq(duel[1].health, 1000, "sin daño")
	assert_eq(_combat_of(duel[1]).stamina, stamina_before, "y sin gasto de resistencia")
	assert_eq(_combat_of(duel[0]).action, CombatState.Action.STAGGER, "el atacante tambalea")
	assert_eq(_combat_of(duel[0]).cc_until_tick, S + 36, "0,6 s")
	var hits: Array[NetMessages.EntityEvent] = _events_of(NetMessages.EntityEvent.Kind.HIT)
	if assert_eq(hits.size(), 1):
		assert_eq(hits[0].hit_flags, HIT_PARRIED)
		assert_eq(hits[0].amount, 0)
		assert_eq(hits[0].attacker, 1)


# --- Controles --------------------------------------------------------------------------------

func test_stagger_cuts_a_light_but_not_a_hyper_armor_heavy() -> void:
	var attacker: Combatant = _body(1, VARDHEIM, Vector3.ZERO, 0.0)
	var cut: Combatant = _body(2, SOLMARCH, Vector3(0.0, 0.0, -1.5), PI)
	# El tercer ligero tambalea 0,3 s. La víctima estaba en la anticipación de su propio ligero.
	var state: CombatState = _combat_of(cut)
	state.action = CombatState.Action.LIGHT
	state.action_id = _light_id(0)
	state.action_tick = S - 3
	CombatFixture.start_light_active(attacker, S, 2)
	_tick()
	assert_eq(state.action, CombatState.Action.STAGGER, "el tambaleo corta el ligero")
	assert_eq(state.cc_until_tick, S + 18, "0,3 s")
	assert_eq(cut.health, 1000 - 130, "y recibe el daño del ligero 3")

	# Con un fuerte en su golpe activo (entereza) no se interrumpe, pero el daño sí entra.
	var armored: Combatant = _body(3, SOLMARCH, Vector3(0.0, 0.0, -1.5), PI)
	cut.get_character().global_position = Vector3(50.0, 0.0, 0.0)
	CombatFixture.start_heavy_active(armored, S + 100)
	CombatFixture.start_light_active(attacker, S + 100, 2)
	_director.process_tick(S + 100, _world.get_world_3d().direct_space_state)
	assert_eq(_combat_of(armored).action, CombatState.Action.HEAVY, "la entereza lo mantiene")
	assert_eq(armored.health, 1000 - 130, "el daño entra igualmente")


func test_heavy_knockback_goes_away_from_the_attacker() -> void:
	var attacker: Combatant = _body(1, VARDHEIM, Vector3.ZERO, 0.0)
	var victim: Combatant = _body(2, SOLMARCH, Vector3(0.0, 0.0, -1.5), PI)
	CombatFixture.start_heavy_active(attacker, S)
	_tick()
	var state: CombatState = _combat_of(victim)
	assert_eq(state.action, CombatState.Action.STAGGER)
	assert_eq(state.cc_until_tick, S + 30, "0,5 s")
	assert_vec_near(state.knockback, Vector2(0.0, -4.0), 0.01, "4 m/s alejándose del atacante")


func test_third_control_in_the_window_does_not_enter_and_opens_immunity() -> void:
	var attacker: Combatant = _body(1, VARDHEIM, Vector3.ZERO, 0.0)
	var victim: Combatant = _body(2, SOLMARCH, Vector3(0.0, 0.0, -1.5), PI)
	var state: CombatState = _combat_of(victim)
	var results: Array[bool] = []
	for hit_index: int in 4:
		var s: int = S + hit_index * 40
		state.action = CombatState.Action.NONE
		CombatFixture.start_light_active(attacker, s, 2)
		_director.process_tick(s, _world.get_world_3d().direct_space_state)
		results.append(state.action == CombatState.Action.STAGGER)
	assert_eq(results, [true, true, false, false] as Array[bool],
			"los dos primeros entran; el tercero y el cuarto (inmunidad) no")
	assert_eq(victim.health, 1000 - 4 * 130, "pero el daño entra siempre")
	assert_eq(victim.cc_immune_until, S + 80 + 120, "2 s de inmunidad desde el tercero")
	# Pasada la inmunidad, el control vuelve a entrar.
	var later: int = S + 80 + 121
	state.action = CombatState.Action.NONE
	CombatFixture.start_light_active(attacker, later, 2)
	_director.process_tick(later, _world.get_world_3d().direct_space_state)
	assert_eq(state.action, CombatState.Action.STAGGER, "tras la inmunidad vuelve a entrar")


# --- Muerte -----------------------------------------------------------------------------------

func test_lethal_hit_kills_once_with_death_and_kill_events() -> void:
	var duel: Array[Combatant] = _duel()
	duel[1].health = 50
	CombatFixture.start_light_active(duel[0], S)
	_tick()
	assert_true(duel[1].is_dead())
	assert_eq(duel[1].death_tick, S)
	assert_eq(duel[1].respawn_tick, S + _director.timing.respawn)
	assert_eq(_combat_of(duel[1]).action, CombatState.Action.DEAD)
	var hits: Array[NetMessages.EntityEvent] = _events_of(NetMessages.EntityEvent.Kind.HIT)
	if assert_eq(hits.size(), 1):
		assert_eq(hits[0].amount, 50, "solo lo que quedaba")
		assert_eq(hits[0].hit_flags, HIT_LETHAL)
	var deaths: Array[NetMessages.EntityEvent] = _events_of(NetMessages.EntityEvent.Kind.DEATH)
	if assert_eq(deaths.size(), 1, "una DEATH"):
		assert_eq(deaths[0].net_id, 2)
		assert_eq(deaths[0].killer, 1)
		assert_eq(deaths[0].attack_id, _light_id(0))
	var kills: Array[NetMessages.EntityEvent] = _events_of(NetMessages.EntityEvent.Kind.KILL)
	if assert_eq(kills.size(), 1, "un KILL"):
		assert_eq(kills[0].net_id, 2)
		assert_eq(kills[0].killer, 1)
		assert_eq(kills[0].assistants.size(), 0)
	assert_eq(duel[1].entity.status, NetMessages.STATUS_DEAD)
	assert_eq(duel[1].entity.health_q, EntityRecord.HEALTH_Q_DEAD)
	assert_eq(duel[1].entity.respawn_tick, duel[1].respawn_tick)
	assert_eq(duel[1].killer_id, 1)
	# Los ticks siguientes no repiten nada: ni más muertes ni golpes contra el cadáver.
	for offset: int in range(1, 20):
		_tick(S + offset)
	assert_eq(_events_of(NetMessages.EntityEvent.Kind.DEATH).size(), 1, "una sola DEATH")
	assert_eq(_events_of(NetMessages.EntityEvent.Kind.KILL).size(), 1, "un solo KILL")
	assert_eq(_events_of(NetMessages.EntityEvent.Kind.HIT).size(), 1, "y ningún golpe más")
	var stats: Dictionary[StringName, int] = _director.stats
	assert_eq(stats[&"deaths"], 1)
	assert_eq(stats[&"kills"], 1)


func test_kill_lists_the_assistants_of_the_damage_ledger() -> void:
	var duel: Array[Combatant] = _duel()
	duel[1].health = 90
	# Antes de este golpe: 600 de otro atacante, 300 de un tercero y 5 de un cuarto.
	duel[1].ledger.record(S - 100, 5, 600)
	duel[1].ledger.record(S - 50, 6, 300)
	duel[1].ledger.record(S - 20, 7, 5)
	CombatFixture.start_light_active(duel[0], S)
	_tick()
	var kills: Array[NetMessages.EntityEvent] = _events_of(NetMessages.EntityEvent.Kind.KILL)
	if not assert_eq(kills.size(), 1):
		return
	assert_eq(kills[0].killer, 1)
	assert_eq(kills[0].assistants, PackedInt32Array([5, 6]),
			"asisten quienes hicieron al menos el 10 % del daño, por daño descendente")
	var kill_index: int = _events.find(kills[0])
	assert_eq(_involved[kill_index], PackedInt32Array([2, 1, 5, 6]),
			"los implicados incluyen a los asistentes")


func test_a_kill_by_an_npc_is_credited_to_the_npc_and_allies_and_self_do_not_assist() -> void:
	var npc: Combatant = _body(7, HUECOS, Vector3.ZERO, 0.0)
	var victim: Combatant = _body(2, VARDHEIM, Vector3(0.0, 0.0, -1.5), PI)
	victim.health = 90
	# Un aliado de la víctima (id 3) y la propia víctima (id 2) no pueden figurar como asistentes.
	victim.ledger.record(S - 10, 3, 400)
	victim.ledger.record(S - 5, 2, 400)
	victim.ledger.record(S - 5, 9, 400)
	CombatFixture.start_light_active(npc, S)
	_tick()
	var kills: Array[NetMessages.EntityEvent] = _events_of(NetMessages.EntityEvent.Kind.KILL)
	if not assert_eq(kills.size(), 1, "un PNJ puede matar"):
		return
	assert_eq(kills[0].killer, 7, "el KILL es del PNJ")
	assert_false(kills[0].assistants.has(2), "la autolesión no cuenta")
	assert_true(kills[0].assistants.has(9), "quien hizo daño asiste")
	assert_eq(_events_of(NetMessages.EntityEvent.Kind.DEATH)[0].killer, 7)


func test_simultaneous_exchange_can_kill_both() -> void:
	var duel: Array[Combatant] = _duel()
	duel[0].health = 50
	duel[1].health = 50
	CombatFixture.start_light_active(duel[0], S)
	CombatFixture.start_light_active(duel[1], S)
	_tick()
	assert_true(duel[0].is_dead() and duel[1].is_dead(), "los dos golpes del mismo tick matan a los dos")
	assert_eq(_events_of(NetMessages.EntityEvent.Kind.DEATH).size(), 2)
	assert_eq(_events_of(NetMessages.EntityEvent.Kind.KILL).size(), 2)


# --- Entorno ----------------------------------------------------------------------------------

func test_fall_damage_above_the_threshold_only() -> void:
	var body: Combatant = _body(1, VARDHEIM, Vector3.ZERO, 0.0)
	body.get_character().last_landing_speed = 14.0
	_tick()
	assert_eq(body.health, 1000, "14 m/s (la pasarela de 3 m saltando) no hace daño")
	body.get_character().last_landing_speed = 15.0
	_tick(S + 1)
	assert_eq(body.health, 1000, "en el umbral tampoco")
	body.get_character().last_landing_speed = 23.0
	_tick(S + 2)
	assert_eq(body.health, 1000 - 560, "23 m/s (la torre de 12 m): (23 - 15) × 70")
	var hits: Array[NetMessages.EntityEvent] = _events_of(NetMessages.EntityEvent.Kind.HIT)
	if assert_eq(hits.size(), 1, "un HIT del entorno"):
		assert_eq(hits[0].attacker, 0)
		assert_eq(hits[0].amount, 560)
	assert_true(body.is_in_combat(S + 2), "recibir daño pone en combate")
	assert_eq(_events_of(NetMessages.EntityEvent.Kind.DEATH).size(), 0)


func test_fall_death_is_credited_to_the_last_enemy_who_hit_within_ten_seconds() -> void:
	var victim: Combatant = _body(1, VARDHEIM, Vector3.ZERO, 0.0)
	_body(2, SOLMARCH, Vector3(30.0, 0.0, 0.0), 0.0)
	victim.health = 400
	victim.note_enemy_hit(2, _light_id(1), S - 100)
	victim.ledger.record(S - 100, 2, 100)
	victim.get_character().last_landing_speed = 25.0
	_tick()
	assert_true(victim.is_dead(), "700 de caída con 400 de vida")
	var deaths: Array[NetMessages.EntityEvent] = _events_of(NetMessages.EntityEvent.Kind.DEATH)
	if assert_eq(deaths.size(), 1):
		assert_eq(deaths[0].killer, 2, "acreditada al enemigo que le golpeó")
		assert_eq(deaths[0].attack_id, 0, "sin ataque: lo mató el entorno")
	var kills: Array[NetMessages.EntityEvent] = _events_of(NetMessages.EntityEvent.Kind.KILL)
	if assert_eq(kills.size(), 1, "y hay KILL para el enemigo"):
		assert_eq(kills[0].killer, 2)
	# Sin un enemigo reciente, la muerte es del entorno y no hay KILL.
	var lonely: Combatant = _body(3, VARDHEIM, Vector3(0.0, 0.0, 50.0), 0.0)
	lonely.health = 100
	lonely.note_enemy_hit(2, 1, S - 700)
	lonely.get_character().last_landing_speed = 25.0
	_tick(S + 1)
	assert_true(lonely.is_dead())
	assert_eq(_events_of(NetMessages.EntityEvent.Kind.DEATH)[1].killer, 0, "hace más de 10 s: entorno")
	assert_eq(_events_of(NetMessages.EntityEvent.Kind.KILL).size(), 1, "sin KILL")


func test_falling_below_the_world_kills_and_moves_the_body_to_the_spawn_while_dead() -> void:
	var body: Combatant = _body(1, VARDHEIM, Vector3.ZERO, 0.0)
	body.get_character().global_position = Vector3(0.0, -150.0, 0.0)
	_tick()
	assert_true(body.is_dead(), "muere")
	assert_eq(_combat_of(body).action, CombatState.Action.DEAD)
	assert_vec_near(body.entity.get_position(), Vector3(101.0, 0.0, 100.0), 1e-3,
			"y el cuerpo vuelve al punto de aparición de su reino")
	assert_eq(body.entity.teleport_counter, 1, "con contador de teletransporte")
	assert_vec_near(body.get_character().velocity, Vector3.ZERO, 1e-6, "sin velocidad")
	assert_eq(_events_of(NetMessages.EntityEvent.Kind.DEATH).size(), 1)
	for offset: int in range(1, 10):
		_tick(S + offset)
	assert_eq(_events_of(NetMessages.EntityEvent.Kind.DEATH).size(), 1, "una sola DEATH")
	assert_eq(body.entity.teleport_counter, 1, "y no se vuelve a colocar")
	assert_eq(_director.stats[&"voids"], 1)


func test_lethal_volume_kills_whoever_is_inside() -> void:
	var inside: Combatant = _body(1, VARDHEIM, Vector3(0.0, 0.0, 0.0), 0.0)
	var outside: Combatant = _body(2, SOLMARCH, Vector3(20.0, 0.0, 0.0), 0.0)
	var area := Area3D.new()
	area.name = "Lava"
	area.collision_layer = 0
	area.collision_mask = PlayerCharacter.CHARACTER_COLLISION_LAYER
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(6.0, 4.0, 6.0)
	shape.shape = box
	shape.position = Vector3(0.0, 1.0, 0.0)
	area.add_child(shape)
	area.add_to_group(Zones.LETHAL_GROUP)
	_world.add_child(area)
	await wait_physics_frames(3)
	_tick()
	assert_true(inside.is_dead(), "dentro del volumen letal muere")
	assert_true(outside.is_alive(), "fuera no le pasa nada")
	assert_eq(_events_of(NetMessages.EntityEvent.Kind.DEATH).size(), 1)
	assert_eq(_director.stats[&"lethal_volumes"], 1)


# --- Reaparición ------------------------------------------------------------------------------

func _kill_for_respawn(realm: int = VARDHEIM) -> Combatant:
	_director.timing.respawn = 30
	_director.timing.auto_respawn = 120
	_director.timing.protection = 50
	var body: Combatant = _body(1, realm, Vector3(5.0, 0.0, 5.0), 0.0)
	_director.kill(body, S)
	_events.clear()
	return body


func test_requested_respawn_waits_for_its_tick_and_uses_the_chosen_point() -> void:
	var body: Combatant = _kill_for_respawn()
	assert_true(body.is_dead())
	assert_eq(body.respawn_tick, S + 30)
	assert_eq(_director.request_respawn(1, 1, S + 1), CombatDirector.RespawnRequestResult.TOO_EARLY,
			"mucho antes de poder")
	assert_eq(_director.request_respawn(1, 1, S + 20), CombatDirector.RespawnRequestResult.ACCEPTED,
			"un poco antes se admite (el cliente cuenta el tick por delante)")
	for offset: int in range(1, 30):
		_tick(S + offset)
	assert_true(body.is_dead(), "no reaparece antes de su tick")
	_tick(S + 30)
	assert_true(body.is_alive(), "reaparece en su tick")
	assert_eq(body.health, body.max_health, "con la vida llena")
	assert_eq(_combat_of(body).action, CombatState.Action.NONE, "sin acción")
	assert_eq(_combat_of(body).stamina, CombatCatalog.rules().stamina_max, "y con la resistencia llena")
	assert_vec_near(body.entity.get_position(), ZoneFixture.VARDHEIM_SPAWNS[1], 0.01,
			"en el segundo punto de aparición de su reino")
	assert_eq(body.entity.teleport_counter, 1, "con contador de teletransporte")
	assert_true(body.is_protected(S + 30 + 49), "protegido")
	assert_false(body.is_protected(S + 30 + 50), "durante la protección configurada")
	assert_true((body.entity.status & NetMessages.STATUS_PROTECTED) != 0, "se publica en el estado")
	assert_eq(body.entity.respawn_tick, 0)
	var respawns: Array[NetMessages.EntityEvent] = _events_of(NetMessages.EntityEvent.Kind.RESPAWN)
	if assert_eq(respawns.size(), 1, "un RESPAWN"):
		assert_eq(respawns[0].point, 1)
		assert_eq(respawns[0].net_id, 1)
		assert_eq(respawns[0].tick, S + 30)


func test_respawn_request_when_alive_is_out_of_time_and_a_stale_index_uses_the_first_point() -> void:
	var body: Combatant = _body(1, VARDHEIM, Vector3(5.0, 0.0, 5.0), 0.0)
	assert_eq(_director.request_respawn(1, 0, S), CombatDirector.RespawnRequestResult.NOT_DEAD,
			"vivo: fuera de plazo")
	assert_eq(_director.request_respawn(99, 0, S), CombatDirector.RespawnRequestResult.NOT_DEAD,
			"un id desconocido también")
	_director.timing.respawn = 10
	_director.kill(body, S)
	assert_eq(_director.request_respawn(1, 77, S + 10), CombatDirector.RespawnRequestResult.ACCEPTED,
			"un índice que ya no vale no es un error")
	_tick(S + 10)
	assert_true(body.is_alive())
	assert_vec_near(body.entity.get_position(), ZoneFixture.VARDHEIM_SPAWNS[0], 0.01,
			"se usa el primer punto del reino")


func test_automatic_respawn_after_the_long_wait_in_the_first_point() -> void:
	var body: Combatant = _kill_for_respawn(SOLMARCH)
	for offset: int in range(1, 120):
		_tick(S + offset)
	assert_true(body.is_dead(), "sin pedirlo no reaparece antes de los 30 s")
	_tick(S + 120)
	assert_true(body.is_alive(), "reaparece solo")
	assert_vec_near(body.entity.get_position(), ZoneFixture.SOLMARCH_SPAWN, 0.01)
	assert_eq(_director.stats[&"respawns"], 1)


func test_protection_blocks_hits_and_is_lost_when_attacking() -> void:
	var attacker: Combatant = _body(5, VARDHEIM, Vector3(40.0, 0.0, 0.0), 0.0)
	var body: Combatant = _kill_for_respawn(SOLMARCH)
	_director.request_respawn(1, 0, S + 20)
	_tick(S + 30)
	assert_true(body.is_protected(S + 30))
	# Un golpe contra el recién reaparecido no hace nada.
	attacker.get_character().global_position = body.entity.get_position() + Vector3(0.0, 0.0, 1.5)
	attacker.get_character().yaw = 0.0
	CombatFixture.start_light_active(attacker, S + 31)
	_director.process_tick(S + 31, _world.get_world_3d().direct_space_state)
	assert_eq(body.health, body.max_health, "la protección evita el daño")
	assert_eq(_events_of(NetMessages.EntityEvent.Kind.HIT).size(), 0)
	# Al empezar un ataque pierde la protección.
	_combat_of(body).action = CombatState.Action.LIGHT
	_combat_of(body).action_id = _light_id(0)
	_combat_of(body).action_tick = S + 32
	_director.process_tick(S + 32, _world.get_world_3d().direct_space_state)
	assert_false(body.is_protected(S + 33), "atacar pierde la protección")
	assert_eq(body.entity.status & NetMessages.STATUS_PROTECTED, 0)


# --- Maniquí ----------------------------------------------------------------------------------

func test_immortal_dummy_never_dies_and_heals_after_five_seconds() -> void:
	var attacker: Combatant = _body(1, VARDHEIM, Vector3.ZERO, 0.0)
	var dummy: Combatant = _body(2, HUECOS, Vector3(0.0, 0.0, -1.5), PI)
	dummy.immortal = true
	dummy.health = 40
	CombatFixture.start_light_active(attacker, S)
	_tick()
	assert_eq(dummy.health, 1, "no baja de 1")
	assert_true(dummy.is_alive())
	var hits: Array[NetMessages.EntityEvent] = _events_of(NetMessages.EntityEvent.Kind.HIT)
	if assert_eq(hits.size(), 1):
		assert_eq(hits[0].amount, 90, "el golpe anuncia el daño entero")
		assert_eq(hits[0].hit_flags & HIT_LETHAL, 0, "y no es mortal")
	assert_eq(_events_of(NetMessages.EntityEvent.Kind.DEATH).size(), 0, "sin DEATH")
	assert_eq(_events_of(NetMessages.EntityEvent.Kind.KILL).size(), 0, "ni KILL")
	# Más golpes, con distintos ataques: sigue en pie.
	for index: int in 5:
		CombatFixture.start_light_active(attacker, S + 20 * (index + 1), 2)
		_director.process_tick(S + 20 * (index + 1), _world.get_world_3d().direct_space_state)
	assert_true(dummy.is_alive())
	var last_hit: int = S + 100
	_director.process_tick(last_hit + 299, _world.get_world_3d().direct_space_state)
	assert_true(dummy.health < dummy.max_health, "a los 299 ticks aún no se ha curado")
	_director.process_tick(last_hit + 300, _world.get_world_3d().direct_space_state)
	assert_eq(dummy.health, dummy.max_health, "a los 5 s sin daño se cura del todo")
	var kill_command_target: Combatant = dummy
	_director.kill(kill_command_target, S + 500)
	assert_true(dummy.is_alive(), "ni el comando de matar puede con un maniquí")


func test_publish_keeps_the_action_byte_of_the_record() -> void:
	var duel: Array[Combatant] = _duel()
	CombatFixture.start_block(duel[1], S - 30)
	_tick()
	assert_eq(duel[1].entity.action & 15, CombatState.Action.BLOCK, "el registro lleva la acción")
	assert_eq(duel[0].entity.action, ActionMachine.action_byte(_combat_of(duel[0]), S))
