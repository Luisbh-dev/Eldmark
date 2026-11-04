extends TestCase
## Tests for the Vado Gris zone (scenes/world/zones/vado_gris/vado_gris.tscn) as the dedicated server
## will load it: headless, with no camera and with the full terrain collision.
##
## They check that the scene loads without errors, that both realms have spawn points facing the fort,
## that a PlayerCharacter dropped at each lands on the terrain and can run 5 m, that the bridge decks
## are free of foreign collisions and can be crossed along any lane, that the fort gate is kept closed,
## that every gameplay tree or rock from the instancer has its collision, and that the server can strip
## the visual layer. The full routes (bridge, ford and fort interior) and fairness between realms are
## checked by tools/terrain/verify_vado_gris_routes.gd, which takes longer.

const ZONE_SCENE_PATH: String = "res://scenes/world/zones/vado_gris/vado_gris.tscn"
const CHARACTER_SCENE_PATH: String = "res://scenes/characters/player_character.tscn"
const REALMS: Array[StringName] = [&"vardheim", &"solmarch"]
const MIN_SPAWNS_PER_REALM: int = 2
const PLAY_HALF: float = 150.0
## Distance each character must cover.
const RUN_DISTANCE: float = 5.0
const DROP_HEIGHT: float = 2.0
## Bridges: x axis, centered at z = ±62, 24 m long, 4 m clear deck.
const BRIDGE_Z: float = 62.0
const BRIDGE_HALF_LENGTH: float = 12.0
const DECK_HALF_WIDTH: float = 1.95
## Lanes that must be crossable on each bridge in both directions.
const BRIDGE_LANES: Array[float] = [-1.5, 0.0, 1.5]
## Player mask: world (1) + the player's invisible blockers (4).
const PLAYER_MASK: int = 1 | 4
## Instancer mesh ids that are trees or rocks (see generate_vado_gris.gd): the first three are pines,
## deciduous and dead trees along with the rocks, the extra tree variants (ART-59) and the twisted
## ones. Inside the playable area all of them have collision; outside there is forest and scree
## without it.
const COVER_MESH_IDS: Array[int] = [2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 16, 17, 18, 19, 20, 21, 22, 23, 24]
const WALL_Z: float = 152.0

var _zone: Node3D


func before_each() -> void:
	var scene: PackedScene = load(ZONE_SCENE_PATH) as PackedScene
	if not assert_not_null(scene, "could not load %s" % ZONE_SCENE_PATH):
		return
	_zone = scene.instantiate() as Node3D
	tree.root.add_child(_zone)
	await wait_physics_frames(2)


func after_each() -> void:
	if is_instance_valid(_zone):
		_zone.get_parent().remove_child(_zone)
		_zone.queue_free()
	_zone = null
	await wait_process_frames()


func test_scene_loads_headless() -> void:
	if not assert_not_null(_zone, "the zone must be instantiated"):
		return
	assert_eq(String(_zone.name), "VadoGris", "root name")
	var terrain: Terrain3D = _zone.get_node_or_null(^"Terrain3D") as Terrain3D
	if not assert_not_null(terrain, "the zone has a Terrain3D node"):
		return
	assert_eq(terrain.collision_mode, Terrain3DCollision.FULL_GAME,
			"full collision: the server has no camera")
	assert_eq(terrain.collision_layer, 1, "the terrain is on the world layer")
	assert_eq(terrain.data.get_region_count(), 4, "500 x 500 m in 2 x 2 regions of 256 m")
	assert_false(terrain.is_physics_processing(),
			"with no camera, ZoneRoot disables Terrain3D processing (avoids its error)")
	assert_null(_zone.get_viewport().get_camera_3d(), "the test runs without a camera")
	# The terrain responds across the whole playable area, also far from the center.
	for point: Vector3 in [Vector3.ZERO, Vector3(-140.0, 0.0, -140.0), Vector3(140.0, 0.0, 140.0),
			Vector3(-62.0, 0.0, 0.0)]:
		assert_false(_raycast_down(point).is_empty(), "there is ground at %s" % point)
	assert_true(get_screenshot_points().size() >= 8, "at least 8 review cameras")


func test_both_realms_have_spawn_points() -> void:
	if not assert_not_null(_zone, "the zone must be instantiated"):
		return
	var fort: Vector3 = Vector3.ZERO
	for realm: StringName in REALMS:
		var spawns: Array[Node3D] = Zones.get_spawn_points(_zone, realm)
		assert_eq(spawns, _zone.call(&"get_spawn_points", realm) as Array[Node3D],
				"ZoneRoot.get_spawn_points delegates to Zones")
		assert_true(spawns.size() >= MIN_SPAWNS_PER_REALM,
				"%s has %d spawn points (minimum %d)" % [realm, spawns.size(), MIN_SPAWNS_PER_REALM])
		for spawn: Node3D in spawns:
			var p: Vector3 = spawn.global_position
			assert_true(absf(p.x) < PLAY_HALF and absf(p.z) < PLAY_HALF,
					"%s is inside the playable area" % spawn.name)
			var forward: Vector3 = -spawn.global_basis.z
			var to_fort: Vector3 = (fort - p) * Vector3(1.0, 0.0, 1.0)
			assert_true(forward.dot(to_fort.normalized()) > 0.9, "%s faces the fort" % spawn.name)
	# Vardheim to the north (-Z) and Solmarch to the south (+Z).
	var north: Array[Node3D] = Zones.get_spawn_points(_zone, &"vardheim")
	var south: Array[Node3D] = Zones.get_spawn_points(_zone, &"solmarch")
	if not north.is_empty() and not south.is_empty():
		assert_true(north[0].global_position.z < -100.0, "Vardheim spawns next to the north wall")
		assert_true(south[0].global_position.z > 100.0, "Solmarch spawns next to the south wall")


## One character per spawn point, all at once (they do not collide with each other: layer 2, mask 1).
func test_characters_land_and_run_at_each_spawn() -> void:
	if not assert_not_null(_zone, "the zone must be instantiated"):
		return
	var spawns: Array[Node3D] = []
	for realm: StringName in REALMS:
		spawns.append_array(Zones.get_spawn_points(_zone, realm))
	if not assert_true(spawns.size() >= MIN_SPAWNS_PER_REALM * 2, "there are spawn points"):
		return
	var scene: PackedScene = load(CHARACTER_SCENE_PATH) as PackedScene
	var characters: Array[PlayerCharacter] = []
	for spawn: Node3D in spawns:
		var character: PlayerCharacter = scene.instantiate() as PlayerCharacter
		_zone.add_child(character)
		characters.append(character)
	await wait_physics_frames()
	if not assert_true(Engine.is_in_physics_frame(), "simulate() must be called in the physics tick"):
		return
	var dt: float = 1.0 / float(Engine.physics_ticks_per_second)
	var starts: Array[Vector3] = []
	for i: int in characters.size():
		var state := PlayerState.new()
		state.position = spawns[i].global_position + Vector3(0.0, DROP_HEIGHT, 0.0)
		state.yaw = spawns[i].global_rotation.y
		state.grounded = false
		characters[i].set_state(state)

	# Fall: all of them must land on the camp terrain.
	var tick: int = 1
	for _t: int in 180:
		var all_grounded: bool = true
		for character: PlayerCharacter in characters:
			character.simulate(_input(tick, Vector2.ZERO, character.yaw), dt)
			all_grounded = all_grounded and character.grounded
		tick += 1
		if all_grounded:
			break
		await wait_physics_frames()
	for i: int in characters.size():
		assert_true(characters[i].grounded, "%s: lands" % spawns[i].name)
		var ground: Dictionary = _raycast_down(characters[i].global_position)
		if assert_false(ground.is_empty(), "%s: there is ground below" % spawns[i].name):
			var ground_position: Vector3 = ground["position"]
			assert_near(characters[i].global_position.y, ground_position.y, 0.1,
					"%s: the feet end up on the ground" % spawns[i].name)
		starts.append(characters[i].global_position)

	# Run toward the fort (the direction the spawn point faces) until covering 5 m.
	await wait_physics_frames()
	var done: Array[bool] = []
	done.resize(characters.size())
	done.fill(false)
	for _t: int in 150:
		var all_done: bool = true
		for i: int in characters.size():
			if done[i]:
				continue
			characters[i].simulate(_input(tick, Vector2(0.0, 1.0), spawns[i].global_rotation.y), dt)
			var moved: Vector3 = characters[i].global_position - starts[i]
			done[i] = Vector2(moved.x, moved.z).length() >= RUN_DISTANCE
			all_done = all_done and done[i]
		tick += 1
		if all_done:
			break
		await wait_physics_frames()
	for i: int in characters.size():
		var moved: Vector3 = characters[i].global_position - starts[i]
		assert_true(Vector2(moved.x, moved.z).length() >= RUN_DISTANCE,
				"%s: runs %.1f m (minimum %.1f)" % [spawns[i].name, Vector2(moved.x, moved.z).length(), RUN_DISTANCE])
		assert_true(characters[i].grounded, "%s: still on the ground after running" % spawns[i].name)
		var forward: Vector3 = -spawns[i].global_basis.z
		assert_true(Vector3(moved.x, 0.0, moved.z).normalized().dot(forward) > 0.95,
				"%s: advances toward the fort" % spawns[i].name)


## Vertical rays on a 5 x 25 cm grid over each deck: the first thing hit must be the bridge or the
## terrain (the deck ends are buried), never an invisible blocker (a shore block used to stick out
## 0.8 m in the west lane).
func test_bridge_decks_have_no_foreign_colliders() -> void:
	if not assert_not_null(_zone, "the zone must be instantiated"):
		return
	var space: PhysicsDirectSpaceState3D = _zone.get_world_3d().direct_space_state
	var terrain: Terrain3D = _zone.get_node(^"Terrain3D") as Terrain3D
	var bad: Dictionary = {}
	var rays: int = 0
	for zs: float in [-1.0, 1.0]:
		var x: float = -DECK_HALF_WIDTH
		while x <= DECK_HALF_WIDTH + 0.001:
			var z: float = zs * BRIDGE_Z - BRIDGE_HALF_LENGTH
			while z <= zs * BRIDGE_Z + BRIDGE_HALF_LENGTH + 0.001:
				var query := PhysicsRayQueryParameters3D.create(Vector3(x, 14.0, z), Vector3(x + 0.001, -2.0, z), PLAYER_MASK)
				var hit: Dictionary = space.intersect_ray(query)
				rays += 1
				if not hit.is_empty():
					var collider: Object = hit["collider"]
					# The bridge body is the root of stone_bridge.tscn (PuenteNorte / PuenteSur).
					var ok: bool = collider == terrain or (collider is Node and (collider as Node).scene_file_path.ends_with("stone_bridge.tscn"))
					if not ok:
						var key: String = String((collider as Node).name) if collider is Node else str(collider)
						bad[key] = "x=%.2f z=%.2f y=%.2f" % [x, z, (hit["position"] as Vector3).y]
				z += 0.25
			x += 0.05
	assert_true(rays > 2000, "%d rays were cast" % rays)
	assert_true(bad.is_empty(), "foreign collisions over the decks: %s" % bad)


## One PlayerCharacter per lane (x = -1.5, 0 and 1.5) and direction crosses each bridge running, all
## at once (they do not collide with each other). None may get stuck.
func test_bridge_lanes_are_walkable() -> void:
	if not assert_not_null(_zone, "the zone must be instantiated"):
		return
	var scene: PackedScene = load(CHARACTER_SCENE_PATH) as PackedScene
	var runners: Array[Dictionary] = []
	for zs: float in [-1.0, 1.0]:
		for lane: float in BRIDGE_LANES:
			for direction: float in [-1.0, 1.0]:
				var start: Vector3 = Vector3(lane, 0.0, zs * BRIDGE_Z - direction * (BRIDGE_HALF_LENGTH + 4.0))
				var goal: Vector3 = Vector3(lane, 0.0, zs * BRIDGE_Z + direction * (BRIDGE_HALF_LENGTH + 4.0))
				var character: PlayerCharacter = scene.instantiate() as PlayerCharacter
				_zone.add_child(character)
				runners.append({"character": character, "start": start, "goal": goal,
						"name": "puente %s carril %.1f hacia %s" % ["norte" if zs < 0.0 else "sur", lane, "+Z" if direction > 0.0 else "-Z"]})
	await wait_physics_frames()
	var dt: float = 1.0 / float(Engine.physics_ticks_per_second)
	for runner: Dictionary in runners:
		var state := PlayerState.new()
		var start: Vector3 = runner["start"]
		var goal: Vector3 = runner["goal"]
		var ground: Dictionary = _raycast_down(start)
		state.position = (ground["position"] as Vector3) + Vector3(0.0, 0.05, 0.0) if not ground.is_empty() else start
		state.yaw = atan2(-(goal.x - start.x), -(goal.z - start.z))
		(runner["character"] as PlayerCharacter).set_state(state)
	var tick: int = 1
	for _t: int in 480:
		var all_done: bool = true
		for runner: Dictionary in runners:
			var character: PlayerCharacter = runner["character"]
			var goal: Vector3 = runner["goal"]
			var to_goal: Vector3 = (goal - character.global_position) * Vector3(1.0, 0.0, 1.0)
			if runner.get("done", false) or to_goal.length() < 1.0:
				runner["done"] = true
				continue
			all_done = false
			character.simulate(_input(tick, Vector2(0.0, 1.0), atan2(-to_goal.x, -to_goal.z)), dt)
		tick += 1
		if all_done:
			break
		await wait_physics_frames()
	for runner: Dictionary in runners:
		var character: PlayerCharacter = runner["character"]
		assert_true(runner.get("done", false), "%s: reaches the other side (stays at %s)"
				% [runner["name"], character.global_position.snapped(Vector3.ONE * 0.01)])


## The fort gate is kept closed (docs/fortress.md, section 3.1) and with two bodies: the movement one
## (realm layers 5 to 7) and the sight one (layer 4). A character with no realm layer in its mask (the
## offline mode, which does not set it) does not notice it and walks in through the opening from the
## esplanade; with a realm layer the neutral gate stops it (test_fort_gate_collision.gd).
func test_fort_gate_is_closed_by_default() -> void:
	if not assert_not_null(_zone, "the zone must be instantiated"):
		return
	var gates: Array[Node] = []
	for node: Node in tree.get_nodes_in_group(&"fort_gate"):
		if _zone.is_ancestor_of(node):
			gates.append(node)
	if not assert_eq(gates.size(), 1, "a fort gate"):
		return
	var gate: FortGate = gates[0] as FortGate
	if not assert_not_null(gate, "it is a FortGate"):
		return
	assert_false(gate.is_broken(), "the gate is intact")
	assert_eq(gate.get_owner_realm(), 0, "and neutral")
	assert_eq(gate.collision_layer, FortGate.layers_for(0, false), "its movement body stops all three realms")
	assert_eq(gate.get_view_body().collision_layer, PlayerCharacter.STRUCTURE_LAYER, "and its sight body is on layer 4")
	assert_eq(gate.collision_layer & PlayerCharacter.WORLD_COLLISION_LAYER, 0, "it is no longer on the world layer")
	var closed_shape: CollisionShape3D = gate.get_node(^"ColisionCerrada") as CollisionShape3D
	assert_false(closed_shape.disabled, "the shape that closes the opening is active")
	var character: PlayerCharacter = (load(CHARACTER_SCENE_PATH) as PackedScene).instantiate() as PlayerCharacter
	_zone.add_child(character)
	await wait_physics_frames()
	assert_eq(character.collision_mask, PlayerCharacter.WORLD_COLLISION_LAYER | PlayerCharacter.PLAYER_BLOCKER_LAYER,
			"without set_realm_collision() it does not look at the realm layers")
	var ground: Dictionary = _raycast_down(Vector3(-26.0, 0.0, 0.0))
	var state := PlayerState.new()
	state.position = (ground["position"] as Vector3) + Vector3(0.0, 0.05, 0.0)
	state.yaw = -PI * 0.5
	character.set_state(state)
	var dt: float = 1.0 / float(Engine.physics_ticks_per_second)
	for t: int in 200:
		character.simulate(_input(t + 1, Vector2(0.0, 1.0), -PI * 0.5), dt)
		if character.global_position.x > -14.0:
			break
		await wait_physics_frames()
	assert_true(character.global_position.x > -14.0, "crosses the gate opening (reaches x = %.1f)" % character.global_position.x)


## Every gameplay tree or rock from the Terrain3D instancer (visual only) inside the playable area
## has a collision in the scene (if someone paints trees with the editor tool, they would be left
## without collision and the server would not see them).
func test_cover_instances_have_colliders() -> void:
	if not assert_not_null(_zone, "the zone must be instantiated"):
		return
	var terrain: Terrain3D = _zone.get_node(^"Terrain3D") as Terrain3D
	var space: PhysicsDirectSpaceState3D = _zone.get_world_3d().direct_space_state
	var exclude: Array[RID] = [terrain.collision.get_rid()]
	var probe := BoxShape3D.new()
	probe.size = Vector3(0.2, 1.0, 0.2)
	var checked: int = 0
	var missing: PackedStringArray = []
	for region: Terrain3DRegion in terrain.data.get_regions_active():
		var offset: Vector3 = Vector3(region.location.x, 0.0, region.location.y) * float(region.region_size) * region.vertex_spacing
		var instances: Dictionary = region.instances
		for mesh_id: int in instances:
			if not COVER_MESH_IDS.has(mesh_id):
				continue
			var cells: Dictionary = instances[mesh_id]
			for cell: Vector2i in cells:
				for xform: Transform3D in cells[cell][0]:
					var p: Vector3 = xform.origin + offset
					if absf(p.x) > PLAY_HALF or absf(p.z) > WALL_Z:
						continue
					checked += 1
					var query := PhysicsShapeQueryParameters3D.new()
					query.shape = probe
					query.transform = Transform3D(Basis.IDENTITY, p + Vector3(0.0, 1.0, 0.0))
					query.collision_mask = 1
					query.exclude = exclude
					if space.intersect_shape(query, 1).is_empty() and missing.size() < 8:
						missing.append("malla %d en %s" % [mesh_id, p.snapped(Vector3.ONE * 0.1)])
	assert_true(checked > 100, "%d gameplay trees and rocks were checked" % checked)
	assert_true(missing.is_empty(), "without collision: %s" % ", ".join(missing))


## The dedicated server strips the visual layer: no meshes, lights or environment remain, but the
## terrain, the collisions and the spawn points are still there.
func test_strip_for_server_keeps_collisions() -> void:
	if not assert_not_null(_zone, "the zone must be instantiated"):
		return
	var colliders_before: int = _count_nodes(_zone, "CollisionShape3D")
	var removed: int = _zone.call(&"strip_for_server")
	await wait_physics_frames(2)
	assert_true(removed > 100, "removes %d visual nodes" % removed)
	assert_eq(_count_nodes(_zone, "CollisionShape3D"), colliders_before, "keeps all the collision shapes")
	for type_name: String in ["MeshInstance3D", "MultiMeshInstance3D", "Light3D", "WorldEnvironment"]:
		assert_eq(_count_nodes(_zone, type_name, true), 0, "no %s nodes remain" % type_name)
	assert_true(bool(_zone.call(&"is_stripped")), "it is flagged")
	assert_eq(Zones.get_spawn_points(_zone, &"vardheim").size(), 4, "the spawn points remain")
	assert_false(_raycast_down(Vector3(-62.0, 0.0, 0.0)).is_empty(), "the terrain still has collision")


## Nodes of [param type_name] under [param node]. With [param skip_terrain], without descending into
## the internal children of the Terrain3D.
func _count_nodes(node: Node, type_name: String, skip_terrain: bool = false) -> int:
	var count: int = 0
	for child: Node in node.get_children():
		if skip_terrain and child is Terrain3D:
			continue
		if child.is_class(type_name):
			count += 1
		count += _count_nodes(child, type_name, skip_terrain)
	return count


func get_screenshot_points() -> Array[Node]:
	var result: Array[Node] = []
	for node: Node in tree.get_nodes_in_group(&"screenshot_points"):
		if _zone.is_ancestor_of(node):
			result.append(node)
	return result


func _input(tick: int, move: Vector2, look_yaw: float) -> PlayerInput:
	var input := PlayerInput.new()
	input.tick = tick
	input.move = move
	input.look_yaw = look_yaw
	return input.quantized()


func _raycast_down(point: Vector3) -> Dictionary:
	var space: PhysicsDirectSpaceState3D = _zone.get_world_3d().direct_space_state
	# Slightly tilted: vertical rays can miss against HeightMapShape3D.
	var from: Vector3 = Vector3(point.x, point.y + 60.0, point.z)
	var query := PhysicsRayQueryParameters3D.create(from, from + Vector3(0.001, -120.0, 0.0), 1)
	return space.intersect_ray(query)
