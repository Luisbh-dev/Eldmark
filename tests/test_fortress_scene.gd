extends TestCase
## Tests of the Vado Gris fort markers (docs/fuerte.md, section 8, package F0): the
## fortress node with its definition, the respawn points of the camps and of the
## fort's interior (in scene order), the NPC spawners (Hollows, Ford Captain and
## Gate Guardians) and the patrol routes. It loads the whole zone, like the server.

const ZONE_SCENE_PATH: String = "res://scenes/world/zones/vado_gris/vado_gris.tscn"
const DEFINITION_PATH: String = "res://data/fortresses/vado_gris.tres"
const FORTRESS_ID: StringName = &"vado_gris_fort"

var _zone: Node3D = null
var _fort: Node3D = null


func before_each() -> void:
	var scene: PackedScene = load(ZONE_SCENE_PATH) as PackedScene
	if not assert_not_null(scene, "could not load %s" % ZONE_SCENE_PATH):
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
	if not assert_not_null(_fort, "the zone has the Fuerte node"):
		return
	var fortresses: Array[Node3D] = Zones.get_group_nodes(_zone, Zones.FORTRESS_GROUP)
	if not assert_eq(fortresses.size(), 1, "a single fortress in Vado Gris"):
		return
	assert_eq(fortresses[0], _fort)
	var path: String = String(_fort.get_meta(Zones.FORTRESS_DEFINITION_META, ""))
	assert_eq(path, DEFINITION_PATH, "definition metadata")
	var definition: FortressDefinition = load(path) as FortressDefinition
	if not assert_not_null(definition, "the definition loads"):
		return
	assert_eq(definition.id, FORTRESS_ID, "the definition id")


func test_the_fort_groups_the_markers_the_controller_needs() -> void:
	if not assert_not_null(_fort, "the zone has the Fuerte node"):
		return
	var circle: Node3D = _fort.get_node_or_null(^"CaptureCircle") as Node3D
	if assert_not_null(circle, "CaptureCircle"):
		assert_eq(float(circle.get_meta(&"radius", 0.0)), 5.0, "the circle's radius comes from the marker")
		assert_true(circle.is_in_group(&"capture_points"))
	var captain: Node3D = _fort.get_node_or_null(^"CaptainSpawn") as Node3D
	if assert_not_null(captain, "CaptainSpawn") and circle != null:
		var offset: Vector3 = captain.global_position - circle.global_position
		assert_true(Vector2(offset.x, offset.z).length() < 5.0, "the captain is inside the circle")
	for index: int in range(1, 5):
		var guard: Node3D = _fort.get_node_or_null(NodePath("GuardSpawn%d" % index)) as Node3D
		if assert_not_null(guard, "GuardSpawn%d" % index) and circle != null:
			var away: Vector3 = guard.global_position - circle.global_position
			assert_true(Vector2(away.x, away.z).length() > 5.0, "GuardSpawn%d is outside the circle" % index)
	for banner_name: String in ["Estandarte", "EstandartePuertaN", "EstandartePuertaS"]:
		assert_not_null(_fort.find_child(banner_name, true, false), banner_name)
	var gate: Node = _fort.get_node_or_null(^"FortGate")
	if assert_not_null(gate, "FortGate") and assert_true(gate is FortGate, "it is a FortGate"):
		assert_true(gate.is_in_group(&"fort_gate"))


func test_the_keep_replaces_the_old_tower_with_a_low_resolution_collision() -> void:
	if not assert_not_null(_fort, "the zone has the Fuerte node"):
		return
	var keep: Node = _fort.get_node_or_null(^"FortKeep")
	if not assert_not_null(keep, "the new keep (FortKeep)") or not assert_true(keep is FortKeep, "with its script"):
		return
	assert_null(_fort.get_node_or_null(^"FortTower"), "the old tower is gone")
	var bodies: Array[Node] = keep.find_children("*", "StaticBody3D", true, false)
	if not assert_eq(bodies.size(), 1, "a single collision body"):
		return
	var body: StaticBody3D = bodies[0] as StaticBody3D
	assert_eq(body.collision_layer, PlayerCharacter.WORLD_COLLISION_LAYER, "the keep is on the world layer")
	assert_eq(body.collision_mask, 0)
	var shape: ConcavePolygonShape3D = (body.find_children("*", "CollisionShape3D", true, false)[0] as CollisionShape3D).shape as ConcavePolygonShape3D
	if not assert_not_null(shape, "mesh collision"):
		return
	var faces: PackedVector3Array = shape.get_faces()
	assert_true(faces.size() / 3 < 600, "low-resolution collision (%d faces)" % (faces.size() / 3))
	# The footprint does not intrude on the capture circle more than expected nor eat the spawn points.
	var lo: Vector3 = Vector3(1e9, 1e9, 1e9)
	var hi: Vector3 = Vector3(-1e9, -1e9, -1e9)
	for vertex: Vector3 in faces:
		lo = lo.min(vertex)
		hi = hi.max(vertex)
	assert_true(hi.x - lo.x < 11.0 and hi.z - lo.z < 11.0, "footprint under 11 m on a side")
	for spawn_name: String in ["CaptainSpawn", "FordCaptainSpawner"]:
		var marker: Node3D = _fort.get_node_or_null(NodePath(spawn_name)) as Node3D
		if marker == null:
			continue
		var local: Vector3 = keep.to_local(marker.global_position)
		var outside: bool = local.x < lo.x - 0.9 or local.x > hi.x + 0.9 or local.z < lo.z - 0.9 or local.z > hi.z + 0.9
		assert_true(outside, "%s is more than 0.9 m from the keep's collision" % spawn_name)
	# The keep's banner carries the per-instance faction color that the fort view drives.
	var banner: MeshInstance3D = _fort.find_child("Estandarte", true, false) as MeshInstance3D
	if assert_not_null(banner, "the keep's banner"):
		assert_not_null(banner.get("instance_shader_parameters/faction_color"), "per-instance faction color")


func test_respawn_points_keep_the_camps_first_and_then_the_fort_interior() -> void:
	var points: Array[Node3D] = Zones.get_group_nodes(_zone, Zones.RESPAWN_GROUP)
	if not assert_eq(points.size(), 12, "4 per camp and 4 inside the fort"):
		return
	# Stable scene order: Vardheim, Solmarch and the fort (the index travels over the network).
	var expected_realms: Array[StringName] = [&"vardheim", &"vardheim", &"vardheim", &"vardheim",
			&"solmarch", &"solmarch", &"solmarch", &"solmarch"]
	for i: int in 8:
		assert_eq(Zones.get_spawn_realm(points[i]), expected_realms[i], "%s: camp realm" % points[i].name)
		assert_false(points[i].has_meta(Zones.FORTRESS_META), "%s: it is not the fort's" % points[i].name)
	var circle: Node3D = _fort.get_node(^"CaptureCircle") as Node3D
	var radius: float = float(circle.get_meta(&"radius"))
	for i: int in range(8, 12):
		var point: Node3D = points[i]
		assert_eq(StringName(point.get_meta(Zones.FORTRESS_META, &"")), FORTRESS_ID, "%s: fortress metadata" % point.name)
		assert_false(point.has_meta(Zones.REALM_META), "%s: no realm, valid for the owner" % point.name)
		# Inside the palisade and outside the capture circle's cylinder.
		var local: Vector3 = _fort.to_local(point.global_position)
		assert_true(absf(local.x) < 19.0 and absf(local.z) < 19.0, "%s: inside the palisade" % point.name)
		var offset: Vector3 = point.global_position - circle.global_position
		assert_true(Vector2(offset.x, offset.z).length() > radius + 2.0, "%s: outside the circle" % point.name)
		# Faces the gate (west).
		assert_true((-point.global_basis.z).dot(Vector3.LEFT) > 0.99, "%s: faces the gate" % point.name)
		# With ground below.
		assert_true(_ground_below(point.global_position), "%s: there is ground" % point.name)
	# Those of the camps are where the spawn points are, in the same order.
	for realm: StringName in [&"vardheim", &"solmarch"]:
		var spawns: Array[Node3D] = Zones.get_spawn_points(_zone, realm)
		var camp: Array[Node3D] = Zones.get_respawn_points(_zone, realm)
		assert_eq(camp.size(), spawns.size(), "%s: one respawn point per spawn point" % realm)
		for i: int in mini(camp.size(), spawns.size()):
			assert_vec_near(camp[i].global_position, spawns[i].global_position, 0.001, "%s %d" % [realm, i])
	# With the group, a realm's list is only its camps (the fort's are not valid yet).
	assert_eq(NetZones.get_respawn_points(_zone, NetProtocol.Realm.VARDHEIM).size(), 4)
	assert_eq(NetZones.get_respawn_points(_zone, NetProtocol.Realm.SOLMARCH).size(), 4)


func test_npc_spawners_for_hollows_the_captain_and_the_gate_guardians() -> void:
	var spawners: Array[Node3D] = Zones.get_group_nodes(_zone, Zones.NPC_SPAWNER_GROUP)
	var by_npc: Dictionary = {}
	for node: Node3D in spawners:
		var spawner: NpcSpawner = node as NpcSpawner
		if not assert_not_null(spawner, "%s has the NpcSpawner script" % node.name):
			return
		if not by_npc.has(spawner.npc_id):
			by_npc[spawner.npc_id] = [] as Array[NpcSpawner]
		(by_npc[spawner.npc_id] as Array[NpcSpawner]).append(spawner)
	assert_eq(spawners.size(), 9, "4 Hollows, the Captain and 4 Guardians")
	var hollows: Array[NpcSpawner] = _list(by_npc, &"hollow")
	var captains: Array[NpcSpawner] = _list(by_npc, &"ford_captain")
	var guardians: Array[NpcSpawner] = _list(by_npc, &"gate_guardian")
	assert_eq(hollows.size(), 4, "four Hollows")
	assert_eq(captains.size(), 1, "one Ford Captain")
	assert_eq(guardians.size(), 4, "two Guardians per camp")

	# Hollows: one per GuardSpawn, active with the fort neutral, with group alert, two patrol.
	var patrolling: int = 0
	for i: int in hollows.size():
		var hollow: NpcSpawner = hollows[i]
		var guard: Node3D = _fort.get_node(NodePath("GuardSpawn%d" % (i + 1))) as Node3D
		assert_vec_near(hollow.global_position, guard.global_position, 0.001, "%s is at %s" % [hollow.name, guard.name])
		assert_eq(hollow.condition, NpcSpawner.Condition.FORT_NEUTRAL, "%s: only with the fort neutral" % hollow.name)
		assert_eq(hollow.alert_group, &"vado_gris_hollows", "%s: alert group" % hollow.name)
		assert_eq(hollow.max_alive, 1)
		assert_eq(hollow.get_respawn_ticks(), 0, "%s: they respawn with the fort, not one by one" % hollow.name)
		assert_eq(hollow.get_fortress(), _fort, "%s hangs from the fortress" % hollow.name)
		assert_eq(hollow.realm, &"", "%s: neutral faction" % hollow.name)
		if hollow.patrol_route != &"":
			patrolling += 1
	assert_eq(patrolling, 2, "two Hollows patrol")

	# Captain: at the CaptainSpawn, inside the circle, and alerts the Hollows.
	var captain: NpcSpawner = captains[0]
	assert_vec_near(captain.global_position, _fort.get_node(^"CaptainSpawn").global_position, 0.001)
	assert_eq(captain.condition, NpcSpawner.Condition.FORT_NEUTRAL)
	assert_eq(captain.alert_group, &"vado_gris_hollows", "the captain's shout alerts the Hollows")
	assert_eq(captain.get_fortress(), _fort)

	# Guardians: two per camp, always active, inside their realm's safe zone.
	var safe: SafeAreas = SafeAreas.from_world(_zone)
	var per_realm: Dictionary = {}
	for guardian: NpcSpawner in guardians:
		per_realm[guardian.realm] = int(per_realm.get(guardian.realm, 0)) + 1
		assert_eq(guardian.condition, NpcSpawner.Condition.ALWAYS, "%s: always active" % guardian.name)
		assert_true(guardian.get_respawn_ticks() > 0, "%s respawns" % guardian.name)
		assert_null(guardian.get_fortress(), "%s belongs to no fortress" % guardian.name)
		var realm_code: int = RealmCatalog.code_of(guardian.realm)
		assert_true(safe.contains_own(realm_code, guardian.global_position), "%s is in its realm's safe zone" % guardian.name)
		assert_eq(guardian.alert_group, StringName("camp_" + String(guardian.realm)))
	assert_eq(per_realm.get(&"vardheim", 0), 2, "two Vardheim Guardians")
	assert_eq(per_realm.get(&"solmarch", 0), 2, "two Solmarch Guardians")


func test_patrol_routes_go_from_the_yard_up_to_the_walkway() -> void:
	var routes: Dictionary = {}
	for node: Node3D in Zones.get_group_nodes(_zone, Zones.PATROL_GROUP):
		var route: StringName = StringName(node.get_meta(Zones.PATROL_ROUTE_META, &""))
		if not routes.has(route):
			routes[route] = [] as Array[Node3D]
		(routes[route] as Array[Node3D]).append(node)
	assert_eq(routes.size(), 2, "one route to the north and another to the south")
	var used: Array[StringName] = []
	for node: Node3D in Zones.get_group_nodes(_zone, Zones.NPC_SPAWNER_GROUP):
		var spawner: NpcSpawner = node as NpcSpawner
		if spawner != null and spawner.patrol_route != &"":
			used.append(spawner.patrol_route)
	used.sort()
	var names: Array[StringName] = []
	names.assign(routes.keys())
	names.sort()
	assert_eq(used, names, "each route has its Hollow, and each Hollow its route")
	for route: StringName in routes:
		var points: Array[Node3D] = routes[route]
		if not assert_true(points.size() >= 3, "%s has at least 3 points" % route):
			continue
		var first: Vector3 = _fort.to_local(points[0].global_position)
		var last: Vector3 = _fort.to_local(points[points.size() - 1].global_position)
		assert_true(first.y < 0.5, "%s starts in the courtyard" % route)
		assert_true(last.y > 3.0, "%s ends on the walkway" % route)
		assert_true(absf(last.z) > 17.0, "%s ends on the north or south side of the walkway" % route)


func _list(by_npc: Dictionary, npc_id: StringName) -> Array[NpcSpawner]:
	var result: Array[NpcSpawner] = []
	result.assign(by_npc.get(npc_id, [] as Array[NpcSpawner]))
	return result


func _ground_below(point: Vector3) -> bool:
	var space: PhysicsDirectSpaceState3D = _zone.get_world_3d().direct_space_state
	var from: Vector3 = point + Vector3(0.0, 1.0, 0.0)
	var query := PhysicsRayQueryParameters3D.create(from, from + Vector3(0.001, -3.0, 0.0), 1)
	return not space.intersect_ray(query).is_empty()
