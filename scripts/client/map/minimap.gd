class_name Minimap
extends Control
## Circular minimap (UI-20, docs/fortress.md section 6): a piece of the zone's baked top-down image
## ([ZoneMapDefinition]) centered on the player, with north (-Z) up, and icons on top: the player's
## arrow with the camera cone, the fort in its owner's color, its gate, the capture
## circle while active, camps, passes and realm companions in sight. What
## falls outside the circle sticks to the edge. It zooms in and out with [method zoom_in] and [method zoom_out]
## (map keys, in levels).
## [br][br]
## [b]Noise-free icons (UI-52).[/b] Only the current objective ([method WorldMarkers.pick_objective]) sticks to the ring; the
## other places (camps, passes, gate) are shown only if they fall within the radius, and icons that touch
## merge into the one with the highest priority ([method select_icons]). The camera cone is a soft gradient (alpha 0.2 at
## the vertex and 0 at the edge), with no hard edge covering the terrain, and there is a north mark at the top.
## [br][br]
## Enemies are not shown (only if revealed, with the watchtowers of phase 7). The map piece is drawn by
## [MinimapTerrain] (a CanvasItem shader behind everything: disc with a soft edge, texture coordinates clamped to
## the image, fade to fog near its edge and mipmaps; UI-52), and [method _draw] puts the ring, the icons and the
## cone on top. Provisional sizes and colors. Client only.

## Diameter of the minimap in pixels.
const DIAMETER: float = 200.0
const MARGIN: float = 16.0
## Bottom margin: leaves free the HUD's controls help line and the network debug panel (F3),
## which occupies the top right corner.
const BOTTOM_MARGIN: float = 64.0
## Meters the diameter covers at each zoom level, from closest to farthest.
const ZOOM_METERS: Array[float] = [80.0, 160.0, 320.0]
const DEFAULT_ZOOM: int = 1
const BACK_COLOR: Color = Color(0.03, 0.035, 0.045, 0.85)
const RING_COLOR: Color = Color(0.62, 0.58, 0.5, 1.0)
const CONE_COLOR: Color = Color(1.0, 1.0, 1.0, 0.2)
## Icons closer than this distance (px) merge into one; allies, closer than [constant ALLY_MERGE_DISTANCE].
const MERGE_DISTANCE: float = 11.0
const ALLY_MERGE_DISTANCE: float = 6.0
## An ally closer than this (px) to an icon or to the player arrow is not drawn: the icon covers it.
const ALLY_ICON_MERGE: float = 8.0
## Priority of each type when merging (the highest stays).
const KIND_PRIORITY: Dictionary = {
	WorldMarker.Kind.CIRCLE: 5,
	WorldMarker.Kind.FORT: 4,
	WorldMarker.Kind.GATE: 3,
	WorldMarker.Kind.CAMP: 2,
	WorldMarker.Kind.PASS: 1,
}
const NORTH_COLOR: Color = Color(0.96, 0.92, 0.78, 0.95)
const CONE_STEPS: int = 14
const PLAYER_COLOR: Color = Color(1.0, 1.0, 1.0, 1.0)
const ALLY_RADIUS: float = 3.0
const ICON_SIZE: float = 6.0
## Half angle of the camera cone (degrees) and its length, as a fraction of the radius.
const CONE_HALF_DEGREES: float = 40.0
const CONE_LENGTH: float = 0.7

var _client: NetClient = null
var _view: FortressView = null
var _camera_rig: CameraRig = null
var _map: ZoneMapDefinition = null
var _texture: Texture2D = null
var _zoom: int = DEFAULT_ZOOM
var _player_position: Vector3 = Vector3.ZERO
var _player_yaw: float = 0.0
var _has_player: bool = false
var _icons: Array[Dictionary] = []
var _allies: Array[Vector3] = []
var _terrain: MinimapTerrain = null


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	custom_minimum_size = Vector2(DIAMETER, DIAMETER)
	_terrain = MinimapTerrain.new()
	_terrain.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(_terrain)


func _ready() -> void:
	# Bottom right.
	anchor_left = 1.0
	anchor_right = 1.0
	anchor_top = 1.0
	anchor_bottom = 1.0
	offset_left = -DIAMETER - MARGIN
	offset_right = -MARGIN
	offset_top = -DIAMETER - BOTTOM_MARGIN
	offset_bottom = -BOTTOM_MARGIN


func _process(_delta: float) -> void:
	refresh()


func _unhandled_input(event: InputEvent) -> void:
	if InputMap.has_action(&"map_zoom_in") and event.is_action_pressed(&"map_zoom_in"):
		zoom_in()
	elif InputMap.has_action(&"map_zoom_out") and event.is_action_pressed(&"map_zoom_out"):
		zoom_out()


## Connects the minimap to the client (position and companions), the fort view, the camera (where it
## faces) and the baked map ([param map] may be null: the plain background is shown with the icons).
func bind(client: NetClient, view: FortressView, camera_rig: CameraRig, map: ZoneMapDefinition) -> void:
	_client = client
	_view = view
	_camera_rig = camera_rig
	_map = map
	_texture = map.load_texture() if map != null else null
	_terrain.set_map(map, _texture)
	_icons.clear()
	_allies.clear()


## Rereads where everything is (every frame).
func refresh() -> void:
	_icons.clear()
	_allies.clear()
	var character: PlayerCharacter = _client.get_character() if is_instance_valid(_client) else null
	_has_player = character != null and is_instance_valid(character)
	if _has_player:
		_player_position = character.global_position if character.is_inside_tree() else character.position
		_player_yaw = _camera_rig.get_yaw() if is_instance_valid(_camera_rig) else character.yaw
		var markers: Array[WorldMarker] = MarkerSource.build(_map, _view)
		var own_realm: int = _client.get_config().realm if _client.get_config() != null else NetProtocol.Realm.NONE
		var objective: WorldMarker = WorldMarkers.pick_objective(markers, _player_position, own_realm)
		_icons = select_icons(markers, objective.id if objective != null else &"", _player_position,
				pixels_per_meter(), center(), radius())
		_collect_allies()
		_terrain.set_view(_player_position, get_visible_meters())
	else:
		_terrain.visible = false
	queue_redraw()


func zoom_in() -> void:
	set_zoom_level(_zoom - 1)


func zoom_out() -> void:
	set_zoom_level(_zoom + 1)


## Zoom level (0 = closest, up to the last of [constant ZOOM_METERS]).
func set_zoom_level(level: int) -> void:
	_zoom = clampi(level, 0, ZOOM_METERS.size() - 1)
	if _has_player:
		_terrain.set_view(_player_position, get_visible_meters())
	queue_redraw()


func get_zoom_level() -> int:
	return _zoom


## Meters the diameter covers at the current zoom.
func get_visible_meters() -> float:
	return ZOOM_METERS[_zoom]


func pixels_per_meter() -> float:
	return DIAMETER / get_visible_meters()


func center() -> Vector2:
	return Vector2(DIAMETER, DIAMETER) * 0.5


func radius() -> float:
	return DIAMETER * 0.5


## Icons that are drawn: [code]{"marker": WorldMarker, "point": Vector2}[/code] with the point in
## minimap pixels.
func get_icons() -> Array[Dictionary]:
	return _icons.duplicate()


## Position (minimap pixels) of each realm companion in sight.
func get_ally_points() -> Array[Vector2]:
	var points: Array[Vector2] = []
	for position: Vector3 in _allies:
		var point: Vector2 = world_to_minimap(position, _player_position, pixels_per_meter(), center())
		# Allies outside the circle are not shown (only the objective goes to the ring) and those that touch become one.
		if point.distance_to(center()) > radius() - ALLY_RADIUS:
			continue
		# An ally on top of an icon or of the player arrow is absorbed by it (same rule as the world map window).
		var merged: bool = point.distance_to(center()) < ALLY_ICON_MERGE
		for icon: Dictionary in _icons:
			if (icon["point"] as Vector2).distance_to(point) < ALLY_ICON_MERGE:
				merged = true
		for other: Vector2 in points:
			if other.distance_to(point) < ALLY_MERGE_DISTANCE:
				merged = true
				break
		if not merged:
			points.append(point)
	return points


func get_ally_count() -> int:
	return _allies.size()


## Where a world point lands on the minimap: [param center_px] is the minimap's center in pixels,
## [param player] the player's position (the center of the piece of world that is seen) and
## [param pixels_per_meter] the scale. North (-Z) up, east (+X) to the right.
static func world_to_minimap(world: Vector3, player: Vector3, p_pixels_per_meter: float,
		center_px: Vector2) -> Vector2:
	return center_px + Vector2(world.x - player.x, world.z - player.z) * p_pixels_per_meter


## [param point] stuck to the circle with center [param center_px] and radius [param circle_radius] if it falls
## outside.
static func clamp_to_circle(point: Vector2, center_px: Vector2, circle_radius: float) -> Vector2:
	var offset: Vector2 = point - center_px
	if offset.length() <= circle_radius:
		return point
	return center_px + offset.normalized() * circle_radius


## Screen direction (north up) a [param yaw] faces (0 = -Z, increases toward the
## left): [code](-sin yaw, -cos yaw)[/code].
static func yaw_to_direction(yaw: float) -> Vector2:
	return Vector2(-sin(yaw), -cos(yaw))


## Which icons are drawn: [code]{"marker": WorldMarker, "point": Vector2, "rim": bool}[/code] with the point in minimap
## pixels. Only the marker [param objective_id] sticks to the ring ([code]rim[/code]) if it falls outside the circle; the
## others are shown only inside the radius. Those within [constant MERGE_DISTANCE] px of another more
## important one are discarded (the objective never).
static func select_icons(markers: Array[WorldMarker], objective_id: StringName, player: Vector3,
		p_pixels_per_meter: float, center_px: Vector2, circle_radius: float) -> Array[Dictionary]:
	var candidates: Array[Dictionary] = []
	for marker: WorldMarker in markers:
		var raw: Vector2 = world_to_minimap(marker.position, player, p_pixels_per_meter, center_px)
		var inside: bool = raw.distance_to(center_px) <= circle_radius - ICON_SIZE
		var is_objective: bool = marker.id == objective_id
		if not inside and not is_objective:
			continue
		var point: Vector2 = raw if inside else clamp_to_circle(raw, center_px, circle_radius - ICON_SIZE)
		candidates.append({"marker": marker, "point": point, "rim": not inside})
	candidates.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var ma: WorldMarker = a["marker"]
		var mb: WorldMarker = b["marker"]
		var wa: int = int(KIND_PRIORITY.get(ma.kind, 0)) + (100 if ma.id == objective_id else 0)
		var wb: int = int(KIND_PRIORITY.get(mb.kind, 0)) + (100 if mb.id == objective_id else 0)
		return wa > wb)
	var kept: Array[Dictionary] = []
	for candidate: Dictionary in candidates:
		var close: bool = false
		for other: Dictionary in kept:
			if (other["point"] as Vector2).distance_to(candidate["point"]) < MERGE_DISTANCE:
				close = true
				break
		if not close:
			kept.append(candidate)
	return kept


## The terrain drawn behind the icons.
func get_terrain() -> MinimapTerrain:
	return _terrain


## Texture coordinates (0 to 1) of the piece of map seen around [param player] at scale
## [param p_pixels_per_meter] at the point [param point_px] of the minimap. It does not clamp them: outside the image they come out as
## values below 0 or above 1 (the [MinimapTerrain] shader clamps them and fades to fog).
static func uv_at(map: ZoneMapDefinition, player: Vector3, p_pixels_per_meter: float, point_px: Vector2,
		center_px: Vector2) -> Vector2:
	var offset: Vector2 = (point_px - center_px) / p_pixels_per_meter
	return map.world_to_uv(Vector3(player.x + offset.x, 0.0, player.z + offset.y))


func _collect_allies() -> void:
	if not is_instance_valid(_client):
		return
	var own_realm: int = _client.get_config().realm if _client.get_config() != null else 0
	if own_realm == NetProtocol.Realm.NONE:
		return
	for view: RemotePlayerView in _client.get_remote_world().get_views():
		if view.get_kind() == NetProtocol.EntityKind.PLAYER and view.get_realm() == own_realm \
				and view.is_drawn() and view.get_drawn_health_q() != EntityRecord.HEALTH_Q_DEAD:
			_allies.append(view.get_drawn_position())


func _draw() -> void:
	var c: Vector2 = center()
	# With no terrain to show (no map or no player) the plain background remains.
	if not _terrain.visible:
		draw_circle(c, radius(), BACK_COLOR)
	draw_arc(c, radius() - 2.5, 0.0, TAU, 64, Color(0.0, 0.0, 0.0, 0.35), 3.0, true)
	draw_arc(c, radius() - 1.0, 0.0, TAU, 64, RING_COLOR, 2.0, true)
	_draw_north(c)
	for icon: Dictionary in _icons:
		var marker: WorldMarker = icon["marker"]
		MarkerIcons.draw(self, marker.kind, icon["point"], marker.color, ICON_SIZE)
	for point: Vector2 in get_ally_points():
		draw_circle(point, ALLY_RADIUS + 1.0, MarkerIcons.OUTLINE_COLOR)
		draw_circle(point, ALLY_RADIUS, UIPalette.faction_color_of_code(_realm()))
	if _has_player:
		_draw_player(c)


# North mark: an "N" with its halo, stuck to the ring on the inside.
func _draw_north(c: Vector2) -> void:
	var font: Font = get_theme_default_font()
	var at: Vector2 = Vector2(c.x - 4.5, c.y - radius() + 16.0)
	draw_string_outline(font, at, "N", HORIZONTAL_ALIGNMENT_LEFT, -1.0, 13, 4, Color(0.0, 0.0, 0.0, 0.8))
	draw_string(font, at, "N", HORIZONTAL_ALIGNMENT_LEFT, -1.0, 13, NORTH_COLOR)


func _draw_player(c: Vector2) -> void:
	var direction: Vector2 = yaw_to_direction(_player_yaw)
	var half: float = deg_to_rad(CONE_HALF_DEGREES)
	var length: float = radius() * CONE_LENGTH
	# Soft cone: opaque (alpha 0.2) at the vertex and transparent at the edge, with no hard edges.
	var points := PackedVector2Array([c])
	var colors := PackedColorArray([CONE_COLOR])
	for step: int in CONE_STEPS + 1:
		var angle: float = lerpf(-half, half, float(step) / float(CONE_STEPS))
		points.append(c + direction.rotated(angle) * length)
		colors.append(Color(CONE_COLOR.r, CONE_COLOR.g, CONE_COLOR.b, 0.0))
	draw_polygon(points, colors)
	MarkerIcons.draw_arrow(self, c, atan2(direction.x, -direction.y), PLAYER_COLOR, 7.0)


func _realm() -> int:
	return _client.get_config().realm if is_instance_valid(_client) and _client.get_config() != null else 0
