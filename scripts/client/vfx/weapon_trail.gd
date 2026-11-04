class_name WeaponTrail
extends MeshInstance3D
## Weapon trail (ART-09, client only): a gradient ribbon that follows the arc of the edge.
## [br][br]
## Each frame it is active, it takes two points of [member target] (the base and the tip of the blade,
## [member base_offset] and [member tip_offset] in the target's local space) and stores them with their
## instant. The ribbon is the triangle strip joining those samples, smoothed with a Catmull-Rom curve and
## painted by [code]vfx_trail.gdshader[/code]. When the blow ends, [method end] stops adding samples and the
## ribbon fades out on its own; it leaves nothing on screen and spends no time when inactive.
## [br][br]
## [b]When it is drawn.[/b] Whoever drives it starts and stops it with the blow's active window
## ([signal CombatFeedback.swing_active_changed], or the animation's marker): [method begin] when it opens
## and [method end] when it closes, so it does not appear during anticipation or recovery. With
## [member min_speed] > 0, samples are also only stored while the tip moves at that speed or more (it trims
## the slow stretch at the window's edges, which does not match the sweep shown by the animation to the
## millimeter).
## [br][br]
## [b]Shape.[/b] It is not drawn with fewer than [member min_samples] samples (with two, the ribbon is a
## straight quadrilateral). The tail narrows and fades by sample number in addition to age, so it ends in
## a point and not a broom; movement along the blade's own axis (a thrust) leaves almost no ribbon; the
## arc that is drawn does not exceed [member max_length] and a tip jump of more than [member max_jump] in
## one frame (a pose change) cuts the ribbon instead of stretching a cable.
## [br][br]
## [b]Synchronization.[/b] Samples are taken right when the skeleton has just updated the pose
## ([signal Skeleton3D.skeleton_updated]), with the character's interpolated transform, and the ribbon is
## rebuilt at that same instant: this way it sticks to the blade seen in this frame, not the previous one.
## Without a skeleton (a loose node, the tests) it is taken in [method Node._process].
## [br][br]
## The colors come from the realm ([method set_realm], [VfxPalette]) or from [method set_colors]; they are
## instance parameters, so all trails share the same material. Reusable: it can be launched again with
## [method begin] without creating anything. With the placeholder sword ([WeaponProps]) the blade extends
## along +X from the hand: the base is at 0.15 m and the tip at 0.9 m.

## Radians of blade rotation covered by each interpolated segment of the ribbon, and segments at most per sample.
const MAX_STEP_ANGLE: float = 0.1
const MAX_STEPS: int = 14

## Seconds the ribbon lasts (how long a sample takes to disappear).
@export var max_age: float = 0.12
## Maximum samples stored.
@export_range(4, 64) var max_samples: int = 24
## Points interpolated between two samples.
@export_range(1, 8) var subdivisions: int = 4
## Point of the blade closest to the hand, in the target's local space.
@export var base_offset: Vector3 = Vector3(0.15, 0.0, 0.0)
## Tip of the blade, in the target's local space.
@export var tip_offset: Vector3 = Vector3(0.9, 0.0, 0.0)
## Realm that decides the colors (see [VfxPalette]).
@export var realm: int = 0:
	set = set_realm
## How far the blade must move (m) between two samples for another to be stored.
@export var min_step: float = 0.004
## Minimum tip speed (m/s) to leave a ribbon; 0 = no limit (see the class description).
@export var min_speed: float = 0.0
## If more than this (s) passes without samples, the next ribbon is another slash: the previous one is
## discarded instead of joining them with a bridge.
@export var break_gap: float = 0.07
## Samples needed to draw the ribbon (with fewer it would be a quadrilateral with straight edges).
@export_range(2, 8) var min_samples: int = 3
## Maximum length (m) of the tip arc that is drawn.
@export var max_length: float = 2.4
## How far the tip may jump (m) between two consecutive samples without cutting the ribbon.
@export var max_jump: float = 2.0

var _target: Node3D = null
var _skeleton: Skeleton3D = null
var _active: bool = false
var _clock: float = 0.0
var _bases: PackedVector3Array = PackedVector3Array()
var _tips: PackedVector3Array = PackedVector3Array()
var _times: PackedFloat32Array = PackedFloat32Array()
var _lateral: PackedFloat32Array = PackedFloat32Array()
var _immediate: ImmediateMesh = ImmediateMesh.new()
var _core: Color = Color.WHITE
var _edge: Color = Color(0.62, 0.7, 0.82)
var _last_tip: Vector3 = Vector3.ZERO
var _last_tip_clock: float = 0.0
var _has_last_tip: bool = false
var _speed: float = 0.0
var _built_frame: int = -1


func _ready() -> void:
	# The ribbon is drawn in world coordinates: it does not inherit the movement of whatever holds it.
	top_level = true
	global_transform = Transform3D.IDENTITY
	mesh = _immediate
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# After this frame's animated pose (the hand bone is already in place).
	process_priority = 1000
	set_realm(realm)
	visible = false
	set_process(false)


func _exit_tree() -> void:
	_disconnect_skeleton()


## Starts following [param target] (the sword node). If the trail is already active, it only changes target.
func begin(target: Node3D) -> void:
	_target = target
	_connect_skeleton(_find_skeleton(target))
	if not _active:
		_has_last_tip = false
	_active = true
	visible = true
	set_process(true)


## Stops adding samples: the existing ribbon fades out on its own.
func end() -> void:
	_active = false


## Turns the trail off at once, without waiting for it to fade.
func clear() -> void:
	_active = false
	_has_last_tip = false
	_clear_samples()
	_immediate.clear_surfaces()
	visible = false
	set_process(false)


## True while it follows the weapon or has ribbon left to fade out.
func is_active() -> bool:
	return _active or not _times.is_empty()


## Colors by realm (see [VfxPalette]).
func set_realm(value: int) -> void:
	realm = value
	var colors: Array[Color] = VfxPalette.trail(value)
	set_colors(colors[0], colors[1])


## Sets the two colors by hand: [param core] hot at the edge and [param edge] on the body.
func set_colors(core: Color, edge: Color) -> void:
	_core = core
	_edge = edge
	set_instance_shader_parameter(&"core_color", core)
	set_instance_shader_parameter(&"edge_color", edge)


func _process(delta: float) -> void:
	_clock += delta
	# With a skeleton, the samples are taken by the pose update signal (see _on_skeleton_updated); here the
	# ribbon is only aged when that signal has not arrived this frame.
	if _skeleton == null and _active and is_instance_valid(_target):
		_push_sample()
	if _built_frame == Engine.get_process_frames() and _skeleton != null:
		return
	_trim()
	_rebuild_or_idle()


func _on_skeleton_updated() -> void:
	if not _active or not is_instance_valid(_target):
		return
	_push_sample()
	_trim()
	_rebuild_or_idle()
	_built_frame = Engine.get_process_frames()


func _rebuild_or_idle() -> void:
	if _times.size() < min_samples:
		_immediate.clear_surfaces()
		if not _active and _times.is_empty():
			visible = false
			set_process(false)
		return
	_rebuild()


func _push_sample() -> void:
	var xform: Transform3D = _target_transform()
	var base: Vector3 = xform * base_offset
	var tip: Vector3 = xform * tip_offset
	if _has_last_tip:
		var elapsed: float = _clock - _last_tip_clock
		# Several updates in the same frame do not give a reliable speed: the previous one is kept.
		if elapsed > 1.0 / 240.0:
			_speed = tip.distance_to(_last_tip) / elapsed
			_last_tip_clock = _clock
		if tip.distance_to(_last_tip) > max_jump:
			# Pose change or teleport: it is not a slash, the ribbon is cut instead of stretching a cable.
			_clear_samples()
			_last_tip = tip
			_last_tip_clock = _clock
			return
	else:
		_speed = 0.0
		_last_tip_clock = _clock
	_last_tip = tip
	_has_last_tip = true
	if min_speed > 0.0 and _speed < min_speed:
		return
	var last: int = _times.size() - 1
	if last >= 0 and _clock - _times[last] > break_gap:
		# Another slash: it is not joined to the previous one's ribbon.
		_clear_samples()
		last = -1
	if last >= 0 and base.distance_to(_bases[last]) < min_step and tip.distance_to(_tips[last]) < min_step:
		return
	_bases.append(base)
	_tips.append(tip)
	_times.append(_clock)
	_lateral.append(_lateral_factor(base, tip, last))


# 1 if the blade sweeps sideways, 0 if it moves along its own axis (a thrust: the ribbon would be a
# quadrilateral with no real width).
func _lateral_factor(base: Vector3, tip: Vector3, last: int) -> float:
	if last < 0:
		return 1.0
	var move: Vector3 = tip - _tips[last]
	var axis: Vector3 = tip - base
	if move.length_squared() < 0.000001 or axis.length_squared() < 0.0001:
		return 1.0
	var along: float = absf(move.normalized().dot(axis.normalized()))
	return 1.0 - smoothstep(0.55, 0.95, along)


# Removes whatever has aged and trims the arc to [member max_length] from the old end.
func _trim() -> void:
	while not _times.is_empty() and (_clock - _times[0] > max_age or _times.size() > max_samples):
		_remove_oldest()
	# It is never trimmed below [member min_samples]: with the blade at 70 m/s the samples end up more than a
	# meter apart and three already exceed the cap, but with fewer not even the whole slash would be drawn.
	var total: float = 0.0
	for index: int in range(_times.size() - 1, 0, -1):
		total += _tips[index].distance_to(_tips[index - 1])
		if total > max_length:
			var removable: int = mini(index, _times.size() - min_samples)
			for _removed: int in maxi(removable, 0):
				_remove_oldest()
			return


func _remove_oldest() -> void:
	_bases.remove_at(0)
	_tips.remove_at(0)
	_times.remove_at(0)
	_lateral.remove_at(0)


func _clear_samples() -> void:
	_bases.clear()
	_tips.clear()
	_times.clear()
	_lateral.clear()


# The weapon's transform in this frame. With the skeleton bone, the freshly computed pose and the
# character's INTERPOLATED transform are read (with physics interpolation, global_transform's is that of
# the last tick, which is not the one that is seen).
func _target_transform() -> Transform3D:
	if _skeleton != null and _target is BoneAttachment3D:
		var bone: int = (_target as BoneAttachment3D).get_bone_idx()
		if bone >= 0 and bone < _skeleton.get_bone_count():
			return _skeleton.get_global_transform_interpolated() * _skeleton.get_bone_global_pose(bone)
	return _target.get_global_transform_interpolated()


func _find_skeleton(node: Node) -> Skeleton3D:
	var current: Node = node
	while current != null:
		if current is Skeleton3D:
			return current as Skeleton3D
		current = current.get_parent()
	return null


func _connect_skeleton(skeleton: Skeleton3D) -> void:
	if skeleton == _skeleton:
		return
	_disconnect_skeleton()
	_skeleton = skeleton
	if _skeleton != null:
		_skeleton.skeleton_updated.connect(_on_skeleton_updated)


func _disconnect_skeleton() -> void:
	if _skeleton != null and is_instance_valid(_skeleton) \
			and _skeleton.skeleton_updated.is_connected(_on_skeleton_updated):
		_skeleton.skeleton_updated.disconnect(_on_skeleton_updated)
	_skeleton = null


# Rebuilds the ribbon: a triangle strip with two vertices per point (base and tip), with age in UV.x,
# position across the width in UV.y and, in the color, how much body remains according to the sample
# number (red) and how lateral the movement is (green).
# The base is smoothed with a Catmull-Rom curve; the tip is NOT interpolated in a straight line between
# samples: the blade's DIRECTION is interpolated and the tip is the base plus that direction times the
# blade's length, so the tip travels an arc around the hand (what a sword does) even if the slash has only
# three or four samples, with a pose that jumps a meter from one frame to the next. The more the blade
# turns between two samples, the more points are interpolated.
func _rebuild() -> void:
	_immediate.clear_surfaces()
	var count: int = _times.size()
	var span: float = float(maxi(count - 1, 1))
	_immediate.surface_begin(Mesh.PRIMITIVE_TRIANGLE_STRIP)
	for index: int in range(count - 1, -1, -1):
		# Walking backward: from sample [index] to [index - 1].
		var p1: int = index
		var p2: int = maxi(index - 1, 0)
		var p0: int = mini(index + 1, count - 1)
		var p3: int = maxi(index - 2, 0)
		var d0: Vector3 = (_tips[p0] - _bases[p0])
		var d1: Vector3 = (_tips[p1] - _bases[p1])
		var d2: Vector3 = (_tips[p2] - _bases[p2])
		var d3: Vector3 = (_tips[p3] - _bases[p3])
		var steps: int = 1
		if index > 0:
			steps = clampi(ceili(d1.angle_to(d2) / MAX_STEP_ANGLE), subdivisions, MAX_STEPS)
		for step: int in steps:
			var t: float = float(step) / float(steps)
			var base: Vector3 = _catmull(_bases[p0], _bases[p1], _bases[p2], _bases[p3], t)
			var direction: Vector3 = _catmull(d0.normalized(), d1.normalized(), d2.normalized(),
					d3.normalized(), t)
			direction = direction.normalized() if direction.length_squared() > 0.000001 else d1.normalized()
			var tip: Vector3 = base + direction * lerpf(d1.length(), d2.length(), t)
			var time: float = lerpf(_times[p1], _times[p2], t)
			var age: float = clampf((_clock - time) / max_age, 0.0, 1.0)
			var order: float = (float(count - 1 - index) + t) / span
			var body: float = pow(clampf(1.0 - order, 0.0, 1.0), 0.9)
			var lateral: float = lerpf(_lateral[p1], _lateral[p2], t)
			_immediate.surface_set_color(Color(body, lateral, 0.0, 1.0))
			_immediate.surface_set_uv(Vector2(age, 0.0))
			_immediate.surface_add_vertex(base)
			_immediate.surface_set_color(Color(body, lateral, 0.0, 1.0))
			_immediate.surface_set_uv(Vector2(age, 1.0))
			_immediate.surface_add_vertex(tip)
	_immediate.surface_end()


static func _catmull(p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3, t: float) -> Vector3:
	var t2: float = t * t
	var t3: float = t2 * t
	return 0.5 * ((2.0 * p1) + (p2 - p0) * t + (2.0 * p0 - 5.0 * p1 + 4.0 * p2 - p3) * t2
			+ (-p0 + 3.0 * p1 - 3.0 * p2 + p3) * t3)
