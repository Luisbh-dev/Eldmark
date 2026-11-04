extends TestCase
## Tests for hit geometry ([HitShapes], docs/combate.md section 4.1): annular sector
## with height against vertical capsule (angle edge, reach with the radius, inner gap,
## height), segment against capsule, frontal cone and line of sight against a real wall in its own
## physics space.
##
## Convention: yaw 0 faces -Z; a positive yaw turns towards -X (like [member PlayerCharacter.yaw]).

## Distance used to place targets "just inside" and "just outside" an edge (m).
const MARGIN: float = 0.01
## The same for angles (degrees).
const ANGLE_MARGIN_DEG: float = 0.05

var _viewport: SubViewport


func after_each() -> void:
	if _viewport != null:
		_viewport.queue_free()
		_viewport = null


# --- Annular sector with height against capsule ----------------------------------------------

func test_sector_hits_target_in_front_and_not_behind() -> void:
	var shape := HitShape.new()
	assert_true(_sector(shape, 0.0, Vector3(0.0, 0.0, -2.0)), "head-on at 2 m")
	assert_true(_sector(shape, 0.0, Vector3(0.0, 0.0, -0.5)), "head-on at 0.5 m")
	assert_false(_sector(shape, 0.0, Vector3(0.0, 0.0, 2.0)), "behind at 2 m")
	assert_false(_sector(shape, 0.0, Vector3(2.0, 0.0, 0.0)), "at 90° at 2 m (the sector is 100°)")
	assert_false(_sector(shape, 0.0, Vector3(-2.0, 0.0, 0.0)), "a -90° a 2 m")


func test_sector_follows_attacker_yaw() -> void:
	var shape := HitShape.new()
	# Yaw +90°: faces -X.
	assert_true(_sector(shape, PI * 0.5, Vector3(-2.0, 0.0, 0.0)), "yaw 90°: -X is in front")
	assert_false(_sector(shape, PI * 0.5, Vector3(2.0, 0.0, 0.0)), "yaw 90°: +X is behind")
	assert_false(_sector(shape, PI * 0.5, Vector3(0.0, 0.0, -2.0)), "yaw 90°: -Z is to one side")
	# Yaw 180°: faces +Z.
	assert_true(_sector(shape, PI, Vector3(0.0, 0.0, 2.0)), "yaw 180°: +Z is in front")
	assert_false(_sector(shape, PI, Vector3(0.0, 0.0, -2.0)), "yaw 180°: -Z is behind")
	# The origin is not (0, 0, 0).
	assert_true(HitShapes.sector_hits_capsule(Vector3(10.0, 0.0, 5.0), 0.0, shape,
			Vector3(10.0, 0.0, 3.0), HitShapes.CAPSULE_RADIUS, HitShapes.CAPSULE_HEIGHT),
			"with the attacker displaced")


func test_sector_angle_edge_grows_with_capsule_radius() -> void:
	var shape := HitShape.new()
	var distance: float = 2.0
	var radius: float = HitShapes.CAPSULE_RADIUS
	# Edge: half the angle plus what the capsule's disc subtends at that distance.
	var edge_deg: float = shape.angle_deg * 0.5 + rad_to_deg(asin(radius / distance))
	for side: float in [1.0, -1.0]:
		var inside: float = deg_to_rad(edge_deg - ANGLE_MARGIN_DEG)
		var outside: float = deg_to_rad(edge_deg + ANGLE_MARGIN_DEG)
		assert_true(_sector(shape, 0.0, _polar(distance, side * inside)),
				"just inside the edge (side %d)" % int(side))
		assert_false(_sector(shape, 0.0, _polar(distance, side * outside)),
				"just outside the edge (side %d)" % int(side))
	# With no capsule radius the edge is the sector's: 50°.
	var half_deg: float = shape.angle_deg * 0.5
	assert_true(HitShapes.sector_hits_capsule(Vector3.ZERO, 0.0, shape,
			_polar(distance, deg_to_rad(half_deg - ANGLE_MARGIN_DEG)), 0.0, 1.8),
			"radius 0 just inside 50°")
	assert_false(HitShapes.sector_hits_capsule(Vector3.ZERO, 0.0, shape,
			_polar(distance, deg_to_rad(half_deg + ANGLE_MARGIN_DEG)), 0.0, 1.8),
			"radius 0 just outside 50°")
	# Closer, the disc subtends more: at 1 m the edge is 50° + asin(0.4) = 73.6°.
	var near_edge_deg: float = half_deg + rad_to_deg(asin(radius / 1.0))
	assert_true(_sector(shape, 0.0, _polar(1.0, deg_to_rad(near_edge_deg - ANGLE_MARGIN_DEG))),
			"at 1 m, just inside")
	assert_false(_sector(shape, 0.0, _polar(1.0, deg_to_rad(near_edge_deg + ANGLE_MARGIN_DEG))),
			"at 1 m, just outside")


func test_sector_reach_includes_capsule_radius() -> void:
	var shape := HitShape.new()
	var reach: float = shape.range_m + HitShapes.CAPSULE_RADIUS
	assert_true(_sector(shape, 0.0, Vector3(0.0, 0.0, -(reach - MARGIN))),
			"capsule axis just inside (reach + radius)")
	assert_false(_sector(shape, 0.0, Vector3(0.0, 0.0, -(reach + MARGIN))),
			"capsule axis just outside")
	assert_true(_sector(shape, 0.0, Vector3(0.0, 0.0, -(shape.range_m + MARGIN))),
			"the axis is beyond the reach but the capsule's edge touches it")
	# With another capsule radius the reach changes.
	assert_true(HitShapes.sector_hits_capsule(Vector3.ZERO, 0.0, shape,
			Vector3(0.0, 0.0, -(shape.range_m + 0.1 - MARGIN)), 0.1, 1.8), "radius 0.1 inside")
	assert_false(HitShapes.sector_hits_capsule(Vector3.ZERO, 0.0, shape,
			Vector3(0.0, 0.0, -(shape.range_m + 0.1 + MARGIN)), 0.1, 1.8), "radius 0.1 outside")
	# A greater reach in the shape extends it.
	shape.range_m = 5.0
	assert_true(_sector(shape, 0.0, Vector3(0.0, 0.0, -5.0)), "with reach 5 m")


func test_sector_inner_radius_leaves_a_hole() -> void:
	var shape := HitShape.new()
	shape.inner_m = 1.0
	var hole: float = shape.inner_m - HitShapes.CAPSULE_RADIUS
	assert_false(_sector(shape, 0.0, Vector3(0.0, 0.0, -(hole - MARGIN))),
			"inside the gap (the capsule's edge does not reach)")
	assert_true(_sector(shape, 0.0, Vector3(0.0, 0.0, -(hole + MARGIN))),
			"the capsule's edge just reaches the ring")
	assert_true(_sector(shape, 0.0, Vector3(0.0, 0.0, -2.0)), "right in the ring")
	assert_false(_sector(shape, 0.0, Vector3(0.0, 0.0, -0.2)), "almost stuck to the attacker")


func test_sector_origin_inside_capsule_ignores_angle() -> void:
	var shape := HitShape.new()
	# The attacker is inside the victim's disc: there is no angle, and it reaches them even if
	# they have it "behind their back".
	assert_true(_sector(shape, 0.0, Vector3(0.0, 0.0, 0.2)), "at 0.2 m behind")
	assert_true(_sector(shape, 0.0, Vector3.ZERO), "at the same point")
	# A bit beyond the radius the angle does count.
	assert_false(_sector(shape, 0.0, Vector3(0.0, 0.0, 0.45)), "at 0.45 m behind it no longer does")


func test_sector_height_overlap() -> void:
	var shape := HitShape.new()
	var height: float = HitShapes.CAPSULE_HEIGHT
	var ahead := Vector3(0.0, 0.0, -2.0)
	# The shape covers [0.2, 2.0] above the attacker's feet; the capsule, [y, y + 1.8].
	assert_true(_sector_at(shape, Vector3(ahead.x, 0.0, ahead.z)), "at the same height")
	assert_true(_sector_at(shape, Vector3(ahead.x, shape.height_max - MARGIN, ahead.z)),
			"feet just below the shape's ceiling")
	assert_false(_sector_at(shape, Vector3(ahead.x, shape.height_max + MARGIN, ahead.z)),
			"feet just above the shape's ceiling (jumping over)")
	assert_true(_sector_at(shape, Vector3(ahead.x, shape.height_min - height + MARGIN, ahead.z)),
			"head just above the shape's floor")
	assert_false(_sector_at(shape, Vector3(ahead.x, shape.height_min - height - MARGIN, ahead.z)),
			"head just below the shape's floor (in a pit)")
	# Heights are relative to the attacker's feet.
	var origin := Vector3(0.0, 10.0, 0.0)
	assert_true(HitShapes.sector_hits_capsule(origin, 0.0, shape, Vector3(0.0, 10.0, -2.0),
			HitShapes.CAPSULE_RADIUS, height), "attacker at y = 10, target at their height")
	assert_false(HitShapes.sector_hits_capsule(origin, 0.0, shape, Vector3(0.0, 0.0, -2.0),
			HitShapes.CAPSULE_RADIUS, height), "attacker at y = 10, target 10 m lower")
	# The shape's heights can be narrowed (a low blow).
	shape.height_min = 0.0
	shape.height_max = 0.5
	assert_true(_sector_at(shape, Vector3(ahead.x, 0.0, ahead.z)), "low blow, at ground level")
	assert_false(_sector_at(shape, Vector3(ahead.x, 0.6, ahead.z)),
			"low blow, the target's feet above")


# --- Segment against capsule ------------------------------------------------------------------

func test_segment_hits_capsule_through_body() -> void:
	var feet := Vector3.ZERO
	var r: float = HitShapes.CAPSULE_RADIUS
	var h: float = HitShapes.CAPSULE_HEIGHT
	# Horizontal at mid height, side to side: the distance to the axis is the deviation in z.
	assert_true(_segment(Vector3(-2.0, 1.0, 0.0), Vector3(2.0, 1.0, 0.0), feet, r, h),
			"through the centre")
	assert_true(_segment(Vector3(-2.0, 1.0, r - MARGIN), Vector3(2.0, 1.0, r - MARGIN), feet, r, h),
			"grazing on the inside")
	assert_false(_segment(Vector3(-2.0, 1.0, r + MARGIN), Vector3(2.0, 1.0, r + MARGIN), feet, r,
			h), "grazing on the outside")
	# A segment that ends before arriving.
	assert_false(_segment(Vector3(-2.0, 1.0, 0.0), Vector3(-r - MARGIN, 1.0, 0.0), feet, r, h),
			"it stops just short of touching")
	assert_true(_segment(Vector3(-2.0, 1.0, 0.0), Vector3(-r + MARGIN, 1.0, 0.0), feet, r, h),
			"it ends just inside the body")
	# A segment that starts behind and crosses diagonally.
	assert_true(_segment(Vector3(-3.0, 0.5, -3.0), Vector3(3.0, 1.5, 3.0), feet, r, h),
			"diagonally through the body")
	assert_false(_segment(Vector3(-3.0, 0.5, 3.0), Vector3(3.0, 1.5, 4.0), feet, r, h),
			"diagonally on the outside")


func test_segment_hits_capsule_end_caps() -> void:
	var feet := Vector3.ZERO
	var r: float = HitShapes.CAPSULE_RADIUS
	var h: float = HitShapes.CAPSULE_HEIGHT
	# The capsule ends at y = 1.8 (spherical cap). Passing over the axis:
	assert_true(_segment(Vector3(-2.0, h - MARGIN, 0.0), Vector3(2.0, h - MARGIN, 0.0), feet, r, h),
			"just below the crown of the head")
	assert_false(_segment(Vector3(-2.0, h + MARGIN, 0.0), Vector3(2.0, h + MARGIN, 0.0), feet, r,
			h), "just above the crown of the head")
	assert_true(_segment(Vector3(-2.0, MARGIN, 0.0), Vector3(2.0, MARGIN, 0.0), feet, r, h),
			"just above the feet")
	assert_false(_segment(Vector3(-2.0, -MARGIN, 0.0), Vector3(2.0, -MARGIN, 0.0), feet, r, h),
			"just below the feet")
	# On the cap the width shrinks: at the height of the crown - 0.05 m, a deviation of
	# 0.35 m is already outside (the cap's edge is at sqrt(0.4² - 0.35²) ≈ 0.19 m from the axis).
	assert_false(_segment(Vector3(-2.0, h - 0.05, 0.35), Vector3(2.0, h - 0.05, 0.35), feet, r, h),
			"through the cap, with deviation")
	assert_true(_segment(Vector3(-2.0, h - 0.05, 0.1), Vector3(2.0, h - 0.05, 0.1), feet, r, h),
			"through the cap, centred")


func test_segment_hits_capsule_vertical_and_degenerate() -> void:
	var feet := Vector3(5.0, 2.0, -1.0)
	var r: float = HitShapes.CAPSULE_RADIUS
	var h: float = HitShapes.CAPSULE_HEIGHT
	# Parallel to the axis.
	assert_true(_segment(Vector3(5.3, -10.0, -1.0), Vector3(5.3, 10.0, -1.0), feet, r, h),
			"vertical at 0.3 m from the axis")
	assert_false(_segment(Vector3(5.5, -10.0, -1.0), Vector3(5.5, 10.0, -1.0), feet, r, h),
			"vertical at 0.5 m from the axis")
	# Segment of length 0 (a stationary projectile).
	var inside := Vector3(5.1, 3.0, -1.1)
	assert_true(_segment(inside, inside, feet, r, h), "point inside")
	var outside := Vector3(6.0, 3.0, -1.0)
	assert_false(_segment(outside, outside, feet, r, h), "point outside")
	# The capsule's position (and its feet's) counts.
	assert_false(_segment(Vector3(0.0, 1.0, 0.0), Vector3(10.0, 1.0, 0.0), feet, r, h),
			"at the height of the other's feet, but 1 m below this capsule's")
	# A capsule shorter than two radii collapses to a point.
	assert_true(_segment(Vector3(-1.0, 0.3, 0.0), Vector3(1.0, 0.3, 0.0), Vector3.ZERO, 0.4, 0.6),
			"squat capsule, through the centre")
	assert_false(_segment(Vector3(-1.0, 0.8, 0.0), Vector3(1.0, 0.8, 0.0), Vector3.ZERO, 0.4, 0.6),
			"squat capsule, above")


# --- Frontal cone -----------------------------------------------------------------------------

func test_is_in_front_cone_edge() -> void:
	var defender := Vector3(1.0, 0.0, 1.0)
	for cone: float in [120.0, 90.0, 180.0]:
		var half: float = cone * 0.5
		for side: float in [1.0, -1.0]:
			var inside: Vector3 = defender + _polar(3.0, side * deg_to_rad(half - ANGLE_MARGIN_DEG))
			var outside: Vector3 = defender + _polar(3.0, side * deg_to_rad(half + ANGLE_MARGIN_DEG))
			assert_true(HitShapes.is_in_front(defender, 0.0, inside, cone),
					"%d° cone: just inside (side %d)" % [int(cone), int(side)])
			assert_false(HitShapes.is_in_front(defender, 0.0, outside, cone),
					"%d° cone: just outside (side %d)" % [int(cone), int(side)])
	assert_true(HitShapes.is_in_front(defender, 0.0, defender + Vector3(0.0, 0.0, -5.0), 120.0),
			"straight ahead")
	assert_false(HitShapes.is_in_front(defender, 0.0, defender + Vector3(0.0, 0.0, 5.0), 120.0),
			"straight behind")
	assert_true(HitShapes.is_in_front(defender, 0.0, defender + Vector3(0.0, 0.0, 5.0), 360.0),
			"a 360° cone covers everything")


func test_is_in_front_uses_defender_yaw_and_ignores_height() -> void:
	var defender := Vector3.ZERO
	# Yaw 90°: faces -X.
	assert_true(HitShapes.is_in_front(defender, PI * 0.5, Vector3(-3.0, 0.0, 0.0), 120.0),
			"yaw 90°: -X is in front")
	assert_false(HitShapes.is_in_front(defender, PI * 0.5, Vector3(0.0, 0.0, -3.0), 120.0),
			"yaw 90°: -Z is at 90°, outside a 120° cone (±60°)")
	assert_false(HitShapes.is_in_front(defender, PI * 0.5, Vector3(3.0, 0.0, 0.0), 120.0),
			"yaw 90°: +X is behind")
	# The attacker's height does not change the horizontal angle.
	assert_true(HitShapes.is_in_front(defender, 0.0, Vector3(0.0, 8.0, -2.0), 120.0),
			"the attacker on a higher floor, in front")
	assert_false(HitShapes.is_in_front(defender, 0.0, Vector3(0.0, 8.0, 2.0), 120.0),
			"the attacker on a higher floor, behind")
	# Directly above: no horizontal direction, counts as in front.
	assert_true(HitShapes.is_in_front(defender, 0.0, Vector3(0.0, 3.0, 0.0), 120.0),
			"attacker on the same vertical")


# --- Line of sight ----------------------------------------------------------------------------

func test_line_of_sight_blocked_by_wall() -> void:
	await _build_world([_wall(Vector3(0.0, 2.0, -3.0), Vector3(4.0, 4.0, 0.2))])
	var space: PhysicsDirectSpaceState3D = _viewport.find_world_3d().direct_space_state
	var attacker := Vector3.ZERO
	assert_false(HitShapes.has_line_of_sight(space, attacker, Vector3(0.0, 0.0, -6.0)),
			"the wall between the two")
	assert_true(HitShapes.has_line_of_sight(space, attacker, Vector3(0.0, 0.0, -2.0)),
			"the target in front of the wall")
	assert_true(HitShapes.has_line_of_sight(space, attacker, Vector3(0.0, 0.0, 4.0)),
			"the target on the opposite side, without a wall")
	assert_true(HitShapes.has_line_of_sight(space, attacker, Vector3(10.0, 0.0, -6.0)),
			"the target behind but going around the wall (the ray passes by the side)")
	assert_false(HitShapes.has_line_of_sight(space, Vector3(0.0, 0.0, -6.0), attacker),
			"the wall also blocks in the opposite direction")


func test_line_of_sight_uses_chest_and_center_heights() -> void:
	# The ray goes from 1.4 m (attacker's chest) to 0.9 m (victim's centre): halfway along
	# it is at 1.15 m. A 1.0 m low wall lets it through and a 1.3 m one blocks it.
	await _build_world([
		_wall(Vector3(-10.0, 0.5, -3.0), Vector3(4.0, 1.0, 0.2)),
		_wall(Vector3(10.0, 0.65, -3.0), Vector3(4.0, 1.3, 0.2)),
	])
	var space: PhysicsDirectSpaceState3D = _viewport.find_world_3d().direct_space_state
	assert_true(HitShapes.has_line_of_sight(space, Vector3(-10.0, 0.0, 0.0),
			Vector3(-10.0, 0.0, -6.0)), "above a 1.0 m low wall")
	assert_false(HitShapes.has_line_of_sight(space, Vector3(10.0, 0.0, 0.0),
			Vector3(10.0, 0.0, -6.0)), "against a 1.3 m low wall")
	# Heights are relative to the feet: with the feet at 1 m, the 1.3 m low wall is below.
	assert_true(HitShapes.has_line_of_sight(space, Vector3(10.0, 1.0, 0.0),
			Vector3(10.0, 1.0, -6.0)), "both raised 1 m above the 1.3 m low wall")


func test_line_of_sight_only_looks_at_world_layer() -> void:
	# A body on the character layer (2) or the invisible blockers layer (3) does not block the ray.
	var character_like: StaticBody3D = _wall(Vector3(0.0, 2.0, -3.0), Vector3(4.0, 4.0, 0.2))
	character_like.collision_layer = PlayerCharacter.CHARACTER_COLLISION_LAYER
	var blocker: StaticBody3D = _wall(Vector3(0.0, 2.0, -4.0), Vector3(4.0, 4.0, 0.2))
	blocker.collision_layer = PlayerCharacter.PLAYER_BLOCKER_LAYER
	# Control: a real wall, just as big, somewhere else.
	var world_wall: StaticBody3D = _wall(Vector3(20.0, 2.0, -3.0), Vector3(4.0, 4.0, 0.2))
	await _build_world([character_like, blocker, world_wall])
	var space: PhysicsDirectSpaceState3D = _viewport.find_world_3d().direct_space_state
	assert_true(HitShapes.has_line_of_sight(space, Vector3.ZERO, Vector3(0.0, 0.0, -6.0)),
			"bodies on other layers do not count")
	assert_true(HitShapes.is_ray_clear(space, Vector3(0.0, 1.0, 0.0), Vector3(0.0, 1.0, -6.0)),
			"is_ray_clear does not look at them either")
	assert_false(HitShapes.has_line_of_sight(space, Vector3(20.0, 0.0, 0.0),
			Vector3(20.0, 0.0, -6.0)), "the world-layer wall does block")


## H3a (docs/habilidades.md, 4.4): is_ray_clear uses hit_from_inside: a ray that starts inside a body
## hits at its origin (without that, Godot ignores it and a fort's owner would strike from its gate's doorway).
func test_a_ray_that_starts_inside_a_body_is_not_clear() -> void:
	await _build_world([_wall(Vector3(0.0, 2.0, -3.0), Vector3(4.0, 4.0, 0.6))])
	var space: PhysicsDirectSpaceState3D = _viewport.find_world_3d().direct_space_state
	assert_false(HitShapes.is_ray_clear(space, Vector3(0.0, 1.4, -3.0), Vector3(0.0, 0.9, 3.0)),
			"from inside the wall outwards")
	assert_false(HitShapes.is_ray_clear(space, Vector3(0.0, 1.4, 3.0), Vector3(0.0, 0.9, -3.0)),
			"from outside inwards (enters through its face)")
	assert_true(HitShapes.is_ray_clear(space, Vector3(0.0, 1.4, -1.0), Vector3(0.0, 0.9, 3.0)),
			"against the wall but outside, clear")


# --- Utilities --------------------------------------------------------------------------------

## Sector against a character capsule with its feet at [param target_feet], from the origin.
func test_segment_capsule_fraction_finds_the_first_entry() -> void:
	var feet := Vector3(0.0, 0.0, -10.0)
	var radius: float = 0.45
	# Head-on, at mid height: it enters through the cylinder's face.
	var a := Vector3(0.0, 0.9, 0.0)
	var b := Vector3(0.0, 0.9, -20.0)
	assert_near(HitShapes.segment_capsule_fraction(a, b, feet, radius, 1.8), (10.0 - radius) / 20.0, 1e-5,
			"enters the cylinder")
	# Above the head: it does not touch.
	assert_eq(HitShapes.segment_capsule_fraction(Vector3(0.0, 2.3, 0.0), Vector3(0.0, 2.3, -20.0), feet,
			radius, 1.8), -1.0, "above, -1")
	# Grazing the top hemisphere: the entry falls on the sphere.
	var top_y: float = 1.8 - radius
	var graze_y: float = top_y + 0.3
	var expected_z: float = -10.0 + sqrt(radius * radius - 0.3 * 0.3)
	var graze: float = HitShapes.segment_capsule_fraction(Vector3(0.0, graze_y, 0.0),
			Vector3(0.0, graze_y, -20.0), feet, radius, 1.8)
	assert_near(graze, -expected_z / 20.0, 1e-5, "enters through the upper hemisphere")
	# Vertical, falling onto the head.
	var fall: float = HitShapes.segment_capsule_fraction(Vector3(0.0, 5.0, -10.0), Vector3(0.0, 0.0, -10.0),
			feet, radius, 1.8)
	assert_near(fall, (5.0 - 1.8) / 5.0, 1e-5, "from above, at the top of the capsule")
	# The segment starts inside: 0.
	assert_eq(HitShapes.segment_capsule_fraction(Vector3(0.1, 1.0, -10.0), Vector3(5.0, 1.0, -10.0),
			feet, radius, 1.8), 0.0, "starts inside: 0")
	# It does not reach.
	assert_eq(HitShapes.segment_capsule_fraction(a, Vector3(0.0, 0.9, -9.0), feet, radius, 1.8), -1.0,
			"falls short: -1")
	# Consistent with segment_hits_capsule over a cloud of segments.
	for i: int in 200:
		var from := Vector3(sin(i * 0.37) * 3.0, 0.9 + sin(i * 0.91) * 1.5, -10.0 + cos(i * 0.53) * 3.0)
		var to := Vector3(cos(i * 0.71) * 3.0, 0.9 + cos(i * 0.29) * 1.5, -10.0 + sin(i * 0.17) * 3.0)
		var fraction: float = HitShapes.segment_capsule_fraction(from, to, feet, radius, 1.8)
		var hits: bool = HitShapes.segment_hits_capsule(from, to, feet, radius, 1.8)
		if (fraction >= 0.0) != hits:
			fail("segment %d: fraction %s and segment_hits_capsule %s" % [i, fraction, hits])
			return
		if fraction > 0.0:
			var entry: Vector3 = from.lerp(to, fraction)
			var before: Vector3 = from.lerp(to, maxf(fraction - 0.001, 0.0))
			assert_true(HitShapes.segment_hits_capsule(entry, entry, feet, radius + 1e-4, 1.8),
					"segment %d: the entry point is on the surface" % i)
			assert_false(HitShapes.segment_hits_capsule(from, before, feet, radius - 1e-4, 1.8),
					"segment %d: and before it, it was not touching" % i)


func test_segment_box_fraction_with_a_turned_box() -> void:
	var box := Transform3D(Basis(Vector3.UP, 0.4), Vector3(2.0, 1.0, -6.0))
	var half := Vector3(1.3, 1.0, 0.15)
	var normal: Vector3 = box.basis * Vector3(0.0, 0.0, 1.0)
	var start: Vector3 = box.origin + normal * 5.0
	var end: Vector3 = box.origin - normal * 5.0
	assert_near(HitShapes.segment_box_fraction(start, end, box, half), (5.0 - 0.15) / 10.0, 1e-5,
			"head-on, the face")
	assert_eq(HitShapes.segment_box_fraction(box.origin, end, box, half), 0.0, "from inside: 0")
	var aside: Vector3 = box.basis * Vector3(2.0, 0.0, 0.0)
	assert_eq(HitShapes.segment_box_fraction(start + aside, end + aside, box, half), -1.0,
			"from the side: -1")
	assert_eq(HitShapes.segment_box_fraction(start, box.origin + normal * 0.5, box, half), -1.0,
			"falls short: -1")
	var over := Vector3(0.0, 1.2, 0.0)
	assert_eq(HitShapes.segment_box_fraction(start + over, end + over, box, half), -1.0, "from above: -1")
	assert_eq(HitShapes.segment_box_fraction(start, start, box, half), -1.0, "a point outside: -1")
	# Parallel to a face, within its strip.
	var along: Vector3 = box.basis * Vector3(1.0, 0.0, 0.0)
	assert_near(HitShapes.segment_box_fraction(box.origin - along * 4.0, box.origin + along * 4.0, box, half),
			(4.0 - 1.3) / 8.0, 1e-5, "along it, enters through the edge")


func _sector(shape: HitShape, yaw: float, target_feet: Vector3) -> bool:
	return HitShapes.sector_hits_capsule(Vector3.ZERO, yaw, shape, target_feet,
			HitShapes.CAPSULE_RADIUS, HitShapes.CAPSULE_HEIGHT)


func _sector_at(shape: HitShape, target_feet: Vector3) -> bool:
	return _sector(shape, 0.0, target_feet)


func _segment(a: Vector3, b: Vector3, feet: Vector3, radius: float, height: float) -> bool:
	return HitShapes.segment_hits_capsule(a, b, feet, radius, height)


## Horizontal point at [param distance] from the origin, rotated [param angle] radians from -Z towards
## +X (positive) or -X (negative): the angle is measured relative to the direction of a yaw 0.
func _polar(distance: float, angle: float) -> Vector3:
	return Vector3(distance * sin(angle), 0.0, -distance * cos(angle))


## Static wall on the world layer, centred at [param center].
func _wall(center: Vector3, size: Vector3) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.collision_layer = PlayerCharacter.WORLD_COLLISION_LAYER
	var collision := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = size
	collision.shape = box
	body.add_child(collision)
	body.position = center
	return body


## Creates its own physics world (SubViewport with own_world_3d) with [param bodies] and waits for
## the physics engine to register them.
func _build_world(bodies: Array[StaticBody3D]) -> void:
	_viewport = SubViewport.new()
	_viewport.own_world_3d = true
	_viewport.size = Vector2i(64, 64)
	tree.root.add_child(_viewport)
	for body: StaticBody3D in bodies:
		_viewport.add_child(body)
	await wait_physics_frames(3)
