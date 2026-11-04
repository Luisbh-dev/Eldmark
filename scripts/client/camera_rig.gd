class_name CameraRig
extends Node3D
## Over-the-shoulder third-person action camera (New World style).
##
## Client only. Scene hierarchy:
## [codeblock]
## CameraRig (top_level, follows the target)
##     Yaw (rotation.y = yaw)
##         Pitch (rotation.x = pitch, positive looks up)
##             Arm (SpringArm3D: shape, margin, mask and exclusions)
##                 Camera (Camera3D, h_offset = shoulder)
## [/codeblock]
## - The pivot follows the target's [b]interpolated[/b] position every frame
##   ([method Node3D.get_global_transform_interpolated]) with exponential smoothing, so the image
##   runs smoothly at any refresh rate even though the character only moves on physics ticks.
## - When jumping, the pivot rises only part of the jump ([member air_follow_ratio]) and never
##   more than a low ceiling allows, so the camera does not go inside the character's head when
##   jumping in a corridor or under a doorway.
## - The captured mouse turns [code]Yaw[/code] and [code]Pitch[/code] without smoothing: aiming is
##   immediate.
## - The arm starts centered on the head and the shoulder offset is done with
##   [member Camera3D.h_offset]; this way the collision sweep never starts inside a wall.
## - Collision: every frame the arm's sphere is swept backward and then toward the shoulder. If
##   something gets in the way, the camera moves closer instantly; when the gap clears it returns
##   smoothly. It never goes through walls.
## - If a wall blocks the chosen shoulder and the other is free, the camera temporarily switches
##   to the other shoulder so the character does not cover the crosshair.
## [br][br]Godot's [SpringArm3D] only recalculates its length on physics ticks (60 Hz) and, with
## the rig moving in [method _process], that produces jumps at high refresh rates and allows going
## through walls for a frame. That is why its internal processing is disabled and the equivalent
## sweep is done here every frame, using the configuration of the [code]Arm[/code] node itself.

## Fraction of the shoulder offset that must be free to use that side (when switching shoulders
## automatically and when returning to the chosen one).
const AUTO_SWAP_CLEAR_RATIO: float = 0.9
## Meters of hysteresis when showing again the node hidden for being too close.
const HIDE_HYSTERESIS: float = 0.15
## Group that every action camera belongs to: the settings ([ClientSettings]) use it to apply
## sensitivity, invert Y, field of view and default shoulder live.
const GROUP: StringName = &"camera_rig"
## Radians per pixel with mouse sensitivity at 1 in the settings.
const DEFAULT_MOUSE_SENSITIVITY: float = 0.0025
## Frequency (rad/s) of the two waves that make up the impact shake.
const SHAKE_FREQUENCY_X: float = 61.0
const SHAKE_FREQUENCY_Y: float = 47.0
## Maximum amplitude (m) of a shake, however strong the hit.
const MAX_SHAKE_AMPLITUDE: float = 0.25
## Fraction of the configured field of view at full bow aim ([method set_aim_zoom] at 1;
## docs/abilities.md, section 6.5).
const AIM_ZOOM_FOV_SCALE: float = 0.75

## Radians of rotation per pixel of mouse movement.
@export var mouse_sensitivity: float = DEFAULT_MOUSE_SENSITIVITY
## Inverts the mouse's vertical axis.
@export var invert_y: bool = false

@export_group("Seguimiento")
## Speed (1/s) at which the pivot catches up with the target. Higher, stiffer.
@export var follow_sharpness: float = 25.0
## If the target jumps farther than this (teleport, server correction), the camera repositions at
## once instead of sliding.
@export var snap_distance: float = 6.0
## Fraction of a jump's rise that the pivot follows (0 = does not rise when jumping, 1 = follows
## the whole jump). Following only part keeps the horizon steadier when aiming in the air. When
## falling below the starting height, it is followed fully.
@export_range(0.0, 1.0, 0.05) var air_follow_ratio: float = 0.5

@export_group("Ángulos")
## Minimum pitch in degrees (negative looks down).
@export_range(-89.0, 0.0, 0.5) var min_pitch_degrees: float = -75.0
## Maximum pitch in degrees (positive looks up).
@export_range(0.0, 89.0, 0.5) var max_pitch_degrees: float = 60.0

@export_group("Zoom")
## Meters the distance changes with each wheel step.
@export var zoom_step: float = 0.5
## Minimum arm distance.
@export var min_distance: float = 1.5
## Maximum arm distance.
@export var max_distance: float = 6.0
## Speed (1/s) at which the distance reaches the requested zoom.
@export var zoom_sharpness: float = 12.0
## Speed (1/s) at which the field of view follows the bow aim ([method set_aim_zoom]).
@export var aim_zoom_sharpness: float = 10.0

@export_group("Sacudida")
## If false, [method add_shake] does not move the camera (player option).
@export var shake_enabled: bool = true

@export_group("Hombro y colisión")
## Speed (1/s) of the shoulder switch.
@export var shoulder_sharpness: float = 10.0
## Speed (1/s) at which the camera recovers its place when an obstacle stops blocking it.
## Moving closer due to collision is always instant.
@export var collision_recover_sharpness: float = 8.0
## If a wall takes more than this fraction of the shoulder offset from the chosen shoulder and the
## other side is free, the camera temporarily switches to the other shoulder.
@export_range(0.0, 1.0, 0.05) var auto_swap_blocked_ratio: float = 0.5
## Seconds the chosen shoulder must be free before returning to it.
@export var auto_swap_return_delay: float = 0.6
## Distance (m) between the camera and the target below which the node from [method set_hide_when_close] is hidden, so the character's interior is not seen.
@export var hide_target_distance: float = 0.8

var _target: Node3D = null
## Target body (the one excluded from collision), to know whether it is in the air.
var _target_body: CharacterBody3D = null
## Height of the target the last time its body was on the ground.
var _ground_height: float = 0.0
var _snap_pending: bool = true
var _yaw: float = 0.0
var _pitch: float = 0.0

## Cursor released persistently (Esc, loss of focus, startup without focus).
var _free_toggled: bool = false
## Cursor released while the key is held (Alt).
var _free_held: bool = false
## The view is controlled by a script (demo): the mouse is neither captured nor read.
var _scripted_look: bool = false
## Which interface element (the death screen, a window, a dialog) asks for the free cursor while it
## is open: requester's instance id -> true. Several may ask at once and the mouse is only
## recaptured when none remain.
var _ui_cursor_holders: Dictionary = {}

var _zoom_target: float = 3.5
var _zoom_distance: float = 3.5
var _shoulder_offset: float = 0.6
var _shoulder_side: float = 1.0
var _shoulder_blend: float = 1.0
## Temporary shoulder (-1 or 1) when the chosen one is blocked; 0 = the chosen one is used.
var _shoulder_override: float = 0.0
## Consecutive seconds the chosen shoulder has been free while the other one is in use.
var _override_clear_time: float = 0.0
## Position of the camera's eye relative to the pivot in the last frame (global).
var _eye_offset: Vector3 = Vector3.ZERO
## Node that is hidden when the camera is too close to the target.
var _hide_node: Node3D = null
## Meters that collision currently takes off the distance and the shoulder.
var _distance_pull: float = 0.0
var _offset_pull: float = 0.0

## Impact shake: initial amplitude (m), duration and time left (s), clock of its waves and offset
## (x = horizontal, y = vertical) that is added to the camera.
var _shake_amplitude: float = 0.0
var _shake_duration: float = 0.0
var _shake_time_left: float = 0.0
var _shake_clock: float = 0.0
var _shake_offset: Vector2 = Vector2.ZERO
## Vertical offset of the scene's camera (without shake).
var _base_v_offset: float = 0.0
## Configured vertical field of view (scene or settings), without the bow aim.
var _configured_fov: float = 72.0
## Requested bow aim (0 to 1) and the one currently applied (which follows it smoothly).
var _aim_zoom_target: float = 0.0
var _aim_zoom: float = 0.0

var _exclude: Array[RID] = []
var _query: PhysicsShapeQueryParameters3D = PhysicsShapeQueryParameters3D.new()
var _fallback_shape: SphereShape3D = null

@onready var _yaw_node: Node3D = $Yaw
@onready var _pitch_node: Node3D = $Yaw/Pitch
@onready var _arm: SpringArm3D = $Yaw/Pitch/Arm
@onready var _camera: Camera3D = $Yaw/Pitch/Arm/Camera


func _ready() -> void:
	InputBindings.ensure_defaults()
	add_to_group(GROUP)
	# It moves in _process with the already interpolated position: it must not be interpolated
	# again. Its children (arm and camera) inherit the mode.
	physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	top_level = true

	_disable_builtin_spring()
	_arm.tree_entered.connect(_disable_builtin_spring)
	for rid: RID in _exclude:
		_arm.add_excluded_object(rid)

	_zoom_target = clampf(_arm.spring_length, min_distance, max_distance)
	_zoom_distance = _zoom_target
	_shoulder_offset = absf(_camera.h_offset)
	_base_v_offset = _camera.v_offset
	_configured_fov = _camera.fov
	_shoulder_side = -1.0 if _camera.h_offset < 0.0 else 1.0
	_shoulder_blend = _shoulder_side

	_query.collide_with_bodies = true
	_query.collide_with_areas = false

	# A window that opens without focus (an automatic capture, another instance) does not take the
	# mouse from whoever is working in another window: it starts with the cursor free and a click captures it.
	if starts_with_free_cursor(get_window()):
		_free_toggled = true
	_apply_look()
	_refresh_mouse_mode()
	# What the player has saved in the settings (only what they have changed).
	ClientSettings.current().apply_to_camera(self, true)


func _process(delta: float) -> void:
	_poll_free_cursor()
	_update_follow(delta)
	_zoom_distance = lerpf(_zoom_distance, _zoom_target, _smoothing(zoom_sharpness, delta))
	_update_aim_zoom(delta)
	_update_shake(delta)
	_update_collision(delta)


func _input(event: InputEvent) -> void:
	# The key to release the cursor is handled here (before the interface) so that releasing it
	# always recaptures the mouse.
	if event.is_action(&"free_cursor"):
		_set_free_held(event.is_pressed())
		return
	# Mouse turning also goes here: while the mouse is captured, no interface control must be able
	# to keep the movement.
	var motion: InputEventMouseMotion = event as InputEventMouseMotion
	if motion == null or not _is_mouse_look_active():
		return
	# screen_relative: real pixels, without the stretch mode's scaling, so that sensitivity does not
	# change with the window size.
	var turn: Vector2 = motion.screen_relative * mouse_sensitivity
	var pitch_sign: float = 1.0 if invert_y else -1.0
	set_look(_yaw - turn.x, _pitch + turn.y * pitch_sign)


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed(&"toggle_cursor"):
		_free_toggled = not _free_toggled
		_refresh_mouse_mode()
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed(&"shoulder_swap"):
		_shoulder_side = -_shoulder_side
		_shoulder_override = 0.0
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed(&"zoom_in"):
		_zoom_target = clampf(_zoom_target - zoom_step, min_distance, max_distance)
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed(&"zoom_out"):
		_zoom_target = clampf(_zoom_target + zoom_step, min_distance, max_distance)
		get_viewport().set_input_as_handled()
	elif _free_toggled and not _scripted_look:
		# With the cursor free, a click that the interface did not use recaptures.
		var button: InputEventMouseButton = event as InputEventMouseButton
		if button != null and button.pressed and button.button_index == MOUSE_BUTTON_LEFT:
			_free_toggled = false
			_refresh_mouse_mode()
			get_viewport().set_input_as_handled()


func _notification(what: int) -> void:
	match what:
		NOTIFICATION_APPLICATION_FOCUS_OUT:
			# When switching windows the mouse is released; a click recaptures it.
			_free_toggled = true
			_free_held = false
			_refresh_mouse_mode()
		NOTIFICATION_EXIT_TREE:
			Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
			if is_instance_valid(_hide_node):
				_hide_node.visible = true


## Follows [param target] (normally the character's head marker). [param exclude] is the
## character's own body, which the camera ignores when checking collisions; if it is a
## [CharacterBody3D], it is also used to know when it is in the air. The first frame is placed
## without smoothing.
func set_target(target: Node3D, exclude: CollisionObject3D = null) -> void:
	_target = target
	_target_body = exclude as CharacterBody3D
	_snap_pending = true
	if exclude != null:
		var rid: RID = exclude.get_rid()
		if not _exclude.has(rid):
			_exclude.append(rid)
			if is_node_ready():
				_arm.add_excluded_object(rid)
	if is_inside_tree() and _has_target():
		_update_follow(0.0)


## View yaw in radians, in [-PI, PI]. Same convention as [member Node3D.rotation].y: 0 looks
## toward -Z.
func get_yaw() -> float:
	return wrapf(_yaw, -PI, PI)


## View pitch in radians; positive looks up.
func get_pitch() -> float:
	return _pitch


## Configured vertical field of view, in degrees (the settings' one: without the bow-aim
## narrowing, which reduces it on the camera while the bow is drawn).
func get_fov() -> float:
	return _configured_fov


## Sets the configured vertical field of view, in degrees (player settings). The bow aim then
## narrows it from this value.
func set_fov(degrees: float) -> void:
	_configured_fov = degrees
	_apply_fov()


## Bow aim (docs/abilities.md, section 6.5): with [param amount] from 0 (none) to 1 (fully
## drawn), the camera's field of view narrows down to [constant AIM_ZOOM_FOV_SCALE] of the
## configured one, smoothly ([member aim_zoom_sharpness]). It does not touch the arm or the
## shoulder: the canonical aim ray does not change.
func set_aim_zoom(amount: float) -> void:
	_aim_zoom_target = clampf(amount, 0.0, 1.0)


## Requested bow aim (0 to 1, [method set_aim_zoom]).
func get_aim_zoom() -> float:
	return _aim_zoom_target


## Vertical field of view the camera currently has (the configured one with the aim narrowing).
func get_effective_fov() -> float:
	return _camera.fov if _camera != null else _configured_fov


## Chosen shoulder: 1 right, -1 left (not counting the temporary switch because of a wall).
func get_chosen_shoulder() -> int:
	return -1 if _shoulder_side < 0.0 else 1


## Shoulder currently looked over: 1 right, -1 left, counting the temporary switch because of a
## wall. It is the one that sets the [constant PlayerInput.AIM_LEFT] bit of the inputs
## (docs/abilities.md, section 6.5).
func get_effective_shoulder() -> int:
	return -1 if _get_shoulder_side() < 0.0 else 1


## Chooses the shoulder to look over, 1 right or -1 left (the settings' default value; the
## shoulder-switch key then toggles it). The change is smooth.
func set_default_shoulder(side: int) -> void:
	_shoulder_side = -1.0 if side < 0 else 1.0
	_shoulder_override = 0.0


## Sets the view. Pitch is clamped to [[member min_pitch_degrees], [member max_pitch_degrees]].
func set_look(yaw: float, pitch: float) -> void:
	_yaw = wrapf(yaw, -PI, PI)
	_pitch = clampf(pitch, deg_to_rad(min_pitch_degrees), deg_to_rad(max_pitch_degrees))
	_apply_look()


## true if the player has released the cursor (Alt held, Esc or loss of focus): the camera does
## not turn and clicks are for the interface.
func is_cursor_free() -> bool:
	if _scripted_look:
		return false
	return _free_toggled or _free_held or _has_ui_cursor_holders()


## An interface element ([param holder]: the death screen, a window, a dialog) releases the cursor
## while it is open: the camera does not turn, clicks are for it and the crosshair is hidden. When
## it is closed ([param enabled] set to false) it stops asking for it, and the mouse is recaptured
## only if no other requester remains and the player has not released it by hand. Each requester
## counts only once, however many times it asks.
func set_ui_cursor_release(enabled: bool, holder: Object) -> void:
	var key: int = holder.get_instance_id()
	if enabled:
		_ui_cursor_holders[key] = true
	else:
		_ui_cursor_holders.erase(key)
	_refresh_mouse_mode()


## true if any interface element (a window, a dialog, the death screen, the map or the chat line)
## currently has the cursor free ([method set_ui_cursor_release]). It does not count the cursor
## released by the player by hand (Alt or Esc), nor the one requested by [param ignored_holder] if given.
func is_ui_holding_cursor(ignored_holder: Object = null) -> bool:
	if not _has_ui_cursor_holders():
		return false
	if ignored_holder == null:
		return true
	var ignored_key: int = ignored_holder.get_instance_id()
	for key: int in _ui_cursor_holders.keys():
		if key != ignored_key:
			return true
	return false


# true if any live requester is still asking for the free cursor. It discards those that were
# freed without notice (their instance id no longer points to anything).
func _has_ui_cursor_holders() -> bool:
	for key: int in _ui_cursor_holders.keys():
		if not is_instance_id_valid(key):
			_ui_cursor_holders.erase(key)
	return not _ui_cursor_holders.is_empty()


func get_camera() -> Camera3D:
	return get_node_or_null(^"Yaw/Pitch/Arm/Camera") as Camera3D


## Aim ray that passes through the center of the screen (the crosshair). Returns
## [code]{"origin": Vector3, "direction": Vector3}[/code] with the direction normalized, in global
## coordinates.
func get_aim_ray() -> Dictionary:
	var camera: Camera3D = get_camera()
	if camera == null or not camera.is_inside_tree():
		var look_basis: Basis = Basis.from_euler(Vector3(_pitch, _yaw, 0.0))
		return {"origin": global_position, "direction": look_basis * Vector3.FORWARD}
	var center: Vector2 = camera.get_viewport().get_visible_rect().size * 0.5
	return {
		"origin": camera.project_ray_origin(center),
		"direction": camera.project_ray_normal(center).normalized(),
	}


## Hides [param node] (normally the character model) while the camera is within [member hide_target_distance] of the target, for example with the back against a corner. null stops
## hiding anything.
func set_hide_when_close(node: Node3D) -> void:
	if is_instance_valid(_hide_node) and _hide_node != node:
		_hide_node.visible = true
	_hide_node = node


## Shakes the camera for a moment, for example on taking a hit (ART-09, basic). It moves the view
## [param amplitude] meters (at most [constant MAX_SHAKE_AMPLITUDE]) with a fast oscillation that
## decays to zero over [param duration] seconds. A new shake does not cancel the one in progress:
## the stronger of the two is kept. It does nothing with [member shake_enabled] set to false.
func add_shake(amplitude: float, duration: float) -> void:
	if not shake_enabled or amplitude <= 0.0 or duration <= 0.0:
		return
	var remaining: float = _current_shake_amplitude()
	_shake_amplitude = maxf(remaining, minf(amplitude, MAX_SHAKE_AMPLITUDE))
	_shake_duration = duration
	_shake_time_left = duration


## Offset (m) that the shake currently adds to the camera: x horizontally, y vertically.
func get_shake_offset() -> Vector2:
	return _shake_offset


## true while a shake lasts.
func is_shaking() -> bool:
	return _shake_time_left > 0.0


## Scripted view (demo and automated tests): the camera does not capture the mouse or read its
## movement and the view only changes with [method set_look]. [method is_cursor_free] returns
## false so the crosshair keeps being drawn and the scene looks the same as when playing.
func set_scripted_look(enabled: bool) -> void:
	_scripted_look = enabled
	_refresh_mouse_mode()


func _has_target() -> bool:
	return is_instance_valid(_target) and _target.is_inside_tree()


func _apply_look() -> void:
	if not is_node_ready():
		return
	_yaw_node.rotation.y = _yaw
	_pitch_node.rotation.x = _pitch


func _update_follow(delta: float) -> void:
	if not _has_target():
		return
	var goal: Vector3 = _target.get_global_transform_interpolated().origin
	var snap: bool = _snap_pending \
			or global_position.distance_squared_to(goal) > snap_distance * snap_distance
	# In the air the pivot rises only part of what the target rises above its ground height; if it
	# falls below it (a ledge), it follows it fully.
	if snap or not _is_target_airborne() or goal.y < _ground_height:
		_ground_height = goal.y
	goal.y = _ground_height + (goal.y - _ground_height) * air_follow_ratio
	if snap:
		global_position = goal
		_snap_pending = false
		# No previous history: collision must be resolved right away, without smoothing.
		_distance_pull = 0.0
		_offset_pull = 0.0
	else:
		global_position = global_position.lerp(goal, _smoothing(follow_sharpness, delta))
	_clamp_below_ceiling()


## While the pivot is above the target's ground height (during a jump), it does not let it rise
## more than the ceiling allows, neither it nor the camera's eye. Without this, under a low
## ceiling the backward sweep hits the ceiling and shortens the arm at once until the camera ends
## up in the head.
func _clamp_below_ceiling() -> void:
	var rise: float = global_position.y - _ground_height
	if rise <= 0.0:
		return
	var base := Vector3(global_position.x, _ground_height, global_position.z)
	var room: float = minf(_sweep(base, Vector3.UP, rise),
			_sweep(base + _eye_offset, Vector3.UP, rise))
	if room < rise:
		global_position.y = _ground_height + room


func _is_target_airborne() -> bool:
	return is_instance_valid(_target_body) and not _target_body.is_on_floor()


## The bow aim follows the requested one smoothly and narrows the field of view.
func _update_aim_zoom(delta: float) -> void:
	if is_equal_approx(_aim_zoom, _aim_zoom_target):
		if _aim_zoom != _aim_zoom_target:
			_aim_zoom = _aim_zoom_target
			_apply_fov()
		return
	_aim_zoom = lerpf(_aim_zoom, _aim_zoom_target, _smoothing(aim_zoom_sharpness, delta))
	if absf(_aim_zoom - _aim_zoom_target) < 0.001:
		_aim_zoom = _aim_zoom_target
	_apply_fov()


## Camera field of view: the configured one, narrowed by the bow aim.
func _apply_fov() -> void:
	if _camera == null:
		return
	_camera.fov = _configured_fov * lerpf(1.0, AIM_ZOOM_FOV_SCALE, _aim_zoom)


## Advances the impact shake and computes its offset for this frame.
func _update_shake(delta: float) -> void:
	if _shake_time_left <= 0.0:
		_shake_offset = Vector2.ZERO
		return
	_shake_time_left = maxf(_shake_time_left - delta, 0.0)
	_shake_clock += delta
	var amplitude: float = _current_shake_amplitude()
	_shake_offset = Vector2(sin(_shake_clock * SHAKE_FREQUENCY_X),
			cos(_shake_clock * SHAKE_FREQUENCY_Y)).limit_length(1.0) * amplitude


# Amplitude of the shake now: it decays linearly to 0.
func _current_shake_amplitude() -> float:
	if _shake_time_left <= 0.0 or _shake_duration <= 0.0:
		return 0.0
	return _shake_amplitude * clampf(_shake_time_left / _shake_duration, 0.0, 1.0)


## Places the camera along the arm and on the shoulder without putting it inside the geometry:
## first it sweeps backward from the pivot and then, from the end of the arm, toward the shoulder
## side. The whole path pivot -> arm -> eye stays clear, so the eye never ends up inside a wall.
func _update_collision(delta: float) -> void:
	var desired_distance: float = _zoom_distance
	_arm.spring_length = desired_distance

	var pivot: Vector3 = _arm.global_position
	var arm_basis: Basis = _arm.global_basis.orthonormalized()
	var back: Vector3 = arm_basis.z
	var right: Vector3 = arm_basis.x
	var recover: float = _smoothing(collision_recover_sharpness, delta)

	var free_distance: float = _sweep(pivot, back, desired_distance)
	_distance_pull = _resolve_pull(_distance_pull, desired_distance - free_distance, recover)
	var distance: float = maxf(desired_distance - _distance_pull, 0.0)
	var arm_end: Vector3 = pivot + back * distance

	_update_shoulder_override(arm_end, right, delta)
	var side_weight: float = _smoothing(shoulder_sharpness, delta)
	_shoulder_blend = lerpf(_shoulder_blend, _get_shoulder_side(), side_weight)
	var desired_offset: float = _shoulder_offset * _shoulder_blend
	var offset_side: float = signf(desired_offset)
	var offset_length: float = absf(desired_offset)

	var free_offset: float = offset_length
	if offset_length > 0.001:
		free_offset = _sweep(arm_end, right * offset_side, offset_length)
	_offset_pull = _resolve_pull(_offset_pull, offset_length - free_offset, recover)
	var offset: float = offset_side * maxf(offset_length - _offset_pull, 0.0)

	_camera.position = Vector3(0.0, 0.0, distance)
	_camera.h_offset = offset + _shake_offset.x
	_camera.v_offset = _base_v_offset + _shake_offset.y
	_eye_offset = back * distance + right * offset
	_update_hidden_node()


## Shoulder in use now: the temporary one if there is one, otherwise the chosen one.
func _get_shoulder_side() -> float:
	return _shoulder_override if _shoulder_override != 0.0 else _shoulder_side


## Automatic shoulder switch. If a wall blocks the chosen shoulder and the other is free, the
## other is used; it returns to the chosen one when it has been free for [member auto_swap_return_delay] seconds, or sooner if the other becomes more blocked. This way the
## character does not end up between the camera and the crosshair next to a wall.
func _update_shoulder_override(arm_end: Vector3, right: Vector3, delta: float) -> void:
	var full: float = _shoulder_offset
	if full <= 0.001:
		_shoulder_override = 0.0
		return
	var free_preferred: float = _sweep(arm_end, right * _shoulder_side, full)
	if _shoulder_override == 0.0:
		if free_preferred < full * auto_swap_blocked_ratio:
			var free_other: float = _sweep(arm_end, right * -_shoulder_side, full)
			if free_other >= full * AUTO_SWAP_CLEAR_RATIO:
				_shoulder_override = -_shoulder_side
				_override_clear_time = 0.0
		return
	if free_preferred >= full * AUTO_SWAP_CLEAR_RATIO:
		_override_clear_time += delta
	else:
		_override_clear_time = 0.0
	var free_override: float = _sweep(arm_end, right * _shoulder_override, full)
	if _override_clear_time >= auto_swap_return_delay or free_override < free_preferred:
		_shoulder_override = 0.0


## Hides the node from [method set_hide_when_close] with the camera pressed against the target
## (with a little hysteresis so it does not flicker at the limit).
func _update_hidden_node() -> void:
	if not is_instance_valid(_hide_node) or not _has_target():
		return
	var eye: Vector3 = global_position + _eye_offset
	var target_position: Vector3 = _target.get_global_transform_interpolated().origin
	var eye_distance: float = eye.distance_to(target_position)
	if _hide_node.visible and eye_distance < hide_target_distance:
		_hide_node.visible = false
	elif not _hide_node.visible and eye_distance > hide_target_distance + HIDE_HYSTERESIS:
		_hide_node.visible = true


## Free distance (in meters, up to [param distance]) when sweeping the arm's sphere from [param from] in direction [param direction], leaving the arm's margin from whatever it hits.
func _sweep(from: Vector3, direction: Vector3, distance: float) -> float:
	if distance <= 0.0 or not is_inside_tree():
		return distance
	var space: PhysicsDirectSpaceState3D = get_world_3d().direct_space_state
	if space == null:
		return distance
	var margin: float = maxf(_arm.margin, 0.0)
	var travel: float = distance + margin
	_query.shape = _get_sweep_shape()
	_query.collision_mask = _arm.collision_mask
	_query.exclude = _exclude
	_query.transform = Transform3D(Basis.IDENTITY, from)
	_query.motion = direction * travel
	var fractions: PackedFloat32Array = space.cast_motion(_query)
	if fractions.is_empty() or fractions[0] >= 1.0:
		return distance
	return clampf(travel * fractions[0] - margin, 0.0, distance)


func _get_sweep_shape() -> Shape3D:
	if _arm.shape != null:
		return _arm.shape
	if _fallback_shape == null:
		_fallback_shape = SphereShape3D.new()
		_fallback_shape.radius = 0.2
	return _fallback_shape


## Collision brings the camera closer instantly and lets it return smoothly.
static func _resolve_pull(current: float, wanted: float, recover: float) -> float:
	wanted = maxf(wanted, 0.0)
	if wanted >= current:
		return wanted
	return lerpf(current, wanted, recover)


## Exponential smoothing factor independent of the frame rate.
static func _smoothing(sharpness: float, delta: float) -> float:
	return 1.0 - exp(-sharpness * delta)


## The SpringArm3D re-enables its internal processing every time it enters the tree; the
## camera's collision is resolved in [method _update_collision].
func _disable_builtin_spring() -> void:
	_arm.set_physics_process_internal(false)


## true if the mouse must not be captured on startup: startup with [code]--sin-raton[/code] or
## with [code]ELDMARK_SIN_RATON=1[/code], or a real window that does not have focus. With no
## window (headless tests) the usual capture is kept.
static func starts_with_free_cursor(window: Window) -> bool:
	if OS.get_cmdline_user_args().has("--sin-raton") or OS.get_environment("ELDMARK_SIN_RATON") == "1":
		return true
	return DisplayServer.get_name() != "headless" and window != null and not window.has_focus()


func _is_mouse_look_active() -> bool:
	return not _scripted_look and not is_cursor_free() \
			and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED


func _poll_free_cursor() -> void:
	# Fallback in case the release event is lost (for example, Alt+Tab).
	var held: bool = Input.is_action_pressed(&"free_cursor")
	if held != _free_held:
		_set_free_held(held)


func _set_free_held(held: bool) -> void:
	if held == _free_held:
		return
	_free_held = held
	_refresh_mouse_mode()


func _refresh_mouse_mode() -> void:
	if not is_inside_tree():
		return
	var wanted: Input.MouseMode = Input.MOUSE_MODE_CAPTURED
	if _scripted_look or is_cursor_free():
		wanted = Input.MOUSE_MODE_VISIBLE
	if Input.mouse_mode != wanted:
		Input.mouse_mode = wanted
