class_name Minimap
extends Control
## Minimapa circular (UI-20, docs/fuerte.md sección 6): un trozo de la imagen cenital horneada de la zona
## ([ZoneMapDefinition]) centrado en el jugador, con el norte (-Z) arriba, y encima iconos: la flecha del
## jugador con el cono de la cámara, el fuerte con el color de su dueño, su puerta, el círculo de
## captura mientras está activo, los campamentos, los pasos y los compañeros de reino a la vista. Lo que
## cae fuera del círculo se pega al borde. Se acerca y aleja con [method zoom_in] y [method zoom_out]
## (teclas del mapa, por niveles).
## [br][br]
## Los enemigos no se enseñan (solo si se revelan, con las atalayas de la fase 7). El trozo de mapa lo dibuja
## [MinimapTerrain] (un shader de CanvasItem detrás de todo: disco con borde suave, coordenadas de textura limitadas a
## la imagen, fundido a niebla cerca de su borde y mipmaps; UI-52), y [method _draw] pone encima el aro, los iconos y el
## cono. Medidas y colores provisionales. Solo cliente.

## Diámetro del minimapa en píxeles.
const DIAMETER: float = 200.0
const MARGIN: float = 16.0
## Margen inferior: deja libre la línea de ayuda de controles del HUD y el panel de depuración de red (F3),
## que ocupa la esquina superior derecha.
const BOTTOM_MARGIN: float = 64.0
## Metros que abarca el diámetro en cada nivel de zoom, del más cerca al más lejos.
const ZOOM_METERS: Array[float] = [80.0, 160.0, 320.0]
const DEFAULT_ZOOM: int = 1
const BACK_COLOR: Color = Color(0.03, 0.035, 0.045, 0.85)
const RING_COLOR: Color = Color(0.62, 0.58, 0.5, 1.0)
const CONE_COLOR: Color = Color(1.0, 1.0, 1.0, 0.2)
const PLAYER_COLOR: Color = Color(1.0, 1.0, 1.0, 1.0)
const ALLY_RADIUS: float = 3.0
const ICON_SIZE: float = 6.0
## Medio ángulo del cono de la cámara (grados) y su largo, como fracción del radio.
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
	# Abajo a la derecha.
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


## Conecta el minimapa con el cliente (posición y compañeros), la vista del fuerte, la cámara (hacia dónde
## mira) y el mapa horneado ([param map] puede ser null: se ve el fondo liso con los iconos).
func bind(client: NetClient, view: FortressView, camera_rig: CameraRig, map: ZoneMapDefinition) -> void:
	_client = client
	_view = view
	_camera_rig = camera_rig
	_map = map
	_texture = map.load_texture() if map != null else null
	_terrain.set_map(map, _texture)
	_icons.clear()
	_allies.clear()


## Vuelve a leer dónde está todo (cada fotograma).
func refresh() -> void:
	_icons.clear()
	_allies.clear()
	var character: PlayerCharacter = _client.get_character() if is_instance_valid(_client) else null
	_has_player = character != null and is_instance_valid(character)
	if _has_player:
		_player_position = character.global_position if character.is_inside_tree() else character.position
		_player_yaw = _camera_rig.get_yaw() if is_instance_valid(_camera_rig) else character.yaw
		for marker: WorldMarker in MarkerSource.build(_map, _view):
			var point: Vector2 = clamp_to_circle(world_to_minimap(marker.position, _player_position,
					pixels_per_meter(), center()), center(), radius() - ICON_SIZE)
			_icons.append({"marker": marker, "point": point})
		_collect_allies()
		_terrain.set_view(_player_position, get_visible_meters())
	else:
		_terrain.visible = false
	queue_redraw()


func zoom_in() -> void:
	set_zoom_level(_zoom - 1)


func zoom_out() -> void:
	set_zoom_level(_zoom + 1)


## Nivel de zoom (0 = el más cerca, hasta el último de [constant ZOOM_METERS]).
func set_zoom_level(level: int) -> void:
	_zoom = clampi(level, 0, ZOOM_METERS.size() - 1)
	if _has_player:
		_terrain.set_view(_player_position, get_visible_meters())
	queue_redraw()


func get_zoom_level() -> int:
	return _zoom


## Metros que abarca el diámetro con el zoom actual.
func get_visible_meters() -> float:
	return ZOOM_METERS[_zoom]


func pixels_per_meter() -> float:
	return DIAMETER / get_visible_meters()


func center() -> Vector2:
	return Vector2(DIAMETER, DIAMETER) * 0.5


func radius() -> float:
	return DIAMETER * 0.5


## Iconos que se dibujan: [code]{"marker": WorldMarker, "point": Vector2}[/code] con el punto en
## píxeles del minimapa.
func get_icons() -> Array[Dictionary]:
	return _icons.duplicate()


## Posición (píxeles del minimapa) de cada compañero de reino a la vista.
func get_ally_points() -> Array[Vector2]:
	var points: Array[Vector2] = []
	for position: Vector3 in _allies:
		points.append(clamp_to_circle(world_to_minimap(position, _player_position, pixels_per_meter(),
				center()), center(), radius() - ALLY_RADIUS))
	return points


func get_ally_count() -> int:
	return _allies.size()


## Dónde cae en el minimapa un punto del mundo: [param center_px] es el centro del minimapa en píxeles,
## [param player] la posición del jugador (el centro del trozo de mundo que se ve) y
## [param pixels_per_meter] la escala. Norte (-Z) arriba, este (+X) a la derecha.
static func world_to_minimap(world: Vector3, player: Vector3, p_pixels_per_meter: float,
		center_px: Vector2) -> Vector2:
	return center_px + Vector2(world.x - player.x, world.z - player.z) * p_pixels_per_meter


## [param point] pegado al círculo de centro [param center_px] y radio [param circle_radius] si queda
## fuera.
static func clamp_to_circle(point: Vector2, center_px: Vector2, circle_radius: float) -> Vector2:
	var offset: Vector2 = point - center_px
	if offset.length() <= circle_radius:
		return point
	return center_px + offset.normalized() * circle_radius


## Dirección en pantalla (norte arriba) hacia la que mira un [param yaw] (0 = -Z, crece hacia la
## izquierda): [code](-sin yaw, -cos yaw)[/code].
static func yaw_to_direction(yaw: float) -> Vector2:
	return Vector2(-sin(yaw), -cos(yaw))


## El terreno que se dibuja detrás de los iconos.
func get_terrain() -> MinimapTerrain:
	return _terrain


## Coordenadas de textura (0 a 1) del trozo de mapa que se ve alrededor de [param player] a la escala
## [param p_pixels_per_meter] en el punto [param point_px] del minimapa. No las limita: fuera de la imagen salen
## valores menores que 0 o mayores que 1 (el shader de [MinimapTerrain] los limita y funde a niebla).
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
	# Sin terreno que enseñar (sin mapa o sin jugador) queda el fondo liso.
	if not _terrain.visible:
		draw_circle(c, radius(), BACK_COLOR)
	draw_arc(c, radius() - 1.0, 0.0, TAU, 64, RING_COLOR, 2.0, true)
	for icon: Dictionary in _icons:
		var marker: WorldMarker = icon["marker"]
		MarkerIcons.draw(self, marker.kind, icon["point"], marker.color, ICON_SIZE)
	for point: Vector2 in get_ally_points():
		draw_circle(point, ALLY_RADIUS + 1.0, MarkerIcons.OUTLINE_COLOR)
		draw_circle(point, ALLY_RADIUS, UIPalette.faction_color_of_code(_realm()))
	if _has_player:
		_draw_player(c)


func _draw_player(c: Vector2) -> void:
	var direction: Vector2 = yaw_to_direction(_player_yaw)
	var half: float = deg_to_rad(CONE_HALF_DEGREES)
	var length: float = radius() * CONE_LENGTH
	draw_colored_polygon(PackedVector2Array([c, c + direction.rotated(-half) * length,
			c + direction.rotated(half) * length]), CONE_COLOR)
	MarkerIcons.draw_arrow(self, c, atan2(direction.x, -direction.y), PLAYER_COLOR, 7.0)


func _realm() -> int:
	return _client.get_config().realm if is_instance_valid(_client) and _client.get_config() != null else 0
