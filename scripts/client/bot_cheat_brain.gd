class_name BotCheatBrain
extends BotBrain
## Brain of the cheating bot's combat modes ([BotCheater], docs/combate.md, section 4.5).
## [br][br]
## It looks for the nearest enemy (provided by [method BotBrain.set_enemy_finder]) and, depending
## on its [enum Style]:
## [br]- [constant Style.REACH]: it stays at [constant REACH_DISTANCE] m, facing it, and throws a
## light attack every [constant SWING_GAP_TICKS] ticks. The inputs are legitimate; the server
## must leave it without a hit because the weapon's sector does not reach (2.6 m plus the
## capsule's radius).
## [br]- [constant Style.RATE]: it sticks to the enemy and mashes PRIMARY, pressed one tick out of
## two (one edge every two ticks, the most that can be pressed). The server must let it hit only at
## the combo rate in the data.
## [br]- [constant Style.REUSE] (CMB-19; docs/habilidades.md, section 4.7): it sticks to the enemy
## and mashes ability 1 (the shield strike) one tick out of two, also while it is on cooldown. The
## server must let it use it only when it becomes valid again: one hit every [code]cooldown +
## cast[/code] ticks.
## [br]- [constant Style.POTION]: it mashes both potions (R and T, alternating, one edge every two
## ticks) wherever it is. The server only lets it drink with charges and outside the shared cooldown.
## [br]- [constant Style.INTERACT]: it mashes INTERACT one tick out of two without moving, away
## from everyone. Without a knocked-down player within reach, the server neither starts a revive
## nor a finishing blow.
## [br]With no enemy in sight, [constant Style.REACH], [constant Style.RATE] and [constant Style.REUSE] wander like [constant BotBrain.Pattern.WANDER]; [constant Style.POTION] and
## [constant Style.INTERACT] need no enemy and stand still.

enum Style {
	## Attacks from [constant REACH_DISTANCE] m.
	REACH,
	## Mashes PRIMARY stuck to the enemy.
	RATE,
	## Mashes ability 1 stuck to the enemy.
	REUSE,
	## Mashes the potions.
	POTION,
	## Mashes INTERACT away from everyone.
	INTERACT,
}

## Distance (m) at which [constant Style.REACH] mode stays, and the slack before moving.
const REACH_DISTANCE: float = 5.0
const REACH_TOLERANCE: float = 0.3
## Distance (m) at which [constant Style.RATE] mode sticks to the enemy (the weapon's sector reaches 2.6 m).
const MELEE_DISTANCE: float = 1.8
## Distance (m) beyond which it sprints to reach the enemy.
const SPRINT_DISTANCE: float = 9.0
## Ticks between the light attacks of [constant Style.REACH] mode and ticks each one is held down.
const SWING_GAP_TICKS: int = 40
const TAP_TICKS: int = 2

var _style: Style = Style.REACH
var _last_swing_tick: int = -1000


## [param rng_seed], [param home] and [param radius] are those of [BotBrain] (wandering with no enemy).
func _init(rng_seed: int, style: Style, home: Vector3 = Vector3.ZERO, radius: float = 30.0) -> void:
	super(rng_seed, BotBrain.Pattern.WANDER, home, radius)
	_style = style


func get_style() -> Style:
	return _style


func next_input(tick: int, position: Vector3, yaw: float) -> PlayerInput:
	if _style == Style.POTION or _style == Style.INTERACT:
		return _mash_in_place(tick, yaw)
	var enemy: Variant = _enemy_finder.call(position) if _enemy_finder.is_valid() else null
	if enemy is BotTarget:
		enemy = (enemy as BotTarget).position
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
			_rate(input, tick, distance, PlayerInput.PRIMARY)
		Style.REUSE:
			_rate(input, tick, distance, PlayerInput.ABILITY_1)
	return input


# POTION and INTERACT: standing still, facing where it faces, mashing their buttons one tick out
# of two (the potions alternate: R on multiples of 4 and T on the other even ticks).
func _mash_in_place(tick: int, yaw: float) -> PlayerInput:
	var input := PlayerInput.new()
	input.tick = tick
	input.look_yaw = yaw
	if tick % 2 != 0:
		return input
	if _style == Style.INTERACT:
		input.buttons = PlayerInput.INTERACT
	else:
		input.buttons = PlayerInput.CONSUMABLE_1 if tick % 4 == 0 else PlayerInput.CONSUMABLE_2
	return input


# It positions itself at REACH_DISTANCE from the enemy and, standing still, throws a light attack
# every SWING_GAP_TICKS.
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


# It sticks to the enemy and presses [param button] one tick out of two.
func _rate(input: PlayerInput, tick: int, distance: float, button: int) -> void:
	if distance > MELEE_DISTANCE:
		input.move = Vector2(0.0, 1.0)
		if distance > SPRINT_DISTANCE:
			input.buttons |= PlayerInput.SPRINT
	if distance <= MELEE_DISTANCE + 0.5 and tick % 2 == 0:
		input.buttons |= button
