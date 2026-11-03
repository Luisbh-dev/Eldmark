extends SceneTree
## Herramienta de revisión del torreón del fuerte (ART-57): renders del modelo solo, sin zona,
## sobre un suelo liso y con la luz del Vado Gris (sol con sombras y el cielo del ambiente de
## la frontera, sin niebla). Saca una vuelta de 8 ángulos, los detalles (puerta, cadalso, remate),
## el LOD lejano, la colisión de baja resolución y las tres paletas de reino.
##
## Necesita ventana (no headless). Uso desde la raíz del proyecto:
## [codeblock]
## godot --path . --resolution 1600x1200 -s res://tools/render/render_fort_keep_model.gd -- \
##     --out=C:/ruta/build/torreon/modelo
## [/codeblock]
## Con [code]--only=<prefijo>[/code] solo guarda las vistas cuyo nombre empiece así.

const KEEP_PATH: String = "res://assets/models/environment/custom/fort_keep.glb"
const MATERIAL_DIR: String = "res://assets/models/environment/custom/fort_keep/materials/"
const ENVIRONMENT_PATH: String = "res://assets/environments/vado_gris_frontier.tres"
const SETTLE_FRAMES: int = 8

## [nombre, posición de la cámara respecto al origen del torreón, punto al que mira, fov, reino,
## modo]. Modos: "" (normal), "lod1" (solo el LOD lejano), "colision" (solo la malla de colisión).
const VIEWS: Array = [
	["vuelta_0_oeste", Vector3(-44, 7, 0), Vector3(0, 10.5, 0), 38.0, "eldrun", ""],
	["vuelta_1_suroeste", Vector3(-31, 7, 31), Vector3(0, 10.5, 0), 38.0, "eldrun", ""],
	["vuelta_2_sur", Vector3(0, 7, 44), Vector3(0, 10.5, 0), 38.0, "eldrun", ""],
	["vuelta_3_sureste", Vector3(31, 7, 31), Vector3(0, 10.5, 0), 38.0, "eldrun", ""],
	["vuelta_4_este", Vector3(44, 7, 0), Vector3(0, 10.5, 0), 38.0, "eldrun", ""],
	["vuelta_5_noreste", Vector3(31, 7, -31), Vector3(0, 10.5, 0), 38.0, "eldrun", ""],
	["vuelta_6_norte", Vector3(0, 7, -44), Vector3(0, 10.5, 0), 38.0, "eldrun", ""],
	["vuelta_7_noroeste", Vector3(-31, 7, -31), Vector3(0, 10.5, 0), 38.0, "eldrun", ""],
	["detalle_puerta", Vector3(-14.0, 2.2, 7.5), Vector3(-5.2, 2.6, 0.2), 45.0, "eldrun", ""],
	["detalle_puerta_frente", Vector3(-12.5, 2.0, 0.0), Vector3(-5.2, 2.5, 0.0), 45.0, "eldrun", ""],
	["detalle_cadalso", Vector3(-12.0, 15.5, 12.0), Vector3(-1.0, 20.6, 0.0), 45.0, "eldrun", ""],
	["detalle_remate", Vector3(-14.0, 22.0, 14.0), Vector3(0.0, 22.0, 0.0), 45.0, "eldrun", ""],
	["detalle_base_esquina", Vector3(-14.0, 3.0, 14.0), Vector3(-4.0, 4.5, 4.0), 45.0, "eldrun", ""],
	["detalle_ventanas", Vector3(-6.0, 11.0, 17.0), Vector3(0.0, 12.0, 4.0), 40.0, "eldrun", ""],
	["aerea", Vector3(-26.0, 38.0, 26.0), Vector3(0, 12.0, 0), 38.0, "eldrun", ""],
	["lod1_suroeste", Vector3(-31, 7, 31), Vector3(0, 10.5, 0), 38.0, "eldrun", "lod1"],
	["lod1_oeste", Vector3(-44, 7, 0), Vector3(0, 10.5, 0), 38.0, "eldrun", "lod1"],
	["colision_suroeste", Vector3(-31, 7, 31), Vector3(0, 10.5, 0), 38.0, "eldrun", "colision"],
	["colision_oeste", Vector3(-44, 7, 0), Vector3(0, 10.5, 0), 38.0, "eldrun", "colision"],
	["reino_vardheim", Vector3(-31, 7, 31), Vector3(0, 10.5, 0), 38.0, "vardheim", ""],
	["reino_solmarch", Vector3(-31, 7, 31), Vector3(0, 10.5, 0), 38.0, "solmarch", ""],
]

var _out_dir: String = ""
var _only: String = ""
var _keep: Node3D = null


func _initialize() -> void:
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--out="):
			_out_dir = arg.trim_prefix("--out=").replace("\\", "/")
		elif arg.begins_with("--only="):
			_only = arg.trim_prefix("--only=")
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
	_build_stage()

	var camera := Camera3D.new()
	camera.name = "Camara"
	camera.far = 600.0
	root.add_child(camera)
	camera.current = true
	for view: Array in VIEWS:
		var view_name: String = view[0]
		if not _only.is_empty() and not view_name.begins_with(_only):
			continue
		_show_mode(String(view[5]))
		_apply_realm(String(view[4]))
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


func _apply_realm(realm: String) -> void:
	for node: Node in _keep.find_children("*", "MeshInstance3D", true, false):
		var instance: MeshInstance3D = node as MeshInstance3D
		for i: int in instance.mesh.get_surface_count():
			var source: Material = instance.mesh.surface_get_material(i)
			if source == null:
				continue
			var path: String = "%s%s/%s.tres" % [MATERIAL_DIR, realm, source.resource_name]
			if ResourceLoader.exists(path):
				instance.set_surface_override_material(i, load(path) as Material)


## "" muestra el LOD0; "lod1" solo el lejano; "colision" el LOD0 con la malla de colisión encima,
## en celeste translúcido y con sus aristas.
func _show_mode(mode: String) -> void:
	for node: Node in _keep.find_children("FortKeep_LOD*", "MeshInstance3D", true, false):
		var instance: MeshInstance3D = node as MeshInstance3D
		if mode == "lod1":
			instance.visible = instance.name.begins_with("FortKeep_LOD1")
		else:
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
