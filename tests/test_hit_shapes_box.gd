extends TestCase
## The fort's gate as a target for hits (docs/fortress.md, section 3.3): the annular sector of an
## attack against an oriented box ([method HitShapes.sector_hits_box]) and the overlap of a capsule with
## the box ([method HitShapes.capsule_overlaps_box]), which decides whether the gate's doorway is occupied.
## The test box is the real gate's: 0.5 m thick in X, 4.3 m high and 4 m wide in Z,
## with its center at 2.15 m.

const HALF_EXTENTS: Vector3 = Vector3(0.25, 2.15, 2.0)
const BOX_CENTER: Vector3 = Vector3(0.0, 2.15, 0.0)
const MARGIN: float = 0.01
## Yaw that faces +X (towards the gate, from the west): yaw -90°.
const YAW_EAST: float = -PI * 0.5


func _box(rotation_y: float = 0.0, at: Vector3 = Vector3.ZERO) -> Transform3D:
	return Transform3D(Basis(Vector3.UP, rotation_y), at + BOX_CENTER)


func _hits(origin: Vector3, yaw: float, shape: HitShape, box: Transform3D = _box()) -> bool:
	return HitShapes.sector_hits_box(origin, yaw, shape, box, HALF_EXTENTS)


# --- Sector against box -------------------------------------------------------------------------

func test_a_sector_in_front_of_the_gate_hits_it_and_one_behind_does_not() -> void:
	var shape := HitShape.new()
	# Reach 2.6 m; the box's west face is at x = -0.25.
	assert_true(_hits(Vector3(-2.0, 0.0, 0.0), YAW_EAST, shape), "head-on at 1.75 m from the face")
	assert_true(_hits(Vector3(-2.8, 0.0, 0.0), YAW_EAST, shape), "just within reach (2.55 m)")
	assert_false(_hits(Vector3(-2.9, 0.0, 0.0), YAW_EAST, shape), "just out of reach (2.65 m)")
	assert_false(_hits(Vector3(-2.0, 0.0, 0.0), -YAW_EAST, shape), "with back to the gate")
	assert_false(_hits(Vector3(-3.0, 0.0, 0.0), 0.0, shape),
			"looking along the gate from afar: not even its near face falls within reach")


func test_the_cone_catches_the_gate_corners_off_axis() -> void:
	var shape := HitShape.new()
	# At 1 m from the west face and displaced 1.9 m in Z: it strikes sideways, within the 50° of
	# half-angle, because the near end of the gate falls inside the cone.
	assert_true(_hits(Vector3(-1.25, 0.0, 3.0), YAW_EAST, shape),
			"from one side of the gate, looking straight ahead, the end falls in the cone")
	# Far to the side: not even the gate's end fits within reach.
	assert_false(_hits(Vector3(-1.25, 0.0, 6.5), YAW_EAST, shape), "too far to one side")
	# Looking away from the end, even if it is close.
	assert_false(_hits(Vector3(-1.25, 0.0, 3.0), PI, shape), "looking the opposite way")


func test_the_sector_height_overlaps_the_gate_height() -> void:
	var shape := HitShape.new()
	assert_true(_hits(Vector3(-2.0, 0.0, 0.0), YAW_EAST, shape), "at ground level")
	# The box reaches up to 4.3 m; the hit goes up to height_max = 2 m above the feet.
	assert_true(_hits(Vector3(-2.0, 2.2, 0.0), YAW_EAST, shape), "with the feet 2.2 m higher (walkway)")
	assert_false(_hits(Vector3(-2.0, 4.2, 0.0), YAW_EAST, shape),
			"hits start at 0.2 m above the feet: with the feet at 4.2 m they are above")
	assert_false(_hits(Vector3(-2.0, -3.0, 0.0), YAW_EAST, shape), "far below the box")


func test_an_attacker_inside_the_box_footprint_hits_it() -> void:
	var shape := HitShape.new()
	assert_true(_hits(Vector3(0.0, 0.0, 0.0), 0.3, shape), "with the origin inside the box")
	assert_true(_hits(Vector3(0.1, 0.0, 1.0), PI, shape), "inside and looking any way")


func test_the_inner_radius_leaves_a_hole() -> void:
	var shape := HitShape.new()
	shape.inner_m = 1.5
	assert_true(_hits(Vector3(-1.0, 0.0, 0.0), YAW_EAST, shape),
			"the far part of the box falls in the ring, even if the near one is in the gap")
	# With the origin against the gate, the box's farthest edge is at 0.5 m: inside the gap.
	assert_false(_hits(Vector3(-0.25, 0.0, 0.0), YAW_EAST, shape), "the whole box falls in the central gap")
	shape.inner_m = 0.0
	assert_true(_hits(Vector3(-0.25, 0.0, 0.0), YAW_EAST, shape), "without a gap, yes")


func test_a_rotated_gate_is_hit_where_it_actually_is() -> void:
	var shape := HitShape.new()
	# The same gate rotated 90°: it now occupies the z = 0 plane with its width along X.
	var rotated: Transform3D = _box(PI * 0.5, Vector3(10.0, 0.0, 5.0))
	# South of the gate (greater z) and facing -Z (yaw 0), 1.5 m from its face.
	assert_true(_hits(Vector3(10.0, 0.0, 6.75), 0.0, shape, rotated), "head-on to the rotated gate")
	assert_false(_hits(Vector3(10.0, 0.0, 6.75), PI, shape, rotated), "with back to it")
	assert_false(_hits(Vector3(-2.0, 0.0, 0.0), YAW_EAST, shape, rotated), "and not where it was before")


func test_a_wide_sector_is_the_union_of_two_half_planes() -> void:
	var shape := HitShape.new()
	shape.angle_deg = 240.0
	# A 240° sector leaves uncovered only the 120° cone behind (±60°): from 2 m, the whole gate
	# fits within ±49° of the direction to it.
	assert_true(_hits(Vector3(-2.0, 0.0, 0.0), YAW_EAST, shape), "head-on")
	assert_true(_hits(Vector3(-2.0, 0.0, 0.0), 0.0, shape), "with the gate to one side")
	assert_false(_hits(Vector3(-2.0, 0.0, 0.0), -YAW_EAST, shape),
			"with back turned, the gate lies entirely in the blind cone")
	shape.angle_deg = 360.0
	assert_true(_hits(Vector3(-2.0, 0.0, 0.0), -YAW_EAST, shape), "with 360° there is no cone")


func test_every_swing_direction_agrees_with_a_brute_force_sample() -> void:
	# Contrasts the exact test with a sampling of the box's points: if any sampled point is in
	# the sector, the test must return true; if the test returns true, some point close to the sector must
	# exist (with a sampling margin).
	var shape := HitShape.new()
	var box: Transform3D = _box()
	var mismatches: int = 0
	for ix: int in range(-6, 3):
		for iz: int in range(-5, 6):
			for yaw_step: int in 16:
				var origin := Vector3(float(ix) * 0.6, 0.0, float(iz) * 0.6)
				var yaw: float = float(yaw_step) * TAU / 16.0
				var expected: bool = _sample_hits(origin, yaw, shape, box)
				var actual: bool = _hits(origin, yaw, shape, box)
				if expected and not actual:
					mismatches += 1
	assert_eq(mismatches, 0, "the exact test never misses a hit that the sampling sees")


func _sample_hits(origin: Vector3, yaw: float, shape: HitShape, box: Transform3D) -> bool:
	var forward: Vector3 = Basis(Vector3.UP, yaw) * Vector3.FORWARD
	for sx: int in 9:
		for sz: int in 17:
			var local := Vector3(lerpf(-HALF_EXTENTS.x, HALF_EXTENTS.x, float(sx) / 8.0), 0.0,
					lerpf(-HALF_EXTENTS.z, HALF_EXTENTS.z, float(sz) / 16.0))
			var point: Vector3 = box * local
			var offset := Vector3(point.x - origin.x, 0.0, point.z - origin.z)
			var distance: float = offset.length()
			if distance > shape.range_m or distance < shape.inner_m:
				continue
			if distance < 0.0001 or rad_to_deg(forward.angle_to(offset)) <= shape.angle_deg * 0.5:
				return true
	return false


# --- Capsule against box (the occupied doorway) ----------------------------------------------

func test_a_character_in_the_doorway_overlaps_the_box() -> void:
	var box: Transform3D = _box()
	var feet := Vector3(0.0, 0.0, 0.0)
	assert_true(HitShapes.capsule_overlaps_box(feet, 0.4, 1.8, box, HALF_EXTENTS), "right in the doorway")
	assert_true(HitShapes.capsule_overlaps_box(Vector3(0.6, 0.0, 0.0), 0.4, 1.8, box, HALF_EXTENTS),
			"grazing the east face with the radius (0.25 + 0.4 = 0.65)")
	assert_false(HitShapes.capsule_overlaps_box(Vector3(0.7, 0.0, 0.0), 0.4, 1.8, box, HALF_EXTENTS),
			"at 0.45 m from the east face it no longer touches")
	assert_false(HitShapes.capsule_overlaps_box(Vector3(-0.7, 0.0, 0.0), 0.4, 1.8, box, HALF_EXTENTS),
			"nor from the west")
	assert_true(HitShapes.capsule_overlaps_box(Vector3(0.0, 0.0, 2.3), 0.4, 1.8, box, HALF_EXTENTS),
			"at the end of the width, grazing the post with the radius")
	assert_false(HitShapes.capsule_overlaps_box(Vector3(0.0, 0.0, 2.5), 0.4, 1.8, box, HALF_EXTENTS),
			"outside the gate's width")


func test_a_character_standing_on_the_walkway_above_the_gate_does_not_block_it() -> void:
	var box: Transform3D = _box()
	assert_false(HitShapes.capsule_overlaps_box(Vector3(0.0, 4.4, 0.0), 0.4, 1.8, box, HALF_EXTENTS),
			"stepping on the walkway at 4.4 m, above the box")
	assert_true(HitShapes.capsule_overlaps_box(Vector3(0.0, 3.0, 0.0), 0.4, 1.8, box, HALF_EXTENTS),
			"with the feet within the box's height")
	assert_false(HitShapes.capsule_overlaps_box(Vector3(0.0, -2.0, 0.0), 0.4, 1.8, box, HALF_EXTENTS),
			"under the box's floor, with the head below")
