class_name WorldMap
extends Control
## Full-screen zone map (UI-20, UI-21, docs/fortress.md section 6). It opens with M
## ([code]open_map[/code]) and closes with M or Esc: it shows the baked top-down image with the fort (in
## its owner's color and its capture state), its gate and its circle, the camps, the passes,
## your position and the direction you are facing, your party members in view and, on the right, a legend and the
## fort status.
## [br][br]
## [b]Respawn choice (UI-21).[/b] With [method set_respawn_mode] (the death screen sets it when
## opening the map) the [RespawnPointList.Option] entries of your realm are also shown: those valid right now (your
## camp, a fort of yours that is idle and not under attack, according to [RespawnRules]) highlighted and the others
## dimmed. Clicking a valid one emits [signal respawn_option_chosen]; the server checks it again and,
## if it is no longer valid, respawns you at the camp.
## [br][br]
## [b]Readable window (UI-53).[/b] The wheel zooms in and out ([method zoom_at]), dragging with the left
## (or middle) button pans ([method pan_by]), and the labels (fort, camps, passes and the place names from
## [ZonePlaces]) are placed by [MapLabelPlacer] so they do not overlap, with a leader line if they end up far from their icon. The background is
## opaque: with the map open the HUD does not show through. The player is a 15 px arrow with a halo and "Tú" ("You").
## [br][br]
## While it is open it releases the camera cursor ([method CameraRig.set_ui_cursor_release]). Sizes,
## colors and texts are provisional. Client only.

## A valid respawn option has been chosen.
signal respawn_option_chosen(option: RespawnPointList.Option)
signal opened
signal closed

const LEGEND_WIDTH: float = 300.0
const OUTER_MARGIN: float = 56.0
const GAP: float = 24.0
const DIM_COLOR: Color = Color(0.035, 0.03, 0.026, 1.0)
const FRAME_COLOR: Color = Color(0.56, 0.47, 0.34, 1.0)
const BACK_COLOR: Color = Color(0.075, 0.065, 0.055, 0.98)
## Ink of the labels over the parchment and its light halo.
const INK_COLOR: Color = Color(0.10, 0.075, 0.055, 1.0)
const INK_HALO: Color = Color(0.86, 0.80, 0.66, 0.9)
const AREA_COLOR: Color = Color(0.22, 0.17, 0.12, 0.92)
const TEXT_COLOR: Color = Color(0.93, 0.92, 0.88, 1.0)
const TEXT_DIM: Color = Color(0.66, 0.64, 0.6, 1.0)
const OUTLINE_COLOR: Color = Color(0.0, 0.0, 0.0, 0.85)
const VALID_COLOR: Color = Color(0.5, 0.95, 0.5, 1.0)
const INVALID_COLOR: Color = Color(0.5, 0.5, 0.5, 0.8)
const ICON_SIZE: float = 9.0
const PLAYER_SIZE: float = 15.0
## Window zoom: 1 shows the whole map; each wheel step multiplies by [constant ZOOM_STEP].
const MIN_ZOOM: float = 1.0
const MAX_ZOOM: float = 6.0
const ZOOM_STEP: float = 1.25
## Label priority by type (higher picks its spot first).
const PRIORITY_PLAYER: int = 120
const PRIORITY_OPTION: int = 110
const PRIORITY_FORT: int = 100
const PRIORITY_CAMP: int = 80
const PRIORITY_PASS: int = 60
const PRIORITY_PLACE: int = 70
const PRIORITY_AREA: int = 20
const OPTION_RADIUS: float = 13.0
const PICK_RADIUS: float = 16.0
const FONT_SIZE: int = 15
## Icons (markers, places) closer than this to an ally dot absorb it, so the dot does not cover them.
const ALLY_MERGE_RADIUS: float = 11.0
## The baked scale bar (southeast corner of the image): 80 m in four sections, [code]SCALE_BAR_END_MARGIN[/code] m
## from the east edge and [code]SCALE_BAR_SOUTH_MARGIN[/code] m from the south one (see the parchment baker).
const SCALE_BAR_SPAN: float = 80.0
const SCALE_BAR_SECTION: float = 20.0
const SCALE_BAR_END_MARGIN: float = 14.0
const SCALE_BAR_SOUTH_MARGIN: float = 23.0
const SCALE_LABEL_SIZE: int = 13
const TITLE_SIZE: int = 24

const TEXT_TITLE: String = "Mapa · %s"
const TEXT_HINT_OPEN: String = "M o Esc para cerrar"
const TEXT_CONTROLS: String = "Rueda: acercar · Arrastrar: mover · Doble clic: ver todo"
const TEXT_HINT_RESPAWN: String = "Elige dónde reaparecer: pulsa un punto resaltado"
const TEXT_LEGEND: String = "Leyenda"
const TEXT_YOU: String = "Tú"
const TEXT_ALLIES: String = "Compañeros de reino"
const TEXT_RESPAWN_VALID: String = "Reaparición disponible"
const TEXT_RESPAWN_INVALID: String = "Reaparición no disponible"
const TEXT_REALMS: String = "Bandos"
## Free space (px) under the last legend line.
const LEGEND_BOTTOM_PAD: float = 20.0
const TEXT_SCALE_UNIT: String = "%d m"
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
var _zoom: float = MIN_ZOOM
var _center_uv: Vector2 = Vector2(0.5, 0.5)
var _dragging: bool = false
var _places: Array[MapLandmark] = []
var _labels: Array[Dictionary] = []


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
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
		var motion: InputEventMouseMotion = event as InputEventMouseMotion
		_mouse = motion.position
		if _dragging:
			pan_by(motion.relative)
		_update_hover()
		queue_redraw()
	elif event is InputEventMouseButton:
		var button: InputEventMouseButton = event as InputEventMouseButton
		if button.button_index == MOUSE_BUTTON_WHEEL_UP and button.pressed:
			zoom_at(ZOOM_STEP, button.position)
			accept_event()
		elif button.button_index == MOUSE_BUTTON_WHEEL_DOWN and button.pressed:
			zoom_at(1.0 / ZOOM_STEP, button.position)
			accept_event()
		elif button.button_index == MOUSE_BUTTON_LEFT and button.pressed:
			if click_at(button.position):
				accept_event()
			elif button.double_click:
				reset_view()
				accept_event()
			elif get_map_rect().has_point(button.position):
				_dragging = true
				accept_event()
		elif button.button_index == MOUSE_BUTTON_MIDDLE and button.pressed:
			_dragging = true
			accept_event()
		elif not button.pressed and (button.button_index == MOUSE_BUTTON_LEFT \
				or button.button_index == MOUSE_BUTTON_MIDDLE):
			_dragging = false


## Connects the map to the client (your position and your party members), the fort view (state), the camera
## (where you are looking and the cursor), the baked map ([param map] may be null) and the zone
## ([param world], which the respawn points come from).
func bind(client: NetClient, view: FortressView, camera_rig: CameraRig, map: ZoneMapDefinition,
		world: Node) -> void:
	_client = client
	_view = view
	_camera_rig = camera_rig
	_map = map
	_texture = map.load_texture() if map != null else null
	_places = ZonePlaces.for_zone(map.zone_id) if map != null else ([] as Array[MapLandmark])
	_world = world
	_options.clear()


## Opens the map. With [param respawn] it also lets you choose where to respawn ([method set_respawn_mode]).
func open(respawn: bool = false) -> void:
	_respawn_mode = respawn
	if _open:
		refresh()
		return
	_open = true
	visible = true
	reset_view()
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
	_dragging = false
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


## With [param enabled] the map offers the respawn points to choose from.
func set_respawn_mode(enabled: bool) -> void:
	_respawn_mode = enabled
	queue_redraw()


func is_respawn_mode() -> bool:
	return _respawn_mode


## Re-reads where everything is and which respawns are valid (every frame while it is open).
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
	_build_labels()
	_update_hover()
	queue_redraw()


# --- Queries --------------------------------------------------------------------------------

## Rectangle (control pixels) where the map image is painted: a square on the left, with the
## legend to its right, all centered.
func get_map_rect() -> Rect2:
	var side: float = maxf(minf(size.y - OUTER_MARGIN * 2.0, size.x - LEGEND_WIDTH - GAP - OUTER_MARGIN * 2.0), 64.0)
	var total_width: float = side + GAP + LEGEND_WIDTH
	var left: float = maxf((size.x - total_width) * 0.5, OUTER_MARGIN * 0.5)
	return Rect2(Vector2(left, (size.y - side) * 0.5), Vector2(side, side))


## Rectangle of the legend, to the right of the map.
func get_legend_rect() -> Rect2:
	var map_rect: Rect2 = get_map_rect()
	return Rect2(Vector2(map_rect.end.x + GAP, map_rect.position.y), Vector2(LEGEND_WIDTH, map_rect.size.y))


## Where [param world] lands on the control (pixels). With no map, the center of the map rectangle.
func world_to_screen(world: Vector3) -> Vector2:
	var rect: Rect2 = get_map_rect()
	if _map == null:
		return rect.get_center()
	var view_uv: Rect2 = get_view_uv()
	return rect.position + (_map.world_to_uv(world) - view_uv.position) / view_uv.size * rect.size


## World point (y = 0) under [param point] (control pixels).
func screen_to_world(point: Vector2) -> Vector3:
	var rect: Rect2 = get_map_rect()
	if _map == null:
		return Vector3.ZERO
	var view_uv: Rect2 = get_view_uv()
	return _map.uv_to_world(view_uv.position + (point - rect.position) / rect.size * view_uv.size)


## Piece of the image that is visible now, in texture coordinates (0 to 1): at zoom 1 the whole image.
func get_view_uv() -> Rect2:
	var half: float = 0.5 / _zoom
	return Rect2(_center_uv - Vector2(half, half), Vector2(half, half) * 2.0)


func get_zoom() -> float:
	return _zoom


## Center of the view in texture coordinates.
func get_view_center() -> Vector2:
	return _center_uv


## Multiplies the zoom by [param factor] (between [constant MIN_ZOOM] and [constant MAX_ZOOM]) keeping fixed the world
## point under [param at] (control pixels).
func zoom_at(factor: float, at: Vector2) -> void:
	var rect: Rect2 = get_map_rect()
	var fixed_fraction: Vector2 = ((at - rect.position) / rect.size).clamp(Vector2.ZERO, Vector2.ONE)
	var before: Rect2 = get_view_uv()
	var anchor_uv: Vector2 = before.position + fixed_fraction * before.size
	_zoom = clampf(_zoom * factor, MIN_ZOOM, MAX_ZOOM)
	var half: float = 0.5 / _zoom
	_center_uv = anchor_uv - (fixed_fraction - Vector2(0.5, 0.5)) * half * 2.0
	_clamp_center()
	refresh()


## Pans the map by [param delta] control pixels (like dragging the image by hand).
func pan_by(delta: Vector2) -> void:
	var rect: Rect2 = get_map_rect()
	_center_uv -= delta / rect.size * get_view_uv().size
	_clamp_center()
	refresh()


## Shows the whole map again.
func reset_view() -> void:
	_zoom = MIN_ZOOM
	_center_uv = Vector2(0.5, 0.5)
	_dragging = false


## Labels of the window right now: [code]{"id", "text", "anchor", "rect", "placed", "leader", "area", "color"}[/code].
func get_labels() -> Array[Dictionary]:
	return _labels.duplicate()


## Place names of the zone.
func get_places() -> Array[MapLandmark]:
	return _places.duplicate()


## Respawn options being shown (valid or not).
func get_options() -> Array[RespawnPointList.Option]:
	return _options.duplicate()


## Markers being drawn.
func get_markers() -> Array[WorldMarker]:
	return _markers.duplicate()


## Index (in [method get_options]) of the option whose icon is less than [constant PICK_RADIUS] pixels
## from [param point], or -1. They only count in respawn mode.
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


## Clicks at [param point]: if it lands on a valid respawn option it emits [signal respawn_option_chosen]
## and returns true.
func click_at(point: Vector2) -> bool:
	var index: int = get_option_at(point)
	if index < 0 or not _options[index].valid:
		return false
	respawn_option_chosen.emit(_options[index])
	return true


## Index of the option under the mouse (-1 if none).
func get_hover_option() -> int:
	return _hover


## Legend lines: [code]{"kind": int or StringName, "text": String, "color": Color}[/code].
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


## Fort status text for the legend: name, owner, phase, capture and gate (empty if the client
## does not know any fortress yet).
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


## Map title ("Mapa · Vado Gris", i.e. "Map · Vado Gris").
func get_title_text() -> String:
	var zone_name: String = String(_map.zone_id).capitalize() if _map != null else ""
	return TEXT_TITLE % zone_name if not zone_name.is_empty() else "Mapa"


func get_hint_text() -> String:
	return TEXT_HINT_RESPAWN if _respawn_mode else TEXT_HINT_OPEN


# --- Internal ----------------------------------------------------------------------------------

func _clamp_center() -> void:
	var half: float = 0.5 / _zoom
	_center_uv = Vector2(clampf(_center_uv.x, half, 1.0 - half), clampf(_center_uv.y, half, 1.0 - half))


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
	var names: Dictionary = _view.get_display_names() if is_instance_valid(_view) else {}
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


## Gathers all the labels (markers, respawn options, place names and "Tú" ("You")) and places them so they do not overlap.
func _build_labels() -> void:
	_labels.clear()
	if _map == null:
		return
	var rect: Rect2 = get_map_rect()
	var font: Font = get_theme_default_font()
	var items: Array[Dictionary] = []
	var player_at: Vector2 = world_to_screen(_player_position)
	# While respawning, the camp or fort is labeled by its option (a single label).
	var option_spots: Array[Vector3] = []
	for option: RespawnPointList.Option in _options:
		option_spots.append(option.position)
	for marker: WorldMarker in _markers:
		if marker.kind == WorldMarker.Kind.CIRCLE and _markers.find(marker) != _hover_marker:
			continue
		var at: Vector2 = world_to_screen(marker.position)
		if not rect.has_point(at) or _near_any(marker.position, option_spots, 12.0):
			continue
		items.append(_label_item(font, StringName("m_%s" % marker.id), marker.label, at, _marker_priority(marker.kind),
				false, INK_COLOR, FONT_SIZE - 1))
	for landmark: MapLandmark in _places:
		var at: Vector2 = world_to_screen(landmark.position)
		if not rect.has_point(at):
			continue
		items.append(_label_item(font, StringName("p_%s" % landmark.label), landmark.label, at,
				PRIORITY_AREA if landmark.area else PRIORITY_PLACE, landmark.area,
				AREA_COLOR if landmark.area else INK_COLOR, FONT_SIZE - 2 if landmark.area else FONT_SIZE - 1))
	for i: int in _options.size():
		var option: RespawnPointList.Option = _options[i]
		var at: Vector2 = world_to_screen(option.position)
		if rect.has_point(at) and (option.valid or i == _hover):
			items.append(_label_item(font, StringName("o_%d" % i), option.label, at, PRIORITY_OPTION, false,
					VALID_COLOR if option.valid else INVALID_COLOR, FONT_SIZE - 1))
	if _has_player and rect.has_point(player_at):
		var you: Dictionary = _label_item(font, &"player", TEXT_YOU, player_at, PRIORITY_PLAYER, false, INK_COLOR, FONT_SIZE)
		you["radius"] = PLAYER_SIZE + 5.0
		items.append(you)
	# Ally icons must not be covered either, but they have no label: they count as small obstacles.
	var extra: Array[Rect2] = []
	for ally_at: Vector2 in get_free_ally_points():
		extra.append(Rect2(ally_at - Vector2.ONE * 5.0, Vector2.ONE * 10.0))
	_labels = MapLabelPlacer.place(items, rect.grow(-4.0), extra)


func _label_item(font: Font, id: StringName, text: String, at: Vector2, priority: int, is_area: bool,
		color: Color, font_size: int) -> Dictionary:
	var size: Vector2 = font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1.0, font_size) + Vector2(6.0, 4.0)
	return {"id": id, "text": text, "anchor": at, "size": size, "priority": priority, "area": is_area,
			"color": color, "font_size": font_size}


func _marker_priority(kind: int) -> int:
	match kind:
		WorldMarker.Kind.FORT:
			return PRIORITY_FORT
		WorldMarker.Kind.CAMP:
			return PRIORITY_CAMP
		_:
			return PRIORITY_PASS


static func _near_any(point: Vector3, spots: Array[Vector3], meters: float) -> bool:
	for spot: Vector3 in spots:
		if Vector2(point.x - spot.x, point.z - spot.z).length() <= meters:
			return true
	return false


func _draw() -> void:
	if not _open:
		return
	# Opaque background: the HUD underneath does not show through.
	draw_rect(Rect2(Vector2.ZERO, size), DIM_COLOR)
	var rect: Rect2 = get_map_rect()
	draw_rect(rect.grow(6.0), BACK_COLOR)
	if _texture != null:
		var view_uv: Rect2 = get_view_uv()
		var texture_size: Vector2 = _texture.get_size()
		draw_texture_rect_region(_texture, rect, Rect2(view_uv.position * texture_size, view_uv.size * texture_size))
	else:
		draw_string(get_theme_default_font(), rect.get_center() - Vector2(80.0, 0.0), TEXT_NO_MAP,
				HORIZONTAL_ALIGNMENT_LEFT, -1.0, FONT_SIZE, TEXT_DIM)
	draw_rect(rect.grow(6.0), FRAME_COLOR, false, 3.0)
	_draw_area_labels()
	for i: int in _markers.size():
		var marker: WorldMarker = _markers[i]
		var at: Vector2 = world_to_screen(marker.position)
		if rect.has_point(at):
			MarkerIcons.draw(self, marker.kind, at, marker.color, ICON_SIZE)
	for landmark: MapLandmark in _places:
		var place_at: Vector2 = world_to_screen(landmark.position)
		if not landmark.area and rect.has_point(place_at):
			_draw_place_icon(place_at)
	var icon_points: PackedVector2Array = _icon_points()
	var absorbed: Dictionary[int, int] = {}
	for ally: Vector3 in _allies:
		var ally_at: Vector2 = world_to_screen(ally)
		if not rect.has_point(ally_at):
			continue
		var icon: int = nearest_icon(ally_at, icon_points)
		if icon >= 0:
			absorbed[icon] = int(absorbed.get(icon, 0)) + 1
			continue
		draw_circle(ally_at, 4.5, MarkerIcons.OUTLINE_COLOR)
		draw_circle(ally_at, 3.5, UIPalette.faction_color_of_code(_realm()))
	for icon: int in absorbed:
		if not (_has_player and icon == icon_points.size() - 1):
			draw_arc(icon_points[icon], ALLY_MERGE_RADIUS + 1.0, 0.0, TAU, 24,
					UIPalette.faction_color_of_code(_realm()), 2.0, true)
	_draw_scale_numbers(rect)
	_draw_options()
	_draw_point_labels()
	if _has_player and rect.has_point(world_to_screen(_player_position)):
		var player_at: Vector2 = world_to_screen(_player_position)
		var direction: Vector2 = Minimap.yaw_to_direction(_player_yaw)
		draw_circle(player_at, PLAYER_SIZE + 5.0, Color(1.0, 1.0, 1.0, 0.28))
		draw_arc(player_at, PLAYER_SIZE + 5.0, 0.0, TAU, 32, Color(1.0, 1.0, 1.0, 0.9), 2.0, true)
		MarkerIcons.draw_arrow(self, player_at, atan2(direction.x, -direction.y), Color.WHITE, PLAYER_SIZE)
	_draw_legend()
	_draw_label(get_title_text(), rect.position + Vector2(0.0, -14.0), TITLE_SIZE, UIPalette.TITLE)
	_draw_label(get_hint_text(), Vector2(rect.position.x, rect.end.y + 30.0), FONT_SIZE, TEXT_DIM)
	_draw_label(TEXT_CONTROLS, Vector2(rect.end.x - 430.0, rect.end.y + 30.0), FONT_SIZE - 2, TEXT_DIM)


# Area labels (ranges, forests, river): drawn below the icons, with spaced letters and no plate.
func _draw_area_labels() -> void:
	var font: Font = get_theme_default_font()
	for label: Dictionary in _labels:
		if not bool(label["placed"]) or not bool(label["area"]):
			continue
		var rect: Rect2 = label["rect"]
		var font_size: int = int(label["font_size"])
		var at: Vector2 = Vector2(rect.position.x + 3.0, rect.position.y + rect.size.y - 6.0)
		draw_string_outline(font, at, String(label["text"]), HORIZONTAL_ALIGNMENT_LEFT, -1.0, font_size, 4, INK_HALO)
		draw_string(font, at, String(label["text"]), HORIZONTAL_ALIGNMENT_LEFT, -1.0, font_size, label["color"])


# Place labels (with a leader line if they end up far from the icon).
func _draw_point_labels() -> void:
	var font: Font = get_theme_default_font()
	for label: Dictionary in _labels:
		if not bool(label["placed"]) or bool(label["area"]):
			continue
		var rect: Rect2 = label["rect"]
		var anchor: Vector2 = label["anchor"]
		var font_size: int = int(label["font_size"])
		var text_color: Color = label["color"]
		var plate: Color = Color(0.09, 0.075, 0.06, 0.82) if _is_bright(text_color) else Color(0.88, 0.82, 0.68, 0.78)
		if bool(label["leader"]):
			var edge: Vector2 = Vector2(clampf(anchor.x, rect.position.x, rect.end.x),
					clampf(anchor.y, rect.position.y, rect.end.y))
			draw_line(anchor, edge, Color(0.1, 0.075, 0.05, 0.85), 1.5, true)
		draw_rect(rect, plate)
		draw_rect(rect, Color(0.1, 0.075, 0.05, 0.55), false, 1.0)
		draw_string(font, Vector2(rect.position.x + 3.0, rect.end.y - 6.0), String(label["text"]),
				HORIZONTAL_ALIGNMENT_LEFT, -1.0, font_size, text_color)


static func _is_bright(color: Color) -> bool:
	return color.get_luminance() > 0.5


# Icon of a point place name: a hollow ink diamond.
func _draw_place_icon(at: Vector2) -> void:
	var points := PackedVector2Array([at + Vector2(0.0, -6.0), at + Vector2(6.0, 0.0), at + Vector2(0.0, 6.0),
			at + Vector2(-6.0, 0.0)])
	draw_colored_polygon(points, INK_HALO)
	var closed := points.duplicate()
	closed.append(points[0])
	draw_polyline(closed, INK_COLOR, 2.0, true)


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


## Index of the icon of [param icons] within [constant ALLY_MERGE_RADIUS] of [param point] (the nearest), or -1.
static func nearest_icon(point: Vector2, icons: PackedVector2Array) -> int:
	var best: int = -1
	var best_distance: float = ALLY_MERGE_RADIUS
	for index: int in icons.size():
		var distance: float = icons[index].distance_to(point)
		if distance < best_distance:
			best = index
			best_distance = distance
	return best


## Screen points of every icon an ally can be absorbed by: markers, point places and the player.
func _icon_points() -> PackedVector2Array:
	var points := PackedVector2Array()
	for marker: WorldMarker in _markers:
		points.append(world_to_screen(marker.position))
	for landmark: MapLandmark in _places:
		if not landmark.area:
			points.append(world_to_screen(landmark.position))
	if _has_player:
		points.append(world_to_screen(_player_position))
	return points


## Allies that stand apart from every icon (screen points). The ones that touch an icon are absorbed by it and are drawn
## as a ring around it ([method _draw_absorbed_rings]); they are not obstacles for the labels either.
func get_free_ally_points() -> PackedVector2Array:
	var icons: PackedVector2Array = _icon_points()
	var free := PackedVector2Array()
	for ally: Vector3 in _allies:
		var at: Vector2 = world_to_screen(ally)
		if nearest_icon(at, icons) < 0:
			free.append(at)
	return free


## Numbers under the baked scale bar (0, 20, 40, 60 and 80 m), placed with the map so they follow zoom and drag.
func _draw_scale_numbers(rect: Rect2) -> void:
	if _map == null:
		return
	var x_end: float = _map.world_origin.x + _map.world_size.x - SCALE_BAR_END_MARGIN
	var z: float = _map.world_origin.y + _map.world_size.y - SCALE_BAR_SOUTH_MARGIN + 6.0
	var font: Font = get_theme_default_font()
	var count: int = roundi(SCALE_BAR_SPAN / SCALE_BAR_SECTION)
	for i: int in count + 1:
		var meters: int = roundi(SCALE_BAR_SECTION * float(i))
		var at: Vector2 = world_to_screen(Vector3(x_end - SCALE_BAR_SPAN + float(meters), 0.0, z))
		if not rect.grow(-4.0).has_point(at):
			continue
		var text: String = TEXT_SCALE_UNIT % meters if i == count else str(meters)
		var width: float = font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1.0, SCALE_LABEL_SIZE).x
		var origin: Vector2 = Vector2(at.x - width * 0.5, at.y)
		draw_string_outline(font, origin, text, HORIZONTAL_ALIGNMENT_LEFT, -1.0, SCALE_LABEL_SIZE, 3, INK_HALO)
		draw_string(font, origin, text, HORIZONTAL_ALIGNMENT_LEFT, -1.0, SCALE_LABEL_SIZE, INK_COLOR)


## Height the legend content needs (the panel is drawn only that tall, never beyond [method get_legend_rect]). It is
## measured by the same pass that draws, so a new line cannot be cut off.
func _legend_content_height() -> float:
	return _legend_pass(Rect2(), false) + LEGEND_BOTTOM_PAD


## One pass over the legend: draws it into [param rect] when [param draw] is true, and returns the y it ends at
## (relative to the top of the panel when measuring).
func _legend_pass(rect: Rect2, draw: bool) -> float:
	var x: float = rect.position.x
	var y: float = rect.position.y + 26.0
	if draw:
		_draw_label(TEXT_LEGEND, Vector2(x + 14.0, y), FONT_SIZE + 2, UIPalette.TITLE)
	y += 12.0
	for entry: Dictionary in get_legend_entries():
		y += 26.0
		if not draw:
			continue
		var icon_at := Vector2(x + 24.0, y - 5.0)
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
		_draw_label(String(entry["text"]), Vector2(x + 44.0, y), FONT_SIZE - 1, TEXT_COLOR)
	y += 30.0
	for line: String in get_fortress_lines():
		y += 22.0
		if draw:
			_draw_label(line, Vector2(x + 14.0, y), FONT_SIZE - 1, TEXT_COLOR)
	y += 40.0
	if draw:
		_draw_label(TEXT_REALMS, Vector2(x + 14.0, y), FONT_SIZE, UIPalette.TITLE)
	for realm_id: StringName in RealmCatalog.FACTION_IDS:
		y += 26.0
		if not draw:
			continue
		var swatch: Rect2 = Rect2(Vector2(x + 18.0, y - 15.0), Vector2(12.0, 12.0))
		draw_rect(swatch.grow(1.5), MarkerIcons.OUTLINE_COLOR)
		draw_rect(swatch, RealmCatalog.color_of(realm_id))
		_draw_label(RealmCatalog.display_name(realm_id), Vector2(x + 44.0, y), FONT_SIZE - 1, TEXT_COLOR)
	return y - rect.position.y


func _draw_legend() -> void:
	var rect: Rect2 = get_legend_rect()
	rect.size.y = minf(rect.size.y, _legend_content_height())
	draw_rect(rect, BACK_COLOR)
	draw_rect(rect, FRAME_COLOR, false, 1.5)
	_legend_pass(rect, true)


func _draw_label(text: String, at: Vector2, font_size: int, color: Color) -> void:
	var font: Font = get_theme_default_font()
	draw_string_outline(font, at, text, HORIZONTAL_ALIGNMENT_LEFT, -1.0, font_size, 4, OUTLINE_COLOR)
	draw_string(font, at, text, HORIZONTAL_ALIGNMENT_LEFT, -1.0, font_size, color)
