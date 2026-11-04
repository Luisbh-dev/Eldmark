extends Node3D
## Vista previa de la espada (herramienta de desarrollo, solo cliente).
##
## Pone el modelo (o los cuatro) bajo la luz del Vado Gris (el sol y los dos rellenos de
## vado_gris.tscn y su ambiente) sobre un fondo liso, y hace las fotos en un SubViewport de tamaño
## propio, así que el tamaño de la ventana da igual.
## [br][br]
## Uso (con ventana; en esta máquina las ventanas van a la segunda pantalla por override.cfg):
## [codeblock]
## godot --path . res://scenes/tests/sword_preview.tscn -- --sin-raton \
##     --shots=build/sword/render [--views=perfil,frente,empunadura,juntas] [--variant=base] \
##     [--lod=0|1] [--no-quit]
## [/codeblock]
## [br]- [code]--shots=<carpeta>[/code]: guarda un PNG por vista ([code]sword_<variante>_<vista>.png[/code],
## o [code]sword_juntas.png[/code]). Sin ella, enseña la primera vista en la ventana.
## [br]- [code]--views=[/code]: lista separada por comas (por defecto, todas).
## [br]- [code]--variant=[/code]: [code]base[/code], [code]vardheim[/code], [code]solmarch[/code] o
## [code]askarra[/code] (por defecto, el base; con [code]all[/code] se hacen las cuatro).
## [br]- [code]--lod=0|1[/code]: fuerza el detalle completo (0, por defecto) o el sencillo (1).
## [br][br]
## Vistas: [code]perfil[/code] (de canto, 90°), [code]frente[/code] (la cara ancha de la hoja),
## [code]tres_cuartos[/code], [code]empunadura[/code] (guarda, cuero y pomo de cerca) y
## [code]pomo[/code] (el pomo de cerca), [code]pomo_frente[/code] y [code]guarda_frente[/code] (el pomo y la guarda de
## cara, sin giro: la silueta tal como está modelada); [code]juntas[/code] pone las cuatro espadas en fila.

## Fondo de las fotos: gris pizarra, para que el acero se despegue.
const BACKGROUND: Color = Color(0.19, 0.205, 0.23, 1.0)
const ENVIRONMENT_PATH: String = "res://assets/environments/vado_gris_frontier.tres"
## Por vista: giro de la espada sobre Y (grados), elevación de la cámara (grados), distancia (m),
## campo de visión vertical (grados), punto al que mira (altura sobre el centro de la empuñadura, m)
## y tamaño de la imagen.
const VIEWS: Dictionary[String, Dictionary] = {
	"perfil": {"yaw": -90.0, "pitch": 4.0, "distance": 3.4, "fov": 22.0, "target": 0.40,
			"size": Vector2i(800, 1400)},
	"frente": {"yaw": -22.0, "pitch": 4.0, "distance": 3.4, "fov": 22.0, "target": 0.40,
			"size": Vector2i(800, 1400)},
	"tres_cuartos": {"yaw": -52.0, "pitch": 8.0, "distance": 3.4, "fov": 22.0, "target": 0.40,
			"size": Vector2i(800, 1400)},
	"empunadura": {"yaw": -36.0, "pitch": 10.0, "distance": 1.15, "fov": 20.0, "target": -0.005,
			"size": Vector2i(1000, 1000)},
	"pomo": {"yaw": -36.0, "pitch": 8.0, "distance": 0.8, "fov": 20.0, "target": -0.115,
			"size": Vector2i(900, 900)},
	"pomo_frente": {"yaw": 0.0, "pitch": 0.0, "distance": 0.8, "fov": 20.0, "target": -0.115,
			"size": Vector2i(900, 900)},
	"guarda_frente": {"yaw": 0.0, "pitch": 0.0, "distance": 1.1, "fov": 20.0, "target": 0.10,
			"size": Vector2i(1200, 800)},
}
const ALL_VARIANTS: Array[StringName] = [&"base", &"vardheim", &"solmarch", &"askarra"]
## Separación entre espadas en la vista de conjunto (m) y tamaño de esa imagen.
const LINEUP_SPACING: float = 0.46
const LINEUP_SIZE: Vector2i = Vector2i(1800, 1150)
const LINEUP_YAW: float = -28.0

var _viewport: SubViewport
var _camera: Camera3D
var _stage: Node3D
var _shots_dir: String = ""
var _views: PackedStringArray = PackedStringArray()
var _variants: Array[StringName] = [&"base"]
var _lod: int = 0
var _quit_when_done: bool = true


func _ready() -> void:
	var names: PackedStringArray = PackedStringArray()
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--shots="):
			_shots_dir = _resolve_dir(arg.trim_prefix("--shots="))
		elif arg.begins_with("--views="):
			names = arg.trim_prefix("--views=").split(",", false)
		elif arg.begins_with("--variant="):
			var value: String = arg.trim_prefix("--variant=")
			var chosen: Array[StringName] = [StringName(value)]
			_variants = ALL_VARIANTS.duplicate() if value == "all" else chosen
		elif arg.begins_with("--lod="):
			_lod = clampi(arg.trim_prefix("--lod=").to_int(), 0, 1)
		elif arg == "--no-quit":
			_quit_when_done = false
	if names.is_empty():
		names = PackedStringArray(["perfil", "frente", "tres_cuartos", "empunadura", "pomo", "juntas"])
	_views = names
	_setup_environment()
	_stage = Node3D.new()
	_stage.name = "Stage"
	add_child(_stage)
	_viewport = SubViewport.new()
	_viewport.msaa_3d = Viewport.MSAA_4X
	_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_viewport.size = Vector2i(800, 1400)
	add_child(_viewport)
	_camera = Camera3D.new()
	_viewport.add_child(_camera)
	_camera.current = true
	_run.call_deferred()


func _setup_environment() -> void:
	var environment: Environment = (load(ENVIRONMENT_PATH) as Environment).duplicate() as Environment
	# Fondo liso; el ambiente y los reflejos siguen saliendo del cielo del juego.
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = BACKGROUND
	environment.fog_enabled = false
	var world_environment := WorldEnvironment.new()
	world_environment.environment = environment
	add_child(world_environment)


func _run() -> void:
	var first: bool = true
	for view_name: String in _views:
		if view_name == "juntas":
			await _shoot_lineup()
		elif VIEWS.has(view_name):
			for variant: StringName in _variants:
				await _shoot_view(view_name, variant)
		else:
			push_warning("[SwordPreview] Vista desconocida: %s" % view_name)
		if _shots_dir.is_empty() and first:
			# Sin carpeta: se queda enseñando la primera vista.
			return
		first = false
	if _quit_when_done and not _shots_dir.is_empty():
		get_tree().quit()


func _shoot_view(view_name: String, variant: StringName) -> void:
	var view: Dictionary = VIEWS[view_name]
	_clear_stage()
	var sword: Node3D = _spawn(variant, Vector3.ZERO, float(view["yaw"]))
	if sword == null:
		return
	_frame_camera(float(view["pitch"]), float(view["distance"]), float(view["fov"]),
			Vector3(0.0, float(view["target"]), 0.0))
	await _capture(view["size"], "sword_%s_%s.png" % [variant, view_name])


func _shoot_lineup() -> void:
	_clear_stage()
	for index: int in range(ALL_VARIANTS.size()):
		var x: float = (index - (ALL_VARIANTS.size() - 1) * 0.5) * LINEUP_SPACING
		_spawn(ALL_VARIANTS[index], Vector3(x, 0.0, 0.0), LINEUP_YAW)
	_frame_camera(5.0, 3.5, 24.0, Vector3(0.0, 0.40, 0.0))
	await _capture(LINEUP_SIZE, "sword_juntas.png")


func _spawn(variant: StringName, position_offset: Vector3, yaw_deg: float) -> Node3D:
	var sword: Node3D = SwordModel.instantiate(variant, false)
	if sword == null:
		push_error("[SwordPreview] No carga el modelo %s" % variant)
		return null
	SwordModel.show_only_lod(sword, _lod)
	var pivot := Node3D.new()
	pivot.position = position_offset
	pivot.rotation_degrees = Vector3(0.0, yaw_deg, 0.0)
	pivot.add_child(sword)
	_stage.add_child(pivot)
	return sword


func _clear_stage() -> void:
	for child: Node in _stage.get_children():
		_stage.remove_child(child)
		child.queue_free()


func _frame_camera(pitch_deg: float, distance: float, fov: float, target: Vector3) -> void:
	_camera.fov = fov
	var pitch: float = deg_to_rad(pitch_deg)
	_camera.position = target + Vector3(0.0, sin(pitch) * distance, cos(pitch) * distance)
	_camera.look_at(target, Vector3.UP)


func _capture(size: Vector2i, file_name: String) -> void:
	_viewport.size = size
	# Unos fotogramas para que se asienten sombras y oclusión ambiental.
	for i: int in range(6):
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	if _shots_dir.is_empty():
		return
	var image: Image = _viewport.get_texture().get_image()
	var path: String = _shots_dir.path_join(file_name)
	var error: Error = image.save_png(path)
	print("[SwordPreview] %s (%dx%d) %s" % [path, image.get_width(), image.get_height(),
			"ok" if error == OK else "ERROR %d" % error])


func _resolve_dir(path: String) -> String:
	var resolved: String = path
	if not path.is_absolute_path():
		resolved = ProjectSettings.globalize_path("res://").path_join(path)
	DirAccess.make_dir_recursive_absolute(resolved)
	return resolved
