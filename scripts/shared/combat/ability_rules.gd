class_name AbilityRules
extends RefCounted
## Segunda mitad de la máquina de acciones (docs/habilidades.md, secciones 3.3 a 3.6): habilidades,
## consumibles, canalizaciones, cambio de arma, levantar y rematar, derribado y efectos de movimiento.
## [br][br]
## La máquina se parte en dos archivos para que no crezca sin fin (docs/habilidades.md, sección 8),
## pero la entrada sigue siendo [method ActionMachine.step]: es la única que llama a estas funciones,
## en su orden fijo, y estas usan sus utilidades internas ([code]_to_none[/code],
## [code]_clear_link[/code], [code]_store_buffer[/code]...). Determinista como el resto de la máquina:
## sin reloj, sin azar y sin leer nada que no viaje en [PlayerState].
## [br][br]
## [b]Reutilizaciones.[/b] Son ticks absolutos en [member CombatState.ability_ready] (índices 0-2, las
## del arma activa; 3-5, las de la otra) y [member CombatState.consumable_ready_tick]. Una habilidad
## sin canalización fija la suya en el compromiso (el primer tick activo); una canalización, en el tick
## en que acaba, por la causa que sea, si ha llegado comprometida ([method close_channel]). El bit
## [constant CombatState.FLAG2_NO_COOLDOWNS] (comando 13) no fija ninguna ni gasta cargas.

## Resultado de intentar empezar una acción: no se puede ahora (va al búfer), empezó, o se descarta
## (no tiene sentido: ranura vacía, sin cargas, sin arma alternativa, avance con ROOT...).
const RETRY: int = 0
const STARTED: int = 1
const DROPPED: int = 2

## Longitud mínima del movimiento que rompe una canalización con
## [member AbilityTicks.channel_breaks_on_move].
const CHANNEL_MOVE_BREAK: float = 0.1

const _NONE: int = CombatState.Action.NONE
const _LIGHT: int = CombatState.Action.LIGHT
const _HEAVY: int = CombatState.Action.HEAVY
const _CHARGE: int = CombatState.Action.CHARGE
const _BLOCK: int = CombatState.Action.BLOCK
const _DODGE: int = CombatState.Action.DODGE
const _ABILITY: int = CombatState.Action.ABILITY
const _SWAP: int = CombatState.Action.SWAP
const _DOWNED: int = CombatState.Action.DOWNED
const _REVIVE: int = CombatState.Action.REVIVE
const _EXECUTE: int = CombatState.Action.EXECUTE


# --- Consultas --------------------------------------------------------------------------------

## Botón que mantiene [param ability]: ABILITY_1-3 según su ranura o CONSUMABLE_1-2 si es un
## consumible (0 si no tiene ninguno: no la lleva ningún arma).
static func button_of(ability: AbilityTicks) -> int:
	if ability.is_consumable():
		return PlayerInput.CONSUMABLE_1 << ability.consumable_index
	if ability.slot >= 0:
		return PlayerInput.ABILITY_1 << ability.slot
	return 0


## Índice de [member CombatState.ability_ready] de [param ability] en [param c]: su ranura si es del
## arma activa, la ranura + 3 si es de la otra, y -1 si no es de ninguna de las dos (o es un
## consumible).
static func ready_index(c: CombatState, ability: AbilityTicks) -> int:
	if ability.slot < 0:
		return -1
	if ability.weapon_id == c.weapon_id:
		return ability.slot
	if ability.weapon_id == c.alt_weapon_id:
		return ability.slot + CombatState.ABILITY_SLOTS
	return -1


## true si el comando 13 ha quitado las reutilizaciones y el gasto de cargas.
static func has_no_cooldowns(c: CombatState) -> bool:
	return (c.combat_flags2 & CombatState.FLAG2_NO_COOLDOWNS) != 0


## Fase de [param ability] [param relative] ticks después de empezar: 0 lanzamiento, 1 activo o
## canalización, 2 recuperación (las constantes PHASE_* de [ActionMachine]).
static func phase_of(ability: AbilityTicks, relative: int) -> int:
	if relative < ability.cast_ticks:
		return ActionMachine.PHASE_WINDUP
	if relative < ability.active_to():
		return ActionMachine.PHASE_ACTIVE
	return ActionMachine.PHASE_RECOVERY


## true si [param c] está en la canalización de [param ability] y esa canalización bloquea (el muro de
## escudos): desde el fin del lanzamiento hasta su tope.
static func is_blocking_channel(c: CombatState, ability: AbilityTicks, tick: int) -> bool:
	if ability == null or c.action != _ABILITY or not ability.channel or not ability.blocks:
		return false
	var relative: int = tick - c.action_tick
	return relative >= ability.cast_ticks and relative < ability.active_to()


## true si alguna ranura de efecto de movimiento enraíza (escala 0).
static func is_rooted(c: CombatState, data: CombatTables) -> bool:
	for i: int in CombatState.MOVE_EFFECT_SLOTS:
		var id: int = c.move_effect_ids[i]
		if id == 0:
			continue
		var status: StatusTicks = data.status(id)
		if status != null and _roots(status):
			return true
	return false


## true si la acción en curso de [param c] deja empezar una habilidad o un consumible en [param t]:
## NONE, BLOCK, CHARGE (cancela la carga sin gastar), DODGE desde su
## [member DodgeTicks.cancel_to_attack_from_ticks], LIGHT y HEAVY en su recuperación y ABILITY en su
## recuperación o desde su [member AbilityTicks.cancel_to_attack_from_ticks].
static func action_allows_ability(c: CombatState, data: CombatTables, weapon: WeaponTicks,
		t: int) -> bool:
	match c.action:
		_NONE, _BLOCK, _CHARGE:
			return true
		_DODGE:
			return weapon != null and t >= c.action_tick + weapon.dodge.cancel_to_attack_from_ticks
		_LIGHT, _HEAVY:
			var attack: AttackTicks = data.attack(c.action_id)
			return attack == null or t >= c.action_tick + attack.active_to()
		_ABILITY:
			var current: AbilityTicks = data.ability(c.action_id)
			return current == null or t - c.action_tick >= mini(current.active_to(),
					current.cancel_to_attack_from_ticks)
	return false


## Estado de la casilla [param slot] de la barra en [param tick] ([enum ActionMachine.AbilityStatus]):
## las ranuras 0-2 son las habilidades del arma activa y
## [constant ActionMachine.STATUS_SLOT_CONSUMABLE_1] y [constant ActionMachine.STATUS_SLOT_CONSUMABLE_2],
## los consumibles. Por orden: EMPTY (no hay nada), NO_CHARGES, COOLDOWN, BLOCKED (la acción en curso
## no la deja empezar, un avance con ROOT o el muro agotado) y READY. No mira el suelo (no viaja en
## [CombatState]).
static func status_of(c: CombatState, slot: int, tick: int) -> int:
	var data: CombatTables = CombatCatalog.tables()
	var ability: AbilityTicks = null
	var ready_tick: int = 0
	if slot >= 0 and slot < CombatState.ABILITY_SLOTS:
		var weapon: WeaponTicks = data.weapon(c.weapon_id)
		if weapon != null and weapon.ability_id(slot) != 0:
			ability = data.ability(weapon.ability_id(slot))
		ready_tick = c.ability_ready[slot]
	elif slot == ActionMachine.STATUS_SLOT_CONSUMABLE_1 \
			or slot == ActionMachine.STATUS_SLOT_CONSUMABLE_2:
		var index: int = slot - ActionMachine.STATUS_SLOT_CONSUMABLE_1
		if data.consumable_ids[index] != 0:
			ability = data.ability(data.consumable_ids[index])
		if ability != null and c.charges_of(index) <= 0:
			return ActionMachine.AbilityStatus.NO_CHARGES
		ready_tick = c.consumable_ready_tick
	if ability == null:
		return ActionMachine.AbilityStatus.EMPTY
	if tick < ready_tick and not has_no_cooldowns(c):
		return ActionMachine.AbilityStatus.COOLDOWN
	var weapon_now: WeaponTicks = data.weapon(c.weapon_id)
	if not action_allows_ability(c, data, weapon_now, tick) \
			or (ability.dash_distance_m > 0.0 and is_rooted(c, data)) \
			or (ability.blocks and ActionMachine._is_blocked_by_exhaustion(c)):
		return ActionMachine.AbilityStatus.BLOCKED
	return ActionMachine.AbilityStatus.READY


# --- Paso 1: fin de acciones ------------------------------------------------------------------

## Regla 1 para ABILITY: acaba en [code]t >= action_tick + total[/code]; una canalización, al llegar
## a su tope ([code]action_tick + cast + active[/code]) y con su reutilización.
static func finish_ability(c: CombatState, data: CombatTables, t: int) -> void:
	var ability: AbilityTicks = data.ability(c.action_id)
	if ability == null:
		ActionMachine._to_none(c)
	elif ability.channel:
		if t >= c.action_tick + ability.active_to():
			close_channel(c, data, t, false)
			ActionMachine._to_none(c)
	elif t >= c.action_tick + ability.total_ticks:
		ActionMachine._to_none(c)


## Al interrumpir en [param tick] una ABILITY de [param c] ([method ActionMachine.impose_interrupt]): la
## reutilización de su ranura (o la compartida, si es un consumible) pasa a ser como poco
## [code]tick + REARM_TICKS[/code] ([constant AbilityTicks.REARM_TICKS]). Sin esto, cortada antes del
## compromiso, otro consumible (o la misma ranura) podía empezar en [code]tick + 1[/code] con el mismo byte de
## acción, y un remoto que no muestrea ese único tick de NONE seguía el clip de la primera. Tras el compromiso
## la reutilización ya es mayor y no cambia.
static func rearm_after_interrupt(c: CombatState, tick: int) -> void:
	if c.action != _ABILITY:
		return
	var ability: AbilityTicks = CombatCatalog.tables().ability(c.action_id)
	if ability == null:
		return
	var ready: int = tick + AbilityTicks.REARM_TICKS
	if ability.is_consumable():
		c.consumable_ready_tick = maxi(c.consumable_ready_tick, ready)
		return
	var index: int = ready_index(c, ability)
	if index >= 0:
		c.ability_ready[index] = maxi(c.ability_ready[index], ready)


## Si [param c] está en una canalización comprometida, fija su reutilización en
## [code]tick + cooldown[/code] (regla 5): lo llama todo lo que la acaba o la corta, justo antes de
## cambiar la acción. [param after_step] es true si quien la corta lo hace después de simular
## [param tick] (el servidor al imponer otra acción: el compromiso de ese tick ya ha ocurrido) y false
## si es la propia máquina, dentro del tick y antes del compromiso: soltar o esquivar en el mismo tick
## del compromiso la cancela sin reutilización.
static func close_channel(c: CombatState, data: CombatTables, tick: int, after_step: bool) -> void:
	if c.action != _ABILITY:
		return
	var ability: AbilityTicks = data.ability(c.action_id)
	if ability == null or not ability.channel:
		return
	var elapsed: int = tick - c.action_tick
	var committed: bool = elapsed >= ability.cast_ticks if after_step \
			else elapsed > ability.cast_ticks
	if not committed or has_no_cooldowns(c):
		return
	var index: int = ready_index(c, ability)
	if index >= 0:
		c.ability_ready[index] = tick + ability.cooldown_ticks


# --- Paso 2: efectos de movimiento ------------------------------------------------------------

## Regla 2: vacía las ranuras de efectos de movimiento que acaban en [param t] o antes.
static func expire_move_effects(c: CombatState, t: int) -> void:
	for i: int in CombatState.MOVE_EFFECT_SLOTS:
		if c.move_effect_ids[i] != 0 and c.move_effect_until[i] <= t:
			c.move_effect_ids[i] = 0
			c.move_effect_until[i] = 0


# --- Paso 4: entradas -------------------------------------------------------------------------

## Regla 4a con una entrada real: una canalización con [member AbilityTicks.channel_hold] acaba si su
## botón no está abajo y una con [member AbilityTicks.channel_breaks_on_move], si hay movimiento (solo
## desde el fin del lanzamiento); REVIVE y EXECUTE acaban sin INTERACT. Todas vuelven a NONE.
static func end_by_input(c: CombatState, input: PlayerInput, data: CombatTables, down: int) -> void:
	match c.action:
		_ABILITY:
			var ability: AbilityTicks = data.ability(c.action_id)
			if ability == null or not ability.channel \
					or input.tick - c.action_tick < ability.cast_ticks:
				return
			var released: bool = ability.channel_hold and (down & button_of(ability)) == 0
			var moved: bool = ability.channel_breaks_on_move \
					and input.move.length() >= CHANNEL_MOVE_BREAK
			if released or moved:
				close_channel(c, data, input.tick, false)
				ActionMachine._to_none(c)
		_REVIVE, _EXECUTE:
			if (down & PlayerInput.INTERACT) == 0:
				ActionMachine._to_none(c)


## ABILITY_n (flanco o búfer, [param from_buffer]): intenta empezar la habilidad de la ranura
## [param slot] del arma activa. Devuelve [constant RETRY], [constant STARTED] o
## [constant DROPPED].
static func try_ability(c: CombatState, input: PlayerInput, data: CombatTables,
		weapon: WeaponTicks, grounded: bool, slot: int, down: int, from_buffer: bool) -> int:
	var id: int = weapon.ability_id(slot)
	if id == 0:
		return DROPPED
	var ability: AbilityTicks = data.ability(id)
	if ability == null:
		return DROPPED
	return _try_start(c, input, data, weapon, grounded, ability, c.ability_ready[slot], down,
			from_buffer)


## CONSUMABLE_n (flanco o búfer): intenta empezar el consumible [param index] (0 o 1) de las reglas.
## Sin cargas, o sin consumible, se descarta.
static func try_consumable(c: CombatState, input: PlayerInput, data: CombatTables,
		weapon: WeaponTicks, grounded: bool, index: int, down: int, from_buffer: bool) -> int:
	var id: int = data.consumable_ids[index]
	if id == 0 or c.charges_of(index) <= 0:
		return DROPPED
	var ability: AbilityTicks = data.ability(id)
	if ability == null:
		return DROPPED
	return _try_start(c, input, data, weapon, grounded, ability, c.consumable_ready_tick, down,
			from_buffer)


## SWAP (flanco o búfer): sin arma en la otra ranura se descarta; desde NONE, BLOCK, la recuperación
## de LIGHT, HEAVY o ABILITY y DODGE desde su [member DodgeTicks.cancel_to_attack_from_ticks],
## también en el aire, intercambia las armas y las dos mitades de las reutilizaciones en el primer
## tick. Nunca a mitad de anticipación, golpe activo, carga, lanzamiento o canalización: ahí, al búfer.
static func try_swap(c: CombatState, data: CombatTables, weapon: WeaponTicks, t: int) -> int:
	if c.alt_weapon_id == 0:
		return DROPPED
	var allowed: bool = false
	match c.action:
		_NONE, _BLOCK:
			allowed = true
		_LIGHT, _HEAVY:
			var attack: AttackTicks = data.attack(c.action_id)
			allowed = attack == null or t >= c.action_tick + attack.active_to()
		_ABILITY:
			var current: AbilityTicks = data.ability(c.action_id)
			allowed = current == null or t >= c.action_tick + current.active_to()
		_DODGE:
			allowed = weapon != null and t >= c.action_tick + weapon.dodge.cancel_to_attack_from_ticks
	if not allowed:
		return RETRY
	close_channel(c, data, t, false)
	ActionMachine._clear_link(c)
	c.combat_flags &= ~CombatState.FLAG_LIGHT_OF_PRESS
	c.action = _SWAP
	c.action_id = 0
	c.action_tick = t
	c.combo_step = 0
	c.charge_ticks = 0
	var active: int = c.weapon_id
	c.weapon_id = c.alt_weapon_id
	c.alt_weapon_id = active
	for i: int in CombatState.ABILITY_SLOTS:
		var ready: int = c.ability_ready[i]
		c.ability_ready[i] = c.ability_ready[i + CombatState.ABILITY_SLOTS]
		c.ability_ready[i + CombatState.ABILITY_SLOTS] = ready
	c.combat_flags2 ^= CombatState.FLAG2_SECOND_SLOT
	return STARTED


# Lo común a habilidades y consumibles: descartes, reutilización, acción en curso y suelo.
static func _try_start(c: CombatState, input: PlayerInput, data: CombatTables, weapon: WeaponTicks,
		grounded: bool, ability: AbilityTicks, ready_tick: int, down: int, from_buffer: bool) -> int:
	var t: int = input.tick
	if ability.dash_distance_m > 0.0 and is_rooted(c, data):
		return DROPPED
	if ability.blocks and ActionMachine._is_blocked_by_exhaustion(c):
		# El agotamiento impide el muro, como BLOCK (docs/habilidades.md, sección 2.4).
		c.combat_flags |= CombatState.FLAG_NO_STAMINA
		return DROPPED
	if from_buffer and ability.channel and ability.channel_hold \
			and (down & button_of(ability)) == 0:
		# Una canalización que se mantiene no sale del búfer con su botón ya suelto.
		return DROPPED
	if t < ready_tick and not has_no_cooldowns(c):
		return RETRY
	if not action_allows_ability(c, data, weapon, t):
		return RETRY
	if not grounded and not ability.usable_in_air:
		return RETRY
	close_channel(c, data, t, false)
	ActionMachine._clear_link(c)
	c.combat_flags &= ~CombatState.FLAG_LIGHT_OF_PRESS
	c.action = _ABILITY
	c.action_id = ability.id
	c.action_tick = t
	c.action_dir = CombatState.quantize_yaw(_dash_yaw(ability, input))
	c.combo_step = 0
	c.charge_ticks = 0
	return STARTED


# Yaw del mundo del avance según [member AbilityTicks.dash_direction]: hacia la cámara, hacia atrás o
# según el movimiento (como la esquiva).
static func _dash_yaw(ability: AbilityTicks, input: PlayerInput) -> float:
	match ability.dash_direction:
		1:
			return input.look_yaw + PI
		2:
			return ActionMachine._dodge_yaw(input)
	return input.look_yaw


# --- Paso 5: compromiso -----------------------------------------------------------------------

## Regla 5: en el primer tick activo ([code]t == action_tick + cast[/code]) de una ABILITY, un
## consumible gasta una carga y fija la reutilización compartida; una habilidad sin canalización fija
## la suya (la canalización, al acabar); los dos devuelven [member AbilityTicks.stamina_restore] de
## resistencia sin pasar del máximo.
static func commit(c: CombatState, data: CombatTables, t: int) -> void:
	if c.action != _ABILITY:
		return
	var ability: AbilityTicks = data.ability(c.action_id)
	if ability == null or t != c.action_tick + ability.cast_ticks:
		return
	if not has_no_cooldowns(c):
		if ability.is_consumable():
			var index: int = ability.consumable_index
			var left: int = maxi(c.charges_of(index) - 1, 0)
			var mask: int = CombatState.MAX_CHARGES << (4 * index)
			c.consumable_charges = (c.consumable_charges & ~mask) | (left << (4 * index))
			c.consumable_ready_tick = t + data.consumable_cooldown_ticks
		elif not ability.channel:
			var slot_index: int = ready_index(c, ability)
			if slot_index >= 0:
				c.ability_ready[slot_index] = t + ability.cooldown_ticks
	if ability.stamina_restore > 0:
		var rules: CombatRules = data.rules
		c.stamina = mini(c.stamina + ability.stamina_restore, rules.stamina_max)
		if c.is_exhausted() and c.stamina > rules.exhausted_exit_threshold:
			c.combat_flags &= ~CombatState.FLAG_EXHAUSTED


# --- Paso 6: movimiento -----------------------------------------------------------------------

## Regla 6 (docs/habilidades.md, sección 3.4) para ABILITY, SWAP, DOWNED, REVIVE y EXECUTE.
static func fill_output(c: CombatState, out: ActionMachine.Output, data: CombatTables,
		t: int) -> void:
	match c.action:
		_ABILITY:
			var ability: AbilityTicks = data.ability(c.action_id)
			if ability == null:
				return
			_restrict(out, ability.move_speed_scale)
			var relative: int = t - c.action_tick
			if relative == 0:
				out.snap_yaw = true
			if ability.is_dashing(relative):
				# Avance impuesto, como la esquiva: sin aceleración y sin giro.
				var heading: float = CombatState.dequantize_yaw(c.action_dir)
				var speed: float = ability.dash_speed_at(relative)
				out.forced_velocity = true
				out.velocity = Vector3(-sin(heading) * speed, 0.0, -cos(heading) * speed)
				out.move_scale = 0.0
				out.turn_rate = 0.0
			elif relative < ability.active_to():
				out.turn_rate = ability.turn_rate
				if not ability.channel or relative < ability.cast_ticks:
					out.lunge_speed = ability.lunge_speed
			else:
				out.turn_rate = 0.0
		_SWAP:
			_restrict(out, data.rules.swap_move_scale)
			out.turn_rate = -1.0
		_DOWNED:
			_restrict(out, data.rules.downed_move_scale)
			out.turn_rate = data.rules.downed_turn_rate
		_REVIVE, _EXECUTE:
			_restrict(out, 0.0)
			out.turn_rate = 0.0


## Efectos de movimiento: [member ActionMachine.Output.speed_factor] = (la menor escala < 1 de las
## ranuras, o 1) × (la mayor > 1, o 1), que [method PlayerCharacter.simulate] aplica a la velocidad
## objetivo no impuesta; ROOT (escala 0) pone además [member ActionMachine.Output.rooted]: sin salto y,
## en el aire, frena.
static func apply_move_effects(c: CombatState, out: ActionMachine.Output, data: CombatTables) -> void:
	if c.move_effect_ids[0] == 0 and c.move_effect_ids[1] == 0:
		return
	var slowest: float = 1.0
	var fastest: float = 1.0
	for i: int in CombatState.MOVE_EFFECT_SLOTS:
		var id: int = c.move_effect_ids[i]
		if id == 0:
			continue
		var status: StatusTicks = data.status(id)
		if status == null:
			continue
		slowest = minf(slowest, status.move_speed_scale)
		fastest = maxf(fastest, status.move_speed_scale)
		if _roots(status):
			out.rooted = true
	out.speed_factor = maxf(slowest, 0.0) * fastest
	if out.rooted:
		out.allow_jump = false


static func _restrict(out: ActionMachine.Output, move_scale: float) -> void:
	out.scaled_movement = true
	out.move_scale = move_scale
	out.allow_jump = false
	out.allow_sprint = false


static func _roots(status: StatusTicks) -> bool:
	return status.kind == StatusEffectDefinition.Kind.ROOT or status.move_speed_scale <= 0.0
