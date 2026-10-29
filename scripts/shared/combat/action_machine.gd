class_name ActionMachine
extends RefCounted
## Máquina de acciones del combate (docs/combate.md, sección 3): ataques ligeros en combo, ataque
## fuerte cargado, bloqueo con parada, esquiva, resistencia y los controles que impone el
## servidor. Es una función determinista de ([CombatState], [PlayerInput], suelo): sin reloj, sin
## aleatoriedad y sin leer nada que no viaje en [PlayerState].
## [br][br]
## [method step] la llama [method PlayerCharacter.simulate] al principio de cada tick, antes del
## movimiento, y devuelve en un [ActionMachine.Output] cómo debe moverse el personaje ese tick.
## El resto de funciones estáticas son consultas (las usan el servidor y el animador) y las
## órdenes que impone el servidor ([method impose_stagger]...).
## [br][br]
## [b]Orden de cada tick[/b] (con [code]t = input.tick[/code]): 1) acciones que terminan; 2)
## regeneración de resistencia; 3) entradas: primero el búfer, luego DODGE, PRIMARY y BLOCK
## (prioridad DODGE > PRIMARY > BLOCK); 4) el [ActionMachine.Output].
## [br][br]
## [b]Flancos.[/b] Los saca de los bits [constant CombatState.FLAG_DODGE_HELD] y compañeros de
## [member CombatState.combat_flags] (el nivel de cada botón en el tick anterior), así que la
## firma de [method step] no necesita [member PlayerCharacter.prev_buttons]. Una entrada
## sustituida ([constant PlayerInput.SUBSTITUTED]) repite los botones y por tanto no crea
## flancos; además no suma a [member CombatState.primary_held], no convierte un ligero en carga,
## no lanza el fuerte al llegar a la carga máxima y no abre ventanas de parada.

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


## Fases de un ataque ([method phase]).
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

const _NONE: int = CombatState.Action.NONE
const _LIGHT: int = CombatState.Action.LIGHT
const _HEAVY: int = CombatState.Action.HEAVY
const _CHARGE: int = CombatState.Action.CHARGE
const _BLOCK: int = CombatState.Action.BLOCK
const _DODGE: int = CombatState.Action.DODGE
const _STAGGER: int = CombatState.Action.STAGGER
const _STUN: int = CombatState.Action.STUN
const _DEAD: int = CombatState.Action.DEAD

## Por debajo de esta longitud el movimiento no da dirección a la esquiva (se esquiva hacia atrás).
const _DODGE_MIN_MOVE: float = 0.1
const _COMBAT_BUTTONS: int = PlayerInput.DODGE | PlayerInput.PRIMARY | PlayerInput.BLOCK
const _HELD_FLAGS: int = (
	CombatState.FLAG_DODGE_HELD | CombatState.FLAG_BLOCK_HELD | CombatState.FLAG_PRIMARY_HELD
)

# Resultado de intentar una esquiva: no se puede ahora (va al búfer), empezó, o se descarta por
# falta de resistencia.
const _DODGE_RETRY: int = 0
const _DODGE_STARTED: int = 1
const _DODGE_DROPPED: int = 2


## Avanza la máquina un tick con [param input] y devuelve cómo se mueve el personaje.
## [param grounded] es si estaba en el suelo al empezar el tick.
static func step(c: CombatState, input: PlayerInput, grounded: bool) -> ActionMachine.Output:
	var out := Output.new()
	var data: CombatTables = CombatCatalog.tables()
	var rules: CombatRules = data.rules
	var t: int = input.tick

	# Niveles y flancos de los botones (el bit SUBSTITUTED no es un botón).
	var down: int = input.buttons & ~PlayerInput.SUBSTITUTED
	var previous: int = c.combat_flags

	# Camino rápido, el de casi todos los ticks: sin acción, sin botones de combate (ni pulsados
	# ni recién soltados), nada pendiente. Solo puede cambiar la resistencia al regenerar.
	if c.action == _NONE and c.buffered == 0 and c.primary_held == 0 \
			and (down & _COMBAT_BUTTONS) == 0 \
			and (previous & (_HELD_FLAGS | CombatState.FLAG_NO_STAMINA)) == 0:
		if c.stamina < rules.stamina_max or (previous & CombatState.FLAG_EXHAUSTED) != 0:
			_regenerate(c, rules, t)
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

	_finish_expired(c, data, weapon, t)
	_regenerate(c, rules, t)
	if weapon != null:
		_run_inputs(c, out, input, data, weapon, rules, grounded, down, edges)
	else:
		c.buffered = 0
		c.primary_held = 0
	_fill_output(c, out, data, weapon, t)
	return out


# --- Consultas --------------------------------------------------------------------------------

## Fase de la acción en [param tick]: [constant PHASE_WINDUP] (anticipación o carga),
## [constant PHASE_ACTIVE], [constant PHASE_RECOVERY] o [constant PHASE_NONE] (la acción no tiene
## fases).
static func phase(c: CombatState, tick: int) -> int:
	if c.action == _CHARGE:
		return PHASE_WINDUP
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


## true si hay un ataque en su golpe activo en [param tick].
static func is_attack_active(c: CombatState, tick: int) -> bool:
	if c.action != _LIGHT and c.action != _HEAVY:
		return false
	return phase(c, tick) == PHASE_ACTIVE


## true si el personaje está bloqueando (incluida la ventana de parada).
static func is_blocking(c: CombatState, _tick: int) -> bool:
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
## [constant DEFENSE_PARRY], [constant DEFENSE_INVULNERABLE] y [constant DEFENSE_DEAD].
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
	return flags


## Byte de acción del registro de red: bits 0-3 la acción, 4-5 la fase y 6-7 el paso del combo
## del ligero en curso (0 en las demás acciones).
static func action_byte(c: CombatState, tick: int) -> int:
	var combo_index: int = 0
	if c.action == _LIGHT:
		var weapon: WeaponTicks = CombatCatalog.weapon(c.weapon_id)
		if weapon != null:
			combo_index = clampi(weapon.light_index(c.action_id), 0, 2)
	return (c.action & 15) | (phase(c, tick) << 4) | (combo_index << 6)


# --- Lo que impone el servidor ----------------------------------------------------------------

## Tambaleo hasta [param until_tick] (exclusivo) con un empuje horizontal (x, z) en m/s que decae
## linealmente. Interrumpe lo que hiciera el personaje y borra el búfer, la pulsación y el combo.
## El empuje se redondea a cm/s, igual que al pasar por [method PlayerState.encode].
static func impose_stagger(c: CombatState, tick: int, until_tick: int, knockback: Vector2) -> void:
	_clear_transient(c)
	c.action = _STAGGER
	c.action_id = 0
	c.action_tick = tick
	c.cc_until_tick = until_tick
	c.knockback = CombatState.quantize_knockback(knockback)


## Aturdimiento hasta [param until_tick] (exclusivo): el personaje solo frena.
static func impose_stun(c: CombatState, tick: int, until_tick: int) -> void:
	_clear_transient(c)
	c.action = _STUN
	c.action_id = 0
	c.action_tick = tick
	c.cc_until_tick = until_tick
	c.knockback = Vector2.ZERO


## Muerte: el personaje solo frena (la gravedad sigue) hasta [method reset_for_respawn].
static func impose_death(c: CombatState, tick: int) -> void:
	_clear_transient(c)
	c.action = _DEAD
	c.action_id = 0
	c.action_tick = tick
	c.cc_until_tick = 0
	c.knockback = Vector2.ZERO


## Deja el combate como al aparecer por primera vez (resistencia llena, sin acción, control ni
## parada pendiente) conservando el arma y los niveles de los botones.
static func reset_for_respawn(c: CombatState, tick: int) -> void:
	var rules: CombatRules = CombatCatalog.rules()
	var held: int = c.combat_flags & _HELD_FLAGS
	var weapon: int = c.weapon_id
	c.copy_from(CombatState.initial(rules, weapon))
	c.action_tick = tick
	c.stamina_regen_tick = tick
	c.combat_flags = held


## Resta [param amount] de resistencia (sin bajar de 0), retrasa la regeneración y, si llega a 0,
## activa el agotamiento. No hace nada con la resistencia infinita.
static func drain_stamina(c: CombatState, amount: int, tick: int) -> void:
	_spend(c, amount, tick, CombatCatalog.tables())


# --- Fin de acciones y resistencia ------------------------------------------------------------

# Paso 1: las acciones con duración que ya han terminado vuelven a NONE.
static func _finish_expired(c: CombatState, data: CombatTables, weapon: WeaponTicks,
		t: int) -> void:
	match c.action:
		_LIGHT, _HEAVY:
			var attack: AttackTicks = data.attack(c.action_id)
			if attack == null or t >= c.action_tick + attack.total_ticks:
				# Sin una pulsación que enlace, el combo vuelve a empezar.
				var linked: bool = c.action == _LIGHT and attack != null \
						and (c.buffered & 3) != CombatState.BUFFER_NONE \
						and (c.buffered & 3) != CombatState.BUFFER_DODGE
				_to_none(c)
				if not linked:
					c.combo_step = 0
		_DODGE:
			if weapon == null or t >= c.action_tick + weapon.dodge.duration_ticks:
				_to_none(c)
		_STAGGER, _STUN:
			if t >= c.cc_until_tick:
				_to_none(c)


# Paso 2: regeneración de resistencia.
static func _regenerate(c: CombatState, rules: CombatRules, t: int) -> void:
	if t < c.stamina_regen_tick:
		return
	if c.action == _BLOCK or c.action == _CHARGE or c.action == _DODGE:
		return
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


# true si el agotamiento impide esquivar, bloquear o cargar (la resistencia infinita lo ignora).
static func _is_blocked_by_exhaustion(c: CombatState) -> bool:
	return (c.combat_flags & CombatState.FLAG_EXHAUSTED) != 0 \
			and (c.combat_flags & CombatState.FLAG_INFINITE_STAMINA) == 0


# true si se puede pagar [param cost] (la resistencia infinita siempre puede).
static func _can_pay(c: CombatState, cost: int) -> bool:
	if (c.combat_flags & CombatState.FLAG_INFINITE_STAMINA) != 0:
		return true
	return c.stamina >= cost


# --- Entradas ---------------------------------------------------------------------------------

# Paso 3: el búfer (con prioridad), DODGE, PRIMARY y BLOCK.
static func _run_inputs(c: CombatState, out: Output, input: PlayerInput,
		data: CombatTables, weapon: WeaponTicks, rules: CombatRules, grounded: bool,
		down: int, edges: int) -> void:
	var t: int = input.tick
	var real: bool = (input.buttons & PlayerInput.SUBSTITUTED) == 0
	if c.action == _DEAD:
		c.buffered = 0
		c.primary_held = 0
		return

	_run_buffer(c, input, data, weapon, rules, grounded)

	if (edges & PlayerInput.DODGE) != 0:
		var result: int = _try_dodge(c, input, data, weapon, grounded)
		if result == _DODGE_RETRY:
			_store_buffer(c, rules, CombatState.BUFFER_DODGE)

	_run_primary(c, out, t, data, weapon, rules, grounded, real, down, edges)
	_run_charge(c, t, data, real, down)
	_run_block(c, t, rules, grounded, real, down, edges)


# Ejecuta lo que hubiera en el búfer en el primer tick en que se pueda; si no, le resta un tick.
static func _run_buffer(c: CombatState, input: PlayerInput, data: CombatTables,
		weapon: WeaponTicks, rules: CombatRules, grounded: bool) -> void:
	var kind: int = c.buffered & 3
	if kind == CombatState.BUFFER_NONE:
		return
	var remaining: int = (c.buffered >> 2) & 15
	var done: bool = false
	if kind == CombatState.BUFFER_DODGE:
		done = _try_dodge(c, input, data, weapon, grounded) != _DODGE_RETRY
	else:
		done = _try_start_light(c, input.tick, data, weapon, grounded)
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
	else:
		c.buffered = kind | (remaining << 2)


static func _store_buffer(c: CombatState, rules: CombatRules, kind: int) -> void:
	c.buffered = kind | (clampi(rules.input_buffer_ticks, 1, 15) << 2)


# Intenta una esquiva en el tick de [param input]. Devuelve _DODGE_STARTED si empezó,
# _DODGE_RETRY si ahora no se puede (por la acción en curso o por estar en el aire: va al búfer) y
# _DODGE_DROPPED si falló por falta de resistencia o agotamiento (se descarta y se avisa a la
# interfaz).
static func _try_dodge(c: CombatState, input: PlayerInput, data: CombatTables,
		weapon: WeaponTicks, grounded: bool) -> int:
	var t: int = input.tick
	var dodge: DodgeTicks = weapon.dodge
	var allowed: bool = false
	match c.action:
		_NONE, _BLOCK, _CHARGE:
			allowed = true
		_LIGHT, _HEAVY:
			var attack: AttackTicks = data.attack(c.action_id)
			allowed = attack != null and t >= c.action_tick + attack.cancel_to_dodge_from_ticks
	if not allowed or not grounded:
		return _DODGE_RETRY
	if _is_blocked_by_exhaustion(c) or not _can_pay(c, dodge.stamina_cost):
		c.combat_flags |= CombatState.FLAG_NO_STAMINA
		return _DODGE_DROPPED
	_spend(c, dodge.stamina_cost, t, data)
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


# true si el personaje puede empezar un ataque ahora: en el suelo y sin acción, bloqueando o en la
# parte cancelable de una esquiva.
static func _can_start_attack(c: CombatState, t: int, weapon: WeaponTicks,
		grounded: bool) -> bool:
	if not grounded:
		return false
	if c.action == _NONE or c.action == _BLOCK:
		return true
	return c.action == _DODGE and t >= c.action_tick + weapon.dodge.cancel_to_attack_from_ticks


# Empieza el siguiente ligero del combo si se puede. Devuelve true si la pulsación queda
# consumida (el ligero empezó o se descartó por falta de resistencia).
static func _try_start_light(c: CombatState, t: int, data: CombatTables,
		weapon: WeaponTicks, grounded: bool) -> bool:
	if not _can_start_attack(c, t, weapon, grounded):
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
# flanco real abre la ventana de parada, y solo si ha pasado el enfriamiento.
static func _run_block(c: CombatState, t: int, rules: CombatRules, grounded: bool, real: bool,
		down: int, edges: int) -> void:
	var block_down: bool = (down & PlayerInput.BLOCK) != 0
	if c.action == _BLOCK:
		if not block_down or not grounded:
			_to_none(c)
		return
	if c.action != _NONE or not block_down or not grounded:
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

# Paso 4: la tabla de movimiento de la sección 3.3 para la acción en curso.
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


# --- Utilidades -------------------------------------------------------------------------------

static func _to_none(c: CombatState) -> void:
	c.action = _NONE
	c.action_id = 0
	c.charge_ticks = 0
	c.combat_flags &= ~CombatState.FLAG_LIGHT_OF_PRESS


# Borra un enlace de combo pendiente: ya no tiene sentido cuando empieza otra acción.
static func _clear_link(c: CombatState) -> void:
	if (c.buffered & 3) == CombatState.BUFFER_LINK:
		c.buffered = 0


static func _clear_transient(c: CombatState) -> void:
	c.buffered = 0
	c.primary_held = 0
	c.combo_step = 0
	c.charge_ticks = 0
	c.combat_flags &= ~CombatState.FLAG_LIGHT_OF_PRESS
