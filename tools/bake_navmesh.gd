extends SceneTree
## Bakes the NPC navigation mesh of the Vado Gris (docs/fortress.md, section 4.1, MUN-06) and
## saves it as text in [code]scenes/world/zones/vado_gris/vado_gris_navmesh.tres[/code].
##
## Usage (from the project root, no window; a few seconds):
## [codeblock]
## godot --headless --path . -s res://tools/bake_navmesh.gd
## godot --headless --path . -s res://tools/bake_navmesh.gd -- --cell=0.3
## [/codeblock]
## What gets baked (nothing else matters, and the result counts for the server, which has no
## meshes):
## [br]- The [Terrain3D] geometry with [code]generate_nav_mesh_source_geometry(aabb, false)[/code]:
## with [code]true[/code] (the default value) it returns 0 faces because there is no painted navigation.
## [br]- The static collisions of layers 1 (world), 3 (the player's invisible blockers: with
## only 1 there is a route through the deep riverbed) and 4 (structures: the fort gate's
## sight body, which leaves it [b]closed[/b]). The gate's realm layers 5 to 7 are not
## baked: passage through the gate is provided by a link the server creates and is not here.
## [br]- A 0.25 m cell and a 0.4 m agent radius (with a 0.5 m cell the radius is rounded up to 0.5 and
## the 2 m walkway leaves only 1 m usable). If the file comes out over 20 MB the cell
## has to be raised to 0.3 with [code]--cell=0.3[/code].
## [br][br]
## It is deterministic (same scene, same result). It has to be repeated if the zone's geometry changes
## (ramps, walkway, bridges, walls, blockers); tests/test_navmesh.gd checks it.

const ZONE_SCENE_PATH: String = "res://scenes/world/zones/vado_gris/vado_gris.tscn"
const OUTPUT_PATH: String = "res://scenes/world/zones/vado_gris/vado_gris_navmesh.tres"
## Cell side and height (m).
const DEFAULT_CELL_SIZE: float = 0.25
const CELL_HEIGHT: float = 0.25
## Agent capsule: the character's (radius 0.4 m, height 1.8 m).
const AGENT_RADIUS: float = 0.4
const AGENT_HEIGHT: float = 1.8
## Maximum walkable step and slope. The character climbs up to 46° (floor_max_angle) and
## clears 0.35 m with floor snapping; the mesh stays a bit below so as not to send
## NPCs up borderline slopes.
const AGENT_MAX_CLIMB: float = 0.4
const AGENT_MAX_SLOPE_DEG: float = 44.0
## Zone that gets baked: the playable area (300 x 300 m) and heights from -6 to 64 m.
const BAKE_AABB: AABB = AABB(Vector3(-150.0, -6.0, -150.0), Vector3(300.0, 70.0, 300.0))
## Layers 1 | 3 | 4.
const COLLISION_MASK: int = PlayerCharacter.WORLD_COLLISION_LAYER \
		| PlayerCharacter.PLAYER_BLOCKER_LAYER | PlayerCharacter.STRUCTURE_LAYER
## Size above which a warning says the cell has to be raised.
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
		printerr("El archivo pasa de 20 MB: repite con --cell=0.3 (y anótalo en docs/fortress.md)")
		quit(1)
		return
	quit(0)
