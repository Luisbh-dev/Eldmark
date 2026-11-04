class_name WarBanners
extends Control
## Banners de los avisos de guerra (UI-18, GUE-13 parte cliente, UI-08): fuerte atacado, capitán caído,
## captura iniciada o disputada, puerta rota, fuerte capturado y reiniciado. El servidor los manda por
## ENTITY_EVENT [code]WAR[/code] a toda la zona; [NetClient] los entrega en el tick de dibujo
## ([signal NetClient.war_event]) y aquí se convierten en texto con [method WarEvents.text].
## [br][br]
## [b]Cola, de uno en uno.[/b] Los avisos esperan en una cola (como mucho [constant MAX_BANNERS]: al llegar otro
## se quita el más antiguo) y se ven de uno en uno sobre una banda oscura con el emblema del bando a los dos
## lados y el texto en la fuente de títulos. Así nunca se pisan entre sí, y la banda tiene su sitio fijo
## ([constant TOP_OFFSET]) entre el panel del fuerte, la barra de jefe y el aviso de derribado. El tiempo de
## cada aviso solo corre mientras es el que se ve; el fundido es breve ([constant FADE_SECONDS]) y lo hace la
## banda entera, para que la letra y su contorno no se aclaren por separado.
## [br][br]
## Las medidas, los colores y las duraciones son provisionales. Solo cliente.

## Avisos en la cola como mucho (al llegar otro, se quita el más antiguo).
const MAX_BANNERS: int = 3
## Segundos que dura un banner normal y uno grande, y el fundido de entrada y de salida.
const NORMAL_SECONDS: float = 4.0
const BIG_SECONDS: float = 6.0
const FADE_SECONDS: float = 0.25
const NORMAL_FONT_SIZE: int = 22
const BIG_FONT_SIZE: int = 28
## Lugar de la banda: px desde lo alto, justo bajo el panel del fuerte (que acaba hacia los 155 px).
const TOP_OFFSET: float = 166.0
const MIN_WIDTH: float = 460.0
const EMBLEM_SIZE: float = 30.0
const BAND_COLOR: Color = Color(0.03, 0.035, 0.05, 0.82)
## Avisos que se muestran en grande.
const BIG_EVENTS: Array[int] = [
	WarEvents.CAPTAIN_DOWN, WarEvents.GATE_BROKEN, WarEvents.FORT_CAPTURED, WarEvents.FORT_RESET,
]

var _client: NetClient = null
var _view: FortressView = null
var _band: PanelContainer = null
var _label: Label = null
var _emblem_left: TextureRect = null
var _emblem_right: TextureRect = null
# La cola: el primero es el que se ve. Cada uno: label (texto), left, text, big, color, emblem.
var _banners: Array[Dictionary] = []


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_ensure_built()


func _process(delta: float) -> void:
	advance(delta)


func _exit_tree() -> void:
	if is_instance_valid(_client) and _client.war_event.is_connected(show_war_event):
		_client.war_event.disconnect(show_war_event)


## Conecta los banners con los avisos de [param client] y, para el nombre del fuerte, con
## [param view].
func bind(client: NetClient, view: FortressView) -> void:
	if is_instance_valid(_client) and _client.war_event.is_connected(show_war_event):
		_client.war_event.disconnect(show_war_event)
	_client = client
	_view = view
	_ensure_built()
	if is_instance_valid(_client):
		_client.war_event.connect(show_war_event)


## Muestra el aviso [param event] (un ENTITY_EVENT de tipo WAR). Un id de aviso desconocido no hace
## nada. Devuelve el texto mostrado.
func show_war_event(event: NetMessages.EntityEvent) -> String:
	if event == null or not WarEvents.is_valid(event.war_event):
		return ""
	var fortress_name: String = WarEvents.DEFAULT_FORTRESS_NAME
	if is_instance_valid(_view):
		var definition: FortressDefinition = _view.get_definition(event.net_id)
		if definition != null:
			fortress_name = definition.display_name
	var text: String = WarEvents.text(event.war_event, event.war_realm, fortress_name)
	add_banner(text, color_for(event.war_event, event.war_realm), BIG_EVENTS.has(event.war_event),
			emblem_for(event.war_event, event.war_realm))
	return text


## Color del banner: el del bando que lo provoca; los avisos sin bando (disputa, reinicio), el color de
## los Huecos.
static func color_for(war_event: int, realm: int) -> Color:
	if war_event == WarEvents.CAPTURE_CONTESTED or war_event == WarEvents.FORT_RESET:
		return UIPalette.WARNING
	return UIPalette.faction_color_of_code(realm)


## Emblema del bando del aviso (null si no hay bando o no hay emblema).
static func emblem_for(war_event: int, realm: int) -> Texture2D:
	if war_event == WarEvents.CAPTURE_CONTESTED or war_event == WarEvents.FORT_RESET:
		return null
	return UIPalette.load_emblem(RealmCatalog.id_of_code(realm))


## Pone en la cola un banner con [param text] del color [param color]; [param big] lo hace grande y más largo.
## [param emblem] es el emblema que lleva a los lados (opcional).
func add_banner(text: String, color: Color, big: bool = false, emblem: Texture2D = null) -> void:
	_ensure_built()
	if text.is_empty():
		return
	while _banners.size() >= MAX_BANNERS:
		_banners.remove_at(0)
	_banners.append({"left": BIG_SECONDS if big else NORMAL_SECONDS, "text": text, "big": big,
			"color": color, "emblem": emblem})
	_refresh_view()


## Avanza [param delta] segundos: solo corre el tiempo del aviso que se ve; al acabar, entra el siguiente.
func advance(delta: float) -> void:
	if _banners.is_empty():
		return
	var banner: Dictionary = _banners[0]
	banner["left"] = float(banner["left"]) - delta
	if float(banner["left"]) <= 0.0:
		_banners.remove_at(0)
		_refresh_view()
	else:
		_band.modulate.a = band_alpha(float(banner["left"]), float(BIG_SECONDS if bool(banner["big"])
				else NORMAL_SECONDS))


## Opacidad de la banda con [param left] segundos por mostrar de un aviso de [param total] segundos: entra y
## sale con un fundido de [constant FADE_SECONDS].
static func band_alpha(left: float, total: float) -> float:
	var fade_in: float = clampf((total - left) / FADE_SECONDS, 0.0, 1.0)
	var fade_out: float = clampf(left / FADE_SECONDS, 0.0, 1.0)
	return minf(fade_in, fade_out)


## Quita todos los banners.
func clear() -> void:
	_banners.clear()
	_refresh_view()


## Avisos en la cola (el que se ve y los que esperan).
func get_banner_count() -> int:
	return _banners.size()


## Textos de la cola, del que se ve a los que esperan.
func get_texts() -> PackedStringArray:
	var texts := PackedStringArray()
	for banner: Dictionary in _banners:
		texts.append(String(banner["text"]))
	return texts


func get_banner_color(index: int) -> Color:
	return _banners[index]["color"] if index >= 0 and index < _banners.size() else Color.WHITE


func is_banner_big(index: int) -> bool:
	return index >= 0 and index < _banners.size() and bool(_banners[index]["big"])


func get_banner_seconds_left(index: int) -> float:
	return float(_banners[index]["left"]) if index >= 0 and index < _banners.size() else 0.0


## true si la banda se ve (hay algún aviso).
func is_band_visible() -> bool:
	return _band != null and _band.visible


## La banda en la que se ve el aviso actual (para medirla en las pruebas).
func get_band() -> PanelContainer:
	return _band


# Pone la banda al día con el primer aviso de la cola (o la esconde).
func _refresh_view() -> void:
	if _band == null:
		return
	if _banners.is_empty():
		_band.visible = false
		return
	var banner: Dictionary = _banners[0]
	var color: Color = banner["color"]
	var big: bool = bool(banner["big"])
	_label.text = String(banner["text"])
	_label.add_theme_font_size_override(&"font_size", BIG_FONT_SIZE if big else NORMAL_FONT_SIZE)
	_label.add_theme_color_override(&"font_color", color.lightened(0.25))
	var style: StyleBoxFlat = _band.get_theme_stylebox(&"panel") as StyleBoxFlat
	style.border_color = color
	var emblem: Texture2D = banner["emblem"]
	for rect: TextureRect in [_emblem_left, _emblem_right]:
		rect.texture = emblem
		rect.visible = emblem != null
		rect.modulate = color.lightened(0.15)
	_band.visible = true
	_band.modulate.a = 0.0
	# Centrada en x = 960: con el texto nuevo se mide su ancho y se reparte a los dos lados del ancla.
	_band.reset_size()
	var width: float = maxf(_band.get_combined_minimum_size().x, MIN_WIDTH)
	_band.offset_left = -width * 0.5
	_band.offset_right = width * 0.5


func _ensure_built() -> void:
	if _band != null:
		return
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_band = PanelContainer.new()
	_band.name = "Banda"
	_band.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_band.visible = false
	var style := StyleBoxFlat.new()
	style.bg_color = BAND_COLOR
	style.border_color = UIPalette.BORDER
	style.border_width_top = 2
	style.border_width_bottom = 2
	style.content_margin_left = 18.0
	style.content_margin_right = 18.0
	style.content_margin_top = 6.0
	style.content_margin_bottom = 6.0
	_band.add_theme_stylebox_override(&"panel", style)
	_band.custom_minimum_size = Vector2(MIN_WIDTH, 0.0)
	add_child(_band)
	# Centrada: ancla en el centro y crece a los dos lados.
	_band.anchor_left = 0.5
	_band.anchor_right = 0.5
	_band.anchor_top = 0.0
	_band.anchor_bottom = 0.0
	_band.offset_top = TOP_OFFSET
	_band.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_band.grow_vertical = Control.GROW_DIRECTION_END
	var row := HBoxContainer.new()
	row.name = "Fila"
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override(&"separation", 14)
	_band.add_child(row)
	_emblem_left = _make_emblem()
	row.add_child(_emblem_left)
	_label = Label.new()
	_label.name = "Texto"
	_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_label.add_theme_font_override(&"font", UIFonts.title_bold())
	_label.add_theme_color_override(&"font_outline_color", UIPalette.OUTLINE)
	_label.add_theme_constant_override(&"outline_size", 4)
	row.add_child(_label)
	_emblem_right = _make_emblem()
	row.add_child(_emblem_right)


func _make_emblem() -> TextureRect:
	var rect := TextureRect.new()
	rect.custom_minimum_size = Vector2(EMBLEM_SIZE, EMBLEM_SIZE)
	rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	rect.visible = false
	return rect
