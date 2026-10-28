class_name ClientMain
extends Node
## Raíz del cliente en la fase 1: sandbox local, sin red.
##
## Monta el mundo de pruebas, el personaje del jugador en el primer punto de
## aparición, la cámara de acción, el controlador local y el HUD. Las opciones
## de arranque llegan desde [code]boot.gd[/code] mediante las variables estáticas.
## [br][br]En modo demo la entrada sale de un [DemoInput] guionizado y, si hay
## carpeta de capturas, se guarda un PNG cada [constant SHOT_INTERVAL_TICKS] ticks.

const WORLD_SCENE_PATH: String = "res://scenes/world/test_world.tscn"
const PLAYER_SCENE_PATH: String = "res://scenes/characters/player_character.tscn"
const CAMERA_RIG_SCENE_PATH: String = "res://scenes/client/camera_rig.tscn"
const HUD_SCENE_PATH: String = "res://scenes/ui/hud.tscn"
const SPAWN_GROUP: StringName = &"spawn_points"
const WINDOW_TITLE: String = "Eldmark"
## Cada cuántos ticks del controlador se guarda una captura en modo demo.
const SHOT_INTERVAL_TICKS: int = 90
## Fotogramas que se espera, como mucho, a que terminen las capturas pendientes antes de salir.
## Si la ventana no se dibuja (por ejemplo, minimizada) las capturas no llegan nunca.
const SHOT_WAIT_LIMIT_FRAMES: int = 120

## Usa la entrada guionizada de [DemoInput] en lugar de teclado y ratón.
static var demo_mode: bool = false
## Carpeta absoluta donde guardar las capturas de la demo. Vacía: sin capturas.
static var shots_dir: String = ""
## Cierra el juego cuando termina la demo.
static var quit_after_demo: bool = false

var _world: Node
var _character: PlayerCharacter
var _camera_rig: CameraRig
var _controller: LocalPlayerController
var _hud: HUD
var _demo: DemoInput
var _shots_enabled: bool = false
var _shot_index: int = 0
var _pending_shots: int = 0
var _demo_finished: bool = false


## Yaw (misma convención que [member Node3D.rotation].y) hacia el que mira una
## base, es decir, la orientación horizontal de su eje -Z.
static func _yaw_from_basis(basis: Basis) -> float:
	var forward: Vector3 = -basis.z
	return atan2(-forward.x, -forward.z)


func _ready() -> void:
	get_window().title = WINDOW_TITLE
	InputBindings.ensure_defaults()

	# Mundo de pruebas.
	_world = _instantiate_scene(WORLD_SCENE_PATH)
	if _world == null:
		return
	add_child(_world)

	# Punto de aparición: posición y orientación del primer marcador del grupo.
	var spawn_position: Vector3 = Vector3.ZERO
	var spawn_yaw: float = 0.0
	var spawn: Node3D = get_tree().get_first_node_in_group(SPAWN_GROUP) as Node3D
	if spawn != null:
		spawn_position = spawn.global_position
		spawn_yaw = _yaw_from_basis(spawn.global_transform.basis)
	else:
		push_warning("[Eldmark] No hay ningún nodo en el grupo '%s'; se aparece en el origen"
				% SPAWN_GROUP)

	# Personaje del jugador. El estado inicial se aplica con set_state() para que
	# 'yaw' y 'grounded' (que usa simulate()) queden coherentes desde el primer tick.
	_character = _instantiate_scene(PLAYER_SCENE_PATH, PlayerCharacter) as PlayerCharacter
	if _character == null:
		return
	add_child(_character)
	var spawn_state: PlayerState = PlayerState.new()
	spawn_state.position = spawn_position
	spawn_state.yaw = spawn_yaw
	_character.set_state(spawn_state)
	_character.reset_physics_interpolation()

	# Cámara de acción por encima del hombro, mirando hacia donde mira el spawn. En la
	# demo la vista es guionizada desde antes de entrar en el árbol, para que la cámara
	# nunca capture el ratón (capturarlo mueve el cursor real del sistema).
	_camera_rig = _instantiate_scene(CAMERA_RIG_SCENE_PATH, CameraRig) as CameraRig
	if _camera_rig == null:
		return
	_camera_rig.set_scripted_look(demo_mode)
	add_child(_camera_rig)
	_camera_rig.set_target(_character.get_camera_target(), _character)
	_camera_rig.set_hide_when_close(_character.get_node_or_null(^"Visual") as Node3D)
	_camera_rig.set_look(spawn_yaw, 0.0)

	# Controlador local: genera un PlayerInput por tick y simula el personaje.
	_controller = LocalPlayerController.new()
	_controller.name = "LocalPlayerController"
	add_child(_controller)
	_controller.setup(_character, _camera_rig)

	# Interfaz.
	_hud = _instantiate_scene(HUD_SCENE_PATH, HUD) as HUD
	if _hud == null:
		return
	add_child(_hud)
	_hud.bind(_character, _camera_rig)

	if demo_mode:
		_start_demo()


## Carga e instancia una escena. Si [param expected] no es null, la raíz debe ser de
## ese tipo; si no lo es, se libera. Devuelve null (y registra el error) si falla.
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
	_demo = DemoInput.new()
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

	print("[Eldmark] Demo iniciada (%d ticks)" % _demo.get_length())


func _on_demo_input_generated(input: PlayerInput) -> void:
	if _shots_enabled and input.tick % SHOT_INTERVAL_TICKS == 0:
		_save_screenshot(_shot_index)
		_shot_index += 1
	if not _demo_finished and _demo.is_finished(input.tick):
		_demo_finished = true
		_finish_demo()


## Espera a que se dibuje el fotograma y guarda el contenido del viewport. Con la
## ventana minimizada no se dibuja nada, así que la captura se omite.
func _save_screenshot(index: int) -> void:
	var path: String = shots_dir.path_join("shot_%03d.png" % index)
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
	print("[Eldmark] Demo terminada (tick %d)" % _controller.get_tick())
	if not quit_after_demo:
		return
	# Deja terminar las capturas pendientes antes de salir, pero sin esperar para
	# siempre: process_frame llega aunque la ventana no se dibuje.
	var waited_frames: int = 0
	while _pending_shots > 0 and waited_frames < SHOT_WAIT_LIMIT_FRAMES:
		await get_tree().process_frame
		waited_frames += 1
	if _pending_shots > 0:
		push_warning("[Eldmark] Se cierra sin %d capturas pendientes: la ventana no se dibujó"
				% _pending_shots)
	get_tree().quit()
