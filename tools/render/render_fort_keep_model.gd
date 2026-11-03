extends SceneTree
## Herramienta de revisión del torreón del fuerte (ART-57): renders del modelo solo, sin zona,
## sobre un suelo liso y con la luz del Vado Gris (sol con sombras y el cielo del ambiente de
## la frontera, sin niebla). Saca una vuelta de 8 ángulos, los detalles (puerta, base, cadalso, remate,
## estandartes), los tres niveles de detalle, la colisión de baja resolución, las cuatro paletas de
## reino y las vistas a 10, 30 y 60 m a altura de jugador.
##
## Necesita ventana (no headless). Uso desde la raíz del proyecto:
## [codeblock]
## godot --path . --resolution 1600x1200 -s res://tools/render/render_fort_keep_model.gd -- \
##     --out=C:/ruta/build/torreon/modelo
## [/codeblock]
## Con [code]--only=<prefijo>[/code] solo guarda las vistas cuyo nombre empiece así; con
## [code]--no-ssao[/code] apaga la oclusión ambiental de pantalla y con [code]--shadow-quality=N[/code]
## (0 a 5, como RenderingServer.ShadowQuality) fuerza el filtro de sombras suaves de la luz direccional:
## sirve para separar el moteado de la penumbra del de las texturas. Con [code]--debug-bg[/code]
## el fondo es magenta: sirve para encontrar rendijas por las que se ve el otro lado del muro.
## Con [code]--shimmer[/code] no guarda vistas: mide el centelleo de la piedra en movimiento (ver [method _measure_shimmer]).

const KEEP_PATH: String = "res://assets/models/environment/custom/fort_keep.glb"
const ENVIRONMENT_PATH: String = "res://assets/environments/vado_gris_frontier.tres"
const SETTLE_FRAMES: int = 8

## [nombre, posición de la cámara respecto al origen del torreón, punto al que mira, fov, reino,
## modo, extras]. Modos: "" (LOD0), "lod1" (nivel medio), "lod2" (silueta lejana), "ranges" (los tres
## con los rangos y el fundido de FortKeepPreview.apply_lods), "colision" (LOD0 con la malla de
## colisión encima). Extras (opcional): owner, contest, progress (estandarte).
const VIEWS: Array = [
	["vuelta_0_oeste", Vector3(-46, 8, 0), Vector3(0, 13, 0), 40.0, "eldrun", ""],
	["vuelta_1_suroeste", Vector3(-33, 8, 33), Vector3(0, 13, 0), 40.0, "eldrun", ""],
	["vuelta_2_sur", Vector3(0, 8, 46), Vector3(0, 13, 0), 40.0, "eldrun", ""],
	["vuelta_3_sureste", Vector3(33, 8, 33), Vector3(0, 13, 0), 40.0, "eldrun", ""],
	["vuelta_4_este", Vector3(46, 8, 0), Vector3(0, 13, 0), 40.0, "eldrun", ""],
	["vuelta_5_noreste", Vector3(33, 8, -33), Vector3(0, 13, 0), 40.0, "eldrun", ""],
	["vuelta_6_norte", Vector3(0, 8, -46), Vector3(0, 13, 0), 40.0, "eldrun", ""],
	["vuelta_7_noroeste", Vector3(-33, 8, -33), Vector3(0, 13, 0), 40.0, "eldrun", ""],
	["detalle_puerta", Vector3(-12.0, 2.0, 6.5), Vector3(-5.0, 2.5, 0.2), 45.0, "eldrun", ""],
	["detalle_puerta_frente", Vector3(-11.5, 2.0, 0.0), Vector3(-4.8, 2.6, 0.0), 45.0, "eldrun", ""],
	["detalle_cadalso", Vector3(-11.0, 12.5, 12.0), Vector3(-1.0, 17.0, 0.0), 45.0, "eldrun", ""],
	["detalle_remate", Vector3(-13.0, 19.0, 13.0), Vector3(0.0, 21.0, 0.0), 45.0, "eldrun", ""],
	["detalle_base_esquina", Vector3(-11.5, 2.6, 11.5), Vector3(-4.0, 3.2, 4.0), 45.0, "eldrun", ""],
	["detalle_base_esquina_rasante", Vector3(-9.0, 1.2, 0.6), Vector3(-4.2, 2.0, 4.2), 50.0, "eldrun", ""],
	["detalle_ventanas", Vector3(-6.0, 10.0, 15.0), Vector3(0.0, 11.0, 4.0), 40.0, "eldrun", ""],
	["detalle_estandarte", Vector3(-9.0, 25.5, 9.5), Vector3(-1.2, 25.6, 0.0), 40.0, "vardheim", "", {"owner": "vardheim", "contest": "solmarch", "progress": 0.35}],
	["detalle_pendon", Vector3(-12.0, 14.0, 0.0), Vector3(-4.3, 13.8, 0.0), 40.0, "solmarch", "", {"owner": "solmarch", "contest": "askarra", "progress": 0.5}],
	["aerea", Vector3(-24.0, 40.0, 24.0), Vector3(0, 13.0, 0), 38.0, "eldrun", ""],
	["lod1_suroeste", Vector3(-33, 8, 33), Vector3(0, 13, 0), 40.0, "eldrun", "lod1"],
	["lod1_oeste", Vector3(-46, 8, 0), Vector3(0, 13, 0), 40.0, "eldrun", "lod1"],
	["lod1_puerta", Vector3(-14.0, 3.0, 8.0), Vector3(-5.0, 3.4, 0.5), 45.0, "eldrun", "lod1"],
	["lod1_cadalso", Vector3(-13.0, 13.0, 13.0), Vector3(-1.0, 17.5, 0.0), 45.0, "eldrun", "lod1"],
	["lod2_suroeste", Vector3(-33, 8, 33), Vector3(0, 13, 0), 40.0, "eldrun", "lod2"],
	["lod2_oeste", Vector3(-46, 8, 0), Vector3(0, 13, 0), 40.0, "eldrun", "lod2"],
	["colision_suroeste", Vector3(-33, 8, 33), Vector3(0, 13, 0), 40.0, "eldrun", "colision"],
	["colision_oeste", Vector3(-46, 8, 0), Vector3(0, 13, 0), 40.0, "eldrun", "colision"],
	["reino_eldrun", Vector3(-33, 8, 33), Vector3(0, 13, 0), 40.0, "eldrun", "", {"owner": "neutral"}],
	["reino_vardheim", Vector3(-33, 8, 33), Vector3(0, 13, 0), 40.0, "vardheim", "", {"owner": "vardheim"}],
	["reino_solmarch", Vector3(-33, 8, 33), Vector3(0, 13, 0), 40.0, "solmarch", "", {"owner": "solmarch"}],
	["reino_askarra", Vector3(-33, 8, 33), Vector3(0, 13, 0), 40.0, "askarra", "", {"owner": "askarra"}],
	["reino_eldrun_brasas", Vector3(-9.0, 2.0, 7.0), Vector3(-2.0, 1.4, 4.0), 55.0, "eldrun", ""],
	["reino_vardheim_base", Vector3(-9.0, 2.0, 7.0), Vector3(-2.0, 1.6, 4.0), 55.0, "vardheim", ""],
	["reino_solmarch_base", Vector3(-9.0, 2.0, 7.0), Vector3(-2.0, 1.6, 4.0), 55.0, "solmarch", ""],
	["reino_askarra_base", Vector3(-9.0, 2.0, 7.0), Vector3(-2.0, 1.6, 4.0), 55.0, "askarra", ""],
	["lodfade_40m", Vector3(-44.4, 1.7, 0.0), Vector3(-4.0, 6.0, 0.0), 70.0, "eldrun", "ranges"],
	["lodfade_50m", Vector3(-54.4, 1.7, 0.0), Vector3(-4.0, 6.0, 0.0), 70.0, "eldrun", "ranges"],
	["lodfade_58m", Vector3(-62.4, 1.7, 0.0), Vector3(-4.0, 6.0, 0.0), 70.0, "eldrun", "ranges"],
	["dist_10m", Vector3(-14.5, 1.7, 0.0), Vector3(-4.0, 3.0, 0.0), 70.0, "eldrun", ""],
	["dist_30m", Vector3(-34.5, 1.7, 0.0), Vector3(-4.0, 7.0, 0.0), 70.0, "eldrun", ""],
	["dist_60m", Vector3(-64.5, 1.7, 0.0), Vector3(-4.0, 11.0, 0.0), 70.0, "eldrun", ""],
]

var _out_dir: String = ""
var _only: String = ""
var _ssao: bool = true
var _debug_background: bool = false
var _shadow_quality: int = -1
var _shimmer: bool = false
var _keep: Node3D = null


func _initialize() -> void:
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--out="):
			_out_dir = arg.trim_prefix("--out=").replace("\\", "/")
		elif arg.begins_with("--only="):
			_only = arg.trim_prefix("--only=")
		elif arg == "--no-ssao":
			_ssao = false
		elif arg == "--debug-bg":
			_debug_background = true
		elif arg == "--shimmer":
			_shimmer = true
		elif arg.begins_with("--shadow-quality="):
			_shadow_quality = int(arg.trim_prefix("--shadow-quality="))
	if _out_dir.is_empty():
		_out_dir = ProjectSettings.globalize_path("res://build/torreon/modelo")
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
	if _shadow_quality >= 0:
		RenderingServer.directional_soft_shadow_filter_set_quality(_shadow_quality as RenderingServer.ShadowQuality)
	_build_stage()

	var camera := Camera3D.new()
	camera.name = "Camara"
	camera.far = 600.0
	root.add_child(camera)
	camera.current = true
	if _shimmer:
		await _measure_shimmer(camera)
		quit(0)
		return
	for view: Array in VIEWS:
		var view_name: String = view[0]
		if not _only.is_empty() and not view_name.begins_with(_only):
			continue
		_show_mode(String(view[5]))
		FortKeepPreview.apply_materials(_keep, StringName(view[4]))
		if String(view[5]) == "ranges":
			FortKeepPreview.apply_lods(_keep)
		var extras: Dictionary = view[6] if view.size() > 6 else {}
		FortKeepPreview.apply_banner(_keep, StringName(extras.get("owner", "neutral")), StringName(extras.get("contest", "")),
				float(extras.get("progress", 0.0)))
		camera.global_position = view[1]
		camera.look_at(view[2], Vector3.UP)
		camera.fov = float(view[3])
		for _i: int in SETTLE_FRAMES:
			await process_frame
		await RenderingServer.frame_post_draw
		var path: String = _out_dir.path_join("%s.png" % view_name)
		var error: Error = root.get_texture().get_image().save_png(path)
		print("%s -> %s (%s)" % [view_name, path, error_string(error)])
	quit(0)


func _build_stage() -> void:
	var environment: Environment = (load(ENVIRONMENT_PATH) as Environment).duplicate() as Environment
	environment.fog_enabled = false
	environment.ssao_enabled = environment.ssao_enabled and _ssao
	if _debug_background:
		# Fondo magenta y suelo fuera: cualquier rendija por la que se vea el otro lado sale magenta.
		environment.background_mode = Environment.BG_COLOR
		environment.background_color = Color(1.0, 0.0, 1.0)
		environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
		environment.ambient_light_color = Color(0.5, 0.5, 0.55)
		environment.ssao_enabled = false
	var world := WorldEnvironment.new()
	world.environment = environment
	root.add_child(world)
	# Sol del Vado Gris: misma orientación, energía y sombras que en la zona.
	var sun := DirectionalLight3D.new()
	sun.transform = Transform3D(Basis(Vector3(-4.371139e-08, 0, 1), Vector3(0.52991927, 0.8480481, 2.3163507e-08),
			Vector3(-0.8480481, 0.52991927, -3.706936e-08)), Vector3.ZERO)
	sun.light_color = Color(0.93333334, 0.9411765, 0.9411765)
	sun.light_energy = 1.2
	sun.light_angular_distance = 3.0
	sun.shadow_enabled = true
	sun.shadow_blur = 2.5
	sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_2_SPLITS
	sun.directional_shadow_max_distance = 120.0
	root.add_child(sun)
	var fill := DirectionalLight3D.new()
	fill.transform = Transform3D(Basis(Vector3.RIGHT, Vector3(0, 0.88294756, -0.46947157), Vector3(0, 0.46947157, 0.88294756)),
			Vector3.ZERO)
	fill.light_color = Color(0.83137256, 0.85490197, 0.8784314)
	fill.light_energy = 0.42
	fill.sky_mode = DirectionalLight3D.SKY_MODE_SKY_ONLY
	root.add_child(fill)
	# Suelo liso verde grisáceo, como la hierba de la colina.
	var ground := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(400, 400)
	ground.mesh = plane
	var ground_material := StandardMaterial3D.new()
	ground_material.albedo_color = Color(0.36, 0.40, 0.29)
	ground_material.roughness = 1.0
	ground.material_override = ground_material
	root.add_child(ground)

	var scene: PackedScene = load(KEEP_PATH) as PackedScene
	_keep = scene.instantiate() as Node3D
	root.add_child(_keep)


## "" muestra el LOD0; "lod1" el nivel medio; "lod2" la silueta lejana; "colision" el LOD0 con la
## malla de colisión encima, en celeste translúcido y con sus aristas.
func _show_mode(mode: String) -> void:
	for node: Node in _keep.find_children("FortKeep_LOD*", "MeshInstance3D", true, false):
		var instance: MeshInstance3D = node as MeshInstance3D
		if mode != "ranges":
			# fuera del modo "ranges" no quedan rangos de visibilidad de una vista anterior
			instance.visibility_range_begin = 0.0
			instance.visibility_range_end = 0.0
			instance.visibility_range_begin_margin = 0.0
			instance.visibility_range_end_margin = 0.0
			instance.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_DISABLED
		match mode:
			"lod1":
				instance.visible = instance.name.begins_with("FortKeep_LOD1")
			"lod2":
				instance.visible = instance.name.begins_with("FortKeep_LOD2")
			"ranges":
				instance.visible = true
			_:
				instance.visible = instance.name.begins_with("FortKeep_LOD0")
	var old: Node = _keep.get_node_or_null("ColisionDibujada")
	if old != null:
		_keep.remove_child(old)
		old.queue_free()
	if mode != "colision":
		return
	var drawn := Node3D.new()
	drawn.name = "ColisionDibujada"
	for shape_node: Node in _keep.find_children("*", "CollisionShape3D", true, false):
		var shape: Shape3D = (shape_node as CollisionShape3D).shape
		var faces: PackedVector3Array = (shape as ConcavePolygonShape3D).get_faces()
		var arrays: Array = []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = faces
		var mesh := ArrayMesh.new()
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		var fill := MeshInstance3D.new()
		fill.mesh = mesh
		var fill_material := StandardMaterial3D.new()
		fill_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		fill_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		fill_material.cull_mode = BaseMaterial3D.CULL_DISABLED
		fill_material.albedo_color = Color(0.1, 0.8, 1.0, 0.38)
		fill.material_override = fill_material
		drawn.add_child(fill)
		var lines := MeshInstance3D.new()
		lines.mesh = shape.get_debug_mesh()
		var line_material := StandardMaterial3D.new()
		line_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		line_material.albedo_color = Color(0.0, 1.0, 1.0)
		lines.material_override = line_material
		drawn.add_child(lines)
	_keep.add_child(drawn)


## Fotogramas por medición, paso lateral de la cámara (en píxeles de pantalla por fotograma) y
## distancias (m) del centelleo en movimiento.
const SHIMMER_FRAMES: int = 14
const SHIMMER_STEP_PX: float = 0.4
const SHIMMER_DISTANCES: Array = [10.0, 30.0, 60.0]
const SHIMMER_FOV: float = 70.0


## Mide el centelleo de la piedra al mover la cámara: a 10, 30 y 60 m de la fachada, con la cámara
## a altura de jugador desplazándose de lado fracciones de píxel por fotograma, calcula el error
## medio de la segunda derivada temporal de la luminancia (|I(t) - (I(t-1) + I(t+1)) / 2|, en una
## zona de 1,6 m de pared; mediana de tres pasadas) con los mipmaps de la importación actual y con las texturas sin
## mipmaps (cómo se importaron antes de fijar el preset del repo). Un movimiento lineal sin
## aliasing da casi cero; el aliasing de la textura da valores altos. Escribe
## [code]metricas_movimiento.txt[/code] en la carpeta de salida.
func _measure_shimmer(camera: Camera3D) -> void:
	camera.fov = SHIMMER_FOV
	var lines: PackedStringArray = PackedStringArray([
		"Centelleo de la piedra en movimiento (error medio de la segunda derivada temporal, niveles de gris 0 a 255; menos es mejor)",
		"Ventana %s | pared a la izquierda del porche | %d fotogramas, %.1f px por fotograma" % [root.size, SHIMMER_FRAMES, SHIMMER_STEP_PX],
		"distancia | LOD0 con mipmaps (actual) | LOD0 sin mipmaps (importación antigua) | LOD1 con mipmaps | LOD2 con mipmaps"])
	for distance: float in SHIMMER_DISTANCES:
		var values: Array[float] = []
		for case: Array in [["", true], ["", false], ["lod1", true], ["lod2", true]]:
			_show_mode(String(case[0]))
			FortKeepPreview.apply_materials(_keep, &"eldrun")
			if not bool(case[1]):
				_strip_mipmaps(_keep)
			# mediana de tres pasadas: una sola oscila por el ruido de las sombras suaves
			var runs: Array[float] = []
			for _run_index: int in 3:
				runs.append(await _shimmer_at(camera, distance))
			runs.sort()
			values.append(runs[1])
		lines.append("%5.0f m | %.3f | %.3f | %.3f | %.3f" % [distance, values[0], values[1], values[2], values[3]])
	var path: String = _out_dir.path_join("metricas_movimiento.txt")
	var file: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	file.store_string("
".join(lines) + "
")
	file.close()
	print("
".join(lines))


func _shimmer_at(camera: Camera3D, distance: float) -> float:
	var target := Vector3(-3.4, 6.0, 2.4)
	var size: Vector2 = Vector2(root.size)
	var meters_per_px: float = 2.0 * distance * tan(deg_to_rad(SHIMMER_FOV) * 0.5) / size.y
	var side: int = clampi(int(1.6 / meters_per_px), 16, 240)
	var frames: Array[PackedFloat32Array] = []
	for i: int in SHIMMER_FRAMES:
		var lateral: float = SHIMMER_STEP_PX * meters_per_px * float(i)
		camera.global_position = Vector3(target.x - distance, 1.7, target.z + lateral)
		camera.look_at(Vector3(target.x, target.y, target.z + lateral), Vector3.UP)
		for _j: int in 3:
			await process_frame
		await RenderingServer.frame_post_draw
		var image: Image = root.get_texture().get_image()
		var x0: int = int(size.x * 0.5) - side / 2
		var y0: int = int(size.y * 0.5) - side / 2
		var luma := PackedFloat32Array()
		luma.resize(side * side)
		for y: int in side:
			for x: int in side:
				var c: Color = image.get_pixel(x0 + x, y0 + y)
				luma[y * side + x] = (c.r * 0.299 + c.g * 0.587 + c.b * 0.114) * 255.0
		frames.append(luma)
	var total: float = 0.0
	var count: int = 0
	for t: int in range(1, SHIMMER_FRAMES - 1):
		for k: int in side * side:
			total += absf(frames[t][k] - 0.5 * (frames[t - 1][k] + frames[t + 1][k]))
			count += 1
	return total / float(count)


## Sustituye las texturas de los materiales de reino por copias sin mipmaps (y sin compresión).
func _strip_mipmaps(keep: Node) -> void:
	for node: Node in keep.find_children("*", "MeshInstance3D", true, false):
		var instance: MeshInstance3D = node as MeshInstance3D
		for i: int in instance.mesh.get_surface_count():
			var material: ShaderMaterial = instance.get_surface_override_material(i) as ShaderMaterial
			if material == null:
				continue
			var copy: ShaderMaterial = material.duplicate() as ShaderMaterial
			for param: StringName in [&"albedo_texture", &"normal_texture", &"atlas"]:
				var texture: Texture2D = copy.get_shader_parameter(param) as Texture2D
				if texture == null:
					continue
				var image: Image = texture.get_image()
				if image.is_compressed():
					image.decompress()
				copy.set_shader_parameter(param, ImageTexture.create_from_image(image))
			instance.set_surface_override_material(i, copy)
