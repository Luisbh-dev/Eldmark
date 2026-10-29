class_name WorldMarkers
extends Control
## Marcadores sobre el mundo (UI-19, docs/fuerte.md sección 6): para cada [WorldMarker] (el fuerte, su
## puerta, el círculo de captura, los campamentos y los pasos) un icono proyectado en la pantalla con su
## nombre y la distancia en metros. Si el lugar cae fuera de la vista (a un lado, arriba, abajo o a la
## espalda) el icono se pega al borde de la pantalla con una flecha hacia donde está, y de cerca se
## desvanece para no tapar nada.
## [br][br]
## Los marcadores salen de [MarkerSource] (mapa horneado y estado del fuerte) y se calculan en cada
## fotograma con [method refresh]; [method project] es la proyección pura (cámara, tamaño de la
## pantalla y punto del mundo). Las distancias son horizontales, desde el jugador. Medidas y colores
## provisionales. Solo cliente.

## Distancia (m) más allá de la cual no se marca un lugar, por tipo; el círculo de captura solo de cerca.
const MAX_DISTANCE: float = 700.0
const CIRCLE_MAX_DISTANCE: float = 150.0
## Profundidad (m) por debajo de la cual un punto cuenta como detrás de la cámara.
const MIN_DEPTH: float = 0.05
## Margen (px) al borde de la pantalla donde se pegan los iconos que salen de la vista.
const EDGE_MARGIN: float = 44.0
## Distancias (m) entre las que un marcador pasa de invisible a opaco al acercarse.
const FADE_NEAR_START: float = 5.0
const FADE_NEAR_END: float = 16.0
const ICON_SIZE: float = 9.0
const FONT_SIZE: int = 14
const TEXT_COLOR: Color = Color(1.0, 1.0, 1.0, 0.95)
const TEXT_OUTLINE: Color = Color(0.0, 0.0, 0.0, 0.85)

var _client: NetClient = null
var _view: FortressView = null
var _camera_rig: CameraRig = null
var _map: ZoneMapDefinition = null
var _items: Array[Dictionary] = []


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)


func _process(_delta: float) -> void:
	refresh()


## Conecta los marcadores con el cliente (dónde está el jugador), la vista del fuerte, la cámara y el
## mapa horneado de la zona ([param map] puede ser null).
func bind(client: NetClient, view: FortressView, camera_rig: CameraRig, map: ZoneMapDefinition) -> void:
	_client = client
	_view = view
	_camera_rig = camera_rig
	_map = map
	_items.clear()


## Recalcula dónde cae cada marcador en la pantalla y redibuja.
func refresh() -> void:
	_items.clear()
	var camera: Camera3D = _camera_rig.get_camera() if is_instance_valid(_camera_rig) else null
	var character: PlayerCharacter = _client.get_character() if is_instance_valid(_client) else null
	if camera == null or not camera.is_inside_tree() or character == null or not is_instance_valid(character):
		queue_redraw()
		return
	var here: Vector3 = character.global_position if character.is_inside_tree() else character.position
	var screen_size: Vector2 = camera.get_viewport().get_visible_rect().size
	for marker: WorldMarker in MarkerSource.build(_map, _view):
		var distance: float = marker.distance_from(here)
		if distance > max_distance_for(marker.kind):
			continue
		var projected: Dictionary = project(camera, screen_size, marker.position, EDGE_MARGIN)
		_items.append({
			"marker": marker, "distance": distance, "screen": projected["screen"],
			"on_edge": projected["on_edge"], "angle": projected["angle"],
			"alpha": fade_alpha(distance),
		})
	queue_redraw()


## Lo que se está dibujando: [code]{"marker", "distance", "screen", "on_edge", "angle", "alpha"}[/code].
func get_items() -> Array[Dictionary]:
	return _items.duplicate()


## El elemento del marcador con id [param id], o un diccionario vacío.
func get_item(id: StringName) -> Dictionary:
	for item: Dictionary in _items:
		if (item["marker"] as WorldMarker).id == id:
			return item
	return {}


## Proyecta [param world] con [param camera] en una pantalla de [param screen_size] píxeles. Devuelve
## [code]{"screen": Vector2, "on_edge": bool, "behind": bool, "angle": float}[/code]: la posición en la
## pantalla; si está pegada al borde (fuera de la vista o a la espalda, a [param margin] px del borde);
## si está detrás de la cámara; y el ángulo (radianes, 0 = arriba, positivo hacia la derecha) de la
## dirección en que cae desde el centro, para la flecha.
static func project(camera: Camera3D, screen_size: Vector2, world: Vector3, margin: float) -> Dictionary:
	var camera_transform: Transform3D = camera.get_camera_transform()
	var local: Vector3 = camera_transform.affine_inverse() * world
	# Detrás de la cámara (o en su plano, donde la proyección no existe) el icono va al borde por el
	# lado hacia el que cae el punto en el plano de la cámara.
	var behind: bool = -local.z <= MIN_DEPTH
	var center: Vector2 = screen_size * 0.5
	var screen: Vector2 = center
	var direction: Vector2 = Vector2(local.x, -local.y)
	if not behind:
		screen = camera.unproject_position(world)
		direction = screen - center
	var inside := Rect2(Vector2(margin, margin), screen_size - Vector2(margin, margin) * 2.0)
	var on_edge: bool = behind or not inside.has_point(screen)
	if on_edge:
		if direction.length() < 0.001:
			direction = Vector2(0.0, 1.0)
		screen = edge_point(center, direction, inside)
	return {"screen": screen, "on_edge": on_edge, "behind": behind, "angle": atan2(direction.x, -direction.y)}


## Punto en que el rayo desde [param center] hacia [param direction] sale del rectángulo [param inside].
static func edge_point(center: Vector2, direction: Vector2, inside: Rect2) -> Vector2:
	var half: Vector2 = inside.size * 0.5
	var scale_x: float = half.x / absf(direction.x) if absf(direction.x) > 0.0001 else INF
	var scale_y: float = half.y / absf(direction.y) if absf(direction.y) > 0.0001 else INF
	return center + direction * minf(scale_x, scale_y)


## Opacidad (0 a 1) de un marcador a [param distance] m: invisible al llegar y opaco a partir de
## [constant FADE_NEAR_END].
static func fade_alpha(distance: float) -> float:
	return smoothstep(FADE_NEAR_START, FADE_NEAR_END, distance)


## Distancia máxima (m) a la que se marca un lugar de [param kind] ([enum WorldMarker.Kind]).
static func max_distance_for(kind: int) -> float:
	return CIRCLE_MAX_DISTANCE if kind == WorldMarker.Kind.CIRCLE else MAX_DISTANCE


func _draw() -> void:
	var font: Font = get_theme_default_font()
	for item: Dictionary in _items:
		var marker: WorldMarker = item["marker"]
		var alpha: float = float(item["alpha"])
		if alpha <= 0.01:
			continue
		var screen: Vector2 = item["screen"]
		var tint: Color = Color(marker.color.r, marker.color.g, marker.color.b, alpha)
		MarkerIcons.draw(self, marker.kind, screen, tint, ICON_SIZE)
		var distance_text: String = "%d m" % roundi(float(item["distance"]))
		var text: String = distance_text if bool(item["on_edge"]) else "%s · %s" % [marker.label, distance_text]
		var size: Vector2 = font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1.0, FONT_SIZE)
		var at := Vector2(screen.x - size.x * 0.5, screen.y + ICON_SIZE + 4.0 + size.y * 0.7)
		at.x = clampf(at.x, 2.0, maxf(self.size.x - size.x - 2.0, 2.0))
		draw_string_outline(font, at, text, HORIZONTAL_ALIGNMENT_LEFT, -1.0, FONT_SIZE, 4,
				Color(TEXT_OUTLINE.r, TEXT_OUTLINE.g, TEXT_OUTLINE.b, alpha * TEXT_OUTLINE.a))
		draw_string(font, at, text, HORIZONTAL_ALIGNMENT_LEFT, -1.0, FONT_SIZE,
				Color(TEXT_COLOR.r, TEXT_COLOR.g, TEXT_COLOR.b, alpha * TEXT_COLOR.a))
		if bool(item["on_edge"]):
			var arrow_center: Vector2 = screen + Vector2.UP.rotated(float(item["angle"])) * (ICON_SIZE + 12.0)
			MarkerIcons.draw_arrow(self, arrow_center, float(item["angle"]), tint, 6.0)
