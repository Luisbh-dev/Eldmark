class_name CombatAnimationLayer
extends RefCounted
## Capa de animación de combate de un personaje (ART-08), por encima de la locomoción. Lee la acción
## en curso, elige el clip con [CombatClipPlanner] y mantiene hasta dos [Slot]: el clip actual y el
## anterior, que se desvanece mientras entra el nuevo. El [CombatPoseModifier] los aplica al esqueleto
## ya con la pose de la locomoción.
## [br][br]
## [b]Dos orígenes de la acción[/b]:
## [br]- [method update_local]: el jugador local (y el sandbox) lee su [CombatState] y el tick de la
## simulación. El instante del clip es una función del estado ([code]tick - action_tick[/code] más la
## fracción de interpolación), así que una reconciliación que repita ticks no reinicia nada mientras
## la clave [code](action, action_id, action_tick)[/code] sea la misma; si el servidor impone otra
## acción (un tambaleo), la clave cambia y hay fundido al clip nuevo.
## [br]- [method update_remote]: un remoto solo trae el byte [code]action[/code] de su registro (bits
## 0-3 la acción, 4-5 la fase, 6-7 el paso del combo). El instante se cuenta en tiempo real desde el
## momento en que se ve entrar en cada fase, y cada cambio de fase reajusta el clip al principio de
## su tramo, de modo que el contacto sigue cayendo en la ventana activa con la precisión de los
## snapshots.
## [br][br]
## Sin acción, el clip actual se desvanece ([member CombatActionAnim.blend_out_s]) y la capa queda
## inactiva.

## Clip en curso (o saliente) con su peso.
class Slot:
	var key: StringName = &""
	var animation_name: StringName = &""
	var animation: Animation = null
	var time_s: float = 0.0
	var speed: float = 0.0
	var weight: float = 0.0
	var target: float = 1.0
	var upper_body: bool = false
	var hold: bool = false
	var blend_in_s: float = 0.06
	var blend_out_s: float = 0.12
	var length_s: float = 0.0

var clips: CombatClipSet = null
var _weapon: WeaponTicks = null
var _current: Slot = null
var _previous: Slot = null
var _plan: CombatClipPlanner.Plan = null
# Seguimiento del byte action de un remoto.
var _remote_action: int = -1
var _remote_combo: int = -1
var _remote_phase: int = -1
var _remote_elapsed: float = 0.0


func _init(clip_set: CombatClipSet = null) -> void:
	clips = clip_set
	_weapon = CombatCatalog.weapon(CombatCatalog.default_weapon_id())


# --- Entrada ----------------------------------------------------------------------------------

## Actualiza la capa con el estado de combate del personaje local en el tick [param tick] de la
## simulación, con [param fraction] (0 a 1) de la interpolación de física, y avanza
## [param delta] segundos de pesos.
func update_local(state: CombatState, tick: int, fraction: float, delta: float) -> void:
	var plan: CombatClipPlanner.Plan = null
	if state.action != CombatState.Action.NONE:
		var weapon: WeaponTicks = CombatCatalog.weapon(state.weapon_id)
		if weapon == null:
			weapon = _weapon
		var phase: int = ActionMachine.phase(state, tick)
		var combo: int = weapon.light_index(state.action_id) \
				if state.action == CombatState.Action.LIGHT else 0
		var elapsed: float = float(tick - state.action_tick) + fraction
		var in_phase: float = elapsed
		if phase != ActionMachine.PHASE_NONE:
			var attack: AttackTicks = CombatCatalog.attack(state.action_id)
			if attack != null and (state.action == CombatState.Action.LIGHT
					or state.action == CombatState.Action.HEAVY):
				in_phase = elapsed - float(CombatClipPlanner.phase_start_ticks(attack, phase))
		var control_ticks: int = maxi(state.cc_until_tick - state.action_tick, 0)
		plan = CombatClipPlanner.plan(clips, weapon, state.action, phase, combo, maxf(in_phase, 0.0),
				control_ticks)
	apply_plan(plan, delta)


## Actualiza la capa con el byte [code]action[/code] del registro dibujado de un remoto
## (ver [method ActionMachine.action_byte]) y avanza [param delta] segundos reales.
func update_remote(action_byte: int, delta: float) -> void:
	var action: int = action_byte & 15
	var phase: int = (action_byte >> 4) & 3
	var combo: int = (action_byte >> 6) & 3
	if action == CombatState.Action.NONE or action > CombatState.Action.DEAD:
		_remote_action = -1
		_remote_combo = -1
		_remote_phase = -1
		_remote_elapsed = 0.0
		apply_plan(null, delta)
		return
	# Cada cambio de acción, de paso del combo o de fase empieza su tramo desde el principio.
	if action != _remote_action or combo != _remote_combo or phase != _remote_phase:
		_remote_elapsed = 0.0
	else:
		_remote_elapsed += delta
	_remote_action = action
	_remote_combo = combo
	_remote_phase = phase
	var used_phase: int = phase if (action == CombatState.Action.LIGHT
			or action == CombatState.Action.HEAVY) else ActionMachine.PHASE_NONE
	var plan: CombatClipPlanner.Plan = CombatClipPlanner.plan(clips, _weapon, action, used_phase,
			combo, _remote_elapsed * float(Engine.physics_ticks_per_second))
	apply_plan(plan, delta)


## Aplica el plan de este fotograma ([param plan] null = sin acción): cambia de clip con fundido si
## hace falta, fija el instante y avanza los pesos [param delta] segundos.
func apply_plan(plan: CombatClipPlanner.Plan, delta: float) -> void:
	_plan = plan
	if plan != null:
		if _current == null or _current.key != plan.key:
			_start_slot(plan)
		else:
			_current.target = 1.0
		if _current.animation_name != plan.animation:
			_current.animation_name = plan.animation
			_current.animation = _animation_of(plan.animation)
			_current.length_s = _current.animation.length if _current.animation != null else 0.0
		_current.time_s = plan.time_s
		_current.speed = plan.speed
		_current.hold = plan.hold
	elif _current != null:
		_current.target = 0.0
		# Sigue avanzando mientras se desvanece, sin pasarse del final del clip.
		_current.time_s = minf(_current.time_s + _current.speed * delta, _current.length_s)
	_advance_weights(delta)


# --- Salida -----------------------------------------------------------------------------------

## Los clips que hay que aplicar ahora, del saliente al actual (con peso mayor que 0).
func get_slots() -> Array[Slot]:
	var slots: Array[Slot] = []
	if _previous != null and _previous.weight > 0.0:
		slots.append(_previous)
	if _current != null and _current.weight > 0.0:
		slots.append(_current)
	return slots


## El plan del último fotograma (null sin acción).
func get_plan() -> CombatClipPlanner.Plan:
	return _plan


## Clip actual (o null).
func get_current() -> Slot:
	return _current


## Clip que se está desvaneciendo (o null).
func get_previous() -> Slot:
	return _previous


## true si algún clip tiene peso.
func is_active() -> bool:
	return not get_slots().is_empty()


## Olvida todo (por ejemplo, tras reaparecer o cambiar de personaje).
func reset() -> void:
	_current = null
	_previous = null
	_plan = null
	_remote_action = -1
	_remote_combo = -1
	_remote_phase = -1
	_remote_elapsed = 0.0


# --- Interno ----------------------------------------------------------------------------------

# Empieza un clip nuevo: el actual pasa a ser el saliente (si se veía) y el nuevo entra desde 0.
func _start_slot(plan: CombatClipPlanner.Plan) -> void:
	if _current != null and _current.weight > 0.01:
		_previous = _current
		_previous.target = 0.0
	var slot := Slot.new()
	slot.key = plan.key
	slot.upper_body = plan.upper_body
	slot.blend_in_s = plan.blend_in_s
	slot.blend_out_s = plan.blend_out_s
	slot.target = 1.0
	slot.weight = 0.0
	_current = slot


func _advance_weights(delta: float) -> void:
	if _previous != null:
		_previous.weight = move_toward(_previous.weight, 0.0, delta / maxf(_previous.blend_out_s, 0.001))
		if _previous.weight <= 0.0:
			_previous = null
	if _current != null:
		var rate: float = _current.blend_in_s if _current.target > _current.weight \
				else _current.blend_out_s
		_current.weight = move_toward(_current.weight, _current.target, delta / maxf(rate, 0.001))
		if _current.weight <= 0.0 and _current.target <= 0.0:
			_current = null


func _animation_of(animation_name: StringName) -> Animation:
	return clips.get_animation(animation_name) if clips != null else null
