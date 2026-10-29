extends TestCase
## Pruebas de [Combatant] (docs/combate.md, sección 5): vida, estado «en combate», protección,
## cadena de controles con su inmunidad, regeneración, maniquí inmortal, muerte y reaparición, la
## muestra congelada y lo que se publica en la entidad para los snapshots.

const VARDHEIM: int = NetProtocol.Realm.VARDHEIM

var _viewport: SubViewport
var _world: Node3D
var _timing: CombatTiming


func before_each() -> void:
	_viewport = CombatFixture.make_world(tree.root)
	_world = NetHarness.get_world(_viewport)
	_timing = CombatTiming.from_rules(CombatCatalog.rules())
	await wait_physics_frames(2)


func after_each() -> void:
	if is_instance_valid(_viewport):
		_viewport.get_parent().remove_child(_viewport)
		_viewport.free()
	_viewport = null
	_world = null
	await wait_process_frames()


func _fighter(position: Vector3 = Vector3.ZERO) -> Combatant:
	return CombatFixture.make_fighter(_world, 1, VARDHEIM, position, 0.0, _timing)


func test_timing_comes_from_the_rules_in_ticks() -> void:
	var rules: CombatRules = CombatCatalog.rules()
	assert_eq(_timing.in_combat, roundi(rules.in_combat_s * 60.0))
	assert_eq(_timing.in_combat, 600, "10 s")
	assert_eq(_timing.respawn, 600, "10 s")
	assert_eq(_timing.auto_respawn, 1800, "30 s")
	assert_eq(_timing.protection, 180, "3 s")
	assert_eq(_timing.cc_window, 180, "3 s")
	assert_eq(_timing.cc_immunity, 120, "2 s")
	assert_eq(_timing.parry_stagger, 36, "0,6 s")
	assert_eq(_timing.guard_break_stun, 60, "1 s")
	assert_eq(_timing.dummy_heal, 300, "5 s")


func test_starts_alive_with_full_health() -> void:
	var fighter: Combatant = _fighter()
	assert_eq(fighter.health, CombatCatalog.rules().health_max)
	assert_eq(fighter.max_health, fighter.health)
	assert_true(fighter.is_alive())
	assert_false(fighter.is_dead())
	assert_false(fighter.is_in_combat(0))
	assert_false(fighter.is_protected(0))
	assert_eq(fighter.status_bits(0), 0)
	assert_eq(fighter.get_id(), 1)
	assert_eq(fighter.get_realm(), VARDHEIM)


func test_take_damage_clamps_to_the_remaining_health() -> void:
	var fighter: Combatant = _fighter()
	assert_eq(fighter.take_damage(300, 10), 300)
	assert_eq(fighter.health, 700)
	assert_eq(fighter.last_damage_tick, 10)
	assert_eq(fighter.take_damage(5000, 11), 700, "solo se quita lo que queda")
	assert_eq(fighter.health, 0)
	assert_true(fighter.is_dead())
	assert_eq(fighter.take_damage(10, 12), 0, "un muerto no recibe más daño")
	assert_eq(fighter.take_damage(-4, 12), 0)
	assert_eq(fighter.take_damage(0, 12), 0)


func test_immortal_dummy_never_goes_below_one() -> void:
	var fighter: Combatant = _fighter()
	fighter.immortal = true
	assert_eq(fighter.take_damage(999, 5), 999)
	assert_eq(fighter.health, 1)
	assert_eq(fighter.take_damage(500, 6), 0, "ya está en el mínimo")
	assert_eq(fighter.health, 1)
	assert_true(fighter.is_alive())


func test_status_bits() -> void:
	var fighter: Combatant = _fighter()
	fighter.mark_combat(100)
	assert_true(fighter.is_in_combat(100))
	assert_true(fighter.is_in_combat(699), "600 ticks de combate")
	assert_false(fighter.is_in_combat(700))
	assert_eq(fighter.status_bits(100), NetMessages.STATUS_IN_COMBAT)
	fighter.protected_until = 200
	assert_eq(fighter.status_bits(150), NetMessages.STATUS_IN_COMBAT | NetMessages.STATUS_PROTECTED)
	assert_eq(fighter.status_bits(200), NetMessages.STATUS_IN_COMBAT, "protección hasta 200 exclusive")
	fighter.mark_dead(300, 7, 2)
	assert_eq(fighter.status_bits(300), NetMessages.STATUS_DEAD, "muerto: solo el bit de muerte")
	# mark_combat no acorta un combate más largo.
	var other: Combatant = _fighter()
	other.mark_combat(100)
	other.mark_combat(50)
	assert_eq(other.in_combat_until, 700)


func test_control_chain_third_control_does_not_enter() -> void:
	var fighter: Combatant = _fighter()
	assert_true(fighter.try_control(100), "el primero entra")
	assert_true(fighter.try_control(150), "el segundo, dentro de la ventana, entra")
	assert_false(fighter.try_control(200), "el tercero no entra")
	assert_eq(fighter.cc_immune_until, 200 + 120, "y abre 2 s de inmunidad")
	assert_false(fighter.try_control(300), "durante la inmunidad nada entra")
	assert_false(fighter.try_control(319))
	# Pasada la inmunidad, la cadena empieza de nuevo.
	assert_true(fighter.try_control(320), "tras la inmunidad vuelve a entrar")
	assert_true(fighter.try_control(330))
	assert_false(fighter.try_control(340), "otra vez el tercero")


func test_control_chain_window_expires() -> void:
	var fighter: Combatant = _fighter()
	assert_true(fighter.try_control(100))
	assert_true(fighter.try_control(120))
	# 100 y 120 salen de la ventana de 180 ticks en 280 y 300: en 290 solo cuenta el segundo.
	assert_true(fighter.try_control(290), "el primero ya caducó: entra")
	assert_false(fighter.try_control(295), "el de 120 y el de 290 siguen dentro: el tercero no")
	assert_eq(fighter.cc_immune_until, 295 + 120)


func test_health_regenerates_only_out_of_combat() -> void:
	var fighter: Combatant = _fighter()
	var per_second: int = CombatCatalog.rules().health_regen_per_s
	fighter.take_damage(500, 0)
	fighter.mark_combat(0)
	for tick: int in range(1, 599):
		fighter.regenerate(tick, per_second)
	assert_eq(fighter.health, 500, "en combate no regenera")
	# Fuera de combate: 20 por segundo, es decir, 20 puntos cada 60 ticks.
	for tick: int in range(600, 600 + 60):
		fighter.regenerate(tick, per_second)
	assert_eq(fighter.health, 520, "un segundo, 20 puntos")
	for tick: int in range(660, 660 + 120):
		fighter.regenerate(tick, per_second)
	assert_eq(fighter.health, 560)
	# No pasa de la vida máxima ni resucita a un muerto.
	for tick: int in range(1000, 1000 + 60 * 60):
		fighter.regenerate(tick, per_second)
	assert_eq(fighter.health, fighter.max_health)
	fighter.mark_dead(5000, 0, 0)
	fighter.regenerate(6000, per_second)
	assert_eq(fighter.health, 0, "un muerto no regenera")


func test_dummy_heals_fully_after_five_seconds_without_damage() -> void:
	var fighter: Combatant = _fighter()
	fighter.immortal = true
	fighter.take_damage(900, 100)
	fighter.mark_combat(100)
	fighter.regenerate(399, 20)
	assert_true(fighter.health < fighter.max_health, "a los 299 ticks aún no")
	fighter.regenerate(400, 20)
	assert_eq(fighter.health, fighter.max_health, "a los 300 ticks se cura del todo")


func test_death_and_respawn_bookkeeping() -> void:
	var fighter: Combatant = _fighter()
	fighter.take_damage(400, 5)
	fighter.note_enemy_hit(9, 3, 5)
	fighter.ledger.record(5, 9, 400)
	fighter.cc_chain.append(4)
	fighter.mark_dead(100, 9, 3)
	assert_true(fighter.is_dead())
	assert_eq(fighter.death_tick, 100)
	assert_eq(fighter.respawn_tick, 100 + _timing.respawn)
	assert_eq(fighter.killer_id, 9)
	assert_eq(fighter.death_attack_id, 3)
	fighter.mark_respawned(800)
	assert_true(fighter.is_alive())
	assert_eq(fighter.health, fighter.max_health, "vida llena")
	assert_eq(fighter.death_tick, -1)
	assert_eq(fighter.respawn_tick, 0)
	assert_eq(fighter.protected_until, 800 + _timing.protection, "3 s de protección")
	assert_true(fighter.is_protected(800 + 179))
	assert_false(fighter.is_protected(800 + 180))
	assert_eq(fighter.ledger.total_damage(800), 0, "el registro de daño se vacía")
	assert_eq(fighter.last_enemy_id, 0)
	assert_eq(fighter.cc_chain.size(), 0)


func test_recent_enemy_credit_window() -> void:
	var fighter: Combatant = _fighter()
	assert_false(fighter.has_recent_enemy(10))
	fighter.note_enemy_hit(4, 2, 100)
	assert_true(fighter.has_recent_enemy(100))
	assert_true(fighter.has_recent_enemy(699), "10 s")
	assert_false(fighter.has_recent_enemy(700))


func test_swing_tracking_one_hit_per_action() -> void:
	var fighter: Combatant = _fighter()
	fighter.track_swing(50)
	assert_false(fighter.has_hit(2))
	fighter.mark_hit(2)
	assert_true(fighter.has_hit(2))
	fighter.track_swing(50)
	assert_true(fighter.has_hit(2), "el mismo ataque recuerda a quién golpeó")
	fighter.track_swing(80)
	assert_false(fighter.has_hit(2), "un ataque nuevo olvida")


func test_freeze_captures_the_state_after_simulating() -> void:
	var fighter: Combatant = _fighter(Vector3(3.0, 0.0, -4.0))
	var state: CombatState = fighter.get_character().combat
	CombatFixture.start_light_active(fighter, 100)
	fighter.entity.teleport_counter = 2
	fighter.freeze(100)
	var frozen: Combatant.Frozen = fighter.frozen
	assert_eq(frozen.tick, 100)
	assert_vec_near(frozen.position, Vector3(3.0, 0.0, -4.0), 1e-4)
	assert_near(frozen.yaw, 0.0, 1e-6)
	assert_eq(frozen.action, CombatState.Action.LIGHT)
	assert_eq(frozen.action_id, state.action_id)
	assert_eq(frozen.action_tick, state.action_tick)
	assert_true(frozen.attack_active, "en el primer tick del golpe activo")
	assert_false(frozen.hyper_armor, "un ligero no tiene entereza")
	assert_eq((frozen.flags >> EntityRecord.TELEPORT_SHIFT) & EntityRecord.TELEPORT_MASK, 2,
			"las banderas llevan el contador de teletransporte")
	# Un fuerte en su golpe activo tiene entereza.
	CombatFixture.start_heavy_active(fighter, 200, 20)
	fighter.freeze(200)
	assert_true(frozen.attack_active)
	assert_true(frozen.hyper_armor, "el fuerte tiene entereza en el golpe activo")
	assert_eq(frozen.charge_ticks, 20)
	# En la anticipación aún no.
	fighter.freeze(200 - 5)
	assert_false(frozen.attack_active, "en la anticipación todavía no golpea")
	assert_false(frozen.hyper_armor)
	# Bloqueando lleva la bandera.
	fighter.get_character().combat.action = CombatState.Action.BLOCK
	fighter.get_character().combat.action_tick = 150
	fighter.freeze(200)
	assert_eq(frozen.defense & ActionMachine.DEFENSE_BLOCKING, ActionMachine.DEFENSE_BLOCKING)
	assert_eq(frozen.flags & ActionMachine.DEFENSE_BLOCKING, ActionMachine.DEFENSE_BLOCKING)


func test_publish_updates_the_entity_view() -> void:
	var fighter: Combatant = _fighter()
	fighter.take_damage(250, 3)
	fighter.mark_combat(3)
	fighter.protected_until = 100
	fighter.publish(50)
	var entity: NetEntity = fighter.entity
	assert_eq(entity.health, 750)
	assert_eq(entity.max_health, 1000)
	assert_eq(entity.status, NetMessages.STATUS_IN_COMBAT | NetMessages.STATUS_PROTECTED)
	assert_eq(entity.respawn_tick, 0, "vivo: 0")
	assert_eq(entity.health_q, EntityRecord.quantize_health(750, 1000))
	assert_eq(entity.action, ActionMachine.action_byte(fighter.get_character().combat, 50))
	fighter.mark_dead(60, 0, 0)
	fighter.publish(60)
	assert_eq(entity.health, 0)
	assert_eq(entity.health_q, EntityRecord.HEALTH_Q_DEAD)
	assert_eq(entity.status, NetMessages.STATUS_DEAD)
	assert_eq(entity.respawn_tick, fighter.respawn_tick, "muerto: el tick de reaparición")
