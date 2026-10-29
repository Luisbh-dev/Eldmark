class_name ApproachRoutes
extends Resource
## Rutas de aproximación a un fuerte (docs/fuerte.md, sección 7), como datos compartidos:
## los puntos de paso (x, z) de cada ruta y de cada reino, desde su punto de aparición hasta la
## explanada delante de la puerta. Las siguen los bots de asedio ([code]BotBrain[/code], el
## patrón de asedio) y la comprueba [code]tools/terrain/verify_vado_gris_routes.gd[/code], que
## recorre cada una con el personaje real.
## [br][br]
## Datos del Vado Gris en [code]data/routes/vado_gris.tres[/code], que escribe
## [code]tools/terrain/export_vado_gris_routes.gd[/code]: dos rutas, el [constant BRIDGE] (directa y
## estrecha, por el puente propio) y el [constant FORD] (ancha y expuesta, por el vado), para
## Vardheim y para Solmarch (el reflejo z -> -z).
## [br][br]
## Los puntos son 2D (plano horizontal): quien los sigue sabe a qué altura está el suelo, y los bots
## que no simulan (SwarmBot) caminan en línea recta de un punto al siguiente.
## [br][br]
## Desde GUE-45 guarda también la pasarela del fuerte ([member walkway_height], [member walkway_path] y
## [member walkway_ramps]) por la que suben los bots de asedio que la guardan, con sus cálculos a lo largo de su eje
## ([method walkway_offset], [method walkway_point], [method walkway_post]...).
## [br][br]
## Compartido: no depende del cliente ni del servidor.

## Ruta directa y estrecha: campamento, puente propio, ladera, esquina del fuerte y puerta.
const BRIDGE: StringName = &"bridge"
## Ruta ancha y expuesta: campamento, llanura del flanco oeste, aldea, vado y puerta.
const FORD: StringName = &"ford"

## Zona a la que pertenecen las rutas.
@export var zone_id: StringName = &""
## Dónde está el fuerte al que llevan, en el plano horizontal (x, z): el centro de la vano de su puerta, el
## centro de su círculo de captura y el radio de este. Los bots que no cargan la zona ([code]SwarmBot[/code])
## no tienen otra manera de saberlo ([method SiegeView.set_places_from_routes]); los escribe el exportador
## con las constantes de la zona y [code]test_siege_zone[/code] comprueba que coinciden con los marcadores de
## la escena. (0, 0) y 0 = no se sabe.
@export var gate_point: Vector2 = Vector2.ZERO
@export var circle_point: Vector2 = Vector2.ZERO
@export var circle_radius: float = 0.0
## Tamaño del recinto del fuerte (F6b), medido desde la puerta: [code]x[/code] es la profundidad (de la puerta a la
## pared de enfrente, por el eje de la puerta hacia el círculo) y [code]y[/code] el ancho (la puerta en medio de su
## pared). Con él un bot sabe si está dentro de la empalizada o pegado a ella por fuera
## ([method SiegeView.is_inside_enclosure]). (0, 0) = no se sabe.
@export var enclosure_size: Vector2 = Vector2.ZERO
## Puntos de paso (x, z) de cada ruta y reino, con la clave [code]"<ruta>/<reino>"[/code] (por
## ejemplo [code]"bridge/vardheim"[/code]); ver [method key_for].
@export var points: Dictionary[String, PackedVector2Array] = {}
## Pasarela del fuerte (GUE-45): altura (y del mundo) de su suelo. 0 = no se sabe y los bots no suben.
@export var walkway_height: float = 0.0
## Eje de la pasarela (x, z), por el que andan los bots que la guardan: de la cima de una rampa a la de la otra pasando
## por encima de la puerta. La pasarela mide 2 m de ancho y no tiene barandilla por dentro: quien se aparta del eje más
## de unos 0,6 m cae al patio.
@export var walkway_path: PackedVector2Array = PackedVector2Array()
## Las rampas de la pasarela, cada una como una ruta (x, z) desde el patio hasta su cima: los puntos del patio por los
## que se llega a su pie sin chocar con la torre, el pie alineado con la rampa y la cima (el último punto, sobre
## [member walkway_path]). Las comprueba [code]tests/test_navmesh.gd[/code] con la malla de navegación de los PNJ
## (MUN-06) y las recorre con el personaje de verdad [code]tools/terrain/verify_vado_gris_routes.gd[/code].
@export var walkway_ramps: Array[PackedVector2Array] = []


## Clave de [member points] para la ruta [param route] del reino [param realm] (id de
## [RealmCatalog], por ejemplo [code]&"vardheim"[/code]).
static func key_for(route: StringName, realm: StringName) -> String:
	return "%s/%s" % [route, realm]


## Guarda los puntos de [param route] para [param realm].
func set_points(route: StringName, realm: StringName, route_points: PackedVector2Array) -> void:
	points[key_for(route, realm)] = route_points


## Puntos de paso (x, z) de [param route] para [param realm]; vacío si no existe esa ruta.
func get_points(route: StringName, realm: StringName) -> PackedVector2Array:
	return points.get(key_for(route, realm), PackedVector2Array())


## Igual que [method get_points] con el código de red del reino ([constant RealmCatalog.REALM_IDS]).
func get_points_for_code(route: StringName, realm_code: int) -> PackedVector2Array:
	return get_points(route, RealmCatalog.id_of_code(realm_code))


## true si el recurso sabe dónde están la puerta y el círculo del fuerte.
func has_places() -> bool:
	return circle_radius > 0.0


## true si hay una ruta [param route] para [param realm].
func has_route(route: StringName, realm: StringName) -> bool:
	return points.has(key_for(route, realm))


## Ids de las rutas que hay (sin repetir), ordenados.
func get_route_ids() -> Array[StringName]:
	var ids: Array[StringName] = []
	for key: String in points:
		var route: StringName = StringName(key.get_slice("/", 0))
		if not ids.has(route):
			ids.append(route)
	ids.sort_custom(func(a: StringName, b: StringName) -> bool: return String(a) < String(b))
	return ids


## Longitud (m) de una ruta recta entre sus puntos; 0 si no existe.
func get_length(route: StringName, realm: StringName) -> float:
	var route_points: PackedVector2Array = get_points(route, realm)
	var length: float = 0.0
	for i: int in range(1, route_points.size()):
		length += route_points[i - 1].distance_to(route_points[i])
	return length


## true si el recurso sabe dónde está la pasarela del fuerte y cómo se sube (GUE-45).
func has_walkway() -> bool:
	return walkway_height != 0.0 and walkway_path.size() >= 2 and not walkway_ramps.is_empty()


## Longitud (m) del eje de la pasarela.
func walkway_length() -> float:
	var length: float = 0.0
	for i: int in range(1, walkway_path.size()):
		length += walkway_path[i - 1].distance_to(walkway_path[i])
	return length


## Distancia (m, en el plano) de [param point] (x, z) al eje de la pasarela; INF sin pasarela.
func walkway_distance(point: Vector2) -> float:
	if walkway_path.size() < 2:
		return INF
	return point.distance_to(walkway_point(walkway_offset(point)))


## Dónde cae [param point] (x, z) a lo largo del eje de la pasarela: los metros desde su primer punto hasta el punto del
## eje más cercano a él. 0 sin pasarela.
func walkway_offset(point: Vector2) -> float:
	var best_distance: float = INF
	var best_offset: float = 0.0
	var walked: float = 0.0
	for i: int in range(1, walkway_path.size()):
		var a: Vector2 = walkway_path[i - 1]
		var b: Vector2 = walkway_path[i]
		var closest: Vector2 = Geometry2D.get_closest_point_to_segment(point, a, b)
		var distance: float = point.distance_to(closest)
		if distance < best_distance:
			best_distance = distance
			best_offset = walked + a.distance_to(closest)
		walked += a.distance_to(b)
	return best_offset


## El punto (x, z) del eje de la pasarela a [param offset] metros de su primer punto (recortado a sus extremos).
func walkway_point(offset: float) -> Vector2:
	if walkway_path.is_empty():
		return Vector2.ZERO
	var remaining: float = maxf(offset, 0.0)
	for i: int in range(1, walkway_path.size()):
		var length: float = walkway_path[i - 1].distance_to(walkway_path[i])
		if remaining <= length:
			return walkway_path[i - 1].lerp(walkway_path[i], remaining / length) if length > 0.0 else walkway_path[i]
		remaining -= length
	return walkway_path[walkway_path.size() - 1]


## Los metros desde el primer punto del eje de la pasarela hasta cada uno de sus puntos (el primero, 0).
func walkway_vertex_offsets() -> PackedFloat32Array:
	var offsets := PackedFloat32Array()
	var walked: float = 0.0
	for i: int in walkway_path.size():
		if i > 0:
			walked += walkway_path[i - 1].distance_to(walkway_path[i])
		offsets.append(walked)
	return offsets


## El puesto de la pasarela (x, z): el punto de su eje más cercano a la puerta, encima de ella. Vector2.ZERO sin
## pasarela o sin puerta.
func walkway_post() -> Vector2:
	if walkway_path.size() < 2 or not has_places():
		return Vector2.ZERO
	return walkway_point(walkway_offset(gate_point))


## Índice del punto de [param route] para [param realm] más cercano a [param position] (x, z), o
## -1 si no hay ruta. Sirve para retomar la ruta desde donde se esté.
func get_nearest_index(route: StringName, realm: StringName, position: Vector2) -> int:
	var route_points: PackedVector2Array = get_points(route, realm)
	var best: int = -1
	var best_distance: float = INF
	for i: int in route_points.size():
		var distance: float = route_points[i].distance_squared_to(position)
		if distance < best_distance:
			best_distance = distance
			best = i
	return best
