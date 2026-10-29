extends TestCase
## Pruebas del [StatusSystem] dentro del [CombatDirector] (docs/habilidades.md, secciones 4.1 y 4.3; CMB-20,
## paquete H3a): un sangrado hace exactamente N pulsos en [code]anchor + 60k[/code], acumulación, renovación y
## el más fuerte, la curación en el tiempo, un pulso no interrumpe, un pulso que mata a mitad de la lista no
## cambia lo que se recorre, limpieza al morir, al reaparecer y al irse el autor, STATUS con su
## [code]until_tick[/code], las ranuras de movimiento con el mismo fin y los modificadores de daño y de
## mitigación.
## [br][br]
## Sin red ni servidor: luchadores montados a mano y el director avanzado tick a tick con
## [method CombatDirector.process_tick], como test_combat_director.

const VARDHEIM: int = NetProtocol.Realm.VARDHEIM
const SOLMARCH: int = NetProtocol.Realm.SOLMARCH
const ZONE_ID: StringName = &"test_world"
const S: int = 400
const HIT: int = NetMessages.EntityEvent.Kind.HIT
const STATUS: int = NetMessages.EntityEvent.Kind.STATUS
const HEAL: int = NetMessages.EntityEvent.Kind.HEAL
const DEATH: int = NetMessages.EntityEvent.Kind.DEATH
const KILL: int = NetMessages.EntityEvent.Kind.KILL
const APPLIED: int = NetMessages.EntityEvent.StatusOp.APPLIED
const REMOVED: int = NetMessages.EntityEvent.StatusOp.REMOVED

var _viewport: SubViewport
var _world: Node3D
var _history: StateHistory
var _director: CombatDirector
var _events: Array[NetMessages.EntityEvent] = []
var _involved: Array[PackedInt32Array] = []
# Efectos de prueba añadidos a las tablas del catálogo (se quitan en after_each).
var _injected: int = 0


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
	var statuses: Array[StatusTicks] = CombatCatalog.tables().statuses
	while _injected > 0:
		statuses.pop_back()
		_injected -= 1
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


## Un luchador «en combate» desde S (hasta S + 600): sin la regeneración natural de vida, que
## enturbiaría las cuentas de los pulsos.
func _body(net_id: int, realm: int, position: Vector3, yaw: float = 0.0) -> Combatant:
	var entity: NetEntity = CombatFixture.make_entity(_world, net_id, realm, position, yaw)
	_history.add_entity(net_id)
	var combatant: Combatant = _director.add(entity, CombatFixture.make_queue(yaw), null)
	combatant.mark_combat(S)
	return combatant


func _status_id(status_name: StringName) -> int:
	var id: int = CombatCatalog.status_id(status_name)
	assert_true(id > 0, "el efecto %s existe" % status_name)
	return id


## Avanza el director de [param from_tick] a [param to_tick], los dos incluidos.
func _run(from_tick: int, to_tick: int) -> void:
	var space: PhysicsDirectSpaceState3D = _world.get_world_3d().direct_space_state
	for tick: int in range(from_tick, to_tick + 1):
		_director.process_tick(tick, space)


func _events_of(kind: int, net_id: int = -1) -> Array[NetMessages.EntityEvent]:
	var found: Array[NetMessages.EntityEvent] = []
	for event: NetMessages.EntityEvent in _events:
		if event.event == kind and (net_id < 0 or event.net_id == net_id):
			found.append(event)
	return found


func _ticks_of(events: Array[NetMessages.EntityEvent]) -> Array[int]:
	var ticks: Array[int] = []
	for event: NetMessages.EntityEvent in events:
		ticks.append(event.tick)
	return ticks


func _combat_of(combatant: Combatant) -> CombatState:
	return combatant.get_character().combat


## Añade a las tablas del catálogo un efecto de prueba de [param kind] con [param magnitude] y devuelve su
## id (after_each lo quita).
func _inject_status(kind: int, magnitude: float) -> int:
	var statuses: Array[StatusTicks] = CombatCatalog.tables().statuses
	var custom := StatusTicks.new()
	custom.id = statuses.size() + 1
	custom.name = &"prueba_%d" % custom.id
	custom.kind = kind
	custom.duration_ticks = 600
	custom.stacking = StatusEffectDefinition.Stacking.REFRESH
	custom.max_stacks = 1
	custom.pulse_ticks = 60
	custom.magnitude = magnitude
	statuses.append(custom)
	_injected += 1
	return custom.id


# --- Pulsos -----------------------------------------------------------------------------------

func test_a_bleed_does_exactly_six_pulses_at_the_anchor_plus_sixty_k() -> void:
	var author: Combatant = _body(1, VARDHEIM, Vector3.ZERO)
	var victim: Combatant = _body(2, SOLMARCH, Vector3(0.0, 0.0, -1.5), PI)
	var bleed: int = _status_id(&"bleed")
	var data: StatusTicks = CombatCatalog.status(bleed)
	assert_eq([data.duration_ticks, data.pulse_ticks, data.pulse_amount], [360, 60, 15], "sangrado de 6 s")
	assert_true(_director.status.apply(victim, bleed, author.get_id(), S), "se aplica")
	var applied: Array[NetMessages.EntityEvent] = _events_of(STATUS, 2)
	if assert_eq(applied.size(), 1, "STATUS 1 al aplicarlo"):
		assert_eq(applied[0].op, APPLIED)
		assert_eq(applied[0].status_id, bleed)
		assert_eq(applied[0].source_entity, 1, "con su autor")
		assert_eq(applied[0].stacks, 1)
		assert_eq(applied[0].until_tick, S + 360, "y su fin")
		assert_eq(applied[0].tick, S)
		assert_eq(_involved[0], PackedInt32Array([2, 1]), "el afectado y el autor")
	_run(S, S + 500)
	var pulses: Array[NetMessages.EntityEvent] = _events_of(HIT, 2)
	assert_eq(_ticks_of(pulses), [S + 60, S + 120, S + 180, S + 240, S + 300, S + 360],
			"exactamente 6 pulsos, en anchor + 60k")
	var source: int = CombatSource.make(CombatSource.Kind.STATUS, bleed)
	for pulse: NetMessages.EntityEvent in pulses:
		assert_eq(pulse.amount, 15, "15 por pulso")
		assert_eq(pulse.attacker, 1, "el autor del efecto es el atacante")
		assert_eq(pulse.get_source(), source, "con la fuente del efecto")
		assert_eq(pulse.damage_type, DamageFormula.DamageType.SLASH, "cortante")
		assert_eq(pulse.hit_flags, 0, "sin crítico, bloqueo ni interrupción")
	assert_eq(victim.health, 1000 - 90, "90 de vida en total")
	assert_eq(victim.ledger.damage_by(1, S + 400), 90, "el registro de daño se lo apunta al autor")
	assert_true(author.is_in_combat(S + 360) and victim.is_in_combat(S + 360), "los pulsos son combate")
	# El último pulso y la caducidad caen en el mismo tick: primero el pulso.
	var statuses: Array[NetMessages.EntityEvent] = _events_of(STATUS, 2)
	if assert_eq(statuses.size(), 2, "aplicado y quitado"):
		assert_eq(statuses[1].op, REMOVED)
		assert_eq(statuses[1].tick, S + 360, "se quita al caducar")
		assert_eq(statuses[1].stacks, 0)
		assert_true(_events.find(pulses[5]) < _events.find(statuses[1]), "el último pulso antes que la caducidad")
	assert_true(victim.effects.is_empty(), "ya no lo lleva")
	assert_eq(_director.stats[&"pulse_hits"], 6)


func test_a_pulse_goes_to_the_combat_log_with_the_name_of_its_effect() -> void:
	var author: Combatant = _body(1, VARDHEIM, Vector3.ZERO)
	var victim: Combatant = _body(2, SOLMARCH, Vector3(0.0, 0.0, -1.5), PI)
	var path: String = NetHarness.build_path("test_status_effects_log.csv")
	_director.combat_log = FileAccess.open(path, FileAccess.WRITE)
	_director.status.apply(victim, _status_id(&"bleed"), author.get_id(), S)
	_run(S + 1, S + 60)
	_director.combat_log.close()
	_director.combat_log = null
	var lines: PackedStringArray = FileAccess.get_file_as_string(path).strip_edges().split("\n")
	if assert_eq(lines.size(), 1, "una línea, la del pulso"):
		assert_eq(lines[0], "%d,1,2,bleed,%d.00,0.00,pulse,15" % [S + 60, S + 60],
				"tick, autor, afectado, nombre del efecto, resultado pulse y daño")


func test_stacking_refreshing_and_the_strongest() -> void:
	var author: Combatant = _body(1, VARDHEIM, Vector3.ZERO)
	var victim: Combatant = _body(2, SOLMARCH, Vector3(0.0, 0.0, -1.5), PI)
	var status: StatusSystem = _director.status
	# STACK (sangrado, hasta 3): cada aplicación suma una y alarga el fin; el ancla no cambia.
	var bleed: int = _status_id(&"bleed")
	for tick: int in [S, S + 30, S + 45, S + 50]:
		status.apply(victim, bleed, author.get_id(), tick)
	var effect: StatusSystem.ActiveEffect = status.find(victim, bleed)
	assert_eq([effect.stacks, effect.anchor_tick, effect.until_tick], [3, S, S + 50 + 360],
			"tres acumulaciones como mucho, ancla del primero, fin del último")
	var stacked: Array[NetMessages.EntityEvent] = _events_of(STATUS, 2)
	assert_eq(stacked.map(func(event: NetMessages.EntityEvent) -> int: return event.stacks), [1, 2, 3, 3])
	_run(S + 51, S + 60)
	var pulses: Array[NetMessages.EntityEvent] = _events_of(HIT, 2)
	if assert_eq(pulses.size(), 1, "el primer pulso, en S + 60"):
		assert_eq(pulses[0].amount, 45, "15 por acumulación")
	# REFRESH (curación de la poción): renovar alarga el fin sin mover el ancla: más pulsos.
	var healed: Combatant = _body(3, VARDHEIM, Vector3(10.0, 0.0, 0.0))
	healed.health = 100
	var regen: int = _status_id(&"potion_regen")
	status.apply(healed, regen, healed.get_id(), S + 100)
	status.apply(healed, regen, healed.get_id(), S + 200)
	var renewed: StatusSystem.ActiveEffect = status.find(healed, regen)
	assert_eq([renewed.anchor_tick, renewed.until_tick, renewed.stacks], [S + 100, S + 200 + 180, 1])
	_run(S + 61, S + 400)
	var heals: Array[NetMessages.EntityEvent] = _events_of(HEAL, 3)
	assert_eq(heals.size(), 9, "pulsos cada 30 ticks desde el ancla hasta el fin renovado")
	assert_eq(heals[0].tick, S + 130)
	assert_eq(heals[8].tick, S + 370)
	for heal: NetMessages.EntityEvent in heals:
		assert_eq(heal.amount, 50)
		assert_eq(heal.healer, 0, "se cura a sí mismo: healer 0")
		assert_eq(heal.get_source(), CombatSource.make(CombatSource.Kind.STATUS, regen))
	assert_eq(healed.health, 100 + 9 * 50)
	# STRONGEST (ralentizar): un mismo efecto es igual de fuerte; se queda con el fin más tardío, y la
	# ranura de movimiento con él.
	var slowed: int = _status_id(&"slowed")
	status.apply(victim, slowed, author.get_id(), S + 500)
	status.apply(victim, slowed, author.get_id(), S + 560)
	var slow: StatusSystem.ActiveEffect = status.find(victim, slowed)
	assert_eq([slow.stacks, slow.anchor_tick, slow.until_tick], [1, S + 500, S + 560 + 180])
	var combat: CombatState = _combat_of(victim)
	assert_eq(combat.move_effect_ids[0], slowed, "la ralentización ocupa una ranura de movimiento")
	assert_eq(combat.move_effect_until[0], S + 740, "con el mismo fin que el efecto")


func test_a_healing_pulse_never_goes_over_the_maximum() -> void:
	var drinker: Combatant = _body(1, VARDHEIM, Vector3.ZERO)
	drinker.health = 980
	_director.status.apply(drinker, _status_id(&"potion_regen"), drinker.get_id(), S)
	_run(S, S + 200)
	assert_eq(drinker.health, 1000, "sin pasar del máximo")
	var heals: Array[NetMessages.EntityEvent] = _events_of(HEAL, 1)
	if assert_eq(heals.size(), 1, "solo el primer pulso cura algo"):
		assert_eq(heals[0].amount, 20, "lo que cura de verdad")


func test_a_pulse_does_not_interrupt_drinking() -> void:
	var author: Combatant = _body(1, VARDHEIM, Vector3.ZERO)
	var drinker: Combatant = _body(2, SOLMARCH, Vector3(0.0, 0.0, -1.5), PI)
	_director.status.apply(drinker, _status_id(&"bleed"), author.get_id(), S)
	var potion: AbilityTicks = CombatCatalog.ability(CombatCatalog.ability_id(&"potion_health"))
	var combat: CombatState = _combat_of(drinker)
	combat.action = CombatState.Action.ABILITY
	combat.action_id = potion.id
	combat.action_tick = S + 50
	assert_true(CombatDirector.is_interruptible(combat, S + 60), "en S + 60 está bebiendo (lanzamiento)")
	_run(S + 1, S + 60)
	var pulses: Array[NetMessages.EntityEvent] = _events_of(HIT, 2)
	if assert_eq(pulses.size(), 1):
		assert_false(pulses[0].has_hit_flag(NetMessages.EntityEvent.HIT_FLAG_INTERRUPTED), "sin bit 5")
	assert_eq(combat.action, CombatState.Action.ABILITY, "sigue bebiendo: un pulso no interrumpe")
	assert_eq(_director.stats[&"interrupts"], 0)


func test_a_lethal_pulse_in_the_middle_of_the_list_does_not_change_what_is_walked() -> void:
	var author: Combatant = _body(1, VARDHEIM, Vector3.ZERO)
	var first: Combatant = _body(2, SOLMARCH, Vector3(0.0, 0.0, -1.5), PI)
	var second: Combatant = _body(3, SOLMARCH, Vector3(3.0, 0.0, -1.5), PI)
	var bleed: int = _status_id(&"bleed")
	var regen: int = _status_id(&"potion_regen")
	assert_true(bleed < regen, "el sangrado va antes que la curación (por id)")
	# El primero lleva sangrado y curación anclados en S: los dos pulsan en S + 60 y el sangrado, que va
	# antes, lo mata.
	first.health = 500
	_director.status.apply(first, bleed, author.get_id(), S)
	_director.status.apply(first, regen, first.get_id(), S)
	_director.status.apply(second, bleed, author.get_id(), S)
	_run(S + 1, S + 59)
	assert_eq(_events_of(HEAL, 2).size(), 1, "la curación pulsa en S + 30")
	assert_eq(first.health, 550)
	first.health = 10
	_events.clear()
	_run(S + 60, S + 60)
	assert_true(first.is_dead(), "el sangrado lo mata")
	assert_eq(_events_of(HEAL, 2).size(), 0, "y su curación de ese mismo tick ya no se aplica")
	assert_true(first.effects.is_empty(), "muerto, sin efectos")
	var deaths: Array[NetMessages.EntityEvent] = _events_of(DEATH, 2)
	if assert_eq(deaths.size(), 1):
		assert_eq(deaths[0].killer, 1, "lo mata el autor del sangrado")
		assert_eq(deaths[0].get_source(), CombatSource.make(CombatSource.Kind.STATUS, bleed))
	assert_eq(_events_of(KILL, 2).size(), 1, "con su KILL")
	assert_eq(_events_of(STATUS, 2).size(), 0, "sin STATUS sueltos: DEATH los borra en el cliente")
	var second_pulses: Array[NetMessages.EntityEvent] = _events_of(HIT, 3)
	assert_eq(second_pulses.size(), 1, "el siguiente de la lista recibe su pulso")
	assert_eq(second.health, 1000 - 15)


# --- Limpieza ---------------------------------------------------------------------------------

func test_effects_are_cleared_on_death_and_on_respawn_without_status_events() -> void:
	var author: Combatant = _body(1, VARDHEIM, Vector3.ZERO)
	var victim: Combatant = _body(2, SOLMARCH, Vector3(0.0, 0.0, -1.5), PI)
	var slowed: int = _status_id(&"slowed")
	_director.status.apply(victim, _status_id(&"bleed"), author.get_id(), S)
	_director.status.apply(victim, slowed, author.get_id(), S)
	assert_eq(_combat_of(victim).move_effect_ids[0], slowed)
	_events.clear()
	_director.kill(victim, S + 10)
	assert_true(victim.effects.is_empty(), "al morir se quitan todos")
	assert_eq(_combat_of(victim).move_effect_ids, PackedInt32Array([0, 0]), "también las ranuras de movimiento")
	assert_eq(_events_of(STATUS).size(), 0, "sin STATUS sueltos")
	# Un efecto que no se aplica a un muerto.
	assert_false(_director.status.apply(victim, slowed, author.get_id(), S + 20), "a un muerto no")
	# Al reaparecer empieza limpio (y con las ranuras vacías).
	_director.request_respawn(2, 0, victim.respawn_tick)
	_run(victim.respawn_tick, victim.respawn_tick)
	assert_true(victim.is_alive(), "ha reaparecido")
	assert_true(victim.effects.is_empty())
	assert_eq(_events_of(STATUS).size(), 0)


func test_effects_of_an_author_that_leaves_are_removed_with_status_two() -> void:
	var author: Combatant = _body(1, VARDHEIM, Vector3.ZERO)
	var victim: Combatant = _body(2, SOLMARCH, Vector3(0.0, 0.0, -1.5), PI)
	var bleed: int = _status_id(&"bleed")
	var slowed: int = _status_id(&"slowed")
	var regen: int = _status_id(&"potion_regen")
	_director.status.apply(victim, bleed, author.get_id(), S)
	_director.status.apply(victim, slowed, author.get_id(), S)
	_director.status.apply(victim, regen, victim.get_id(), S)
	# El autor también lleva un efecto propio: se va con él, sin eventos.
	_director.status.apply(author, regen, author.get_id(), S)
	_events.clear()
	_director.remove(author.get_id(), S + 10)
	var removed: Array[NetMessages.EntityEvent] = _events_of(STATUS, 2)
	assert_eq(removed.size(), 2, "STATUS 2 de los dos efectos que puso")
	for event: NetMessages.EntityEvent in removed:
		assert_eq(event.op, REMOVED)
		assert_eq(event.tick, S + 10, "en el tick de la baja")
		assert_eq(event.source_entity, 1)
	assert_eq(removed.map(func(event: NetMessages.EntityEvent) -> int: return event.status_id), [bleed, slowed])
	assert_eq(victim.effects.size(), 1, "la curación propia sigue")
	assert_eq(victim.effects[0].status_id, regen)
	assert_eq(_combat_of(victim).move_effect_ids, PackedInt32Array([0, 0]), "y la ranura de la ralentización se vacía")
	assert_eq(_events_of(STATUS, 1).size(), 0, "del que se va no sale nada")
	# Ya no hay pulsos huérfanos.
	_run(S + 11, S + 120)
	assert_eq(_events_of(HIT, 2).size(), 0)


# --- Ranuras y límites ------------------------------------------------------------------------

func test_a_slow_and_a_root_write_their_movement_slots_and_the_ninth_effect_replaces_the_earliest() -> void:
	var author: Combatant = _body(1, VARDHEIM, Vector3.ZERO)
	var victim: Combatant = _body(2, SOLMARCH, Vector3(0.0, 0.0, -1.5), PI)
	var slowed: int = _status_id(&"slowed")
	var rooted: int = _status_id(&"rooted")
	_director.status.apply(victim, slowed, author.get_id(), S)
	_director.status.apply(victim, rooted, author.get_id(), S + 5, 30)
	var combat: CombatState = _combat_of(victim)
	assert_eq(combat.move_effect_ids, PackedInt32Array([slowed, rooted]))
	assert_eq(combat.move_effect_until, PackedInt64Array([S + 180, S + 35]),
			"cada ranura con el fin de su efecto (el enraizado con la duración pedida)")
	var events: Array[NetMessages.EntityEvent] = _events_of(STATUS, 2)
	assert_eq(events[1].until_tick, S + 35, "STATUS con el until_tick de la duración pedida")
	# Hasta 8 efectos: uno nuevo sustituye al que acaba antes (el enraizado), con STATUS 2.
	for index: int in 6:
		_inject_status(StatusEffectDefinition.Kind.DAMAGE_UP, 0.0)
	var first_custom: int = CombatCatalog.tables().statuses.size() - 5
	for index: int in 6:
		_director.status.apply(victim, first_custom + index, author.get_id(), S + 10)
	assert_eq(victim.effects.size(), StatusSystem.MAX_EFFECTS)
	_events.clear()
	var ninth: int = _inject_status(StatusEffectDefinition.Kind.DAMAGE_UP, 0.0)
	_director.status.apply(victim, ninth, author.get_id(), S + 20)
	assert_eq(victim.effects.size(), StatusSystem.MAX_EFFECTS, "sigue habiendo 8")
	assert_null(_director.status.find(victim, rooted), "el que acababa antes se ha ido")
	var removed: Array[NetMessages.EntityEvent] = _events_of(STATUS, 2)
	if assert_eq(removed.size(), 2, "STATUS 2 del sustituido y STATUS 1 del nuevo"):
		assert_eq([removed[0].op, removed[0].status_id], [REMOVED, rooted])
		assert_eq([removed[1].op, removed[1].status_id], [APPLIED, ninth])
	assert_eq(combat.move_effect_ids, PackedInt32Array([slowed, 0]), "la ranura del enraizado se vacía")


func test_damage_up_and_mitigation_down_change_the_damage() -> void:
	var attacker: Combatant = _body(1, VARDHEIM, Vector3.ZERO)
	var victim: Combatant = _body(2, SOLMARCH, Vector3(0.0, 0.0, -1.5), PI)
	var damage_up: int = _inject_status(StatusEffectDefinition.Kind.DAMAGE_UP, 0.5)
	var mitigation_down: int = _inject_status(StatusEffectDefinition.Kind.MITIGATION_DOWN, -0.25)
	_director.status.apply(attacker, damage_up, attacker.get_id(), S - 10)
	assert_near(_director.status.damage_scale(attacker), 1.5, 0.0001, "1 + Σ DAMAGE_UP")
	assert_near(_director.status.damage_scale(victim), 1.0, 0.0001, "sin efectos, 1")
	CombatFixture.start_light_active(attacker, S)
	_run(S, S)
	assert_eq(victim.health, 1000 - 135, "el ligero de 90 hace 135 con +50 %")
	# Bloqueando, con MITIGATION_DOWN de 0,25 el escudo solo absorbe el 75 %.
	victim.heal_full()
	_director.status.apply(victim, mitigation_down, attacker.get_id(), S + 90)
	assert_near(_director.status.mitigation_penalty(victim), 0.25, 0.0001, "Σ MITIGATION_DOWN, en valor absoluto")
	CombatFixture.start_block(victim, S + 50)
	CombatFixture.start_light_active(attacker, S + 100)
	attacker.forget_swing()
	_run(S + 100, S + 100)
	# Bruto 135; absorbe 135 × 0,75 = 101,25; pasan 33,75 → 34.
	assert_eq(victim.health, 1000 - 34, "pasa lo que el escudo ya no absorbe")
