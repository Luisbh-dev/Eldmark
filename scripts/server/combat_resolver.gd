class_name CombatResolver
extends RefCounted
## Resolución autoritativa de los golpes con rebobinado de hitboxes (docs/combate.md, sección 4.3;
## CMB-09 y TEC-14).
## [br][br]
## [method resolve] se llama una vez por tick, después de simular a todas las entidades y de
## congelarlas ([method Combatant.freeze]). Para cada atacante en golpe activo calcula contra quién
## acierta, [b]sin tocar ningún estado de combate[/b] (solo apunta, en el propio atacante, a quién
## ha golpeado ya): todos los golpes de un tick son simultáneos y los aplica después quien llama
## (en orden de net_id del atacante y del objetivo).
## [br][br]
## Para cada atacante:
## [br]1. [b]Rebobinado.[/b] [method InputQueue.get_rewind_params] da [code]view_offset_q[/code] y
## la antelación de la entrada del golpe, [b]una sola vez por golpe[/b] (en su primer tick activo: el
## rebobinado queda fijado en el [Combatant] y los demás ticks activos lo reutilizan, con el
## [code]view_tick[/code] avanzando con el tick). El tope [method allowed_rewind] sale de red.md,
## sección 10, con el mayor de [member ServerPeer.rtt_ticks] y [member ServerPeer.rtt_peak_ticks] (con
## jitter el mínimo se queda corto para un jugador honrado) y una antelación acotada por la habitual
## del cliente más su dispersión y por un máximo (la de cada entrada la escoge el cliente). Con más de
## [code]allowed + 1[/code] ticks el golpe no se prueba (puntuación de sospecha del peer y línea en el
## registro). Si no, [code]view_tick = clamp(s − view_offset_q / 16, s − allowed, s)[/code]. Para las
## defensas retroactivas se mira atrás como mínimo [code]rtt_floor + 4 − 2[/code] ticks
## ([member ServerPeer.rtt_floor_ticks], el RTT de ENet): pedir 0 no libra de ellas. Los jugadores
## falsos y los PNJ no rebobinan ([code]view_tick = s[/code]).
## [br]2. [b]Muestras.[/b] El atacante, siempre en su estado congelado de [code]s[/code]. Cada
## candidato en [code]view_tick[/code]: del [StateHistory] si [code]view_tick ≤ s − 1[/code],
## interpolado entre la pista de [code]s − 1[/code] y lo congelado si está entre [code]s − 1[/code] y
## [code]s[/code], o lo congelado si es [code]s[/code]. Sin muestra, el candidato se descarta.
## [br]3. [b]Candidatos.[/b] Hostiles según [FactionRules], vivos ahora y sin el bit «muerto» en
## [code]view_tick[/code], sin protección de reaparición y sin zona segura de por medio (la víctima
## en la de su reino, o el atacante en la de su reino), en [code]s[/code]. Un objetivo ya golpeado
## por este ataque no se vuelve a probar.
## [br]4. [b]Forma y línea de visión.[/b] [method HitShapes.sector_hits_capsule] con la muestra de
## la víctima y un rayo contra el mundo actual.
## [br]5. [b]Defensa[/b], por este orden: invulnerable en algún tick de
## [code][floor(defensa), s][/code] (sin efecto, [b]no consume[/b] el golpe), parada, bloqueo e
## impacto, donde [code]defensa[/code] es el [code]view_tick[/code] o, si es anterior, el instante que
## impone el mínimo para la defensa. La parada y el bloqueo se miran en la muestra de ese instante y en
## la de [code]s[/code], con el atacante dentro del cono frontal del defensor; la antigua no cuenta si
## el defensor ha empezado después un ataque, una esquiva o un control (tambaleo, aturdimiento): quien
## suelta el escudo para atacar, o a quien se lo quitan, deja de estar protegido.
## [br][br]
## Un impacto, un bloqueo o una parada consumen el ataque para ese objetivo.

## Resultado de un golpe sobre un objetivo.
enum Outcome {
	## Acierta: daño completo y controles del ataque.
	IMPACT,
	## Acierta contra un escudo en alto: el daño se mitiga y cuesta resistencia.
	BLOCKED,
	## Parada: sin daño y el atacante queda tambaleándose.
	PARRIED,
	## El objetivo era invulnerable: sin efecto y el ataque sigue vivo.
	INVULNERABLE,
	## El rebobinado pedido supera el tope: el ataque no se prueba (no hay objetivo).
	REWIND_REJECTED,
	## Acierta un blanco estático (la puerta de un fuerte, [member Hit.structure]): sin rebobinado,
	## sin crítico y sin defensa.
	STRUCTURE,
}

## Escala de [code]view_offset_q[/code] (ticks × 16).
const VIEW_OFFSET_Q_SCALE: int = 16
## Velocidad (m/s) con la que se ensancha la búsqueda de candidatos por el rebobinado: la mayor que
## puede tener un personaje (esquiva o empuje) con margen.
const _SEARCH_SPEED: float = 24.0
const _SEARCH_MARGIN: float = 0.25
## Retardo de interpolación mínimo (ticks) que se supone al calcular el tope de rebobinado.
const _MIN_INTERP_TICKS: int = 4
## Antelación (ticks) que como mucho abona el tope del rebobinado: la que mantiene un cliente honrado
## con [code]TickSync[/code] (margen objetivo de hasta 4 más 2 de holgura de la ventana, más 2). Un cliente
## que se adelante más no sube el tope.
const _MAX_LEAD_CREDIT: int = 8
## Cuánto puede pasar la antelación de la entrada de un golpe de la habitual del cliente
## ([method InputQueue.get_typical_lead]): la dispersión de un honrado con jitter. Más es una entrada
## adelantada a propósito.
const _LEAD_SPREAD: int = 3

## Blancos estáticos de la zona (las puertas de los fuertes, docs/fuerte.md 3.3): se prueban para cada
## ataque activo después de los jugadores, sin rebobinado (no se mueven).
var structure_targets: Array[StructureTarget] = []
## Golpes rechazados por rebobinado excesivo desde que existe el resolutor.
var rewind_rejects: int = 0
## Comprobaciones de forma y línea de visión de un ataque contra un candidato (con muestra del historial
## incluida) desde que existe el resolutor: la unidad de coste de las pruebas de carga.
var tests: int = 0

var _history: StateHistory
var _zone_id: StringName
var _safe_areas: SafeAreas
# (bando atacante · 16 + bando víctima) -> si hay daño entre ellos en esta zona.
var _hostile_cache: Dictionary = {}


## Un resultado de [method resolve].
class Hit:
	var attacker: Combatant
	## null en [constant Outcome.REWIND_REJECTED] y en [constant Outcome.STRUCTURE].
	var victim: Combatant
	## El blanco estático golpeado ([constant Outcome.STRUCTURE]); null en los demás.
	var structure: StructureTarget = null
	var attack: AttackTicks
	var outcome: int = Outcome.IMPACT
	## Instante (en ticks, fraccionario) en el que el atacante veía al objetivo.
	var view_tick: float = 0.0
	## Ticks rebobinados ([code]s − view_tick[/code]).
	var rewind: float = 0.0
	## Golpe por la espalda (solo en impactos y bloqueos).
	var critical: bool = false


## [param history] es el historial de posiciones del servidor, [param zone_id] la zona (para las
## reglas de hostilidad) y [param safe_areas] sus zonas seguras (null = ninguna).
func _init(history: StateHistory, zone_id: StringName, safe_areas: SafeAreas = null) -> void:
	_history = history
	_zone_id = zone_id
	_safe_areas = safe_areas if safe_areas != null else SafeAreas.new()


## Tope de rebobinado en ticks (red.md, sección 10): [code]min(24, rtt + lead + clamp(interp / 8,
## 4, 12) + 2)[/code], con el retardo de interpolación [param interp_delay_q] en octavos de tick.
@warning_ignore("integer_division")
static func allowed_rewind(rtt_ticks: int, lead: int, interp_delay_q: int) -> int:
	var interpolation: int = clampi(interp_delay_q / NetProtocol.INTERP_DELAY_Q_SCALE,
			_MIN_INTERP_TICKS, NetProtocol.MAX_INTERP_DELAY_TICKS)
	return mini(NetProtocol.MAX_REWIND_TICKS, rtt_ticks + maxi(lead, 0) + interpolation + 2)


## Resuelve los ataques activos del tick [param s] de [param combatants] (ordenados por net_id, ya
## congelados en [param s]) contra el espacio de física [param space] (para la línea de visión).
## Devuelve los golpes en orden de net_id del atacante y del objetivo.
func resolve(s: int, combatants: Array[Combatant],
		space: PhysicsDirectSpaceState3D) -> Array[Hit]:
	var hits: Array[Hit] = []
	var rules: CombatRules = CombatCatalog.rules()
	for attacker: Combatant in combatants:
		var attacker_frame: Combatant.Frozen = attacker.frozen
		if not attacker_frame.attack_active or attacker.is_dead():
			continue
		var attack: AttackTicks = CombatCatalog.attack(attacker_frame.action_id)
		if attack == null or attack.shape == null:
			continue
		attacker.track_swing(attacker_frame.action_tick)
		if not structure_targets.is_empty():
			_resolve_structures(attacker, attack, space, hits)
		var rewind: float = _swing_rewind(attacker, s)
		if is_nan(rewind):
			_reject(attacker, attack, s, hits)
			continue
		var view_tick: float = float(s) - rewind
		var defense_tick: float = float(s) - attacker.swing_defense_rewind
		var margin: float = _SEARCH_MARGIN + _SEARCH_SPEED * (float(s) - view_tick) \
				/ float(Engine.physics_ticks_per_second)
		var reach: float = attack.shape.range_m + HitShapes.CAPSULE_RADIUS + margin
		var reach_squared: float = reach * reach
		for victim: Combatant in combatants:
			if victim == attacker or attacker.has_hit(victim.get_id()):
				continue
			# Lo barato primero: casi todos los demás están fuera del alcance.
			var victim_position: Vector3 = victim.frozen.position
			var dx: float = victim_position.x - attacker_frame.position.x
			var dz: float = victim_position.z - attacker_frame.position.z
			if dx * dx + dz * dz > reach_squared:
				continue
			if not _is_candidate(attacker, victim, s):
				continue
			var hit: Hit = _test(attacker, victim, attack, view_tick, defense_tick, s, space,
					rules)
			if hit != null:
				hits.append(hit)
	return hits


# Prueba el ataque activo de [param attacker] contra los blancos estáticos: forma (sector contra caja)
# y línea de visión hasta la caja, sin contar los cuerpos de la propia puerta. Sin rebobinado, sin
# críticos ni defensa. Quien está en la zona segura de su reino no ataca (tampoco a la puerta).
func _resolve_structures(attacker: Combatant, attack: AttackTicks,
		space: PhysicsDirectSpaceState3D, hits: Array[Hit]) -> void:
	var frame: Combatant.Frozen = attacker.frozen
	if _safe_areas.contains_own(attacker.get_realm(), frame.position):
		return
	for target: StructureTarget in structure_targets:
		if attacker.has_hit(target.net_id) or not target.can_be_hit_by(attacker.get_realm()):
			continue
		tests += 1
		if not HitShapes.sector_hits_box(frame.position, frame.yaw, attack.shape, target.box,
				target.half_extents):
			continue
		var from: Vector3 = frame.position + Vector3(0.0, HitShapes.LINE_OF_SIGHT_FROM_HEIGHT, 0.0)
		if not _is_clear_to(space, from, target.closest_point(from), target.exclude):
			continue
		var hit := Hit.new()
		hit.attacker = attacker
		hit.attack = attack
		hit.structure = target
		hit.outcome = Outcome.STRUCTURE
		hit.view_tick = float(frame.tick)
		attacker.mark_hit(target.net_id)
		hits.append(hit)


# Línea de visión de [param from] a [param to] contra el mundo y las estructuras, sin contar los cuerpos
# [param exclude] (los de la propia puerta).
static func _is_clear_to(space: PhysicsDirectSpaceState3D, from: Vector3, to: Vector3,
		exclude: Array[RID]) -> bool:
	if from.distance_squared_to(to) < 0.0001:
		return true
	var query: PhysicsRayQueryParameters3D = PhysicsRayQueryParameters3D.create(from, to,
			HitShapes.LINE_OF_SIGHT_MASK, exclude)
	return space.intersect_ray(query).is_empty()


# Ticks que el golpe ve atrás, o NAN si pide más de lo permitido. Se fija una vez, en el primer tick
# activo del golpe, y los demás ticks activos lo reutilizan (el view_tick avanza con ellos): el cliente
# ya no puede cambiar el rebobinado de un tick a otro para barrer la ventana ni quitarse las defensas
# retroactivas con un 0. El tope abona la antelación de la entrada del golpe (con ella un honrado nunca
# queda por encima: su vista es rtt + antelación + interpolación), pero acotada por la habitual del
# cliente más su dispersión y por un máximo: la de cada entrada la escoge el cliente. Un atacante sin
# peer (jugador falso, PNJ) no rebobina.
func _swing_rewind(attacker: Combatant, s: int) -> float:
	if attacker.peer == null or attacker.queue == null:
		return 0.0
	if attacker.swing_rewind_fixed:
		return attacker.swing_rewind
	var params: Vector2i = attacker.queue.get_rewind_params(s)
	var lead: int = mini(params.y, mini(attacker.queue.get_typical_lead(s) + _LEAD_SPREAD,
			_MAX_LEAD_CREDIT))
	var allowed: int = allowed_rewind(maxi(attacker.peer.rtt_ticks, attacker.peer.rtt_peak_ticks),
			lead, attacker.peer.interp_delay_q)
	var rewind: float = NAN
	if params.x <= (allowed + 1) * VIEW_OFFSET_Q_SCALE:
		rewind = clampf(float(params.x) / float(VIEW_OFFSET_Q_SCALE), 0.0, float(allowed))
	attacker.swing_rewind_fixed = true
	attacker.swing_rewind = rewind
	# Para la defensa se mira atrás como mínimo lo que un honrado con ese RTT no puede evitar ver
	# (el RTT de ENet más el retardo de interpolación mínimo, menos 2 de holgura), pero nunca más allá
	# del tope.
	var minimum: float = minf(float(maxi(attacker.peer.rtt_floor_ticks + _MIN_INTERP_TICKS - 2, 0)),
			float(allowed))
	attacker.swing_defense_rewind = maxf(rewind, minimum) if not is_nan(rewind) else 0.0
	return rewind


# Anota un golpe rechazado por rebobinado excesivo: una vez por ataque.
func _reject(attacker: Combatant, attack: AttackTicks, s: int, hits: Array[Hit]) -> void:
	if attacker.rejected_swing_tick == attacker.frozen.action_tick:
		return
	attacker.rejected_swing_tick = attacker.frozen.action_tick
	rewind_rejects += 1
	if attacker.peer != null:
		attacker.peer.suspicion_score += 1
		attacker.peer.rewind_rejects += 1
	var hit := Hit.new()
	hit.attacker = attacker
	hit.attack = attack
	hit.outcome = Outcome.REWIND_REJECTED
	if attacker.peer != null and attacker.queue != null:
		var params: Vector2i = attacker.queue.get_rewind_params(s)
		hit.rewind = float(params.x) / float(VIEW_OFFSET_Q_SCALE)
		hit.view_tick = float(s) - hit.rewind
	hits.append(hit)


# Candidato por reglas: hostil, vivo, sin protección y sin zona segura de por medio.
func _is_candidate(attacker: Combatant, victim: Combatant, s: int) -> bool:
	if victim.is_dead() or victim.is_protected(s):
		return false
	if not _is_hostile(attacker.get_realm(), victim.get_realm()):
		return false
	if _safe_areas.contains_own(victim.get_realm(), victim.frozen.position):
		return false
	if _safe_areas.contains_own(attacker.get_realm(), attacker.frozen.position):
		return false
	return true


# [method FactionRules.can_damage] de la zona, con caché por pareja de bandos (la zona no cambia).
func _is_hostile(attacker_realm: int, victim_realm: int) -> bool:
	var key: int = attacker_realm * 16 + victim_realm
	if not _hostile_cache.has(key):
		_hostile_cache[key] = FactionRules.can_damage(attacker_realm, victim_realm, _zone_id)
	return _hostile_cache[key]


# Prueba un ataque contra un candidato. null si no lo alcanza.
func _test(attacker: Combatant, victim: Combatant, attack: AttackTicks, view_tick: float,
		defense_tick: float, s: int, space: PhysicsDirectSpaceState3D, rules: CombatRules) -> Hit:
	var attacker_frame: Combatant.Frozen = attacker.frozen
	tests += 1
	var sample: StateHistory.Sample = _sample(victim, view_tick, s)
	if sample == null or (sample.flags & ActionMachine.DEFENSE_DEAD) != 0:
		return null
	if not HitShapes.sector_hits_capsule(attacker_frame.position, attacker_frame.yaw,
			attack.shape, sample.position, HitShapes.CAPSULE_RADIUS, HitShapes.CAPSULE_HEIGHT):
		return null
	if not HitShapes.has_line_of_sight(space, attacker_frame.position, sample.position):
		return null

	var hit := Hit.new()
	hit.attacker = attacker
	hit.victim = victim
	hit.attack = attack
	hit.view_tick = view_tick
	hit.rewind = float(s) - view_tick
	hit.outcome = _defense(attacker, victim, attack, view_tick, defense_tick, s, sample)
	if hit.outcome == Outcome.IMPACT or hit.outcome == Outcome.BLOCKED:
		hit.critical = DamageFormula.is_backstab(attacker_frame.position, sample.position,
				sample.yaw, rules.backstab_angle_deg)
	if hit.outcome != Outcome.INVULNERABLE:
		attacker.mark_hit(victim.get_id())
	return hit


# Precedencia de la defensa (docs/combate.md, 4.3, paso 6). [param defense_tick] es el instante más
# antiguo que se mira para las defensas retroactivas: view_tick, o antes si el servidor impone un
# rebobinado mínimo (el cliente no se libra de ellas pidiendo 0).
func _defense(attacker: Combatant, victim: Combatant, attack: AttackTicks, view_tick: float,
		defense_tick: float, s: int, sample: StateHistory.Sample) -> int:
	var old_tick: float = minf(view_tick, defense_tick)
	if _was_invulnerable(victim, old_tick, s):
		return Outcome.INVULNERABLE
	var victim_frame: Combatant.Frozen = victim.frozen
	var weapon: WeaponTicks = CombatCatalog.weapon(victim_frame.weapon_id)
	if weapon == null:
		return Outcome.IMPACT
	var attacker_position: Vector3 = attacker.frozen.position
	var cone: float = weapon.block_angle_deg
	# La muestra antigua solo cuenta si el defensor no ha bajado el escudo después: ni por un ataque
	# o una esquiva propios ni porque le hayan impuesto un control.
	var old_sample: StateHistory.Sample = sample
	if old_tick < view_tick:
		old_sample = _sample(victim, old_tick, s)
	var old_counts: bool = old_sample != null and old_tick < float(s) \
			and not _dropped_guard_after(victim_frame, old_tick)
	# Parada (solo contra golpes cuerpo a cuerpo: todos los de la fase 3).
	if _defends(victim_frame, old_sample, old_counts, ActionMachine.DEFENSE_PARRY, cone,
			attacker_position):
		return Outcome.PARRIED
	# Bloqueo: el escudo solo frena el daño físico.
	if DamageFormula.is_physical(attack.damage_type) and _defends(victim_frame, old_sample,
			old_counts, ActionMachine.DEFENSE_BLOCKING, cone, attacker_position):
		return Outcome.BLOCKED
	return Outcome.IMPACT


# true si el defensor tiene la bandera [param flag] en s (muestra congelada) o en view_tick
# (muestra rebobinada, si cuenta), con el atacante dentro del cono frontal en esa muestra.
func _defends(victim_frame: Combatant.Frozen, sample: StateHistory.Sample, old_counts: bool,
		flag: int, cone: float, attacker_position: Vector3) -> bool:
	if (victim_frame.defense & flag) != 0 and HitShapes.is_in_front(victim_frame.position,
			victim_frame.yaw, attacker_position, cone):
		return true
	return old_counts and (sample.flags & flag) != 0 and HitShapes.is_in_front(sample.position,
			sample.yaw, attacker_position, cone)


# true si el defensor, después de view_tick, empezó una acción que baja el escudo: un ataque, una carga
# o una esquiva suyos, o un control que le han impuesto (tambaleo, aturdimiento, muerte). Soltar el
# escudo sin hacer nada más (NONE, que conserva el action_tick del bloqueo) o seguir bloqueando no
# cuenta: ahí la muestra de view_tick sigue siendo lo que el atacante veía.
static func _dropped_guard_after(victim_frame: Combatant.Frozen, view_tick: float) -> bool:
	if float(victim_frame.action_tick) <= view_tick:
		return false
	return victim_frame.action != CombatState.Action.NONE \
			and victim_frame.action != CombatState.Action.BLOCK


# true si el objetivo fue invulnerable en algún tick de [floor(view_tick), s].
func _was_invulnerable(victim: Combatant, view_tick: float, s: int) -> bool:
	if (victim.frozen.defense & ActionMachine.DEFENSE_INVULNERABLE) != 0:
		return true
	for tick: int in range(floori(view_tick), s):
		var flags: int = _history.get_flags(victim.get_id(), tick)
		if flags >= 0 and (flags & ActionMachine.DEFENSE_INVULNERABLE) != 0:
			return true
	return false


# Estado del objetivo en el instante view_tick, o null si no se conoce.
func _sample(victim: Combatant, view_tick: float, s: int) -> StateHistory.Sample:
	var frame: Combatant.Frozen = victim.frozen
	if view_tick >= float(s):
		return frame
	if view_tick <= float(s - 1):
		return _history.sample(victim.get_id(), view_tick)
	# Entre s − 1 y s: interpolación entre la pista de s − 1 y lo congelado.
	var previous: StateHistory.Sample = _history.sample(victim.get_id(), float(s - 1))
	if previous == null:
		return null
	if _teleport_counter(previous.flags) != _teleport_counter(frame.flags):
		return previous
	var fraction: float = view_tick - float(s - 1)
	var result := StateHistory.Sample.new()
	result.position = previous.position.lerp(frame.position, fraction)
	result.yaw = lerp_angle(previous.yaw, frame.yaw, fraction)
	result.flags = previous.flags if fraction < 0.5 else frame.flags
	return result


static func _teleport_counter(flags: int) -> int:
	return (flags >> EntityRecord.TELEPORT_SHIFT) & EntityRecord.TELEPORT_MASK
