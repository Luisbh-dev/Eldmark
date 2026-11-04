extends SceneTree
## Writes the approach routes to the Vado Gris fort as shared data
## ([ApproachRoutes], docs/fortress.md section 7) to [code]data/routes/vado_gris.tres[/code].
##
## Usage (from the project root, windowless):
## [codeblock]
## godot --headless --path . -s res://tools/terrain/export_vado_gris_routes.gd
## [/codeblock]
## The points are those of the routes walked and verified by [code]verify_vado_gris_routes.gd[/code]
## from the Vardheim spawn point to the esplanade in front of the fort gate
## (the same bridge route the [RouteDemoInput] demo follows); Solmarch's are their
## exact mirror (z -> -z), because the zone is symmetric. Since GUE-45 it also writes the fort walkway (its
## height, its axis and the two ramps used to climb up). If the zone layout changes, the points are changed here,
## this script is run again and the verification is passed.

const OUTPUT_PATH: String = "res://data/routes/vado_gris.tres"

## Where the fort is (x, z): the centre of the gate opening (west face of the enclosure), the centre of the
## capture circle (the CaptureCircle marker) and its radius. They are those in vado_gris.tscn;
## tests/test_siege_zone.gd checks that they still match the scene's.
const GATE_POINT: Vector2 = Vector2(-20.0, 0.0)
const CIRCLE_POINT: Vector2 = Vector2(-8.5, 0.0)
const CIRCLE_RADIUS: float = 5.0
## The palisade enclosure (40 x 40 m, docs/zonas/vado_gris.md), measured from the gate: depth and width.
const ENCLOSURE_SIZE: Vector2 = Vector2(40.0, 40.0)
## The walkway (GUE-45; docs/zonas/vado_gris.md): its floor is 3.35 m above the fort plateau (10.2 m: at 13.55 m) and its axis
## at 18.77 m from the centre (the 20 m half side, minus the radius of the logs and half of their 2 m width). The bots
## walk along the axis from the top of the north ramp to that of the south one, passing over the gate (west face).
const WALKWAY_HEIGHT: float = 13.55
const WALKWAY_AXIS: float = 18.77
const WALKWAY_PATH: Array[Vector2] = [
	Vector2(7.0, -WALKWAY_AXIS), Vector2(-WALKWAY_AXIS, -WALKWAY_AXIS), Vector2(-WALKWAY_AXIS, WALKWAY_AXIS),
	Vector2(7.0, WALKWAY_AXIS),
]
## North ramp from the courtyard: a point between the gate and the tower but outside the capture circle (9.6 m from its
## centre: with the points verify_vado_gris_routes.gd used to walk, (-6, -6) and (7, -5), whoever went up crossed the
## edge of the circle and contested the capture in passing, and the bots' recapture dragged on), in front of the foot of the
## ramp (x = 7, it climbs towards -Z from z = -10.87) and its top, on the walkway axis. The south one is its mirror.
const NORTH_RAMP: Array[Vector2] = [Vector2(-12.0, -9.0), Vector2(7.0, -8.0), Vector2(7.0, -WALKWAY_AXIS)]

## Routes from the northern spawn point (Vardheim): (x, z).
const VARDHEIM_ROUTES: Dictionary = {
	ApproachRoutes.BRIDGE: [
		Vector2(-2.5, -132), Vector2(0, -116), Vector2(0, -78), Vector2(0, -62), Vector2(0, -47),
		Vector2(-12, -35), Vector2(-26, -26), Vector2(-29, -10), Vector2(-25, -2),
	],
	ApproachRoutes.FORD: [
		Vector2(-2.5, -132), Vector2(-8, -114), Vector2(-36, -100), Vector2(-70, -74),
		Vector2(-92, -40), Vector2(-90, -10), Vector2(-80, 0), Vector2(-62, 0), Vector2(-44, 0),
		Vector2(-25, 0),
	],
}


func _initialize() -> void:
	var routes := ApproachRoutes.new()
	routes.zone_id = &"vado_gris"
	routes.gate_point = GATE_POINT
	routes.circle_point = CIRCLE_POINT
	routes.circle_radius = CIRCLE_RADIUS
	routes.enclosure_size = ENCLOSURE_SIZE
	routes.walkway_height = WALKWAY_HEIGHT
	routes.walkway_path = PackedVector2Array(WALKWAY_PATH)
	var north_ramp := PackedVector2Array(NORTH_RAMP)
	var south_ramp := PackedVector2Array()
	for point: Vector2 in NORTH_RAMP:
		south_ramp.append(Vector2(point.x, -point.y))
	var ramps: Array[PackedVector2Array] = [north_ramp, south_ramp]
	routes.walkway_ramps = ramps
	for route: StringName in VARDHEIM_ROUTES:
		var north := PackedVector2Array()
		var south := PackedVector2Array()
		for point: Vector2 in VARDHEIM_ROUTES[route]:
			north.append(point)
			south.append(Vector2(point.x, -point.y))
		routes.set_points(route, RealmCatalog.VARDHEIM, north)
		routes.set_points(route, RealmCatalog.SOLMARCH, south)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUTPUT_PATH.get_base_dir()))
	var error: Error = ResourceSaver.save(routes, OUTPUT_PATH)
	if error != OK:
		printerr("No se pudo guardar %s (%s)" % [OUTPUT_PATH, error_string(error)])
		quit(1)
		return
	for route: StringName in routes.get_route_ids():
		print("%s: %.1f m" % [route, routes.get_length(route, RealmCatalog.VARDHEIM)])
	print("pasarela: %.1f m a %.2f m de altura, puesto en %s" % [routes.walkway_length(), routes.walkway_height,
			routes.walkway_post()])
	print("Guardado %s" % OUTPUT_PATH)
	quit(0)
