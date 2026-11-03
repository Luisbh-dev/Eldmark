extends Node3D
## Vista previa de los efectos de golpe (ART-09; herramienta de desarrollo, solo cliente).
##
## Un [PlayerCharacter] con el humanoide animado, la espada y el escudo provisionales y un muñeco enfrente
## (otro humanoide quieto) sobre un suelo liso, bajo el entorno del Vado Gris. El jugador repite en bucle el
## guion de combate de la demo ([CombatDemoScript], por la simulación de verdad): tres ligeros, un fuerte
## cargado, un bloqueo y una esquiva. Cada acción dispara su efecto como lo haría el combate cuando se
## conecte (los efectos NO están conectados al combate: aquí lo hace esta escena mirando el estado):
## [br]- [b]Estela[/b] de la espada ([WeaponTrail]) mientras el golpe está activo.
## [br]- [b]Ligero 1[/b]: chispa de metal en la espada del muñeco. [b]Ligero 2[/b]: impacto en carne. [b]Ligero
## 3[/b]: impacto bloqueado en su escudo de madera. [b]Fuerte[/b]: carne y metal a la vez.
## [br]- [b]Carga del fuerte[/b]: aura ([ChargeAura]) que crece con la carga, pulso al completarla y estallido al
## soltar.
## [br]- [b]Bloqueo[/b]: parada perfecta entre los dos. [b]Esquiva[/b]: polvo hacia atrás y, al caer, el anillo
## de polvo del aterrizaje.
## [br][br]
## Uso (ventana; [code]--fixed-fps 60[/code] hace la ejecución determinista, un tick por fotograma):
## [codeblock]
## godot --path . res://scenes/tests/vfx_preview.tscn --fixed-fps 60 -- \
##     [--strip=metal|flesh|block|parry|dust|dodge|trail|aura|showcase] [--realm=0..4] \
##     [--out=build/vfx/strips] [--folder=<nombre>] [--no-quit]
## [/codeblock]
## [br]- Sin [code]--strip[/code]: bucle de demostración, sin cerrarse.
## [br]- [code]--strip=<efecto>[/code]: graba doce fotogramas recortados alrededor del efecto en
## [code]<out>/<efecto>/frame_NN.png[/code] y un [code]meta.json[/code] con sus tiempos
## ([code]tools/vfx/compose_strips.py[/code] los une en una hoja). [code]showcase[/code] dispara todos a la
## vez y guarda cuatro pantallas completas.
## [br]- [code]--realm=<n>[/code]: reino del color de la estela, el aura y el polvo (1 Vardheim, 2 Solmarch, 3
## Askarra, 4 Eldrun, 0 neutro).
## [br]- [code]--folder=<nombre>[/code]: subcarpeta de la grabación (por defecto, el nombre del efecto).
## [br]- [code]--out=<carpeta>[/code]: carpeta de salida (por defecto [code]build/vfx/strips[/code], relativa a la raíz
## del proyecto).

const PLAYER_SCENE: PackedScene = preload("res://scenes/characters/player_character.tscn")
const METAL_SCENE: PackedScene = preload("res://scenes/vfx/hit_metal_spark.tscn")
const FLESH_SCENE: PackedScene = preload("res://scenes/vfx/hit_flesh.tscn")
const BLOCK_SCENE: PackedScene = preload("res://scenes/vfx/hit_block_wood.tscn")
const PARRY_SCENE: PackedScene = preload("res://scenes/vfx/parry_flash.tscn")
const DUST_SCENE: PackedScene = preload("res://scenes/vfx/dust_kick.tscn")
const TRAIL_SCENE: PackedScene = preload("res://scenes/vfx/weapon_trail.tscn")
const AURA_SCENE: PackedScene = preload("res://scenes/vfx/charge_aura.tscn")

## Dónde está el muñeco (mira hacia +Z, el jugador hacia -Z desde el origen).
const DUMMY_POSITION: Vector3 = Vector3(0.0, 0.0, -1.9)
## Posición de la cámara de la demo y punto al que mira.
const DEMO_CAMERA: Vector3 = Vector3(4.3, 1.55, 0.35)
const DEMO_TARGET: Vector3 = Vector3(0.0, 1.05, -0.95)
## Ticks de espera al principio del guion y antes de repetirlo.
const START_IDLE_TICKS: int = 30
const LOOP_GAP_TICKS: int = 50
## Retraso (s) entre el inicio del golpe activo y el efecto de impacto.
const IMPACT_DELAY: float = 0.07
## Fotogramas en reposo antes de disparar un efecto en los modos de grabación.
const STRIP_WARMUP_FRAMES: int = 40
const STRIP_FRAMES: int = 12
## Tamaño de la ventana de grabación y de cada recorte guardado.
const CAPTURE_WINDOW: Vector2i = Vector2i(1920, 1080)
const CROP_SIZE: Vector2i = Vector2i(640, 480)
## Fotogramas por segundo del modo determinista.
const FPS: float = 60.0

## Configuración de cada grabación: [code]times[/code] (segundos tras el disparo, o [code]step[/code] en
## fotogramas para los que siguen al combate), [code]distance[/code] y [code]height[/code] de la cámara.
const STRIPS: Dictionary = {
	"metal": {"times": [0.017, 0.033, 0.05, 0.067, 0.1, 0.133, 0.18, 0.25, 0.35, 0.5, 0.7, 0.95],
			"distance": 4.6, "side": -1.0},
	"flesh": {"times": [0.017, 0.033, 0.05, 0.083, 0.117, 0.15, 0.2, 0.267, 0.35, 0.45, 0.58, 0.75],
			"distance": 4.4, "side": -1.0},
	"block": {"times": [0.017, 0.033, 0.05, 0.083, 0.117, 0.167, 0.233, 0.317, 0.42, 0.55, 0.7, 0.9],
			"distance": 4.4},
	"parry": {"times": [0.017, 0.033, 0.05, 0.083, 0.117, 0.15, 0.2, 0.267, 0.35, 0.45, 0.58, 0.75],
			"distance": 5.2},
	"dust": {"times": [0.05, 0.1, 0.15, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.95, 1.1], "distance": 4.4},
	"dodge": {"times": [0.05, 0.1, 0.15, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.95, 1.1], "distance": 4.4},
	"trail": {"step": 3, "lead": 0, "distance": 3.6},
	"aura": {"step": 6, "lead": 0, "distance": 5.6},
}
## Pantallas completas del modo [code]showcase[/code] (segundos tras el disparo).
const SHOWCASE_TIMES: Array[float] = [0.05, 0.1, 0.2, 0.4]

var _character: PlayerCharacter
var _dummy: PlayerCharacter
var _visual: HumanoidVisual
var _dummy_visual: HumanoidVisual
var _camera: Camera3D
var _label: Label
var _vfx_root: Node3D
var _pools: Dictionary[StringName, VfxPool] = {}
var _trail: WeaponTrail
var _aura: ChargeAura
var _sword: Node3D
var _script: CombatDemoScript = CombatDemoScript.new()
var _realm: int = 0

var _tick: int = 0
var _frame: int = 0
var _loop_start_tick: int = 0
var _last_action: int = -1
var _swing_active: bool = false
var _swing_count: int = 0
var _charge_start_tick: int = -1
var _pending: Array[Dictionary] = []
var _quit_when_done: bool = true

# Grabación.
var _strip: String = ""
var _out_dir: String = "build/vfx/strips"
var _folder: String = ""
var _strip_dir: String = ""
var _capture_frames: Array[int] = []
var _capture_index: int = 0
var _capture_focus: Vector3 = Vector3.ZERO
var _fire_frame: int = -1
var _pending_shots: int = 0
var _times_log: Array[float] = []
var _combat_driven: bool = false
var _impacts_enabled: bool = true


func _ready() -> void:
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--strip="):
			_strip = arg.trim_prefix("--strip=")
		elif arg.begins_with("--realm="):
			_realm = arg.trim_prefix("--realm=").to_int()
		elif arg.begins_with("--out="):
			_out_dir = arg.trim_prefix("--out=")
		elif arg.begins_with("--folder="):
			_folder = arg.trim_prefix("--folder=")
		elif arg == "--no-quit":
			_quit_when_done = false
	process_priority = 100
	_camera = $Camera3D
	_label = $Overlay/Label
	_character = _spawn_character(Vector3.ZERO, 0.0)
	_visual = HumanoidVisual.install(_character)
	_dummy = _spawn_character(DUMMY_POSITION, PI)
	_dummy_visual = HumanoidVisual.install(_dummy)
	_sword = _find_attachment(_visual, WeaponProps.SWORD_ATTACHMENT)
	_build_effects()
	_camera.global_position = DEMO_CAMERA
	_camera.look_at(DEMO_TARGET, Vector3.UP)
	_combat_driven = _strip.is_empty() or _strip == "trail" or _strip == "aura" or _strip == "showcase"
	# En las grabaciones de la estela y del aura no suenan los demás efectos (no hay impactos que tapen).
	_impacts_enabled = _strip.is_empty() or _strip == "showcase"
	if not _strip.is_empty():
		get_window().size = CAPTURE_WINDOW
		_strip_dir = _resolve_dir(_out_dir).path_join(_folder if not _folder.is_empty() else _strip)
		DirAccess.make_dir_recursive_absolute(_strip_dir)
		_prepare_strip()
	print("[VfxPreview] listo (modo %s, reino %d)" % [_strip if not _strip.is_empty() else "bucle", _realm])


func _physics_process(delta: float) -> void:
	_tick += 1
	var input := PlayerInput.new()
	input.tick = _tick
	input.look_yaw = 0.0
	if _combat_driven:
		var script_tick: int = _tick - _loop_start_tick - START_IDLE_TICKS
		if script_tick >= 0 and script_tick < _script.get_length():
			input.buttons = _script.buttons_at(script_tick)
		elif script_tick >= _script.get_length() + LOOP_GAP_TICKS and _strip.is_empty():
			_restart_script()
	_character.simulate(input.quantized(), delta)
	if _combat_driven:
		_observe_combat()


func _process(delta: float) -> void:
	_frame += 1
	_run_pending(delta)
	_update_aura()
	_update_camera()
	_update_label()
	if not _strip.is_empty():
		_run_capture()


# --- Montaje ----------------------------------------------------------------------------------------

func _spawn_character(position: Vector3, yaw: float) -> PlayerCharacter:
	var character: PlayerCharacter = PLAYER_SCENE.instantiate() as PlayerCharacter
	add_child(character)
	var state := PlayerState.new()
	state.position = position
	state.yaw = yaw
	character.set_state(state)
	character.reset_physics_interpolation()
	return character


func _find_attachment(visual: HumanoidVisual, attachment: StringName) -> Node3D:
	var skeleton: Skeleton3D = visual.get_skeleton()
	if skeleton == null:
		return null
	return skeleton.get_node_or_null(NodePath(attachment)) as Node3D


func _build_effects() -> void:
	_vfx_root = Node3D.new()
	_vfx_root.name = "Vfx"
	add_child(_vfx_root)
	_pools[&"metal"] = _make_pool("PoolMetal", METAL_SCENE, 4)
	_pools[&"flesh"] = _make_pool("PoolFlesh", FLESH_SCENE, 4)
	_pools[&"block"] = _make_pool("PoolBlock", BLOCK_SCENE, 3)
	_pools[&"parry"] = _make_pool("PoolParry", PARRY_SCENE, 2)
	_pools[&"dust"] = _make_pool("PoolDust", DUST_SCENE, 3)
	_pools[&"dust"].set_tint(VfxPalette.dust(_realm))
	_trail = TRAIL_SCENE.instantiate() as WeaponTrail
	_trail.tip_offset = Vector3(1.15, 0.0, 0.0)
	_trail.min_speed = 5.0
	_vfx_root.add_child(_trail)
	_trail.set_realm(_realm)
	_aura = AURA_SCENE.instantiate() as ChargeAura
	_character.add_child(_aura)
	_aura.set_realm(_realm)


func _make_pool(pool_name: String, scene: PackedScene, size: int) -> VfxPool:
	var pool := VfxPool.new()
	pool.name = pool_name
	_vfx_root.add_child(pool)
	pool.setup(scene, size)
	return pool


# --- Combate de la demo -----------------------------------------------------------------------------

func _restart_script() -> void:
	_loop_start_tick = _tick
	_swing_count = 0
	_swing_active = false
	_charge_start_tick = -1
	_last_action = -1
	_trail.clear()
	_aura.reset()
	var state := PlayerState.new()
	state.position = Vector3.ZERO
	state.yaw = 0.0
	_character.set_state(state)
	_character.reset_physics_interpolation()


# Mira el estado de combate del jugador y lanza lo que toca, como lo haría CombatFeedback.
func _observe_combat() -> void:
	var combat: CombatState = _character.combat
	var active: bool = ActionMachine.is_attack_active(combat, _character.last_input_tick)
	if active != _swing_active:
		_swing_active = active
		if active:
			_on_swing_started()
	if combat.action != _last_action:
		_on_action_changed(combat.action, _last_action)
		_last_action = combat.action


func _on_swing_started() -> void:
	if not _impacts_enabled:
		return
	_swing_count += 1
	match _swing_count:
		1:
			_queue(&"metal", IMPACT_DELAY)
		2:
			_queue(&"flesh", IMPACT_DELAY)
		3:
			_queue(&"block", IMPACT_DELAY)
		_:
			_queue(&"flesh", IMPACT_DELAY)
			_queue(&"metal", IMPACT_DELAY + 0.03)


func _on_action_changed(action: int, previous: int) -> void:
	# La estela sigue la espada durante todo el ataque; es su velocidad mínima la que decide el tramo que se
	# pinta (la animación no coincide con la ventana activa de la simulación).
	if _sword != null and (action == CombatState.Action.LIGHT or action == CombatState.Action.HEAVY):
		_trail.begin(_sword)
	elif _sword != null:
		_trail.end()
	match action:
		CombatState.Action.LIGHT:
			if _fire_frame < 0 and _strip == "trail":
				_fire_frame = _frame
				_schedule_frames_from_combat()
		CombatState.Action.CHARGE:
			_charge_start_tick = _tick
			_aura.play()
			if _fire_frame < 0 and _strip == "aura":
				_fire_frame = _frame
				_schedule_frames_from_combat()
		CombatState.Action.BLOCK:
			if _impacts_enabled:
				_queue(&"parry", 0.16)
		CombatState.Action.DODGE:
			if _impacts_enabled:
				_fire(&"dodge")
				_queue(&"dust", 0.5)
	if previous == CombatState.Action.CHARGE and action != CombatState.Action.CHARGE:
		_aura.release()
		_charge_start_tick = -1


func _update_aura() -> void:
	if _charge_start_tick < 0 or not _aura.is_playing():
		return
	var combat: CombatState = _character.combat
	var attack: AttackTicks = CombatCatalog.attack(combat.action_id)
	var full: int = maxi(attack.charge_max_ticks if attack != null else 0, 1)
	if attack != null and attack.charge_max_ticks <= 0:
		full = maxi(attack.charge_min_ticks, 1)
	_aura.set_charge(clampf(float(_tick - _charge_start_tick) / float(full), 0.0, 1.0))


func _queue(effect: StringName, delay: float) -> void:
	_pending.append({"effect": effect, "left": delay})


func _run_pending(delta: float) -> void:
	var index: int = 0
	while index < _pending.size():
		var item: Dictionary = _pending[index]
		item["left"] = float(item["left"]) - delta
		if float(item["left"]) <= 0.0:
			_fire(StringName(item["effect"]))
			_pending.remove_at(index)
		else:
			index += 1


# Dispara un efecto en su sitio (el del muñeco, el de los pies del jugador...).
func _fire(effect: StringName) -> void:
	var toward_player: Vector3 = Vector3(0.0, 0.12, 1.0).normalized()
	match effect:
		&"metal":
			var blade: Vector3 = _dummy_point(WeaponProps.SWORD_ATTACHMENT, Vector3(0.55, 0.0, 0.0),
					Vector3(0.0, 1.25, DUMMY_POSITION.z + 0.35))
			_pools[&"metal"].spawn(blade, Vector3(0.25, 0.25, 1.0).normalized())
		&"flesh":
			_pools[&"flesh"].spawn(DUMMY_POSITION + Vector3(0.02, 1.32, 0.2), toward_player)
		&"block":
			var shield: Vector3 = _dummy_point(WeaponProps.SHIELD_ATTACHMENT, Vector3(0.0, 0.0, -0.1),
					Vector3(0.2, 1.1, DUMMY_POSITION.z + 0.3))
			_pools[&"block"].spawn(shield, toward_player)
		&"parry":
			_pools[&"parry"].spawn(Vector3(0.1, 1.3, DUMMY_POSITION.z * 0.5 - 0.05), toward_player)
		&"dust":
			var kick: DustKick = _pools[&"dust"].acquire() as DustKick
			if kick != null:
				kick.play_landing(_character.global_position, 1.0)
		&"dodge":
			var dodge_kick: DustKick = _pools[&"dust"].acquire() as DustKick
			if dodge_kick != null:
				# La esquiva del guion es hacia atrás (+Z): el polvo sale hacia el muñeco.
				dodge_kick.play_dodge(_character.global_position, Vector3(0.0, 0.0, 1.0), 1.0)


func _dummy_point(attachment: StringName, local_offset: Vector3, fallback: Vector3) -> Vector3:
	var node: Node3D = _find_attachment(_dummy_visual, attachment)
	if node == null:
		return fallback
	return node.global_transform * local_offset


# --- Cámara y rótulo --------------------------------------------------------------------------------

func _update_camera() -> void:
	if _strip.is_empty() or _strip == "showcase":
		return
	var config: Dictionary = STRIPS.get(_strip, {})
	var distance: float = float(config.get("distance", 3.2))
	var focus: Vector3 = _capture_focus
	# Cámara al costado del punto de interés (lado +X), algo elevada y adelantada hacia el jugador.
	if _strip == "trail" or _strip == "aura":
		# Sigue al jugador (los ataques lo adelantan) y el recorte también.
		focus = _character.global_position + Vector3(0.0, 1.1, 0.0)
		_capture_focus = focus
		_camera.global_position = _character.global_position + Vector3(distance * 0.75, 1.55, -distance * 0.7)
	else:
		# Tres cuartos desde el lado indicado (+1 el del escudo del muñeco, -1 el de su espada).
		var side: float = float(config.get("side", 1.0))
		_camera.global_position = focus + Vector3(side * distance * 0.5, 0.2, distance * 0.85)
	_camera.look_at(focus, Vector3.UP)


func _update_label() -> void:
	var text: String = "ART-09  efectos de golpe"
	if _strip.is_empty():
		text += "\nacción %s  golpe %d" % [CombatState.Action.keys()[_character.combat.action], _swing_count]
	else:
		text += "\nmodo %s  fotograma %d" % [_strip, _frame]
	_label.text = text


# --- Grabación --------------------------------------------------------------------------------------

func _prepare_strip() -> void:
	_label.visible = false
	var config: Dictionary = STRIPS.get(_strip, {})
	match _strip:
		"metal":
			_capture_focus = _dummy_point(WeaponProps.SWORD_ATTACHMENT, Vector3(0.55, 0.0, 0.0),
					Vector3(0.0, 1.25, DUMMY_POSITION.z + 0.35))
		"flesh":
			_capture_focus = DUMMY_POSITION + Vector3(0.02, 1.32, 0.2)
		"block":
			_capture_focus = _dummy_point(WeaponProps.SHIELD_ATTACHMENT, Vector3(0.0, 0.0, -0.1),
					Vector3(0.2, 1.1, DUMMY_POSITION.z + 0.3))
		"parry":
			_capture_focus = Vector3(0.1, 1.3, DUMMY_POSITION.z * 0.5 - 0.05)
		"dust", "dodge":
			_capture_focus = Vector3(0.0, 0.3, 0.0)
		"trail", "aura":
			_capture_focus = Vector3(0.0, 1.1, 0.0)
		"showcase":
			_capture_focus = DEMO_TARGET
		_:
			push_warning("[VfxPreview] Grabación desconocida: %s" % _strip)
			get_tree().quit(1)
			return
	# La cámara de la estela y del aura mira al jugador desde delante: el muñeco se interpondría.
	if _strip == "trail" or _strip == "aura":
		_dummy.visible = false
	if config.has("times"):
		_fire_frame = STRIP_WARMUP_FRAMES
		for time: float in config["times"]:
			_capture_frames.append(_fire_frame + roundi(time * FPS))
	elif _strip == "showcase":
		_fire_frame = STRIP_WARMUP_FRAMES
		for time: float in SHOWCASE_TIMES:
			_capture_frames.append(_fire_frame + roundi(time * FPS))


# El modo "trail" y el "aura" siguen al combate: los fotogramas salen del primer golpe activo o de la
# primera carga.
func _schedule_frames_from_combat() -> void:
	var config: Dictionary = STRIPS[_strip]
	var step: int = int(config["step"])
	var lead: int = int(config["lead"])
	for index: int in STRIP_FRAMES:
		_capture_frames.append(_frame - lead + index * step)


func _run_capture() -> void:
	if _strip != "trail" and _strip != "aura" and _frame == _fire_frame and _strip != "":
		if _strip == "showcase":
			for effect: StringName in [&"metal", &"flesh", &"block", &"parry"]:
				_fire(effect)
			_fire(&"dust")
		else:
			_fire(StringName(_strip))
	while _capture_index < _capture_frames.size() and _frame >= _capture_frames[_capture_index]:
		var index: int = _capture_index
		_capture_index += 1
		_times_log.append(float(_frame - maxi(_fire_frame, 0)) / FPS)
		_capture_shot(index)
	if _capture_frames.size() > 0 and _capture_index >= _capture_frames.size() and _pending_shots == 0:
		_finish_capture()


func _capture_shot(index: int) -> void:
	_pending_shots += 1
	await RenderingServer.frame_post_draw
	var image: Image = get_viewport().get_texture().get_image()
	if image != null and not image.is_empty():
		if _strip != "showcase":
			image = _crop_around_focus(image)
		image.save_png(_strip_dir.path_join("frame_%02d.png" % index))
	_pending_shots -= 1


# Recorte de [constant CROP_SIZE] (proporción de la pantalla) centrado en el punto de interés.
func _crop_around_focus(image: Image) -> Image:
	var focus_world: Vector3 = _capture_focus
	var screen: Vector2 = _camera.unproject_position(focus_world)
	var ratio: float = float(image.get_height()) / float(CAPTURE_WINDOW.y)
	var crop: Vector2i = Vector2i(roundi(CROP_SIZE.x * ratio), roundi(CROP_SIZE.y * ratio))
	var origin: Vector2i = Vector2i(roundi(screen.x) - crop.x / 2, roundi(screen.y) - crop.y / 2)
	origin.x = clampi(origin.x, 0, maxi(image.get_width() - crop.x, 0))
	origin.y = clampi(origin.y, 0, maxi(image.get_height() - crop.y, 0))
	return image.get_region(Rect2i(origin, crop))


func _finish_capture() -> void:
	var meta: Dictionary = {"strip": _strip, "realm": _realm, "times": _times_log,
			"fps": FPS, "frames": _capture_frames}
	var file: FileAccess = FileAccess.open(_strip_dir.path_join("meta.json"), FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(meta, "\t"))
		file.close()
	print("[VfxPreview] %d fotogramas en %s" % [_capture_frames.size(), _strip_dir])
	_capture_frames.clear()
	if _quit_when_done:
		get_tree().quit()


static func _resolve_dir(path: String) -> String:
	path = path.strip_edges().trim_prefix("\"").trim_suffix("\"").replace("\\", "/")
	if path.begins_with("res://") or path.begins_with("user://"):
		return ProjectSettings.globalize_path(path)
	if path.is_relative_path():
		return ProjectSettings.globalize_path("res://").path_join(path)
	return path
