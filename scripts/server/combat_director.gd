class_name CombatDirector
extends RefCounted
## El combate de una zona en el servidor (docs/combate.md, secciones 4.2 y 5): lleva un
## [Combatant] por entidad con cuerpo y, una vez por tick, congela, resuelve, aplica y publica.
## [br][br]
## [method process_tick] es el paso «combate» del tick (red.md 8.1, tras simular a todas las
## entidades y antes de las altas, el historial y los snapshots):
## [codeblock]
## congelar    la muestra del tick actual de cada entidad (Combatant.freeze)
## resolver    CombatResolver.resolve: todos los golpes del tick contra lo congelado y el historial
## aplicar     por net_id del atacante y del objetivo: daño, gasto de resistencia del bloqueo,
##             controles (con cadena e inmunidad), paradas y muertes, con sus eventos
## entorno     volúmenes letales, daño por caída, muerte bajo y = -100
## reaparecer  las pedidas (RESPAWN_REQUEST) y las automáticas vencidas
## publicar    protección, regeneración y lo que ven los snapshots (vida, estado, acción)
## [/codeblock]
## Todo estado de combate que impone el servidor pasa por
## [code]PlayerState.decode(PlayerState.encode())[/code] ([method commit_state]), el mismo redondeo
## que sufre en el cliente al reconciliar.
## [br][br]
## No toca la red ni el reloj: avisa de los eventos con [signal event_emitted] (quien llama decide a
## quién se envían) y coloca los cuerpos con el [Callable] [code]place[/code] que le da el servidor.

## Un evento de combate (HIT, DEATH, KILL o RESPAWN) y los net_id de las entidades implicadas
## (víctima, atacante, asesino y asistentes): sus dueños y quien las tenga por relevantes lo reciben.
signal event_emitted(event: NetMessages.EntityEvent, involved: PackedInt32Array)
## Un golpe ha dado en un blanco estático (la puerta de un fuerte) y le ha quitado [param amount] de
## vida en el tick [param tick]: ya se ha emitido su HIT. Lo recoge el [FortressController].
signal structure_hit(target: StructureTarget, attacker: Combatant, amount: int, tick: int)

## Resultado de [method request_respawn].
enum RespawnRequestResult {
	## La petición queda anotada; se ejecuta cuando llegue el momento.
	ACCEPTED,
	## No está muerto (fuera de plazo).
	NOT_DEAD,
	## Está muerto, pero aún falta mucho para poder reaparecer (fuera de plazo).
	TOO_EARLY,
}

## Por debajo de esta altura el personaje muere (cae fuera del mundo).
const VOID_LIMIT_Y: float = -100.0
## Sección de [ServerMetrics] de la resolución de los golpes (forma, línea de visión y rebobinado).
const SECTION_RESOLVE: StringName = &"combat_resolve"
## Bits de [member NetMessages.EntityEvent.hit_flags] que da el director.
const _HIT_CRITICAL: int = NetMessages.EntityEvent.HIT_FLAG_CRITICAL
const _HIT_BLOCKED: int = NetMessages.EntityEvent.HIT_FLAG_BLOCKED
const _HIT_PARRIED: int = NetMessages.EntityEvent.HIT_FLAG_PARRIED
const _HIT_GUARD_BREAK: int = NetMessages.EntityEvent.HIT_FLAG_GUARD_BREAK
const _HIT_LETHAL: int = NetMessages.EntityEvent.HIT_FLAG_LETHAL

## Plazos en ticks (las pruebas los acortan).
var timing: CombatTiming = CombatTiming.from_rules(CombatCatalog.rules())
var resolver: CombatResolver
## Archivo del registro de combate ([code]--combat-log[/code]); null = ninguno.
var combat_log: FileAccess = null
## Medidas del servidor (null = sin medir): el paso de combate mide aparte la resolución de los golpes
## con el rebobinado ([code]combat_resolve[/code]).
var metrics: ServerMetrics = null
## Contadores de la ejecución (para el informe).
var stats: Dictionary[StringName, int] = {
	&"hits": 0, &"blocked": 0, &"parried": 0, &"guard_breaks": 0, &"invulnerable": 0,
	&"criticals": 0, &"rewind_rejected": 0, &"damage": 0, &"deaths": 0, &"kills": 0,
	&"respawns": 0, &"falls": 0, &"lethal_volumes": 0, &"voids": 0, &"events": 0,
	&"hit_tests": 0, &"resolve_us": 0, &"resolve_busy_ticks": 0, &"gate_hits": 0, &"gate_damage": 0,
}
## [code]() -> Dictionary[/code]: los [FortressState] vivos por id de fortaleza, para decidir qué puntos
## de reaparición valen ([method RespawnRules.points_for]). Sin esto no hay fortalezas.
var fortress_states: Callable = Callable()

var _history: StateHistory
var _zone_id: StringName
var _world: Node3D
var _place: Callable
var _pick_spawn: Callable
var _combatants: Dictionary[int, Combatant] = {}
var _sorted: Array[Combatant] = []
var _sorted_dirty: bool = false
# La lista estática de puntos de reaparición de la zona (todos, en el orden de la escena), leída la
# primera vez.
var _all_respawn_points: Array[Node3D] = []
var _respawn_points_loaded: bool = false


## [param history] es el historial del servidor, [param zone_id] la zona, [param world] su raíz
## (para los volúmenes letales y los puntos de reaparición) y [param safe_areas] sus zonas seguras.
## [param place] es
## [code](entity: NetEntity, position: Vector3, yaw: float) -> void] (coloca un cuerpo y sube su
## contador de teletransporte) y [param pick_spawn] [code](realm: int) -> Transform3D] (un punto de
## aparición del reino).
func _init(history: StateHistory, zone_id: StringName, world: Node3D, safe_areas: SafeAreas,
		place: Callable, pick_spawn: Callable) -> void:
	_history = history
	_zone_id = zone_id
	_world = world
	_place = place
	_pick_spawn = pick_spawn
	resolver = CombatResolver.new(history, zone_id, safe_areas)


## Redondea el estado de [param character] como lo haría el cliente al reconciliar (pasa por
## [code]encode/decode[/code]). Hay que llamarla tras cambiar el [member PlayerCharacter.combat] desde
## fuera de la simulación.
static func commit_state(character: PlayerCharacter) -> void:
	character.set_state(PlayerState.decode(character.get_state().encode()))


# --- Altas y bajas ----------------------------------------------------------------------------

## Da de alta el combate de [param entity] (con un [PlayerCharacter] de nodo), su cola de entradas
## y su peer (null si no es un jugador de red). Aparece con la vida máxima.
func add(entity: NetEntity, queue: InputQueue, peer: ServerPeer) -> Combatant:
	var combatant := Combatant.new(entity, queue, peer, timing, CombatCatalog.rules().health_max)
	_combatants[entity.net_id] = combatant
	_sorted_dirty = true
	return combatant


## Da de baja a [param net_id] y borra su rastro de los registros de daño de los demás (su id puede
## reutilizarse).
func remove(net_id: int) -> void:
	if not _combatants.erase(net_id):
		return
	_sorted_dirty = true
	for other: Combatant in _combatants.values():
		other.ledger.forget_attacker(net_id)
		if other.last_enemy_id == net_id:
			other.last_enemy_id = 0


## Da de baja a todos (cierre del servidor).
func clear() -> void:
	_combatants.clear()
	_sorted.clear()
	_sorted_dirty = false


## El combate de [param net_id], o null.
func get_combatant(net_id: int) -> Combatant:
	return _combatants.get(net_id)


## Todos los combatientes por net_id ascendente (el array se sustituye cuando cambia el conjunto).
func get_sorted() -> Array[Combatant]:
	if _sorted_dirty:
		var ids: Array[int] = []
		ids.assign(_combatants.keys())
		ids.sort()
		var rebuilt: Array[Combatant] = []
		for net_id: int in ids:
			rebuilt.append(_combatants[net_id])
		_sorted = rebuilt
		_sorted_dirty = false
	return _sorted


func size() -> int:
	return _combatants.size()


# --- El tick ----------------------------------------------------------------------------------

## El paso de combate del tick [param s]: congela, resuelve, aplica, entorno, reapariciones y
## publicación. [param space] es el espacio de física del mundo (línea de visión).
func process_tick(s: int, space: PhysicsDirectSpaceState3D) -> void:
	var list: Array[Combatant] = get_sorted()
	if list.is_empty():
		return
	for combatant: Combatant in list:
		combatant.freeze(s)
		_count_swing(combatant)
	if metrics != null:
		metrics.begin_section(SECTION_RESOLVE)
	var tests_before: int = resolver.tests
	var resolve_started: int = Time.get_ticks_usec()
	var hits: Array[CombatResolver.Hit] = resolver.resolve(s, list, space)
	if resolver.tests > tests_before:
		# Solo cuentan los ticks en los que hubo algún golpe que probar: es lo que cuesta cada comprobación.
		stats[&"resolve_us"] += Time.get_ticks_usec() - resolve_started
		stats[&"resolve_busy_ticks"] += 1
	if metrics != null:
		metrics.end_section(SECTION_RESOLVE)
	stats[&"hit_tests"] = resolver.tests
	for hit: CombatResolver.Hit in hits:
		_apply_hit(hit, s)
	_process_environment(s, list)
	_process_respawns(s, list)
	var regen: int = CombatCatalog.rules().health_regen_per_s
	for combatant: Combatant in list:
		if combatant.is_protected(s) and _started_attack(combatant):
			# Atacar pierde la protección de reaparición.
			combatant.protected_until = s
		combatant.regenerate(s, regen)
		combatant.publish(s)


# --- Acciones desde fuera de la simulación -----------------------------------------------------

## Mata a [param combatant] ahora (comando de depuración, caída...) sin autor. No hace nada si ya
## está muerto o es un maniquí. [param tick] es el tick en el que se anota la muerte.
func kill(combatant: Combatant, tick: int) -> void:
	if combatant.is_dead() or combatant.immortal:
		return
	_die(combatant, tick, 0, 0)


## Cura del todo a [param combatant] (comando de depuración).
func heal(combatant: Combatant) -> void:
	if combatant.is_alive():
		combatant.heal_full()


## Pone o quita la resistencia infinita de [param combatant] (comando de depuración).
func set_infinite_stamina(combatant: Combatant, enabled: bool) -> void:
	var character: PlayerCharacter = combatant.get_character()
	if enabled:
		character.combat.combat_flags |= CombatState.FLAG_INFINITE_STAMINA
	else:
		character.combat.combat_flags &= ~CombatState.FLAG_INFINITE_STAMINA
	commit_state(character)


## Cambia el arma equipada de [param combatant] (comando de depuración) por la del catálogo
## [param weapon_id]. Devuelve false si no existe.
func set_weapon(combatant: Combatant, weapon_id: int) -> bool:
	if CombatCatalog.weapon(weapon_id) == null:
		return false
	var character: PlayerCharacter = combatant.get_character()
	character.combat.weapon_id = weapon_id
	commit_state(character)
	return true


## Anota una petición de reaparición de [param net_id] en el punto [param point_index] de la lista
## estática de la zona ([method get_all_respawn_points]), pedida cuando el servidor va a simular el tick
## [param tick]. Un índice que ya no vale para su reino no es un error: al reaparecer se usa el primer
## campamento válido (el estado del cliente va atrasado). Devuelve si se acepta o por qué está fuera de
## plazo.
func request_respawn(net_id: int, point_index: int, tick: int) -> int:
	var combatant: Combatant = _combatants.get(net_id)
	if combatant == null or combatant.is_alive():
		return RespawnRequestResult.NOT_DEAD
	if tick + CombatTiming.RESPAWN_REQUEST_SLACK_TICKS < combatant.respawn_tick:
		return RespawnRequestResult.TOO_EARLY
	combatant.pending_respawn_point = point_index
	return RespawnRequestResult.ACCEPTED


## Pone los blancos estáticos de la zona (las puertas de los fuertes): el resolutor los prueba para
## cada ataque activo.
func set_structure_targets(targets: Array[StructureTarget]) -> void:
	resolver.structure_targets = targets


## Todos los puntos de reaparición de la zona, en el orden de la escena ([method
## NetZones.get_all_respawn_points]): la lista [b]estática[/b] sobre la que va el índice de
## RESPAWN_REQUEST y RESPAWN. Qué puntos valen para un jugador lo dice [method get_valid_respawn_points].
func get_all_respawn_points() -> Array[Node3D]:
	if not _respawn_points_loaded:
		_all_respawn_points = NetZones.get_all_respawn_points(_world)
		_respawn_points_loaded = true
	return _all_respawn_points


## Índices (de la lista estática) de los puntos en los que puede reaparecer un jugador del reino
## [param realm] en el tick [param tick] ([method RespawnRules.points_for]): su campamento y las
## fortalezas de su reino en GARRISONED que no estén atacadas.
func get_valid_respawn_points(realm: int, tick: int) -> PackedInt32Array:
	var states: Dictionary = {}
	if fortress_states.is_valid():
		states = fortress_states.call()
	return RespawnRules.points_for(realm, get_all_respawn_points(), states, tick)


# --- Aplicar los golpes -----------------------------------------------------------------------

func _apply_hit(hit: CombatResolver.Hit, s: int) -> void:
	var attacker: Combatant = hit.attacker
	if hit.outcome == CombatResolver.Outcome.REWIND_REJECTED:
		stats[&"rewind_rejected"] += 1
		_log_hit(s, hit, "rewind_rejected", 0)
		return
	if hit.outcome == CombatResolver.Outcome.STRUCTURE:
		_apply_structure_hit(hit, s)
		return
	var victim: Combatant = hit.victim
	if hit.outcome == CombatResolver.Outcome.INVULNERABLE:
		stats[&"invulnerable"] += 1
		_log_hit(s, hit, "invulnerable", 0)
		return
	if victim.is_dead():
		# Murió antes en este mismo tick (otro golpe simultáneo): su turno ya pasó.
		return
	_note_landed(attacker)
	attacker.mark_combat(s)
	victim.mark_combat(s)
	if hit.outcome == CombatResolver.Outcome.PARRIED:
		_apply_parry(hit, s)
		return
	_apply_impact(hit, s)


# Golpe a la puerta de un fuerte (docs/fuerte.md, 3.3): daño de la fórmula (sin crítico ni defensa) por el
# multiplicador contra estructuras de su tipo de daño, mínimo 1 si queda algo, sin pasar de la vida que le
# queda. HIT con el net_id de la fortaleza para el atacante (y quien lo tenga por relevante); el atacante
# queda «en combate».
func _apply_structure_hit(hit: CombatResolver.Hit, s: int) -> void:
	var attacker: Combatant = hit.attacker
	var target: StructureTarget = hit.structure
	var attack: AttackTicks = hit.attack
	if not target.can_be_hit_by(attacker.get_realm()):
		# La rompió otro golpe de este mismo tick, o el fuerte cambió de manos.
		return
	var rules: CombatRules = CombatCatalog.rules()
	var result: DamageFormula.Result = DamageFormula.compute(attack.base_damage,
			attacker.frozen.charge_ticks, attack.charge_min_ticks, attack.charge_max_ticks,
			attack.charge_damage_scale, false, false, 0.0, 0.0, 0, 0, rules.crit_multiplier)
	var scaled: int = roundi(float(result.damage) * rules.structure_multiplier(attack.damage_type))
	if result.damage > 0:
		scaled = maxi(scaled, 1)
	var health_before: int = target.state.gate_health
	var applied: int = mini(scaled, health_before)
	if applied <= 0:
		return
	_note_landed(attacker)
	attacker.mark_combat(s)
	stats[&"gate_hits"] += 1
	stats[&"gate_damage"] += applied
	var flags: int = _HIT_LETHAL if applied >= health_before else 0
	_emit(NetMessages.EntityEvent.hit(target.net_id, s, attacker.get_id(), applied,
			attack.damage_type, flags, attack.id), _ids([attacker.get_id()]))
	structure_hit.emit(target, attacker, applied, s)
	_log_hit(s, hit, "gate", applied)


# Parada: sin daño y el atacante queda tambaleándose.
func _apply_parry(hit: CombatResolver.Hit, s: int) -> void:
	var attacker: Combatant = hit.attacker
	var victim: Combatant = hit.victim
	stats[&"parried"] += 1
	if attacker.is_alive() and attacker.try_control(s):
		var character: PlayerCharacter = attacker.get_character()
		ActionMachine.impose_stagger(character.combat, s, s + timing.parry_stagger, Vector2.ZERO)
		commit_state(character)
	_emit(NetMessages.EntityEvent.hit(victim.get_id(), s, attacker.get_id(), 0,
			hit.attack.damage_type, _HIT_PARRIED, hit.attack.id),
			_ids([victim.get_id(), attacker.get_id()]))
	_log_hit(s, hit, "parried", 0)


# Impacto, con o sin bloqueo.
func _apply_impact(hit: CombatResolver.Hit, s: int) -> void:
	var attacker: Combatant = hit.attacker
	var victim: Combatant = hit.victim
	var attack: AttackTicks = hit.attack
	var rules: CombatRules = CombatCatalog.rules()
	var blocked: bool = hit.outcome == CombatResolver.Outcome.BLOCKED
	var victim_character: PlayerCharacter = victim.get_character()
	var weapon: WeaponTicks = CombatCatalog.weapon(victim.frozen.weapon_id)
	var result: DamageFormula.Result = DamageFormula.compute(attack.base_damage,
			attacker.frozen.charge_ticks, attack.charge_min_ticks, attack.charge_max_ticks,
			attack.charge_damage_scale, hit.critical, blocked,
			weapon.block_mitigation if blocked else 0.0,
			weapon.block_stamina_per_damage if blocked else 0.0,
			victim_character.combat.stamina, 0, rules.crit_multiplier)
	var applied: int = victim.take_damage(result.damage, s)
	victim.ledger.record(s, attacker.get_id(), applied)
	victim.note_enemy_hit(attacker.get_id(), attack.id, s)
	var flags: int = 0
	if hit.critical:
		flags |= _HIT_CRITICAL
		stats[&"criticals"] += 1
	var changed: bool = false
	if blocked:
		flags |= _HIT_BLOCKED
		stats[&"blocked"] += 1
		if result.stamina_cost > 0:
			ActionMachine.drain_stamina(victim_character.combat, result.stamina_cost, s)
			changed = true
		if result.guard_break:
			flags |= _HIT_GUARD_BREAK
			stats[&"guard_breaks"] += 1
			if victim.is_alive() and victim.try_control(s):
				ActionMachine.impose_stun(victim_character.combat, s, s + timing.guard_break_stun)
				changed = true
	else:
		changed = _apply_hit_controls(hit, s)
	stats[&"hits"] += 1
	stats[&"damage"] += applied
	var lethal: bool = victim.is_dead()
	if lethal:
		flags |= _HIT_LETHAL
	# Un maniquí inmortal anuncia el daño completo (el medidor de DPS lo cuenta entero).
	var amount: int = result.damage if victim.immortal else applied
	_emit(NetMessages.EntityEvent.hit(victim.get_id(), s, attacker.get_id(), amount,
			attack.damage_type, flags, attack.id), _ids([victim.get_id(), attacker.get_id()]))
	_log_hit(s, hit, "guard_break" if (flags & _HIT_GUARD_BREAK) != 0
			else ("blocked" if blocked else "hit"), amount)
	if lethal:
		_die(victim, s, attacker.get_id(), attack.id)
	elif changed:
		commit_state(victim_character)


# Tambaleo y empuje del golpe, salvo con entereza en el golpe activo y respetando la cadena. Devuelve
# true si ha impuesto el control (y hay que pasar el estado por encode/decode).
func _apply_hit_controls(hit: CombatResolver.Hit, s: int) -> bool:
	var victim: Combatant = hit.victim
	var attack: AttackTicks = hit.attack
	if attack.stagger_ticks <= 0 or victim.is_dead() or victim.frozen.hyper_armor:
		return false
	if not victim.try_control(s):
		return false
	var away := Vector2(victim.frozen.position.x - hit.attacker.frozen.position.x,
			victim.frozen.position.z - hit.attacker.frozen.position.z)
	var knockback := Vector2.ZERO
	if attack.knockback_speed > 0.0 and away.length() > 0.0001:
		knockback = away.normalized() * attack.knockback_speed
	ActionMachine.impose_stagger(victim.get_character().combat, s, s + attack.stagger_ticks,
			knockback)
	return true


# --- Muerte -----------------------------------------------------------------------------------

# Muerte de [param victim] por [param killer_id] (0 = el entorno) con [param attack_id]: acción
# DEAD, una sola DEATH y, si hay autor, un KILL con los asistentes del registro de daño.
func _die(victim: Combatant, s: int, killer_id: int, attack_id: int) -> void:
	if victim.immortal or victim.death_tick >= 0:
		return
	victim.mark_dead(s, killer_id, attack_id)
	var character: PlayerCharacter = victim.get_character()
	ActionMachine.impose_death(character.combat, s)
	commit_state(character)
	stats[&"deaths"] += 1
	var victim_id: int = victim.get_id()
	_emit(NetMessages.EntityEvent.death(victim_id, s, killer_id, attack_id),
			_ids([victim_id, killer_id]))
	if killer_id != 0:
		var assistants: PackedInt32Array = victim.ledger.get_assistants(killer_id, s)
		var involved: Array[int] = [victim_id, killer_id]
		for assistant: int in assistants:
			involved.append(assistant)
		stats[&"kills"] += 1
		_emit(NetMessages.EntityEvent.kill(victim_id, s, killer_id, attack_id, assistants),
				_ids(involved))


# Muerte o daño del entorno: el autor es el último enemigo que golpeó en los últimos 10 s.
func _credited_killer(victim: Combatant, s: int) -> int:
	if not victim.has_recent_enemy(s):
		return 0
	var enemy: Combatant = _combatants.get(victim.last_enemy_id)
	return victim.last_enemy_id if enemy != null else 0


# --- Entorno ----------------------------------------------------------------------------------

func _process_environment(s: int, list: Array[Combatant]) -> void:
	var rules: CombatRules = CombatCatalog.rules()
	var volumes: Array[Node3D] = NetZones.get_lethal_volumes(_world)
	for combatant: Combatant in list:
		if combatant.is_dead() or combatant.immortal:
			continue
		var character: PlayerCharacter = combatant.get_character()
		if _in_lethal_volume(character, volumes):
			stats[&"lethal_volumes"] += 1
			_die(combatant, s, _credited_killer(combatant, s), 0)
			continue
		var position: Vector3 = combatant.entity.get_position()
		if not position.is_finite() or position.y < VOID_LIMIT_Y:
			stats[&"voids"] += 1
			_die_in_the_void(combatant, s)
			continue
		var speed: float = character.last_landing_speed
		if speed > rules.fall_damage_threshold:
			_apply_fall(combatant, s, roundi((speed - rules.fall_damage_threshold)
					* float(rules.fall_damage_per_mps)))


func _in_lethal_volume(character: PlayerCharacter, volumes: Array[Node3D]) -> bool:
	for node: Node3D in volumes:
		var area: Area3D = node as Area3D
		if area != null and area.monitoring and area.overlaps_body(character):
			return true
	return false


# Muerte bajo el límite del mundo: DEAD y el cuerpo vuelve a un punto de aparición de su reino (con
# contador de teletransporte) y se queda ahí, sin velocidad, hasta reaparecer.
func _die_in_the_void(combatant: Combatant, s: int) -> void:
	var killer: int = _credited_killer(combatant, s)
	var character: PlayerCharacter = combatant.get_character()
	combatant.mark_dead(s, killer, 0)
	ActionMachine.impose_death(character.combat, s)
	stats[&"deaths"] += 1
	var spawn: Transform3D = _pick_spawn.call(combatant.get_realm())
	_place.call(combatant.entity, spawn.origin, _yaw_of(spawn))
	var victim_id: int = combatant.get_id()
	_emit(NetMessages.EntityEvent.death(victim_id, s, killer, 0), _ids([victim_id, killer]))
	if killer != 0:
		var assistants: PackedInt32Array = combatant.ledger.get_assistants(killer, s)
		var involved: Array[int] = [victim_id, killer]
		for assistant: int in assistants:
			involved.append(assistant)
		stats[&"kills"] += 1
		_emit(NetMessages.EntityEvent.kill(victim_id, s, killer, 0, assistants), _ids(involved))


# Daño por caída: HIT del entorno (atacante 0); si mata, la muerte se acredita al último enemigo.
func _apply_fall(combatant: Combatant, s: int, damage: int) -> void:
	if damage <= 0:
		return
	var applied: int = combatant.take_damage(damage, s)
	combatant.mark_combat(s)
	stats[&"falls"] += 1
	stats[&"damage"] += applied
	var lethal: bool = combatant.is_dead()
	_emit(NetMessages.EntityEvent.hit(combatant.get_id(), s, 0, applied, DamageFormula.DamageType.BLUNT,
			_HIT_LETHAL if lethal else 0, 0), _ids([combatant.get_id()]))
	if lethal:
		_die(combatant, s, _credited_killer(combatant, s), 0)


# --- Reaparición ------------------------------------------------------------------------------

func _process_respawns(s: int, list: Array[Combatant]) -> void:
	for combatant: Combatant in list:
		if combatant.is_alive() or combatant.death_tick < 0:
			continue
		var requested: bool = combatant.pending_respawn_point >= 0 and s >= combatant.respawn_tick
		var automatic: bool = s >= combatant.death_tick + timing.auto_respawn
		if requested or automatic:
			_respawn(combatant, combatant.pending_respawn_point if requested else 0, s)


# Reaparece a [param combatant] en el punto [param point_index] de la lista estática de la zona: si ya no
# vale para su reino (un campamento ajeno, una fortaleza que ha cambiado de manos, en combate o en otra
# fase), en el primer campamento válido de su reino, sin aviso; y, si la zona no tiene puntos para su
# reino, en un punto de aparición. Estado de combate nuevo, vida llena, protección, teletransporte con
# contador y evento RESPAWN.
func _respawn(combatant: Combatant, point_index: int, s: int) -> void:
	var points: Array[Node3D] = get_all_respawn_points()
	var valid: PackedInt32Array = get_valid_respawn_points(combatant.get_realm(), s)
	var index: int = point_index
	if not valid.has(index):
		index = _first_camp_point(valid, points)
	var position: Vector3
	var yaw: float
	if index < 0:
		var spawn: Transform3D = _pick_spawn.call(combatant.get_realm())
		position = spawn.origin
		yaw = _yaw_of(spawn)
		index = 0
	else:
		var transform: Transform3D = points[index].global_transform
		position = transform.origin
		yaw = _yaw_of(transform)
	var character: PlayerCharacter = combatant.get_character()
	ActionMachine.reset_for_respawn(character.combat, s)
	combatant.mark_respawned(s)
	# _place pasa el estado (con el combate ya reiniciado) por encode/decode.
	_place.call(combatant.entity, position, yaw)
	stats[&"respawns"] += 1
	_emit(NetMessages.EntityEvent.respawn(combatant.get_id(), s, index),
			_ids([combatant.get_id()]))


# El primer punto válido que es un campamento (lleva el metadato de reino), o -1 si no hay ninguno.
static func _first_camp_point(valid: PackedInt32Array, points: Array[Node3D]) -> int:
	for index: int in valid:
		if points[index].has_meta(NetZones.realm_meta()):
			return index
	return -1


# --- Utilidades -------------------------------------------------------------------------------

# Cuenta como ataque lanzado el tick en que empieza un ligero o un fuerte.
func _count_swing(combatant: Combatant) -> void:
	var frame: Combatant.Frozen = combatant.frozen
	if combatant.peer == null:
		return
	if (frame.action == CombatState.Action.LIGHT or frame.action == CombatState.Action.HEAVY) \
			and frame.action_tick == frame.tick:
		combatant.peer.swings += 1


# Un ataque (o su carga) ha acertado, fallado o sido parado: cuenta como acierto del peer una vez
# por ataque.
func _note_landed(attacker: Combatant) -> void:
	if attacker.peer != null and not attacker.swing_landed:
		attacker.peer.swings_landed += 1
	attacker.swing_landed = true


func _started_attack(combatant: Combatant) -> bool:
	var action: int = combatant.frozen.action
	return action == CombatState.Action.LIGHT or action == CombatState.Action.HEAVY \
			or action == CombatState.Action.CHARGE


func _emit(event: NetMessages.EntityEvent, involved: PackedInt32Array) -> void:
	stats[&"events"] += 1
	event_emitted.emit(event, involved)


static func _ids(ids: Array[int]) -> PackedInt32Array:
	var result := PackedInt32Array()
	for net_id: int in ids:
		if net_id > 0 and not result.has(net_id):
			result.append(net_id)
	return result


# Yaw (convención de Node3D.rotation.y) hacia el que mira una base.
static func _yaw_of(transform: Transform3D) -> float:
	var forward: Vector3 = -transform.basis.z
	return atan2(-forward.x, -forward.z)


# Una línea del registro de combate: tick, atacante, objetivo, ataque, view_tick, rebobinado,
# resultado y daño.
func _log_hit(s: int, hit: CombatResolver.Hit, result: String, damage: int) -> void:
	if combat_log == null:
		return
	var target_id: int = 0
	if hit.victim != null:
		target_id = hit.victim.get_id()
	elif hit.structure != null:
		target_id = hit.structure.net_id
	combat_log.store_line("%d,%d,%d,%s,%.2f,%.2f,%s,%d" % [s, hit.attacker.get_id(),
			target_id, hit.attack.name, hit.view_tick,
			hit.rewind, result, damage])
