class_name WorldMap
extends Control
## Mapa de la zona a pantalla completa (UI-20, UI-21, docs/fuerte.md sección 6). Se abre con M
## ([code]open_map[/code]) y se cierra con M o Esc: enseña la imagen cenital horneada con el fuerte (con
## el color de su dueño y el estado de su captura), su puerta y su círculo, los campamentos, los pasos,
## tu posición con hacia dónde miras, a tus compañeros a la vista y, a la derecha, una leyenda y el
## estado del fuerte.
## [br][br]
## [b]Elección de reaparición (UI-21).[/b] Con [method set_respawn_mode] (la pantalla de muerte lo pone al
## abrir el mapa) se ven además las [RespawnPointList.Option] de tu reino: las válidas ahora (tu
## campamento, un fuerte tuyo en reposo y sin ataques, según [RespawnRules]) resaltadas y las demás
## apagadas. Pulsar una válida emite [signal respawn_option_chosen]; el servidor vuelve a comprobarla y,
## si ya no vale, te reaparece en el campamento.
## [br][br]
## Mientras está abierto libera el cursor de la cámara ([method CameraRig.set_ui_cursor_release]). Las
## medidas, colores y textos son provisionales. Solo cliente.

## Se ha elegido una opción de reaparición válida.
signal respawn_option_chosen(option: RespawnPointList.Option)
signal opened
signal closed

const LEGEND_WIDTH: float = 300.0
const OUTER_MARGIN: float = 56.0
const GAP: float = 24.0
const DIM_COLOR: Color = Color(0.0, 0.0, 0.0, 0.68)
const FRAME_COLOR: Color = Color(0.62, 0.58, 0.5, 1.0)
const BACK_COLOR: Color = Color(0.05, 0.055, 0.07, 0.96)
const TEXT_COLOR: Color = Color(0.93, 0.92, 0.88, 1.0)
const TEXT_DIM: Color = Color(0.66, 0.64, 0.6, 1.0)
const OUTLINE_COLOR: Color = Color(0.0, 0.0, 0.0, 0.85)
const VALID_COLOR: Color = Color(0.5, 0.95, 0.5, 1.0)
const INVALID_COLOR: Color = Color(0.5, 0.5, 0.5, 0.8)
const ICON_SIZE: float = 9.0
const OPTION_RADIUS: float = 13.0
const PICK_RADIUS: float = 16.0
const FONT_SIZE: int = 15
const TITLE_SIZE: int = 24

const TEXT_TITLE: String = "Mapa · %s"
const TEXT_HINT_OPEN: String = "M o Esc para cerrar"
const TEXT_HINT_RESPAWN: String = "Elige dónde reaparecer: pulsa un punto resaltado"
const TEXT_LEGEND: String = "Leyenda"
const TEXT_YOU: String = "Tú"
const TEXT_ALLIES: String = "Compañeros de reino"
const TEXT_RESPAWN_VALID: String = "Reaparición disponible"
const TEXT_RESPAWN_INVALID: String = "Reaparición no disponible"
const TEXT_NO_MAP: String = "Esta zona no tiene mapa"
const TEXT_CAPTURE: String = "Captura: %d %%"
const KIND_NAMES: Dictionary = {
	WorldMarker.Kind.FORT: "Fuerte",
	WorldMarker.Kind.GATE: "Puerta del fuerte",
	WorldMarker.Kind.CIRCLE: "Círculo de captura",
	WorldMarker.Kind.CAMP: "Campamento",
	WorldMarker.Kind.PASS: "Paso a otra zona",
}

var _client: NetClient = null
var _view: FortressView = null
var _camera_rig: CameraRig = null
var _map: ZoneMapDefinition = null
var _texture: Texture2D = null
var _world: Node = null
var _open: bool = false
var _respawn_mode: bool = false
var _options: Array[RespawnPointList.Option] = []
var _markers: Array[WorldMarker] = []
var _hover: int = -1
var _hover_marker: int = -1
var _mouse: Vector2 = Vector2(-1.0, -1.0)
var _player_position: Vector3 = Vector3.ZERO
var _player_yaw: float = 0.0
var _has_player: bool = false
var _allies: Array[Vector3] = []
var _clock: float = 0.0


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	visible = false


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	set_process_unhandled_input(true)


func _exit_tree() -> void:
	if _open and is_instance_valid(_camera_rig):
		_camera_rig.set_ui_cursor_release(false, self)


func _process(delta: float) -> void:
	if _open:
		_clock += delta
		refresh()


func _unhandled_input(event: InputEvent) -> void:
	if InputMap.has_action(&"open_map") and event.is_action_pressed(&"open_map") and _can_toggle():
		toggle()
		get_viewport().set_input_as_handled()
	elif _open and InputMap.has_action(&"toggle_cursor") and event.is_action_pressed(&"toggle_cursor"):
		close()
		get_viewport().set_input_as_handled()


func _gui_input(event: InputEvent) -> void:
	if not _open:
		return
	if event is InputEventMouseMotion:
		_mouse = (event as InputEventMouseMotion).position
		_update_hover()
		queue_redraw()
	elif event is InputEventMouseButton:
		var button: InputEventMouseButton = event as InputEventMouseButton
		if button.button_index == MOUSE_BUTTON_LEFT and button.pressed:
			if click_at(button.position):
				accept_event()


## Conecta el mapa con el cliente (tu posición y tus compañeros), la vista del fuerte (estado), la cámara
## (hacia dónde miras y el cursor), el mapa horneado ([param map] puede ser null) y la zona
## ([param world], de la que salen los puntos de reaparición).
func bind(client: NetClient, view: FortressView, camera_rig: CameraRig, map: ZoneMapDefinition,
		world: Node) -> void:
	_client = client
	_view = view
	_camera_rig = camera_rig
	_map = map
	_texture = map.load_texture() if map != null else null
	_world = world
	_options.clear()


## Abre el mapa. Con [param respawn] elige además dónde reaparecer ([method set_respawn_mode]).
func open(respawn: bool = false) -> void:
	_respawn_mode = respawn
	if _open:
		refresh()
		return
	_open = true
	visible = true
	if is_instance_valid(_camera_rig):
		_camera_rig.set_ui_cursor_release(true, self)
	refresh()
	opened.emit()


func close() -> void:
	if not _open:
		return
	_open = false
	_respawn_mode = false
	visible = false
	_hover = -1
	if is_instance_valid(_camera_rig):
		_camera_rig.set_ui_cursor_release(false, self)
	closed.emit()


func toggle() -> void:
	if _open:
		close()
	else:
		open()


func is_open() -> bool:
	return _open


## Con [param enabled] el mapa ofrece los puntos de reaparición para elegir.
func set_respawn_mode(enabled: bool) -> void:
	_respawn_mode = enabled
	queue_redraw()


func is_respawn_mode() -> bool:
	return _respawn_mode


## Vuelve a leer dónde está todo y qué reapariciones valen (cada fotograma mientras está abierto).
func refresh() -> void:
	var character: PlayerCharacter = _client.get_character() if is_instance_valid(_client) else null
	_has_player = character != null and is_instance_valid(character)
	if _has_player:
		_player_position = character.global_position if character.is_inside_tree() else character.position
		_player_yaw = _camera_rig.get_yaw() if is_instance_valid(_camera_rig) else character.yaw
	_markers = MarkerSource.build(_map, _view)
	_allies.clear()
	if is_instance_valid(_client):
		var own_realm: int = _client.get_config().realm if _client.get_config() != null else 0
		for remote: RemotePlayerView in _client.get_remote_world().get_views():
			if own_realm != NetProtocol.Realm.NONE and remote.get_kind() == NetProtocol.EntityKind.PLAYER \
					and remote.get_realm() == own_realm and remote.is_drawn():
				_allies.append(remote.get_drawn_position())
	_refresh_options()
	_update_hover()
	queue_redraw()


# --- Consultas --------------------------------------------------------------------------------

## Rectángulo (píxeles del control) donde se pinta la imagen del mapa: un cuadrado a la izquierda, con la
## leyenda a su derecha, todo centrado.
func get_map_rect() -> Rect2:
	var side: float = maxf(minf(size.y - OUTER_MARGIN * 2.0, size.x - LEGEND_WIDTH - GAP - OUTER_MARGIN * 2.0), 64.0)
	var total_width: float = side + GAP + LEGEND_WIDTH
	var left: float = maxf((size.x - total_width) * 0.5, OUTER_MARGIN * 0.5)
	return Rect2(Vector2(left, (size.y - side) * 0.5), Vector2(side, side))


## Rectángulo de la leyenda, a la derecha del mapa.
func get_legend_rect() -> Rect2:
	var map_rect: Rect2 = get_map_rect()
	return Rect2(Vector2(map_rect.end.x + GAP, map_rect.position.y), Vector2(LEGEND_WIDTH, map_rect.size.y))


## Dónde cae [param world] en el control (píxeles). Sin mapa, el centro del rectángulo del mapa.
func world_to_screen(world: Vector3) -> Vector2:
	var rect: Rect2 = get_map_rect()
	if _map == null:
		return rect.get_center()
	return rect.position + _map.world_to_uv(world) * rect.size


## Punto del mundo (y = 0) bajo [param point] (píxeles del control).
func screen_to_world(point: Vector2) -> Vector3:
	var rect: Rect2 = get_map_rect()
	if _map == null:
		return Vector3.ZERO
	return _map.uv_to_world((point - rect.position) / rect.size)


## Opciones de reaparición que se están mostrando (válidas o no).
func get_options() -> Array[RespawnPointList.Option]:
	return _options.duplicate()


## Marcadores que se están dibujando.
func get_markers() -> Array[WorldMarker]:
	return _markers.duplicate()


## Índice (en [method get_options]) de la opción cuyo icono está a menos de [constant PICK_RADIUS] píxeles
## de [param point], o -1. Solo cuentan en el modo de reaparición.
func get_option_at(point: Vector2) -> int:
	if not _respawn_mode:
		return -1
	var best: int = -1
	var best_distance: float = PICK_RADIUS
	for i: int in _options.size():
		var distance: float = world_to_screen(_options[i].position).distance_to(point)
		if distance <= best_distance:
			best_distance = distance
			best = i
	return best


## Pulsa en [param point]: si cae en una opción de reaparición válida emite [signal respawn_option_chosen]
## y devuelve true.
func click_at(point: Vector2) -> bool:
	var index: int = get_option_at(point)
	if index < 0 or not _options[index].valid:
		return false
	respawn_option_chosen.emit(_options[index])
	return true


## Índice de la opción bajo el ratón (-1 si ninguna).
func get_hover_option() -> int:
	return _hover


## Líneas de la leyenda: [code]{"kind": int o StringName, "text": String, "color": Color}[/code].
func get_legend_entries() -> Array[Dictionary]:
	var entries: Array[Dictionary] = []
	entries.append({"kind": &"player", "text": TEXT_YOU, "color": Color.WHITE})
	entries.append({"kind": &"ally", "text": TEXT_ALLIES,
			"color": UIPalette.faction_color_of_code(_realm())})
	var present: Dictionary = {}
	for marker: WorldMarker in _markers:
		present[marker.kind] = true
	for kind: int in [WorldMarker.Kind.FORT, WorldMarker.Kind.GATE, WorldMarker.Kind.CIRCLE,
			WorldMarker.Kind.CAMP, WorldMarker.Kind.PASS]:
		if present.has(kind):
			entries.append({"kind": kind, "text": KIND_NAMES[kind], "color": UIPalette.TEXT})
	if _respawn_mode:
		entries.append({"kind": &"respawn_valid", "text": TEXT_RESPAWN_VALID, "color": VALID_COLOR})
		entries.append({"kind": &"respawn_invalid", "text": TEXT_RESPAWN_INVALID, "color": INVALID_COLOR})
	return entries


## Texto del estado del fuerte para la leyenda: nombre, dueño, fase, captura y puerta (vacío si el cliente
## aún no conoce ninguna fortaleza).
func get_fortress_lines() -> PackedStringArray:
	var lines := PackedStringArray()
	if not is_instance_valid(_view):
		return lines
	var net_id: int = _view.get_primary_id()
	var state: FortressState = _view.get_displayed_state(net_id) if net_id != 0 else null
	if state == null:
		return lines
	var definition: FortressDefinition = _view.get_definition(net_id)
	lines.append(definition.display_name if definition != null else "Fuerte")
	lines.append(CapturePanel.TEXT_NO_OWNER if state.owner == RealmCatalog.NEUTRAL_CODE
			else CapturePanel.TEXT_OWNER % WarEvents.realm_label(state.owner))
	lines.append(CapturePanel.phase_text(state, _realm()))
	var status: String = CapturePanel.status_text(state)
	if not status.is_empty():
		lines.append(status)
	if state.phase == FortressState.Phase.CAPTURING:
		lines.append(TEXT_CAPTURE % roundi(_view.get_progress_fraction_now(net_id) * 100.0))
	if state.gate_max > 0:
		lines.append(CapturePanel.TEXT_GATE_BROKEN if state.is_gate_broken()
				else CapturePanel.TEXT_GATE % [state.gate_health, state.gate_max])
	return lines


## Título del mapa («Mapa · Vado Gris»).
func get_title_text() -> String:
	var zone_name: String = String(_map.zone_id).capitalize() if _map != null else ""
	return TEXT_TITLE % zone_name if not zone_name.is_empty() else "Mapa"


func get_hint_text() -> String:
	return TEXT_HINT_RESPAWN if _respawn_mode else TEXT_HINT_OPEN


# --- Interno ----------------------------------------------------------------------------------

func _can_toggle() -> bool:
	return is_instance_valid(_client)


func _realm() -> int:
	return _client.get_config().realm if is_instance_valid(_client) and _client.get_config() != null else 0


func _refresh_options() -> void:
	_options.clear()
	if not _respawn_mode or _world == null or not is_instance_valid(_world) or not is_instance_valid(_client):
		return
	var tick: int = _client.get_estimated_server_tick()
	var states: Dictionary = _view.get_states_by_definition(tick) if is_instance_valid(_view) else {}
	var names: Dictionary = {}
	if is_instance_valid(_view):
		for net_id: int in _view.get_fortress_ids():
			var definition: FortressDefinition = _view.get_definition(net_id)
			if definition != null:
				names[definition.id] = definition.display_name
	_options = RespawnPointList.options(_world, _realm(), states, tick, names)


func _update_hover() -> void:
	_hover = get_option_at(_mouse)
	_hover_marker = -1
	var best: float = PICK_RADIUS
	for i: int in _markers.size():
		var distance: float = world_to_screen(_markers[i].position).distance_to(_mouse)
		if distance <= best:
			best = distance
			_hover_marker = i


func _draw() -> void:
	if not _open:
		return
	draw_rect(Rect2(Vector2.ZERO, size), DIM_COLOR)
	var rect: Rect2 = get_map_rect()
	draw_rect(rect.grow(6.0), BACK_COLOR)
	if _texture != null:
		draw_texture_rect(_texture, rect, false)
	else:
		draw_string(get_theme_default_font(), rect.get_center() - Vector2(80.0, 0.0), TEXT_NO_MAP,
				HORIZONTAL_ALIGNMENT_LEFT, -1.0, FONT_SIZE, TEXT_DIM)
	draw_rect(rect.grow(6.0), FRAME_COLOR, false, 2.0)
	for i: int in _markers.size():
		var marker: WorldMarker = _markers[i]
		var at: Vector2 = world_to_screen(marker.position)
		if not rect.has_point(at):
			continue
		MarkerIcons.draw(self, marker.kind, at, marker.color, ICON_SIZE)
		if marker.kind != WorldMarker.Kind.CIRCLE or i == _hover_marker:
			_draw_label(marker.label, at + Vector2(ICON_SIZE + 5.0, 5.0), FONT_SIZE - 2, TEXT_COLOR)
	for ally: Vector3 in _allies:
		var ally_at: Vector2 = world_to_screen(ally)
		if rect.has_point(ally_at):
			draw_circle(ally_at, 4.5, MarkerIcons.OUTLINE_COLOR)
			draw_circle(ally_at, 3.5, UIPalette.faction_color_of_code(_realm()))
	_draw_options()
	if _has_player:
		var player_at: Vector2 = world_to_screen(_player_position)
		var direction: Vector2 = Minimap.yaw_to_direction(_player_yaw)
		MarkerIcons.draw_arrow(self, player_at, atan2(direction.x, -direction.y), Color.WHITE, 9.0)
	_draw_legend()
	_draw_label(get_title_text(), rect.position + Vector2(0.0, -14.0), TITLE_SIZE, UIPalette.TITLE)
	_draw_label(get_hint_text(), Vector2(rect.position.x, rect.end.y + 30.0), FONT_SIZE, TEXT_DIM)


func _draw_options() -> void:
	if not _respawn_mode:
		return
	var pulse: float = 0.5 + 0.5 * sin(_clock * TAU * 1.2)
	for i: int in _options.size():
		var option: RespawnPointList.Option = _options[i]
		var at: Vector2 = world_to_screen(option.position)
		var color: Color = VALID_COLOR if option.valid else INVALID_COLOR
		var radius: float = OPTION_RADIUS + (3.0 * pulse if option.valid else 0.0) + (3.0 if i == _hover else 0.0)
		draw_arc(at, radius, 0.0, TAU, 28, MarkerIcons.OUTLINE_COLOR, 5.0, true)
		draw_arc(at, radius, 0.0, TAU, 28, color, 3.0, true)
		if i == _hover or option.valid:
			_draw_label(option.label, at + Vector2(OPTION_RADIUS + 6.0, 18.0), FONT_SIZE - 1, color)


func _draw_legend() -> void:
	var rect: Rect2 = get_legend_rect()
	draw_rect(rect, BACK_COLOR)
	draw_rect(rect, FRAME_COLOR, false, 1.5)
	var y: float = rect.position.y + 26.0
	_draw_label(TEXT_LEGEND, Vector2(rect.position.x + 14.0, y), FONT_SIZE + 2, UIPalette.TITLE)
	y += 12.0
	for entry: Dictionary in get_legend_entries():
		y += 26.0
		var icon_at := Vector2(rect.position.x + 24.0, y - 5.0)
		var kind: Variant = entry["kind"]
		var color: Color = entry["color"]
		if typeof(kind) == TYPE_INT:
			MarkerIcons.draw(self, int(kind), icon_at, color, 7.0)
		elif kind == &"player":
			MarkerIcons.draw_arrow(self, icon_at, 0.0, color, 7.0)
		elif kind == &"ally":
			draw_circle(icon_at, 4.5, color)
		else:
			draw_arc(icon_at, 7.0, 0.0, TAU, 20, color, 2.5, true)
		_draw_label(String(entry["text"]), Vector2(rect.position.x + 44.0, y), FONT_SIZE - 1, TEXT_COLOR)
	y += 30.0
	for line: String in get_fortress_lines():
		y += 22.0
		_draw_label(line, Vector2(rect.position.x + 14.0, y), FONT_SIZE - 1, TEXT_COLOR)


func _draw_label(text: String, at: Vector2, font_size: int, color: Color) -> void:
	var font: Font = get_theme_default_font()
	draw_string_outline(font, at, text, HORIZONTAL_ALIGNMENT_LEFT, -1.0, font_size, 4, OUTLINE_COLOR)
	draw_string(font, at, text, HORIZONTAL_ALIGNMENT_LEFT, -1.0, font_size, color)
