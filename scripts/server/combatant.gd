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
## [CombatResolver] usa para que todos los golpes de un tick sean simultáneos.

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
	## Hay un ataque en su golpe activo.
	var attack_active: bool = false
	## Está en el golpe activo de un ataque con entereza ([member AttackTicks.hyper_armor]).
	var hyper_armor: bool = false


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
## Ataque (por su tick de inicio) que se está resolviendo, y a quién ha golpeado ya: un impacto por
## acción y objetivo.
var swing_action_tick: int = -1
var swing_hits: Dictionary[int, bool] = {}
## El ataque en curso ya ha dado en algo (impacto, bloqueo o parada): cuenta como acierto una vez.
var swing_landed: bool = false
## Tick de inicio del ataque cuyo rebobinado se rechazó (para contar la sospecha una sola vez).
var rejected_swing_tick: int = -1

# Resto de la regeneración de vida (en puntos por segundo, se canjea cada 60).
var _regen_carry: int = 0


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


func is_alive() -> bool:
	return health > 0


func is_dead() -> bool:
	return health <= 0


## true mientras dure el estado «en combate» (10 s tras dar o recibir daño).
func is_in_combat(tick: int) -> bool:
	return tick < in_combat_until


## true durante la protección de reaparición.
func is_protected(tick: int) -> bool:
	return tick < protected_until


## Bits de estado del bloque extra del snapshot ([constant NetMessages.STATUS_IN_COMBAT]...).
func status_bits(tick: int) -> int:
	var bits: int = 0
	if is_dead():
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
	sample.flags = (entity.teleport_counter & EntityRecord.TELEPORT_MASK) \
			<< EntityRecord.TELEPORT_SHIFT
	if character.grounded:
		sample.flags |= EntityRecord.FLAG_GROUNDED
	sample.flags |= sample.defense
	sample.attack_active = ActionMachine.is_attack_active(state, tick)
	sample.hyper_armor = false
	if sample.attack_active:
		var attack: AttackTicks = CombatCatalog.attack(state.action_id)
		sample.hyper_armor = attack != null and attack.hyper_armor


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


## Cura del todo (comando de depuración, reaparición).
func heal_full() -> void:
	health = max_health
	_regen_carry = 0


## Marca la muerte en [param tick]: vida a 0, plazo de reaparición y autor.
func mark_dead(tick: int, killer: int, attack_id: int) -> void:
	health = 0
	death_tick = tick
	respawn_tick = tick + timing.respawn
	pending_respawn_point = -1
	killer_id = killer
	death_attack_id = attack_id


## Deja la entidad viva como al aparecer: vida llena, protegida durante
## [member CombatTiming.protection] ticks desde [param tick], fuera de combate y con el registro de
## daño vacío.
func mark_respawned(tick: int) -> void:
	heal_full()
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
	swing_hits.clear()
	swing_landed = false


## Empieza a seguir el ataque que empezó en [param action_tick]; si es otro que el anterior, olvida a
## quién había golpeado.
func track_swing(action_tick: int) -> void:
	if action_tick != swing_action_tick:
		swing_action_tick = action_tick
		swing_hits.clear()
		swing_landed = false


## true si este ataque ya ha golpeado (o ha sido bloqueado o parado por) a [param victim_id].
func has_hit(victim_id: int) -> bool:
	return swing_hits.has(victim_id)


func mark_hit(victim_id: int) -> void:
	swing_hits[victim_id] = true


## Actualiza lo que ven los snapshots: vida, estado, tick de reaparición y byte de acción de la
## entidad ([method NetEntity.set_health_view]).
func publish(tick: int) -> void:
	entity.set_health_view(health, max_health, status_bits(tick),
			respawn_tick if health <= 0 else 0)
	var character: PlayerCharacter = entity.get_character()
	if character != null:
		entity.action = ActionMachine.action_byte(character.combat, tick)
