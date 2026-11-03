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
## provisionales.
## [br][br]
## [b]Qué se dibuja (UI-54).[/b] Antes se rotulaban todos los lugares a la vez y bajo la mira se amontonaba una sopa de
## nombres. Ahora ([method select_shown]):
## [br]- Siempre, el [b]objetivo actual[/b] ([method pick_objective]: el círculo de captura si está activo y, si no, el
## fuerte más cercano que no es del propio reino), con su distancia y, si cae fuera de la vista, pegado al borde con una
## flecha.
## [br]- El [b]nombre[/b] solo cuando la mira está a menos de [constant AIM_RADIUS] px del icono o con Alt pulsado
## (que suelta el cursor para mirar a gusto).
## [br]- Los demás lugares (puerta, campamentos, pasos) solo aparecen, con su nombre, al acercar la mira o con Alt; nunca
## pegados al borde.
## [br]- Hasta [constant MAX_SHOWN] a la vez, sin que dos iconos queden a menos de [constant LABEL_SPACING] (se
## pisarían los rótulos) y, durante [constant COMBAT_SECONDS] s tras un golpe dado o recibido
## ([method notify_combat]), solo el objetivo y sin nombres.
## [br][br]
## Solo cliente.

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
## Distancia (px) de la mira (el centro de la pantalla) a un icono por debajo de la cual enseña su nombre.
const AIM_RADIUS: float = 80.0
## Marcadores como mucho en pantalla a la vez.
const MAX_SHOWN: int = 3
## Segundos tras un golpe dado o recibido en los que solo se dibuja el objetivo, sin nombres.
const COMBAT_SECONDS: float = 5.0
## Separación mínima (px, en x y en y) entre los iconos de dos marcadores dibujados a la vez: más cerca, sus rótulos se
## pisarían (el fuerte y un paso que cae detrás de él a lo lejos), y el que va después no se dibuja.
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


## Avisa de que hubo un golpe dado o recibido: durante [constant COMBAT_SECONDS] s solo se dibuja el objetivo, sin nombres.
func notify_combat() -> void:
	_combat_left = COMBAT_SECONDS


## true mientras dura el aviso de [method notify_combat].
func is_in_combat() -> bool:
	return _combat_left > 0.0


## Conecta los marcadores con el cliente (dónde está el jugador), la vista del fuerte, la cámara y el
## mapa horneado de la zona ([param map] puede ser null).
func bind(client: NetClient, view: FortressView, camera_rig: CameraRig, map: ZoneMapDefinition) -> void:
	_client = client
	_view = view
	_camera_rig = camera_rig
	_map = map
	_items.clear()
	_objective_id = &""


## Recalcula dónde cae cada marcador en la pantalla, cuáles se dibujan y redibuja.
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
	_objective_id = objective.id if objective != null else &""
	for marker: WorldMarker in markers:
		var distance: float = marker.distance_from(here)
		if distance > max_distance_for(marker.kind):
			continue
		var projected: Dictionary = project(camera, screen_size, marker.position, EDGE_MARGIN)
		_items.append({
			"marker": marker, "distance": distance, "screen": projected["screen"],
			"on_edge": projected["on_edge"], "angle": projected["angle"],
			"alpha": fade_alpha(distance), "objective": marker.id == _objective_id,
			"shown": false, "label": false,
		})
	var alt_held: bool = InputMap.has_action(&"free_cursor") and Input.is_action_pressed(&"free_cursor")
	select_shown(_items, screen_size * 0.5, alt_held, is_in_combat())
	queue_redraw()


## Lo que se está dibujando: [code]{"marker", "distance", "screen", "on_edge", "angle", "alpha"}[/code].
func get_items() -> Array[Dictionary]:
	return _items.duplicate()


## Los elementos que se dibujan ahora (los de [method get_items] con [code]shown[/code]).
func get_shown_items() -> Array[Dictionary]:
	var shown: Array[Dictionary] = []
	for item: Dictionary in _items:
		if bool(item["shown"]):
			shown.append(item)
	return shown


## Id del marcador que es el objetivo actual (vacío si no hay).
func get_objective_id() -> StringName:
	return _objective_id


## El elemento del marcador con id [param id], o un diccionario vacío.
func get_item(id: StringName) -> Dictionary:
	for item: Dictionary in _items:
		if (item["marker"] as WorldMarker).id == id:
			return item
	return {}


## El objetivo actual entre [param markers] visto desde [param origin] y por alguien del reino [param own_realm]: el
## círculo de captura más cercano si hay alguno activo; si no, el fuerte más cercano que no es de [param own_realm] (o el
## más cercano si todos son suyos). null si no hay ni círculo ni fuerte.
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


## Decide cuáles de [param items] (los de [method refresh]: [code]marker[/code], [code]screen[/code], [code]on_edge[/code],
## [code]alpha[/code] y [code]objective[/code]) se dibujan y con nombre, y lo anota en cada uno ([code]shown[/code],
## [code]label[/code]). [param aim] es el punto de la mira en pantalla. Ver las reglas en la documentación de la clase.
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
	# Con sitio para MAX_SHOWN en total (el objetivo ya cuenta), los más cercanos a la mira.
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
		var at := Vector2(screen.x - size.x * 0.5, screen.y + ICON_SIZE + 4.0 + size.y * 0.7)
		at.x = clampf(at.x, 2.0, maxf(self.size.x - size.x - 2.0, 2.0))
		draw_string_outline(font, at, text, HORIZONTAL_ALIGNMENT_LEFT, -1.0, FONT_SIZE, 4,
				Color(TEXT_OUTLINE.r, TEXT_OUTLINE.g, TEXT_OUTLINE.b, alpha * TEXT_OUTLINE.a))
		draw_string(font, at, text, HORIZONTAL_ALIGNMENT_LEFT, -1.0, FONT_SIZE,
				Color(TEXT_COLOR.r, TEXT_COLOR.g, TEXT_COLOR.b, alpha * TEXT_COLOR.a))
		if bool(item["on_edge"]):
			var arrow_center: Vector2 = screen + Vector2.UP.rotated(float(item["angle"])) * (ICON_SIZE + 12.0)
			MarkerIcons.draw_arrow(self, arrow_center, float(item["angle"]), tint, 6.0)
