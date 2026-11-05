class_name Nameplates
extends Control
## Nameplates with name and health bar over remote players (UI-07, UI-13). A 2D control covering
## the [HUD] screen: every frame it uses the camera to project ([method Camera3D.unproject_position])
## the head of each remote, at the interpolated position it is drawn at, and places a
## [Nameplate] from a pool.
## [br][br]
## [b]What is shown[/b]:
## [br]- [b]Never your own character[/b] ([RemoteWorld] only holds the others).
## [br]- [b]Allies[/b] (same realm): name in their realm's color and health bar, up to
## [constant ALLY_RANGE] m, with a fade over the last few meters.
## [br]- [b]Enemies[/b]: the name only when the crosshair points at them ([method
## CameraRig.get_aim_ray] against their capsule); the health bar while they are under the crosshair or
## a hit damaged them within the last [constant DAMAGED_SECONDS] s ([method mark_damaged]).
## With neither of the two, there is no plate.
## [br]- The dead ([code]health_q[/code] at 0) and those not being drawn: nothing.
## [br]- Phase 4 (UI-45): with a client ([method set_client]), each one's effects (their STATUS entries, at the
## draw tick) and whether they are knocked down (the DOWNED action in their drawn record: their bar is the knocked-down
## health bar).
## [br][br]
## [b]Occlusion.[/b] A ray from the camera to the head against the world layer ([method
## HitShapes.is_ray_clear]) hides the plate of whoever is behind a wall. To avoid casting a ray
## per player per frame, each player repeats their ray every [constant OCCLUSION_INTERVAL_FRAMES]
## frames (staggered) and in between the last result is used.
## [br][br]
## The pool has [constant MAX_PLATES] plates: if there are more candidates the closest ones are shown.
## Time is driven by [method refresh] (the HUD calls it from [method _process]).

## Maximum distance (m) at which an ally's plate is visible, and start of the fade.
const ALLY_RANGE: float = 40.0
const ALLY_FADE_START: float = 30.0
## Distance (m) up to which each player carries their side mark above their head.
const MARK_RANGE: float = 30.0
## Minimum gap (px) between two stacked plates.
const STACK_GAP: float = 2.0
## The most (px) a plate rises when stacking: higher up you can no longer tell whose it is, so the rest stay
## where they fall. With a large party, the plates overlap a little instead of forming towers.
const MAX_STACK_SHIFT: float = 60.0
## Maximum distance (m) at which an enemy can be targeted with the crosshair or shown as wounded.
const ENEMY_RANGE: float = 70.0
## Name color of party members (provisional, the same blue as the chat's party channel).
const PARTY_COLOR: Color = Color(0.4, 0.7, 1.0, 1.0)
## Seconds a damaged enemy keeps its health bar.
const DAMAGED_SECONDS: float = 5.0
## Plates in the pool.
const MAX_PLATES: int = 32
## Frames between two occlusion rays of the same player.
const OCCLUSION_INTERVAL_FRAMES: int = 6
## Dimensions (m) of the capsule the crosshair is checked against (slightly wider than the
## real one, to aim with some slack) and head height at which the plate is anchored.
const AIM_RADIUS: float = 0.6
const AIM_HEIGHT: float = 1.9
const HEAD_HEIGHT: float = 2.05
## Margin (m) of the occlusion ray: a hit closer to the head than this does not cover it.
const OCCLUSION_MARGIN: float = 0.4

var _world: RemoteWorld = null
var _camera_rig: CameraRig = null
var _own_realm: int = NetProtocol.Realm.NONE
# The local player's party (SOC-08): its members carry the name in the party color.
var _party: PartyState = null
# Network client: each entity's effects and the draw tick (null = no effects).
var _client: NetClient = null
var _plates: Array[Nameplate] = []
# net_id -> plate assigned in the last frame.
var _assigned: Dictionary[int, Nameplate] = {}
# net_id -> seconds (internal clock) of the last damage received.
var _damaged_at: Dictionary[int, float] = {}
# net_id -> the last result of the occlusion ray.
var _occluded: Dictionary[int, bool] = {}
var _clock: float = 0.0
var _frame: int = 0
var _targeted_id: int = 0
var _ray_count: int = 0


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	# "Placas de nombre" ("Nameplates") option in the player's settings.
	ClientSettings.bind_visibility(self, ClientSettings.NAMEPLATES)


func _process(delta: float) -> void:
	refresh(delta)


## Connects the plates to the remotes ([param world]), the camera ([param camera_rig]) and the local
## player's realm ([param own_realm], an [enum NetProtocol.Realm]): those of that realm are allies.
func setup(world: RemoteWorld, camera_rig: CameraRig, own_realm: int) -> void:
	_world = world
	_camera_rig = camera_rig
	_own_realm = own_realm
	_occluded.clear()
	_damaged_at.clear()


## Gives the plates the network client [param client]: the effects of each remote come from it
## ([method NetClient.get_status_tracker]) and so does the draw tick they expire against. null removes them.
func set_client(client: NetClient) -> void:
	_client = client


## Gives the plates the local player's party ([param party]): its members' names are painted with
## [constant PARTY_COLOR] instead of the realm color (SOC-08). null removes it.
func set_party(party: PartyState) -> void:
	_party = party


## The party given to the plates ([method set_party]), or null.
func get_party() -> PartyState:
	return _party


## Records that [param net_id] took a hit now: its health bar is visible for [constant
## DAMAGED_SECONDS] s even if it is not targeted.
func mark_damaged(net_id: int) -> void:
	_damaged_at[net_id] = _clock


## Updates the plates for one frame of [param delta] seconds: chooses which remotes get a plate, places them
## on screen and returns the surplus ones to the pool.
func refresh(delta: float) -> void:
	_clock += delta
	_frame += 1
	_assigned.clear()
	_targeted_id = 0
	var camera: Camera3D = _camera_rig.get_camera() if is_instance_valid(_camera_rig) else null
	if _world == null or not is_instance_valid(_world) or camera == null \
			or not camera.is_inside_tree():
		_release_from(0)
		return
	var candidates: Array[Dictionary] = _collect_candidates(camera)
	candidates.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return float(a["distance"]) < float(b["distance"]))
	var used: int = 0
	for candidate: Dictionary in candidates:
		if used >= MAX_PLATES:
			break
		var plate: Nameplate = _plate_at(used)
		_show(plate, candidate, camera)
		if plate.visible:
			_assigned[int(candidate["net_id"])] = plate
			used += 1
	_release_from(used)
	_stack_overlapping()
	_forget_gone(candidates)


## Plates visible right now.
func get_visible_count() -> int:
	return _assigned.size()


## The plate of [param net_id], or null if it has none right now.
func get_plate_for(net_id: int) -> Nameplate:
	return _assigned.get(net_id)


## Plates created (pool): never more than [constant MAX_PLATES].
func get_pool_size() -> int:
	return _plates.size()


## Remote the crosshair points at right now (0 if none).
func get_targeted_id() -> int:
	return _targeted_id


## Occlusion rays cast since it exists (to check that they are spread out).
func get_ray_count() -> int:
	return _ray_count


## true if [param net_id] was damaged less than [constant DAMAGED_SECONDS] s ago.
func was_damaged_recently(net_id: int) -> bool:
	return _damaged_at.has(net_id) and _clock - float(_damaged_at[net_id]) <= DAMAGED_SECONDS


# --- Candidates -------------------------------------------------------------------------------

# Remotes that are being drawn and are alive, with their distance to the camera and their data.
func _collect_candidates(camera: Camera3D) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var eye: Vector3 = camera.global_position
	var aim: Dictionary = _camera_rig.get_aim_ray()
	var aim_enabled: bool = not _camera_rig.is_cursor_free()
	var best_aim_distance: float = INF
	for view: RemotePlayerView in _world.get_views():
		if not view.is_drawn() or view.get_drawn_health_q() == EntityRecord.HEALTH_Q_DEAD:
			continue
		var feet: Vector3 = view.get_drawn_position()
		var distance: float = eye.distance_to(feet + Vector3(0.0, 1.0, 0.0))
		var net_id: int = view.get_net_id()
		var ally: bool = _is_ally(view)
		var occluded: bool = _is_occluded(net_id, eye, feet + Vector3(0.0, HEAD_HEIGHT, 0.0),
				distance)
		var aimed: bool = false
		if aim_enabled and not occluded and not ally and distance <= ENEMY_RANGE:
			aimed = _is_aimed_at(aim, feet)
		if aimed:
			var along: float = (feet - Vector3(aim["origin"])).dot(Vector3(aim["direction"]))
			if along < best_aim_distance:
				best_aim_distance = along
				_targeted_id = net_id
		result.append({
			"view": view, "net_id": net_id, "distance": distance, "ally": ally,
			"occluded": occluded, "aimed": aimed, "feet": feet,
		})
	# Only one is "the targeted one": the closest along the ray.
	for candidate: Dictionary in result:
		candidate["aimed"] = int(candidate["net_id"]) == _targeted_id
	return result


func _is_ally(view: RemotePlayerView) -> bool:
	return _own_realm != NetProtocol.Realm.NONE and view.get_realm() == _own_realm \
			and view.get_kind() == NetProtocol.EntityKind.PLAYER


func _is_aimed_at(aim: Dictionary, feet: Vector3) -> bool:
	var origin: Vector3 = aim["origin"]
	var direction: Vector3 = aim["direction"]
	return HitShapes.segment_hits_capsule(origin, origin + direction * ENEMY_RANGE, feet,
			AIM_RADIUS, AIM_HEIGHT)


# Occlusion with one ray per player every OCCLUSION_INTERVAL_FRAMES frames (staggered by id).
func _is_occluded(net_id: int, eye: Vector3, head: Vector3, distance: float) -> bool:
	var known: bool = _occluded.has(net_id)
	if known and (_frame + net_id) % OCCLUSION_INTERVAL_FRAMES != 0:
		return bool(_occluded[net_id])
	# find_world_3d: also inside a SubViewport with its own world (own_world_3d), where get_world_3d()
	# is null (the network tests put a HUD in each bot's viewport).
	var world: World3D = get_viewport().find_world_3d() if is_inside_tree() else null
	var space: PhysicsDirectSpaceState3D = world.direct_space_state if world != null else null
	if space == null:
		_occluded[net_id] = false
		return false
	_ray_count += 1
	var blocked: bool = is_head_hidden(space, eye, head)
	_occluded[net_id] = blocked
	return blocked


## true if the world or a structure ([constant HitShapes.LINE_OF_SIGHT_MASK]) covers the head [param head] seen
## from [param eye] (the camera). The ray is cut [constant OCCLUSION_MARGIN] m before the head so that the
## floor or wall the player is standing on does not cover it. It is the plates' occlusion test, and the same one the
## social menu ([method SocialTarget.find]) uses to avoid targeting through walls.
static func is_head_hidden(space: PhysicsDirectSpaceState3D, eye: Vector3, head: Vector3) -> bool:
	var toward: Vector3 = head - eye
	var length: float = toward.length()
	if length <= OCCLUSION_MARGIN:
		return false
	var target: Vector3 = eye + toward * ((length - OCCLUSION_MARGIN) / length)
	return not HitShapes.is_ray_clear(space, eye, target)


# --- Plates -----------------------------------------------------------------------------------

# Decides what a candidate's plate shows and places it; if it should not be seen, leaves it hidden.
func _show(plate: Nameplate, candidate: Dictionary, camera: Camera3D) -> void:
	var view: RemotePlayerView = candidate["view"]
	var net_id: int = candidate["net_id"]
	var distance: float = candidate["distance"]
	var ally: bool = candidate["ally"]
	var show_name: bool = false
	var show_bar: bool = false
	var alpha: float = 1.0
	if bool(candidate["occluded"]):
		plate.release()
		return
	if ally:
		if distance > ALLY_RANGE:
			plate.release()
			return
		show_name = true
		show_bar = true
		alpha = 1.0 - smoothstep(ALLY_FADE_START, ALLY_RANGE, distance)
	else:
		var aimed: bool = candidate["aimed"]
		var damaged: bool = was_damaged_recently(net_id) and distance <= ENEMY_RANGE
		if not aimed and not damaged:
			# Neither aimed at nor wounded: only the side mark (a diamond) within MARK_RANGE m, to
			# tell an enemy from an ally at a distance (UI-56). NPCs do not carry it.
			if view.get_kind() != NetProtocol.EntityKind.PLAYER or distance > MARK_RANGE:
				plate.release()
				return
		else:
			show_name = aimed
			show_bar = true
	var head: Vector3 = Vector3(candidate["feet"]) + Vector3(0.0, HEAD_HEIGHT, 0.0)
	if camera.is_position_behind(head):
		plate.release()
		return
	var fraction: float = EntityRecord.health_fraction(view.get_drawn_health_q())
	var realm_color: Color = RealmCatalog.color_of(RealmCatalog.id_of_code(view.get_realm()))
	if ally and _party != null and _party.has_member(net_id):
		realm_color = PARTY_COLOR
	plate.configure(net_id, view.get_display_name(), realm_color, show_name, show_bar, fraction,
			ally, alpha)
	plate.set_near(distance <= Nameplate.NEAR_RANGE)
	var mark: int = Nameplate.Mark.NONE
	if view.get_kind() == NetProtocol.EntityKind.PLAYER and distance <= MARK_RANGE:
		mark = Nameplate.Mark.ALLY if ally else Nameplate.Mark.ENEMY
	plate.set_mark(mark, realm_color)
	plate.set_downed((view.get_drawn_action() & 15) == CombatState.Action.DOWNED)
	# The level only for allies (an enemy's arrives as 0 and is not shown, docs/progresion.md §7.3).
	plate.set_level(view.get_level() if ally else 0)
	if is_instance_valid(_client):
		plate.set_statuses(_client.get_status_tracker(net_id),
				int(_client.get_interpolation_clock().get_render_tick()))
	plate.place(camera.unproject_position(head))
	plate.visible = true


# Stacks upward the plates that touch (UI-56): the others rise just enough not to overlap them, up to
# [constant MAX_STACK_SHIFT]. The order is stable (by net_id) so the plates do not jump from one frame to the next.
func _stack_overlapping() -> void:
	var plates: Array[Nameplate] = []
	var rects: Array[Rect2] = []
	for plate: Nameplate in _assigned.values():
		var content: Rect2 = plate.get_content_rect()
		plates.append(plate)
		rects.append(Rect2(plate.position + content.position, content.size))
	var order: Array[int] = []
	for index: int in plates.size():
		order.append(index)
	order.sort_custom(func(a: int, b: int) -> bool:
		return plates[a].get_net_id() < plates[b].get_net_id())
	var shifts: PackedFloat32Array = stack_shifts(rects, order, STACK_GAP, MAX_STACK_SHIFT)
	for index: int in plates.size():
		plates[index].position.y -= shifts[index]


## How much each rectangle of [param rects] rises (in px, 0 or more) so that none overlaps another. They are handled in
## the order of [param order] (indices): the first does not move and each next one rises until it is clear of those
## already placed, with [param gap] px of air, and none rises more than [param max_shift]. Returns one value per rectangle, in the original order.
static func stack_shifts(rects: Array[Rect2], order: Array[int], gap: float,
		max_shift: float = INF) -> PackedFloat32Array:
	var shifts := PackedFloat32Array()
	shifts.resize(rects.size())
	var placed: Array[Rect2] = []
	for index: int in order:
		var rect: Rect2 = rects[index]
		var shift: float = 0.0
		# Each pass that collides raises the plate it collides with; with N plates, N passes are enough.
		for _pass: int in order.size():
			var moved: bool = false
			for other: Rect2 in placed:
				var current := Rect2(rect.position - Vector2(0.0, shift), rect.size)
				if current.grow(gap * 0.5).intersects(other):
					shift = rect.end.y - other.position.y + gap
					moved = true
			if not moved:
				break
		shift = minf(shift, max_shift)
		shifts[index] = shift
		placed.append(Rect2(rect.position - Vector2(0.0, shift), rect.size))
	return shifts


func _plate_at(index: int) -> Nameplate:
	while _plates.size() <= index and _plates.size() < MAX_PLATES:
		var plate := Nameplate.new()
		plate.name = "Placa%d" % _plates.size()
		add_child(plate)
		_plates.append(plate)
	return _plates[index]


# Hides the pool's plates from index [param first] onward.
func _release_from(first: int) -> void:
	for i: int in range(first, _plates.size()):
		_plates[i].release()


# Forgets the occlusion and damage of whoever is no longer there.
func _forget_gone(candidates: Array[Dictionary]) -> void:
	var present: Dictionary[int, bool] = {}
	for candidate: Dictionary in candidates:
		present[int(candidate["net_id"])] = true
	for net_id: int in _occluded.keys():
		if not present.has(net_id):
			_occluded.erase(net_id)
	for net_id: int in _damaged_at.keys():
		if _clock - float(_damaged_at[net_id]) > DAMAGED_SECONDS * 4.0:
			_damaged_at.erase(net_id)
