class_name HitShapes
extends RefCounted
## Geometría de los golpes (docs/combate.md, sección 4.1): matemática pura, sin cuerpos de física,
## salvo la línea de visión, que lanza un rayo contra el mundo.
## [br][br]
## Todas las pruebas son de un volumen contra una cápsula vertical (la del personaje: radio
## [constant CAPSULE_RADIUS] y altura [constant CAPSULE_HEIGHT] medidos desde los pies). La
## orientación sigue la convención de [member PlayerCharacter.yaw]: yaw 0 mira hacia -Z.
## [br][br]
## Compartido: lo usan el servidor (compensación de latencia), la puntería y los proyectiles
## (docs/habilidades.md, sección 4.4: [method segment_capsule_fraction] y
## [method segment_box_fraction]) y las pruebas; no depende de nada del cliente.

## Radio de la cápsula de un personaje (m), igual que el nodo [code]Collision[/code].
const CAPSULE_RADIUS: float = 0.4
## Altura de la cápsula de un personaje desde los pies (m).
const CAPSULE_HEIGHT: float = 1.8
## Altura sobre los pies del atacante desde la que sale el rayo de la línea de visión (el pecho).
const LINE_OF_SIGHT_FROM_HEIGHT: float = 1.4
## Altura sobre los pies de la víctima a la que llega el rayo de la línea de visión (su centro).
const LINE_OF_SIGHT_TO_HEIGHT: float = 0.9
## Capas contra las que se lanza el rayo de la línea de visión: la del mundo (capa 1) y la de las
## estructuras (capa 4, el cuerpo de vista de la puerta del fuerte: no para a nadie, pero no se
## ve ni se golpea a través de ella).
const LINE_OF_SIGHT_MASK: int = PlayerCharacter.WORLD_COLLISION_LAYER | PlayerCharacter.STRUCTURE_LAYER

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


## Fracción (0 a 1) del segmento de [param a] a [param b] en la que entra por primera vez en la
## cápsula vertical de [param radius] y [param height] que apoya en [param capsule_feet] (el mismo
## volumen que [method segment_hits_capsule]), o -1 si no la toca. Si [param a] ya está dentro,
## 0 (docs/habilidades.md, sección 4.4: un proyectil que empieza su tick dentro de una cápsula).
## La cápsula es la unión de un cilindro y dos esferas: la entrada es la primera de las tres.
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
	# Lateral del cilindro (eje vertical): solo cuenta si la entrada cae entre los dos centros.
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
	# Las dos semiesferas.
	for center: Vector3 in [axis_a, axis_b]:
		var entry_sphere: float = _segment_sphere_entry(a, direction, center, radius_squared)
		if entry_sphere >= 0.0:
			best = minf(best, entry_sphere)
	return best if best <= 1.0 else -1.0


## Fracción (0 a 1) del segmento de [param a] a [param b] en la que entra en la caja [param box]
## (transformación de su centro; puede girar en cualquier eje) de medias dimensiones
## [param half_extents], o -1 si no la toca; 0 si [param a] ya está dentro o en el borde (método de
## las franjas en el espacio de la caja). Sirve para el muro de escudos que para proyectiles
## (docs/habilidades.md, sección 4.4).
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


## true si el sector anular con altura de [param shape], con su origen en [param origin] (los pies
## del atacante) y orientado según [param yaw], toca la caja [param box] de medias dimensiones
## [param half_extents] (docs/fuerte.md, sección 3.3: la puerta del fuerte como blanco).
## [br][br]
## [param box] es la transformación del [b]centro[/b] de la caja; solo se admite un giro en el eje Y
## (o ninguno): la altura se toma de [code]box.origin.y ± half_extents.y[/code]. Los bordes cuentan
## como contacto. Mismas tres condiciones que [method sector_hits_capsule], pero exactas para el
## rectángulo en planta de la caja: se recorta con las dos semiplanos del cono del ataque y se
## comprueba que alguna parte de lo que queda esté entre [code]inner_m[/code] y [code]range_m[/code]
## del origen. Un sector de 360° o más no tiene cono; uno de entre 180° y 360° es la unión de dos
## semiplanos.
static func sector_hits_box(origin: Vector3, yaw: float, shape: HitShape, box: Transform3D,
		half_extents: Vector3) -> bool:
	# Altura.
	var box_bottom: float = box.origin.y - half_extents.y
	var box_top: float = box.origin.y + half_extents.y
	if origin.y + shape.height_min > box_top + _EPSILON \
			or origin.y + shape.height_max < box_bottom - _EPSILON:
		return false
	# Rectángulo en planta (x, z) de la caja, recorrido por el perímetro.
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
		# d dentro del cono <=> cross(ray_right, d) >= 0 y cross(d, ray_left) >= 0.
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


## true si la cápsula vertical de [param radius] y [param height] que apoya en [param capsule_feet]
## solapa la caja [param box] (transformación de su centro, con giro solo en Y) de medias
## dimensiones [param half_extents]. Sirve para saber si un personaje ocupa el vano de la puerta del
## fuerte (docs/fuerte.md, sección 3.3: no se repara la puerta mientras alguien lo solape).
static func capsule_overlaps_box(capsule_feet: Vector3, radius: float, height: float,
		box: Transform3D, half_extents: Vector3) -> bool:
	var local: Vector3 = box.affine_inverse() * capsule_feet
	if local.y > half_extents.y + _EPSILON or local.y + height < -half_extents.y - _EPSILON:
		return false
	var dx: float = maxf(absf(local.x) - half_extents.x, 0.0)
	var dz: float = maxf(absf(local.z) - half_extents.z, 0.0)
	return dx * dx + dz * dz <= radius * radius + _EPSILON


## true si no hay nada del mundo (ni la puerta cerrada de un fuerte) entre el pecho del atacante
## y el centro de la víctima.
## [param attacker_feet] y [param victim_feet] son las posiciones de los pies (el origen de cada
## personaje); la función sube el origen del rayo [constant LINE_OF_SIGHT_FROM_HEIGHT] metros y su
## destino [constant LINE_OF_SIGHT_TO_HEIGHT]. El rayo solo mira las capas del mundo y de las
## estructuras ([constant LINE_OF_SIGHT_MASK]), así que los personajes y los bloqueos invisibles no
## lo cortan.
## [param space] es el espacio de física del mundo actual (no se rebobina: las paredes no se
## mueven).
static func has_line_of_sight(space: PhysicsDirectSpaceState3D, attacker_feet: Vector3,
		victim_feet: Vector3) -> bool:
	var from: Vector3 = attacker_feet + Vector3(0.0, LINE_OF_SIGHT_FROM_HEIGHT, 0.0)
	var to: Vector3 = victim_feet + Vector3(0.0, LINE_OF_SIGHT_TO_HEIGHT, 0.0)
	return is_ray_clear(space, from, to)


## true si el rayo de [param from] a [param to] no choca con el mundo ni con las estructuras
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


# Fracción de [code]a + direction · f[/code] (f en [0, 1]) en la que el segmento entra en la esfera de
# centro [param center] y radio² [param radius_squared], o -1 si no entra (o si [param a] está dentro:
# eso lo mira quien llama).
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


# Recorta el polígono convexo [param polygon] a los puntos p con dot(p - apex, normal) >= 0
# (Sutherland-Hodgman). Devuelve el polígono resultante (vacío si no queda nada).
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


# true si algún punto del polígono convexo [param polygon] (vértices en orden; puede ser un punto o
# un segmento degenerado) está entre [param inner] y [param outer] del punto [param apex].
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


# true si [param point] está dentro (o en el borde) del polígono convexo [param polygon] de al menos
# 3 vértices, en cualquier sentido de giro.
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
