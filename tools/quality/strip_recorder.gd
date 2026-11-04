extends RefCounted
## Quality capture bench (TEC-50): strip recorder for a followed character (a remote one, or the local one).
##
## Stores in a ring, every 50 ms, the last seconds of the followed character: a crop of the game's real
## camera (480 x 540, the same framing as the sandbox strips) and its own side view (a SubViewport that looks
## at the character from one side, perpendicular to the line joining it to the client, at 5 m), which no other body
## can block. With each sample it stores what the character's animation layer shows: combat action, phase,
## speed and the clip, its time and its speed ([method CharacterAnimator.get_debug_state]).
## [br][br]
## When a scenario sees the moment it is looking for (for example, the rising edge of [code]BLOCK[/code] on the remote) it calls
## [method extract] with that instant: the strip comes out of the ring with a few frames from before, so the
## start of short actions is not lost (a dodge lasts 0.45 s). [method save_strip] writes it in the same format as
## [code]anim_strips.gd[/code] ([code]<raw>/<id>/ciclo/{game,side}_NN.png[/code] and [code]meta.json[/code]), which
## [code]compose_strips.py[/code] joins into grids.
## [br][br]
## Each sample also notes whether any other body blocks or surrounds the followed one ([code]occluded[/code], [code]neighbors[/code]):
## a strip with blocked frames proves nothing and the index says so.
## [br][br]
## Use from the driver: [code]d.recorder = Recorder.new(d)[/code], [method follow_remote] or [method follow_local] and
## [code]await d.step()[/code] instead of [code]await d.frames(1)[/code].

const GAME_SIZE: Vector2i = Vector2i(480, 540)
const SIDE_SIZE: Vector2i = Vector2i(400, 520)
## Milliseconds between samples (20 per second).
const SAMPLE_MS: int = 50
## How much history the ring keeps.
const RING_MS: int = 4500
const SIDE_DISTANCE: float = 5.0
## The closest (m) the side camera gets to a character with a wall in between, and clearance (m) from the wall.
const SIDE_MIN_DISTANCE: float = 2.2
const SIDE_WALL_MARGIN: float = 0.4
const SIDE_HEIGHT: float = 1.25
const SIDE_LOOK_HEIGHT: float = 0.95
const SIDE_FOV: float = 42.0
## Another body within this distance (m) on the ground plane counts as a neighbour.
const NEIGHBOR_RADIUS: float = 4.0
## Half-width (m) with which a body closer to the camera blocks the followed one.
const OCCLUDER_HALF_WIDTH: float = 0.45

var _d: Variant
var _view: Object = null
var _local: bool = false
var _ring: Array[Dictionary] = []
var _vp: SubViewport
var _cam: Camera3D
var _last_ms: int = -100000
var _due: bool = false
var _game_center: Vector2i = Vector2i(960, 540)
var _side_sign: float = 1.0


func _init(driver: Variant) -> void:
	_d = driver
	_vp = SubViewport.new()
	_vp.size = SIDE_SIZE
	_vp.msaa_3d = Viewport.MSAA_4X
	_vp.render_target_update_mode = SubViewport.UPDATE_DISABLED
	_vp.gui_disable_input = true
	_d.root.add_child(_vp)
	_cam = Camera3D.new()
	_cam.fov = SIDE_FOV
	_cam.near = 0.1
	_cam.far = 400.0
	_cam.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	_vp.add_child(_cam)
	_cam.current = true


## Follows a remote character (a [RemotePlayerView]). Empties the ring.
func follow_remote(view: Object) -> void:
	_view = view
	_local = false
	_ring.clear()


## Follows the client's character. Empties the ring.
func follow_local() -> void:
	_view = null
	_local = true
	_ring.clear()


func clear() -> void:
	_view = null
	_local = false
	_ring.clear()


func is_following() -> bool:
	if _local:
		return _d.ch != null and is_instance_valid(_d.ch)
	return _view != null and is_instance_valid(_view)


## The followed remote (null if following the local one or nobody).
func get_view() -> Object:
	return _view


## Time (ms) of the last stored sample, or -1.
func last_sample_ms() -> int:
	return int(_ring[-1]["ms"]) if not _ring.is_empty() else -1


## The last sample (its [code]meta[/code]), or {}.
func last_meta() -> Dictionary:
	return _ring[-1]["meta"] if not _ring.is_empty() else {}


## The sample before the last (its [code]meta[/code]), or {}: useful for detecting rising edges.
func previous_meta() -> Dictionary:
	return _ring[-2]["meta"] if _ring.size() >= 2 else {}


# --- Per frame --------------------------------------------------------------------------------

## Before drawing: if a sample is due, positions the side camera and requests a draw.
func before_draw() -> void:
	_due = false
	if not is_following():
		return
	var now: int = Time.get_ticks_msec()
	if now - _last_ms < SAMPLE_MS:
		return
	_due = true
	var p: Vector3 = _target_position()
	var me: Vector3 = _d.pos()
	var toward: Vector3 = Vector3(me.x - p.x, 0.0, me.z - p.z)
	if _local:
		# The local one is viewed from the side relative to its line towards the nearest enemy (if there is none, from the camera's front).
		var enemy: Dictionary = _d.nearest_enemy(30.0)
		if not enemy.is_empty():
			var q: Vector3 = enemy["pos"]
			toward = Vector3(q.x - p.x, 0.0, q.z - p.z)
	if toward.length() < 0.1:
		toward = Vector3(0.0, 0.0, -1.0)
	toward = toward.normalized()
	var side_dir: Vector3 = Vector3(toward.z, 0.0, -toward.x) * _side_sign
	_cam.global_position = _free_camera_position(p + Vector3(0.0, SIDE_HEIGHT, 0.0), side_dir)
	_cam.look_at(p + Vector3(0.0, SIDE_LOOK_HEIGHT, 0.0), Vector3.UP)
	_game_center = _project_center(p)
	_vp.render_target_update_mode = SubViewport.UPDATE_ONCE


## After drawing: stores the sample if it was due.
func after_draw() -> void:
	if not _due:
		return
	_due = false
	var now: int = Time.get_ticks_msec()
	_last_ms = now
	var full: Image = _d.root.get_texture().get_image()
	var crop := Rect2i(_game_center - GAME_SIZE / 2, GAME_SIZE)
	var sx: float = float(full.get_width()) / _d.root.get_visible_rect().size.x
	if absf(sx - 1.0) > 0.01:
		crop = Rect2i(Vector2i(Vector2(crop.position) * sx), Vector2i(Vector2(crop.size) * sx))
	var game: Image = full.get_region(crop)
	var side: Image = _vp.get_texture().get_image()
	var meta: Dictionary = _sample_meta()
	meta["ms"] = now
	_ring.append({"ms": now, "game": game, "side": side, "meta": meta})
	while not _ring.is_empty() and now - int(_ring[0]["ms"]) > RING_MS:
		_ring.pop_front()


# --- Extraction -------------------------------------------------------------------------------

## [param count] samples from the ring, the nearest to each instant
## [code]trigger_ms - pre_ms + k * interval_ms[/code]. Returns [] if the ring does not yet reach that start.
func extract(trigger_ms: int, pre_ms: int, interval_ms: int, count: int) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if _ring.is_empty():
		return out
	var first_ms: int = trigger_ms - pre_ms
	if first_ms < int(_ring[0]["ms"]) - SAMPLE_MS / 5:
		return out
	for k: int in count:
		var want: int = first_ms + k * interval_ms
		var best: Dictionary = _ring[0]
		for sample: Dictionary in _ring:
			if absi(int(sample["ms"]) - want) < absi(int(best["ms"]) - want):
				best = sample
		out.append(best)
	return out


## Writes the strip [param frames] (what [method extract] returned) into [param raw_dir]/[param id]/ciclo. The
## frames carry, besides the sample, the local client's hits ([code]hit_events[/code] of the driver) that
## fall in their interval.
func save_strip(raw_dir: String, id: String, title: String, frames_in: Array[Dictionary], note_text: String = "",
		extra: Dictionary = {}) -> void:
	if frames_in.is_empty():
		return
	var dir: String = raw_dir.path_join(id).path_join("ciclo")
	DirAccess.make_dir_recursive_absolute(dir)
	var t0_ms: int = int(frames_in[0]["ms"])
	var frames_meta: Array = []
	var clips: Dictionary = {}
	var occluded: int = 0
	var max_neighbors: int = 0
	var with_clip: int = 0
	for k: int in frames_in.size():
		var sample: Dictionary = frames_in[k]
		(sample["game"] as Image).save_png(dir.path_join("game_%02d.png" % k))
		(sample["side"] as Image).save_png(dir.path_join("side_%02d.png" % k))
		var m: Dictionary = (sample["meta"] as Dictionary).duplicate()
		var ms: int = int(sample["ms"])
		m["k"] = k
		m["t"] = snappedf(float(ms - t0_ms) / 1000.0, 0.001)
		m["rt"] = roundi(float(ms - t0_ms) * 0.06)
		var hit: String = _hit_label(ms)
		if not hit.is_empty():
			m["hit"] = hit
		frames_meta.append(m)
		var clip: String = String(m.get("clip", ""))
		if not clip.is_empty():
			clips[clip] = true
			with_clip += 1
		if bool(m.get("occluded", false)):
			occluded += 1
		max_neighbors = maxi(max_neighbors, int(m.get("neighbors", 0)))
	var meta: Dictionary = {
		"id": id, "name": "ciclo", "title": title, "desc": String(extra.get("desc", "")), "note": note_text,
		"frames": frames_meta, "from": 0, "to": 0, "weapon": String(extra.get("weapon", "")),
		"source": "online", "target": extra.get("target", {}),
		"layer_clips": clips.keys(), "frames_with_clip": with_clip,
		"occluded_frames": occluded, "max_neighbors": max_neighbors,
	}
	var f: FileAccess = FileAccess.open(dir.path_join("meta.json"), FileAccess.WRITE)
	f.store_string(JSON.stringify(meta, "  "))
	f.close()


## Data of the followed one for the [code]meta.json[/code]: name, type, NPC definition and weapon.
func target_info() -> Dictionary:
	var weapon_id: int = 0
	var weapon_name: String = ""
	if _local:
		weapon_id = _d.ch.combat.weapon_id if _d.ch != null else 0
	elif _view != null and is_instance_valid(_view):
		weapon_id = int(_view.get_active_weapon_id())
	if weapon_id > 0:
		var w: WeaponTicks = CombatCatalog.weapon(weapon_id)
		weapon_name = String(w.name) if w != null else ""
	var info: Dictionary = {"local": _local, "weapon": weapon_name}
	if _view != null and is_instance_valid(_view):
		info["name"] = _view.get_display_name()
		info["kind"] = _view.get_kind()
		info["realm"] = _view.get_realm()
		info["npc_def"] = _view.get_npc_def_id()
	return info


# --- Internals --------------------------------------------------------------------------------

func _hit_label(ms: int) -> String:
	var half: int = SAMPLE_MS / 2
	var found: String = ""
	for e: Dictionary in _d.hit_events:
		if absi(int(e["ms"]) - ms) > half:
			continue
		if String(e["kind"]) == "sound":
			continue
		var label: String = "PARADA" if bool(e["parried"]) else ("BLOQUEADO" if bool(e["blocked"]) else
				("GOLPE" if String(e["kind"]) == "taken" else "ACIERTO"))
		found = label if found.is_empty() else found + "+" + label
	return found


# Where to put the side camera: SIDE_DISTANCE m from [param origin] towards [param side_dir] or, if there is a wall or a trunk
# in between (the fort palisade, a wall), towards the opposite side or closer, so that it does not end up inside.
func _free_camera_position(origin: Vector3, side_dir: Vector3) -> Vector3:
	var space: PhysicsDirectSpaceState3D = _d.root.world_3d.direct_space_state
	var best_dir: Vector3 = side_dir
	var best_len: float = -1.0
	for sign_value: float in [1.0, -1.0]:
		var dir: Vector3 = side_dir * sign_value
		var query := PhysicsRayQueryParameters3D.create(origin, origin + dir * SIDE_DISTANCE, 1)
		var hit: Dictionary = space.intersect_ray(query)
		var length: float = SIDE_DISTANCE if hit.is_empty() else origin.distance_to(hit["position"]) - SIDE_WALL_MARGIN
		if length > best_len:
			best_len = length
			best_dir = dir
		if hit.is_empty():
			break
	return origin + best_dir * clampf(best_len, SIDE_MIN_DISTANCE, SIDE_DISTANCE)


func _target_body() -> PlayerCharacter:
	if _local:
		return _d.ch
	if _view != null and is_instance_valid(_view):
		return _view.get_body()
	return null


func _target_position() -> Vector3:
	if _local:
		return _d.ch.global_position
	return _view.get_drawn_position()


func _project_center(p: Vector3) -> Vector2i:
	var cam: Camera3D = _d.rig.get_camera()
	var size: Vector2 = _d.root.get_visible_rect().size
	var sp: Vector2 = cam.unproject_position(p + Vector3(0.0, 0.95, 0.0))
	var cx: int = clampi(int(sp.x), GAME_SIZE.x / 2, int(size.x) - GAME_SIZE.x / 2)
	var cy: int = clampi(int(sp.y), GAME_SIZE.y / 2, int(size.y) - GAME_SIZE.y / 2)
	return Vector2i(cx, cy)


# What the followed one's animation layer shows and its surroundings at this instant.
func _sample_meta() -> Dictionary:
	var body: PlayerCharacter = _target_body()
	var action: int = 0
	var phase: int = 0
	if _local:
		action = _d.ch.combat.action
	else:
		var byte: int = int(_view.get_drawn_action())
		action = clampi(byte & 0x0F, 0, CombatState.Action.size() - 1)
		phase = (byte >> 4) & 0x03
	var m: Dictionary = {
		"ms": Time.get_ticks_msec(),
		"action": CombatState.Action.keys()[clampi(action, 0, CombatState.Action.size() - 1)],
		"phase": phase,
		"speed": 0.0, "air": "", "clip": "", "clip_t": 0.0, "clip_speed": 0.0, "upper": false, "pos_y": 0.0,
		"neighbors": 0, "occluded": false,
	}
	if body == null:
		return m
	m["speed"] = snappedf(body.get_horizontal_speed(), 0.01)
	m["pos_y"] = snappedf(body.global_position.y, 0.01)
	var visual: HumanoidVisual = body.get_node_or_null(^"Visual/HumanoidVisual") as HumanoidVisual
	if visual == null:
		visual = body.get_node_or_null(^"Visual") as HumanoidVisual
	if visual != null and visual.get_animator() != null:
		var dbg: Dictionary = visual.get_animator().get_debug_state()
		var combat: Dictionary = dbg.get("combat", {})
		m["air"] = String(dbg.get("air_state", ""))
		m["clip"] = String(combat.get("animation", ""))
		m["clip_t"] = snappedf(float(combat.get("time", 0.0)), 0.001)
		m["clip_speed"] = snappedf(float(combat.get("speed", 0.0)), 0.01)
		m["upper"] = bool(combat.get("upper_body", false))
	_add_surroundings(m, _target_position())
	return m


# How many bodies are within NEIGHBOR_RADIUS of the followed one and whether any, closer to the game camera, blocks it.
func _add_surroundings(m: Dictionary, p: Vector3) -> void:
	var others: Array[Vector3] = []
	if not _local and _d.ch != null:
		others.append(_d.ch.global_position)
	for r: Dictionary in _d.remotes():
		if not _local and r["view"] == _view:
			continue
		others.append(r["pos"])
	var cam: Camera3D = _d.rig.get_camera()
	var cam_pos: Vector3 = cam.global_position
	var target_depth: float = cam_pos.distance_to(p)
	var right: Vector3 = cam.global_transform.basis.x
	var center: Vector2 = cam.unproject_position(p + Vector3(0.0, 0.95, 0.0))
	var px_per_m: float = (cam.unproject_position(p + Vector3(0.0, 0.95, 0.0) + right) - center).length()
	var neighbors: int = 0
	var occluded: bool = false
	for q: Vector3 in others:
		if Vector2(q.x - p.x, q.z - p.z).length() <= NEIGHBOR_RADIUS:
			neighbors += 1
		if cam.is_position_behind(q) or cam_pos.distance_to(q) >= target_depth:
			continue
		var sq: Vector2 = cam.unproject_position(q + Vector3(0.0, 0.95, 0.0))
		if absf(sq.x - center.x) < OCCLUDER_HALF_WIDTH * px_per_m and absf(sq.y - center.y) < 1.2 * px_per_m:
			occluded = true
	m["neighbors"] = neighbors
	m["occluded"] = occluded
