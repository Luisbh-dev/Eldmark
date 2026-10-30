class_name ActionMachine
extends RefCounted
## Máquina de acciones del combate (docs/combate.md, sección 3, y docs/habilidades.md, sección 3):
## ataques ligeros en combo, ataque fuerte cargado, bloqueo con parada, esquiva, resistencia,
## habilidades, consumibles, cambio de arma, efectos de movimiento y lo que impone el servidor
## (controles, muerte, derribado, levantar y rematar). Es una función determinista de
## ([CombatState], [PlayerInput], suelo): sin reloj, sin aleatoriedad y sin leer nada que no viaje en
## [PlayerState].
## [br][br]
## [method step] la llama [method PlayerCharacter.simulate] al principio de cada tick, antes del
## movimiento, y devuelve en un [ActionMachine.Output] cómo debe moverse el personaje ese tick.
## El resto de funciones estáticas son consultas (las usan el servidor, el animador y la barra de
## acciones) y las órdenes que impone el servidor ([method impose_stagger]...).
## [br][br]
## [b]Orden de cada tick[/b] (con [code]t = input.tick[/code]; docs/habilidades.md, sección 3.3): 0)
## camino rápido; 1) acciones que terminan; 2) efectos de movimiento que caducan; 3) regeneración de
## resistencia; 4) entradas: 4a fines por entrada (canalización, levantar y rematar), 4b el búfer y 4c
## los flancos nuevos con prioridad DODGE > ABILITY_1 > ABILITY_2 > ABILITY_3 > CONSUMABLE_1 >
## CONSUMABLE_2 > PRIMARY > SWAP > BLOCK; 5) el compromiso de una habilidad o un consumible; 6) el
## [ActionMachine.Output]. Habilidades, consumibles, cambio de arma, canalizaciones y efectos de
## movimiento viven en [AbilityRules] (la máquina partida en dos archivos); esta sigue siendo la
## entrada.
## [br][br]
## [b]Flancos.[/b] Los saca de los bits [constant CombatState.FLAG_DODGE_HELD] y compañeros de
## [member CombatState.combat_flags] y de los bits 1-6 de [member CombatState.combat_flags2] (el nivel
## de cada botón en el tick anterior), así que la firma de [method step] no necesita
## [member PlayerCharacter.prev_buttons]. Una entrada sustituida ([constant PlayerInput.SUBSTITUTED])
## repite los botones y por tanto no crea flancos; además no suma a [member CombatState.primary_held],
## no convierte un ligero en carga, no lanza el fuerte al llegar a la carga máxima (la carga se congela
## hasta [member CombatRules.input_buffer_ticks] ticks más; si el silencio sigue, se cancela), no abre
## ventanas de parada, no corta una canalización por moverse y no suelta lo que se mantiene (una
## canalización, levantar o rematar). Ninguna pérdida inventa una habilidad, un cambio de arma ni una
## poción.
## [br][br]
## [b]Búfer.[/b] Una ranura ([member CombatState.buffered]: tipo y ticks que le quedan): un flanco que
## no se puede ejecutar ahora la ocupa (la última pulsación gana) y se ejecuta en el primer tick en que
## se pueda, dentro de [member CombatRules.input_buffer_ticks]; un flanco que no tiene sentido (ranura
## vacía, sin cargas, sin arma alternativa, [member WeaponTicks.can_block] falso, avance con ROOT) se
## descarta.
## [br][br]
## [b]Historial.[/b] [method defense_flags] da los bits 3-7 de [StateHistory]; el byte que graba el
## servidor es [code](flags del registro & 0b111) | defense_flags[/code]
## ([constant EntityRecord.HISTORY_FLAGS_MASK]; lo enmascaran [code]ZoneServer._record_history[/code] y
## [method Combatant.freeze]): el bit 3 del registro de red (ranura 2 activa, docs/habilidades.md,
## sección 5.2) no entra nunca, porque en el historial el bit 3 es [constant DEFENSE_BLOCKING].

## Cómo debe moverse el personaje este tick (lo aplica [method PlayerCharacter.simulate]).
class Output:
	## Fracción de la velocidad de carrera permitida ([code]wish * run_speed * move_scale[/code]).
	var move_scale: float = 1.0
	## Velocidad hacia delante (m/s) que se suma a la de carrera.
	var lunge_speed: float = 0.0
	## Giro hacia la cámara (rad/s) aunque el personaje esté quieto; 0 = no gira; -1 = el giro
	## normal de simulate() (solo al moverse).
	var turn_rate: float = -1.0
	## El yaw salta a look_yaw este tick.
	var snap_yaw: bool = false
	## La velocidad horizontal es [member velocity] y se impone sin aceleración.
	var forced_velocity: bool = false
	var velocity: Vector3 = Vector3.ZERO
	var allow_jump: bool = true
	var allow_sprint: bool = true
	## true en toda acción menos NONE: la velocidad objetivo es
	## [code]wish * run_speed * move_scale[/code], sin los multiplicadores de ir hacia atrás o de
	## lado ni el esprint.
	var scaled_movement: bool = false
	## Efectos de movimiento (docs/habilidades.md, sección 3.4): multiplica la velocidad objetivo no
	## impuesta en todas las acciones (NONE y el esprint incluidos); la esquiva, el avance de una
	## habilidad y el empuje no.
	var speed_factor: float = 1.0
	## Enraizado (ROOT): sin salto y, en el aire, frena como con [code]move_scale[/code] 0.
	var rooted: bool = false


## Estado de una casilla de la barra de acciones ([method ability_status]).
enum AbilityStatus { READY, COOLDOWN, BLOCKED, EMPTY, NO_CHARGES }

## Fases de un ataque o una habilidad ([method phase]).
const PHASE_WINDUP: int = 0
const PHASE_ACTIVE: int = 1
const PHASE_RECOVERY: int = 2
const PHASE_NONE: int = 3

## Bits de [method defense_flags] (siguen a los de [StateHistory]: bit 0 suelo, bits 1-2
## teletransporte).
const DEFENSE_BLOCKING: int = 1 << 3
const DEFENSE_PARRY: int = 1 << 4
const DEFENSE_INVULNERABLE: int = 1 << 5
const DEFENSE_DEAD: int = 1 << 6
## Bloqueo ancho: la canalización que bloquea (el muro de escudos) lo da junto a
## [constant DEFENSE_BLOCKING]; el servidor usa entonces el cono y el coste de las reglas
## ([member CombatRules.ability_block_angle_deg]) en vez de los del arma.
const DEFENSE_WIDE_BLOCK: int = 1 << 7

## Casillas de [method ability_status] de los dos consumibles (las 0-2 son las habilidades del arma
## activa).
const STATUS_SLOT_CONSUMABLE_1: int = 3
const STATUS_SLOT_CONSUMABLE_2: int = 4

const _NONE: int = CombatState.Action.NONE
const _LIGHT: int = CombatState.Action.LIGHT
const _HEAVY: int = CombatState.Action.HEAVY
const _CHARGE: int = CombatState.Action.CHARGE
const _BLOCK: int = CombatState.Action.BLOCK
const _DODGE: int = CombatState.Action.DODGE
const _STAGGER: int = CombatState.Action.STAGGER
const _STUN: int = CombatState.Action.STUN
const _DEAD: int = CombatState.Action.DEAD
const _ABILITY: int = CombatState.Action.ABILITY
const _SWAP: int = CombatState.Action.SWAP
const _DOWNED: int = CombatState.Action.DOWNED
const _REVIVE: int = CombatState.Action.REVIVE
const _EXECUTE: int = CombatState.Action.EXECUTE

## Por debajo de esta longitud el movimiento no da dirección a la esquiva (se esquiva hacia atrás).
const _DODGE_MIN_MOVE: float = 0.1
## Botones que sacan del camino rápido: los de combate. AIM_LEFT (un nivel que solo lee la puntería),
## INTERACT (lo atiende el servidor), salto y esprint no.
const _COMBAT_BUTTONS: int = (
	PlayerInput.DODGE | PlayerInput.PRIMARY | PlayerInput.BLOCK | PlayerInput.ABILITY_1
	| PlayerInput.ABILITY_2 | PlayerInput.ABILITY_3 | PlayerInput.SWAP_WEAPON
	| PlayerInput.CONSUMABLE_1 | PlayerInput.CONSUMABLE_2
)
const _HELD_FLAGS: int = (
	CombatState.FLAG_DODGE_HELD | CombatState.FLAG_BLOCK_HELD | CombatState.FLAG_PRIMARY_HELD
)

# Resultado de intentar una esquiva: no se puede ahora (va al búfer), empezó, o se descarta por
# falta de resistencia (o por estar enraizado). Los mismos valores que AbilityRules.RETRY, STARTED y
# DROPPED.
const _DODGE_RETRY: int = 0
const _DODGE_STARTED: int = 1
const _DODGE_DROPPED: int = 2


## Avanza la máquina un tick con [param input] y devuelve cómo se mueve el personaje.
## [param grounded] es si estaba en el suelo al empezar el tick.
static func step(c: CombatState, input: PlayerInput, grounded: bool) -> ActionMachine.Output:
	var out := Output.new()
	var data: CombatTables = CombatCatalog.tables()
	var t: int = input.tick

	# Niveles y flancos de los botones (el bit SUBSTITUTED no es un botón).
	var down: int = input.buttons & ~PlayerInput.SUBSTITUTED
	var previous: int = c.combat_flags
	var previous2: int = c.combat_flags2

	# Camino rápido, el de casi todos los ticks: sin acción, sin botones de combate (ni pulsados
	# ni recién soltados), nada pendiente y sin efectos de movimiento. Solo puede cambiar la
	# resistencia al regenerar. No busca el arma ni recorre las ranuras de habilidades.
	if c.action == _NONE and c.buffered == 0 and c.primary_held == 0 \
			and (down & _COMBAT_BUTTONS) == 0 \
			and (previous & (_HELD_FLAGS | CombatState.FLAG_NO_STAMINA)) == 0 \
			and (previous2 & CombatState.FLAG2_HELD_MASK) == 0 \
			and c.move_effect_ids[0] == 0 and c.move_effect_ids[1] == 0:
		if c.stamina < data.rules.stamina_max or (previous & CombatState.FLAG_EXHAUSTED) != 0:
			_regenerate(c, data, t)
		return out

	var weapon: WeaponTicks = data.weapon(c.weapon_id)
	var edges: int = 0
	var held_flags: int = 0
	if (down & PlayerInput.DODGE) != 0:
		held_flags |= CombatState.FLAG_DODGE_HELD
		if (previous & CombatState.FLAG_DODGE_HELD) == 0:
			edges |= PlayerInput.DODGE
	if (down & PlayerInput.PRIMARY) != 0:
		held_flags |= CombatState.FLAG_PRIMARY_HELD
		if (previous & CombatState.FLAG_PRIMARY_HELD) == 0:
			edges |= PlayerInput.PRIMARY
	if (down & PlayerInput.BLOCK) != 0:
		held_flags |= CombatState.FLAG_BLOCK_HELD
		if (previous & CombatState.FLAG_BLOCK_HELD) == 0:
			edges |= PlayerInput.BLOCK
	c.combat_flags = (previous & ~(_HELD_FLAGS | CombatState.FLAG_NO_STAMINA)) | held_flags
	var held2: int = 0
	held2 |= _level(down, PlayerInput.ABILITY_1, CombatState.FLAG2_ABILITY_1_HELD)
	held2 |= _level(down, PlayerInput.ABILITY_2, CombatState.FLAG2_ABILITY_2_HELD)
	held2 |= _level(down, PlayerInput.ABILITY_3, CombatState.FLAG2_ABILITY_3_HELD)
	held2 |= _level(down, PlayerInput.SWAP_WEAPON, CombatState.FLAG2_SWAP_HELD)
	held2 |= _level(down, PlayerInput.CONSUMABLE_1, CombatState.FLAG2_CONSUMABLE_1_HELD)
	held2 |= _level(down, PlayerInput.CONSUMABLE_2, CombatState.FLAG2_CONSUMABLE_2_HELD)
	edges |= _edge(held2, previous2, CombatState.FLAG2_ABILITY_1_HELD, PlayerInput.ABILITY_1)
	edges |= _edge(held2, previous2, CombatState.FLAG2_ABILITY_2_HELD, PlayerInput.ABILITY_2)
	edges |= _edge(held2, previous2, CombatState.FLAG2_ABILITY_3_HELD, PlayerInput.ABILITY_3)
	edges |= _edge(held2, previous2, CombatState.FLAG2_SWAP_HELD, PlayerInput.SWAP_WEAPON)
	edges |= _edge(held2, previous2, CombatState.FLAG2_CONSUMABLE_1_HELD, PlayerInput.CONSUMABLE_1)
	edges |= _edge(held2, previous2, CombatState.FLAG2_CONSUMABLE_2_HELD, PlayerInput.CONSUMABLE_2)
	c.combat_flags2 = (previous2 & ~CombatState.FLAG2_HELD_MASK) | held2

	_finish_expired(c, data, weapon, t)
	AbilityRules.expire_move_effects(c, t)
	_regenerate(c, data, t)
	if weapon != null:
		_run_inputs(c, out, input, data, weapon, grounded, down, edges)
	else:
		c.buffered = 0
		c.primary_held = 0
	AbilityRules.commit(c, data, t)
	if weapon != null and c.weapon_id != weapon.id:
		weapon = data.weapon(c.weapon_id)
	_fill_output(c, out, data, weapon, t)
	AbilityRules.apply_move_effects(c, out, data)
	return out


# --- Consultas --------------------------------------------------------------------------------

## Fase de la acción en [param tick]: [constant PHASE_WINDUP] (anticipación, carga o lanzamiento),
## [constant PHASE_ACTIVE] (golpe activo, o activo o canalización de una habilidad),
## [constant PHASE_RECOVERY] o [constant PHASE_NONE] (la acción no tiene fases: también SWAP, DOWNED,
## REVIVE y EXECUTE).
static func phase(c: CombatState, tick: int) -> int:
	if c.action == _CHARGE:
		return PHASE_WINDUP
	if c.action == _ABILITY:
		var ability: AbilityTicks = CombatCatalog.ability(c.action_id)
		if ability == null:
			return PHASE_NONE
		return AbilityRules.phase_of(ability, tick - c.action_tick)
	if c.action != _LIGHT and c.action != _HEAVY:
		return PHASE_NONE
	var attack: AttackTicks = CombatCatalog.attack(c.action_id)
	if attack == null:
		return PHASE_NONE
	var relative: int = tick - c.action_tick
	if relative < attack.windup_ticks:
		return PHASE_WINDUP
	if relative < attack.active_to():
		return PHASE_ACTIVE
	return PHASE_RECOVERY


## true si hay un ataque en su golpe activo en [param tick] (solo LIGHT y HEAVY; el golpe de una
## habilidad lo da [method active_hit]).
static func is_attack_active(c: CombatState, tick: int) -> bool:
	if c.action != _LIGHT and c.action != _HEAVY:
		return false
	return phase(c, tick) == PHASE_ACTIVE


## El golpe que [param c] tiene activo en [param tick]: el ataque en su golpe activo o el golpe
## sintetizado ([member AbilityTicks.hit]) de la habilidad en su activo o su canalización; null si no
## hay ninguno. Sin forma ([member AttackTicks.shape] null) el golpe no prueba a nadie.
static func active_hit(c: CombatState, tick: int) -> AttackTicks:
	match c.action:
		_LIGHT, _HEAVY:
			var attack: AttackTicks = CombatCatalog.attack(c.action_id)
			if attack == null:
				return null
			var relative: int = tick - c.action_tick
			if relative >= attack.active_from() and relative < attack.active_to():
				return attack
		_ABILITY:
			var ability: AbilityTicks = CombatCatalog.ability(c.action_id)
			if ability == null:
				return null
			var relative_ability: int = tick - c.action_tick
			if relative_ability >= ability.active_from() and relative_ability < ability.active_to():
				return ability.hit
	return null


## true si [param tick] es el compromiso de la acción: el primer tick activo de un LIGHT, un HEAVY o
## una ABILITY (cuando salen los proyectiles y se fijan reutilizaciones y cargas).
static func is_commit_tick(c: CombatState, tick: int) -> bool:
	match c.action:
		_LIGHT, _HEAVY:
			var attack: AttackTicks = CombatCatalog.attack(c.action_id)
			return attack != null and tick - c.action_tick == attack.windup_ticks
		_ABILITY:
			var ability: AbilityTicks = CombatCatalog.ability(c.action_id)
			return ability != null and tick - c.action_tick == ability.cast_ticks
	return false


## Estado de la casilla [param slot] de la barra de acciones en [param tick]: 0-2 las habilidades
## del arma activa, [constant STATUS_SLOT_CONSUMABLE_1] y [constant STATUS_SLOT_CONSUMABLE_2] los
## consumibles. Devuelve un [enum AbilityStatus] (ver [method AbilityRules.status_of]).
static func ability_status(c: CombatState, slot: int, tick: int) -> int:
	return AbilityRules.status_of(c, slot, tick)


## true si el personaje está bloqueando (incluida la ventana de parada y la canalización que bloquea,
## el muro de escudos).
static func is_blocking(c: CombatState, tick: int) -> bool:
	if c.action == _ABILITY:
		return AbilityRules.is_blocking_channel(c, CombatCatalog.ability(c.action_id), tick)
	return c.action == _BLOCK


## true si [param tick] cae en la ventana de parada abierta al empezar el bloqueo.
static func is_parry_window(c: CombatState, tick: int) -> bool:
	if c.action != _BLOCK:
		return false
	var rules: CombatRules = CombatCatalog.rules()
	var opened_at: int = c.parry_ready_tick - rules.parry_cooldown_ticks
	if c.action_tick != opened_at:
		return false
	var elapsed: int = tick - opened_at
	return elapsed >= 0 and elapsed < rules.parry_window_ticks


## true si [param tick] cae en los ticks de invulnerabilidad de la esquiva.
static func is_invulnerable(c: CombatState, tick: int) -> bool:
	if c.action != _DODGE:
		return false
	var weapon: WeaponTicks = CombatCatalog.weapon(c.weapon_id)
	if weapon == null:
		return false
	var relative: int = tick - c.action_tick
	return relative >= weapon.dodge.invulnerable_from_ticks \
			and relative < weapon.dodge.invulnerable_to_ticks


## Banderas defensivas de [param tick] para [StateHistory]: [constant DEFENSE_BLOCKING],
## [constant DEFENSE_PARRY], [constant DEFENSE_INVULNERABLE], [constant DEFENSE_DEAD] y
## [constant DEFENSE_WIDE_BLOCK] (con BLOCKING, en la canalización que bloquea). Un derribado no
## tiene ninguna defensa.
static func defense_flags(c: CombatState, tick: int) -> int:
	var flags: int = 0
	if c.action == _BLOCK:
		flags |= DEFENSE_BLOCKING
		if is_parry_window(c, tick):
			flags |= DEFENSE_PARRY
	elif c.action == _DODGE:
		if is_invulnerable(c, tick):
			flags |= DEFENSE_INVULNERABLE
	elif c.action == _DEAD:
		flags |= DEFENSE_DEAD
	elif c.action == _ABILITY:
		if AbilityRules.is_blocking_channel(c, CombatCatalog.ability(c.action_id), tick):
			flags |= DEFENSE_BLOCKING | DEFENSE_WIDE_BLOCK
	return flags


## Byte de acción del registro de red (docs/habilidades.md, sección 5.5): bits 0-3 la acción, 4-5
## la fase ([method phase]) y 6-7 el paso del combo del ligero en curso o, en una ABILITY, su ranura
## (0-2; 3 = un consumible). En las demás acciones, 0 ([ActionWire] pone ahí el contador de reinicio
## de las que lo llevan).
static func action_byte(c: CombatState, tick: int) -> int:
	var step_bits: int = 0
	if c.action == _LIGHT:
		var weapon: WeaponTicks = CombatCatalog.weapon(c.weapon_id)
		if weapon != null:
			step_bits = clampi(weapon.light_index(c.action_id), 0, 2)
	elif c.action == _ABILITY:
		var ability: AbilityTicks = CombatCatalog.ability(c.action_id)
		if ability != null:
			step_bits = 3 if ability.is_consumable() else clampi(ability.slot, 0, 2)
	return (c.action & 15) | (phase(c, tick) << 4) | (step_bits << 6)


# --- Lo que impone el servidor ----------------------------------------------------------------
# Todas van seguidas de CombatDirector.commit_state (redondeo por encode/decode). Las que cambian la
# acción y cortan una canalización comprometida fijan su reutilización en ese tick.

## Tambaleo hasta [param until_tick] (exclusivo) con un empuje horizontal (x, z) en m/s que decae
## linealmente. Interrumpe lo que hiciera el personaje y borra el búfer, la pulsación y el combo.
## El empuje se redondea a cm/s, igual que al pasar por [method PlayerState.encode]. No hace nada
## sobre un derribado ni un muerto.
static func impose_stagger(c: CombatState, tick: int, until_tick: int, knockback: Vector2) -> void:
	if c.action == _DOWNED or c.action == _DEAD:
		return
	_leave_imposed(c, tick)
	c.action = _STAGGER
	c.action_id = 0
	c.action_tick = tick
	c.cc_until_tick = until_tick
	c.knockback = CombatState.quantize_knockback(knockback)


## Aturdimiento hasta [param until_tick] (exclusivo): el personaje solo frena. No hace nada sobre un
## derribado ni un muerto.
static func impose_stun(c: CombatState, tick: int, until_tick: int) -> void:
	if c.action == _DOWNED or c.action == _DEAD:
		return
	_leave_imposed(c, tick)
	c.action = _STUN
	c.action_id = 0
	c.action_tick = tick
	c.cc_until_tick = until_tick
	c.knockback = Vector2.ZERO


## Muerte: el personaje solo frena (la gravedad sigue) hasta [method reset_for_respawn].
static func impose_death(c: CombatState, tick: int) -> void:
	_leave_imposed(c, tick)
	c.action = _DEAD
	c.action_id = 0
	c.action_tick = tick
	c.cc_until_tick = 0
	c.knockback = Vector2.ZERO


## Derribado (docs/habilidades.md, sección 4.5): DOWNED con [code]action_tick = tick[/code]; borra el
## búfer, la pulsación, el combo y las ranuras de movimiento. Se arrastra a
## [member CombatRules.downed_move_scale] y no termina solo.
static func impose_downed(c: CombatState, tick: int) -> void:
	_leave_imposed(c, tick)
	c.action = _DOWNED
	c.action_id = 0
	c.action_tick = tick
	c.cc_until_tick = 0
	c.knockback = Vector2.ZERO
	clear_move_effects(c)


## Levantado: NONE con [code]action_tick = tick[/code].
static func impose_revived(c: CombatState, tick: int) -> void:
	_leave_imposed(c, tick)
	c.action = _NONE
	c.action_id = 0
	c.action_tick = tick
	c.cc_until_tick = 0
	c.knockback = Vector2.ZERO


## Levantar o rematar ([param action] REVIVE o EXECUTE; cualquier otra no hace nada) con
## [code]action_tick = tick[/code]. Acaba sola al cumplir [member CombatTables.revive_ticks] o
## [member CombatTables.execute_ticks], con una entrada real sin INTERACT o con una esquiva.
static func impose_interact(c: CombatState, tick: int, action: int) -> void:
	if action != _REVIVE and action != _EXECUTE:
		return
	_leave_imposed(c, tick)
	c.action = action
	c.action_id = 0
	c.action_tick = tick
	c.cc_until_tick = 0
	c.knockback = Vector2.ZERO


## Interrupción (docs/habilidades.md, sección 4.2): NONE, cortando beber, un lanzamiento marcado,
## levantar o rematar, y conservando el [member CombatState.action_tick] de lo que corta (como al
## acabar sin más). Antes del compromiso no hay reutilización ni gasto: solo un margen de
## [constant AbilityTicks.REARM_TICKS] ticks antes de otro consumible (o de la misma ranura), para que un
## remoto vea el NONE entre los dos (el byte de acción no los distingue; revisión de H5).
static func impose_interrupt(c: CombatState, tick: int) -> void:
	AbilityRules.rearm_after_interrupt(c, tick)
	_leave_imposed(c, tick)
	_to_none(c)


## Ocupa una ranura de efecto de movimiento con [param effect_id] ([StatusTicks]) hasta
## [param until_tick] (exclusivo): el mismo efecto alarga su ranura ([code]until = max[/code]); si no,
## una ranura libre; si no hay, sustituye a la que acaba antes.
static func impose_move_effect(c: CombatState, effect_id: int, until_tick: int) -> void:
	if effect_id <= 0:
		return
	for i: int in CombatState.MOVE_EFFECT_SLOTS:
		if c.move_effect_ids[i] == effect_id:
			c.move_effect_until[i] = maxi(c.move_effect_until[i], until_tick)
			return
	for i: int in CombatState.MOVE_EFFECT_SLOTS:
		if c.move_effect_ids[i] == 0:
			c.move_effect_ids[i] = effect_id
			c.move_effect_until[i] = until_tick
			return
	var earliest: int = 0
	for i: int in range(1, CombatState.MOVE_EFFECT_SLOTS):
		if c.move_effect_until[i] < c.move_effect_until[earliest]:
			earliest = i
	c.move_effect_ids[earliest] = effect_id
	c.move_effect_until[earliest] = until_tick


## Vacía la ranura de efecto de movimiento que ocupa [param effect_id] (si alguna lo lleva): el
## servidor la quita cuando el efecto se va antes de tiempo (su autor se da de baja, muere quien lo
## lleva).
static func remove_move_effect(c: CombatState, effect_id: int) -> void:
	for i: int in CombatState.MOVE_EFFECT_SLOTS:
		if c.move_effect_ids[i] == effect_id:
			c.move_effect_ids[i] = 0
			c.move_effect_until[i] = 0


## Vacía las dos ranuras de efectos de movimiento.
static func clear_move_effects(c: CombatState) -> void:
	for i: int in CombatState.MOVE_EFFECT_SLOTS:
		c.move_effect_ids[i] = 0
		c.move_effect_until[i] = 0


## Pone a 0 todas las reutilizaciones (las seis de las habilidades y la compartida de los
## consumibles).
static func reset_cooldowns(c: CombatState) -> void:
	c.ability_ready.fill(0)
	c.consumable_ready_tick = 0


## Cambia [b]solo[/b] las cargas de los consumibles (empaquetadas como
## [member CombatState.consumable_charges]): la recarga del campamento y el comando 16 no tocan arma,
## reutilizaciones, ranuras ni la acción en curso.
static func set_charges(c: CombatState, charges: int) -> void:
	c.consumable_charges = charges & 0xFF


## Equipo al aparecer (personaje recién creado o muerto): [param weapon_1] activa,
## [param weapon_2] en la otra ranura (0 = ninguna), reutilizaciones a 0, [param charges] y ranuras
## de movimiento vacías; conserva los bits de los botones pulsados. Sobre un vivo fuerza antes NONE
## (la acción en curso podía ser de otra arma) y borra búfer, pulsación y combo.
static func set_loadout(c: CombatState, weapon_1: int, weapon_2: int, charges: int) -> void:
	if c.action != _DEAD:
		_clear_transient(c)
		if c.action != _NONE:
			_to_none(c)
			c.cc_until_tick = 0
			c.knockback = Vector2.ZERO
	c.weapon_id = weapon_1
	c.alt_weapon_id = weapon_2
	c.combat_flags2 &= ~CombatState.FLAG2_SECOND_SLOT
	reset_cooldowns(c)
	set_charges(c, charges)
	clear_move_effects(c)


## Deja el combate como al aparecer por primera vez (resistencia llena, sin acción, control,
## parada, reutilizaciones ni efectos de movimiento) con el equipo de la plantilla: [param weapon_1]
## activa, [param weapon_2] en la otra ranura y [param charges]. Conserva los niveles de los botones
## (bits 3-5 de [member CombatState.combat_flags] y 1-6 de [member CombatState.combat_flags2]); los
## comandos de depuración (resistencia infinita, sin reutilizaciones) no.
static func reset_for_respawn(c: CombatState, tick: int, weapon_1: int, weapon_2: int,
		charges: int) -> void:
	var rules: CombatRules = CombatCatalog.rules()
	var held: int = c.combat_flags & _HELD_FLAGS
	var held2: int = c.combat_flags2 & CombatState.FLAG2_HELD_MASK
	c.copy_from(CombatState.initial(rules, weapon_1, weapon_2, charges))
	c.action_tick = tick
	c.stamina_regen_tick = tick
	c.combat_flags = held
	c.combat_flags2 = held2


## Resta [param amount] de resistencia (sin bajar de 0), retrasa la regeneración y, si llega a 0,
## activa el agotamiento. No hace nada con la resistencia infinita.
static func drain_stamina(c: CombatState, amount: int, tick: int) -> void:
	_spend(c, amount, tick, CombatCatalog.tables())


# Antes de imponer otra acción: la canalización comprometida que se corta fija su reutilización, y
# se borran el búfer, la pulsación y el combo.
static func _leave_imposed(c: CombatState, tick: int) -> void:
	AbilityRules.close_channel(c, CombatCatalog.tables(), tick, true)
	_clear_transient(c)


# --- Fin de acciones y resistencia ------------------------------------------------------------

# Paso 1: las acciones con duración que ya han terminado vuelven a NONE. DOWNED y DEAD no terminan
# solos.
static func _finish_expired(c: CombatState, data: CombatTables, weapon: WeaponTicks,
		t: int) -> void:
	match c.action:
		_LIGHT, _HEAVY:
			var attack: AttackTicks = data.attack(c.action_id)
			if attack == null or t >= c.action_tick + attack.total_ticks:
				# Sin una pulsación que enlace (PRIMARY guardada o enlace), el combo vuelve a empezar.
				var kind: int = c.buffered_type()
				var linked: bool = c.action == _LIGHT and attack != null \
						and (kind == CombatState.BUFFER_PRIMARY or kind == CombatState.BUFFER_LINK)
				_to_none(c)
				if not linked:
					c.combo_step = 0
		_DODGE:
			if weapon == null or t >= c.action_tick + weapon.dodge.duration_ticks:
				_to_none(c)
		_STAGGER, _STUN:
			if t >= c.cc_until_tick:
				_to_none(c)
		_ABILITY:
			AbilityRules.finish_ability(c, data, t)
		_SWAP:
			if t >= c.action_tick + data.swap_ticks:
				_to_none(c)
		_REVIVE:
			if t >= c.action_tick + data.revive_ticks:
				_to_none(c)
		_EXECUTE:
			if t >= c.action_tick + data.execute_ticks:
				_to_none(c)


# Paso 3: regeneración de resistencia (no en BLOCK, CHARGE, DODGE ni en la canalización que
# bloquea).
static func _regenerate(c: CombatState, data: CombatTables, t: int) -> void:
	if t < c.stamina_regen_tick:
		return
	if c.action == _BLOCK or c.action == _CHARGE or c.action == _DODGE:
		return
	if c.action == _ABILITY \
			and AbilityRules.is_blocking_channel(c, data.ability(c.action_id), t):
		return
	var rules: CombatRules = data.rules
	var exhausted: bool = (c.combat_flags & CombatState.FLAG_EXHAUSTED) != 0
	if c.stamina < rules.stamina_max:
		var rate: int = rules.stamina_regen_per_tick
		if exhausted:
			rate = rules.exhausted_regen_per_tick
		c.stamina = mini(c.stamina + rate, rules.stamina_max)
	if exhausted and c.stamina > rules.exhausted_exit_threshold:
		c.combat_flags &= ~CombatState.FLAG_EXHAUSTED


static func _spend(c: CombatState, amount: int, t: int, data: CombatTables) -> void:
	if amount <= 0 or (c.combat_flags & CombatState.FLAG_INFINITE_STAMINA) != 0:
		return
	c.stamina = maxi(c.stamina - amount, 0)
	c.stamina_regen_tick = t + data.regen_delay_ticks
	if c.stamina == 0:
		c.combat_flags |= CombatState.FLAG_EXHAUSTED


# true si el agotamiento impide esquivar, bloquear, cargar o el muro (la resistencia infinita lo
# ignora).
static func _is_blocked_by_exhaustion(c: CombatState) -> bool:
	return (c.combat_flags & CombatState.FLAG_EXHAUSTED) != 0 \
			and (c.combat_flags & CombatState.FLAG_INFINITE_STAMINA) == 0


# true si se puede pagar [param cost] (la resistencia infinita siempre puede).
static func _can_pay(c: CombatState, cost: int) -> bool:
	if (c.combat_flags & CombatState.FLAG_INFINITE_STAMINA) != 0:
		return true
	return c.stamina >= cost


# --- Entradas ---------------------------------------------------------------------------------

# Paso 4: 4a fines por entrada, 4b el búfer y 4c los flancos nuevos por prioridad.
static func _run_inputs(c: CombatState, out: Output, input: PlayerInput,
		data: CombatTables, weapon: WeaponTicks, grounded: bool, down: int, edges: int) -> void:
	var t: int = input.tick
	var rules: CombatRules = data.rules
	var real: bool = (input.buttons & PlayerInput.SUBSTITUTED) == 0
	if c.action == _DEAD or c.action == _DOWNED:
		c.buffered = 0
		c.primary_held = 0
		return

	# 4a: soltar el botón de una canalización (o moverse, si lo dice el dato) y soltar INTERACT.
	if real:
		AbilityRules.end_by_input(c, input, data, down)

	# 4b: el búfer, con prioridad sobre los flancos de este tick. Un cambio de arma del búfer cambia el
	# arma ya en este tick.
	_run_buffer(c, input, data, weapon, rules, grounded, down)
	if c.weapon_id != weapon.id:
		weapon = data.weapon(c.weapon_id)
		if weapon == null:
			return

	# 4c: DODGE > ABILITY_1 > ABILITY_2 > ABILITY_3 > CONSUMABLE_1 > CONSUMABLE_2 > PRIMARY > SWAP >
	# BLOCK. Un flanco que no puede ejecutarse ahora va al búfer (la última pulsación gana).
	if (edges & PlayerInput.DODGE) != 0:
		if _try_dodge(c, input, data, weapon, grounded) == _DODGE_RETRY:
			_store_buffer(c, rules, CombatState.BUFFER_DODGE)
	for slot: int in CombatState.ABILITY_SLOTS:
		if (edges & (PlayerInput.ABILITY_1 << slot)) != 0:
			if AbilityRules.try_ability(c, input, data, weapon, grounded, slot, down, false) \
					== AbilityRules.RETRY:
				_store_buffer(c, rules, CombatState.BUFFER_ABILITY_1 + slot)
	for index: int in CombatState.CONSUMABLE_SLOTS:
		if (edges & (PlayerInput.CONSUMABLE_1 << index)) != 0:
			if AbilityRules.try_consumable(c, input, data, weapon, grounded, index, down, false) \
					== AbilityRules.RETRY:
				_store_buffer(c, rules, CombatState.BUFFER_CONSUMABLE_1 + index)
	_run_primary(c, out, t, data, weapon, rules, grounded, real, down, edges)
	_run_charge(c, t, data, real, down)
	if (edges & PlayerInput.SWAP_WEAPON) != 0:
		var swap: int = AbilityRules.try_swap(c, data, weapon, t)
		if swap == AbilityRules.RETRY:
			_store_buffer(c, rules, CombatState.BUFFER_SWAP)
		elif swap == AbilityRules.STARTED:
			weapon = data.weapon(c.weapon_id)
			if weapon == null:
				return
	_run_block(c, t, rules, weapon, grounded, real, down, edges)


# Ejecuta lo que hubiera en el búfer en el primer tick en que se pueda; si no, le resta un tick. El
# despacho es por tipo (docs/habilidades.md, sección 3.1).
static func _run_buffer(c: CombatState, input: PlayerInput, data: CombatTables,
		weapon: WeaponTicks, rules: CombatRules, grounded: bool, down: int) -> void:
	var kind: int = c.buffered_type()
	if kind == CombatState.BUFFER_NONE:
		return
	var remaining: int = c.buffered_ticks()
	var done: bool = false
	match kind:
		CombatState.BUFFER_DODGE:
			done = _try_dodge(c, input, data, weapon, grounded) != _DODGE_RETRY
		CombatState.BUFFER_PRIMARY, CombatState.BUFFER_LINK:
			done = _try_start_light(c, input.tick, data, weapon, grounded)
		CombatState.BUFFER_ABILITY_1, CombatState.BUFFER_ABILITY_2, CombatState.BUFFER_ABILITY_3:
			done = AbilityRules.try_ability(c, input, data, weapon, grounded,
					kind - CombatState.BUFFER_ABILITY_1, down, true) != AbilityRules.RETRY
		CombatState.BUFFER_SWAP:
			done = AbilityRules.try_swap(c, data, weapon, input.tick) != AbilityRules.RETRY
		CombatState.BUFFER_CONSUMABLE_1, CombatState.BUFFER_CONSUMABLE_2:
			done = AbilityRules.try_consumable(c, input, data, weapon, grounded,
					kind - CombatState.BUFFER_CONSUMABLE_1, down, true) != AbilityRules.RETRY
		_:
			done = true
	if done:
		c.buffered = 0
		return
	if kind == CombatState.BUFFER_LINK:
		# El enlace espera a que acabe el ligero; si ya no hay ligero en curso (terminó sin poder
		# encadenar, o lo cortó otra acción) pasa a ser una pulsación guardada normal.
		if c.action != _LIGHT:
			_store_buffer(c, rules, CombatState.BUFFER_PRIMARY)
		return
	remaining -= 1
	if remaining <= 0:
		c.buffered = 0
		# Una pulsación que caduca sin haber empezado nada, con el ligero anterior ya terminado (el
		# enlace no pudo ejecutarse, p. ej. en el aire), no deja el combo a medias: el siguiente
		# ligero vuelve a ser el primero. Con un ligero en curso, su propio final lo decide. Vale para
		# cualquier tipo (docs/habilidades.md, sección 3.1): también una esquiva o una habilidad que
		# sustituyó en el búfer a la pulsación que enlazaba.
		if c.action != _LIGHT:
			c.combo_step = 0
	else:
		c.buffered = CombatState.pack_buffer(kind, remaining)


static func _store_buffer(c: CombatState, rules: CombatRules, kind: int) -> void:
	c.buffered = CombatState.pack_buffer(kind, clampi(rules.input_buffer_ticks, 1, 15))


# Intenta una esquiva en el tick de [param input]. Devuelve _DODGE_STARTED si empezó,
# _DODGE_RETRY si ahora no se puede (por la acción en curso o por estar en el aire: va al búfer) y
# _DODGE_DROPPED si falló por falta de resistencia o agotamiento (se descarta y se avisa a la
# interfaz) o por estar enraizado (se descarta sin aviso).
static func _try_dodge(c: CombatState, input: PlayerInput, data: CombatTables,
		weapon: WeaponTicks, grounded: bool) -> int:
	var t: int = input.tick
	var dodge: DodgeTicks = weapon.dodge
	var allowed: bool = false
	match c.action:
		_NONE, _BLOCK, _CHARGE, _REVIVE, _EXECUTE:
			allowed = true
		_LIGHT, _HEAVY:
			var attack: AttackTicks = data.attack(c.action_id)
			allowed = attack != null and t >= c.action_tick + attack.cancel_to_dodge_from_ticks
		_ABILITY:
			var ability: AbilityTicks = data.ability(c.action_id)
			allowed = ability == null or t >= c.action_tick + ability.cancel_to_dodge_from_ticks
	if (c.move_effect_ids[0] != 0 or c.move_effect_ids[1] != 0) \
			and AbilityRules.is_rooted(c, data):
		return _DODGE_DROPPED
	if not allowed or not grounded:
		return _DODGE_RETRY
	if _is_blocked_by_exhaustion(c) or not _can_pay(c, dodge.stamina_cost):
		c.combat_flags |= CombatState.FLAG_NO_STAMINA
		return _DODGE_DROPPED
	_spend(c, dodge.stamina_cost, t, data)
	# Desde una canalización, la acaba (con su reutilización si ya se comprometió).
	AbilityRules.close_channel(c, data, t, false)
	_clear_link(c)
	c.combat_flags &= ~CombatState.FLAG_LIGHT_OF_PRESS
	c.action = _DODGE
	c.action_id = 0
	c.action_tick = t
	c.combo_step = 0
	c.charge_ticks = 0
	c.action_dir = CombatState.quantize_yaw(_dodge_yaw(input))
	return _DODGE_STARTED


# Yaw del mundo hacia el que se esquiva: la dirección del movimiento relativa a la cámara, o hacia
# atrás si no hay movimiento.
static func _dodge_yaw(input: PlayerInput) -> float:
	if input.move.length() < _DODGE_MIN_MOVE:
		return input.look_yaw + PI
	return input.look_yaw + atan2(-input.move.x, input.move.y)


# true si el personaje puede empezar un ataque ahora: en el suelo y sin acción, bloqueando, en la
# parte cancelable de una esquiva o en la recuperación de una habilidad (o desde su
# cancel_to_attack_from).
static func _can_start_attack(c: CombatState, t: int, data: CombatTables, weapon: WeaponTicks,
		grounded: bool) -> bool:
	if not grounded:
		return false
	match c.action:
		_NONE, _BLOCK:
			return true
		_DODGE:
			return t >= c.action_tick + weapon.dodge.cancel_to_attack_from_ticks
		_ABILITY:
			var ability: AbilityTicks = data.ability(c.action_id)
			return ability == null or t - c.action_tick >= mini(ability.active_to(),
					ability.cancel_to_attack_from_ticks)
	return false


# Empieza el siguiente ligero del combo si se puede. Devuelve true si la pulsación queda
# consumida (el ligero empezó o se descartó por falta de resistencia).
static func _try_start_light(c: CombatState, t: int, data: CombatTables,
		weapon: WeaponTicks, grounded: bool) -> bool:
	if not _can_start_attack(c, t, data, weapon, grounded):
		return false
	var count: int = weapon.light_ids.size()
	if count == 0:
		return true
	var index: int = clampi(c.combo_step, 0, count - 1)
	var attack: AttackTicks = data.attack(weapon.light_ids[index])
	if attack == null:
		return true
	if attack.stamina_cost > 0 and not _can_pay(c, attack.stamina_cost):
		c.combat_flags |= CombatState.FLAG_NO_STAMINA
		return true
	_spend(c, attack.stamina_cost, t, data)
	AbilityRules.close_channel(c, data, t, false)
	_clear_link(c)
	c.action = _LIGHT
	c.action_id = attack.id
	c.action_tick = t
	c.combo_step = (index + 1) % count
	c.charge_ticks = 0
	# Es de la pulsación viva si el botón sigue abajo (flanco de este tick, o búfer o enlace que ella
	# dejó): mantenerla lo convierte en carga.
	if c.primary_held > 0 and (c.combat_flags & CombatState.FLAG_PRIMARY_HELD) != 0:
		c.combat_flags |= CombatState.FLAG_LIGHT_OF_PRESS
	else:
		c.combat_flags &= ~CombatState.FLAG_LIGHT_OF_PRESS
	return true


# PRIMARY: flanco, mantenido y soltado.
static func _run_primary(c: CombatState, out: Output, t: int, data: CombatTables,
		weapon: WeaponTicks, rules: CombatRules, grounded: bool, real: bool, down: int,
		edges: int) -> void:
	if (down & PlayerInput.PRIMARY) == 0:
		c.primary_held = 0
		c.combat_flags &= ~CombatState.FLAG_LIGHT_OF_PRESS
		return
	if (edges & PlayerInput.PRIMARY) != 0:
		# Mientras se carga, una pulsación nueva (tras soltar y esperar a la carga mínima) no hace
		# nada: la carga ya está decidida.
		if c.action == _CHARGE:
			return
		c.primary_held = 1
		if not _try_start_light(c, t, data, weapon, grounded):
			_buffer_primary(c, t, data, rules)
		return
	if not real or c.primary_held == 0:
		return
	c.primary_held = mini(c.primary_held + 1, 255)
	if c.primary_held >= rules.hold_to_heavy_ticks and c.action == _LIGHT:
		_try_charge(c, out, t, data, weapon)


# Guarda una pulsación de PRIMARY que no se puede ejecutar ahora. Dentro de la ventana de combo de
# un ligero (o hasta input_buffer_ticks antes) es un enlace, que espera a que acabe la
# recuperación; en cualquier otro caso es una pulsación normal del búfer.
static func _buffer_primary(c: CombatState, t: int, data: CombatTables,
		rules: CombatRules) -> void:
	if c.action == _LIGHT:
		var attack: AttackTicks = data.attack(c.action_id)
		if attack != null and attack.combo_window_ticks > 0:
			var end: int = c.action_tick + attack.total_ticks
			if t >= end - attack.combo_window_ticks - rules.input_buffer_ticks:
				c.buffered = CombatState.BUFFER_LINK
				return
	_store_buffer(c, rules, CombatState.BUFFER_PRIMARY)


# Convierte el ligero en carga del fuerte si todavía está en la anticipación, lo empezó esta
# pulsación y hay resistencia.
static func _try_charge(c: CombatState, out: Output, t: int, data: CombatTables,
		weapon: WeaponTicks) -> void:
	var attack: AttackTicks = data.attack(c.action_id)
	if attack == null or t - c.action_tick >= attack.windup_ticks:
		return
	# Si el ligero empezó antes de la pulsación viva, no es suyo. (No se deduce de primary_held: solo
	# cuenta ticks reales, y con una entrada sustituida de por medio t - primary_held + 1 deja de ser
	# el tick de la pulsación.)
	if (c.combat_flags & CombatState.FLAG_LIGHT_OF_PRESS) == 0:
		return
	var heavy: AttackTicks = data.attack(weapon.heavy_id)
	if heavy == null:
		return
	if _is_blocked_by_exhaustion(c) or not _can_pay(c, heavy.stamina_cost):
		c.combat_flags |= CombatState.FLAG_NO_STAMINA
		return
	_clear_link(c)
	c.combat_flags &= ~CombatState.FLAG_LIGHT_OF_PRESS
	c.action = _CHARGE
	c.action_id = heavy.id
	c.charge_ticks = 0
	out.snap_yaw = true


# Carga: lanza el fuerte al soltar (esperando a la carga mínima) o al llegar a la máxima.
static func _run_charge(c: CombatState, t: int, data: CombatTables, real: bool,
		down: int) -> void:
	if c.action != _CHARGE:
		return
	var heavy: AttackTicks = data.attack(c.action_id)
	if heavy == null:
		_to_none(c)
		return
	var charge: int = t - c.action_tick
	var live: bool = (down & PlayerInput.PRIMARY) != 0 and c.primary_held > 0
	if live:
		if real and charge >= heavy.charge_max_ticks:
			_launch_heavy(c, t, heavy, data)
		elif not real and charge >= heavy.charge_max_ticks + data.rules.input_buffer_ticks:
			# El cliente lleva más del búfer de entradas callado con la carga al máximo: se cancela
			# sin lanzar ni gastar. Si no, un cliente que deja de enviar (con la conexión viva)
			# guardaría el fuerte cargado todo el tiempo que quisiera y lo soltaría al instante.
			_to_none(c)
	elif charge >= heavy.charge_min_ticks:
		_launch_heavy(c, t, heavy, data)


static func _launch_heavy(c: CombatState, t: int, heavy: AttackTicks, data: CombatTables) -> void:
	if not _can_pay(c, heavy.stamina_cost):
		c.combat_flags |= CombatState.FLAG_NO_STAMINA
		_to_none(c)
		return
	_spend(c, heavy.stamina_cost, t, data)
	c.charge_ticks = clampi(t - c.action_tick, 0, heavy.charge_max_ticks)
	c.action = _HEAVY
	c.action_id = heavy.id
	c.action_tick = t
	c.combo_step = 0


# BLOCK: a nivel. Empieza desde NONE (también al acabar otra acción con el botón pulsado); solo un
# flanco real abre la ventana de parada, y solo si ha pasado el enfriamiento. Con un arma que no
# bloquea (el arco), no hace nada.
static func _run_block(c: CombatState, t: int, rules: CombatRules, weapon: WeaponTicks,
		grounded: bool, real: bool, down: int, edges: int) -> void:
	var block_down: bool = (down & PlayerInput.BLOCK) != 0
	if c.action == _BLOCK:
		if not block_down or not grounded or not weapon.can_block:
			_to_none(c)
		return
	if c.action != _NONE or not block_down or not grounded or not weapon.can_block:
		return
	if _is_blocked_by_exhaustion(c):
		return
	c.action = _BLOCK
	c.action_id = 0
	c.action_tick = t
	if (edges & PlayerInput.BLOCK) != 0 and real and t >= c.parry_ready_tick \
			and rules.parry_window_ticks > 0:
		c.parry_ready_tick = t + rules.parry_cooldown_ticks


# --- Movimiento permitido ---------------------------------------------------------------------

# Paso 6: la tabla de movimiento de docs/combate.md, sección 3.3, ampliada en docs/habilidades.md,
# sección 3.4, para la acción en curso.
static func _fill_output(c: CombatState, out: Output, data: CombatTables,
		weapon: WeaponTicks, t: int) -> void:
	match c.action:
		_LIGHT, _HEAVY:
			var attack: AttackTicks = data.attack(c.action_id)
			if attack == null:
				return
			out.scaled_movement = true
			out.move_scale = attack.move_speed_scale
			out.allow_jump = false
			out.allow_sprint = false
			var relative: int = t - c.action_tick
			if relative < attack.active_to():
				out.lunge_speed = attack.lunge_speed
				out.turn_rate = attack.turn_rate
				if relative == 0:
					out.snap_yaw = true
			else:
				out.turn_rate = 0.0
		_CHARGE:
			var heavy: AttackTicks = data.attack(c.action_id)
			if heavy == null:
				return
			out.scaled_movement = true
			out.move_scale = heavy.charge_move_scale
			out.turn_rate = heavy.charge_turn_rate
			out.allow_jump = false
			out.allow_sprint = false
		_BLOCK:
			if weapon == null:
				return
			out.scaled_movement = true
			out.move_scale = weapon.block_move_scale
			out.turn_rate = weapon.block_turn_rate
			out.allow_sprint = false
		_DODGE:
			if weapon == null:
				return
			var heading: float = CombatState.dequantize_yaw(c.action_dir)
			var speed: float = weapon.dodge.speed_at(t - c.action_tick)
			out.scaled_movement = true
			out.forced_velocity = true
			out.velocity = Vector3(-sin(heading) * speed, 0.0, -cos(heading) * speed)
			out.move_scale = 0.0
			out.turn_rate = 0.0
			out.allow_jump = false
			out.allow_sprint = false
		_STAGGER:
			out.scaled_movement = true
			out.move_scale = 0.0
			out.turn_rate = 0.0
			out.allow_jump = false
			out.allow_sprint = false
			var duration: int = c.cc_until_tick - c.action_tick
			if duration > 0 and c.knockback != Vector2.ZERO:
				var factor: float = clampf((c.cc_until_tick - t) / float(duration), 0.0, 1.0)
				out.forced_velocity = true
				out.velocity = Vector3(c.knockback.x * factor, 0.0, c.knockback.y * factor)
		_STUN, _DEAD:
			out.scaled_movement = true
			out.move_scale = 0.0
			out.turn_rate = 0.0
			out.allow_jump = false
			out.allow_sprint = false
		_ABILITY, _SWAP, _DOWNED, _REVIVE, _EXECUTE:
			AbilityRules.fill_output(c, out, data, t)


# --- Utilidades -------------------------------------------------------------------------------

# Bit de [param flag] si [param button] está abajo en [param down].
static func _level(down: int, button: int, flag: int) -> int:
	return flag if (down & button) != 0 else 0


# [param button] si el bit [param flag] está en [param held] y no lo estaba en [param previous].
static func _edge(held: int, previous: int, flag: int, button: int) -> int:
	return button if (held & flag) != 0 and (previous & flag) == 0 else 0


# Vuelve a NONE conservando el action_tick de lo que acaba (la muestra antigua del bloqueo lo usa:
# docs/habilidades.md, sección 4.2).
static func _to_none(c: CombatState) -> void:
	c.action = _NONE
	c.action_id = 0
	c.charge_ticks = 0
	c.combat_flags &= ~CombatState.FLAG_LIGHT_OF_PRESS


# Borra un enlace de combo pendiente: ya no tiene sentido cuando empieza otra acción.
static func _clear_link(c: CombatState) -> void:
	if c.buffered_type() == CombatState.BUFFER_LINK:
		c.buffered = 0


static func _clear_transient(c: CombatState) -> void:
	c.buffered = 0
	c.primary_held = 0
	c.combo_step = 0
	c.charge_ticks = 0
	c.combat_flags &= ~CombatState.FLAG_LIGHT_OF_PRESS
