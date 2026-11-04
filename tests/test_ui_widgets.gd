extends TestCase
## Tests for the UI components with a custom look (UI-09): the tooltip with a delay and edge fitting
## ([UITooltip]), the icon slot with a cooldown sweep ([UIIconSlot]), the window ([UIWindow]), the
## confirmation dialog ([UIConfirmDialog]) and the gallery that shows all of them.

const GALLERY_SCENE_PATH: String = "res://scenes/tests/ui_gallery.tscn"
const CAMERA_RIG_SCENE_PATH: String = "res://scenes/client/camera_rig.tscn"
const BOUNDS: Rect2 = Rect2(0.0, 0.0, 1000.0, 800.0)

var _nodes: Array[Node] = []


func before_each() -> void:
	InputBindings.ensure_defaults()
	UISounds.reset()


func after_each() -> void:
	for node: Node in _nodes:
		if is_instance_valid(node):
			if node.get_parent() != null:
				node.get_parent().remove_child(node)
			node.free()
	_nodes.clear()
	UISounds.reset()


func _add(node: Node) -> Node:
	tree.root.add_child(node)
	_nodes.append(node)
	return node


func _click(position: Vector2, pressed: bool) -> InputEventMouseButton:
	var event: InputEventMouseButton = InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_LEFT
	event.position = position
	event.pressed = pressed
	return event


func _press_escape() -> void:
	var event: InputEventKey = InputEventKey.new()
	event.keycode = KEY_ESCAPE
	event.physical_keycode = KEY_ESCAPE
	event.pressed = true
	tree.root.push_input(event)


# Area of a polygon (shoelace formula).
func _area(points: PackedVector2Array) -> float:
	var total: float = 0.0
	for index: int in points.size():
		var current: Vector2 = points[index]
		var next: Vector2 = points[(index + 1) % points.size()]
		total += current.x * next.y - next.x * current.y
	return absf(total) * 0.5


# --- Tooltip ----------------------------------------------------------------------------------

func test_the_tooltip_goes_right_and_below_the_cursor_when_there_is_room() -> void:
	var anchor: Vector2 = Vector2(100.0, 100.0)
	var tooltip_size: Vector2 = Vector2(200.0, 80.0)
	assert_vec_near(UITooltip.fit_position(anchor, tooltip_size, BOUNDS),
			anchor + UITooltip.CURSOR_OFFSET, 0.001)


func test_the_tooltip_flips_and_clamps_at_the_screen_edges() -> void:
	var tooltip_size: Vector2 = Vector2(200.0, 80.0)
	var offset: Vector2 = UITooltip.CURSOR_OFFSET
	# Against the right edge: it flips to the left of the cursor.
	var right: Vector2 = UITooltip.fit_position(Vector2(900.0, 100.0), tooltip_size, BOUNDS)
	assert_near(right.x, 900.0 - offset.x - tooltip_size.x, 0.001, "to the left")
	assert_near(right.y, 100.0 + offset.y, 0.001)
	# Against the bottom edge: it flips above.
	var bottom: Vector2 = UITooltip.fit_position(Vector2(100.0, 760.0), tooltip_size, BOUNDS)
	assert_near(bottom.y, 760.0 - offset.y - tooltip_size.y, 0.001, "above")
	assert_near(bottom.x, 100.0 + offset.x, 0.001)
	# In the corner, both at once.
	var corner: Vector2 = UITooltip.fit_position(Vector2(990.0, 790.0), tooltip_size, BOUNDS)
	assert_near(corner.x, 990.0 - offset.x - tooltip_size.x, 0.001)
	assert_near(corner.y, 790.0 - offset.y - tooltip_size.y, 0.001)
	# If flipping would push it off the other side, it is clamped to the margin.
	var wide: Vector2 = UITooltip.fit_position(Vector2(150.0, 100.0), Vector2(400.0, 80.0),
			Rect2(0.0, 0.0, 300.0, 800.0))
	assert_near(wide.x, UITooltip.MARGIN, 0.001, "clamped to the left edge")
	var top: Vector2 = UITooltip.fit_position(Vector2(100.0, 5.0), tooltip_size,
			Rect2(0.0, 0.0, 1000.0, 90.0))
	assert_near(top.y, UITooltip.MARGIN, 0.001, "and to the top")
	# Larger than the screen: the top-left corner wins.
	var huge: Vector2 = UITooltip.fit_position(Vector2(50.0, 50.0), Vector2(2000.0, 2000.0), BOUNDS)
	assert_vec_near(huge, Vector2(UITooltip.MARGIN, UITooltip.MARGIN), 0.001)
	# With bounds that do not start at the origin.
	var offset_bounds: Rect2 = Rect2(100.0, 50.0, 400.0, 300.0)
	var inside: Vector2 = UITooltip.fit_position(Vector2(110.0, 60.0), tooltip_size, offset_bounds)
	assert_true(inside.x >= 100.0 + UITooltip.MARGIN and inside.y >= 50.0 + UITooltip.MARGIN)
	# It always stays inside, wherever the cursor is.
	for x: int in range(0, 1001, 125):
		for y: int in range(0, 801, 100):
			var placed: Vector2 = UITooltip.fit_position(Vector2(x, y), tooltip_size, BOUNDS)
			assert_true(Rect2(placed, tooltip_size).intersection(BOUNDS).size.is_equal_approx(tooltip_size),
					"cursor (%d, %d): stays inside" % [x, y])


func test_the_tooltip_waits_for_its_delay() -> void:
	var tooltip: UITooltip = _add(UITooltip.new()) as UITooltip
	tooltip.bounds_override = BOUNDS
	assert_false(tooltip.visible)
	tooltip.request("Espada de hierro", "Un arma sencilla.", UIPalette.TITLE, Vector2(100.0, 100.0))
	assert_true(tooltip.is_pending())
	assert_false(tooltip.is_showing())
	tooltip.advance(0.2)
	assert_false(tooltip.visible, "not yet")
	tooltip.advance(UITooltip.DEFAULT_DELAY - 0.2 - 0.01)
	assert_false(tooltip.visible, "just short of the delay, still no")
	tooltip.advance(0.02)
	assert_true(tooltip.visible, "after the delay it appears")
	assert_true(tooltip.is_showing())
	assert_false(tooltip.is_pending())
	tooltip.cancel()
	assert_false(tooltip.visible)
	assert_false(tooltip.is_showing())
	assert_eq(tooltip.get_elapsed(), 0.0)
	# Cancelling before the delay never shows it.
	tooltip.request("Escudo", "", UIPalette.TITLE, Vector2(100.0, 100.0))
	tooltip.advance(0.3)
	tooltip.cancel()
	tooltip.advance(1.0)
	assert_false(tooltip.visible, "cancelled in time")
	# The delay can be changed.
	tooltip.delay = 0.0
	tooltip.request("Ya", "", UIPalette.TITLE, Vector2(100.0, 100.0))
	tooltip.advance(0.0)
	assert_true(tooltip.visible, "no delay, shown right away")


func test_the_tooltip_shows_rich_content_and_changes_it_while_visible() -> void:
	var tooltip: UITooltip = _add(UITooltip.new()) as UITooltip
	tooltip.bounds_override = BOUNDS
	tooltip.delay = 0.1
	tooltip.request("Hacha rara", "Daño [b]120[/b] y [color=#E9C341]oro[/color]", UIPalette.rarity_color(2),
			Vector2(100.0, 100.0), "Arma · dos manos")
	tooltip.advance(0.2)
	assert_eq(tooltip.get_title_label().text, "Hacha rara")
	assert_eq(tooltip.get_title_label().get_theme_color(&"font_color"), UIPalette.rarity_color(2),
			"the title uses the rarity color")
	assert_true(tooltip.get_subtitle_label().visible)
	assert_eq(tooltip.get_subtitle_label().text, "Arma · dos manos")
	assert_eq(tooltip.get_body_label().get_parsed_text(), "Daño 120 y oro", "BBCode is interpreted")
	# Switching items while the tooltip is visible does not wait again.
	tooltip.request("Escudo", "", UIPalette.TITLE, Vector2(300.0, 200.0))
	assert_true(tooltip.is_showing(), "still visible")
	assert_false(tooltip.is_pending(), "no new wait")
	assert_eq(tooltip.get_title_label().text, "Escudo")
	assert_false(tooltip.get_body_label().visible, "without a body there is no gap")
	assert_false(tooltip.get_subtitle_label().visible)
	assert_eq(tooltip.mouse_filter, Control.MOUSE_FILTER_IGNORE, "never captures the mouse")


func test_the_tooltip_stays_inside_the_screen_when_shown() -> void:
	var tooltip: UITooltip = _add(UITooltip.new()) as UITooltip
	tooltip.bounds_override = BOUNDS
	tooltip.delay = 0.0
	var long_text: String = "Un texto muy largo que ocupa varias líneas. ".repeat(6)
	for anchor: Vector2 in [Vector2(5.0, 5.0), Vector2(995.0, 5.0), Vector2(995.0, 795.0),
			Vector2(5.0, 795.0), Vector2(500.0, 400.0)]:
		tooltip.request("Título", long_text, UIPalette.TITLE, anchor, "Subtítulo")
		tooltip.advance(0.0)
		var rect: Rect2 = Rect2(tooltip.position, tooltip.size)
		assert_true(BOUNDS.encloses(rect), "anchor %s: the %s tooltip stays inside" % [anchor, rect])
		assert_true(tooltip.size.x <= UITooltip.MAX_TEXT_WIDTH + 60.0, "the width is capped")
		tooltip.cancel()
	# Moving the mouse repositions it.
	tooltip.request("Título", "Cuerpo", UIPalette.TITLE, Vector2(100.0, 100.0))
	tooltip.advance(0.0)
	var before: Vector2 = tooltip.position
	tooltip.move_to(Vector2(400.0, 300.0))
	assert_true(tooltip.position.x > before.x and tooltip.position.y > before.y, "follows the cursor")


func test_a_bound_control_shows_and_hides_the_tooltip() -> void:
	var tooltip: UITooltip = _add(UITooltip.new()) as UITooltip
	tooltip.bounds_override = BOUNDS
	var button: Button = _add(Button.new()) as Button
	var calls: Array[int] = [0]
	tooltip.bind_source(button, func() -> Dictionary:
		calls[0] += 1
		return {"title": "Botón", "body": "Hace cosas", "subtitle": "Prueba",
				"accent": UIPalette.faction_color(&"solmarch")})
	tooltip.bind_source(button, func() -> Dictionary:
		calls[0] += 100
		return {"title": "Botón", "body": "Hace cosas", "subtitle": "Prueba",
				"accent": UIPalette.faction_color(&"solmarch")})
	button.mouse_entered.emit()
	assert_eq(calls[0], 100, "the content is requested on enter, from the latest provider")
	assert_true(tooltip.is_pending())
	tooltip.advance(UITooltip.DEFAULT_DELAY + 0.01)
	assert_true(tooltip.visible)
	assert_eq(tooltip.get_title_label().text, "Botón")
	assert_eq(tooltip.get_title_label().get_theme_color(&"font_color"), RealmCatalog.SOLMARCH_COLOR)
	button.mouse_exited.emit()
	assert_false(tooltip.visible, "it hides on exit")
	# Focus only shows it with the keyboard or gamepad (UI-49).
	button.focus_entered.emit()
	assert_false(tooltip.is_pending(), "with nothing pressed, focus does not open tooltips")
	var key: InputEventKey = InputEventKey.new()
	key.pressed = true
	key.keycode = KEY_RIGHT
	tooltip.note_input(key)
	button.focus_entered.emit()
	tooltip.advance(UITooltip.DEFAULT_DELAY + 0.01)
	assert_true(tooltip.visible, "focus (keyboard or gamepad) shows it too")
	button.focus_exited.emit()
	assert_false(tooltip.visible)
	tooltip.note_input(InputEventMouseMotion.new())
	button.focus_entered.emit()
	assert_false(tooltip.is_pending(), "after moving the mouse, focus stops showing anything again")
	tooltip.note_input(key)
	# A provider with no content shows nothing.
	var silent: Button = _add(Button.new()) as Button
	tooltip.bind_source(silent, func() -> Dictionary: return {})
	silent.mouse_entered.emit()
	assert_false(tooltip.is_pending())
	# Leaving the tree while it is shown hides it.
	button.mouse_entered.emit()
	tooltip.advance(UITooltip.DEFAULT_DELAY + 0.01)
	assert_true(tooltip.visible)
	button.tree_exiting.emit()
	assert_false(tooltip.visible)


func test_the_shared_tooltip_lives_in_its_own_layer() -> void:
	var first: UITooltip = UITooltip.get_shared(tree)
	var layer: Node = first.get_parent()
	_nodes.append(layer)
	assert_true(layer is CanvasLayer)
	assert_eq((layer as CanvasLayer).layer, UITooltip.LAYER, "above the HUD")
	assert_eq(UITooltip.get_shared(tree), first, "just one")
	assert_false(first.visible)
	layer.get_parent().remove_child(layer)
	layer.free()
	_nodes.clear()
	var second: UITooltip = UITooltip.get_shared(tree)
	assert_not_null(second, "if it is lost, another one is created")
	_nodes.append(second.get_parent())


# --- Icon slot --------------------------------------------------------------------------------

func test_the_sweep_polygon_covers_the_swept_part_of_the_slot() -> void:
	var square: Rect2 = Rect2(Vector2(2.0, 2.0), Vector2(48.0, 48.0))
	var total: float = square.get_area()
	assert_eq(UIIconSlot.sweep_polygon(square, 0.0).size(), 0, "no cooldown, nothing")
	assert_near(_area(UIIconSlot.sweep_polygon(square, 1.0)), total, 0.01, "just started: all of it")
	assert_near(_area(UIIconSlot.sweep_polygon(square, 0.5)), total * 0.5, 0.01, "half")
	# In a square, turns that are multiples of an eighth split the area evenly.
	for eighths: int in range(1, 9):
		var fraction: float = float(eighths) / 8.0
		assert_near(_area(UIIconSlot.sweep_polygon(square, fraction)), total * fraction, 0.05,
				"%d/8 of a turn" % eighths)
	var wide: Rect2 = Rect2(0.0, 0.0, 80.0, 30.0)
	assert_near(_area(UIIconSlot.sweep_polygon(wide, 0.5)), wide.get_area() * 0.5, 0.01,
			"half is half in any rectangle")
	# It starts at 12 o'clock and advances clockwise.
	var quarter: PackedVector2Array = UIIconSlot.sweep_polygon(square, 0.25)
	assert_vec_near(quarter[0], square.get_center(), 0.001, "fan from the center")
	assert_vec_near(quarter[1], Vector2(square.get_center().x, square.position.y), 0.001,
			"starts at the top")
	assert_vec_near(quarter[quarter.size() - 1], Vector2(square.end.x, square.get_center().y), 0.001,
			"and a quarter turn reaches the right")
	# It never leaves the rectangle.
	for rect: Rect2 in [square, wide, Rect2(0.0, 0.0, 30.0, 80.0)]:
		for step: int in 21:
			for point: Vector2 in UIIconSlot.sweep_polygon(rect, float(step) / 20.0):
				assert_true(rect.grow(0.001).has_point(point), "%s inside %s" % [point, rect])
	assert_eq(UIIconSlot.sweep_polygon(Rect2(), 0.5).size(), 0, "empty rectangle")


func test_cooldown_text() -> void:
	assert_eq(UIIconSlot.cooldown_text(0.0), "")
	assert_eq(UIIconSlot.cooldown_text(-1.0), "")
	assert_eq(UIIconSlot.cooldown_text(0.5), "0,5")
	assert_eq(UIIconSlot.cooldown_text(0.94), "0,9")
	assert_eq(UIIconSlot.cooldown_text(1.0), "1")
	assert_eq(UIIconSlot.cooldown_text(1.2), "2")
	assert_eq(UIIconSlot.cooldown_text(9.01), "10")
	assert_eq(UIIconSlot.cooldown_text(45.0), "45")


func test_slot_cooldown_runs_and_flashes_when_ready() -> void:
	var slot: UIIconSlot = _add(UIIconSlot.new()) as UIIconSlot
	var finished: Array[int] = [0]
	slot.cooldown_finished.connect(func() -> void: finished[0] += 1)
	assert_false(slot.is_on_cooldown())
	assert_eq(slot.get_cooldown_fraction(), 0.0)
	slot.start_cooldown(2.0)
	assert_true(slot.is_on_cooldown())
	assert_near(slot.get_cooldown_fraction(), 1.0, 0.0001)
	slot.advance(0.5)
	assert_near(slot.get_cooldown_remaining(), 1.5, 0.0001)
	assert_near(slot.get_cooldown_fraction(), 0.75, 0.0001)
	assert_eq(finished[0], 0)
	slot.advance(1.5)
	assert_false(slot.is_on_cooldown(), "it is over")
	assert_eq(finished[0], 1, "notifies once")
	assert_near(slot.get_flash_alpha(), 1.0, 0.0001, "and flashes")
	slot.advance(UIIconSlot.FLASH_SECONDS * 0.5)
	assert_near(slot.get_flash_alpha(), 0.5, 0.0001, "the flash fades out")
	slot.advance(1.0)
	assert_eq(slot.get_flash_alpha(), 0.0)
	assert_eq(finished[0], 1)
	slot.advance(1.0)
	assert_eq(finished[0], 1, "with no cooldown it does not notify again")


func test_the_server_can_correct_a_predicted_cooldown() -> void:
	var slot: UIIconSlot = _add(UIIconSlot.new()) as UIIconSlot
	var finished: Array[int] = [0]
	slot.cooldown_finished.connect(func() -> void: finished[0] += 1)
	slot.start_cooldown(2.0)
	slot.advance(0.5)
	# The server says more is needed: the slot corrects itself.
	slot.set_cooldown(3.0, 4.0)
	assert_near(slot.get_cooldown_remaining(), 3.0, 0.0001)
	assert_near(slot.get_cooldown_fraction(), 0.75, 0.0001)
	# The action was rejected and never actually spent: it is removed with no flash or notification.
	slot.set_cooldown(0.0, 4.0)
	assert_false(slot.is_on_cooldown(), "reverted")
	assert_eq(slot.get_flash_alpha(), 0.0)
	assert_eq(finished[0], 0)
	slot.start_cooldown(1.0)
	slot.clear_cooldown()
	assert_false(slot.is_on_cooldown())
	slot.start_cooldown(0.0)
	assert_false(slot.is_on_cooldown(), "zero seconds is not a cooldown")
	slot.set_cooldown(5.0, 2.0)
	assert_near(slot.get_cooldown_fraction(), 1.0, 0.0001, "the total is never less than what remains")


func test_slot_cooldown_advances_by_itself_only_while_needed() -> void:
	var slot: UIIconSlot = _add(UIIconSlot.new()) as UIIconSlot
	assert_false(slot.is_processing(), "an idle slot spends nothing")
	slot.start_cooldown(0.1)
	assert_true(slot.is_processing())
	var waited: float = 0.0
	while slot.is_processing() and waited < 3.0:
		await wait_process_frames(2)
		waited += 2.0 / 60.0
	assert_false(slot.is_on_cooldown(), "it resolves on its own with the engine clock")
	assert_false(slot.is_processing(), "and goes idle again after the flash")


func test_slot_borders_counts_and_state() -> void:
	var slot: UIIconSlot = _add(UIIconSlot.new()) as UIIconSlot
	assert_eq(slot.get_border_color(), UIPalette.BORDER, "no rarity, metal border")
	for rarity: int in UIPalette.RARITY_COLORS.size():
		slot.rarity = rarity
		assert_eq(slot.get_border_color(), UIPalette.rarity_color(rarity),
				"border of rarity %d" % rarity)
	slot.rarity = UIPalette.Rarity.EPIC
	slot.selected = true
	assert_eq(slot.get_border_color(), UIPalette.ACCENT, "selected: accent")
	slot.selected = false
	slot.mouse_entered.emit()
	assert_true(slot.is_hovered())
	assert_eq(slot.get_border_color(), UIPalette.rarity_color(UIPalette.Rarity.EPIC).lightened(0.25),
			"with the mouse over it, lighter")
	assert_eq(UISounds.get_play_count(UISounds.HOVER), 1, "and it makes a sound")
	slot.mouse_exited.emit()
	assert_false(slot.is_hovered())
	assert_eq(slot.get_count_text(), "", "no stack, no counter")
	slot.count = 1
	assert_eq(slot.get_count_text(), "", "a single unit neither")
	slot.count = 20
	assert_eq(slot.get_count_text(), "20")
	assert_eq(slot.custom_minimum_size, UIIconSlot.SLOT_SIZE)
	assert_eq(slot.focus_mode, Control.FOCUS_ALL, "focusable with keyboard and gamepad")


func test_slot_key_glyph_and_tooltip_content() -> void:
	var slot: UIIconSlot = _add(UIIconSlot.new()) as UIIconSlot
	assert_null(slot.get_glyph())
	slot.key_action = &"ability_2"
	assert_not_null(slot.get_glyph())
	assert_eq(slot.get_glyph().get_label(), "2", "the glyph reads the InputMap")
	assert_true(slot.get_glyph().compact)
	slot.key_action = &"ability_3"
	assert_eq(slot.get_glyph().get_label(), "3")
	var glyph: UIKeyGlyph = slot.get_glyph()
	slot.key_action = &""
	assert_null(slot.get_glyph())
	assert_true(glyph.is_queued_for_deletion(), "and the glyph is released")
	assert_true(slot.get_tooltip_content().is_empty(), "no title, no tooltip")
	slot.set_tooltip_info("Poción", "Cura 200", "Consumible")
	slot.rarity = UIPalette.Rarity.UNCOMMON
	var content: Dictionary = slot.get_tooltip_content()
	assert_eq(content["title"], "Poción")
	assert_eq(content["body"], "Cura 200")
	assert_eq(content["subtitle"], "Consumible")
	assert_eq(content["accent"], UIPalette.rarity_color(UIPalette.Rarity.UNCOMMON))
	slot.rarity = -1
	assert_eq(slot.get_tooltip_content()["accent"], UIPalette.TITLE)
	# Linked to a tooltip, it shows it on mouse hover.
	var tooltip: UITooltip = _add(UITooltip.new()) as UITooltip
	tooltip.bounds_override = BOUNDS
	slot.bind_tooltip(tooltip)
	slot.mouse_entered.emit()
	tooltip.advance(UITooltip.DEFAULT_DELAY + 0.01)
	assert_true(tooltip.visible)
	assert_eq(tooltip.get_title_label().text, "Poción")


func test_slot_press_by_click_and_by_keyboard() -> void:
	var slot: UIIconSlot = _add(UIIconSlot.new()) as UIIconSlot
	slot.size = UIIconSlot.SLOT_SIZE
	var presses: Array[int] = [0]
	slot.pressed.connect(func() -> void: presses[0] += 1)
	slot._gui_input(_click(Vector2(20.0, 20.0), true))
	assert_eq(presses[0], 0, "not on press: on release inside")
	slot._gui_input(_click(Vector2(20.0, 20.0), false))
	assert_eq(presses[0], 1)
	slot._gui_input(_click(Vector2(200.0, 20.0), false))
	assert_eq(presses[0], 1, "releasing outside does not count")
	assert_eq(UISounds.get_play_count(UISounds.CLICK), 1, "the press makes a sound")
	var accept: InputEventAction = InputEventAction.new()
	accept.action = &"ui_accept"
	accept.pressed = true
	slot._gui_input(accept)
	assert_eq(presses[0], 1, "accept without focus does not press")
	slot.grab_focus()
	assert_true(slot.has_focus())
	slot._gui_input(accept)
	assert_eq(presses[0], 2, "with focus, accept presses")
	# Drawing the slot in every state raises no errors.
	slot.icon = UIPalette.load_emblem(&"vardheim")
	slot.rarity = UIPalette.Rarity.LEGENDARY
	slot.count = 12
	slot.key_action = &"ability_1"
	slot.start_cooldown(3.0)
	slot.advance(1.0)
	slot.enabled = false
	await wait_process_frames(2)
	slot.clear_cooldown()
	slot.advance(0.0)
	await wait_process_frames(1)


# --- Window -----------------------------------------------------------------------------------

func test_window_opens_closes_and_focuses_its_content() -> void:
	var window: UIWindow = UIWindow.new()
	window.window_title = "Ajustes de prueba"
	var button: Button = Button.new()
	window.get_content().add_child(button)
	_add(window)
	assert_false(window.visible, "starts closed")
	assert_false(window.is_open())
	var events: Array[String] = []
	window.opened.connect(func() -> void: events.append("abierta"))
	window.closed.connect(func() -> void: events.append("cerrada"))
	window.open()
	window.open()
	assert_true(window.visible)
	assert_true(window.is_open())
	assert_true(button.has_focus(), "opening it focuses its content")
	assert_eq(UISounds.get_play_count(UISounds.OPEN), 1)
	window.close()
	window.close()
	assert_false(window.visible)
	assert_eq(UISounds.get_play_count(UISounds.CLOSE), 1)
	window.toggle()
	assert_true(window.is_open())
	window.get_close_button().pressed.emit()
	assert_false(window.is_open(), "the close button closes it")
	assert_eq(events, ["abierta", "cerrada", "abierta", "cerrada"] as Array[String])
	assert_eq(window.theme_type_variation, &"WindowPanel")
	assert_eq(window.anchor_left, 0.5, "it is centered on its parent")
	assert_eq(window.anchor_top, 0.5)
	window.window_title = "Otro título"
	var title: Label = window.get_child(0).get_child(0).get_child(0) as Label
	assert_eq(title.text, "Otro título")


func test_escape_closes_the_window_before_anything_else_sees_it() -> void:
	var window: UIWindow = _add(UIWindow.new()) as UIWindow
	window.open()
	_press_escape()
	assert_false(window.is_open(), "Esc closes it")
	window.close_on_cancel = false
	window.open()
	_press_escape()
	assert_true(window.is_open(), "unless it must not close with Esc")
	window.close_on_cancel = true
	window.close()
	_press_escape()
	assert_false(window.is_open(), "when closed, Esc does nothing to it")


func test_the_camera_starts_with_the_cursor_free_when_asked_and_captured_headless() -> void:
	# With no real window (headless) the mouse is captured as usual.
	assert_false(CameraRig.starts_with_free_cursor(tree.root), "headless: it is captured")
	OS.set_environment("ELDMARK_SIN_RATON", "1")
	assert_true(CameraRig.starts_with_free_cursor(tree.root), "with ELDMARK_SIN_RATON=1 it starts released")
	var rig: CameraRig = (load(CAMERA_RIG_SCENE_PATH) as PackedScene).instantiate() as CameraRig
	_add(rig)
	OS.unset_environment("ELDMARK_SIN_RATON")
	assert_true(rig.is_cursor_free(), "the camera starts with the cursor released")
	assert_false(CameraRig.starts_with_free_cursor(tree.root), "without the variable, it is captured again")


func test_a_window_frees_and_recaptures_the_cursor_through_the_camera() -> void:
	var rig: CameraRig = (load(CAMERA_RIG_SCENE_PATH) as PackedScene).instantiate() as CameraRig
	_add(rig)
	var window: UIWindow = _add(UIWindow.new()) as UIWindow
	window.bind_camera(rig)
	assert_false(rig.is_cursor_free())
	window.open()
	assert_true(rig.is_cursor_free(), "when open, the cursor is free")
	window.close()
	assert_false(rig.is_cursor_free(), "when closed, it is captured again")
	window.open()
	tree.root.remove_child(window)
	assert_false(rig.is_cursor_free(), "if it disappears while open, it does not leave the cursor released")
	tree.root.add_child(window)
	window.close()
	# Linked to the already-open window.
	var other_window: UIWindow = _add(UIWindow.new()) as UIWindow
	other_window.open()
	other_window.bind_camera(rig)
	assert_true(rig.is_cursor_free())
	other_window.close()
	assert_false(rig.is_cursor_free())


func test_the_cursor_stays_free_until_every_window_has_closed() -> void:
	# T1: several requesters at once; the mouse is only recaptured when none is left.
	var rig: CameraRig = (load(CAMERA_RIG_SCENE_PATH) as PackedScene).instantiate() as CameraRig
	_add(rig)
	var first: UIWindow = _add(UIWindow.new()) as UIWindow
	var second: UIWindow = _add(UIWindow.new()) as UIWindow
	first.bind_camera(rig)
	second.bind_camera(rig)
	first.open()
	second.open()
	first.close()
	assert_true(rig.is_cursor_free(), "the second one is still open")
	second.close()
	assert_false(rig.is_cursor_free())
	# Requesting it twice counts as one; releasing it once is enough.
	rig.set_ui_cursor_release(true, first)
	rig.set_ui_cursor_release(true, first)
	rig.set_ui_cursor_release(false, first)
	assert_false(rig.is_cursor_free())
	# A requester that is freed without notice does not leave the cursor released forever.
	var gone := Node.new()
	rig.set_ui_cursor_release(true, gone)
	assert_true(rig.is_cursor_free())
	gone.free()
	assert_false(rig.is_cursor_free(), "the requester that no longer exists is discarded")


# --- Confirmation dialog ----------------------------------------------------------------------

func test_confirm_dialog_confirms_and_cancels() -> void:
	var dialog: UIConfirmDialog = _add(UIConfirmDialog.new()) as UIConfirmDialog
	assert_false(dialog.visible)
	var results: Array[String] = []
	dialog.confirmed.connect(func() -> void:
		results.append("confirmado:%s" % dialog.is_open()))
	dialog.canceled.connect(func() -> void:
		results.append("cancelado:%s" % dialog.is_open()))
	dialog.open("Salir", "¿Seguro?", "Sí", "No")
	assert_true(dialog.visible)
	assert_true(dialog.is_open())
	assert_eq(dialog.get_title_label().text, "Salir")
	assert_eq(dialog.get_message_label().text, "¿Seguro?")
	assert_eq(dialog.get_confirm_button().text, "Sí")
	assert_eq(dialog.get_cancel_button().text, "No")
	assert_eq(UISounds.get_play_count(UISounds.OPEN), 1)
	dialog.get_confirm_button().pressed.emit()
	assert_eq(results, ["confirmado:false"] as Array[String], "it closes before notifying")
	assert_false(dialog.visible)
	assert_eq(UISounds.get_play_count(UISounds.CONFIRM), 1)
	dialog.confirm()
	dialog.cancel()
	assert_eq(results.size(), 1, "when closed, it does not respond")
	dialog.open("Otra", "Pregunta")
	assert_eq(dialog.get_confirm_button().text, UIConfirmDialog.DEFAULT_CONFIRM_TEXT)
	assert_eq(dialog.get_cancel_button().text, UIConfirmDialog.DEFAULT_CANCEL_TEXT)
	dialog.get_cancel_button().pressed.emit()
	assert_eq(results, ["confirmado:false", "cancelado:false"] as Array[String])
	assert_eq(UISounds.get_play_count(UISounds.CANCEL), 1)
	# Esc cancels.
	dialog.open("Otra", "Pregunta")
	_press_escape()
	assert_false(dialog.is_open(), "Esc cancels")
	assert_eq(results.size(), 3)
	assert_eq(results[2], "cancelado:false")


func test_confirm_dialog_focus_and_danger_style() -> void:
	var dialog: UIConfirmDialog = _add(UIConfirmDialog.new()) as UIConfirmDialog
	dialog.open("Aviso", "Mensaje")
	assert_true(dialog.get_cancel_button().has_focus(), "by default focus starts on cancel")
	dialog.cancel()
	dialog.open("Aviso", "Mensaje", "Sí", "No", false, false)
	assert_true(dialog.get_confirm_button().has_focus(), "unless asked otherwise")
	assert_eq(dialog.get_confirm_button().theme_type_variation, &"")
	dialog.cancel()
	dialog.open("Borrar", "No se puede deshacer", "Borrar", "Cancelar", true, false)
	assert_true(dialog.get_cancel_button().has_focus(), "a destructive action starts on cancel")
	assert_eq(dialog.get_confirm_button().theme_type_variation, &"DangerButton")
	# Focus does not leave the dialog.
	var confirm_button: Button = dialog.get_confirm_button()
	var cancel_button: Button = dialog.get_cancel_button()
	assert_eq(UIFocus.get_neighbor(cancel_button, SIDE_RIGHT), confirm_button)
	assert_eq(UIFocus.get_neighbor(confirm_button, SIDE_LEFT), cancel_button)
	assert_eq(UIFocus.get_neighbor(confirm_button, SIDE_TOP), confirm_button, "it does not leave upward")
	assert_eq(UIFocus.get_neighbor(cancel_button, SIDE_BOTTOM), cancel_button, "nor downward")
	assert_eq(dialog.mouse_filter, Control.MOUSE_FILTER_STOP, "it is modal: it swallows the mouse")
	assert_eq(dialog.anchor_right, 1.0, "covers the screen")
	assert_eq(dialog.anchor_bottom, 1.0)


func test_confirm_dialog_frees_the_cursor_while_open() -> void:
	var rig: CameraRig = (load(CAMERA_RIG_SCENE_PATH) as PackedScene).instantiate() as CameraRig
	_add(rig)
	var dialog: UIConfirmDialog = _add(UIConfirmDialog.new()) as UIConfirmDialog
	dialog.bind_camera(rig)
	dialog.open("Aviso", "Mensaje")
	assert_true(rig.is_cursor_free())
	dialog.open("Aviso", "Otro mensaje")
	dialog.confirm()
	assert_false(rig.is_cursor_free(), "on close it recaptures (only once)")
	dialog.open("Aviso", "Mensaje")
	tree.root.remove_child(dialog)
	assert_false(rig.is_cursor_free(), "and if it disappears while open, too")
	tree.root.add_child(dialog)


# --- The gallery ------------------------------------------------------------------------------

func test_the_gallery_shows_every_common_component() -> void:
	var gallery: UIGallery = (load(GALLERY_SCENE_PATH) as PackedScene).instantiate() as UIGallery
	_add(gallery)
	await wait_process_frames(2)
	assert_true(gallery.get_slots().size() >= 9, "slots of every rarity and state")
	var found: Dictionary = {}
	for control: Control in gallery.get_all_controls():
		for name: String in ["UIIconSlot", "UIKeyGlyph", "UIHintBar", "UIConfirmDialog",
				"UITooltip"]:
			if control.get_script() != null and control.get_script().get_global_name() == name:
				found[name] = true
	for name: String in ["UIIconSlot", "UIKeyGlyph", "UIHintBar", "UIConfirmDialog", "UITooltip"]:
		assert_true(found.has(name), "the gallery shows %s" % name)
	var rarities: Dictionary = {}
	for slot: UIIconSlot in gallery.get_slots():
		rarities[slot.rarity] = true
	for rarity: int in UIPalette.RARITY_COLORS.size():
		assert_true(rarities.has(rarity), "a slot with rarity %d" % rarity)
	assert_true(gallery.get_cooldown_slot().is_on_cooldown(), "a slot with a cooldown running")
	assert_not_null(gallery.get_cooldown_slot().get_glyph(), "and with its key glyph")
	# Its buttons are hooked up to sound.
	var button: Button = gallery.find_child("Muestras", true, false).get_child(0) as Button
	if button != null:
		UISounds.reset()
		button.pressed.emit()
		assert_eq(UISounds.get_play_count(UISounds.CLICK), 1, "the gallery buttons make a sound")


func test_the_gallery_confirmation_buttons_open_the_dialog() -> void:
	var gallery: UIGallery = (load(GALLERY_SCENE_PATH) as PackedScene).instantiate() as UIGallery
	_add(gallery)
	await wait_process_frames(2)
	var dialog: UIConfirmDialog = gallery.get_confirm_dialog()
	var danger: Button = null
	for node: Node in gallery.find_children("*", "Button", true, false):
		if (node as Button).text == "Borrar personaje":
			danger = node as Button
	assert_not_null(danger, "the gallery's dangerous button")
	danger.pressed.emit()
	assert_true(dialog.is_open())
	assert_eq(dialog.get_confirm_button().theme_type_variation, &"DangerButton")
	dialog.confirm()
	await wait_process_frames(1)
	var results: Array[Node] = gallery.find_children("*", "Label", true, false).filter(
			func(node: Node) -> bool: return (node as Label).text == "Confirmado")
	assert_eq(results.size(), 1, "the result is shown in the gallery")
