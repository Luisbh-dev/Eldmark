class_name ZoneMapBaker
extends RefCounted
## Hornea la imagen cenital de una zona sin GPU (docs/fuerte.md, sección 6; UI-20). La usa
## [code]tools/bake_zone_map.gd[/code]; las pruebas la usan con datos pequeños y con la zona entera.
## [br][br]
## Todo se calcula en la CPU a partir de los datos de la escena (nada se renderiza, así que vale en
## headless y da el mismo resultado en cualquier máquina):
## [br]- [b]Relieve[/b]: la altura de [code]Terrain3D.data.get_height[/code] en cada píxel, con
## sombreado de ladera (luz del noroeste) y un tinte según la altura.
## [br]- [b]Suelo[/b]: el color de la textura pintada en el terreno ([code]get_texture_id[/code]:
## base, superpuesta y mezcla) con una paleta propia por id de textura ([constant TEXTURE_COLORS]).
## [br]- [b]Agua[/b]: los triángulos de las mallas de los hijos del nodo [code]Agua[/code], proyectados
## sobre el plano (las MultiMesh no se leen en headless, pero la malla del río sí).
## [br]- [b]Estructuras[/b]: el contorno en planta de las colisiones estáticas de la capa del mundo
## (cajas, cilindros de troncos y rocas, mallas cóncavas y convexas) y de las instancias de los
## [BakedMultiMesh] (empalizada, murallas, postes), que en headless devuelven la identidad si se les
## pide el MultiMesh: se leen de [code]instance_transforms[/code]. Las capas de bloqueos invisibles,
## estructuras y reino quedan fuera.
## [br][br]
## Las medidas de la imagen y de la zona salen de la [ZoneMapDefinition] que se pasa. Los colores y
## el estilo son provisionales (arte de interfaz, ART-12).

## Capa del mundo estático, la única que se dibuja.
const WORLD_LAYER: int = 1
## Mallas repetidas más bajas que esto (m) no se dibujan (suelos y tableros).
const MIN_INSTANCE_HEIGHT: float = 0.15

## Color de cada textura del terreno del Vado Gris (ids de su Terrain3DAssets). Una zona con otros ids
## usa [constant UNKNOWN_TEXTURE_COLOR].
const TEXTURE_COLORS: Dictionary[int, Color] = {
	0: Color(0.45, 0.58, 0.32),
	1: Color(0.62, 0.60, 0.35),
	2: Color(0.56, 0.43, 0.31),
	3: Color(0.74, 0.72, 0.65),
	4: Color(0.52, 0.50, 0.50),
	5: Color(0.38, 0.55, 0.30),
	6: Color(0.40, 0.42, 0.46),
	7: Color(0.36, 0.33, 0.28),
	8: Color(0.88, 0.90, 0.92),
	9: Color(0.27, 0.26, 0.20),
}
const UNKNOWN_TEXTURE_COLOR: Color = Color(0.5, 0.5, 0.45)
const WATER_COLOR: Color = Color(0.20, 0.42, 0.62)
const WATER_OPACITY: float = 0.88
const WALL_FILL: Color = Color(0.36, 0.33, 0.30)
const BUILDING_FILL: Color = Color(0.44, 0.38, 0.32)
const OUTLINE: Color = Color(0.10, 0.09, 0.08)
const TREE_FILL: Color = Color(0.16, 0.34, 0.19)
const ROCK_FILL: Color = Color(0.55, 0.54, 0.55)
## Un cilindro de este radio (m) o más es una roca; menos, el tronco de un árbol.
const ROCK_MIN_RADIUS: float = 1.0
## Radio mínimo (m) con el que se dibuja el tronco de un árbol (la copa no se conoce).
const TREE_DRAW_RADIUS: float = 1.1
## Exageración del relieve en el sombreado y rango del brillo.
const RELIEF_EXAGGERATION: float = 2.2
const SHADE_MIN: float = 0.6
const SHADE_MAX: float = 1.35
## Hacia dónde está la luz (noroeste y arriba; norte = -Z).
const LIGHT_DIRECTION: Vector3 = Vector3(-0.55, 0.70, -0.55)
## Segmentos con los que se aproxima un círculo.
const CIRCLE_SEGMENTS: int = 14


## Contorno en planta de algo de la escena: un polígono convexo en coordenadas del mundo (x, z) y su
## clase, que decide cómo se dibuja.
class Footprint extends RefCounted:
	const WALL: StringName = &"wall"
	const BUILDING: StringName = &"building"
	const TREE: StringName = &"tree"
	const ROCK: StringName = &"rock"

	var polygon: PackedVector2Array = PackedVector2Array()
	var kind: StringName = BUILDING


	static func make(p_polygon: PackedVector2Array, p_kind: StringName) -> Footprint:
		var footprint := Footprint.new()
		footprint.polygon = p_polygon
		footprint.kind = p_kind
		return footprint


# --- Definición -------------------------------------------------------------------------------

## La [ZoneMapDefinition] de la zona en [param zone]: [param zone_id], el trozo de mundo
## ([param world_origin], [param world_size] en metros), el tamaño de la imagen y los lugares fijos
## que salen de la escena (el fuerte, los campamentos y las puertas de las murallas).
static func build_definition(zone: Node3D, zone_id: StringName, world_origin: Vector2,
		world_size: Vector2, image_size: Vector2i) -> ZoneMapDefinition:
	var definition := ZoneMapDefinition.new()
	definition.zone_id = zone_id
	definition.image_path = ZoneMapDefinition.image_path_for(zone_id)
	definition.world_origin = world_origin
	definition.world_size = world_size
	definition.image_size = image_size
	definition.landmarks = collect_landmarks(zone)
	# Ids de subrecurso fijos: el .tres sale igual en cada horneado (sin ellos Godot los sortea).
	for index: int in definition.landmarks.size():
		definition.landmarks[index].resource_scene_unique_id = "lugar%d" % index
	return definition


## Lugares fijos de la zona: el nodo de cada fortaleza, las zonas seguras con reino (los campamentos) y
## las puertas de las murallas ([code]Murallas/<muralla>/Puerta[/code]). Los nombres de las murallas
## son de la zona (tabla [constant WALL_PASSES]); hasta que las zonas declaren sus pasos, esto basta.
static func collect_landmarks(zone: Node3D) -> Array[MapLandmark]:
	var landmarks: Array[MapLandmark] = []
	for node: Node in zone.get_tree().get_nodes_in_group(Zones.FORTRESS_GROUP):
		var fort: Node3D = node as Node3D
		if fort == null or not zone.is_ancestor_of(fort):
			continue
		var definition: FortressDefinition = load(String(fort.get_meta(Zones.FORTRESS_DEFINITION_META, ""))) as FortressDefinition
		var label: String = definition.display_name if definition != null else "Fuerte"
		var fortress_id: StringName = definition.id if definition != null else &""
		landmarks.append(MapLandmark.make(MapLandmark.KIND_FORT, label, fort.global_position, 0, fortress_id))
	for area: Node3D in Zones.get_group_nodes(zone, Zones.SAFE_AREA_GROUP):
		var realm_code: int = RealmCatalog.code_of(Zones.get_spawn_realm(area))
		if realm_code <= 0:
			continue
		landmarks.append(MapLandmark.make(MapLandmark.KIND_CAMP,
				"Campamento de %s" % RealmCatalog.display_name(Zones.get_spawn_realm(area)),
				area.global_position, realm_code))
	var walls: Node = zone.get_node_or_null(^"Murallas")
	if walls != null:
		for wall: Node in walls.get_children():
			var gate: Node3D = wall.get_node_or_null(^"Puerta") as Node3D
			if gate == null or not WALL_PASSES.has(String(wall.name)):
				continue
			var entry: Array = WALL_PASSES[String(wall.name)]
			landmarks.append(MapLandmark.make(MapLandmark.KIND_PASS, String(entry[0]), gate.global_position,
					int(entry[1])))
	return landmarks


## Murallas del Vado Gris: nombre del nodo -> [nombre del paso, reino al que lleva (código de red)].
const WALL_PASSES: Dictionary = {
	"MuroDeEscarcha": ["Puerta del Muro de Escarcha", NetProtocol.Realm.VARDHEIM],
	"MurallaDelAlba": ["Puerta de la Muralla del Alba", NetProtocol.Realm.SOLMARCH],
}


# --- Horneado ---------------------------------------------------------------------------------

## Hornea la imagen del mapa de [param zone] (en el árbol) con las medidas de [param definition]. Devuelve
## null si la zona no tiene un [Terrain3D] con datos.
static func bake(zone: Node3D, definition: ZoneMapDefinition) -> Image:
	var terrain: Terrain3D = zone.get_node_or_null(^"Terrain3D") as Terrain3D
	if terrain == null or terrain.data == null:
		return null
	var width: int = definition.image_size.x
	var height: int = definition.image_size.y
	var heights: PackedFloat32Array = sample_heights(terrain, definition)
	var low: float = INF
	var high: float = -INF
	for value: float in heights:
		low = minf(low, value)
		high = maxf(high, value)
	var image: Image = Image.create_empty(width, height, false, Image.FORMAT_RGB8)
	var meters: float = definition.meters_per_pixel()
	var light: Vector3 = LIGHT_DIRECTION.normalized()
	var flat_light: float = light.y
	for y: int in height:
		for x: int in width:
			var h: float = heights[y * width + x]
			var left: float = heights[y * width + maxi(x - 1, 0)]
			var right: float = heights[y * width + mini(x + 1, width - 1)]
			var up: float = heights[maxi(y - 1, 0) * width + x]
			var down: float = heights[mini(y + 1, height - 1) * width + x]
			var slope_x: float = (right - left) / (2.0 * meters) * RELIEF_EXAGGERATION
			var slope_z: float = (down - up) / (2.0 * meters) * RELIEF_EXAGGERATION
			var normal: Vector3 = Vector3(-slope_x, 1.0, -slope_z).normalized()
			var shade: float = clampf(normal.dot(light) / flat_light, SHADE_MIN, SHADE_MAX)
			var tint: float = lerpf(0.84, 1.1, inverse_lerp(low, high, h))
			var world: Vector3 = definition.pixel_to_world(Vector2(x + 0.5, y + 0.5))
			var color: Color = ground_color(terrain, world) * (shade * tint)
			image.set_pixel(x, y, Color(color.r, color.g, color.b, 1.0))
	_draw_water(image, zone, definition)
	_draw_footprints(image, collect_footprints(zone), definition)
	return image


## Altura del terreno en el centro de cada píxel (metros), fila a fila. Donde Terrain3D no tiene datos
## (NAN) se usa la mínima de las demás.
static func sample_heights(terrain: Terrain3D, definition: ZoneMapDefinition) -> PackedFloat32Array:
	var width: int = definition.image_size.x
	var height: int = definition.image_size.y
	var heights := PackedFloat32Array()
	heights.resize(width * height)
	var lowest: float = INF
	var missing: Array[int] = []
	for y: int in height:
		for x: int in width:
			var world: Vector3 = definition.pixel_to_world(Vector2(x + 0.5, y + 0.5))
			var value: float = terrain.data.get_height(world)
			if is_nan(value):
				missing.append(y * width + x)
				value = 0.0
			else:
				lowest = minf(lowest, value)
			heights[y * width + x] = value
	if not missing.is_empty():
		var fill: float = lowest if is_finite(lowest) else 0.0
		for index: int in missing:
			heights[index] = fill
	return heights


## Color del suelo en [param world]: el de la textura base mezclado con el de la superpuesta según la
## mezcla pintada.
static func ground_color(terrain: Terrain3D, world: Vector3) -> Color:
	var ids: Vector3 = terrain.data.get_texture_id(world)
	var base: Color = TEXTURE_COLORS.get(roundi(ids.x), UNKNOWN_TEXTURE_COLOR)
	var overlay: Color = TEXTURE_COLORS.get(roundi(ids.y), UNKNOWN_TEXTURE_COLOR)
	return base.lerp(overlay, clampf(ids.z, 0.0, 1.0))


# --- Estructuras ------------------------------------------------------------------------------

## Contornos en planta de las colisiones estáticas de la capa del mundo bajo [param zone] y de las
## instancias de sus [BakedMultiMesh] (ver la descripción de la clase).
static func collect_footprints(zone: Node) -> Array[Footprint]:
	var footprints: Array[Footprint] = []
	for node: Node in zone.find_children("*", "CollisionShape3D", true, false):
		var collision: CollisionShape3D = node as CollisionShape3D
		var body: CollisionObject3D = collision.get_parent() as CollisionObject3D
		if collision.disabled or collision.shape == null or body == null \
				or (body.collision_layer & WORLD_LAYER) == 0:
			continue
		var footprint: Footprint = footprint_of_shape(collision.shape, collision.global_transform)
		if footprint != null:
			footprints.append(footprint)
	for node: Node in zone.find_children("*", "MultiMeshInstance3D", true, false):
		var baked: BakedMultiMesh = node as BakedMultiMesh
		if baked == null or baked.source_mesh == null:
			continue
		footprints.append_array(footprints_of_instances(baked.source_mesh.get_aabb(),
				baked.instance_transforms, baked.global_transform))
	return footprints


## Contorno en planta de una forma de colisión colocada en [param shape_transform] (mundo), o null si no
## se dibuja (terreno, formas sin volumen).
static func footprint_of_shape(shape: Shape3D, shape_transform: Transform3D) -> Footprint:
	var points := PackedVector2Array()
	var kind: StringName = Footprint.BUILDING
	if shape is BoxShape3D:
		points = _project_box((shape as BoxShape3D).size, shape_transform)
	elif shape is CylinderShape3D:
		var cylinder: CylinderShape3D = shape as CylinderShape3D
		var radius: float = cylinder.radius * _horizontal_scale(shape_transform)
		return _circle_footprint(Vector2(shape_transform.origin.x, shape_transform.origin.z), radius)
	elif shape is SphereShape3D:
		var sphere: SphereShape3D = shape as SphereShape3D
		return _circle_footprint(Vector2(shape_transform.origin.x, shape_transform.origin.z),
				sphere.radius * _horizontal_scale(shape_transform))
	elif shape is CapsuleShape3D:
		var capsule: CapsuleShape3D = shape as CapsuleShape3D
		return _circle_footprint(Vector2(shape_transform.origin.x, shape_transform.origin.z),
				capsule.radius * _horizontal_scale(shape_transform))
	elif shape is ConcavePolygonShape3D:
		for vertex: Vector3 in (shape as ConcavePolygonShape3D).get_faces():
			var world: Vector3 = shape_transform * vertex
			points.append(Vector2(world.x, world.z))
	elif shape is ConvexPolygonShape3D:
		for vertex: Vector3 in (shape as ConvexPolygonShape3D).points:
			var world: Vector3 = shape_transform * vertex
			points.append(Vector2(world.x, world.z))
	else:
		return null
	var hull: PackedVector2Array = convex_hull(points)
	if hull.size() < 3:
		return null
	return Footprint.make(hull, kind)


## Contornos de las instancias de una malla repetida: [param mesh_bounds] es la caja de la malla,
## [param packed_transforms] las transformaciones locales ([constant BakedMultiMesh.FLOATS_PER_INSTANCE]
## números por instancia) y [param node_transform] la del nodo. Las mallas más bajas que
## [constant MIN_INSTANCE_HEIGHT] no se dibujan.
static func footprints_of_instances(mesh_bounds: AABB, packed_transforms: PackedFloat32Array,
		node_transform: Transform3D) -> Array[Footprint]:
	var footprints: Array[Footprint] = []
	if mesh_bounds.size.y < MIN_INSTANCE_HEIGHT:
		return footprints
	var count: int = packed_transforms.size() / BakedMultiMesh.FLOATS_PER_INSTANCE
	for i: int in count:
		var k: int = i * BakedMultiMesh.FLOATS_PER_INSTANCE
		var basis := Basis(
				Vector3(packed_transforms[k], packed_transforms[k + 1], packed_transforms[k + 2]),
				Vector3(packed_transforms[k + 3], packed_transforms[k + 4], packed_transforms[k + 5]),
				Vector3(packed_transforms[k + 6], packed_transforms[k + 7], packed_transforms[k + 8]))
		var local := Transform3D(basis, Vector3(packed_transforms[k + 9], packed_transforms[k + 10],
				packed_transforms[k + 11]))
		var points := PackedVector2Array()
		for corner: int in 8:
			var world: Vector3 = node_transform * (local * mesh_bounds.get_endpoint(corner))
			points.append(Vector2(world.x, world.z))
		var hull: PackedVector2Array = convex_hull(points)
		if hull.size() >= 3:
			footprints.append(Footprint.make(hull, Footprint.WALL))
	return footprints


## Casco convexo de [param points] sin el vértice repetido del final (menos de 3 puntos distintos dan
## un polígono vacío).
static func convex_hull(points: PackedVector2Array) -> PackedVector2Array:
	var hull: PackedVector2Array = Geometry2D.convex_hull(points)
	if hull.size() > 1 and hull[0] == hull[hull.size() - 1]:
		hull.remove_at(hull.size() - 1)
	return hull if hull.size() >= 3 else PackedVector2Array()


static func _project_box(size: Vector3, shape_transform: Transform3D) -> PackedVector2Array:
	var points := PackedVector2Array()
	var half: Vector3 = size * 0.5
	for sign_x: float in [-1.0, 1.0]:
		for sign_y: float in [-1.0, 1.0]:
			for sign_z: float in [-1.0, 1.0]:
				var world: Vector3 = shape_transform * Vector3(half.x * sign_x, half.y * sign_y, half.z * sign_z)
				points.append(Vector2(world.x, world.z))
	return points


static func _horizontal_scale(shape_transform: Transform3D) -> float:
	var scale_value: Vector3 = shape_transform.basis.get_scale()
	return maxf(scale_value.x, scale_value.z)


static func _circle_footprint(center: Vector2, radius: float) -> Footprint:
	if radius <= 0.0:
		return null
	var polygon := PackedVector2Array()
	for i: int in CIRCLE_SEGMENTS:
		var angle: float = TAU * float(i) / float(CIRCLE_SEGMENTS)
		polygon.append(center + Vector2(cos(angle), sin(angle)) * radius)
	var kind: StringName = Footprint.ROCK if radius >= ROCK_MIN_RADIUS else Footprint.TREE
	if kind == Footprint.TREE and radius < TREE_DRAW_RADIUS:
		polygon.clear()
		for i: int in CIRCLE_SEGMENTS:
			var angle: float = TAU * float(i) / float(CIRCLE_SEGMENTS)
			polygon.append(center + Vector2(cos(angle), sin(angle)) * TREE_DRAW_RADIUS)
	return Footprint.make(polygon, kind)


# --- Dibujo -----------------------------------------------------------------------------------

# Pinta los triángulos de las mallas de los hijos del nodo «Agua» proyectados sobre el plano.
static func _draw_water(image: Image, zone: Node3D, definition: ZoneMapDefinition) -> void:
	var water: Node = zone.get_node_or_null(^"Agua")
	if water == null:
		return
	for node: Node in water.find_children("*", "MeshInstance3D", true, false):
		var instance: MeshInstance3D = node as MeshInstance3D
		if instance.mesh == null:
			continue
		for surface: int in instance.mesh.get_surface_count():
			var arrays: Array = instance.mesh.surface_get_arrays(surface)
			var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
			var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX] if arrays[Mesh.ARRAY_INDEX] != null \
					else PackedInt32Array()
			if indices.is_empty():
				for i: int in vertices.size():
					indices.append(i)
			for t: int in range(0, indices.size() - 2, 3):
				var a: Vector2 = definition.world_to_pixel(instance.global_transform * vertices[indices[t]])
				var b: Vector2 = definition.world_to_pixel(instance.global_transform * vertices[indices[t + 1]])
				var c: Vector2 = definition.world_to_pixel(instance.global_transform * vertices[indices[t + 2]])
				_fill_triangle(image, a, b, c, WATER_COLOR, WATER_OPACITY)


# Rellena un triángulo (píxeles) mezclando [param color] con lo que ya hay.
static func _fill_triangle(image: Image, a: Vector2, b: Vector2, c: Vector2, color: Color, opacity: float) -> void:
	var min_x: int = maxi(floori(minf(a.x, minf(b.x, c.x))), 0)
	var max_x: int = mini(ceili(maxf(a.x, maxf(b.x, c.x))), image.get_width() - 1)
	var min_y: int = maxi(floori(minf(a.y, minf(b.y, c.y))), 0)
	var max_y: int = mini(ceili(maxf(a.y, maxf(b.y, c.y))), image.get_height() - 1)
	var denominator: float = (b.y - c.y) * (a.x - c.x) + (c.x - b.x) * (a.y - c.y)
	if absf(denominator) < 1e-9:
		return
	for y: int in range(min_y, max_y + 1):
		for x: int in range(min_x, max_x + 1):
			var p := Vector2(x + 0.5, y + 0.5)
			var w1: float = ((b.y - c.y) * (p.x - c.x) + (c.x - b.x) * (p.y - c.y)) / denominator
			var w2: float = ((c.y - a.y) * (p.x - c.x) + (a.x - c.x) * (p.y - c.y)) / denominator
			var w3: float = 1.0 - w1 - w2
			if w1 >= 0.0 and w2 >= 0.0 and w3 >= 0.0:
				image.set_pixel(x, y, image.get_pixel(x, y).lerp(color, opacity))


# Pinta los contornos: primero los árboles y las rocas, luego las estructuras (con su borde oscuro).
static func _draw_footprints(image: Image, footprints: Array[Footprint], definition: ZoneMapDefinition) -> void:
	for pass_kinds: Array in [[Footprint.TREE, Footprint.ROCK], [Footprint.BUILDING], [Footprint.WALL]]:
		for footprint: Footprint in footprints:
			if not pass_kinds.has(footprint.kind):
				continue
			var polygon := PackedVector2Array()
			for point: Vector2 in footprint.polygon:
				polygon.append(definition.world_to_pixel(Vector3(point.x, 0.0, point.y)))
			var fill: Color = fill_color(footprint.kind)
			fill_convex(image, polygon, fill)
			draw_outline(image, polygon, OUTLINE if footprint.kind != Footprint.TREE else fill.darkened(0.35))


## Color de relleno de una clase de contorno.
static func fill_color(kind: StringName) -> Color:
	match kind:
		Footprint.TREE:
			return TREE_FILL
		Footprint.ROCK:
			return ROCK_FILL
		Footprint.WALL:
			return WALL_FILL
	return BUILDING_FILL


## Rellena un polígono convexo (en píxeles) con [param color].
static func fill_convex(image: Image, polygon: PackedVector2Array, color: Color) -> void:
	if polygon.size() < 3:
		return
	var min_y: float = INF
	var max_y: float = -INF
	for point: Vector2 in polygon:
		min_y = minf(min_y, point.y)
		max_y = maxf(max_y, point.y)
	for y: int in range(maxi(floori(min_y), 0), mini(ceili(max_y), image.get_height() - 1) + 1):
		var scan: float = y + 0.5
		var left: float = INF
		var right: float = -INF
		for i: int in polygon.size():
			var p: Vector2 = polygon[i]
			var q: Vector2 = polygon[(i + 1) % polygon.size()]
			if (p.y <= scan and q.y > scan) or (q.y <= scan and p.y > scan):
				var x: float = p.x + (scan - p.y) / (q.y - p.y) * (q.x - p.x)
				left = minf(left, x)
				right = maxf(right, x)
		if left > right:
			continue
		for x: int in range(maxi(roundi(left), 0), mini(roundi(right), image.get_width() - 1) + 1):
			image.set_pixel(x, y, color)


## Dibuja el borde de un polígono (en píxeles) con [param color], un píxel de grosor.
static func draw_outline(image: Image, polygon: PackedVector2Array, color: Color) -> void:
	for i: int in polygon.size():
		var p: Vector2 = polygon[i]
		var q: Vector2 = polygon[(i + 1) % polygon.size()]
		var steps: int = maxi(ceili(maxf(absf(q.x - p.x), absf(q.y - p.y)) * 2.0), 1)
		for s: int in steps + 1:
			var at: Vector2 = p.lerp(q, float(s) / float(steps))
			var x: int = floori(at.x)
			var y: int = floori(at.y)
			if x >= 0 and y >= 0 and x < image.get_width() and y < image.get_height():
				image.set_pixel(x, y, color)
