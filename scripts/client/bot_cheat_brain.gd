class_name BotCheatBrain
extends BotBrain
## Cerebro de los modos de combate del bot tramposo ([BotCheater], docs/combate.md, sección 4.5).
## [br][br]
## Busca al enemigo más cercano (lo da [method BotBrain.set_enemy_finder]) y, según su [enum Style]:
## [br]- [constant Style.REACH]: se queda a [constant REACH_DISTANCE] m, mirándolo, y lanza un ligero
## cada [constant SWING_GAP_TICKS] ticks. Las entradas son legítimas; el servidor tiene que dejarlo sin
## golpe porque el sector del arma no llega (2,6 m más el radio de la cápsula).
## [br]- [constant Style.RATE]: se pega al enemigo y machaca PRIMARY, pulsado un tick de cada dos
## (un flanco cada dos ticks, lo máximo que se puede pulsar). El servidor tiene que dejarlo pegar solo
## al ritmo del combo de los datos.
## [br]Sin enemigo a la vista pasea como [constant BotBrain.Pattern.WANDER].

enum Style {
	## Ataca desde [constant REACH_DISTANCE] m.
	REACH,
	## Machaca PRIMARY pegado al enemigo.
	RATE,
}

## Distancia (m) a la que se queda el modo [constant Style.REACH] y holgura antes de moverse.
const REACH_DISTANCE: float = 5.0
const REACH_TOLERANCE: float = 0.3
## Distancia (m) a la que se pega el modo [constant Style.RATE] (el sector del arma llega a 2,6 m).
const MELEE_DISTANCE: float = 1.8
## Distancia (m) a partir de la cual esprinta para alcanzar al enemigo.
const SPRINT_DISTANCE: float = 9.0
## Ticks entre los ligeros del modo [constant Style.REACH] y ticks que se mantiene pulsado cada uno.
const SWING_GAP_TICKS: int = 40
const TAP_TICKS: int = 2

var _style: Style = Style.REACH
var _last_swing_tick: int = -1000


## [param rng_seed], [param home] y [param radius] son los de [BotBrain] (paseo sin enemigo).
func _init(rng_seed: int, style: Style, home: Vector3 = Vector3.ZERO, radius: float = 30.0) -> void:
	super(rng_seed, BotBrain.Pattern.WANDER, home, radius)
	_style = style


func get_style() -> Style:
	return _style


func next_input(tick: int, position: Vector3, yaw: float) -> PlayerInput:
	var enemy: Variant = _enemy_finder.call(position) if _enemy_finder.is_valid() else null
	if not enemy is Vector3:
		return super.next_input(tick, position, yaw)
	var to_enemy: Vector3 = (enemy as Vector3) - position
	to_enemy.y = 0.0
	var distance: float = to_enemy.length()
	var input := PlayerInput.new()
	input.tick = tick
	input.look_yaw = _yaw_toward(to_enemy, yaw)
	match _style:
		Style.REACH:
			_reach(input, tick, distance)
		Style.RATE:
			_rate(input, tick, distance)
	return input


# Se coloca a REACH_DISTANCE del enemigo y, quieto, lanza un ligero cada SWING_GAP_TICKS.
func _reach(input: PlayerInput, tick: int, distance: float) -> void:
	if distance > REACH_DISTANCE + REACH_TOLERANCE:
		input.move = Vector2(0.0, 1.0)
		if distance > SPRINT_DISTANCE:
			input.buttons |= PlayerInput.SPRINT
	elif distance < REACH_DISTANCE - REACH_TOLERANCE:
		input.move = Vector2(0.0, -1.0)
	elif tick - _last_swing_tick >= SWING_GAP_TICKS:
		_last_swing_tick = tick
	if tick - _last_swing_tick < TAP_TICKS:
		input.buttons |= PlayerInput.PRIMARY


# Se pega al enemigo y pulsa PRIMARY un tick de cada dos.
func _rate(input: PlayerInput, tick: int, distance: float) -> void:
	if distance > MELEE_DISTANCE:
		input.move = Vector2(0.0, 1.0)
		if distance > SPRINT_DISTANCE:
			input.buttons |= PlayerInput.SPRINT
	if distance <= MELEE_DISTANCE + 0.5 and tick % 2 == 0:
		input.buttons |= PlayerInput.PRIMARY
