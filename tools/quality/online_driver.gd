extends SceneTree
## Quality capture bench (TEC-50): networked client driver.
##
## Starts the real client (OnlineMain) against a real server, waits to be in the world and runs a script
## ("scenario": a script with [code]func run(d)[/code]) that moves the camera, teleports with the server's
## debug commands, presses keys and actions and saves window captures. It never uses accounts or
## passwords: the server runs with --debug-commands and the client joins with an ephemeral character.
##
## Normally launched by [code]python tools/quality/run.py <area>[/code]; by hand:
## [codeblock]
## godot --path . --resolution 1920x1080 -s res://tools/quality/online_driver.gd -- \
##     --connect=127.0.0.1:24721 --realm=vardheim --name=Capturador \
##     --scenario=res://tools/quality/sc_mundo.gd --out=C:/ruta/build/calidad --tag=mundo_vardheim
## [/codeblock]
##
## Own options (the rest are read by [ClientConfig]): [code]--scenario=res://...gd[/code], [code]--out=<folder>[/code]
## (captures and indices), [code]--tag=<name>[/code] (name of the log [code]<out>/indices/<tag>.json[/code]),
## [code]--raw=<folder>[/code] (loose frames of the strips; by default [code]<out>/raw[/code]),
## [code]--scene=res://...tscn[/code] (instead of the networked client, any scene: preview tools) and
## [code]--front[/code] (the title screen with account, without entering the world).
## With the engine's [code]--write-movie[/code], the driver throttles frames to real time so that the server
## (which knows nothing about it) and the client stay in sync while recording.

const ONLINE_SCENE: String = "res://scenes/client/online_main.tscn"

var main: Node
var client: NetClient
var rig: CameraRig
var hud: HUD
var ch: PlayerCharacter
var out_dir: String = ""
var raw_dir: String = ""
var scenario_path: String = ""
var tag: String = "run"
var records: Array = []
var notes: Array = []
## Strip recorder of the scenario (null if it uses none); [method step] feeds it.
var recorder: Variant = null
## Hits and combat sounds seen by the local client: [{ms, kind, blocked, parried, amount}]
## (filled after [method enter_world]; see [method _watch_feedback]).
var hit_events: Array = []
var _args: PackedStringArray
var _held: Dictionary = {}
var _movie: bool = false
var _last_frame_us: int = 0


func _initialize() -> void:
	_args = OS.get_cmdline_user_args()
	for a: String in _args:
		if a.begins_with("--out="):
			out_dir = a.trim_prefix("--out=").replace("\\", "/")
		elif a.begins_with("--scenario="):
			scenario_path = a.trim_prefix("--scenario=")
		elif a.begins_with("--tag="):
			tag = a.trim_prefix("--tag=")
		elif a.begins_with("--raw="):
			raw_dir = a.trim_prefix("--raw=").replace("\\", "/")
	if out_dir.is_empty():
		out_dir = ProjectSettings.globalize_path("res://build/calidad")
	if raw_dir.is_empty():
		raw_dir = out_dir.path_join("raw")
	_movie = OS.get_cmdline_args().has("--write-movie")
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 60
	if _movie:
		process_frame.connect(_pace_to_real_time)
	var cfg: ClientConfig = ClientConfig.from_args(_args)
	var scene_arg: String = ""
	for a2: String in _args:
		if a2.begins_with("--scene="):
			scene_arg = a2.trim_prefix("--scene=")
	if not scene_arg.is_empty():
		# Any scene (preview tools).
		main = (load(scene_arg) as PackedScene).instantiate()
	elif _args.has("--front"):
		# Title screen with account (FrontMain), without entering the world.
		FrontMain.config = cfg
		main = (load("res://scenes/client/front_main.tscn") as PackedScene).instantiate()
	else:
		OnlineMain.config = cfg
		main = (load(ONLINE_SCENE) as PackedScene).instantiate()
	root.add_child(main)
	_start.call_deferred()


func _start() -> void:
	await process_frame
	var sc: RefCounted = (load(scenario_path) as GDScript).new()
	await sc.run(self)
	release_all()
	_write_records()
	if client != null and is_instance_valid(client):
		client.leave()
		await wait(1.0)
	print("[driver] terminado: %s (%d capturas)" % [tag, records.size()])
	quit(0)


# With --write-movie the engine advances one frame of 1/fps per iteration without waiting for the clock: faster than the
# server if the machine can manage it. Each frame is held back until its real time has passed.
func _pace_to_real_time() -> void:
	var target_us: int = int(1000000.0 / float(maxi(Engine.physics_ticks_per_second, 1)))
	var now: int = Time.get_ticks_usec()
	if _last_frame_us > 0:
		var wait_us: int = target_us - (now - _last_frame_us)
		if wait_us > 500:
			OS.delay_usec(wait_us)
	_last_frame_us = Time.get_ticks_usec()


# ---------------------------------------------------------------------------------------------
# Waits
# ---------------------------------------------------------------------------------------------
func frames(n: int) -> void:
	for _i: int in n:
		await process_frame


## One frame with the strip recorder kept up to date: before drawing it places its side camera and, after drawing, it saves the
## sample if due. Without a recorder it is equivalent to [code]frames(1)[/code].
func step() -> void:
	await process_frame
	if recorder != null:
		recorder.before_draw()
		await RenderingServer.frame_post_draw
		recorder.after_draw()


func wait(seconds: float) -> void:
	var end: int = Time.get_ticks_msec() + int(seconds * 1000.0)
	while Time.get_ticks_msec() < end:
		await step()


## Waits to be in the world with HUD, camera and character. Returns false if it does not arrive within [param timeout] s.
func enter_world(timeout: float = 90.0) -> bool:
	var end: int = Time.get_ticks_msec() + int(timeout * 1000.0)
	while Time.get_ticks_msec() < end:
		await process_frame
		client = main.get_client()
		if client != null and client.get_state() == NetClient.State.IN_WORLD and main.get_hud() != null \
				and main.get_camera_rig() != null and client.get_character() != null:
			break
	if main.get_hud() == null:
		note("no se llegó a entrar en el mundo")
		return false
	rig = main.get_camera_rig()
	hud = main.get_hud()
	ch = client.get_character()
	rig.set_scripted_look(true)
	_watch_feedback()
	await wait(2.0)
	return true


func note(text: String) -> void:
	notes.append(text)
	print("[driver] ", text)


# Records the hits the local client deals or receives (already timed for drawing) and the sounds it requests.
func _watch_feedback() -> void:
	var feedback: CombatFeedback = hud.get_feedback() if hud != null else null
	if feedback == null:
		return
	feedback.damage_taken.connect(func(amount: int, _attacker: int, event: NetMessages.EntityEvent) -> void:
		_log_hit("taken", amount, event))
	feedback.hit_confirmed.connect(func(_kind: int, amount: int, event: NetMessages.EntityEvent) -> void:
		_log_hit("dealt", amount, event))
	feedback.sound_requested.connect(func(sound: StringName, _pos: Vector3) -> void:
		hit_events.append({"ms": Time.get_ticks_msec(), "kind": "sound", "sound": String(sound),
				"blocked": false, "parried": false, "amount": 0}))


func _log_hit(kind: String, amount: int, event: NetMessages.EntityEvent) -> void:
	hit_events.append({"ms": Time.get_ticks_msec(), "kind": kind,
			"blocked": event.has_hit_flag(NetMessages.EntityEvent.HIT_FLAG_BLOCKED),
			"parried": event.has_hit_flag(NetMessages.EntityEvent.HIT_FLAG_PARRIED), "amount": amount})
	while hit_events.size() > 400:
		hit_events.pop_front()


# ---------------------------------------------------------------------------------------------
# Input
# ---------------------------------------------------------------------------------------------
func hold(action: StringName) -> void:
	Input.action_press(action)
	_held[action] = true


func release(action: StringName) -> void:
	Input.action_release(action)
	_held.erase(action)


func release_all() -> void:
	for a: Variant in _held.keys():
		Input.action_release(a as StringName)
	_held.clear()


func tap(action: StringName, n_frames: int = 4) -> void:
	Input.action_press(action)
	await frames(n_frames)
	Input.action_release(action)
	await frames(2)


func key(keycode: Key, n_frames: int = 3) -> void:
	var down := InputEventKey.new()
	down.physical_keycode = keycode
	down.keycode = keycode
	down.pressed = true
	Input.parse_input_event(down)
	await frames(n_frames)
	var up := InputEventKey.new()
	up.physical_keycode = keycode
	up.keycode = keycode
	up.pressed = false
	Input.parse_input_event(up)
	await frames(2)


func key_down(keycode: Key) -> void:
	var down := InputEventKey.new()
	down.physical_keycode = keycode
	down.keycode = keycode
	down.pressed = true
	Input.parse_input_event(down)


func key_up(keycode: Key) -> void:
	var up := InputEventKey.new()
	up.physical_keycode = keycode
	up.keycode = keycode
	up.pressed = false
	Input.parse_input_event(up)


func look(yaw_deg: float, pitch_deg: float = 0.0) -> void:
	if rig != null:
		rig.set_look(deg_to_rad(yaw_deg), deg_to_rad(pitch_deg))


## Yaw (degrees) to look from (x, z) towards (tx, tz).
static func yaw_to(x: float, z: float, tx: float, tz: float) -> float:
	return rad_to_deg(atan2(-(tx - x), -(tz - z)))


func pos() -> Vector3:
	return ch.global_position if ch != null else Vector3.ZERO


## Walks towards (x, z) looking that way until within [param radius] m (or [param timeout] s).
func walk_to(x: float, z: float, sprint: bool = false, radius: float = 2.0, timeout: float = 20.0) -> void:
	var end: int = Time.get_ticks_msec() + int(timeout * 1000.0)
	hold(&"move_forward")
	if sprint:
		hold(&"sprint")
	while Time.get_ticks_msec() < end:
		var p: Vector3 = pos()
		if Vector2(p.x - x, p.z - z).length() < radius:
			break
		look(yaw_to(p.x, p.z, x, z), 0.0)
		await step()
	release(&"move_forward")
	release(&"sprint")


# ---------------------------------------------------------------------------------------------
# World / server
# ---------------------------------------------------------------------------------------------
func ground_y(x: float, z: float) -> float:
	var world: Node3D = main.get_world() as Node3D
	if world == null:
		return 5.0
	var space: PhysicsDirectSpaceState3D = world.get_world_3d().direct_space_state
	var q := PhysicsRayQueryParameters3D.create(Vector3(x, 300.0, z), Vector3(x, -50.0, z), 1)
	var hit: Dictionary = space.intersect_ray(q)
	return float(hit["position"].y) if not hit.is_empty() else 5.0


## From the points [param candidates] (each one a [Vector2] with world x and z), the most open one: the one with the fewest
## obstacles (walls, posts, trunks, slopes) within [param radius] m, measured with 12 rays at chest height. Used
## to choose where to fight in front of the camera: next to a post or a wall the over-the-shoulder camera moves closer to the
## character and the crop shows only one huge face.
func open_spot(candidates: Array, radius: float = 6.0) -> Vector2:
	var world: Node3D = main.get_world() as Node3D
	if world == null or candidates.is_empty():
		return candidates[0] if not candidates.is_empty() else Vector2.ZERO
	var space: PhysicsDirectSpaceState3D = world.get_world_3d().direct_space_state
	var best: Vector2 = candidates[0]
	var best_hits: int = 1000
	for candidate: Vector2 in candidates:
		var from := Vector3(candidate.x, ground_y(candidate.x, candidate.y) + 1.2, candidate.y)
		var hits: int = 0
		for i: int in 12:
			var angle: float = TAU * float(i) / 12.0
			var query := PhysicsRayQueryParameters3D.create(from, from + Vector3(cos(angle), 0.0, sin(angle)) * radius, 1)
			if not space.intersect_ray(query).is_empty():
				hits += 1
		if hits < best_hits:
			best_hits = hits
			best = candidate
			if hits == 0:
				break
	return best


func cmd(command: int, payload: PackedByteArray = PackedByteArray()) -> void:
	client.send_debug_command(command, payload)


var _last_heal_ms: int = 0


func heal() -> void:
	# With more than a few commands per second the server kicks for "exceso de ritmo" (rate limit exceeded).
	var now: int = Time.get_ticks_msec()
	if now - _last_heal_ms < 400:
		return
	_last_heal_ms = now
	cmd(NetProtocol.DEBUG_HEAL)
	cmd(NetProtocol.DEBUG_REFILL)
	cmd(NetProtocol.DEBUG_STAMINA_INF, PackedByteArray([1]))


## Waits [param seconds] healing the player every 0.3 s (so as not to die while taking a capture in a war zone).
func wait_healing(seconds: float) -> void:
	var end: int = Time.get_ticks_msec() + int(seconds * 1000.0)
	var next_heal: int = 0
	while Time.get_ticks_msec() < end:
		if Time.get_ticks_msec() >= next_heal:
			heal()
			next_heal = Time.get_ticks_msec() + 300
		await step()


## If the player is dead or knocked down, brings them back to life (knocked down: finished off with the kill
## command; dead: waits for the respawn tick and requests spawn point 0). Returns true if it had to do so.
func ensure_alive(timeout: float = 60.0) -> bool:
	var did: bool = false
	var end: int = Time.get_ticks_msec() + int(timeout * 1000.0)
	while Time.get_ticks_msec() < end:
		if client.is_dead():
			did = true
			var respawn_tick: int = client.get_respawn_tick()
			if respawn_tick > 0 and client.get_estimated_server_tick() >= respawn_tick:
				client.send_respawn_request(0)
				await wait(1.2)
			else:
				await wait(0.4)
		elif client.is_downed():
			did = true
			cmd(NetProtocol.DEBUG_KILL)
			await wait(0.6)
		else:
			break
	if did:
		await wait(1.5)
		ch = client.get_character()
	return did


## Teleports to (x, z) (on the ground, or at [param y] if given), orients the camera and leaves a moment for
## the terrain, the LOD and the grass to load.
func tp(x: float, z: float, yaw_deg: float = 0.0, pitch_deg: float = 0.0, y: float = NAN, settle: float = 1.2) -> void:
	# The first teleport after entering the world sometimes fails to apply on the client: it is checked and repeated.
	for attempt: int in 3:
		var py: float = (ground_y(x, z) + 0.2) if is_nan(y) else y
		var message: NetMessages.DebugCommand = NetMessages.DebugCommand.teleport(Vector3(x, py, z))
		client.send_debug_command(message.command, message.payload)
		await wait(0.7 if attempt == 0 else 1.5)
		if Vector2(pos().x - x, pos().z - z).length() < 8.0:
			break
		note("teletransporte a (%.0f, %.0f) sin efecto todavía (estoy en %.0f, %.0f), intento %d" % [x, z, pos().x, pos().z, attempt + 1])
	look(yaw_deg, pitch_deg)
	# One step forward so that the character faces where the camera is looking.
	hold(&"move_forward")
	await frames(6)
	release(&"move_forward")
	await wait(settle)


# ---------------------------------------------------------------------------------------------
# Captures
# ---------------------------------------------------------------------------------------------
func shot(rel: String, desc: String = "", how: String = "") -> Image:
	await RenderingServer.frame_post_draw
	var img: Image = root.get_texture().get_image()
	var path: String = out_dir.path_join(rel)
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	img.save_png(path)
	records.append({"file": rel, "desc": desc, "how": how, "w": img.get_width(), "h": img.get_height()})
	return img


func crop(rel: String, rect: Rect2i, desc: String = "", how: String = "", scale: float = 1.0) -> void:
	await RenderingServer.frame_post_draw
	var img: Image = root.get_texture().get_image()
	var part: Image = img.get_region(rect)
	if scale != 1.0:
		part.resize(int(part.get_width() * scale), int(part.get_height() * scale), Image.INTERPOLATE_LANCZOS)
	var path: String = out_dir.path_join(rel)
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	part.save_png(path)
	records.append({"file": rel, "desc": desc, "how": how, "w": part.get_width(), "h": part.get_height()})


# ---------------------------------------------------------------------------------------------
# Remotes (other players, bots and NPCs seen from this client)
# ---------------------------------------------------------------------------------------------
## Visible remote views: [{view, pos, kind, realm, name, dist, npc, id, action}] sorted by distance to the player.
func remotes() -> Array:
	var out: Array = []
	if client == null:
		return out
	var rw: Object = client.get_remote_world()
	if rw == null:
		return out
	var views: Dictionary = rw.get(&"_views")
	var me: Vector3 = pos()
	for id: Variant in views.keys():
		var v: Object = views[id]
		if not is_instance_valid(v):
			continue
		var body: Node3D = v.get_body()
		if body == null or not body.visible:
			continue
		var p: Vector3 = v.get_drawn_position()
		out.append({"view": v, "pos": p, "kind": v.get_kind(), "realm": v.get_realm(), "name": v.get_display_name(),
				"dist": me.distance_to(p), "npc": v.get_npc_def_id(), "id": id, "action": v.get_drawn_action()})
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return float(a["dist"]) < float(b["dist"]))
	return out


## The nearest enemy (different realm; neutral NPCs count) within [param max_dist], or {}.
func nearest_enemy(max_dist: float = 60.0) -> Dictionary:
	var my_realm: int = client.get_config().realm
	for r: Dictionary in remotes():
		if float(r["dist"]) > max_dist:
			break
		if int(r["realm"]) == my_realm:
			continue
		if int(r["kind"]) == NetProtocol.EntityKind.NPC and String(r["name"]).begins_with("Mani"):
			continue
		return r
	return {}


## Center of the group of players/bots (not NPCs) with the most neighbours within [param radius] m. {} if there are fewer than [param min_count].
func busiest_spot(radius: float = 9.0, min_count: int = 3, include_npc: bool = true) -> Dictionary:
	var best: Dictionary = {}
	var best_n: int = 0
	var list: Array = remotes()
	for a: Dictionary in list:
		if not include_npc and int(a["kind"]) != NetProtocol.EntityKind.PLAYER:
			continue
		var n: int = 0
		var sum := Vector3.ZERO
		for b: Dictionary in list:
			if not include_npc and int(b["kind"]) != NetProtocol.EntityKind.PLAYER:
				continue
			if (a["pos"] as Vector3).distance_to(b["pos"]) <= radius:
				n += 1
				sum += b["pos"]
		if n > best_n:
			best_n = n
			best = {"center": sum / float(n), "count": n}
	return best if best_n >= min_count else {}


## Screen position (window pixels) of a world point, or (-1, -1) if it is behind the camera.
func to_screen(world_pos: Vector3) -> Vector2:
	var cam: Camera3D = rig.get_camera()
	if cam.is_position_behind(world_pos):
		return Vector2(-1.0, -1.0)
	return cam.unproject_position(world_pos)


func set_hud_visible(v: bool) -> void:
	if hud != null:
		hud.visible = v


func _write_records() -> void:
	var dir: String = out_dir.path_join("indices")
	DirAccess.make_dir_recursive_absolute(dir)
	var f: FileAccess = FileAccess.open(dir.path_join("%s.json" % tag), FileAccess.WRITE)
	f.store_string(JSON.stringify({"tag": tag, "records": records, "notes": notes}, "  "))
	f.close()
