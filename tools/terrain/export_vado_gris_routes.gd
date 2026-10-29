extends SceneTree
## Escribe las rutas de aproximación al fuerte del Vado Gris como datos compartidos
## ([ApproachRoutes], docs/fuerte.md sección 7) en [code]data/routes/vado_gris.tres[/code].
##
## Uso (desde la raíz del proyecto, sin ventana):
## [codeblock]
## godot --headless --path . -s res://tools/terrain/export_vado_gris_routes.gd
## [/codeblock]
## Los puntos son los de las rutas que recorre y verifica [code]verify_vado_gris_routes.gd[/code]
## desde el punto de aparición de Vardheim hasta la explanada delante de la puerta del fuerte
## (la misma ruta del puente que sigue la demo de [RouteDemoInput]); las de Solmarch son su
## reflejo exacto (z -> -z), porque la zona es simétrica. Si cambia el trazado de la zona, se
## cambian aquí los puntos, se vuelve a lanzar este script y se pasa la verificación.

const OUTPUT_PATH: String = "res://data/routes/vado_gris.tres"

## Rutas desde el punto de aparición del norte (Vardheim): (x, z).
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
	print("Guardado %s" % OUTPUT_PATH)
	quit(0)
