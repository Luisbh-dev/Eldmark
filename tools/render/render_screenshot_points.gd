extends SceneTree
## Herramienta de revisión: carga una zona y guarda una captura desde cada Marker3D del grupo
## "screenshot_points", con las métricas de render de esa vista (FPS, llamadas de dibujo,
## primitivas y objetos visibles).
##
## Necesita ventana (no headless). Uso desde la raíz del proyecto:
## [codeblock]
## godot --path . -s res://tools/render/render_screenshot_points.gd -- --out=C:/ruta/build/vado_gris
## [/codeblock]
## Opciones: [code]--scene=res://...tscn[/code] (por defecto el Vado Gris),
## [code]--only=<nombre>[/code] (una sola vista), [code]--no-capsules[/code] (sin las cápsulas
## rojas de 1,8 m que se ponen en los puntos de aparición y en lugares clave como referencia de
## escala). Las capturas se guardan como [code]<out>/<nombre>.png[/code] y las métricas en
## [code]<out>/metricas.txt[/code].

const DEFAULT_SCENE: String = "res://scenes/world/zones/vado_gris/vado_gris.tscn"
const SCREENSHOT_GROUP: StringName = &"screenshot_points"
const SPAWN_GROUP: StringName = &"spawn_points"
## Fotogramas de espera tras mover la cámara (sombras, LOD y el clipmap del terreno).
const SETTLE_FRAMES: int = 24
## Fotogramas medidos por vista para las métricas.
const MEASURE_FRAMES: int = 90
## Puntos de referencia de escala extra (cápsulas), en coordenadas de la zona.
const EXTRA_CAPSULES: Array[Vector3] = [
	Vector3(0.0, 0.0, -56.0), Vector3(-1.2, 0.0, 56.0), Vector3(-56.0, 0.0, 0.0),
	Vector3(-24.0, 0.0, 0.0), Vector3(-104.0, 0.0, 2.0), Vector3(-6.0, 0.0, -6.0),
]

var _out_dir: String = ""
var _scene_path: String = DEFAULT_SCENE
var _only: String = ""
var _capsules: bool = true


func _initialize() -> void:
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--out="):
			_out_dir = arg.trim_prefix("--out=").replace("\\", "/")
		elif arg.begins_with("--scene="):
			_scene_path = arg.trim_prefix("--scene=")
		elif arg.begins_with("--only="):
			_only = arg.trim_prefix("--only=")
		elif arg == "--no-capsules":
			_capsules = false
	if _out_dir.is_empty():
		_out_dir = ProjectSettings.globalize_path("res://build/screenshots")
	_run()


func _run() -> void:
	await process_frame
	if DisplayServer.get_name() == "headless":
		printerr("Esta herramienta necesita ventana: ejecútala sin --headless.")
		quit(1)
		return
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0
	DirAccess.make_dir_recursive_absolute(_out_dir)

	var scene: PackedScene = load(_scene_path) as PackedScene
	if scene == null:
		printerr("No se pudo cargar %s" % _scene_path)
		quit(1)
		return
	var zone: Node3D = scene.instantiate() as Node3D
	root.add_child(zone)
	var camera := Camera3D.new()
	camera.name = "CamaraRevision"
	camera.far = 1200.0
	root.add_child(camera)
	camera.current = true
	if _capsules:
		_add_capsules(zone)

	var report: PackedStringArray = PackedStringArray()
	report.append("Escena: %s  |  ventana %s  |  %s" % [_scene_path,
			DisplayServer.window_get_size(), RenderingServer.get_video_adapter_name()])
	report.append("vista | fps medios | ms/fotograma | llamadas de dibujo | primitivas | objetos")
	var markers: Array[Node] = get_nodes_in_group(SCREENSHOT_GROUP)
	if markers.is_empty():
		printerr("La escena no tiene nodos en el grupo %s" % SCREENSHOT_GROUP)
	for node: Node in markers:
		var marker: Node3D = node as Node3D
		if marker == null or (not _only.is_empty() and marker.name != _only):
			continue
		camera.global_transform = marker.global_transform
		camera.fov = float(marker.get_meta(&"fov", 60.0))
		for _i: int in SETTLE_FRAMES:
			await process_frame
		var frame_ms: float = 0.0
		var draw_calls: float = 0.0
		var primitives: float = 0.0
		var objects: float = 0.0
		var started: int = Time.get_ticks_usec()
		for _i: int in MEASURE_FRAMES:
			await process_frame
			draw_calls += Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)
			primitives += Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME)
			objects += Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME)
		frame_ms = float(Time.get_ticks_usec() - started) / 1000.0 / MEASURE_FRAMES
		await RenderingServer.frame_post_draw
		var image: Image = root.get_texture().get_image()
		var path: String = _out_dir.path_join("%s.png" % marker.name)
		var error: Error = image.save_png(path)
		var line: String = "%s | %.0f | %.2f | %.0f | %.0f | %.0f" % [marker.name, 1000.0 / frame_ms,
				frame_ms, draw_calls / MEASURE_FRAMES, primitives / MEASURE_FRAMES, objects / MEASURE_FRAMES]
		report.append(line)
		print("%s -> %s (%s)" % [line, path, error_string(error)])
	var file: FileAccess = FileAccess.open(_out_dir.path_join("metricas.txt"), FileAccess.WRITE)
	if file != null:
		file.store_string("\n".join(report) + "\n")
		file.close()
	quit(0)


## Cápsulas rojas de 1,8 m (el tamaño de PlayerCharacter) como referencia de escala.
func _add_capsules(zone: Node3D) -> void:
	var mesh := CapsuleMesh.new()
	mesh.radius = 0.4
	mesh.height = 1.8
	var material := StandardMaterial3D.new()
	material.albedo_color = Color(0.85, 0.15, 0.12)
	mesh.material = material
	var points: Array[Vector3] = []
	for node: Node in get_nodes_in_group(SPAWN_GROUP):
		points.append((node as Node3D).global_position)
	var space: PhysicsDirectSpaceState3D = zone.get_world_3d().direct_space_state
	for extra: Vector3 in EXTRA_CAPSULES:
		var query := PhysicsRayQueryParameters3D.create(extra + Vector3(0.0, 80.0, 0.0),
				extra + Vector3(0.001, -40.0, 0.0), 1)
		var hit: Dictionary = space.intersect_ray(query)
		if not hit.is_empty():
			points.append(hit["position"])
	for point: Vector3 in points:
		var capsule := MeshInstance3D.new()
		capsule.mesh = mesh
		capsule.position = point + Vector3(0.0, 0.9, 0.0)
		root.add_child(capsule)
