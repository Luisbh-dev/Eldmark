class_name PlayerCharacter
extends CharacterBody3D
## Playable character with deterministic movement.
##
## All simulation happens in [method simulate], which is a deterministic function of
## (state, input, delta). Whoever controls the character calls it exactly once per physics tick:
## for now the local controller; in phase 2 also the server and the client's prediction and
## replay. This script reads no Input, no time and no random numbers, so that the dedicated server
## can load it without depending on anything from the client.
## [br][br]
## The node's origin is at the feet. Collision layer 2 (characters); mask 1 (world) and 3 (invisible
## blockers), plus its realm's layer (5 to 7) if the simulation calls [method set_realm_collision]:
## this is what makes a fort's closed gate stop its owner's enemies and not its own.

## Emitted on the tick in which the character jumps (for future animation and sound).
signal jumped
## Emitted on the tick in which the character touches the ground again.
signal landed

## Physics layer of the world's static geometry (layer 1).
const WORLD_COLLISION_LAYER: int = 1 << 0
## Physics layer of characters (layer 2).
const CHARACTER_COLLISION_LAYER: int = 1 << 1
## Layer of invisible blockers that only stop characters (layer 3): playable area limits, deep
## shores, bridge parapets. The camera and shots do not look at it.
const PLAYER_BLOCKER_LAYER: int = 1 << 2
## Layer of structures (layer 4): the visible body of the fort gate. It is part of the line of
## sight of hits ([constant HitShapes.LINE_OF_SIGHT_MASK]), of the camera arm's mask and of the
## navigation bake, but not of the character's mask: stopping movement is the job of the realm
## layers (docs/fortress.md, section 3.1).
const STRUCTURE_LAYER: int = 1 << 3
## Bit position of the first realm's layer (docs/fortress.md, section 3.1): layer 5 is Vardheim's
## (realm code 1), 6 is Solmarch's and 7 is Askarra's.
## See [method realm_layer].
const REALM_LAYER_BASE: int = 4
## Minimum length of the movement wish for turning the character toward the camera.
const FACING_MIN_WISH: float = 0.1
## Speed of the upward probe used to reset the floor state after set_state().
const _FLOOR_PROBE_SPEED: float = 0.01
## Below this length the movement wish has no direction.
const _MIN_WISH_DIRECTION: float = 0.001

## Running speed (m/s).
@export var run_speed: float = 5.0
## Sprinting speed (m/s). Forward only; sprinting starts on the ground.
@export var sprint_speed: float = 7.5
## Speed multiplier when moving backward.
@export var backward_multiplier: float = 0.65
## Speed multiplier when movement is mostly sideways.
@export var strafe_multiplier: float = 0.9
## Horizontal acceleration on the ground when gaining speed (m/s²).
@export var ground_acceleration: float = 45.0
## Horizontal deceleration on the ground when losing speed or braking (m/s²).
@export var ground_deceleration: float = 60.0
## Horizontal acceleration in the air (m/s²). In the air momentum is preserved: this control is
## for turning and gaining speed, and for braking only with no input or in the opposite direction.
@export var air_acceleration: float = 6.0
## Gravity (m/s²).
@export var gravity: float = 22.0
## Initial vertical speed of the jump (m/s).
@export var jump_velocity: float = 8.0
## Turning speed of the character toward the camera direction (rad/s).
@export var turn_speed: float = 14.0
## Maximum fall speed (m/s).
@export var terminal_velocity: float = 50.0
## Ticks (counting the press tick) during which a jump press remains valid if it arrives a little
## before touching the ground (jump buffer). 1 = no buffer. At most
## [constant PlayerState.MAX_JUMP_BUFFER_TICKS], because it travels in the network state.
@export_range(1, 15) var jump_buffer_window: int = 6
## Ticks in the air, after leaving the ground without jumping (when falling off an edge), during
## which jumping is still possible ("coyote time"). 0 = disabled. At most
## [constant PlayerState.MAX_COYOTE_TICKS], because it travels in the network state.
@export_range(0, 7) var coyote_window: int = 6

## Orientation of the character in radians (same convention as [member Node3D.rotation].y; 0 faces
## -Z). Assigning it also rotates the node.
## [br][br]
## It is rounded to a 32-bit float ([method PlayerState.to_f32]), the precision with which it
## travels in [method PlayerState.encode]. Without the rounding, the result of [code]atan2[/code]
## would not survive the round trip over the network and no exact state comparison would pass.
## [br][br]
## The node's basis is written directly from the yaw. [member Node3D.rotation] is not used because
## Godot then recomputes the scale from the previous basis and the rounding drifts it away from 1
## with every turn; that hidden scale changes the collision capsule and breaks the deterministic
## replay (phase 2 reconciliation).
var yaw: float = 0.0:
	set(value):
		yaw = PlayerState.to_f32(value)
		basis = Basis(Vector3.UP, yaw)
## If false, [method simulate] does not emit [signal jumped] or [signal landed]. It is disabled
## during reconciliation replays and the client prediction's neutral advance, to avoid duplicating
## sounds and animations. It does not alter the simulation.
var events_enabled: bool = true
## Whether the character was on the ground when the last tick ended. [method simulate] uses this
## value (and not is_on_floor()) at the start of each tick, so that a restored state behaves the
## same.
var grounded: bool = false
## Buttons of the last applied input (to detect rising edges).
var prev_buttons: int = 0
## Tick of the last applied input.
var last_input_tick: int = 0
## Ticks in the air remaining to be able to jump after leaving the ground without jumping (coyote
## time).
var coyote_ticks: int = 0
## Ticks remaining for a jump press stored in the buffer (0 = none pending).
var jump_buffer_ticks: int = 0
## Combat state (docs/combate.md, section 3): current action, stamina, crowd controls...
## It is part of [method get_state] and [method set_state], and [method simulate] advances it with
## [method ActionMachine.step] at the start of each tick.
var combat: CombatState = CombatState.initial(
		CombatCatalog.rules(), CombatCatalog.default_weapon_id())
## Landing speed (m/s, positive downward) measured right before move_and_slide() on the tick in
## which [member grounded] becomes true; 0 on other ticks. The server uses it for fall damage. It
## does not travel in the state: it is an output of [method simulate].
var last_landing_speed: float = 0.0

# After set_state(), CharacterBody3D's internal state (floor, floor normal) may correspond to
# another tick; it is recomputed at the start of the next simulation.
var _floor_contact_dirty: bool = false
var _warned_tick_context: bool = false


func _ready() -> void:
	floor_max_angle = deg_to_rad(46.0)
	floor_snap_length = 0.35
	floor_constant_speed = true
	floor_stop_on_slope = true
	collision_layer = CHARACTER_COLLISION_LAYER
	collision_mask = WORLD_COLLISION_LAYER | PLAYER_BLOCKER_LAYER
	# Respects a rotation assigned before entering the tree (for example, the spawn point's) and
	# leaves the node's basis clean (yaw only, scale 1).
	yaw = rotation.y


## Mask of the movement layer of realm [param realm_code] ([RealmCatalog] network code: 1 Vardheim,
## 2 Solmarch, 3 Askarra): [code]1 << (REALM_LAYER_BASE + code - 1)[/code]. 0 for the neutral side
## (code 0, the Hollow) and for any code that is not a realm.
static func realm_layer(realm_code: int) -> int:
	if realm_code < 1 or realm_code > 3:
		return 0
	return 1 << (REALM_LAYER_BASE + realm_code - 1)


## Advances the simulation one tick with the given input. Deterministic: it reads no Input, time,
## randomness or global state, only the state members ([member yaw], [member grounded],
## [member prev_buttons], [member last_input_tick], [member coyote_ticks],
## [member jump_buffer_ticks], [member combat], the position and
## [member CharacterBody3D.velocity]).
## [br][br]
## At the start of each tick it advances the action machine ([method ActionMachine.step]), which
## decides how much the character can move, turn, jump and sprint during an attack, a block, a
## dodge, an ability, a weapon swap or a crowd control; with no action, movement is the usual.
## Movement effects (slow, root) scale the non-imposed target speed with
## [member ActionMachine.Output.speed_factor] in all actions; while rooted the character neither
## jumps nor keeps air momentum ([member ActionMachine.Output.rooted]).
## [br][br]
## [b]Important:[/b] move_and_slide() internally uses the physics tick's delta, so [param delta]
## must be exactly [code]1.0 / Engine.physics_ticks_per_second[/code] and the call must be made
## inside the physics tick (from _physics_process or after
## [code]await get_tree().physics_frame[/code]). Outside it, move_and_slide() would use the delta
## of _process and the result would no longer be deterministic.
func simulate(input: PlayerInput, delta: float) -> void:
	_check_tick_context(delta)
	if _floor_contact_dirty:
		_resync_floor_contact()
	var was_grounded: bool = grounded

	# Action machine: attacks, block, dodge, stamina and crowd controls. It decides how much the
	# character can move this tick (with no action, movement is the usual).
	var action: ActionMachine.Output = ActionMachine.step(combat, input, was_grounded)

	# Desired direction on the horizontal plane, relative to the camera's yaw.
	var look_basis := Basis(Vector3.UP, input.look_yaw)
	var forward: Vector3 = look_basis * Vector3.FORWARD
	var right: Vector3 = look_basis * Vector3.RIGHT
	var wish: Vector3 = (right * input.move.x + forward * input.move.y).limit_length(1.0)
	var wish_length: float = wish.length()

	# Orientation: when moving, the character turns toward where the camera looks; during an action
	# the action decides (it turns even when standing still, snaps to the camera on the first tick or
	# does not turn). The yaw is always assigned (also when stopped) so that its setter rewrites the
	# node's basis in case something external touched the rotation or scale.
	var new_yaw: float = yaw
	if action.snap_yaw:
		new_yaw = wrapf(input.look_yaw, -PI, PI)
	elif action.turn_rate >= 0.0:
		new_yaw = wrapf(rotate_toward(yaw, input.look_yaw, action.turn_rate * delta), -PI, PI)
	elif wish_length > FACING_MIN_WISH:
		new_yaw = wrapf(rotate_toward(yaw, input.look_yaw, turn_speed * delta), -PI, PI)
	yaw = new_yaw

	var horizontal := Vector3(velocity.x, 0.0, velocity.z)
	if action.forced_velocity:
		# Dodge or push: horizontal speed is imposed by the action, without acceleration.
		velocity.x = action.velocity.x
		velocity.z = action.velocity.z
	else:
		# Target speed. Sprinting only starts on the ground; in the air the momentum carried in is
		# preserved (see below).
		var target_velocity: Vector3
		if action.scaled_movement:
			# Inside an action: reduced run plus the attack's advance toward where the character faces
			# (already turned this tick).
			target_velocity = wish * run_speed * action.move_scale
			if action.lunge_speed != 0.0:
				target_velocity += (Basis(Vector3.UP, yaw) * Vector3.FORWARD) * action.lunge_speed
		else:
			var speed: float = run_speed
			if action.allow_sprint and input.has(PlayerInput.SPRINT) and input.move.y > 0.5 \
					and grounded:
				speed = sprint_speed
			if input.move.y < 0.0:
				speed *= backward_multiplier
			if absf(input.move.x) > absf(input.move.y):
				speed *= strafe_multiplier
			target_velocity = wish * speed
		# Movement effects (slow, root; docs/abilities.md, section 3.4): scale the target speed, also
		# the attacks' advance and the sprint. The dodge, an ability's advance and the push (imposed
		# speed) do not.
		target_velocity *= action.speed_factor

		# Horizontal acceleration. On the ground, deceleration is used when the target reduces speed in
		# the current direction (braking, releasing the sprint, turning or reversing direction).
		var rate: float = air_acceleration
		if grounded:
			var slowing_down: bool = horizontal.dot(target_velocity) < horizontal.length_squared()
			rate = ground_deceleration if slowing_down else ground_acceleration
		elif wish_length > _MIN_WISH_DIRECTION and not action.rooted \
				and not (action.scaled_movement and action.move_scale <= 0.0):
			# In the air there is no braking in the wished direction: a jump or a fall while sprinting keeps
			# its speed as long as the player keeps pushing forward. Air control only turns the movement or
			# adds speed up to the target. This does not apply to an action that does not allow movement
			# (dead, stunned or staggered with no push, with move_scale 0) nor to a rooting effect: those
			# brake, and the stick does not steer them.
			var wish_direction: Vector3 = wish / wish_length
			var carried_speed: float = horizontal.dot(wish_direction)
			if carried_speed > target_velocity.length():
				target_velocity = wish_direction * carried_speed
		horizontal = horizontal.move_toward(target_velocity, rate * delta)
		velocity.x = horizontal.x
		velocity.z = horizontal.z

	# Gravity, with limited fall speed.
	if not grounded:
		velocity.y = maxf(velocity.y - gravity * delta, -terminal_velocity)

	# Jump: the button's rising edge enters the buffer and the character jumps if there is ground or
	# coyote time remains. This way a jump pressed right before landing or right after falling off an
	# edge is not lost, and holding the button does not repeat the jump. Actions that prevent it
	# (attack, dodge, crowd controls) leave it in the buffer.
	var just_pressed: int = input.buttons & ~prev_buttons
	jump_buffer_ticks = maxi(jump_buffer_ticks - 1, 0)
	if (just_pressed & PlayerInput.JUMP) != 0:
		jump_buffer_ticks = clampi(jump_buffer_window, 1, PlayerState.MAX_JUMP_BUFFER_TICKS)
	var jumped_now: bool = false
	if action.allow_jump and jump_buffer_ticks > 0 and (grounded or coyote_ticks > 0):
		velocity.y = jump_velocity
		jump_buffer_ticks = 0
		jumped_now = true
		if events_enabled:
			jumped.emit()

	# Fall speed right before move_and_slide() zeroes it on landing.
	var fall_speed: float = maxf(-velocity.y, 0.0)
	move_and_slide()

	grounded = is_on_floor()
	last_landing_speed = fall_speed if grounded and not was_grounded else 0.0
	if grounded and not was_grounded and events_enabled:
		landed.emit()
	# Coyote time is refilled while standing on the ground (also on the tick it is left) and consumed
	# in the air. Jumping exhausts it so there is no second jump in the air.
	if jumped_now:
		coyote_ticks = 0
	elif grounded or was_grounded:
		coyote_ticks = clampi(coyote_window, 0, PlayerState.MAX_COYOTE_TICKS)
	else:
		coyote_ticks = maxi(coyote_ticks - 1, 0)
	# The substituted-input bit is not a button: it is not stored, so the state does not depend on
	# whether the input arrived or was repeated.
	prev_buttons = input.buttons & ~PlayerInput.SUBSTITUTED
	last_input_tick = input.tick


## Adds to the collision mask the movement layer of realm [param realm_code] (network code; 1
## Vardheim, 2 Solmarch, 3 Askarra), so that the closed gates of other realms' forts stop it
## ([method FortGate.layers_for]). With 0 (the Hollow) or a code that is not a realm, the mask is
## left with no realm layer. It replaces the previous call, it does not accumulate.
## [br][br]
## [b]It must be called after the character enters the tree[/b]: [method _ready] rewrites the
## mask. It is called, when creating each character that simulates, by the server (when
## registering) and the client (with the local character); remote ones do not collide. It must be
## the same realm on both sides for prediction to match.
func set_realm_collision(realm_code: int) -> void:
	collision_mask = WORLD_COLLISION_LAYER | PLAYER_BLOCKER_LAYER | realm_layer(realm_code)


## Returns a copy of the current simulation state.
func get_state() -> PlayerState:
	var state := PlayerState.new()
	state.position = global_position if is_inside_tree() else position
	state.velocity = velocity
	state.yaw = yaw
	state.grounded = grounded
	state.prev_buttons = prev_buttons
	state.last_input_tick = last_input_tick
	state.coyote_ticks = coyote_ticks
	state.jump_buffer_ticks = jump_buffer_ticks
	state.combat = combat.duplicate_state()
	return state


## Restores a simulation state (global position, velocity, yaw and rotation, grounded,
## prev_buttons, last_input_tick, the jump counters and the combat state). It does not call
## reset_physics_interpolation(): that is up to the caller.
func set_state(state: PlayerState) -> void:
	yaw = state.yaw
	if is_inside_tree():
		global_position = state.position
	else:
		position = state.position
	velocity = state.velocity
	grounded = state.grounded
	prev_buttons = state.prev_buttons
	last_input_tick = state.last_input_tick
	coyote_ticks = state.coyote_ticks
	jump_buffer_ticks = state.jump_buffer_ticks
	combat.copy_from(state.combat)
	_floor_contact_dirty = true


## Speed on the horizontal plane (m/s).
func get_horizontal_speed() -> float:
	return Vector2(velocity.x, velocity.z).length()


## Point the camera follows (at head height).
func get_camera_target() -> Node3D:
	return $CameraTarget as Node3D


# move_and_slide() depends on the floor state left by the previous call (for floor snap and for
# not climbing walls). After set_state() that state may belong to another tick, so it is rebuilt
# from the restored position and "grounded": a tiny upward displacement (without snap) resets the
# state and, if the character was on the ground, apply_floor_snap() recovers the floor contact and
# normal. Position and velocity are left exactly as they were.
func _resync_floor_contact() -> void:
	if not is_inside_tree():
		return
	_floor_contact_dirty = false
	var saved_transform: Transform3D = global_transform
	var saved_velocity: Vector3 = velocity
	velocity = up_direction * _FLOOR_PROBE_SPEED
	move_and_slide()
	global_transform = saved_transform
	if grounded:
		apply_floor_snap()
		global_transform = saved_transform
	velocity = saved_velocity


# Diagnostic: warns once if simulate() is used outside the physics tick or with a delta different
# from the physics one, because then move_and_slide() does not advance the same as the rest of
# the step. It does not affect the simulation result.
func _check_tick_context(delta: float) -> void:
	if _warned_tick_context:
		return
	if not Engine.is_in_physics_frame():
		_warned_tick_context = true
		push_warning(
			"PlayerCharacter.simulate() se ha llamado fuera del tick de física; "
			+ "move_and_slide() usará el delta de _process y la simulación no será determinista."
		)
	elif not is_equal_approx(delta, get_physics_process_delta_time()):
		_warned_tick_context = true
		push_warning(
			"PlayerCharacter.simulate(): delta (%f) no coincide con el delta de física (%f) "
			% [delta, get_physics_process_delta_time()]
			+ "que usa move_and_slide()."
		)
