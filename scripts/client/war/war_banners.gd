class_name WarBanners
extends Control
## Banners de los avisos de guerra (UI-18, GUE-13 parte cliente): fuerte atacado, capitán caído, captura
## iniciada o disputada, puerta rota, fuerte capturado y reiniciado. El servidor los manda por
## ENTITY_EVENT [code]WAR[/code] a toda la zona; [NetClient] los entrega en el tick de dibujo
## ([signal NetClient.war_event]) y aquí se convierten en texto con [method WarEvents.text] y se
## apilan unos segundos con un fundido final.
## [br][br]
## Las medidas, los colores y las duraciones son provisionales. Solo cliente.

## Banners a la vez como mucho (al llegar otro, se quita el más antiguo).
const MAX_BANNERS: int = 3
## Segundos que dura un banner normal y uno grande, y cuántos de ellos son de fundido final.
const NORMAL_SECONDS: float = 5.0
const BIG_SECONDS: float = 8.0
const FADE_SECONDS: float = 1.0
const NORMAL_FONT_SIZE: int = 22
const BIG_FONT_SIZE: int = 32
const TOP_OFFSET: float = 262.0
const WIDTH: float = 900.0
## Avisos que se muestran en grande.
const BIG_EVENTS: Array[int] = [
	WarEvents.CAPTAIN_DOWN, WarEvents.GATE_BROKEN, WarEvents.FORT_CAPTURED, WarEvents.FORT_RESET,
]

var _client: NetClient = null
var _view: FortressView = null
var _column: VBoxContainer = null
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
	add_banner(text, color_for(event.war_event, event.war_realm), BIG_EVENTS.has(event.war_event))
	return text


## Color del banner: el del bando que lo provoca; los avisos sin bando (disputa, reinicio), el color de
## los Huecos.
static func color_for(war_event: int, realm: int) -> Color:
	if war_event == WarEvents.CAPTURE_CONTESTED or war_event == WarEvents.FORT_RESET:
		return UIPalette.WARNING
	return UIPalette.faction_color_of_code(realm)


## Apila un banner con [param text] del color [param color]; [param big] lo hace grande y más largo.
func add_banner(text: String, color: Color, big: bool = false) -> void:
	_ensure_built()
	if text.is_empty():
		return
	while _banners.size() >= MAX_BANNERS:
		_remove_banner(0)
	var label := Label.new()
	label.text = text
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.add_theme_font_size_override(&"font_size", BIG_FONT_SIZE if big else NORMAL_FONT_SIZE)
	label.add_theme_color_override(&"font_color", color)
	label.add_theme_color_override(&"font_outline_color", UIPalette.OUTLINE)
	label.add_theme_constant_override(&"outline_size", 8)
	_column.add_child(label)
	_banners.append({"label": label, "left": BIG_SECONDS if big else NORMAL_SECONDS, "text": text,
			"big": big, "color": color})


## Avanza [param delta] segundos: fundido final y retirada de los que acaban.
func advance(delta: float) -> void:
	var index: int = _banners.size() - 1
	while index >= 0:
		var banner: Dictionary = _banners[index]
		banner["left"] = float(banner["left"]) - delta
		if float(banner["left"]) <= 0.0:
			_remove_banner(index)
		else:
			(banner["label"] as Label).modulate.a = clampf(float(banner["left"]) / FADE_SECONDS, 0.0, 1.0)
		index -= 1


## Quita todos los banners.
func clear() -> void:
	while not _banners.is_empty():
		_remove_banner(0)


func get_banner_count() -> int:
	return _banners.size()


## Textos de los banners que se ven, del más antiguo al más nuevo.
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


func _remove_banner(index: int) -> void:
	var label: Label = _banners[index]["label"]
	_banners.remove_at(index)
	if is_instance_valid(label):
		label.get_parent().remove_child(label)
		label.queue_free()


func _ensure_built() -> void:
	if _column != null:
		return
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_column = VBoxContainer.new()
	_column.name = "Columna"
	_column.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_column.alignment = BoxContainer.ALIGNMENT_BEGIN
	_column.add_theme_constant_override(&"separation", 4)
	add_child(_column)
	_column.anchor_left = 0.5
	_column.anchor_right = 0.5
	_column.anchor_top = 0.0
	_column.anchor_bottom = 0.0
	_column.offset_left = -WIDTH * 0.5
	_column.offset_right = WIDTH * 0.5
	_column.offset_top = TOP_OFFSET
	_column.offset_bottom = TOP_OFFSET
	_column.grow_vertical = Control.GROW_DIRECTION_END
