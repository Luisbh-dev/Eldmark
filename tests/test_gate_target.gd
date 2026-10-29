extends TestCase
## La puerta del fuerte como blanco de los golpes (docs/fuerte.md, sección 3.3; GUE-10): el
## [CombatResolver] la prueba como una caja sin rebobinado ni defensa, el [CombatDirector] aplica el daño
## con el multiplicador de su tipo y emite un HIT con el net_id de la fortaleza, y el [FortressController]
## le quita la vida y avisa. Luchadores montados a mano, sin servidor ni red.

const VARDHEIM: int = NetProtocol.Realm.VARDHEIM
const SOLMARCH: int = NetProtocol.Realm.SOLMARCH
const ASKARRA: int = NetProtocol.Realm.ASKARRA
const HUECOS: int = RealmCatalog.NEUTRAL_CODE
const ZONE_ID: StringName = &"test_world"
const S: int = 400
## Hacia +X, hacia la cara oeste de la puerta, a 2,25 m de ella.
const YAW_EAST: float = -PI * 0.5
const ATTACK_SPOT: Vector3 = Vector3(77.5, 0.0, 0.0)

var _viewport: SubViewport
var _world: Node3D
var _history: StateHistory
var _director: CombatDirector
var _controller: FortressController
var _registry: NetEntityRegistry
var _events: Array[NetMessages.EntityEvent] = []
var _involved: Array[PackedInt32Array] = []
var _war: Array[NetMessages.EntityEvent] = []


func before_each() -> void:
	_viewport = CombatFixture.make_world(tree.root)
	_world = NetHarness.get_world(_viewport)
	FortressFixture.add_fortress(_world, FortressFixture.make_definition())
	_history = StateHistory.new()
	_director = CombatDirector.new(_history, ZONE_ID, _world, SafeAreas.new(),
			CombatFixture.place, func(_realm: int) -> Transform3D: return Transform3D.IDENTITY)
	_registry = NetEntityRegistry.new()
	_controller = FortressController.new()
	_controller.setup(_world, _registry, 0)
	_director.set_structure_targets(_controller.get_structure_targets())
	_director.structure_hit.connect(_controller.on_structure_hit)
	_director.event_emitted.connect(_controller.on_combat_event)
	_events.clear()
	_involved.clear()
	_war.clear()
	_director.event_emitted.connect(func(event: NetMessages.EntityEvent,
			involved: PackedInt32Array) -> void:
		_events.append(event)
		_involved.append(involved))
	_controller.war_event_emitted.connect(func(event: NetMessages.EntityEvent) -> void:
		_war.append(event))
	await wait_physics_frames(3)


func after_each() -> void:
	_director = null
	_controller = null
	if is_instance_valid(_viewport):
		_viewport.get_parent().remove_child(_viewport)
		_viewport.free()
	_viewport = null
	_world = null
	await wait_process_frames()


# --- Ayudantes --------------------------------------------------------------------------------

func _body(net_id: int, realm: int, position: Vector3, yaw: float) -> Combatant:
	var entity: NetEntity = CombatFixture.make_entity(_world, net_id, realm, position, yaw)
	_history.add_entity(net_id)
	return _director.add(entity, CombatFixture.make_queue(yaw), null)


func _tick(s: int = S) -> void:
	_director.process_tick(s, _world.get_world_3d().direct_space_state)


## Lo que quita a la puerta un golpe cortante de [param base] de daño (el multiplicador de las reglas).
func _slash(base: int) -> int:
	return roundi(float(base) * CombatCatalog.rules().structure_multiplier(DamageFormula.DamageType.SLASH))


func _state() -> FortressState:
	return _controller.get_fortress_state(FortressFixture.FORTRESS_ID)


func _gate_id() -> int:
	return _controller.get_net_id(FortressFixture.FORTRESS_ID)


## Los HIT a la puerta (no los que se dan entre sí los luchadores).
func _hits() -> Array[NetMessages.EntityEvent]:
	var found: Array[NetMessages.EntityEvent] = []
	for event: NetMessages.EntityEvent in _events:
		if event.event == NetMessages.EntityEvent.Kind.HIT and event.net_id == _gate_id():
			found.append(event)
	return found


func _attacker(realm: int = VARDHEIM, position: Vector3 = ATTACK_SPOT) -> Combatant:
	var fighter: Combatant = _body(11, realm, position, YAW_EAST)
	CombatFixture.start_light_active(fighter, S)
	return fighter


func _set_owner(realm: int) -> void:
	_controller.set_owner(FortressFixture.FORTRESS_ID, realm, S - 1)
	_war.clear()


# --- Daño --------------------------------------------------------------------------------------

func test_a_light_hit_takes_off_the_slashing_share_of_its_damage() -> void:
	var attacker: Combatant = _attacker()
	_tick()
	# 90 de daño cortante x 0,35 = 31,5 (31,499... en coma flotante, que redondea a 31).
	assert_eq(_slash(90), 31)
	assert_eq(_state().gate_health, 900 - _slash(90), "el ligero quita 31 a la puerta")
	var hits: Array[NetMessages.EntityEvent] = _hits()
	if not assert_eq(hits.size(), 1, "un HIT"):
		return
	assert_eq(hits[0].net_id, _gate_id(), "atado a la fortaleza")
	assert_eq(hits[0].attacker, 11)
	assert_eq(hits[0].amount, _slash(90))
	assert_eq(hits[0].damage_type, DamageFormula.DamageType.SLASH)
	assert_eq(hits[0].hit_flags, 0, "sin crítico ni bloqueo")
	assert_eq(hits[0].tick, S)
	assert_eq(_involved[0], PackedInt32Array([11]), "solo el atacante lo recibe por ser el implicado")
	assert_true(attacker.is_in_combat(S), "golpear la puerta pone al atacante en combate")
	assert_eq(attacker.health, 1000)
	assert_eq(_director.stats[&"gate_hits"], 1)
	assert_eq(_director.stats[&"gate_damage"], _slash(90))
	assert_eq(_war.size(), 1, "y el fuerte avisa de que lo atacan")
	assert_eq(_war[0].war_event, WarEvents.UNDER_ATTACK)
	assert_eq(_war[0].war_realm, VARDHEIM)
	assert_true(_state().under_attack_until_tick > S, "cuenta como atacado")
	assert_eq(_state().gate_last_damage_tick, S)


func test_there_are_no_criticals_against_the_gate_whichever_side_the_attacker_stands() -> void:
	# Un atacante al otro lado, de espaldas respecto a donde «mira» la puerta (que no mira a ningún sitio).
	var attacker: Combatant = _body(11, VARDHEIM, Vector3(82.0, 0.0, 0.0), PI * 0.5)
	CombatFixture.start_light_active(attacker, S)
	_tick()
	assert_eq(_hits().size(), 1)
	assert_eq(_hits()[0].hit_flags, 0)
	assert_eq(_hits()[0].amount, _slash(90))


func test_a_charged_heavy_attack_scales_before_the_multiplier() -> void:
	var attacker: Combatant = _body(11, VARDHEIM, ATTACK_SPOT, YAW_EAST)
	var heavy: AttackTicks = CombatCatalog.attack(CombatCatalog.weapon(
			attacker.get_character().combat.weapon_id).heavy_id)
	CombatFixture.start_heavy_active(attacker, S, heavy.charge_max_ticks)
	_tick()
	assert_eq(_state().gate_health, 900 - roundi(roundi(180.0 * 1.7) * 0.35),
			"carga máxima: 180 x 1,7 = 306, x 0,35 = 107")


func test_each_damage_type_has_its_multiplier_and_none_goes_below_one() -> void:
	var rules: CombatRules = CombatCatalog.rules()
	assert_eq(rules.structure_multiplier(DamageFormula.DamageType.SLASH), 0.35)
	assert_eq(rules.structure_multiplier(DamageFormula.DamageType.PIERCE), 0.2)
	assert_eq(rules.structure_multiplier(DamageFormula.DamageType.BLUNT), 1.0)
	assert_eq(rules.structure_multiplier(DamageFormula.DamageType.ELEMENTAL), 0.6)
	assert_eq(rules.structure_multiplier(99), 1.0, "un tipo desconocido no cambia el daño")
	var expected: Dictionary = {DamageFormula.DamageType.SLASH: 35, DamageFormula.DamageType.PIERCE: 20,
			DamageFormula.DamageType.BLUNT: 100, DamageFormula.DamageType.ELEMENTAL: 60}
	var attacker: Combatant = _body(11, VARDHEIM, ATTACK_SPOT, YAW_EAST)
	var last_health: int = _state().gate_health
	for damage_type: int in expected:
		var attack := AttackTicks.new()
		attack.id = 900 + damage_type
		attack.name = &"prueba"
		attack.base_damage = 100
		attack.damage_type = damage_type
		attack.shape = CombatCatalog.attack(_light_id()).shape
		_apply_structure_hit(attacker, attack)
		assert_eq(last_health - _state().gate_health, expected[damage_type], "tipo %d" % damage_type)
		last_health = _state().gate_health
	# Un golpe de 1 de daño perforante (0,2) sigue quitando 1.
	var weak := AttackTicks.new()
	weak.id = 950
	weak.name = &"debil"
	weak.base_damage = 1
	weak.damage_type = DamageFormula.DamageType.PIERCE
	weak.shape = CombatCatalog.attack(_light_id()).shape
	_apply_structure_hit(attacker, weak)
	assert_eq(last_health - _state().gate_health, 1, "mínimo 1 si queda algo")


func _light_id() -> int:
	return CombatCatalog.weapon(CombatCatalog.weapon_id(CombatCatalog.DEFAULT_WEAPON)).light_ids[0]


# Aplica a mano un golpe de [param attack] a la puerta (como lo haría el resolutor).
func _apply_structure_hit(attacker: Combatant, attack: AttackTicks) -> void:
	var hit := CombatResolver.Hit.new()
	hit.attacker = attacker
	hit.attack = attack
	hit.structure = _controller.get_structure_targets()[0]
	hit.outcome = CombatResolver.Outcome.STRUCTURE
	attacker.frozen.charge_ticks = 0
	_director._apply_hit(hit, S)


func test_the_last_hit_is_capped_by_the_remaining_health_and_flagged_lethal() -> void:
	_state().gate_health = 20
	var attacker: Combatant = _attacker()
	_tick()
	assert_eq(_state().gate_health, 0)
	var hits: Array[NetMessages.EntityEvent] = _hits()
	assert_eq(hits[0].amount, 20, "no hace más daño que la vida que queda")
	assert_true(hits[0].has_hit_flag(NetMessages.EntityEvent.HIT_FLAG_LETHAL), "y lo rompe")
	assert_eq(_war.size(), 2, "atacada y rota")
	assert_eq(_war[1].war_event, WarEvents.GATE_BROKEN)
	assert_eq(_war[1].war_realm, VARDHEIM, "con el reino de quien la rompió")
	# Una puerta rota ya no se golpea: ni se emite otro HIT.
	attacker.forget_swing()
	CombatFixture.start_light_active(attacker, S + 20)
	_director.process_tick(S + 20, _world.get_world_3d().direct_space_state)
	assert_eq(_hits().size(), 1)


func test_two_simultaneous_hits_cannot_break_the_gate_twice() -> void:
	_state().gate_health = 40
	var first: Combatant = _body(11, VARDHEIM, ATTACK_SPOT + Vector3(0.0, 0.0, -0.5), YAW_EAST)
	var second: Combatant = _body(12, SOLMARCH, ATTACK_SPOT + Vector3(0.0, 0.0, 1.5), YAW_EAST)
	CombatFixture.start_light_active(first, S)
	CombatFixture.start_light_active(second, S)
	_tick()
	assert_eq(_state().gate_health, 0)
	var total: int = 0
	for event: NetMessages.EntityEvent in _hits():
		total += event.amount
	assert_eq(total, 40, "entre los dos, la vida que había")
	var broken: int = 0
	for event: NetMessages.EntityEvent in _war:
		if event.war_event == WarEvents.GATE_BROKEN:
			broken += 1
	assert_eq(broken, 1, "un solo aviso de rotura")


func test_one_swing_hits_the_gate_once_however_many_ticks_it_stays_active() -> void:
	var attacker: Combatant = _attacker()
	_tick(S)
	_tick(S + 1)
	_tick(S + 2)
	assert_eq(_hits().size(), 1, "un impacto por acción")
	assert_eq(_state().gate_health, 900 - _slash(90))


# --- Quién puede golpearla ---------------------------------------------------------------------

func test_a_neutral_fortress_gate_is_hit_by_the_three_realms_but_not_by_the_hollows() -> void:
	var spot: float = -1.5
	for realm: int in [VARDHEIM, SOLMARCH, ASKARRA, HUECOS]:
		var fighter: Combatant = _body(20 + realm, realm, ATTACK_SPOT + Vector3(0.0, 0.0, spot), YAW_EAST)
		CombatFixture.start_light_active(fighter, S)
		spot += 1.0
	_tick()
	var by_attacker: Dictionary = {}
	for event: NetMessages.EntityEvent in _hits():
		by_attacker[event.attacker] = true
	assert_true(by_attacker.has(20 + VARDHEIM) and by_attacker.has(20 + SOLMARCH) and by_attacker.has(20 + ASKARRA),
			"Vardheim, Solmarch y Askarra la dañan")
	assert_false(by_attacker.has(20 + HUECOS), "los Huecos, que la guardan, no")
	assert_eq(_state().gate_health, 900 - 3 * _slash(90))


func test_only_the_enemies_of_the_owner_hit_the_gate() -> void:
	_set_owner(VARDHEIM)
	var own: Combatant = _body(11, VARDHEIM, ATTACK_SPOT + Vector3(0.0, 0.0, -0.5), YAW_EAST)
	CombatFixture.start_light_active(own, S)
	_tick()
	assert_eq(_state().gate_health, 900, "el dueño no daña su propia puerta")
	assert_true(_hits().is_empty())
	var enemy: Combatant = _body(12, SOLMARCH, ATTACK_SPOT + Vector3(0.0, 0.0, 1.5), YAW_EAST)
	CombatFixture.start_light_active(enemy, S + 100)
	_director.process_tick(S + 100, _world.get_world_3d().direct_space_state)
	assert_eq(_state().gate_health, 900 - _slash(90), "el enemigo sí")
	assert_eq(_hits()[0].attacker, 12)
	# Y con Solmarch de dueño, a quien deja de dañar es a Solmarch.
	_set_owner(SOLMARCH)
	enemy.forget_swing()
	CombatFixture.start_light_active(enemy, S + 200)
	own.forget_swing()
	CombatFixture.start_light_active(own, S + 200)
	_director.process_tick(S + 200, _world.get_world_3d().direct_space_state)
	# Cambiar de dueño repara la puerta (900), y de los dos solo la daña Vardheim.
	assert_eq(_state().gate_health, 900 - _slash(90), "ahora la daña Vardheim, no Solmarch")


# --- Geometría y línea de visión ---------------------------------------------------------------

func test_a_swing_out_of_reach_or_facing_away_does_not_touch_the_gate() -> void:
	var far: Combatant = _body(11, VARDHEIM, Vector3(75.0, 0.0, -3.0), YAW_EAST)
	CombatFixture.start_light_active(far, S)
	var away: Combatant = _body(12, SOLMARCH, ATTACK_SPOT + Vector3(0.0, 0.0, 1.0), -YAW_EAST)
	CombatFixture.start_light_active(away, S)
	_tick()
	assert_eq(_state().gate_health, 900, "a 4,75 m de la cara no llega y de espaldas tampoco")
	assert_true(_hits().is_empty())


func test_a_wall_between_the_attacker_and_the_gate_blocks_the_hit() -> void:
	var wall := StaticBody3D.new()
	wall.collision_layer = PlayerCharacter.WORLD_COLLISION_LAYER
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(0.2, 4.0, 6.0)
	shape.shape = box
	wall.add_child(shape)
	_world.add_child(wall)
	wall.position = Vector3(78.5, 2.0, 0.0)
	await wait_physics_frames(2)
	var attacker: Combatant = _attacker()
	_tick()
	assert_eq(_state().gate_health, 900, "el muro corta la línea de visión")
	wall.queue_free()
	await wait_physics_frames(2)
	attacker.forget_swing()
	CombatFixture.start_light_active(attacker, S + 100)
	_director.process_tick(S + 100, _world.get_world_3d().direct_space_state)
	assert_eq(_state().gate_health, 900 - _slash(90), "sin el muro, golpea; la propia puerta no cuenta para la línea de visión")


func test_attackers_from_the_other_side_of_the_gate_also_reach_it() -> void:
	var attacker: Combatant = _body(11, VARDHEIM, Vector3(82.5, 0.0, 0.0), PI * 0.5)
	CombatFixture.start_light_active(attacker, S)
	_tick()
	assert_eq(_state().gate_health, 900 - _slash(90), "desde dentro del fuerte, por la cara este")


# --- Sin rebobinado ----------------------------------------------------------------------------

func test_the_gate_is_hit_where_it_is_now_whatever_the_requested_rewind() -> void:
	var peer := ServerPeer.new(7)
	peer.rtt_ticks = 0
	peer.interp_delay_q = 32
	var entity: NetEntity = CombatFixture.make_entity(_world, 11, VARDHEIM, ATTACK_SPOT, YAW_EAST)
	_history.add_entity(11)
	var attacker: Combatant = _director.add(entity, CombatFixture.make_queue(YAW_EAST), peer)
	# El cliente pide 40 ticks de rebobinado: contra un jugador se rechazaría; la puerta no se mueve.
	attacker.queue.reset(S - 1, NetProtocol.neutral_input(S - 1, YAW_EAST))
	attacker.queue.push(NetProtocol.neutral_input(S, YAW_EAST), 40 * 16, S)
	attacker.queue.take(S)
	CombatFixture.start_light_active(attacker, S)
	_tick()
	assert_eq(_state().gate_health, 900 - _slash(90), "el golpe a la puerta no depende del rebobinado")
	assert_eq(peer.rewind_rejects, 1, "pero el golpe sospechoso se sigue anotando para los jugadores")
