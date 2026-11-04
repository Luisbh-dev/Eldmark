extends TestCase
## Pruebas de la brújula y los marcadores del mundo (UI-19, docs/fuerte.md sección 6): [Compass]
## (rumbos, norte = -Z, coincidencia con el yaw de la cámara), [WorldMarkers] (proyección a la pantalla,
## borde, desvanecido de cerca) y [MarkerSource] (de dónde salen los marcadores y con qué color). Los
## lugares son los del Vado Gris: el fuerte en el centro y un campamento a cada lado, a 138 m.

const VARDHEIM: int = NetProtocol.Realm.VARDHEIM
const SOLMARCH: int = NetProtocol.Realm.SOLMARCH
const ZONE_ID: StringName = &"vado_gris"
const DEFINITION_PATH: String = "res://data/fortresses/vado_gris.tres"
const FORT_SCENE_PATH: String = "res://scenes/world/props/fort/vado_gris_fort.tscn"
const CHARACTER_SCENE_PATH: String = "res://scenes/characters/player_character.tscn"
const CAMERA_RIG_SCENE_PATH: String = "res://scenes/client/camera_rig.tscn"
## Campamentos del Vado Gris (marcadores de zona segura) y ojo de quien está de pie en ellos.
const VARDHEIM_CAMP: Vector3 = Vector3(0.0, 6.25, -138.0)
const SOLMARCH_CAMP: Vector3 = Vector3(0.0, 6.25, 138.0)
const EYE: Vector3 = Vector3(0.0, 1.7, 0.0)
const NET_ID: int = 900


class FakeClient extends NetClient:
	var fake_character: PlayerCharacter = null

	func get_character() -> PlayerCharacter:
		return fake_character

	func get_config() -> ClientConfig:
		var config := ClientConfig.new()
		config.realm = VARDHEIM
		return config


var _root: Node3D = null
var _nodes: Array[Node] = []
var _map: ZoneMapDefinition = null
var _def: FortressDefinition = null


func before_each() -> void:
	_map = ZoneMapDefinition.load_for_zone(ZONE_ID)
	_def = load(DEFINITION_PATH) as FortressDefinition
	_root = Node3D.new()
	_root.name = "CompassTest"
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


# --- Rumbos -----------------------------------------------------------------------------------

func test_the_heading_follows_the_yaw_with_north_at_minus_z() -> void:
	assert_near(Compass.heading_of_yaw(0.0), 0.0, 1e-6, "yaw 0 mira a -Z: norte")
	assert_near(Compass.heading_of_yaw(-PI * 0.5), 90.0, 1e-6, "yaw -90° mira a +X: este")
	assert_near(Compass.heading_of_yaw(PI), 180.0, 1e-6, "yaw 180° mira a +Z: sur")
	assert_near(Compass.heading_of_yaw(PI * 0.5), 270.0, 1e-6, "yaw 90° mira a -X: oeste")
	assert_near(Compass.heading_of_yaw(0.1), 360.0 - rad_to_deg(0.1), 1e-6, "girar a la izquierda baja el rumbo")
	# Misma convención que el movimiento: el vector de avance de un yaw da el rumbo del yaw.
	for yaw: float in [0.0, 0.7, -1.3, 2.9, -3.0]:
		var forward: Vector3 = Basis(Vector3.UP, yaw) * Vector3.FORWARD
		assert_near(Compass.bearing_to(Vector3.ZERO, forward * 10.0), Compass.heading_of_yaw(yaw), 1e-4,
				"el rumbo del avance con yaw %.2f" % yaw)


func test_bearings_to_the_four_directions_and_relative_angles() -> void:
	var origin := Vector3(5.0, 3.0, 5.0)
	assert_near(Compass.bearing_to(origin, origin + Vector3(0.0, 0.0, -10.0)), 0.0, 1e-6, "al norte")
	assert_near(Compass.bearing_to(origin, origin + Vector3(10.0, 0.0, 0.0)), 90.0, 1e-6, "al este")
	assert_near(Compass.bearing_to(origin, origin + Vector3(0.0, 9.0, 10.0)), 180.0, 1e-6, "al sur, la altura no cuenta")
	assert_near(Compass.bearing_to(origin, origin + Vector3(-10.0, 0.0, 0.0)), 270.0, 1e-6, "al oeste")
	assert_near(Compass.bearing_to(origin, origin + Vector3(10.0, 0.0, -10.0)), 45.0, 1e-6, "al noreste")
	assert_near(Compass.relative_bearing(90.0, 0.0), 90.0, 1e-9, "el este mirando al norte: a la derecha")
	assert_near(Compass.relative_bearing(270.0, 0.0), -90.0, 1e-9, "el oeste: a la izquierda")
	assert_near(Compass.relative_bearing(10.0, 350.0), 20.0, 1e-9, "cruzando el norte")
	assert_near(Compass.relative_bearing(350.0, 10.0), -20.0, 1e-9)
	assert_near(absf(Compass.relative_bearing(180.0, 0.0)), 180.0, 1e-9, "a la espalda")


func test_cardinal_names_and_heading_text_are_in_spanish() -> void:
	assert_eq(Compass.cardinal_of(0.0), "N")
	assert_eq(Compass.cardinal_of(44.0), "NE")
	assert_eq(Compass.cardinal_of(90.0), "E")
	assert_eq(Compass.cardinal_of(135.0), "SE")
	assert_eq(Compass.cardinal_of(180.0), "S")
	assert_eq(Compass.cardinal_of(200.0), "S")
	assert_eq(Compass.cardinal_of(225.0), "SO", "suroeste, en español")
	assert_eq(Compass.cardinal_of(270.0), "O", "oeste")
	assert_eq(Compass.cardinal_of(315.0), "NO")
	assert_eq(Compass.cardinal_of(359.0), "N", "casi 360 vuelve al norte")
	assert_eq(Compass.heading_text(5.0), "005° N")
	assert_eq(Compass.heading_text(359.7), "000° N")
	assert_eq(Compass.heading_text(135.2), "135° SE")


func test_the_tape_places_a_relative_bearing_and_cuts_at_the_span() -> void:
	assert_near(Compass.tape_x(0.0), Compass.WIDTH * 0.5, 1e-9, "delante: el centro")
	assert_near(Compass.tape_x(90.0), Compass.WIDTH, 1e-9, "a 90° a la derecha, el borde")
	assert_near(Compass.tape_x(-90.0), 0.0, 1e-9)
	assert_near(Compass.tape_x(45.0), Compass.WIDTH * 0.75, 1e-9)
	assert_eq(Compass.tape_x(91.0), INF, "pasado el arco, fuera")
	assert_eq(Compass.tape_x(-120.0), -INF)


func test_the_compass_follows_the_cameras_real_orientation() -> void:
	var rig: CameraRig = (load(CAMERA_RIG_SCENE_PATH) as PackedScene).instantiate() as CameraRig
	rig.set_scripted_look(false)
	_track(rig)
	await wait_process_frames(2)
	for yaw: float in [0.0, -PI * 0.5, PI * 0.5, 2.0, -2.5, 0.4]:
		rig.set_look(yaw, 0.0)
		await wait_process_frames(2)
		var forward: Vector3 = -rig.get_camera().global_transform.basis.z
		var camera_bearing: float = fposmod(rad_to_deg(atan2(forward.x, -forward.z)), 360.0)
		var compass_heading: float = Compass.heading_of_yaw(rig.get_yaw())
		var difference: float = absf(wrapf(camera_bearing - compass_heading, -180.0, 180.0))
		assert_true(difference < 0.01, "yaw %.2f: la cámara mira al rumbo %.2f y la brújula marca %.2f" % [yaw, camera_bearing, compass_heading])


# --- Brújula con los lugares del Vado Gris ----------------------------------------------------

func test_from_each_camp_the_fort_is_straight_ahead_when_looking_at_it() -> void:
	if not assert_not_null(_map, "el mapa del Vado Gris"):
		return
	var markers: Array[WorldMarker] = MarkerSource.build(_map, null)
	var compass: Compass = _track(Compass.new()) as Compass
	# Vardheim está al norte: mira al sur (+Z) hacia el fuerte.
	compass.update_view(PI, VARDHEIM_CAMP, markers)
	assert_near(compass.get_heading(), 180.0, 1e-6)
	assert_eq(compass.get_heading_text(), "180° S")
	var fort: Dictionary = _entry_of(compass, &"fort_vado_gris_fort")
	if assert_false(fort.is_empty(), "el fuerte sale en la brújula"):
		assert_near(float(fort["relative"]), 0.0, 1e-6, "justo delante")
		assert_near(float(fort["x"]), Compass.WIDTH * 0.5, 1e-6, "en el centro de la cinta")
	assert_true(_entry_of(compass, &"pass_puerta_del_muro_de_escarcha").is_empty(),
			"la puerta de la muralla de Vardheim queda a su espalda y no sale")
	assert_false(_entry_of(compass, &"camp_2").is_empty(), "el campamento de Solmarch, tras el fuerte, a 276 m, también queda delante")
	# Solmarch está al sur: mira al norte (-Z).
	compass.update_view(0.0, SOLMARCH_CAMP, markers)
	assert_eq(compass.get_heading_text(), "000° N")
	fort = _entry_of(compass, &"fort_vado_gris_fort")
	if assert_false(fort.is_empty()):
		assert_near(float(fort["relative"]), 0.0, 1e-6, "también justo delante")
	assert_true(_entry_of(compass, &"pass_puerta_de_la_muralla_del_alba").is_empty(), "su muralla queda a la espalda")


func test_turning_moves_the_markers_across_the_tape() -> void:
	var markers: Array[WorldMarker] = MarkerSource.build(_map, null)
	var compass: Compass = _track(Compass.new()) as Compass
	# Desde el campamento de Vardheim el fuerte está al sur. Mirando 40° hacia el oeste de él (yaw 180° - 40°)
	# el fuerte queda 40° a la izquierda de donde se mira, y al otro lado, 40° a la derecha.
	compass.update_view(PI - deg_to_rad(40.0), VARDHEIM_CAMP, markers)
	var left: Dictionary = _entry_of(compass, &"fort_vado_gris_fort")
	compass.update_view(PI + deg_to_rad(40.0), VARDHEIM_CAMP, markers)
	var right: Dictionary = _entry_of(compass, &"fort_vado_gris_fort")
	if not assert_false(left.is_empty()) or not assert_false(right.is_empty()):
		return
	assert_near(float(left["relative"]), -40.0, 1e-4, "girado a la izquierda del sur, el fuerte queda 40° a la izquierda")
	assert_true(float(left["x"]) < Compass.WIDTH * 0.5)
	assert_near(float(right["relative"]), 40.0, 1e-4, "y al otro lado, 40° a la derecha")
	assert_true(float(right["x"]) > Compass.WIDTH * 0.5)
	assert_true(absf(float(left["x"]) - Compass.WIDTH * 0.5) < Compass.WIDTH * 0.5, "dentro de la cinta")
	# Mirando al este, 80° a la izquierda del sur... el fuerte queda a 100° y ya no cabe en la cinta de 180°.
	compass.update_view(-deg_to_rad(80.0), VARDHEIM_CAMP, markers)
	assert_true(_entry_of(compass, &"fort_vado_gris_fort").is_empty(), "a más de 90° ya no cabe en la cinta")
	compass.update_view(-deg_to_rad(100.0), VARDHEIM_CAMP, markers)
	var edge: Dictionary = _entry_of(compass, &"fort_vado_gris_fort")
	assert_false(edge.is_empty(), "a 80° sí")
	assert_true(float(edge["x"]) > Compass.WIDTH * 0.8, "cerca del borde derecho")


func test_compass_markers_are_sorted_far_to_near_and_a_marker_underfoot_is_skipped() -> void:
	var compass: Compass = _track(Compass.new()) as Compass
	var near: WorldMarker = WorldMarker.make(&"near", WorldMarker.Kind.CAMP, "Cerca", Vector3(0.0, 0.0, -10.0), Color.WHITE)
	var far: WorldMarker = WorldMarker.make(&"far", WorldMarker.Kind.FORT, "Lejos", Vector3(0.0, 0.0, -100.0), Color.WHITE)
	var here: WorldMarker = WorldMarker.make(&"here", WorldMarker.Kind.PASS, "Aquí", Vector3(0.0, 0.0, 0.0), Color.WHITE)
	var markers: Array[WorldMarker] = [near, far, here]
	compass.update_view(0.0, Vector3.ZERO, markers)
	var visible: Array[Dictionary] = compass.get_visible_markers()
	assert_eq(visible.size(), 2, "el que se pisa no sale")
	assert_eq((visible[0]["marker"] as WorldMarker).id, &"far", "el más lejano se dibuja primero")
	assert_eq((visible[1]["marker"] as WorldMarker).id, &"near")


# --- Marcadores en pantalla -------------------------------------------------------------------

func test_markers_project_onto_the_screen_and_stick_to_the_border_when_out_of_view() -> void:
	var camera: Camera3D = await _make_camera(VARDHEIM_CAMP + EYE, VARDHEIM_CAMP + EYE + Vector3(0.0, 0.0, 10.0))
	var size: Vector2 = camera.get_viewport().get_visible_rect().size
	var margin: float = WorldMarkers.EDGE_MARGIN
	# El fuerte (150 m al frente, algo más alto) cae cerca del centro.
	var ahead: Dictionary = WorldMarkers.project(camera, size, Vector3(0.0, 10.2, 0.0), margin)
	assert_false(ahead["on_edge"], "delante y a la vista")
	assert_false(ahead["behind"])
	assert_near((ahead["screen"] as Vector2).x, size.x * 0.5, 1.0, "centrado en horizontal")
	assert_true((ahead["screen"] as Vector2).y < size.y * 0.5, "por encima del centro: está más alto que el ojo")
	# La puerta de la muralla de Vardheim queda detrás: pegada al borde.
	var behind: Dictionary = WorldMarkers.project(camera, size, Vector3(0.0, 6.2, -152.0), margin)
	assert_true(behind["behind"])
	assert_true(behind["on_edge"])
	assert_true(_is_on_border(behind["screen"], size, margin), "pegado al borde (%s)" % behind["screen"])
	# Un punto a la derecha de la vista (al oeste, mirando al sur, queda a la izquierda de la persona: x > centro
	# en la pantalla, porque mirando a +Z el oeste -X es la derecha).
	var right: Dictionary = WorldMarkers.project(camera, size, Vector3(-400.0, 6.2, -137.0), margin)
	assert_true(right["on_edge"], "fuera de la vista")
	assert_near((right["screen"] as Vector2).x, size.x - margin, 1e-3, "pegado al borde derecho")
	assert_true(float(right["angle"]) > 0.0, "y la flecha apunta hacia la derecha")
	var left: Dictionary = WorldMarkers.project(camera, size, Vector3(400.0, 6.2, -137.0), margin)
	assert_near((left["screen"] as Vector2).x, margin, 1e-3, "al otro lado, el borde izquierdo")
	assert_true(float(left["angle"]) < 0.0)


func test_from_each_camp_the_markers_point_the_same_way_as_the_compass() -> void:
	var markers: Array[WorldMarker] = MarkerSource.build(_map, null)
	var compass: Compass = _track(Compass.new()) as Compass
	for setup: Array in [[VARDHEIM_CAMP, 0.0], [VARDHEIM_CAMP, 60.0], [VARDHEIM_CAMP, -60.0], [VARDHEIM_CAMP, 200.0],
			[SOLMARCH_CAMP, 0.0], [SOLMARCH_CAMP, 70.0], [SOLMARCH_CAMP, -70.0], [SOLMARCH_CAMP, 250.0]]:
		var camp: Vector3 = setup[0]
		var yaw_degrees: float = setup[1]
		var yaw: float = deg_to_rad(yaw_degrees)
		# El yaw 0 mira al norte; el reino de Vardheim mira al sur a partir de PI.
		var facing: float = yaw + (PI if camp == VARDHEIM_CAMP else 0.0)
		var forward: Vector3 = Basis(Vector3.UP, facing) * Vector3.FORWARD
		var camera: Camera3D = await _make_camera(camp + EYE, camp + EYE + forward * 10.0)
		var size: Vector2 = camera.get_viewport().get_visible_rect().size
		compass.update_view(facing, camp, markers)
		var fort: WorldMarker = MarkerSource.find(markers, &"fort_vado_gris_fort")
		var projected: Dictionary = WorldMarkers.project(camera, size, fort.position + Vector3(0.0, 1.0, 0.0), WorldMarkers.EDGE_MARGIN)
		var relative: float = Compass.relative_bearing(Compass.bearing_to(camp, fort.position), compass.get_heading())
		if absf(relative) < 5.0:
			assert_false(projected["on_edge"], "%s, yaw %.0f: delante del todo, a la vista" % [camp, yaw_degrees])
			assert_near((projected["screen"] as Vector2).x, size.x * 0.5, 30.0, "%s, yaw %.0f: en el centro" % [camp, yaw_degrees])
		elif absf(relative) > 120.0:
			assert_true(projected["behind"], "%s, yaw %.0f: a la espalda" % [camp, yaw_degrees])
		elif relative > 0.0:
			assert_true((projected["screen"] as Vector2).x > size.x * 0.5, "%s, yaw %.0f: a la derecha, como dice la brújula (%.0f°)" % [camp, yaw_degrees, relative])
		else:
			assert_true((projected["screen"] as Vector2).x < size.x * 0.5, "%s, yaw %.0f: a la izquierda, como dice la brújula (%.0f°)" % [camp, yaw_degrees, relative])
		_nodes.erase(camera)
		camera.get_parent().remove_child(camera)
		camera.free()


func test_markers_fade_when_close_and_far_places_are_not_marked() -> void:
	assert_eq(WorldMarkers.fade_alpha(0.0), 0.0, "encima, invisible")
	assert_eq(WorldMarkers.fade_alpha(WorldMarkers.FADE_NEAR_START), 0.0)
	assert_eq(WorldMarkers.fade_alpha(WorldMarkers.FADE_NEAR_END), 1.0, "de lejos, opaco")
	assert_eq(WorldMarkers.fade_alpha(500.0), 1.0)
	var middle: float = WorldMarkers.fade_alpha((WorldMarkers.FADE_NEAR_START + WorldMarkers.FADE_NEAR_END) * 0.5)
	assert_true(middle > 0.2 and middle < 0.8, "y a medias, a medias (%.2f)" % middle)
	assert_eq(WorldMarkers.max_distance_for(WorldMarker.Kind.FORT), WorldMarkers.MAX_DISTANCE)
	assert_true(WorldMarkers.max_distance_for(WorldMarker.Kind.CIRCLE) < WorldMarkers.MAX_DISTANCE, "el círculo solo de cerca")


func test_world_markers_refresh_with_a_client_and_a_camera() -> void:
	var client: FakeClient = _track(FakeClient.new()) as FakeClient
	var character: PlayerCharacter = _track((load(CHARACTER_SCENE_PATH) as PackedScene).instantiate(), _root) as PlayerCharacter
	character.global_position = VARDHEIM_CAMP
	client.fake_character = character
	var rig: CameraRig = (load(CAMERA_RIG_SCENE_PATH) as PackedScene).instantiate() as CameraRig
	rig.set_scripted_look(false)
	_track(rig)
	var markers_node: WorldMarkers = _track(WorldMarkers.new()) as WorldMarkers
	markers_node.bind(client, null, rig, _map)
	rig.get_camera().global_transform = Transform3D(Basis(), VARDHEIM_CAMP + EYE).looking_at(
			VARDHEIM_CAMP + EYE + Vector3(0.0, 0.0, 10.0), Vector3.UP)
	rig.get_camera().reset_physics_interpolation()
	markers_node.refresh()
	var fort: Dictionary = markers_node.get_item(&"fort_vado_gris_fort")
	if assert_false(fort.is_empty(), "el fuerte se marca"):
		assert_near(float(fort["distance"]), 138.0, 0.01, "a 138 m")
		assert_eq(fort["alpha"], 1.0)
		assert_false(fort["on_edge"])
	var own_camp: Dictionary = markers_node.get_item(&"camp_1")
	if assert_false(own_camp.is_empty(), "y el propio campamento"):
		assert_eq(own_camp["alpha"], 0.0, "pero encima de él se desvanece")
	assert_eq(markers_node.get_item(&"camp_2"), {}, "el campamento enemigo, a 276 m, no se marca (UI-54)")
	assert_eq(markers_node.get_item(&"circle_1"), {}, "el círculo no está activo y no se marca")
	# Sin cliente o sin cámara no hay nada que marcar.
	markers_node.bind(null, null, rig, _map)
	markers_node.refresh()
	assert_true(markers_node.get_items().is_empty())


# --- De dónde salen los marcadores ------------------------------------------------------------

func test_markers_come_from_the_map_until_the_client_knows_the_fortress() -> void:
	var markers: Array[WorldMarker] = MarkerSource.build(_map, null)
	assert_eq(markers.size(), 5, "el fuerte, dos campamentos y dos pasos")
	var fort: WorldMarker = MarkerSource.find(markers, &"fort_vado_gris_fort")
	if assert_not_null(fort):
		assert_eq(fort.kind, WorldMarker.Kind.FORT)
		assert_eq(fort.label, "Fuerte del Vado Gris")
		assert_eq(fort.color, RealmCatalog.color_of(RealmCatalog.HUECOS), "sin estado, neutral")
	var camp: WorldMarker = MarkerSource.find(markers, &"camp_2")
	if assert_not_null(camp):
		assert_eq(camp.color, RealmCatalog.color_of(RealmCatalog.SOLMARCH))
		assert_eq(camp.label, "Campamento de Solmarch")
		assert_vec_near(camp.position, SOLMARCH_CAMP, 1e-3)
	var pass_marker: WorldMarker = MarkerSource.find(markers, &"pass_puerta_del_muro_de_escarcha")
	if assert_not_null(pass_marker):
		assert_eq(pass_marker.kind, WorldMarker.Kind.PASS)
		assert_eq(pass_marker.color, RealmCatalog.color_of(RealmCatalog.VARDHEIM))
	assert_eq(MarkerSource.build(null, null).size(), 0, "sin mapa ni vista no hay nada")
	assert_null(MarkerSource.find(markers, &"no_existe"))


func test_the_fortress_markers_take_the_owners_color_and_the_circle_only_when_active() -> void:
	var view: FortressView = _track(FortressView.new()) as FortressView
	var fort_node: Node3D = (load(FORT_SCENE_PATH) as PackedScene).instantiate() as Node3D
	fort_node.add_to_group(Zones.FORTRESS_GROUP)
	fort_node.set_meta(Zones.FORTRESS_DEFINITION_META, DEFINITION_PATH)
	_track(fort_node, _root)
	fort_node.global_position = Vector3(0.0, 10.2, 0.0)
	view.set_zone(_root)
	view.on_spawn(_spawn(100, {FortressFields.OWNER: SOLMARCH}))
	view.advance(100.0)
	var markers: Array[WorldMarker] = MarkerSource.build(_map, view)
	assert_eq(markers.size(), 2 + 2 + 2, "fuerte y puerta de la vista, dos campamentos y dos pasos (el círculo está inactivo)")
	var fort: WorldMarker = MarkerSource.find(markers, StringName("fort_%d" % NET_ID))
	if assert_not_null(fort, "el fuerte sale de la vista, no del mapa"):
		assert_eq(fort.color, RealmCatalog.color_of(RealmCatalog.SOLMARCH), "con el color de su dueño")
		assert_eq(fort.realm, SOLMARCH)
	assert_null(MarkerSource.find(markers, &"fort_vado_gris_fort"), "y el del mapa no se repite")
	var gate: WorldMarker = MarkerSource.find(markers, StringName("gate_%d" % NET_ID))
	if assert_not_null(gate, "la puerta"):
		assert_eq(gate.kind, WorldMarker.Kind.GATE)
		assert_vec_near(gate.position, view.get_gate_position(NET_ID), 1e-6)
		assert_eq(gate.color, RealmCatalog.color_of(RealmCatalog.SOLMARCH))
	assert_null(MarkerSource.find(markers, StringName("circle_%d" % NET_ID)), "el círculo inactivo no se marca")
	# El capitán cae: el círculo se activa en blanco; con una captura de Vardheim toma su color.
	var change := NetMessages.ObjectState.new()
	change.net_id = NET_ID
	change.tick = 200
	change.add_field(FortressFields.PHASE, NetMessages.ObjectField.ValueType.U8, FortressState.Phase.VULNERABLE)
	view.on_object_state(change)
	view.advance(200.0)
	var circle: WorldMarker = MarkerSource.find(MarkerSource.build(_map, view), StringName("circle_%d" % NET_ID))
	if assert_not_null(circle, "con el capitán caído el círculo se marca"):
		assert_eq(circle.color, MarkerSource.CIRCLE_COLOR)
		assert_vec_near(circle.position, view.get_circle_center(NET_ID), 1e-6)
		assert_eq(circle.kind, WorldMarker.Kind.CIRCLE)
	var capturing := NetMessages.ObjectState.new()
	capturing.net_id = NET_ID
	capturing.tick = 300
	capturing.add_field(FortressFields.PHASE, NetMessages.ObjectField.ValueType.U8, FortressState.Phase.CAPTURING)
	capturing.add_field(FortressFields.CAPTURE_REALM, NetMessages.ObjectField.ValueType.U8, VARDHEIM)
	view.on_object_state(capturing)
	view.advance(300.0)
	circle = MarkerSource.find(MarkerSource.build(_map, view), StringName("circle_%d" % NET_ID))
	if assert_not_null(circle):
		assert_eq(circle.color, RealmCatalog.color_of(RealmCatalog.VARDHEIM), "capturando, el color del captor")
	assert_near(MarkerSource.find(MarkerSource.build(_map, view), StringName("gate_%d" % NET_ID)).distance_from(Vector3.ZERO), 20.0, 0.01,
			"la puerta está a 20 m del centro del fuerte")


# --- Montaje en el HUD ------------------------------------------------------------------------

func test_the_war_hud_mounts_the_compass_and_the_markers() -> void:
	var client: FakeClient = _track(FakeClient.new()) as FakeClient
	var character: PlayerCharacter = _track((load(CHARACTER_SCENE_PATH) as PackedScene).instantiate(), _root) as PlayerCharacter
	character.global_position = SOLMARCH_CAMP
	client.fake_character = character
	var rig: CameraRig = (load(CAMERA_RIG_SCENE_PATH) as PackedScene).instantiate() as CameraRig
	rig.set_scripted_look(false)
	_track(rig)
	rig.set_look(0.0, 0.0)
	var war: WarHud = _track(WarHud.new()) as WarHud
	war.bind(client, rig)
	assert_not_null(war.get_compass())
	assert_not_null(war.get_world_markers())
	assert_not_null(war.get_map(), "el mapa horneado del Vado Gris")
	assert_eq(war.get_map().zone_id, ZONE_ID)
	await wait_process_frames(2)
	assert_near(war.get_compass().get_heading(), 0.0, 1e-3, "mirando al norte")
	var seen: Array[Dictionary] = war.get_compass().get_visible_markers()
	var ids: PackedStringArray = PackedStringArray()
	for entry: Dictionary in seen:
		ids.append(String((entry["marker"] as WorldMarker).id))
	assert_true(ids.has("fort_vado_gris_fort"), "desde el campamento de Solmarch el fuerte sale en la brújula (%s)" % ", ".join(ids))
	assert_true(ids.has("camp_1"), "y el campamento de Vardheim, detrás del fuerte")


# --- Ayudantes --------------------------------------------------------------------------------

func _entry_of(compass: Compass, id: StringName) -> Dictionary:
	for entry: Dictionary in compass.get_visible_markers():
		if (entry["marker"] as WorldMarker).id == id:
			return entry
	return {}


# Una cámara en [param from] mirando a [param target]. La interpolación de física usa la transformación
# del último paso, así que se reinicia y se espera un fotograma antes de proyectar nada.
func _make_camera(from: Vector3, target: Vector3) -> Camera3D:
	var camera := Camera3D.new()
	_track(camera)
	camera.global_transform = Transform3D(Basis(), from).looking_at(target, Vector3.UP)
	camera.reset_physics_interpolation()
	await wait_physics_frames(1)
	return camera


func _is_on_border(point: Vector2, size: Vector2, margin: float) -> bool:
	return is_equal_approx(point.x, margin) or is_equal_approx(point.x, size.x - margin) \
			or is_equal_approx(point.y, margin) or is_equal_approx(point.y, size.y - margin)


func _spawn(tick: int, values: Dictionary = {}) -> NetMessages.EntitySpawn:
	var state: FortressState = FortressState.initial(_def, tick)
	for field_id: int in values:
		FortressFields.set_value(state, field_id, int(values[field_id]))
	return NetMessages.EntitySpawn.decode(NetMessages.EntitySpawn.for_fortress(NET_ID, tick,
			"vado_gris_fort", state).encode())
