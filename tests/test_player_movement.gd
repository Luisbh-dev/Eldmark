extends TestCase
## Tests of PlayerCharacter's movement simulation.
##
## Each test builds a minimal world in code (a 200 x 200 m ground on layer 1, a walkable 25° ramp,
## a steep 55° one and a 1 m platform with edges), instantiates the character and calls
## [method PlayerCharacter.simulate] in a loop with
## [code]delta = 1 / Engine.physics_ticks_per_second[/code], just as the server and the client
## prediction will do in phase 2.
## [br][br]
## [b]Important:[/b] move_and_slide() takes its delta from the physics tick only if it is called
## inside it ([method Engine.is_in_physics_frame]); outside it uses the _process delta, which varies.
## That is why each test starts with [method _begin] (which waits one physics step) and does not wait
## for frames again between calls to simulate(), except the one that records one tick per physics step.
## [br][br]
## The most important tests are the replay ones: restoring a state and repeating the same inputs
## must reproduce exactly the same trajectory from any tick, even if the internal state of the
## CharacterBody3D (floor contact, floor normal) comes from another situation. This is what the
## phase 2 reconciliation will do every time a state arrives from the server.

## How the internal state of the CharacterBody3D is "dirtied" before restoring a state.
enum Pollution {
	AIRBORNE, ## The body comes from falling through the air (without ground contact).
	GROUNDED, ## The body comes from resting on the ground, somewhere else.
}

const CHARACTER_SCENE_PATH: String = "res://scenes/characters/player_character.tscn"
const WORLD_LAYER: int = 1
const FLAT_SPAWN: Vector3 = Vector3(0.0, 0.0, 0.0)
const RAMP_THICKNESS: float = 0.5
const RAMP_WIDTH: float = 10.0
## Center of the bottom edge of the 25° ramp, which rises toward -Z (slightly sunk so that
## there is no step with the ground).
const RAMP_FOOT: Vector3 = Vector3(20.0, -0.02, 0.0)
const RAMP_ANGLE_DEG: float = 25.0
const RAMP_LENGTH: float = 12.0
const STEEP_RAMP_FOOT: Vector3 = Vector3(-20.0, -0.02, 0.0)
const STEEP_RAMP_ANGLE_DEG: float = 55.0
const STEEP_RAMP_LENGTH: float = 8.0
## 1 m high platform, far from the rest, to fall off an edge.
const LEDGE_CENTER: Vector3 = Vector3(-40.0, 0.5, 30.0)
const LEDGE_SIZE: Vector3 = Vector3(10.0, 1.0, 10.0)
## Start on the platform, 9 m from its -Z edge.
const LEDGE_START: Vector3 = Vector3(-40.0, 1.0, 34.0)
## Start of the replay test route: 6 m in front of the 25° ramp.
const REPLAY_START: Vector3 = Vector3(20.0, 0.0, 6.0)
const REPLAY_TICKS: int = 180
## Tolerance of the replays in the same process. In practice they are bit-exact; any hidden
## state that does not travel in PlayerState (like the scale the node used to accumulate when
## turning) makes the trajectory drift far more than this.
const REPLAY_EPSILON: float = 1e-6
## Diverging replays that are described in the failure message (the rest are only counted).
const MAX_REPORTED_REPLAYS: int = 3
## Clear area where the internal state is dirtied before restoring.
const POLLUTION_SPOT: Vector3 = Vector3(0.0, 0.0, 60.0)
const REPLAY_HINT: String = (
	"Pista: tras set_state(), el estado interno de CharacterBody3D (is_on_floor(), normal del "
	+ "suelo) sigue siendo el de la última move_and_slide(); simulate() debe resincronizarlo con "
	+ "'grounded'. Y nada que influya en la colisión (como la escala del nodo) puede depender "
	+ "de la historia: todo debe salir de PlayerState."
)

var _world: Node3D
var _character: PlayerCharacter
var _dt: float = 1.0 / 60.0
var _next_tick: int = 1
var _jumped_count: int = 0
var _landed_count: int = 0


func before_each() -> void:
	_dt = 1.0 / float(Engine.physics_ticks_per_second)
	_world = Node3D.new()
	_world.name = "MovementTestWorld"
	tree.root.add_child(_world)
	_add_static_box("Floor", Vector3(200.0, 1.0, 200.0), Vector3(0.0, -0.5, 0.0), 0.0)
	_add_ramp("Ramp", RAMP_FOOT, RAMP_ANGLE_DEG, RAMP_LENGTH)
	_add_ramp("SteepRamp", STEEP_RAMP_FOOT, STEEP_RAMP_ANGLE_DEG, STEEP_RAMP_LENGTH)
	_add_static_box("Ledge", LEDGE_SIZE, LEDGE_CENTER, 0.0)

	var scene: PackedScene = load(CHARACTER_SCENE_PATH) as PackedScene
	if not assert_not_null(scene, "could not load %s" % CHARACTER_SCENE_PATH):
		return
	var instance: Node = scene.instantiate()
	_character = instance as PlayerCharacter
	if not assert_not_null(_character,
			"the root of %s must be a PlayerCharacter" % CHARACTER_SCENE_PATH):
		if instance != null:
			instance.free()
		return
	_character.jumped.connect(_on_jumped)
	_character.landed.connect(_on_landed)
	_world.add_child(_character)
	# Two ticks for the physics space to register the newly added bodies.
	await wait_physics_frames(2)


func after_each() -> void:
	if is_instance_valid(_world):
		# It is removed from the tree right away (the bodies leave the physics space) and freed afterward.
		_world.get_parent().remove_child(_world)
		_world.queue_free()
	_world = null
	_character = null
	await wait_process_frames()


# --- Configuration ----------------------------------------------------------------------------

func test_character_configuration() -> void:
	if not await _begin():
		return
	assert_eq(_character.collision_layer, 2, "collision_layer (layer 2 = characters)")
	assert_eq(_character.collision_mask, 1 | 4,
			"collision_mask (layer 1, static world, and layer 3, invisible player blockers)")
	assert_near(_character.floor_max_angle, deg_to_rad(46.0), 1e-4, "floor_max_angle")
	assert_near(_character.floor_snap_length, 0.35, 1e-4, "floor_snap_length")
	assert_true(_character.floor_constant_speed, "floor_constant_speed")
	assert_true(_character.floor_stop_on_slope, "floor_stop_on_slope")
	assert_true(_character.jump_buffer_window <= PlayerState.MAX_JUMP_BUFFER_TICKS,
			"jump_buffer_window fits in the network state")
	assert_true(_character.coyote_window <= PlayerState.MAX_COYOTE_TICKS,
			"coyote_window fits in the network state")

	var target: Node3D = _character.get_camera_target()
	if assert_not_null(target, "get_camera_target()"):
		assert_eq(target.name, "CameraTarget", "name of the camera target")
		assert_true(_character.is_ancestor_of(target), "CameraTarget must be a child of the character")
		assert_near(target.position.y, 1.6, 0.05, "CameraTarget at head height")

	var collision: CollisionShape3D = _character.get_node_or_null(^"Collision") as CollisionShape3D
	if assert_not_null(collision, "Collision node (CollisionShape3D)"):
		var capsule: CapsuleShape3D = collision.shape as CapsuleShape3D
		if assert_not_null(capsule, "Collision must use a CapsuleShape3D"):
			assert_near(capsule.radius, 0.4, 1e-3, "capsule radius")
			assert_near(capsule.height, 1.8, 1e-3, "capsule height")
		assert_near(collision.position.y, 0.9, 1e-3,
				"the capsule starts at the origin: origin at the feet")


# --- Falling, running and speeds --------------------------------------------------------------

func test_falls_and_lands_from_one_meter() -> void:
	if not await _begin():
		return
	_place(Vector3(0.0, 1.0, 0.0), 0.0, false)
	_reset_counters()
	_step(Vector2.ZERO, 0.0)
	assert_false(_character.grounded, "after the first falling tick it cannot be on the ground")
	assert_true(_character.global_position.y < 1.0, "it must start falling")

	var landed_tick: int = -1
	for tick: int in range(2, 91):
		_step(Vector2.ZERO, 0.0)
		if _character.grounded:
			landed_tick = tick
			break
	# Free fall of 1 m: t = sqrt(2 / g), about 18-19 ticks with g = 22.
	var expected_ticks: int = ceili(sqrt(2.0 / _character.gravity)
			* Engine.physics_ticks_per_second)
	assert_true(landed_tick >= expected_ticks - 4 and landed_tick <= expected_ticks + 6,
			"it must land around tick %d (it landed on %d)" % [expected_ticks, landed_tick])
	assert_near(_character.global_position.y, 0.0, 0.05,
			"lands with its feet on the ground (y = 0)")
	assert_near(_character.velocity.y, 0.0, 0.01, "on landing the vertical velocity is zeroed")
	assert_eq(_landed_count, 1, "landed is emitted once on landing")
	assert_eq(_jumped_count, 0, "jumped is not emitted when falling")

	# At rest it must stay on the ground without 'grounded' flickering.
	for i: int in 60:
		_step(Vector2.ZERO, 0.0)
		if not _character.grounded:
			fail("at rest on the ground, 'grounded' turned false on tick %d" % i)
			break
	assert_near(_character.global_position.y, 0.0, 0.05, "stays at ground level")
	assert_near(_character.get_horizontal_speed(), 0.0, 1e-4, "no horizontal drift at rest")
	assert_eq(_landed_count, 1, "landed is not repeated while it stays on the ground")


func test_runs_forward_at_run_speed() -> void:
	if not await _begin() or not _settle(FLAT_SPAWN):
		return
	var start: Vector3 = _character.global_position
	_step(Vector2(0.0, 1.0), 0.0, 0, 60)
	var velocity: Vector3 = _character.velocity
	assert_vec_near(Vector3(velocity.x, 0.0, velocity.z),
			Vector3(0.0, 0.0, -_character.run_speed), 0.05,
			"after 60 ticks forward with look_yaw 0 it runs at run_speed toward -Z")
	assert_near(_character.get_horizontal_speed(), _character.run_speed, 0.05,
			"get_horizontal_speed()")
	var moved: Vector3 = _character.global_position - start
	assert_true(moved.z < -0.85 * _character.run_speed,
			"in 1 s it must advance almost run_speed meters toward -Z (it advanced %.3f)" % -moved.z)
	assert_true(moved.z > -_character.run_speed - 0.01,
			"in 1 s it cannot advance more than run_speed meters (it advanced %.3f)" % -moved.z)
	assert_near(moved.x, 0.0, 0.01, "no lateral drift")
	assert_near(_character.global_position.y, 0.0, 0.05, "stays at ground level")
	assert_true(_character.grounded, "stays on the ground")


func test_movement_is_relative_to_look_yaw() -> void:
	if not await _begin() or not _settle(FLAT_SPAWN):
		return
	# look_yaw = PI/2 looks toward -X: "forward" is -X.
	_step(Vector2(0.0, 1.0), PI / 2.0, 0, 60)
	assert_vec_near(_horizontal_velocity(), Vector3(-_character.run_speed, 0.0, 0.0), 0.05,
			"forward with look_yaw PI/2 goes toward -X")
	_step(Vector2.ZERO, PI / 2.0, 0, 30)

	# Right with look_yaw 0 is +X, at strafe speed.
	_step(Vector2(1.0, 0.0), 0.0, 0, 60)
	assert_vec_near(_horizontal_velocity(),
			Vector3(_character.run_speed * _character.strafe_multiplier, 0.0, 0.0), 0.05,
			"right with look_yaw 0 goes toward +X at run_speed * strafe_multiplier")

	# Diagonal (1, 1): it is clamped to length 1 and does not count as lateral (|x| == |y|).
	_step(Vector2(1.0, 1.0), 0.0, 0, 60)
	assert_near(_character.get_horizontal_speed(), _character.run_speed, 0.05,
			"on the diagonal the speed is run_speed (the desire is clamped to length 1)")
	assert_vec_near(_horizontal_velocity().normalized(), Vector3(1.0, 0.0, -1.0).normalized(),
			0.01, "the forward-right diagonal goes toward (+X, -Z)")


func test_sprint_is_faster_than_run() -> void:
	if not await _begin() or not _settle(FLAT_SPAWN):
		return
	_step(Vector2(0.0, 1.0), 0.0, PlayerInput.SPRINT, 60)
	assert_vec_near(_horizontal_velocity(), Vector3(0.0, 0.0, -_character.sprint_speed), 0.05,
			"sprinting forward goes at sprint_speed")
	assert_true(_character.sprint_speed > _character.run_speed + 1.0,
			"sprint_speed must clearly exceed run_speed")

	# Sprint only counts forward: backward it is ignored.
	_step(Vector2(0.0, -1.0), 0.0, PlayerInput.SPRINT, 90)
	assert_near(_character.get_horizontal_speed(),
			_character.run_speed * _character.backward_multiplier, 0.05,
			"backward the sprint has no effect")

	# Nor in pure lateral.
	_step(Vector2(1.0, 0.0), 0.0, PlayerInput.SPRINT, 90)
	assert_near(_character.get_horizontal_speed(),
			_character.run_speed * _character.strafe_multiplier, 0.05,
			"laterally the sprint has no effect")


func test_backward_is_slower() -> void:
	if not await _begin() or not _settle(FLAT_SPAWN):
		return
	_step(Vector2(0.0, -1.0), 0.0, 0, 60)
	var expected: float = _character.run_speed * _character.backward_multiplier
	assert_vec_near(_horizontal_velocity(), Vector3(0.0, 0.0, expected), 0.05,
			"backward with look_yaw 0 goes toward +Z at run_speed * backward_multiplier")
	assert_true(_character.get_horizontal_speed() < _character.run_speed - 0.5,
			"backward is slower than running")


func test_stops_when_input_released() -> void:
	if not await _begin() or not _settle(FLAT_SPAWN):
		return
	_step(Vector2(0.0, 1.0), 0.0, 0, 60)
	_step(Vector2.ZERO, 0.0)
	assert_true(_character.get_horizontal_speed() > 0.5, "brakes with deceleration, not instantly")
	_step(Vector2.ZERO, 0.0, 0, 14)
	assert_near(_character.get_horizontal_speed(), 0.0, 0.01,
			"on the ground it stops in fewer than 15 ticks")
	var stopped_at: Vector3 = _character.global_position
	_step(Vector2.ZERO, 0.0, 0, 30)
	assert_vec_near(_character.global_position, stopped_at, 0.005, "stopped, it does not slide")


# --- Jumping and air --------------------------------------------------------------------------

func test_jump_apex_and_landing() -> void:
	if not await _begin() or not _settle(FLAT_SPAWN):
		return
	_reset_counters()
	var ground_y: float = _character.global_position.y
	_step(Vector2.ZERO, 0.0, PlayerInput.JUMP)
	assert_eq(_jumped_count, 1, "jumped is emitted on the jump tick")
	assert_near(_character.velocity.y, _character.jump_velocity, _character.gravity * _dt + 1e-3,
			"the vertical velocity after jumping is jump_velocity")
	assert_false(_character.grounded, "after jumping it is no longer on the ground")

	var apex: float = _character.global_position.y
	var landed_tick: int = -1
	for tick: int in range(2, 121):
		_step(Vector2.ZERO, 0.0)
		apex = maxf(apex, _character.global_position.y)
		if _character.grounded:
			landed_tick = tick
			break
	var expected_apex: float = (_character.jump_velocity * _character.jump_velocity
			/ (2.0 * _character.gravity))
	assert_near(apex - ground_y, expected_apex, expected_apex * 0.08,
			"maximum jump height ≈ jump_velocity² / (2 · gravity)")
	var expected_air_ticks: int = roundi(2.0 * _character.jump_velocity / _character.gravity
			* Engine.physics_ticks_per_second)
	assert_true(landed_tick >= expected_air_ticks - 4 and landed_tick <= expected_air_ticks + 6,
			"it must land around tick %d (it landed on %d)" % [
				expected_air_ticks, landed_tick,
			])
	assert_eq(_landed_count, 1, "landed is emitted once on landing")
	assert_near(_character.global_position.y, ground_y, 0.05, "back at ground level")


func test_holding_jump_only_jumps_once() -> void:
	if not await _begin() or not _settle(FLAT_SPAWN):
		return
	_reset_counters()
	_step(Vector2.ZERO, 0.0, PlayerInput.JUMP, 150)
	assert_eq(_jumped_count, 1, "holding the jump pressed only jumps once (rising edge)")
	assert_eq(_landed_count, 1, "lands once")
	assert_true(_character.grounded, "ends up on the ground even if still pressed")
	_step(Vector2.ZERO, 0.0, 0)
	_step(Vector2.ZERO, 0.0, PlayerInput.JUMP)
	assert_eq(_jumped_count, 2, "releasing and pressing again jumps again")


func test_no_second_jump_in_the_air() -> void:
	if not await _begin() or not _settle(FLAT_SPAWN):
		return
	_reset_counters()
	_step(Vector2.ZERO, 0.0, PlayerInput.JUMP)
	# Pressing again right away (within what the coyote time would last) does not jump again.
	for _i: int in 4:
		_step(Vector2.ZERO, 0.0, 0)
		_step(Vector2.ZERO, 0.0, PlayerInput.JUMP)
	assert_false(_character.grounded, "still in the air")
	assert_eq(_jumped_count, 1, "in the air there is no second jump (jumping uses up the coyote time)")


func test_jump_pressed_just_before_landing_is_buffered() -> void:
	if not await _begin() or not _settle(FLAT_SPAWN):
		return
	_step(Vector2.ZERO, 0.0, PlayerInput.JUMP)
	_step(Vector2.ZERO, 0.0, 0)
	var airborne: PlayerState = _character.get_state()
	# Tick (counting from 'airborne') at which it touches the ground again without pressing anything.
	var landing_tick: int = 0
	while not _character.grounded and landing_tick < 120:
		_step(Vector2.ZERO, 0.0, 0)
		landing_tick += 1
	if not assert_true(_character.grounded, "the jump must end on the ground"):
		return

	# The press is valid for jump_buffer_window ticks counting its own; the jump happens on the
	# first tick on the ground (landing_tick + 1).
	var window: int = _character.jump_buffer_window
	for early: int in [0, 1, window - 2, window, window + 3]:
		var press_tick: int = landing_tick - early
		var should_jump: bool = landing_tick + 1 - press_tick <= window - 1
		_character.set_state(airborne)
		_reset_counters()
		for tick: int in range(1, landing_tick + 8):
			# Pressed at press_tick and held: there are no more rising edges.
			_step(Vector2.ZERO, 0.0, PlayerInput.JUMP if tick >= press_tick else 0)
		var label: String = "salto pulsado %d ticks antes de tocar el suelo" % early
		if should_jump:
			assert_eq(_jumped_count, 1, "%s: it must jump on landing (buffer)" % label)
		else:
			assert_eq(_jumped_count, 0, "%s: too early, it must not jump" % label)


func test_coyote_time_after_walking_off_a_ledge() -> void:
	if not await _begin() or not _settle(LEDGE_START):
		return
	# Walks toward the platform's -Z edge until it stops stepping on it.
	var walked: int = 0
	while _character.grounded and walked < 240:
		_step(Vector2(0.0, 1.0), 0.0, 0)
		walked += 1
	if not assert_false(_character.grounded, "it must leave the platform over the edge"):
		return
	var left_ledge: PlayerState = _character.get_state()
	assert_true(left_ledge.position.y > 0.6, "it has just left the 1 m platform")

	# You can jump during coyote_window ticks in the air; after that you cannot.
	var window: int = _character.coyote_window
	for delay: int in [1, 2, window, window + 2]:
		_character.set_state(left_ledge)
		_reset_counters()
		_step(Vector2(0.0, 1.0), 0.0, 0, delay - 1)
		_step(Vector2(0.0, 1.0), 0.0, PlayerInput.JUMP)
		var label: String = "salto pulsado en el tick %d en el aire" % delay
		if delay <= window:
			assert_eq(_jumped_count, 1, "%s: the coyote time must allow it" % label)
			assert_near(_character.velocity.y, _character.jump_velocity, 1e-3,
					"%s: leaves with jump_velocity" % label)
			# And it does not leave a second jump in the air.
			_step(Vector2(0.0, 1.0), 0.0, 0)
			_step(Vector2(0.0, 1.0), 0.0, PlayerInput.JUMP)
			assert_eq(_jumped_count, 1, "%s: after the jump there is no other in the air" % label)
		else:
			assert_eq(_jumped_count, 0, "%s: the coyote time has already passed" % label)


func test_sprint_jump_keeps_momentum() -> void:
	if not await _begin() or not _settle(FLAT_SPAWN):
		return
	var sprint_jump: int = PlayerInput.SPRINT | PlayerInput.JUMP
	_step(Vector2(0.0, 1.0), 0.0, PlayerInput.SPRINT, 60)
	_reset_counters()
	_step(Vector2(0.0, 1.0), 0.0, sprint_jump)
	assert_eq(_jumped_count, 1, "jumps while sprinting")
	var slowest: float = _character.get_horizontal_speed()
	var air_ticks: int = 0
	while not _character.grounded and air_ticks < 120:
		_step(Vector2(0.0, 1.0), 0.0, sprint_jump)
		slowest = minf(slowest, _character.get_horizontal_speed())
		air_ticks += 1
	assert_true(air_ticks > 30, "the jump lasts more than half a second (%d ticks)" % air_ticks)
	assert_near(slowest, _character.sprint_speed, 0.05,
			"in the air it keeps the sprint speed (minimum %.3f m/s)" % slowest)
	assert_near(_character.get_horizontal_speed(), _character.sprint_speed, 0.05,
			"lands at sprint_speed")

	# Releasing the sprint in the air, while still moving forward, does not brake either until landing.
	_step(Vector2(0.0, 1.0), 0.0, PlayerInput.SPRINT, 5)
	_step(Vector2(0.0, 1.0), 0.0, sprint_jump)
	_step(Vector2(0.0, 1.0), 0.0, 0, 20)
	assert_false(_character.grounded, "still in the air")
	assert_near(_character.get_horizontal_speed(), _character.sprint_speed, 0.05,
			"without sprint in the air it keeps the momentum it had")


func test_running_off_a_ledge_while_sprinting_keeps_momentum() -> void:
	if not await _begin() or not _settle(LEDGE_START):
		return
	var walked: int = 0
	while _character.grounded and walked < 240:
		_step(Vector2(0.0, 1.0), 0.0, PlayerInput.SPRINT)
		walked += 1
	if not assert_false(_character.grounded, "it must leave the platform over the edge"):
		return
	var slowest: float = _character.get_horizontal_speed()
	var air_ticks: int = 0
	while not _character.grounded and air_ticks < 120:
		_step(Vector2(0.0, 1.0), 0.0, PlayerInput.SPRINT)
		slowest = minf(slowest, _character.get_horizontal_speed())
		air_ticks += 1
	assert_true(_character.grounded, "lands at the foot of the platform")
	assert_near(slowest, _character.sprint_speed, 0.05,
			"when falling off the edge it keeps the sprint speed (minimum %.3f m/s)" % slowest)


func test_air_control_is_limited() -> void:
	if not await _begin() or not _settle(FLAT_SPAWN):
		return
	_step(Vector2(0.0, 1.0), 0.0, 0, 60)
	_step(Vector2(0.0, 1.0), 0.0, PlayerInput.JUMP)
	_step(Vector2.ZERO, 0.0, 0, 10)
	assert_false(_character.grounded, "still in the air 10 ticks after jumping")
	var speed: float = _character.get_horizontal_speed()
	# On the ground it would have stopped completely; in the air it only loses a bit of speed.
	assert_true(speed > _character.run_speed - 1.5 and speed < _character.run_speed - 0.3,
			"without input in the air it keeps almost all of its speed (%.3f m/s)" % speed)
	_step(Vector2(0.0, 1.0), 0.0, PlayerInput.SPRINT, 15)
	assert_false(_character.grounded, "still in the air")
	assert_true(_character.get_horizontal_speed() <= _character.run_speed + 0.01,
			"in the air the sprint does not accelerate above run_speed (%.3f m/s)"
			% _character.get_horizontal_speed())


func test_fall_speed_is_clamped_to_terminal_velocity() -> void:
	if not await _begin():
		return
	_place(Vector3(0.0, 150.0, 0.0), 0.0, false)
	var lowest_vertical_speed: float = 0.0
	for _i: int in 180:
		_step(Vector2.ZERO, 0.0)
		lowest_vertical_speed = minf(lowest_vertical_speed, _character.velocity.y)
	assert_false(_character.grounded, "after 3 s of falling from 150 m it is still in the air")
	assert_true(lowest_vertical_speed >= -_character.terminal_velocity - 1e-3,
			"never falls faster than terminal_velocity (it reached %.3f)" % lowest_vertical_speed)
	assert_near(_character.velocity.y, -_character.terminal_velocity, 1e-3,
			"reaches terminal_velocity")


# --- Orientation ------------------------------------------------------------------------------

func test_facing_turns_toward_look_yaw() -> void:
	if not await _begin() or not _settle(FLAT_SPAWN, PI / 2.0):
		return
	var max_turn: float = _character.turn_speed * _dt
	_step(Vector2(0.0, 1.0), 0.0)
	assert_near(absf(angle_difference(_character.yaw, PI / 2.0)), max_turn, 1e-3,
			"in one tick it turns turn_speed * delta toward the camera")
	_step(Vector2(0.0, 1.0), 0.0, 0, 30)
	assert_near(absf(angle_difference(_character.yaw, 0.0)), 0.0, 1e-3,
			"ends up facing the camera")
	assert_near(absf(angle_difference(_character.rotation.y, _character.yaw)), 0.0, 1e-4,
			"rotation.y = yaw")

	# Turns the short way when crossing ±PI (from 3.0 to -3.0 is 0.28 rad, not 6.0).
	var state: PlayerState = _character.get_state()
	state.yaw = 3.0
	state.velocity = Vector3.ZERO
	_character.set_state(state)
	assert_near(absf(angle_difference(_character.rotation.y, 3.0)), 0.0, 1e-4,
			"set_state() updates rotation.y")
	_step(Vector2(0.0, 1.0), -3.0)
	var remaining: float = absf(angle_difference(_character.yaw, -3.0))
	assert_near(remaining, (TAU - 6.0) - max_turn, 1e-3,
			"turns the short way across ±PI (%.3f rad remain)" % remaining)
	_step(Vector2(0.0, 1.0), -3.0, 0, 5)
	assert_near(absf(angle_difference(_character.yaw, -3.0)), 0.0, 1e-3,
			"reaches -3.0 the short way")


func test_facing_unchanged_when_idle() -> void:
	if not await _begin() or not _settle(FLAT_SPAWN, 0.0):
		return
	# The camera orbits around the stationary character: the character does not turn.
	_step(Vector2.ZERO, 1.2, 0, 30)
	assert_near(absf(angle_difference(_character.yaw, 0.0)), 0.0, 1e-6, "stopped it does not turn")
	# A movement desire below 0.1 does not turn it either.
	_step(Vector2(0.05, 0.05), 1.2, 0, 30)
	assert_near(absf(angle_difference(_character.yaw, 0.0)), 0.0, 1e-6,
			"with a desire < 0.1 it does not turn")


func test_turning_keeps_the_basis_a_pure_function_of_yaw() -> void:
	# If the node's basis accumulated scale when turning (as happens when assigning 'rotation'), the capsule
	# would change size depending on the history of turns and the replay would stop being exact.
	if not await _begin() or not _settle(FLAT_SPAWN, 0.0):
		return
	for i: int in 1200:
		var look_yaw: float = wrapf(i * 0.37, -PI, PI)
		_step(Vector2(0.0, 1.0) if i % 3 != 0 else Vector2(0.6, 0.6), look_yaw)
		if i % 200 == 0:
			_step(Vector2.ZERO, look_yaw, 0, 20)
	_assert_basis_is_pure_yaw("tras 20 s girando")

	# An external scale or rotation is cleared on the next tick. (Uniform scale: Jolt does not
	# support non-uniform scales on a capsule and would log an error.)
	_character.scale = Vector3.ONE * 1.02
	_character.rotation = Vector3(0.2, 1.0, 0.0)
	_step(Vector2.ZERO, 0.0)
	_assert_basis_is_pure_yaw("tras tocar la escala y la rotación desde fuera")


# --- Ramps ------------------------------------------------------------------------------------

func test_walkable_ramp_is_climbable() -> void:
	if not await _begin() or not _settle(RAMP_FOOT + Vector3(0.0, 0.02, 3.0)):
		return
	_step(Vector2(0.0, 1.0), 0.0, 0, 150)
	assert_true(_character.global_position.y > 2.0,
			"it must climb the %d° ramp (height %.2f m)" % [
				RAMP_ANGLE_DEG, _character.global_position.y,
			])
	assert_true(_character.grounded, "stays resting on the ramp while climbing")


func test_steep_ramp_is_not_climbable() -> void:
	if not await _begin() or not _settle(STEEP_RAMP_FOOT + Vector3(0.0, 0.02, 3.0)):
		return
	_step(Vector2(0.0, 1.0), 0.0, 0, 150)
	assert_true(_character.global_position.y < 0.5,
			"it cannot climb a slope of %d° (it reached %.2f m)" % [
				STEEP_RAMP_ANGLE_DEG, _character.global_position.y,
			])


# --- State ------------------------------------------------------------------------------------

func test_get_state_and_set_state_roundtrip() -> void:
	if not await _begin():
		return
	var state := PlayerState.new()
	state.position = Vector3(3.25, 1.5, -7.75)
	state.velocity = Vector3(3.0, -10.0, 4.0)
	state.yaw = 0.75
	state.grounded = false
	state.prev_buttons = PlayerInput.JUMP | PlayerInput.SPRINT
	state.last_input_tick = 1234
	state.coyote_ticks = 3
	state.jump_buffer_ticks = 5
	_character.set_state(state)

	assert_vec_near(_character.global_position, state.position, 1e-5,
			"set_state() places global_position")
	assert_vec_near(_character.velocity, state.velocity, 1e-5, "set_state() assigns velocity")
	assert_near(_character.yaw, 0.75, 1e-6, "set_state() assigns yaw")
	assert_near(_character.rotation.y, 0.75, 1e-5, "set_state() turns the node (rotation.y)")
	assert_false(_character.grounded, "set_state() assigns grounded")
	assert_eq(_character.prev_buttons, state.prev_buttons, "set_state() assigns prev_buttons")
	assert_eq(_character.last_input_tick, 1234, "set_state() assigns last_input_tick")
	assert_eq(_character.coyote_ticks, 3, "set_state() assigns coyote_ticks")
	assert_eq(_character.jump_buffer_ticks, 5, "set_state() assigns jump_buffer_ticks")
	assert_near(_character.get_horizontal_speed(), 5.0, 1e-4,
			"get_horizontal_speed() ignores the vertical component")

	var read_back: PlayerState = _character.get_state()
	if not assert_not_null(read_back, "get_state()"):
		return
	assert_false(is_same(read_back, state), "get_state() returns a new object")
	assert_vec_near(read_back.position, state.position, 1e-5, "get_state().position")
	assert_vec_near(read_back.velocity, state.velocity, 1e-5, "get_state().velocity")
	assert_near(read_back.yaw, 0.75, 1e-6, "get_state().yaw")
	assert_eq(read_back.grounded, false, "get_state().grounded")
	assert_eq(read_back.prev_buttons, state.prev_buttons, "get_state().prev_buttons")
	assert_eq(read_back.last_input_tick, 1234, "get_state().last_input_tick")
	assert_eq(read_back.coyote_ticks, 3, "get_state().coyote_ticks")
	assert_eq(read_back.jump_buffer_ticks, 5, "get_state().jump_buffer_ticks")

	# Neither the state read nor the one restored stays linked to the character.
	read_back.position = Vector3(100.0, 100.0, 100.0)
	state.yaw = 2.0
	assert_vec_near(_character.global_position, Vector3(3.25, 1.5, -7.75), 1e-5,
			"modifying the returned state does not move the character")
	assert_near(_character.get_state().yaw, 0.75, 1e-6,
			"modifying the restored state does not change the character")


func test_simulate_records_tick_and_buttons() -> void:
	if not await _begin() or not _settle(FLAT_SPAWN):
		return
	var input := PlayerInput.new()
	input.tick = 4242
	input.move = Vector2(0.0, 1.0)
	input.buttons = PlayerInput.SPRINT | PlayerInput.BLOCK
	_character.simulate(input.quantized(), _dt)
	var expected_buttons: int = PlayerInput.SPRINT | PlayerInput.BLOCK
	assert_eq(_character.last_input_tick, 4242, "last_input_tick = tick of the applied input")
	assert_eq(_character.prev_buttons, expected_buttons, "prev_buttons = applied buttons")
	var state: PlayerState = _character.get_state()
	assert_eq(state.last_input_tick, 4242, "get_state().last_input_tick")
	assert_eq(state.prev_buttons, expected_buttons, "get_state().prev_buttons")


func test_set_state_restores_grounded_so_jump_works() -> void:
	if not await _begin() or not _settle(FLAT_SPAWN):
		return
	var grounded_state: PlayerState = _character.get_state()
	assert_true(grounded_state.grounded, "starting state on the ground")
	_pollute(Pollution.AIRBORNE)
	assert_false(_character.grounded, "after dirtying the state it is in the air")

	_character.set_state(grounded_state)
	assert_true(_character.grounded, "set_state() restores grounded")
	_reset_counters()
	_step(Vector2.ZERO, 0.0, PlayerInput.JUMP)
	assert_eq(_jumped_count, 1, "jumping right after restoring a state on the ground works")
	assert_near(_character.velocity.y, _character.jump_velocity, _character.gravity * _dt + 1e-3,
			"vertical velocity of the jump after restoring")
	assert_true(_character.global_position.y > grounded_state.position.y + 0.05, "takes off")


func test_set_state_restores_prev_buttons_for_jump_edge() -> void:
	if not await _begin() or not _settle(FLAT_SPAWN):
		return
	var state: PlayerState = _character.get_state()
	state.prev_buttons = PlayerInput.JUMP
	_character.set_state(state)
	_reset_counters()
	_step(Vector2.ZERO, 0.0, PlayerInput.JUMP, 5)
	assert_eq(_jumped_count, 0, "with JUMP already pressed in the restored state, holding it does not jump")
	_step(Vector2.ZERO, 0.0, 0)
	_step(Vector2.ZERO, 0.0, PlayerInput.JUMP)
	assert_eq(_jumped_count, 1, "releasing and pressing again does jump")


# --- Determinism ------------------------------------------------------------------------------

func test_replay_determinism_after_restore() -> void:
	if not await _begin() or not _settle(REPLAY_START, 0.0):
		return
	var inputs: Array[PlayerInput] = _build_replay_inputs()
	var states: Array[PlayerState] = []
	var max_height: float = 0.0
	_reset_counters()
	for input: PlayerInput in inputs:
		states.append(_character.get_state())
		_character.simulate(input, _dt)
		max_height = maxf(max_height, _character.global_position.y)
	states.append(_character.get_state())

	# Checks of the route: if they fail, the scenario no longer tests what it should.
	assert_true(max_height > 1.0,
			"the route must climb the ramp (maximum height %.2f m)" % max_height)
	assert_true(_jumped_count >= 2,
			"the route must include two jumps (there were %d)" % _jumped_count)
	assert_true(states[60].grounded, "at tick 60 the character must be on the ground")
	assert_true(_find_tick_just_before_landing(states) > 0,
			"the route must have a tick in the air, descending and about to land")
	_assert_basis_is_pure_yaw("tras el recorrido con giros")

	_check_replays_from_every_tick(inputs, states, false, "estado restaurado en el mismo proceso")


func test_replay_from_decoded_network_state() -> void:
	# As in phase 2: the restored state arrives over the network (PlayerState.encode/decode).
	if not await _begin() or not _settle(REPLAY_START, 0.0):
		return
	var inputs: Array[PlayerInput] = _build_replay_inputs()
	var states: Array[PlayerState] = []
	for input: PlayerInput in inputs:
		states.append(_character.get_state())
		_character.simulate(input, _dt)
	states.append(_character.get_state())

	_check_replays_from_every_tick(inputs, states, true, "estado decodificado de la red")


func test_replay_matches_recording_across_physics_frames() -> void:
	# Like the local controller: when playing, one tick is simulated per physics step, but the
	# reconciliation will replay many ticks within a single step. Both must match.
	if not await _begin() or not _settle(REPLAY_START, 0.0):
		return
	var start: PlayerState = _character.get_state()
	var inputs: Array[PlayerInput] = _build_replay_inputs()
	var recorded: Array[PlayerState] = []
	for input: PlayerInput in inputs:
		recorded.append(_character.get_state())
		await wait_physics_frames()
		_character.simulate(input, _dt)
	recorded.append(_character.get_state())
	_assert_basis_is_pure_yaw("tras grabar un tick por paso de física")

	_character.set_state(start)
	for i: int in inputs.size():
		_character.simulate(inputs[i], _dt)
		var actual: PlayerState = _character.get_state()
		if not actual.is_close_to(recorded[i + 1], REPLAY_EPSILON):
			fail("the same inputs in a single physics step diverge at tick %d. %s" % [
				i, _describe_difference(actual, recorded[i + 1]),
			])
			break

	_check_replays_from_every_tick(inputs, recorded, false, "grabación tick a tick")


# --- Utilities: world -------------------------------------------------------------------------

func _add_static_box(node_name: String, size: Vector3, center: Vector3, pitch: float) -> void:
	var body := StaticBody3D.new()
	body.name = node_name
	body.collision_layer = WORLD_LAYER
	body.collision_mask = 0
	var box := BoxShape3D.new()
	box.size = size
	var shape := CollisionShape3D.new()
	shape.shape = box
	body.add_child(shape)
	body.position = center
	body.rotation = Vector3(pitch, 0.0, 0.0)
	_world.add_child(body)


## Ramp that rises toward -Z with the given incline. [param foot] is the center of its nearest
## upper edge (+Z), at ground level.
func _add_ramp(node_name: String, foot: Vector3, angle_deg: float, length: float) -> void:
	var angle: float = deg_to_rad(angle_deg)
	var surface_normal := Vector3(0.0, cos(angle), sin(angle))
	var uphill := Vector3(0.0, sin(angle), -cos(angle))
	var center: Vector3 = (foot + uphill * (length * 0.5)
			- surface_normal * (RAMP_THICKNESS * 0.5))
	_add_static_box(node_name, Vector3(RAMP_WIDTH, RAMP_THICKNESS, length), center, angle)


# --- Utilities: simulation --------------------------------------------------------------------

## Checks that the character exists and enters a physics tick. All the tests that simulate
## start with [code]if not await _begin(): return[/code].
func _begin() -> bool:
	if _character == null:
		fail("the character could not be instantiated (see before_each)")
		return false
	await wait_physics_frames()
	return assert_true(Engine.is_in_physics_frame(),
			"simulate() must be called within the physics tick so that move_and_slide() "
			+ "uses its delta")


func _place(position: Vector3, yaw: float, grounded: bool,
		velocity: Vector3 = Vector3.ZERO) -> void:
	var state := PlayerState.new()
	state.position = position
	state.velocity = velocity
	state.yaw = yaw
	state.grounded = grounded
	_character.set_state(state)


## Places the character 5 cm above [param position] and simulates at rest until it touches the
## ground. Returns false (and logs a failure) if it does not manage to.
func _settle(position: Vector3, yaw: float = 0.0) -> bool:
	_place(position + Vector3(0.0, 0.05, 0.0), yaw, false)
	for _i: int in 60:
		_step(Vector2.ZERO, yaw)
		if _character.grounded:
			_step(Vector2.ZERO, yaw, 0, 2)
			return assert_true(_character.grounded,
					"the character must stay on the ground after settling at %s" % position)
	fail("the character never settled on the ground at %s" % position)
	return false


func _make_input(move: Vector2, look_yaw: float, buttons: int = 0,
		look_pitch: float = 0.0) -> PlayerInput:
	var input := PlayerInput.new()
	input.tick = _next_tick
	_next_tick += 1
	input.move = move
	input.look_yaw = look_yaw
	input.look_pitch = look_pitch
	input.buttons = buttons
	# Same as the controller: it simulates with the input as the server will see it.
	return input.quantized()


func _step(move: Vector2, look_yaw: float, buttons: int = 0, ticks: int = 1) -> void:
	for _i: int in ticks:
		_character.simulate(_make_input(move, look_yaw, buttons), _dt)


func _horizontal_velocity() -> Vector3:
	return Vector3(_character.velocity.x, 0.0, _character.velocity.z)


## The node's basis must be exactly the yaw rotation, without accumulated scale.
func _assert_basis_is_pure_yaw(context: String) -> void:
	var expected := Basis(Vector3.UP, _character.yaw)
	assert_true(_character.transform.basis == expected,
			"%s: the node's basis must come only from the yaw (scale %s)" % [
				context, _character.transform.basis.get_scale(),
			])
	assert_true(_character.scale.is_equal_approx(Vector3.ONE),
			"%s: the character's scale must be 1 (it is %s)" % [context, _character.scale])


func _reset_counters() -> void:
	_jumped_count = 0
	_landed_count = 0


func _on_jumped() -> void:
	_jumped_count += 1


func _on_landed() -> void:
	_landed_count += 1


# --- Utilities: replay ------------------------------------------------------------------------

## 180 varied ticks: running, diagonal sprint while turning the camera, climbing the ramp, held jump
## on the slope, strafing, backward walking while going down, rest and a second jump with
## sprint in the air.
func _build_replay_inputs() -> Array[PlayerInput]:
	var inputs: Array[PlayerInput] = []
	for i: int in REPLAY_TICKS:
		var move: Vector2 = Vector2.ZERO
		var look_yaw: float = 0.0
		var buttons: int = 0
		if i < 25:
			move = Vector2(0.0, 1.0)
		elif i < 55:
			move = Vector2(0.3, 1.0)
			look_yaw = lerpf(0.0, 0.15, (i - 25) / 30.0)
			buttons = PlayerInput.SPRINT
		elif i < 60:
			move = Vector2(0.0, 1.0)
			look_yaw = 0.1
			buttons = PlayerInput.SPRINT
		elif i < 80:
			move = Vector2(0.0, 1.0)
			look_yaw = 0.1
		elif i < 100:
			move = Vector2(0.0, 1.0)
			look_yaw = 0.1
			buttons = PlayerInput.JUMP
		elif i < 115:
			move = Vector2(-1.0, 0.3)
			look_yaw = 0.3
		elif i < 135:
			move = Vector2(0.0, -1.0)
			look_yaw = lerpf(0.3, -0.4, (i - 115) / 20.0)
		elif i < 145:
			look_yaw = -0.4
		elif i < 148:
			move = Vector2(0.5, 0.5)
			look_yaw = -0.4
			buttons = PlayerInput.JUMP
		else:
			move = Vector2(0.7, 0.7)
			look_yaw = -0.4
			buttons = PlayerInput.SPRINT
		inputs.append(_make_input(move, look_yaw, buttons, 0.2))
	return inputs


## Replays the route from each of its ticks, with both ways of dirtying the internal state, and
## logs a single failure with the first diverging replays. If [param through_network] is true,
## the restored state goes through encode()/decode() first.
func _check_replays_from_every_tick(inputs: Array[PlayerInput], states: Array[PlayerState],
		through_network: bool, label: String) -> void:
	var problems: PackedStringArray = PackedStringArray()
	var replays: int = 0
	for pollution: Pollution in [Pollution.AIRBORNE, Pollution.GROUNDED]:
		for from_tick: int in inputs.size():
			replays += 1
			var problem: String = _replay_from(inputs, states, from_tick, pollution,
					through_network)
			if not problem.is_empty():
				problems.append(problem)
	var shown: PackedStringArray = problems.slice(0, MAX_REPORTED_REPLAYS)
	assert_true(problems.is_empty(), "%s: %d of %d replays diverge.\n      %s\n      %s" % [
		label, problems.size(), replays, "\n      ".join(shown), REPLAY_HINT,
	])


## Restores the state of tick [param from_tick] after dirtying the internal state of the
## CharacterBody3D and repeats the same inputs until the end. Every replayed tick must match
## the original (not just the final state). Returns a description of the first difference, or
## an empty string if everything matches.
func _replay_from(inputs: Array[PlayerInput], states: Array[PlayerState], from_tick: int,
		pollution: Pollution, through_network: bool) -> String:
	var context: String = "desde el tick %d (estado interno previo: %s)" % [
		from_tick, "en el aire" if pollution == Pollution.AIRBORNE else "en el suelo",
	]
	var restored: PlayerState = states[from_tick]
	if through_network:
		restored = PlayerState.decode(restored.encode())
		if restored == null:
			return "%s: PlayerState.decode() devolvió null" % context
	_pollute(pollution)
	_character.set_state(restored)
	for i: int in range(from_tick, inputs.size()):
		_character.simulate(inputs[i], _dt)
		var actual: PlayerState = _character.get_state()
		var expected: PlayerState = states[i + 1]
		if not actual.is_close_to(expected, REPLAY_EPSILON):
			return "%s: diverge en el tick %d. %s" % [
				context, i, _describe_difference(actual, expected),
			]
	var final_state: PlayerState = _character.get_state()
	var original_final: PlayerState = states[inputs.size()]
	if final_state.prev_buttons != original_final.prev_buttons:
		return "%s: prev_buttons final %d (esperado %d)" % [
			context, final_state.prev_buttons, original_final.prev_buttons,
		]
	if final_state.last_input_tick != original_final.last_input_tick:
		return "%s: last_input_tick final %d (esperado %d)" % [
			context, final_state.last_input_tick, original_final.last_input_tick,
		]
	return ""


## Leaves the internal state of the CharacterBody3D in a situation different from the one about
## to be restored, as happens in phase 2 when the prediction has already advanced with other inputs.
func _pollute(pollution: Pollution) -> void:
	if pollution == Pollution.AIRBORNE:
		_place(POLLUTION_SPOT + Vector3(0.0, 20.0, 0.0), 2.5, false, Vector3(3.0, 0.0, -2.0))
		_step(Vector2(0.5, 1.0), 2.5, PlayerInput.SPRINT, 3)
	else:
		_place(POLLUTION_SPOT + Vector3(0.0, 0.05, 0.0), -2.0, false)
		_step(Vector2(-1.0, 0.0), -2.0, 0, 30)
		assert_true(_character.grounded,
				"when dirtying the state on the ground, the character must be resting on it")


## Tick (index in [param states]) two ticks before a landing after tick 60: the character is in
## the air, descending and a few centimeters from the ground (within snap reach).
func _find_tick_just_before_landing(states: Array[PlayerState]) -> int:
	for landing: int in range(63, states.size()):
		var candidate: PlayerState = states[landing - 2]
		if (states[landing].grounded and not states[landing - 1].grounded
				and not candidate.grounded and candidate.velocity.y < 0.0):
			return landing - 2
	return -1


func _describe_difference(actual: PlayerState, expected: PlayerState) -> String:
	var text: String = "Δposición %.7f, Δvelocidad %.7f, Δyaw %.7f, grounded %s (esperado %s)"
	text = text % [
		actual.position.distance_to(expected.position),
		actual.velocity.distance_to(expected.velocity),
		absf(angle_difference(actual.yaw, expected.yaw)),
		actual.grounded, expected.grounded,
	]
	return "%s\n        obtenido: %s\n        esperado: %s" % [text, actual, expected]
