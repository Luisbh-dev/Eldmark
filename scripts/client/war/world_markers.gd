class_name WorldMarkers
extends Control
## World markers (UI-19, docs/fortress.md section 6): for each [WorldMarker] (the fort, its
## gate, the capture circle, the camps and the passes) an icon projected onto the screen with its
## name and the distance in meters. If the place falls outside the view (to a side, above, below or
## behind) the icon sticks to the screen edge with an arrow toward where it is, and up close it
## fades out so as not to cover anything.
## [br][br]
## The markers come from [MarkerSource] (baked map and fort state) and are computed every
## frame with [method refresh]; [method project] is the pure projection (camera, screen size
## and world point). Distances are horizontal, from the player. Measurements and colors
## provisional.
## [br][br]
## [b]What gets drawn (UI-54).[/b] Before, every place was labeled at once and a soup of names piled up under the crosshair.
## Now ([method select_shown]):
## [br]- Always, the [b]current objective[/b] ([method pick_objective]: the capture circle if active and, if not, the
## nearest fort that is not of the player's own realm), with its distance and, if it falls outside the view, stuck to the edge with an
## arrow.
## [br]- The [b]name[/b] only when the crosshair is within [constant AIM_RADIUS] px of the icon or with Alt held
## (which frees the cursor to look around at ease).
## [br]- The other places (gate, camps, passes) only appear, with their name, when the crosshair gets close or with Alt; never
## stuck to the edge.
## [br]- Up to [constant MAX_SHOWN] at once, with no two icons closer than [constant LABEL_SPACING] (their
## labels would overlap) and, for [constant COMBAT_SECONDS] s after a hit dealt or received
## ([method notify_combat]), only the objective and without names.
## [br]- The camp and the pass of an enemy realm are not marked ([method is_markable]).
## [br]- Nothing stuck to the HUD edges: the bottom edge leaves [constant BOTTOM_MARGIN] px free.
## [br]- [b]Text never falls closer than [constant LABEL_MIN_AIM_DISTANCE] px to the crosshair[/b] ([method push_from_aim]):
## if the icon is near it, the label moves aside and stays joined to the icon by a guide line.
## [br][br]
## Client only.

## Distance (m) beyond which a place is not marked, per kind; the capture circle only up close.
const MAX_DISTANCE: float = 700.0
const CIRCLE_MAX_DISTANCE: float = 150.0
## Depth (m) below which a point counts as behind the camera.
const MIN_DEPTH: float = 0.05
## Margin (px) to the screen edge where icons that leave the view stick.
const EDGE_MARGIN: float = 44.0
## Distances (m) between which a marker goes from invisible to opaque as you approach.
const FADE_NEAR_START: float = 5.0
const FADE_NEAR_END: float = 16.0
## Free margin (px) at the bottom edge of the screen (the action bar and the health bars).
const BOTTOM_MARGIN: float = 150.0
## Minimum distance (px) between the crosshair and any marker label.
const LABEL_MIN_AIM_DISTANCE: float = 150.0
const ICON_SIZE: float = 9.0
const FONT_SIZE: int = 14
const TEXT_COLOR: Color = Color(1.0, 1.0, 1.0, 0.95)
const TEXT_OUTLINE: Color = Color(0.0, 0.0, 0.0, 0.85)
## Distance (px) from the crosshair (the screen center) to an icon below which it shows its name.
const AIM_RADIUS: float = 80.0
## Maximum markers on screen at once.
const MAX_SHOWN: int = 3
## Seconds after a hit dealt or received during which only the objective is drawn, without names.
const COMBAT_SECONDS: float = 5.0
## Minimum separation (px, in x and y) between the icons of two markers drawn at once: any closer, their labels would
## overlap (the fort and a pass that falls behind it in the distance), and the one that comes later is not drawn.
const LABEL_SPACING: Vector2 = Vector2(240.0, 24.0)

var _client: NetClient = null
var _view: FortressView = null
var _camera_rig: CameraRig = null
var _map: ZoneMapDefinition = null
var _items: Array[Dictionary] = []
var _objective_id: StringName = &""
var _combat_left: float = 0.0


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)


func _process(delta: float) -> void:
	_combat_left = maxf(_combat_left - delta, 0.0)
	refresh()


## Signals that a hit was dealt or received: for [constant COMBAT_SECONDS] s only the objective is drawn, without names.
func notify_combat() -> void:
	_combat_left = COMBAT_SECONDS


## true while the [method notify_combat] notice lasts.
func is_in_combat() -> bool:
	return _combat_left > 0.0


## Connects the markers to the client (where the player is), the fort view, the camera and the
## zone's baked map ([param map] can be null).
func bind(client: NetClient, view: FortressView, camera_rig: CameraRig, map: ZoneMapDefinition) -> void:
	_client = client
	_view = view
	_camera_rig = camera_rig
	_map = map
	_items.clear()
	_objective_id = &""


## Recomputes where each marker falls on the screen, which ones are drawn, and redraws.
func refresh() -> void:
	_items.clear()
	var camera: Camera3D = _camera_rig.get_camera() if is_instance_valid(_camera_rig) else null
	var character: PlayerCharacter = _client.get_character() if is_instance_valid(_client) else null
	if camera == null or not camera.is_inside_tree() or character == null or not is_instance_valid(character):
		queue_redraw()
		return
	var here: Vector3 = character.global_position if character.is_inside_tree() else character.position
	var screen_size: Vector2 = camera.get_viewport().get_visible_rect().size
	var markers: Array[WorldMarker] = MarkerSource.build(_map, _view)
	var own_realm: int = _client.get_config().realm if _client.get_config() != null else NetProtocol.Realm.NONE
	var objective: WorldMarker = pick_objective(markers, here, own_realm)
	var markable: Array[WorldMarker] = []
	for candidate: WorldMarker in markers:
		if is_markable(candidate, own_realm):
			markable.append(candidate)
	markers = markable
	_objective_id = objective.id if objective != null else &""
	for marker: WorldMarker in markers:
		var distance: float = marker.distance_from(here)
		if distance > max_distance_for(marker.kind):
			continue
		var projected: Dictionary = project(camera, screen_size, marker.position, EDGE_MARGIN, BOTTOM_MARGIN)
		_items.append({
			"marker": marker, "distance": distance, "screen": projected["screen"],
			"on_edge": projected["on_edge"], "angle": projected["angle"],
			"alpha": fade_alpha(distance), "objective": marker.id == _objective_id,
			"shown": false, "label": false,
		})
	var alt_held: bool = InputMap.has_action(&"free_cursor") and Input.is_action_pressed(&"free_cursor")
	select_shown(_items, screen_size * 0.5, alt_held, is_in_combat())
	queue_redraw()


## What is being drawn: [code]{"marker", "distance", "screen", "on_edge", "angle", "alpha"}[/code].
func get_items() -> Array[Dictionary]:
	return _items.duplicate()


## The elements drawn right now (those of [method get_items] with [code]shown[/code]).
func get_shown_items() -> Array[Dictionary]:
	var shown: Array[Dictionary] = []
	for item: Dictionary in _items:
		if bool(item["shown"]):
			shown.append(item)
	return shown


## Id of the marker that is the current objective (empty if there is none).
func get_objective_id() -> StringName:
	return _objective_id


## The element of the marker with id [param id], or an empty dictionary.
func get_item(id: StringName) -> Dictionary:
	for item: Dictionary in _items:
		if (item["marker"] as WorldMarker).id == id:
			return item
	return {}


## The current objective among [param markers] seen from [param origin] and by someone of realm [param own_realm]: the
## nearest capture circle if any is active; otherwise, the nearest fort that is not of [param own_realm] (or the
## nearest one if they are all theirs). null if there is neither a circle nor a fort.
static func pick_objective(markers: Array[WorldMarker], origin: Vector3, own_realm: int) -> WorldMarker:
	var circle: WorldMarker = _nearest(markers, origin, func(marker: WorldMarker) -> bool:
		return marker.kind == WorldMarker.Kind.CIRCLE)
	if circle != null:
		return circle
	var foreign: WorldMarker = _nearest(markers, origin, func(marker: WorldMarker) -> bool:
		return marker.kind == WorldMarker.Kind.FORT \
				and (own_realm == NetProtocol.Realm.NONE or marker.realm != own_realm))
	if foreign != null:
		return foreign
	return _nearest(markers, origin, func(marker: WorldMarker) -> bool: return marker.kind == WorldMarker.Kind.FORT)


## Decides which of [param items] (those of [method refresh]: [code]marker[/code], [code]screen[/code], [code]on_edge[/code],
## [code]alpha[/code] and [code]objective[/code]) are drawn and with a name, and records it on each ([code]shown[/code],
## [code]label[/code]). [param aim] is the crosshair point on the screen. See the rules in the class documentation.
static func select_shown(items: Array[Dictionary], aim: Vector2, alt_held: bool, in_combat: bool) -> void:
	var candidates: Array[Dictionary] = []
	for item: Dictionary in items:
		item["shown"] = false
		item["label"] = false
		if float(item["alpha"]) <= 0.01:
			continue
		var on_edge: bool = bool(item["on_edge"])
		var near_aim: bool = not on_edge and (item["screen"] as Vector2).distance_to(aim) <= AIM_RADIUS
		var wants_name: bool = not in_combat and (near_aim or (alt_held and not on_edge))
		if bool(item["objective"]):
			item["shown"] = true
			item["label"] = wants_name
		elif not in_combat and not on_edge and (near_aim or alt_held):
			item["label"] = true
			candidates.append(item)
	# With room for MAX_SHOWN in total (the objective already counts), the ones closest to the crosshair.
	var room: int = MAX_SHOWN
	for item: Dictionary in items:
		if bool(item["shown"]):
			room -= 1
	candidates.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return (a["screen"] as Vector2).distance_to(aim) < (b["screen"] as Vector2).distance_to(aim))
	var drawn: Array[Vector2] = []
	for item: Dictionary in items:
		if bool(item["shown"]):
			drawn.append(item["screen"])
	for candidate: Dictionary in candidates:
		if room <= 0:
			break
		var screen: Vector2 = candidate["screen"]
		var overlaps: bool = false
		for other: Vector2 in drawn:
			if absf(screen.x - other.x) < LABEL_SPACING.x and absf(screen.y - other.y) < LABEL_SPACING.y:
				overlaps = true
				break
		if overlaps:
			continue
		candidate["shown"] = true
		drawn.append(screen)
		room -= 1


## Projects [param world] with [param camera] onto a screen of [param screen_size] pixels. Returns
## [code]{"screen": Vector2, "on_edge": bool, "behind": bool, "angle": float}[/code]: the position on the
## screen; whether it is stuck to the edge (outside the view or behind, [param margin] px from the edge);
## whether it is behind the camera; and the angle (radians, 0 = up, positive toward the right) of the
## direction in which it falls from the center, for the arrow.
static func project(camera: Camera3D, screen_size: Vector2, world: Vector3, margin: float,
		bottom_margin: float = -1.0) -> Dictionary:
	var camera_transform: Transform3D = camera.get_camera_transform()
	var local: Vector3 = camera_transform.affine_inverse() * world
	# Behind the camera (or on its plane, where the projection does not exist) the icon goes to the edge on the
	# side toward which the point falls in the camera plane.
	var behind: bool = -local.z <= MIN_DEPTH
	var center: Vector2 = screen_size * 0.5
	var screen: Vector2 = center
	var direction: Vector2 = Vector2(local.x, -local.y)
	if not behind:
		screen = camera.unproject_position(world)
		direction = screen - center
	var bottom: float = margin if bottom_margin < 0.0 else bottom_margin
	var inside := Rect2(Vector2(margin, margin), screen_size - Vector2(margin * 2.0, margin + bottom))
	var on_edge: bool = behind or not inside.has_point(screen)
	if on_edge:
		if direction.length() < 0.001:
			direction = Vector2(0.0, 1.0)
		screen = edge_point(center, direction, inside)
	return {"screen": screen, "on_edge": on_edge, "behind": behind, "angle": atan2(direction.x, -direction.y)}


## Point where the ray from [param center] toward [param direction] leaves the rectangle [param inside].
static func edge_point(center: Vector2, direction: Vector2, inside: Rect2) -> Vector2:
	# The rectangle may not be centered on [param center] (the bottom margin is larger): it is measured toward each side.
	var limit_x: float = INF
	if absf(direction.x) > 0.0001:
		limit_x = ((inside.end.x if direction.x > 0.0 else inside.position.x) - center.x) / direction.x
	var limit_y: float = INF
	if absf(direction.y) > 0.0001:
		limit_y = ((inside.end.y if direction.y > 0.0 else inside.position.y) - center.y) / direction.y
	return center + direction * minf(limit_x, limit_y)


## false for the camp and the pass of a realm that is not [param own_realm]: they are not marked (they only help the enemy).
static func is_markable(marker: WorldMarker, own_realm: int) -> bool:
	if marker.kind != WorldMarker.Kind.CAMP and marker.kind != WorldMarker.Kind.PASS:
		return true
	return marker.realm == 0 or own_realm == NetProtocol.Realm.NONE or marker.realm == own_realm


## Moves [param rect] (the label) in a straight line away from [param aim] until its closest point is
## [param min_distance] px or more from it. If it already complies, it is left where it is; if it is right on top, it is moved up.
static func push_from_aim(rect: Rect2, aim: Vector2, min_distance: float) -> Rect2:
	var closest: Vector2 = Vector2(clampf(aim.x, rect.position.x, rect.end.x), clampf(aim.y, rect.position.y, rect.end.y))
	var gap: float = closest.distance_to(aim)
	if gap >= min_distance:
		return rect
	var direction: Vector2 = rect.get_center() - aim
	if direction.length() < 0.001:
		direction = Vector2.UP
	direction = direction.normalized()
	# Advances until it complies (the rectangle is small: a few steps are enough and the solution is monotonic).
	var moved: Rect2 = rect
	for step: int in 400:
		moved.position += direction * 2.0
		var nearest: Vector2 = Vector2(clampf(aim.x, moved.position.x, moved.end.x),
				clampf(aim.y, moved.position.y, moved.end.y))
		if nearest.distance_to(aim) >= min_distance:
			break
	return moved


## Opacity (0 to 1) of a marker at [param distance] m: invisible on arrival and opaque from
## [constant FADE_NEAR_END] on.
static func fade_alpha(distance: float) -> float:
	return smoothstep(FADE_NEAR_START, FADE_NEAR_END, distance)


## Maximum distance (m) at which a place of [param kind] ([enum WorldMarker.Kind]) is marked.
static func max_distance_for(kind: int) -> float:
	return CIRCLE_MAX_DISTANCE if kind == WorldMarker.Kind.CIRCLE else MAX_DISTANCE


static func _nearest(markers: Array[WorldMarker], origin: Vector3, accept: Callable) -> WorldMarker:
	var best: WorldMarker = null
	var best_distance: float = INF
	for marker: WorldMarker in markers:
		if not bool(accept.call(marker)):
			continue
		var distance: float = marker.distance_from(origin)
		if distance < best_distance:
			best = marker
			best_distance = distance
	return best


func _draw() -> void:
	var font: Font = get_theme_default_font()
	for item: Dictionary in _items:
		if not bool(item["shown"]):
			continue
		var marker: WorldMarker = item["marker"]
		var alpha: float = float(item["alpha"])
		if alpha <= 0.01:
			continue
		var screen: Vector2 = item["screen"]
		var tint: Color = Color(marker.color.r, marker.color.g, marker.color.b, alpha)
		MarkerIcons.draw(self, marker.kind, screen, tint, ICON_SIZE)
		var distance_text: String = "%d m" % roundi(float(item["distance"]))
		var text: String = "%s · %s" % [marker.label, distance_text] if bool(item["label"]) else distance_text
		var size: Vector2 = font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1.0, FONT_SIZE)
		var rect := Rect2(Vector2(screen.x - size.x * 0.5, screen.y + ICON_SIZE + 4.0), size)
		rect.position.x = clampf(rect.position.x, 2.0, maxf(self.size.x - size.x - 2.0, 2.0))
		var pushed: Rect2 = push_from_aim(rect, self.size * 0.5, LABEL_MIN_AIM_DISTANCE)
		if pushed.position != rect.position:
			# Label moved away from the crosshair: guide line to the icon.
			var edge := Vector2(clampf(screen.x, pushed.position.x, pushed.end.x),
					clampf(screen.y, pushed.position.y, pushed.end.y))
			draw_line(screen, edge, Color(1.0, 1.0, 1.0, alpha * 0.5), 1.0, true)
		var at := Vector2(pushed.position.x, pushed.position.y + size.y * 0.75)
		draw_string_outline(font, at, text, HORIZONTAL_ALIGNMENT_LEFT, -1.0, FONT_SIZE, 4,
				Color(TEXT_OUTLINE.r, TEXT_OUTLINE.g, TEXT_OUTLINE.b, alpha * TEXT_OUTLINE.a))
		draw_string(font, at, text, HORIZONTAL_ALIGNMENT_LEFT, -1.0, FONT_SIZE,
				Color(TEXT_COLOR.r, TEXT_COLOR.g, TEXT_COLOR.b, alpha * TEXT_COLOR.a))
		if bool(item["on_edge"]):
			var arrow_center: Vector2 = screen + Vector2.UP.rotated(float(item["angle"])) * (ICON_SIZE + 12.0)
			MarkerIcons.draw_arrow(self, arrow_center, float(item["angle"]), tint, 6.0)
