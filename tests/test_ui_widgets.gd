extends TestCase
## Pruebas de los componentes de interfaz con aspecto propio (UI-09): el tooltip con retraso y ajuste
## a los bordes ([UITooltip]), la casilla de icono con barrido de reutilización ([UIIconSlot]), la
## ventana ([UIWindow]), el diálogo de confirmación ([UIConfirmDialog]) y la galería con todos ellos.

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


# Área de un polígono (fórmula del cordón).
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
	# Pegado a la derecha: pasa a la izquierda del cursor.
	var right: Vector2 = UITooltip.fit_position(Vector2(900.0, 100.0), tooltip_size, BOUNDS)
	assert_near(right.x, 900.0 - offset.x - tooltip_size.x, 0.001, "a la izquierda")
	assert_near(right.y, 100.0 + offset.y, 0.001)
	# Pegado abajo: pasa encima.
	var bottom: Vector2 = UITooltip.fit_position(Vector2(100.0, 760.0), tooltip_size, BOUNDS)
	assert_near(bottom.y, 760.0 - offset.y - tooltip_size.y, 0.001, "encima")
	assert_near(bottom.x, 100.0 + offset.x, 0.001)
	# En la esquina, las dos cosas.
	var corner: Vector2 = UITooltip.fit_position(Vector2(990.0, 790.0), tooltip_size, BOUNDS)
	assert_near(corner.x, 990.0 - offset.x - tooltip_size.x, 0.001)
	assert_near(corner.y, 790.0 - offset.y - tooltip_size.y, 0.001)
	# Si al girar se saliera por el otro lado, se encaja con el margen.
	var wide: Vector2 = UITooltip.fit_position(Vector2(150.0, 100.0), Vector2(400.0, 80.0),
			Rect2(0.0, 0.0, 300.0, 800.0))
	assert_near(wide.x, UITooltip.MARGIN, 0.001, "encajado al borde izquierdo")
	var top: Vector2 = UITooltip.fit_position(Vector2(100.0, 5.0), tooltip_size,
			Rect2(0.0, 0.0, 1000.0, 90.0))
	assert_near(top.y, UITooltip.MARGIN, 0.001, "y al superior")
	# Mayor que la pantalla: manda la esquina superior izquierda.
	var huge: Vector2 = UITooltip.fit_position(Vector2(50.0, 50.0), Vector2(2000.0, 2000.0), BOUNDS)
	assert_vec_near(huge, Vector2(UITooltip.MARGIN, UITooltip.MARGIN), 0.001)
	# Con límites que no empiezan en el origen.
	var offset_bounds: Rect2 = Rect2(100.0, 50.0, 400.0, 300.0)
	var inside: Vector2 = UITooltip.fit_position(Vector2(110.0, 60.0), tooltip_size, offset_bounds)
	assert_true(inside.x >= 100.0 + UITooltip.MARGIN and inside.y >= 50.0 + UITooltip.MARGIN)
	# Siempre queda dentro, esté el cursor donde esté.
	for x: int in range(0, 1001, 125):
		for y: int in range(0, 801, 100):
			var placed: Vector2 = UITooltip.fit_position(Vector2(x, y), tooltip_size, BOUNDS)
			assert_true(Rect2(placed, tooltip_size).intersection(BOUNDS).size.is_equal_approx(tooltip_size),
					"cursor (%d, %d): queda dentro" % [x, y])


func test_the_tooltip_waits_for_its_delay() -> void:
	var tooltip: UITooltip = _add(UITooltip.new()) as UITooltip
	tooltip.bounds_override = BOUNDS
	assert_false(tooltip.visible)
	tooltip.request("Espada de hierro", "Un arma sencilla.", UIPalette.TITLE, Vector2(100.0, 100.0))
	assert_true(tooltip.is_pending())
	assert_false(tooltip.is_showing())
	tooltip.advance(0.2)
	assert_false(tooltip.visible, "todavía no")
	tooltip.advance(UITooltip.DEFAULT_DELAY - 0.2 - 0.01)
	assert_false(tooltip.visible, "a un pelo del retraso, tampoco")
	tooltip.advance(0.02)
	assert_true(tooltip.visible, "pasado el retraso aparece")
	assert_true(tooltip.is_showing())
	assert_false(tooltip.is_pending())
	tooltip.cancel()
	assert_false(tooltip.visible)
	assert_false(tooltip.is_showing())
	assert_eq(tooltip.get_elapsed(), 0.0)
	# Cancelar antes del retraso no llega a mostrarlo.
	tooltip.request("Escudo", "", UIPalette.TITLE, Vector2(100.0, 100.0))
	tooltip.advance(0.3)
	tooltip.cancel()
	tooltip.advance(1.0)
	assert_false(tooltip.visible, "cancelado a tiempo")
	# El retraso se puede cambiar.
	tooltip.delay = 0.0
	tooltip.request("Ya", "", UIPalette.TITLE, Vector2(100.0, 100.0))
	tooltip.advance(0.0)
	assert_true(tooltip.visible, "sin retraso, a la primera")


func test_the_tooltip_shows_rich_content_and_changes_it_while_visible() -> void:
	var tooltip: UITooltip = _add(UITooltip.new()) as UITooltip
	tooltip.bounds_override = BOUNDS
	tooltip.delay = 0.1
	tooltip.request("Hacha rara", "Daño [b]120[/b] y [color=#E9C341]oro[/color]", UIPalette.rarity_color(2),
			Vector2(100.0, 100.0), "Arma · dos manos")
	tooltip.advance(0.2)
	assert_eq(tooltip.get_title_label().text, "Hacha rara")
	assert_eq(tooltip.get_title_label().get_theme_color(&"font_color"), UIPalette.rarity_color(2),
			"el título lleva el color de la rareza")
	assert_true(tooltip.get_subtitle_label().visible)
	assert_eq(tooltip.get_subtitle_label().text, "Arma · dos manos")
	assert_eq(tooltip.get_body_label().get_parsed_text(), "Daño 120 y oro", "el BBCode se interpreta")
	# Cambiar de objeto con el tooltip visible no espera otra vez.
	tooltip.request("Escudo", "", UIPalette.TITLE, Vector2(300.0, 200.0))
	assert_true(tooltip.is_showing(), "sigue visible")
	assert_false(tooltip.is_pending(), "sin nueva espera")
	assert_eq(tooltip.get_title_label().text, "Escudo")
	assert_false(tooltip.get_body_label().visible, "sin cuerpo no hay hueco")
	assert_false(tooltip.get_subtitle_label().visible)
	assert_eq(tooltip.mouse_filter, Control.MOUSE_FILTER_IGNORE, "nunca captura el ratón")


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
		assert_true(BOUNDS.encloses(rect), "ancla %s: el tooltip %s queda dentro" % [anchor, rect])
		assert_true(tooltip.size.x <= UITooltip.MAX_TEXT_WIDTH + 60.0, "el ancho se limita")
		tooltip.cancel()
	# Mover el ratón lo recoloca.
	tooltip.request("Título", "Cuerpo", UIPalette.TITLE, Vector2(100.0, 100.0))
	tooltip.advance(0.0)
	var before: Vector2 = tooltip.position
	tooltip.move_to(Vector2(400.0, 300.0))
	assert_true(tooltip.position.x > before.x and tooltip.position.y > before.y, "acompaña al cursor")


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
	assert_eq(calls[0], 100, "se pide el contenido al entrar, con el último proveedor")
	assert_true(tooltip.is_pending())
	tooltip.advance(UITooltip.DEFAULT_DELAY + 0.01)
	assert_true(tooltip.visible)
	assert_eq(tooltip.get_title_label().text, "Botón")
	assert_eq(tooltip.get_title_label().get_theme_color(&"font_color"), RealmCatalog.SOLMARCH_COLOR)
	button.mouse_exited.emit()
	assert_false(tooltip.visible, "al salir se oculta")
	button.focus_entered.emit()
	tooltip.advance(UITooltip.DEFAULT_DELAY + 0.01)
	assert_true(tooltip.visible, "el foco (teclado o mando) también lo muestra")
	button.focus_exited.emit()
	assert_false(tooltip.visible)
	# Un proveedor sin contenido no muestra nada.
	var silent: Button = _add(Button.new()) as Button
	tooltip.bind_source(silent, func() -> Dictionary: return {})
	silent.mouse_entered.emit()
	assert_false(tooltip.is_pending())
	# Salir del árbol mientras se muestra lo oculta.
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
	assert_eq((layer as CanvasLayer).layer, UITooltip.LAYER, "por encima del HUD")
	assert_eq(UITooltip.get_shared(tree), first, "uno solo")
	assert_false(first.visible)
	layer.get_parent().remove_child(layer)
	layer.free()
	_nodes.clear()
	var second: UITooltip = UITooltip.get_shared(tree)
	assert_not_null(second, "si se pierde, se crea otro")
	_nodes.append(second.get_parent())


# --- Casilla de icono -------------------------------------------------------------------------

func test_the_sweep_polygon_covers_the_swept_part_of_the_slot() -> void:
	var square: Rect2 = Rect2(Vector2(2.0, 2.0), Vector2(48.0, 48.0))
	var total: float = square.get_area()
	assert_eq(UIIconSlot.sweep_polygon(square, 0.0).size(), 0, "sin reutilización, nada")
	assert_near(_area(UIIconSlot.sweep_polygon(square, 1.0)), total, 0.01, "recién empezada: todo")
	assert_near(_area(UIIconSlot.sweep_polygon(square, 0.5)), total * 0.5, 0.01, "mitad")
	# En un cuadrado, las vueltas múltiplos de un octavo reparten el área por igual.
	for eighths: int in range(1, 9):
		var fraction: float = float(eighths) / 8.0
		assert_near(_area(UIIconSlot.sweep_polygon(square, fraction)), total * fraction, 0.05,
				"%d/8 de vuelta" % eighths)
	var wide: Rect2 = Rect2(0.0, 0.0, 80.0, 30.0)
	assert_near(_area(UIIconSlot.sweep_polygon(wide, 0.5)), wide.get_area() * 0.5, 0.01,
			"la mitad lo es en cualquier rectángulo")
	# Empieza en las 12 en punto y avanza en sentido horario.
	var quarter: PackedVector2Array = UIIconSlot.sweep_polygon(square, 0.25)
	assert_vec_near(quarter[0], square.get_center(), 0.001, "abanico desde el centro")
	assert_vec_near(quarter[1], Vector2(square.get_center().x, square.position.y), 0.001,
			"empieza arriba")
	assert_vec_near(quarter[quarter.size() - 1], Vector2(square.end.x, square.get_center().y), 0.001,
			"y a un cuarto de vuelta llega a la derecha")
	# Nunca se sale del rectángulo.
	for rect: Rect2 in [square, wide, Rect2(0.0, 0.0, 30.0, 80.0)]:
		for step: int in 21:
			for point: Vector2 in UIIconSlot.sweep_polygon(rect, float(step) / 20.0):
				assert_true(rect.grow(0.001).has_point(point), "%s dentro de %s" % [point, rect])
	assert_eq(UIIconSlot.sweep_polygon(Rect2(), 0.5).size(), 0, "rectángulo vacío")


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
	assert_false(slot.is_on_cooldown(), "se acabó")
	assert_eq(finished[0], 1, "avisa una vez")
	assert_near(slot.get_flash_alpha(), 1.0, 0.0001, "y destella")
	slot.advance(UIIconSlot.FLASH_SECONDS * 0.5)
	assert_near(slot.get_flash_alpha(), 0.5, 0.0001, "el destello se apaga")
	slot.advance(1.0)
	assert_eq(slot.get_flash_alpha(), 0.0)
	assert_eq(finished[0], 1)
	slot.advance(1.0)
	assert_eq(finished[0], 1, "sin reutilización no vuelve a avisar")


func test_the_server_can_correct_a_predicted_cooldown() -> void:
	var slot: UIIconSlot = _add(UIIconSlot.new()) as UIIconSlot
	var finished: Array[int] = [0]
	slot.cooldown_finished.connect(func() -> void: finished[0] += 1)
	slot.start_cooldown(2.0)
	slot.advance(0.5)
	# El servidor dice que falta más: la casilla se corrige.
	slot.set_cooldown(3.0, 4.0)
	assert_near(slot.get_cooldown_remaining(), 3.0, 0.0001)
	assert_near(slot.get_cooldown_fraction(), 0.75, 0.0001)
	# Rechazó la acción y no llegó a gastarse: se quita sin destello ni aviso.
	slot.set_cooldown(0.0, 4.0)
	assert_false(slot.is_on_cooldown(), "revertida")
	assert_eq(slot.get_flash_alpha(), 0.0)
	assert_eq(finished[0], 0)
	slot.start_cooldown(1.0)
	slot.clear_cooldown()
	assert_false(slot.is_on_cooldown())
	slot.start_cooldown(0.0)
	assert_false(slot.is_on_cooldown(), "cero segundos no es una reutilización")
	slot.set_cooldown(5.0, 2.0)
	assert_near(slot.get_cooldown_fraction(), 1.0, 0.0001, "el total nunca es menor que lo que falta")


func test_slot_cooldown_advances_by_itself_only_while_needed() -> void:
	var slot: UIIconSlot = _add(UIIconSlot.new()) as UIIconSlot
	assert_false(slot.is_processing(), "una casilla en reposo no gasta nada")
	slot.start_cooldown(0.1)
	assert_true(slot.is_processing())
	var waited: float = 0.0
	while slot.is_processing() and waited < 3.0:
		await wait_process_frames(2)
		waited += 2.0 / 60.0
	assert_false(slot.is_on_cooldown(), "se resuelve sola con el reloj del motor")
	assert_false(slot.is_processing(), "y vuelve a quedarse quieta tras el destello")


func test_slot_borders_counts_and_state() -> void:
	var slot: UIIconSlot = _add(UIIconSlot.new()) as UIIconSlot
	assert_eq(slot.get_border_color(), UIPalette.BORDER, "sin rareza, borde de metal")
	for rarity: int in UIPalette.RARITY_COLORS.size():
		slot.rarity = rarity
		assert_eq(slot.get_border_color(), UIPalette.rarity_color(rarity),
				"borde de la rareza %d" % rarity)
	slot.rarity = UIPalette.Rarity.EPIC
	slot.selected = true
	assert_eq(slot.get_border_color(), UIPalette.ACCENT, "elegida: acento")
	slot.selected = false
	slot.mouse_entered.emit()
	assert_true(slot.is_hovered())
	assert_eq(slot.get_border_color(), UIPalette.rarity_color(UIPalette.Rarity.EPIC).lightened(0.25),
			"con el ratón encima, más claro")
	assert_eq(UISounds.get_play_count(UISounds.HOVER), 1, "y suena")
	slot.mouse_exited.emit()
	assert_false(slot.is_hovered())
	assert_eq(slot.get_count_text(), "", "sin pila no hay contador")
	slot.count = 1
	assert_eq(slot.get_count_text(), "", "una unidad tampoco")
	slot.count = 20
	assert_eq(slot.get_count_text(), "20")
	assert_eq(slot.custom_minimum_size, UIIconSlot.SLOT_SIZE)
	assert_eq(slot.focus_mode, Control.FOCUS_ALL, "enfocable con teclado y mando")


func test_slot_key_glyph_and_tooltip_content() -> void:
	var slot: UIIconSlot = _add(UIIconSlot.new()) as UIIconSlot
	assert_null(slot.get_glyph())
	slot.key_action = &"ability_2"
	assert_not_null(slot.get_glyph())
	assert_eq(slot.get_glyph().get_label(), "2", "el glifo lee el InputMap")
	assert_true(slot.get_glyph().compact)
	slot.key_action = &"ability_3"
	assert_eq(slot.get_glyph().get_label(), "3")
	var glyph: UIKeyGlyph = slot.get_glyph()
	slot.key_action = &""
	assert_null(slot.get_glyph())
	assert_true(glyph.is_queued_for_deletion(), "y el glifo se libera")
	assert_true(slot.get_tooltip_content().is_empty(), "sin título no hay tooltip")
	slot.set_tooltip_info("Poción", "Cura 200", "Consumible")
	slot.rarity = UIPalette.Rarity.UNCOMMON
	var content: Dictionary = slot.get_tooltip_content()
	assert_eq(content["title"], "Poción")
	assert_eq(content["body"], "Cura 200")
	assert_eq(content["subtitle"], "Consumible")
	assert_eq(content["accent"], UIPalette.rarity_color(UIPalette.Rarity.UNCOMMON))
	slot.rarity = -1
	assert_eq(slot.get_tooltip_content()["accent"], UIPalette.TITLE)
	# Enlazada con un tooltip, lo muestra al pasar el ratón.
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
	assert_eq(presses[0], 0, "no al apretar: al soltar dentro")
	slot._gui_input(_click(Vector2(20.0, 20.0), false))
	assert_eq(presses[0], 1)
	slot._gui_input(_click(Vector2(200.0, 20.0), false))
	assert_eq(presses[0], 1, "soltar fuera no cuenta")
	assert_eq(UISounds.get_play_count(UISounds.CLICK), 1, "la pulsación suena")
	var accept: InputEventAction = InputEventAction.new()
	accept.action = &"ui_accept"
	accept.pressed = true
	slot._gui_input(accept)
	assert_eq(presses[0], 1, "aceptar sin foco no pulsa")
	slot.grab_focus()
	assert_true(slot.has_focus())
	slot._gui_input(accept)
	assert_eq(presses[0], 2, "con el foco, aceptar pulsa")
	# Dibujar la casilla en cada estado no da errores.
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


# --- Ventana ----------------------------------------------------------------------------------

func test_window_opens_closes_and_focuses_its_content() -> void:
	var window: UIWindow = UIWindow.new()
	window.window_title = "Ajustes de prueba"
	var button: Button = Button.new()
	window.get_content().add_child(button)
	_add(window)
	assert_false(window.visible, "empieza cerrada")
	assert_false(window.is_open())
	var events: Array[String] = []
	window.opened.connect(func() -> void: events.append("abierta"))
	window.closed.connect(func() -> void: events.append("cerrada"))
	window.open()
	window.open()
	assert_true(window.visible)
	assert_true(window.is_open())
	assert_true(button.has_focus(), "abrirla enfoca su contenido")
	assert_eq(UISounds.get_play_count(UISounds.OPEN), 1)
	window.close()
	window.close()
	assert_false(window.visible)
	assert_eq(UISounds.get_play_count(UISounds.CLOSE), 1)
	window.toggle()
	assert_true(window.is_open())
	window.get_close_button().pressed.emit()
	assert_false(window.is_open(), "el botón de cerrar la cierra")
	assert_eq(events, ["abierta", "cerrada", "abierta", "cerrada"] as Array[String])
	assert_eq(window.theme_type_variation, &"WindowPanel")
	assert_eq(window.anchor_left, 0.5, "se centra en su padre")
	assert_eq(window.anchor_top, 0.5)
	window.window_title = "Otro título"
	var title: Label = window.get_child(0).get_child(0).get_child(0) as Label
	assert_eq(title.text, "Otro título")


func test_escape_closes_the_window_before_anything_else_sees_it() -> void:
	var window: UIWindow = _add(UIWindow.new()) as UIWindow
	window.open()
	_press_escape()
	assert_false(window.is_open(), "Esc la cierra")
	window.close_on_cancel = false
	window.open()
	_press_escape()
	assert_true(window.is_open(), "salvo que no deba cerrarse con Esc")
	window.close_on_cancel = true
	window.close()
	_press_escape()
	assert_false(window.is_open(), "cerrada, Esc no hace nada con ella")


func test_a_window_frees_and_recaptures_the_cursor_through_the_camera() -> void:
	var rig: CameraRig = (load(CAMERA_RIG_SCENE_PATH) as PackedScene).instantiate() as CameraRig
	_add(rig)
	var window: UIWindow = _add(UIWindow.new()) as UIWindow
	window.bind_camera(rig)
	assert_false(rig.is_cursor_free())
	window.open()
	assert_true(rig.is_cursor_free(), "abierta, el cursor está libre")
	window.close()
	assert_false(rig.is_cursor_free(), "cerrada, vuelve a capturarse")
	window.open()
	tree.root.remove_child(window)
	assert_false(rig.is_cursor_free(), "si desaparece abierta, no deja el cursor suelto")
	tree.root.add_child(window)
	window.close()
	# Enlazada con la ventana ya abierta.
	var other_window: UIWindow = _add(UIWindow.new()) as UIWindow
	other_window.open()
	other_window.bind_camera(rig)
	assert_true(rig.is_cursor_free())
	other_window.close()
	assert_false(rig.is_cursor_free())


# --- Diálogo de confirmación ------------------------------------------------------------------

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
	assert_eq(results, ["confirmado:false"] as Array[String], "se cierra antes de avisar")
	assert_false(dialog.visible)
	assert_eq(UISounds.get_play_count(UISounds.CONFIRM), 1)
	dialog.confirm()
	dialog.cancel()
	assert_eq(results.size(), 1, "cerrado, no responde")
	dialog.open("Otra", "Pregunta")
	assert_eq(dialog.get_confirm_button().text, UIConfirmDialog.DEFAULT_CONFIRM_TEXT)
	assert_eq(dialog.get_cancel_button().text, UIConfirmDialog.DEFAULT_CANCEL_TEXT)
	dialog.get_cancel_button().pressed.emit()
	assert_eq(results, ["confirmado:false", "cancelado:false"] as Array[String])
	assert_eq(UISounds.get_play_count(UISounds.CANCEL), 1)
	# Esc cancela.
	dialog.open("Otra", "Pregunta")
	_press_escape()
	assert_false(dialog.is_open(), "Esc cancela")
	assert_eq(results.size(), 3)
	assert_eq(results[2], "cancelado:false")


func test_confirm_dialog_focus_and_danger_style() -> void:
	var dialog: UIConfirmDialog = _add(UIConfirmDialog.new()) as UIConfirmDialog
	dialog.open("Aviso", "Mensaje")
	assert_true(dialog.get_cancel_button().has_focus(), "por defecto el foco empieza en cancelar")
	dialog.cancel()
	dialog.open("Aviso", "Mensaje", "Sí", "No", false, false)
	assert_true(dialog.get_confirm_button().has_focus(), "salvo que se pida lo contrario")
	assert_eq(dialog.get_confirm_button().theme_type_variation, &"")
	dialog.cancel()
	dialog.open("Borrar", "No se puede deshacer", "Borrar", "Cancelar", true, false)
	assert_true(dialog.get_cancel_button().has_focus(), "una acción destructiva empieza en cancelar")
	assert_eq(dialog.get_confirm_button().theme_type_variation, &"DangerButton")
	# El foco no se sale del diálogo.
	var confirm_button: Button = dialog.get_confirm_button()
	var cancel_button: Button = dialog.get_cancel_button()
	assert_eq(UIFocus.get_neighbor(cancel_button, SIDE_RIGHT), confirm_button)
	assert_eq(UIFocus.get_neighbor(confirm_button, SIDE_LEFT), cancel_button)
	assert_eq(UIFocus.get_neighbor(confirm_button, SIDE_TOP), confirm_button, "arriba no sale")
	assert_eq(UIFocus.get_neighbor(cancel_button, SIDE_BOTTOM), cancel_button, "abajo tampoco")
	assert_eq(dialog.mouse_filter, Control.MOUSE_FILTER_STOP, "es modal: se come el ratón")
	assert_eq(dialog.anchor_right, 1.0, "cubre la pantalla")
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
	assert_false(rig.is_cursor_free(), "al cerrarlo se recaptura (una sola vez)")
	dialog.open("Aviso", "Mensaje")
	tree.root.remove_child(dialog)
	assert_false(rig.is_cursor_free(), "y si desaparece abierto, también")
	tree.root.add_child(dialog)


# --- La galería -------------------------------------------------------------------------------

func test_the_gallery_shows_every_common_component() -> void:
	var gallery: UIGallery = (load(GALLERY_SCENE_PATH) as PackedScene).instantiate() as UIGallery
	_add(gallery)
	await wait_process_frames(2)
	assert_true(gallery.get_slots().size() >= 9, "casillas de todas las rarezas y estados")
	var found: Dictionary = {}
	for control: Control in gallery.get_all_controls():
		for name: String in ["UIIconSlot", "UIKeyGlyph", "UIHintBar", "UIConfirmDialog",
				"UITooltip"]:
			if control.get_script() != null and control.get_script().get_global_name() == name:
				found[name] = true
	for name: String in ["UIIconSlot", "UIKeyGlyph", "UIHintBar", "UIConfirmDialog", "UITooltip"]:
		assert_true(found.has(name), "la galería muestra %s" % name)
	var rarities: Dictionary = {}
	for slot: UIIconSlot in gallery.get_slots():
		rarities[slot.rarity] = true
	for rarity: int in UIPalette.RARITY_COLORS.size():
		assert_true(rarities.has(rarity), "una casilla con la rareza %d" % rarity)
	assert_true(gallery.get_cooldown_slot().is_on_cooldown(), "una casilla con reutilización en marcha")
	assert_not_null(gallery.get_cooldown_slot().get_glyph(), "y con su glifo de tecla")
	# Sus botones están enganchados al sonido.
	var button: Button = gallery.find_child("Muestras", true, false).get_child(0) as Button
	if button != null:
		UISounds.reset()
		button.pressed.emit()
		assert_eq(UISounds.get_play_count(UISounds.CLICK), 1, "los botones de la galería suenan")


func test_the_gallery_confirmation_buttons_open_the_dialog() -> void:
	var gallery: UIGallery = (load(GALLERY_SCENE_PATH) as PackedScene).instantiate() as UIGallery
	_add(gallery)
	await wait_process_frames(2)
	var dialog: UIConfirmDialog = gallery.get_confirm_dialog()
	var danger: Button = null
	for node: Node in gallery.find_children("*", "Button", true, false):
		if (node as Button).text == "Borrar personaje":
			danger = node as Button
	assert_not_null(danger, "el botón peligroso de la galería")
	danger.pressed.emit()
	assert_true(dialog.is_open())
	assert_eq(dialog.get_confirm_button().theme_type_variation, &"DangerButton")
	dialog.confirm()
	await wait_process_frames(1)
	var results: Array[Node] = gallery.find_children("*", "Label", true, false).filter(
			func(node: Node) -> bool: return (node as Label).text == "Confirmado")
	assert_eq(results.size(), 1, "el resultado se muestra en la galería")
