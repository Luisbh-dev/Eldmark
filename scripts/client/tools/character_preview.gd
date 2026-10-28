extends Node3D
## Escena de prueba del personaje animado (herramienta de desarrollo, solo cliente).
##
## Aparece un [PlayerCharacter] sobre un suelo a cuadros de 1 m, se le cuelga
## [code]humanoid_visual.tscn[/code] bajo su nodo Visual (ocultando la cápsula) y se le conduce con
## un guion fijo de [PlayerInput]: reposo, caminar, trotar, esprintar, frenar, desplazamiento
## lateral, hacia atrás, salto parado y salto corriendo. La cámara sigue al personaje con un
## desplazamiento fijo, sin girar, para que los cuadros del suelo delaten si los pies patinan.
## [br][br]
## Uso (ventana; [code]--fixed-fps[/code] hace la ejecución determinista):
## [codeblock]
## godot --path . res://scenes/tests/character_preview.tscn --fixed-fps 30 -- \
##     [--shots=build/char] [--every=6] [--range=0-200] \
##     [--view=three_quarter|side|front|back|close|close_back|feet] \
##     [--capsule] [--hood] [--no-quit]
## [/codeblock]
## [br]- [code]--shots=<carpeta>[/code]: guarda un PNG cada [code]--every[/code] fotogramas y hojas
## de contactos de 4x4 ([code]sheet_XX.png[/code]). Relativa a la raíz del proyecto o absoluta.
## [br]- [code]--range=<desde>-<hasta>[/code]: solo captura esos fotogramas.
## [br]Al terminar imprime, por tramo del guion, cuánto se mueve el tobillo del pie apoyado
## (patinaje): con la zancada bien ajustada debe quedarse cerca de 0 aunque se corra.
## [br]- [code]--capsule[/code]: deja la cápsula de colisión visible y translúcida para comparar la
## escala.
## [br]- [code]--hood[/code]: muestra la capucha del traje.
## [br]- [code]--no-quit[/code]: no cierra al terminar el guion.

const PLAYER_SCENE: PackedScene = preload("res://scenes/characters/player_character.tscn")

## Por vista: desplazamiento de la cámara respecto a los pies (xyz) y altura del punto al que
## mira (w).
const VIEWS: Dictionary[String, Vector4] = {
	"three_quarter": Vector4(3.2, 1.8, -3.6, 0.95),
	"side": Vector4(5.0, 1.3, 0.0, 0.95),
	"front": Vector4(0.0, 1.5, -4.6, 0.95),
	"back": Vector4(0.0, 1.9, 4.6, 0.95),
	"close": Vector4(0.9, 1.65, -1.5, 1.45),
	"close_back": Vector4(-0.9, 1.75, 1.5, 1.45),
	"feet": Vector4(3.2, 0.8, 0.0, 0.45),
}
## Hojas de contactos: columnas, filas y tamaño de cada miniatura.
const SHEET_COLUMNS: int = 4
const SHEET_ROWS: int = 4
const THUMB_SIZE: Vector2i = Vector2i(480, 270)

## Guion: [nombre, ticks, movimiento, botones, tick (relativo) en que empieza a pulsarse el salto].
var _script_steps: Array[Dictionary] = [
	{"name": "Reposo", "ticks": 60, "move": Vector2.ZERO},
	{"name": "Caminar (1 m/s)", "ticks": 120, "move": Vector2(0.0, 0.2)},
	{"name": "Trotar (5 m/s)", "ticks": 120, "move": Vector2(0.0, 1.0)},
	{"name": "Esprintar (7,5 m/s)", "ticks": 120, "move": Vector2(0.0, 1.0),
			"buttons": PlayerInput.SPRINT},
	{"name": "Frenar", "ticks": 45, "move": Vector2.ZERO},
	{"name": "Lateral derecha", "ticks": 90, "move": Vector2(1.0, 0.0)},
	{"name": "Lateral izquierda", "ticks": 90, "move": Vector2(-1.0, 0.0)},
	{"name": "Hacia atrás", "ticks": 90, "move": Vector2(0.0, -1.0)},
	{"name": "Reposo", "ticks": 45, "move": Vector2.ZERO},
	{"name": "Salto parado", "ticks": 75, "move": Vector2.ZERO, "jump_at": 5},
	{"name": "Reposo", "ticks": 30, "move": Vector2.ZERO},
	{"name": "Salto corriendo", "ticks": 100, "move": Vector2(0.0, 1.0), "jump_at": 25},
	{"name": "Reposo final", "ticks": 75, "move": Vector2.ZERO},
]

var _character: PlayerCharacter
var _visual: HumanoidVisual
var _camera: Camera3D
var _label: Label
var _view: Vector4 = VIEWS["three_quarter"]
var _range_start: int = 0
var _range_end: int = 1 << 30
var _tick: int = 0
var _step_index: int = 0
var _step_tick: int = 0
var _finished: bool = false
var _quit_when_done: bool = true
var _shots_dir: String = ""
var _shot_every: int = 6
var _frame: int = 0
var _shot_index: int = 0
var _sheet: Image = null
var _sheet_slot: int = 0
var _sheet_index: int = 0
var _pending_shots: int = 0
var _foot_bones: PackedInt32Array = PackedInt32Array()
var _prev_feet: Array[Vector3] = []
var _slide_samples: Dictionary[String, PackedFloat32Array] = {}
var _speed_samples: Dictionary[String, PackedFloat32Array] = {}


func _ready() -> void:
	var show_capsule: bool = false
	var hood: bool = false
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--shots="):
			_shots_dir = _resolve_dir(arg.trim_prefix("--shots="))
		elif arg.begins_with("--every="):
			_shot_every = maxi(arg.trim_prefix("--every=").to_int(), 1)
		elif arg.begins_with("--view="):
			var view: String = arg.trim_prefix("--view=")
			if VIEWS.has(view):
				_view = VIEWS[view]
			else:
				push_warning("[Preview] Vista desconocida: %s" % view)
		elif arg.begins_with("--range="):
			var bounds: PackedStringArray = arg.trim_prefix("--range=").split("-")
			if bounds.size() == 2:
				_range_start = bounds[0].to_int()
				_range_end = bounds[1].to_int()
		elif arg == "--capsule":
			show_capsule = true
		elif arg == "--hood":
			hood = true
		elif arg == "--no-quit":
			_quit_when_done = false
	if not _shots_dir.is_empty():
		DirAccess.make_dir_recursive_absolute(_shots_dir)
	# Después de todos los nodos (también del AnimationTree), para que la cámara, el texto y la
	# medida de los pies usen la pose ya animada de este fotograma.
	process_priority = 100

	_camera = $Camera3D
	_label = $Overlay/Label

	_character = PLAYER_SCENE.instantiate() as PlayerCharacter
	add_child(_character)
	var state := PlayerState.new()
	state.position = Vector3.ZERO
	state.yaw = 0.0
	_character.set_state(state)
	_character.reset_physics_interpolation()

	# Igual que lo haría el cliente: instala el visual y oculta la cápsula provisional.
	_visual = HumanoidVisual.install(_character)
	_visual.hood_visible = hood
	if show_capsule:
		var body: MeshInstance3D = _character.get_node_or_null(^"Visual/Body") as MeshInstance3D
		if body != null:
			var ghost := StandardMaterial3D.new()
			ghost.albedo_color = Color(0.3, 0.55, 1.0, 0.22)
			ghost.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
			ghost.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
			body.material_override = ghost
			body.visible = true
	_update_camera()


func _physics_process(delta: float) -> void:
	if _finished:
		return
	var step: Dictionary = _script_steps[_step_index]
	_tick += 1
	var input := PlayerInput.new()
	input.tick = _tick
	input.move = step.get("move", Vector2.ZERO)
	input.look_yaw = 0.0
	input.buttons = step.get("buttons", 0)
	if step.has("jump_at"):
		var jump_at: int = step["jump_at"]
		if _step_tick >= jump_at and _step_tick < jump_at + 6:
			input.buttons |= PlayerInput.JUMP
	_character.simulate(input.quantized(), delta)

	_step_tick += 1
	if _step_tick >= int(step["ticks"]):
		_step_tick = 0
		_step_index += 1
		if _step_index >= _script_steps.size():
			_finished = true
			_on_script_finished()


func _process(delta: float) -> void:
	_update_camera()
	_update_label()
	_measure_feet(delta)
	_frame += 1
	var in_range: bool = _frame >= _range_start and _frame <= _range_end
	if not _shots_dir.is_empty() and not _finished and in_range and _frame % _shot_every == 0:
		_capture()


func _update_camera() -> void:
	if not is_instance_valid(_character):
		return
	var feet: Vector3 = _character.get_global_transform_interpolated().origin
	var target: Vector3 = feet + Vector3(0.0, _view.w, 0.0)
	_camera.global_position = feet + Vector3(_view.x, _view.y, _view.z)
	_camera.look_at(target, Vector3.UP)


func _update_label() -> void:
	if not is_instance_valid(_visual):
		return
	var state: Dictionary = _visual.get_animator().get_debug_state()
	var step_name: String = _script_steps[mini(_step_index, _script_steps.size() - 1)]["name"]
	_label.text = "%s\nvel %.2f m/s  ciclo x%.2f  mov %.2f\naire %s %.2f  caída %.2f  aterrizaje %.2f  giro %.0f°" % [
		step_name, state["speed"], state["locomotion_scale"], state["move"], state["air_state"],
		state["air"], state["fall"], state["land"], state["facing_offset_deg"],
	]


## Mide cuánto patinan los pies: velocidad horizontal en el mundo del tobillo más lento (el
## apoyado) en cada fotograma, con la pose y la transformación que se dibujan. Con la zancada
## bien ajustada, el pie apoyado casi no se mueve aunque el personaje corra.
func _measure_feet(delta: float) -> void:
	if not is_instance_valid(_visual) or _finished or delta <= 0.0:
		return
	var skeleton: Skeleton3D = _visual.get_skeleton()
	if skeleton == null:
		return
	if _foot_bones.is_empty():
		_foot_bones = PackedInt32Array([skeleton.find_bone("LeftFoot"), skeleton.find_bone("RightFoot")])
	var displayed: Transform3D = _character.get_global_transform_interpolated() * (
			_character.global_transform.affine_inverse() * skeleton.global_transform)
	var slowest: float = INF
	for i: int in _foot_bones.size():
		var position: Vector3 = displayed * skeleton.get_bone_global_pose(_foot_bones[i]).origin
		if _prev_feet.size() == _foot_bones.size():
			var step := Vector2(position.x - _prev_feet[i].x, position.z - _prev_feet[i].z)
			slowest = minf(slowest, step.length() / delta)
		if _prev_feet.size() < _foot_bones.size():
			_prev_feet.append(position)
		else:
			_prev_feet[i] = position
	if is_inf(slowest):
		return
	var step_name: String = _script_steps[_step_index]["name"]
	if not _slide_samples.has(step_name):
		_slide_samples[step_name] = PackedFloat32Array()
		_speed_samples[step_name] = PackedFloat32Array()
	# Se ignora el primer tercio de cada tramo (aceleración y transición).
	if _step_tick > int(_script_steps[_step_index]["ticks"]) / 3:
		_slide_samples[step_name].append(slowest)
		_speed_samples[step_name].append(_character.get_horizontal_speed())


func _print_slide_report() -> void:
	print("[Preview] Patinaje del pie apoyado (m/s; mediana y percentil 20 del tobillo más lento):")
	for step_name: String in _slide_samples:
		var slides: PackedFloat32Array = _slide_samples[step_name]
		var speeds: PackedFloat32Array = _speed_samples[step_name]
		if slides.is_empty():
			continue
		var sorted: PackedFloat32Array = slides.duplicate()
		sorted.sort()
		var mean_speed: float = 0.0
		for s: float in speeds:
			mean_speed += s
		mean_speed /= speeds.size()
		print("  %-22s vel %.2f  mediana %.2f  p20 %.2f  (%d muestras)" % [step_name, mean_speed,
				sorted[sorted.size() / 2], sorted[sorted.size() / 5], sorted.size()])


func _capture() -> void:
	_pending_shots += 1
	var index: int = _shot_index
	_shot_index += 1
	await RenderingServer.frame_post_draw
	var image: Image = get_viewport().get_texture().get_image()
	if image != null and not image.is_empty():
		image.save_png(_shots_dir.path_join("frame_%04d.png" % index))
		_add_to_sheet(image)
	_pending_shots -= 1


func _add_to_sheet(image: Image) -> void:
	if _sheet == null:
		_sheet = Image.create(THUMB_SIZE.x * SHEET_COLUMNS, THUMB_SIZE.y * SHEET_ROWS, false,
				Image.FORMAT_RGB8)
		_sheet.fill(Color.BLACK)
	var thumb: Image = image.duplicate() as Image
	thumb.convert(Image.FORMAT_RGB8)
	thumb.resize(THUMB_SIZE.x, THUMB_SIZE.y, Image.INTERPOLATE_BILINEAR)
	var slot := Vector2i(_sheet_slot % SHEET_COLUMNS, _sheet_slot / SHEET_COLUMNS)
	_sheet.blit_rect(thumb, Rect2i(Vector2i.ZERO, THUMB_SIZE), slot * THUMB_SIZE)
	_sheet_slot += 1
	if _sheet_slot >= SHEET_COLUMNS * SHEET_ROWS:
		_flush_sheet()


func _flush_sheet() -> void:
	if _sheet == null or _sheet_slot == 0:
		return
	_sheet.save_png(_shots_dir.path_join("sheet_%02d.png" % _sheet_index))
	_sheet_index += 1
	_sheet = null
	_sheet_slot = 0


func _on_script_finished() -> void:
	print("[Preview] Guion terminado (%d ticks)" % _tick)
	_print_slide_report()
	if not _quit_when_done:
		return
	var waited: int = 0
	while _pending_shots > 0 and waited < 120:
		await get_tree().process_frame
		waited += 1
	if not _shots_dir.is_empty():
		_flush_sheet()
		print("[Preview] Capturas en %s" % _shots_dir)
	get_tree().quit()


static func _resolve_dir(path: String) -> String:
	path = path.strip_edges().trim_prefix("\"").trim_suffix("\"").replace("\\", "/")
	if path.begins_with("res://") or path.begins_with("user://"):
		return ProjectSettings.globalize_path(path)
	if path.is_relative_path():
		return ProjectSettings.globalize_path("res://").path_join(path)
	return path
