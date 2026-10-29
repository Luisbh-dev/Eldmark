class_name UITooltip
extends PanelContainer
## Tooltip enriquecido (UI-09): título (con el color de rareza o de bando), subtítulo y cuerpo con
## BBCode, que aparece tras un retraso y se ajusta a los bordes de la pantalla.
## [br][br]
## [b]Uso.[/b] Un tooltip compartido por viewport ([method get_shared]) lo alimentan las casillas y
## los controles que lo piden: [method request] arranca la espera ([member delay] segundos) y
## [method cancel] la anula y lo oculta; [method bind_source] hace las dos cosas por su cuenta cuando
## el ratón entra y sale de un control (o este recibe y pierde el foco, para el teclado y el mando).
## Mientras la espera o la muestra siguen a un ratón, el tooltip lo acompaña.
## [br][br]
## [b]Colocación.[/b] [method fit_position] es la regla (pura, para poder probarla): por defecto a la
## derecha y debajo del cursor; si así se saldría de [param bounds] por la derecha pasa a la
## izquierda, y por abajo, encima; después se encaja dentro dejando [constant MARGIN] px de borde.
## [br][br]
## El tiempo lo lleva [method advance] ([method _process] lo llama con el delta de cada fotograma);
## las pruebas lo llaman con pasos exactos. Nunca captura el ratón.
## [br][br]
## Solo cliente.

## Segundos que el ratón debe quedarse quieto sobre un control antes de que aparezca el tooltip.
const DEFAULT_DELAY: float = 0.45
## Separación (px) entre el cursor y el tooltip, y borde mínimo con la pantalla.
const CURSOR_OFFSET: Vector2 = Vector2(16.0, 22.0)
const MARGIN: float = 8.0
## Ancho máximo del texto (px).
const MAX_TEXT_WIDTH: float = 320.0
const MIN_TEXT_WIDTH: float = 140.0
## Capa en la que vive el tooltip compartido (por encima del HUD y las ventanas).
const LAYER: int = 90
## Metadatos de un control enlazado con [method bind_source]: su proveedor y si ya está conectado.
const PROVIDER_META: StringName = &"ui_tooltip_provider"
const BOUND_META: StringName = &"ui_tooltip_bound"

## Segundos de espera antes de mostrarlo.
var delay: float = DEFAULT_DELAY
## Si no es null, los límites en los que se encaja (pruebas); si lo es, el rectángulo visible del
## viewport.
var bounds_override: Variant = null

static var _shared: UITooltip = null

var _title: Label = null
var _subtitle: Label = null
var _body: RichTextLabel = null
var _pending: bool = false
var _showing: bool = false
var _elapsed: float = 0.0
var _anchor: Vector2 = Vector2.ZERO
var _follow_mouse: bool = false


## El tooltip compartido del árbol de [param tree], creado la primera vez (en su propia capa).
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


## Posición (esquina superior izquierda) de un tooltip de tamaño [param tooltip_size] para un cursor
## en [param anchor], dentro de [param bounds]. Ver la regla en la documentación de la clase.
static func fit_position(anchor: Vector2, tooltip_size: Vector2, bounds: Rect2,
		offset: Vector2 = CURSOR_OFFSET) -> Vector2:
	var corner: Vector2 = anchor + offset
	if corner.x + tooltip_size.x > bounds.end.x - MARGIN:
		corner.x = anchor.x - offset.x - tooltip_size.x
	if corner.y + tooltip_size.y > bounds.end.y - MARGIN:
		corner.y = anchor.y - offset.y - tooltip_size.y
	var min_corner: Vector2 = bounds.position + Vector2(MARGIN, MARGIN)
	var max_corner: Vector2 = bounds.end - Vector2(MARGIN, MARGIN) - tooltip_size
	# Si el tooltip es mayor que la pantalla, manda la esquina superior izquierda.
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


func _process(delta: float) -> void:
	if _follow_mouse and (_pending or _showing) and is_inside_tree():
		_anchor = get_viewport().get_mouse_position()
	advance(delta)


## Pide un tooltip con [param title], [param body] (BBCode) y [param subtitle], con el título del
## color [param accent], junto a [param anchor_position] (coordenadas de pantalla; con
## [param follow_mouse] el tooltip sigue al ratón). Empieza la espera de [member delay]; si ya se
## estaba mostrando, cambia el contenido al instante.
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


## Anula la petición y oculta el tooltip.
func cancel() -> void:
	_pending = false
	_showing = false
	_follow_mouse = false
	_elapsed = 0.0
	visible = false


## Avanza [param delta] segundos la espera y, si cumple el retraso, lo muestra.
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


## Mueve el tooltip a [param anchor_position] (pantalla).
func move_to(anchor_position: Vector2) -> void:
	_anchor = anchor_position
	if _showing:
		_place()


## true mientras hay una espera en curso.
func is_pending() -> bool:
	return _pending


## true mientras se ve.
func is_showing() -> bool:
	return _showing


## Segundos que lleva esperando la petición actual.
func get_elapsed() -> float:
	return _elapsed


func get_title_label() -> Label:
	return _title


func get_subtitle_label() -> Label:
	return _subtitle


func get_body_label() -> RichTextLabel:
	return _body


## Enlaza [param control] con este tooltip: al entrar el ratón (o el foco) pide el contenido a
## [param provider] (un [Callable] que devuelve un diccionario con [code]title[/code] y,
## opcionalmente, [code]subtitle[/code], [code]body[/code] y [code]accent[/code]) y al salir lo
## cancela. Un proveedor que devuelve un diccionario vacío no muestra nada.
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


# Ancho del texto: el natural del cuerpo, entre un mínimo y el máximo, para que el cuerpo largo se
# ajuste en varias líneas y el corto no deje un hueco enorme.
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
	# El cuerpo y el título parten el texto según su ancho actual: se les da el ancho antes de medir
	# (si no, con ancho 0 cada palabra ocuparía una línea y el tooltip saldría altísimo) y el alto del
	# cuerpo se pide a su contenido en lugar de fiarlo a la maquetación diferida.
	_body.size = Vector2(_body.custom_minimum_size.x, 0.0)
	_title.size = Vector2(_title.custom_minimum_size.x, 0.0)
	if _body.visible:
		_body.custom_minimum_size.y = float(_body.get_content_height())
	reset_size()
	size = get_combined_minimum_size()
	var rect: Rect2 = get_viewport_rect() if bounds_override == null else (bounds_override as Rect2)
	position = fit_position(_anchor, size, rect)
