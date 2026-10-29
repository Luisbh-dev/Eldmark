class_name CombatDirector
extends RefCounted
## El combate de una zona en el servidor (docs/combate.md, secciones 4.2 y 5): lleva un
## [Combatant] por entidad con cuerpo y, una vez por tick, congela, resuelve, aplica y publica.
## [br][br]
## [method process_tick] es el paso «combate» del tick (red.md 8.1, tras simular a todas las
## entidades y antes de las altas, el historial y los snapshots), con los pasos 2 a 9 del orden de
## docs/habilidades.md, sección 4.1 (que completa docs/fuerte.md, 1.7):
## [codeblock]
## 2 congelar    la muestra del tick actual de cada entidad (Combatant.freeze): posición, giro, defensa,
##               acción, golpe activo (ataque o habilidad), compromiso y caja del muro
## 3 propios     quien está en su compromiso, por net_id: efecto propio (self_status) y curación propia
##               (HEAL) de su habilidad; los proyectiles nuevos son de H3b
## 4 resolver    CombatResolver.resolve: todos los golpes de ataques y habilidades del tick contra lo
##               congelado y el historial, y las puertas (el vuelo de los proyectiles, H3b)
## 5 aplicar     por net_id del atacante y del objetivo: daño (con los modificadores de los efectos),
##               gasto de resistencia del bloqueo (el del muro es el de las reglas), controles (con cadena
##               e inmunidad), efectos al objetivo, interrupciones, paradas y muertes, con sus eventos
## 6 efectos     StatusSystem.step: pulsos (reunidos antes de aplicarlos) y caducidades
## 7 derribado   (H3c)
## 8 entorno     volúmenes letales, daño por caída, muerte bajo y = -100; reapariciones pedidas
##               (RESPAWN_REQUEST) y automáticas vencidas (la recarga del campamento, H3c)
## 9 publicar    protección, regeneración y lo que ven los snapshots (vida, estado, acción)
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
const _HIT_INTERRUPTED: int = NetMessages.EntityEvent.HIT_FLAG_INTERRUPTED

## Plazos en ticks (las pruebas los acortan).
var timing: CombatTiming = CombatTiming.from_rules(CombatCatalog.rules())
var resolver: CombatResolver
## Efectos de estado de la zona (docs/habilidades.md, sección 4.3): sus eventos salen por
## [signal event_emitted] y sus pulsos de daño los aplica el director.
var status: StatusSystem = StatusSystem.new()
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
	&"interrupts": 0, &"pulse_hits": 0, &"heals": 0,
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
	status.event_emitted.connect(_emit)
	status.pulse_damage.connect(_apply_pulse)


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


## Da de baja a [param net_id] en el tick [param tick] y borra su rastro de los registros de daño de los
## demás (su id puede reutilizarse). Los efectos que puso a otros se quitan con STATUS 2 en ese tick
## (docs/habilidades.md, sección 4.1); sus flechas en el aire, con H3b.
func remove(net_id: int, tick: int) -> void:
	var leaving: Combatant = _combatants.get(net_id)
	if leaving == null:
		return
	_combatants.erase(net_id)
	_sorted_dirty = true
	leaving.effects.clear()
	status.forget_author(net_id, tick, get_sorted())
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

## El paso de combate del tick [param s] (pasos 2 a 9 de docs/habilidades.md, sección 4.1): congela,
## efectos propios del compromiso, resuelve, aplica, efectos de estado, entorno, reapariciones y
## publicación. [param space] es el espacio de física del mundo (línea de visión).
func process_tick(s: int, space: PhysicsDirectSpaceState3D) -> void:
	var list: Array[Combatant] = get_sorted()
	if list.is_empty():
		return
	# Paso 2: congelar.
	var committing: Array[Combatant] = []
	for combatant: Combatant in list:
		combatant.freeze(s)
		_count_swing(combatant)
		if combatant.frozen.commit:
			committing.append(combatant)
	# Paso 3: disparos y efectos propios de quien está en su compromiso (los proyectiles, H3b).
	if not committing.is_empty():
		_process_commits(s, committing)
	# Paso 4: resolver (el vuelo de los proyectiles, H3b).
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
	# Paso 5: aplicar, por net_id del atacante y del objetivo.
	for hit: CombatResolver.Hit in hits:
		_apply_hit(hit, s)
	# Paso 6: efectos de estado (pulsos y caducidades).
	status.step(s, list)
	# Paso 7: derribado (H3c).
	# Paso 8: entorno y reapariciones (la recarga de consumibles en el campamento, H3c).
	_process_environment(s, list)
	_process_respawns(s, list)
	# Paso 9: publicar.
	var regen: int = CombatCatalog.rules().health_regen_per_s
	for combatant: Combatant in list:
		if combatant.is_protected(s) and _started_attack(combatant):
			# Atacar (o lanzar una habilidad) pierde la protección de reaparición.
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


## Quita o devuelve las reutilizaciones y el gasto de cargas de [param combatant] (comando 13
## [code]cooldowns_off[/code]: bit 7 de [member CombatState.combat_flags2]).
func set_cooldowns_off(combatant: Combatant, enabled: bool) -> void:
	var character: PlayerCharacter = combatant.get_character()
	if enabled:
		character.combat.combat_flags2 |= CombatState.FLAG2_NO_COOLDOWNS
	else:
		character.combat.combat_flags2 &= ~CombatState.FLAG2_NO_COOLDOWNS
	commit_state(character)


## Aplica a [param combatant] el efecto [param status_id] del catálogo en el tick [param tick], sin autor,
## durante [param duration_ticks] ticks (0 = los del dato): el comando 14 [code]apply_status[/code].
## Devuelve false si el efecto no existe o está muerto.
func apply_status(combatant: Combatant, status_id: int, tick: int, duration_ticks: int = 0) -> bool:
	if CombatCatalog.status(status_id) == null or combatant.is_dead():
		return false
	return status.apply(combatant, status_id, 0, tick, duration_ticks)


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


## Emite un evento que no sale del combate propiamente dicho (el aviso [code]TELEGRAPH[/code] de un ataque fuerte
## de un PNJ) por el mismo canal que los demás: [signal event_emitted], con [param involved] como destinatarios.
func emit_event(event: NetMessages.EntityEvent, involved: PackedInt32Array) -> void:
	_emit(event, involved)


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


# Impacto, con o sin bloqueo. El golpe de una habilidad ([member AbilityTicks.hit]) sigue el mismo
# camino que un ataque (docs/habilidades.md, sección 4.2): su id es la fuente de la habilidad.
func _apply_impact(hit: CombatResolver.Hit, s: int) -> void:
	var attacker: Combatant = hit.attacker
	var victim: Combatant = hit.victim
	var attack: AttackTicks = hit.attack
	var rules: CombatRules = CombatCatalog.rules()
	var blocked: bool = hit.outcome == CombatResolver.Outcome.BLOCKED
	var victim_character: PlayerCharacter = victim.get_character()
	var weapon: WeaponTicks = CombatCatalog.weapon(victim.frozen.weapon_id)
	var mitigation: float = 0.0
	var stamina_per_damage: float = 0.0
	if blocked:
		mitigation = weapon.block_mitigation if weapon != null else 1.0
		# El muro de escudos gasta lo de las reglas, no lo del arma.
		stamina_per_damage = rules.ability_block_stamina_per_damage if hit.wide_block \
				else weapon.block_stamina_per_damage
	var result: DamageFormula.Result = DamageFormula.compute(attack.base_damage,
			attacker.frozen.charge_ticks, attack.charge_min_ticks, attack.charge_max_ticks,
			attack.charge_damage_scale, hit.critical, blocked, mitigation, stamina_per_damage,
			victim_character.combat.stamina, 0, rules.crit_multiplier,
			status.damage_scale(attacker), status.mitigation_penalty(victim))
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
	# Interrupción (docs/habilidades.md, sección 4.2): un impacto con daño de un hostil corta beber, un
	# lanzamiento marcado, levantar o rematar, si el golpe no ha impuesto ya un control.
	if not lethal and not changed and hit.outcome == CombatResolver.Outcome.IMPACT and amount > 0 \
			and _interrupt(victim_character.combat, s):
		flags |= _HIT_INTERRUPTED
		changed = true
	_emit(NetMessages.EntityEvent.hit(victim.get_id(), s, attacker.get_id(), amount,
			attack.damage_type, flags, attack.id), _ids([victim.get_id(), attacker.get_id()]))
	_log_hit(s, hit, "guard_break" if (flags & _HIT_GUARD_BREAK) != 0
			else ("blocked" if blocked else "hit"), amount)
	if lethal:
		_die(victim, s, attacker.get_id(), attack.id)
		return
	if changed:
		commit_state(victim_character)
	# El efecto del golpe al objetivo, solo en un impacto.
	if hit.outcome == CombatResolver.Outcome.IMPACT and attack.on_hit_status_id != 0:
		status.apply(victim, attack.on_hit_status_id, attacker.get_id(), s)


# Control del golpe, salvo con entereza en el golpe activo y respetando la cadena: aturdimiento si el
# golpe lo lleva ([member AttackTicks.stun_ticks], el golpe de escudo) y, si no, tambaleo y empuje
# radial. Devuelve true si ha impuesto el control (y hay que pasar el estado por encode/decode).
func _apply_hit_controls(hit: CombatResolver.Hit, s: int) -> bool:
	var victim: Combatant = hit.victim
	var attack: AttackTicks = hit.attack
	if attack.stagger_ticks <= 0 and attack.stun_ticks <= 0:
		return false
	if victim.is_dead() or victim.frozen.hyper_armor:
		return false
	if not victim.try_control(s):
		return false
	var combat: CombatState = victim.get_character().combat
	if attack.stun_ticks > 0:
		ActionMachine.impose_stun(combat, s, s + attack.stun_ticks)
		return true
	var away := Vector2(victim.frozen.position.x - hit.attacker.frozen.position.x,
			victim.frozen.position.z - hit.attacker.frozen.position.z)
	var knockback := Vector2.ZERO
	if attack.knockback_speed > 0.0 and away.length() > 0.0001:
		knockback = away.normalized() * attack.knockback_speed
	ActionMachine.impose_stagger(combat, s, s + attack.stagger_ticks, knockback)
	return true


# Corta lo que [param combat] hace en [param s] si un impacto lo interrumpe: la fase 0 (el lanzamiento,
# [code][0, cast)[/code]) de un consumible o de una habilidad con [member AbilityTicks.interrupt_on_damage],
# REVIVE o EXECUTE. Tras el compromiso ya no: la carga y la curación ya están puestas. Devuelve true si
# ha interrumpido.
func _interrupt(combat: CombatState, s: int) -> bool:
	if not is_interruptible(combat, s):
		return false
	ActionMachine.impose_interrupt(combat, s)
	stats[&"interrupts"] += 1
	return true


## true si un impacto con daño de un hostil cortaría lo que hace [param combat] en [param tick]
## (docs/habilidades.md, sección 4.2): el lanzamiento de un consumible o de una habilidad con
## [member AbilityTicks.interrupt_on_damage], levantar o rematar.
static func is_interruptible(combat: CombatState, tick: int) -> bool:
	match combat.action:
		CombatState.Action.REVIVE, CombatState.Action.EXECUTE:
			return true
		CombatState.Action.ABILITY:
			var ability: AbilityTicks = CombatCatalog.ability(combat.action_id)
			return ability != null and (ability.is_consumable() or ability.interrupt_on_damage) \
					and tick - combat.action_tick < ability.cast_ticks
	return false


# --- Efectos de estado ------------------------------------------------------------------------

# Paso 3, sobre quien está en su compromiso ([param list], por net_id): el de una habilidad (el primer
# tick activo) se pone su efecto propio ([member AbilityTicks.self_status_id], la curación de la poción) y
# se cura [member AbilityTicks.self_heal]. Una vez: el compromiso cae en un solo tick.
func _process_commits(s: int, list: Array[Combatant]) -> void:
	for combatant: Combatant in list:
		var frame: Combatant.Frozen = combatant.frozen
		if not frame.commit or frame.action != CombatState.Action.ABILITY or combatant.is_dead():
			continue
		var ability: AbilityTicks = CombatCatalog.ability(frame.action_id)
		if ability == null:
			continue
		if ability.self_status_id != 0:
			status.apply(combatant, ability.self_status_id, combatant.get_id(), s)
		if ability.self_heal > 0:
			if status.heal(combatant, combatant.get_id(), ability.self_heal,
					CombatSource.make(CombatSource.Kind.ABILITY, ability.id), s) > 0:
				stats[&"heals"] += 1


# Un pulso de daño en el tiempo ([signal StatusSystem.pulse_damage]): HIT con la fuente del efecto y el
# autor del efecto como atacante, sin bloqueo ni crítico, con el más daño del autor. Puede matar (H3c:
# derribar); no interrumpe ni impone controles.
func _apply_pulse(target: Combatant, author_id: int, effect: StatusTicks, amount: int, s: int) -> void:
	if target.is_dead():
		return
	var author: Combatant = _combatants.get(author_id) if author_id > 0 else null
	var rules: CombatRules = CombatCatalog.rules()
	var result: DamageFormula.Result = DamageFormula.compute(amount, 0, 0, 0, 1.0, false, false, 0.0,
			0.0, 0, 0, rules.crit_multiplier, status.damage_scale(author), 0.0)
	var applied: int = target.take_damage(result.damage, s)
	var source: int = CombatSource.make(CombatSource.Kind.STATUS, effect.id)
	var attacker_id: int = author.get_id() if author != null else 0
	target.mark_combat(s)
	if author != null and author != target:
		author.mark_combat(s)
		target.ledger.record(s, attacker_id, applied)
		target.note_enemy_hit(attacker_id, source, s)
	stats[&"pulse_hits"] += 1
	stats[&"damage"] += applied
	var lethal: bool = target.is_dead()
	var shown: int = result.damage if target.immortal else applied
	_emit(NetMessages.EntityEvent.hit(target.get_id(), s, attacker_id, shown, effect.damage_type,
			_HIT_LETHAL if lethal else 0, source), _ids([target.get_id(), attacker_id]))
	_log_line(s, attacker_id, target.get_id(), CombatSource.name_of(source), float(s), 0.0, "pulse",
			shown)
	if lethal:
		_die(target, s, attacker_id, source)


# --- Muerte -----------------------------------------------------------------------------------

# Muerte de [param victim] por [param killer_id] (0 = el entorno) con [param attack_id]: acción
# DEAD, una sola DEATH y, si hay autor, un KILL con los asistentes del registro de daño.
func _die(victim: Combatant, s: int, killer_id: int, attack_id: int) -> void:
	if victim.immortal or victim.death_tick >= 0:
		return
	victim.mark_dead(s, killer_id, attack_id)
	var character: PlayerCharacter = victim.get_character()
	ActionMachine.impose_death(character.combat, s)
	# Al morir se quitan todos sus efectos, sin STATUS: DEATH los borra en el cliente.
	status.clear(victim)
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
	status.clear(combatant)
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
		# Los PNJ no reaparecen solos: los repone su generador (NpcSpawnerSystem).
		if combatant.entity.kind == NetProtocol.EntityKind.NPC:
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
	var combat: CombatState = character.combat
	# Hasta las plantillas (H3c, docs/habilidades.md, sección 4.6) reaparece con las armas y las cargas que
	# llevaba, con la de la ranura 1 activa.
	var first: int = combat.alt_weapon_id if combat.is_second_slot() else combat.weapon_id
	var second: int = combat.weapon_id if combat.is_second_slot() else combat.alt_weapon_id
	ActionMachine.reset_for_respawn(combat, s, first, second, combat.consumable_charges)
	# Ya no debería quedar ninguno (se quitan al morir), pero reaparecer empieza siempre limpio.
	status.clear(combatant)
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

# Cuenta como ataque lanzado el tick en que empieza un ligero, un fuerte o una habilidad que golpea
# (con forma o proyectil): sus aciertos también cuentan en _note_landed.
func _count_swing(combatant: Combatant) -> void:
	var frame: Combatant.Frozen = combatant.frozen
	if combatant.peer == null or frame.action_tick != frame.tick:
		return
	match frame.action:
		CombatState.Action.LIGHT, CombatState.Action.HEAVY:
			combatant.peer.swings += 1
		CombatState.Action.ABILITY:
			var ability: AbilityTicks = CombatCatalog.ability(frame.action_id)
			if ability != null and (ability.hit.shape != null or ability.projectile_id != 0):
				combatant.peer.swings += 1


# Un ataque (o su carga) ha acertado, fallado o sido parado: cuenta como acierto del peer una vez
# por ataque.
func _note_landed(attacker: Combatant) -> void:
	if attacker.peer != null and not attacker.swing_landed:
		attacker.peer.swings_landed += 1
	attacker.swing_landed = true


# Lo que quita la protección de reaparición: un ataque (o su carga) y una habilidad que no sea un
# consumible (docs/habilidades.md, sección 4.2). Beber, SWAP, REVIVE y EXECUTE no la quitan.
func _started_attack(combatant: Combatant) -> bool:
	var frame: Combatant.Frozen = combatant.frozen
	match frame.action:
		CombatState.Action.LIGHT, CombatState.Action.HEAVY, CombatState.Action.CHARGE:
			return true
		CombatState.Action.ABILITY:
			var ability: AbilityTicks = CombatCatalog.ability(frame.action_id)
			return ability != null and not ability.is_consumable()
	return false


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


# Una línea del registro de combate de un golpe resuelto: tick, atacante, objetivo, fuente (el nombre del
# ataque o de la habilidad), view_tick, rebobinado, resultado y daño.
func _log_hit(s: int, hit: CombatResolver.Hit, result: String, damage: int) -> void:
	if combat_log == null:
		return
	var target_id: int = 0
	if hit.victim != null:
		target_id = hit.victim.get_id()
	elif hit.structure != null:
		target_id = hit.structure.net_id
	_log_line(s, hit.attacker.get_id(), target_id, String(hit.attack.name), hit.view_tick, hit.rewind,
			result, damage)


# Una línea del registro de combate ([code]--combat-log[/code]): la columna «ataque» lleva el nombre de la
# fuente ([method CombatSource.name_of]: ataque, habilidad, efecto…). Resultados de la fase 4: pulse (un
# pulso de daño de un efecto); arrow_hit, arrow_blocked, wall_blocked (H3b) y downed, executed, bled_out
# y revived (H3c).
func _log_line(s: int, attacker_id: int, target_id: int, source_name: String, view_tick: float,
		rewind: float, result: String, damage: int) -> void:
	if combat_log == null:
		return
	combat_log.store_line("%d,%d,%d,%s,%.2f,%.2f,%s,%d" % [s, attacker_id, target_id, source_name,
			view_tick, rewind, result, damage])
