class_name ClientMain
extends Node
## Client root: local sandbox, still with no network.
##
## Mounts the chosen zone ([member zone_id], see [Zones]), the player's character at their realm's
## spawn point ([member realm]), its visual look ([HumanoidVisual], client-only), the action camera,
## the local controller and the HUD. The start-up options arrive from [ClientLauncher] (which parses
## what [code]boot.gd[/code] leaves) through the static variables.
## [br][br]In demo mode the input comes from a scripted demo ([DemoInput] on the test course,
## [RouteDemoInput] in the zones) and, if there is a screenshots folder, a PNG is saved every
## [constant SHOT_INTERVAL_TICKS] ticks and, at the end, one from each review camera of the zone
## (group [constant Zones.SCREENSHOT_GROUP]).

const PLAYER_SCENE_PATH: String = "res://scenes/characters/player_character.tscn"
const CAMERA_RIG_SCENE_PATH: String = "res://scenes/client/camera_rig.tscn"
const HUD_SCENE_PATH: String = "res://scenes/ui/hud.tscn"
const WINDOW_TITLE: String = "Eldmark"
## How many controller ticks between screenshots in demo mode.
const SHOT_INTERVAL_TICKS: int = 90
## Frames to wait, at most, for pending screenshots to finish before exiting.
## If the window is not drawn (for example, minimized) the screenshots never arrive.
const SHOT_WAIT_LIMIT_FRAMES: int = 120
## Frames to wait after placing the review camera (shadows, LOD and the terrain clipmap) before
## capturing.
const REVIEW_SETTLE_FRAMES: int = 24
## Prefix of the screenshots from the zone's review cameras.
const REVIEW_SHOT_PREFIX: String = "zona_"

## Zone to load (identifier from [Zones]).
static var zone_id: StringName = Zones.DEFAULT_ZONE
## Player's realm: decides the spawn point.
static var realm: StringName = Zones.DEFAULT_REALM
## Uses the scripted input of [DemoInput] instead of keyboard and mouse.
static var demo_mode: bool = false
## Absolute folder where demo screenshots are saved. Empty: no screenshots.
static var shots_dir: String = ""
## Closes the game when the demo ends.
static var quit_after_demo: bool = false

var _world: Node
var _visual: HumanoidVisual
var _character: PlayerCharacter
var _camera_rig: CameraRig
var _controller: LocalPlayerController
var _hud: HUD
var _demo: DemoInput
var _shots_enabled: bool = false
var _shot_index: int = 0
var _pending_shots: int = 0
var _demo_finished: bool = false
## Times the character entered each combat action during the demo
## ([code]CombatState.Action[/code] -> times; a light attack with another combo hit counts as a new entry).
var _demo_actions: Dictionary = {}
## Last (action, attack) pair seen during the demo.
var _demo_last_action: Vector2i = Vector2i(CombatState.Action.NONE, 0)


## Yaw (same convention as [member Node3D.rotation].y) that a basis faces, that is, the
## horizontal orientation of its -Z axis.
static func _yaw_from_basis(basis: Basis) -> float:
	var forward: Vector3 = -basis.z
	return atan2(-forward.x, -forward.z)


func _ready() -> void:
	get_window().title = WINDOW_TITLE
	InputBindings.ensure_defaults()

	# Zone.
	var world_path: String = Zones.get_scene_path(zone_id)
	if world_path.is_empty():
		push_error("[Eldmark] Zona desconocida: %s" % zone_id)
		return
	_world = _instantiate_scene(world_path)
	if _world == null:
		return
	add_child(_world)
	print("[Eldmark] Zona: %s (%s), reino: %s" % [zone_id, world_path, realm])

	# Spawn point: position and orientation of the realm's first one (or the zone's first one).
	var spawn_position: Vector3 = Vector3.ZERO
	var spawn_yaw: float = 0.0
	var spawn: Node3D = Zones.find_spawn_point(_world, realm)
	if spawn != null:
		spawn_position = spawn.global_position
		spawn_yaw = _yaw_from_basis(spawn.global_transform.basis)
		var spawn_realm: StringName = Zones.get_spawn_realm(spawn)
		if not spawn_realm.is_empty() and spawn_realm != realm:
			push_warning("[Eldmark] La zona %s no tiene puntos de aparición de %s; se usa %s"
					% [zone_id, realm, spawn.name])
	else:
		push_warning("[Eldmark] La zona %s no tiene nodos en el grupo '%s'; se aparece en el origen"
				% [zone_id, Zones.SPAWN_GROUP])

	# Player character. The initial state is applied with set_state() so that
	# 'yaw' and 'grounded' (used by simulate()) are consistent from the first tick.
	_character = _instantiate_scene(PLAYER_SCENE_PATH, PlayerCharacter) as PlayerCharacter
	if _character == null:
		return
	add_child(_character)
	var spawn_state: PlayerState = PlayerState.new()
	spawn_state.position = spawn_position
	spawn_state.yaw = spawn_yaw
	_character.set_state(spawn_state)
	_character.reset_physics_interpolation()

	# Visual look (client only): the animated humanoid replaces the provisional capsule of
	# player_character.tscn, which stays lightweight for the server.
	_install_visual()

	# Over-the-shoulder action camera, facing where the spawn faces. In the
	# demo the view is scripted from before entering the tree, so that the camera
	# never captures the mouse (capturing it moves the real system cursor).
	_camera_rig = _instantiate_scene(CAMERA_RIG_SCENE_PATH, CameraRig) as CameraRig
	if _camera_rig == null:
		return
	_camera_rig.set_scripted_look(demo_mode)
	add_child(_camera_rig)
	_camera_rig.set_target(_character.get_camera_target(), _character)
	_camera_rig.set_hide_when_close(_character.get_node_or_null(^"Visual") as Node3D)
	_camera_rig.set_look(spawn_yaw, 0.0)

	# Local controller: generates one PlayerInput per tick and simulates the character.
	_controller = LocalPlayerController.new()
	_controller.name = "LocalPlayerController"
	add_child(_controller)
	_controller.setup(_character, _camera_rig)

	# UI.
	_hud = _instantiate_scene(HUD_SCENE_PATH, HUD) as HUD
	if _hud == null:
		return
	add_child(_hud)
	_hud.bind(_character, _camera_rig)
	_hud.bind_controller(_controller)

	if demo_mode:
		_start_demo()


## Scene of the loaded zone (null if it could not be loaded).
func get_world() -> Node:
	return _world


## The local player's character.
func get_character() -> PlayerCharacter:
	return _character


## Visual look of the character (null if it could not be loaded and the provisional capsule is shown).
func get_visual() -> HumanoidVisual:
	return _visual


## Action camera.
func get_camera_rig() -> CameraRig:
	return _camera_rig


## Hangs the [HumanoidVisual] under the character's Visual node and removes the provisional meshes
## (capsule and visor). If the visual does not load, the capsule stays so that something is visible.
func _install_visual() -> void:
	_visual = HumanoidVisual.install_replacing_placeholder(_character)
	if _visual == null:
		push_warning("[Eldmark] Sin visual del humanoide: se usa la cápsula provisional")


## Loads and instantiates a scene. If [param expected] is not null, the root must be of
## that type; if it is not, it is freed. Returns null (and logs the error) on failure.
func _instantiate_scene(path: String, expected: Script = null) -> Node:
	var scene: PackedScene = load(path) as PackedScene
	if scene == null:
		push_error("[Eldmark] No se pudo cargar la escena %s" % path)
		return null
	var instance: Node = scene.instantiate()
	if instance == null:
		push_error("[Eldmark] No se pudo instanciar la escena %s" % path)
		return null
	if expected != null and not is_instance_of(instance, expected):
		push_error("[Eldmark] La raíz de %s no es un %s" % [path, expected.get_global_name()])
		instance.free()
		return null
	return instance


func _start_demo() -> void:
	_demo = RouteDemoInput.for_zone(zone_id, realm)
	_demo.bind(_character)
	_controller.enable_demo(_demo)
	_controller.input_generated.connect(_on_demo_input_generated)

	if not shots_dir.is_empty():
		if DisplayServer.get_name() == "headless":
			print("[Eldmark] Sin pantalla (headless): se omiten las capturas")
		else:
			var error: Error = DirAccess.make_dir_recursive_absolute(shots_dir)
			if error == OK:
				_shots_enabled = true
			else:
				push_error("[Eldmark] No se pudo crear la carpeta de capturas %s (%s)"
						% [shots_dir, error_string(error)])

	print("[Eldmark] Demo iniciada (%s, unos %d ticks)" % [_demo.get_script().get_global_name(),
			_demo.get_length()])


func _on_demo_input_generated(input: PlayerInput) -> void:
	_note_demo_action()
	# After the demo no more periodic screenshots are taken (the review ones use their own camera).
	if _shots_enabled and not _demo_finished and input.tick % SHOT_INTERVAL_TICKS == 0:
		_save_screenshot(_shot_index)
		_shot_index += 1
	if not _demo_finished and _demo.is_finished(input.tick):
		_demo_finished = true
		_finish_demo()


## Records the combat action the character is in (the previous tick's) if it is a new entry.
func _note_demo_action() -> void:
	var current := Vector2i(_character.combat.action, _character.combat.action_id)
	if current == _demo_last_action:
		return
	_demo_last_action = current
	if current.x != CombatState.Action.NONE:
		_demo_actions[current.x] = int(_demo_actions.get(current.x, 0)) + 1


## Summary of the demo's combat actions, in the order each was entered:
## "LIGHT x4, CHARGE x1, HEAVY x1, BLOCK x1, DODGE x1". Empty if there was no combat.
func _demo_actions_summary() -> String:
	var parts := PackedStringArray()
	for action: int in _demo_actions:
		parts.append("%s x%d" % [CombatState.Action.keys()[action], _demo_actions[action]])
	return ", ".join(parts)


## Waits for the frame to be drawn and saves the viewport contents. With the
## window minimized nothing is drawn, so the screenshot is skipped.
func _save_screenshot(index: int) -> void:
	await _save_viewport_png(shots_dir.path_join("shot_%03d.png" % index))


## Waits for the next drawn frame and saves the viewport to [param path].
func _save_viewport_png(path: String) -> void:
	if DisplayServer.window_get_mode() == DisplayServer.WINDOW_MODE_MINIMIZED:
		push_warning("[Eldmark] Ventana minimizada: se omite la captura %s" % path)
		return
	_pending_shots += 1
	await RenderingServer.frame_post_draw
	var image: Image = get_viewport().get_texture().get_image()
	if image == null or image.is_empty():
		push_error("[Eldmark] No se pudo leer el viewport para la captura %s" % path)
	else:
		var error: Error = image.save_png(path)
		if error == OK:
			print("[Eldmark] Captura guardada: %s" % path)
		else:
			push_error("[Eldmark] No se pudo guardar la captura %s (%s)"
					% [path, error_string(error)])
	_pending_shots -= 1


func _finish_demo() -> void:
	var actions: String = _demo_actions_summary()
	if not actions.is_empty():
		print("[Eldmark] Demo, acciones de combate: %s" % actions)
	print("[Eldmark] Demo terminada (tick %d)" % _controller.get_tick())
	if _shots_enabled:
		await _capture_review_points()
	if not quit_after_demo:
		return
	# Lets pending screenshots finish before exiting, but without waiting
	# forever: process_frame fires even if the window is not drawn.
	var waited_frames: int = 0
	while _pending_shots > 0 and waited_frames < SHOT_WAIT_LIMIT_FRAMES:
		await get_tree().process_frame
		waited_frames += 1
	if _pending_shots > 0:
		push_warning("[Eldmark] Se cierra sin %d capturas pendientes: la ventana no se dibujó"
				% _pending_shots)
	get_tree().quit()


## Saves a screenshot from each review camera of the zone ([code]zona_<name>.png[/code]),
## without the HUD, and returns the view to the action camera.
func _capture_review_points() -> void:
	var markers: Array[Node3D] = Zones.get_screenshot_points(_world)
	if markers.is_empty():
		return
	print("[Eldmark] Capturando %d cámaras de revisión de la zona" % markers.size())
	var camera: Camera3D = Camera3D.new()
	camera.name = "ReviewCamera"
	camera.far = 1200.0
	camera.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	add_child(camera)
	camera.make_current()
	_hud.visible = false
	for marker: Node3D in markers:
		camera.global_transform = marker.global_transform
		camera.fov = float(marker.get_meta(&"fov", 60.0))
		for _i: int in REVIEW_SETTLE_FRAMES:
			await get_tree().process_frame
		await _save_viewport_png(shots_dir.path_join("%s%s.png" % [REVIEW_SHOT_PREFIX, marker.name]))
	_hud.visible = true
	camera.queue_free()
	_camera_rig.get_camera().make_current()
