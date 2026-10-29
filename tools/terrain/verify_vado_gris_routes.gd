extends SceneTree
## Comprueba que las rutas del Vado Gris se pueden recorrer y que son justas: un PlayerCharacter
## sale de un punto de aparición de cada reino y va, simulando su movimiento real (correr, sin
## esprintar), por el puente y por el vado hasta la puerta del fuerte. Imprime metros y segundos
## de cada ruta y falla si el personaje se atasca o si las dos facciones difieren más de un 3 %.
## Además cruza cada puente por los carriles x = -1,5, 0 y 1,5 en los dos sentidos, recorre el
## interior del fuerte (rampa norte y sur, pasarela hasta encima de la puerta; la puerta cerrada no
## lo para porque el personaje no lleva capa de reino en la máscara) y comprueba que el cauce
## profundo no se puede recorrer desde el vado.
##
## Uso (sin ventana; --fixed-fps hace que la física vaya tan rápido como pueda):
## [codeblock]
## godot --headless --path . --fixed-fps 60 -s res://tools/terrain/verify_vado_gris_routes.gd
## [/codeblock]

const SCENE_PATH: String = "res://scenes/world/zones/vado_gris/vado_gris.tscn"
const CHARACTER_SCENE_PATH: String = "res://scenes/characters/player_character.tscn"
## Distancia a la que se da por alcanzado un punto de paso.
const REACH: float = 1.6
## Ticks sin acercarse al siguiente punto antes de declarar al personaje atascado.
const STUCK_TICKS: int = 180
const MAX_TICKS: int = 60 * 120
## Diferencia relativa máxima permitida entre reinos.
const FAIRNESS_TOLERANCE: float = 0.03
## Cruces que NO deben poder hacerse (fuera del puente y del vado el borde del agua no se
## cruza): [nombre, inicio, meta]. El personaje debe atascarse antes de llegar.
const BLOCKED_CROSSINGS: Array[Array] = [
	["brazo_norte_este", Vector2(40, -90), Vector2(40, -30)],
	["brazo_sur_este", Vector2(40, 90), Vector2(40, 30)],
	["curva_noroeste", Vector2(-70, -70), Vector2(-30, -30)],
	["curva_suroeste", Vector2(-70, 70), Vector2(-30, 30)],
	# Por el lecho profundo desde el vado hacia los puentes, siguiendo el eje del cauce (está
	# cerrado a los dos lados del vado).
	["cauce_desde_vado_norte", Vector2(-62, -3), [Vector2(-61.1, -10.8), Vector2(-58.3, -21.2), Vector2(-53.7, -31.0), Vector2(-43.8, -43.8)]],
	["cauce_desde_vado_sur", Vector2(-62, 3), [Vector2(-61.1, 10.8), Vector2(-58.3, 21.2), Vector2(-53.7, 31.0), Vector2(-43.8, 43.8)]],
]
## Carriles de los puentes que deben cruzarse en los dos sentidos.
const BRIDGE_LANES: Array[float] = [-1.5, 0.0, 1.5]
## Interior del fuerte (el personaje de la prueba no lleva capa de reino y cruza la puerta cerrada):
## explanada, puerta, patio, rampa norte, pasarela norte y oeste hasta encima de la puerta. La del
## sur es el reflejo. Los puntos van por el eje de la rampa y de la pasarela (que no tiene
## barandilla por dentro): se recorre con un alcance de [constant FORT_REACH] m para no recortar
## las esquinas y caerse al patio.
const FORT_ROUTE: Array[Vector2] = [
	Vector2(-26, 0), Vector2(-15, 0), Vector2(-6, -6), Vector2(7, -5), Vector2(7, -18.77),
	Vector2(-18.77, -18.77), Vector2(-18.77, -1.0),
]
const FORT_REACH: float = 0.5
## Altura mínima de la pasarela sobre la meseta al acabar la ruta del interior.
const WALKWAY_MIN_HEIGHT: float = 3.0

## Rutas desde el punto de aparición del norte (Vardheim). Las de Solmarch son su reflejo (z -> -z).
## La meta es la explanada delante de la puerta del fuerte (cara oeste, x = -20).
const ROUTES: Dictionary = {
	"puente": [
		Vector2(-2.5, -132), Vector2(0, -116), Vector2(0, -78), Vector2(0, -62), Vector2(0, -47),
		Vector2(-12, -35), Vector2(-26, -26), Vector2(-29, -10), Vector2(-25, -2),
	],
	"vado": [
		Vector2(-2.5, -132), Vector2(-8, -114), Vector2(-36, -100), Vector2(-70, -74),
		Vector2(-92, -40), Vector2(-90, -10), Vector2(-80, 0), Vector2(-62, 0), Vector2(-44, 0),
		Vector2(-25, 0),
	],
}

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
	var results: Dictionary = {}
	for route_name: String in ROUTES:
		for realm: String in ["vardheim", "solmarch"]:
			var spawn: Marker3D = _first_spawn(zone, realm)
			if spawn == null:
				_fail("No hay punto de aparición de %s" % realm)
				continue
			var waypoints: Array[Vector2] = []
			for p: Vector2 in ROUTES[route_name]:
				waypoints.append(Vector2(p.x, p.y if realm == "vardheim" else -p.y))
			var result: Dictionary = await _walk(zone, spawn, waypoints)
			results["%s/%s" % [route_name, realm]] = result
			print("%-8s %-9s %s: %.1f m en %.1f s (%d ticks)%s" % [route_name, realm,
					"OK" if result["ok"] else "ATASCADO", result["distance"], result["seconds"],
					result["ticks"], "" if result["ok"] else " en " + str(result["where"])])
			if not result["ok"]:
				_fail("%s/%s no llega a la puerta del fuerte" % [route_name, realm])
	for route_name: String in ROUTES:
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
	for mirror: float in [1.0, -1.0]:
		var waypoints: Array[Vector2] = []
		for p: Vector2 in FORT_ROUTE:
			waypoints.append(Vector2(p.x, p.y * mirror))
		var marker := Marker3D.new()
		zone.add_child(marker)
		marker.global_position = _ground_point(zone, waypoints[0])
		marker.rotation.y = -PI * 0.5
		waypoints.remove_at(0)
		var result: Dictionary = await _walk(zone, marker, waypoints, FORT_REACH)
		marker.queue_free()
		var height: float = (result["where"] as Vector3).y - plateau
		var ok: bool = result["ok"] and height > WALKWAY_MIN_HEIGHT
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


## Recorre los puntos de paso corriendo hacia cada uno. Devuelve ok, distancia, segundos y ticks.
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
		# look_yaw: 0 mira a -Z (misma convención que Node3D.rotation.y).
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
