class_name UIIconSlot
extends Control
## Casilla de icono (UI-09): la pieza de las barras de acciones, los inventarios y los efectos.
## Dibuja un icono sobre un fondo hundido con borde del color de su rareza, un contador de pila
## abajo a la derecha, un glifo de tecla ([UIKeyGlyph]) arriba a la izquierda y, cuando está en
## reutilización, un barrido en sentido horario con los segundos que faltan. Al quedar lista da un
## destello breve.
## [br][br]
## [b]Reutilización.[/b] [method start_cooldown] la arranca (se predice al pulsar) y
## [method set_cooldown] la fija con lo que dice el servidor (la corrige si rechaza la acción o
## llega con otro tiempo); [method clear_cooldown] la quita. El tiempo lo lleva [method advance]
## ([method _process] lo llama con el delta de cada fotograma, solo mientras hace falta); las
## pruebas lo llaman con pasos exactos. El barrido es el polígono de [method sweep_polygon].
## [br][br]
## [b]Entrada.[/b] Un clic izquierdo suelto sobre la casilla, o aceptar con ella enfocada, emite
## [signal pressed]; la casilla no decide si la acción vale (eso es de quien la escucha). Es
## enfocable ([constant Control.FOCUS_ALL]) para navegar con teclado o mando ([UIFocus]) y suena por
## [UISounds] al pasar el ratón y al pulsar.
## [br][br]
## [b]Tooltip.[/b] [method set_tooltip_info] guarda el contenido y [method bind_tooltip] lo enlaza con
## un [UITooltip]; el título lleva el color de la rareza.
## [br][br]
## Solo cliente. Todo se dibuja en [method _draw] (sin nodos hijos salvo el glifo): una barra con
## decenas de casillas no cuesta nada.

## Se pulsó la casilla (clic izquierdo o aceptar con el foco).
signal pressed
## La reutilización llegó a cero.
signal cooldown_finished

const SLOT_SIZE: Vector2 = Vector2(52.0, 52.0)
## Segundos que dura el destello de «lista».
const FLASH_SECONDS: float = 0.3
## Margen (px) entre el borde y el icono.
const ICON_MARGIN: float = 3.0
const BORDER_WIDTH: int = 2
const COUNT_FONT_SIZE: int = 14
const COOLDOWN_FONT_SIZE: int = 18
const COOLDOWN_OVERLAY: Color = Color(0.0, 0.0, 0.0, 0.62)
const DISABLED_TINT: Color = Color(0.45, 0.45, 0.45, 0.8)

## Icono (null: casilla vacía).
var icon: Texture2D = null:
	set(value):
		icon = value
		queue_redraw()
## Rareza ([enum UIPalette.Rarity]) que da el color del borde; -1 = sin rareza (borde de metal).
var rarity: int = -1:
	set(value):
		rarity = value
		queue_redraw()
## Tamaño de la pila: solo se dibuja si es mayor que 1.
var count: int = 0:
	set(value):
		count = value
		queue_redraw()
## Acción cuyo glifo de tecla se muestra arriba a la izquierda (vacía: sin glifo).
var key_action: StringName = &"":
	set(value):
		key_action = value
		_update_glyph()
## Si es false, el icono se ve apagado.
var enabled: bool = true:
	set(value):
		enabled = value
		queue_redraw()
## Casilla elegida (borde de acento).
var selected: bool = false:
	set(value):
		selected = value
		queue_redraw()
## Contenido del tooltip: [code]title[/code], [code]subtitle[/code] y [code]body[/code].
var tooltip_info: Dictionary = {}

var _cooldown_total: float = 0.0
var _cooldown_left: float = 0.0
var _flash_left: float = 0.0
var _hovered: bool = false
var _glyph: UIKeyGlyph = null
var _box: StyleBoxFlat = StyleBoxFlat.new()


## Texto de los segundos que faltan: enteros hacia arriba desde 1 s («9») y con un decimal por
## debajo («0,7»).
static func cooldown_text(seconds: float) -> String:
	if seconds <= 0.0:
		return ""
	if seconds < 1.0:
		return ("%.1f" % seconds).replace(".", ",")
	return str(ceili(seconds))


## Polígono que cubre la parte de [param rect] barrida, en sentido horario desde las 12 en punto,
## por [param fraction] (0 a 1) de una vuelta completa: con 1 es todo el rectángulo, con 0,5 la mitad
## derecha, con 0 vacío. Es un abanico desde el centro que sigue el borde del rectángulo.
static func sweep_polygon(rect: Rect2, fraction: float) -> PackedVector2Array:
	var amount: float = clampf(fraction, 0.0, 1.0)
	if amount <= 0.0 or rect.size.x <= 0.0 or rect.size.y <= 0.0:
		return PackedVector2Array()
	var center: Vector2 = rect.get_center()
	var start_angle: float = -PI / 2.0
	var end_angle: float = start_angle + TAU * amount
	var points: PackedVector2Array = PackedVector2Array([center, _edge_point(rect, start_angle)])
	# Las esquinas que quedan dentro del arco, en orden de ángulo creciente.
	var corners: Array[Vector2] = [rect.position + Vector2(rect.size.x, 0.0), rect.end,
			rect.position + Vector2(0.0, rect.size.y), rect.position]
	for corner: Vector2 in corners:
		var angle: float = (corner - center).angle()
		while angle <= start_angle + 0.00001:
			angle += TAU
		if angle < end_angle - 0.00001:
			points.append(corner)
	points.append(_edge_point(rect, end_angle))
	return points


# Punto del borde de [param rect] en la dirección [param angle] desde su centro.
static func _edge_point(rect: Rect2, angle: float) -> Vector2:
	var center: Vector2 = rect.get_center()
	var direction: Vector2 = Vector2(cos(angle), sin(angle))
	var half: Vector2 = rect.size * 0.5
	var scale_x: float = half.x / absf(direction.x) if absf(direction.x) > 0.000001 else INF
	var scale_y: float = half.y / absf(direction.y) if absf(direction.y) > 0.000001 else INF
	return center + direction * minf(scale_x, scale_y)


func _init() -> void:
	custom_minimum_size = SLOT_SIZE
	focus_mode = Control.FOCUS_ALL
	mouse_filter = Control.MOUSE_FILTER_STOP
	mouse_entered.connect(_on_mouse_entered)
	mouse_exited.connect(_on_mouse_exited)
	focus_entered.connect(queue_redraw)
	focus_exited.connect(queue_redraw)


func _ready() -> void:
	# El motor activa _process al entrar en el árbol si el script lo define: se apaga hasta que haga
	# falta (una reutilización en marcha o un destello).
	set_process(_cooldown_left > 0.0 or _flash_left > 0.0)


func _process(delta: float) -> void:
	advance(delta)


# --- Reutilización ----------------------------------------------------------------------------

## Empieza una reutilización de [param seconds] segundos (la predicción al pulsar).
func start_cooldown(seconds: float) -> void:
	if seconds <= 0.0:
		clear_cooldown()
		return
	_cooldown_total = seconds
	_cooldown_left = seconds
	_flash_left = 0.0
	set_process(true)
	queue_redraw()


## Fija la reutilización con lo que dice el servidor: faltan [param remaining] s de [param total].
## Con [param remaining] a 0 o menos la quita sin destello (por ejemplo, el servidor rechazó la
## acción y no llegó a gastarse).
func set_cooldown(remaining: float, total: float) -> void:
	if remaining <= 0.0:
		clear_cooldown()
		return
	_cooldown_total = maxf(total, remaining)
	_cooldown_left = remaining
	set_process(true)
	queue_redraw()


## Quita la reutilización sin destello.
func clear_cooldown() -> void:
	_cooldown_total = 0.0
	_cooldown_left = 0.0
	queue_redraw()


## Avanza [param delta] segundos la reutilización y el destello. Al llegar a cero emite
## [signal cooldown_finished] y da el destello.
func advance(delta: float) -> void:
	if _cooldown_left > 0.0:
		_cooldown_left = maxf(_cooldown_left - delta, 0.0)
		if _cooldown_left <= 0.0:
			_cooldown_total = 0.0
			_flash_left = FLASH_SECONDS
			cooldown_finished.emit()
		queue_redraw()
	elif _flash_left > 0.0:
		_flash_left = maxf(_flash_left - delta, 0.0)
		queue_redraw()
	if _cooldown_left <= 0.0 and _flash_left <= 0.0:
		set_process(false)


func is_on_cooldown() -> bool:
	return _cooldown_left > 0.0


## Segundos que faltan.
func get_cooldown_remaining() -> float:
	return _cooldown_left


## Fracción de la reutilización que falta (1 recién empezada, 0 lista).
func get_cooldown_fraction() -> float:
	return _cooldown_left / _cooldown_total if _cooldown_total > 0.0 else 0.0


## Opacidad actual del destello de «lista» (0 sin destello).
func get_flash_alpha() -> float:
	return clampf(_flash_left / FLASH_SECONDS, 0.0, 1.0)


## Glifo de tecla de la esquina (null mientras no haya [member key_action]).
func get_glyph() -> UIKeyGlyph:
	return _glyph


func is_hovered() -> bool:
	return _hovered


## Color del borde ahora: el de la rareza (o el de metal sin ella), el de acento si está elegida y un
## poco más claro con el ratón encima.
func get_border_color() -> Color:
	var border: Color = UIPalette.rarity_color(rarity) if rarity >= 0 else UIPalette.BORDER
	if selected:
		return UIPalette.ACCENT
	if _hovered:
		return border.lightened(0.25)
	return border


## Texto del contador de pila: vacío si la pila es de 1 o menos.
func get_count_text() -> String:
	return str(count) if count > 1 else ""


# --- Tooltip ----------------------------------------------------------------------------------

## Guarda el contenido del tooltip: [param title], [param body] (BBCode) y [param subtitle].
func set_tooltip_info(title: String, body: String = "", subtitle: String = "") -> void:
	tooltip_info = {"title": title, "body": body, "subtitle": subtitle}


## El contenido que pide el [UITooltip]: el guardado más el color de la rareza para el título;
## vacío si no hay título.
func get_tooltip_content() -> Dictionary:
	if String(tooltip_info.get("title", "")).is_empty():
		return {}
	var content: Dictionary = tooltip_info.duplicate()
	content["accent"] = UIPalette.rarity_color(rarity) if rarity >= 0 else UIPalette.TITLE
	return content


## Enlaza la casilla con [param tooltip] (al pasar el ratón o enfocarla lo muestra).
func bind_tooltip(tooltip: UITooltip) -> void:
	tooltip.bind_source(self, get_tooltip_content)


# --- Entrada ----------------------------------------------------------------------------------

func _gui_input(event: InputEvent) -> void:
	var click: InputEventMouseButton = event as InputEventMouseButton
	if click != null and click.button_index == MOUSE_BUTTON_LEFT and not click.pressed \
			and Rect2(Vector2.ZERO, size).has_point(click.position):
		_press()
		accept_event()
	elif event.is_action_pressed(&"ui_accept") and has_focus():
		_press()
		accept_event()


func _press() -> void:
	UISounds.play(UISounds.CLICK)
	pressed.emit()


func _on_mouse_entered() -> void:
	_hovered = true
	UISounds.play(UISounds.HOVER)
	queue_redraw()


func _on_mouse_exited() -> void:
	_hovered = false
	queue_redraw()


# --- Dibujo -----------------------------------------------------------------------------------

func _update_glyph() -> void:
	if key_action == &"":
		if _glyph != null:
			_glyph.queue_free()
			_glyph = null
		return
	if _glyph == null:
		_glyph = UIKeyGlyph.new()
		_glyph.compact = true
		_glyph.position = Vector2(3.0, 3.0)
		add_child(_glyph)
	_glyph.action = key_action


func _draw() -> void:
	var rect: Rect2 = Rect2(Vector2.ZERO, size)
	_box.bg_color = UIPalette.INSET_BG
	_box.border_color = get_border_color()
	_box.set_border_width_all(BORDER_WIDTH)
	_box.set_corner_radius_all(3)
	_box.anti_aliasing = true
	draw_style_box(_box, rect)
	var inner: Rect2 = rect.grow(-float(BORDER_WIDTH))
	if icon != null:
		draw_texture_rect(icon, rect.grow(-ICON_MARGIN), false,
				Color.WHITE if enabled else DISABLED_TINT)
	var font: Font = get_theme_default_font()
	if _cooldown_left > 0.0:
		var points: PackedVector2Array = sweep_polygon(inner, get_cooldown_fraction())
		if points.size() >= 3:
			draw_colored_polygon(points, COOLDOWN_OVERLAY)
		var text: String = cooldown_text(_cooldown_left)
		var text_size: Vector2 = font.get_string_size(text, HORIZONTAL_ALIGNMENT_CENTER, -1.0,
				COOLDOWN_FONT_SIZE)
		var origin: Vector2 = Vector2((size.x - text_size.x) * 0.5,
				(size.y - text_size.y) * 0.5 + font.get_ascent(COOLDOWN_FONT_SIZE))
		draw_string_outline(font, origin, text, HORIZONTAL_ALIGNMENT_LEFT, -1.0,
				COOLDOWN_FONT_SIZE, 4, UIPalette.OUTLINE)
		draw_string(font, origin, text, HORIZONTAL_ALIGNMENT_LEFT, -1.0, COOLDOWN_FONT_SIZE,
				UIPalette.TEXT)
	var count_text: String = get_count_text()
	if not count_text.is_empty():
		var count_origin: Vector2 = Vector2(0.0, size.y - 5.0)
		draw_string_outline(font, count_origin, count_text, HORIZONTAL_ALIGNMENT_RIGHT,
				size.x - 5.0, COUNT_FONT_SIZE, 4, UIPalette.OUTLINE)
		draw_string(font, count_origin, count_text, HORIZONTAL_ALIGNMENT_RIGHT, size.x - 5.0,
				COUNT_FONT_SIZE, UIPalette.TEXT)
	if _flash_left > 0.0:
		draw_rect(inner, UIPalette.with_alpha(Color.WHITE, 0.55 * get_flash_alpha()))
	if has_focus():
		var ring: StyleBoxFlat = StyleBoxFlat.new()
		ring.draw_center = false
		ring.border_color = UIPalette.ACCENT.lightened(0.15)
		ring.set_border_width_all(2)
		ring.set_corner_radius_all(3)
		draw_style_box(ring, rect.grow(1.0))
