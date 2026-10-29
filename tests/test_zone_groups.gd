extends TestCase
## Pruebas de los grupos de nodos de una zona que usa el combate del servidor
## ([method Zones.get_respawn_points], [method Zones.get_group_nodes], las zonas seguras, los
## volúmenes letales y los puntos de maniquí) y de [SafeAreas], con zonas armadas a mano y con las
## zonas reales.

const VARDHEIM: int = NetProtocol.Realm.VARDHEIM
const SOLMARCH: int = NetProtocol.Realm.SOLMARCH
const ASKARRA: int = NetProtocol.Realm.ASKARRA

var _zone: Node3D


func before_each() -> void:
	_zone = Node3D.new()
	_zone.name = "ZonaDeGrupos"
	tree.root.add_child(_zone)


func after_each() -> void:
	if is_instance_valid(_zone):
		_zone.get_parent().remove_child(_zone)
		_zone.free()
	_zone = null
	await wait_process_frames()


func _marker(marker_name: String, position: Vector3, group: StringName,
		realm: StringName = &"") -> Marker3D:
	var marker := Marker3D.new()
	marker.name = marker_name
	_zone.add_child(marker)
	marker.position = position
	marker.add_to_group(group)
	if not realm.is_empty():
		marker.set_meta(Zones.REALM_META, realm)
	return marker


func test_respawn_points_fall_back_to_spawn_points_without_the_group() -> void:
	_marker("V1", Vector3(0, 0, 1), Zones.SPAWN_GROUP, &"vardheim")
	_marker("S1", Vector3(0, 0, 2), Zones.SPAWN_GROUP, &"solmarch")
	_marker("V2", Vector3(0, 0, 3), Zones.SPAWN_GROUP, &"vardheim")
	var points: Array[Node3D] = Zones.get_respawn_points(_zone, &"vardheim")
	assert_eq(points.size(), 2, "sin respawn_points se usan los puntos de aparición del reino")
	assert_eq(points[0].name, &"V1", "en el orden de la escena")
	assert_eq(points[1].name, &"V2")
	assert_eq(NetZones.get_respawn_points(_zone, SOLMARCH).size(), 1)
	# Un reino sin puntos propios (o un código que no es un reino) recibe todos los de la zona, como
	# SpawnPicker al aparecer: es la lista común de servidor y cliente para RESPAWN_REQUEST.
	assert_eq(NetZones.get_respawn_points(_zone, ASKARRA).size(), 3, "un reino sin puntos ve todos")
	assert_eq(NetZones.get_respawn_points(_zone, 0).size(), 3, "y los Huecos también")


func test_respawn_points_group_wins_over_spawn_points() -> void:
	_marker("V1", Vector3(0, 0, 1), Zones.SPAWN_GROUP, &"vardheim")
	_marker("R1", Vector3(5, 0, 1), Zones.RESPAWN_GROUP, &"vardheim")
	_marker("R2", Vector3(6, 0, 1), Zones.RESPAWN_GROUP, &"solmarch")
	_marker("R3", Vector3(7, 0, 1), Zones.RESPAWN_GROUP, &"vardheim")
	var points: Array[Node3D] = Zones.get_respawn_points(_zone, &"vardheim")
	assert_eq(points.size(), 2)
	assert_eq(points[0].name, &"R1")
	assert_eq(points[1].name, &"R3")
	assert_eq(Zones.get_respawn_points(_zone, &"askarra").size(), 0,
			"con el grupo en la zona, un reino sin puntos de reaparición no usa los de aparición")


func test_group_nodes_ignore_other_trees() -> void:
	_marker("Dentro", Vector3.ZERO, Zones.DUMMY_GROUP)
	var outsider := Marker3D.new()
	outsider.add_to_group(Zones.DUMMY_GROUP)
	tree.root.add_child(outsider)
	var found: Array[Node3D] = NetZones.get_dummy_points(_zone)
	assert_eq(found.size(), 1, "solo los de esta zona")
	assert_eq(found[0].name, &"Dentro")
	tree.root.remove_child(outsider)
	outsider.free()
	assert_eq(Zones.get_group_nodes(null, Zones.DUMMY_GROUP).size(), 0, "sin zona no hay nodos")


func test_safe_area_metadata_and_safe_areas_helper() -> void:
	var camp: Marker3D = _marker("CampamentoV", Vector3(10, 6, -20), Zones.SAFE_AREA_GROUP, &"vardheim")
	camp.set_meta(Zones.SAFE_AREA_RADIUS_META, 18.5)
	_marker("SinRadio", Vector3(0, 0, 40), Zones.SAFE_AREA_GROUP, &"solmarch")
	_marker("SinReino", Vector3(0, 0, 80), Zones.SAFE_AREA_GROUP)
	var bad_radius: Marker3D = _marker("RadioMalo", Vector3(0, 0, 120), Zones.SAFE_AREA_GROUP,
			&"askarra")
	bad_radius.set_meta(Zones.SAFE_AREA_RADIUS_META, -3.0)
	assert_eq(NetZones.safe_area_radius(camp), 18.5)
	assert_eq(NetZones.safe_area_radius(_zone.get_node("SinRadio")), Zones.SAFE_AREA_DEFAULT_RADIUS,
			"sin metadato: 24 m")
	assert_eq(NetZones.safe_area_radius(bad_radius), Zones.SAFE_AREA_DEFAULT_RADIUS,
			"un radio no positivo se ignora")
	assert_eq(NetZones.node_realm_code(camp), VARDHEIM)
	assert_eq(NetZones.node_realm_code(_zone.get_node("SinReino")), -1)
	var safe: SafeAreas = SafeAreas.from_world(_zone)
	assert_eq(safe.size(), 3, "el marcador sin reino se ignora")
	# Dentro de la de Vardheim (10, -20) con radio 18,5.
	assert_true(safe.contains_own(VARDHEIM, Vector3(10, 100, -20 + 18)), "dentro: la altura no cuenta")
	assert_false(safe.contains_own(VARDHEIM, Vector3(10, 0, -20 + 19)), "fuera por 0,5 m")
	assert_false(safe.contains_own(SOLMARCH, Vector3(10, 0, -20)), "no protege a otro reino")
	assert_true(safe.contains_own(SOLMARCH, Vector3(0, 0, 40 + 23.9)), "la de Solmarch usa 24 m")
	assert_false(safe.contains_own(SOLMARCH, Vector3(0, 0, 40 + 24.1)))
	assert_false(safe.contains_own(0, Vector3(10, 0, -20)), "los Huecos no tienen zona segura")


func test_safe_areas_of_a_zone_without_markers_is_empty() -> void:
	var safe: SafeAreas = SafeAreas.from_world(_zone)
	assert_eq(safe.size(), 0)
	assert_false(safe.contains_own(VARDHEIM, Vector3.ZERO))
	assert_eq(SafeAreas.from_world(null).size(), 0, "sin zona tampoco")


## Marcadores del grupo [param group] de la escena [param scene_path], leídos del [SceneState] sin
## instanciarla (el Vado Gris tarda segundos en instanciarse por su terreno): nombre, posición,
## reino, radio y si el marcador tiene el metadato.
func _scene_markers(scene_path: String, group: StringName) -> Array[Dictionary]:
	var markers: Array[Dictionary] = []
	var packed: PackedScene = load(scene_path) as PackedScene
	if not assert_not_null(packed, "carga %s" % scene_path):
		return markers
	var state: SceneState = packed.get_state()
	for index: int in state.get_node_count():
		if not state.get_node_groups(index).has(String(group)):
			continue
		var marker: Dictionary = {"name": state.get_node_name(index), "position": Vector3.ZERO,
				"realm": &"", "radius": -1.0}
		for property: int in state.get_node_property_count(index):
			var property_name: String = state.get_node_property_name(index, property)
			var value: Variant = state.get_node_property_value(index, property)
			if property_name == "transform":
				marker["position"] = (value as Transform3D).origin
			elif property_name == "position":
				marker["position"] = value
			elif property_name == "metadata/realm":
				marker["realm"] = StringName(value)
			elif property_name == "metadata/radius":
				marker["radius"] = float(value)
		markers.append(marker)
	return markers


func test_vado_gris_has_a_safe_area_per_camp_that_covers_its_spawns() -> void:
	var path: String = Zones.get_scene_path(&"vado_gris")
	var areas: Array[Dictionary] = _scene_markers(path, Zones.SAFE_AREA_GROUP)
	if not assert_eq(areas.size(), 2, "una zona segura por campamento"):
		return
	var safe := SafeAreas.new()
	var realms: Array[StringName] = []
	for area: Dictionary in areas:
		assert_eq(area["radius"], 24.0, "%s: radio de 24 m" % area["name"])
		realms.append(area["realm"])
		safe.add(area["position"], area["radius"], RealmCatalog.code_of(area["realm"]))
	realms.sort()
	assert_eq(realms, [&"solmarch", &"vardheim"] as Array[StringName], "una de cada reino")
	# Cada zona segura contiene todos los puntos de aparición de su reino.
	var spawns: Array[Dictionary] = _scene_markers(path, Zones.SPAWN_GROUP)
	assert_eq(spawns.size(), 8, "4 puntos de aparición por reino")
	for spawn: Dictionary in spawns:
		var realm: int = RealmCatalog.code_of(spawn["realm"])
		assert_true(safe.contains_own(realm, spawn["position"]),
				"%s está dentro de la zona segura de su reino" % spawn["name"])
		var enemy: int = SOLMARCH if realm == VARDHEIM else VARDHEIM
		assert_false(safe.contains_own(enemy, spawn["position"]),
				"%s no está en la zona segura del otro reino" % spawn["name"])


func test_vado_gris_dummies_are_next_to_each_camp_and_outside_the_safe_areas() -> void:
	var path: String = Zones.get_scene_path(&"vado_gris")
	var dummies: Array[Dictionary] = _scene_markers(path, Zones.DUMMY_GROUP)
	if not assert_eq(dummies.size(), 2, "un maniquí junto a cada campamento"):
		return
	var safe := SafeAreas.new()
	for area: Dictionary in _scene_markers(path, Zones.SAFE_AREA_GROUP):
		safe.add(area["position"], area["radius"], RealmCatalog.code_of(area["realm"]))
	var sides: Array[float] = []
	for dummy: Dictionary in dummies:
		var position: Vector3 = dummy["position"]
		sides.append(signf(position.z))
		assert_false(safe.contains_own(VARDHEIM, position) or safe.contains_own(SOLMARCH, position),
				"%s está fuera de las zonas seguras (se puede golpear desde fuera)" % dummy["name"])
		assert_true(absf(position.z) > 100.0 and absf(position.z) < 125.0,
				"%s está junto al campamento de un reino" % dummy["name"])
	sides.sort()
	assert_eq(sides, [-1.0, 1.0] as Array[float], "uno al norte y otro al sur")


func test_test_world_has_a_dummy_point() -> void:
	var dummies: Array[Dictionary] = _scene_markers(Zones.get_scene_path(&"test_world"),
			Zones.DUMMY_GROUP)
	assert_eq(dummies.size(), 1, "un maniquí en el mundo de pruebas")
