extends Node3D
## Vista previa de la animación de combate (herramienta de desarrollo, solo cliente; ART-06/ART-08).
##
## Un [PlayerCharacter] con el humanoide animado, la espada y el escudo provisionales y la capa de
## combate recorre un guion con las mismas piezas que el juego: el combo de tres ligeros, un fuerte
## cargado, un bloqueo y una esquiva ([CombatDemoScript], por la simulación de verdad), y después un
## tambaleo, un aturdimiento y la muerte (impuestos con [ActionMachine], como haría el servidor).
## Sirve para revisar los clips, los tramos de [code]data/animation/sword_shield_clips.tres[/code] y la
## orientación de las armas sin lanzar el servidor.
## [br][br]
## Uso (ventana; [code]--fixed-fps[/code] hace la ejecución determinista, 2 ticks por fotograma a 30):
## [codeblock]
## godot --path . res://scenes/tests/combat_preview.tscn --fixed-fps 30 -- \
##     [--shots=build/combat] [--every=3] [--range=0-200] \
##     [--view=three_quarter|side|front|back|close] [--no-quit]
## [/codeblock]
## [br]- [code]--shots=<carpeta>[/code]: guarda un PNG cada [code]--every[/code] fotogramas y hojas de
## contactos de 4x4 ([code]sheet_XX.png[/code]). Relativa a la raíz del proyecto o absoluta.
## [br]- [code]--range=<desde>-<hasta>[/code]: solo captura esos fotogramas.
## [br]- [code]--no-quit[/code]: no cierra al terminar el guion.
## [br]En la rotulación se ve la acción, la fase y el clip y el instante que está enseñando la capa.

## Por vista: desplazamiento de la cámara respecto a los pies (xyz) y altura del punto al que mira (w).
const VIEWS: Dictionary[String, Vector4] = {
	"three_quarter": Vector4(2.6, 1.7, -3.2, 0.95),
	"side": Vector4(4.0, 1.3, 0.0, 0.95),
	"front": Vector4(0.0, 1.5, -4.0, 0.95),
	"back": Vector4(0.0, 1.9, 4.0, 0.95),
	"close": Vector4(1.4, 1.5, -2.2, 1.1),
}
const SHEET_COLUMNS: int = 4
const SHEET_ROWS: int = 4
const THUMB_SIZE: Vector2i = Vector2i(480, 270)
const PLAYER_SCENE: PackedScene = preload("res://scenes/characters/player_character.tscn")
## Ticks de espera al principio y entre el guion y los controles impuestos.
const START_IDLE_TICKS: int = 30
const STAGGER_TICKS: int = 24
const STUN_TICKS: int = 50
const DEAD_TICKS: int = 150

var _character: PlayerCharacter
var _visual: HumanoidVisual
var _camera: Camera3D
var _label: Label
var _script: CombatDemoScript = CombatDemoScript.new()
var _view: Vector4 = VIEWS["three_quarter"]
var _range_start: int = 0
var _range_end: int = 1 << 30
var _tick: int = 0
var _finished: bool = false
var _quit_when_done: bool = true
var _shots_dir: String = ""
var _shot_every: int = 3
var _frame: int = 0
var _shot_index: int = 0
var _sheet: Image = null
var _sheet_slot: int = 0
var _sheet_index: int = 0
var _pending_shots: int = 0


func _ready() -> void:
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
				push_warning("[CombatPreview] Vista desconocida: %s" % view)
		elif arg.begins_with("--range="):
			var bounds: PackedStringArray = arg.trim_prefix("--range=").split("-")
			if bounds.size() == 2:
				_range_start = bounds[0].to_int()
				_range_end = bounds[1].to_int()
		elif arg == "--no-quit":
			_quit_when_done = false
	if not _shots_dir.is_empty():
		DirAccess.make_dir_recursive_absolute(_shots_dir)
	# Después de todos los nodos (también del AnimationTree y los modificadores de pose).
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
	_visual = HumanoidVisual.install(_character)
	_update_camera()


func _physics_process(delta: float) -> void:
	if _finished:
		return
	_tick += 1
	var script_tick: int = _tick - START_IDLE_TICKS
	var input := PlayerInput.new()
	input.tick = _tick
	input.look_yaw = 0.0
	if script_tick >= 0 and script_tick < _script.get_length():
		input.buttons = _script.buttons_at(script_tick)
	_character.simulate(input.quantized(), delta)
	# Lo que impondría el servidor, tras el guion.
	var after: int = script_tick - _script.get_length()
	if after == 0:
		ActionMachine.impose_stagger(_character.combat, _tick, _tick + STAGGER_TICKS, Vector2.ZERO)
	elif after == STAGGER_TICKS + 20:
		ActionMachine.impose_stun(_character.combat, _tick, _tick + STUN_TICKS)
	elif after == STAGGER_TICKS + 20 + STUN_TICKS + 20:
		ActionMachine.impose_death(_character.combat, _tick)
	elif after >= STAGGER_TICKS + 40 + STUN_TICKS + DEAD_TICKS:
		_finished = true
		_on_script_finished()


func _process(_delta: float) -> void:
	_update_camera()
	_update_label()
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
	var combat: Dictionary = _visual.get_animator().get_debug_state()["combat"]
	var state: CombatState = _character.combat
	var text: String = "tick %d  %s  resist. %d" % [_tick, CombatState.Action.keys()[state.action],
			state.stamina]
	if bool(combat.get("active", false)):
		text += "\n%s  t=%.2f  x%.2f  peso %.2f%s" % [combat["animation"], combat["time"],
				combat["speed"], combat["weight"], "  (arriba)" if combat["upper_body"] else ""]
	_label.text = text


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
	print("[CombatPreview] Guion terminado (%d ticks)" % _tick)
	if not _quit_when_done:
		return
	var waited: int = 0
	while _pending_shots > 0 and waited < 120:
		await get_tree().process_frame
		waited += 1
	if not _shots_dir.is_empty():
		_flush_sheet()
		print("[CombatPreview] Capturas en %s" % _shots_dir)
	get_tree().quit()


static func _resolve_dir(path: String) -> String:
	path = path.strip_edges().trim_prefix("\"").trim_suffix("\"").replace("\\", "/")
	if path.begins_with("res://") or path.begins_with("user://"):
		return ProjectSettings.globalize_path(path)
	if path.is_relative_path():
		return ProjectSettings.globalize_path("res://").path_join(path)
	return path
