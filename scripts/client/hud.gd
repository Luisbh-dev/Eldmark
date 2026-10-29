class_name HUD
extends CanvasLayer
## Interfaz del jugador en el sandbox: punto de mira, panel de depuración y
## ayuda de controles.
##
## Solo cliente. Lee el estado del personaje y de la cámara cada frame, pero
## nunca modifica la simulación. Se conecta con [method bind].

## Cada cuánto se refresca el texto del panel de depuración, en segundos.
## Refrescarlo cada frame hace que las cifras parpadeen y sean ilegibles.
const DEBUG_REFRESH_INTERVAL: float = 0.1

var _character: PlayerCharacter = null
var _camera_rig: CameraRig = null
var _debug_refresh_left: float = 0.0

@onready var _crosshair: Crosshair = $Crosshair
@onready var _debug_panel: PanelContainer = $DebugPanel
@onready var _debug_label: Label = $DebugPanel/DebugLabel


func _ready() -> void:
	# Los controles no se mueven, pero así el HUD nunca se ve afectado por la
	# interpolación de físicas.
	physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	_update_crosshair()
	_refresh_debug_text()


## Conecta el HUD con el personaje local y la cámara. Se puede llamar antes o
## después de añadir el HUD al árbol.
func bind(character: PlayerCharacter, camera_rig: CameraRig) -> void:
	_character = character
	_camera_rig = camera_rig
	_debug_refresh_left = 0.0
	if is_node_ready():
		_update_crosshair()
		_refresh_debug_text()


func _process(delta: float) -> void:
	_update_crosshair()
	if not _debug_panel.visible:
		return
	_debug_refresh_left -= delta
	if _debug_refresh_left <= 0.0:
		_debug_refresh_left = DEBUG_REFRESH_INTERVAL
		_refresh_debug_text()


func _unhandled_input(event: InputEvent) -> void:
	if InputMap.has_action(&"toggle_debug") and event.is_action_pressed(&"toggle_debug"):
		_debug_panel.visible = not _debug_panel.visible
		if _debug_panel.visible:
			_debug_refresh_left = 0.0
			_refresh_debug_text()
		get_viewport().set_input_as_handled()


## Muestra u oculta el panel de depuración sin esperar a F3. El cliente en red lo empieza oculto y
## F3 lo alterna junto con [NetDebugOverlay].
func set_debug_visible(visible_now: bool) -> void:
	_debug_panel.visible = visible_now
	if visible_now:
		_debug_refresh_left = 0.0
		_refresh_debug_text()


## El punto de mira solo tiene sentido mientras el ratón controla la cámara.
func _update_crosshair() -> void:
	var cursor_free: bool = is_instance_valid(_camera_rig) and _camera_rig.is_cursor_free()
	_crosshair.visible = not cursor_free


func _refresh_debug_text() -> void:
	var fps: int = roundi(Engine.get_frames_per_second())
	if not is_instance_valid(_character):
		_debug_label.text = "FPS: %d\nSin personaje vinculado" % fps
		return
	var pos: Vector3 = _character.global_position
	var yaw_degrees: float = rad_to_deg(wrapf(_character.yaw, -PI, PI))
	var lines: PackedStringArray = [
		"FPS: %d" % fps,
		"Posición: (%7.2f, %7.2f, %7.2f)" % [pos.x, pos.y, pos.z],
		"Velocidad horizontal: %5.2f m/s" % _character.get_horizontal_speed(),
		"En suelo: %s" % ("sí" if _character.grounded else "no"),
		"Orientación (yaw): %6.1f°" % yaw_degrees,
	]
	_debug_label.text = "\n".join(lines)
