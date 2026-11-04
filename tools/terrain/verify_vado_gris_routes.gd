extends SceneTree
## Checks that the Vado Gris routes can be walked and that they are fair: a PlayerCharacter
## leaves from a spawn point of each realm and goes, simulating its real movement (running, without
## sprinting), over the bridge and through the ford to the fort gate. It prints metres and seconds
## for each route and fails if the character gets stuck or if the two factions differ by more than 3 %.
## It also crosses each bridge along the lanes x = -1.5, 0 and 1.5 in both directions, walks the
## interior of the fort (north and south ramp, walkway up to above the gate; the closed gate does not
## stop it because the character carries no realm layer in the mask) and checks that the deep
## channel cannot be walked from the ford.
##
## Usage (windowless; --fixed-fps makes the physics run as fast as it can):
## [codeblock]
## godot --headless --path . --fixed-fps 60 -s res://tools/terrain/verify_vado_gris_routes.gd
## [/codeblock]

const SCENE_PATH: String = "res://scenes/world/zones/vado_gris/vado_gris.tscn"
const CHARACTER_SCENE_PATH: String = "res://scenes/characters/player_character.tscn"
## Distance at which a waypoint is considered reached.
const REACH: float = 1.6
## Ticks without getting closer to the next point before declaring the character stuck.
const STUCK_TICKS: int = 180
const MAX_TICKS: int = 60 * 120
## Maximum relative difference allowed between realms.
const FAIRNESS_TOLERANCE: float = 0.03
## Crossings that must NOT be possible (outside the bridge and the ford the water's edge cannot
## be crossed): [name, start, goal]. The character must get stuck before arriving.
const BLOCKED_CROSSINGS: Array[Array] = [
	["brazo_norte_este", Vector2(40, -90), Vector2(40, -30)],
	["brazo_sur_este", Vector2(40, 90), Vector2(40, 30)],
	["curva_noroeste", Vector2(-70, -70), Vector2(-30, -30)],
	["curva_suroeste", Vector2(-70, 70), Vector2(-30, 30)],
	# Along the deep bed from the ford towards the bridges, following the channel axis (it is
	# closed off on both sides of the ford).
	["cauce_desde_vado_norte", Vector2(-62, -3), [Vector2(-61.1, -10.8), Vector2(-58.3, -21.2), Vector2(-53.7, -31.0), Vector2(-43.8, -43.8)]],
	["cauce_desde_vado_sur", Vector2(-62, 3), [Vector2(-61.1, 10.8), Vector2(-58.3, 21.2), Vector2(-53.7, 31.0), Vector2(-43.8, 43.8)]],
]
## Bridge lanes that must be crossed in both directions.
const BRIDGE_LANES: Array[float] = [-1.5, 0.0, 1.5]
## Fort interior (the test character carries no realm layer and crosses the closed gate):
## esplanade and gate ([constant FORT_ENTRY]) and, since GUE-45, the climb to the walkway from the route data, the one
## followed by the siege bots: for each ramp, its courtyard points, its top and the walkway axis up to the post
## above the gate. The points follow the axis of the ramp and the walkway (which has no railing on the inside): it is
## walked with a reach of [constant FORT_REACH] m so as not to cut corners and fall into the courtyard.
const FORT_ENTRY: Array[Vector2] = [Vector2(-26, 0), Vector2(-15, 0)]
const FORT_REACH: float = 0.5
## Minimum height of the walkway above the plateau at the end of the interior route.
const WALKWAY_MIN_HEIGHT: float = 3.0

## Approach routes to the fort, as shared data (written by export_vado_gris_routes.gd and
## followed by the siege bots): from each realm's spawn point to the esplanade in front of the
## fort gate (west face, x = -20). Solmarch's are the mirror of Vardheim's.
const ROUTES_PATH: String = "res://data/routes/vado_gris.tres"

var _failed: bool = false
var _tick: int = 1


func _initialize() -> void:
	_run()


func _run() -> void:
	await process_frame
	var zone: Node3D = (load(SCENE_PATH) as PackedScene).instantiate() as Node3D
	root.add_child(zone)
	await physics_frame
	await physics_frame
	var routes: ApproachRoutes = load(ROUTES_PATH) as ApproachRoutes
	if routes == null or routes.get_route_ids().is_empty():
		_fail("No se pudieron cargar las rutas de %s" % ROUTES_PATH)
		quit(1)
		return
	var results: Dictionary = {}
	for route_name: StringName in routes.get_route_ids():
		for realm: String in ["vardheim", "solmarch"]:
			var spawn: Marker3D = _first_spawn(zone, realm)
			if spawn == null:
				_fail("No hay punto de aparición de %s" % realm)
				continue
			var waypoints: Array[Vector2] = []
			waypoints.assign(routes.get_points(route_name, StringName(realm)))
			if waypoints.is_empty():
				_fail("La ruta %s no tiene puntos para %s" % [route_name, realm])
				continue
			var result: Dictionary = await _walk(zone, spawn, waypoints)
			results["%s/%s" % [route_name, realm]] = result
			print("%-8s %-9s %s: %.1f m en %.1f s (%d ticks)%s" % [route_name, realm,
					"OK" if result["ok"] else "ATASCADO", result["distance"], result["seconds"],
					result["ticks"], "" if result["ok"] else " en " + str(result["where"])])
			if not result["ok"]:
				_fail("%s/%s no llega a la puerta del fuerte" % [route_name, realm])
	for route_name: StringName in routes.get_route_ids():
		var a: Dictionary = results.get("%s/vardheim" % route_name, {})
		var b: Dictionary = results.get("%s/solmarch" % route_name, {})
		if a.is_empty() or b.is_empty() or not a["ok"] or not b["ok"]:
			continue
		var diff: float = absf(float(a["seconds"]) - float(b["seconds"])) / maxf(float(a["seconds"]), 0.001)
		print("Equidad %s: diferencia %.2f %%" % [route_name, diff * 100.0])
		if diff > FAIRNESS_TOLERANCE:
			_fail("La ruta %s no es justa (%.1f %%)" % [route_name, diff * 100.0])
	for zs: float in [-1.0, 1.0]:
		for lane: float in BRIDGE_LANES:
			for direction: float in [-1.0, 1.0]:
				var start: Vector2 = Vector2(lane, zs * 62.0 - direction * 16.0)
				var goal: Vector2 = Vector2(lane, zs * 62.0 + direction * 16.0)
				var marker := Marker3D.new()
				zone.add_child(marker)
				marker.global_position = _ground_point(zone, start)
				marker.rotation.y = atan2(-(goal.x - start.x), -(goal.y - start.y))
				var result: Dictionary = await _walk(zone, marker, [goal] as Array[Vector2])
				marker.queue_free()
				print("carril puente %s x=%+.1f hacia %s: %s" % ["norte" if zs < 0.0 else "sur", lane,
						"+Z" if direction > 0.0 else "-Z", "OK" if result["ok"] else "ATASCADO en " + str(result["where"])])
				if not result["ok"]:
					_fail("El carril x=%.1f del puente %s no se cruza" % [lane, "norte" if zs < 0.0 else "sur"])
	var fort_seconds: Array[float] = []
	var plateau: float = _ground_point(zone, Vector2(-8.5, 0.0)).y
	if not routes.has_walkway():
		_fail("Las rutas no conocen la pasarela del fuerte")
	for ramp_index: int in routes.walkway_ramps.size():
		var mirror: float = 1.0 if routes.walkway_ramps[ramp_index][0].y < 0.0 else -1.0
		var waypoints: Array[Vector2] = _walkway_route(routes, ramp_index)
		var marker := Marker3D.new()
		zone.add_child(marker)
		marker.global_position = _ground_point(zone, waypoints[0])
		marker.rotation.y = -PI * 0.5
		waypoints.remove_at(0)
		var result: Dictionary = await _walk(zone, marker, waypoints, FORT_REACH)
		marker.queue_free()
		var height: float = (result["where"] as Vector3).y - plateau
		var ok: bool = result["ok"] and height > WALKWAY_MIN_HEIGHT \
				and absf((result["where"] as Vector3).y - routes.walkway_height) < 0.1
		print("interior del fuerte (rampa %s): %s, %.1f m en %.1f s, acaba a %.2f m sobre la meseta" % [
				"norte" if mirror > 0.0 else "sur", "OK" if ok else "ATASCADO en " + str(result["where"]),
				result["distance"], result["seconds"], height])
		if not ok:
			_fail("No se llega a la pasarela por la rampa %s" % ("norte" if mirror > 0.0 else "sur"))
		fort_seconds.append(result["seconds"])
	if fort_seconds.size() == 2:
		var fort_diff: float = absf(fort_seconds[0] - fort_seconds[1]) / maxf(fort_seconds[0], 0.001)
		print("Equidad interior: diferencia %.2f %%" % (fort_diff * 100.0))
		if fort_diff > FAIRNESS_TOLERANCE:
			_fail("Las dos rampas del fuerte no son equivalentes (%.1f %%)" % (fort_diff * 100.0))
	for spec: Array in BLOCKED_CROSSINGS:
		var start: Vector2 = spec[1]
		var marker := Marker3D.new()
		zone.add_child(marker)
		var ground: Vector3 = _ground_point(zone, start)
		marker.global_position = ground
		var goals: Array[Vector2] = []
		if spec[2] is Vector2:
			goals.append(spec[2])
		else:
			goals.assign(spec[2])
		var result: Dictionary = await _walk(zone, marker, goals)
		marker.queue_free()
		print("cruce prohibido %-17s %s" % [spec[0], "bloqueado (bien)" if not result["ok"] else "SE PUEDE CRUZAR"])
		if result["ok"]:
			_fail("Se puede cruzar el río por %s" % spec[0])
	print("RESULTADO: %s" % ("FALLO" if _failed else "todas las rutas se recorren, son justas, los puentes se cruzan por cualquier carril, se llega a la pasarela y el río solo se cruza por el puente y el vado"))
	quit(1 if _failed else 0)


## The climb to the walkway via ramp [param ramp_index] of [param routes] (GUE-45), as a siege bot follows it:
## the entry through the gate, the ramp points and, along the walkway axis, its corners up to the post.
func _walkway_route(routes: ApproachRoutes, ramp_index: int) -> Array[Vector2]:
	var waypoints: Array[Vector2] = []
	waypoints.assign(FORT_ENTRY)
	var ramp: PackedVector2Array = routes.walkway_ramps[ramp_index]
	for point: Vector2 in ramp:
		waypoints.append(point)
	var post: Vector2 = routes.walkway_post()
	var post_offset: float = routes.walkway_offset(post)
	var top_offset: float = routes.walkway_offset(ramp[ramp.size() - 1])
	var offsets: PackedFloat32Array = routes.walkway_vertex_offsets()
	var corners: Array[Vector2] = []
	for vertex: int in offsets.size():
		if offsets[vertex] > minf(top_offset, post_offset) + 0.01 and offsets[vertex] < maxf(top_offset, post_offset) - 0.01:
			corners.append(routes.walkway_path[vertex])
	if top_offset > post_offset:
		corners.reverse()
	waypoints.append_array(corners)
	waypoints.append(post)
	return waypoints


func _ground_point(zone: Node3D, p: Vector2) -> Vector3:
	var space: PhysicsDirectSpaceState3D = zone.get_world_3d().direct_space_state
	var query := PhysicsRayQueryParameters3D.create(Vector3(p.x, 120.0, p.y), Vector3(p.x + 0.001, -20.0, p.y), 1)
	var hit: Dictionary = space.intersect_ray(query)
	return hit.get("position", Vector3(p.x, 10.0, p.y))


func _first_spawn(zone: Node, realm: String) -> Marker3D:
	for node: Node in get_nodes_in_group(&"spawn_points"):
		if zone.is_ancestor_of(node) and String(node.get_meta(&"realm", "")) == realm:
			return node as Marker3D
	return null


## Walks the waypoints running towards each one. Returns ok, distance, seconds and ticks.
func _walk(zone: Node3D, spawn: Marker3D, waypoints: Array[Vector2], reach: float = REACH) -> Dictionary:
	var character: PlayerCharacter = (load(CHARACTER_SCENE_PATH) as PackedScene).instantiate() as PlayerCharacter
	zone.add_child(character)
	await physics_frame
	var state := PlayerState.new()
	state.position = spawn.global_position + Vector3(0.0, 0.05, 0.0)
	state.yaw = spawn.global_rotation.y
	character.set_state(state)
	var dt: float = 1.0 / float(Engine.physics_ticks_per_second)
	var index: int = 0
	var ticks: int = 0
	var distance: float = 0.0
	var best: float = INF
	var since_progress: int = 0
	var last: Vector3 = character.global_position
	var ok: bool = false
	while ticks < MAX_TICKS:
		await physics_frame
		var p: Vector3 = character.global_position
		var target: Vector2 = waypoints[index]
		var to_target: Vector2 = target - Vector2(p.x, p.z)
		if to_target.length() < reach:
			index += 1
			best = INF
			since_progress = 0
			if index >= waypoints.size():
				ok = true
				break
			continue
		# look_yaw: 0 looks along -Z (same convention as Node3D.rotation.y).
		var input := PlayerInput.new()
		input.tick = _tick
		_tick += 1
		input.look_yaw = atan2(-to_target.x, -to_target.y)
		input.move = Vector2(0.0, 1.0)
		character.simulate(input.quantized(), dt)
		ticks += 1
		var moved: Vector3 = character.global_position - last
		distance += Vector2(moved.x, moved.z).length()
		last = character.global_position
		if to_target.length() < best - 0.05:
			best = to_target.length()
			since_progress = 0
		else:
			since_progress += 1
			if since_progress > STUCK_TICKS:
				break
	var result: Dictionary = {"ok": ok, "distance": distance, "seconds": ticks * dt, "ticks": ticks,
			"where": character.global_position}
	character.queue_free()
	await physics_frame
	return result


func _fail(message: String) -> void:
	_failed = true
	printerr(message)
