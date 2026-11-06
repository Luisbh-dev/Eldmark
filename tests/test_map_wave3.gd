extends TestCase
## Tests of quality wave 3 (UI-52, UI-53, UI-54): map label placement ([MapLabelPlacer]),
## place names ([ZonePlaces]), zoom and drag of [WorldMap], icon selection and merging in the [Minimap], compass with
## merged icons ([Compass]), filter and crosshair-offset label of [WorldMarkers] and the [ObjectiveLine].

const ZONE_ID: StringName = &"vado_gris"
const SCREEN: Vector2 = Vector2(1280.0, 720.0)

var _nodes: Array[Node] = []


func after_each() -> void:
	for node: Node in _nodes:
		if is_instance_valid(node):
			if node.get_parent() != null:
				node.get_parent().remove_child(node)
			node.free()
	_nodes.clear()
	await wait_process_frames()


func _item(id: String, anchor: Vector2, size: Vector2, priority: int, is_area: bool = false) -> Dictionary:
	return {"id": id, "anchor": anchor, "size": size, "priority": priority, "area": is_area}


func _marker(id: String, kind: int, position: Vector3, realm: int = 0) -> WorldMarker:
	return WorldMarker.make(StringName(id), kind, id, position, Color.WHITE, realm)


# --- Label placement ----------------------------------------------------------------------------

func test_labels_never_overlap_each_other_or_leave_the_bounds() -> void:
	var bounds := Rect2(0.0, 0.0, 800.0, 600.0)
	var items: Array[Dictionary] = []
	# Seven places very close together: the labels must not overlap.
	for i: int in 7:
		items.append(_item("lugar_%d" % i, Vector2(400.0 + 14.0 * i, 300.0 + 6.0 * i), Vector2(150.0, 20.0), 50 + i))
	var placed: Array[Dictionary] = MapLabelPlacer.place(items, bounds)
	assert_eq(placed.size(), items.size(), "same items, same order")
	var rects: Array[Rect2] = []
	for label: Dictionary in placed:
		if not bool(label["placed"]):
			continue
		var rect: Rect2 = label["rect"]
		assert_true(bounds.encloses(rect), "%s inside the map" % label["id"])
		for other: Rect2 in rects:
			assert_false(rect.intersects(other), "%s does not overlap another label" % label["id"])
		rects.append(rect)
	assert_true(rects.size() >= 5, "almost all of them fit (%d of 7)" % rects.size())


func test_labels_do_not_cover_icons_and_higher_priority_picks_first() -> void:
	var bounds := Rect2(0.0, 0.0, 800.0, 600.0)
	var items: Array[Dictionary] = [
		_item("bajo", Vector2(300.0, 300.0), Vector2(120.0, 20.0), 10),
		_item("alto", Vector2(310.0, 300.0), Vector2(120.0, 20.0), 90),
	]
	var placed: Array[Dictionary] = MapLabelPlacer.place(items, bounds)
	var alto: Dictionary = placed[1]
	var first: Rect2 = alto["rect"]
	assert_true(bool(alto["placed"]))
	assert_eq(first.position, Vector2(310.0 + MapLabelPlacer.ICON_RADIUS + MapLabelPlacer.GAP_NEAR, 290.0),
			"the highest-priority one takes the preferred spot: to the right of its icon")
	for label: Dictionary in placed:
		if not bool(label["placed"]):
			continue
		for item: Dictionary in items:
			var at: Vector2 = item["anchor"]
			assert_false((label["rect"] as Rect2).has_point(at), "%s does not cover the icon of %s" % [label["id"], item["id"]])


func test_a_label_that_does_not_fit_nearby_moves_far_with_a_leader_line() -> void:
	var bounds := Rect2(0.0, 0.0, 600.0, 300.0)
	var items: Array[Dictionary] = []
	for i: int in 12:
		items.append(_item("l%d" % i, Vector2(300.0, 150.0), Vector2(90.0, 20.0), 100 - i))
	var placed: Array[Dictionary] = MapLabelPlacer.place(items, bounds)
	var with_leader: int = 0
	for label: Dictionary in placed:
		if bool(label["placed"]) and bool(label["leader"]):
			with_leader += 1
	assert_true(with_leader >= 1, "some fall to the second ring and carry a leader line")
	var hidden: Array[Dictionary] = MapLabelPlacer.place([_item("fuera", Vector2(5.0, 5.0), Vector2(900.0, 20.0), 1)] as Array[Dictionary], bounds)
	assert_false(bool(hidden[0]["placed"]), "a label that does not fit in the map is hidden")


func test_area_labels_are_centered_and_have_a_single_position() -> void:
	var area: Dictionary = _item("sierra", Vector2(100.0, 100.0), Vector2(80.0, 20.0), 20, true)
	var found: Array[Dictionary] = MapLabelPlacer.candidates(area)
	assert_eq(found.size(), 1)
	assert_eq((found[0]["rect"] as Rect2).get_center(), Vector2(100.0, 100.0))
	var placed: Array[Dictionary] = MapLabelPlacer.place([area] as Array[Dictionary], Rect2(0.0, 0.0, 300.0, 300.0))
	assert_true(bool(placed[0]["placed"]))
	assert_false(bool(placed[0]["leader"]))


func test_vado_gris_places_are_named_and_inside_the_map() -> void:
	var places: Array[MapLandmark] = ZonePlaces.for_zone(ZONE_ID)
	var definition: ZoneMapDefinition = ZoneMapDefinition.load_for_zone(ZONE_ID)
	assert_true(places.size() >= 8, "bridges, ford, ruins, chapel, forests, ranges and river")
	var names: PackedStringArray = PackedStringArray()
	for place: MapLandmark in places:
		names.append(place.label)
		assert_eq(place.kind, MapLandmark.KIND_PLACE)
		assert_false(place.label.is_empty())
		if definition != null:
			assert_true(definition.contains(place.position), "%s falls inside the map" % place.label)
	for expected: String in ["Puente del Norte", "Puente del Sur", "El Vado", "Ruinas de Eld", "Capilla en ruinas"]:
		assert_true(names.has(expected), "tiene nombre «%s»" % expected)
	assert_true(ZonePlaces.for_zone(&"no_existe").is_empty())


# --- Map window: zoom and drag ------------------------------------------------------------------

func _make_world_map() -> WorldMap:
	var layer: CanvasLayer = CanvasLayer.new()
	tree.root.add_child(layer)
	_nodes.append(layer)
	var world_map: WorldMap = WorldMap.new()
	layer.add_child(world_map)
	world_map.anchor_right = 0.0
	world_map.anchor_bottom = 0.0
	world_map.size = SCREEN
	world_map.bind(null, null, null, ZoneMapDefinition.load_for_zone(ZONE_ID), null)
	return world_map


func test_the_map_zooms_with_the_wheel_around_the_cursor_and_clamps() -> void:
	var world_map: WorldMap = _make_world_map()
	assert_near(world_map.get_zoom(), 1.0, 1e-9)
	var rect: Rect2 = world_map.get_map_rect()
	assert_eq(world_map.get_view_uv(), Rect2(0.0, 0.0, 1.0, 1.0), "with zoom 1 the whole image is visible")
	var cursor: Vector2 = rect.position + rect.size * Vector2(0.75, 0.25)
	var world_before: Vector3 = world_map.screen_to_world(cursor)
	world_map.zoom_at(2.0, cursor)
	assert_near(world_map.get_zoom(), 2.0, 1e-9)
	var world_after: Vector3 = world_map.screen_to_world(cursor)
	assert_near(world_after.x, world_before.x, 1e-3, "the point under the cursor does not move when zooming in (x)")
	assert_near(world_after.z, world_before.z, 1e-3, "ni en z")
	assert_near(world_map.get_view_uv().size.x, 0.5, 1e-9, "with zoom 2 half is visible")
	world_map.zoom_at(100.0, cursor)
	assert_near(world_map.get_zoom(), WorldMap.MAX_ZOOM, 1e-9, "the zoom has a cap")
	world_map.zoom_at(0.0001, cursor)
	assert_near(world_map.get_zoom(), WorldMap.MIN_ZOOM, 1e-9, "and a minimum: it does not zoom out beyond the whole image")
	assert_eq(world_map.get_view_uv(), Rect2(0.0, 0.0, 1.0, 1.0))


func test_dragging_pans_the_view_and_stays_inside_the_image() -> void:
	var world_map: WorldMap = _make_world_map()
	world_map.zoom_at(WorldMap.MAX_ZOOM, world_map.get_map_rect().get_center())
	var center_before: Vector2 = world_map.get_view_center()
	var point: Vector3 = Vector3(10.0, 0.0, 20.0)
	var screen_before: Vector2 = world_map.world_to_screen(point)
	world_map.pan_by(Vector2(40.0, -25.0))
	assert_vec_near(world_map.world_to_screen(point), screen_before + Vector2(40.0, -25.0), 1e-2,
			"dragging moves the map as much as the hand")
	assert_true(world_map.get_view_center() != center_before)
	world_map.pan_by(Vector2(100000.0, 100000.0))
	var view: Rect2 = world_map.get_view_uv()
	assert_true(view.position.x >= -1e-9 and view.position.y >= -1e-9, "it does not leave through the northwest")
	assert_true(view.end.x <= 1.0 + 1e-9 and view.end.y <= 1.0 + 1e-9, "nor through the southeast")
	world_map.reset_view()
	assert_eq(world_map.get_view_uv(), Rect2(0.0, 0.0, 1.0, 1.0))


func test_world_and_screen_still_convert_both_ways_when_zoomed_and_panned() -> void:
	var world_map: WorldMap = _make_world_map()
	world_map.zoom_at(3.0, world_map.get_map_rect().get_center() + Vector2(60.0, 30.0))
	world_map.pan_by(Vector2(-30.0, 17.0))
	for point: Vector3 in [Vector3(0.0, 0.0, 0.0), Vector3(-40.0, 0.0, 25.0), Vector3(60.0, 0.0, -35.0)]:
		var back: Vector3 = world_map.screen_to_world(world_map.world_to_screen(point))
		assert_near(back.x, point.x, 1e-3, "round trip in x (%s)" % point)
		assert_near(back.z, point.z, 1e-3, "y en z")


func test_the_wheel_event_zooms_and_a_left_drag_pans() -> void:
	var world_map: WorldMap = _make_world_map()
	world_map.open()
	var rect: Rect2 = world_map.get_map_rect()
	var wheel := InputEventMouseButton.new()
	wheel.button_index = MOUSE_BUTTON_WHEEL_UP
	wheel.pressed = true
	wheel.position = rect.get_center()
	world_map._gui_input(wheel)
	assert_true(world_map.get_zoom() > 1.0, "the wheel forward zooms in")
	var press := InputEventMouseButton.new()
	press.button_index = MOUSE_BUTTON_LEFT
	press.pressed = true
	press.position = rect.get_center()
	world_map._gui_input(press)
	var before: Vector2 = world_map.get_view_center()
	var motion := InputEventMouseMotion.new()
	motion.position = rect.get_center() + Vector2(50.0, 0.0)
	motion.relative = Vector2(50.0, 0.0)
	world_map._gui_input(motion)
	assert_true(world_map.get_view_center().x < before.x, "dragging to the right moves the view to the left")
	var release := InputEventMouseButton.new()
	release.button_index = MOUSE_BUTTON_LEFT
	release.pressed = false
	world_map._gui_input(release)
	var after: Vector2 = world_map.get_view_center()
	var more := InputEventMouseMotion.new()
	more.relative = Vector2(50.0, 0.0)
	world_map._gui_input(more)
	assert_eq(world_map.get_view_center(), after, "on release it stops dragging")
	world_map.close()


func test_the_open_map_labels_the_named_places_without_overlap() -> void:
	var world_map: WorldMap = _make_world_map()
	world_map.open()
	world_map.refresh()
	var labels: Array[Dictionary] = world_map.get_labels()
	var ids: PackedStringArray = PackedStringArray()
	var rects: Array[Rect2] = []
	for label: Dictionary in labels:
		if not bool(label["placed"]):
			continue
		ids.append(String(label["text"]))
		var rect: Rect2 = label["rect"]
		for other: Rect2 in rects:
			assert_false(rect.intersects(other), "\"%s\" does not overlap another label" % label["text"])
		rects.append(rect)
	for expected: String in ["Fuerte del Vado Gris", "Puente del Norte", "Puente del Sur", "El Vado", "Ruinas de Eld", "Capilla en ruinas",
			"Campamento de Vardheim", "Campamento de Solmarch"]:
		assert_true(ids.has(expected), "\"%s\" has a label (%s)" % [expected, ", ".join(ids)])
	world_map.close()


# --- Minimapa: iconos ---------------------------------------------------------------------------

func test_only_the_objective_sticks_to_the_rim_and_other_places_need_to_be_inside() -> void:
	var center := Vector2(100.0, 100.0)
	var player := Vector3.ZERO
	var markers: Array[WorldMarker] = [
		_marker("fort", WorldMarker.Kind.FORT, Vector3(0.0, 0.0, -300.0)),
		_marker("camp_lejos", WorldMarker.Kind.CAMP, Vector3(0.0, 0.0, 300.0)),
		_marker("paso_cerca", WorldMarker.Kind.PASS, Vector3(10.0, 0.0, 0.0)),
	]
	var icons: Array[Dictionary] = Minimap.select_icons(markers, &"fort", player, 1.0, center, 100.0)
	var ids: PackedStringArray = PackedStringArray()
	for icon: Dictionary in icons:
		ids.append(String((icon["marker"] as WorldMarker).id))
		if (icon["marker"] as WorldMarker).id == &"fort":
			assert_true(bool(icon["rim"]), "the objective sticks to the ring")
			assert_near((icon["point"] as Vector2).distance_to(center), 100.0 - Minimap.ICON_SIZE, 1e-3)
	assert_true(ids.has("fort"), "the objective, even if it is far away")
	assert_true(ids.has("paso_cerca"), "what falls inside is shown")
	assert_false(ids.has("camp_lejos"), "a camp outside the radius does not stick to the ring")
	var no_objective: Array[Dictionary] = Minimap.select_icons(markers, &"", player, 1.0, center, 100.0)
	assert_eq(no_objective.size(), 1, "without an objective, only what is inside")


func test_icons_that_touch_are_merged_into_the_most_important_one() -> void:
	var center := Vector2(100.0, 100.0)
	var markers: Array[WorldMarker] = [
		_marker("paso", WorldMarker.Kind.PASS, Vector3(20.0, 0.0, 0.0)),
		_marker("puerta", WorldMarker.Kind.GATE, Vector3(23.0, 0.0, 0.0)),
		_marker("campamento", WorldMarker.Kind.CAMP, Vector3(-30.0, 0.0, 0.0)),
	]
	var icons: Array[Dictionary] = Minimap.select_icons(markers, &"", Vector3.ZERO, 2.0, center, 100.0)
	var ids: PackedStringArray = PackedStringArray()
	for icon: Dictionary in icons:
		ids.append(String((icon["marker"] as WorldMarker).id))
	assert_true(ids.has("puerta"), "the highest-priority one stays")
	assert_false(ids.has("paso"), "the one that touches a better one merges into it")
	assert_true(ids.has("campamento"), "the one that is far away is not touched")
	for i: int in icons.size():
		for j: int in range(i + 1, icons.size()):
			assert_true((icons[i]["point"] as Vector2).distance_to(icons[j]["point"]) >= Minimap.MERGE_DISTANCE,
					"no pair of icons ends up touching")


func test_the_minimap_fades_the_terrain_into_fog_at_the_ring() -> void:
	var terrain: MinimapTerrain = MinimapTerrain.new()
	_nodes.append(terrain)
	var material: ShaderMaterial = terrain.get_terrain_material()
	assert_near(float(material.get_shader_parameter(&"rim_fade")), MinimapTerrain.RIM_FADE, 1e-9)
	assert_true(float(material.get_shader_parameter(&"rim_strength")) > 0.0)
	assert_true(material.shader.code.contains("rim_fade"), "the shader fades the terrain toward the ring")


# --- Compass ------------------------------------------------------------------------------------

func test_the_compass_merges_icons_at_the_same_bearing_and_fades_letters_at_the_edges() -> void:
	var compass: Compass = Compass.new()
	_nodes.append(compass)
	tree.root.add_child(compass)
	var markers: Array[WorldMarker] = [
		_marker("fuerte", WorldMarker.Kind.FORT, Vector3(0.0, 0.0, -100.0)),
		_marker("puerta", WorldMarker.Kind.GATE, Vector3(0.5, 0.0, -90.0)),
		_marker("campamento", WorldMarker.Kind.CAMP, Vector3(80.0, 0.0, -20.0)),
	]
	compass.update_view(0.0, Vector3.ZERO, markers)
	assert_eq(compass.get_visible_markers().size(), 3, "all three fall on the strip")
	var drawn: Array[Dictionary] = compass.get_drawn_markers()
	assert_eq(drawn.size(), 2, "fort and gate, at the same bearing, are a single icon")
	var kinds: Array[int] = []
	for entry: Dictionary in drawn:
		var marker: WorldMarker = entry["marker"]
		kinds.append(marker.kind)
		if marker.kind == WorldMarker.Kind.FORT:
			assert_eq(int(entry["merged"]), 2, "and it says it represents two")
	assert_true(kinds.has(WorldMarker.Kind.FORT) and not kinds.has(WorldMarker.Kind.GATE), "the highest-priority one remains")
	assert_near(Compass.letter_alpha(Compass.WIDTH * 0.5), 1.0, 1e-9, "the letters, opaque at the center")
	assert_near(Compass.letter_alpha(0.0), 0.0, 1e-9, "and dimmed at the edge")
	assert_true(Compass.letter_alpha(Compass.WIDTH * 0.85) < Compass.letter_alpha(Compass.WIDTH * 0.6), "and fade out gradually")
	assert_true(Compass.HEIGHT >= Compass.TAPE_HEIGHT + Compass.ICON_ROW_HEIGHT + 10.0,
			"there is room for the strip, the separate row of icons and the bearing plate")
	assert_eq(compass.get_heading_text(), "000° N", "the numeric bearing under the needle")


# --- World markers -----------------------------------------------------------------------------

func test_enemy_camps_and_passes_are_not_marked_but_everything_else_is() -> void:
	var vardheim: int = NetProtocol.Realm.VARDHEIM
	var solmarch: int = NetProtocol.Realm.SOLMARCH
	assert_true(WorldMarkers.is_markable(_marker("c", WorldMarker.Kind.CAMP, Vector3.ZERO, vardheim), vardheim), "mi campamento")
	assert_false(WorldMarkers.is_markable(_marker("c", WorldMarker.Kind.CAMP, Vector3.ZERO, solmarch), vardheim), "the enemy camp does not")
	assert_false(WorldMarkers.is_markable(_marker("p", WorldMarker.Kind.PASS, Vector3.ZERO, solmarch), vardheim), "nor its pass")
	assert_true(WorldMarkers.is_markable(_marker("p", WorldMarker.Kind.PASS, Vector3.ZERO, vardheim), vardheim), "mine does")
	assert_true(WorldMarkers.is_markable(_marker("f", WorldMarker.Kind.FORT, Vector3.ZERO, solmarch), vardheim), "the fort, whoever owns it")
	assert_true(WorldMarkers.is_markable(_marker("g", WorldMarker.Kind.GATE, Vector3.ZERO, solmarch), vardheim))


func test_a_marker_label_is_pushed_at_least_150_px_from_the_aim() -> void:
	var aim := Vector2(960.0, 540.0)
	var near_aim := Rect2(Vector2(930.0, 560.0), Vector2(120.0, 18.0))
	var pushed: Rect2 = WorldMarkers.push_from_aim(near_aim, aim, WorldMarkers.LABEL_MIN_AIM_DISTANCE)
	var closest := Vector2(clampf(aim.x, pushed.position.x, pushed.end.x), clampf(aim.y, pushed.position.y, pushed.end.y))
	assert_true(closest.distance_to(aim) >= WorldMarkers.LABEL_MIN_AIM_DISTANCE - 0.01,
			"the label falls %.0f px from the crosshair" % closest.distance_to(aim))
	assert_eq(pushed.size, near_aim.size, "and does not change size")
	var far := Rect2(Vector2(200.0, 100.0), Vector2(120.0, 18.0))
	assert_eq(WorldMarkers.push_from_aim(far, aim, WorldMarkers.LABEL_MIN_AIM_DISTANCE), far, "a distant one stays where it is")
	var on_top: Rect2 = WorldMarkers.push_from_aim(Rect2(aim - Vector2(40.0, 9.0), Vector2(80.0, 18.0)), aim,
			WorldMarkers.LABEL_MIN_AIM_DISTANCE)
	var c2 := Vector2(clampf(aim.x, on_top.position.x, on_top.end.x), clampf(aim.y, on_top.position.y, on_top.end.y))
	assert_true(c2.distance_to(aim) >= WorldMarkers.LABEL_MIN_AIM_DISTANCE - 0.01, "even one right over the crosshair")


func test_the_bottom_margin_keeps_icons_off_the_lower_hud() -> void:
	var camera := Camera3D.new()
	tree.root.add_child(camera)
	_nodes.append(camera)
	camera.global_position = Vector3(0.0, 1.7, 0.0)
	camera.look_at(Vector3(0.0, 1.7, -10.0))
	camera.make_current()
	var screen := Vector2(1920.0, 1080.0)
	# A point far below the view: at the edge, but without entering the bottom 150 px.
	var projected: Dictionary = WorldMarkers.project(camera, screen, Vector3(0.0, -400.0, -20.0), WorldMarkers.EDGE_MARGIN,
			WorldMarkers.BOTTOM_MARGIN)
	assert_true(bool(projected["on_edge"]))
	assert_true((projected["screen"] as Vector2).y <= screen.y - WorldMarkers.BOTTOM_MARGIN + 0.01,
			"it stays above the bottom bar (%s)" % projected["screen"])


# --- Objective line -----------------------------------------------------------------------------

func test_the_objective_line_composes_a_compact_status_text() -> void:
	var definition: FortressDefinition = load("res://data/fortresses/vado_gris.tres") as FortressDefinition
	var state: FortressState = FortressState.initial(definition, 100)
	state.gate_max = 9000
	state.gate_health = 6480
	var text: String = ObjectiveLine.compose_text("Fuerte del Vado Gris", state, 0.0, 182.4)
	assert_true(text.begins_with("Fuerte del Vado Gris"), text)
	assert_true(text.contains("Capitán del Vado en pie"), "says whether the captain is standing: %s" % text)
	assert_true(text.contains("Puerta 72 %"), "and the gate's health: %s" % text)
	assert_true(text.ends_with("182 m"), "and the distance: %s" % text)
	assert_false(text.contains("\n"), "a single line")
	state.phase = FortressState.Phase.CAPTURING
	state.capture_realm = NetProtocol.Realm.SOLMARCH
	var capturing: String = ObjectiveLine.compose_text("Fuerte", state, 0.4, 50.0)
	assert_true(capturing.contains("Captura de") and capturing.contains("40 %"), capturing)
	state.phase = FortressState.Phase.VULNERABLE
	assert_true(ObjectiveLine.compose_text("Fuerte", state, 0.0, 50.0).contains(ObjectiveLine.TEXT_CAPTAIN_DOWN))
	assert_eq(ObjectiveLine.WIDTH, Compass.WIDTH, "as wide as the compass, below it")
	assert_true(ObjectiveLine.TOP_MARGIN >= Compass.TOP_MARGIN + Compass.HEIGHT, "and without overlapping it")
	assert_true(CapturePanel.TOP_MARGIN >= Compass.TOP_MARGIN + Compass.HEIGHT, "the capture panel does not overlap the compass either")


# --- Wave 6 polish: ally absorption, legend measure and scale bar figures ---------------------------------------

func test_an_ally_on_an_icon_is_absorbed_by_it_and_one_apart_is_not() -> void:
	var icons := PackedVector2Array([Vector2(100.0, 100.0), Vector2(300.0, 100.0)])
	assert_eq(WorldMap.nearest_icon(Vector2(104.0, 100.0), icons), 0, "inside the merge radius: absorbed by the first")
	assert_eq(WorldMap.nearest_icon(Vector2(296.0, 103.0), icons), 1, "or by the second")
	assert_eq(WorldMap.nearest_icon(Vector2(200.0, 100.0), icons), -1, "apart from both it stays a free dot")
	assert_eq(WorldMap.nearest_icon(Vector2(100.0 + WorldMap.ALLY_MERGE_RADIUS + 1.0, 100.0), icons), -1)


func test_the_legend_panel_is_as_tall_as_what_is_drawn() -> void:
	var world_map := WorldMap.new()
	world_map.size = SCREEN
	_nodes.append(world_map)
	var drawn_to: float = world_map._legend_pass(Rect2(), false)
	assert_near(world_map._legend_content_height(), drawn_to + WorldMap.LEGEND_BOTTOM_PAD, 0.0001,
			"the panel is cut at the last line drawn plus the padding")
	var rows: int = world_map.get_legend_entries().size() + world_map.get_fortress_lines().size() \
			+ RealmCatalog.FACTION_IDS.size()
	assert_true(drawn_to >= 22.0 * float(rows), "every row counts toward the height")


func test_the_scale_bar_figures_match_the_baked_bar() -> void:
	assert_near(WorldMap.SCALE_BAR_SPAN, 80.0, 0.0001)
	assert_near(WorldMap.SCALE_BAR_SPAN / WorldMap.SCALE_BAR_SECTION, 4.0, 0.0001, "four sections")
	assert_true(FileAccess.get_file_as_string("res://tools/map/parchment_map_baker.gd").contains("WorldMap.SCALE_BAR_SPAN"),
			"the baker takes the numbers from the map window")
