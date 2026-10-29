extends TestCase
## Pruebas de los marcadores del fuerte del Vado Gris (docs/fuerte.md, sección 8, paquete F0): el
## nodo de la fortaleza con su definición, los puntos de reaparición de los campamentos y del
## interior del fuerte (en orden de escena), los generadores de PNJ (Huecos, Capitán del Vado y
## Guardianes de la Puerta) y las rutas de patrulla. Carga la zona entera, como el servidor.

const ZONE_SCENE_PATH: String = "res://scenes/world/zones/vado_gris/vado_gris.tscn"
const DEFINITION_PATH: String = "res://data/fortresses/vado_gris.tres"
const FORTRESS_ID: StringName = &"vado_gris_fort"

var _zone: Node3D = null
var _fort: Node3D = null


func before_each() -> void:
	var scene: PackedScene = load(ZONE_SCENE_PATH) as PackedScene
	if not assert_not_null(scene, "no se pudo cargar %s" % ZONE_SCENE_PATH):
		return
	_zone = scene.instantiate() as Node3D
	tree.root.add_child(_zone)
	_fort = _zone.get_node_or_null(^"Fuerte") as Node3D
	await wait_physics_frames(2)


func after_each() -> void:
	if is_instance_valid(_zone):
		_zone.get_parent().remove_child(_zone)
		_zone.queue_free()
	_zone = null
	_fort = null
	await wait_process_frames()


func test_the_fort_is_the_only_fortress_node_and_points_to_its_definition() -> void:
	if not assert_not_null(_fort, "la zona tiene el nodo Fuerte"):
		return
	var fortresses: Array[Node3D] = Zones.get_group_nodes(_zone, Zones.FORTRESS_GROUP)
	if not assert_eq(fortresses.size(), 1, "una sola fortaleza en el Vado Gris"):
		return
	assert_eq(fortresses[0], _fort)
	var path: String = String(_fort.get_meta(Zones.FORTRESS_DEFINITION_META, ""))
	assert_eq(path, DEFINITION_PATH, "metadato definition")
	var definition: FortressDefinition = load(path) as FortressDefinition
	if not assert_not_null(definition, "la definición se carga"):
		return
	assert_eq(definition.id, FORTRESS_ID, "el id de la definición")


func test_the_fort_groups_the_markers_the_controller_needs() -> void:
	if not assert_not_null(_fort, "la zona tiene el nodo Fuerte"):
		return
	var circle: Node3D = _fort.get_node_or_null(^"CaptureCircle") as Node3D
	if assert_not_null(circle, "CaptureCircle"):
		assert_eq(float(circle.get_meta(&"radius", 0.0)), 5.0, "el radio del círculo sale del marcador")
		assert_true(circle.is_in_group(&"capture_points"))
	var captain: Node3D = _fort.get_node_or_null(^"CaptainSpawn") as Node3D
	if assert_not_null(captain, "CaptainSpawn") and circle != null:
		var offset: Vector3 = captain.global_position - circle.global_position
		assert_true(Vector2(offset.x, offset.z).length() < 5.0, "el capitán está dentro del círculo")
	for index: int in range(1, 5):
		var guard: Node3D = _fort.get_node_or_null(NodePath("GuardSpawn%d" % index)) as Node3D
		if assert_not_null(guard, "GuardSpawn%d" % index) and circle != null:
			var away: Vector3 = guard.global_position - circle.global_position
			assert_true(Vector2(away.x, away.z).length() > 5.0, "GuardSpawn%d queda fuera del círculo" % index)
	for banner_name: String in ["Estandarte", "EstandartePuertaN", "EstandartePuertaS"]:
		assert_not_null(_fort.get_node_or_null(NodePath(banner_name)), banner_name)
	var gate: Node = _fort.get_node_or_null(^"FortGate")
	if assert_not_null(gate, "FortGate") and assert_true(gate is FortGate, "es un FortGate"):
		assert_true(gate.is_in_group(&"fort_gate"))


func test_respawn_points_keep_the_camps_first_and_then_the_fort_interior() -> void:
	var points: Array[Node3D] = Zones.get_group_nodes(_zone, Zones.RESPAWN_GROUP)
	if not assert_eq(points.size(), 12, "4 por campamento y 4 en el interior del fuerte"):
		return
	# Orden de escena estable: Vardheim, Solmarch y el fuerte (el índice viaja por la red).
	var expected_realms: Array[StringName] = [&"vardheim", &"vardheim", &"vardheim", &"vardheim",
			&"solmarch", &"solmarch", &"solmarch", &"solmarch"]
	for i: int in 8:
		assert_eq(Zones.get_spawn_realm(points[i]), expected_realms[i], "%s: reino del campamento" % points[i].name)
		assert_false(points[i].has_meta(Zones.FORTRESS_META), "%s: no es del fuerte" % points[i].name)
	var circle: Node3D = _fort.get_node(^"CaptureCircle") as Node3D
	var radius: float = float(circle.get_meta(&"radius"))
	for i: int in range(8, 12):
		var point: Node3D = points[i]
		assert_eq(StringName(point.get_meta(Zones.FORTRESS_META, &"")), FORTRESS_ID, "%s: metadato fortress" % point.name)
		assert_false(point.has_meta(Zones.REALM_META), "%s: sin reino, vale para el dueño" % point.name)
		# Dentro de la empalizada y fuera del cilindro del círculo de captura.
		var local: Vector3 = _fort.to_local(point.global_position)
		assert_true(absf(local.x) < 19.0 and absf(local.z) < 19.0, "%s: dentro de la empalizada" % point.name)
		var offset: Vector3 = point.global_position - circle.global_position
		assert_true(Vector2(offset.x, offset.z).length() > radius + 2.0, "%s: fuera del círculo" % point.name)
		# Mira a la puerta (oeste).
		assert_true((-point.global_basis.z).dot(Vector3.LEFT) > 0.99, "%s: mira a la puerta" % point.name)
		# Con suelo debajo.
		assert_true(_ground_below(point.global_position), "%s: hay suelo" % point.name)
	# Los de los campamentos están donde los puntos de aparición, en el mismo orden.
	for realm: StringName in [&"vardheim", &"solmarch"]:
		var spawns: Array[Node3D] = Zones.get_spawn_points(_zone, realm)
		var camp: Array[Node3D] = Zones.get_respawn_points(_zone, realm)
		assert_eq(camp.size(), spawns.size(), "%s: un punto de reaparición por punto de aparición" % realm)
		for i: int in mini(camp.size(), spawns.size()):
			assert_vec_near(camp[i].global_position, spawns[i].global_position, 0.001, "%s %d" % [realm, i])
	# Con el grupo, la lista de un reino son solo sus campamentos (los del fuerte aún no valen).
	assert_eq(NetZones.get_respawn_points(_zone, NetProtocol.Realm.VARDHEIM).size(), 4)
	assert_eq(NetZones.get_respawn_points(_zone, NetProtocol.Realm.SOLMARCH).size(), 4)


func test_npc_spawners_for_hollows_the_captain_and_the_gate_guardians() -> void:
	var spawners: Array[Node3D] = Zones.get_group_nodes(_zone, Zones.NPC_SPAWNER_GROUP)
	var by_npc: Dictionary = {}
	for node: Node3D in spawners:
		var spawner: NpcSpawner = node as NpcSpawner
		if not assert_not_null(spawner, "%s tiene el script NpcSpawner" % node.name):
			return
		if not by_npc.has(spawner.npc_id):
			by_npc[spawner.npc_id] = [] as Array[NpcSpawner]
		(by_npc[spawner.npc_id] as Array[NpcSpawner]).append(spawner)
	assert_eq(spawners.size(), 9, "4 Huecos, el Capitán y 4 Guardianes")
	var hollows: Array[NpcSpawner] = _list(by_npc, &"hollow")
	var captains: Array[NpcSpawner] = _list(by_npc, &"ford_captain")
	var guardians: Array[NpcSpawner] = _list(by_npc, &"gate_guardian")
	assert_eq(hollows.size(), 4, "cuatro Huecos")
	assert_eq(captains.size(), 1, "un Capitán del Vado")
	assert_eq(guardians.size(), 4, "dos Guardianes por campamento")

	# Huecos: uno por GuardSpawn, activos con el fuerte neutral, con alerta de grupo, dos patrullan.
	var patrolling: int = 0
	for i: int in hollows.size():
		var hollow: NpcSpawner = hollows[i]
		var guard: Node3D = _fort.get_node(NodePath("GuardSpawn%d" % (i + 1))) as Node3D
		assert_vec_near(hollow.global_position, guard.global_position, 0.001, "%s está en %s" % [hollow.name, guard.name])
		assert_eq(hollow.condition, NpcSpawner.Condition.FORT_NEUTRAL, "%s: solo con el fuerte neutral" % hollow.name)
		assert_eq(hollow.alert_group, &"vado_gris_hollows", "%s: grupo de alerta" % hollow.name)
		assert_eq(hollow.max_alive, 1)
		assert_eq(hollow.get_respawn_ticks(), 0, "%s: reaparecen con el fuerte, no uno a uno" % hollow.name)
		assert_eq(hollow.get_fortress(), _fort, "%s cuelga de la fortaleza" % hollow.name)
		assert_eq(hollow.realm, &"", "%s: bando neutral" % hollow.name)
		if hollow.patrol_route != &"":
			patrolling += 1
	assert_eq(patrolling, 2, "dos Huecos patrullan")

	# Capitán: en el CaptainSpawn, dentro del círculo, y avisa a los Huecos.
	var captain: NpcSpawner = captains[0]
	assert_vec_near(captain.global_position, _fort.get_node(^"CaptainSpawn").global_position, 0.001)
	assert_eq(captain.condition, NpcSpawner.Condition.FORT_NEUTRAL)
	assert_eq(captain.alert_group, &"vado_gris_hollows", "el grito del capitán alerta a los Huecos")
	assert_eq(captain.get_fortress(), _fort)

	# Guardianes: dos por campamento, siempre activos, dentro de la zona segura de su reino.
	var safe: SafeAreas = SafeAreas.from_world(_zone)
	var per_realm: Dictionary = {}
	for guardian: NpcSpawner in guardians:
		per_realm[guardian.realm] = int(per_realm.get(guardian.realm, 0)) + 1
		assert_eq(guardian.condition, NpcSpawner.Condition.ALWAYS, "%s: siempre activo" % guardian.name)
		assert_true(guardian.get_respawn_ticks() > 0, "%s reaparece" % guardian.name)
		assert_null(guardian.get_fortress(), "%s no es de ninguna fortaleza" % guardian.name)
		var realm_code: int = RealmCatalog.code_of(guardian.realm)
		assert_true(safe.contains_own(realm_code, guardian.global_position), "%s está en la zona segura de su reino" % guardian.name)
		assert_eq(guardian.alert_group, StringName("camp_" + String(guardian.realm)))
	assert_eq(per_realm.get(&"vardheim", 0), 2, "dos Guardianes de Vardheim")
	assert_eq(per_realm.get(&"solmarch", 0), 2, "dos Guardianes de Solmarch")


func test_patrol_routes_go_from_the_yard_up_to_the_walkway() -> void:
	var routes: Dictionary = {}
	for node: Node3D in Zones.get_group_nodes(_zone, Zones.PATROL_GROUP):
		var route: StringName = StringName(node.get_meta(Zones.PATROL_ROUTE_META, &""))
		if not routes.has(route):
			routes[route] = [] as Array[Node3D]
		(routes[route] as Array[Node3D]).append(node)
	assert_eq(routes.size(), 2, "una ruta al norte y otra al sur")
	var used: Array[StringName] = []
	for node: Node3D in Zones.get_group_nodes(_zone, Zones.NPC_SPAWNER_GROUP):
		var spawner: NpcSpawner = node as NpcSpawner
		if spawner != null and spawner.patrol_route != &"":
			used.append(spawner.patrol_route)
	used.sort()
	var names: Array[StringName] = []
	names.assign(routes.keys())
	names.sort()
	assert_eq(used, names, "cada ruta tiene su Hueco, y cada Hueco su ruta")
	for route: StringName in routes:
		var points: Array[Node3D] = routes[route]
		if not assert_true(points.size() >= 3, "%s tiene al menos 3 puntos" % route):
			continue
		var first: Vector3 = _fort.to_local(points[0].global_position)
		var last: Vector3 = _fort.to_local(points[points.size() - 1].global_position)
		assert_true(first.y < 0.5, "%s empieza en el patio" % route)
		assert_true(last.y > 3.0, "%s acaba en la pasarela" % route)
		assert_true(absf(last.z) > 17.0, "%s acaba en el lado norte o sur de la pasarela" % route)


func _list(by_npc: Dictionary, npc_id: StringName) -> Array[NpcSpawner]:
	var result: Array[NpcSpawner] = []
	result.assign(by_npc.get(npc_id, [] as Array[NpcSpawner]))
	return result


func _ground_below(point: Vector3) -> bool:
	var space: PhysicsDirectSpaceState3D = _zone.get_world_3d().direct_space_state
	var from: Vector3 = point + Vector3(0.0, 1.0, 0.0)
	var query := PhysicsRayQueryParameters3D.create(from, from + Vector3(0.001, -3.0, 0.0), 1)
	return not space.intersect_ray(query).is_empty()
