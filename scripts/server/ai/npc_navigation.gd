class_name NpcNavigation
extends RefCounted
## Navegación de los PNJ en el servidor (docs/fuerte.md, sección 4.1; MUN-06).
## [br][br]
## Crea un mapa propio de [NavigationServer3D] (con iteraciones síncronas: nada del mapa de la escena, que
## el servidor no tiene), le pone la región de la malla horneada ([code]tools/bake_navmesh.gd[/code], con la
## puerta del fuerte [b]cerrada[/b]) y, por cada puerta, un enlace por el vano creado por RID. Después
## contesta [method get_path] con la ruta de un agente de un reino concreto.
## [br][br]
## [b]Capas de navegación.[/b] La región está en la capa [constant REGION_LAYER] (la miran todas las
## consultas). El enlace de la puerta está siempre activo, pero en la capa del reino [b]dueño[/b]
## ([method layer_of_realm]); cada consulta filtra con la capa de su reino ([method query_layers]), así que un
## agente solo cruza por el enlace si la puerta lo deja pasar físicamente: el dueño (y los Huecos, con el
## fuerte neutral, que no tienen capa de reino en su máscara de colisión) sí, los demás no. Con la puerta rota
## el enlace está en las capas de todos. El filtro es inmediato (no espera a ninguna iteración del mapa).
## [br][br]
## [b]Espera al mapa.[/b] Comprobado en Godot 4.7.2: la primera iteración del mapa sale vacía (las órdenes de
## la región se aplican después, aunque sea síncrono) y las rutas buenas llegan unos pasos de física más
## tarde; consultar el mapa antes de su primera iteración registra un error del motor. Por eso
## [method poll] da el mapa por listo solo cuando una consulta de prueba devuelve un punto de la malla, y
## [method get_path] devuelve una ruta vacía hasta entonces. Quien lo lleva llama a [method poll] en cada
## tick hasta que devuelva true.
## [br][br]
## Libera sus RID con [method dispose] (hay que llamarla: un objeto que se destruye en su destructor no puede
## llamar a sus propios métodos).

## Capa de la región: la incluyen todas las consultas.
const REGION_LAYER: int = 1
## Capas de los reinos: la del bando neutral (los Huecos) y la de cada reino (1 a 3) son los bits 1 a 4.
const REALM_LAYER_SHIFT: int = 1
const REALM_LAYERS_MASK: int = 0b11110
## Puntos del enlace de una puerta respecto a su origen (centro del vano a ras de suelo, interior hacia +X):
## 2,5 m dentro y 3 m fuera, fuera del grosor de la puerta y del radio del agente.
const GATE_INSIDE_OFFSET: Vector3 = Vector3(2.5, 0.0, 0.0)
const GATE_OUTSIDE_OFFSET: Vector3 = Vector3(-3.0, 0.0, 0.0)
## Distancia (m) a la que la consulta de prueba debe devolver el vértice de prueba para dar el mapa por listo.
const PROBE_TOLERANCE: float = 1.0
## Una ruta llega a su destino si acaba a menos de esto (m) en horizontal y en vertical.
const REACH_XZ: float = 1.0
const REACH_Y: float = 1.5

## Un enlace por el vano de una puerta.
class GateLink:
	extends RefCounted

	var id: StringName = &""
	## Punto del lado de dentro y del de fuera, tal como se pidieron (se proyectan sobre la malla al crear
	## el enlace).
	var inside: Vector3 = Vector3.ZERO
	var outside: Vector3 = Vector3.ZERO
	var rid: RID = RID()
	var owner_realm: int = 0
	var broken: bool = false

var _map: RID = RID()
var _region: RID = RID()
var _links: Dictionary[StringName, GateLink] = {}
var _probe: Vector3 = Vector3.ZERO
var _ready: bool = false
var _params: NavigationPathQueryParameters3D = NavigationPathQueryParameters3D.new()
var _result: NavigationPathQueryResult3D = NavigationPathQueryResult3D.new()
var _paths_computed: int = 0


## Capa de navegación del reino [param realm] (código de red; 0 = neutral, los Huecos): un bit entre el 1 y el 4.
static func layer_of_realm(realm: int) -> int:
	return 1 << (REALM_LAYER_SHIFT + clampi(realm, 0, 3))


## Capas con las que consulta un agente del reino [param realm]: la de la región y la de su reino.
static func query_layers(realm: int) -> int:
	return REGION_LAYER | layer_of_realm(realm)


## true si la ruta [param path] acaba a menos de [constant REACH_XZ] (en horizontal) y [constant REACH_Y]
## (en vertical) de [param target].
static func path_reaches(path: PackedVector3Array, target: Vector3) -> bool:
	if path.is_empty():
		return false
	var end: Vector3 = path[path.size() - 1]
	return Vector2(end.x - target.x, end.z - target.z).length() <= REACH_XZ \
			and absf(end.y - target.y) <= REACH_Y


## Crea el mapa y la región con la malla [param navmesh] (en la posición [param region_transform]). Devuelve
## false si no hay malla o no tiene polígonos. Solo se puede llamar una vez.
func setup(navmesh: NavigationMesh, region_transform: Transform3D = Transform3D.IDENTITY) -> bool:
	if _map.is_valid() or navmesh == null or navmesh.get_polygon_count() == 0 \
			or navmesh.get_vertices().is_empty():
		return false
	_probe = region_transform * navmesh.get_vertices()[0]
	_map = NavigationServer3D.map_create()
	NavigationServer3D.map_set_cell_size(_map, navmesh.cell_size)
	NavigationServer3D.map_set_cell_height(_map, navmesh.cell_height)
	NavigationServer3D.map_set_up(_map, Vector3.UP)
	NavigationServer3D.map_set_use_async_iterations(_map, false)
	NavigationServer3D.map_set_active(_map, true)
	_region = NavigationServer3D.region_create()
	NavigationServer3D.region_set_map(_region, _map)
	NavigationServer3D.region_set_navigation_layers(_region, REGION_LAYER)
	NavigationServer3D.region_set_navigation_mesh(_region, navmesh)
	NavigationServer3D.region_set_transform(_region, region_transform)
	NavigationServer3D.region_set_enabled(_region, true)
	return true


## Añade el enlace por el vano de la puerta [param id]: de [param inside] (dentro del fuerte) a
## [param outside], en los dos sentidos. Sus extremos se proyectan sobre la malla cuando el mapa está listo
## (antes no se puede consultar). El enlace empieza en la capa de los Huecos (fuerte neutral, puerta entera).
func add_gate_link(id: StringName, inside: Vector3, outside: Vector3) -> void:
	if not _map.is_valid() or _links.has(id):
		return
	var link := GateLink.new()
	link.id = id
	link.inside = inside
	link.outside = outside
	_links[id] = link
	if _ready:
		_create_link(link)


## Como [method add_gate_link] para una puerta cuyo origen está en [param gate_transform] (el centro del vano a
## ras de suelo, con el interior del fuerte hacia +X): [constant GATE_INSIDE_OFFSET] y
## [constant GATE_OUTSIDE_OFFSET] dan los dos extremos.
func add_gate_link_at(id: StringName, gate_transform: Transform3D) -> void:
	add_gate_link(id, gate_transform * GATE_INSIDE_OFFSET, gate_transform * GATE_OUTSIDE_OFFSET)


## Pone el estado de la puerta [param id]: dueño del fuerte (0 = neutral) y si está rota. El enlace pasa a
## la capa del dueño (a las de todos si está rota); el filtro de las consultas lo deja pasar solo a esos
## agentes. Se puede llamar antes de que el mapa esté listo.
func set_gate_state(id: StringName, owner_realm: int, broken: bool) -> void:
	var link: GateLink = _links.get(id)
	if link == null:
		return
	link.owner_realm = owner_realm
	link.broken = broken
	if link.rid.is_valid():
		NavigationServer3D.link_set_navigation_layers(link.rid, _link_layers(link))


## Capas de navegación que tiene ahora el enlace de la puerta [param id] (0 si no existe).
func get_gate_layers(id: StringName) -> int:
	var link: GateLink = _links.get(id)
	return _link_layers(link) if link != null else 0


## Comprueba si el mapa ya da rutas de verdad (una consulta de prueba devuelve un punto de la malla) y, la
## primera vez que lo hace, crea los enlaces de las puertas. Devuelve true si está listo. Barato: no consulta
## nada antes de la primera iteración del mapa (registraría un error del motor).
func poll() -> bool:
	if _ready:
		return true
	if not _map.is_valid() or NavigationServer3D.map_get_iteration_id(_map) == 0:
		return false
	if NavigationServer3D.map_get_closest_point(_map, _probe).distance_to(_probe) > PROBE_TOLERANCE:
		return false
	_ready = true
	for link: GateLink in _links.values():
		_create_link(link)
	return true


## true si el mapa ya dio por buena una consulta de prueba ([method poll]).
func is_ready() -> bool:
	return _ready


## Ruta de [param from] a [param to] para un agente del reino [param realm] (código de red; 0 = Huecos): la
## lista de puntos de la ruta, o vacía si el mapa aún no está listo. Si no hay camino, acaba en el punto
## alcanzable más cercano al destino ([method path_reaches] dice si llega de verdad).
func get_path(from: Vector3, to: Vector3, realm: int) -> PackedVector3Array:
	if not _ready:
		return PackedVector3Array()
	_params.map = _map
	_params.start_position = from
	_params.target_position = to
	_params.navigation_layers = query_layers(realm)
	_paths_computed += 1
	NavigationServer3D.query_path(_params, _result)
	return _result.path


## El punto de la malla más cercano a [param position], o la propia posición si el mapa no está listo.
func closest_point(position: Vector3) -> Vector3:
	if not _ready:
		return position
	return NavigationServer3D.map_get_closest_point(_map, position)


## Rutas calculadas desde que existe (para medir).
func get_paths_computed() -> int:
	return _paths_computed


## El mapa de navegación (RID), para quien necesite consultas más finas; inválido antes de [method setup].
func get_map() -> RID:
	return _map


## Libera el enlace de cada puerta, la región y el mapa. Se puede llamar más de una vez.
func dispose() -> void:
	for link: GateLink in _links.values():
		if link.rid.is_valid():
			NavigationServer3D.free_rid(link.rid)
			link.rid = RID()
	_links.clear()
	if _region.is_valid():
		NavigationServer3D.free_rid(_region)
		_region = RID()
	if _map.is_valid():
		NavigationServer3D.free_rid(_map)
		_map = RID()
	_ready = false


func _create_link(link: GateLink) -> void:
	link.rid = NavigationServer3D.link_create()
	NavigationServer3D.link_set_map(link.rid, _map)
	NavigationServer3D.link_set_start_position(link.rid,
			NavigationServer3D.map_get_closest_point(_map, link.inside))
	NavigationServer3D.link_set_end_position(link.rid,
			NavigationServer3D.map_get_closest_point(_map, link.outside))
	NavigationServer3D.link_set_bidirectional(link.rid, true)
	NavigationServer3D.link_set_navigation_layers(link.rid, _link_layers(link))
	NavigationServer3D.link_set_enabled(link.rid, true)


# Capas del enlace: las de todos los reinos si la puerta está rota; si no, la del dueño.
func _link_layers(link: GateLink) -> int:
	return REALM_LAYERS_MASK if link.broken else layer_of_realm(link.owner_realm)
