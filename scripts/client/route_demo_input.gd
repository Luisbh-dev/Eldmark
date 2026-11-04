class_name RouteDemoInput
extends DemoInput
## Scripted demo that walks a route through a zone by following waypoints.
##
## Unlike [DemoInput] (a fixed script designed for the test circuit), this demo reads the character's
## position on every tick and runs in a straight line toward the next waypoint, like
## [code]tools/terrain/verify_vado_gris_routes.gd[/code]; this way it does not bump into the palisade,
## the bridge parapets or the stalls even if a hit or a slope pushes it off course. The view turns
## toward the heading at a limited speed, so the camera does not jump at corners. It is still
## deterministic: the input depends only on the tick and the simulated state.
## [br][br]
## The route is a list of steps (stand still, go to a point, jumps, strafe, look at a point, camera
## orbit, combat) built by chaining [method idle], [method go_to], [method jumps], [method strafe],
## [method face], [method orbit] and [method combat]. With [code]mirror_z = true[/code] each step is
## mirrored (z -> -z), which is how the north route (Vardheim) is turned into the south one (Solmarch) in
## a symmetric zone.
## [br][br]
## You must call [method look_for] and [method next] once per tick and in order (both with the same tick
## return consistent data) and bind the character with [method bind].

enum Kind { IDLE, GOTO, JUMPS, STRAFE, FACE, ORBIT, COMBAT }

## Distance (m) at which a waypoint counts as reached.
const REACH: float = 1.6
## Maximum turning speed of the view toward the heading (degrees per second).
const LOOK_TURN_DEGREES_PER_SECOND: float = 220.0
## Ticks of each jump of [method jumps], and the tick within that stretch at which it is pressed.
const JUMP_SLOT_TICKS: int = 50
const JUMP_PRESS_OFFSET: int = 6
## Ticks without getting closer to the waypoint before declaring it unreachable and moving on to the next.
const STUCK_TICKS: int = 150
## Tick margin of a [method go_to] stretch over the time it should take.
const GOTO_EXTRA_TICKS: int = 120
## Speeds (m/s) used to estimate the duration of the stretches (those of [PlayerCharacter]).
const ESTIMATE_RUN_SPEED: float = 5.0
const ESTIMATE_SPRINT_SPEED: float = 7.5


## A route step.
class Step:
	var kind: int = 0
	var label: String = ""
	## GOTO: destination point (x, z). FACE: point to look at.
	var target: Vector2 = Vector2.ZERO
	var sprint: bool = false
	## Duration in ticks (not used in GOTO: computed when the stretch starts).
	var ticks: int = 0
	## STRAFE: movement relative to the view (x = right, y = forward).
	var move: Vector2 = Vector2.ZERO
	## GOTO: ticks since the start of the stretch at which jump is pressed (-1: no jump).
	var jump_after: int = -1
	## ORBIT and COMBAT: total turn of the view (degrees, positive to the left).
	var degrees: float = 0.0
	## COMBAT: button script that is pressed during the step.
	var combat: CombatDemoScript = null


## Mirrors every step that is added (z -> -z, strafe and orbit inverted).
var mirror_z: bool = false

var _steps: Array[Step] = []
var _character: PlayerCharacter = null
var _index: int = 0
var _step_tick: int = 0
var _last_tick: int = -1
var _finished: bool = false
var _look_yaw: float = 0.0
var _look_pitch: float = deg_to_rad(BASE_PITCH_DEGREES)
var _move: Vector2 = Vector2.ZERO
var _buttons: int = 0
var _goto_budget: int = 0
var _best_distance: float = INF
var _since_progress: int = 0
var _orbit_start_yaw: float = 0.0
var _orbit_start_pitch: float = 0.0


## Demo of [param zone_id] for a player of [param realm]: the zone's route if it has one, the test
## circuit's script in [code]test_world[/code] and, in any other zone, a camera turn without moving (the
## terrain is not known).
static func for_zone(zone_id: StringName, realm: StringName) -> DemoInput:
	match zone_id:
		&"test_world":
			return DemoInput.new()
		&"vado_gris":
			return vado_gris(realm)
	var fallback: RouteDemoInput = RouteDemoInput.new()
	fallback.idle(60).orbit(360.0, 240)
	return fallback


## Vado Gris route (see docs/zonas/vado_gris.md): from the player's own camp along the causeway, a run
## with a jump, crossing the realm's own bridge, two jumps on the fort's slope, a strafe, going around
## the corner of the palisade to the gate esplanade (facing the ford) and, there, the combat
## ([CombatDemoScript]: a 3-hit light combo, a charged heavy attack, a block and a dodge) while the
## camera makes a full turn. The waypoints are those of the bridge route in
## [code]verify_vado_gris_routes.gd[/code]; Solmarch walks the mirror image of Vardheim's.
static func vado_gris(realm: StringName) -> RouteDemoInput:
	var demo: RouteDemoInput = RouteDemoInput.new()
	demo.mirror_z = realm == &"solmarch"
	demo.idle(30, "quieto en el campamento")
	demo.go_to(-2.5, -132.0, false, -1, "salir del campamento")
	demo.go_to(0.0, -116.0, false, -1, "calzada")
	demo.go_to(0.0, -86.0, true, 40, "esprint con salto por la calzada")
	demo.go_to(0.0, -62.0, false, -1, "subir al puente")
	demo.go_to(0.0, -47.0, false, -1, "bajar del puente")
	demo.jumps(2, "dos saltos al pie del fuerte")
	demo.strafe(Vector2(1.0, 0.0), 60, "paso lateral")
	demo.go_to(-12.0, -35.0, false, -1, "ladera del fuerte")
	demo.go_to(-26.0, -26.0, true, -1, "esquina de la empalizada")
	demo.go_to(-29.0, -10.0, true, -1, "cara oeste de la empalizada")
	demo.go_to(-25.0, -2.0, false, -1, "explanada de la puerta")
	demo.face(-20.0, 0.0, 45, "mirar la puerta del fuerte")
	demo.combat(360.0, "combate con vuelta de cámara")
	return demo


# --- Building the route -----------------------------------------------------------------------

## Stand still for [param ticks] ticks.
func idle(ticks: int, label: String = "quieto") -> RouteDemoInput:
	var step: Step = _new_step(Kind.IDLE, label)
	step.ticks = ticks
	return self


## Run (or sprint) in a straight line to (x, z). With [param jump_after] >= 0 it jumps that many ticks
## after the stretch starts.
func go_to(x: float, z: float, sprint: bool = false, jump_after: int = -1,
		label: String = "") -> RouteDemoInput:
	var step: Step = _new_step(Kind.GOTO, label if not label.is_empty() else "ir a (%.0f, %.0f)" % [x, z])
	step.target = Vector2(x, -z if mirror_z else z)
	step.sprint = sprint
	step.jump_after = jump_after
	return self


## [param count] jumps on the spot.
func jumps(count: int, label: String = "saltos") -> RouteDemoInput:
	var step: Step = _new_step(Kind.JUMPS, label)
	step.ticks = count * JUMP_SLOT_TICKS
	return self


## Move for [param ticks] ticks with [param move] relative to the view, without turning it.
func strafe(move: Vector2, ticks: int, label: String = "paso lateral") -> RouteDemoInput:
	var step: Step = _new_step(Kind.STRAFE, label)
	step.move = Vector2(-move.x if mirror_z else move.x, move.y)
	step.ticks = ticks
	return self


## Stand still for [param ticks] ticks while the view turns toward (x, z).
func face(x: float, z: float, ticks: int, label: String = "mirar") -> RouteDemoInput:
	var step: Step = _new_step(Kind.FACE, label)
	step.target = Vector2(x, -z if mirror_z else z)
	step.ticks = ticks
	return self


## Stand still while the camera turns [param degrees] degrees over [param ticks] ticks, looking slightly
## more from above.
func orbit(degrees: float, ticks: int, label: String = "vuelta de cámara") -> RouteDemoInput:
	var step: Step = _new_step(Kind.ORBIT, label)
	step.degrees = -degrees if mirror_z else degrees
	step.ticks = ticks
	return self


## Combat on the spot ([CombatDemoScript]) while the camera turns [param degrees] degrees.
func combat(degrees: float, label: String = "combate") -> RouteDemoInput:
	var step: Step = _new_step(Kind.COMBAT, label)
	step.combat = CombatDemoScript.new()
	step.ticks = step.combat.get_length()
	step.degrees = -degrees if mirror_z else degrees
	return self


# --- DemoInput API ----------------------------------------------------------------------------

func bind(character: PlayerCharacter) -> void:
	_character = character
	if is_instance_valid(_character):
		_look_yaw = _character.yaw


func next(tick: int) -> PlayerInput:
	_update(tick)
	var input: PlayerInput = PlayerInput.new()
	input.tick = tick
	input.look_yaw = wrapf(_look_yaw, -PI, PI)
	input.look_pitch = _look_pitch
	input.move = _move
	input.buttons = _buttons
	return input


func look_for(tick: int) -> Vector2:
	_update(tick)
	return Vector2(wrapf(_look_yaw, -PI, PI), _look_pitch)


## Estimated duration in ticks ([method go_to] stretches depend on the actual path).
func get_length() -> int:
	var dt: float = 1.0 / float(Engine.physics_ticks_per_second)
	var total: int = 0
	var position: Vector2 = Vector2.ZERO
	var has_position: bool = false
	if is_instance_valid(_character):
		position = Vector2(_character.global_position.x, _character.global_position.z)
		has_position = true
	for step: Step in _steps:
		if step.kind == Kind.GOTO:
			if has_position:
				var speed: float = ESTIMATE_SPRINT_SPEED if step.sprint else ESTIMATE_RUN_SPEED
				total += ceili(position.distance_to(step.target) / speed / dt)
			position = step.target
			has_position = true
		else:
			total += step.ticks
	return total


func is_finished(_tick: int) -> bool:
	return _finished


## Name of the step in progress (empty when finished).
func get_step_label() -> String:
	return _steps[_index].label if _index < _steps.size() else ""


# --- Execution --------------------------------------------------------------------------------

func _new_step(kind: int, label: String) -> Step:
	var step: Step = Step.new()
	step.kind = kind
	step.label = label
	_steps.append(step)
	return step


## Computes the input for tick [param tick] (only once per tick).
func _update(tick: int) -> void:
	if tick == _last_tick:
		return
	_last_tick = tick
	_move = Vector2.ZERO
	_buttons = 0
	if _finished:
		return
	if not is_instance_valid(_character):
		_finished = true
		return
	var dt: float = 1.0 / float(Engine.physics_ticks_per_second)
	while _index < _steps.size():
		if _step_tick == 0:
			_begin_step(_steps[_index], tick)
		if _run_step(_steps[_index], dt):
			_step_tick += 1
			return
		_index += 1
		_step_tick = 0
	_finished = true


func _begin_step(step: Step, tick: int) -> void:
	var p: Vector3 = _character.global_position
	print("[Eldmark] Demo, tick %d: %s (desde %.1f, %.1f, %.1f)" % [tick, step.label, p.x, p.y, p.z])
	if step.kind == Kind.GOTO:
		var dt: float = 1.0 / float(Engine.physics_ticks_per_second)
		var speed: float = ESTIMATE_SPRINT_SPEED if step.sprint else ESTIMATE_RUN_SPEED
		var distance: float = Vector2(p.x, p.z).distance_to(step.target)
		_goto_budget = ceili(distance / speed / dt * 1.5) + GOTO_EXTRA_TICKS
		_best_distance = INF
		_since_progress = 0
	elif step.kind == Kind.ORBIT or step.kind == Kind.COMBAT:
		_orbit_start_yaw = _look_yaw
		_orbit_start_pitch = _look_pitch


## Runs one tick of the step. Returns false if the step had already finished (without generating input).
func _run_step(step: Step, dt: float) -> bool:
	var p: Vector3 = _character.global_position
	var flat: Vector2 = Vector2(p.x, p.z)
	match step.kind:
		Kind.IDLE:
			return _step_tick < step.ticks
		Kind.GOTO:
			var to_target: Vector2 = step.target - flat
			var distance: float = to_target.length()
			if distance < REACH:
				return false
			if distance < _best_distance - 0.05:
				_best_distance = distance
				_since_progress = 0
			else:
				_since_progress += 1
			if _since_progress > STUCK_TICKS or _step_tick > _goto_budget:
				push_warning("[Eldmark] Demo: no se llega a '%s' (%s); se sigue con el siguiente paso"
						% [step.label, flat])
				return false
			var direction: Vector2 = to_target / distance
			_turn_look_toward(atan2(-direction.x, -direction.y), dt)
			_move = _world_to_move(direction)
			if step.sprint:
				_buttons |= PlayerInput.SPRINT
			if step.jump_after >= 0 and _step_tick >= step.jump_after \
					and _step_tick < step.jump_after + JUMP_HOLD_TICKS:
				_buttons |= PlayerInput.JUMP
			return true
		Kind.JUMPS:
			if _step_tick >= step.ticks:
				return false
			var slot_tick: int = _step_tick % JUMP_SLOT_TICKS
			if slot_tick >= JUMP_PRESS_OFFSET and slot_tick < JUMP_PRESS_OFFSET + JUMP_HOLD_TICKS:
				_buttons |= PlayerInput.JUMP
			return true
		Kind.STRAFE:
			if _step_tick >= step.ticks:
				return false
			_move = step.move
			return true
		Kind.FACE:
			if _step_tick >= step.ticks:
				return false
			var to_point: Vector2 = step.target - flat
			if to_point.length() > 0.01:
				_turn_look_toward(atan2(-to_point.x, -to_point.y), dt)
			return true
		Kind.ORBIT:
			if _step_tick >= step.ticks:
				return false
			var k: float = float(_step_tick + 1) / float(step.ticks)
			_look_yaw = _orbit_start_yaw + deg_to_rad(step.degrees) * k
			var pitch_k: float = smoothstep(0.0, 1.0, minf(k * 4.0, 1.0))
			_look_pitch = lerpf(_orbit_start_pitch, deg_to_rad(ORBIT_PITCH_DEGREES), pitch_k)
			return true
		Kind.COMBAT:
			if _step_tick >= step.ticks:
				return false
			_buttons |= step.combat.buttons_at(_step_tick)
			var combat_k: float = float(_step_tick + 1) / float(step.ticks)
			_look_yaw = _orbit_start_yaw + deg_to_rad(step.degrees) * combat_k
			var combat_pitch_k: float = smoothstep(0.0, 1.0, minf(combat_k * 4.0, 1.0))
			_look_pitch = lerpf(_orbit_start_pitch, deg_to_rad(ORBIT_PITCH_DEGREES), combat_pitch_k)
			return true
	return false


## Turns the view toward [param heading] (yaw) at the maximum turning speed.
func _turn_look_toward(heading: float, dt: float) -> void:
	var max_step: float = deg_to_rad(LOOK_TURN_DEGREES_PER_SECOND) * dt
	_look_yaw = wrapf(rotate_toward(_look_yaw, heading, max_step), -PI, PI)


## World direction (x, z) -> movement relative to the view (x = right, y = forward), with the same
## conventions as [method PlayerCharacter.simulate].
func _world_to_move(direction: Vector2) -> Vector2:
	var forward: Vector2 = Vector2(-sin(_look_yaw), -cos(_look_yaw))
	var right: Vector2 = Vector2(cos(_look_yaw), -sin(_look_yaw))
	return Vector2(direction.dot(right), direction.dot(forward)).limit_length(1.0)
