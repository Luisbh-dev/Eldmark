extends SceneTree
## Hornea la malla de navegación de los PNJ del Vado Gris (docs/fuerte.md, sección 4.1, MUN-06) y
## la guarda en texto en [code]scenes/world/zones/vado_gris/vado_gris_navmesh.tres[/code].
##
## Uso (desde la raíz del proyecto, sin ventana; unos segundos):
## [codeblock]
## godot --headless --path . -s res://tools/bake_navmesh.gd
## godot --headless --path . -s res://tools/bake_navmesh.gd -- --cell=0.3
## [/codeblock]
## Qué se hornea (todo lo demás da igual, y el resultado cuenta para el servidor, que no tiene
## mallas):
## [br]- La geometría de [Terrain3D] con [code]generate_nav_mesh_source_geometry(aabb, false)[/code]:
## con [code]true[/code] (el valor por defecto) devuelve 0 caras porque no hay navegación pintada.
## [br]- Las colisiones estáticas de las capas 1 (mundo), 3 (bloqueos invisibles del jugador: con
## solo la 1 hay ruta por el lecho profundo del río) y 4 (estructuras: el cuerpo de vista de la
## puerta del fuerte, que la deja [b]cerrada[/b]). Las capas de reino 5 a 7 de la puerta no se
## hornean: el paso por la puerta lo da un enlace que crea el servidor y no está aquí.
## [br]- Celda de 0,25 m y radio de agente de 0,4 m (con celda de 0,5 m el radio se redondea a 0,5 y
## la pasarela de 2 m deja solo 1 m útil). Si el archivo sale de más de 20 MB hay que subir la
## celda a 0,3 con [code]--cell=0.3[/code].
## [br][br]
## Es determinista (misma escena, mismo resultado). Hay que repetirlo si cambia la geometría de la
## zona (rampas, pasarela, puentes, murallas, bloqueos); lo comprueba tests/test_navmesh.gd.

const ZONE_SCENE_PATH: String = "res://scenes/world/zones/vado_gris/vado_gris.tscn"
const OUTPUT_PATH: String = "res://scenes/world/zones/vado_gris/vado_gris_navmesh.tres"
## Lado de la celda y su altura (m).
const DEFAULT_CELL_SIZE: float = 0.25
const CELL_HEIGHT: float = 0.25
## Cápsula del agente: la del personaje (radio 0,4 m, altura 1,8 m).
const AGENT_RADIUS: float = 0.4
const AGENT_HEIGHT: float = 1.8
## Escalón máximo y pendiente máxima caminables. El personaje sube hasta 46° (floor_max_angle) y
## salva 0,35 m con el ajuste al suelo; la malla se queda un poco por debajo para no meter a los
## PNJ por laderas límite.
const AGENT_MAX_CLIMB: float = 0.4
const AGENT_MAX_SLOPE_DEG: float = 44.0
## Zona que se hornea: el área jugable (300 x 300 m) y alturas de -6 a 64 m.
const BAKE_AABB: AABB = AABB(Vector3(-150.0, -6.0, -150.0), Vector3(300.0, 70.0, 300.0))
## Capas 1 | 3 | 4.
const COLLISION_MASK: int = PlayerCharacter.WORLD_COLLISION_LAYER \
		| PlayerCharacter.PLAYER_BLOCKER_LAYER | PlayerCharacter.STRUCTURE_LAYER
## Tamaño a partir del cual se avisa de que hay que subir la celda.
const MAX_FILE_BYTES: int = 20 * 1024 * 1024

var _cell_size: float = DEFAULT_CELL_SIZE


func _initialize() -> void:
	_run()


func _run() -> void:
	await process_frame
	for argument: String in OS.get_cmdline_user_args():
		if argument.begins_with("--cell="):
			_cell_size = float(argument.trim_prefix("--cell="))
	var started: int = Time.get_ticks_msec()
	print("Cargando %s..." % ZONE_SCENE_PATH)
	var zone: Node3D = (load(ZONE_SCENE_PATH) as PackedScene).instantiate() as Node3D
	root.add_child(zone)
	await physics_frame
	await physics_frame

	var navmesh := NavigationMesh.new()
	navmesh.cell_size = _cell_size
	navmesh.cell_height = CELL_HEIGHT
	navmesh.agent_radius = AGENT_RADIUS
	navmesh.agent_height = AGENT_HEIGHT
	navmesh.agent_max_climb = AGENT_MAX_CLIMB
	navmesh.agent_max_slope = AGENT_MAX_SLOPE_DEG
	navmesh.geometry_parsed_geometry_type = NavigationMesh.PARSED_GEOMETRY_STATIC_COLLIDERS
	navmesh.geometry_collision_mask = COLLISION_MASK
	navmesh.geometry_source_geometry_mode = NavigationMesh.SOURCE_GEOMETRY_ROOT_NODE_CHILDREN
	navmesh.filter_baking_aabb = BAKE_AABB

	var source := NavigationMeshSourceGeometryData3D.new()
	NavigationServer3D.parse_source_geometry_data(navmesh, source, zone)
	print("Colisiones estáticas (capas 1|3|4) leídas: %d caras" % (source.get_vertices().size() / 3))

	var terrain: Terrain3D = zone.get_node(^"Terrain3D") as Terrain3D
	var faces: PackedVector3Array = terrain.generate_nav_mesh_source_geometry(BAKE_AABB, false)
	print("Geometría de Terrain3D: %d caras" % (faces.size() / 3))
	if faces.is_empty():
		printerr("Terrain3D no ha devuelto geometría: no se guarda nada")
		quit(1)
		return
	source.add_faces(faces, Transform3D.IDENTITY)

	print("Horneando (celda %.2f m, radio %.2f m)..." % [_cell_size, AGENT_RADIUS])
	NavigationServer3D.bake_from_source_geometry_data(navmesh, source)
	var polygon_count: int = navmesh.get_polygon_count()
	print("Malla: %d vértices, %d polígonos" % [navmesh.get_vertices().size(), polygon_count])
	if polygon_count == 0:
		printerr("El horneado no ha producido polígonos: no se guarda nada")
		quit(1)
		return

	var error: Error = ResourceSaver.save(navmesh, OUTPUT_PATH)
	if error != OK:
		printerr("No se pudo guardar %s (%s)" % [OUTPUT_PATH, error_string(error)])
		quit(1)
		return
	var size: int = FileAccess.get_file_as_bytes(OUTPUT_PATH).size()
	print("%s (%.1f MB) en %.1f s" % [OUTPUT_PATH, size / 1048576.0, (Time.get_ticks_msec() - started) / 1000.0])
	if size > MAX_FILE_BYTES:
		printerr("El archivo pasa de 20 MB: repite con --cell=0.3 (y anótalo en docs/fuerte.md)")
		quit(1)
		return
	quit(0)
