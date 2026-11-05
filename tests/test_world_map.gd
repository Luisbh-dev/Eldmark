extends TestCase
## Tests of the minimap and the full-screen map (UI-20, UI-21, docs/fortress.md section 6):
## [Minimap] (projection with north up, crop centered on the player, zoom, icons and companions),
## [WorldMap] (geometry, coordinate conversion, legend, respawn choice) and their mounting in the
## [HUD] with the death screen. No server: a fake client provides the character, the realm and the tick, and the
## fort states are synthetic. The places are those of Vado Gris: the fort in the center and a
## camp on each side, 138 m away.

const VARDHEIM: int = NetProtocol.Realm.VARDHEIM
const SOLMARCH: int = NetProtocol.Realm.SOLMARCH
const ZONE_ID: StringName = &"vado_gris"
const FORT_ID: StringName = &"vado_gris_fort"
const DEFINITION_PATH: String = "res://data/fortresses/vado_gris.tres"
const FORT_SCENE_PATH: String = "res://scenes/world/props/fort/vado_gris_fort.tscn"
const ZONE_SCENE_PATH: String = "res://scenes/world/zones/vado_gris/vado_gris.tscn"
const CHARACTER_SCENE_PATH: String = "res://scenes/characters/player_character.tscn"
const CAMERA_RIG_SCENE_PATH: String = "res://scenes/client/camera_rig.tscn"
const HUD_SCENE_PATH: String = "res://scenes/ui/hud.tscn"
const VARDHEIM_CAMP: Vector3 = Vector3(0.0, 6.25, -138.0)
const OWN_ID: int = 5
const NET_ID: int = 900
const SIZE: Vector2 = Vector2(1280.0, 720.0)


## Network client that connects to nothing: provides the character, the realm, the tick and death at will.
class FakeClient extends NetClient:
	var fake_character: PlayerCharacter = null
	var fake_config: ClientConfig = ClientConfig.new()
	var fake_tick: int = 1000
	var fake_dead: bool = false
	var fake_respawn_tick: int = 0
	var fake_snapshot_tick: int = 1
	var respawn_requests: Array[int] = []

	func get_character() -> PlayerCharacter:
		return fake_character

	func get_config() -> ClientConfig:
		return fake_config

	func get_estimated_server_tick() -> int:
		return fake_tick

	func get_net_id() -> int:
		return OWN_ID

	func is_dead() -> bool:
		return fake_dead

	func has_health() -> bool:
		return true

	func get_health() -> int:
		return 0 if fake_dead else 1000

	func get_respawn_tick() -> int:
		return fake_respawn_tick

	func get_last_snapshot_tick() -> int:
		return fake_snapshot_tick

	func send_respawn_request(point_index: int) -> bool:
		respawn_requests.append(point_index)
		return true


var _root: Node3D = null
var _nodes: Array[Node] = []
var _map: ZoneMapDefinition = null
var _def: FortressDefinition = null


func before_each() -> void:
	HintLog.set_current(HintLog.in_memory())
	_map = ZoneMapDefinition.load_for_zone(ZONE_ID)
	_def = load(DEFINITION_PATH) as FortressDefinition
	_root = Node3D.new()
	_root.name = "WorldMapTest"
	tree.root.add_child(_root)


func after_each() -> void:
	for node: Node in _nodes:
		if is_instance_valid(node):
			if node.get_parent() != null:
				node.get_parent().remove_child(node)
			node.free()
	_nodes.clear()
	if is_instance_valid(_root):
		tree.root.remove_child(_root)
		_root.free()
	_root = null
	await wait_process_frames()


func _track(node: Node, parent: Node = null) -> Node:
	(parent if parent != null else _root).add_child(node)
	_nodes.append(node)
	return node


# --- Minimap: math ----------------------------------------------------------------------------

func test_the_minimap_projection_puts_north_up_and_east_right() -> void:
	var center := Vector2(100.0, 100.0)
	var player := Vector3(10.0, 5.0, 20.0)
	assert_eq(Minimap.world_to_minimap(player, player, 2.0, center), center, "the player, at the center")
	var north: Vector2 = Minimap.world_to_minimap(player + Vector3(0.0, 0.0, -10.0), player, 2.0, center)
	assert_vec_near(north, Vector2(100.0, 80.0), 1e-6, "10 m north (-Z): 20 px up")
	var east: Vector2 = Minimap.world_to_minimap(player + Vector3(15.0, 40.0, 0.0), player, 2.0, center)
	assert_vec_near(east, Vector2(130.0, 100.0), 1e-6, "15 m east (+X): 30 px to the right, and height does not count")


func test_points_outside_the_circle_stick_to_its_edge() -> void:
	var center := Vector2(100.0, 100.0)
	assert_eq(Minimap.clamp_to_circle(Vector2(130.0, 100.0), center, 90.0), Vector2(130.0, 100.0), "dentro, igual")
	var stuck: Vector2 = Minimap.clamp_to_circle(Vector2(400.0, 100.0), center, 90.0)
	assert_vec_near(stuck, Vector2(190.0, 100.0), 1e-4, "outside, at the edge and in the same direction")
	var diagonal: Vector2 = Minimap.clamp_to_circle(Vector2(500.0, 500.0), center, 90.0)
	assert_near((diagonal - center).length(), 90.0, 1e-4, "on the diagonal, one radius from the center")
	assert_near(diagonal.x - center.x, diagonal.y - center.y, 1e-4, "y a 45 grados")


func test_the_yaw_direction_matches_the_compass() -> void:
	assert_vec_near(Minimap.yaw_to_direction(0.0), Vector2(0.0, -1.0), 1e-6, "yaw 0 faces north: up")
	assert_vec_near(Minimap.yaw_to_direction(PI * 0.5), Vector2(-1.0, 0.0), 1e-6, "yaw grows to the left: west")
	assert_vec_near(Minimap.yaw_to_direction(PI), Vector2(0.0, 1.0), 1e-6, "to the south, down")
	assert_vec_near(Minimap.yaw_to_direction(-PI * 0.5), Vector2(1.0, 0.0), 1e-6, "and to the east, to the right")
	for yaw: float in [0.0, 0.7, 2.0, -1.3]:
		var direction: Vector2 = Minimap.yaw_to_direction(yaw)
		var heading: float = fposmod(rad_to_deg(atan2(direction.x, -direction.y)), 360.0)
		assert_near(heading, Compass.heading_of_yaw(yaw), 1e-3,
				"the minimap heading matches the compass one (yaw %.1f)" % yaw)


func test_the_minimap_crop_is_centered_on_the_player_with_the_maps_scale() -> void:
	if not assert_not_null(_map, "Vado Gris has a map"):
		return
	var center := Vector2(Minimap.DIAMETER, Minimap.DIAMETER) * 0.5
	var player := Vector3(40.0, 8.0, -25.0)
	var ppm: float = 2.0
	assert_vec_near(Minimap.uv_at(_map, player, ppm, center, center), _map.world_to_uv(player), 1e-6,
			"the center of the minimap is the player's position on the map")
	var right: Vector2 = Minimap.uv_at(_map, player, ppm, center + Vector2(20.0, 0.0), center)
	var expected: Vector2 = _map.world_to_uv(player + Vector3(10.0, 0.0, 0.0))
	assert_vec_near(right, expected, 1e-6, "20 px to the right at 2 px/m is 10 m east")
	var up: Vector2 = Minimap.uv_at(_map, player, ppm, center - Vector2(0.0, 40.0), center)
	assert_vec_near(up, _map.world_to_uv(player + Vector3(0.0, 0.0, -20.0)), 1e-6, "and up is north")


func test_zoom_levels_are_clamped_and_change_the_scale() -> void:
	var minimap: Minimap = _track(Minimap.new()) as Minimap
	assert_eq(minimap.get_zoom_level(), Minimap.DEFAULT_ZOOM)
	assert_eq(minimap.get_visible_meters(), Minimap.ZOOM_METERS[Minimap.DEFAULT_ZOOM])
	var base: float = minimap.pixels_per_meter()
	minimap.zoom_in()
	assert_true(minimap.pixels_per_meter() > base, "zooming in gives more pixels per meter")
	for i: int in 10:
		minimap.zoom_in()
	assert_eq(minimap.get_zoom_level(), 0, "it does not go past the closest level")
	assert_eq(minimap.get_visible_meters(), Minimap.ZOOM_METERS[0])
	for i: int in 10:
		minimap.zoom_out()
	assert_eq(minimap.get_zoom_level(), Minimap.ZOOM_METERS.size() - 1, "nor the farthest")
	assert_near(minimap.pixels_per_meter(), Minimap.DIAMETER / Minimap.ZOOM_METERS[Minimap.ZOOM_METERS.size() - 1], 1e-6)


# --- Minimap with a client --------------------------------------------------------------------

func _make_client(position: Vector3, realm: int = VARDHEIM) -> FakeClient:
	var client: FakeClient = _track(FakeClient.new()) as FakeClient
	client.fake_config.realm = realm
	client.get_remote_world().install_visuals = false
	var character: PlayerCharacter = _track((load(CHARACTER_SCENE_PATH) as PackedScene).instantiate(), _root) as PlayerCharacter
	character.global_position = position
	client.fake_character = character
	return client


func _make_rig() -> CameraRig:
	var rig: CameraRig = (load(CAMERA_RIG_SCENE_PATH) as PackedScene).instantiate() as CameraRig
	rig.set_scripted_look(false)
	_track(rig)
	rig.set_look(0.0, 0.0)
	return rig


func _player_spawn(net_id: int, display_name: String, realm: int, position: Vector3) -> NetMessages.EntitySpawn:
	var spawn := NetMessages.EntitySpawn.new()
	spawn.net_id = net_id
	spawn.kind = NetProtocol.EntityKind.PLAYER
	spawn.spawn_tick = 100
	spawn.display_name = display_name
	spawn.realm = realm
	spawn.state = PlayerState.new()
	spawn.state.position = position
	return spawn


func _fort_view(values: Dictionary) -> FortressView:
	var view: FortressView = _track(FortressView.new()) as FortressView
	var fort_node: Node3D = (load(FORT_SCENE_PATH) as PackedScene).instantiate() as Node3D
	fort_node.add_to_group(Zones.FORTRESS_GROUP)
	fort_node.set_meta(Zones.FORTRESS_DEFINITION_META, DEFINITION_PATH)
	_track(fort_node, _root)
	fort_node.global_position = Vector3(0.0, 10.2, 0.0)
	view.set_zone(_root)
	view.on_spawn(_fortress_spawn(100, values))
	view.advance(100.0)
	return view


func _fortress_spawn(tick: int, values: Dictionary) -> NetMessages.EntitySpawn:
	var state: FortressState = FortressState.initial(_def, tick)
	for field_id: int in values:
		FortressFields.set_value(state, field_id, int(values[field_id]))
	return NetMessages.EntitySpawn.decode(NetMessages.EntitySpawn.for_fortress(NET_ID, tick,
			String(FORT_ID), state).encode())


func test_the_minimap_marks_the_fortress_in_its_owners_color_the_camps_and_only_allies() -> void:
	var client: FakeClient = _make_client(VARDHEIM_CAMP)
	var view: FortressView = _fort_view({FortressFields.OWNER: SOLMARCH})
	var rig: CameraRig = _make_rig()
	var minimap: Minimap = _track(Minimap.new()) as Minimap
	minimap.bind(client, view, rig, _map)
	var remote: RemoteWorld = client.get_remote_world()
	remote.on_spawn(_player_spawn(31, "Aliada", VARDHEIM, VARDHEIM_CAMP + Vector3(10.0, 0.0, 0.0)))
	remote.on_spawn(_player_spawn(32, "Enemigo", SOLMARCH, VARDHEIM_CAMP + Vector3(0.0, 0.0, 10.0)))
	remote.on_spawn(_player_spawn(33, "Caído", VARDHEIM, VARDHEIM_CAMP + Vector3(-10.0, 0.0, 0.0)))
	remote.draw(200.0, 0.016)
	var dead := EntityRecord.new()
	dead.net_id = 33
	dead.kind = NetProtocol.EntityKind.PLAYER
	dead.position = VARDHEIM_CAMP + Vector3(-10.0, 0.0, 0.0)
	dead.health_q = EntityRecord.HEALTH_Q_DEAD
	remote.get_view(33).push(210, dead)
	remote.draw(210.0, 0.016)
	minimap.refresh()
	assert_eq(minimap.get_ally_count(), 1, "only the living ally: neither the enemy nor the fallen one")
	var ally_points: Array[Vector2] = minimap.get_ally_points()
	var ally_expected: Vector2 = Minimap.world_to_minimap(VARDHEIM_CAMP + Vector3(10.0, 0.0, 0.0), VARDHEIM_CAMP,
			minimap.pixels_per_meter(), minimap.center())
	assert_vec_near(ally_points[0], ally_expected, 1e-3, "10 m east of the player")
	var ids: PackedStringArray = PackedStringArray()
	var fort_color: Color = Color.BLACK
	for icon: Dictionary in minimap.get_icons():
		var marker: WorldMarker = icon["marker"]
		ids.append(String(marker.id))
		if marker.kind == WorldMarker.Kind.FORT:
			fort_color = marker.color
		var point: Vector2 = icon["point"]
		assert_true(point.distance_to(minimap.center()) <= minimap.radius() + 1e-3,
				"icon %s fits in the circle" % marker.id)
	assert_true(ids.has("fort_%d" % NET_ID), "the fort, which is the objective, stuck to the ring (%s)" % ", ".join(ids))
	assert_true(ids.has("camp_1"), "the camp where the player is")
	assert_false(ids.has("gate_%d" % NET_ID), "the gate falls outside the circle and is not the objective: it does not stick to the ring")
	assert_false(ids.has("camp_2"), "nor the camp on the other side")
	assert_eq(fort_color, RealmCatalog.color_of(RealmCatalog.SOLMARCH), "the fort, with its owner's color")
	# Without a client there is nothing to draw.
	minimap.bind(null, null, null, null)
	minimap.refresh()
	assert_true(minimap.get_icons().is_empty())
	assert_eq(minimap.get_ally_count(), 0)


func test_the_minimap_and_the_map_draw_for_a_few_frames_without_errors() -> void:
	var client: FakeClient = _make_client(VARDHEIM_CAMP)
	var view: FortressView = _fort_view({})
	var rig: CameraRig = _make_rig()
	var layer: CanvasLayer = _track(CanvasLayer.new()) as CanvasLayer
	var minimap: Minimap = Minimap.new()
	layer.add_child(minimap)
	minimap.bind(client, view, rig, _map)
	var world_map: WorldMap = WorldMap.new()
	layer.add_child(world_map)
	world_map.bind(client, view, rig, _map, _root)
	world_map.open(true)
	await wait_process_frames(3)
	assert_true(world_map.is_open())
	world_map.close()
	minimap.bind(client, view, rig, null)
	await wait_process_frames(2)
	assert_not_null(minimap, "without a baked map it still draws the background and the icons")


# --- Full map: geometry -----------------------------------------------------------------------

func _make_map_node(client: FakeClient, view: FortressView, rig: CameraRig, world: Node) -> WorldMap:
	var layer: CanvasLayer = _track(CanvasLayer.new()) as CanvasLayer
	var world_map: WorldMap = WorldMap.new()
	layer.add_child(world_map)
	_fix_size(world_map)
	world_map.bind(client, view, rig, _map, world)
	return world_map


# Gives the map a known screen size (with the four anchors loose, so it does not rewrite it).
func _fix_size(world_map: WorldMap) -> void:
	world_map.anchor_right = 0.0
	world_map.anchor_bottom = 0.0
	world_map.size = SIZE


func test_the_map_rect_is_a_square_inside_the_screen_and_converts_coordinates_both_ways() -> void:
	var world_map: WorldMap = _make_map_node(_make_client(VARDHEIM_CAMP), null, _make_rig(), _root)
	var rect: Rect2 = world_map.get_map_rect()
	assert_near(rect.size.x, rect.size.y, 1e-6, "cuadrado")
	assert_true(Rect2(Vector2.ZERO, SIZE).encloses(rect), "inside the screen")
	assert_false(rect.intersects(world_map.get_legend_rect()), "the legend, to its right and without overlapping it")
	assert_true(Rect2(Vector2.ZERO, SIZE).encloses(world_map.get_legend_rect()), "and also inside")
	assert_vec_near(world_map.world_to_screen(Vector3.ZERO), rect.get_center(), 1e-3,
			"the center of the map (the fort) falls at the center of the square")
	assert_vec_near(world_map.world_to_screen(Vector3(-200.0, 0.0, -200.0)), rect.position, 1e-3,
			"the northwest corner of the map, top left")
	assert_vec_near(world_map.world_to_screen(Vector3(200.0, 0.0, 200.0)), rect.end, 1e-3, "and the southeast one, bottom right")
	for point: Vector3 in [VARDHEIM_CAMP, Vector3(60.0, 0.0, 30.0), Vector3(-90.0, 0.0, 120.0)]:
		var back: Vector3 = world_map.screen_to_world(world_map.world_to_screen(point))
		assert_near(back.x, point.x, 1e-3, "round trip in x (%s)" % point)
		assert_near(back.z, point.z, 1e-3, "y en z")
	assert_true(world_map.get_title_text().contains("Vado Gris"), "the title states the zone: %s" % world_map.get_title_text())
	assert_eq(world_map.get_hint_text(), WorldMap.TEXT_HINT_OPEN)


func test_the_map_legend_lists_what_is_marked_and_the_fortress_state() -> void:
	var view: FortressView = _fort_view({FortressFields.OWNER: SOLMARCH})
	var world_map: WorldMap = _make_map_node(_make_client(VARDHEIM_CAMP), view, _make_rig(), _root)
	world_map.open()
	var texts: PackedStringArray = PackedStringArray()
	for entry: Dictionary in world_map.get_legend_entries():
		texts.append(String(entry["text"]))
	assert_true(texts.has(WorldMap.TEXT_YOU) and texts.has(WorldMap.TEXT_ALLIES), "you and your companions")
	for kind_text: String in ["Fuerte", "Puerta del fuerte", "Campamento", "Paso a otra zona"]:
		assert_true(texts.has(kind_text), "%s (%s)" % [kind_text, ", ".join(texts)])
	assert_false(texts.has(WorldMap.TEXT_RESPAWN_VALID), "without respawn there is no such legend")
	var lines: PackedStringArray = world_map.get_fortress_lines()
	assert_eq(lines[0], "Fuerte del Vado Gris")
	assert_true(lines[1].contains("Solmarch"), "the owner: %s" % lines[1])
	world_map.set_respawn_mode(true)
	texts.clear()
	for entry: Dictionary in world_map.get_legend_entries():
		texts.append(String(entry["text"]))
	assert_true(texts.has(WorldMap.TEXT_RESPAWN_VALID) and texts.has(WorldMap.TEXT_RESPAWN_INVALID), "in respawn mode, both legends")
	assert_eq(world_map.get_hint_text(), WorldMap.TEXT_HINT_RESPAWN)
	var without_view: WorldMap = _make_map_node(_make_client(VARDHEIM_CAMP), null, _make_rig(), _root)
	assert_true(without_view.get_fortress_lines().is_empty(), "without a view there are no fort lines")


func test_opening_the_map_frees_the_cursor_and_closing_gives_it_back() -> void:
	var rig: CameraRig = _make_rig()
	var world_map: WorldMap = _make_map_node(_make_client(VARDHEIM_CAMP), null, rig, _root)
	var opened: Array[int] = [0]
	var closed: Array[int] = [0]
	world_map.opened.connect(func() -> void: opened[0] += 1)
	world_map.closed.connect(func() -> void: closed[0] += 1)
	assert_false(world_map.visible)
	world_map.toggle()
	assert_true(world_map.is_open() and world_map.visible)
	assert_true(rig.is_cursor_free(), "open, the cursor is left free")
	world_map.open()
	assert_eq(opened[0], 1, "opening an open map does not repeat the signal")
	world_map.toggle()
	assert_false(world_map.is_open() or world_map.visible)
	assert_false(rig.is_cursor_free(), "closed, the cursor returns")
	assert_eq(closed[0], 1)
	world_map.close()
	assert_eq(closed[0], 1, "cerrar un mapa cerrado no hace nada")
	# The map closes with the cursor key (Esc) and no stray cursor is left if it disappears while open.
	world_map.open()
	var escape := InputEventAction.new()
	escape.action = &"toggle_cursor"
	escape.pressed = true
	if not InputMap.has_action(&"toggle_cursor"):
		InputBindings.ensure_defaults()
	world_map._unhandled_input(escape)
	assert_false(world_map.is_open(), "Esc lo cierra")


# --- Full map: respawn choice -----------------------------------------------------------------

## A zone with the twelve Vado Gris markers (four per camp and four in the fort's courtyard),
## in the same order and with the same metadata as the real scene.
func _synthetic_zone() -> Node3D:
	var zone: Node3D = _track(Node3D.new()) as Node3D
	var camps: Array = [[&"vardheim", Vector3(0.0, 6.25, -138.0), "CampamentoVardheim"],
			[&"solmarch", Vector3(0.0, 6.25, 138.0), "CampamentoSolmarch"]]
	for camp: Array in camps:
		for i: int in 4:
			var marker := Marker3D.new()
			marker.name = "%s%d" % [camp[2], i + 1]
			zone.add_child(marker)
			marker.global_position = (camp[1] as Vector3) + Vector3(float(i) * 2.0, 0.0, 0.0)
			marker.add_to_group(Zones.RESPAWN_GROUP)
			marker.set_meta(&"realm", camp[0])
	for i: int in 4:
		var marker := Marker3D.new()
		marker.name = "PatioFuerte%d" % (i + 1)
		zone.add_child(marker)
		marker.global_position = Vector3(float(i) * 2.0 - 3.0, 10.2, 8.0)
		marker.add_to_group(Zones.RESPAWN_GROUP)
		marker.set_meta(&"fortress", FORT_ID)
	return zone


func _option_labels(options: Array[RespawnPointList.Option], only_valid: bool = false) -> PackedStringArray:
	var labels: PackedStringArray = PackedStringArray()
	for option: RespawnPointList.Option in options:
		if option.valid or not only_valid:
			labels.append(option.label)
	return labels


func test_the_respawn_options_group_each_site_and_follow_the_fortress_state() -> void:
	var zone: Node3D = _synthetic_zone()
	var neutral: Dictionary = {FORT_ID: FortressState.initial(_def, 0)}
	var names: Dictionary = {FORT_ID: "Fuerte del Vado Gris"}
	var options: Array[RespawnPointList.Option] = RespawnPointList.options(zone, VARDHEIM, neutral, 1000, names)
	assert_eq(options.size(), 3, "three sites: two camps and the fort")
	assert_eq(_option_labels(options), PackedStringArray(["Campamento de Vardheim", "Campamento de Solmarch",
			"Fuerte del Vado Gris"]), "in the scene's order, with the fort's name")
	assert_eq(_option_labels(options, true), PackedStringArray(["Campamento de Vardheim"]),
			"with the fort neutral, only the player's own camp")
	assert_eq(options[0].members, PackedInt32Array([0, 1, 2, 3]), "the four camp points are one option")
	assert_eq(options[1].members, PackedInt32Array([4, 5, 6, 7]))
	assert_eq(options[2].members, PackedInt32Array([8, 9, 10, 11]))
	assert_eq(options[2].fortress_id, FORT_ID)
	assert_eq(options[0].realm, VARDHEIM)
	var owned: FortressState = FortressState.initial(_def, 0)
	owned.owner = VARDHEIM
	var with_fort: Array[RespawnPointList.Option] = RespawnPointList.options(zone, VARDHEIM, {FORT_ID: owned}, 1000, names)
	assert_eq(_option_labels(with_fort, true), PackedStringArray(["Campamento de Vardheim", "Fuerte del Vado Gris"]),
			"with the fort owned and calm, the interior too")
	var enemy: Array[RespawnPointList.Option] = RespawnPointList.options(zone, SOLMARCH, {FORT_ID: owned}, 1000, names)
	assert_eq(_option_labels(enemy, true), PackedStringArray(["Campamento de Solmarch"]), "for the rival, only theirs")
	owned.under_attack_until_tick = 1500
	var attacked: Array[RespawnPointList.Option] = RespawnPointList.options(zone, VARDHEIM, {FORT_ID: owned}, 1000, names)
	assert_eq(_option_labels(attacked, true), PackedStringArray(["Campamento de Vardheim"]), "atacado, no")
	var calm_again: Array[RespawnPointList.Option] = RespawnPointList.options(zone, VARDHEIM, {FORT_ID: owned}, 1500, names)
	assert_eq(_option_labels(calm_again, true).size(), 2, "and it returns on the exact tick the attack ends")


func test_each_option_sends_the_index_of_one_of_its_markers_spread_by_player() -> void:
	var zone: Node3D = _synthetic_zone()
	var options: Array[RespawnPointList.Option] = RespawnPointList.options(zone, VARDHEIM, {}, 1000)
	var camp: RespawnPointList.Option = options[0]
	var seen: Dictionary = {}
	for player: int in 8:
		var index: int = camp.index_for(player)
		assert_true(camp.has_member(index), "index %d is of a camp marker" % index)
		seen[index] = true
	assert_eq(seen.size(), 4, "with eight players the four markers come out: they do not stack")
	assert_eq(RespawnPointList.option_indices(options, 5), PackedInt32Array([1, 5, 9]),
			"player 5 sends the 2nd of each site (position 5 % 4)")


func test_the_real_vado_gris_offers_three_sites() -> void:
	var zone: Node3D = (load(ZONE_SCENE_PATH) as PackedScene).instantiate() as Node3D
	tree.root.add_child(zone)
	var neutral: Dictionary = {FORT_ID: FortressState.initial(_def, 0)}
	var options: Array[RespawnPointList.Option] = RespawnPointList.options(zone, SOLMARCH, neutral, 1000,
			{FORT_ID: _def.display_name})
	assert_eq(options.size(), 3, "each realm's camp and the fort")
	var valid: Array[RespawnPointList.Option] = RespawnPointList.valid_options(zone, SOLMARCH, neutral, 1000)
	assert_eq(valid.size(), 1, "Solmarch, with the fort neutral, only its camp")
	assert_eq(valid[0].label, "Campamento de Solmarch")
	assert_eq(valid[0].members, PackedInt32Array([4, 5, 6, 7]), "the index is the position among the twelve markers")
	zone.get_parent().remove_child(zone)
	zone.queue_free()
	await wait_process_frames()


func test_clicking_a_valid_option_chooses_it_and_an_invalid_one_does_nothing() -> void:
	var zone: Node3D = _synthetic_zone()
	var owned: FortressState = FortressState.initial(_def, 0)
	owned.owner = SOLMARCH
	var view: FortressView = _fort_view({FortressFields.OWNER: SOLMARCH})
	var client: FakeClient = _make_client(VARDHEIM_CAMP)
	var world_map: WorldMap = _make_map_node(client, view, _make_rig(), zone)
	var chosen: Array[RespawnPointList.Option] = []
	world_map.respawn_option_chosen.connect(func(option: RespawnPointList.Option) -> void: chosen.append(option))
	world_map.open()
	assert_eq(world_map.get_option_at(world_map.world_to_screen(VARDHEIM_CAMP)), -1,
			"outside respawn mode the points cannot be clicked")
	assert_false(world_map.click_at(world_map.world_to_screen(VARDHEIM_CAMP)))
	world_map.open(true)
	assert_true(world_map.is_respawn_mode())
	assert_eq(world_map.get_options().size(), 3)
	var camp_at: Vector2 = world_map.world_to_screen(Vector3(3.0, 6.25, -138.0))
	var camp_index: int = world_map.get_option_at(camp_at)
	assert_eq(camp_index, 0, "the Vardheim camp, under the cursor")
	assert_true(world_map.click_at(camp_at), "is valid")
	assert_eq(chosen.size(), 1)
	assert_eq(chosen[0].label, "Campamento de Vardheim")
	assert_false(world_map.click_at(world_map.world_to_screen(Vector3(3.0, 6.25, 138.0))),
			"the rival's camp cannot be chosen")
	assert_false(world_map.click_at(world_map.world_to_screen(Vector3(-3.0, 10.2, 8.0))),
			"nor can the rival's fort")
	assert_eq(chosen.size(), 1, "and nothing is emitted")
	assert_false(world_map.click_at(world_map.world_to_screen(Vector3(80.0, 0.0, 80.0))), "nor the void")
	# The fort becomes Vardheim's: it can now be chosen (with the same map open).
	view.on_object_state(_owner_change(200, VARDHEIM))
	client.fake_tick = 300
	world_map.refresh()
	var fort_at: Vector2 = world_map.world_to_screen(Vector3(-3.0, 10.2, 8.0))
	assert_true(world_map.click_at(fort_at), "with the fort won, yes")
	assert_eq(chosen[1].label, "Fuerte del Vado Gris", "and it is named like the fort")
	world_map.close()
	assert_false(world_map.is_respawn_mode(), "on closing, respawn mode is left")


func _owner_change(tick: int, owner_realm: int) -> NetMessages.ObjectState:
	var change := NetMessages.ObjectState.new()
	change.net_id = NET_ID
	change.tick = tick
	change.add_field(FortressFields.OWNER, NetMessages.ObjectField.ValueType.U8, owner_realm)
	return change


# --- The HUD with the death screen ------------------------------------------------------------

class HudRig:
	var hud: HUD
	var client: FakeClient
	var rig: CameraRig
	var world: Node3D
	var view: FortressView


func _make_hud() -> HudRig:
	var h := HudRig.new()
	h.world = _synthetic_zone()
	h.client = _make_client(VARDHEIM_CAMP)
	h.rig = _make_rig()
	h.hud = (load(HUD_SCENE_PATH) as PackedScene).instantiate() as HUD
	_track(h.hud)
	h.hud.bind(h.client.fake_character, h.rig)
	h.hud.bind_net(h.client, h.world)
	h.view = h.client.get_fortress_view()
	return h


## Kills the local player on the fake client and lets the HUD open the death screen.
func _die(h: HudRig) -> void:
	h.client.fake_dead = true
	h.client.fake_respawn_tick = h.client.fake_tick + 600
	h.client.fake_snapshot_tick = h.client.fake_tick
	h.hud._process(0.016)


func test_the_hud_mounts_the_minimap_and_the_map_above_the_death_screen() -> void:
	var h: HudRig = _make_hud()
	assert_not_null(h.hud.get_war_hud().get_minimap(), "the minimap hangs from the war interface")
	var world_map: WorldMap = h.hud.get_world_map()
	if not assert_not_null(world_map, "and the HUD's map"):
		return
	assert_true(world_map.get_index() > h.hud.get_death_screen().get_index(), "above the death screen")
	assert_false(world_map.visible, "closed at the start")
	var hints: String = h.hud.get_node(^"HintLabel").get_plain_text()
	assert_true(hints.contains("Mapa") and hints.contains("Marcador"), "the help line states the new keys: %s" % hints)


func test_the_death_screen_lists_the_valid_sites_and_sends_the_index_of_the_one_chosen() -> void:
	var h: HudRig = _make_hud()
	var screen: DeathScreen = h.hud.get_death_screen()
	_die(h)
	assert_true(screen.is_open())
	assert_eq(screen.get_point_count(), 1, "with the fort neutral, only the player's own camp")
	assert_eq(screen.get_point_label(0), "Campamento de Vardheim")
	assert_false(screen.get_map_button().visible, "with a single option the map is not needed")
	assert_eq(h.hud.get_hints().get_current_id(), &"", "nor does the map hint appear")
	h.view.on_spawn(_fortress_spawn(100, {FortressFields.OWNER: VARDHEIM}))
	h.hud._process(0.016)
	assert_eq(screen.get_point_count(), 2, "when the fort comes into their hands, the list updates without closing")
	assert_eq(screen.get_point_label(1), "Fuerte del Vado Gris")
	assert_true(screen.get_map_button().visible, "and with two options \"Elegir en el mapa\" (Choose on the map) appears")
	assert_eq(h.hud.get_hints().get_current_id(), HintCatalog.RESPAWN_MAP,
			"and the map hint, when the second appears with the screen already open")
	assert_eq(screen.get_selected_point_index(), RespawnPointList.option_indices(
			RespawnPointList.valid_options(h.world, VARDHEIM, h.view.get_states_by_definition(1000), 1000), OWN_ID)[0],
			"and it keeps the choice")
	h.client.fake_tick = h.client.fake_respawn_tick
	h.hud._process(0.016)
	screen.select_point(1)
	screen.get_button().pressed.emit()
	assert_eq(h.client.respawn_requests.size(), 1)
	assert_eq(h.client.respawn_requests[0], 8 + OWN_ID % 4, "the fort marker's index among the twelve, spread per player")


func test_choosing_on_the_map_selects_the_site_and_returns_to_the_death_screen() -> void:
	var h: HudRig = _make_hud()
	h.view.on_spawn(_fortress_spawn(100, {FortressFields.OWNER: VARDHEIM}))
	var screen: DeathScreen = h.hud.get_death_screen()
	var world_map: WorldMap = h.hud.get_world_map()
	_die(h)
	assert_eq(screen.get_point_count(), 2)
	assert_eq(h.hud.get_hints().get_current_id(), HintCatalog.RESPAWN_MAP,
			"with two sites to choose from, the map hint appears")
	assert_eq(screen.get_selected_point(), 0, "it starts at the first")
	screen.get_map_button().pressed.emit()
	assert_true(world_map.is_open(), "the button opens the map")
	assert_true(world_map.is_respawn_mode(), "in respawn mode")
	_fix_size(world_map)
	assert_true(world_map.click_at(world_map.world_to_screen(Vector3(-3.0, 10.2, 8.0))), "the fort is clicked")
	assert_false(world_map.is_open(), "choosing returns to the death screen")
	assert_true(screen.is_open())
	assert_eq(screen.get_selected_point(), 1, "with the fort chosen in the list")
	assert_eq(screen.get_selected_point_index(), 8 + OWN_ID % 4)
	# M with the screen open also opens the map to choose.
	world_map.open()
	assert_true(world_map.is_respawn_mode(), "opened with the death screen in front, it is for choosing")
	world_map.close()
	# On respawn, a map opened to choose closes by itself.
	world_map.open(true)
	h.client.fake_dead = false
	h.client.fake_respawn_tick = 0
	h.client.fake_snapshot_tick = 2000
	h.hud._process(0.016)
	assert_false(screen.is_open())
	assert_false(world_map.is_open(), "respawning closes the choosing map")
	assert_false(h.rig.is_cursor_free(), "and the cursor returns to the camera")


func test_a_map_opened_while_alive_is_not_in_respawn_mode_and_survives_the_hud_refresh() -> void:
	var h: HudRig = _make_hud()
	var world_map: WorldMap = h.hud.get_world_map()
	world_map.open()
	assert_false(world_map.is_respawn_mode())
	h.hud._process(0.016)
	assert_true(world_map.is_open(), "alive, the HUD does not close it")
	assert_eq(world_map.get_options().size(), 0, "nor does it offer respawn")
	world_map.close()


# --- The death screen does not keep the keyboard ----------------------------------------------

## Presses and releases the mouse at the center of [param control], through the window's input (in its coordinates: the
## test window is small and scales the content).
func _click(control: Control) -> void:
	var center: Vector2 = tree.root.get_final_transform() * control.get_global_transform_with_canvas() \
			* (control.size * 0.5)
	for pressed: bool in [true, false]:
		var click := InputEventMouseButton.new()
		click.button_index = MOUSE_BUTTON_LEFT
		click.pressed = pressed
		click.position = center
		click.global_position = center
		tree.root.push_input(click)


## Presses or releases the key [param keycode], through the window's input.
func _push_key(keycode: Key, pressed: bool) -> void:
	var key := InputEventKey.new()
	key.physical_keycode = keycode
	key.keycode = keycode
	key.pressed = pressed
	tree.root.push_input(key)


## Phase 4 review (client): the death screen is driven with the mouse. If a click on a point or on a
## template gave that control focus, Tab moved it to the next one (instead of opening the scoreboard, which is mounted on top
## so the dead player can see it) and Enter or Space pressed \"Reaparecer\" (Respawn).
func test_after_clicking_the_death_screen_tab_still_shows_the_scoreboard_and_enter_does_not_respawn() -> void:
	var h: HudRig = _make_hud()
	h.view.on_spawn(_fortress_spawn(100, {FortressFields.OWNER: VARDHEIM}))
	var screen: DeathScreen = h.hud.get_death_screen()
	_die(h)
	h.client.fake_tick = h.client.fake_respawn_tick
	h.hud._process(0.016)
	assert_true(screen.is_respawn_enabled(), "it can now respawn")
	await wait_process_frames(2)
	var selector: TemplateSelector = screen.get_template_selector()
	var template_button: Button = selector.get_button(selector.get_template_ids()[0])
	_click(template_button)
	assert_true(template_button.button_pressed, "the click chooses the template")
	assert_null(tree.root.gui_get_focus_owner(), "without keeping the focus")
	var board: ScoreboardPanel = h.hud.get_scoreboard()
	_push_key(KEY_TAB, true)
	assert_true(board.is_open(), "Tab opens the scoreboard even after choosing a template")
	_push_key(KEY_TAB, false)
	assert_false(board.is_open(), "and on release it closes")
	_push_key(KEY_ENTER, true)
	_push_key(KEY_ENTER, false)
	_push_key(KEY_SPACE, true)
	_push_key(KEY_SPACE, false)
	assert_eq(h.client.respawn_requests.size(), 0, "ni Intro ni Espacio pulsan «Reaparecer»")
	# The same after clicking in the point list.
	var points: ItemList = screen.get_node(^"Centro/Columna/Puntos") as ItemList
	_click(points)
	assert_null(tree.root.gui_get_focus_owner(), "the list does not keep the focus either")
	_push_key(KEY_TAB, true)
	assert_true(board.is_open(), "and Tab is still the scoreboard")
	_push_key(KEY_TAB, false)
	for control: Control in [points, screen.get_map_button(), screen.get_button(), template_button]:
		assert_eq(control.focus_mode, Control.FOCUS_NONE, "%s does not take focus" % control.name)
	# The button still works with the mouse.
	_click(screen.get_button())
	assert_eq(h.client.respawn_requests.size(), 1, "a click on \"Reaparecer\" does respawn")


# --- The hints with the death screen and the map -----------------------------------------------

## Opacity with which [param item] is painted: its own times that of all its interface parents.
func _effective_alpha(item: CanvasItem) -> float:
	var alpha: float = 1.0
	var node: Node = item
	while node is CanvasItem:
		alpha *= (node as CanvasItem).modulate.a * (node as CanvasItem).self_modulate.a
		node = node.get_parent()
	return alpha


## Phase 4 review (client): the hints lived in the war interface, below the death screen
## and dimmed along with it, and were recorded as seen as soon as they appeared. The respawn one (which is only requested with the death
## screen open) was always lost without being readable; the others, if they arrived while dead or with the map open.
func test_the_hints_show_above_the_death_screen_undimmed_and_wait_while_the_map_covers_them() -> void:
	var h: HudRig = _make_hud()
	h.view.on_spawn(_fortress_spawn(100, {FortressFields.OWNER: VARDHEIM}))
	var hints: HintToasts = h.hud.get_hints()
	if not assert_not_null(hints, "the networked HUD mounts the hints"):
		return
	var screen: DeathScreen = h.hud.get_death_screen()
	var world_map: WorldMap = h.hud.get_world_map()
	assert_true(hints.get_index() > screen.get_index(), "above the death screen")
	assert_true(hints.get_index() < world_map.get_index(), "and below the map")
	assert_true(hints.get_index() < h.hud.get_scoreboard().get_index(), "and the scoreboard")
	_die(h)
	assert_true(h.hud.is_dimmed(), "dead, the game interface dims")
	assert_eq(hints.get_current_id(), HintCatalog.RESPAWN_MAP, "and the respawn hint appears")
	assert_true(hints.is_showing())
	assert_near(_effective_alpha(hints.get_panel()), 1.0, 1e-6, "not dimmed")
	var log: HintLog = HintLog.current()
	assert_false(log.has_shown(HintCatalog.RESPAWN_MAP), "it is not recorded until it has been seen for a while")
	hints.advance(HintToasts.MIN_SEEN_SECONDS * 0.5)
	# The player opens the map (what the hint asks for) before finishing reading it: the map covers it.
	screen.get_map_button().pressed.emit()
	assert_true(world_map.is_open())
	hints.advance(0.016)
	assert_false(hints.is_showing(), "covered by the map, it is removed")
	assert_eq(hints.get_queued_ids(), [HintCatalog.RESPAWN_MAP] as Array[StringName], "and goes back to the queue")
	assert_false(log.has_shown(HintCatalog.RESPAWN_MAP), "without being recorded")
	hints.advance(HintToasts.GAP_SECONDS + HintToasts.SHOW_SECONDS)
	assert_false(hints.is_showing(), "with the map open nothing appears")
	world_map.close()
	hints.advance(0.016)
	assert_eq(hints.get_current_id(), HintCatalog.RESPAWN_MAP, "on closing it, it appears again")
	hints.advance(HintToasts.MIN_SEEN_SECONDS + 0.1)
	assert_true(log.has_shown(HintCatalog.RESPAWN_MAP), "seen long enough, recorded")
	assert_true(hints.is_showing(), "and it stays until its time is up")


func test_a_respawn_hint_not_yet_read_leaves_with_the_death_screen_and_comes_back_next_time() -> void:
	var h: HudRig = _make_hud()
	h.view.on_spawn(_fortress_spawn(100, {FortressFields.OWNER: VARDHEIM}))
	var hints: HintToasts = h.hud.get_hints()
	_die(h)
	assert_eq(hints.get_current_id(), HintCatalog.RESPAWN_MAP)
	hints.advance(1.0)
	# Respawns right away: the hint no longer applies and does not count as seen.
	h.client.fake_dead = false
	h.client.fake_respawn_tick = 0
	h.client.fake_snapshot_tick = 2000
	h.hud._process(0.016)
	assert_false(h.hud.get_death_screen().is_open())
	assert_false(hints.is_showing(), "it is removed when the death screen closes")
	assert_false(hints.get_queued_ids().has(HintCatalog.RESPAWN_MAP), "and does not stay in the queue")
	assert_false(HintLog.current().has_shown(HintCatalog.RESPAWN_MAP), "without being recorded")
	hints.advance(HintToasts.GAP_SECONDS + 0.1)
	h.client.fake_tick = 3000
	h.client.fake_snapshot_tick = 3000
	_die(h)
	hints.advance(HintToasts.GAP_SECONDS + 0.1)
	assert_eq(hints.get_current_id(), HintCatalog.RESPAWN_MAP, "the next death shows it again")
