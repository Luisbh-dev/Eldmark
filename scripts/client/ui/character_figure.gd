class_name CharacterFigure
extends SubViewportContainer
## The 3D figure for character selection and creation (docs/platform.md §13.2, UI-23 and UI-24): a
## [SubViewport] with its own world, a still [PlayerCharacter] with [HumanoidVisual] and the appearance
## it is given ([method show_appearance], with [method AppearanceApplier.apply]) and an orbital camera:
## dragging with the mouse rotates it around the figure and the wheel zooms in or out. Without an
## appearance (or with one that is not valid for its people), the default of the realm's people
## ([method AppearanceApplier.resolve]).
## [br][br]
## The figure is assembled on entering the tree. Placeholder framing and lighting
## ([code]# TODO(arte)[/code], like the character window). Client only.

const PLAYER_SCENE_PATH: String = "res://scenes/characters/player_character.tscn"
const DEFAULT_SIZE: Vector2i = Vector2i(360, 480)
## Radians the camera turns per dragged pixel.
const TURN_RATE: float = 0.01
## Radians the camera starts away from the front: a three-quarter view, so the shield is seen at an angle (with its
## dome and rim) instead of as a disc facing the camera.
const DEFAULT_TURN: float = -0.45
## Camera distance to the figure's center: default, minimum and maximum, and wheel step.
const DEFAULT_DISTANCE: float = 3.3
const MIN_DISTANCE: float = 1.6
const MAX_DISTANCE: float = 5.0
const ZOOM_STEP: float = 0.25
## Height of the point the camera looks at.
const TARGET_HEIGHT: float = 0.95
const CAMERA_FOV: float = 38.0
const AMBIENT_COLOR: Color = Color(0.55, 0.55, 0.6, 1.0)

var _viewport: SubViewport = null
var _camera: Camera3D = null
var _preview: PlayerCharacter = null
var _visual: HumanoidVisual = null
var _yaw: float = PI + DEFAULT_TURN
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


## Shows the appearance from the 8 B [param bytes] of a character of [param realm]
## ([enum NetProtocol.Realm] code): its own if it is valid for the realm's people and, if not, the default one.
func show_appearance(bytes: PackedByteArray, realm: int) -> void:
	_realm = realm
	_appearance = AppearanceApplier.resolve(bytes, realm)
	_apply()


## Shows [param appearance] as is (creation: what is being chosen).
func show_appearance_object(appearance: CharacterAppearance, realm: int) -> void:
	_realm = realm
	_appearance = appearance
	_apply()


## The appearance being shown (null if none).
func get_appearance() -> CharacterAppearance:
	return _appearance


## The figure's [HumanoidVisual] (null until it enters the tree or if it could not be assembled).
func get_visual() -> HumanoidVisual:
	return _visual


## The figure's still [PlayerCharacter] (null until it enters the tree or if it could not be assembled).
func get_preview_character() -> PlayerCharacter:
	return _preview


## Camera angle around the figure (radians).
func get_yaw() -> float:
	return _yaw


## Camera distance.
func get_distance() -> float:
	return _distance


## Turns the camera by the amount corresponding to dragging [param pixels] horizontally.
func orbit(pixels: float) -> void:
	_yaw = wrapf(_yaw + pixels * TURN_RATE, -PI, PI)
	_place_camera()


## Zooms the camera in (negative) or out (positive) by [param steps] wheel steps.
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
	# TODO(arte): placeholder framing, lighting and background until UI-23 and UI-24 get sign-off (docs/platform.md §15).
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
	# Nobody simulates this character: without this, the animator always sees it in the air and shows it in the fall pose (UI-49).
	_preview.grounded = true
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
