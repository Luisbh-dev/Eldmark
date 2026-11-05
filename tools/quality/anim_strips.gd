extends SceneTree
## Quality capture bench (TEC-50), animation area: frame strips of the character in the sandbox.
##
## It builds the real sandbox (test_world zone, PlayerCharacter + HumanoidVisual + real CameraRig +
## LocalPlayerController), drives the character with an input script (its own BotBrain, see
## anim_actions.gd) and, for each capture window, saves N frames from three cameras:
##   - "game":  the game's real camera (CameraRig), cropped around the character.
##   - "side":  full-body camera from the side (own SubViewport, over a 1 m checkered floor).
##   - "front": full-body camera from the front.
## The frames go to <raw>/<action>/<window>/{game,side,front}_NN.png and meta.json (with, per frame, the combat
## action, the speed and the combat clip shown by the animation layer); compose_strips.py joins them into
## grids. What in the game is imposed by the server (stagger, stun, death, knocked down, revive, execute) is
## imposed here with ActionMachine.impose_* at the script's tick.
##
## It needs a window (not headless) and a GPU. Usually launched with `python tools/quality/run.py animacion`; by hand:
##   godot --path . --resolution 1920x1080 --fixed-fps 30 -s res://tools/quality/anim_strips.gd -- \
##       --raw=C:/path/build/calidad/raw [--set=player|npc|all] [--only=a,b] [--list]
##
## Options: --raw=<folder> (default build/calidad/raw), --set=player (default), npc (the catalog's NPCs)
## or all; --only=<comma-separated ids> (action ids); --list prints the ids and exits (no window).

const AnimActions = preload("res://tools/quality/anim_actions.gd")

const PLAYER_SCENE: String = "res://scenes/characters/player_character.tscn"
const RIG_SCENE: String = "res://scenes/client/camera_rig.tscn"
const ZONE_SCENE: String = "res://scenes/world/test_world.tscn"
const FRAMES: int = AnimActions.FRAMES
const CELL_CLOSE: Vector2i = Vector2i(400, 520)
const CROP_GAME: Vector2i = Vector2i(480, 540)
const START_POS: Vector3 = Vector3(-60.0, 0.1, 90.0)

var _raw: String = ""
var _only: PackedStringArray = PackedStringArray()
var _set: String = "player"
var _list: bool = false

var ch: PlayerCharacter
var visual: HumanoidVisual
var rig: CameraRig
var ctrl: LocalPlayerController
var brain: ScriptBrain
var _svs: Dictionary = {}
var _cams: Dictionary = {}
var _checker: MeshInstance3D
var _game_center: Vector2i = Vector2i(960, 600)

var W_SWORD: int


# ---------------------------------------------------------------------------------------------
# Scripted brain
# ---------------------------------------------------------------------------------------------
class ScriptBrain extends BotBrain:
	var owner_main: Object = null
	var active: bool = false
	var start_tick: int = 0
	var segs: Array = []
	var events: Array = []
	var pitch: float = 0.0
	var applied: Dictionary = {}

	func _init() -> void:
		super(1)

	func begin(new_segs: Array, new_events: Array, tick: int) -> void:
		segs = new_segs
		events = new_events
		start_tick = tick
		applied.clear()
		active = true

	func stop() -> void:
		active = false

	func rt_of(tick: int) -> int:
		return tick - start_tick

	func next_input(tick: int, _position: Vector3, _yaw: float) -> PlayerInput:
		var input := PlayerInput.new()
		input.tick = tick
		if not active:
			input.look_yaw = 0.0
			owner_main.rig.set_look(0.0, pitch)
			return input
		var rt: int = tick - start_tick
		for i: int in events.size():
			var ev: Dictionary = events[i]
			if int(ev["at"]) <= rt and not applied.has(i):
				applied[i] = true
				owner_main.apply_event(ev, tick)
		var seg: Dictionary = segs[0]
		for s: Dictionary in segs:
			if not s.has("over") and rt >= int(s["a"]):
				seg = s
		for s: Dictionary in segs:
			if s.has("over") and rt >= int(s["a"]) and rt < int(s["b"]):
				seg = s
		var look: float = float(seg["yaw0"])
		if rt >= int(seg["b"]):
			look = float(seg["yaw1"])
		else:
			var span: float = maxf(float(int(seg["b"]) - int(seg["a"])), 1.0)
			look = lerpf(float(seg["yaw0"]), float(seg["yaw1"]), clampf(float(rt - int(seg["a"])) / span, 0.0, 1.0))
		input.look_yaw = look
		input.move = seg["move"]
		input.buttons = int(seg["buttons"])
		owner_main.rig.set_look(look, pitch)
		return input


func _initialize() -> void:
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--raw="):
			_raw = arg.trim_prefix("--raw=").replace("\\", "/")
		elif arg.begins_with("--only="):
			_only = arg.trim_prefix("--only=").split(",", false)
		elif arg.begins_with("--set="):
			_set = arg.trim_prefix("--set=")
		elif arg == "--list":
			_list = true
	if _raw.is_empty():
		_raw = ProjectSettings.globalize_path("res://build/calidad/raw")
	_run.call_deferred()


func _actions() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if _set == "player" or _set == "all":
		out.append_array(AnimActions.player_actions())
	if _set == "npc" or _set == "all":
		out.append_array(AnimActions.npc_actions())
	return out


func _run() -> void:
	await process_frame
	var actions: Array[Dictionary] = _actions()
	if _list:
		for id: String in AnimActions.ids_of(actions):
			print(id)
		quit(0)
		return
	if DisplayServer.get_name() == "headless":
		printerr("Necesita ventana")
		quit(1)
		return
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0
	W_SWORD = CombatCatalog.weapon_id(&"sword_shield")
	_build_world()
	for _i: int in 90:
		await process_frame
	var done: int = 0
	for act: Dictionary in actions:
		if not _only.is_empty() and not _only.has(String(act["id"])):
			continue
		print("[strips] ", act["id"])
		await _run_action(act)
		done += 1
	print("[strips] terminado: %d acciones" % done)
	quit(0)


# ---------------------------------------------------------------------------------------------
# Setup
# ---------------------------------------------------------------------------------------------
func _build_world() -> void:
	var zone: Node = (load(ZONE_SCENE) as PackedScene).instantiate()
	root.add_child(zone)
	ch = (load(PLAYER_SCENE) as PackedScene).instantiate() as PlayerCharacter
	root.add_child(ch)
	var st := PlayerState.new()
	st.position = START_POS
	ch.set_state(st)
	ch.reset_physics_interpolation()
	visual = HumanoidVisual.install_replacing_placeholder(ch)
	rig = (load(RIG_SCENE) as PackedScene).instantiate() as CameraRig
	rig.set_scripted_look(true)
	root.add_child(rig)
	rig.set_target(ch.get_camera_target(), ch)
	rig.set_hide_when_close(ch.get_node_or_null(^"Visual") as Node3D)
	rig.set_look(0.0, 0.0)
	# The game camera does not see the checkered floor (layer 2).
	rig.get_camera().cull_mask = 0xFFFFF & ~2
	ctrl = LocalPlayerController.new()
	root.add_child(ctrl)
	ctrl.setup(ch, rig)
	brain = ScriptBrain.new()
	brain.owner_main = self
	ctrl.set_bot(brain)
	# 1 m checkered floor, only for the close-up cameras (layer 2): it reveals whether the feet slide.
	var shader := Shader.new()
	shader.code = "shader_type spatial;\nrender_mode unshaded;\nvarying vec3 wp;\nvoid vertex(){ wp = (MODEL_MATRIX * vec4(VERTEX,1.0)).xyz; }\nvoid fragment(){ vec2 c = floor(wp.xz); float k = mod(c.x + c.y, 2.0); ALBEDO = mix(vec3(0.60,0.60,0.56), vec3(0.34,0.37,0.33), k); }\n"
	var mat := ShaderMaterial.new()
	mat.shader = shader
	var plane := PlaneMesh.new()
	plane.size = Vector2(400.0, 400.0)
	plane.material = mat
	_checker = MeshInstance3D.new()
	_checker.mesh = plane
	_checker.layers = 2
	_checker.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_checker.position = Vector3(START_POS.x, 0.012, 0.0)
	root.add_child(_checker)
	for view: String in ["side", "front"]:
		var sv := SubViewport.new()
		sv.size = CELL_CLOSE
		sv.msaa_3d = Viewport.MSAA_4X
		sv.render_target_update_mode = SubViewport.UPDATE_ALWAYS
		sv.gui_disable_input = true
		root.add_child(sv)
		var cam := Camera3D.new()
		cam.fov = 42.0
		cam.near = 0.1
		cam.far = 400.0
		cam.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
		sv.add_child(cam)
		cam.current = true
		_svs[view] = sv
		_cams[view] = cam


func _set_close_cameras(cam_y: float, target_y: float, dist: float) -> void:
	var feet: Vector3 = ch.get_global_transform_interpolated().origin
	var side: Camera3D = _cams["side"]
	var front: Camera3D = _cams["front"]
	side.global_position = Vector3(feet.x + dist, cam_y, feet.z)
	side.look_at(Vector3(feet.x, target_y, feet.z), Vector3.UP)
	front.global_position = Vector3(feet.x, cam_y, feet.z - dist)
	front.look_at(Vector3(feet.x, target_y, feet.z), Vector3.UP)


# ---------------------------------------------------------------------------------------------
# Imposed events (what the server would do)
# ---------------------------------------------------------------------------------------------
func apply_event(ev: Dictionary, tick: int) -> void:
	var c: CombatState = ch.combat
	match String(ev["kind"]):
		"stagger":
			ActionMachine.impose_stagger(c, tick, tick + int(ev.get("ticks", 24)), ev.get("kb", Vector2(0.0, 3.0)))
		"stun":
			ActionMachine.impose_stun(c, tick, tick + int(ev.get("ticks", 90)))
		"death":
			ActionMachine.impose_death(c, tick)
		"downed":
			ActionMachine.impose_downed(c, tick)
		"revive":
			ActionMachine.impose_interact(c, tick, CombatState.Action.REVIVE)
		"execute":
			ActionMachine.impose_interact(c, tick, CombatState.Action.EXECUTE)
		"revived":
			ActionMachine.impose_revived(c, tick)
		"hit", "block_hit":
			# Visual reaction to a hit that the server does not turn into control (ART-48, ART-50): the attacker
			# is in front of the character (who faces -Z).
			visual.react_to_hit(Vector3(0.0, 0.0, -1.0), float(ev.get("amount", 90.0)), String(ev["kind"]) == "block_hit")


# ---------------------------------------------------------------------------------------------
# Running an action
# ---------------------------------------------------------------------------------------------
func _reset_character(act: Dictionary) -> void:
	brain.stop()
	var st := PlayerState.new()
	st.position = START_POS
	st.yaw = 0.0
	ch.set_state(st)
	ch.velocity = Vector3.ZERO
	ch.reset_physics_interpolation()
	var weapon: int = int(act.get("weapon", W_SWORD))
	var alt: int = int(act.get("alt_weapon", 0))
	ActionMachine.set_loadout(ch.combat, weapon, alt, CombatState.pack_charges(5, 5))
	ch.combat.stamina = CombatCatalog.rules().stamina_max
	var animator: CharacterAnimator = visual.get_animator()
	animator.reset_facing()
	if animator.get_combat_layer() != null:
		animator.get_combat_layer().reset()
	rig.set_look(0.0, 0.0)
	rig.set_target(ch.get_camera_target(), ch)


func _run_action(act: Dictionary) -> void:
	# Each window runs the whole action again from the start (windows may overlap).
	for i: int in (act["windows"] as Array).size():
		await _run_one(act, i)


func _run_one(act: Dictionary, win_index: int) -> void:
	_reset_character(act)
	# Idle so that the animator, the weapon and the camera settle.
	for _i: int in 24:
		await process_frame
	var tl: AnimActions.TL = act["tl"] as AnimActions.TL
	var start_tick: int = ctrl.get_tick() + 2
	brain.begin(tl.segs, tl.events, start_tick)
	var cam_y: float = float(act.get("cam_y", 1.25))
	var target_y: float = float(act.get("target_y", 0.95))
	var dist: float = float(act.get("dist", 5.0))
	var windows: Array = [(act["windows"] as Array)[win_index]]
	var guard: int = 0
	for w: Dictionary in windows:
		var win: Dictionary = w.duplicate()
		if win.has("dyn_warm"):
			while ctrl.get_tick() - start_tick < int(win["dyn_warm"]):
				await process_frame
			var scale: float = absf(float(visual.get_animator().get_debug_state()["locomotion_scale"]))
			var cycle_ticks: int = clampi(roundi(60.0 / maxf(scale, 0.2)), 20, 200)
			win["from"] = int(win["dyn_warm"])
			win["to"] = int(win["dyn_warm"]) + cycle_ticks
			win["cycle"] = true
			win["note"] = "ciclo de locomoción completo: escala %.2f ciclos/s, %d ticks" % [scale, cycle_ticks]
		# Center of the game camera crop: where the character is when the window starts.
		while ctrl.get_tick() - start_tick < int(win["from"]) - 2:
			await process_frame
			guard += 1
		_game_center = _project_center()
		var frames_meta: Array = []
		var count: int = int(win.get("frames", FRAMES))
		var denom: float = float(count) if bool(win.get("cycle", false)) else float(count - 1)
		var dir: String = _raw.path_join(String(act["id"])).path_join(String(win["name"]))
		DirAccess.make_dir_recursive_absolute(dir)
		for k: int in count:
			var target_rt: int = roundi(lerpf(float(win["from"]), float(win["to"]), float(k) / denom))
			while ctrl.get_tick() - start_tick < target_rt:
				await process_frame
				guard += 1
				if guard > 20000:
					printerr("[strips] guarda de seguridad en ", act["id"])
					break
			_set_close_cameras(cam_y, target_y, dist)
			await RenderingServer.frame_post_draw
			_grab(dir, k)
			var rt_now: int = ctrl.get_tick() - start_tick
			var dbg: Dictionary = visual.get_animator().get_debug_state()
			var combat_dbg: Dictionary = dbg.get("combat", {})
			frames_meta.append({
				"k": k, "rt": rt_now, "t": snappedf(float(rt_now) / 60.0, 0.001),
				"action": CombatState.Action.keys()[ch.combat.action],
				"speed": snappedf(float(dbg["speed"]), 0.01),
				"air": String(dbg["air_state"]),
				"clip": String(combat_dbg.get("animation", "")),
				"clip_t": snappedf(float(combat_dbg.get("time", 0.0)), 0.001),
				"clip_speed": snappedf(float(combat_dbg.get("speed", 0.0)), 0.01),
				"upper": bool(combat_dbg.get("upper_body", false)),
				"pos_y": snappedf(ch.global_position.y, 0.01),
			})
		var meta: Dictionary = {
			"id": act["id"], "name": win["name"], "title": act.get("title", act["id"]),
			"desc": act.get("desc", ""), "note": win.get("note", ""), "frames": frames_meta,
			"from": win["from"], "to": win["to"], "weapon": str(CombatCatalog.weapon(int(act.get("weapon", W_SWORD))).name),
			"source": "sandbox",
		}
		var file: FileAccess = FileAccess.open(dir.path_join("meta.json"), FileAccess.WRITE)
		file.store_string(JSON.stringify(meta, "  "))
		file.close()
	brain.stop()
	for _i: int in 6:
		await process_frame


func _project_center() -> Vector2i:
	var cam: Camera3D = rig.get_camera()
	var feet: Vector3 = ch.get_global_transform_interpolated().origin
	var p: Vector2 = cam.unproject_position(feet + Vector3(0.0, 0.95, 0.0))
	var size: Vector2 = root.get_visible_rect().size
	var cx: int = clampi(int(p.x), CROP_GAME.x / 2, int(size.x) - CROP_GAME.x / 2)
	var cy: int = clampi(int(p.y), CROP_GAME.y / 2, int(size.y) - CROP_GAME.y / 2)
	return Vector2i(cx, cy)


func _grab(dir: String, k: int) -> void:
	var full: Image = root.get_texture().get_image()
	var crop := Rect2i(_game_center - CROP_GAME / 2, CROP_GAME)
	var sx: float = float(full.get_width()) / root.get_visible_rect().size.x
	if absf(sx - 1.0) > 0.01:
		crop = Rect2i(Vector2i(Vector2(crop.position) * sx), Vector2i(Vector2(crop.size) * sx))
	full.get_region(crop).save_png(dir.path_join("game_%02d.png" % k))
	for view: String in ["side", "front"]:
		var img: Image = (_svs[view] as SubViewport).get_texture().get_image()
		img.save_png(dir.path_join("%s_%02d.png" % [view, k]))
