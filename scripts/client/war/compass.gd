class_name Compass
extends Control
## Brújula de la parte superior de la pantalla (UI-19, docs/fuerte.md sección 6): una cinta con los
## rumbos (N, NE, E, SE, S, SO, O, NO y los grados cada 15°) que se desliza según hacia dónde mira la
## cámara, con los [WorldMarker] (el fuerte, los campamentos, los pasos) en el rumbo en que están.
## [br][br]
## [b]Convención.[/b] El norte es -Z de la zona. Con el [code]yaw[/code] del personaje y de la cámara
## (0 = mira a -Z, crece girando a la izquierda) el rumbo, en grados hacia la derecha desde el norte,
## es [code]-yaw[/code] ([method heading_of_yaw]): mirando al este (+X) el yaw es -90° y el rumbo, 90°.
## Un punto del mundo está en el rumbo [method bearing_to] y a [method relative_bearing] grados a la
## derecha (positivos) o a la izquierda (negativos) de hacia donde se mira.
## [br][br]
## La cinta enseña [constant SPAN_DEGREES] grados (± la mitad a cada lado). Los marcadores fuera de ese
## arco no se dibujan en la brújula (los muestra el [WorldMarkers] en el borde de la pantalla). Las
## medidas y los colores son provisionales. Solo cliente.

const GROUP: StringName = &"compass"
## Grados que cubre la cinta, de lado a lado.
const SPAN_DEGREES: float = 180.0
const WIDTH: float = 560.0
const HEIGHT: float = 34.0
const TOP_MARGIN: float = 4.0
const BACK_COLOR: Color = Color(0.04, 0.045, 0.06, 0.62)
const TICK_COLOR: Color = Color(0.8, 0.78, 0.72, 0.75)
const CARDINAL_COLOR: Color = Color(0.96, 0.92, 0.78, 1.0)
const HEADING_COLOR: Color = Color(1.0, 1.0, 1.0, 0.95)
const FONT_SIZE: int = 14
## Un marcador a menos de esta distancia (m) no se dibuja en la brújula.
const MIN_DISTANCE: float = 1.0
## Rumbos con nombre, cada 45° desde el norte.
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
	set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP, Control.PRESET_MODE_MINSIZE, 0)
	position.y = TOP_MARGIN


## Pone hacia dónde se mira (el [code]yaw[/code] de la cámara, en radianes), dónde se está y los
## marcadores que se dibujan.
func update_view(yaw: float, origin: Vector3, markers: Array[WorldMarker]) -> void:
	_heading = heading_of_yaw(yaw)
	_origin = origin
	_markers = markers
	_recompute()
	queue_redraw()


## Rumbo actual en grados (0 a 360, 0 = norte, 90 = este).
func get_heading() -> float:
	return _heading


## Marcadores que caen dentro del arco de la cinta ahora, del más lejano al más cercano:
## [code]{"marker": WorldMarker, "relative": float, "x": float}[/code], con [code]x[/code] la posición
## en la cinta (0 a [constant WIDTH]).
func get_visible_markers() -> Array[Dictionary]:
	return _visible_markers.duplicate()


## Texto del rumbo central: «045° NE».
func get_heading_text() -> String:
	return heading_text(_heading)


## Rumbo (grados, 0 a 360, hacia la derecha desde el norte) de quien tiene el yaw [param yaw]
## (radianes): [code]-yaw[/code].
static func heading_of_yaw(yaw: float) -> float:
	return fposmod(rad_to_deg(-yaw), 360.0)


## Rumbo (grados, 0 a 360) del punto [param to] visto desde [param from] (norte = -Z, este = +X).
static func bearing_to(from: Vector3, to: Vector3) -> float:
	return fposmod(rad_to_deg(atan2(to.x - from.x, -(to.z - from.z))), 360.0)


## Grados (-180 a 180) a la derecha (positivo) del rumbo [param heading] en que está el rumbo
## [param bearing].
static func relative_bearing(bearing: float, heading: float) -> float:
	return wrapf(bearing - heading, -180.0, 180.0)


## Nombre del rumbo más cercano a [param heading] (grados): N, NE, E, SE, S, SO, O o NO.
static func cardinal_of(heading: float) -> String:
	return CARDINALS[roundi(fposmod(heading, 360.0) / 45.0) % CARDINALS.size()]


## «045° NE» para [param heading].
static func heading_text(heading: float) -> String:
	return "%03d° %s" % [roundi(fposmod(heading, 360.0)) % 360, cardinal_of(heading)]


## Posición (0 a [constant WIDTH]) en la cinta de un rumbo relativo de [param relative] grados; fuera del
## arco, [constant INF] (o -INF a la izquierda).
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
			# Encima del lugar no hay rumbo que marcar.
			continue
		var relative: float = relative_bearing(bearing_to(_origin, marker.position), _heading)
		var x: float = tape_x(relative)
		if is_finite(x):
			_visible_markers.append({"marker": marker, "relative": relative, "x": x})
	_visible_markers.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return (a["marker"] as WorldMarker).distance_from(_origin) > (b["marker"] as WorldMarker).distance_from(_origin))


func _draw() -> void:
	var area := Rect2(Vector2.ZERO, Vector2(WIDTH, HEIGHT))
	draw_rect(area, BACK_COLOR)
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
		draw_line(Vector2(x, HEIGHT - (14.0 if cardinal else 8.0)), Vector2(x, HEIGHT - 2.0), TICK_COLOR, 1.0)
		if cardinal:
			var text: String = cardinal_of(rumbo)
			var size: Vector2 = font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1.0, FONT_SIZE)
			draw_string(font, Vector2(x - size.x * 0.5, 14.0), text, HORIZONTAL_ALIGNMENT_LEFT, -1.0, FONT_SIZE, CARDINAL_COLOR)
		elif is_equal_approx(fposmod(rumbo, 30.0), 0.0):
			var number: String = "%d" % roundi(rumbo)
			var number_size: Vector2 = font.get_string_size(number, HORIZONTAL_ALIGNMENT_LEFT, -1.0, FONT_SIZE - 3)
			draw_string(font, Vector2(x - number_size.x * 0.5, 14.0), number, HORIZONTAL_ALIGNMENT_LEFT, -1.0, FONT_SIZE - 3, TICK_COLOR)
	for entry: Dictionary in _visible_markers:
		var marker: WorldMarker = entry["marker"]
		MarkerIcons.draw(self, marker.kind, Vector2(float(entry["x"]), HEIGHT * 0.5 + 2.0), marker.color, 7.0)
	# Marca del centro (hacia donde se mira) y rumbo.
	draw_colored_polygon(PackedVector2Array([Vector2(WIDTH * 0.5 - 5.0, 0.0), Vector2(WIDTH * 0.5 + 5.0, 0.0),
			Vector2(WIDTH * 0.5, 7.0)]), HEADING_COLOR)
