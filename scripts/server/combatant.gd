class_name Combatant
extends RefCounted
## Lo que el servidor sabe del combate de una entidad con cuerpo (docs/combate.md, sección 5): jugador,
## jugador falso o PNJ. Uno por entidad que puede recibir daño.
## [br][br]
## Lleva la vida (autoritativa, no predicha: no va en [PlayerState]), el estado «en combate», la
## protección de reaparición, la muerte y el plazo de reaparición, la cadena de controles con su
## inmunidad, el [DamageLedger] y el último enemigo que le golpeó (para acreditar caídas). Lo que sí
## cambia la simulación (acción, resistencia, controles) vive en [member PlayerCharacter.combat] y
## viaja en [PlayerState].
## [br][br]
## [member frozen] es la «muestra del tick actual» (docs/combate.md, 4.2): la posición, el giro, las
## banderas defensivas y la acción de la entidad justo después de simular el tick, que el
## [CombatResolver] usa para que todos los golpes de un tick sean simultáneos. Desde la fase 4
## (docs/habilidades.md, sección 4.1, paso 2) congela también el golpe activo (un ataque o el golpe
## sintetizado de una habilidad), si es el tick del compromiso y la caja del muro de escudos.
## [br][br]
## [member effects] son sus efectos de estado activos (los lleva el [StatusSystem]).
## [br][br]
## [b]Derribado[/b] (docs/habilidades.md, sección 4.5; lo lleva el [DownedSystem]): con la vida a 0 tras un golpe
## mortal de un jugador hostil en una zona RVR, el jugador queda derribado ([method is_downed]) con
## [member downed_health] de vida de derribado. Un derribado no es ni vivo ni muerto: [method is_alive] es
## [code]health > 0[/code] (sin cambios) y [method is_dead] es [code]health == 0[/code] y no derribado. Quien
## levanta o remata lleva en [member interact_target] a quién y desde cuándo.
## [br][br]
## [member template_id] es la plantilla de equipo vigente ([EquipmentTemplate]; 0 = ninguna: los PNJ y los
## luchadores montados a mano en las pruebas); la pendiente, la que eligió el jugador para su siguiente
## aparición, vive en [member ServerPeer.pending_template_id].

## Estado congelado de la entidad tras simular el tick [member tick]. Es una
## [StateHistory.Sample] (posición, giro y banderas) con la acción en curso.
class Frozen:
	extends StateHistory.Sample

	## Tick tras el que se congeló (-1 = nunca).
	var tick: int = -1
	## Banderas defensivas ([method ActionMachine.defense_flags]) del tick.
	var defense: int = 0
	var action: int = 0
	var action_id: int = 0
	var action_tick: int = 0
	var weapon_id: int = 0
	## Carga con la que se lanzó el golpe fuerte en curso.
	var charge_ticks: int = 0
	## El golpe activo del tick ([method ActionMachine.active_hit]): el ataque en su golpe activo o el
	## golpe sintetizado de la habilidad en su activo o su canalización ([member AbilityTicks.hit]);
	## null si no hay. Sin forma no prueba a nadie.
	var hit: AttackTicks = null
	## Hay un golpe activo ([member hit] no es null).
	var attack_active: bool = false
	## Está en el golpe activo de un ataque o una habilidad con entereza
	## ([member AttackTicks.hyper_armor]).
	var hyper_armor: bool = false
	## El tick es el del compromiso ([method ActionMachine.is_commit_tick]): el primer tick activo de un
	## LIGHT, un HEAVY o una ABILITY (salen los proyectiles y los efectos propios).
	var commit: bool = false
	## Caja del muro de escudos (centro y giro) mientras la canalización que bloquea la lleva
	## ([member AbilityTicks.wall_half_extents]); vale si [member wall_half_extents] no es cero.
	var wall: Transform3D = Transform3D.IDENTITY
	## Semiejes de [member wall] (cero = sin muro).
	var wall_half_extents: Vector3 = Vector3.ZERO


## [member effects_due] sin efectos: nunca.
const NO_EFFECTS_DUE: int = 0x7FFFFFFFFFFFFFFF
## [member last_buttons_tick] cuando aún no se ha visto ninguna entrada.
const NO_BUTTONS_TICK: int = -1

var entity: NetEntity
## Cola de entradas de la entidad (la de un jugador de red, un jugador falso o un PNJ).
var queue: InputQueue
## Peer del jugador (null en los falsos y los PNJ: no rebobinan).
var peer: ServerPeer
var timing: CombatTiming
var health: int = 0
var max_health: int = 0
## Un maniquí: la vida no baja de 1, no muere y se cura del todo tras [member CombatTiming.dummy_heal].
var immortal: bool = false
## Un Guardián de la Puerta: puede atacar desde la zona segura de su propio reino y ataca a los enemigos que
## hay dentro (docs/combate.md, sección 5). Lo pone quien crea el PNJ, según su [code]NpcDefinition[/code].
var ignores_safe_area: bool = false
var in_combat_until: int = 0
var protected_until: int = 0
## Tick de la muerte (-1 si está vivo) y primer tick en que puede reaparecer.
var death_tick: int = -1
var respawn_tick: int = 0
## Punto de reaparición pedido con RESPAWN_REQUEST (-1 = ninguna petición pendiente).
var pending_respawn_point: int = -1
## Quién dio el golpe mortal (0 = el entorno) y con qué ataque.
var killer_id: int = 0
var death_attack_id: int = 0
## Último tick en que recibió daño.
var last_damage_tick: int = -1
## Último enemigo que le golpeó: net_id, tick y ataque. Acredita las muertes por caída o volumen.
var last_enemy_id: int = 0
var last_enemy_tick: int = -1
var last_enemy_attack_id: int = 0
## Controles recibidos dentro de la ventana de la cadena (ticks) y fin de la inmunidad.
var cc_chain: PackedInt64Array = PackedInt64Array()
var cc_immune_until: int = 0
var ledger: DamageLedger
var frozen: Frozen = Frozen.new()
## Efectos de estado activos (hasta [constant StatusSystem.MAX_EFFECTS], por id de efecto). Los lleva el
## [StatusSystem]: nadie más los toca.
var effects: Array[StatusSystem.ActiveEffect] = []
## Primer tick en que a [member effects] le pasa algo (un pulso o una caducidad); el [StatusSystem] no mira
## a la entidad antes. [constant NO_EFFECTS_DUE] si no lleva ninguno.
var effects_due: int = NO_EFFECTS_DUE
## Vida de derribado (de [member CombatRules.downed_health] a 0) y tick en que cayó (-1 = no está derribado).
var downed_health: int = 0
var downed_tick: int = -1
## Quién lo derribó (0 = nadie: el comando 15) y con qué fuente ([CombatSource]).
var downed_by: int = 0
var downed_source: int = 0
## Levantar o rematar en curso de esta entidad (la que actúa): el net_id del derribado (0 = ninguno), la
## acción ([constant CombatState.Action.REVIVE] o [constant CombatState.Action.EXECUTE]) y su tick de inicio.
var interact_target: int = 0
var interact_action: int = 0
var interact_start: int = -1
## Botones (sin [constant PlayerInput.SUBSTITUTED]) de la entrada del tick [member last_buttons_tick]: con
## ellos el [DownedSystem] ve el flanco de INTERACT de la entrada siguiente.
var last_buttons: int = 0
var last_buttons_tick: int = NO_BUTTONS_TICK
## Plantilla de equipo vigente (id del catálogo; 0 = ninguna). La pendiente, en
## [member ServerPeer.pending_template_id].
var template_id: int = 0
## Ataque (por su tick de inicio) que se está resolviendo, y a quién ha golpeado ya: un impacto por
## acción y objetivo.
var swing_action_tick: int = -1
var swing_hits: Dictionary[int, bool] = {}
## El ataque en curso ya ha dado en algo (impacto, bloqueo o parada): cuenta como acierto una vez.
var swing_landed: bool = false
## Rebobinado del ataque en curso, fijado por el [CombatResolver] en su primer tick activo (el cliente
## no lo cambia en los siguientes): [member swing_rewind_fixed] dice si ya se fijó, [member swing_rewind]
## son los ticks que ve atrás (NAN = el golpe pidió más de lo permitido y no se prueba) y
## [member swing_defense_rewind] los que se miran atrás para la parada, el bloqueo y la invulnerabilidad
## (al menos el mínimo coherente con el RTT medido).
var swing_rewind_fixed: bool = false
var swing_rewind: float = 0.0
var swing_defense_rewind: float = 0.0
## Tick de inicio del ataque cuyo rebobinado se rechazó (para contar la sospecha una sola vez).
var rejected_swing_tick: int = -1

# Resto de la regeneración de vida (en puntos por segundo, se canjea cada 60).
var _regen_carry: int = 0
# Arma el byte de acción del registro de red, con el contador de reinicio de las esquivas y los controles.
var _action_wire: ActionWire = ActionWire.new()


## [param entity] debe tener un [PlayerCharacter] como nodo. [param max_health] es la vida máxima
## y con ella aparece.
func _init(new_entity: NetEntity, new_queue: InputQueue, new_peer: ServerPeer,
		new_timing: CombatTiming, new_max_health: int) -> void:
	entity = new_entity
	queue = new_queue
	peer = new_peer
	timing = new_timing
	max_health = new_max_health
	health = new_max_health
	ledger = DamageLedger.new(new_entity.net_id)


## net_id de la entidad.
func get_id() -> int:
	return entity.net_id


## Código de bando de la entidad.
func get_realm() -> int:
	return entity.realm


func get_character() -> PlayerCharacter:
	return entity.get_character()


## true con vida (ni muerto ni derribado).
func is_alive() -> bool:
	return health > 0


## true si está muerto: sin vida y no derribado (docs/habilidades.md, sección 4.5). Un derribado no es ni
## vivo ni muerto.
func is_dead() -> bool:
	return health <= 0 and downed_tick < 0


## true mientras está derribado (docs/habilidades.md, sección 4.5).
func is_downed() -> bool:
	return downed_tick >= 0


## true mientras levanta o remata a alguien (lo lleva el [DownedSystem]).
func is_interacting() -> bool:
	return interact_target != 0


## true mientras dure el estado «en combate» (10 s tras dar o recibir daño).
func is_in_combat(tick: int) -> bool:
	return tick < in_combat_until


## true durante la protección de reaparición.
func is_protected(tick: int) -> bool:
	return tick < protected_until


## Bits de estado del bloque extra del snapshot ([constant NetMessages.STATUS_IN_COMBAT]...). Un derribado
## lleva [constant NetMessages.STATUS_DOWNED] (nunca con [constant NetMessages.STATUS_DEAD]) y, si sigue en
## combate, [constant NetMessages.STATUS_IN_COMBAT].
func status_bits(tick: int) -> int:
	var bits: int = 0
	if is_downed():
		bits |= NetMessages.STATUS_DOWNED
		if is_in_combat(tick):
			bits |= NetMessages.STATUS_IN_COMBAT
	elif is_dead():
		bits |= NetMessages.STATUS_DEAD
	else:
		if is_in_combat(tick):
			bits |= NetMessages.STATUS_IN_COMBAT
		if is_protected(tick):
			bits |= NetMessages.STATUS_PROTECTED
	return bits


## Anota que la entidad ha dado o recibido daño en [param tick]: «en combate» otros
## [member CombatTiming.in_combat] ticks.
func mark_combat(tick: int) -> void:
	in_combat_until = maxi(in_combat_until, tick + timing.in_combat)


## Congela la entidad tras simular el tick [param tick] (la muestra del tick actual).
func freeze(tick: int) -> void:
	var character: PlayerCharacter = entity.get_character()
	var state: CombatState = character.combat
	var sample: Frozen = frozen
	sample.tick = tick
	sample.position = entity.get_position()
	sample.yaw = character.yaw
	sample.action = state.action
	sample.action_id = state.action_id
	sample.action_tick = state.action_tick
	sample.weapon_id = state.weapon_id
	sample.charge_ticks = state.charge_ticks
	sample.defense = ActionMachine.defense_flags(state, tick)
	# El byte del historial: los bits 0-2 del registro (suelo y teletransporte) y las banderas
	# defensivas; el bit 3 del registro (ranura 2) no entra nunca (es DEFENSE_BLOCKING aquí).
	sample.flags = (entity.teleport_counter & EntityRecord.TELEPORT_MASK) \
			<< EntityRecord.TELEPORT_SHIFT
	if character.grounded:
		sample.flags |= EntityRecord.FLAG_GROUNDED
	sample.flags = (sample.flags & EntityRecord.HISTORY_FLAGS_MASK) | sample.defense
	sample.hit = null
	sample.commit = false
	sample.wall_half_extents = Vector3.ZERO
	match state.action:
		CombatState.Action.LIGHT, CombatState.Action.HEAVY, CombatState.Action.ABILITY:
			sample.hit = ActionMachine.active_hit(state, tick)
			sample.commit = ActionMachine.is_commit_tick(state, tick)
			if (sample.defense & ActionMachine.DEFENSE_WIDE_BLOCK) != 0:
				_freeze_wall(sample, state, character.yaw)
	sample.attack_active = sample.hit != null
	sample.hyper_armor = sample.hit != null and sample.hit.hyper_armor


# La caja del muro de escudos de la canalización que bloquea: delante de los pies
# [member AbilityTicks.wall_forward_m], con su base en el suelo y girada con el cuerpo.
static func _freeze_wall(sample: Frozen, state: CombatState, yaw: float) -> void:
	var ability: AbilityTicks = CombatCatalog.ability(state.action_id)
	if ability == null or ability.wall_half_extents == Vector3.ZERO:
		return
	var basis := Basis(Vector3.UP, yaw)
	sample.wall = Transform3D(basis, sample.position
			+ basis * Vector3(0.0, ability.wall_half_extents.y, -ability.wall_forward_m))
	sample.wall_half_extents = ability.wall_half_extents


## Quita hasta [param amount] de vida y devuelve lo que ha quitado de verdad. Un maniquí
## ([member immortal]) conserva al menos 1 punto. No hace nada si ya está muerto. No toca el
## estado «en combate» (lo marca quien aplica el golpe).
func take_damage(amount: int, tick: int) -> int:
	if amount <= 0 or health <= 0:
		return 0
	var floor_health: int = 1 if immortal else 0
	var applied: int = clampi(health - floor_health, 0, amount)
	health -= applied
	last_damage_tick = tick
	return applied


## Quita hasta [param amount] de la vida de derribado y devuelve lo que ha quitado de verdad (sin bloqueo ni
## controles: lo decide quien aplica el golpe). No hace nada si no está derribado. A 0, quien llama lo mata.
func take_downed_damage(amount: int, tick: int) -> int:
	if amount <= 0 or not is_downed():
		return 0
	var applied: int = mini(amount, downed_health)
	downed_health -= applied
	if applied > 0:
		last_damage_tick = tick
	return applied


## Lo deja derribado en [param tick] por [param author_id] con la fuente [param source] y [param health] de
## vida de derribado. La vida normal queda a 0. No toca su [CombatState]: lo impone el [DownedSystem].
func mark_downed(tick: int, author_id: int, source: int, health_when_downed: int) -> void:
	health = 0
	downed_health = maxi(health_when_downed, 1)
	downed_tick = tick
	downed_by = author_id
	downed_source = source
	_regen_carry = 0


## Deja de estar derribado (levantado, muerto o al reaparecer): borra la vida de derribado y su autor.
func clear_downed() -> void:
	downed_health = 0
	downed_tick = -1
	downed_by = 0
	downed_source = 0


## Olvida el levantar o rematar que llevaba (lo llama el [DownedSystem] al acabarlo o cortarlo).
func clear_interaction() -> void:
	interact_target = 0
	interact_action = 0
	interact_start = -1


## Anota al último enemigo que le ha golpeado.
func note_enemy_hit(attacker_id: int, attack_id: int, tick: int) -> void:
	last_enemy_id = attacker_id
	last_enemy_attack_id = attack_id
	last_enemy_tick = tick


## true si [param tick] está dentro de la ventana de crédito del último enemigo (la misma que
## «en combate»).
func has_recent_enemy(tick: int) -> bool:
	return last_enemy_id != 0 and last_enemy_tick >= 0 and tick - last_enemy_tick < timing.in_combat


## Intenta imponerle un control (tambaleo, aturdimiento...) en [param tick]. Cadena de controles
## (docs/combate.md, 4.4): se cuentan los de los últimos [member CombatTiming.cc_window] ticks; el
## tercero no entra y abre [member CombatTiming.cc_immunity] ticks de inmunidad a los controles.
## Devuelve false si el control no entra.
func try_control(tick: int) -> bool:
	if tick < cc_immune_until:
		return false
	var kept := PackedInt64Array()
	for control_tick: int in cc_chain:
		if tick - control_tick < timing.cc_window:
			kept.append(control_tick)
	cc_chain = kept
	if cc_chain.size() >= 2:
		cc_immune_until = tick + timing.cc_immunity
		cc_chain.clear()
		return false
	cc_chain.append(tick)
	return true


## Un tick de regeneración de vida: [param per_second] puntos por segundo, solo fuera de combate
## y sin estar muerto. El maniquí se cura del todo cuando lleva
## [member CombatTiming.dummy_heal] ticks sin recibir daño.
func regenerate(tick: int, per_second: int) -> void:
	if health <= 0 or health >= max_health:
		_regen_carry = 0
		return
	if immortal and last_damage_tick >= 0 and tick - last_damage_tick >= timing.dummy_heal:
		health = max_health
		return
	if tick < in_combat_until:
		return
	_regen_carry += per_second
	@warning_ignore("integer_division")
	var gained: int = _regen_carry / CombatCatalog.TICK_RATE
	_regen_carry -= gained * CombatCatalog.TICK_RATE
	if gained > 0:
		health = mini(health + gained, max_health)


## Cura hasta [param amount] sin pasar del máximo (pociones, curación en el tiempo) y devuelve lo que
## ha curado de verdad. No hace nada sobre un muerto.
func restore_health(amount: int) -> int:
	if amount <= 0 or health <= 0 or health >= max_health:
		return 0
	var restored: int = mini(amount, max_health - health)
	health += restored
	return restored


## Cura del todo (comando de depuración, reaparición).
func heal_full() -> void:
	health = max_health
	_regen_carry = 0


## Marca la muerte en [param tick]: vida a 0, plazo de reaparición y autor. Un derribado deja de estarlo.
func mark_dead(tick: int, killer: int, attack_id: int) -> void:
	health = 0
	clear_downed()
	death_tick = tick
	respawn_tick = timing.respawn_tick_for(tick)
	pending_respawn_point = -1
	killer_id = killer
	death_attack_id = attack_id


## Deja la entidad viva como al aparecer: vida llena, protegida durante
## [member CombatTiming.protection] ticks desde [param tick], fuera de combate y con el registro de
## daño vacío.
func mark_respawned(tick: int) -> void:
	heal_full()
	clear_downed()
	clear_interaction()
	death_tick = -1
	respawn_tick = 0
	pending_respawn_point = -1
	killer_id = 0
	death_attack_id = 0
	protected_until = tick + timing.protection
	in_combat_until = 0
	last_enemy_id = 0
	last_enemy_tick = -1
	cc_chain.clear()
	cc_immune_until = 0
	last_damage_tick = -1
	ledger.clear()
	swing_action_tick = -1
	forget_swing()


## Empieza a seguir el ataque que empezó en [param action_tick]; si es otro que el anterior, olvida a
## quién había golpeado.
func track_swing(action_tick: int) -> void:
	if action_tick != swing_action_tick:
		swing_action_tick = action_tick
		forget_swing()


## Olvida lo que sabe del ataque en curso: a quién ha golpeado ya, si ha acertado y el rebobinado que se
## fijó en su primer tick activo.
func forget_swing() -> void:
	swing_hits.clear()
	swing_landed = false
	swing_rewind_fixed = false


## true si este ataque ya ha golpeado (o ha sido bloqueado o parado por) a [param victim_id].
func has_hit(victim_id: int) -> bool:
	return swing_hits.has(victim_id)


func mark_hit(victim_id: int) -> void:
	swing_hits[victim_id] = true


## Actualiza lo que ven los snapshots: vida, estado, tick de reaparición y byte de acción de la
## entidad ([method NetEntity.set_health_view]). Derribado, la vida es la de derribado sobre
## [member CombatRules.downed_health] (docs/habilidades.md, sección 5.2): su vida cuantizada nunca es 0.
func publish(tick: int) -> void:
	if is_downed():
		entity.set_health_view(downed_health, CombatCatalog.rules().downed_health, status_bits(tick), 0)
	else:
		entity.set_health_view(health, max_health, status_bits(tick),
				respawn_tick if health <= 0 else 0)
	var character: PlayerCharacter = entity.get_character()
	if character != null:
		entity.action = _action_wire.encode(character.combat, tick)
