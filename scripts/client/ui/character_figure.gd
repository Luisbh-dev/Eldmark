class_name CharacterFigure
extends SubViewportContainer
## La figura 3D de la selección y la creación de personaje (docs/plataforma.md §13.2, UI-23 y UI-24): un
## [SubViewport] con su propio mundo, un [PlayerCharacter] quieto con [HumanoidVisual] y la apariencia que se le da
## ([method show_appearance], con [method AppearanceApplier.apply]) y una cámara orbital: arrastrar con el ratón la
## gira alrededor de la figura y la rueda acerca o aleja. Sin apariencia (o con una que no vale para su pueblo), la de
## por defecto del pueblo del reino ([method AppearanceApplier.resolve]).
## [br][br]
## La figura se monta al entrar en el árbol. Encuadre y luz provisionales ([code]# TODO(arte)[/code], como la ventana
## de personaje). Solo cliente.

const PLAYER_SCENE_PATH: String = "res://scenes/characters/player_character.tscn"
const DEFAULT_SIZE: Vector2i = Vector2i(360, 480)
## Radianes que gira la cámara por píxel arrastrado.
const TURN_RATE: float = 0.01
## Distancia de la cámara al centro de la figura: por defecto, mínima y máxima, y paso de la rueda.
const DEFAULT_DISTANCE: float = 3.3
const MIN_DISTANCE: float = 1.6
const MAX_DISTANCE: float = 5.0
const ZOOM_STEP: float = 0.25
## Altura del punto que mira la cámara.
const TARGET_HEIGHT: float = 0.95
const CAMERA_FOV: float = 38.0
const AMBIENT_COLOR: Color = Color(0.55, 0.55, 0.6, 1.0)

var _viewport: SubViewport = null
var _camera: Camera3D = null
var _preview: PlayerCharacter = null
var _visual: HumanoidVisual = null
var _yaw: float = PI
var _distance: float = DEFAULT_DISTANCE
var _dragging: bool = false
var _appearance: CharacterAppearance = null
var _realm: int = NetProtocol.Realm.NONE


func _init() -> void:
	name = "Figura"
	stretch = true
	custom_minimum_size = Vector2(DEFAULT_SIZE)
	mouse_filter = Control.MOUSE_FILTER_STOP
	gui_input.connect(_on_gui_input)


func _ready() -> void:
	_build()


## Enseña la apariencia de los 8 B [param bytes] de un personaje de [param realm] (código de
## [enum NetProtocol.Realm]): la suya si vale para el pueblo del reino y, si no, la de por defecto.
func show_appearance(bytes: PackedByteArray, realm: int) -> void:
	_realm = realm
	_appearance = AppearanceApplier.resolve(bytes, realm)
	_apply()


## Enseña [param appearance] tal cual (la creación: lo que se está eligiendo).
func show_appearance_object(appearance: CharacterAppearance, realm: int) -> void:
	_realm = realm
	_appearance = appearance
	_apply()


## La apariencia que se enseña (null si ninguna).
func get_appearance() -> CharacterAppearance:
	return _appearance


## El [HumanoidVisual] de la figura (null hasta que entra en el árbol o si no se pudo montar).
func get_visual() -> HumanoidVisual:
	return _visual


## Ángulo de la cámara alrededor de la figura (radianes).
func get_yaw() -> float:
	return _yaw


## Distancia de la cámara.
func get_distance() -> float:
	return _distance


## Gira la cámara lo que corresponde a arrastrar [param pixels] en horizontal.
func orbit(pixels: float) -> void:
	_yaw = wrapf(_yaw + pixels * TURN_RATE, -PI, PI)
	_place_camera()


## Acerca (negativo) o aleja (positivo) la cámara [param steps] pasos de la rueda.
func zoom(steps: float) -> void:
	_distance = clampf(_distance + steps * ZOOM_STEP, MIN_DISTANCE, MAX_DISTANCE)
	_place_camera()


func _build() -> void:
	if _viewport != null:
		return
	_viewport = SubViewport.new()
	_viewport.name = "Mundo"
	_viewport.own_world_3d = true
	_viewport.transparent_bg = true
	_viewport.size = DEFAULT_SIZE
	_viewport.render_target_update_mode = SubViewport.UPDATE_WHEN_VISIBLE
	add_child(_viewport)
	var environment := WorldEnvironment.new()
	environment.environment = Environment.new()
	environment.environment.background_mode = Environment.BG_CLEAR_COLOR
	environment.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.environment.ambient_light_color = AMBIENT_COLOR
	_viewport.add_child(environment)
	# TODO(arte): encuadre, luz y fondo provisionales hasta el visto bueno de UI-23 y UI-24 (docs/plataforma.md §15).
	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-35.0, 160.0, 0.0)
	_viewport.add_child(light)
	_camera = Camera3D.new()
	_camera.fov = CAMERA_FOV
	_viewport.add_child(_camera)
	var scene: PackedScene = load(PLAYER_SCENE_PATH) as PackedScene
	_preview = scene.instantiate() as PlayerCharacter if scene != null else null
	if _preview == null:
		push_warning("[Eldmark] No se pudo montar la figura del personaje")
		return
	_preview.name = "Personaje"
	_viewport.add_child(_preview)
	_visual = HumanoidVisual.install_replacing_placeholder(_preview)
	_place_camera()
	_apply()


func _apply() -> void:
	if _visual == null or _appearance == null:
		return
	AppearanceApplier.apply(_visual, _appearance)


func _place_camera() -> void:
	if _camera == null or not _camera.is_inside_tree():
		return
	var target := Vector3(0.0, TARGET_HEIGHT, 0.0)
	var offset := Vector3(sin(_yaw), 0.08, cos(_yaw)) * _distance
	_camera.look_at_from_position(target + offset, target, Vector3.UP)


func _on_gui_input(event: InputEvent) -> void:
	var button: InputEventMouseButton = event as InputEventMouseButton
	if button != null:
		match button.button_index:
			MOUSE_BUTTON_LEFT:
				_dragging = button.pressed
				accept_event()
			MOUSE_BUTTON_WHEEL_UP:
				if button.pressed:
					zoom(-1.0)
				accept_event()
			MOUSE_BUTTON_WHEEL_DOWN:
				if button.pressed:
					zoom(1.0)
				accept_event()
		return
	var motion: InputEventMouseMotion = event as InputEventMouseMotion
	if motion != null and _dragging:
		orbit(motion.relative.x)
		accept_event()
