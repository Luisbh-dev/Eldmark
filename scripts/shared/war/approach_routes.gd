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
## Puntos de paso (x, z) de cada ruta y reino, con la clave [code]"<ruta>/<reino>"[/code] (por
## ejemplo [code]"bridge/vardheim"[/code]); ver [method key_for].
@export var points: Dictionary[String, PackedVector2Array] = {}


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
