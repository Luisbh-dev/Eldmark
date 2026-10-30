class_name AimRay
extends RefCounted
## Puntería canónica de los proyectiles (docs/habilidades.md, sección 4.4): el rayo de la cámara que
## sale de [code]look_yaw[/code], [code]look_pitch[/code] y el bit de hombro
## ([constant PlayerInput.AIM_LEFT]), el punto apuntado con la convergencia a la profundidad del
## hostil más cercano a la mira, la boca de salida (el pecho) y la inversa para bots y PNJ.
## [br][br]
## Es la misma línea que [code]CameraRig.get_aim_ray()[/code] sin colisión de la cámara: el pivote de
## la cámara está en los pies + [member CombatRules.aim_pivot_height] (el [code]CameraTarget[/code]
## del personaje) y la cámara se desplaza en su propio plano con [code]h_offset[/code] (el hombro,
## [member CombatRules.aim_shoulder_offset]) y [code]v_offset[/code]
## ([member CombatRules.aim_camera_v_offset]), que mueven el origen sin girar el rayo; el brazo y el
## zoom lo mueven a lo largo del rayo y no cambian la línea. El origen canónico es el del plano del
## pivote: lo que hay detrás del personaje no cuenta.
## [br][br]
## Compartido y determinista: lo usan el servidor (al disparar), la predicción del cliente (la flecha
## propia) y los bots.

## Altura (m) sobre los pies del centro de un hostil al que converge la mira (el mismo que la línea
## de visión de los golpes).
const TARGET_CENTER_HEIGHT: float = HitShapes.LINE_OF_SIGHT_TO_HEIGHT


## Rayo canónico de la cámara de un personaje con los pies en [param feet]: base
## [code]B = Basis(UP, look_yaw) · Basis(RIGHT, look_pitch)[/code], dirección
## [code]D = B · FORWARD[/code] y origen
## [code]C = feet + (0, aim_pivot_height, 0) + B · (±aim_shoulder_offset, aim_camera_v_offset, 0)[/code]
## (hombro derecho +, izquierdo −). Devuelve [code][C, D][/code] con [code]D[/code] unitaria.
static func canonical(feet: Vector3, look_yaw: float, look_pitch: float,
		left_shoulder: bool) -> Array:
	var rules: CombatRules = CombatCatalog.rules()
	var look: Basis = _look_basis(look_yaw, look_pitch)
	var side: float = -1.0 if left_shoulder else 1.0
	var origin: Vector3 = feet + Vector3(0.0, rules.aim_pivot_height, 0.0) \
			+ look * Vector3(side * rules.aim_shoulder_offset, rules.aim_camera_v_offset, 0.0)
	return [origin, look * Vector3.FORWARD]


## Punto apuntado ([code]P = C + D · t[/code]) desde [param origin] en la dirección unitaria
## [param direction]. [code]t_m[/code] es la distancia al primer choque con el mundo
## ([constant HitShapes.LINE_OF_SIGHT_MASK]) o [member CombatRules.aim_range_m]. Si el rayo toca antes
## de [code]t_m[/code] la cápsula de un hostil (pies en [param capsule_feet]), [code]t[/code] es ese
## choque; si no, el hostil cuyo centro (pies + [constant TARGET_CENTER_HEIGHT]) queda a menos de
## [member CombatRules.aim_converge_deg] de [code]D[/code], delante y antes de [code]t_m[/code], y con
## el menor ángulo (empate: el primero de la lista, que va por net_id), da su profundidad
## [code](H − C) · D[/code]; sin ninguno, [code]t = t_m[/code]. Así la flecha cruza la mira a la
## profundidad del blanco aunque la mira apunte al aire por delante de él. [param space] null = sin
## mundo.
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
	# Choque directo con una cápsula antes del mundo.
	var end: Vector3 = origin + direction * reach
	var nearest: float = INF
	for feet: Vector3 in capsule_feet:
		var fraction: float = HitShapes.segment_capsule_fraction(origin, end, feet,
				HitShapes.CAPSULE_RADIUS, HitShapes.CAPSULE_HEIGHT)
		if fraction >= 0.0:
			nearest = minf(nearest, fraction * reach)
	if nearest < INF:
		return origin + direction * nearest
	# Convergencia: el hostil más cercano a la mira dentro del cono.
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


## Boca de salida de los proyectiles: el pecho, [code]feet + (0, muzzle_height, 0)[/code].
static func muzzle(feet: Vector3) -> Vector3:
	return feet + Vector3(0.0, CombatCatalog.rules().muzzle_height, 0.0)


## Inversa de [method canonical] para bots y PNJ: el [code](yaw, pitch)[/code] cuyo rayo canónico
## (con los pies en [param feet] y el hombro [param left_shoulder]) pasa por [param point]. Solución
## cerrada: en la base de la cámara el punto está en [code](±s, v, −t)[/code] desde el pivote, con
## [code]t² = |Q|² − s² − v²[/code]; el pitch sale de la altura y el yaw del ángulo en planta. Si el
## punto está dentro del desplazamiento de la cámara (a menos de [code]√(s² + v²)[/code] del pivote) no
## hay solución exacta y apunta desde el pivote. El yaw queda en [code][−PI, PI][/code].
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
	# Altura: lift · cos(p) + depth · sin(p) = target.y.
	var radius: float = sqrt(lift * lift + depth * depth)
	var pitch: float = asin(clampf(target.y / radius, -1.0, 1.0)) - atan2(lift, depth)
	# Planta: el vector local (side, ·, lift · sin(p) − depth · cos(p)) girado por el yaw debe apuntar
	# a (target.x, target.z); el giro suma el yaw al ángulo atan2(x, z).
	var local_z: float = lift * sin(pitch) - depth * cos(pitch)
	var yaw: float = atan2(target.x, target.z) - atan2(side, local_z)
	return Vector2(wrapf(yaw, -PI, PI), pitch)


static func _look_basis(look_yaw: float, look_pitch: float) -> Basis:
	return Basis(Vector3.UP, look_yaw) * Basis(Vector3.RIGHT, look_pitch)
