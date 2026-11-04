class_name DemoInput
extends RefCounted
## Scripted, deterministic input for automatic visual tests.
##
## It is the phase 1 course demo ([code]--zone=test_world[/code]); real zones use
## [RouteDemoInput], which follows a route of waypoints.
## [br][br]About 10 s at 60 ticks/s. Each tick always returns the same input and the
## same view, without reading devices or the clock, so two runs of the
## demo produce the same path. It assumes the spawn point faces
## -Z (yaw 0) with about 15 m clear ahead and the ramp area after that,
## ahead to the right (in [code]test_world.tscn[/code], the foot of the walkable
## ramp is at about (15, 0, -24.5)).
## [br][br]Script (ticks start at 1):
## [br]1. Stand still 0.5 s.
## [br]2. Run forward 2 s.
## [br]3. Sprint 1.5 s while the camera turns slowly to the left (so the
## next lateral movement does not hit the pillar at (6, -20)).
## [br]4. Two jumps in place.
## [br]5. Strafe to the right for 1 s.
## [br]6. Turn toward +X and run to the ramp area.
## [br]7. Combat in place ([CombatDemoScript]: 3-hit light combo, a charged heavy attack, a
## block and a dodge) while the camera makes a full turn (360°) around the character.
## It lasts about 5 s (the combo and the wait between hits come from the combat data) instead of the 2 s
## of the camera-only turn from before: the script goes from about 10.5 s to about 13.5 s.
## [br][br]Approximate path (x, z): (0, -9.8) at the end of the run,
## (-2.9, -20.4) at the end of the sprint, (0.6, -22.9) after the sidestep and
## (8.7, -24.4) at the start of combat.

## Last tick (inclusive) of each phase.
const IDLE_END: int = 30
const RUN_END: int = 150
const SPRINT_END: int = 240
const JUMPS_END: int = 340
const STRAFE_END: int = 400
const APPROACH_END: int = 510
## First tick of combat (the last one of the approach).
const COMBAT_START: int = APPROACH_END

## Ticks at which the jump starts being pressed and how long it is held.
const JUMP_1_START: int = 246
const JUMP_2_START: int = 296
const JUMP_HOLD_TICKS: int = 6

## View (degrees). Positive yaw turns left and negative right;
## negative pitch looks down.
const BASE_PITCH_DEGREES: float = -10.0
const SPRINT_TURN_YAW_DEGREES: float = 30.0
const APPROACH_YAW_DEGREES: float = -90.0
const ORBIT_PITCH_DEGREES: float = -20.0
## Ticks the camera takes to turn toward the ramps at the start of phase 6.
const APPROACH_TURN_TICKS: int = 30

## Combat script of phase 7.
var _combat: CombatDemoScript = CombatDemoScript.new()


## Input of tick [param tick]. Past the end it returns an idle input
## with the last view.
func next(tick: int) -> PlayerInput:
	var input: PlayerInput = PlayerInput.new()
	input.tick = tick
	var look: Vector2 = look_for(tick)
	input.look_yaw = look.x
	input.look_pitch = look.y

	if tick <= IDLE_END:
		pass
	elif tick <= RUN_END:
		input.move = Vector2(0.0, 1.0)
	elif tick <= SPRINT_END:
		input.move = Vector2(0.0, 1.0)
		input.buttons |= PlayerInput.SPRINT
	elif tick <= JUMPS_END:
		if _is_jump_held(tick):
			input.buttons |= PlayerInput.JUMP
	elif tick <= STRAFE_END:
		input.move = Vector2(1.0, 0.0)
	elif tick <= APPROACH_END:
		input.move = Vector2(0.0, 1.0)
	else:
		# Combat in place: the script's ticks start at 0 with the first one after the approach.
		input.buttons |= _combat.buttons_at(tick - COMBAT_START - 1)
	return input


## Camera view at tick [param tick]: x = yaw, y = pitch (radians,
## same conventions as [PlayerInput]). Yaw is returned in [-PI, PI].
func look_for(tick: int) -> Vector2:
	var t: int = clampi(tick, 0, get_length())
	var yaw_degrees: float = 0.0
	var pitch_degrees: float = BASE_PITCH_DEGREES

	if t <= RUN_END:
		yaw_degrees = 0.0
	elif t <= SPRINT_END:
		# Slow, smooth turn during the sprint.
		var k: float = smoothstep(0.0, 1.0, _progress(t, RUN_END, SPRINT_END))
		yaw_degrees = lerpf(0.0, SPRINT_TURN_YAW_DEGREES, k)
	elif t <= STRAFE_END:
		yaw_degrees = SPRINT_TURN_YAW_DEGREES
	elif t <= APPROACH_END:
		var turn_end: int = STRAFE_END + APPROACH_TURN_TICKS
		var k: float = smoothstep(0.0, 1.0, _progress(t, STRAFE_END, turn_end))
		yaw_degrees = lerpf(SPRINT_TURN_YAW_DEGREES, APPROACH_YAW_DEGREES, k)
	else:
		# Full orbit at constant speed; the pitch lowers at the start to
		# see the character somewhat from above.
		var k: float = _progress(t, APPROACH_END, get_length())
		yaw_degrees = APPROACH_YAW_DEGREES + 360.0 * k
		var pitch_k: float = smoothstep(0.0, 1.0, minf(k * 4.0, 1.0))
		pitch_degrees = lerpf(BASE_PITCH_DEGREES, ORBIT_PITCH_DEGREES, pitch_k)

	return Vector2(wrapf(deg_to_rad(yaw_degrees), -PI, PI), deg_to_rad(pitch_degrees))


## Character that walks the demo. This script is fixed and does not need it; demos that follow
## a route ([RouteDemoInput]) read it to orient themselves toward the next waypoint.
func bind(_character: PlayerCharacter) -> void:
	pass


## Total number of ticks of the script.
func get_length() -> int:
	return COMBAT_START + _combat.get_length()


## true once the script's last tick has been executed.
func is_finished(tick: int) -> bool:
	return tick >= get_length()


func _is_jump_held(tick: int) -> bool:
	return (tick >= JUMP_1_START and tick < JUMP_1_START + JUMP_HOLD_TICKS) \
			or (tick >= JUMP_2_START and tick < JUMP_2_START + JUMP_HOLD_TICKS)


## Progress in [0, 1] of [param tick] within the phase that goes from
## [param from_tick] (excluded) to [param to_tick] (included).
static func _progress(tick: int, from_tick: int, to_tick: int) -> float:
	return clampf(float(tick - from_tick) / float(to_tick - from_tick), 0.0, 1.0)
