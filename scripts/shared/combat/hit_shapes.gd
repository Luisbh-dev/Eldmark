class_name HitShapes
extends RefCounted
## Hit geometry (docs/combate.md, section 4.1): pure math, no physics bodies,
## except line of sight, which casts a ray against the world.
## [br][br]
## All tests are of a volume against a vertical capsule (the character's: radius
## [constant CAPSULE_RADIUS] and height [constant CAPSULE_HEIGHT] measured from the feet). The
## orientation follows the convention of [member PlayerCharacter.yaw]: yaw 0 looks toward -Z.
## [br][br]
## Shared: used by the server (lag compensation), aiming and projectiles
## (docs/abilities.md, section 4.4: [method segment_capsule_fraction] and
## [method segment_box_fraction]) and the tests; it depends on nothing from the client.

## Radius of a character's capsule (m), equal to the [code]Collision[/code] node.
const CAPSULE_RADIUS: float = 0.4
## Height of a character's capsule from the feet (m).
const CAPSULE_HEIGHT: float = 1.8
## Height above the attacker's feet from which the line-of-sight ray starts (the chest).
const LINE_OF_SIGHT_FROM_HEIGHT: float = 1.4
## Height above the victim's feet that the line-of-sight ray reaches (their center).
const LINE_OF_SIGHT_TO_HEIGHT: float = 0.9
## Layers the line-of-sight ray is cast against: the world's (layer 1) and the
## structures' (layer 4, the fort gate's sight body: it stops nobody, but nothing can be
## seen or hit through it).
const LINE_OF_SIGHT_MASK: int = PlayerCharacter.WORLD_COLLISION_LAYER | PlayerCharacter.STRUCTURE_LAYER

## Below this horizontal distance two points are considered to be in the same place, and there is no
## direction between them.
const _MIN_DIRECTION_LENGTH: float = 0.0001
## Tolerance of floating-point comparisons at the edges (m and radians).
const _EPSILON: float = 0.000001


## true if the annular sector with height of [param shape], with its origin at [param origin] (the attacker's
## feet) and oriented according to [param yaw], touches the vertical capsule of [param radius] and
## [param height] resting at [param capsule_feet].
## [br][br]
## Three conditions at once, with edges included:
## [br]- horizontal distance between the origin and the capsule's axis within
## [code][inner_m - radius, range_m + radius][/code];
## [br]- angle between the attacker's yaw and the direction to the capsule's axis at most
## [code]angle_deg / 2 + asin(radius / d)[/code] (the capsule's disc seen from the origin
## subtends [code]asin(radius / d)[/code]); if the origin falls inside the disc
## ([code]d <= radius[/code]) there is no direction and the angle does not count;
## [br]- vertical overlap of [code][height_min, height_max][/code] above the attacker's feet with
## [code][0, height][/code] above the capsule's feet.
static func sector_hits_capsule(origin: Vector3, yaw: float, shape: HitShape,
		capsule_feet: Vector3, radius: float, height: float) -> bool:
	# Height.
	var shape_bottom: float = origin.y + shape.height_min
	var shape_top: float = origin.y + shape.height_max
	if shape_bottom > capsule_feet.y + height + _EPSILON or shape_top < capsule_feet.y - _EPSILON:
		return false
	# Horizontal distance to the axis.
	var offset := Vector2(capsule_feet.x - origin.x, capsule_feet.z - origin.z)
	var distance: float = offset.length()
	if distance > shape.range_m + radius + _EPSILON:
		return false
	if distance < shape.inner_m - radius - _EPSILON:
		return false
	# Angle. With the origin inside the capsule's disc there is no direction to compare.
	if distance <= radius:
		return true
	var forward: Vector3 = Basis(Vector3.UP, yaw) * Vector3.FORWARD
	var cos_angle: float = (forward.x * offset.x + forward.z * offset.y) / distance
	var angle: float = acos(clampf(cos_angle, -1.0, 1.0))
	var limit: float = deg_to_rad(shape.angle_deg) * 0.5 + asin(clampf(radius / distance, 0.0, 1.0))
	return angle <= limit + _EPSILON


## true if the segment from [param a] to [param b] (a projectile in one tick, for example) touches the
## vertical capsule of [param radius] and [param height] resting at [param capsule_feet]: the
## distance between the segment and the capsule's axis (from the radius height to the total height
## minus the radius) is at most the radius. Works with a segment of length 0.
static func segment_hits_capsule(a: Vector3, b: Vector3, capsule_feet: Vector3, radius: float,
		height: float) -> bool:
	# The capsule's axis: the segment between the centers of the two hemispheres. A capsule shorter
	# than two radii reduces to a point at mid height.
	var bottom_y: float = capsule_feet.y + minf(radius, height * 0.5)
	var top_y: float = capsule_feet.y + maxf(height - radius, height * 0.5)
	var axis_a := Vector3(capsule_feet.x, bottom_y, capsule_feet.z)
	var axis_b := Vector3(capsule_feet.x, top_y, capsule_feet.z)
	var squared: float = _segment_segment_distance_squared(a, b, axis_a, axis_b)
	return squared <= radius * radius + _EPSILON


## Fraction (0 to 1) of the segment from [param a] to [param b] at which it first enters the
## vertical capsule of [param radius] and [param height] resting at [param capsule_feet] (the same
## volume as [method segment_hits_capsule]), or -1 if it does not touch it. If [param a] is already inside,
## 0 (docs/abilities.md, section 4.4: a projectile that starts its tick inside a capsule).
## The capsule is the union of a cylinder and two spheres: the entry is the first of the three.
static func segment_capsule_fraction(a: Vector3, b: Vector3, capsule_feet: Vector3, radius: float,
		height: float) -> float:
	var bottom_y: float = capsule_feet.y + minf(radius, height * 0.5)
	var top_y: float = capsule_feet.y + maxf(height - radius, height * 0.5)
	var axis_a := Vector3(capsule_feet.x, bottom_y, capsule_feet.z)
	var axis_b := Vector3(capsule_feet.x, top_y, capsule_feet.z)
	var radius_squared: float = radius * radius
	if _segment_segment_distance_squared(a, a, axis_a, axis_b) <= radius_squared + _EPSILON:
		return 0.0
	var direction: Vector3 = b - a
	var best: float = INF
	# Side of the cylinder (vertical axis): it only counts if the entry falls between the two centers.
	var flat_direction := Vector2(direction.x, direction.z)
	var flat_offset := Vector2(a.x - capsule_feet.x, a.z - capsule_feet.z)
	var quad_a: float = flat_direction.dot(flat_direction)
	if quad_a > _EPSILON * _EPSILON:
		var quad_b: float = 2.0 * flat_offset.dot(flat_direction)
		var quad_c: float = flat_offset.dot(flat_offset) - radius_squared
		var discriminant: float = quad_b * quad_b - 4.0 * quad_a * quad_c
		if discriminant >= 0.0:
			var entry: float = (-quad_b - sqrt(discriminant)) / (2.0 * quad_a)
			var entry_y: float = a.y + direction.y * entry
			if entry >= 0.0 and entry <= 1.0 and entry_y >= bottom_y and entry_y <= top_y:
				best = entry
	# The two hemispheres.
	for center: Vector3 in [axis_a, axis_b]:
		var entry_sphere: float = _segment_sphere_entry(a, direction, center, radius_squared)
		if entry_sphere >= 0.0:
			best = minf(best, entry_sphere)
	return best if best <= 1.0 else -1.0


## Fraction (0 to 1) of the segment from [param a] to [param b] at which it enters the box [param box]
## (transform of its center; it can rotate on any axis) of half dimensions
## [param half_extents], or -1 if it does not touch it; 0 if [param a] is already inside or on the edge (slab
## method in the box's space). Used for the shield wall against projectiles
## (docs/abilities.md, section 4.4).
static func segment_box_fraction(a: Vector3, b: Vector3, box: Transform3D,
		half_extents: Vector3) -> float:
	var inverse: Transform3D = box.affine_inverse()
	var local_a: Vector3 = inverse * a
	var local_b: Vector3 = inverse * b
	var direction: Vector3 = local_b - local_a
	var enter: float = 0.0
	var leave: float = 1.0
	for axis: int in 3:
		var start: float = local_a[axis]
		var delta: float = direction[axis]
		var extent: float = half_extents[axis]
		if absf(delta) <= _EPSILON * _EPSILON:
			if start < -extent - _EPSILON or start > extent + _EPSILON:
				return -1.0
			continue
		var first: float = (-extent - start) / delta
		var second: float = (extent - start) / delta
		if first > second:
			var swap: float = first
			first = second
			second = swap
		enter = maxf(enter, first)
		leave = minf(leave, second)
		if enter > leave:
			return -1.0
	return enter


## true if the annular sector with height of [param shape], with its origin at [param origin] (the attacker's
## feet) and oriented according to [param yaw], touches the box [param box] of half dimensions
## [param half_extents] (docs/fortress.md, section 3.3: the fort gate as a target).
## [br][br]
## [param box] is the transform of the box's [b]center[/b]; only a rotation about the Y axis is allowed
## (or none): the height is taken from [code]box.origin.y ± half_extents.y[/code]. Edges count
## as contact. The same three conditions as [method sector_hits_capsule], but exact for the
## box's footprint rectangle: it is clipped with the two half-planes of the attack's cone and
## it is checked that some part of what remains lies between [code]inner_m[/code] and [code]range_m[/code]
## from the origin. A sector of 360° or more has no cone; one between 180° and 360° is the union of two
## half-planes.
static func sector_hits_box(origin: Vector3, yaw: float, shape: HitShape, box: Transform3D,
		half_extents: Vector3) -> bool:
	# Height.
	var box_bottom: float = box.origin.y - half_extents.y
	var box_top: float = box.origin.y + half_extents.y
	if origin.y + shape.height_min > box_top + _EPSILON \
			or origin.y + shape.height_max < box_bottom - _EPSILON:
		return false
	# Footprint rectangle (x, z) of the box, walked along the perimeter.
	var rectangle: Array[Vector2] = []
	for corner_signs: Vector2 in [Vector2(-1.0, -1.0), Vector2(1.0, -1.0), Vector2(1.0, 1.0),
			Vector2(-1.0, 1.0)]:
		var corner: Vector3 = box * Vector3(corner_signs.x * half_extents.x, 0.0,
				corner_signs.y * half_extents.z)
		rectangle.append(Vector2(corner.x, corner.z))
	var apex := Vector2(origin.x, origin.z)
	var forward3: Vector3 = Basis(Vector3.UP, yaw) * Vector3.FORWARD
	var forward := Vector2(forward3.x, forward3.z)
	var half_angle: float = deg_to_rad(shape.angle_deg) * 0.5
	var pieces: Array[Array] = []
	if half_angle >= PI - _EPSILON:
		pieces.append(rectangle)
	else:
		var ray_left: Vector2 = forward.rotated(half_angle)
		var ray_right: Vector2 = forward.rotated(-half_angle)
		# d inside the cone <=> cross(ray_right, d) >= 0 and cross(d, ray_left) >= 0.
		var normal_right := Vector2(-ray_right.y, ray_right.x)
		var normal_left := Vector2(ray_left.y, -ray_left.x)
		if half_angle <= PI * 0.5 + _EPSILON:
			var clipped: Array[Vector2] = _clip_to_half_plane(rectangle, apex, normal_right)
			clipped = _clip_to_half_plane(clipped, apex, normal_left)
			pieces.append(clipped)
		else:
			pieces.append(_clip_to_half_plane(rectangle, apex, normal_right))
			pieces.append(_clip_to_half_plane(rectangle, apex, normal_left))
	for piece: Array in pieces:
		if _polygon_reaches_ring(piece, apex, shape.inner_m, shape.range_m):
			return true
	return false


## true if the vertical capsule of [param radius] and [param height] resting at [param capsule_feet]
## overlaps the box [param box] (transform of its center, rotated only about Y) of half
## dimensions [param half_extents]. Used to know whether a character occupies the fort's gate
## opening (docs/fortress.md, section 3.3: the gate is not repaired while someone overlaps it).
static func capsule_overlaps_box(capsule_feet: Vector3, radius: float, height: float,
		box: Transform3D, half_extents: Vector3) -> bool:
	var local: Vector3 = box.affine_inverse() * capsule_feet
	if local.y > half_extents.y + _EPSILON or local.y + height < -half_extents.y - _EPSILON:
		return false
	var dx: float = maxf(absf(local.x) - half_extents.x, 0.0)
	var dz: float = maxf(absf(local.z) - half_extents.z, 0.0)
	return dx * dx + dz * dz <= radius * radius + _EPSILON


## true if there is nothing from the world (nor a fort's closed gate) between the attacker's chest
## and the victim's center.
## [param attacker_feet] and [param victim_feet] are the feet positions (the origin of each
## character); the function raises the ray's origin by [constant LINE_OF_SIGHT_FROM_HEIGHT] meters and its
## destination by [constant LINE_OF_SIGHT_TO_HEIGHT]. The ray only looks at the world and
## structure layers ([constant LINE_OF_SIGHT_MASK]), so characters and invisible blockers do not
## cut it.
## [param space] is the physics space of the current world (it is not rewound: walls do not
## move).
static func has_line_of_sight(space: PhysicsDirectSpaceState3D, attacker_feet: Vector3,
		victim_feet: Vector3) -> bool:
	var from: Vector3 = attacker_feet + Vector3(0.0, LINE_OF_SIGHT_FROM_HEIGHT, 0.0)
	var to: Vector3 = victim_feet + Vector3(0.0, LINE_OF_SIGHT_TO_HEIGHT, 0.0)
	return is_ray_clear(space, from, to)


## true if the ray from [param from] to [param to] does not hit the world or the structures
## ([constant LINE_OF_SIGHT_MASK]). Basis of [method has_line_of_sight] with the points already
## computed.
## [br][br]
## With [code]hit_from_inside[/code] (F6b and docs/abilities.md, section 4.4): a ray that [b]starts
## inside[/b] a convex shape hits at its origin. Without that, the owner of a fort with their feet in the opening
## of its closed gate (the chest ends up inside the 0.5 m sight box) would hit from inside whoever
## is outside without those outside seeing them, because a ray that starts inside a box ignores it;
## this way the closed gate cuts hits in both directions: from the opening you neither hit nor get hit.
## Concave meshes and terrain do not change (Godot has no "inside" for them).
static func is_ray_clear(space: PhysicsDirectSpaceState3D, from: Vector3, to: Vector3) -> bool:
	var query: PhysicsRayQueryParameters3D = PhysicsRayQueryParameters3D.create(from, to,
			LINE_OF_SIGHT_MASK)
	query.hit_from_inside = true
	return space.intersect_ray(query).is_empty()


## true if [param attacker_pos] is inside the defender's front cone of [param cone_deg] degrees (total
## angle, edge included), measured horizontally from their yaw. Used for the block
## and parry cones. An attacker right above the defender (no horizontal direction) counts
## as in front.
static func is_in_front(defender_pos: Vector3, defender_yaw: float, attacker_pos: Vector3,
		cone_deg: float) -> bool:
	var offset := Vector2(attacker_pos.x - defender_pos.x, attacker_pos.z - defender_pos.z)
	var distance: float = offset.length()
	if distance < _MIN_DIRECTION_LENGTH:
		return true
	var forward: Vector3 = Basis(Vector3.UP, defender_yaw) * Vector3.FORWARD
	var cos_angle: float = (forward.x * offset.x + forward.z * offset.y) / distance
	var angle: float = acos(clampf(cos_angle, -1.0, 1.0))
	return angle <= deg_to_rad(cone_deg) * 0.5 + _EPSILON


## Squared minimum distance between the segments [param p1]-[param q1] and
## [param p2]-[param q2] (Ericson, "Real-Time Collision Detection", 5.1.9), handling the cases of
## zero-length and parallel segments.
static func _segment_segment_distance_squared(p1: Vector3, q1: Vector3, p2: Vector3,
		q2: Vector3) -> float:
	var d1: Vector3 = q1 - p1
	var d2: Vector3 = q2 - p2
	var r: Vector3 = p1 - p2
	var a: float = d1.dot(d1)
	var e: float = d2.dot(d2)
	var f: float = d2.dot(r)
	var s: float = 0.0
	var t: float = 0.0
	if a <= _EPSILON and e <= _EPSILON:
		return r.dot(r)
	if a <= _EPSILON:
		t = clampf(f / e, 0.0, 1.0)
	else:
		var c: float = d1.dot(r)
		if e <= _EPSILON:
			s = clampf(-c / a, 0.0, 1.0)
		else:
			var b: float = d1.dot(d2)
			var denominator: float = a * e - b * b
			if denominator > _EPSILON:
				s = clampf((b * f - c * e) / denominator, 0.0, 1.0)
			t = (b * s + f) / e
			if t < 0.0:
				t = 0.0
				s = clampf(-c / a, 0.0, 1.0)
			elif t > 1.0:
				t = 1.0
				s = clampf((b - c) / a, 0.0, 1.0)
	var closest1: Vector3 = p1 + d1 * s
	var closest2: Vector3 = p2 + d2 * t
	var gap: Vector3 = closest1 - closest2
	return gap.dot(gap)


# Fraction of [code]a + direction · f[/code] (f in [0, 1]) at which the segment enters the sphere with
# center [param center] and radius² [param radius_squared], or -1 if it does not enter (or if [param a] is inside:
# the caller checks that).
static func _segment_sphere_entry(a: Vector3, direction: Vector3, center: Vector3,
		radius_squared: float) -> float:
	var quad_a: float = direction.dot(direction)
	if quad_a <= _EPSILON * _EPSILON:
		return -1.0
	var offset: Vector3 = a - center
	var quad_b: float = 2.0 * offset.dot(direction)
	var quad_c: float = offset.dot(offset) - radius_squared
	var discriminant: float = quad_b * quad_b - 4.0 * quad_a * quad_c
	if discriminant < 0.0:
		return -1.0
	var entry: float = (-quad_b - sqrt(discriminant)) / (2.0 * quad_a)
	if entry < 0.0 or entry > 1.0:
		return -1.0
	return entry


# Clips the convex polygon [param polygon] to the points p with dot(p - apex, normal) >= 0
# (Sutherland-Hodgman). Returns the resulting polygon (empty if nothing remains).
static func _clip_to_half_plane(polygon: Array[Vector2], apex: Vector2,
		normal: Vector2) -> Array[Vector2]:
	var result: Array[Vector2] = []
	var count: int = polygon.size()
	for i: int in count:
		var current: Vector2 = polygon[i]
		var next: Vector2 = polygon[(i + 1) % count]
		var current_side: float = (current - apex).dot(normal)
		var next_side: float = (next - apex).dot(normal)
		var current_inside: bool = current_side >= -_EPSILON
		var next_inside: bool = next_side >= -_EPSILON
		if current_inside:
			result.append(current)
		if current_inside != next_inside:
			var denominator: float = current_side - next_side
			if absf(denominator) > _EPSILON:
				result.append(current.lerp(next, current_side / denominator))
	return result


# true if any point of the convex polygon [param polygon] (vertices in order; it may be a point or
# a degenerate segment) is between [param inner] and [param outer] of the point [param apex].
static func _polygon_reaches_ring(polygon: Array[Vector2], apex: Vector2, inner: float,
		outer: float) -> bool:
	if polygon.is_empty():
		return false
	var farthest: float = 0.0
	for vertex: Vector2 in polygon:
		farthest = maxf(farthest, apex.distance_to(vertex))
	var nearest: float = INF
	if polygon.size() == 1:
		nearest = apex.distance_to(polygon[0])
	else:
		for i: int in polygon.size():
			var closest: Vector2 = Geometry2D.get_closest_point_to_segment(apex, polygon[i],
					polygon[(i + 1) % polygon.size()])
			nearest = minf(nearest, apex.distance_to(closest))
		if _polygon_contains(polygon, apex):
			nearest = 0.0
	return nearest <= outer + _EPSILON and farthest >= inner - _EPSILON


# true if [param point] is inside (or on the edge of) the convex polygon [param polygon] of at least
# 3 vertices, in either winding direction.
static func _polygon_contains(polygon: Array[Vector2], point: Vector2) -> bool:
	if polygon.size() < 3:
		return false
	var positive: bool = false
	var negative: bool = false
	for i: int in polygon.size():
		var a: Vector2 = polygon[i]
		var b: Vector2 = polygon[(i + 1) % polygon.size()]
		var side: float = (b - a).cross(point - a)
		if side > _EPSILON:
			positive = true
		elif side < -_EPSILON:
			negative = true
	return not (positive and negative)
