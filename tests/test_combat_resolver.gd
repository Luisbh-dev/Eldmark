extends TestCase
## Pruebas del [CombatResolver] (docs/combate.md, sección 4.3) con escenarios montados a mano en un
## [SubViewport]: luchadores con su personaje, su cola de entradas y su [Combatant], un
## [StateHistory] grabado a mano y el servidor sin red.
## [br][br]
## Se cubren la forma y la línea de visión, la defensa con su precedencia (bloqueo frontal y por la
## espalda, ventana de parada, invulnerabilidad de la esquiva con la ventana entera entre
## [code]view_tick[/code] y [code]s[/code], la regla de «suelta el escudo y ataca»), un impacto por
## acción, el intercambio simultáneo, el rebobinado (acierto con el objetivo donde estaba y rechazo
## por encima del tope) y los candidatos (reinos, protección, zonas seguras, muertos).

const VARDHEIM: int = NetProtocol.Realm.VARDHEIM
const SOLMARCH: int = NetProtocol.Realm.SOLMARCH
const ASKARRA: int = NetProtocol.Realm.ASKARRA
const ZONE_ID: StringName = &"test_world"
## Tick en el que se resuelve (lejos de 0 para que haya historial).
const S: int = 200
const PI_YAW: float = PI

var _viewport: SubViewport
var _world: Node3D
var _history: StateHistory
var _timing: CombatTiming
var _resolver: CombatResolver
var _fighters: Array[Combatant] = []


func before_each() -> void:
	_viewport = CombatFixture.make_world(tree.root)
	_world = NetHarness.get_world(_viewport)
	_history = StateHistory.new()
	_timing = CombatTiming.from_rules(CombatCatalog.rules())
	_resolver = CombatResolver.new(_history, ZONE_ID)
	_fighters.clear()
	# Los cuerpos de colisión entran en el espacio de física en los primeros pasos.
	await wait_physics_frames(3)


func after_each() -> void:
	_fighters.clear()
	if is_instance_valid(_viewport):
		_viewport.get_parent().remove_child(_viewport)
		_viewport.free()
	_viewport = null
	_world = null
	await wait_process_frames()


# --- Ayudantes --------------------------------------------------------------------------------

func _fighter(net_id: int, realm: int, position: Vector3, yaw: float,
		peer: ServerPeer = null) -> Combatant:
	var fighter: Combatant = CombatFixture.make_fighter(_world, net_id, realm, position, yaw,
			_timing, peer)
	_history.add_entity(net_id)
	_fighters.append(fighter)
	return fighter


## Atacante de Vardheim en el origen mirando a -Z, y víctima de Solmarch a [param distance] metros
## delante de él, mirándolo de frente.
func _duel(distance: float = 1.5) -> Array[Combatant]:
	var attacker: Combatant = _fighter(1, VARDHEIM, Vector3.ZERO, 0.0)
	var victim: Combatant = _fighter(2, SOLMARCH, Vector3(0.0, 0.0, -distance), PI_YAW)
	return [attacker, victim]


## Resuelve el tick [param s]. Con [param fresh] (por defecto) se olvida a quién había golpeado ya
## cada atacante, para repetir un mismo ataque con distintas posiciones.
func _resolve(s: int = S, fresh: bool = true) -> Array[CombatResolver.Hit]:
	for fighter: Combatant in _fighters:
		if fresh:
			fighter.swing_hits.clear()
		fighter.freeze(s)
	var space: PhysicsDirectSpaceState3D = _world.get_world_3d().direct_space_state
	return _resolver.resolve(s, _fighters, space)


## Graba el historial de todos los luchadores en los ticks [param from] a [param to] (incluidos)
## con su estado de ahora.
func _record_all(from_tick: int, to_tick: int) -> void:
	for tick: int in range(from_tick, to_tick + 1):
		for fighter: Combatant in _fighters:
			CombatFixture.record(_history, fighter, tick)


## Un peer con RTT de 4 ticks y 6 de interpolación: tope de rebobinado de 4 + 0 + 6 + 2 = 12.
func _lagged_peer() -> ServerPeer:
	var peer := ServerPeer.new(7)
	peer.rtt_ticks = 4
	peer.interp_delay_q = 48
	return peer


## Hace que la entrada real del tick [param tick] (S por defecto) del atacante lleve ese
## [param view_offset_q] y la consume, como haría el servidor.
func _set_view_offset(attacker: Combatant, view_offset_q: int, tick: int = S) -> void:
	attacker.queue.reset(tick - 1, NetProtocol.neutral_input(tick - 1, 0.0))
	attacker.queue.push(NetProtocol.neutral_input(tick, 0.0), view_offset_q, tick)
	attacker.queue.take(tick)


func _outcomes(hits: Array[CombatResolver.Hit]) -> Array[int]:
	var result: Array[int] = []
	for hit: CombatResolver.Hit in hits:
		result.append(hit.outcome)
	return result


# --- Forma y línea de visión ------------------------------------------------------------------

func test_hit_inside_the_sector() -> void:
	var duel: Array[Combatant] = _duel(1.5)
	CombatFixture.start_light_active(duel[0], S)
	var hits: Array[CombatResolver.Hit] = _resolve()
	if not assert_eq(hits.size(), 1, "un golpe"):
		return
	assert_eq(hits[0].outcome, CombatResolver.Outcome.IMPACT)
	assert_true(hits[0].attacker == duel[0] and hits[0].victim == duel[1], "de 1 a 2")
	assert_near(hits[0].view_tick, float(S), 1e-6, "sin rebobinado")
	assert_near(hits[0].rewind, 0.0, 1e-6)
	assert_false(hits[0].critical, "de frente no es crítico")
	assert_eq(hits[0].attack.id, CombatCatalog.attack_id(&"sword_light_1"))


func test_misses_outside_the_sector() -> void:
	var attacker: Combatant = _fighter(1, VARDHEIM, Vector3.ZERO, 0.0)
	CombatFixture.start_light_active(attacker, S)
	# Fuera de alcance (2,6 + 0,4 de radio).
	var far: Combatant = _fighter(2, SOLMARCH, Vector3(0.0, 0.0, -3.2), 0.0)
	assert_eq(_resolve().size(), 0, "a 3,2 m no llega")
	far.get_character().global_position = Vector3(0.0, 0.0, -2.9)
	assert_eq(_resolve().size(), 1, "a 2,9 m (alcance más radio) sí")
	# Detrás del atacante.
	far.get_character().global_position = Vector3(0.0, 0.0, 1.5)
	assert_eq(_resolve().size(), 0, "a su espalda no")
	# A los lados: 100° de arco, así que 50° a cada lado más lo que ocupa la cápsula.
	far.get_character().global_position = Vector3(1.5, 0.0, -0.3)
	assert_eq(_resolve().size(), 0, "casi de lado (79°) no")
	far.get_character().global_position = Vector3(1.0, 0.0, -1.0)
	assert_eq(_resolve().size(), 1, "a 45° sí")
	# Por encima: las alturas del sector son 0,2 a 2,0 m sobre los pies del atacante.
	far.get_character().global_position = Vector3(0.0, 2.5, -1.5)
	assert_eq(_resolve().size(), 0, "dos metros y medio por encima no")


func test_a_wall_in_between_blocks_the_hit() -> void:
	var duel: Array[Combatant] = _duel(1.5)
	CombatFixture.start_light_active(duel[0], S)
	var wall := StaticBody3D.new()
	wall.collision_layer = PlayerCharacter.WORLD_COLLISION_LAYER
	wall.collision_mask = 0
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(4.0, 3.0, 0.2)
	shape.shape = box
	shape.position = Vector3(0.0, 1.5, -0.8)
	wall.add_child(shape)
	_world.add_child(wall)
	await wait_physics_frames(2)
	assert_eq(_resolve().size(), 0, "detrás de un muro no hay golpe")
	_world.remove_child(wall)
	wall.free()
	await wait_physics_frames(2)
	assert_eq(_resolve().size(), 1, "sin el muro, sí")


func test_back_attack_is_critical() -> void:
	var attacker: Combatant = _fighter(1, VARDHEIM, Vector3.ZERO, 0.0)
	# La víctima mira en el mismo sentido que el atacante: le da la espalda.
	_fighter(2, SOLMARCH, Vector3(0.0, 0.0, -1.5), 0.0)
	CombatFixture.start_light_active(attacker, S)
	var hits: Array[CombatResolver.Hit] = _resolve()
	if assert_eq(hits.size(), 1):
		assert_eq(hits[0].outcome, CombatResolver.Outcome.IMPACT)
		assert_true(hits[0].critical, "por la espalda es crítico")


# --- Defensa ----------------------------------------------------------------------------------

func test_frontal_block_yes_and_back_block_no() -> void:
	var duel: Array[Combatant] = _duel(1.5)
	CombatFixture.start_light_active(duel[0], S)
	CombatFixture.start_block(duel[1], S - 30)
	var hits: Array[CombatResolver.Hit] = _resolve()
	if assert_eq(hits.size(), 1):
		assert_eq(hits[0].outcome, CombatResolver.Outcome.BLOCKED, "el escudo de cara bloquea")
	# De espaldas al atacante el cono de bloqueo no lo cubre.
	duel[1].get_character().yaw = 0.0
	hits = _resolve()
	if assert_eq(hits.size(), 1):
		assert_eq(hits[0].outcome, CombatResolver.Outcome.IMPACT, "por la espalda no bloquea")
		assert_true(hits[0].critical, "y es crítico")


func test_parry_inside_and_outside_the_window() -> void:
	var duel: Array[Combatant] = _duel(1.5)
	var window: int = CombatCatalog.rules().parry_window_ticks
	CombatFixture.start_light_active(duel[0], S)
	# La ventana de parada se abrió hace window - 1 ticks: el último tick de la ventana.
	CombatFixture.start_block(duel[1], S - window + 1, true)
	var hits: Array[CombatResolver.Hit] = _resolve()
	if assert_eq(hits.size(), 1):
		assert_eq(hits[0].outcome, CombatResolver.Outcome.PARRIED, "dentro de la ventana, parada")
	# Un tick más tarde la ventana se cerró: ya es un bloqueo normal.
	CombatFixture.start_block(duel[1], S - window, true)
	hits = _resolve()
	if assert_eq(hits.size(), 1):
		assert_eq(hits[0].outcome, CombatResolver.Outcome.BLOCKED, "fuera de la ventana, bloqueo")


func test_invulnerable_dodge_has_no_effect_and_does_not_consume_the_swing() -> void:
	var duel: Array[Combatant] = _duel(1.5)
	CombatFixture.start_light_active(duel[0], S)
	var dodge_ticks: DodgeTicks = CombatCatalog.weapon(duel[1].get_character().combat.weapon_id).dodge
	# La esquiva empezó hace 10 ticks: el tick S está dentro de sus ticks invulnerables.
	var start: int = S - dodge_ticks.invulnerable_from_ticks - 2
	CombatFixture.start_dodge(duel[1], start)
	assert_true(ActionMachine.is_invulnerable(duel[1].get_character().combat, S), "invulnerable en S")
	var hits: Array[CombatResolver.Hit] = _resolve()
	if assert_eq(hits.size(), 1):
		assert_eq(hits[0].outcome, CombatResolver.Outcome.INVULNERABLE)
	assert_false(duel[0].has_hit(2), "la invulnerabilidad no consume el golpe")
	# Pasada la invulnerabilidad el mismo ataque sí acierta.
	CombatFixture.start_dodge(duel[1], S - dodge_ticks.invulnerable_to_ticks)
	assert_false(ActionMachine.is_invulnerable(duel[1].get_character().combat, S))
	hits = _resolve()
	if assert_eq(hits.size(), 1):
		assert_eq(hits[0].outcome, CombatResolver.Outcome.IMPACT, "acierta al acabar")


func test_invulnerability_is_found_even_when_the_whole_window_falls_between_view_tick_and_s() -> void:
	var peer: ServerPeer = _lagged_peer()
	var attacker: Combatant = _fighter(1, VARDHEIM, Vector3.ZERO, 0.0, peer)
	var victim: Combatant = _fighter(2, SOLMARCH, Vector3(0.0, 0.0, -1.5), PI_YAW)
	CombatFixture.start_light_active(attacker, S)
	_set_view_offset(attacker, 10 * CombatResolver.VIEW_OFFSET_Q_SCALE)
	# Historial: la víctima esquivó entre S - 8 y S - 3 (invulnerable en parte de esos ticks) y
	# ahora, en S, ya no es invulnerable ni lo era en view_tick (S - 10).
	var dodge: DodgeTicks = CombatCatalog.weapon(victim.get_character().combat.weapon_id).dodge
	for tick: int in range(S - 12, S):
		var flags: int = EntityRecord.FLAG_GROUNDED
		var dodge_age: int = tick - (S - 8)
		if dodge_age >= dodge.invulnerable_from_ticks and dodge_age < dodge.invulnerable_from_ticks + 2:
			flags |= ActionMachine.DEFENSE_INVULNERABLE
		_history.record(tick, 1, Vector3.ZERO, 0.0, EntityRecord.FLAG_GROUNDED)
		_history.record(tick, 2, Vector3(0.0, 0.0, -1.5), PI_YAW, flags)
	var hits: Array[CombatResolver.Hit] = _resolve()
	if assert_eq(hits.size(), 1):
		assert_eq(hits[0].outcome, CombatResolver.Outcome.INVULNERABLE,
				"el golpe cae en la ventana invulnerable del rebobinado")
		assert_near(hits[0].view_tick, float(S - 10), 1e-4)
		assert_near(hits[0].rewind, 10.0, 1e-4)
	assert_false(attacker.has_hit(2), "sin consumir")


func test_releasing_the_shield_to_attack_removes_the_old_block() -> void:
	var peer: ServerPeer = _lagged_peer()
	var attacker: Combatant = _fighter(1, VARDHEIM, Vector3.ZERO, 0.0, peer)
	var victim: Combatant = _fighter(2, SOLMARCH, Vector3(0.0, 0.0, -1.5), PI_YAW)
	CombatFixture.start_light_active(attacker, S)
	_set_view_offset(attacker, 8 * CombatResolver.VIEW_OFFSET_Q_SCALE)
	# En view_tick (S - 8) y los ticks anteriores la víctima bloqueaba; después soltó el escudo y
	# empezó un ataque en S - 3.
	for tick: int in range(S - 12, S):
		_history.record(tick, 1, Vector3.ZERO, 0.0, EntityRecord.FLAG_GROUNDED)
		_history.record(tick, 2, Vector3(0.0, 0.0, -1.5), PI_YAW,
				EntityRecord.FLAG_GROUNDED | ActionMachine.DEFENSE_BLOCKING)
	var state: CombatState = victim.get_character().combat
	state.action = CombatState.Action.LIGHT
	state.action_id = CombatCatalog.attack_id(&"sword_light_1")
	state.action_tick = S - 3
	var hits: Array[CombatResolver.Hit] = _resolve()
	if assert_eq(hits.size(), 1):
		assert_eq(hits[0].outcome, CombatResolver.Outcome.IMPACT,
				"quien suelta el escudo y ataca ya no está protegido")
	# Si en cambio sigue bloqueando ahora, el bloqueo de view_tick y el de S cuentan.
	CombatFixture.start_block(victim, S - 20)
	hits = _resolve()
	if assert_eq(hits.size(), 1):
		assert_eq(hits[0].outcome, CombatResolver.Outcome.BLOCKED)
	# Y si bloqueaba en view_tick pero ahora está en reposo, el bloqueo de view_tick protege.
	state.action = CombatState.Action.NONE
	state.action_id = 0
	hits = _resolve()
	if assert_eq(hits.size(), 1):
		assert_eq(hits[0].outcome, CombatResolver.Outcome.BLOCKED,
				"el defensor de view_tick que ya no ataca conserva su bloqueo")


func test_a_dodge_started_after_view_tick_also_drops_the_old_block() -> void:
	var peer: ServerPeer = _lagged_peer()
	var attacker: Combatant = _fighter(1, VARDHEIM, Vector3.ZERO, 0.0, peer)
	var victim: Combatant = _fighter(2, SOLMARCH, Vector3(0.0, 0.0, -1.5), PI_YAW)
	CombatFixture.start_light_active(attacker, S)
	_set_view_offset(attacker, 8 * CombatResolver.VIEW_OFFSET_Q_SCALE)
	for tick: int in range(S - 12, S):
		_history.record(tick, 1, Vector3.ZERO, 0.0, EntityRecord.FLAG_GROUNDED)
		_history.record(tick, 2, Vector3(0.0, 0.0, -1.5), PI_YAW,
				EntityRecord.FLAG_GROUNDED | ActionMachine.DEFENSE_BLOCKING)
	# Esquiva empezada en S - 2: en S aún no es invulnerable (los ticks invulnerables empiezan más
	# tarde), pero ya no cuenta el bloqueo de hace 8 ticks.
	CombatFixture.start_dodge(victim, S - 2)
	var dodge: DodgeTicks = CombatCatalog.weapon(victim.get_character().combat.weapon_id).dodge
	if dodge.invulnerable_from_ticks <= 2:
		return
	var hits: Array[CombatResolver.Hit] = _resolve()
	if assert_eq(hits.size(), 1):
		assert_eq(hits[0].outcome, CombatResolver.Outcome.IMPACT)


# --- Un impacto por acción ---------------------------------------------------------------------

func test_one_impact_per_action_and_target() -> void:
	var duel: Array[Combatant] = _duel(1.5)
	CombatFixture.start_light_active(duel[0], S)
	assert_eq(_resolve(S, false).size(), 1, "el primer tick activo acierta")
	var attack: AttackTicks = CombatCatalog.attack(duel[0].get_character().combat.action_id)
	# Los demás ticks activos del mismo ataque no vuelven a golpear.
	for offset: int in range(1, attack.active_ticks):
		assert_eq(_resolve(S + offset, false).size(), 0, "tick activo +%d: ya golpeó" % offset)
	# Un ataque nuevo (otro action_tick) sí.
	CombatFixture.start_light_active(duel[0], S + 20, 1)
	assert_eq(_resolve(S + 20, false).size(), 1, "el siguiente ataque vuelve a golpear")


func test_a_blocked_or_parried_swing_is_also_consumed() -> void:
	var duel: Array[Combatant] = _duel(1.5)
	CombatFixture.start_light_active(duel[0], S)
	CombatFixture.start_block(duel[1], S - 30)
	assert_eq(_resolve(S, false).size(), 1, "bloqueado")
	assert_eq(_resolve(S + 1, false).size(), 0,
			"un golpe bloqueado no se repite en el siguiente tick")


func test_simultaneous_exchange_resolves_both_hits() -> void:
	var duel: Array[Combatant] = _duel(1.5)
	CombatFixture.start_light_active(duel[0], S)
	CombatFixture.start_light_active(duel[1], S)
	var hits: Array[CombatResolver.Hit] = _resolve()
	if not assert_eq(hits.size(), 2, "los dos golpes del mismo tick"):
		return
	assert_true(hits[0].attacker == duel[0] and hits[0].victim == duel[1], "primero 1 -> 2")
	assert_true(hits[1].attacker == duel[1] and hits[1].victim == duel[0], "luego 2 -> 1")
	assert_eq(_outcomes(hits), [CombatResolver.Outcome.IMPACT, CombatResolver.Outcome.IMPACT])


# --- Rebobinado -------------------------------------------------------------------------------

func test_allowed_rewind_formula() -> void:
	assert_eq(CombatResolver.allowed_rewind(4, 0, 48), 12, "4 + 0 + 6 + 2")
	assert_eq(CombatResolver.allowed_rewind(0, 0, 0), 6, "la interpolación sube al mínimo de 4")
	assert_eq(CombatResolver.allowed_rewind(2, 3, 200), 19, "2 + 3 + 12 (máximo) + 2")
	assert_eq(CombatResolver.allowed_rewind(30, 10, 96), NetProtocol.MAX_REWIND_TICKS, "tope de 24")
	assert_eq(CombatResolver.allowed_rewind(4, -3, 48), 12, "una antelación negativa cuenta 0")


func test_rewound_hit_lands_where_the_attacker_saw_the_target() -> void:
	var peer: ServerPeer = _lagged_peer()
	var attacker: Combatant = _fighter(1, VARDHEIM, Vector3.ZERO, 0.0, peer)
	var victim: Combatant = _fighter(2, SOLMARCH, Vector3(4.2, 0.0, -1.5), PI_YAW)
	CombatFixture.start_light_active(attacker, S)
	# Historial: la víctima estaba delante hasta S - 6 y se movió hacia un lado a 0,7 m por tick.
	for tick: int in range(S - 12, S):
		var x: float = maxf(0.0, float(tick - (S - 6))) * 0.7
		_history.record(tick, 1, Vector3.ZERO, 0.0, EntityRecord.FLAG_GROUNDED)
		_history.record(tick, 2, Vector3(x, 0.0, -1.5), PI_YAW, EntityRecord.FLAG_GROUNDED)
	_set_view_offset(attacker, 0)
	assert_eq(_resolve().size(), 0, "sin rebobinado, la víctima ya está fuera del arco")
	_set_view_offset(attacker, 6 * CombatResolver.VIEW_OFFSET_Q_SCALE)
	var hits: Array[CombatResolver.Hit] = _resolve()
	if assert_eq(hits.size(), 1, "con 6 ticks de rebobinado, acierta donde la veía"):
		assert_near(hits[0].view_tick, float(S - 6), 1e-4)
		assert_near(hits[0].rewind, 6.0, 1e-4)


func test_rewind_between_s_minus_one_and_s_interpolates() -> void:
	var peer: ServerPeer = _lagged_peer()
	var attacker: Combatant = _fighter(1, VARDHEIM, Vector3.ZERO, 0.0, peer)
	# La víctima se aleja de frente: estaba a 2,5 m en S - 1 y está a 3,3 m ahora (el alcance, con
	# el radio de la cápsula, es 3,0 m). A un cuarto de tick atrás ya ha recorrido el 75 % (3,1 m:
	# fuera); a tres cuartos de tick atrás, el 25 % (2,7 m: dentro).
	_fighter(2, SOLMARCH, Vector3(0.0, 0.0, -3.3), PI_YAW)
	CombatFixture.start_light_active(attacker, S)
	_history.record(S - 1, 1, Vector3.ZERO, 0.0, EntityRecord.FLAG_GROUNDED)
	_history.record(S - 1, 2, Vector3(0.0, 0.0, -2.5), PI_YAW, EntityRecord.FLAG_GROUNDED)
	_set_view_offset(attacker, 4)
	assert_eq(_resolve().size(), 0, "a un cuarto de tick atrás (3,1 m) sigue fuera")
	_set_view_offset(attacker, 12)
	var hits: Array[CombatResolver.Hit] = _resolve()
	if assert_eq(hits.size(), 1, "a tres cuartos de tick atrás (2,7 m) está dentro"):
		assert_near(hits[0].view_tick, float(S) - 0.75, 1e-4)
		assert_near(hits[0].rewind, 0.75, 1e-4)


func test_rewind_beyond_the_cap_is_rejected_and_counts_suspicion() -> void:
	var peer: ServerPeer = _lagged_peer()
	var attacker: Combatant = _fighter(1, VARDHEIM, Vector3.ZERO, 0.0, peer)
	_fighter(2, SOLMARCH, Vector3(0.0, 0.0, -1.5), PI_YAW)
	CombatFixture.start_light_active(attacker, S)
	for tick: int in range(S - 30, S):
		for fighter: Combatant in _fighters:
			CombatFixture.record(_history, fighter, tick)
	var allowed: int = CombatResolver.allowed_rewind(peer.rtt_ticks, 0, peer.interp_delay_q)
	assert_eq(allowed, 12)
	# allowed + 1 ticks se acepta (con tope): el view_tick queda en S - allowed.
	_set_view_offset(attacker, (allowed + 1) * CombatResolver.VIEW_OFFSET_Q_SCALE)
	var hits: Array[CombatResolver.Hit] = _resolve()
	if assert_eq(hits.size(), 1, "allowed + 1 no se rechaza"):
		assert_eq(hits[0].outcome, CombatResolver.Outcome.IMPACT)
		assert_near(hits[0].view_tick, float(S - allowed), 1e-4, "y se recorta al tope")
	assert_eq(peer.suspicion_score, 0)
	# Por encima de allowed + 1, el golpe ni se prueba.
	_set_view_offset(attacker, (allowed + 1) * CombatResolver.VIEW_OFFSET_Q_SCALE + 1)
	hits = _resolve()
	if assert_eq(hits.size(), 1, "una entrada de rechazo"):
		assert_eq(hits[0].outcome, CombatResolver.Outcome.REWIND_REJECTED)
		assert_null(hits[0].victim, "sin objetivo")
	assert_eq(peer.suspicion_score, 1, "suma a la sospecha")
	assert_eq(peer.rewind_rejects, 1)
	assert_eq(_resolver.rewind_rejects, 1)
	# El mismo ataque no suma otra vez en el siguiente tick activo (la sustituta hereda el pedido).
	attacker.queue.take(S + 1)
	hits = _resolve(S + 1, false)
	assert_eq(hits.size(), 0, "ya rechazado")
	assert_eq(peer.suspicion_score, 1, "se cuenta una vez por ataque")
	# Con 40 ticks (el bot tramposo del documento) también.
	CombatFixture.start_light_active(attacker, S + 30)
	_set_view_offset(attacker, 40 * CombatResolver.VIEW_OFFSET_Q_SCALE, S + 30)
	hits = _resolve(S + 30)
	assert_eq(_outcomes(hits), [CombatResolver.Outcome.REWIND_REJECTED], "40 ticks de rebobinado")
	assert_eq(peer.suspicion_score, 2)


## Con jitter, el mínimo del RTT de la ventana se queda por debajo del viaje de un tick cualquiera: un
## jugador honrado cuya vista va más atrás de lo que cubre el mínimo no debe ser rechazado ni
## sospechoso. El tope usa el mayor de los dos (el máximo ya viene acotado por una fuente que el cliente
## no controla).
func test_the_cap_covers_the_worst_round_trips_of_the_window_not_only_the_best() -> void:
	var peer: ServerPeer = _lagged_peer()
	peer.rtt_peak_ticks = 10
	var attacker: Combatant = _fighter(1, VARDHEIM, Vector3.ZERO, 0.0, peer)
	_fighter(2, SOLMARCH, Vector3(0.0, 0.0, -1.5), PI_YAW)
	CombatFixture.start_light_active(attacker, S)
	for tick: int in range(S - 30, S):
		for fighter: Combatant in _fighters:
			CombatFixture.record(_history, fighter, tick)
	# Con el mínimo (4) el tope sería 12 y 17 ticks se rechazarían; con el máximo (10) es 18.
	assert_eq(CombatResolver.allowed_rewind(peer.rtt_ticks, 0, peer.interp_delay_q), 12)
	_set_view_offset(attacker, 17 * CombatResolver.VIEW_OFFSET_Q_SCALE)
	var hits: Array[CombatResolver.Hit] = _resolve()
	if assert_eq(hits.size(), 1, "una vista de 17 ticks entra"):
		assert_eq(hits[0].outcome, CombatResolver.Outcome.IMPACT)
		assert_near(hits[0].view_tick, float(S - 17), 1e-4, "sin recortar")
	assert_eq(peer.suspicion_score, 0, "y no suma sospecha")
	# El tope sigue siendo un tope: 20 ticks pasan del máximo (18 + 1).
	_set_view_offset(attacker, 20 * CombatResolver.VIEW_OFFSET_Q_SCALE)
	assert_eq(_outcomes(_resolve()), [CombatResolver.Outcome.REWIND_REJECTED], "20 ticks, no")
	assert_eq(peer.suspicion_score, 1)


func test_substituted_input_uses_the_last_real_rewind() -> void:
	var peer: ServerPeer = _lagged_peer()
	var attacker: Combatant = _fighter(1, VARDHEIM, Vector3.ZERO, 0.0, peer)
	_fighter(2, SOLMARCH, Vector3(0.0, 0.0, -1.5), PI_YAW)
	CombatFixture.start_light_active(attacker, S)
	for tick: int in range(S - 30, S):
		for fighter: Combatant in _fighters:
			CombatFixture.record(_history, fighter, tick)
	# La última entrada real (tick S - 1) pedía 5 ticks; la del tick S se sustituyó.
	_set_view_offset(attacker, 5 * CombatResolver.VIEW_OFFSET_Q_SCALE, S - 1)
	attacker.queue.take(S)
	var hits: Array[CombatResolver.Hit] = _resolve()
	if assert_eq(hits.size(), 1):
		assert_near(hits[0].view_tick, float(S - 5), 1e-4, "la sustituta hereda el rebobinado")


func test_fakes_and_npcs_never_rewind() -> void:
	var attacker: Combatant = _fighter(1, VARDHEIM, Vector3.ZERO, 0.0)
	_fighter(2, SOLMARCH, Vector3(0.0, 0.0, -1.5), PI_YAW)
	CombatFixture.start_light_active(attacker, S)
	var hits: Array[CombatResolver.Hit] = _resolve()
	if assert_eq(hits.size(), 1):
		assert_near(hits[0].view_tick, float(S), 1e-6)


func test_a_target_that_did_not_exist_at_view_tick_is_discarded() -> void:
	var peer: ServerPeer = _lagged_peer()
	var attacker: Combatant = _fighter(1, VARDHEIM, Vector3.ZERO, 0.0, peer)
	_fighter(2, SOLMARCH, Vector3(0.0, 0.0, -1.5), PI_YAW)
	CombatFixture.start_light_active(attacker, S)
	# La víctima solo tiene historial desde S - 2, y el atacante pide mirar 6 ticks atrás.
	for tick: int in range(S - 2, S):
		for fighter: Combatant in _fighters:
			CombatFixture.record(_history, fighter, tick)
	_set_view_offset(attacker, 6 * CombatResolver.VIEW_OFFSET_Q_SCALE)
	assert_eq(_resolve().size(), 0, "sin muestra no hay golpe")


# --- Candidatos -------------------------------------------------------------------------------

func test_allies_are_never_hit_and_realms_need_an_rvr_zone() -> void:
	var attacker: Combatant = _fighter(1, VARDHEIM, Vector3.ZERO, 0.0)
	var ally: Combatant = _fighter(2, VARDHEIM, Vector3(0.0, 0.0, -1.5), PI_YAW)
	CombatFixture.start_light_active(attacker, S)
	assert_eq(_resolve().size(), 0, "sin fuego amigo")
	ally.entity.realm = ASKARRA
	assert_eq(_resolve().size(), 1, "un reino enemigo en una zona RVR")
	# En una zona segura los reinos no se dañan.
	var safe_zone := CombatResolver.new(_history, &"zona_segura_inventada")
	for fighter: Combatant in _fighters:
		fighter.freeze(S)
	var space: PhysicsDirectSpaceState3D = _world.get_world_3d().direct_space_state
	assert_eq(safe_zone.resolve(S, _fighters, space).size(), 0, "zona SAFE: no hay daño entre reinos")
	# Un Hueco (bando neutral) es hostil a todos.
	attacker.swing_hits.clear()
	ally.entity.realm = RealmCatalog.NEUTRAL_CODE
	assert_eq(safe_zone.resolve(S, _fighters, space).size(), 1, "los Huecos son hostiles")


func test_dead_and_protected_targets_are_not_candidates() -> void:
	var duel: Array[Combatant] = _duel(1.5)
	CombatFixture.start_light_active(duel[0], S)
	duel[1].protected_until = S + 10
	assert_eq(_resolve().size(), 0, "protegido por la reaparición")
	duel[1].protected_until = S
	assert_eq(_resolve().size(), 1, "la protección acaba en su tick de fin")
	duel[1].health = 0
	assert_eq(_resolve().size(), 0, "un muerto no recibe golpes")


func test_target_dead_at_view_tick_is_discarded() -> void:
	var peer: ServerPeer = _lagged_peer()
	var attacker: Combatant = _fighter(1, VARDHEIM, Vector3.ZERO, 0.0, peer)
	var victim: Combatant = _fighter(2, SOLMARCH, Vector3(0.0, 0.0, -1.5), PI_YAW)
	CombatFixture.start_light_active(attacker, S)
	for tick: int in range(S - 12, S):
		_history.record(tick, 1, Vector3.ZERO, 0.0, EntityRecord.FLAG_GROUNDED)
		_history.record(tick, 2, Vector3(0.0, 0.0, -1.5), PI_YAW,
				EntityRecord.FLAG_GROUNDED | ActionMachine.DEFENSE_DEAD)
	_set_view_offset(attacker, 4 * CombatResolver.VIEW_OFFSET_Q_SCALE)
	assert_eq(victim.is_alive(), true)
	assert_eq(_resolve().size(), 0, "estaba muerto en view_tick: ya no es un blanco")


func _safe_area_resolver() -> void:
	var safe := SafeAreas.new()
	safe.add(Vector3.ZERO, 24.0, VARDHEIM)
	_resolver = CombatResolver.new(_history, ZONE_ID, safe)


func test_safe_area_protects_a_victim_of_its_realm() -> void:
	_safe_area_resolver()
	var attacker: Combatant = _fighter(1, SOLMARCH, Vector3(10.0, 0.0, 0.0), 0.0)
	_fighter(2, VARDHEIM, Vector3(10.0, 0.0, -1.5), PI_YAW)
	CombatFixture.start_light_active(attacker, S)
	assert_eq(_resolve().size(), 0, "la víctima de Vardheim dentro de su zona segura no recibe daño")


func test_safe_area_does_not_let_its_realm_attack_from_inside() -> void:
	_safe_area_resolver()
	var attacker: Combatant = _fighter(1, VARDHEIM, Vector3(10.0, 0.0, 0.0), 0.0)
	_fighter(2, SOLMARCH, Vector3(10.0, 0.0, -1.5), PI_YAW)
	CombatFixture.start_light_active(attacker, S)
	assert_eq(_resolve().size(), 0, "desde dentro de su zona segura no se puede atacar")


func test_an_intruder_inside_a_safe_area_can_be_hit_from_outside() -> void:
	_safe_area_resolver()
	# El atacante de Vardheim está a 25 m del centro (fuera) y el intruso de Solmarch a 23 m (dentro).
	var attacker: Combatant = _fighter(1, VARDHEIM, Vector3(0.0, 0.0, 25.0), 0.0)
	_fighter(2, SOLMARCH, Vector3(0.0, 0.0, 23.0), PI_YAW)
	CombatFixture.start_light_active(attacker, S)
	var hits: Array[CombatResolver.Hit] = _resolve()
	if assert_eq(hits.size(), 1, "el intruso dentro de la zona segura enemiga sí es dañable"):
		assert_eq(hits[0].outcome, CombatResolver.Outcome.IMPACT)


func test_safe_area_of_another_realm_does_not_protect() -> void:
	_safe_area_resolver()
	# Dentro de la zona segura de Vardheim, un Solmarch y un Askarra se pegan sin problema.
	var attacker: Combatant = _fighter(1, SOLMARCH, Vector3(10.0, 0.0, 0.0), 0.0)
	_fighter(2, ASKARRA, Vector3(10.0, 0.0, -1.5), PI_YAW)
	CombatFixture.start_light_active(attacker, S)
	assert_eq(_resolve().size(), 1, "la zona segura solo protege a su reino")
