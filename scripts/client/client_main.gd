class_name ClientMain
extends Node
## Raíz del cliente: sandbox local, todavía sin red.
##
## Monta la zona elegida ([member zone_id], ver [Zones]), el personaje del jugador en el punto
## de aparición de su reino ([member realm]), su aspecto visual ([HumanoidVisual], solo en el
## cliente), la cámara de acción, el controlador local y el HUD. Las opciones de arranque llegan
## desde [code]boot.gd[/code] mediante las variables estáticas.
## [br][br]En modo demo la entrada sale de una demo guionizada ([DemoInput] en el circuito de
## pruebas, [RouteDemoInput] en las zonas) y, si hay carpeta de capturas, se guarda un PNG cada
## [constant SHOT_INTERVAL_TICKS] ticks y, al terminar, uno desde cada cámara de revisión de la
## zona (grupo [constant Zones.SCREENSHOT_GROUP]).

const PLAYER_SCENE_PATH: String = "res://scenes/characters/player_character.tscn"
const CAMERA_RIG_SCENE_PATH: String = "res://scenes/client/camera_rig.tscn"
const HUD_SCENE_PATH: String = "res://scenes/ui/hud.tscn"
const WINDOW_TITLE: String = "Eldmark"
## Cada cuántos ticks del controlador se guarda una captura en modo demo.
const SHOT_INTERVAL_TICKS: int = 90
## Fotogramas que se espera, como mucho, a que terminen las capturas pendientes antes de salir.
## Si la ventana no se dibuja (por ejemplo, minimizada) las capturas no llegan nunca.
const SHOT_WAIT_LIMIT_FRAMES: int = 120
## Fotogramas que se espera tras colocar la cámara de revisión (sombras, LOD y el clipmap del
## terreno) antes de capturar.
const REVIEW_SETTLE_FRAMES: int = 24
## Prefijo de las capturas de las cámaras de revisión de la zona.
const REVIEW_SHOT_PREFIX: String = "zona_"

## Zona que se carga (identificador de [Zones]).
static var zone_id: StringName = Zones.DEFAULT_ZONE
## Reino del jugador: decide el punto de aparición.
static var realm: StringName = Zones.DEFAULT_REALM
## Usa la entrada guionizada de [DemoInput] en lugar de teclado y ratón.
static var demo_mode: bool = false
## Carpeta absoluta donde guardar las capturas de la demo. Vacía: sin capturas.
static var shots_dir: String = ""
## Cierra el juego cuando termina la demo.
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


## Yaw (misma convención que [member Node3D.rotation].y) hacia el que mira una
## base, es decir, la orientación horizontal de su eje -Z.
static func _yaw_from_basis(basis: Basis) -> float:
	var forward: Vector3 = -basis.z
	return atan2(-forward.x, -forward.z)


func _ready() -> void:
	get_window().title = WINDOW_TITLE
	InputBindings.ensure_defaults()

	# Zona.
	var world_path: String = Zones.get_scene_path(zone_id)
	if world_path.is_empty():
		push_error("[Eldmark] Zona desconocida: %s" % zone_id)
		return
	_world = _instantiate_scene(world_path)
	if _world == null:
		return
	add_child(_world)
	print("[Eldmark] Zona: %s (%s), reino: %s" % [zone_id, world_path, realm])

	# Punto de aparición: posición y orientación del primero del reino (o del primero de la zona).
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

	# Aspecto visual (solo cliente): el humanoide animado sustituye a la cápsula provisional de
	# player_character.tscn, que se queda ligera para el servidor.
	_install_visual()

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


## Escena de la zona cargada (null si no se pudo cargar).
func get_world() -> Node:
	return _world


## Personaje del jugador local.
func get_character() -> PlayerCharacter:
	return _character


## Aspecto visual del personaje (null si no se pudo cargar y se ve la cápsula provisional).
func get_visual() -> HumanoidVisual:
	return _visual


## Cámara de acción.
func get_camera_rig() -> CameraRig:
	return _camera_rig


## Cuelga el [HumanoidVisual] bajo el nodo Visual del personaje y quita las mallas provisionales
## (cápsula y visor). Si el visual no carga, la cápsula se queda para que se vea algo.
func _install_visual() -> void:
	_visual = HumanoidVisual.install(_character)
	if _visual == null:
		push_warning("[Eldmark] Sin visual del humanoide: se usa la cápsula provisional")
		return
	var visual_root: Node = _visual.get_parent()
	for child: Node in visual_root.get_children():
		if child is MeshInstance3D:
			visual_root.remove_child(child)
			child.queue_free()


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
	# Tras la demo ya no se hacen capturas periódicas (las de revisión usan su propia cámara).
	if _shots_enabled and not _demo_finished and input.tick % SHOT_INTERVAL_TICKS == 0:
		_save_screenshot(_shot_index)
		_shot_index += 1
	if not _demo_finished and _demo.is_finished(input.tick):
		_demo_finished = true
		_finish_demo()


## Espera a que se dibuje el fotograma y guarda el contenido del viewport. Con la
## ventana minimizada no se dibuja nada, así que la captura se omite.
func _save_screenshot(index: int) -> void:
	await _save_viewport_png(shots_dir.path_join("shot_%03d.png" % index))


## Espera al siguiente fotograma dibujado y guarda el viewport en [param path].
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
	print("[Eldmark] Demo terminada (tick %d)" % _controller.get_tick())
	if _shots_enabled:
		await _capture_review_points()
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


## Guarda una captura desde cada cámara de revisión de la zona ([code]zona_<nombre>.png[/code]),
## sin HUD, y devuelve la vista a la cámara de acción.
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
