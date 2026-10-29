class_name NpcBrain
extends BotBrain
## Cerebro de un PNJ humanoide muy sencillo (docs/combate.md, sección 7): el del maniquí de
## entrenamiento. Genera entradas de jugador que entran en la [InputQueue] del PNJ como las de un
## jugador falso, así que su cuerpo es un [PlayerCharacter] simulado en el mismo bucle.
## [br][br]
## Modos ([enum Mode]):
## [br]- [constant STILL]: quieto, mirando hacia donde mira.
## [br]- [constant BLOCK]: con el escudo en alto (BLOCK pulsado) mirando hacia donde mira.
## [br]- [constant SPIN]: gira despacio sobre sí mismo (una vuelta cada
## [constant SPIN_PERIOD_TICKS] ticks) para que se le pueda golpear de lado y por la espalda.

enum Mode { STILL, BLOCK, SPIN }

## Ticks que tarda en dar una vuelta completa en el modo [constant SPIN].
const SPIN_PERIOD_TICKS: int = 360
## Movimiento (adelante, de 0 a 1) con el que gira en el modo [constant SPIN]: el personaje solo
## gira hacia la cámara si se mueve más de [constant PlayerCharacter.FACING_MIN_WISH]; esto lo
## deja a unos 0,6 m/s, es decir, dando vueltas en un círculo de menos de un metro.
const SPIN_MOVE: float = 0.115

## Modo del PNJ (se puede cambiar en marcha).
var mode: int = Mode.STILL

var _spin_origin_tick: int = -1
var _spin_origin_yaw: float = 0.0


func _init(new_mode: int = Mode.STILL, rng_seed: int = 1) -> void:
	super(rng_seed, BotBrain.Pattern.IDLE)
	mode = new_mode


## Nombre del modo en español ([code]quieto[/code], [code]bloqueando[/code], [code]girando[/code]).
static func mode_name(mode_value: int) -> String:
	match mode_value:
		Mode.BLOCK:
			return "bloqueando"
		Mode.SPIN:
			return "girando"
	return "quieto"


## Modo con ese nombre ([code]quieto[/code], [code]bloqueando[/code] o [code]girando[/code]; también
## sus nombres en inglés [code]still[/code], [code]block[/code], [code]spin[/code]), o -1 si no
## existe.
static func mode_from_name(text: String) -> int:
	match text.strip_edges().to_lower():
		"quieto", "still":
			return Mode.STILL
		"bloqueando", "bloquear", "block":
			return Mode.BLOCK
		"girando", "girar", "spin":
			return Mode.SPIN
	return -1


func next_input(tick: int, _position: Vector3, yaw: float) -> PlayerInput:
	var input := PlayerInput.new()
	input.tick = tick
	input.look_yaw = yaw
	match mode:
		Mode.BLOCK:
			input.buttons = PlayerInput.BLOCK
		Mode.SPIN:
			if _spin_origin_tick < 0:
				_spin_origin_tick = tick
				_spin_origin_yaw = yaw
			var turned: float = TAU * float(tick - _spin_origin_tick) / float(SPIN_PERIOD_TICKS)
			input.look_yaw = fposmod(_spin_origin_yaw - turned, TAU)
			input.move = Vector2(0.0, SPIN_MOVE)
	return input
