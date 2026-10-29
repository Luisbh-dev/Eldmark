class_name BotBrain
extends RefCounted
## Cerebro de un bot: genera entradas de jugador deterministas para las pruebas y la carga.
##
## Lo usan los bots del cliente (fase 2) y los jugadores falsos del servidor. Es una función de
## (semilla, secuencia de llamadas): no lee el reloj ni aleatoriedad global, solo su propio
## [RandomNumberGenerator]. Con la misma semilla y las mismas posiciones, produce siempre las mismas
## entradas.
## [br][br]
## Patrones ([enum Pattern]):
## [br]- [constant WANDER]: pasea. Cada 60-180 ticks cambia de dirección o se para un momento,
## a veces esprinta y salta de vez en cuando.
## [br]- [constant CIRCLE]: da vueltas alrededor de [code]home[/code] a media distancia del radio.
## [br]- [constant IDLE]: no hace nada (entradas neutras).
## [br]- [constant JUMPY]: como [constant WANDER], pero salta casi siempre que puede.
## [br]- [constant COMBAT]: busca al enemigo más cercano (lo da [method set_enemy_finder]), se
## acerca, ataca (ligeros en combo y, a veces, un fuerte cargado), y de vez en cuando bloquea o esquiva.
## Sin enemigo a la vista pasea como [constant WANDER] (sin saltar). Todo sale de su generador con
## semilla, así que con la misma semilla y las mismas posiciones hace siempre lo mismo.
## [br][br]
## Si el bot se aleja de [code]home[/code] más que el radio, vuelve hacia él hasta quedar dentro
## de [constant RETURN_RELEASE_FRACTION] del radio.

enum Pattern { WANDER, CIRCLE, IDLE, JUMPY, COMBAT }

## Duración mínima de un tramo de paseo (ticks).
const SEGMENT_MIN_TICKS: int = 60
## Duración máxima de un tramo de paseo (ticks).
const SEGMENT_MAX_TICKS: int = 180
## Probabilidad de que un tramo de paseo sea una parada.
const PAUSE_CHANCE: float = 0.2
## Probabilidad de que un tramo en marcha sea de esprint.
const SPRINT_CHANCE: float = 0.3
## Probabilidad de que un tramo en marcha lleve el movimiento ligeramente lateral.
const STRAFE_CHANCE: float = 0.25
## Separación entre saltos de un paseante (ticks, mínimo y máximo).
const WANDER_JUMP_GAP_TICKS: Vector2i = Vector2i(120, 420)
## Separación entre saltos de un [constant JUMPY] (ticks, mínimo y máximo).
const JUMPY_JUMP_GAP_TICKS: Vector2i = Vector2i(20, 60)
## Ticks que se mantiene pulsado el botón de salto (mínimo y máximo).
const JUMP_HOLD_TICKS: Vector2i = Vector2i(2, 5)
## Fracción del radio a la que el bot que volvía a casa se da por llegado.
const RETURN_RELEASE_FRACTION: float = 0.6
## Fracción del radio a la que gira un [constant CIRCLE].
const CIRCLE_RADIUS_FRACTION: float = 0.5
## Radio mínimo de la circunferencia de un [constant CIRCLE] (m).
const CIRCLE_MIN_RADIUS: float = 2.0
## [constant COMBAT]: distancia (m) a la que ve a un enemigo, a la que se detiene para golpear (el
## sector del arma llega a 2,6 m) y a partir de la cual esprinta para alcanzarlo.
const COMBAT_SIGHT_RANGE: float = 40.0
const COMBAT_ATTACK_DISTANCE: float = 1.8
const COMBAT_SPRINT_DISTANCE: float = 8.0
## [constant COMBAT]: a esta distancia empieza a pelear (ataca, bloquea o esquiva).
const COMBAT_ENGAGE_DISTANCE: float = 3.0
## [constant COMBAT]: ticks que se mantiene pulsado un toque de ataque.
const COMBAT_TAP_TICKS: int = 2
## [constant COMBAT]: ticks entre dos ataques (enlazan el combo: la ventana de enlace es el final de
## la recuperación) y entre una defensa y la siguiente decisión.
const COMBAT_ATTACK_GAP_TICKS: Vector2i = Vector2i(26, 34)
## [constant COMBAT]: probabilidades de cada decisión (el resto es un ligero) y duraciones de
## bloqueo y de carga del fuerte (ticks).
const COMBAT_BLOCK_CHANCE: float = 0.14
const COMBAT_DODGE_CHANCE: float = 0.10
const COMBAT_HEAVY_CHANCE: float = 0.12
const COMBAT_BLOCK_TICKS: Vector2i = Vector2i(30, 80)
const COMBAT_HEAVY_HOLD_TICKS: Vector2i = Vector2i(24, 50)
## [constant COMBAT]: ticks que se recuerda la posición del enemigo antes de volver a buscarlo.
const COMBAT_RETARGET_TICKS: int = 4

var _rng: RandomNumberGenerator = RandomNumberGenerator.new()
var _pattern: Pattern = Pattern.WANDER
var _home: Vector3 = Vector3.ZERO
var _radius: float = 30.0
var _idle_from: int = -1
var _started: bool = false
var _returning: bool = false
var _circle_sign: float = 1.0
# Tramo actual de paseo.
var _next_change_tick: int = 0
var _heading: float = 0.0
var _move: Vector2 = Vector2.ZERO
var _sprint: bool = false
# Salto: tick en el que empieza el siguiente y tick en el que se suelta el botón.
var _next_jump_tick: int = 0
var _jump_release_tick: int = -1
# COMBAT: quién busca al enemigo, el último visto, y qué botón se mantiene hasta cuándo.
var _enemy_finder: Callable = Callable()
var _enemy_position: Variant = null
var _enemy_checked_tick: int = -1000
var _hold_buttons: int = 0
var _hold_until: int = -1
var _hold_move: Vector2 = Vector2.ZERO
var _next_decision_tick: int = 0


## [param rng_seed] fija la secuencia. [param home] y [param radius] delimitan la zona por la
## que se mueve el bot (en el plano horizontal).
func _init(rng_seed: int, pattern: Pattern = Pattern.WANDER, home: Vector3 = Vector3.ZERO,
		radius: float = 30.0) -> void:
	_rng.seed = rng_seed
	_pattern = pattern
	_home = home
	_radius = maxf(radius, 1.0)
	_circle_sign = 1.0 if _rng.randi() % 2 == 0 else -1.0


## Entrada sin cuantizar para [param tick] (la cuantiza quien llama). [param position] y
## [param yaw] son los actuales del personaje. Cambia de dirección cada 60-180 ticks, salta y
## esprinta a veces y vuelve hacia home si sale del radio.
func next_input(tick: int, position: Vector3, yaw: float) -> PlayerInput:
	var input := PlayerInput.new()
	input.tick = tick
	if _pattern == Pattern.IDLE or (_idle_from >= 0 and tick >= _idle_from):
		input.look_yaw = yaw
		return input
	if _pattern == Pattern.COMBAT:
		var fighting: PlayerInput = _combat_input(tick, position, yaw)
		if fighting != null:
			return fighting
	if not _started:
		_started = true
		_next_change_tick = tick
		_schedule_jump(tick)

	var to_home: Vector3 = _home - position
	to_home.y = 0.0
	var distance: float = to_home.length()
	if distance > _radius:
		_returning = true
	elif distance < _radius * RETURN_RELEASE_FRACTION:
		_returning = false

	if _returning:
		input.look_yaw = _yaw_toward(to_home, yaw)
		input.move = Vector2(0.0, 1.0)
		# Un tramo nuevo al llegar, para no retomar un rumbo que lo vuelva a sacar del radio.
		_next_change_tick = tick
	elif _pattern == Pattern.CIRCLE:
		input.look_yaw = _circle_yaw(position, yaw)
		input.move = Vector2(0.0, 1.0)
	else:
		if tick >= _next_change_tick:
			_start_segment(tick)
		input.look_yaw = _heading
		input.move = _move
		if _sprint:
			input.buttons |= PlayerInput.SPRINT

	if _pattern == Pattern.WANDER or _pattern == Pattern.JUMPY:
		_update_jump(tick)
		if tick < _jump_release_tick:
			input.buttons |= PlayerInput.JUMP
	return input


## Función con la que el patrón [constant COMBAT] busca enemigos:
## [code](position: Vector3) -> Variant[/code] devuelve la posición (un [Vector3]) del enemigo más
## cercano a [param position], o null si no hay ninguno. Sin ella el patrón pasea.
func set_enemy_finder(finder: Callable) -> void:
	_enemy_finder = finder
	_enemy_checked_tick = -1000


## true si el patrón [constant COMBAT] ya tiene quién le busque enemigos.
func has_enemy_finder() -> bool:
	return _enemy_finder.is_valid()


## Patrón del bot.
func get_pattern() -> Pattern:
	return _pattern


## Desde [param tick] (incluido) solo devuelve entradas neutras: sin movimiento ni botones y
## mirando al yaw actual. Sirve para las pruebas de convergencia de la reconciliación.
func set_idle_from(tick: int) -> void:
	_idle_from = tick


# Entrada del patrón COMBAT, o null si no hay enemigo a la vista (entonces pasea).
func _combat_input(tick: int, position: Vector3, yaw: float) -> PlayerInput:
	if tick - _enemy_checked_tick >= COMBAT_RETARGET_TICKS:
		_enemy_checked_tick = tick
		_enemy_position = _enemy_finder.call(position) if _enemy_finder.is_valid() else null
	if not _enemy_position is Vector3:
		_hold_until = -1
		return null
	var to_enemy: Vector3 = (_enemy_position as Vector3) - position
	to_enemy.y = 0.0
	var distance: float = to_enemy.length()
	if distance > COMBAT_SIGHT_RANGE:
		_hold_until = -1
		return null
	var input := PlayerInput.new()
	input.tick = tick
	input.look_yaw = _yaw_toward(to_enemy, yaw)
	if tick < _hold_until:
		# Un botón mantenido (toque, bloqueo, carga del fuerte o esquiva).
		input.buttons = _hold_buttons
		input.move = _hold_move
		return input
	if distance <= COMBAT_ENGAGE_DISTANCE and tick >= _next_decision_tick:
		_decide_combat_action(tick)
		if tick < _hold_until:
			input.buttons = _hold_buttons
			input.move = _hold_move
			return input
	# Acercarse hasta la distancia de golpe.
	if distance > COMBAT_ATTACK_DISTANCE:
		input.move = Vector2(0.0, 1.0)
		if distance > COMBAT_SPRINT_DISTANCE:
			input.buttons |= PlayerInput.SPRINT
	return input


# Elige qué hacer a distancia de combate: bloquear, esquivar, cargar un fuerte o dar un ligero.
func _decide_combat_action(tick: int) -> void:
	var roll: float = _rng.randf()
	_hold_move = Vector2.ZERO
	if roll < COMBAT_BLOCK_CHANCE:
		_hold_buttons = PlayerInput.BLOCK
		_hold_until = tick + _rng.randi_range(COMBAT_BLOCK_TICKS.x, COMBAT_BLOCK_TICKS.y)
		_next_decision_tick = _hold_until + 1
	elif roll < COMBAT_BLOCK_CHANCE + COMBAT_DODGE_CHANCE:
		# Esquiva hacia un lado o hacia atrás.
		_hold_buttons = PlayerInput.DODGE
		_hold_until = tick + 1
		_hold_move = Vector2(1.0 if _rng.randi() % 2 == 0 else -1.0, 0.0) if _rng.randf() < 0.7 \
				else Vector2(0.0, -1.0)
		_next_decision_tick = tick + _rng.randi_range(COMBAT_ATTACK_GAP_TICKS.x,
				COMBAT_ATTACK_GAP_TICKS.y)
	elif roll < COMBAT_BLOCK_CHANCE + COMBAT_DODGE_CHANCE + COMBAT_HEAVY_CHANCE:
		_hold_buttons = PlayerInput.PRIMARY
		_hold_until = tick + _rng.randi_range(COMBAT_HEAVY_HOLD_TICKS.x, COMBAT_HEAVY_HOLD_TICKS.y)
		_next_decision_tick = _hold_until + _rng.randi_range(COMBAT_ATTACK_GAP_TICKS.x,
				COMBAT_ATTACK_GAP_TICKS.y)
	else:
		_hold_buttons = PlayerInput.PRIMARY
		_hold_until = tick + COMBAT_TAP_TICKS
		_next_decision_tick = tick + _rng.randi_range(COMBAT_ATTACK_GAP_TICKS.x,
				COMBAT_ATTACK_GAP_TICKS.y)


# Elige el rumbo, la marcha y el esprint del siguiente tramo de paseo.
func _start_segment(tick: int) -> void:
	_next_change_tick = tick + _rng.randi_range(SEGMENT_MIN_TICKS, SEGMENT_MAX_TICKS)
	_heading = _rng.randf() * TAU
	_sprint = false
	if _rng.randf() < PAUSE_CHANCE:
		_move = Vector2.ZERO
		return
	_move = Vector2(0.0, 1.0)
	if _rng.randf() < STRAFE_CHANCE:
		_move = Vector2(_rng.randf_range(-0.7, 0.7), 1.0).limit_length(1.0)
	else:
		_sprint = _rng.randf() < SPRINT_CHANCE


# Pulsa el botón de salto cuando toca y programa el siguiente salto.
func _update_jump(tick: int) -> void:
	if tick < _next_jump_tick:
		return
	_jump_release_tick = tick + _rng.randi_range(JUMP_HOLD_TICKS.x, JUMP_HOLD_TICKS.y)
	_schedule_jump(_jump_release_tick)


func _schedule_jump(from_tick: int) -> void:
	var gap: Vector2i = JUMPY_JUMP_GAP_TICKS if _pattern == Pattern.JUMPY else WANDER_JUMP_GAP_TICKS
	_next_jump_tick = from_tick + _rng.randi_range(gap.x, gap.y)


# Yaw que mira hacia [param direction] (plano horizontal), con la convención de PlayerInput: el
# yaw 0 mira hacia -Z. Con una dirección nula conserva [param fallback].
func _yaw_toward(direction: Vector3, fallback: float) -> float:
	if direction.x * direction.x + direction.z * direction.z < 0.0001:
		return fallback
	return fposmod(atan2(-direction.x, -direction.z), TAU)


# Rumbo de una circunferencia alrededor de home: la tangente más una corrección radial que
# devuelve al bot a su circunferencia si se desvía.
func _circle_yaw(position: Vector3, fallback: float) -> float:
	var circle_radius: float = maxf(_radius * CIRCLE_RADIUS_FRACTION, CIRCLE_MIN_RADIUS)
	var offset: Vector3 = position - _home
	offset.y = 0.0
	var distance: float = offset.length()
	if distance < 0.01:
		return fallback
	var radial: Vector3 = offset / distance
	var tangent := Vector3(-radial.z, 0.0, radial.x) * _circle_sign
	var correction: float = clampf((circle_radius - distance) / circle_radius * 2.0, -1.0, 1.0)
	return _yaw_toward(tangent + radial * correction, fallback)
