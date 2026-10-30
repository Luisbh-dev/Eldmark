class_name MachineDriver
extends RefCounted
## La máquina de acciones sin física (para las pruebas de docs/habilidades.md, sección 7.3): un
## [CombatState], un reloj y la entrada de cada tick, para guionizar botones tick a tick como el
## [code]Driver[/code] de test_action_machine.gd, pero con el equipo que se quiera (dos armas y
## cargas).

## Primer tick (lejos de 0 para no rozar ventanas negativas).
const START_TICK: int = 1000

var c: CombatState
var tick: int = START_TICK
var grounded: bool = true
var move: Vector2 = Vector2.ZERO
var look_yaw: float = 0.0
var look_pitch: float = 0.0
## Salida del último [method step].
var out: ActionMachine.Output


## Con [param weapon_1] activa, [param weapon_2] en la otra ranura (0 = ninguna) y las cargas
## [param charges] (empaquetadas como [member CombatState.consumable_charges]).
func _init(weapon_1: int, weapon_2: int = 0, charges: int = 0) -> void:
	c = CombatState.initial(CombatCatalog.rules(), weapon_1, weapon_2, charges)


## Avanza un tick con [param buttons] (y la marca de entrada sustituida si se pide) y devuelve el
## movimiento permitido. El tick avanzado queda en [member tick].
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


## [param count] ticks seguidos con los mismos botones.
func hold(buttons: int, count: int, substituted: bool = false) -> void:
	for _i: int in count:
		step(buttons, substituted)


## Avanza (con [param buttons]) hasta que el siguiente [method step] sea el del tick [param target].
func idle_until_before(target: int, buttons: int = 0) -> void:
	while tick < target - 1:
		step(buttons)


## Fija la resistencia sin que la regeneración (que va antes de las entradas de cada tick) la
## cambie.
func set_stamina(value: int) -> void:
	c.stamina = value
	c.stamina_regen_tick = tick + 100000


## El estado tal y como viaja (para comparar byte a byte).
func bytes() -> PackedByteArray:
	var encoded := PackedByteArray()
	encoded.resize(CombatState.ENCODED_SIZE)
	c.encode_into(encoded, 0)
	return encoded
