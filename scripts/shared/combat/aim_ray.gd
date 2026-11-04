class_name AimRay
extends RefCounted
## Canonical aiming for projectiles (docs/habilidades.md, section 4.4): the camera ray that
## comes out of [code]look_yaw[/code], [code]look_pitch[/code] and the shoulder bit
## ([constant PlayerInput.AIM_LEFT]), the aimed point with convergence to the depth of the hostile
## closest to the crosshair, the muzzle (the chest) and the inverse for bots and NPCs.
## [br][br]
## It is the same line as [code]CameraRig.get_aim_ray()[/code] without camera collision: the camera pivot
## is at the feet + [member CombatRules.aim_pivot_height] (the character's [code]CameraTarget[/code])
## and the camera is offset in its own plane with [code]h_offset[/code] (the shoulder,
## [member CombatRules.aim_shoulder_offset]) and [code]v_offset[/code]
## ([member CombatRules.aim_camera_v_offset]), which move the origin without rotating the ray; the arm and
## zoom move it along the ray and do not change the line. The canonical origin is that of the pivot's
## plane: what is behind the character does not count.
## [br][br]
## Shared and deterministic: used by the server (when firing), client prediction (the player's own
## arrow) and the bots.

## Height (m) above the feet of the center of a hostile that the crosshair converges to (the same as the
## line of sight of hits).
const TARGET_CENTER_HEIGHT: float = HitShapes.LINE_OF_SIGHT_TO_HEIGHT


## Canonical camera ray of a character with feet at [param feet]: basis
## [code]B = Basis(UP, look_yaw) · Basis(RIGHT, look_pitch)[/code], direction
## [code]D = B · FORWARD[/code] and origin
## [code]C = feet + (0, aim_pivot_height, 0) + B · (±aim_shoulder_offset, aim_camera_v_offset, 0)[/code]
## (right shoulder +, left −). Returns [code][C, D][/code] with [code]D[/code] a unit vector.
static func canonical(feet: Vector3, look_yaw: float, look_pitch: float,
		left_shoulder: bool) -> Array:
	var rules: CombatRules = CombatCatalog.rules()
	var look: Basis = _look_basis(look_yaw, look_pitch)
	var side: float = -1.0 if left_shoulder else 1.0
	var origin: Vector3 = feet + Vector3(0.0, rules.aim_pivot_height, 0.0) \
			+ look * Vector3(side * rules.aim_shoulder_offset, rules.aim_camera_v_offset, 0.0)
	return [origin, look * Vector3.FORWARD]


## Aimed point ([code]P = C + D · t[/code]) from [param origin] in the unit direction
## [param direction]. [code]t_m[/code] is the distance to the first collision with the world
## ([constant HitShapes.LINE_OF_SIGHT_MASK]) or [member CombatRules.aim_range_m]. If the ray hits a hostile's
## capsule (feet at [param capsule_feet]) before
## [code]t_m[/code], [code]t[/code] is that collision; otherwise, the hostile whose center (feet + [constant TARGET_CENTER_HEIGHT]) is within
## [member CombatRules.aim_converge_deg] of [code]D[/code], ahead and before [code]t_m[/code], and with
## the smallest angle (tie: the first in the list, which goes by net_id), gives its depth
## [code](H − C) · D[/code]; with none, [code]t = t_m[/code]. This way the arrow crosses the crosshair at the
## target's depth even if the crosshair points at the air in front of it. [param space] null = no
## world.
static func aim_point(space: PhysicsDirectSpaceState3D, origin: Vector3, direction: Vector3,
		capsule_feet: PackedVector3Array) -> Vector3:
	var rules: CombatRules = CombatCatalog.rules()
	var reach: float = rules.aim_range_m
	if space != null:
		var query: PhysicsRayQueryParameters3D = PhysicsRayQueryParameters3D.create(origin,
				origin + direction * reach, HitShapes.LINE_OF_SIGHT_MASK)
		var hit: Dictionary = space.intersect_ray(query)
		if not hit.is_empty():
			reach = maxf(((hit["position"] as Vector3) - origin).dot(direction), 0.0)
	# Direct hit on a capsule before the world.
	var end: Vector3 = origin + direction * reach
	var nearest: float = INF
	for feet: Vector3 in capsule_feet:
		var fraction: float = HitShapes.segment_capsule_fraction(origin, end, feet,
				HitShapes.CAPSULE_RADIUS, HitShapes.CAPSULE_HEIGHT)
		if fraction >= 0.0:
			nearest = minf(nearest, fraction * reach)
	if nearest < INF:
		return origin + direction * nearest
	# Convergence: the hostile closest to the crosshair within the cone.
	var limit: float = cos(deg_to_rad(rules.aim_converge_deg))
	var best_cos: float = -INF
	var best_depth: float = reach
	for feet: Vector3 in capsule_feet:
		var to_center: Vector3 = feet + Vector3(0.0, TARGET_CENTER_HEIGHT, 0.0) - origin
		var depth: float = to_center.dot(direction)
		if depth <= 0.0 or depth >= reach:
			continue
		var cos_angle: float = depth / to_center.length()
		if cos_angle >= limit and cos_angle > best_cos:
			best_cos = cos_angle
			best_depth = depth
	return origin + direction * best_depth


## Projectile muzzle: the chest, [code]feet + (0, muzzle_height, 0)[/code].
static func muzzle(feet: Vector3) -> Vector3:
	return feet + Vector3(0.0, CombatCatalog.rules().muzzle_height, 0.0)


## Inverse of [method canonical] for bots and NPCs: the [code](yaw, pitch)[/code] whose canonical ray
## (with feet at [param feet] and shoulder [param left_shoulder]) passes through [param point]. Closed-form
## solution: in the camera basis the point is at [code](±s, v, −t)[/code] from the pivot, with
## [code]t² = |Q|² − s² − v²[/code]; the pitch comes from the height and the yaw from the angle in the ground plane. If the
## point is within the camera offset (less than [code]√(s² + v²)[/code] from the pivot) there is
## no exact solution and it aims from the pivot. The yaw ends up in [code][−PI, PI][/code].
static func look_for(feet: Vector3, point: Vector3, left_shoulder: bool) -> Vector2:
	var rules: CombatRules = CombatCatalog.rules()
	var side: float = -rules.aim_shoulder_offset if left_shoulder else rules.aim_shoulder_offset
	var lift: float = rules.aim_camera_v_offset
	var target: Vector3 = point - feet - Vector3(0.0, rules.aim_pivot_height, 0.0)
	var depth_squared: float = target.length_squared() - side * side - lift * lift
	if depth_squared <= 0.0:
		var flat: float = Vector2(target.x, target.z).length()
		return Vector2(atan2(-target.x, -target.z), atan2(target.y, flat))
	var depth: float = sqrt(depth_squared)
	# Height: lift · cos(p) + depth · sin(p) = target.y.
	var radius: float = sqrt(lift * lift + depth * depth)
	var pitch: float = asin(clampf(target.y / radius, -1.0, 1.0)) - atan2(lift, depth)
	# Ground plane: the local vector (side, ·, lift · sin(p) − depth · cos(p)) rotated by the yaw must point
	# at (target.x, target.z); the rotation adds the yaw to the angle atan2(x, z).
	var local_z: float = lift * sin(pitch) - depth * cos(pitch)
	var yaw: float = atan2(target.x, target.z) - atan2(side, local_z)
	return Vector2(wrapf(yaw, -PI, PI), pitch)


static func _look_basis(look_yaw: float, look_pitch: float) -> Basis:
	return Basis(Vector3.UP, look_yaw) * Basis(Vector3.RIGHT, look_pitch)
