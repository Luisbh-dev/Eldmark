extends SceneTree
## ART-06 review tool: the hero with the sword at rest, striking and blocking, up
## close and from the game camera.
##
## Builds the real sandbox (test_world zone, [PlayerCharacter] with [HumanoidVisual], [CameraRig] and
## [LocalPlayerController]), drives it with an input script and, for each action, saves a
## contact sheet of 4 x 3 frames per view:
## [br]- [code]game[/code]: the game's real camera (over the shoulder), cropped around the
## character.
## [br]- [code]side[/code]: full body from the side (camera at 5 m, FOV 42), the same shot as
## build/calidad/animacion/lado/com_ligero_1.png, to compare with the earlier box.
## [br]- [code]hand[/code]: the sword hand up close, from the front and right.
## [br][br]
## Needs a window (not headless). Usage (on this machine the window goes to the second screen via
## override.cfg):
## [codeblock]
## godot --path . --resolution 1920x1080 --fixed-fps 30 -s res://tools/render/sword_hero_shots.gd -- \
##     --sin-raton --out=build/sword/hero [--only=reposo,ligero,fuerte,bloqueo] [--views=game,side,hand] \
##     [--grip-offset=0,0.07,0] [--grip-rot=0,0,-90] [--variant=base|vardheim|solmarch|askarra] [--frames]
## [/codeblock]
## [br]With [code]--variant[/code] the hand's sword is that realm's (and the trail, in its colour). With
## [code]--fixed-fps 60[/code] each strike's contact sheet spreads its 12 frames over the active phase
## (with a margin before and after) and, with [code]--frames[/code], all the frames of the active
## phase are also saved, one by one, in [code]<out>/frames/<action>/<view>/[/code] (to assemble video).
## [br]The last two settings replace the [WeaponProps] grip only for this run: they are useful
## for trying positions before committing them to the constants.

const PLAYER_SCENE: String = "res://scenes/characters/player_character.tscn"
const RIG_SCENE: String = "res://scenes/client/camera_rig.tscn"
const ZONE_SCENE: String = "res://scenes/world/test_world.tscn"
const START_POS: Vector3 = Vector3(-60.0, 0.1, 90.0)
const COLUMNS: int = 4
const ROWS: int = 3
const FRAMES: int = COLUMNS * ROWS
const SIDE_SIZE: Vector2i = Vector2i(400, 520)
const HAND_SIZE: Vector2i = Vector2i(520, 520)
const GAME_CROP: Vector2i = Vector2i(480, 540)
## Hand camera: offset relative to the hand (m), in character space (it looks along -Z), and
## field of view.
const HAND_CAMERA_OFFSET: Vector3 = Vector3(0.75, 0.30, -0.85)
const HAND_CAMERA_FOV: float = 34.0

var _out: String = ""
var _only: PackedStringArray = PackedStringArray()
var _views: PackedStringArray = PackedStringArray(["game", "side", "hand"])
var _grip_offset: Variant = null
var _grip_rotation: Variant = null
var _variant: StringName = &""
var _save_frames: bool = false

var character: PlayerCharacter
var visual: HumanoidVisual
var rig: CameraRig
var controller: LocalPlayerController
var brain: ScriptBrain
var _viewports: Dictionary = {}
var _cameras: Dictionary = {}
var _game_center: Vector2i = Vector2i(960, 600)


## Scripted brain: returns the input due according to the action's script.
class ScriptBrain extends BotBrain:
	var active: bool = false
	var start_tick: int = 0
	var segments: Array[Dictionary] = []
	var rig: CameraRig = null

	func _init() -> void:
		super(1)

	func begin(new_segments: Array[Dictionary], tick: int) -> void:
		segments = new_segments
		start_tick = tick
		active = true

	func stop() -> void:
		active = false

	func next_input(tick: int, _position: Vector3, _yaw: float) -> PlayerInput:
		var input := PlayerInput.new()
		input.tick = tick
		input.look_yaw = 0.0
		if rig != null:
			rig.set_look(0.0, 0.0)
		if not active:
			return input
		var elapsed: int = tick - start_tick
		for segment: Dictionary in segments:
			if elapsed >= int(segment["from"]) and elapsed < int(segment["to"]):
				input.move = segment.get("move", Vector2.ZERO)
				input.buttons = int(segment.get("buttons", 0))
		return input


func _initialize() -> void:
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--out="):
			_out = arg.trim_prefix("--out=").replace("\\", "/")
		elif arg.begins_with("--only="):
			_only = arg.trim_prefix("--only=").split(",", false)
		elif arg.begins_with("--views="):
			_views = arg.trim_prefix("--views=").split(",", false)
		elif arg.begins_with("--grip-offset="):
			_grip_offset = _parse_vector(arg.trim_prefix("--grip-offset="))
		elif arg.begins_with("--variant="):
			_variant = StringName(arg.trim_prefix("--variant="))
		elif arg == "--frames":
			_save_frames = true
		elif arg.begins_with("--grip-rot="):
			_grip_rotation = _parse_vector(arg.trim_prefix("--grip-rot="))
	if _out.is_empty():
		_out = "build/sword/hero"
	if not _out.is_absolute_path():
		_out = ProjectSettings.globalize_path("res://").path_join(_out)
	_run.call_deferred()


func _parse_vector(text: String) -> Vector3:
	var parts: PackedStringArray = text.split(",", false)
	return Vector3(parts[0].to_float(), parts[1].to_float(), parts[2].to_float())


func _run() -> void:
	await process_frame
	if DisplayServer.get_name() == "headless":
		printerr("Esta herramienta necesita ventana: ejecútala sin --headless.")
		quit(1)
		return
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0
	DirAccess.make_dir_recursive_absolute(_out)
	_build_world()
	for _i: int in range(90):
		await process_frame
	_apply_grip_overrides()
	if _variant != &"":
		WeaponProps.set_sword_variant(visual.get_skeleton(), _variant)
		for _i: int in range(8):
			await process_frame
	for action: Dictionary in _actions():
		if not _only.is_empty() and not _only.has(String(action["id"])):
			continue
		print("[sword_hero] ", action["id"])
		await _run_action(action)
	print("[sword_hero] terminado: ", _out)
	quit(0)


func _build_world() -> void:
	var zone: Node = (load(ZONE_SCENE) as PackedScene).instantiate()
	root.add_child(zone)
	character = (load(PLAYER_SCENE) as PackedScene).instantiate() as PlayerCharacter
	root.add_child(character)
	var state := PlayerState.new()
	state.position = START_POS
	character.set_state(state)
	character.reset_physics_interpolation()
	visual = HumanoidVisual.install_replacing_placeholder(character)
	rig = (load(RIG_SCENE) as PackedScene).instantiate() as CameraRig
	rig.set_scripted_look(true)
	root.add_child(rig)
	rig.set_target(character.get_camera_target(), character)
	rig.set_hide_when_close(character.get_node_or_null(^"Visual") as Node3D)
	rig.set_look(0.0, 0.0)
	controller = LocalPlayerController.new()
	root.add_child(controller)
	controller.setup(character, rig)
	brain = ScriptBrain.new()
	brain.rig = rig
	controller.set_bot(brain)
	for view: String in ["side", "hand"]:
		var viewport := SubViewport.new()
		viewport.size = SIDE_SIZE if view == "side" else HAND_SIZE
		viewport.msaa_3d = Viewport.MSAA_4X
		viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
		viewport.gui_disable_input = true
		root.add_child(viewport)
		var camera := Camera3D.new()
		camera.fov = 42.0 if view == "side" else HAND_CAMERA_FOV
		camera.far = 400.0
		camera.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
		viewport.add_child(camera)
		camera.current = true
		_viewports[view] = viewport
		_cameras[view] = camera


func _sword_node() -> Node3D:
	var skeleton: Skeleton3D = visual.get_skeleton()
	var attachment: Node = skeleton.get_node_or_null(NodePath(WeaponProps.SWORD_ATTACHMENT))
	if attachment == null or attachment.get_child_count() == 0:
		return null
	return attachment.get_child(0) as Node3D


func _apply_grip_overrides() -> void:
	var sword: Node3D = _sword_node()
	if sword == null:
		return
	if _grip_offset != null:
		sword.position = _grip_offset as Vector3
	if _grip_rotation != null:
		sword.rotation_degrees = _grip_rotation as Vector3


func _trail_node() -> SwordTrail:
	var sword: Node3D = _sword_node()
	return sword.get_node_or_null(^"SwordTrail") as SwordTrail if sword != null else null


func _hand_position() -> Vector3:
	var skeleton: Skeleton3D = visual.get_skeleton()
	var bone: int = skeleton.find_bone(WeaponProps.SWORD_BONE)
	return (skeleton.global_transform * skeleton.get_bone_global_pose(bone)).origin


func _update_cameras() -> void:
	var feet: Vector3 = character.get_global_transform_interpolated().origin
	var side: Camera3D = _cameras["side"]
	side.global_position = Vector3(feet.x + 5.0, 1.25, feet.z)
	side.look_at(Vector3(feet.x, 0.95, feet.z), Vector3.UP)
	var hand: Camera3D = _cameras["hand"]
	var target: Vector3 = _hand_position()
	hand.global_position = target + HAND_CAMERA_OFFSET
	hand.look_at(target, Vector3.UP)


func _reset_character() -> void:
	brain.stop()
	var state := PlayerState.new()
	state.position = START_POS
	state.yaw = 0.0
	character.set_state(state)
	character.velocity = Vector3.ZERO
	character.reset_physics_interpolation()
	var sword_id: int = CombatCatalog.weapon_id(&"sword_shield")
	ActionMachine.set_loadout(character.combat, sword_id, 0, CombatState.pack_charges(5, 5))
	character.combat.stamina = CombatCatalog.rules().stamina_max
	var animator: CharacterAnimator = visual.get_animator()
	animator.reset_facing()
	if animator.get_combat_layer() != null:
		animator.get_combat_layer().reset()
	rig.set_look(0.0, 0.0)
	rig.set_target(character.get_camera_target(), character)


func _actions() -> Array[Dictionary]:
	var sword: WeaponTicks = CombatCatalog.weapon(CombatCatalog.weapon_id(&"sword_shield"))
	var light: AttackTicks = CombatCatalog.attack(sword.light_ids[0])
	var heavy: AttackTicks = CombatCatalog.attack(sword.heavy_id)
	var primary: int = PlayerInput.PRIMARY
	var out: Array[Dictionary] = []
	out.append({"id": "reposo", "segments": [], "from": 0, "to": 236,
			"title": "Reposo"})
	# Same script and same window as com_ligero_1 in build/calidad, to compare with the box.
	out.append({"id": "ligero", "title": "Golpe ligero 1",
			"segments": [{"from": 10, "to": 13, "buttons": primary}],
			"from": 6, "to": 10 + light.total_ticks + 6})
	var hold: int = heavy.charge_min_ticks + 12
	out.append({"id": "fuerte", "title": "Golpe fuerte",
			"segments": [{"from": 10, "to": 10 + hold, "buttons": primary}],
			"from": 8, "to": 10 + hold + heavy.total_ticks + 6})
	out.append({"id": "bloqueo", "title": "Bloqueo",
			"segments": [{"from": 20, "to": 110, "buttons": PlayerInput.BLOCK}],
			"from": 14, "to": 120})
	return out


func _run_action(action: Dictionary) -> void:
	_reset_character()
	for _i: int in range(24):
		await process_frame
	var segments: Array[Dictionary] = []
	for segment: Variant in action["segments"]:
		segments.append(segment as Dictionary)
	var start_tick: int = controller.get_tick() + 2
	brain.begin(segments, start_tick)
	var from_tick: int = int(action["from"])
	var to_tick: int = int(action["to"])
	while controller.get_tick() - start_tick < from_tick - 2:
		await process_frame
	_game_center = _project_center()
	# One frame for each engine frame between `from` and `to`, with a flag for whether the strike was active.
	var frames: Dictionary = {}
	for view: String in _views:
		frames[view] = []
	var active_flags: Array[bool] = []
	var trail: SwordTrail = _trail_node()
	var guard: int = 0
	while controller.get_tick() - start_tick < to_tick and guard < 20000:
		await process_frame
		guard += 1
		if controller.get_tick() - start_tick < from_tick:
			continue
		_update_cameras()
		await RenderingServer.frame_post_draw
		for view: String in _views:
			(frames[view] as Array).append(_grab(view))
		active_flags.append(trail != null and trail.is_active())
	brain.stop()
	var count: int = active_flags.size()
	# Active phase: from the first to the last active frame (with a margin); with no strike, the whole take.
	var first: int = 0
	var last: int = maxi(count - 1, 0)
	var first_active: int = active_flags.find(true)
	if first_active >= 0:
		var last_active: int = active_flags.rfind(true)
		first = maxi(first_active - 3, 0)
		last = mini(last_active + 8, count - 1)
		print("[sword_hero]   fase activa: fotogramas %d a %d de %d" % [first_active, last_active, count])
		if _save_frames:
			_save_active_frames(String(action["id"]), frames, maxi(first_active - 2, 0), mini(last_active + 6, count - 1))
	for view: String in _views:
		var picks: Array = []
		for k: int in range(FRAMES):
			var index: int = roundi(lerpf(float(first), float(last), float(k) / float(FRAMES - 1)))
			picks.append((frames[view] as Array)[index])
		var sheet: Image = _compose(picks)
		var path: String = _out.path_join("%s__%s.png" % [action["id"], view])
		sheet.save_png(path)
		print("[sword_hero]   ", path)
	for _i: int in range(6):
		await process_frame


func _save_active_frames(action_id: String, frames: Dictionary, first: int, last: int) -> void:
	for view: String in _views:
		if view == "hand":
			continue
		var dir: String = _out.path_join("frames").path_join(action_id).path_join(view)
		DirAccess.make_dir_recursive_absolute(dir)
		for index: int in range(first, last + 1):
			((frames[view] as Array)[index] as Image).save_png(dir.path_join("%03d.png" % (index - first)))


func _project_center() -> Vector2i:
	var camera: Camera3D = rig.get_camera()
	var feet: Vector3 = character.get_global_transform_interpolated().origin
	var point: Vector2 = camera.unproject_position(feet + Vector3(0.0, 0.95, 0.0))
	var size: Vector2 = root.get_visible_rect().size
	var cx: int = clampi(int(point.x), GAME_CROP.x / 2, int(size.x) - GAME_CROP.x / 2)
	var cy: int = clampi(int(point.y), GAME_CROP.y / 2, int(size.y) - GAME_CROP.y / 2)
	return Vector2i(cx, cy)


func _grab(view: String) -> Image:
	if view == "game":
		var full: Image = root.get_texture().get_image()
		var scale: float = float(full.get_width()) / root.get_visible_rect().size.x
		var crop := Rect2i(_game_center - GAME_CROP / 2, GAME_CROP)
		if absf(scale - 1.0) > 0.01:
			crop = Rect2i(Vector2i(Vector2(crop.position) * scale), Vector2i(Vector2(crop.size) * scale))
		return full.get_region(crop)
	return (_viewports[view] as SubViewport).get_texture().get_image()


func _compose(images: Array) -> Image:
	var first: Image = images[0] as Image
	var cell: Vector2i = first.get_size()
	var sheet: Image = Image.create(cell.x * COLUMNS, cell.y * ROWS, false, Image.FORMAT_RGBA8)
	for index: int in range(images.size()):
		var image: Image = images[index] as Image
		image.convert(Image.FORMAT_RGBA8)
		sheet.blit_rect(image, Rect2i(Vector2i.ZERO, cell),
				Vector2i((index % COLUMNS) * cell.x, (index / COLUMNS) * cell.y))
	return sheet
