class_name MachineDriver
extends RefCounted
## The action machine without physics (for the tests of docs/habilidades.md, section 7.3): a
## [CombatState], a clock and each tick's input, to script buttons tick by tick like the
## [code]Driver[/code] of test_action_machine.gd, but with whatever loadout is wanted (two weapons
## and charges).

## First tick (far from 0 to avoid brushing negative windows).
const START_TICK: int = 1000

var c: CombatState
var tick: int = START_TICK
var grounded: bool = true
var move: Vector2 = Vector2.ZERO
var look_yaw: float = 0.0
var look_pitch: float = 0.0
## Output of the last [method step].
var out: ActionMachine.Output


## With [param weapon_1] active, [param weapon_2] in the other slot (0 = none) and the charges
## [param charges] (packed as [member CombatState.consumable_charges]).
func _init(weapon_1: int, weapon_2: int = 0, charges: int = 0) -> void:
	c = CombatState.initial(CombatCatalog.rules(), weapon_1, weapon_2, charges)


## Advances one tick with [param buttons] (and the substituted-input marker if requested) and
## returns the allowed movement. The advanced tick stays in [member tick].
func step(buttons: int = 0, substituted: bool = false) -> ActionMachine.Output:
	tick += 1
	var input := PlayerInput.new()
	input.tick = tick
	input.buttons = buttons | (PlayerInput.SUBSTITUTED if substituted else 0)
	input.move = move
	input.look_yaw = look_yaw
	input.look_pitch = look_pitch
	out = ActionMachine.step(c, input, grounded)
	return out


## [param count] consecutive ticks with the same buttons.
func hold(buttons: int, count: int, substituted: bool = false) -> void:
	for _i: int in count:
		step(buttons, substituted)


## Advances (with [param buttons]) until the next [method step] is that of tick [param target].
func idle_until_before(target: int, buttons: int = 0) -> void:
	while tick < target - 1:
		step(buttons)


## Sets the stamina without the regeneration (which runs before each tick's inputs) changing it.
func set_stamina(value: int) -> void:
	c.stamina = value
	c.stamina_regen_tick = tick + 100000


## The state as it travels (to compare byte by byte).
func bytes() -> PackedByteArray:
	var encoded := PackedByteArray()
	encoded.resize(CombatState.ENCODED_SIZE)
	c.encode_into(encoded, 0)
	return encoded
