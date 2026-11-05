class_name CharacterAnimator
extends Node
## Drives the [AnimationTree] of a [HumanoidVisual] from the state of a [PlayerCharacter].
##
## Client only and read-only: every frame it reads the velocity, the interpolated orientation and
## [member PlayerCharacter.grounded] of the character it decorates, and listens to
## [signal PlayerCharacter.jumped]. It never writes to the simulation and the server needs none
## of this. The landing is deduced from the change of [member PlayerCharacter.grounded] (and not from
## [signal PlayerCharacter.landed]) so that a reconciliation that replays past ticks does not
## trigger false landings; for the same reason, the jump is validated against the current state (in the
## air and rising) and is also detected without the signal if the ground is left while rising fast.
## [br][br]
## [b]Locomotion.[/b] The [code]locomotion[/code] node of the tree is a BlendSpace1D by speed
## (m/s) with walk, jog and sprint. Each clip has its own timeline stretched to
## 1 s, so they are all in phase (left foot planted at the start of the cycle) and a single
## TimeScale sets the cycles per second. So that the feet do not skate, that rate is the
## real speed divided by the blended stride (meters per cycle of each clip, from
## [member clip_ground_speeds]).
## [br][br]
## [b]Orientation.[/b] UAL has no sideways or backward movement clips. So that
## strafing does not look like skating, the hips (the [code]Pivot[/code] node, not the simulation) turn
## toward the direction of movement and the spine ([SpineTwistModifier]) turns the opposite way
## so that the chest and head keep facing the aim point. When backpedaling (movement at
## more than [member backpedal_enter_angle] from the simulation's yaw) the model looks forward and
## the locomotion plays in reverse: the character walks backward facing the enemy instead of
## turning around and running toward the camera. When standing still, it smoothly returns to the simulation's yaw. The
## Pivot does not use physics interpolation: its turn is applied every frame on top of the character's
## interpolated transform.
## [br][br]
## [b]Dodge[/b] (ART-49, visual only): during [constant CombatState.Action.DODGE] the model faces the direction of
## travel from the first frame (the heading of the dodge in the character's state or, on a remote, its
## velocity) and the spine does not compensate for the turn: the roll goes head first toward where the body moves in
## all four directions, backward too. When it ends, the model returns to the usual turn with the smoothing
## of [member turn_sharpness] and the spine recovers its compensation over [member dodge_twist_return_time]. The
## simulation is unaware: only the [code]Pivot[/code] moves.
## [br][br]
## [b]Combat stance[/b] (ART-45): the [ArmedStanceModifier] applies the combat rest (the shield guard
## from [code]ual2/Idle_Shield_Loop[/code]) when standing still and, while walking, an arm layer with weight 0.6 to
## 0.9 (the shield in front of the torso, the blade not going backward) and closed fingers. It steps aside in the air, with a
## full-body clip (dodge, death...) and with the bow; the Hollow uses the zombie profile.
## [br][br]
## [b]Attacks with planted feet[/b] (ART-46): while an attack lasts without the input asking to walk, the model
## faces where the camera faces (it snaps into place at the start) and the combat layer takes hips and legs from the
## clip ([member CombatAnimationLayer.move_request] at 0). What the attack's lunge advances does not count as
## input: it is subtracted from the velocity. If walking is requested, everything goes back to locomotion.
## [br][br]
## [b]Reactions[/b] (ART-48, ART-50, ART-51): [method react_to_hit] gives the [HitReactionModifier] the hit received or
## blocked; the stagger takes a step back with the [code]Pivot[/code]; on death, the body keeps part of the
## velocity it had (it slides and slows down) and turns toward the attacker to fall away from them. It is all
## visual: the simulation is unaware.
## [br][br]
## [b]Air.[/b] Jumping plays Jump_Start from the takeoff (without the crouching anticipation, because
## the simulation has already taken off) and switches to Jump_Loop when it starts to fall; falling off an edge goes
## straight to Jump_Loop. On landing, Jump_Land is blended with an intensity that depends on the
## impact speed and on whether the character keeps running.

## [br][br]
## [b]Combat.[/b] On top of the locomotion goes the combat animation layer ([CombatAnimationLayer],
## ART-08): attacks, block, stagger and stun on the upper body; dodge and
## death on the whole body. The action comes from the character's [member PlayerCharacter.combat] (the local
## player and the sandbox) or, on a remote, from the [code]action[/code] byte of its record
## ([method set_remote_source]). Each clip is rescaled to the duration of the phase in the combat
## data; see [CombatClipPlanner]. The pose is applied by the [CombatPoseModifier] after the tree.
## [br][br]
## [b]Active weapon[/b] (phase 4): the one from the character's state or, on a remote, the one its view gives (weapon pair
## and slot bit of the record, [method set_remote_source]). It picks the weapon's clip set and,
## when it changes, notifies through [signal weapon_shown] (the [HumanoidVisual] swaps the hand props,
## [WeaponProps]). If the change arrives during the [constant CombatState.Action.SWAP] action (ART-06), the
## props change mid-gesture ([member swap_show_fraction]) rather than on the first frame; in any other
## case (spawning, an equipment change) they change instantly.

## Path of the tree's parameters (see humanoid_visual.tscn).
const PARAM_LOCOMOTION_BLEND: StringName = &"parameters/locomotion/blend_position"
const PARAM_LOCOMOTION_SCALE: StringName = &"parameters/locomotion_speed/scale"
const PARAM_MOVE: StringName = &"parameters/move/blend_amount"
const PARAM_LAND: StringName = &"parameters/land/blend_amount"
const PARAM_LAND_SEEK: StringName = &"parameters/land_seek/seek_request"
const PARAM_LAND_SCALE: StringName = &"parameters/land_speed/scale"
const PARAM_JUMP_SEEK: StringName = &"parameters/jump_seek/seek_request"
const PARAM_AIR_PHASE: StringName = &"parameters/air_phase/blend_amount"
const PARAM_AIR: StringName = &"parameters/air/blend_amount"
## Locomotion BlendSpace1D node inside the tree.
const LOCOMOTION_NODE: StringName = &"locomotion"

## The weapon shown in the hands has changed (combat catalog id; 0 = none known).
signal weapon_shown(weapon_id: int)
## The weapon's hit becomes active (or stops being so), for the local player and for remotes
## ([method CombatAnimationLayer.is_swing_active]): the sword trail hangs from this.
signal swing_active_changed(active: bool)

## The character leaves the ground with a jump (for the sound and the dust; it is not emitted when falling off an edge).
signal jumped_visual
## The character touches the ground after being in the air, with [param strength] from 0 to 1 according to the impact speed.
signal touched_down(strength: float)
## A remote starts a combat action ([param action] is a [enum CombatState.Action]; [param step] the combo
## step, the ability slot or the restart counter from the action byte). Remotes only: the local player's own is
## dispatched by [CombatFeedback].
signal remote_action_started(action: int, step: int)
## The heavy-attack charge is in progress ([param active]) with [param fraction] from 0 to 1, or has ended. It is emitted
## every frame while it lasts. The sword aura ([ChargeAura]) hangs from this.
signal charge_changed(active: bool, fraction: float)

## Air phases.
enum AirState { GROUNDED, JUMPING, FALLING }
## Horizontal speed (m/s) above which a knocked-down character crawls.
const CRAWL_MIN_SPEED: float = 0.2

## Animation tree being driven.
## Time (s) over which the model turns toward the dodge heading at the start, and the smoothing of that turn.
const DODGE_TURN_TIME: float = 0.08
const DODGE_TURN_SHARPNESS: float = 40.0
## Speed (m/s) from which the input counts as "asks to walk" during an attack (between that 8 % and 40 % of
## the run, the legs go from the clip to the locomotion).
const MOVE_REQUEST_FROM: float = 0.08
const MOVE_REQUEST_TO: float = 0.4
## Weights of the combat stance arm layer: walking and sprinting.
const STANCE_ARM_WEIGHT_WALK: float = 0.9
const STANCE_ARM_WEIGHT_SPRINT: float = 0.65
## Speed (m/s) of the zombie walk at its playback speed of 1, and the limits of that speed. Above
## [constant ZOMBIE_RUN_FROM] m/s the Hollow runs with the normal locomotion (the zombie does not sprint).
const ZOMBIE_WALK_SPEED: float = 1.1
const ZOMBIE_RUN_FROM: float = 2.8
const ZOMBIE_RUN_TO: float = 4.0
## Stagger: meters the body moves backward and how quickly it does so and returns.
const STAGGER_STEP_BACK: float = 0.3
const STAGGER_STEP_RATE: float = 2.4
const STAGGER_RETURN_RATE: float = 1.0
## Death (ART-51): fraction of the velocity the body keeps (capped in m/s), time (s) over which it slows down and
## how long it takes to turn toward the attacker.
const DEATH_SLIDE_FACTOR: float = 0.55
const DEATH_SLIDE_MAX_SPEED: float = 3.5
const DEATH_SLIDE_TAU: float = 0.28
const DEATH_FACE_SHARPNESS: float = 22.0
## Time (s) after which a received hit no longer counts as the killing one.
const LAST_HIT_MEMORY: float = 0.7

@export var animation_tree: AnimationTree
## Node that is rotated to orient the model; its parent must be a Node3D that follows the character.
@export var pivot: Node3D

## Clips of the combat actions (text resource in data/animation/).
@export var clip_set: CombatClipSet

@export_group("Locomoción")
## Ground speed (m/s) of each clip at playback speed 1, measured on the installed
## model (1.84 m Ranger) with tools/animation/measure_locomotion_strides.gd: advance
## of the toes while planted / cycle duration. (Those of the UAL mannequin's root motion variant
## are 15 % shorter and made the feet skate backward.)
@export var clip_ground_speeds: Dictionary[StringName, float] = {
	&"ual1/Walk_Loop": 1.028,
	&"ual1/Jog_Fwd_Loop": 6.093,
	&"ual1/Sprint_Loop": 9.387,
}
## How quickly the speed used for blending follows the real one (1/s, exponential smoothing).
@export var speed_smoothing: float = 14.0
## Below this speed (m/s) it blends with the rest pose.
@export var idle_blend_speed: float = 0.7
## Maximum locomotion rate (1 s cycles per second).
@export var max_locomotion_scale: float = 2.5

@export_group("Orientación")
## Horizontal speed (m/s) from which the model faces the direction it moves.
@export var turn_min_speed: float = 0.6
## Speed of the model's turn (1/s, exponential smoothing of the angle).
@export var turn_sharpness: float = 12.0
## Maximum angular speed of the model (rad/s).
@export var max_turn_speed: float = 14.0
## Angle (degrees) between the movement and the simulation's yaw from which the character backpedals
## facing forward (reverse locomotion) instead of turning around.
@export var backpedal_enter_angle: float = 110.0
## Angle (degrees) below which it stops backpedaling (hysteresis).
@export var backpedal_exit_angle: float = 95.0
## Maximum twist (degrees) with which the spine compensates for that of the hips.
@export var max_spine_twist: float = 75.0

@export_group("Esquiva")
## Time (s) the spine takes to recover its compensation toward the aim point when the dodge ends.
@export var dodge_twist_return_time: float = 0.15
## Horizontal speed (m/s) from which a remote that is dodging gives the heading of its movement.
@export var dodge_min_speed: float = 0.5

@export_group("Cambio de arma")
## Fraction of the weapon swap action (0 to 1) at which the hand props change.
@export_range(0.0, 1.0) var swap_show_fraction: float = 0.5

@export_group("Aire")
## Second of Jump_Start at which the feet leave the ground (before that there is a crouching anticipation).
@export var jump_takeoff_time: float = 0.07
## Time in the air without jumping before it is considered that the character is falling (steps, ramps).
@export var fall_grace_time: float = 0.15
## Vertical speed (m/s) below which the jump switches to the fall pose.
@export var fall_blend_velocity: float = -1.0
## Vertical speed (m/s) on leaving the ground from which it is considered a jump even if the signal
## has not arrived (for example, after a reconciliation).
@export var jump_detect_velocity: float = 4.0
## Duration of the ground -> air blend (s).
@export var air_blend_in_time: float = 0.08
## Duration of the air -> ground blend on landing (s).
@export var air_blend_out_time: float = 0.1
## Duration of the jump -> fall blend (s).
@export var fall_blend_time: float = 0.25

@export_group("Aterrizaje")
## Intensity of Jump_Land when landing while standing still after a normal jump (0..1).
@export var land_strength_idle: float = 0.8
## Intensity of Jump_Land when landing while running.
@export var land_strength_moving: float = 0.3
## Impact speed (m/s) below which the landing is not played.
@export var land_min_impact: float = 2.0
## Impact speed (m/s) from which the landing has full intensity.
@export var land_full_impact: float = 7.0
## Speed multiplier of Jump_Land (the original clip is a heavy 1.3 s landing).
@export var land_playback_speed: float = 1.6
## Time (s) the landing stays at its intensity before fading out.
@export var land_hold_time: float = 0.12
## Total duration (s) of the landing.
@export var land_duration: float = 0.5

var _character: PlayerCharacter = null
var _spine: SpineTwistModifier = null
var _blend_space: AnimationNodeBlendSpace1D = null
## Sorted BlendSpace points: [position (m/s), meters per TimeScale unit].
var _stride_points: Array[Vector2] = []

var _speed: float = 0.0
var _visual_yaw: float = 0.0
var _yaw_initialized: bool = false
var _air_state: AirState = AirState.GROUNDED
var _air_time: float = 0.0
var _min_vertical_velocity: float = 0.0
var _jump_pending: bool = false
var _air_weight: float = 0.0
var _fall_weight: float = 0.0
var _land_weight: float = 0.0
var _land_time: float = -1.0
var _land_strength: float = 0.0
var _locomotion_scale: float = 0.0
var _move_weight: float = 0.0
var _backpedal: bool = false
## Dodge in progress (the model faces its heading) and how much of the spine compensation is applied (0 to 1).
var _dodging: bool = false
var _twist_weight: float = 1.0
## Seconds the current weapon swap action has been running.
var _swap_elapsed: float = 0.0
var _combat_layer: CombatAnimationLayer = null
var _combat_modifier: CombatPoseModifier = null
var _stance: ArmedStanceModifier = null
var _reaction: HitReactionModifier = null
## Times of the combat stance clips (s).
var _stance_rest_time: float = 0.0
var _stance_walk_time: float = 0.0
## Requested stance profile: [code]shield[/code] or [code]zombie[/code].
var _stance_profile: StringName = &"shield"
# Attack in progress with the model already turned toward the camera.
var _attack_facing: bool = false
# Body: visual offset of the Pivot (stagger step back, death slide).
var _body_offset: Vector3 = Vector3.ZERO
var _slide_velocity: Vector3 = Vector3.ZERO
var _live_velocity: Vector3 = Vector3.ZERO
var _was_dead: bool = false
var _death_yaw: float = NAN
var _was_staggered: bool = false
# Last hit received: direction toward the attacker (world) and seconds since then.
var _last_attacker_dir: Vector3 = Vector3.ZERO
var _last_reaction_age: float = 99.0
## Source of a remote's action byte: returns the byte of the drawn record. If it is not valid, the
## action comes from the character's [member PlayerCharacter.combat].
var _remote_source: Callable = Callable()
## Active weapon of a remote (returns its id); if it is not valid, the one from the character's state.
var _remote_weapon_source: Callable = Callable()
var _shown_weapon: int = -1
# Last value notified through [signal swing_active_changed].
var _swing_shown: bool = false
# Last action of a remote notified through [signal remote_action_started] and its step (-1 = none).
var _remote_action_seen: int = -1
var _remote_step_seen: int = -1
# Heavy-attack charge: whether it is being notified and the seconds a remote has been charging.
var _charging: bool = false
var _remote_charge_s: float = 0.0


func _ready() -> void:
	# Before the AnimationTree (priority 0), so that this frame's parameters are
	# applied in this same frame and not the next one.
	process_priority = -1
	if animation_tree == null:
		animation_tree = get_node_or_null(^"../AnimationTree") as AnimationTree
	if pivot == null:
		pivot = get_node_or_null(^"../Pivot") as Node3D
	_cache_locomotion_strides()
	if _character == null:
		set_character(_find_character())


## The character being decorated. It can be changed at any time (or pass null to release it).
func set_character(character: PlayerCharacter) -> void:
	if _character == character:
		return
	if is_instance_valid(_character):
		if _character.jumped.is_connected(_on_jumped):
			_character.jumped.disconnect(_on_jumped)
	_character = character
	_yaw_initialized = false
	_air_state = AirState.GROUNDED
	_air_weight = 0.0
	_fall_weight = 0.0
	_land_weight = 0.0
	_land_time = -1.0
	if is_instance_valid(_character):
		_character.jumped.connect(_on_jumped)


## The decorated character (or null).
func get_character() -> PlayerCharacter:
	return _character


## Places the model instantly facing the way the simulation does, with no smooth turn. For after a
## teleport or a respawn (together with [method Node.reset_physics_interpolation]).
func reset_facing() -> void:
	_yaw_initialized = false
	_backpedal = false
	_dodging = false
	_twist_weight = 1.0
	_attack_facing = false
	_body_offset = Vector3.ZERO
	_slide_velocity = Vector3.ZERO
	_was_dead = false
	_death_yaw = NAN
	if pivot != null:
		pivot.rotation = Vector3.ZERO
		pivot.position = Vector3.ZERO
	if _spine != null:
		_spine.twist = 0.0


## Modifier that twists the spine ([HumanoidVisual] creates it under its skeleton).
func set_spine_modifier(modifier: SpineTwistModifier) -> void:
	_spine = modifier


## Modifier that applies the combat pose to the skeleton ([HumanoidVisual] creates it under the
## skeleton, before the spine one). It creates the combat layer with [member clip_set].
func set_combat_modifier(modifier: CombatPoseModifier) -> void:
	_combat_modifier = modifier
	if _combat_layer == null:
		_combat_layer = CombatAnimationLayer.new(clip_set)
	if _combat_modifier != null:
		_combat_modifier.layer = _combat_layer


## Combat stance modifier ([HumanoidVisual] creates it; it goes before the combat one).
func set_stance_modifier(modifier: ArmedStanceModifier) -> void:
	_stance = modifier
	if _stance != null:
		_stance.clips = clip_set
		_apply_stance_profile()


## Modifier for the procedural reactions ([HumanoidVisual] creates it).
func set_reaction_modifier(modifier: HitReactionModifier) -> void:
	_reaction = modifier


## Changes the combat stance profile: [code]shield[/code] (shield guard) or [code]zombie[/code] (the Hollow).
func set_stance_profile(profile: StringName) -> void:
	_stance_profile = profile
	_apply_stance_profile()


## The combat stance modifier (or null).
func get_stance_modifier() -> ArmedStanceModifier:
	return _stance


## The reactions modifier (or null).
func get_reaction_modifier() -> HitReactionModifier:
	return _reaction


## Weight with which the combat rest is blended with the locomotion (1 standing still, 0 moving).
func get_move_weight() -> float:
	return _move_weight


## The character receives a hit of [param amount] damage from [param attacker_direction] (a vector in the world from the
## victim toward the attacker; zero if unknown). With [param blocked], the shield has stopped it: a push of the arm and
## the spine instead of throwing the body back (ART-48, ART-50).
func react_to_hit(attacker_direction: Vector3, amount: float = 0.0, blocked: bool = false) -> void:
	_last_reaction_age = 0.0
	if attacker_direction.length_squared() > 0.0001:
		_last_attacker_dir = Vector3(attacker_direction.x, 0.0, attacker_direction.z).normalized()
	if _reaction == null:
		return
	if blocked:
		_reaction.trigger_block(attacker_direction)
	else:
		_reaction.trigger_hit(attacker_direction, amount)


## Makes the combat action come from the [code]action[/code] byte that [param source] returns
## (a remote's drawn record) instead of the character's state, and the active weapon from
## [param weapon_source] (the id its view reports). An invalid [Callable] goes back to the character's state.
func set_remote_source(source: Callable, weapon_source: Callable = Callable()) -> void:
	_remote_source = source
	_remote_weapon_source = weapon_source
	if _combat_layer != null:
		_combat_layer.reset()
	_set_swing_shown(false)


## Weapon currently shown in the hands (-1 before the first frame).
func get_shown_weapon() -> int:
	return _shown_weapon


## Combat animation layer (null until [method set_combat_modifier]).
func get_combat_layer() -> CombatAnimationLayer:
	return _combat_layer


## Modifier that applies the combat pose (or null).
func get_combat_modifier() -> CombatPoseModifier:
	return _combat_modifier


## Internal state for debugging and visual tests.
func get_debug_state() -> Dictionary:
	return {
		"speed": _speed,
		"locomotion_scale": _locomotion_scale,
		"move": _move_weight,
		"air_state": AirState.keys()[_air_state],
		"air": _air_weight,
		"fall": _fall_weight,
		"land": _land_weight,
		"facing_offset_deg": rad_to_deg(pivot.rotation.y) if pivot != null else 0.0,
		"backpedal": _backpedal,
		"dodging": _dodging,
		"spine_twist_deg": rad_to_deg(_spine.twist) if _spine != null else 0.0,
		"combat": _combat_debug(),
		"move_request": _combat_layer.move_request if _combat_layer != null else 0.0,
		"stance_rest": _stance.rest_weight if _stance != null else 0.0,
		"stance_arms": _stance.arm_weight if _stance != null else 0.0,
		"stance_master": _stance.master_weight if _stance != null else 0.0,
		"body_offset": _body_offset,
		"attack_facing": _attack_facing,
	}


func _process(delta: float) -> void:
	if not is_instance_valid(_character) or animation_tree == null or pivot == null:
		return
	var velocity: Vector3 = _character.velocity
	var horizontal := Vector3(velocity.x, 0.0, velocity.z)
	var real_speed: float = horizontal.length()
	_speed = lerpf(_speed, real_speed, 1.0 - exp(-speed_smoothing * delta))

	_update_air(delta, velocity.y)
	_update_facing(delta, horizontal, real_speed)
	_update_locomotion()

	animation_tree.set(PARAM_AIR, _air_weight)
	animation_tree.set(PARAM_AIR_PHASE, _fall_weight)
	animation_tree.set(PARAM_LAND, _land_weight)

	_update_combat(delta)
	_update_body_offset(delta, horizontal)
	_update_stance(delta)


# --- Combat ------------------------------------------------------------------------------------

# Feeds the combat layer with this frame's action.
func _update_combat(delta: float) -> void:
	var weapon_id: int = _character.combat.weapon_id
	if _remote_source.is_valid() and _remote_weapon_source.is_valid():
		weapon_id = int(_remote_weapon_source.call())
	if _current_action() == CombatState.Action.SWAP:
		_swap_elapsed += delta
	else:
		_swap_elapsed = 0.0
	# In the middle of a weapon swap the props wait for the middle of the gesture; if the action ends earlier (or there is no
	# weapon swap, but new equipment), they change right away.
	var swapping_in_place: bool = _shown_weapon >= 0 and _swap_elapsed > 0.0 \
			and _swap_elapsed < _swap_show_seconds()
	if weapon_id != _shown_weapon and not swapping_in_place:
		_shown_weapon = weapon_id
		weapon_shown.emit(weapon_id)
	if _combat_layer == null:
		return
	var moving: bool = _character.get_horizontal_speed() > CRAWL_MIN_SPEED
	_combat_layer.move_request = _move_request()
	_combat_layer.crawl_speed = _character.get_horizontal_speed()
	if _remote_source.is_valid():
		_combat_layer.update_remote(int(_remote_source.call()), delta, weapon_id, moving)
	else:
		_combat_layer.update_local(_character.combat, _character.last_input_tick,
				Engine.get_physics_interpolation_fraction(), delta, moving)
	_set_swing_shown(_combat_layer.is_swing_active())
	_update_charge(delta, weapon_id)
	_observe_remote_action()


# Notifies the heavy-attack charge ([signal charge_changed]): the fraction comes from the state for the local player and from the
# time a remote is seen charging.
func _update_charge(delta: float, weapon_id: int) -> void:
	var charging: bool = _current_action() == CombatState.Action.CHARGE
	if not charging:
		_remote_charge_s = 0.0
		if _charging:
			_charging = false
			charge_changed.emit(false, 0.0)
		return
	var weapon: WeaponTicks = CombatCatalog.weapon(weapon_id)
	var heavy: AttackTicks = CombatCatalog.attack(weapon.heavy_id) if weapon != null else null
	var full_ticks: float = float(maxi(heavy.charge_max_ticks, 1)) if heavy != null else 72.0
	var elapsed_ticks: float = 0.0
	if _remote_source.is_valid():
		_remote_charge_s += delta
		elapsed_ticks = _remote_charge_s * float(Engine.physics_ticks_per_second)
	else:
		elapsed_ticks = float(_character.last_input_tick - _character.combat.action_tick) \
				+ Engine.get_physics_interpolation_fraction()
	_charging = true
	charge_changed.emit(true, clampf(elapsed_ticks / full_ticks, 0.0, 1.0))


# Notifies the new actions of a remote ([signal remote_action_started]).
func _observe_remote_action() -> void:
	if not _remote_source.is_valid():
		return
	var byte: int = int(_remote_source.call())
	var action: int = byte & 15
	var step: int = ActionWire.step_of(byte)
	if action == CombatState.Action.NONE or action > CombatState.Action.EXECUTE:
		_remote_action_seen = -1
		_remote_step_seen = -1
		return
	if action != _remote_action_seen or step != _remote_step_seen:
		_remote_action_seen = action
		_remote_step_seen = step
		remote_action_started.emit(action, step)


## true if this animator is driven by a remote (the action comes from the byte of its record).
func is_remote() -> bool:
	return _remote_source.is_valid()


# How much movement the input asks for (0 to 1) for the legs of an attack: the horizontal speed minus what the lunge of
# the current attack advances, between [constant MOVE_REQUEST_FROM] and [constant MOVE_REQUEST_TO] of the run.
func _move_request() -> float:
	var speed: float = _character.get_horizontal_speed() - _current_lunge_speed()
	var ratio: float = maxf(speed, 0.0) / maxf(_character.run_speed, 0.001)
	return smoothstep(MOVE_REQUEST_FROM, MOVE_REQUEST_TO, ratio)


# Advance (m/s) that the simulation currently adds for the lunge of the current attack (until the end of the active hit).
func _current_lunge_speed() -> float:
	if _combat_layer == null:
		return 0.0
	var plan: CombatClipPlanner.Plan = _combat_layer.get_plan()
	if plan == null or plan.phase == ActionMachine.PHASE_NONE or plan.phase == ActionMachine.PHASE_RECOVERY:
		return 0.0
	var attack: AttackTicks = CombatCatalog.attack(CombatCatalog.attack_id(plan.key))
	return attack.lunge_speed if attack != null else 0.0


# true if this frame's action is an attack of the kind that plants toward the camera.
func _is_attack_action(action: int) -> bool:
	return action == CombatState.Action.LIGHT or action == CombatState.Action.HEAVY \
			or action == CombatState.Action.CHARGE or action == CombatState.Action.ABILITY


# Notifies through [signal swing_active_changed] only when the state changes.
func _set_swing_shown(swinging: bool) -> void:
	if swinging != _swing_shown:
		_swing_shown = swinging
		swing_active_changed.emit(swinging)


## Combat action of this frame (a [enum CombatState.Action]): the one from the drawn record's byte for a remote
## or the one from the character's state.
func get_current_action() -> int:
	return _current_action()


# Combat action of this frame: the one from the drawn record's byte for a remote or the one from the
# character's state.
func _current_action() -> int:
	if _remote_source.is_valid():
		return int(_remote_source.call()) & 15
	return _character.combat.action


# Seconds from the start of the weapon swap at which the props change.
func _swap_show_seconds() -> float:
	return float(CombatCatalog.tables().swap_ticks) / float(Engine.physics_ticks_per_second) * swap_show_fraction


func _combat_debug() -> Dictionary:
	if _combat_layer == null:
		return {}
	var current: CombatAnimationLayer.Slot = _combat_layer.get_current()
	if current == null:
		return {"active": false}
	return {
		"active": true,
		"key": current.key,
		"animation": current.animation_name,
		"time": current.time_s,
		"speed": current.speed,
		"weight": current.weight,
		"upper_body": current.upper_body,
	}


# --- Locomotion --------------------------------------------------------------------------------

## Reads the points of the locomotion BlendSpace and computes, for each one, how many meters the
## clip advances per TimeScale unit (stride / duration of its cycle in the tree).
func _cache_locomotion_strides() -> void:
	_stride_points.clear()
	if animation_tree == null:
		return
	var root: AnimationNodeBlendTree = animation_tree.tree_root as AnimationNodeBlendTree
	if root == null or not root.has_node(LOCOMOTION_NODE):
		push_error("[CharacterAnimator] El árbol no tiene el nodo '%s'" % LOCOMOTION_NODE)
		return
	_blend_space = root.get_node(LOCOMOTION_NODE) as AnimationNodeBlendSpace1D
	if _blend_space == null:
		push_error("[CharacterAnimator] '%s' no es un BlendSpace1D" % LOCOMOTION_NODE)
		return
	for i: int in _blend_space.get_blend_point_count():
		var node: AnimationNodeAnimation = _blend_space.get_blend_point_node(i) as AnimationNodeAnimation
		if node == null:
			continue
		var animation: Animation = animation_tree.get_animation(node.animation)
		if animation == null or not clip_ground_speeds.has(node.animation):
			push_warning("[CharacterAnimator] Sin velocidad sobre el suelo para '%s'" % node.animation)
			continue
		var stride: float = clip_ground_speeds[node.animation] * animation.length
		var cycle: float = animation.length
		if node.use_custom_timeline and node.stretch_time_scale:
			cycle = node.timeline_length
		_stride_points.append(Vector2(_blend_space.get_blend_point_position(i), stride / cycle))
	_stride_points.sort_custom(func(a: Vector2, b: Vector2) -> bool: return a.x < b.x)


func _update_locomotion() -> void:
	var blend: float = _speed
	if _blend_space != null:
		blend = clampf(_speed, _blend_space.min_space, _blend_space.max_space)
	var meters_per_unit: float = _stride_at(blend)
	_locomotion_scale = 0.0
	if meters_per_unit > 0.0:
		_locomotion_scale = clampf(_speed / meters_per_unit, 0.0, max_locomotion_scale)
	# Backpedal: the same cycle in reverse (the stride is the same in both directions).
	if _backpedal:
		_locomotion_scale = -_locomotion_scale
	_move_weight = clampf(_speed / maxf(idle_blend_speed, 0.001), 0.0, 1.0)
	_move_weight = _move_weight * _move_weight * (3.0 - 2.0 * _move_weight)
	animation_tree.set(PARAM_LOCOMOTION_BLEND, blend)
	animation_tree.set(PARAM_LOCOMOTION_SCALE, _locomotion_scale)
	animation_tree.set(PARAM_MOVE, _move_weight)


## Meters per TimeScale unit at position [param blend], interpolating linearly between the
## BlendSpace points just as the BlendSpace1D itself does.
func _stride_at(blend: float) -> float:
	if _stride_points.is_empty():
		return 0.0
	if blend <= _stride_points[0].x:
		return _stride_points[0].y
	for i: int in range(1, _stride_points.size()):
		var a: Vector2 = _stride_points[i - 1]
		var b: Vector2 = _stride_points[i]
		if blend <= b.x:
			var t: float = (blend - a.x) / maxf(b.x - a.x, 0.0001)
			return lerpf(a.y, b.y, t)
	return _stride_points[_stride_points.size() - 1].y


# --- Orientation -------------------------------------------------------------------------------

func _update_facing(delta: float, horizontal: Vector3, real_speed: float) -> void:
	var parent: Node3D = pivot.get_parent() as Node3D
	if parent == null:
		return
	var base_yaw: float = _yaw_of(parent.get_global_transform_interpolated().basis)
	if not _yaw_initialized:
		_visual_yaw = base_yaw
		_yaw_initialized = true
	# Dodge: the model faces the direction of travel from the first frame, with no smooth turn or spine
	# compensation (ART-49).
	if _current_action() == CombatState.Action.DODGE:
		var dodge_yaw: float = _dodge_heading(horizontal, real_speed)
		if not _dodging:
			_dodging = true
			_backpedal = false
			_twist_weight = 0.0
		if not is_nan(dodge_yaw):
			# The entry turn is spread over about 0.08 s (it used to be a jump of up to 180 degrees in one frame).
			var dodge_diff: float = angle_difference(_visual_yaw, dodge_yaw)
			var dodge_step: float = dodge_diff * (1.0 - exp(-DODGE_TURN_SHARPNESS * delta))
			var dodge_max: float = PI / DODGE_TURN_TIME * delta
			_visual_yaw = wrapf(_visual_yaw + clampf(dodge_step, -dodge_max, dodge_max), -PI, PI)
		pivot.rotation = Vector3(0.0, angle_difference(base_yaw, _visual_yaw), 0.0)
		if _spine != null:
			_spine.twist = 0.0
		return
	_dodging = false
	_twist_weight = move_toward(_twist_weight, 1.0, delta / maxf(dodge_twist_return_time, 0.001))
	var action: int = _current_action()
	# Death: the model turns toward the attacker to fall away from them (ART-51).
	if action == CombatState.Action.DEAD and not is_nan(_death_yaw):
		var death_diff: float = angle_difference(_visual_yaw, _death_yaw)
		_visual_yaw = wrapf(_visual_yaw + death_diff * (1.0 - exp(-DEATH_FACE_SHARPNESS * delta)), -PI, PI)
		pivot.rotation = Vector3(0.0, angle_difference(base_yaw, _visual_yaw), 0.0)
		if _spine != null:
			_spine.twist = 0.0
		return
	# Attack without asking to walk: the model faces where the camera does, instantly at the start, and the spine compensates
	# nothing (ART-46): the clip's hips and feet turn toward the aim point.
	var planted: bool = _is_attack_action(action) \
			and (_combat_layer == null or _combat_layer.move_request < 0.5)
	if planted:
		if not _attack_facing:
			_attack_facing = true
			_visual_yaw = base_yaw
		_backpedal = false
		_visual_yaw = wrapf(_visual_yaw + angle_difference(_visual_yaw, base_yaw)
				* (1.0 - exp(-turn_sharpness * 2.0 * delta)), -PI, PI)
		pivot.rotation = Vector3(0.0, angle_difference(base_yaw, _visual_yaw), 0.0)
		if _spine != null:
			_spine.twist = -clampf(pivot.rotation.y, -deg_to_rad(max_spine_twist), deg_to_rad(max_spine_twist)) \
					* _twist_weight
		return
	_attack_facing = false
	var target_yaw: float = base_yaw
	if real_speed > turn_min_speed:
		var move_yaw: float = atan2(-horizontal.x, -horizontal.z)
		var relative: float = absf(rad_to_deg(angle_difference(base_yaw, move_yaw)))
		if _backpedal and relative < backpedal_exit_angle:
			_backpedal = false
		elif not _backpedal and relative > backpedal_enter_angle:
			_backpedal = true
		target_yaw = wrapf(move_yaw + PI, -PI, PI) if _backpedal else move_yaw
	elif real_speed < turn_min_speed * 0.5:
		_backpedal = false
	var diff: float = angle_difference(_visual_yaw, target_yaw)
	var step: float = diff * (1.0 - exp(-turn_sharpness * delta))
	var max_step: float = max_turn_speed * delta
	_visual_yaw = wrapf(_visual_yaw + clampf(step, -max_step, max_step), -PI, PI)
	var offset: float = angle_difference(base_yaw, _visual_yaw)
	pivot.rotation = Vector3(0.0, offset, 0.0)
	# The spine returns the chest and head toward the aim point.
	if _spine != null:
		var limit: float = deg_to_rad(max_spine_twist)
		_spine.twist = -clampf(offset, -limit, limit) * _twist_weight


# Heading (yaw) of the current dodge: the one from the character's state if it is the local one (the simulation sets it
# at the start) or the one from its velocity if it is a remote; NAN if it is not yet known.
func _dodge_heading(horizontal: Vector3, real_speed: float) -> float:
	if not _remote_source.is_valid():
		return CombatState.dequantize_yaw(_character.combat.action_dir)
	if real_speed > dodge_min_speed:
		return atan2(-horizontal.x, -horizontal.z)
	return NAN


## Yaw (convention of [member Node3D.rotation].y: 0 faces -Z) of a basis.
static func _yaw_of(basis: Basis) -> float:
	return atan2(basis.z.x, basis.z.z)


# --- Combat stance and body --------------------------------------------------------------------

# Sets the clips of the requested profile on the stance modifier.
func _apply_stance_profile() -> void:
	if _stance == null:
		return
	if _stance_profile == &"zombie":
		_stance.use_zombie_profile()
	else:
		_stance.use_shield_profile()


# Sets the weights and times of this frame's combat stance (ART-45).
func _update_stance(delta: float) -> void:
	if _stance == null:
		return
	var weapon: WeaponTicks = CombatCatalog.weapon(_shown_weapon)
	var bow: bool = weapon != null and weapon.name == WeaponProps.BOW_WEAPON
	if _stance.clips == null:
		_stance.clips = clip_set
	_stance.enabled = not bow
	var full_body: float = _combat_layer.get_full_body_weight() if _combat_layer != null else 0.0
	_stance.master_weight = (1.0 - _air_weight) * (1.0 - full_body)
	_stance.rest_weight = 1.0 - _move_weight
	var sprint_ratio: float = clampf(inverse_lerp(_character.run_speed, _character.sprint_speed, _speed), 0.0, 1.0)
	_stance.arm_weight = lerpf(STANCE_ARM_WEIGHT_WALK, STANCE_ARM_WEIGHT_SPRINT, sprint_ratio)
	_stance.left_arm_reserved = _combat_layer.get_left_arm_reserved() if _combat_layer != null else 0.0
	_stance.grip_weight = 1.0
	_stance.grip_time = 0.0
	var rest: Animation = null
	if clip_set != null and _stance.rest_clip != &"":
		rest = clip_set.get_animation(_stance.rest_clip)
	if rest != null and rest.length > 0.0:
		_stance_rest_time = fposmod(_stance_rest_time + delta, rest.length)
	_stance.rest_time = _stance_rest_time
	if _stance.walk_clip != &"":
		var walk: Animation = clip_set.get_animation(_stance.walk_clip) if clip_set != null else null
		var rate: float = clampf(_speed / ZOMBIE_WALK_SPEED, 0.5, 2.2)
		if walk != null and walk.length > 0.0:
			_stance_walk_time = fposmod(_stance_walk_time + delta * rate, walk.length)
		_stance.walk_time = _stance_walk_time
		var shamble: float = 1.0 - smoothstep(ZOMBIE_RUN_FROM, ZOMBIE_RUN_TO, _speed)
		_stance.walk_weight = _move_weight * shamble
		# The sword arm only comes in when running: while walking, the zombie arm rules.
		_stance.arm_weight *= 1.0 - _stance.walk_weight
	else:
		_stance.walk_weight = 0.0
	if _reaction != null:
		_reaction.guard_raise = _guard_raise()
	_last_reaction_age += delta


# How far the shield is raised (0 to 1): while the block or the shield wall lasts.
func _guard_raise() -> float:
	if _combat_layer == null:
		return 0.0
	var raise: float = 0.0
	for slot: CombatAnimationLayer.Slot in _combat_layer.get_slots():
		if slot.key == CombatClipPlanner.KEY_BLOCK or slot.key == &"shield_wall":
			raise = maxf(raise, slot.weight)
	return raise


# Visual offset of the Pivot: the stagger step back and the death slide (ART-50, ART-51).
func _update_body_offset(delta: float, horizontal: Vector3) -> void:
	var parent: Node3D = pivot.get_parent() as Node3D
	if parent == null:
		return
	var to_local: Basis = parent.global_transform.basis.orthonormalized().inverse()
	var action: int = _current_action()
	if action == CombatState.Action.DEAD:
		if not _was_dead:
			_was_dead = true
			_slide_velocity = _live_velocity * DEATH_SLIDE_FACTOR
			if _slide_velocity.length() > DEATH_SLIDE_MAX_SPEED:
				_slide_velocity = _slide_velocity.normalized() * DEATH_SLIDE_MAX_SPEED
			if _last_reaction_age < LAST_HIT_MEMORY and _last_attacker_dir != Vector3.ZERO:
				_death_yaw = atan2(-_last_attacker_dir.x, -_last_attacker_dir.z)
			else:
				_death_yaw = NAN
		_slide_velocity *= exp(-delta / DEATH_SLIDE_TAU)
		_body_offset += to_local * _slide_velocity * delta
		pivot.position = _body_offset
		return
	if _was_dead:
		# Leaves the death state (respawn): the body goes back to the capsule and the heading at once, without sliding to it.
		reset_facing()
	_was_dead = false
	_death_yaw = NAN
	_slide_velocity = Vector3.ZERO
	_live_velocity = _live_velocity.lerp(horizontal, 1.0 - exp(-6.0 * delta))
	var staggered: bool = action == CombatState.Action.STAGGER
	if staggered and not _was_staggered and _last_reaction_age > 0.15:
		# A stagger without a notified hit (the sandbox, a test): it falls back as if the hit came from the front.
		react_to_hit(-parent.global_transform.basis.z, 60.0)
	_was_staggered = staggered
	var target := Vector3.ZERO
	var rate: float = STAGGER_RETURN_RATE
	if staggered:
		var away: Vector3 = parent.global_transform.basis.z
		if _last_attacker_dir != Vector3.ZERO and _last_reaction_age < LAST_HIT_MEMORY:
			away = -_last_attacker_dir
		target = to_local * away.normalized() * STAGGER_STEP_BACK
		rate = STAGGER_STEP_RATE
	_body_offset = _body_offset.move_toward(target, STAGGER_STEP_BACK * rate * delta * 2.0)
	pivot.position = _body_offset


# --- Air ---------------------------------------------------------------------------------------

func _on_jumped() -> void:
	_jump_pending = true


func _update_air(delta: float, vertical_velocity: float) -> void:
	var airborne: bool = not _character.grounded
	if airborne:
		_air_time += delta
		_min_vertical_velocity = minf(_min_vertical_velocity, vertical_velocity)
		var jump_started: bool = _jump_pending and vertical_velocity > 0.0
		if not jump_started and _air_state == AirState.GROUNDED and _air_time <= delta * 1.5:
			jump_started = vertical_velocity > jump_detect_velocity
		if jump_started:
			_start_jump()
		elif _air_state == AirState.GROUNDED and _air_time >= fall_grace_time:
			_start_fall()
		if _air_state == AirState.JUMPING and vertical_velocity < fall_blend_velocity:
			_air_state = AirState.FALLING
	elif _air_state != AirState.GROUNDED:
		_land()
	if not airborne:
		_air_time = 0.0
		_min_vertical_velocity = 0.0
	_jump_pending = false

	var air_target: float = 0.0 if _air_state == AirState.GROUNDED else 1.0
	var air_rate: float = 1.0 / maxf(air_blend_in_time if air_target > _air_weight else air_blend_out_time, 0.001)
	_air_weight = move_toward(_air_weight, air_target, air_rate * delta)
	if _air_state == AirState.FALLING:
		_fall_weight = move_toward(_fall_weight, 1.0, delta / maxf(fall_blend_time, 0.001))

	if _land_time >= 0.0:
		_land_time += delta
		var fade_in: float = clampf(_land_time / 0.04, 0.0, 1.0)
		var fade_out: float = 1.0 - smoothstep(land_hold_time, land_duration, _land_time)
		_land_weight = _land_strength * fade_in * fade_out
		if _land_time >= land_duration:
			_land_time = -1.0
			_land_weight = 0.0


func _start_jump() -> void:
	jumped_visual.emit()
	_air_state = AirState.JUMPING
	_air_time = 0.0
	_min_vertical_velocity = 0.0
	_fall_weight = 0.0
	_land_time = -1.0
	_land_weight = 0.0
	animation_tree.set(PARAM_JUMP_SEEK, jump_takeoff_time)


func _start_fall() -> void:
	_air_state = AirState.FALLING
	if _air_weight <= 0.0:
		_fall_weight = 1.0


func _land() -> void:
	var impact: float = -_min_vertical_velocity
	_air_state = AirState.GROUNDED
	var impact_factor: float = clampf(inverse_lerp(land_min_impact, land_full_impact, impact), 0.0, 1.0)
	var run_factor: float = clampf(_speed / maxf(_character.run_speed, 0.001), 0.0, 1.0)
	_land_strength = lerpf(land_strength_idle, land_strength_moving, run_factor) * impact_factor
	if impact > 0.5:
		touched_down.emit(clampf(maxf(impact_factor, 0.15), 0.0, 1.0))
	if _land_strength > 0.01:
		_land_time = 0.0
		animation_tree.set(PARAM_LAND_SEEK, 0.0)
		animation_tree.set(PARAM_LAND_SCALE, land_playback_speed)


func _find_character() -> PlayerCharacter:
	var node: Node = get_parent()
	while node != null:
		if node is PlayerCharacter:
			return node as PlayerCharacter
		node = node.get_parent()
	return null
