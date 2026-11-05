class_name Compass
extends Control
## Compass at the top of the screen (UI-19, docs/fortress.md section 6): a tape with the
## headings (N, NE, E, SE, S, SO, O, NO and the degrees every 15°) that slides according to where the
## camera is facing, with the [WorldMarker] entries (the fort, the camps, the passes) at the heading they are at.
## [br][br]
## [b]Convention.[/b] North is the zone's -Z. With the [code]yaw[/code] of the character and camera
## (0 = facing -Z, increasing when turning left) the heading, in degrees clockwise from north,
## is [code]-yaw[/code] ([method heading_of_yaw]): facing east (+X) the yaw is -90° and the heading, 90°.
## A world point is at heading [method bearing_to] and [method relative_bearing] degrees to the
## right (positive) or left (negative) of where you are facing.
## [br][br]
## [b]Hierarchy (UI-54).[/b] Three rows: the tape with the letters and marks (the letters fade toward the
## ends), a separate row below with the marker icons (those that fall at the same heading merge into the one of
## highest priority: [method get_drawn_markers]) and, under the needle, a plate with the numeric heading ("045° NE").
## [br][br]
## The tape shows [constant SPAN_DEGREES] degrees (± half on each side). Markers outside that
## arc are not drawn on the compass ([WorldMarkers] shows them at the screen edge). Sizes
## and colors are provisional. Client only.

const GROUP: StringName = &"compass"
## Degrees the tape covers, from side to side.
const SPAN_DEGREES: float = 180.0
const WIDTH: float = 560.0
const HEIGHT: float = 60.0
## Height of the tape of letters and marks; below it, the row of icons and the heading plate.
const TAPE_HEIGHT: float = 24.0
const ICON_ROW_HEIGHT: float = 20.0
const PLATE_SIZE: Vector2 = Vector2(84.0, 18.0)
## Icons closer than this distance (px) in the row merge into one.
const MERGE_PX: float = 14.0
## Letters start to fade at this fraction of the tape's half-width and vanish at the edge.
const FADE_FROM: float = 0.55
const TOP_MARGIN: float = 4.0
const BACK_COLOR: Color = Color(0.04, 0.045, 0.06, 0.62)
const TICK_COLOR: Color = Color(0.8, 0.78, 0.72, 0.75)
const CARDINAL_COLOR: Color = Color(0.96, 0.92, 0.78, 1.0)
const HEADING_COLOR: Color = Color(1.0, 1.0, 1.0, 0.95)
const FONT_SIZE: int = 14
## A marker closer than this distance (m) is not drawn on the compass.
const MIN_DISTANCE: float = 1.0
## Named headings, every 45° from north.
const CARDINALS: Array[String] = ["N", "NE", "E", "SE", "S", "SO", "O", "NO"]

var _markers: Array[WorldMarker] = []
var _heading: float = 0.0
var _origin: Vector3 = Vector3.ZERO
var _visible_markers: Array[Dictionary] = []


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	custom_minimum_size = Vector2(WIDTH, HEIGHT)
	add_to_group(GROUP)


func _ready() -> void:
	# Centered at the top (UI-49): with the minimum-size preset it ended up with its left edge at the center.
	UILayout.anchor_top_center(self, WIDTH, TOP_MARGIN)


## Sets where you are facing (the camera's [code]yaw[/code], in radians), where you are and the
## markers to draw.
func update_view(yaw: float, origin: Vector3, markers: Array[WorldMarker]) -> void:
	_heading = heading_of_yaw(yaw)
	_origin = origin
	_markers = markers
	_recompute()
	queue_redraw()


## Current heading in degrees (0 to 360, 0 = north, 90 = east).
func get_heading() -> float:
	return _heading


## Markers that fall inside the tape's arc right now, from farthest to nearest:
## [code]{"marker": WorldMarker, "relative": float, "x": float}[/code], with [code]x[/code] the position
## on the tape (0 to [constant WIDTH]).
func get_visible_markers() -> Array[Dictionary]:
	return _visible_markers.duplicate()


## The markers drawn in the icon row: those of [method get_visible_markers] with the ones that fall within
## [constant MERGE_PX] px of another merged into the one of highest priority (on a tie, the one nearest the player). Each
## element adds [code]merged: int[/code], how many markers it represents.
func get_drawn_markers() -> Array[Dictionary]:
	var ordered: Array[Dictionary] = _visible_markers.duplicate()
	ordered.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var pa: int = int(Minimap.KIND_PRIORITY.get((a["marker"] as WorldMarker).kind, 0))
		var pb: int = int(Minimap.KIND_PRIORITY.get((b["marker"] as WorldMarker).kind, 0))
		if pa != pb:
			return pa > pb
		return (a["marker"] as WorldMarker).distance_from(_origin) < (b["marker"] as WorldMarker).distance_from(_origin))
	var drawn: Array[Dictionary] = []
	for entry: Dictionary in ordered:
		var absorbed: bool = false
		for kept: Dictionary in drawn:
			if absf(float(kept["x"]) - float(entry["x"])) < MERGE_PX:
				kept["merged"] = int(kept["merged"]) + 1
				absorbed = true
				break
		if not absorbed:
			var copy: Dictionary = entry.duplicate()
			copy["merged"] = 1
			drawn.append(copy)
	return drawn


## Opacity (0 to 1) of the tape's letters and numbers at position [param x] (0 to [constant WIDTH]): 1 at the
## center, 0 at the edges.
static func letter_alpha(x: float) -> float:
	var distance: float = absf(x - WIDTH * 0.5) / (WIDTH * 0.5)
	return 1.0 - smoothstep(FADE_FROM, 1.0, distance)


## Text of the central heading: "045° NE".
func get_heading_text() -> String:
	return heading_text(_heading)


## Heading (degrees, 0 to 360, clockwise from north) of whoever has yaw [param yaw]
## (radians): [code]-yaw[/code].
static func heading_of_yaw(yaw: float) -> float:
	return fposmod(rad_to_deg(-yaw), 360.0)


## Heading (degrees, 0 to 360) of point [param to] seen from [param from] (north = -Z, east = +X).
static func bearing_to(from: Vector3, to: Vector3) -> float:
	return fposmod(rad_to_deg(atan2(to.x - from.x, -(to.z - from.z))), 360.0)


## Degrees (-180 to 180) to the right (positive) of heading [param heading] at which heading
## [param bearing] lies.
static func relative_bearing(bearing: float, heading: float) -> float:
	return wrapf(bearing - heading, -180.0, 180.0)


## Name of the heading nearest to [param heading] (degrees): N, NE, E, SE, S, SO, O or NO.
static func cardinal_of(heading: float) -> String:
	return CARDINALS[roundi(fposmod(heading, 360.0) / 45.0) % CARDINALS.size()]


## "045° NE" for [param heading].
static func heading_text(heading: float) -> String:
	return "%03d° %s" % [roundi(fposmod(heading, 360.0)) % 360, cardinal_of(heading)]


## Position (0 to [constant WIDTH]) on the tape of a relative heading of [param relative] degrees; outside the
## arc, [constant INF] (or -INF on the left).
static func tape_x(relative: float) -> float:
	var half: float = SPAN_DEGREES * 0.5
	if relative > half:
		return INF
	if relative < -half:
		return -INF
	return WIDTH * 0.5 + relative / half * (WIDTH * 0.5)


func _recompute() -> void:
	_visible_markers.clear()
	for marker: WorldMarker in _markers:
		if marker.distance_from(_origin) < MIN_DISTANCE:
			# Directly above the place there is no heading to mark.
			continue
		var relative: float = relative_bearing(bearing_to(_origin, marker.position), _heading)
		var x: float = tape_x(relative)
		if is_finite(x):
			_visible_markers.append({"marker": marker, "relative": relative, "x": x})
	_visible_markers.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return (a["marker"] as WorldMarker).distance_from(_origin) > (b["marker"] as WorldMarker).distance_from(_origin))


func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, Vector2(WIDTH, TAPE_HEIGHT + ICON_ROW_HEIGHT)), BACK_COLOR)
	# Thin rule between the tape and the icon row.
	draw_line(Vector2(0.0, TAPE_HEIGHT), Vector2(WIDTH, TAPE_HEIGHT), Color(TICK_COLOR.r, TICK_COLOR.g, TICK_COLOR.b, 0.25), 1.0)
	var font: Font = get_theme_default_font()
	var half: float = SPAN_DEGREES * 0.5
	var first: int = floori((_heading - half) / 15.0)
	var last: int = ceili((_heading + half) / 15.0)
	for step: int in range(first, last + 1):
		var degrees: float = float(step) * 15.0
		var x: float = tape_x(degrees - _heading)
		if not is_finite(x):
			continue
		var rumbo: float = fposmod(degrees, 360.0)
		var cardinal: bool = is_equal_approx(fposmod(rumbo, 45.0), 0.0)
		var fade: float = letter_alpha(x)
		var tick_color: Color = Color(TICK_COLOR.r, TICK_COLOR.g, TICK_COLOR.b, TICK_COLOR.a * lerpf(0.35, 1.0, fade))
		draw_line(Vector2(x, TAPE_HEIGHT - (10.0 if cardinal else 6.0)), Vector2(x, TAPE_HEIGHT - 2.0), tick_color, 1.0)
		if cardinal:
			var text: String = cardinal_of(rumbo)
			var size: Vector2 = font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1.0, FONT_SIZE)
			draw_string(font, Vector2(x - size.x * 0.5, 14.0), text, HORIZONTAL_ALIGNMENT_LEFT, -1.0, FONT_SIZE,
					Color(CARDINAL_COLOR.r, CARDINAL_COLOR.g, CARDINAL_COLOR.b, fade))
		elif is_equal_approx(fposmod(rumbo, 30.0), 0.0):
			var number: String = "%d" % roundi(rumbo)
			var number_size: Vector2 = font.get_string_size(number, HORIZONTAL_ALIGNMENT_LEFT, -1.0, FONT_SIZE - 3)
			draw_string(font, Vector2(x - number_size.x * 0.5, 14.0), number, HORIZONTAL_ALIGNMENT_LEFT, -1.0,
					FONT_SIZE - 3, Color(TICK_COLOR.r, TICK_COLOR.g, TICK_COLOR.b, TICK_COLOR.a * fade))
	# Separate icon row, with the markers merged at the same heading.
	for entry: Dictionary in get_drawn_markers():
		var marker: WorldMarker = entry["marker"]
		var at: Vector2 = Vector2(float(entry["x"]), TAPE_HEIGHT + ICON_ROW_HEIGHT * 0.5)
		MarkerIcons.draw(self, marker.kind, at, marker.color, 7.0)
		if int(entry["merged"]) > 1:
			draw_circle(at + Vector2(7.0, -6.0), 2.5, HEADING_COLOR)
	# Needle: triangle on top, thread through the tape and plate with the numeric heading below.
	var center_x: float = WIDTH * 0.5
	draw_colored_polygon(PackedVector2Array([Vector2(center_x - 5.0, 0.0), Vector2(center_x + 5.0, 0.0),
			Vector2(center_x, 7.0)]), HEADING_COLOR)
	draw_line(Vector2(center_x, 7.0), Vector2(center_x, TAPE_HEIGHT - 1.0), Color(HEADING_COLOR.r, HEADING_COLOR.g,
			HEADING_COLOR.b, 0.35), 1.0)
	var plate := Rect2(Vector2(center_x - PLATE_SIZE.x * 0.5, TAPE_HEIGHT + ICON_ROW_HEIGHT - 1.0), PLATE_SIZE)
	draw_rect(plate, Color(0.03, 0.035, 0.05, 0.85))
	draw_rect(plate, Color(TICK_COLOR.r, TICK_COLOR.g, TICK_COLOR.b, 0.45), false, 1.0)
	var heading_label: String = get_heading_text()
	var heading_size: Vector2 = font.get_string_size(heading_label, HORIZONTAL_ALIGNMENT_LEFT, -1.0, FONT_SIZE - 1)
	draw_string(font, Vector2(center_x - heading_size.x * 0.5, plate.end.y - 5.0), heading_label,
			HORIZONTAL_ALIGNMENT_LEFT, -1.0, FONT_SIZE - 1, HEADING_COLOR)
