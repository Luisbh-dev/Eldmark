class_name NpcBrain
extends BotBrain
## Brain of a very simple humanoid NPC (docs/combat.md, section 7): the training dummy's. It generates player inputs that enter the NPC's [InputQueue] like those of a
## fake player, so its body is a [PlayerCharacter] simulated in the same loop.
## [br][br]
## Modes ([enum Mode]):
## [br]- [constant STILL]: standing still, facing the direction it faces.
## [br]- [constant BLOCK]: with the shield raised (BLOCK pressed) facing the direction it faces.
## [br]- [constant SPIN]: turns slowly on itself (one turn every
## [constant SPIN_PERIOD_TICKS] ticks) so it can be hit from the side and from behind.

enum Mode { STILL, BLOCK, SPIN }

## Ticks it takes to make a full turn in [constant SPIN] mode.
const SPIN_PERIOD_TICKS: int = 360
## Movement (forward, from 0 to 1) with which it turns in [constant SPIN] mode: the character only
## turns toward the camera if it moves more than [constant PlayerCharacter.FACING_MIN_WISH]; this
## leaves it at about 0.6 m/s, that is, going around in a circle of less than one meter.
const SPIN_MOVE: float = 0.115

## The NPC's mode (can be changed on the fly).
var mode: int = Mode.STILL

var _spin_origin_tick: int = -1
var _spin_origin_yaw: float = 0.0


func _init(new_mode: int = Mode.STILL, rng_seed: int = 1) -> void:
	super(rng_seed, BotBrain.Pattern.IDLE)
	mode = new_mode


## Name of the mode in Spanish ([code]quieto[/code], [code]bloqueando[/code], [code]girando[/code]).
static func mode_name(mode_value: int) -> String:
	match mode_value:
		Mode.BLOCK:
			return "bloqueando"
		Mode.SPIN:
			return "girando"
	return "quieto"


## Mode with that name ([code]quieto[/code], [code]bloqueando[/code] or [code]girando[/code]; also
## their English names [code]still[/code], [code]block[/code], [code]spin[/code]), or -1 if it
## does not exist.
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
