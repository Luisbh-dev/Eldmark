class_name HitShapes
extends RefCounted
## Geometría de los golpes (docs/combate.md, sección 4.1): matemática pura, sin cuerpos de física,
## salvo la línea de visión, que lanza un rayo contra el mundo.
## [br][br]
## Todas las pruebas son de un volumen contra una cápsula vertical (la del personaje: radio
## [constant CAPSULE_RADIUS] y altura [constant CAPSULE_HEIGHT] medidos desde los pies). La
## orientación sigue la convención de [member PlayerCharacter.yaw]: yaw 0 mira hacia -Z.
## [br][br]
## Compartido: lo usan el servidor (compensación de latencia) y las pruebas; no depende de nada
## del cliente.

## Radio de la cápsula de un personaje (m), igual que el nodo [code]Collision[/code].
const CAPSULE_RADIUS: float = 0.4
## Altura de la cápsula de un personaje desde los pies (m).
const CAPSULE_HEIGHT: float = 1.8
## Altura sobre los pies del atacante desde la que sale el rayo de la línea de visión (el pecho).
const LINE_OF_SIGHT_FROM_HEIGHT: float = 1.4
## Altura sobre los pies de la víctima a la que llega el rayo de la línea de visión (su centro).
const LINE_OF_SIGHT_TO_HEIGHT: float = 0.9
## Capa de física contra la que se lanza el rayo de la línea de visión: la del mundo (capa 1).
const LINE_OF_SIGHT_MASK: int = PlayerCharacter.WORLD_COLLISION_LAYER

## Por debajo de esta distancia horizontal dos puntos se consideran en el mismo sitio, y no hay
## dirección entre ellos.
const _MIN_DIRECTION_LENGTH: float = 0.0001
## Tolerancia de las comparaciones de punto flotante en los bordes (m y radianes).
const _EPSILON: float = 0.000001


## true si el sector anular con altura de [param shape], con su origen en [param origin] (los pies
## del atacante) y orientado según [param yaw], toca la cápsula vertical de [param radius] y
## [param height] que apoya en [param capsule_feet].
## [br][br]
## Tres condiciones a la vez, con los bordes incluidos:
## [br]- distancia horizontal entre el origen y el eje de la cápsula en
## [code][inner_m - radius, range_m + radius][/code];
## [br]- ángulo entre el yaw del atacante y la dirección al eje de la cápsula como mucho
## [code]angle_deg / 2 + asin(radius / d)[/code] (el disco de la cápsula visto desde el origen
## subtiende [code]asin(radius / d)[/code]); si el origen cae dentro del disco
## ([code]d <= radius[/code]) no hay dirección y el ángulo no cuenta;
## [br]- solape vertical de [code][height_min, height_max][/code] sobre los pies del atacante con
## [code][0, height][/code] sobre los pies de la cápsula.
static func sector_hits_capsule(origin: Vector3, yaw: float, shape: HitShape,
		capsule_feet: Vector3, radius: float, height: float) -> bool:
	# Altura.
	var shape_bottom: float = origin.y + shape.height_min
	var shape_top: float = origin.y + shape.height_max
	if shape_bottom > capsule_feet.y + height + _EPSILON or shape_top < capsule_feet.y - _EPSILON:
		return false
	# Distancia horizontal al eje.
	var offset := Vector2(capsule_feet.x - origin.x, capsule_feet.z - origin.z)
	var distance: float = offset.length()
	if distance > shape.range_m + radius + _EPSILON:
		return false
	if distance < shape.inner_m - radius - _EPSILON:
		return false
	# Ángulo. Con el origen dentro del disco de la cápsula no hay dirección que comparar.
	if distance <= radius:
		return true
	var forward: Vector3 = Basis(Vector3.UP, yaw) * Vector3.FORWARD
	var cos_angle: float = (forward.x * offset.x + forward.z * offset.y) / distance
	var angle: float = acos(clampf(cos_angle, -1.0, 1.0))
	var limit: float = deg_to_rad(shape.angle_deg) * 0.5 + asin(clampf(radius / distance, 0.0, 1.0))
	return angle <= limit + _EPSILON


## true si el segmento de [param a] a [param b] (un proyectil en un tick, por ejemplo) toca la
## cápsula vertical de [param radius] y [param height] que apoya en [param capsule_feet]: la
## distancia entre el segmento y el eje de la cápsula (de la altura del radio a la altura total
## menos el radio) es como mucho el radio. Funciona con un segmento de longitud 0.
static func segment_hits_capsule(a: Vector3, b: Vector3, capsule_feet: Vector3, radius: float,
		height: float) -> bool:
	# Eje de la cápsula: el segmento entre los centros de las dos semiesferas. Una cápsula más
	# baja que dos radios se reduce a un punto a media altura.
	var bottom_y: float = capsule_feet.y + minf(radius, height * 0.5)
	var top_y: float = capsule_feet.y + maxf(height - radius, height * 0.5)
	var axis_a := Vector3(capsule_feet.x, bottom_y, capsule_feet.z)
	var axis_b := Vector3(capsule_feet.x, top_y, capsule_feet.z)
	var squared: float = _segment_segment_distance_squared(a, b, axis_a, axis_b)
	return squared <= radius * radius + _EPSILON


## true si no hay nada del mundo entre el pecho del atacante y el centro de la víctima.
## [param attacker_feet] y [param victim_feet] son las posiciones de los pies (el origen de cada
## personaje); la función sube el origen del rayo [constant LINE_OF_SIGHT_FROM_HEIGHT] metros y su
## destino [constant LINE_OF_SIGHT_TO_HEIGHT]. El rayo solo mira la capa del mundo
## ([constant LINE_OF_SIGHT_MASK]), así que los personajes y los bloqueos invisibles no lo cortan.
## [param space] es el espacio de física del mundo actual (no se rebobina: las paredes no se
## mueven).
static func has_line_of_sight(space: PhysicsDirectSpaceState3D, attacker_feet: Vector3,
		victim_feet: Vector3) -> bool:
	var from: Vector3 = attacker_feet + Vector3(0.0, LINE_OF_SIGHT_FROM_HEIGHT, 0.0)
	var to: Vector3 = victim_feet + Vector3(0.0, LINE_OF_SIGHT_TO_HEIGHT, 0.0)
	return is_ray_clear(space, from, to)


## true si el rayo de [param from] a [param to] no choca con la capa del mundo
## ([constant LINE_OF_SIGHT_MASK]). Base de [method has_line_of_sight] con los puntos ya
## calculados.
static func is_ray_clear(space: PhysicsDirectSpaceState3D, from: Vector3, to: Vector3) -> bool:
	var query: PhysicsRayQueryParameters3D = PhysicsRayQueryParameters3D.create(from, to,
			LINE_OF_SIGHT_MASK)
	return space.intersect_ray(query).is_empty()


## true si [param attacker_pos] está dentro del cono frontal de [param cone_deg] grados (ángulo
## total, borde incluido) del defensor, medido en horizontal desde su yaw. Sirve para los conos
## de bloqueo y de parada. Un atacante justo encima del defensor (sin dirección horizontal) cuenta
## como delante.
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


## Cuadrado de la distancia mínima entre los segmentos [param p1]-[param q1] y
## [param p2]-[param q2] (Ericson, «Real-Time Collision Detection», 5.1.9), con los casos de
## segmentos de longitud 0 y paralelos.
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
