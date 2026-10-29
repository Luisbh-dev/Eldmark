extends TestCase
## Pruebas del mapa horneado de la zona (UI-20, docs/fuerte.md sección 6): la imagen y su escala existen y
## son coherentes ([ZoneMapDefinition]), los lugares fijos son los de la escena, el horneado es el que
## sale de la escena de hoy (si se cambia el relieve, el agua o las colisiones hay que repetir
## [code]tools/bake_zone_map.gd[/code]) y las piezas de [ZoneMapBaker] hacen lo que dicen.

const ZONE_ID: StringName = &"vado_gris"
const IMAGE_PATH: String = "res://assets/maps/vado_gris.png"
const DEFINITION_PATH: String = "res://assets/maps/vado_gris_map.tres"
## Diferencia media por canal (0 a 1) con la que se da por igual un horneado nuevo y el guardado, y
## fracción de píxeles que pueden distinguirse (el relieve de Linux y de Windows no es idéntico en la
## última cifra).
const MAX_MEAN_DIFFERENCE: float = 0.004
const MAX_DIFFERENT_FRACTION: float = 0.01

var _zone: Node3D = null


func after_each() -> void:
	if is_instance_valid(_zone):
		_zone.get_parent().remove_child(_zone)
		_zone.queue_free()
	_zone = null
	await wait_process_frames()


# --- El mapa guardado -------------------------------------------------------------------------

func test_the_baked_map_exists_with_its_scale() -> void:
	var definition: ZoneMapDefinition = ZoneMapDefinition.load_for_zone(ZONE_ID)
	if not assert_not_null(definition, "assets/maps/vado_gris_map.tres se carga"):
		return
	assert_eq(ZoneMapDefinition.definition_path(ZONE_ID), DEFINITION_PATH)
	assert_eq(ZoneMapDefinition.image_path_for(ZONE_ID), IMAGE_PATH)
	assert_eq(definition.zone_id, ZONE_ID)
	assert_eq(definition.image_path, IMAGE_PATH)
	assert_eq(definition.image_size, Vector2i(1024, 1024))
	assert_eq(definition.world_origin, Vector2(-160.0, -160.0), "el área jugable (±150 m) con 10 m de margen")
	assert_eq(definition.world_size, Vector2(320.0, 320.0))
	assert_near(definition.meters_per_pixel(), 0.3125, 1e-9, "320 m en 1024 píxeles")
	assert_eq(definition.pixels_per_meter(), Vector2(3.2, 3.2))
	var texture: Texture2D = definition.load_texture()
	if assert_not_null(texture, "la imagen está importada"):
		assert_eq(texture.get_size(), Vector2(1024.0, 1024.0), "la textura mide lo que dice la definición")
	var image: Image = _saved_image()
	if assert_not_null(image, "y su imagen se lee"):
		assert_eq(image.get_size(), Vector2i(1024, 1024))
	assert_true(FileAccess.file_exists(IMAGE_PATH), "el PNG está en assets/maps/")


func test_world_and_image_coordinates_convert_both_ways() -> void:
	var definition: ZoneMapDefinition = ZoneMapDefinition.load_for_zone(ZONE_ID)
	if not assert_not_null(definition):
		return
	assert_eq(definition.world_to_pixel(Vector3(-160.0, 5.0, -160.0)), Vector2.ZERO, "la esquina noroeste es el píxel 0, 0")
	assert_eq(definition.world_to_pixel(Vector3(160.0, 0.0, 160.0)), Vector2(1024.0, 1024.0), "y la sureste, el último")
	assert_eq(definition.world_to_pixel(Vector3(0.0, 0.0, 0.0)), Vector2(512.0, 512.0), "el centro del fuerte, en el centro")
	assert_true(definition.world_to_pixel(Vector3(0.0, 0.0, -100.0)).y < definition.world_to_pixel(Vector3(0.0, 0.0, 100.0)).y,
			"el norte (-Z) queda arriba")
	assert_true(definition.world_to_pixel(Vector3(100.0, 0.0, 0.0)).x > definition.world_to_pixel(Vector3(-100.0, 0.0, 0.0)).x,
			"y el este (+X) a la derecha")
	for point: Vector3 in [Vector3(12.5, 0.0, -33.0), Vector3(-150.0, 0.0, 149.0), Vector3(1.0, 0.0, 2.0)]:
		assert_vec_near(definition.pixel_to_world(definition.world_to_pixel(point)), point, 1e-4, "ida y vuelta de %s" % point)
		assert_vec_near(definition.uv_to_world(definition.world_to_uv(point)), point, 1e-4, "y por uv")
	assert_eq(definition.world_to_uv(Vector3(0.0, 0.0, 0.0)), Vector2(0.5, 0.5))
	assert_true(definition.contains(Vector3(0.0, 0.0, 0.0)))
	assert_true(definition.contains(Vector3(-160.0, 0.0, 160.0)), "el borde cuenta")
	assert_false(definition.contains(Vector3(161.0, 0.0, 0.0)))
	assert_false(definition.contains(Vector3(0.0, 0.0, -170.0)))
	assert_null(ZoneMapDefinition.load_for_zone(&"no_existe"), "una zona sin mapa da null")


func test_the_landmarks_are_the_ones_in_the_scene() -> void:
	await _load_zone()
	var definition: ZoneMapDefinition = ZoneMapDefinition.load_for_zone(ZONE_ID)
	if not assert_not_null(definition):
		return
	var forts: Array[MapLandmark] = definition.get_landmarks(MapLandmark.KIND_FORT)
	if assert_eq(forts.size(), 1, "un fuerte") and assert_not_null(_zone.get_node_or_null(^"Fuerte")):
		assert_vec_near(forts[0].position, (_zone.get_node(^"Fuerte") as Node3D).global_position, 1e-3, "en su sitio")
		assert_eq(forts[0].fortress_id, &"vado_gris_fort")
		assert_eq(forts[0].label, "Fuerte del Vado Gris")
	var camps: Array[MapLandmark] = definition.get_landmarks(MapLandmark.KIND_CAMP)
	assert_eq(camps.size(), 2, "un campamento por reino")
	for camp: MapLandmark in camps:
		var area: Node3D = _zone.get_node("SafeAreas/Campamento%s" % RealmCatalog.display_name(RealmCatalog.id_of_code(camp.realm))) as Node3D
		if assert_not_null(area, "la zona segura del reino %d" % camp.realm):
			assert_vec_near(camp.position, area.global_position, 1e-3, camp.label)
	var passes: Array[MapLandmark] = definition.get_landmarks(MapLandmark.KIND_PASS)
	assert_eq(passes.size(), 2, "una puerta por muralla")
	var gates: Array[Vector3] = [(_zone.get_node(^"Murallas/MuroDeEscarcha/Puerta") as Node3D).global_position,
			(_zone.get_node(^"Murallas/MurallaDelAlba/Puerta") as Node3D).global_position]
	for gate: Vector3 in gates:
		var found: bool = false
		for pass_landmark: MapLandmark in passes:
			found = found or pass_landmark.position.distance_to(gate) < 1e-3
		assert_true(found, "hay un paso en %s" % gate)
	for landmark: MapLandmark in definition.landmarks:
		assert_true(definition.contains(landmark.position), "%s cae dentro del mapa" % landmark.label)


func test_the_image_shows_water_structures_and_ground() -> void:
	var definition: ZoneMapDefinition = ZoneMapDefinition.load_for_zone(ZONE_ID)
	var image: Image = _saved_image()
	if not assert_not_null(definition) or not assert_not_null(image):
		return
	# El brazo norte del río (z = -62) es agua azul.
	var river: Color = _pixel(image, definition, Vector3(40.0, 0.0, -62.0))
	assert_true(river.b > river.r + 0.15 and river.b > river.g, "el río es azul (%s)" % river)
	# El camino de grava y el prado no lo son.
	var meadow: Color = _pixel(image, definition, Vector3(80.0, 0.0, -110.0))
	assert_true(meadow.g > meadow.b, "el prado es verdoso (%s)" % meadow)
	# La empalizada del fuerte (40 x 40 m, el borde sur está en z = 20 de su centro) deja un trazo oscuro.
	var found_outline: bool = false
	for step: int in range(-3, 4):
		var sample: Color = _pixel(image, definition, Vector3(float(step) * 0.3, 0.0, 20.0))
		if sample.get_luminance() < 0.2:
			found_outline = true
	assert_true(found_outline, "el borde de la empalizada se dibuja")
	# Dos puntos distintos de la imagen no son iguales: hay relieve y detalle, no un color liso.
	var distinct: Dictionary = {}
	for x: int in range(0, 1024, 64):
		for y: int in range(0, 1024, 64):
			distinct[image.get_pixel(x, y).to_html(false)] = true
	assert_true(distinct.size() > 40, "la imagen no es lisa (%d colores en 256 muestras)" % distinct.size())


# --- Horneado con la escena de hoy ------------------------------------------------------------

func test_baking_the_zone_again_gives_the_saved_map() -> void:
	await _load_zone()
	var saved: ZoneMapDefinition = ZoneMapDefinition.load_for_zone(ZONE_ID)
	var saved_image: Image = _saved_image()
	if not assert_not_null(saved) or not assert_not_null(saved_image):
		return
	var fresh: ZoneMapDefinition = ZoneMapBaker.build_definition(_zone, ZONE_ID, saved.world_origin,
			saved.world_size, saved.image_size)
	assert_eq(fresh.landmarks.size(), saved.landmarks.size(), "los mismos lugares fijos")
	for i: int in mini(fresh.landmarks.size(), saved.landmarks.size()):
		assert_eq(fresh.landmarks[i].label, saved.landmarks[i].label)
		assert_eq(fresh.landmarks[i].kind, saved.landmarks[i].kind)
		assert_eq(fresh.landmarks[i].realm, saved.landmarks[i].realm)
		assert_vec_near(fresh.landmarks[i].position, saved.landmarks[i].position, 1e-3, fresh.landmarks[i].label)
	var image: Image = ZoneMapBaker.bake(_zone, fresh)
	if not assert_not_null(image, "la zona se hornea"):
		return
	assert_eq(image.get_size(), saved_image.get_size())
	var total: float = 0.0
	var different: int = 0
	for y: int in image.get_height():
		for x: int in image.get_width():
			var a: Color = image.get_pixel(x, y)
			var b: Color = saved_image.get_pixel(x, y)
			var channel: float = (absf(a.r - b.r) + absf(a.g - b.g) + absf(a.b - b.b)) / 3.0
			total += channel
			if channel > 0.03:
				different += 1
	var count: float = float(image.get_width() * image.get_height())
	assert_true(total / count <= MAX_MEAN_DIFFERENCE,
			"el mapa guardado ya no es el de la escena: repite tools/bake_zone_map.gd (diferencia media %.5f)" % (total / count))
	assert_true(float(different) / count <= MAX_DIFFERENT_FRACTION,
			"y %.2f %% de los píxeles cambia" % (100.0 * float(different) / count))


# --- Piezas del horneador ---------------------------------------------------------------------

func test_box_and_cylinder_footprints() -> void:
	var box := BoxShape3D.new()
	box.size = Vector3(4.0, 2.0, 2.0)
	var turned: Transform3D = Transform3D(Basis(Vector3.UP, PI * 0.25), Vector3(10.0, 1.0, -5.0))
	var footprint: ZoneMapBaker.Footprint = ZoneMapBaker.footprint_of_shape(box, turned)
	if not assert_not_null(footprint, "una caja tiene contorno"):
		return
	assert_eq(footprint.polygon.size(), 4, "un rectángulo girado: cuatro vértices")
	assert_eq(footprint.kind, ZoneMapBaker.Footprint.BUILDING)
	var bounds := Rect2(footprint.polygon[0], Vector2.ZERO)
	for point: Vector2 in footprint.polygon:
		bounds = bounds.expand(point)
	# 4 x 2 girado 45°: la caja que lo contiene mide (4 + 2) / √2 de lado.
	assert_near(bounds.size.x, 6.0 / sqrt(2.0), 1e-4)
	assert_near(bounds.size.y, 6.0 / sqrt(2.0), 1e-4)
	assert_vec_near(bounds.get_center(), Vector2(10.0, -5.0), 1e-4, "centrado donde está la caja")

	var thin := CylinderShape3D.new()
	thin.radius = 0.4
	thin.height = 6.0
	var tree: ZoneMapBaker.Footprint = ZoneMapBaker.footprint_of_shape(thin, Transform3D(Basis(), Vector3(3.0, 3.0, 4.0)))
	assert_eq(tree.kind, ZoneMapBaker.Footprint.TREE, "un cilindro fino es un tronco")
	assert_eq(tree.polygon.size(), ZoneMapBaker.CIRCLE_SEGMENTS)
	var tree_radius: float = tree.polygon[0].distance_to(Vector2(3.0, 4.0))
	assert_near(tree_radius, ZoneMapBaker.TREE_DRAW_RADIUS, 1e-4, "se dibuja con un radio mínimo (la copa no se conoce)")
	var wide := CylinderShape3D.new()
	wide.radius = 2.0
	var rock: ZoneMapBaker.Footprint = ZoneMapBaker.footprint_of_shape(wide, Transform3D(Basis().scaled(Vector3(1.5, 1.0, 1.5)), Vector3.ZERO))
	assert_eq(rock.kind, ZoneMapBaker.Footprint.ROCK, "uno ancho es una roca")
	assert_near(rock.polygon[0].length(), 3.0, 1e-4, "y la escala del nodo cuenta")
	assert_null(ZoneMapBaker.footprint_of_shape(WorldBoundaryShape3D.new(), Transform3D()), "formas sin volumen no se dibujan")
	assert_null(ZoneMapBaker.footprint_of_shape(SphereShape3D.new(), Transform3D(Basis().scaled(Vector3.ZERO), Vector3.ZERO)), "con escala 0 no hay contorno")


func test_concave_and_convex_shapes_use_their_hull() -> void:
	var concave := ConcavePolygonShape3D.new()
	concave.set_faces(PackedVector3Array([
		Vector3(0, 0, 0), Vector3(10, 0, 0), Vector3(10, 0, 2),
		Vector3(0, 0, 0), Vector3(10, 0, 2), Vector3(0, 0, 2),
	]))
	var deck: ZoneMapBaker.Footprint = ZoneMapBaker.footprint_of_shape(concave, Transform3D(Basis(), Vector3(5.0, 1.0, 5.0)))
	assert_eq(deck.polygon.size(), 4, "un tablero: su rectángulo")
	var convex := ConvexPolygonShape3D.new()
	convex.points = PackedVector3Array([Vector3(0, 0, 0), Vector3(2, 0, 0), Vector3(0, 2, 0), Vector3(0, 0, 2), Vector3(1, 0, 1)])
	var ramp: ZoneMapBaker.Footprint = ZoneMapBaker.footprint_of_shape(convex, Transform3D())
	assert_eq(ramp.polygon.size(), 3, "el punto de dentro no es del casco")
	assert_eq(ZoneMapBaker.convex_hull(PackedVector2Array([Vector2(0, 0), Vector2(1, 1)])).size(), 0,
			"con menos de tres puntos no hay casco")


func test_baked_instances_become_wall_footprints_and_flat_meshes_are_skipped() -> void:
	var transforms: Array[Transform3D] = [
		Transform3D(Basis(), Vector3(1.0, 0.0, 1.0)),
		Transform3D(Basis(Vector3.UP, PI * 0.5), Vector3(10.0, 0.0, 1.0)),
	]
	var packed: PackedFloat32Array = BakedMultiMesh.pack_transforms(transforms)
	var tall: AABB = AABB(Vector3(-0.5, 0.0, -0.25), Vector3(1.0, 3.0, 0.5))
	var footprints: Array[ZoneMapBaker.Footprint] = ZoneMapBaker.footprints_of_instances(tall, packed,
			Transform3D(Basis(), Vector3(100.0, 0.0, 0.0)))
	assert_eq(footprints.size(), 2, "una por instancia")
	assert_eq(footprints[0].kind, ZoneMapBaker.Footprint.WALL)
	var first := Rect2(footprints[0].polygon[0], Vector2.ZERO)
	for point: Vector2 in footprints[0].polygon:
		first = first.expand(point)
	assert_vec_near(first.position, Vector2(100.5, 0.75), 1e-4, "con la transformación del nodo y la de la instancia")
	assert_vec_near(first.size, Vector2(1.0, 0.5), 1e-4)
	var turned := Rect2(footprints[1].polygon[0], Vector2.ZERO)
	for point: Vector2 in footprints[1].polygon:
		turned = turned.expand(point)
	assert_vec_near(turned.size, Vector2(0.5, 1.0), 1e-4, "la instancia girada 90° intercambia los ejes")
	var flat: AABB = AABB(Vector3(-1.0, -0.01, -1.0), Vector3(2.0, 0.02, 2.0))
	assert_true(ZoneMapBaker.footprints_of_instances(flat, packed, Transform3D()).is_empty(), "una losa plana no se dibuja")


func test_polygon_fill_and_outline_paint_the_right_pixels() -> void:
	var image: Image = Image.create_empty(20, 20, false, Image.FORMAT_RGB8)
	image.fill(Color.BLACK)
	var square: PackedVector2Array = PackedVector2Array([Vector2(4, 4), Vector2(12, 4), Vector2(12, 12), Vector2(4, 12)])
	ZoneMapBaker.fill_convex(image, square, Color.WHITE)
	assert_eq(image.get_pixel(8, 8), Color.WHITE, "dentro")
	assert_eq(image.get_pixel(2, 8), Color.BLACK, "fuera")
	assert_eq(image.get_pixel(14, 8), Color.BLACK)
	assert_eq(image.get_pixel(8, 2), Color.BLACK)
	var filled: int = 0
	for y: int in 20:
		for x: int in 20:
			if image.get_pixel(x, y) == Color.WHITE:
				filled += 1
	assert_true(filled >= 60 and filled <= 81, "unos 8 x 8 píxeles (%d)" % filled)
	ZoneMapBaker.draw_outline(image, square, Color.RED)
	assert_eq(image.get_pixel(4, 8), Color.RED, "el borde izquierdo")
	assert_eq(image.get_pixel(8, 4), Color.RED, "el superior")
	assert_eq(image.get_pixel(8, 8), Color.WHITE, "el interior sigue igual")
	# Los bordes y rellenos fuera de la imagen no rompen nada.
	ZoneMapBaker.fill_convex(image, PackedVector2Array([Vector2(-10, -10), Vector2(30, -10), Vector2(30, 30), Vector2(-10, 30)]), Color.BLUE)
	ZoneMapBaker.draw_outline(image, PackedVector2Array([Vector2(-5, -5), Vector2(40, 3), Vector2(3, 40)]), Color.GREEN)
	assert_eq(image.get_pixel(10, 10), Color.BLUE, "un relleno mayor que la imagen la cubre sin salirse")
	ZoneMapBaker.fill_convex(image, PackedVector2Array([Vector2(1, 1), Vector2(2, 2)]), Color.WHITE)


func test_every_texture_id_of_the_zone_has_a_ground_color() -> void:
	var assets: Terrain3DAssets = load("res://scenes/world/zones/vado_gris/vado_gris_terrain_assets.tres") as Terrain3DAssets
	if not assert_not_null(assets, "los activos del terreno del Vado Gris"):
		return
	for i: int in assets.get_texture_count():
		var texture: Terrain3DTextureAsset = assets.get_texture(i)
		assert_true(ZoneMapBaker.TEXTURE_COLORS.has(texture.id), "el suelo «%s» (id %d) tiene color en el mapa" % [texture.name, texture.id])


# --- Ayudantes --------------------------------------------------------------------------------

func _load_zone() -> void:
	var scene: PackedScene = load(Zones.get_scene_path(ZONE_ID)) as PackedScene
	_zone = scene.instantiate() as Node3D
	tree.root.add_child(_zone)
	await wait_physics_frames(2)


# La imagen guardada, leída de la textura importada (no del PNG suelto, que no valdría al exportar).
func _saved_image() -> Image:
	var texture: Texture2D = load(IMAGE_PATH) as Texture2D
	if texture == null:
		return null
	var image: Image = texture.get_image()
	if image != null and image.is_compressed():
		image.decompress()
	return image


func _pixel(image: Image, definition: ZoneMapDefinition, world: Vector3) -> Color:
	var pixel: Vector2 = definition.world_to_pixel(world)
	return image.get_pixel(clampi(floori(pixel.x), 0, image.get_width() - 1), clampi(floori(pixel.y), 0, image.get_height() - 1))
