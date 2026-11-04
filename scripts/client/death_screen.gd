class_name DeathScreen
extends Control
## Death and respawn screen (UI-14). It opens on death and shows who defeated you and with what,
## the countdown until the server allows respawning, the list of respawn points and the
## "Reaparecer" (Respawn) button, which is only enabled when it is possible and sends the chosen point
## ([signal respawn_requested]). On respawn it closes and leaves nothing behind.
## [br][br]
## It does not read the network: the [HUD] opens it with [method open], updates it every frame with
## [method update_countdown] (with the server tick estimated by [NetClient]) and closes it with
## [method close]. The countdown is in server ticks, so it stays in sync with the
## real respawn even if the local clock drifts. The nodes are created once in
## [method _ready] and opening and closing it only changes texts and visibility: dying and respawning many
## times accumulates nothing.
## [br][br]
## [b]Equipment template[/b] (PRG-07, docs/abilities.md, section 6.5): below the respawn points,
## the [TemplateSelector] ([method get_template_selector]); the [HUD] sends the LOADOUT_SELECT on
## choosing and the template applies on this respawn.
## [br][br]
## [b]With the mouse.[/b] No control takes focus ([constant Control.FOCUS_NONE]): if a click on a point or a
## template left it focused, Tab would move focus instead of opening the scoreboard (which is mounted on top so it can be seen while dead) and
## Enter would press "Reaparecer" (phase 4 review, client).

## The player asks to respawn at point [param point_index] of the list.
signal respawn_requested(point_index: int)
## The player asks to see the map to choose the respawn point.
signal map_requested
## The screen has been opened or closed.
signal opened
signal closed

const TITLE_TEXT: String = "Has caído"
const BUTTON_TEXT: String = "Reaparecer"
const MAP_BUTTON_TEXT: String = "Elegir en el mapa"
const POINTS_TITLE: String = "Punto de reaparición"
const TEXT_READY: String = "Ya puedes reaparecer"
const TEXT_COUNTDOWN: String = "Podrás reaparecer en %d s"
const TEXT_REQUESTED: String = "Reapareciendo…"
const NO_POINTS_TEXT: String = "Punto de reaparición del reino"
const DIM_COLOR: Color = Color(0.02, 0.0, 0.0, 0.62)
const PANEL_WIDTH: float = 460.0
## Seconds without the player respawning after requesting it, after which the button is enabled
## again (the server does not answer a request made out of time).
const REQUEST_TIMEOUT_SECONDS: float = 2.0

var _open: bool = false
# Index sent for each row of the list (empty = the row's own).
var _point_indices: PackedInt32Array = PackedInt32Array()
var _respawn_tick: int = 0
var _estimated_tick: int = 0
var _requested: bool = false
var _request_age: float = 0.0
var _background: ColorRect = null
var _title: Label = null
var _cause: Label = null
var _countdown: Label = null
var _points_title: Label = null
var _points: ItemList = null
var _button: Button = null
var _map_button: Button = null
var _templates: TemplateSelector = null


func _ready() -> void:
	# Covers the screen and swallows the mouse while open (the cursor is free).
	mouse_filter = Control.MOUSE_FILTER_STOP
	_ensure_built()
	visible = _open


## Opens the screen. [param cause_text] is the sentence about who defeated you (see [method
## CombatText.death_text]), [param respawn_tick] the server tick at which respawning is possible
## and [param point_labels] the names of the respawn points, in the order of the list whose
## index is sent to the server. If it was already open, it only updates.
func open(cause_text: String, respawn_tick: int, point_labels: PackedStringArray) -> void:
	_ensure_built()
	_respawn_tick = respawn_tick
	_requested = false
	_request_age = 0.0
	_cause.text = cause_text
	_point_indices = PackedInt32Array()
	_set_points(point_labels)
	update_countdown(_estimated_tick)
	if not _open:
		_open = true
		visible = true
		opened.emit()


func _process(delta: float) -> void:
	advance(delta)


## Advances [param delta] seconds the wait for the response to a respawn request: if the
## server does not handle it within [constant REQUEST_TIMEOUT_SECONDS] s, the button is enabled again.
func advance(delta: float) -> void:
	if not _open or not _requested:
		return
	_request_age += delta
	if _request_age >= REQUEST_TIMEOUT_SECONDS:
		_requested = false
		update_countdown(_estimated_tick)


## Changes the list of points (the one from [method open]) without closing the screen: the state of the forts
## changes while waiting. Keeps the chosen point if it is still in the list.
func update_points(point_labels: PackedStringArray, indices: PackedInt32Array = PackedInt32Array()) -> void:
	_ensure_built()
	var previous: int = get_selected_point_index()
	var had_previous: bool = not _point_indices.is_empty() or _points.item_count > 0
	_set_points(point_labels)
	set_point_indices(indices)
	if had_previous:
		select_point_index(previous)


## Index sent in the request for each row of the list (the one from the list of all the zone's
## respawn markers, see [RespawnPointList.Option.index_for]). Without calling it, the row's own.
func set_point_indices(indices: PackedInt32Array) -> void:
	_point_indices = indices


## Index that would be sent now: that of the chosen row, mapped through [method set_point_indices] if set.
func get_selected_point_index() -> int:
	var row: int = get_selected_point()
	if row >= 0 and row < _point_indices.size():
		return _point_indices[row]
	return row


## Chooses the row whose sent index is [param point_index] (if it is in the list). Returns false if not.
func select_point_index(point_index: int) -> bool:
	for row: int in get_point_count():
		var sent: int = _point_indices[row] if row < _point_indices.size() else row
		if sent == point_index:
			select_point(row)
			return true
	return false


## Changes the sentence about who defeated you (the event may arrive with the screen already open).
func set_cause_text(text: String) -> void:
	_ensure_built()
	_cause.text = text


## Closes the screen (on respawn) and leaves everything as it was.
func close() -> void:
	if not _open:
		return
	_open = false
	_requested = false
	visible = false
	_button.disabled = true
	closed.emit()


## Updates the countdown with the server tick [param estimated_server_tick] (see
## [method NetClient.get_estimated_server_tick]). The button is enabled when that tick reaches the
## respawn tick.
func update_countdown(estimated_server_tick: int) -> void:
	_estimated_tick = estimated_server_tick
	if _button == null:
		return
	var remaining: int = get_remaining_ticks()
	if _requested:
		_countdown.text = TEXT_REQUESTED
	elif remaining <= 0:
		_countdown.text = TEXT_READY
	else:
		_countdown.text = TEXT_COUNTDOWN % get_remaining_seconds()
	_button.disabled = remaining > 0 or _requested


func is_open() -> bool:
	return _open


## Ticks remaining until respawn is possible (0 if it already is).
func get_remaining_ticks() -> int:
	return maxi(_respawn_tick - _estimated_tick, 0)


## Whole seconds (rounded up) remaining until respawn is possible.
func get_remaining_seconds() -> int:
	return ceili(float(get_remaining_ticks()) / float(Engine.physics_ticks_per_second))


## true if the button is enabled.
func is_respawn_enabled() -> bool:
	return _button != null and not _button.disabled


## Point chosen in the list (0 if there is no selection).
func get_selected_point() -> int:
	if _points == null:
		return 0
	var selected: PackedInt32Array = _points.get_selected_items()
	return selected[0] if not selected.is_empty() else 0


func select_point(index: int) -> void:
	if _points != null and index >= 0 and index < _points.item_count:
		_points.select(index)


## The equipment template selector for the respawn.
func get_template_selector() -> TemplateSelector:
	_ensure_built()
	return _templates


## The "Elegir en el mapa" (Choose on the map) button (visible while there is more than one point to choose from).
func get_map_button() -> Button:
	return _map_button


func get_point_count() -> int:
	return _points.item_count if _points != null else 0


func get_point_label(index: int) -> String:
	return _points.get_item_text(index) if _points != null and index < _points.item_count else ""


func get_cause_text() -> String:
	return _cause.text if _cause != null else ""


func get_countdown_text() -> String:
	return _countdown.text if _countdown != null else ""


## The "Reaparecer" (Respawn) button; tests press it with [code]emit_signal("pressed")[/code].
func get_button() -> Button:
	return _button


## Nodes hanging from the screen: it does not grow when opened and closed.
func get_node_total() -> int:
	return find_children("*", "", true, false).size()


func _on_button_pressed() -> void:
	if not _open or _button.disabled:
		return
	_requested = true
	_request_age = 0.0
	_button.disabled = true
	_countdown.text = TEXT_REQUESTED
	respawn_requested.emit(get_selected_point_index())


func _set_points(labels: PackedStringArray) -> void:
	_points.clear()
	var names: PackedStringArray = labels
	if names.is_empty():
		names = PackedStringArray([NO_POINTS_TEXT])
	for label: String in names:
		_points.add_item(label)
	_points.select(0)
	_points_title.visible = names.size() > 1
	_points.visible = names.size() > 1
	_map_button.visible = names.size() > 1
	# The list grows with the points, up to five visible rows.
	_points.custom_minimum_size = Vector2(0.0, 28.0 * mini(names.size(), 5) + 6.0)


func _ensure_built() -> void:
	if _title == null:
		_build()


func _build() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_background = ColorRect.new()
	_background.name = "Fondo"
	_background.color = DIM_COLOR
	_background.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_background)
	_background.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var center := CenterContainer.new()
	center.name = "Centro"
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(center)
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var column := VBoxContainer.new()
	column.name = "Columna"
	column.custom_minimum_size = Vector2(PANEL_WIDTH, 0.0)
	column.add_theme_constant_override(&"separation", 14)
	center.add_child(column)
	_title = _make_label("Titulo", TITLE_TEXT, 40)
	column.add_child(_title)
	_cause = _make_label("Causa", "", 22)
	_cause.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	column.add_child(_cause)
	_countdown = _make_label("Cuenta", "", 24)
	column.add_child(_countdown)
	_points_title = _make_label("TituloPuntos", POINTS_TITLE, 18)
	column.add_child(_points_title)
	_points = ItemList.new()
	_points.name = "Puntos"
	_points.select_mode = ItemList.SELECT_SINGLE
	_points.auto_height = false
	_points.focus_mode = Control.FOCUS_NONE
	column.add_child(_points)
	_map_button = Button.new()
	_map_button.name = "Mapa"
	_map_button.text = MAP_BUTTON_TEXT
	_map_button.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_map_button.focus_mode = Control.FOCUS_NONE
	_map_button.pressed.connect(func() -> void: map_requested.emit())
	column.add_child(_map_button)
	_templates = TemplateSelector.new()
	_templates.set_buttons_focusable(false)
	column.add_child(_templates)
	_button = Button.new()
	_button.name = "Reaparecer"
	_button.text = BUTTON_TEXT
	_button.custom_minimum_size = Vector2(200.0, 48.0)
	_button.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_button.disabled = true
	_button.focus_mode = Control.FOCUS_NONE
	_button.pressed.connect(_on_button_pressed)
	column.add_child(_button)


func _make_label(label_name: String, text: String, font_size: int) -> Label:
	var label := Label.new()
	label.name = label_name
	label.text = text
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.add_theme_font_size_override(&"font_size", font_size)
	label.add_theme_color_override(&"font_outline_color", Color(0.0, 0.0, 0.0, 0.9))
	label.add_theme_constant_override(&"outline_size", 6)
	return label
