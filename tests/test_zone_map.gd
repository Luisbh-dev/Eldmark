extends TestCase
## Tests of the zone's baked map (UI-20, docs/fortress.md section 6): the image and its scale exist and
## are consistent ([ZoneMapDefinition]), the fixed places are those of the scene, the bake is the one that
## comes out of today's scene (if the relief, the water or the collisions change, you must repeat
## [code]tools/map/bake_parchment_map.gd[/code], UI-51) and the [ZoneMapBaker] pieces do what they say.

const ZONE_ID: StringName = &"vado_gris"
const IMAGE_PATH: String = "res://assets/maps/vado_gris.png"
const DEFINITION_PATH: String = "res://assets/maps/vado_gris_map.tres"
## Mean difference per channel (0 to 1) below which a new bake and the saved one are considered equal, and
## the fraction of pixels that may differ (the relief on Linux and Windows is not identical in the
## last digit).
const MAX_MEAN_DIFFERENCE: float = 0.004
const MAX_DIFFERENT_FRACTION: float = 0.01

var _zone: Node3D = null


func after_each() -> void:
	if is_instance_valid(_zone):
		_zone.get_parent().remove_child(_zone)
		_zone.queue_free()
	_zone = null
	await wait_process_frames()


# --- The saved map ----------------------------------------------------------------------------

func test_the_baked_map_exists_with_its_scale() -> void:
	var definition: ZoneMapDefinition = ZoneMapDefinition.load_for_zone(ZONE_ID)
	if not assert_not_null(definition, "assets/maps/vado_gris_map.tres loads"):
		return
	assert_eq(ZoneMapDefinition.definition_path(ZONE_ID), DEFINITION_PATH)
	assert_eq(ZoneMapDefinition.image_path_for(ZONE_ID), IMAGE_PATH)
	assert_eq(definition.zone_id, ZONE_ID)
	assert_eq(definition.image_path, IMAGE_PATH)
	assert_eq(definition.image_size, Vector2i(2048, 2048))
	assert_eq(definition.world_origin, Vector2(-200.0, -200.0), "±200 m: the playable valley (±150 m) and the mountains that frame it")
	assert_eq(definition.world_size, Vector2(400.0, 400.0))
	assert_near(definition.meters_per_pixel(), 0.1953125, 1e-9, "400 m over 2048 pixels")
	assert_eq(definition.pixels_per_meter(), Vector2(5.12, 5.12))
	var texture: Texture2D = definition.load_texture()
	if assert_not_null(texture, "the image is imported"):
		assert_eq(texture.get_size(), Vector2(2048.0, 2048.0), "the texture measures what the definition says")
	var image: Image = _saved_image()
	if assert_not_null(image, "and its image can be read"):
		assert_eq(image.get_size(), Vector2i(2048, 2048))
	assert_true(FileAccess.file_exists(IMAGE_PATH), "the PNG is in assets/maps/")


func test_world_and_image_coordinates_convert_both_ways() -> void:
	var definition: ZoneMapDefinition = ZoneMapDefinition.load_for_zone(ZONE_ID)
	if not assert_not_null(definition):
		return
	assert_eq(definition.world_to_pixel(Vector3(-200.0, 5.0, -200.0)), Vector2.ZERO, "the northwest corner is pixel 0, 0")
	assert_eq(definition.world_to_pixel(Vector3(200.0, 0.0, 200.0)), Vector2(2048.0, 2048.0), "and the southeast one, the last")
	assert_eq(definition.world_to_pixel(Vector3(0.0, 0.0, 0.0)), Vector2(1024.0, 1024.0), "the fort's center, at the center")
	assert_true(definition.world_to_pixel(Vector3(0.0, 0.0, -100.0)).y < definition.world_to_pixel(Vector3(0.0, 0.0, 100.0)).y,
			"north (-Z) is up")
	assert_true(definition.world_to_pixel(Vector3(100.0, 0.0, 0.0)).x > definition.world_to_pixel(Vector3(-100.0, 0.0, 0.0)).x,
			"and east (+X) to the right")
	for point: Vector3 in [Vector3(12.5, 0.0, -33.0), Vector3(-150.0, 0.0, 149.0), Vector3(1.0, 0.0, 2.0)]:
		assert_vec_near(definition.pixel_to_world(definition.world_to_pixel(point)), point, 1e-4, "ida y vuelta de %s" % point)
		assert_vec_near(definition.uv_to_world(definition.world_to_uv(point)), point, 1e-4, "and by uv")
	assert_eq(definition.world_to_uv(Vector3(0.0, 0.0, 0.0)), Vector2(0.5, 0.5))
	assert_true(definition.contains(Vector3(0.0, 0.0, 0.0)))
	assert_true(definition.contains(Vector3(-200.0, 0.0, 200.0)), "the edge counts")
	assert_false(definition.contains(Vector3(201.0, 0.0, 0.0)))
	assert_false(definition.contains(Vector3(0.0, 0.0, -210.0)))
	assert_null(ZoneMapDefinition.load_for_zone(&"no_existe"), "a zone without a map gives null")


func test_the_landmarks_are_the_ones_in_the_scene() -> void:
	await _load_zone()
	var definition: ZoneMapDefinition = ZoneMapDefinition.load_for_zone(ZONE_ID)
	if not assert_not_null(definition):
		return
	var forts: Array[MapLandmark] = definition.get_landmarks(MapLandmark.KIND_FORT)
	if assert_eq(forts.size(), 1, "un fuerte") and assert_not_null(_zone.get_node_or_null(^"Fuerte")):
		assert_vec_near(forts[0].position, (_zone.get_node(^"Fuerte") as Node3D).global_position, 1e-3, "in its place")
		assert_eq(forts[0].fortress_id, &"vado_gris_fort")
		assert_eq(forts[0].label, "Fuerte del Vado Gris")
	var camps: Array[MapLandmark] = definition.get_landmarks(MapLandmark.KIND_CAMP)
	assert_eq(camps.size(), 2, "one camp per realm")
	for camp: MapLandmark in camps:
		var area: Node3D = _zone.get_node("SafeAreas/Campamento%s" % RealmCatalog.display_name(RealmCatalog.id_of_code(camp.realm))) as Node3D
		if assert_not_null(area, "the safe zone of realm %d" % camp.realm):
			assert_vec_near(camp.position, area.global_position, 1e-3, camp.label)
	var passes: Array[MapLandmark] = definition.get_landmarks(MapLandmark.KIND_PASS)
	assert_eq(passes.size(), 2, "one gate per wall")
	var gates: Array[Vector3] = [(_zone.get_node(^"Murallas/MuroDeEscarcha/Puerta") as Node3D).global_position,
			(_zone.get_node(^"Murallas/MurallaDelAlba/Puerta") as Node3D).global_position]
	for gate: Vector3 in gates:
		var found: bool = false
		for pass_landmark: MapLandmark in passes:
			found = found or pass_landmark.position.distance_to(gate) < 1e-3
		assert_true(found, "there is a pass at %s" % gate)
	for landmark: MapLandmark in definition.landmarks:
		assert_true(definition.contains(landmark.position), "%s falls inside the map" % landmark.label)


func test_the_image_shows_water_structures_and_ground() -> void:
	var definition: ZoneMapDefinition = ZoneMapDefinition.load_for_zone(ZONE_ID)
	var image: Image = _saved_image()
	if not assert_not_null(definition) or not assert_not_null(image):
		return
	# The river's north arm (z = -62) is blue water.
	var river: Color = _pixel(image, definition, Vector3(40.0, 0.0, -62.0))
	assert_true(river.b > river.r + 0.15 and river.b > river.g, "the river is blue (%s)" % river)
	# The gravel path and the meadow are not.
	var meadow: Color = _pixel(image, definition, Vector3(80.0, 0.0, -110.0))
	assert_true(meadow.g > meadow.b, "the meadow is greenish (%s)" % meadow)
	# The fort's palisade (drawn 1.5 times larger: its south edge falls at z = 30) leaves a dark stroke.
	var found_outline: bool = false
	for step: int in range(-3, 4):
		var sample: Color = _pixel(image, definition, Vector3(float(step) * 0.3, 0.0, 30.0))
		if sample.get_luminance() < 0.2:
			found_outline = true
	assert_true(found_outline, "the palisade's edge is drawn")
	# Two different points of the image are not equal: there is relief and detail, not a flat color.
	var distinct: Dictionary = {}
	for x: int in range(0, 2048, 128):
		for y: int in range(0, 2048, 128):
			distinct[image.get_pixel(x, y).to_html(false)] = true
	assert_true(distinct.size() > 40, "the image is not flat (%d colors in 256 samples)" % distinct.size())


# --- Bake with today's scene ------------------------------------------------------------------

func test_baking_the_zone_again_gives_the_saved_map() -> void:
	await _load_zone()
	var saved: ZoneMapDefinition = ZoneMapDefinition.load_for_zone(ZONE_ID)
	var saved_image: Image = _saved_image()
	if not assert_not_null(saved) or not assert_not_null(saved_image):
		return
	var fresh: ZoneMapDefinition = ZoneMapBaker.build_definition(_zone, ZONE_ID, saved.world_origin,
			saved.world_size, saved.image_size)
	assert_eq(fresh.landmarks.size(), saved.landmarks.size(), "the same fixed places")
	for i: int in mini(fresh.landmarks.size(), saved.landmarks.size()):
		assert_eq(fresh.landmarks[i].label, saved.landmarks[i].label)
		assert_eq(fresh.landmarks[i].kind, saved.landmarks[i].kind)
		assert_eq(fresh.landmarks[i].realm, saved.landmarks[i].realm)
		assert_vec_near(fresh.landmarks[i].position, saved.landmarks[i].position, 1e-3, fresh.landmarks[i].label)
	var image: Image = ParchmentMapBaker.bake(_zone, fresh)
	if not assert_not_null(image, "the zone bakes"):
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
			"the saved map is no longer the scene's: repeat tools/map/bake_parchment_map.gd (mean difference %.5f)" % (total / count))
	assert_true(float(different) / count <= MAX_DIFFERENT_FRACTION,
			"and %.2f %% of the pixels change" % (100.0 * float(different) / count))


# --- Baker pieces -----------------------------------------------------------------------------

func test_box_and_cylinder_footprints() -> void:
	var box := BoxShape3D.new()
	box.size = Vector3(4.0, 2.0, 2.0)
	var turned: Transform3D = Transform3D(Basis(Vector3.UP, PI * 0.25), Vector3(10.0, 1.0, -5.0))
	var footprint: ZoneMapBaker.Footprint = ZoneMapBaker.footprint_of_shape(box, turned)
	if not assert_not_null(footprint, "a box has an outline"):
		return
	assert_eq(footprint.polygon.size(), 4, "a rotated rectangle: four vertices")
	assert_eq(footprint.kind, ZoneMapBaker.Footprint.BUILDING)
	var bounds := Rect2(footprint.polygon[0], Vector2.ZERO)
	for point: Vector2 in footprint.polygon:
		bounds = bounds.expand(point)
	# 4 x 2 rotated 45°: the box that contains it measures (4 + 2) / √2 per side.
	assert_near(bounds.size.x, 6.0 / sqrt(2.0), 1e-4)
	assert_near(bounds.size.y, 6.0 / sqrt(2.0), 1e-4)
	assert_vec_near(bounds.get_center(), Vector2(10.0, -5.0), 1e-4, "centered where the box is")

	var thin := CylinderShape3D.new()
	thin.radius = 0.4
	thin.height = 6.0
	var tree: ZoneMapBaker.Footprint = ZoneMapBaker.footprint_of_shape(thin, Transform3D(Basis(), Vector3(3.0, 3.0, 4.0)))
	assert_eq(tree.kind, ZoneMapBaker.Footprint.TREE, "a thin cylinder is a trunk")
	assert_eq(tree.polygon.size(), ZoneMapBaker.CIRCLE_SEGMENTS)
	var tree_radius: float = tree.polygon[0].distance_to(Vector2(3.0, 4.0))
	assert_near(tree_radius, ZoneMapBaker.TREE_DRAW_RADIUS, 1e-4, "it is drawn with a minimum radius (the canopy is not known)")
	var wide := CylinderShape3D.new()
	wide.radius = 2.0
	var rock: ZoneMapBaker.Footprint = ZoneMapBaker.footprint_of_shape(wide, Transform3D(Basis().scaled(Vector3(1.5, 1.0, 1.5)), Vector3.ZERO))
	assert_eq(rock.kind, ZoneMapBaker.Footprint.ROCK, "a wide one is a rock")
	assert_near(rock.polygon[0].length(), 3.0, 1e-4, "and the node's scale counts")
	assert_null(ZoneMapBaker.footprint_of_shape(WorldBoundaryShape3D.new(), Transform3D()), "shapes without volume are not drawn")
	assert_null(ZoneMapBaker.footprint_of_shape(SphereShape3D.new(), Transform3D(Basis().scaled(Vector3.ZERO), Vector3.ZERO)), "with scale 0 there is no outline")


func test_concave_and_convex_shapes_use_their_hull() -> void:
	var concave := ConcavePolygonShape3D.new()
	concave.set_faces(PackedVector3Array([
		Vector3(0, 0, 0), Vector3(10, 0, 0), Vector3(10, 0, 2),
		Vector3(0, 0, 0), Vector3(10, 0, 2), Vector3(0, 0, 2),
	]))
	var deck: ZoneMapBaker.Footprint = ZoneMapBaker.footprint_of_shape(concave, Transform3D(Basis(), Vector3(5.0, 1.0, 5.0)))
	assert_eq(deck.polygon.size(), 4, "a board: its rectangle")
	var convex := ConvexPolygonShape3D.new()
	convex.points = PackedVector3Array([Vector3(0, 0, 0), Vector3(2, 0, 0), Vector3(0, 2, 0), Vector3(0, 0, 2), Vector3(1, 0, 1)])
	var ramp: ZoneMapBaker.Footprint = ZoneMapBaker.footprint_of_shape(convex, Transform3D())
	assert_eq(ramp.polygon.size(), 3, "the point inside is not on the hull")
	assert_eq(ZoneMapBaker.convex_hull(PackedVector2Array([Vector2(0, 0), Vector2(1, 1)])).size(), 0,
			"with fewer than three points there is no hull")


func test_baked_instances_become_wall_footprints_and_flat_meshes_are_skipped() -> void:
	var transforms: Array[Transform3D] = [
		Transform3D(Basis(), Vector3(1.0, 0.0, 1.0)),
		Transform3D(Basis(Vector3.UP, PI * 0.5), Vector3(10.0, 0.0, 1.0)),
	]
	var packed: PackedFloat32Array = BakedMultiMesh.pack_transforms(transforms)
	var tall: AABB = AABB(Vector3(-0.5, 0.0, -0.25), Vector3(1.0, 3.0, 0.5))
	var footprints: Array[ZoneMapBaker.Footprint] = ZoneMapBaker.footprints_of_instances(tall, packed,
			Transform3D(Basis(), Vector3(100.0, 0.0, 0.0)))
	assert_eq(footprints.size(), 2, "one per instance")
	assert_eq(footprints[0].kind, ZoneMapBaker.Footprint.WALL)
	var first := Rect2(footprints[0].polygon[0], Vector2.ZERO)
	for point: Vector2 in footprints[0].polygon:
		first = first.expand(point)
	assert_vec_near(first.position, Vector2(100.5, 0.75), 1e-4, "with the node's transform and the instance's")
	assert_vec_near(first.size, Vector2(1.0, 0.5), 1e-4)
	var turned := Rect2(footprints[1].polygon[0], Vector2.ZERO)
	for point: Vector2 in footprints[1].polygon:
		turned = turned.expand(point)
	assert_vec_near(turned.size, Vector2(0.5, 1.0), 1e-4, "the instance rotated 90° swaps the axes")
	var flat: AABB = AABB(Vector3(-1.0, -0.01, -1.0), Vector3(2.0, 0.02, 2.0))
	assert_true(ZoneMapBaker.footprints_of_instances(flat, packed, Transform3D()).is_empty(), "a flat slab is not drawn")


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
	assert_true(filled >= 60 and filled <= 81, "about 8 x 8 pixels (%d)" % filled)
	ZoneMapBaker.draw_outline(image, square, Color.RED)
	assert_eq(image.get_pixel(4, 8), Color.RED, "the left edge")
	assert_eq(image.get_pixel(8, 4), Color.RED, "the top one")
	assert_eq(image.get_pixel(8, 8), Color.WHITE, "the interior stays the same")
	# Borders and fills outside the image break nothing.
	ZoneMapBaker.fill_convex(image, PackedVector2Array([Vector2(-10, -10), Vector2(30, -10), Vector2(30, 30), Vector2(-10, 30)]), Color.BLUE)
	ZoneMapBaker.draw_outline(image, PackedVector2Array([Vector2(-5, -5), Vector2(40, 3), Vector2(3, 40)]), Color.GREEN)
	assert_eq(image.get_pixel(10, 10), Color.BLUE, "a fill larger than the image covers it without spilling out")
	ZoneMapBaker.fill_convex(image, PackedVector2Array([Vector2(1, 1), Vector2(2, 2)]), Color.WHITE)


func test_every_texture_id_of_the_zone_has_a_ground_color() -> void:
	var assets: Terrain3DAssets = load("res://scenes/world/zones/vado_gris/vado_gris_terrain_assets.tres") as Terrain3DAssets
	if not assert_not_null(assets, "the Vado Gris terrain assets"):
		return
	for i: int in assets.get_texture_count():
		var texture: Terrain3DTextureAsset = assets.get_texture(i)
		assert_true(ZoneMapBaker.TEXTURE_COLORS.has(texture.id), "the ground \"%s\" (id %d) has a color on the map" % [texture.name, texture.id])


# --- Ayudantes --------------------------------------------------------------------------------

func _load_zone() -> void:
	var scene: PackedScene = load(Zones.get_scene_path(ZONE_ID)) as PackedScene
	_zone = scene.instantiate() as Node3D
	tree.root.add_child(_zone)
	await wait_physics_frames(2)


# The saved image, read from the imported texture (not from the loose PNG, which would not work on export).
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
