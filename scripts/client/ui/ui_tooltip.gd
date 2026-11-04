class_name UITooltip
extends PanelContainer
## Rich tooltip (UI-09): title (in the rarity or faction color), subtitle and body with BBCode, which
## appears after a delay and fits within the screen edges.
## [br][br]
## [b]Usage.[/b] One tooltip shared per viewport ([method get_shared]) is fed by the slots and the
## controls that request it: [method request] starts the wait ([member delay] seconds) and
## [method cancel] aborts it and hides it; [method bind_source] does both on its own when the mouse enters
## and leaves a control (or it gains and loses focus, for keyboard and gamepad). While the wait or the
## display follow a mouse, the tooltip accompanies it.
## [br][br]
## [b]Placement.[/b] [method fit_position] is the rule (pure, so it can be tested): by default to the right
## of and below the cursor; if that would go out of [param bounds] on the right it moves to the left, and
## on the bottom, above; then it is fitted inside leaving [constant MARGIN] px of edge.
## [br][br]
## [b]Focus.[/b] The focus tooltip exists for keyboard and gamepad: it only opens if the last thing the
## player did was press a key or a gamepad button ([method note_input]) and the focus was not given by
## code ([method grab_focus_silently]). With the mouse, or when opening a window that focuses its first
## control, focus shows nothing: previously a tooltip covered the inventory and the character window when
## opening them (UI-49).
## [br][br]
## Time is kept by [method advance] ([method _process] calls it with each frame's delta); the tests call it
## with exact steps. It never captures the mouse.
## [br][br]
## Client only.

## Seconds the mouse must stay still over a control before the tooltip appears.
const DEFAULT_DELAY: float = 0.45
## Separation (px) between the cursor and the tooltip, and minimum edge to the screen.
const CURSOR_OFFSET: Vector2 = Vector2(16.0, 22.0)
const MARGIN: float = 8.0
## Maximum width of the text (px).
const MAX_TEXT_WIDTH: float = 320.0
const MIN_TEXT_WIDTH: float = 140.0
## Layer where the shared tooltip lives (above the HUD and the windows).
const LAYER: int = 90
## Metadata of a control bound with [method bind_source]: its provider and whether it is already connected.
const PROVIDER_META: StringName = &"ui_tooltip_provider"
const BOUND_META: StringName = &"ui_tooltip_bound"

## Seconds to wait before showing it.
var delay: float = DEFAULT_DELAY
## If not null, the bounds it is fitted within (tests); if it is, the viewport's visible rectangle.
var bounds_override: Variant = null

static var _shared: UITooltip = null
## [method grab_focus_silently] calls in progress: while there are any, focus does not open tooltips.
static var _silent_focus: int = 0

var _title: Label = null
var _subtitle: Label = null
var _body: RichTextLabel = null
var _pending: bool = false
var _showing: bool = false
var _elapsed: float = 0.0
var _anchor: Vector2 = Vector2.ZERO
var _follow_mouse: bool = false
# true if the player's last input was from keyboard or gamepad (focus only shows tooltips then).
var _navigation_input: bool = false


## The shared tooltip of the tree of [param tree], created the first time (on its own layer).
static func get_shared(tree: SceneTree) -> UITooltip:
	if is_instance_valid(_shared) and _shared.is_inside_tree():
		return _shared
	var layer: CanvasLayer = CanvasLayer.new()
	layer.name = "TooltipLayer"
	layer.layer = LAYER
	var tooltip: UITooltip = UITooltip.new()
	layer.add_child(tooltip)
	tree.root.add_child(layer)
	_shared = tooltip
	return tooltip


## Gives focus to [param control] without it opening its tooltip: the focus is set by code (a window that
## opens), not by the player when navigating.
static func grab_focus_silently(control: Control) -> void:
	_silent_focus += 1
	control.grab_focus()
	_silent_focus -= 1


## Position (top-left corner) of a tooltip of size [param tooltip_size] for a cursor at [param anchor],
## within [param bounds]. See the rule in the class documentation.
static func fit_position(anchor: Vector2, tooltip_size: Vector2, bounds: Rect2,
		offset: Vector2 = CURSOR_OFFSET) -> Vector2:
	var corner: Vector2 = anchor + offset
	if corner.x + tooltip_size.x > bounds.end.x - MARGIN:
		corner.x = anchor.x - offset.x - tooltip_size.x
	if corner.y + tooltip_size.y > bounds.end.y - MARGIN:
		corner.y = anchor.y - offset.y - tooltip_size.y
	var min_corner: Vector2 = bounds.position + Vector2(MARGIN, MARGIN)
	var max_corner: Vector2 = bounds.end - Vector2(MARGIN, MARGIN) - tooltip_size
	# If the tooltip is larger than the screen, the top-left corner wins.
	corner.x = maxf(min_corner.x, minf(corner.x, max_corner.x))
	corner.y = maxf(min_corner.y, minf(corner.y, max_corner.y))
	return corner


func _init() -> void:
	visible = false
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	theme_type_variation = &"WindowPanel"
	var column: VBoxContainer = VBoxContainer.new()
	column.mouse_filter = Control.MOUSE_FILTER_IGNORE
	column.add_theme_constant_override(&"separation", 3)
	add_child(column)
	_title = Label.new()
	_title.theme_type_variation = &"HeaderLabel"
	_title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_title.mouse_filter = Control.MOUSE_FILTER_IGNORE
	column.add_child(_title)
	_subtitle = Label.new()
	_subtitle.theme_type_variation = &"DimLabel"
	_subtitle.mouse_filter = Control.MOUSE_FILTER_IGNORE
	column.add_child(_subtitle)
	_body = RichTextLabel.new()
	_body.bbcode_enabled = true
	_body.fit_content = false
	_body.scroll_active = false
	_body.mouse_filter = Control.MOUSE_FILTER_IGNORE
	column.add_child(_body)


func _exit_tree() -> void:
	if _shared == self:
		_shared = null


func _input(event: InputEvent) -> void:
	note_input(event)


func _process(delta: float) -> void:
	if _follow_mouse and (_pending or _showing) and is_inside_tree():
		_anchor = get_viewport().get_mouse_position()
	advance(delta)


## Records which device the player is playing with: the mouse turns off the focus tooltip; a key or a
## button (or a gamepad axis past half) turns it on. Called by [method _input] with each event.
func note_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion or event is InputEventMouseButton:
		_navigation_input = false
	elif event is InputEventKey or event is InputEventJoypadButton:
		_navigation_input = true
	elif event is InputEventJoypadMotion and absf((event as InputEventJoypadMotion).axis_value) > 0.5:
		_navigation_input = true


## true if a focus change would now open a tooltip: the last input was keyboard or gamepad and the focus
## is not given by code.
func allows_focus_tooltip() -> bool:
	return _navigation_input and _silent_focus == 0


## Requests a tooltip with [param title], [param body] (BBCode) and [param subtitle], with the title in
## color [param accent], next to [param anchor_position] (screen coordinates; with [param follow_mouse]
## the tooltip follows the mouse). Starts the [member delay] wait; if it was already being shown, it
## changes the content instantly.
func request(title: String, body: String = "", accent: Color = UIPalette.TITLE,
		anchor_position: Vector2 = Vector2.ZERO, subtitle: String = "",
		follow_mouse: bool = false) -> void:
	_title.text = title
	_title.visible = not title.is_empty()
	_title.add_theme_color_override(&"font_color", accent)
	_subtitle.text = subtitle
	_subtitle.visible = not subtitle.is_empty()
	_body.text = body
	_body.visible = not body.is_empty()
	var width: float = _text_width(body, title)
	_body.custom_minimum_size.x = width
	_title.custom_minimum_size.x = width
	_anchor = anchor_position
	_follow_mouse = follow_mouse
	if _showing:
		_place()
		return
	_pending = true
	_elapsed = 0.0


## Aborts the request and hides the tooltip.
func cancel() -> void:
	_pending = false
	_showing = false
	_follow_mouse = false
	_elapsed = 0.0
	visible = false


## Advances the wait by [param delta] seconds and, if it meets the delay, shows it.
func advance(delta: float) -> void:
	if _pending:
		_elapsed += delta
		if _elapsed >= delay:
			_pending = false
			_showing = true
			visible = true
			_place()
	elif _showing:
		_place()


## Moves the tooltip to [param anchor_position] (screen).
func move_to(anchor_position: Vector2) -> void:
	_anchor = anchor_position
	if _showing:
		_place()


## true while a wait is in progress.
func is_pending() -> bool:
	return _pending


## true while it is visible.
func is_showing() -> bool:
	return _showing


## Seconds the current request has been waiting.
func get_elapsed() -> float:
	return _elapsed


func get_title_label() -> Label:
	return _title


func get_subtitle_label() -> Label:
	return _subtitle


func get_body_label() -> RichTextLabel:
	return _body


## Binds [param control] to this tooltip: when the mouse (or focus) enters, it asks [param provider] for
## the content (a [Callable] that returns a dictionary with [code]title[/code] and, optionally,
## [code]subtitle[/code], [code]body[/code] and [code]accent[/code]) and when it leaves it cancels. A
## provider that returns an empty dictionary shows nothing.
func bind_source(control: Control, provider: Callable) -> void:
	control.set_meta(PROVIDER_META, provider)
	if control.has_meta(BOUND_META):
		return
	control.set_meta(BOUND_META, true)
	control.mouse_entered.connect(_on_source_entered.bind(control, true))
	control.mouse_exited.connect(_on_source_exited.bind(control))
	control.focus_entered.connect(_on_source_entered.bind(control, false))
	control.focus_exited.connect(_on_source_exited.bind(control))
	control.tree_exiting.connect(_on_source_exited.bind(control))


func _on_source_entered(control: Control, by_mouse: bool) -> void:
	if not by_mouse and not allows_focus_tooltip():
		return
	var provider: Callable = control.get_meta(PROVIDER_META, Callable()) as Callable
	if not provider.is_valid():
		return
	var content: Dictionary = provider.call()
	if content.is_empty():
		return
	var anchor: Vector2 = control.get_global_mouse_position() if by_mouse \
			else control.get_global_rect().get_center()
	request(String(content.get("title", "")), String(content.get("body", "")),
			content.get("accent", UIPalette.TITLE), anchor, String(content.get("subtitle", "")),
			by_mouse)


func _on_source_exited(_control: Control) -> void:
	cancel()


# Width of the text: the body's natural one, between a minimum and the maximum, so that a long body wraps
# over several lines and a short one does not leave a huge gap.
func _text_width(body: String, title: String) -> float:
	var font: Font = get_theme_default_font()
	var plain: String = _strip_bbcode(body)
	var wanted: float = maxf(font.get_string_size(plain, HORIZONTAL_ALIGNMENT_LEFT, -1.0,
			UIThemeBuilder.FONT_SIZE).x, font.get_string_size(title, HORIZONTAL_ALIGNMENT_LEFT, -1.0,
			UIThemeBuilder.HEADER_FONT_SIZE).x)
	return clampf(wanted, MIN_TEXT_WIDTH, MAX_TEXT_WIDTH)


static func _strip_bbcode(text: String) -> String:
	var regex: RegEx = RegEx.new()
	regex.compile("\\[/?[^\\]]*\\]")
	return regex.sub(text, "", true)


func _place() -> void:
	if bounds_override == null and not is_inside_tree():
		return
	# The body and the title wrap the text according to their current width: they are given the width before
	# measuring (otherwise, with width 0 each word would take a line and the tooltip would come out very
	# tall) and the body's height is requested from its content instead of relying on deferred layout.
	_body.size = Vector2(_body.custom_minimum_size.x, 0.0)
	_title.size = Vector2(_title.custom_minimum_size.x, 0.0)
	if _body.visible:
		_body.custom_minimum_size.y = float(_body.get_content_height())
	reset_size()
	size = get_combined_minimum_size()
	var rect: Rect2 = get_viewport_rect() if bounds_override == null else (bounds_override as Rect2)
	position = fit_position(_anchor, size, rect)
