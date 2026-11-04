extends Node3D
## Hit effects preview (ART-09; development tool, client only).
##
## A [PlayerCharacter] with the animated humanoid, the placeholder sword and shield and a dummy in front
## (another humanoid standing still). The player loops the demo's combat script ([CombatDemoScript],
## through the real simulation): three light attacks, a charged heavy attack, a block and a dodge. Each
## action triggers its effect as combat would once connected (the effects are NOT connected to combat:
## here this scene does it by watching the state):
## [br]- [b]Trail[/b] of the sword ([WeaponTrail]) while the hit's active window lasts.
## [br]- [b]Light 1[/b]: metal spark on the dummy's sword. [b]Light 2[/b]: impact on flesh (on cloth on
## the odd loops of the video). [b]Light 3[/b]: blocked impact on its wooden shield. [b]Heavy[/b]: flesh
## and metal at once.
## [br]- [b]Heavy attack charge[/b]: aura on the sword ([ChargeAura]) that grows with the charge, a pulse
## on completing it and a burst on release.
## [br]- [b]Block[/b]: perfect parry between the two. [b]Dodge[/b]: dust backward and, on landing, the
## landing dust.
## [br][br]
## [b]Two stages and two cameras.[/b] By default, a plain gray floor and a demo camera (40 degree field
## of view at about 4.4 m: good for seeing detail up close). With [code]--field[/code] the characters
## fight in Vardheim's camp in Vado Gris, on its terrain, with its sun, its shadows and its fog; with
## [code]--camera=game[/code] the camera is the game's [CameraRig] (72 degree field of view, over the
## shoulder, at the game distance), which is what the real player sees.
## [br][br]
## Usage (window; [code]--fixed-fps 60[/code] makes execution deterministic, one tick per frame):
## [codeblock]
## godot --path . res://scenes/tests/vfx_preview.tscn --fixed-fps 60 -- \
##     [--strip=metal|metal_side|flesh|cloth|block|parry|dust|dust_soft|dodge|trail|aura|showcase|melee] \
##     [--realm=0..4] [--ground=dirt|stone|sand|...] [--field] [--camera=demo|game] [--shade] \
##     [--out=build/vfx/strips] [--folder=<name>] [--no-quit] [--reel=60] [--bench]
## [/codeblock]
## [br]- Without [code]--strip[/code]: demo loop, without closing.
## [br]- [code]--strip=<effect>[/code]: records twelve frames cropped around the effect in
## [code]<out>/<effect>/frame_NN.png[/code] and a [code]meta.json[/code] with their timings
## ([code]tools/vfx/compose_strips.py[/code] joins them into a sheet). [code]showcase[/code] fires them
## all at once and saves four full screens; [code]melee[/code] fires ten effects at once.
## [br]- [code]--shade[/code]: the stage is the shadow of a roof (which only casts shadow): a test that
## dust and puffs darken in the shade.
## [br]- [code]--reel=<seconds>[/code]: the demo loop with the four realms, a stretch in the shade and a
## melee, and it closes after [code]<seconds>[/code] (to record it with [code]--write-movie[/code]).
## [br]- [code]--bench[/code]: measures the cost of a ten-effect melee (draw calls, objects, primitives,
## GPU and CPU) against the same scenario without effects and writes it to [code]<out>/bench.json[/code].
## [br]- [code]--realm=<n>[/code]: realm for the color of the trail and the aura (1 Vardheim, 2 Solmarch,
## 3 Askarra, 4 Eldrun, 0 neutral). [code]--ground=<material>[/code]: the ground for the dust when it is
## not read from the terrain.
## [br]- [code]--folder=<name>[/code]: subfolder of the recording (by default, the effect's name).
## [br]- [code]--out=<folder>[/code]: output folder (by default [code]build/vfx/strips[/code], relative to
## the project root).

const PLAYER_SCENE: PackedScene = preload("res://scenes/characters/player_character.tscn")
const CAMERA_RIG_SCENE: PackedScene = preload("res://scenes/client/camera_rig.tscn")
const METAL_SCENE: PackedScene = preload("res://scenes/vfx/hit_metal_spark.tscn")
const FLESH_SCENE: PackedScene = preload("res://scenes/vfx/hit_flesh.tscn")
const CLOTH_SCENE: PackedScene = preload("res://scenes/vfx/hit_cloth.tscn")
const BLOCK_SCENE: PackedScene = preload("res://scenes/vfx/hit_block_wood.tscn")
const PARRY_SCENE: PackedScene = preload("res://scenes/vfx/parry_flash.tscn")
const DUST_SCENE: PackedScene = preload("res://scenes/vfx/dust_kick.tscn")
const TRAIL_SCENE: PackedScene = preload("res://scenes/vfx/weapon_trail.tscn")
const AURA_SCENE: PackedScene = preload("res://scenes/vfx/charge_aura.tscn")
const ZONE_SCENE_PATH: String = "res://scenes/world/zones/vado_gris/vado_gris.tscn"
const TERRAIN_ASSETS_PATH: String = "res://scenes/world/zones/vado_gris/vado_gris_terrain_assets.tres"

## Vardheim's camp in Vado Gris: a flat clearing (the height is read from the terrain).
const FIELD_CENTER: Vector3 = Vector3(0.0, 6.2, -128.0)
## Where the shaded stage lies relative to the sunlit one (the roof that casts the shadow is not visible).
const SHADE_OFFSET: Vector3 = Vector3(12.0, 0.0, 0.0)
const ROOF_HEIGHT: float = 3.4
const ROOF_SIZE: float = 12.0
## Pitch of the game camera relative to the horizontal (rad; negative looks downward).
const GAME_PITCH: float = -0.12
## Frames to wait on the terrain before dropping the characters (its collision is built at startup).
const FIELD_SETTLE_FRAMES: int = 30

## Where the dummy is relative to the player (it faces +Z, the player faces -Z from the origin).
const DUMMY_POSITION: Vector3 = Vector3(0.0, 0.0, -1.9)
## Position of the demo camera and the point it looks at.
const DEMO_CAMERA: Vector3 = Vector3(4.3, 1.55, 0.35)
const DEMO_TARGET: Vector3 = Vector3(0.0, 1.05, -0.95)
## Ticks to wait at the start of the script and before repeating it.
const START_IDLE_TICKS: int = 30
const LOOP_GAP_TICKS: int = 50
## Delay (s) between the start of the active hit and the impact effect.
const IMPACT_DELAY: float = 0.07
## Margin (ticks) of the trail window relative to the hit's active window.
const TRAIL_LEAD_TICKS: int = 4
const TRAIL_TAIL_TICKS: int = 2
## Idle frames before firing an effect in the recording modes.
const STRIP_WARMUP_FRAMES: int = 40
const STRIP_FRAMES: int = 12
## Size of the recording window.
const CAPTURE_WINDOW: Vector2i = Vector2i(1920, 1080)
## Size of each saved crop depending on the camera.
const CROP_DEMO: Vector2i = Vector2i(640, 480)
const CROP_GAME: Vector2i = Vector2i(640, 360)
const CROP_GAME_WIDE: Vector2i = Vector2i(960, 540)
## Frames per second of deterministic mode.
const FPS: float = 60.0
## Direction of the slash when there is no real hit to provide it (standalone recordings): right to left
## and downward, like the first light attack.
const DEFAULT_BLOW: Vector3 = Vector3(-0.8, -0.45, -0.35)

## Configuration of each recording: [code]times[/code] (seconds after the trigger, or [code]step[/code] in
## frames for those that follow combat), [code]distance[/code] and [code]height[/code] of the demo
## camera, [code]side[/code] (side from which it is viewed) and [code]wide[/code] (large crop on the game
## camera).
const STRIPS: Dictionary = {
	"metal": {"times": [0.017, 0.033, 0.05, 0.067, 0.1, 0.133, 0.18, 0.25, 0.35, 0.5, 0.7, 0.85],
			"distance": 4.6, "side": -1.0},
	"metal_side": {"times": [0.017, 0.033, 0.05, 0.067, 0.1, 0.133, 0.18, 0.25, 0.35, 0.5, 0.7, 0.85],
			"distance": 4.2, "side": -1.0, "profile": true},
	"flesh": {"times": [0.017, 0.033, 0.05, 0.067, 0.083, 0.1, 0.117, 0.133, 0.167, 0.2, 0.267, 0.35],
			"distance": 3.2, "side": -1.0},
	"cloth": {"times": [0.017, 0.033, 0.05, 0.083, 0.117, 0.15, 0.2, 0.267, 0.35, 0.45, 0.55, 0.65],
			"distance": 3.6, "side": -1.0},
	"block": {"times": [0.017, 0.033, 0.05, 0.067, 0.1, 0.133, 0.167, 0.2, 0.267, 0.35, 0.45, 0.58],
			"distance": 4.4},
	"parry": {"times": [0.017, 0.033, 0.05, 0.067, 0.083, 0.1, 0.117, 0.15, 0.183, 0.217, 0.267, 0.35],
			"distance": 5.2},
	"dust": {"times": [0.05, 0.1, 0.15, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9, 1.0], "distance": 4.4},
	"dust_soft": {"times": [0.05, 0.1, 0.15, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9, 1.0], "distance": 4.4},
	"dodge": {"times": [0.05, 0.1, 0.15, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9, 1.0], "distance": 4.4},
	"trail": {"step": 1, "lead": 0, "distance": 3.6, "wide": true},
	"aura": {"step": 6, "lead": 0, "distance": 5.6, "wide": true},
	"melee": {"times": [0.033, 0.083, 0.133, 0.2, 0.267, 0.35, 0.45, 0.55, 0.7, 0.85, 1.0, 1.2],
			"distance": 5.0, "wide": true},
}
## Full screens of [code]showcase[/code] mode (seconds after the trigger).
const SHOWCASE_TIMES: Array[float] = [0.05, 0.1, 0.2, 0.4]
## Frames of the measurement ([code]--bench[/code]): warm-up, baseline and with the melee.
const BENCH_WARMUP: int = 90
const BENCH_BASELINE: int = 90
const BENCH_BURST: int = 60

var _character: PlayerCharacter
var _dummy: PlayerCharacter
var _visual: HumanoidVisual
var _dummy_visual: HumanoidVisual
var _camera: Camera3D
var _rig: CameraRig
var _label: Label
var _vfx_root: Node3D
var _pools: Dictionary[StringName, VfxPool] = {}
var _trail: WeaponTrail
var _aura: ChargeAura
var _sword: Node3D
var _script: CombatDemoScript = CombatDemoScript.new()
var _realm: int = 0
var _ground_kind: StringName = &"dirt"

# Stage.
var _field: bool = false
var _game_camera: bool = false
var _shade: bool = false
var _origin: Vector3 = Vector3.ZERO
var _sun_origin: Vector3 = Vector3.ZERO
var _terrain: Node = null
var _terrain_assets: Resource = null
var _sun: DirectionalLight3D = null
var _in_shade: bool = false

var _tick: int = 0
var _frame: int = 0
var _loop_start_tick: int = 0
var _loop_index: int = 0
var _last_action: int = -1
var _swing_active: bool = false
var _trail_window: bool = false
var _swing_count: int = 0
var _charge_start_tick: int = -1
var _pending: Array[Dictionary] = []
var _quit_when_done: bool = true
var _tip_velocity: Vector3 = Vector3.ZERO
var _last_tip: Vector3 = Vector3.ZERO
var _has_tip: bool = false

# Recording.
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

# Video, melee and measurement.
var _reel_length: float = 0.0
var _reel_time: float = 0.0
var _reel_stage: int = 0
var _next_melee: float = 0.0
var _bench: bool = false
var _bench_phase: int = 0
var _bench_frames: int = 0
var _bench_samples: Array[Dictionary] = []
var _bench_results: Dictionary = {}


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
		elif arg.begins_with("--ground="):
			_ground_kind = StringName(arg.trim_prefix("--ground="))
		elif arg.begins_with("--camera="):
			_game_camera = arg.trim_prefix("--camera=") == "game"
		elif arg.begins_with("--reel="):
			_reel_length = arg.trim_prefix("--reel=").to_float()
		elif arg == "--field":
			_field = true
		elif arg == "--shade":
			_shade = true
			_field = true
		elif arg == "--bench":
			_bench = true
			_field = true
			_game_camera = true
		elif arg == "--no-quit":
			_quit_when_done = false
	if _reel_length > 0.0:
		_field = true
		_game_camera = true
		_realm = 1
	process_priority = 100
	_label = $Overlay/Label
	if _field:
		_build_field()
	_character = _spawn_character(_w(Vector3.ZERO), 0.0)
	_visual = HumanoidVisual.install(_character)
	_dummy = _spawn_character(_w(DUMMY_POSITION), PI)
	_dummy_visual = HumanoidVisual.install(_dummy)
	_sword = _find_attachment(_visual, WeaponProps.SWORD_ATTACHMENT)
	_build_effects()
	_setup_camera()
	_combat_driven = _strip.is_empty() or _strip == "trail" or _strip == "aura" or _strip == "showcase"
	# In the trail and aura recordings the other effects do not play (so no impacts cover them).
	_impacts_enabled = _strip.is_empty() or _strip == "showcase"
	if _bench:
		_combat_driven = false
		_impacts_enabled = false
	if _field:
		# The terrain collision is built at startup: until then nobody falls.
		set_physics_process(false)
	if not _strip.is_empty():
		get_window().size = CAPTURE_WINDOW
		_strip_dir = _resolve_dir(_out_dir).path_join(_folder if not _folder.is_empty() else _strip)
		DirAccess.make_dir_recursive_absolute(_strip_dir)
		_prepare_strip()
	if _bench:
		_label.visible = false
		get_window().size = CAPTURE_WINDOW
		RenderingServer.viewport_set_measure_render_time(get_viewport().get_viewport_rid(), true)
	if _reel_length > 0.0:
		_label.visible = false
	print("[VfxPreview] listo (modo %s, reino %d, %s, %s)" % [
			_strip if not _strip.is_empty() else "bucle", _realm,
			"terreno" if _field else "suelo liso", "cámara del juego" if _game_camera else "cámara de demostración"])


func _physics_process(delta: float) -> void:
	_tick += 1
	var input := PlayerInput.new()
	input.tick = _tick
	input.look_yaw = 0.0
	if _combat_driven:
		var script_tick: int = _tick - _loop_start_tick - START_IDLE_TICKS
		if script_tick >= 0 and script_tick < _script.get_length():
			input.buttons = _script.buttons_at(script_tick)
		elif script_tick >= _script.get_length() + LOOP_GAP_TICKS and (_strip.is_empty() or _reel_length > 0.0):
			_restart_script()
	_character.simulate(input.quantized(), delta)
	if _combat_driven:
		_observe_combat()


func _process(delta: float) -> void:
	_frame += 1
	if _field and not is_physics_processing() and _frame >= FIELD_SETTLE_FRAMES:
		set_physics_process(true)
	_track_tip(delta)
	_run_pending(delta)
	_update_aura()
	_update_camera()
	_update_label()
	if not _strip.is_empty():
		_run_capture()
	if _reel_length > 0.0:
		_run_reel(delta)
	if _bench:
		_run_bench()


# --- Setup ------------------------------------------------------------------------------------------

# World position of a point on the stage (the stage can move: sunlit or shaded).
func _w(local: Vector3) -> Vector3:
	return _origin + local


# Loads Vado Gris (terrain, sun, shadows, fog) instead of the plain floor and sets the stage's center.
func _build_field() -> void:
	for node_name: String in ["Floor", "Sun", "WorldEnvironment"]:
		var node: Node = get_node_or_null(NodePath(node_name))
		if node != null:
			node.queue_free()
	var zone: Node3D = (load(ZONE_SCENE_PATH) as PackedScene).instantiate() as Node3D
	zone.name = "Zone"
	add_child(zone)
	_terrain = zone.get_node_or_null(^"Terrain3D")
	_sun = zone.get_node_or_null(^"Sun") as DirectionalLight3D
	_terrain_assets = load(TERRAIN_ASSETS_PATH) as Resource
	var ground: float = FIELD_CENTER.y
	if _terrain != null and _terrain.get(&"data") != null:
		var data: Object = _terrain.get(&"data") as Object
		ground = float(data.call(&"get_height", FIELD_CENTER))
	_sun_origin = Vector3(FIELD_CENTER.x, ground + 0.03, FIELD_CENTER.z)
	_origin = _sun_origin
	_add_shade_roof()
	if _shade:
		_in_shade = true
		_origin = _sun_origin + SHADE_OFFSET


# A roof that only casts shadow (not visible) over the shaded stage: the sun's shadow falls right where
# the fight happens, like that of a wall or a large tree.
func _add_shade_roof() -> void:
	var to_sun: Vector3 = Vector3(-0.6, 0.6, 0.5).normalized()
	if _sun != null:
		to_sun = _sun.global_transform.basis.z.normalized()
	var center: Vector3 = _sun_origin + SHADE_OFFSET
	var roof := MeshInstance3D.new()
	roof.name = "ShadeRoof"
	var box := BoxMesh.new()
	box.size = Vector3(ROOF_SIZE, 0.12, ROOF_SIZE)
	roof.mesh = box
	roof.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY
	add_child(roof)
	roof.global_position = center + to_sun * (ROOF_HEIGHT / maxf(to_sun.y, 0.1))


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
	_pools[&"metal"] = _make_pool("PoolMetal", METAL_SCENE, 6)
	_pools[&"flesh"] = _make_pool("PoolFlesh", FLESH_SCENE, 6)
	_pools[&"cloth"] = _make_pool("PoolCloth", CLOTH_SCENE, 4)
	_pools[&"block"] = _make_pool("PoolBlock", BLOCK_SCENE, 4)
	_pools[&"parry"] = _make_pool("PoolParry", PARRY_SCENE, 3)
	_pools[&"dust"] = _make_pool("PoolDust", DUST_SCENE, 4)
	_trail = TRAIL_SCENE.instantiate() as WeaponTrail
	_trail.tip_offset = Vector3(1.15, 0.0, 0.0)
	_trail.min_speed = 3.0
	_vfx_root.add_child(_trail)
	_trail.set_realm(_realm)
	_aura = AURA_SCENE.instantiate() as ChargeAura
	_character.add_child(_aura)
	_aura.set_realm(_realm)
	_aura.set_weapon(_sword)


func _make_pool(pool_name: String, scene: PackedScene, size: int) -> VfxPool:
	var pool := VfxPool.new()
	pool.name = pool_name
	_vfx_root.add_child(pool)
	pool.setup(scene, size)
	return pool


# The camera: the demo one (the scene's) or the game's [CameraRig], which follows the player.
func _setup_camera() -> void:
	var demo_camera: Camera3D = $Camera3D
	if _game_camera:
		demo_camera.current = false
		demo_camera.queue_free()
		_rig = CAMERA_RIG_SCENE.instantiate() as CameraRig
		_rig.set_scripted_look(true)
		add_child(_rig)
		_rig.set_target(_character.get_camera_target(), _character)
		_rig.set_hide_when_close(_character.get_node_or_null(^"Visual") as Node3D)
		_rig.set_look(0.0, GAME_PITCH)
		_camera = _rig.get_camera()
		_camera.make_current()
	else:
		_camera = demo_camera
		_camera.global_position = DEMO_CAMERA + _origin
		_camera.look_at(DEMO_TARGET + _origin, Vector3.UP)


# Places the two characters again on the sunlit stage or the shaded one.
func _move_stage(shade: bool) -> void:
	_in_shade = shade
	_origin = _sun_origin + (SHADE_OFFSET if shade else Vector3.ZERO)
	for pair: Array in [[_character, Vector3.ZERO, 0.0], [_dummy, DUMMY_POSITION, PI]]:
		var character: PlayerCharacter = pair[0] as PlayerCharacter
		var state := PlayerState.new()
		state.position = _w(pair[1] as Vector3)
		state.yaw = float(pair[2])
		character.set_state(state)
		character.reset_physics_interpolation()
	_trail.clear()
	_aura.reset()
	_restart_script()


# --- Demo combat ------------------------------------------------------------------------------------

func _restart_script() -> void:
	_loop_start_tick = _tick
	_loop_index += 1
	_swing_count = 0
	_swing_active = false
	_trail_window = false
	_charge_start_tick = -1
	_last_action = -1
	_trail.clear()
	_aura.reset()
	if _reel_length > 0.0:
		# Each loop of the video, another realm (trail and aura).
		_realm = 1 + (_loop_index % 4)
		_trail.set_realm(_realm)
		_aura.set_realm(_realm)
	var state := PlayerState.new()
	state.position = _w(Vector3.ZERO)
	state.yaw = 0.0
	_character.set_state(state)
	_character.reset_physics_interpolation()


# Velocity of the sword's tip: gives the slash direction to the impact effects.
func _track_tip(delta: float) -> void:
	if _sword == null or delta <= 0.0:
		return
	var tip: Vector3 = _sword.global_transform * Vector3(1.15, 0.0, 0.0)
	if _has_tip:
		_tip_velocity = _tip_velocity.lerp((tip - _last_tip) / delta, 0.6)
	_last_tip = tip
	_has_tip = true


# The blow's direction: the sword tip's if it is moving fast, [constant DEFAULT_BLOW]'s if not.
func _blow_direction() -> Vector3:
	if _tip_velocity.length() > 2.0:
		return _tip_velocity.normalized()
	return DEFAULT_BLOW.normalized()


# Looks at the player's combat state and launches what is due, as CombatFeedback would.
func _observe_combat() -> void:
	var combat: CombatState = _character.combat
	var active: bool = ActionMachine.is_attack_active(combat, _character.last_input_tick)
	if active != _swing_active:
		_swing_active = active
		if active:
			_on_swing_started()
	var window: bool = _trail_window_open(combat)
	if window != _trail_window:
		_trail_window = window
		_on_trail_window_changed(window)
	if combat.action != _last_action:
		_on_action_changed(combat.action, _last_action)
		_last_action = combat.action


# The trail window: the hit's active window with a margin. The attack animation reaches its fast sweep a
# few ticks BEFORE the simulation's window opens (the clips are not tuned to the ticks, docs/calidad.md,
# section 1), so it opens [constant TRAIL_LEAD_TICKS] earlier and closes [constant TRAIL_TAIL_TICKS]
# later; outside of it (anticipation and recovery) there is no trail. When the clips carry a sweep
# marker, that marker replaces the margin.
func _trail_window_open(combat: CombatState) -> bool:
	if combat.action != CombatState.Action.LIGHT and combat.action != CombatState.Action.HEAVY:
		return false
	var attack: AttackTicks = CombatCatalog.attack(combat.action_id)
	if attack == null:
		return false
	var relative: int = _character.last_input_tick - combat.action_tick
	return relative >= attack.active_from() - TRAIL_LEAD_TICKS and relative < attack.active_to() + TRAIL_TAIL_TICKS


func _on_trail_window_changed(open: bool) -> void:
	if open:
		if _sword != null:
			_trail.begin(_sword)
		if _fire_frame < 0 and _strip == "trail":
			_fire_frame = _frame
			_schedule_frames_from_combat()
	else:
		_trail.end()


func _on_swing_started() -> void:
	if not _impacts_enabled:
		return
	_swing_count += 1
	match _swing_count:
		1:
			_queue(&"metal", IMPACT_DELAY)
		2:
			# In the video, the odd loops hit cloth.
			_queue(&"cloth" if (_reel_length > 0.0 and _loop_index % 2 == 1) else &"flesh", IMPACT_DELAY)
		3:
			_queue(&"block", IMPACT_DELAY)
		_:
			_queue(&"flesh", IMPACT_DELAY)
			_queue(&"metal", IMPACT_DELAY + 0.03)


func _on_action_changed(action: int, previous: int) -> void:
	match action:
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


# Fires an effect in its place (the dummy's, the player's feet's...). [param jitter] offsets the impact
# point (the melee spreads the effects over the dummy's body).
func _fire(effect: StringName, jitter: Vector3 = Vector3.ZERO) -> void:
	var toward_player: Vector3 = Vector3(0.0, 0.12, 1.0).normalized()
	var blow: Vector3 = _blow_direction()
	match effect:
		&"metal":
			var blade: Vector3 = _dummy_point(WeaponProps.SWORD_ATTACHMENT, Vector3(0.55, 0.0, 0.0),
					_w(Vector3(0.0, 1.25, DUMMY_POSITION.z + 0.35)))
			_pools[&"metal"].spawn(blade + jitter, Vector3(0.25, 0.25, 1.0).normalized(), blow)
		&"flesh":
			_pools[&"flesh"].spawn(_w(DUMMY_POSITION + Vector3(0.02, 1.32, 0.2)) + jitter, toward_player, blow)
		&"cloth":
			_pools[&"cloth"].spawn(_w(DUMMY_POSITION + Vector3(0.0, 1.0, 0.22)) + jitter, toward_player, blow)
		&"block":
			var shield: Vector3 = _dummy_point(WeaponProps.SHIELD_ATTACHMENT, Vector3(0.0, 0.0, -0.1),
					_w(Vector3(0.2, 1.1, DUMMY_POSITION.z + 0.3)))
			_pools[&"block"].spawn(shield + jitter, toward_player)
		&"parry":
			_pools[&"parry"].spawn(_w(Vector3(0.1, 1.3, DUMMY_POSITION.z * 0.5 - 0.05)) + jitter, toward_player)
		&"dust":
			_fire_dust(false, 1.0, jitter)
		&"dust_soft":
			_fire_dust(false, 0.4, jitter)
		&"dodge":
			_fire_dust(true, 1.0, jitter)


func _fire_dust(dodge: bool, strength: float, jitter: Vector3) -> void:
	var kick: DustKick = _pools[&"dust"].acquire() as DustKick
	if kick == null:
		return
	var feet: Vector3 = _character.global_position + jitter
	kick.set_ground_color(VfxGround.color_at(_terrain, feet, _ground_kind, _terrain_assets))
	if dodge:
		# The script's dodge is backward (+Z): the dust goes toward the dummy.
		kick.play_dodge(feet, Vector3(0.0, 0.0, 1.0), strength)
	else:
		kick.play_landing(feet, strength)


func _dummy_point(attachment: StringName, local_offset: Vector3, fallback: Vector3) -> Vector3:
	var node: Node3D = _find_attachment(_dummy_visual, attachment)
	if node == null:
		return fallback
	return node.global_transform * local_offset


# Ten effects at once spread over the dummy and the player's feet: the budget's melee.
func _fire_melee() -> void:
	var spread: Array[Vector3] = [
		Vector3(0.3, 0.1, 0.0), Vector3(-0.3, -0.1, 0.05), Vector3(0.0, 0.25, -0.05), Vector3(0.25, -0.3, 0.0),
		Vector3(-0.2, 0.2, 0.0), Vector3(0.1, -0.1, 0.0),
	]
	for index: int in 3:
		_fire(&"metal", spread[index])
	for index: int in 2:
		_fire(&"flesh", spread[3 + index])
	_fire(&"cloth", spread[5])
	for index: int in 2:
		_fire(&"block", spread[index] * 0.6)
	_fire(&"parry")
	_fire(&"dust")


# --- Camera and label -------------------------------------------------------------------------------

func _update_camera() -> void:
	if _game_camera or _strip.is_empty() or _strip == "showcase":
		return
	var config: Dictionary = STRIPS.get(_strip, {})
	var distance: float = float(config.get("distance", 3.2))
	var focus: Vector3 = _capture_focus
	# Camera at the side of the point of interest (+X side), slightly raised and forward toward the player.
	if _strip == "trail" or _strip == "aura":
		# Follows the player (attacks move them forward) and so does the crop.
		focus = _character.global_position + Vector3(0.0, 1.1, 0.0)
		_capture_focus = focus
		_camera.global_position = _character.global_position + Vector3(distance * 0.75, 1.55, -distance * 0.7)
	else:
		# Three-quarter view from the indicated side (+1 the dummy's shield side, -1 its sword side), or in profile.
		var side: float = float(config.get("side", 1.0))
		if bool(config.get("profile", false)):
			_camera.global_position = focus + Vector3(side * distance, 0.1, 0.0)
		else:
			_camera.global_position = focus + Vector3(side * distance * 0.5, 0.2, distance * 0.85)
	_camera.look_at(focus, Vector3.UP)


func _update_label() -> void:
	var text: String = "ART-09  efectos de golpe"
	if _strip.is_empty():
		text += "\nacción %s  golpe %d" % [CombatState.Action.keys()[_character.combat.action], _swing_count]
	else:
		text += "\nmodo %s  fotograma %d" % [_strip, _frame]
	_label.text = text


# --- Recording --------------------------------------------------------------------------------------

func _prepare_strip() -> void:
	_label.visible = false
	var config: Dictionary = STRIPS.get(_strip, {})
	match _strip:
		"metal", "metal_side":
			_capture_focus = _dummy_point(WeaponProps.SWORD_ATTACHMENT, Vector3(0.55, 0.0, 0.0),
					_w(Vector3(0.0, 1.25, DUMMY_POSITION.z + 0.35)))
		"flesh":
			_capture_focus = _w(DUMMY_POSITION + Vector3(0.02, 1.32, 0.2))
		"cloth":
			_capture_focus = _w(DUMMY_POSITION + Vector3(0.0, 1.0, 0.22))
		"block":
			_capture_focus = _dummy_point(WeaponProps.SHIELD_ATTACHMENT, Vector3(0.0, 0.0, -0.1),
					_w(Vector3(0.2, 1.1, DUMMY_POSITION.z + 0.3)))
		"parry":
			_capture_focus = _w(Vector3(0.1, 1.3, DUMMY_POSITION.z * 0.5 - 0.05))
		"dust", "dust_soft", "dodge":
			_capture_focus = _w(Vector3(0.0, 0.3, 0.0))
		"trail", "aura":
			_capture_focus = _w(Vector3(0.0, 1.1, 0.0))
		"melee":
			_capture_focus = _w(DUMMY_POSITION + Vector3(0.0, 1.0, 0.8))
		"showcase":
			_capture_focus = _w(DEMO_TARGET)
		_:
			push_warning("[VfxPreview] Grabación desconocida: %s" % _strip)
			get_tree().quit(1)
			return
	# The demo camera for the trail and the aura looks at the player from the front: the dummy would get in
	# the way. The game camera sees it from behind: the dummy is in front and does not obstruct.
	if (_strip == "trail" or _strip == "aura") and not _game_camera:
		_dummy.visible = false
	var warmup: int = STRIP_WARMUP_FRAMES + (FIELD_SETTLE_FRAMES if _field else 0)
	if config.has("times"):
		_fire_frame = warmup
		for time: float in config["times"]:
			_capture_frames.append(_fire_frame + roundi(time * FPS))
	elif _strip == "showcase":
		_fire_frame = warmup
		for time: float in SHOWCASE_TIMES:
			_capture_frames.append(_fire_frame + roundi(time * FPS))


# The "trail" and "aura" modes follow combat: the frames come from the first active hit or the first
# charge.
func _schedule_frames_from_combat() -> void:
	var config: Dictionary = STRIPS[_strip]
	var step: int = int(config["step"])
	var lead: int = int(config["lead"])
	for index: int in STRIP_FRAMES:
		_capture_frames.append(_frame - lead + index * step)


func _run_capture() -> void:
	if _strip != "trail" and _strip != "aura" and _frame == _fire_frame and _strip != "":
		if _strip == "showcase":
			for effect: StringName in [&"metal", &"flesh", &"cloth", &"block", &"parry"]:
				_fire(effect)
			_fire(&"dust")
		elif _strip == "melee":
			_fire_melee()
		elif _strip == "metal_side":
			_fire(&"metal")
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


# Crop around the point of interest: [constant CROP_DEMO] with the demo camera, [constant
# CROP_GAME] (or the large one, for the trail, the aura and the melee) with the game's.
func _crop_around_focus(image: Image) -> Image:
	var focus_world: Vector3 = _capture_focus
	if (_strip == "trail" or _strip == "aura") and _sword != null:
		focus_world = _sword.global_position.lerp(_character.global_position + Vector3(0.0, 1.1, 0.0), 0.5)
	var screen: Vector2 = _camera.unproject_position(focus_world)
	var ratio: float = float(image.get_height()) / float(CAPTURE_WINDOW.y)
	var size: Vector2i = CROP_DEMO
	if _game_camera:
		size = CROP_GAME_WIDE if bool(STRIPS.get(_strip, {}).get("wide", false)) else CROP_GAME
	var crop: Vector2i = Vector2i(roundi(size.x * ratio), roundi(size.y * ratio))
	var origin: Vector2i = Vector2i(roundi(screen.x) - crop.x / 2, roundi(screen.y) - crop.y / 2)
	origin.x = clampi(origin.x, 0, maxi(image.get_width() - crop.x, 0))
	origin.y = clampi(origin.y, 0, maxi(image.get_height() - crop.y, 0))
	return image.get_region(Rect2i(origin, crop))


func _finish_capture() -> void:
	var meta: Dictionary = {"strip": _strip, "realm": _realm, "times": _times_log,
			"fps": FPS, "frames": _capture_frames, "camera": "game" if _game_camera else "demo",
			"field": _field, "shade": _shade, "ground": String(_ground_kind)}
	var file: FileAccess = FileAccess.open(_strip_dir.path_join("meta.json"), FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(meta, "\t"))
		file.close()
	print("[VfxPreview] %d fotogramas en %s" % [_capture_frames.size(), _strip_dir])
	_capture_frames.clear()
	if _quit_when_done:
		get_tree().quit()


# --- Video ------------------------------------------------------------------------------------------

# The demo video: the combat loop with a different realm on each lap, a stretch in the shade and a
# melee at the end. It closes on its own after [code]--reel[/code] seconds.
func _run_reel(delta: float) -> void:
	if _frame < FIELD_SETTLE_FRAMES:
		return
	_reel_time += delta
	var fraction: float = _reel_time / maxf(_reel_length, 0.001)
	var stage: int = 0
	if fraction >= 0.4:
		stage = 1
	if fraction >= 0.68:
		stage = 2
	if stage != _reel_stage:
		_reel_stage = stage
		_move_stage(stage == 1)
		_next_melee = 0.0
	if _reel_stage == 2:
		_next_melee -= delta
		if _next_melee <= 0.0:
			_next_melee = 1.1
			_fire_melee()
	if _reel_time >= _reel_length:
		print("[VfxPreview] vídeo completo (%d fotogramas)" % _frame)
		get_tree().quit()


# --- Measurement ------------------------------------------------------------------------------------

# Measures a melee: warm-up, baseline without effects and ten effects at once (plus the trail and the
# aura at maximum charge on the sword).
func _run_bench() -> void:
	_bench_frames += 1
	var viewport: RID = get_viewport().get_viewport_rid()
	match _bench_phase:
		0:
			if _bench_frames >= BENCH_WARMUP + FIELD_SETTLE_FRAMES:
				_bench_phase = 1
				_bench_frames = 0
				_bench_samples.clear()
		1:
			_bench_samples.append(_bench_sample(viewport))
			if _bench_frames >= BENCH_BASELINE:
				_bench_results["baseline"] = _bench_summary(_bench_samples)
				_bench_samples.clear()
				_bench_phase = 2
				_bench_frames = 0
				_fire_melee()
				_trail.begin(_sword)
				_aura.play()
				_aura.set_charge(1.0)
		2:
			_bench_samples.append(_bench_sample(viewport))
			# The trail needs the sword to move to paint anything: it is given the first light attack's sweep.
			if _bench_frames >= BENCH_BURST:
				_bench_results["melee"] = _bench_summary(_bench_samples)
				_bench_phase = 3
				_write_bench()
				if _quit_when_done:
					get_tree().quit()


func _bench_sample(viewport: RID) -> Dictionary:
	return {
		"draw_calls": Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME),
		"objects": Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME),
		"primitives": Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME),
		"gpu_ms": RenderingServer.viewport_get_measured_render_time_gpu(viewport),
		"cpu_ms": RenderingServer.viewport_get_measured_render_time_cpu(viewport)
				+ RenderingServer.get_frame_setup_time_cpu(),
		"active_effects": _active_effects(),
	}


func _active_effects() -> int:
	var count: int = 0
	for pool: VfxPool in _pools.values():
		count += pool.get_active_count()
	if _aura.is_playing():
		count += 1
	if _trail.is_active():
		count += 1
	return count


func _bench_summary(samples: Array[Dictionary]) -> Dictionary:
	var result: Dictionary = {"frames": samples.size()}
	for key: String in ["draw_calls", "objects", "primitives", "gpu_ms", "cpu_ms", "active_effects"]:
		var total: float = 0.0
		var peak: float = 0.0
		for sample: Dictionary in samples:
			total += float(sample[key])
			peak = maxf(peak, float(sample[key]))
		result[key + "_mean"] = snappedf(total / maxf(samples.size(), 1), 0.001)
		result[key + "_max"] = snappedf(peak, 0.001)
	return result


func _write_bench() -> void:
	_bench_results["gpu"] = RenderingServer.get_video_adapter_name()
	_bench_results["window"] = str(get_window().size)
	var baseline: Dictionary = _bench_results["baseline"]
	var melee: Dictionary = _bench_results["melee"]
	_bench_results["delta"] = {
		"draw_calls_mean": snappedf(float(melee["draw_calls_mean"]) - float(baseline["draw_calls_mean"]), 0.01),
		"draw_calls_max": snappedf(float(melee["draw_calls_max"]) - float(baseline["draw_calls_mean"]), 0.01),
		"gpu_ms_mean": snappedf(float(melee["gpu_ms_mean"]) - float(baseline["gpu_ms_mean"]), 0.001),
		"gpu_ms_max": snappedf(float(melee["gpu_ms_max"]) - float(baseline["gpu_ms_mean"]), 0.001),
		"cpu_ms_mean": snappedf(float(melee["cpu_ms_mean"]) - float(baseline["cpu_ms_mean"]), 0.001),
	}
	var directory: String = _resolve_dir(_out_dir)
	DirAccess.make_dir_recursive_absolute(directory)
	var file: FileAccess = FileAccess.open(directory.path_join("bench.json"), FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(_bench_results, "\t"))
		file.close()
	print("[VfxPreview] medición: %s" % JSON.stringify(_bench_results["delta"]))


static func _resolve_dir(path: String) -> String:
	path = path.strip_edges().trim_prefix("\"").trim_suffix("\"").replace("\\", "/")
	if path.begins_with("res://") or path.begins_with("user://"):
		return ProjectSettings.globalize_path(path)
	if path.is_relative_path():
		return ProjectSettings.globalize_path("res://").path_join(path)
	return path
