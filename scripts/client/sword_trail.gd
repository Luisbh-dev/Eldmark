class_name SwordTrail
extends Node3D
## Sword strike trail (ART-09, docs/calidad.md decision 8). Client only.
## [br][br]
## It is a ribbon that is born from the blade itself: it runs from [constant INNER_FRACTION] (40 %) of the edge between the
## [code]TrailBase[/code] and [code]TrailTip[/code] marks of the model ([SwordModel]) to the tip, and does not go past
## it. Every frame of the active phase stores a sample (edge start and tip); a
## Catmull-Rom curve joins the samples and is split into segments according to the time between each pair (not according to
## frames), so at 30 fps the swing comes out curved rather than a string of straight lines. The ribbon carries a
## gradient texture ([method _gradient_texture]: u = age, v = along the blade) with the tail broken up by noise
## and a maximum alpha of [constant PEAK_ALPHA], in normal blending with the saturated realm color (additive
## over a bright sky gives white). On top, a thin hot line on the tip's edge, that one additive.
## No shadow or light.
## [br][br]
## The pose is read AFTER the skeleton applies the [CombatPoseModifier]: the trail connects to
## [signal Skeleton3D.skeleton_updated] of the skeleton it hangs from (if there is no skeleton, as in
## tests, [method _process] moves it). Sampling in [method _process] read the previous frame's pose and
## left the trail 0.3-0.5 m from the blade on a fast slash.
## [br][br]
## It does not decide when there is a strike: whoever knows activates it with [method set_active]. For the local player it is
## decided by the same check as [signal CombatFeedback.swing_active_changed]
## ([method ActionMachine.is_attack_active]) and for remotes by the active phase of the action byte
## (both unified by [CombatAnimationLayer.is_swing_active], which notifies the animator). It hangs from the sword node
## but goes its own way ([member Node3D.top_level]): the samples are in world coordinates.
## The real reach of the strike (decision 8) comes from the combat data and not from this mesh.

## Seconds each sample takes to fade out (between 0.12 and 0.15 s according to decision 8).
const FADE_SECONDS: float = 0.13
## Where the body of the ribbon starts, as a fraction of the length between TrailBase and TrailTip.
const INNER_FRACTION: float = 0.40
## Where the hot line of the tip's edge starts (fraction of the same length).
const LINE_FRACTION: float = 0.94
## Maximum segments and seconds per segment into which each jump between two samples is split.
const MAX_SUBDIVISIONS: int = 12
const SUBDIVISION_SECONDS: float = 1.0 / 240.0
## Cap on live samples (at 240 fps, 0.13 s is 32).
const MAX_SAMPLES: int = 48
## Maximum opacity of the ribbon body and of the edge line.
const PEAK_ALPHA: float = 0.5
const LINE_ALPHA: float = 0.85
## How much the realm color is lightened on the edge line (0 = same, 1 = white).
const LINE_LIGHTEN: float = 0.45
## Heavy strike: the ribbon starts earlier on the blade (wider), with more opacity, more saturated and with a touch of ember
## in the color, and the edge line is fully opaque. The heavy one came out pale (wave 4 review).
const HEAVY_INNER_FRACTION: float = 0.22
const HEAVY_PEAK_ALPHA: float = 0.86
const HEAVY_LINE_ALPHA: float = 1.0
const HEAVY_HEAT: Color = Color(1.0, 0.62, 0.22, 1.0)
const HEAVY_HEAT_MIX: float = 0.28
const HEAVY_SATURATION_BOOST: float = 0.18
## Size of the gradient texture (u = age, v = along the blade).
const TEXTURE_SIZE: Vector2i = Vector2i(128, 64)
## Color per sword variant (ids of [constant SwordModel.MODELS]), saturated: what is not visible in the
## texture (which is white with alpha) is supplied by this tint.
## The base sword carries a warm steel trail (silvery ivory), not blue: blue belongs to Vardheim and the base was
## confused with it (wave 4 review).
const DEFAULT_COLOR: Color = Color(0.88, 0.84, 0.72, 1.0)
const COLORS: Dictionary[StringName, Color] = {
	&"base": Color(0.88, 0.84, 0.72, 1.0),
	&"vardheim": Color(0.16, 0.60, 1.00, 1.0),
	&"solmarch": Color(1.00, 0.68, 0.12, 1.0),
	&"askarra": Color(1.00, 0.26, 0.04, 1.0),
}

static var _texture: ImageTexture = null

var _base: Node3D = null
var _tip: Node3D = null
var _skeleton: Skeleton3D = null
var _active: bool = false
var _heavy: bool = false
var _color: Color = DEFAULT_COLOR
var _last_update_frame: int = -100
# Samples from oldest to newest: [base: Vector3, tip: Vector3, age: float].
var _samples: Array[Array] = []
var _mesh: ImmediateMesh = ImmediateMesh.new()
var _instance: MeshInstance3D = MeshInstance3D.new()
var _body_material: StandardMaterial3D = _make_body_material()
var _line_material: StandardMaterial3D = _make_line_material()


func _init() -> void:
	name = "SwordTrail"
	top_level = true
	_instance.name = "Ribbon"
	_instance.mesh = _mesh
	_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_instance.visible = false
	# The ribbon may be far from the node's origin (which does not move): it is never culled by its box.
	_instance.extra_cull_margin = 16384.0
	add_child(_instance)
	set_process(false)


func _enter_tree() -> void:
	# The parents have already entered: the BoneAttachment3D connected before us and places the sword first.
	var node: Node = get_parent()
	while node != null and not node is Skeleton3D:
		node = node.get_parent()
	_skeleton = node as Skeleton3D
	if _skeleton != null and not _skeleton.skeleton_updated.is_connected(_on_skeleton_updated):
		_skeleton.skeleton_updated.connect(_on_skeleton_updated)


func _exit_tree() -> void:
	if _skeleton != null and is_instance_valid(_skeleton) \
			and _skeleton.skeleton_updated.is_connected(_on_skeleton_updated):
		_skeleton.skeleton_updated.disconnect(_on_skeleton_updated)
	_skeleton = null


## Trail color of sword variant [param variant] ([constant COLORS]; the base one if it does not exist).
static func color_for(variant: StringName) -> Color:
	return COLORS.get(variant, DEFAULT_COLOR)


## Looks for the [code]TrailBase[/code] and [code]TrailTip[/code] marks in the sword model [param model].
## With another model (another variant) it is called again and the samples are forgotten.
func bind(model: Node) -> void:
	_base = model.find_child(String(SwordModel.TRAIL_BASE_NAME), true, false) as Node3D
	_tip = model.find_child(String(SwordModel.TRAIL_TIP_NAME), true, false) as Node3D
	_samples.clear()
	_rebuild()


## Tints the trail with [param color] (alpha is ignored).
func set_tint(color: Color) -> void:
	_color = Color(color.r, color.g, color.b, 1.0)


## Starts or cuts the sweep; with [param heavy] it is the heavy strike's (wider, opaque and saturated). When cut, what
## remains of the ribbon fades out on its own.
func set_active(active: bool, heavy: bool = false) -> void:
	if active == _active:
		return
	_active = active
	if active:
		_heavy = heavy
	if _active:
		set_process(true)
		# With a skeleton, the first sample is that of the next already-posed frame; without one, this very one.
		if _skeleton == null:
			add_sample()


func is_active() -> bool:
	return _active


## true if the sweep in progress (or the last one) is the heavy strike's.
func is_heavy() -> bool:
	return _heavy


## Color the ribbon body is painted with now: the realm's, or with ember and more saturated if it is the heavy one.
func get_body_color() -> Color:
	if not _heavy:
		return _color
	var hot: Color = _color.lerp(HEAVY_HEAT, HEAVY_HEAT_MIX)
	return Color.from_hsv(hot.h, minf(hot.s + HEAVY_SATURATION_BOOST, 1.0), 1.0)


## Maximum opacity of the ribbon body right now.
func get_peak_alpha() -> float:
	return HEAVY_PEAK_ALPHA if _heavy else PEAK_ALPHA


## Live samples right now.
func get_sample_count() -> int:
	return _samples.size()


## Stores a sample with the current position of the marks (if the model has them) and the new ribbon.
func add_sample() -> void:
	if _push_current():
		_rebuild()


## Stores a sample with the edge start [param base] and the tip [param tip] (in world
## coordinates). Tests use it without a model.
func add_sample_points(base: Vector3, tip: Vector3) -> void:
	_push(base, tip)
	_rebuild()


## Ages the samples by [param delta] seconds and removes the faded ones. The skeleton calls it when it updates (or
## [method _process] without a skeleton); tests call it by hand.
func advance(delta: float) -> void:
	_age(delta)
	_rebuild()


func _process(delta: float) -> void:
	# With a skeleton, skeleton_updated drives; this fallback is used only if the skeleton has not updated for a while.
	if _skeleton != null and Engine.get_process_frames() - _last_update_frame <= 2:
		return
	_age(delta)
	if _active:
		_push_current()
	_rebuild()
	if not _active and _samples.is_empty():
		set_process(false)


# The skeleton has just applied all its modifiers (the combat pose one included): the sword is already
# where it will be drawn this frame.
func _on_skeleton_updated() -> void:
	if not is_inside_tree() or (not _active and _samples.is_empty()):
		return
	_last_update_frame = Engine.get_process_frames()
	_age(get_process_delta_time())
	if _active:
		_push_current()
	_rebuild()


func _age(delta: float) -> void:
	for sample: Array in _samples:
		sample[2] = float(sample[2]) + delta
	while not _samples.is_empty() and float((_samples[0] as Array)[2]) >= FADE_SECONDS:
		_samples.pop_front()


func _push_current() -> bool:
	if _base == null or _tip == null or not is_instance_valid(_base) or not is_instance_valid(_tip):
		return false
	_push(_base.global_position, _tip.global_position)
	return true


func _push(base: Vector3, tip: Vector3) -> void:
	_samples.append([base, tip, 0.0])
	while _samples.size() > MAX_SAMPLES:
		_samples.pop_front()


## The two points of sample [param index] on the blade: the start of the ribbon ([constant INNER_FRACTION])
## and the tip.
func get_ribbon_edges(index: int) -> PackedVector3Array:
	var sample: Array = _samples[index]
	return _edges(sample[0] as Vector3, sample[1] as Vector3, HEAVY_INNER_FRACTION if _heavy else INNER_FRACTION)


static func _edges(base: Vector3, tip: Vector3, inner: float = INNER_FRACTION) -> PackedVector3Array:
	var along: Vector3 = tip - base
	return PackedVector3Array([base + along * inner, tip])


# Uniform Catmull-Rom between [param p1] and [param p2] at [param t] (from 0 to 1).
static func _catmull(p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3, t: float) -> Vector3:
	var t2: float = t * t
	var t3: float = t2 * t
	return 0.5 * ((2.0 * p1) + (p2 - p0) * t + (2.0 * p0 - 5.0 * p1 + 4.0 * p2 - p3) * t2
			+ (3.0 * p1 - p0 - 3.0 * p2 + p3) * t3)


# The dense curve through the samples: [base, tip, age] every few milliseconds of sweep, with the position by
# Catmull-Rom and the age in a straight line. The number of segments of each jump comes from the time that separates it.
func _dense_samples() -> Array[Array]:
	var dense: Array[Array] = []
	var last: int = _samples.size() - 1
	for index: int in range(last):
		var s0: Array = _samples[maxi(index - 1, 0)]
		var s1: Array = _samples[index]
		var s2: Array = _samples[index + 1]
		var s3: Array = _samples[mini(index + 2, last)]
		var seconds: float = absf(float(s1[2]) - float(s2[2]))
		var steps: int = clampi(ceili(seconds / SUBDIVISION_SECONDS), 2, MAX_SUBDIVISIONS)
		for step: int in range(steps):
			var t: float = float(step) / float(steps)
			dense.append([
				_catmull(s0[0] as Vector3, s1[0] as Vector3, s2[0] as Vector3, s3[0] as Vector3, t),
				_catmull(s0[1] as Vector3, s1[1] as Vector3, s2[1] as Vector3, s3[1] as Vector3, t),
				lerpf(float(s1[2]), float(s2[2]), t),
			])
	dense.append(_samples[last])
	return dense


# Rebuilds the ribbon: one strip for the body (from 40 % of the blade to the tip, with the gradient texture) and
# another, additive, for the hot line on the tip's edge.
func _rebuild() -> void:
	_mesh.clear_surfaces()
	if _samples.size() < 2:
		_instance.visible = false
		return
	_instance.visible = true
	var dense: Array[Array] = _dense_samples()
	var body_color: Color = get_body_color()
	var line_color: Color = body_color.lerp(Color.WHITE, LINE_LIGHTEN)
	var inner: float = HEAVY_INNER_FRACTION if _heavy else INNER_FRACTION
	var peak: float = get_peak_alpha()
	var line_peak: float = HEAVY_LINE_ALPHA if _heavy else LINE_ALPHA
	_mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLE_STRIP, _body_material)
	for sample: Array in dense:
		var age: float = float(sample[2])
		var fade: float = _fade(age)
		var u: float = clampf(age / FADE_SECONDS, 0.0, 1.0)
		var edges: PackedVector3Array = _edges(sample[0] as Vector3, sample[1] as Vector3, inner)
		_mesh.surface_set_color(Color(body_color.r, body_color.g, body_color.b, peak * fade))
		_mesh.surface_set_uv(Vector2(u, 0.0))
		_mesh.surface_add_vertex(edges[0])
		_mesh.surface_set_color(Color(body_color.r, body_color.g, body_color.b, peak * fade))
		_mesh.surface_set_uv(Vector2(u, 1.0))
		_mesh.surface_add_vertex(edges[1])
	_mesh.surface_end()
	_mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLE_STRIP, _line_material)
	for sample: Array in dense:
		var age: float = float(sample[2])
		var fade: float = _fade(age)
		var base: Vector3 = sample[0] as Vector3
		var tip: Vector3 = sample[1] as Vector3
		# The line fades faster than the body: a spark on the edge, not a tail.
		var alpha: float = line_peak * fade * fade
		_mesh.surface_set_color(Color(line_color.r, line_color.g, line_color.b, 0.0))
		_mesh.surface_add_vertex(base + (tip - base) * LINE_FRACTION)
		_mesh.surface_set_color(Color(line_color.r, line_color.g, line_color.b, alpha))
		_mesh.surface_add_vertex(tip)
	_mesh.surface_end()


# Opacity (from 0 to 1) of a sample of [param age] seconds: falls quadratically until it fades out.
static func _fade(age: float) -> float:
	var fade: float = clampf(1.0 - age / FADE_SECONDS, 0.0, 1.0)
	return fade * fade


# White texture with alpha: u = age (0 = just past the tip, 1 = about to fade out), v = along the
# body (0 = 40 % of the blade, 1 = the tip). Alpha rises toward the tip and the tail breaks up into streaks via
# noise elongated along the sweep direction.
static func _gradient_texture() -> ImageTexture:
	if _texture != null:
		return _texture
	var noise := FastNoiseLite.new()
	noise.seed = 1307
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	noise.frequency = 1.0
	var image: Image = Image.create(TEXTURE_SIZE.x, TEXTURE_SIZE.y, false, Image.FORMAT_RGBA8)
	for y: int in range(TEXTURE_SIZE.y):
		var v: float = (float(y) + 0.5) / float(TEXTURE_SIZE.y)
		# From the blade toward the tip: nothing up to a third, then it rises along a curve to almost 1.
		var across: float = pow(smoothstep(0.10, 1.0, v), 1.7)
		for x: int in range(TEXTURE_SIZE.x):
			var u: float = (float(x) + 0.5) / float(TEXTURE_SIZE.x)
			# Long streaks along u, short across the blade (v).
			var streak: float = noise.get_noise_2d(u * 3.2, v * 15.0) * 0.5 + 0.5
			var dissolve: float = clampf((1.0 - u) * 1.5 - 0.30 + (streak - 0.5) * 1.1 * u, 0.0, 1.0)
			var alpha: float = across * smoothstep(0.0, 0.85, dissolve)
			image.set_pixel(x, y, Color(1.0, 1.0, 1.0, alpha))
	_texture = ImageTexture.create_from_image(image)
	return _texture


func _make_body_material() -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.blend_mode = BaseMaterial3D.BLEND_MODE_MIX
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	material.vertex_color_use_as_albedo = true
	material.albedo_texture = _gradient_texture()
	material.texture_repeat = false
	material.disable_receive_shadows = true
	return material


func _make_line_material() -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	material.vertex_color_use_as_albedo = true
	material.disable_receive_shadows = true
	return material
