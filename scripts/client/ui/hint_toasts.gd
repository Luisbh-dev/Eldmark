class_name HintToasts
extends Control
## Game hints (UI-42, docs/fortress.md section 6): short tips ([HintCatalog]) that appear at the bottom,
## above the controls help line, only once per player ([HintLog], in [code]user://[/code]) and only if
## hints are enabled in the settings ([constant ClientSettings.HINTS]).
## [br][br]
## [b]What triggers them.[/b] Client events: a war notice of a fallen captain ([signal
## NetClient.war_event]) or a TELEGRAPH ([signal NetClient.telegraph_received]) from someone who
## can damage the player ([method TelegraphMarks.threatens], the same rule that draws the marker) within
## its radius plus [constant TELEGRAPH_DISTANCE] m; and things that are checked every
## [constant POLL_SECONDS] ([method poll]): already being inside the world (the combat controls and those
## of the map and the scoreboard), being near the fort (the capture panel is visible) or within
## [constant GATE_DISTANCE] m of a gate that is closed for your realm. The death screen requests
## [constant HintCatalog.RESPAWN_MAP] with [method request] and withdraws it when it closes
## ([method withdraw]).
## [br][br]
## [b]Queue.[/b] One hint is shown at a time, for [constant SHOW_SECONDS] s with a fade, and
## [constant GAP_SECONDS] s pass between one and the next. The TELEGRAPH hint expires with its marker: if
## its turn does not come before then, it is discarded.
## [br][br]
## [b]Actually seen.[/b] The [HUD] mounts them above the death screen (without dimming) and below the map
## and the scoreboard, and gives it [member is_covered]: while the map or the scoreboard cover them none
## is shown, and the one that was visible returns to the head of the queue if it had not been read yet. A
## hint is only recorded as seen ([HintLog]) after [constant MIN_SEEN_SECONDS] s on screen uncovered, or
## when removed with [method dismiss] (its time runs out or hints are disabled); if hints are disabled
## with any queued, they are discarded without being recorded (phase 4 review, client). Measurements,
## texts and timings are provisional. Client only.

const SHOW_SECONDS: float = 9.0
const FADE_SECONDS: float = 1.0
const GAP_SECONDS: float = 2.0
const POLL_SECONDS: float = 0.5
## Seconds on screen, uncovered, after which a hint counts as seen.
const MIN_SEEN_SECONDS: float = 4.0
## Meters from a gate closed for your realm at which the gate hint appears.
const GATE_DISTANCE: float = 15.0
## Meters, beyond the marker's radius, within which a TELEGRAPH gives its hint.
const TELEGRAPH_DISTANCE: float = 20.0
## Extra seconds (after the impact) that a TELEGRAPH's hint waits in the queue.
const TELEGRAPH_GRACE_SECONDS: float = 0.5
const WIDTH: float = 640.0
const BOTTOM_OFFSET: float = 84.0
const FONT_SIZE: int = 18
const TEXT_TITLE: String = "Pista"

## [code]() -> bool[/code]: true while something covers the hints (the map, the scoreboard). Provided by the [HUD].
var is_covered: Callable = Callable()

var _client: NetClient = null
var _view: FortressView = null
var _capture_panel: CapturePanel = null
var _settings: ClientSettings = null
var _log: HintLog = null
var _queue: Array[StringName] = []
var _current: StringName = &""
var _left: float = 0.0
var _gap: float = 0.0
var _poll_left: float = 0.0
var _shown_total: int = 0
# Seconds the current one has been in view and whether it has already been recorded.
var _seen: float = 0.0
var _noted: bool = false
# Queued hint -> seconds it has left to appear before expiring (those that do not expire are absent).
var _deadlines: Dictionary[StringName, float] = {}

var _panel: PanelContainer = null
var _body: Label = null


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func _ready() -> void:
	_ensure_built()
	_panel.visible = false


func _process(delta: float) -> void:
	_poll_left -= delta
	if _poll_left <= 0.0:
		_poll_left = POLL_SECONDS
		poll()
	advance(delta)


func _exit_tree() -> void:
	_disconnect()


## Connects the hints with the client (its notices and where the player is), the fort view and the capture
## panel (to know whether the player is nearby), the settings ([param settings], by default the player's)
## and the log of seen hints ([param hint_log], by default the player's).
func bind(client: NetClient, view: FortressView, capture_panel: CapturePanel = null,
		settings: ClientSettings = null, hint_log: HintLog = null) -> void:
	_disconnect()
	_client = client
	_view = view
	_capture_panel = capture_panel
	_settings = settings if settings != null else ClientSettings.current()
	_log = hint_log if hint_log != null else HintLog.current()
	_ensure_built()
	if is_instance_valid(_client):
		_client.war_event.connect(_on_war_event)
		_client.telegraph_received.connect(_on_telegraph)
	_settings.changed.connect(_on_setting_changed)


## true if hints are enabled in the settings.
func is_enabled() -> bool:
	return _settings == null or bool(_settings.get_value(ClientSettings.HINTS))


## Requests hint [param id]. It is queued if the catalog knows it, hints are enabled, the player has not
## already seen it and it is not already queued or on screen. With [param lifetime] greater than 0, if it
## has not appeared within that time it is discarded without being recorded (what motivated it is gone).
## Returns true if it was queued.
func request(id: StringName, lifetime: float = 0.0) -> bool:
	if not HintCatalog.has_hint(id) or not is_enabled():
		return false
	if _log != null and _log.has_shown(id):
		return false
	if id == _current or _queue.has(id):
		return false
	_queue.append(id)
	if lifetime > 0.0:
		_deadlines[id] = lifetime
	if _current == &"" and _gap <= 0.0 and not _covered():
		_show_next()
	return true


## Withdraws hint [param id] because it no longer applies (the respawn one, when the death screen
## closes): it leaves the queue and, if it is being shown and has not yet been read, it is removed without
## being recorded. It can be requested again.
func withdraw(id: StringName) -> void:
	_queue.erase(id)
	_deadlines.erase(id)
	if id != _current:
		return
	if _noted:
		dismiss()
		return
	_hide_current()
	_gap = GAP_SECONDS


## Advances [param delta] seconds: the time on screen, the fade, the pause between hints and the expiry of
## those waiting.
func advance(delta: float) -> void:
	_expire(delta)
	if _current == &"":
		if _gap > 0.0:
			_gap -= delta
		if _gap <= 0.0 and not _queue.is_empty() and not _covered():
			_show_next()
		return
	if not is_enabled():
		dismiss()
		return
	if _covered():
		if _noted:
			dismiss()
		else:
			# Covered before being read: it returns to the front of the queue and appears as soon as it is uncovered.
			_queue.push_front(_current)
			_hide_current()
		return
	_seen += delta
	if not _noted and _seen >= MIN_SEEN_SECONDS:
		_note_current()
	_left -= delta
	if _left <= 0.0:
		dismiss()
	else:
		_panel.modulate.a = clampf(_left / FADE_SECONDS, 0.0, 1.0)


## Removes the hint from the screen and counts it as seen (the next one appears after the pause).
func dismiss() -> void:
	if _current == &"":
		return
	if not _noted:
		_note_current()
	_hide_current()
	_gap = GAP_SECONDS


## Checks what triggers hints without an event: being in the world, near the fort or near a closed gate.
func poll() -> void:
	if not is_enabled() or not is_instance_valid(_client):
		return
	var character: PlayerCharacter = _client.get_character()
	if character == null or not is_instance_valid(character):
		return
	request(HintCatalog.COMBAT)
	request(HintCatalog.CONTROLS)
	if is_instance_valid(_capture_panel) and _capture_panel.is_shown():
		request(HintCatalog.FORT_NEAR)
	if _near_closed_gate(character):
		request(HintCatalog.GATE_CLOSED)


# --- Accessors (for the tests) ----------------------------------------------------------------

func get_current_id() -> StringName:
	return _current


func get_current_text() -> String:
	return _body.text if _body != null and _current != &"" else ""


func get_queued_ids() -> Array[StringName]:
	return _queue.duplicate()


func get_seconds_left() -> float:
	return _left


## How many hints have appeared on screen since it was created.
func get_shown_total() -> int:
	return _shown_total


func is_showing() -> bool:
	return _panel != null and _panel.visible


## The hint's panel.
func get_panel() -> PanelContainer:
	_ensure_built()
	return _panel


# --- Internal ---------------------------------------------------------------------------------

func _disconnect() -> void:
	if is_instance_valid(_client):
		if _client.war_event.is_connected(_on_war_event):
			_client.war_event.disconnect(_on_war_event)
		if _client.telegraph_received.is_connected(_on_telegraph):
			_client.telegraph_received.disconnect(_on_telegraph)
	if _settings != null and _settings.changed.is_connected(_on_setting_changed):
		_settings.changed.disconnect(_on_setting_changed)


func _on_war_event(event: NetMessages.EntityEvent) -> void:
	if event.war_event == WarEvents.CAPTAIN_DOWN:
		request(HintCatalog.CAPTAIN_DOWN)


# A TELEGRAPH gives its hint if it comes from someone who can damage the player and lands nearby; it
# expires with the marker.
func _on_telegraph(event: NetMessages.EntityEvent) -> void:
	if event == null or not is_instance_valid(_client) or not TelegraphMarks.threatens(_client, event.net_id):
		return
	var character: PlayerCharacter = _client.get_character()
	if character == null or not is_instance_valid(character):
		return
	var here: Vector3 = character.global_position if character.is_inside_tree() else character.position
	var distance: float = Vector2(here.x - event.position.x, here.z - event.position.z).length()
	if distance > event.get_radius() + TELEGRAPH_DISTANCE:
		return
	var lifetime: float = float(maxi(event.impact_in_ticks, 0)) / float(Engine.physics_ticks_per_second) \
			+ TELEGRAPH_GRACE_SECONDS
	request(HintCatalog.TELEGRAPH, lifetime)


# When hints are disabled, whatever was waiting in the queue is discarded (and not recorded as seen).
func _on_setting_changed(id: StringName, value: Variant) -> void:
	if id == ClientSettings.HINTS and not bool(value):
		_queue.clear()
		_deadlines.clear()
		dismiss()


func _covered() -> bool:
	return is_covered.is_valid() and bool(is_covered.call())


# Subtracts [param delta] from the queued hints that expire and discards (without recording them) those
# that will no longer appear.
func _expire(delta: float) -> void:
	for id: StringName in _deadlines.keys():
		_deadlines[id] -= delta
		if _deadlines[id] <= 0.0:
			_deadlines.erase(id)
			_queue.erase(id)


func _note_current() -> void:
	_noted = true
	if _log != null:
		_log.mark_shown(_current)


func _hide_current() -> void:
	_current = &""
	_left = 0.0
	_seen = 0.0
	_noted = false
	if _panel != null:
		_panel.visible = false


# true if there is a gate fully closed for the player's realm within GATE_DISTANCE m.
func _near_closed_gate(character: PlayerCharacter) -> bool:
	if not is_instance_valid(_view) or _client.get_config() == null:
		return false
	var realm_bit: int = PlayerCharacter.realm_layer(_client.get_config().realm)
	if realm_bit == 0:
		return false
	var here: Vector3 = character.global_position if character.is_inside_tree() else character.position
	for net_id: int in _view.get_fortress_ids():
		var state: FortressState = _view.get_displayed_state(net_id)
		var gate: Vector3 = _view.get_gate_position(net_id)
		if state == null or gate == Vector3.INF:
			continue
		if (FortGate.layers_for(state.owner, state.is_gate_broken()) & realm_bit) == 0:
			continue
		if Vector2(here.x - gate.x, here.z - gate.z).length() <= GATE_DISTANCE:
			return true
	return false


func _show_next() -> void:
	while not _queue.is_empty():
		var id: StringName = _queue.pop_front()
		_deadlines.erase(id)
		if _log != null and _log.has_shown(id):
			continue
		_current = id
		_left = SHOW_SECONDS
		_seen = 0.0
		_noted = false
		_shown_total += 1
		_ensure_built()
		_body.text = HintCatalog.text_of(id)
		_panel.modulate.a = 1.0
		_panel.visible = true
		return


func _ensure_built() -> void:
	if _panel != null:
		return
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_panel = PanelContainer.new()
	_panel.name = "Pista"
	_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var style := StyleBoxFlat.new()
	style.bg_color = UIPalette.PANEL_BG
	style.border_color = UIPalette.ACCENT
	style.set_border_width_all(1)
	style.border_width_left = 4
	style.set_corner_radius_all(4)
	style.set_content_margin_all(10.0)
	_panel.add_theme_stylebox_override(&"panel", style)
	add_child(_panel)
	_panel.anchor_left = 0.5
	_panel.anchor_right = 0.5
	_panel.anchor_top = 1.0
	_panel.anchor_bottom = 1.0
	_panel.offset_left = -WIDTH * 0.5
	_panel.offset_right = WIDTH * 0.5
	_panel.offset_top = -BOTTOM_OFFSET
	_panel.offset_bottom = -BOTTOM_OFFSET
	_panel.grow_vertical = Control.GROW_DIRECTION_BEGIN
	var column := VBoxContainer.new()
	column.mouse_filter = Control.MOUSE_FILTER_IGNORE
	column.add_theme_constant_override(&"separation", 2)
	_panel.add_child(column)
	var title := Label.new()
	title.text = TEXT_TITLE
	title.mouse_filter = Control.MOUSE_FILTER_IGNORE
	title.add_theme_font_size_override(&"font_size", FONT_SIZE - 3)
	title.add_theme_color_override(&"font_color", UIPalette.ACCENT)
	column.add_child(title)
	_body = Label.new()
	_body.name = "Texto"
	_body.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_body.custom_minimum_size = Vector2(WIDTH - 24.0, 0.0)
	_body.add_theme_font_size_override(&"font_size", FONT_SIZE)
	_body.add_theme_color_override(&"font_color", UIPalette.TEXT)
	column.add_child(_body)
	_panel.visible = false
